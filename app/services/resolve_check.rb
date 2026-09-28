# Runs a criterion with check.type resolve against a product identifier.
#
# The first request follows the identifier with the Accept header of the
# criterion (`accept`). Without `expect`, it has to resolve to a single
# passport object whose uniqueProductIdentifier equals the identifier. With
# `expect`, its status and content type are checked instead. The content type
# is compared as media type without parameters, case-insensitively; for a JSON
# media type (application/json or +json) the body must also be a single JSON
# object, which belongs to the content type check. Following "Order of
# evaluation within a request" in CRITERIA-FORMAT.md, the header fields
# (`headers`, see HeaderAssertion) are evaluated only if status and content
# type hold; otherwise they give no message of their own.
#
# `further_requests` are sent after the first request to the same identifier,
# each with its own `accept` and `expect`, and are evaluated independently of
# it. `severity: warning` on a further request reports every failure of that
# request as a warning.
class ResolveCheck
  # Parts of `expect` this version evaluates for check type resolve.
  SUPPORTED_EXPECT = %w[status content_type headers].freeze

  def initialize(check, product_id, resolver)
    @check = check
    @product_id = product_id
    @resolver = resolver
  end

  # Keys of an `expect` block this version does not evaluate. A criterion that
  # uses one is skipped rather than passed without that part.
  def unsupported
    expects.flat_map { |e| e.keys - SUPPORTED_EXPECT }.uniq
  end

  # A reason if a regular expression of the criterion cannot be evaluated
  # (not valid ECMA-262 or outside the portable subset), otherwise nil. Such a
  # criterion is skipped.
  def pattern_problem
    expects.lazy.map { |e| HeaderAssertion.problem(e["headers"]) }.find(&:itself)
  end

  # Returns messages { severity: "violation" | "warning", message: }; none means passed.
  def messages
    first = request(@check["accept"], @check["expect"])
    further = Array(@check["further_requests"]).flat_map do |r|
      request(r["accept"], r["expect"] || {}, severity: r["severity"], label: "request with Accept #{r['accept']}")
    end
    first + further
  end

  private

  def expects = [@check["expect"], *Array(@check["further_requests"]).map { |r| r["expect"] }].compact

  def request(accept, expect, severity: nil, label: nil)
    res = @resolver.get(@product_id, accept: accept)
    out = if res.error then [violation(res.error)]
          elsif expect then expected(res, expect)
          else resolves_to_passport(res)
          end
    out = out.map { |m| m.merge(severity: "warning") } if severity == "warning"
    label ? out.map { |m| m.merge(message: "#{label}: #{m[:message]}") } : out
  end

  # status and content type first; header fields only if both hold.
  def expected(res, expect)
    out = status_and_content_type(res, expect)
    return out if out.any?

    HeaderAssertion.messages(expect["headers"], res.headers)
  end

  def status_and_content_type(res, expect)
    out = []
    if expect["status"] && !expect["status"].include?(res.status)
      out << violation("HTTP status is #{res.status}, expected #{expect['status'].join(' or ')}")
    end
    if (type = expect["content_type"])
      expected_type = media_type(type)
      if res.media_type != expected_type
        out << violation("Content-Type is #{res.content_type.presence || 'missing'}, expected #{type}")
      elsif json_media_type?(expected_type)
        json = parse_json(res.body)
        if json == :invalid then out << violation("response is not valid JSON")
        elsif !json.is_a?(Hash) then out << violation("response is not a single JSON object")
        end
      end
    end
    out
  end

  # The media type without parameters, lower case (CRITERIA-FORMAT.md, "Order
  # of evaluation within a request").
  def media_type(value) = value.to_s.split(";").first.to_s.strip.downcase

  # application/json or a type with the structured syntax suffix +json.
  def json_media_type?(type) = type == "application/json" || type.end_with?("+json")

  def parse_json(body)
    JSON.parse(body.to_s)
  rescue JSON::ParserError
    :invalid
  end

  def resolves_to_passport(res)
    return [violation("HTTP status is #{res.status}, expected 2xx")] unless res.success?

    json = JSON.parse(res.body) rescue nil
    return [violation("response is not a single JSON object")] unless json.is_a?(Hash)

    upi = json["uniqueProductIdentifier"]
    return [] if upi == @product_id

    [violation("uniqueProductIdentifier is #{upi.inspect}, expected the requested identifier #{@product_id}")]
  end

  def violation(message) = { severity: "violation", message: message }

end
