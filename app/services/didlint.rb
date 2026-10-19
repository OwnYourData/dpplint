require "net/http"

# Client for didlint (https://github.com/OwnYourData/didlint), which resolves a
# DID and checks its DID document against DID Core.
#
# One instance serves one check of a passport and keeps it within a time
# budget: each request waits at most `timeout` seconds, and all requests of the
# check together at most `budget` seconds. Once didlint has failed to answer,
# the remaining requests of the check are not sent; they raise Unavailable with
# the same reason, so the criteria that need didlint are reported as not
# evaluated instead of holding up the whole check.
class Didlint
  class Unavailable < StandardError; end

  OPEN_TIMEOUT = 5

  def initialize(base = Rails.configuration.x.dpplint.didlint,
                 timeout: Rails.configuration.x.dpplint.didlint_timeout,
                 budget: Rails.configuration.x.dpplint.didlint_budget)
    @base = base.chomp("/")
    @timeout = timeout.to_f
    @budget = budget.to_f
    @cache = {}
    @spent = 0.0
    @down = nil
  end

  # {"valid" => true} or {"valid" => false, "error" => ..., "errors" => [...]}
  # Raises Unavailable if didlint cannot be reached in time.
  def validate(did) = get("api/validate/#{did}")

  # The DID document, or nil if the DID cannot be resolved.
  def resolve(did)
    resolve!(did)
  rescue Unavailable
    nil
  end

  # Like resolve, but raises Unavailable if didlint cannot be reached in time.
  def resolve!(did)
    doc = get("api/resolve/#{did}")
    doc.is_a?(Hash) && doc["id"] ? doc : nil
  end

  private

  # Answers are cached per instance (one instance per check).
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
    raise Unavailable, @down if @down

    remaining = @budget - @spent
    raise down!("didlint was not asked: the time budget of #{seconds(@budget)} for this check is used up") if remaining <= 0

    wait = [@timeout, remaining].min
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      res = request(path, wait)
    ensure
      @spent += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
    parse(res)
  rescue Net::OpenTimeout
    raise down!("didlint not reachable (no connection within #{seconds([OPEN_TIMEOUT, wait].min)})")
  rescue Net::ReadTimeout
    raise down!("didlint did not answer within #{seconds(wait)}")
  rescue Unavailable
    raise
  rescue StandardError => e
    raise down!("didlint not reachable (#{e.message})")
  end

  # Net::HTTP repeats an idempotent request once after a timeout; max_retries 0
  # keeps the wait at one timeout.
  def request(path, wait)
    uri = URI("#{@base}/#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = [OPEN_TIMEOUT, wait].min
    http.read_timeout = wait
    http.max_retries = 0
    http.start { http.request(Net::HTTP::Get.new(uri, "Accept" => "application/json")) }
  end

  # The answer is checked before it is parsed: a status of 500 or above, or
  # anything other than JSON (such as the HTML error page of a proxy), means
  # that didlint could not answer.
  def parse(res)
    type = res["Content-Type"].to_s
    raise down!("didlint answered HTTP #{res.code}") if res.code.to_i >= 500
    raise down!("didlint answered HTTP #{res.code} with #{type.presence || 'no content type'} instead of JSON") unless type.match?(/json/i)

    JSON.parse(res.body)
  rescue JSON::ParserError
    raise down!("didlint answered HTTP #{res.code} with invalid JSON")
  end

  def down!(reason)
    @down = reason
    Unavailable.new(reason)
  end

  def seconds(value) = "#{value.to_f.round(1).to_s.delete_suffix('.0')} s"
end
