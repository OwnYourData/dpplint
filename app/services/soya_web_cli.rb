require "net/http"

# Client for the SOyA web-cli running inside the same image. It validates
# against the structures built into the image and does not contact the SOyA
# repository at soya.ownyourdata.eu.
class SoyaWebCli
  class Error < StandardError; end

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 30

  def initialize(base = Rails.configuration.x.dpplint.soya_web_cli, read_timeout: READ_TIMEOUT)
    @base = base.chomp("/")
    @read_timeout = read_timeout
  end

  def acquire(structure, passport) = post("acquire/#{structure}", passport)

  def validate(structure, instance) = post("validate/#{structure}", instance)

  def version
    uri = URI("#{@base}/api/v1/version")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = OPEN_TIMEOUT
    http.max_retries = 0
    res = http.start { http.get(uri.request_uri) }
    res.is_a?(Net::HTTPSuccess) && res["Content-Type"].to_s.match?(/json/i) ? JSON.parse(res.body)["version"] : nil
  rescue StandardError
    nil
  end

  private

  def post(path, body)
    uri = URI("#{@base}/api/v1/#{path}")
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: OPEN_TIMEOUT, read_timeout: @read_timeout) do |http|
      http.post(uri.request_uri, body.to_json, "Content-Type" => "application/json", "Accept" => "application/json")
    end
    parse(path, res)
  rescue Error
    raise
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, "SOyA web-cli did not answer #{path} within #{@read_timeout} s"
  rescue StandardError => e
    raise Error, "SOyA web-cli not reachable for #{path} (#{e.message})"
  end

  # The answer is checked before it is parsed, so that an error page is
  # reported as such and not as a JSON syntax error.
  def parse(path, res)
    type = res["Content-Type"].to_s
    raise Error, "SOyA web-cli answered #{path} with HTTP #{res.code}: #{res.body.to_s[0, 200]}" unless res.is_a?(Net::HTTPSuccess)
    raise Error, "SOyA web-cli answered #{path} with #{type.presence || 'no content type'} instead of JSON" unless type.match?(/json/i)

    JSON.parse(res.body)
  rescue JSON::ParserError
    raise Error, "SOyA web-cli answered #{path} with invalid JSON"
  end
end
