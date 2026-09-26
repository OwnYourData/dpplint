# Runs a criterion with check.type resolve against a product identifier.
#
# Without `expect`, the identifier has to resolve to a single passport object
# whose uniqueProductIdentifier equals the identifier. With `expect`, its
# status and content type are checked instead; an expected JSON content type
# also requires the body to be a JSON object.
class ResolveCheck
  def initialize(check, product_id, resolver)
    @check = check
    @product_id = product_id
    @resolver = resolver
  end

  # Returns a list of violation messages; empty means passed.
  def violations
    res = @resolver.get(@product_id, accept: @check["accept"])
    return [res.error] if res.error

    @check["expect"] ? expected(res) : resolves_to_passport(res)
  end

  private

  def expected(res)
    expect = @check["expect"]
    out = []
    if expect["status"] && !expect["status"].include?(res.status)
      out << "HTTP status is #{res.status}, expected #{expect['status'].join(' or ')}"
    end
    if (type = expect["content_type"])
      if res.media_type != type.downcase
        out << "Content-Type is #{res.content_type.presence || 'missing'}, expected #{type}"
      elsif type.downcase == "application/json" && !json_object?(res.body)
        out << "response is not a single JSON object"
      end
    end
    out
  end

  def resolves_to_passport(res)
    return ["HTTP status is #{res.status}, expected 2xx"] unless res.success?

    json = JSON.parse(res.body) rescue nil
    return ["response is not a single JSON object"] unless json.is_a?(Hash)

    upi = json["uniqueProductIdentifier"]
    return [] if upi == @product_id

    ["uniqueProductIdentifier is #{upi.inspect}, expected the requested identifier #{@product_id}"]
  end

  def json_object?(body)
    JSON.parse(body).is_a?(Hash)
  rescue JSON::ParserError
    false
  end
end
