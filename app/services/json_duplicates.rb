require "strscan"

# Finds member names that occur more than once in one JSON object, in JSON
# text as it was delivered. JSON parsers keep only one of the values of such a
# name, so the repetition cannot be seen in the parsed passport.
#
#   JsonDuplicates.find('{"a":1,"b":{"c":1,"c":2}}')
#   # => [{ path: "$['b']", name: "c", count: 2 }]
#
# Names are compared after their escapes are resolved ("a" and "a" are
# the same name). Paths are normalized JSONPaths (RFC 9535 2.7). Raises
# JsonDuplicates::Invalid if the text is not a single JSON value or nests
# deeper than MAX_DEPTH.
class JsonDuplicates
  class Invalid < StandardError; end

  MAX_DEPTH = 512
  WS = /[ \t\n\r]*/
  STRING = /"(?:[^"\\\u0000-\u001f]|\\(?:["\\\/bfnrt]|u\h{4}))*"/
  NUMBER = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/
  LITERAL = /true|false|null/

  def self.find(text)
    new(text).find
  end

  def initialize(text)
    source = text.to_s.dup.force_encoding(Encoding::UTF_8)
    raise Invalid, "the text is not valid UTF-8" unless source.valid_encoding?

    @s = StringScanner.new(source.delete_prefix("﻿"))
    @found = []
  end

  def find
    @s.skip(WS)
    value("$", 0)
    @s.skip(WS)
    raise Invalid, "unexpected text after the JSON value at character #{@s.charpos}" unless @s.eos?

    @found
  end

  private

  def value(path, depth)
    raise Invalid, "nested deeper than #{MAX_DEPTH} levels" if depth > MAX_DEPTH

    if @s.skip(/\{/) then object(path, depth)
    elsif @s.skip(/\[/) then array(path, depth)
    elsif @s.scan(STRING) || @s.scan(NUMBER) || @s.scan(LITERAL) then nil
    else raise Invalid, "unexpected character at #{@s.charpos}"
    end
  end

  def object(path, depth)
    counts = Hash.new(0)
    @s.skip(WS)
    unless @s.skip(/\}/)
      loop do
        @s.skip(WS)
        token = @s.scan(STRING) or raise Invalid, "member name expected at character #{@s.charpos}"
        name = JSON.parse(token)
        counts[name] += 1
        @s.skip(WS)
        @s.skip(/:/) or raise Invalid, "':' expected at character #{@s.charpos}"
        @s.skip(WS)
        value("#{path}[#{self.class.quote(name)}]", depth + 1)
        @s.skip(WS)
        next if @s.skip(/,/)
        break if @s.skip(/\}/)

        raise Invalid, "',' or '}' expected at character #{@s.charpos}"
      end
    end
    counts.each { |name, count| @found << { path: path, name: name, count: count } if count > 1 }
  end

  def array(path, depth)
    @s.skip(WS)
    return if @s.skip(/\]/)

    index = 0
    loop do
      @s.skip(WS)
      value("#{path}[#{index}]", depth + 1)
      index += 1
      @s.skip(WS)
      next if @s.skip(/,/)
      break if @s.skip(/\]/)

      raise Invalid, "',' or ']' expected at character #{@s.charpos}"
    end
  end

  SHORT_ESCAPES = { "\b" => "\\b", "\f" => "\\f", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }.freeze

  # A member name in single quotes, escaped as a normalized path requires
  # (RFC 9535 2.7).
  def self.quote(name)
    escaped = name.gsub(/[\\']/) { |c| "\\#{c}" }
                  .gsub(/[\u0000-\u001f]/) { |c| SHORT_ESCAPES[c] || format("\\u%04x", c.ord) }
    "'#{escaped}'"
  end
end
