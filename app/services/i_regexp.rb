# I-Regexp (RFC 9485), the regular expressions of the JSONPath functions
# match() and search() (RFC 9535, sections 2.4.6 and 2.4.7), as CRITERIA-FORMAT.md
# of dpp-criteria requires for regular expressions inside a JSONPath expression.
#
# The pattern is parsed with the ABNF of RFC 9485, section 3, and translated
# into an equivalent Ruby Regexp. CRITERIA-FORMAT.md does not allow `^` or `$`
# outside a character class (RFC 9485 lists them as ordinary characters, its
# mappings in section 5 and the JSONPath Compliance Test Suite treat them as
# anchors): such a pattern is unusable (Anchored), like an invalid one
# (Invalid). An escaped `\^` is a literal ^ (dpp-criteria issue #7); `\$` is
# not valid I-Regexp (use `[$]`). Differences to Ruby and ECMA-262 that
# matter: `.` matches any character except LF and CR; only the escapes \( \) \*
# \+ \- \. \? \[ \\ \] \n \r \t \{ \| \} and the category escapes \p{..} and \P{..} exist (no \d,
# \w, \s); there are no lazy quantifiers, no {,m} and no non-capturing or other
# special groups. Matching works on code points and is case-sensitive.
#
# match() holds if the entire value matches, search() if a substring does;
# both are false if the value is not a string. Callers check patterns with
# `problem` before evaluating the JSONPath: an unusable pattern makes the
# criterion skipped ("Results"). match?/search? return false for one, as a
# safeguard only.
class IRegexp
  class Unusable < StandardError; end
  class Invalid < Unusable; end
  class Anchored < Unusable; end

  CATEGORIES = %w[L Ll Lm Lo Lt Lu M Mc Me Mn N Nd Nl No P Pc Pd Pe Pf Pi Po Ps Z Zl Zp Zs S Sc Sk Sm So C Cc Cf Cn Co].freeze
  SINGLE_ESCAPES = { "n" => 0x0A, "r" => 0x0D, "t" => 0x09 }.freeze
  SINGLE_ESCAPABLE = ["(", ")", "*", "+", "-", ".", "?", "[", "\\", "]", "^", "{", "|", "}"].freeze
  # Characters that are not NormalChar (RFC 9485): ( ) * + . ? [ \ ] { | }
  SPECIAL = ["(", ")", "*", "+", ".", "?", "[", "\\", "]", "{", "|", "}"].freeze
  RANGE_QUANTIFIER = /\A\{(\d+)(?:(,)(\d*))?\}/

  # match(): the entire value matches the pattern.
  def self.match?(pattern, value)
    return false unless value.is_a?(String)

    Regexp.new("\\A(?:#{translate(pattern)})\\z").match?(value)
  rescue Unusable
    false
  end

  # search(): a substring of the value matches the pattern.
  def self.search?(pattern, value)
    return false unless value.is_a?(String)

    Regexp.new(translate(pattern)).match?(value)
  rescue Unusable
    false
  end

  # nil for a usable pattern, otherwise the reason.
  def self.problem(pattern)
    translate(pattern)
    nil
  rescue Invalid => e
    "is not a valid I-Regexp (RFC 9485): #{e.message}"
  rescue Anchored => e
    "contains #{e.message} outside a character class, which CRITERIA-FORMAT.md does not allow in JSONPath (use match() for a whole-value match)"
  end

  def self.translate(pattern)
    raise Invalid, "not a string" unless pattern.is_a?(String)

    source = new(pattern).translate
    Regexp.new(source)
    source
  rescue RegexpError => e
    raise Invalid, e.message
  end

  def initialize(pattern)
    @src = pattern.chars
    @pos = 0
    @out = +""
  end

  def translate
    regexp
    raise Invalid, "unmatched )" unless eof?

    @out
  end

  private

  def peek(offset = 0) = @src[@pos + offset]
  def take = (@pos += 1; @src[@pos - 1])
  def eof? = @pos >= @src.size
  def rest = @src[@pos..].join

  def regexp
    branch
    while peek == "|"
      take
      @out << "|"
      branch
    end
  end

  def branch
    piece until eof? || peek == "|" || peek == ")"
  end

  def piece
    start = @out.size
    atom
    return unless quantifier?

    @out.insert(start, "(?:") << ")"
    quantifier
    raise Invalid, "quantifier without an atom at #{peek}" if quantifier?
  end

  def atom
    c = take
    case c
    when "(" then group
    when "." then @out << "[^\\n\\r]"
    when "[" then char_class
    when "^", "$" then raise Anchored, c
    when "\\" then @out << escape_outside
    else
      raise Invalid, "#{c} is not allowed here" if SPECIAL.include?(c)

      @out << char(c.ord)
    end
  end

  def group
    @out << "(?:"
    regexp
    raise Invalid, "missing )" unless take == ")"

    @out << ")"
  end

  def quantifier? = %w[* + ?].include?(peek) || (peek == "{" && rest.match?(RANGE_QUANTIFIER))

  def quantifier
    if %w[* + ?].include?(peek)
      @out << take
      return
    end
    m = rest.match(RANGE_QUANTIFIER)
    @pos += m[0].size
    min = m[1].to_i
    max = m[3].to_s.empty? ? nil : m[3].to_i
    raise Invalid, "quantifier {#{min},#{max}} with maximum below minimum" if max && max < min

    @out << (m[2] ? "{#{min},#{max}}" : "{#{min}}")
  end

  def escape_outside
    raise Invalid, "\\ at end of pattern" if eof?

    c = take
    return category(c) if %w[p P].include?(c)

    char(single_escape(c))
  end

  def single_escape(c)
    return SINGLE_ESCAPES[c] if SINGLE_ESCAPES.key?(c)
    return c.ord if SINGLE_ESCAPABLE.include?(c)

    raise Invalid, "\\#{c} is not an I-Regexp escape"
  end

  def category(c)
    raise Invalid, "\\#{c} must be followed by {" unless take == "{"

    name = +""
    name << take until eof? || peek == "}"
    raise Invalid, "missing } after \\#{c}{#{name}" unless take == "}"
    raise Invalid, "unknown category #{name}" unless CATEGORIES.include?(name)

    "\\#{c}{#{name}}"
  end

  # charClassExpr = "[" [ "^" ] ( "-" / CCE1 ) *CCE1 [ "-" ] "]"
  def char_class
    negate = peek == "^"
    take if negate
    items = +""
    first = true
    loop do
      raise Invalid, "missing ]" if eof?

      if peek == "]"
        raise Invalid, "empty character class" if first

        take
        break
      end
      if peek == "-"
        raise Invalid, "- inside a character class must be escaped" unless first || peek(1) == "]"

        take
        items << char("-".ord)
      else
        items << class_element
      end
      first = false
    end
    @out << "[#{'^' if negate}#{items}]"
  end

  # CCE1 = ( CCchar [ "-" CCchar ] ) / charClassEsc
  def class_element
    if peek == "\\" && %w[p P].include?(peek(1))
      @pos += 2
      return category(@src[@pos - 1])
    end
    from = class_char
    return char(from) unless peek == "-" && peek(1) != "]"

    take
    to = class_char
    raise Invalid, "range out of order in character class" if to < from

    "#{char(from)}-#{char(to)}"
  end

  # CCchar: any character except - [ \ ], or a SingleCharEsc
  def class_char
    raise Invalid, "missing ]" if eof?

    c = take
    if c == "\\"
      raise Invalid, "\\ at end of pattern" if eof?

      return single_escape(take)
    end
    raise Invalid, "#{c} inside a character class must be escaped" if ["-", "[", "]"].include?(c)

    c.ord
  end

  def char(code) = format("\\u{%X}", code)
end
