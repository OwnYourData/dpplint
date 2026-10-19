# Retrieves the passport for a product identifier as JSON.
#
# The passport is requested with Accept: application/json. If the answer is a
# compact JWS, its payload is the passport. Otherwise the identifier is also
# requested with the JOSE media types of VC-JOSE-COSE; a JWS delivered that
# way is kept for the integrity check (DPP-SEC-002), as are the bytes of the
# JSON answer (compared with the payloadHash of the passport DID).
#
# If the time limit of the check is reached while the passport is retrieved,
# the retrieval reports that as its error. If it is reached during the JWS
# request, the passport is kept and `jws_unchecked` says why there is no JWS.
class PassportFetcher
  Result = Struct.new(:json, :info, :jws, :jws_only, :raw, :jws_unchecked, keyword_init: true)

  def initialize(resolver = HttpResolver.new)
    @resolver = resolver
  end

  def fetch(product_id)
    info = { productId: product_id, url: product_id, status: nil, contentType: nil, httpVersion: nil }
    res = @resolver.get(product_id, accept: "application/json")
    info.merge!(url: res.url, status: res.status, contentType: res.content_type, httpVersion: res.http_version)
    return Result.new(info: info.merge(error: res.error)) if res.error
    return Result.new(info: info.merge(error: "retrieval returned HTTP #{res.status}")) unless res.success?

    if (jws = jws_from(res))
      return Result.new(info: info.merge(error: "JWS payload is not a JSON object")) unless jws.payload.is_a?(Hash)

      return Result.new(json: jws.payload, jws: jws, jws_only: true, info: info.merge(securedAs: "jws"))
    end

    json = JSON.parse(res.body)
    return Result.new(info: info.merge(error: "response is not a JSON object")) unless json.is_a?(Hash)

    jws, unchecked = secured(product_id)
    Result.new(json: json, raw: res.body.to_s.b, jws: jws, jws_only: false, jws_unchecked: unchecked,
               info: jws ? info.merge(securedAs: "json and jws") : info)
  rescue JSON::ParserError
    Result.new(info: info.merge(error: "response is not JSON"))
  rescue CheckDeadline::Reached => e
    Result.new(info: info.merge(error: "not retrieved: #{e.message}"))
  end

  private

  def jws_from(res)
    return unless Jws::MEDIA_TYPES.include?(res.media_type) || res.body.to_s.lstrip.start_with?("eyJ")

    Jws.parse(res.body)
  end

  # [JWS or nil, reason why it was not requested or nil]
  def secured(product_id)
    res = @resolver.get(product_id, accept: Jws::ACCEPT)
    [res.success? ? jws_from(res) : nil, nil]
  rescue CheckDeadline::Reached => e
    [nil, "the passport was not requested as JWS: #{e.message}"]
  end
end
