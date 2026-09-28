# Evaluates the applies_if conditions of a criterion on the passport JSON.
# Each condition is a JSON assertion (CRITERIA-FORMAT.md): a JSONPath `path`
# and one of `exists`, `equals`, `in`, `matches`.
#
# Supported paths (RFC 9535):
#   $.<member>
#   $.<member>[?search(@, '<I-Regexp>')]
#   $.<member>[?match(@, '<I-Regexp>')]
# The string literal may be single- or double-quoted with the escapes of
# RFC 9535, 2.3.1.1. The filter selects the elements of an array (or the
# member values of an object) for which the function holds; search() and
# match() evaluate their pattern as I-Regexp (RFC 9485, see IRegexp) and are
# false for values that are not strings. The pattern is checked before the
# JSONPath is evaluated: an invalid I-Regexp or one with `^` or `$` outside a
# character class makes the criterion skipped (see problem), as
# CRITERIA-FORMAT.md requires, instead of letting the function return false.
#
# `matches` of the assertion itself is an ECMA-262 regular expression
# (see EcmaRegexp), as for all JSON assertions. It holds only for JSON
# strings; numbers, booleans, null, arrays and objects never satisfy it and
# are not converted to text.
class AppliesIf
  MEMBER = /[A-Za-z_\u0080-\u{10FFFF}][A-Za-z0-9_\u0080-\u{10FFFF}]*/
  SIMPLE = /\A\$\.(#{MEMBER})\z/
  FILTER = /\A\$\.(#{MEMBER})\[\s*\?\s*(match|search)\(\s*@\s*,\s*(.*)\s*\)\s*\]\z/m
  ESCAPES = { "b" => "\b", "f" => "\f", "n" => "\n", "r" => "\r", "t" => "\t", "/" => "/", "\\" => "\\" }.freeze

  class Unsupported < StandardError; end

  def self.holds?(conditions, passport)
    Array(conditions).all? { |c| new(c, passport).holds? }
  end

  # nil if every condition can be evaluated, otherwise the reason. A criterion
  # with such a condition is skipped.
  def self.problem(conditions)
    Array(conditions).each do |c|
      _member, function, pattern = parse_path(c["path"].to_s)
      if function && (reason = IRegexp.problem(pattern))
        return "regular expression #{pattern.inspect} of #{function}() in applies_if path #{c['path']} #{reason}"
      end
      next unless c.key?("matches")

      reason = EcmaRegexp.problem(c["matches"])
      return "regular expression #{c['matches'].to_s.inspect} in applies_if #{reason}" if reason
    end
    nil
  rescue Unsupported => e
    e.message
  end

  # [member, nil, nil] or [member, "match" | "search", pattern]
  def self.parse_path(path)
    if (m = path.match(SIMPLE))
      [m[1], nil, nil]
    elsif (m = path.match(FILTER))
      [m[1], m[2], string_literal(m[3].rstrip)]
    else
      raise Unsupported, "applies_if path #{path} is not supported in this version"
    end
  end

  # A JSONPath string literal (RFC 9535, 2.3.1.1).
  def self.string_literal(literal)
    quote = literal[0]
    unless literal.size >= 2 && %w[' "].include?(quote) && literal[-1] == quote
      raise Unsupported, "applies_if: #{literal} is not a JSONPath string literal"
    end

    chars = literal[1...-1].chars
    out = +""
    until chars.empty?
      c = chars.shift
      if c == "\\"
        out << unescape(chars, quote, literal)
      elsif c == quote || c.ord < 0x20
        raise Unsupported, "applies_if: #{literal} is not a valid JSONPath string literal"
      else
        out << c
      end
    end
    out
  end

  def self.unescape(chars, quote, literal)
    e = chars.shift
    return e if e == quote
    return ESCAPES[e] if ESCAPES.key?(e)
    raise Unsupported, "applies_if: invalid escape in JSONPath string literal #{literal}" unless e == "u"

    code = hex4(chars, literal)
    if (0xD800..0xDBFF).cover?(code)
      raise Unsupported, "applies_if: lone surrogate in #{literal}" unless chars.shift(2) == ["\\", "u"]

      low = hex4(chars, literal)
      raise Unsupported, "applies_if: lone surrogate in #{literal}" unless (0xDC00..0xDFFF).cover?(low)

      code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
    elsif (0xDC00..0xDFFF).cover?(code)
      raise Unsupported, "applies_if: lone surrogate in #{literal}"
    end
    code.chr(Encoding::UTF_8)
  end

  def self.hex4(chars, literal)
    hex = chars.shift(4).join
    raise Unsupported, "applies_if: invalid \\u escape in #{literal}" unless hex.match?(/\A\h{4}\z/)

    hex.to_i(16)
  end

  def initialize(condition, passport)
    @c = condition
    @passport = passport
  end

  def holds?
    values = select
    return !values.empty? == @c["exists"] if @c.key?("exists")
    return values.any? { |v| v == @c["equals"] } if @c.key?("equals")
    return values.any? { |v| @c["in"].include?(v) } if @c.key?("in")
    return values.any? { |v| v.is_a?(String) && EcmaRegexp.search?(@c["matches"], v) } if @c.key?("matches")

    !values.empty?
  end

  private

  def select
    member, function, pattern = self.class.parse_path(@c["path"].to_s)
    return [] unless @passport.is_a?(Hash) && @passport.key?(member)

    value = @passport[member]
    return [value] unless function

    candidates = case value
                 when Array then value
                 when Hash then value.values
                 else []
                 end
    candidates.select { |v| IRegexp.public_send("#{function}?", pattern, v) }
  end
end
