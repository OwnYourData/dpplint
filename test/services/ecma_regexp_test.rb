require "test_helper"

# Expected results were taken from JavaScript (new RegExp(pattern).test(value)),
# i.e. ECMA-262 without flags.
class EcmaRegexpTest < ActiveSupport::TestCase
  def search?(pattern, value) = EcmaRegexp.search?(pattern, value)

  test "searched anywhere in the value, not implicitly anchored" do
    assert search?("json", "application/ld+json; charset=utf-8")
    assert search?("^application/(ld\\+)?json(;|$)", "application/ld+json; charset=utf-8")
    assert search?("^application/(ld\\+)?json(;|$)", "application/json")
    refute search?("^application/(ld\\+)?json(;|$)", "text/application/json")
  end

  test "^ and $ anchor the whole value, not a line" do
    refute search?("^b", "a\nb")
    refute search?("a$", "a\nb")
    refute search?("a$", "a\n")
    assert search?("^a", "a\nb")
    assert search?("b$", "a\nb")
    assert search?("^a\\nb$", "a\nb")
  end

  test "case-sensitive" do
    refute search?("accept", "Accept")
    assert search?("Accept", "Origin, Accept")
  end

  test ". does not match line terminators" do
    assert search?("a.c", "abc")
    refute search?("a.c", "a\nc")
    refute search?("^.$", " ")
    refute search?("^.$", "\r")
  end

  test "\\s, \\b and \\w follow ECMA-262" do
    assert search?("\\s", " ")
    assert search?("\\s", "﻿")
    refute search?("[^\\s]", " ")
    refute search?("\\w", "é")
    assert search?("\\bfoo\\b", "éfooé")
    refute search?("\\Bo", "o")
  end

  test "Annex B: identity escapes and lone braces are literals" do
    assert search?("\\A", "A")
    refute search?("\\Aa", "a")
    assert search?("\\h", "h")
    assert search?("a{", "a{")
    assert search?("a{,2}", "a{,2}")
    refute search?("a{,2}", "aa")
    assert search?("\\u{2}", "uu")
    assert search?("\\p{L}", "p{L}")
  end

  test "character classes: no nesting, no intersection" do
    assert search?("[[a]", "[")
    assert search?("[a&&b]", "&")
    refute search?("[a&&b]", "c")
    assert search?("[\\d-z]", "-")
    refute search?("[]", "a")
    assert search?("[^]", "\n")
    assert search?("[\\b]", "\b")
  end

  test "quantifiers" do
    assert search?("^(?:ab)+$", "abab")
    assert search?("^a{2}?$", "aa")
    refute search?("^a{2}?$", "a")
    assert search?("^[0-9]{4}-[0-9]{2}-[0-9]{2}T", "2026-09-28T10:00:00Z")
  end

  test "escapes of characters" do
    assert search?("\\x41", "A")
    assert search?("\\x4", "x4")
    assert search?("\\u0041", "A")
    assert search?("x\\cAy", "x\u0001y")
    assert search?("\\c", "\\c")
    assert search?("\\uD83D\\uDE00", "😀")
  end

  test "patterns that are not valid ECMA-262" do
    ["(?i)a", "a**", "a*+", "^*", "\\b+", "a{2,1}", "[z-a]", "(?>a)", "(", ")", "a\\", "[a", "{2}"].each do |pattern|
      assert_match(/\Ais not a valid ECMA-262 regular expression/, EcmaRegexp.problem(pattern), pattern)
    end
  end

  test "valid patterns outside the portable subset are not evaluated" do
    ["(?=a)", "(?<!a)b", "(?<n>a)", "(a)\\1", "\\01", "\\k<a>", "\\uD83D"].each do |pattern|
      assert_match(/\Auses a feature outside the portable subset/, EcmaRegexp.problem(pattern), pattern)
    end
    assert_nil EcmaRegexp.problem("^Accept$")
  end

  test "values that are not valid UTF-8 do not raise" do
    refute search?("é", "\xFF".b)
  end
end
