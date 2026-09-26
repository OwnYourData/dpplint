require "net/http"

# Retrieves a passport through its product identifier like a phone scanning a
# data carrier: plain HTTPS GET without credentials, following redirects.
class PassportFetcher
  class Error < StandardError; end

  Result = Struct.new(:product_id, :url, :status, :content_type, :json, keyword_init: true) do
    def to_h = { productId: product_id, url: url, status: status, contentType: content_type }
  end

  MAX_REDIRECTS = 5

  def fetch(product_id)
    uri = parse(product_id)
    MAX_REDIRECTS.times do
      res = request(uri)
      if res.is_a?(Net::HTTPRedirection) && res["location"]
        uri = uri + res["location"]
        next
      end
      json = parse_json(res)
      return Result.new(product_id: product_id, url: uri.to_s, status: res.code.to_i,
                        content_type: res["content-type"], json: json)
    end
    raise Error, "more than #{MAX_REDIRECTS} redirects"
  end

  private

  def parse(product_id)
    uri = URI.parse(product_id)
    raise Error, "product identifier is not an HTTP(S) URL" unless uri.is_a?(URI::HTTP)

    uri
  rescue URI::InvalidURIError
    raise Error, "product identifier is not a valid URL"
  end

  def request(uri)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 20) do |http|
      http.request(Net::HTTP::Get.new(uri, "Accept" => "application/json"))
    end
  rescue StandardError => e
    raise Error, "retrieval failed: #{e.message}"
  end

  def parse_json(res)
    raise Error, "retrieval returned HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    json = JSON.parse(res.body)
    raise Error, "response is not a JSON object" unless json.is_a?(Hash)

    json
  rescue JSON::ParserError
    raise Error, "response is not JSON"
  end
end
