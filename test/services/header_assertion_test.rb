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

  test "matches searches the pattern anywhere in the value, without implicit anchoring" do
    assert holds?({ "name" => "Cache-Control", "matches" => "max-age=[0-9]+" }, { "cache-control" => ["public, max-age=300"] })
    refute holds?({ "name" => "Cache-Control", "matches" => "^no-store$" }, { "cache-control" => ["public, no-store"] })
    assert holds?({ "name" => "Cache-Control", "matches" => "^public, no-store$" }, { "cache-control" => ["public, no-store"] })
  end

  test "matches: ^ and $ anchor the whole value, also when it contains a line break" do
    headers = { "x-test" => ["first\nsecond"] }
    refute holds?({ "name" => "X-Test", "matches" => "^second" }, headers)
    refute holds?({ "name" => "X-Test", "matches" => "first$" }, headers)
    assert holds?({ "name" => "X-Test", "matches" => "^first" }, headers)
    assert holds?({ "name" => "X-Test", "matches" => "second$" }, headers)
    assert holds?({ "name" => "X-Test", "matches" => "^first\\nsecond$" }, headers)
  end

  test "matches is case-sensitive" do
    headers = { "cache-control" => ["Max-Age=300"] }
    refute holds?({ "name" => "Cache-Control", "matches" => "max-age" }, headers)
    assert holds?({ "name" => "Cache-Control", "matches" => "Max-Age" }, headers)
  end

  test "matches uses ECMA-262 syntax, where \\A is the letter A" do
    refute holds?({ "name" => "Vary", "matches" => "\\AAccept" }, { "vary" => ["Accept"] })
    assert holds?({ "name" => "Vary", "matches" => "\\AAccept" }, { "vary" => ["AAccept"] })
  end

  test "problem names an invalid pattern and a pattern outside the portable subset" do
    assert_nil HeaderAssertion.problem([{ "name" => "Vary", "matches" => "^Accept" }, { "name" => "Vary", "exists" => true }])
    assert_match(/\Aregular expression "\(" for header X-Test is not a valid ECMA-262 regular expression/,
                 HeaderAssertion.problem([{ "name" => "X-Test", "matches" => "(" }]))
    assert_match(/\Aregular expression "\(\?=a\)" for header X-Test uses a feature outside the portable subset .*\(lookahead\)/,
                 HeaderAssertion.problem([{ "name" => "X-Test", "matches" => "(?=a)" }]))
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
