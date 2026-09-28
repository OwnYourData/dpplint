require "test_helper"

class AppliesIfTest < ActiveSupport::TestCase
  BAT_002 = [{ "path" => "$.contentSpecificationIds[?search(@, '[Bb]atter')]", "exists" => true }].freeze
  PCDS_008 = [{ "path" => "$.contentSpecificationIds[?search(@, '59040|PCDS|pcds')]", "exists" => true }].freeze

  def holds?(conditions, passport) = AppliesIf.holds?(conditions, passport)

  test "DPP-BAT-002: search() with I-Regexp on contentSpecificationIds" do
    assert holds?(BAT_002, { "contentSpecificationIds" => ["urn:x", "EN 18222 Battery"] })
    assert holds?(BAT_002, { "contentSpecificationIds" => ["battery-passport"] })
    refute holds?(BAT_002, { "contentSpecificationIds" => ["BATTERY"] })
    refute holds?(BAT_002, { "contentSpecificationIds" => [] })
    refute holds?(BAT_002, {})
  end

  test "DPP-PCDS-008: alternatives in search()" do
    assert holds?(PCDS_008, { "contentSpecificationIds" => ["DIN SPEC 59040"] })
    assert holds?(PCDS_008, { "contentSpecificationIds" => ["urn:pcds"] })
    refute holds?(PCDS_008, { "contentSpecificationIds" => ["Pcds"] })
  end

  test "match() needs the entire element, search() a substring" do
    passport = { "contentSpecificationIds" => ["battery-passport"] }
    refute holds?([{ "path" => "$.contentSpecificationIds[?match(@, '[Bb]atter')]", "exists" => true }], passport)
    assert holds?([{ "path" => "$.contentSpecificationIds[?match(@, '[Bb]atter.*')]", "exists" => true }], passport)
    assert holds?([{ "path" => "$.contentSpecificationIds[?search(@, '[Bb]atter')]", "exists" => true }], passport)
  end

  test "search() is false for elements that are not strings" do
    refute holds?(PCDS_008, { "contentSpecificationIds" => [59040] })
  end

  test "the filter selects array elements or member values, nothing from a string" do
    assert holds?(BAT_002, { "contentSpecificationIds" => { "a" => "Battery" } })
    refute holds?(BAT_002, { "contentSpecificationIds" => "Battery" })
  end

  test "an invalid I-Regexp is found before the JSONPath is evaluated (dpp-criteria 4b17bb8)" do
    conditions = [{ "path" => "$.contentSpecificationIds[?search(@, '\\\\d+')]", "exists" => false }]
    assert_match(/\Aregular expression "\\\\d\+" of search\(\) in applies_if path .* is not a valid I-Regexp \(RFC 9485\)/,
                 AppliesIf.problem(conditions))
  end

  test "^ or $ outside a character class in match() or search() is unusable" do
    ["$.contentSpecificationIds[?search(@, '^[Bb]atter')]", "$.contentSpecificationIds[?match(@, 'pcds$')]"].each do |path|
      assert_match(/in applies_if path .* contains [$^] outside a character class/, AppliesIf.problem([{ "path" => path, "exists" => true }]), path)
    end
    assert_nil AppliesIf.problem([{ "path" => "$.contentSpecificationIds[?match(@, '[^x]+')]", "exists" => true }])
  end

  test "JSONPath string literals: double quotes and escapes (RFC 9535, 2.3.1.1)" do
    passport = { "contentSpecificationIds" => ["a.c", "abc", "it's"] }
    assert holds?([{ "path" => '$.contentSpecificationIds[?search(@, "[Bb]")]', "exists" => true }], { "contentSpecificationIds" => ["Battery"] })
    assert_equal "a\\.c", AppliesIf.string_literal("'a\\\\.c'")
    refute holds?([{ "path" => "$.contentSpecificationIds[?match(@, 'a\\\\.c')]", "exists" => true }], { "contentSpecificationIds" => ["abc"] })
    assert holds?([{ "path" => "$.contentSpecificationIds[?match(@, 'a\\\\.c')]", "exists" => true }], passport)
    assert holds?([{ "path" => "$.contentSpecificationIds[?match(@, 'it\\'s')]", "exists" => true }], passport)
    assert holds?([{ "path" => "$.contentSpecificationIds[ ?search( @ , 'bc' ) ]", "exists" => true }], passport)
  end

  test "exists holds for a member whose value is null or false" do
    assert holds?([{ "path" => "$.facilityId", "exists" => true }], { "facilityId" => nil })
    assert holds?([{ "path" => "$.flag", "exists" => true }], { "flag" => false })
    assert holds?([{ "path" => "$.facilityId", "exists" => false }], {})
  end

  test "matches holds only for JSON strings; other values are not converted to text" do
    condition = [{ "path" => "$.v", "matches" => "^(1|true|null)$" }]
    assert holds?(condition, { "v" => "1" })
    refute holds?(condition, { "v" => 1 })
    refute holds?(condition, { "v" => true })
    refute holds?(condition, { "v" => nil })
    refute holds?([{ "path" => "$.v", "matches" => "a" }], { "v" => ["a"] })
    refute holds?([{ "path" => "$.v", "matches" => "a" }], { "v" => { "k" => "a" } })
    refute holds?([{ "path" => "$.v", "matches" => "59040" }], { "v" => 59040.0 })
    assert holds?([{ "path" => "$.contentSpecificationIds[?search(@, '59040')]", "matches" => "DIN" }], { "contentSpecificationIds" => [59040, "DIN SPEC 59040"] })
  end

  test "matches of the assertion is ECMA-262, searched in the value" do
    assert holds?([{ "path" => "$.granularity", "matches" => "^(item|batch)$" }], { "granularity" => "item" })
    refute holds?([{ "path" => "$.granularity", "matches" => "^(item|batch)$" }], { "granularity" => "model\nitem" })
  end

  test "problem: unsupported path, invalid JSONPath string literal, unusable matches" do
    assert_match(/\Aapplies_if path \$\.a\.b is not supported/, AppliesIf.problem([{ "path" => "$.a.b", "exists" => true }]))
    assert_match(/not a valid JSONPath string literal/, AppliesIf.problem([{ "path" => "$.a[?search(@, 'x'y')]", "exists" => true }]))
    assert_match(/invalid escape/, AppliesIf.problem([{ "path" => "$.a[?search(@, '\\d')]", "exists" => true }]))
    assert_match(/\Aregular expression "\(\?i\)item" in applies_if is not a valid ECMA-262 regular expression/,
                 AppliesIf.problem([{ "path" => "$.granularity", "matches" => "(?i)item" }]))
    assert_nil AppliesIf.problem(BAT_002 + PCDS_008)
    assert_nil AppliesIf.problem(nil)
  end
end
