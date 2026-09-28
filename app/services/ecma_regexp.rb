# Regular expressions as CRITERIA-FORMAT.md of dpp-criteria defines them for
# `matches` in JSON and header assertions, including applies_if ("Regular
# expressions"): ECMA-262 syntax without flags, searched
# anywhere in the value (no implicit anchoring), case-sensitive.
#
# Ruby's own Regexp differs from ECMA-262 in ways that change results, above
# all: `^` and `$` are line anchors in Ruby but anchor the whole value in
# ECMA-262 without the m flag; `.` also matches U+2028/U+2029 in Ruby; `\s`
# and `\b` are defined differently; `[a&&b]`, `[[a]`, `a*+` and `a{,2}` mean
# something else or nothing in ECMA-262. The pattern is therefore parsed as
# ECMA-262 (including the Annex B rules that apply without flags, e.g. `\A`
# is the letter A and a lone `{` is a literal) and translated into an
# equivalent Ruby Regexp.
#
# Patterns that are not valid ECMA-262 raise Invalid. Valid patterns that use
# features outside the portable subset of CRITERIA-FORMAT.md, which dpplint
# does not evaluate (lookaround, named groups, backreferences, legacy octal
# escapes, \k, lone surrogates), raise Unsupported. Characters outside the
# Basic Multilingual Plane count as one character here, as two UTF-16 code
# units in ECMA-262; CRITERIA-FORMAT.md leaves results that depend on this
# undefined. Regular expressions inside JSONPath (match(), search()) are
# I-Regexp, see IRegexp.
class EcmaRegexp
  class Error < StandardError; end
  class Invalid < Error; end
  class Unsupported < Error; end

  LINE_TERMINATORS = "\\n\\r\\u2028\\u2029".freeze
  WHITESPACE = "\\t\\n\\v\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff".freeze
  CLASS_ESCAPES = { "d" => "0-9", "w" => "A-Za-z0-9_", "s" => WHITESPACE }.freeze
  CONTROL_ESCAPES = { "f" => 0x0C, "n" => 0x0A, "r" => 0x0D, "t" => 0x09, "v" => 0x0B }.freeze
  WORD = "[A-Za-z0-9_]".freeze
  BOUNDARY = "(?:(?<=#{WORD})(?!#{WORD})|(?<!#{WORD})(?=#{WORD}))".freeze
  NON_BOUNDARY = "(?:(?<=#{WORD})(?=#{WORD})|(?<!#{WORD})(?!#{WORD}))".freeze
  BRACED = /\A\{(\d+)(?:(,)(\d*))?\}/
  HEX = /\A\h+\z/

  # The Ruby Regexp equivalent to the ECMA-262 pattern.
  def self.compile(pattern)
    Regexp.new(new(pattern.to_s).translate)
  rescue RegexpError => e
    raise Unsupported, e.message
  end

  # Whether the pattern is found anywhere in the value.
  def self.search?(pattern, value)
    compile(pattern).match?(utf8(value))
  end

  # nil for a pattern dpplint can evaluate, otherwise a reason.
  def self.problem(pattern)
    compile(pattern)
    nil
  rescue Invalid => e
    "is not a valid ECMA-262 regular expression (#{e.message})"
  rescue Unsupported => e
    "uses a feature outside the portable subset of CRITERIA-FORMAT.md that dpplint does not evaluate (#{e.message})"
  end

  def self.utf8(value)
    s = value.to_s.dup.force_encoding(Encoding::UTF_8)
    s.valid_encoding? ? s : s.scrub
  end

  def initialize(pattern)
    @src = pattern.chars
    @pos = 0
    @out = +""
  end

  def translate
    disjunction(0)
    @out
  end

  private

  def peek(offset = 0) = @src[@pos + offset]
  def rest = @src[@pos..].join
  def take = (@pos += 1; @src[@pos - 1])
  def eof? = @pos >= @src.size

  def disjunction(depth)
    loop do
      alternative
      break if eof?

      case peek
      when "|" then take; @out << "|"
      when ")"
        raise Invalid, "unmatched )" if depth.zero?

        break
      end
    end
  end

  def alternative
    term until eof? || peek == "|" || peek == ")"
  end

  def term
    start = @out.size
    kind = atom
    quantifier(start, kind)
  end

  # Emits one atom or assertion; returns :atom or :assertion.
  def atom
    c = take
    case c
    when "^" then @out << "\\A"; :assertion
    when "$" then @out << "\\z"; :assertion
    when "\\" then escape
    when "(" then group; :atom
    when "[" then char_class; :atom
    when "." then @out << "[^#{LINE_TERMINATORS}]"; :atom
    when "*", "+", "?" then raise Invalid, "nothing to repeat before #{c}"
    when "{"
      @pos -= 1
      raise Invalid, "nothing to repeat before {" if rest.match?(BRACED)

      take
      literal(c)
    else literal(c)
    end
  end

  def literal(c)
    @out << char(c.ord)
    :atom
  end

  def quantifier(start, kind)
    q = quantifier_at
    return unless q
    raise Invalid, "nothing to repeat after an assertion" if kind == :assertion

    @out.insert(start, "(?:") << ")"
    @pos += q[:length]
    lazy = peek == "?"
    take if lazy
    @out << q[:ruby]
    @out << "?" if lazy && !q[:exact]
    raise Invalid, "nothing to repeat before #{peek}" if quantifier_at
  end

  def quantifier_at
    case peek
    when "*", "+", "?" then { length: 1, ruby: peek, exact: false }
    when "{"
      m = rest.match(BRACED)
      return unless m

      min = m[1].to_i
      max = m[3].to_s.empty? ? nil : m[3].to_i
      raise Invalid, "numbers out of order in {} quantifier" if max && max < min

      ruby = m[2] ? "{#{min},#{max}}" : "{#{min}}"
      { length: m[0].size, ruby: ruby, exact: m[2].nil? }
    end
  end

  def group
    if peek == "?"
      take
      nxt = take
      case nxt
      when ":" then @out << "(?:"
      when "=", "!" then raise Unsupported, "lookahead"
      when "<"
        raise Unsupported, "lookbehind" if %w[= !].include?(peek)

        raise Unsupported, "named groups"
      else raise Invalid, "invalid group (?#{nxt}"
      end
    else
      @out << "("
    end
    disjunction(1)
    raise Invalid, "missing )" unless take == ")"

    @out << ")"
  end

  # Escape outside a character class; returns :atom or :assertion.
  def escape
    raise Invalid, "\\ at end of pattern" if eof?

    c = take
    case c
    when "b" then @out << BOUNDARY; :assertion
    when "B" then @out << NON_BOUNDARY; :assertion
    when "d", "w", "s" then @out << "[#{CLASS_ESCAPES[c]}]"; :atom
    when "D", "W", "S" then @out << "[^#{CLASS_ESCAPES[c.downcase]}]"; :atom
    else
      code = escaped_code(c, in_class: false)
      @out << (code.nil? ? char("\\".ord) : char(code))
      :atom
    end
  end

  # Code point of a character escape (the character after the backslash is
  # already taken). nil means Annex B `\c` without a control letter: a literal
  # backslash, the c is read again as a literal.
  def escaped_code(c, in_class:)
    return CONTROL_ESCAPES[c] if CONTROL_ESCAPES.key?(c)

    case c
    when "c"
      if peek&.match?(/[A-Za-z]/) || (in_class && peek&.match?(/[0-9_]/))
        take.ord % 32
      else
        @pos -= 1
        nil
      end
    when "0"
      raise Unsupported, "legacy octal escape" if peek&.match?(/[0-9]/)

      0
    when "1".."9" then raise Unsupported, in_class ? "legacy octal escape" : "backreference or legacy octal escape"
    when "k" then raise Unsupported, "\\k"
    when "x" then hex_escape(2) || "x".ord
    when "u" then unicode_escape || "u".ord
    else c.ord
    end
  end

  def hex_escape(digits)
    s = @src[@pos, digits]&.join
    return unless s && s.size == digits && s.match?(HEX)

    @pos += digits
    s.to_i(16)
  end

  def unicode_escape
    code = hex_escape(4)
    return unless code
    return code unless (0xD800..0xDFFF).cover?(code)

    if code <= 0xDBFF && peek == "\\" && peek(1) == "u"
      @pos += 2
      low = hex_escape(4)
      return 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00) if low && (0xDC00..0xDFFF).cover?(low)
    end
    raise Unsupported, "lone surrogate"
  end

  def char_class
    negate = peek == "^"
    take if negate
    if peek == "]"
      take
      @out << (negate ? "(?m:.)" : "(?!)")
      return
    end
    items = +""
    until peek == "]"
      raise Invalid, "missing ]" if eof?

      items << class_range
    end
    take
    @out << "[#{'^' if negate}#{items}]"
  end

  def class_range
    from = class_atom
    return fragment(from) unless peek == "-" && peek(1) && peek(1) != "]"

    take
    to = class_atom
    return fragment(from) + char("-".ord) + fragment(to) if from.is_a?(String) || to.is_a?(String)
    raise Invalid, "range out of order in character class" if to < from

    "#{char(from)}-#{char(to)}"
  end

  # Integer code point, or String for a class escape such as \d.
  def class_atom
    raise Invalid, "missing ]" if eof?

    c = take
    return c.ord unless c == "\\"
    raise Invalid, "\\ at end of pattern" if eof?

    e = take
    case e
    when "b" then 0x08
    when "d", "w", "s" then CLASS_ESCAPES[e]
    when "D", "W", "S" then "[^#{CLASS_ESCAPES[e.downcase]}]"
    else escaped_code(e, in_class: true) || "\\".ord
    end
  end

  def fragment(item) = item.is_a?(String) ? item : char(item)

  def char(code) = format("\\u{%X}", code)
end
