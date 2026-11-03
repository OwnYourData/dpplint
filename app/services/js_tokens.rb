require "strscan"

# Splits JavaScript source text into tokens, as far as needed to tell code
# from comments, string literals, template literals and regular expression
# literals. It does not parse: whether a "/" starts a regular expression is
# decided from the token before it, as JavaScript tokenizers commonly do
# (after ")" only if the parentheses close the head of if, while, for or
# with).
#
# Tokens are Token(type, value) with type :name (identifiers and keywords),
# :private (#name), :number, :string (value: the characters between the
# quotes, escapes as written), :template (one literal part of a template
# literal), :regexp and :punct. Comments are dropped.
#
# Error is raised for text that cannot be read as JavaScript this way, for
# example a string literal that runs into a line break or brackets that do
# not match; the caller then must not rely on the tokens. With partial: true
# (a script cut after a number of bytes) the end of the text may cut a token
# and leave brackets open.
class JsTokens
  class Error < StandardError; end

  Token = Struct.new(:type, :value)

  PUNCTUATORS = %w[>>>= ... === !== **= <<= >>= >>> &&= ||= ??= => == != <= >= && || ?? ?. ++ -- += -= *= %= &= |= ^=
                   << >> ** { } ( ) [ ] ; , < > + - * % & | ^ ! ~ ? : = . @].freeze
  PUNCTUATOR = Regexp.union(PUNCTUATORS.sort_by { |p| -p.length })
  ID_START = '(?:[\p{L}\p{Nl}$_]|\\\\u\h{4}|\\\\u\{\h+\})'.freeze
  ID_PART = '(?:[\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}$\u200C\u200D]|\\\\u\h{4}|\\\\u\{\h+\})'.freeze
  NAME = /#{ID_START}#{ID_PART}*/
  PRIVATE = /\##{ID_START}#{ID_PART}*/
  NUMBER = /0[xX][\h_]+n?|0[oO][0-7_]+n?|0[bB][01_]+n?|(?:\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?\d[\d_]*)?n?/
  SPACE = /[\p{Zs}\t\v\f\uFEFF]+/
  LINE_BREAK = /\r\n|[\n\r\u2028\u2029]/
  LINE_COMMENT = %r{(?://|<!--)[^\n\r\u2028\u2029]*}
  CLOSE_COMMENT = /-->[^\n\r\u2028\u2029]*/
  BLOCK_COMMENT = %r{/\*.*?\*/}m
  STRING = { "'" => /'((?>[^'\\\n\r]+|\\(?:\r\n|[\s\S]))*)'/, '"' => /"((?>[^"\\\n\r]+|\\(?:\r\n|[\s\S]))*)"/ }.freeze
  TEMPLATE_PART = /(?>[^`\\$]+|\\[\s\S]|\$(?!\{))*/
  REGEXP = %r{/(?>[^/\\\[\n\r\u2028\u2029]+|\\[^\n\r\u2028\u2029]|\[(?>[^\]\\\n\r\u2028\u2029]+|\\[^\n\r\u2028\u2029])*\])+/#{ID_PART}*}
  # After these keywords an expression starts, so "/" begins a regular expression.
  BEFORE_EXPRESSION = %w[return typeof instanceof in of new delete void throw case do else yield await extends].freeze
  CONTROL = %w[if while for with].freeze

  def self.call(source, partial: false) = new(source, partial: partial).tokens

  def initialize(source, partial: false)
    @s = StringScanner.new(source.to_s)
    @partial = partial
    @tokens = []
    @braces = []   # :block or :template for each open "{" or "${"
    @parens = []   # for each open "(": whether it opens the head of if/while/for/with
    @after_control = false
    @line_start = true
  end

  def tokens
    read until @s.eos?
    raise Error, "brackets not closed at the end" unless @partial || (@braces.empty? && @parens.empty?)

    @tokens
  end

  private

  # One token, comment or run of white space, chosen by its first byte.
  def read
    case @s.string.getbyte(@s.pos)
    when 0x0A, 0x0D then line_break
    when 0x09, 0x0B, 0x0C, 0x20 then @s.skip(SPACE)
    when 0x2F then slash
    when 0x22, 0x27 then string(@s.peek(1))
    when 0x60 then @s.getch && template
    when 0x30..0x39 then add(:number, @s.scan(NUMBER))
    when 0x2E then @s.check(/\.\d/) ? add(:number, @s.scan(NUMBER)) : punct(@s.scan(PUNCTUATOR))
    when 0x3F then @s.check(/\?\.\d/) ? @s.getch && add(:punct, "?") : punct(@s.scan(PUNCTUATOR))
    when 0x3C then @s.skip(LINE_COMMENT) || punct(@s.scan(PUNCTUATOR))
    when 0x2D then (@line_start && @s.skip(CLOSE_COMMENT)) || punct(@s.scan(PUNCTUATOR))
    when 0x23 then hash
    when 0x41..0x5A, 0x61..0x7A, 0x24, 0x5F, 0x5C then name
    when 0x80..0xFF then other
    else (p = @s.scan(PUNCTUATOR)) ? punct(p) : unexpected
    end
  end

  def line_break
    @s.skip(LINE_BREAK)
    @line_start = true
  end

  def slash
    return if @s.skip(BLOCK_COMMENT) || @s.skip(LINE_COMMENT)
    return unterminated("comment", anywhere: true) if @s.check(%r{/\*})

    regexp_allowed? ? regexp : add(:punct, @s.scan(%r{/=?}))
  end

  def hash
    return if @s.pos.zero? && @s.skip(/#![^\n\r\u2028\u2029]*/)

    (n = @s.scan(PRIVATE)) ? add(:private, n) : unexpected
  end

  def name
    (n = @s.scan(NAME)) ? add(:name, n) : unexpected
  end

  # A character outside ASCII: a line break, white space or part of a name.
  def other
    return line_break if @s.check(LINE_BREAK)
    return if @s.skip(SPACE)

    name
  end

  # In a cut text, the cut may also split an escape in a name or a character
  # (replaced by U+FFFD).
  def unexpected
    return @s.terminate if @partial && @s.rest.match?(/\A(?:[\\#]|\\u\h{0,3}|\\u\{\h*|\uFFFD)\z/)

    raise Error, "unexpected character #{@s.check(/./m).inspect} at #{@s.pos}"
  end

  def add(type, value)
    @tokens << Token.new(type, value)
    @after_control = false
    @line_start = false
  end

  def punct(p)
    case p
    when "(" then @parens << CONTROL.include?(last_name)
    when ")" then return close_paren
    when "{" then @braces << :block
    when "}" then return close_brace
    end
    add(:punct, p)
  end

  def close_paren
    raise Error, "unmatched ) at #{@s.pos}" if @parens.empty?

    control = @parens.pop
    add(:punct, ")")
    @after_control = control
  end

  def close_brace
    raise Error, "unmatched } at #{@s.pos}" if @braces.empty?

    if @braces.pop == :template
      template
    else
      add(:punct, "}")
    end
  end

  def last_name
    t = @tokens.last
    t.value if t&.type == :name
  end

  def regexp_allowed?
    t = @tokens.last
    return true if t.nil?

    case t.type
    when :name then BEFORE_EXPRESSION.include?(t.value)
    when :punct
      case t.value
      when ")" then @after_control
      when "]", "++", "--" then false
      else true
      end
    when :template then t.equal?(@substitution)
    else false
    end
  end

  def regexp
    r = @s.scan(REGEXP)
    return add(:regexp, r) if r

    unterminated("regular expression")
  end

  def string(quote)
    return add(:string, @s[1]) if @s.scan(STRING[quote])

    unterminated("string")
  end

  # The literal part of a template literal up to "`" or "${"; the part after
  # a substitution starts after its closing "}".
  def template
    part = @s.scan(TEMPLATE_PART)
    if @s.scan(/`/)
      add(:template, part)
    elsif @s.scan(/\$\{/)
      @braces << :template
      add(:template, "#{part}${")
      @substitution = @tokens.last
    else
      unterminated("template literal")
    end
  end

  # A literal or comment without its end: at the end of a cut script that is
  # expected, otherwise the text is not read as JavaScript. A string or
  # regular expression literal must not contain a line break, so one that
  # stops at a line break is not cut but misread.
  def unterminated(what, anywhere: false)
    raise Error, "#{what} not closed at #{@s.pos}" unless @partial && (anywhere || !@s.rest.match?(LINE_BREAK))

    @s.terminate
  end
end
