# JSON Canonicalization Scheme (RFC 8785): object members sorted by their
# UTF-16 code units, no whitespace, numbers serialised like ECMAScript.
module Jcs
  def self.dump(value)
    case value
    when Hash
      members = value.map { |k, v| [k.to_s, v] }.sort_by { |k, _| k.encode("UTF-16BE").bytes }
      "{#{members.map { |k, v| "#{string(k)}:#{dump(v)}" }.join(',')}}"
    when Array then "[#{value.map { |v| dump(v) }.join(',')}]"
    when String then string(value)
    when Integer then value.to_s
    when Float then number(value)
    when true then "true"
    when false then "false"
    when nil then "null"
    else raise ArgumentError, "cannot canonicalise #{value.class}"
    end
  end

  ESCAPES = { "\"" => "\\\"", "\\" => "\\\\", "\b" => "\\b", "\f" => "\\f", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }.freeze

  def self.string(str)
    body = str.gsub(/["\\\u0000-\u001f]/) { |c| ESCAPES[c] || format("\\u%04x", c.ord) }
    "\"#{body}\""
  end

  # ECMAScript Number::toString, built on Ruby's shortest round-trip digits.
  def self.number(float)
    raise ArgumentError, "NaN and Infinity are not valid JSON" unless float.finite?
    return "0" if float.zero?
    return "-#{number(-float)}" if float.negative?

    mantissa, exponent = float.to_s.split("e")
    int, frac = mantissa.split(".")
    all = "#{int}#{frac}"
    lead = all[/\A0*/].length
    digits = all[lead..].sub(/0+\z/, "")
    n = int.length - lead + exponent.to_i
    k = digits.length

    if k <= n && n <= 21 then digits + ("0" * (n - k))
    elsif n.positive? && n <= 21 then "#{digits[0, n]}.#{digits[n..]}"
    elsif n > -6 && n <= 0 then "0.#{'0' * -n}#{digits}"
    else
      e = n - 1
      "#{digits[0]}#{k > 1 ? ".#{digits[1..]}" : ''}e#{e.negative? ? '-' : '+'}#{e.abs}"
    end
  end
end
