require "test_helper"

# Expected results agree with the JSONPath Compliance Test Suite where it has a
# case, and with the Python implementation jsonpath-rfc9535.
class IRegexpTest < ActiveSupport::TestCase
  test "match() needs the entire value, search() a substring" do
    assert IRegexp.search?("batter", "battery")
    refute IRegexp.match?("batter", "battery")
    assert IRegexp.match?("batter.*", "battery")
    refute IRegexp.match?("a|b", "ab")
    assert IRegexp.match?("(a|b)+", "abab")
  end

  test "patterns of DPP-BAT-002 and DPP-PCDS-008" do
    assert IRegexp.search?("[Bb]atter", "EN 18222 Battery passport")
    assert IRegexp.search?("[Bb]atter", "battery")
    refute IRegexp.search?("[Bb]atter", "BATTERY")
    refute IRegexp.match?("[Bb]atter", "Battery")
    assert IRegexp.search?("59040|PCDS|pcds", "DIN SPEC 59040")
    assert IRegexp.search?("59040|PCDS|pcds", "urn:pcds:v1")
    refute IRegexp.search?("59040|PCDS|pcds", "Pcds")
  end

  test "^ and $ anchor the whole value (Compliance Test Suite: explicit caret, explicit dollar)" do
    assert IRegexp.match?("^ab.*", "abc")
    refute IRegexp.match?("^ab.*", "xab")
    assert IRegexp.match?(".*bc$", "abc")
    refute IRegexp.match?(".*bc$", "abcx")
    refute IRegexp.search?("^b", "a\nb")
    refute IRegexp.search?("a$", "a\nb")
  end

  test ". matches any character except LF and CR" do
    assert IRegexp.match?(".", " ")
    refute IRegexp.search?(".", "\n")
    refute IRegexp.search?(".", "\r")
    assert IRegexp.match?(".", "😀")
    assert IRegexp.match?("a[.b]c", "a.c")
    refute IRegexp.match?("a\\.c", "abc")
  end

  test "case-sensitive, category escapes" do
    refute IRegexp.search?("pcds", "PCDS")
    assert IRegexp.match?("\\p{Lu}+", "ABC")
    refute IRegexp.match?("\\p{Lu}+", "AbC")
    assert IRegexp.match?("[\\p{Nd}x]", "5")
    assert IRegexp.match?("\\P{L}", "1")
  end

  test "not a string: false" do
    refute IRegexp.search?("5", 5)
    refute IRegexp.match?("true", true)
    refute IRegexp.search?("a", nil)
  end

  test "patterns that do not conform to RFC 9485 give false and a problem" do
    ["\\d", "(?:a)", "a*?", "a{,2}", "[]", "[a-c-e]", "\\p{Xx}", "(a", "a)", "[z-a]", "a{2,1}", "\\w+"].each do |pattern|
      assert_match(/\Ais not a valid I-Regexp \(RFC 9485\)/, IRegexp.problem(pattern), pattern)
      refute IRegexp.search?(pattern, "a"), pattern
      refute IRegexp.match?(pattern, "a"), pattern
    end
    assert_nil IRegexp.problem("[Bb]atter")
    assert_nil IRegexp.problem("59040|PCDS|pcds")
  end
end
