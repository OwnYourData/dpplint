# Retrieves the passport for a product identifier as JSON.
class PassportFetcher
  Result = Struct.new(:json, :info, keyword_init: true)

  def initialize(resolver = HttpResolver.new)
    @resolver = resolver
  end

  def fetch(product_id)
    res = @resolver.get(product_id, accept: "application/json")
    info = { productId: product_id, url: res.url, status: res.status, contentType: res.content_type }
    return Result.new(info: info.merge(error: res.error)) if res.error
    return Result.new(info: info.merge(error: "retrieval returned HTTP #{res.status}")) unless res.success?

    json = JSON.parse(res.body)
    return Result.new(info: info.merge(error: "response is not a JSON object")) unless json.is_a?(Hash)

    Result.new(json: json, info: info)
  rescue JSON::ParserError
    Result.new(info: info.merge(error: "response is not JSON"))
  end
end
