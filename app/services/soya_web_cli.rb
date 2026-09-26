require "net/http"

# Client for the SOyA web-cli running inside the same image.
class SoyaWebCli
  class Error < StandardError; end

  def initialize(base = Rails.configuration.x.dpplint.soya_web_cli)
    @base = base.chomp("/")
  end

  def acquire(structure, passport) = post("acquire/#{structure}", passport)

  def validate(structure, instance) = post("validate/#{structure}", instance)

  def version
    res = Net::HTTP.get_response(URI("#{@base}/api/v1/version"))
    res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body)["version"] : nil
  rescue StandardError
    nil
  end

  private

  def post(path, body)
    uri = URI("#{@base}/api/v1/#{path}")
    res = Net::HTTP.post(uri, body.to_json, "Content-Type" => "application/json")
    raise Error, "web-cli #{path}: HTTP #{res.code} #{res.body.to_s[0, 200]}" unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)
  end
end
