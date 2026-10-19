require "test_helper"
require "socket"

# Answers of the SOyA web-cli are checked before they are parsed: an error page
# or no answer is reported as such, not as a JSON syntax error.
class SoyaWebCliTest < ActiveSupport::TestCase
  def serve(&answer)
    tcp = TCPServer.new("127.0.0.1", 0)
    clients = []
    thread = Thread.new do
      loop do
        client = tcp.accept
        clients << client
        Thread.new(client) do |c|
          while (line = c.gets) && line != "\r\n"; end
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
    ["http://127.0.0.1:#{tcp.addr[1]}", -> { clients.each { |c| c.close unless c.closed? }; tcp.close; thread.join(2) }]
  end

  def http(status, type, body)
    "HTTP/1.1 #{status} X\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  end

  test "a JSON answer is parsed" do
    base, stop = serve { http(200, "application/json; charset=utf-8", '{"isValid":true,"results":[]}') }
    assert_equal({ "isValid" => true, "results" => [] }, SoyaWebCli.new(base).validate("DigitalProductPassport", {}))
  ensure
    stop&.call
  end

  test "an HTML page instead of JSON is reported, not parsed" do
    base, stop = serve { http(200, "text/html", "<html> <head><title>Error</title></head></html>") }
    error = assert_raises(SoyaWebCli::Error) { SoyaWebCli.new(base).validate("DigitalProductPassport", {}) }
    assert_equal "SOyA web-cli answered validate/DigitalProductPassport with text/html instead of JSON", error.message
  ensure
    stop&.call
  end

  test "an error status is reported with the start of the answer" do
    base, stop = serve { http(500, "text/html; charset=utf-8", "Error: GET http://127.0.0.1:8081/Unknown failed: 404") }
    error = assert_raises(SoyaWebCli::Error) { SoyaWebCli.new(base).acquire("Unknown", {}) }
    assert_equal "SOyA web-cli answered acquire/Unknown with HTTP 500: Error: GET http://127.0.0.1:8081/Unknown failed: 404", error.message
  ensure
    stop&.call
  end

  test "no answer within the time limit is reported" do
    base, stop = serve
    error = assert_raises(SoyaWebCli::Error) { SoyaWebCli.new(base, read_timeout: 0.3).validate("DigitalProductPassport", {}) }
    assert_equal "SOyA web-cli did not answer validate/DigitalProductPassport within 0.3 s", error.message
  ensure
    stop&.call
  end

  test "web-cli not reachable" do
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    tcp.close
    error = assert_raises(SoyaWebCli::Error) { SoyaWebCli.new("http://127.0.0.1:#{port}").validate("DigitalProductPassport", {}) }
    assert_match(/\ASOyA web-cli not reachable for validate\/DigitalProductPassport \(/, error.message)
    assert_nil SoyaWebCli.new("http://127.0.0.1:#{port}").version
  end
end
