# Evaluates the header assertions of an `expect` block (expect.headers) on the
# header fields of a response, as defined in CRITERIA-FORMAT.md of dpp-criteria:
#
# - `name` is matched case-insensitively; several fields with the same name are
#   combined into one value, separated by ", " (RFC 9110 5.3);
# - `exists`: the field is present (true) or absent (false);
# - `equals`: the combined value equals the string exactly;
# - `contains`: the combined value, split at commas and trimmed, has a member
#   equal to the string, compared case-insensitively ("Vary: *" therefore does
#   not contain "Accept");
# - `matches`: the ECMA-262 regular expression is found anywhere in the
#   combined value, case-sensitively (see EcmaRegexp); an invalid pattern
#   raises EcmaRegexp::Error, callers check patterns beforehand (problem);
# - a missing field fails every assertion except `exists: false`;
# - `severity: warning` reports a failure as a warning instead of a violation.
class HeaderAssertion
  OPERATIONS = %w[exists equals contains matches].freeze

  # assertions: the list under expect.headers; headers: Hash of field name =>
  # value or list of values. Returns messages { severity:, message: }.
  def self.messages(assertions, headers)
    Array(assertions).flat_map do |assertion|
      severity = assertion["severity"] == "warning" ? "warning" : "violation"
      new(assertion).failures(headers).map { |m| { severity: severity, message: m } }
    end
  end

  # The combined value of all fields named `name`, or nil if there is none.
  def self.field(headers, name)
    values = (headers || {}).select { |key, _| key.to_s.casecmp?(name.to_s) }.values.flatten.map(&:to_s)
    values.empty? ? nil : values.join(", ")
  end

  # The first pattern of `matches` in the assertions that dpplint cannot
  # evaluate, as a reason, or nil.
  def self.problem(assertions)
    Array(assertions).each do |assertion|
      next unless assertion.key?("matches")

      reason = EcmaRegexp.problem(assertion["matches"])
      return "regular expression #{assertion['matches'].to_s.inspect} for header #{assertion['name']} #{reason}" if reason
    end
    nil
  end

  def initialize(assertion)
    @assertion = assertion
    @name = assertion["name"].to_s
  end

  # Returns one message per operation that does not hold; empty means it holds.
  def failures(headers)
    value = self.class.field(headers, @name)
    OPERATIONS.select { |op| @assertion.key?(op) }.filter_map { |op| failure(op, @assertion[op], value) }
  end

  private

  def failure(op, expected, value)
    return exists(expected, value) if op == "exists"
    return "header #{@name} is missing, expected #{describe(op, expected)}" if value.nil?

    holds = case op
            when "equals" then value == expected.to_s
            when "contains" then value.split(",").map(&:strip).any? { |member| member.casecmp?(expected.to_s) }
            when "matches" then EcmaRegexp.search?(expected, value)
            end
    holds ? nil : "header #{@name} is #{value.inspect}, expected #{describe(op, expected)}"
  end

  def exists(expected, value)
    return nil if expected == !value.nil?

    expected ? "header #{@name} is missing" : "header #{@name} is present (#{value.inspect}), expected it to be absent"
  end

  def describe(op, expected)
    case op
    when "equals" then "exactly #{expected.to_s.inspect}"
    when "contains" then "a member #{expected.to_s.inspect}"
    when "matches" then "a value matching /#{expected}/"
    end
  end
end
