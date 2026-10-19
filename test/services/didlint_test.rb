require "test_helper"
require "socket"

# didlint not reachable, answering with HTML, not answering at all: a check
# waits at most its time budget and reports the reason instead of failing.
class DidlintTest < ActiveSupport::TestCase
  DID = "did:web:operator.example.org".freeze
  OTHER = "did:web:plant.example.org".freeze

  # Plain HTTP server on 127.0.0.1. With a block it answers every request with
  # the response the block returns; without one it accepts connections and
  # never answers. Returns [base URL, number of connections, stop].
  def serve(delay: 0, &answer)
    tcp = TCPServer.new("127.0.0.1", 0)
    connections = []
    thread = Thread.new do
      loop do
        client = tcp.accept
        connections << client
        Thread.new(client) do |c|
          while (line = c.gets) && line != "\r\n"; end
          sleep delay
          answer ? c.write(answer.call) : sleep(30)
        rescue IOError, SystemCallError
          nil
        ensure
          c.close unless c.closed?
        end
      end
    rescue IOError
      nil
    end
    ["http://127.0.0.1:#{tcp.addr[1]}", connections, -> { connections.each { |c| c.close unless c.closed? }; tcp.close; thread.join(2) }]
  end

  def http(status, type, body)
    "HTTP/1.1 #{status} X\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  test "a JSON answer is returned" do
    base, _, stop = serve { http(200, "application/json", '{"valid":true}') }
    assert_equal({ "valid" => true }, Didlint.new(base, timeout: 2, budget: 5).validate(DID))
  ensure
    stop&.call
  end

  test "didlint not reachable" do
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    tcp.close
    error = assert_raises(Didlint::Unavailable) { Didlint.new("http://127.0.0.1:#{port}", timeout: 2, budget: 5).validate(DID) }
    assert_match(/\Adidlint not reachable \(/, error.message)
  end

  test "an HTML page instead of JSON is reported, not parsed" do
    base, _, stop = serve { http(200, "text/html", "<html> <head><title>Maintenance</title></head></html>") }
    error = assert_raises(Didlint::Unavailable) { Didlint.new(base, timeout: 2, budget: 5).validate(DID) }
    assert_equal "didlint answered HTTP 200 with text/html instead of JSON", error.message
  ensure
    stop&.call
  end

  test "an HTML error page of a proxy is reported with its status" do
    base, _, stop = serve { http(504, "text/html", "<html> <head><title>504 Gateway Time-out</title></head></html>") }
    error = assert_raises(Didlint::Unavailable) { Didlint.new(base, timeout: 2, budget: 5).validate(DID) }
    assert_equal "didlint answered HTTP 504", error.message
  ensure
    stop&.call
  end

  test "a timeout ends the wait, and the other requests of the check are not sent" do
    base, connections, stop = serve
    didlint = Didlint.new(base, timeout: 0.4, budget: 5)
    first = nil
    took = elapsed do
      first = assert_raises(Didlint::Unavailable) { didlint.validate(DID) }
      assert_raises(Didlint::Unavailable) { didlint.validate(OTHER) }
      assert_nil didlint.resolve(OTHER)
    end
    assert_equal "didlint did not answer within 0.4 s", first.message
    assert_operator took, :<, 2
    assert_equal 1, connections.size
  ensure
    stop&.call
  end

  test "all requests of a check together stay within the budget" do
    base, _, stop = serve(delay: 0.3) { http(200, "application/json", '{"valid":true}') }
    didlint = Didlint.new(base, timeout: 2, budget: 0.5)
    error = nil
    took = elapsed do
      assert_equal({ "valid" => true }, didlint.validate(DID))
      error = assert_raises(Didlint::Unavailable) { didlint.validate(OTHER) }
      assert_raises(Didlint::Unavailable) { didlint.resolve!(OTHER) }
    end
    assert_match(/\Adidlint did not answer within 0\.\d s\z/, error.message)
    assert_operator took, :<, 1.5
  ensure
    stop&.call
  end

  test "a used-up budget is reported without asking didlint" do
    base, connections, stop = serve { http(200, "application/json", '{"valid":true}') }
    error = assert_raises(Didlint::Unavailable) { Didlint.new(base, timeout: 2, budget: 0).validate(DID) }
    assert_equal "didlint was not asked: the time budget of 0 s for this check is used up", error.message
    assert_empty connections
  ensure
    stop&.call
  end

  class FakeCatalogue
    def initialize(criteria) = @criteria = criteria
    def passport_criteria = @criteria
    def description_url(_id) = nil
  end

  test "a check with a hanging didlint answers in bounded time and reports DPP-ID-016 as not evaluated" do
    base, _, stop = serve
    criterion = { "id" => "DPP-ID-016", "title" => "t", "level" => "MUST", "status" => "active",
                  "check" => { "type" => "did", "paths" => ["$.economicOperatorId", "$.facilityId"] } }
    report = nil
    took = elapsed do
      report = PassportLinter.new(catalogue: FakeCatalogue.new([criterion]), didlint: Didlint.new(base, timeout: 0.4, budget: 1))
                             .run(passport: { "economicOperatorId" => DID, "facilityId" => OTHER })
    end
    result = report[:criteria].first
    assert_equal "skipped", result[:result]
    assert_equal "not_evaluated", result[:reason_code]
    assert_equal "didlint did not answer within 0.4 s", result[:reason]
    assert_operator took, :<, 2
  ensure
    stop&.call
  end
end
