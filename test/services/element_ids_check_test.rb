require "test_helper"

class ElementIdsCheckTest < ActiveSupport::TestCase
  LEVEL = { "type" => "element_ids", "unique" => "level" }.freeze
  PASSPORT = { "type" => "element_ids", "unique" => "passport" }.freeze
  VECTORS = Rails.root.join("test/fixtures/files/element_ids")

  def outcome(check, text, source: true)
    ElementIdsCheck.new(check, JSON.parse(text), source: source ? text : nil).outcome
  end

  def vectors(id, kind) = Dir[VECTORS.join(id, kind, "*.json")].sort

  # Test vectors: DPP-DAT-017 (unique: level) and DPP-DAT-021 (unique: passport).
  test "DPP-DAT-017 test vectors: valid ones pass, invalid ones fail" do
    assert_operator vectors("DPP-DAT-017", "valid").size, :>=, 4
    vectors("DPP-DAT-017", "valid").each do |file|
      o = outcome(LEVEL, File.read(file))
      assert_nil o.skipped, file
      assert_empty o.messages, file
    end
    assert_operator vectors("DPP-DAT-017", "invalid").size, :>=, 4
    vectors("DPP-DAT-017", "invalid").each do |file|
      o = outcome(LEVEL, File.read(file))
      assert_equal ["violation"], o.messages.map { |m| m[:severity] }, file
    end
  end

  test "DPP-DAT-021 test vectors: valid ones pass, the others give a warning" do
    vectors("DPP-DAT-021", "valid").each do |file|
      assert_empty outcome(PASSPORT, File.read(file)).messages, file
    end
    assert_operator vectors("DPP-DAT-021", "warning").size, :>=, 2
    vectors("DPP-DAT-021", "warning").each do |file|
      assert_equal ["warning"], outcome(PASSPORT, File.read(file)).messages.map { |m| m[:severity] }, file
    end
  end

  test "the reference passport passes both" do
    text = file_fixture("reference-passport.json").read
    assert_empty outcome(LEVEL, text).messages
    assert_empty outcome(PASSPORT, text).messages
  end

  test "messages name the repeated elementId, how often and where" do
    text = VECTORS.join("DPP-DAT-017/invalid/full-collection-language-variants.json").read
    assert_equal "elementId repeated within one level: SafetyInstructions 2 times in ProductInformation",
                 outcome(LEVEL, text).messages.first[:message]
    text = VECTORS.join("DPP-DAT-017/invalid/full-top-level-repeated.json").read
    assert_match(/ModelIdentifier 2 times at the top level of the passport/, outcome(LEVEL, text).messages.first[:message])
    text = VECTORS.join("DPP-DAT-017/invalid/full-multi-valued-item-repeated.json").read
    assert_match(%r{efficiencyRating2 2 times in EnergyPerformance/efficiencyRatings}, outcome(LEVEL, text).messages.first[:message])
    text = VECTORS.join("DPP-DAT-021/warning/full-same-id-in-two-collections.json").read
    assert_equal "elementId used at more than one place of the passport: name at 2 places (Manufacturer/name, Importer/name)",
                 outcome(PASSPORT, text).messages.first[:message]
  end

  test "a repeated elementId is reported once by the level check, not again as a second place" do
    text = VECTORS.join("DPP-DAT-017/invalid/full-collection-language-variants.json").read
    assert_empty outcome(PASSPORT, text).messages
  end

  test "compressed serialization: repeated member names in the passport as delivered fail" do
    text = VECTORS.join("DPP-DAT-017/invalid/compressed-repeated-member.json").read
    assert_equal "member name repeated within one JSON object: maxPressure 2 times in the object at $['performanceMetrics']",
                 outcome(LEVEL, text).messages.first[:message]
  end

  test "compressed serialization without the passport as delivered is skipped" do
    text = VECTORS.join("DPP-DAT-017/valid/compressed-unique.json").read
    o = outcome(LEVEL, text, source: false)
    assert_equal "not_evaluated", o.code
    assert_match(/not available as delivered/, o.skipped)
  end

  test "the passport-wide check skips the compressed serialization" do
    o = outcome(PASSPORT, VECTORS.join("DPP-DAT-017/valid/compressed-unique.json").read)
    assert_equal "not_evaluated", o.code
    assert_match(/compressed serialization/, o.skipped)
  end

  test "the full serialization is checked on the parsed passport, without the bytes" do
    text = VECTORS.join("DPP-DAT-017/invalid/full-top-level-repeated.json").read
    assert_equal ["violation"], outcome(LEVEL, text, source: false).messages.map { |m| m[:severity] }
  end

  test "unreadable bytes skip the compressed check" do
    o = ElementIdsCheck.new(LEVEL, { "dppStatus" => "Active" }, source: '{"dppStatus": "Active",}').outcome
    assert_equal "not_evaluated", o.code
    assert_match(/cannot be read/, o.skipped)
  end

  test "more than ten findings are cut short" do
    elements = (1..12).flat_map { |i| [{ "elementId" => "e#{i}" }, { "elementId" => "e#{i}" }] }
    o = ElementIdsCheck.new(LEVEL, { "elements" => elements }).outcome
    assert_match(/e10 2 times at the top level of the passport and 2 more\z/, o.messages.first[:message])
  end
end
