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

  test "a pattern that does not conform to RFC 9485 selects nothing (RFC 9535)" do
    conditions = [{ "path" => "$.contentSpecificationIds[?search(@, '\\\\d+')]", "exists" => true }]
    assert_nil AppliesIf.problem(conditions)
    refute holds?(conditions, { "contentSpecificationIds" => ["59040"] })
    absent = [{ "path" => "$.contentSpecificationIds[?search(@, '\\\\d+')]", "exists" => false }]
    assert holds?(absent, { "contentSpecificationIds" => ["59040"] })
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
