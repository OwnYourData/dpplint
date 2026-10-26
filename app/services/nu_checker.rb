require "net/http"

# Client for the Nu Html Checker (vnu) that dpplint runs itself (NU_CHECKER_URL;
# in the deployment a second container of the pod that listens on 127.0.0.1
# only). The HTML view is posted to it as received; it is never sent to a
# public instance. Without NU_CHECKER_URL there is no checker. Each call waits
# at most OPEN_TIMEOUT and READ_TIMEOUT, but never beyond the time limit of
# the check (CheckDeadline).
class NuChecker
  class Unavailable < StandardError; end

  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 15

  def initialize(base = Rails.configuration.x.dpplint.nu_checker, deadline: CheckDeadline.new)
    @base = base.to_s.strip
    @deadline = deadline
  end

  def configured? = !@base.empty?

  # The messages of the checker for one HTML document, as the checker gives
  # them ("type", "subType", "message", "lastLine", …). Raises Unavailable if
  # there is no checker, it does not answer, or it could not check the
  # document (non-document-error).
  def messages(body, content_type)
    raise Unavailable, "no Nu Html Checker is configured for this instance" unless configured?

    uri = URI.join(@base.end_with?("/") ? @base : "#{@base}/", "?out=json")
    limits = @deadline.split(OPEN_TIMEOUT, READ_TIMEOUT)
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: limits.connect, read_timeout: limits.read, write_timeout: limits.read) do |http|
      http.post(uri.request_uri, body.to_s, "Content-Type" => content_type, "Accept" => "application/json")
    end
    parse(res)
  rescue Unavailable, CheckDeadline::Reached
    raise
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
    @deadline.timed_out!(limits)
    raise Unavailable, "the Nu Html Checker did not answer in time"
  rescue StandardError => e
    raise Unavailable, "the Nu Html Checker is not reachable (#{e.class})"
  end

  private

  def parse(res)
    raise Unavailable, "the Nu Html Checker answered with HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    list = JSON.parse(res.body.to_s)["messages"]
    raise Unavailable, "the Nu Html Checker answered without a list of messages" unless list.is_a?(Array)

    failure = list.find { |m| m.is_a?(Hash) && m["type"] == "non-document-error" }
    raise Unavailable, "the Nu Html Checker could not check the document: #{failure['message'].to_s.strip}" if failure

    list.grep(Hash)
  rescue JSON::ParserError
    raise Unavailable, "the Nu Html Checker answered with invalid JSON"
  end
end
