require "net/http"

# Plain HTTP(S) GET like a phone scanning a data carrier: no credentials,
# redirects followed, optional Accept header. Responses are cached per run.
class HttpResolver
  Response = Struct.new(:url, :status, :content_type, :body, :error, keyword_init: true) do
    def media_type = content_type.to_s.split(";").first.to_s.strip.downcase
    def success? = error.nil? && status.between?(200, 299)
  end

  MAX_REDIRECTS = 5

  def initialize
    @cache = {}
  end

  def get(url, accept: nil)
    @cache[[url, accept]] ||= fetch(url, accept)
  end

  private

  def fetch(url, accept)
    uri = URI.parse(url)
    return Response.new(url: url, error: "not an HTTP(S) URL") unless uri.is_a?(URI::HTTP)

    MAX_REDIRECTS.times do
      res = request(uri, accept)
      if res.is_a?(Net::HTTPRedirection) && res["location"]
        uri += res["location"]
        next
      end
      return Response.new(url: uri.to_s, status: res.code.to_i, content_type: res["content-type"], body: res.body)
    end
    Response.new(url: uri.to_s, error: "more than #{MAX_REDIRECTS} redirects")
  rescue URI::InvalidURIError
    Response.new(url: url, error: "not a valid URL")
  rescue StandardError => e
    Response.new(url: uri.to_s, error: "retrieval failed: #{e.message}")
  end

  def request(uri, accept)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 20) do |http|
      headers = accept ? { "Accept" => accept } : {}
      http.request(Net::HTTP::Get.new(uri, headers))
    end
  end
end
