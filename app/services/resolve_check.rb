# Runs a criterion with check.type resolve against a product identifier.
#
# The first request follows the identifier with the Accept header of the
# criterion (`accept`). Without `expect`, it has to resolve to a single
# passport object whose uniqueProductIdentifier equals the identifier. With
# `expect`, its status, content type and header fields (`headers`, see
# HeaderAssertion) are checked instead; an expected JSON content type also
# requires the body to be a JSON object.
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
    expects = [@check["expect"], *Array(@check["further_requests"]).map { |r| r["expect"] }]
    expects.compact.flat_map { |e| e.keys - SUPPORTED_EXPECT }.uniq
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

  def request(accept, expect, severity: nil, label: nil)
    res = @resolver.get(@product_id, accept: accept)
    out = if res.error then [violation(res.error)]
          elsif expect then expected(res, expect)
          else resolves_to_passport(res)
          end
    out = out.map { |m| m.merge(severity: "warning") } if severity == "warning"
    label ? out.map { |m| m.merge(message: "#{label}: #{m[:message]}") } : out
  end

  def expected(res, expect)
    out = []
    if expect["status"] && !expect["status"].include?(res.status)
      out << violation("HTTP status is #{res.status}, expected #{expect['status'].join(' or ')}")
    end
    if (type = expect["content_type"])
      if res.media_type != type.downcase
        out << violation("Content-Type is #{res.content_type.presence || 'missing'}, expected #{type}")
      elsif type.downcase == "application/json" && !json_object?(res.body)
        out << violation("response is not a single JSON object")
      end
    end
    out + HeaderAssertion.messages(expect["headers"], res.headers)
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

  def json_object?(body)
    JSON.parse(body).is_a?(Hash)
  rescue JSON::ParserError
    false
  end
end
