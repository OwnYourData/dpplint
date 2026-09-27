require "test_helper"

class HeaderAssertionTest < ActiveSupport::TestCase
  def problems(assertion, headers) = HeaderAssertion.new(assertion).failures(headers)
  def holds?(assertion, headers) = problems(assertion, headers).empty?

  VARY = { "vary" => ["Accept-Encoding, Accept"] }.freeze

  test "exists true holds when the field is present, fails when it is missing" do
    assert holds?({ "name" => "Vary", "exists" => true }, VARY)
    assert_equal ["header Vary is missing"], problems({ "name" => "Vary", "exists" => true }, {})
  end

  test "exists false holds when the field is missing, fails when it is present" do
    assert holds?({ "name" => "Vary", "exists" => false }, {})
    assert_match(/header Vary is present .*expected it to be absent/, problems({ "name" => "Vary", "exists" => false }, VARY).first)
  end

  test "field present with an empty value exists" do
    assert holds?({ "name" => "Vary", "exists" => true }, { "vary" => [""] })
  end

  test "equals compares the whole value exactly" do
    assert holds?({ "name" => "Vary", "equals" => "Accept-Encoding, Accept" }, VARY)
    refute holds?({ "name" => "Vary", "equals" => "Accept" }, VARY)
    refute holds?({ "name" => "Vary", "equals" => "accept-encoding, accept" }, VARY)
  end

  test "contains finds a trimmed member, case-insensitively" do
    assert holds?({ "name" => "Vary", "contains" => "Accept" }, VARY)
    assert holds?({ "name" => "Vary", "contains" => "accept" }, { "vary" => ["Origin ,  ACCEPT  "] })
    assert_equal ['header Vary is "Accept-Encoding", expected a member "Accept"'],
                 problems({ "name" => "Vary", "contains" => "Accept" }, { "vary" => ["Accept-Encoding"] })
  end

  test "Vary * does not contain Accept" do
    refute holds?({ "name" => "Vary", "contains" => "Accept" }, { "vary" => ["*"] })
  end

  test "matches searches the whole value" do
    assert holds?({ "name" => "Cache-Control", "matches" => "max-age=\\d+" }, { "cache-control" => ["public, max-age=300"] })
    refute holds?({ "name" => "Cache-Control", "matches" => "\\Ano-store\\z" }, { "cache-control" => ["public, no-store"] })
  end

  test "invalid regular expression fails with a message" do
    assert_match(/regular expression "\(" for header X-Test is invalid/, problems({ "name" => "X-Test", "matches" => "(" }, { "x-test" => ["a"] }).first)
  end

  test "missing field fails equals, contains and matches" do
    %w[equals contains matches].each do |op|
      assert_match(/\Aheader Vary is missing, expected/, problems({ "name" => "Vary", op => "Accept" }, {}).first, op)
    end
  end

  test "missing field fails every operation of an assertion except exists false" do
    result = problems({ "name" => "Vary", "exists" => false, "contains" => "Accept" }, {})
    assert_equal ['header Vary is missing, expected a member "Accept"'], result
  end

  test "field name is matched case-insensitively" do
    assert holds?({ "name" => "vary", "contains" => "Accept" }, { "Vary" => ["Accept"] })
    assert holds?({ "name" => "VARY", "equals" => "Accept" }, { "vary" => ["Accept"] })
  end

  test "several fields with the same name are combined with commas" do
    headers = { "vary" => ["Origin", "Accept"] }
    assert holds?({ "name" => "Vary", "equals" => "Origin, Accept" }, headers)
    assert holds?({ "name" => "Vary", "contains" => "Accept" }, headers)
    assert holds?({ "name" => "Vary", "matches" => "Origin, Accept" }, headers)
  end

  test "fields whose names differ only in case are combined" do
    headers = { "Vary" => "Origin", "vary" => ["Accept"] }
    assert_equal "Origin, Accept", HeaderAssertion.field(headers, "VARY")
  end

  test "all operations of one assertion are checked" do
    result = problems({ "name" => "Vary", "exists" => true, "equals" => "Accept", "contains" => "Origin" }, { "vary" => ["Accept"] })
    assert_equal ['header Vary is "Accept", expected a member "Origin"'], result
  end

  test "severity warning turns a failure into a warning" do
    assertions = [{ "name" => "Vary", "contains" => "Accept", "severity" => "warning" }, { "name" => "Vary", "exists" => true }]
    assert_equal [{ severity: "warning", message: "header Vary is missing, expected a member \"Accept\"" },
                  { severity: "violation", message: "header Vary is missing" }],
                 HeaderAssertion.messages(assertions, {})
  end

  test "severity error is a violation" do
    assert_equal ["violation"], HeaderAssertion.messages([{ "name" => "Vary", "exists" => true, "severity" => "error" }], nil).map { |m| m[:severity] }
  end
end
