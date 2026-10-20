require "net/http"

# Whether this replica can check passports: the SOyA web-cli and the local
# SOyA repository with the structures of the image (both started by
# docker/init.sh) answer on their ports. GET /ready reports it for the
# readiness probe.
#
# The result is held, so that the probe (every 5 s, 2 s time limit) stays
# cheap and starts no process: once both have answered, they are asked again
# at most every RECHECK seconds; until then at most every RETRY seconds. Each
# question is one local request with short time limits (at most 1.5 s for
# both together). Only one question runs at a time; a caller that comes while
# one runs gets the held result.
class Readiness
  RECHECK = 30
  RETRY = 1
  OPEN_TIMEOUT = 0.25
  READ_TIMEOUT = 0.5

  Result = Struct.new(:ready, :reason, keyword_init: true)

  NOT_CHECKED = Result.new(ready: false, reason: "not checked yet").freeze

  CURRENT_LOCK = Mutex.new

  def self.current = CURRENT_LOCK.synchronize { @current ||= new }

  def initialize(web_cli: nil, repository: nil, structures_dir: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    config = Rails.configuration.x.dpplint
    @web_cli = (web_cli || config.soya_web_cli).chomp("/")
    @repository = (repository || config.soya_repository).chomp("/")
    @structures_dir = structures_dir || config.structures_dir
    @clock = clock
    @lock = Mutex.new
    @result = NOT_CHECKED
    @checked_at = nil
  end

  def status
    if due? && @lock.try_lock
      begin
        @result = check
        @checked_at = @clock.call
      ensure
        @lock.unlock
      end
    end
    @result
  end

  private

  def due?
    return true if @checked_at.nil?

    @clock.call - @checked_at >= (@result.ready ? RECHECK : RETRY)
  end

  def check
    reason = web_cli_problem || repository_problem
    reason ? Result.new(ready: false, reason: reason) : Result.new(ready: true)
  end

  def web_cli_problem
    res = request(Net::HTTP::Get, "#{@web_cli}/api/v1/version")
    return "SOyA web-cli answered HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
    return "SOyA web-cli answered without its version" unless res["Content-Type"].to_s.match?(/json/i) && JSON.parse(res.body)["version"].present?

    nil
  rescue JSON::ParserError
    "SOyA web-cli answered without its version"
  rescue StandardError
    "SOyA web-cli not reachable"
  end

  def repository_problem
    structure = Dir.exist?(@structures_dir) && Dir.children(@structures_dir).min
    return "no SOyA structures in this image" unless structure

    res = request(Net::HTTP::Head, "#{@repository}/#{ERB::Util.url_encode(structure)}")
    res.is_a?(Net::HTTPSuccess) ? nil : "SOyA repository answered HTTP #{res.code} for #{structure}"
  rescue StandardError
    "SOyA repository not reachable"
  end

  def request(method, url)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, max_retries: 0) do |http|
      http.request(method.new(uri.request_uri))
    end
  end
end
