require "net/http"

# Client for didlint (https://github.com/OwnYourData/didlint), which resolves a
# DID and checks its DID document against DID Core.
class Didlint
  class Unavailable < StandardError; end

  def initialize(base = Rails.configuration.x.dpplint.didlint)
    @base = base.chomp("/")
    @cache = {}
  end

  # {"valid" => true} or {"valid" => false, "error" => ..., "errors" => [...]}
  # Raises Unavailable if didlint cannot be reached.
  def validate(did) = get("api/validate/#{did}")

  # The DID document, or nil if the DID cannot be resolved.
  def resolve(did)
    resolve!(did)
  rescue Unavailable
    nil
  end

  # Like resolve, but raises Unavailable if didlint cannot be reached.
  def resolve!(did)
    doc = get("api/resolve/#{did}")
    doc.is_a?(Hash) && doc["id"] ? doc : nil
  end

  private

  # Answers are cached per instance (one instance per validation).
  def get(path)
    @cache[path] ||= begin
      fetch(path)
    rescue Unavailable => e
      e
    end
    raise @cache[path] if @cache[path].is_a?(Unavailable)

    @cache[path]
  end

  def fetch(path)
    uri = URI("#{@base}/#{path}")
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 60) do |http|
      http.request(Net::HTTP::Get.new(uri, "Accept" => "application/json"))
    end
    raise Unavailable, "didlint answered HTTP #{res.code}" if res.code.to_i >= 500

    JSON.parse(res.body)
  rescue Unavailable
    raise
  rescue StandardError => e
    raise Unavailable, "didlint not reachable (#{e.message})"
  end
end
