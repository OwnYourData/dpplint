require "test_helper"

# JsTokens tells code from comments, strings, template literals and regular
# expressions.
class JsTokensTest < ActiveSupport::TestCase
  def tokens(code, **opts) = JsTokens.call(code, **opts).map { |t| [t.type, t.value] }

  def kinds(code, type) = JsTokens.call(code).select { |t| t.type == type }.map(&:value)

  test "names, strings, numbers and punctuators" do
    assert_equal [[:name, "a"], [:punct, "?."], [:name, "b"], [:punct, "("], [:string, "x\\'y"], [:punct, ","],
                  [:number, ".5"], [:punct, ","], [:number, "0x1F"], [:punct, ")"]],
                 tokens("a?.b('x\\'y', .5, 0x1F)")
    assert_equal [[:name, "a"], [:punct, "?"], [:number, ".5"], [:punct, ":"], [:number, "1"]], tokens("a?.5:1")
    assert_equal [[:name, "\\u0061b"], [:punct, "="], [:name, "\u00e9t\u00e9"], [:punct, "+"], [:private, "#x"]],
                 tokens("\\u0061b = \u00e9t\u00e9 + #x")
  end

  test "comments are dropped" do
    assert_equal [[:name, "a"], [:name, "b"], [:name, "c"], [:name, "d"]],
                 tokens("#!/usr/bin/env node\na // x\n/* y */ b <!-- z\n--> w\nc /* \n */ d")
  end

  test "a slash after an operand divides, otherwise it starts a regular expression" do
    assert_equal [], kinds("a / b / c; x[1] / 2; (a) / 2; i++ / 2; this / 2", :regexp)
    assert_equal ["/re/g", "/[/]x/", "/=/", "/a/", "/b/", "/c/", "/d/"],
                 kinds("x = /re/g; y(/[/]x/); z = /=/; if (a) /a/.test(s); return /b/; {} /c/; [ /d/ ]", :regexp)
  end

  test "template literals with substitutions" do
    assert_equal [[:template, "a${"], [:name, "b"], [:punct, "+"], [:template, "c${"], [:name, "d"], [:template, "e"],
                  [:template, "f"]],
                 tokens("`a${b + `c${d}e`}f`")
    assert_equal ["/x/"], kinds("`${/x/.source}`", :regexp)
    assert_equal [[:template, "a${"], [:punct, "{"], [:name, "b"], [:punct, "}"], [:template, ""]], tokens("`a${{b}}`")
  end

  test "text that is no JavaScript raises Error" do
    ["'not closed\nx", "a = /x\ny/", "f(a", "a)", "{ a", "`a${b", "/* open", "a \u0001 b"].each do |code|
      assert_raises(JsTokens::Error, code) { JsTokens.call(code) }
    end
  end

  test "a cut text may end inside a token or with open brackets" do
    ["f('cut", "f(`cut ${a", "f(/* cut", "f(/cut", "{ a: [1, 2"].each do |code|
      JsTokens.call(code, partial: true)
    end
    assert_raises(JsTokens::Error) { JsTokens.call("f('cut\nmore", partial: true) }
  end
end
