require "test_helper"
require "minitest/mock"
require "socket"

class HttpResolverTest < ActiveSupport::TestCase
  # A plain HTTP server on 127.0.0.1 that answers every request with the
  # response the block returns for the request line and headers.
  def serve
    tcp = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new do
      loop do
        client = tcp.accept
        lines = []
        while (line = client.gets) && line != "\r\n"
          lines << line.chomp
        end
        requests << lines
        client.write(yield(lines))
        client.close
      end
    rescue IOError
      nil
    end
    [tcp.addr[1], requests, -> { tcp.close; thread.join(2) }]
  end

  def http(status, headers = {}, body = "")
    head = headers.merge("Content-Length" => body.bytesize, "Connection" => "close").map { |k, v| "#{k}: #{v}\r\n" }.join
    "HTTP/1.1 #{status} X\r\n#{head}\r\n#{body}"
  end

  # Resolves pin.test (a name that does not exist) to 127.0.0.1, as a public
  # name would resolve to its public address; every other host is checked as usual.
  def with_pin_test(&block)
    original = HttpResolver.method(:public_address!)
    HttpResolver.stub(:public_address!, ->(host) { host == "pin.test" ? "127.0.0.1" : original.call(host) }, &block)
  end

  test "internal addresses are refused" do
    %w[127.0.0.1 10.1.2.3 172.16.0.1 192.168.1.1 169.254.169.254 100.64.0.1 ::1 fe80::1 fd00::1 ::ffff:127.0.0.1 localhost].each do |host|
      assert_raises(HttpResolver::Blocked, host) { HttpResolver.public_address!(host) }
    end
  end

  test "public addresses are allowed" do
    assert_equal "89.58.20.114", HttpResolver.public_address!("89.58.20.114")
    assert_equal "2a03:4000:6:1::1", HttpResolver.public_address!("2a03:4000:6:1::1")
  end

  test "retrieval from an internal address is refused" do
    res = HttpResolver.new(allow_private: false).get("http://127.0.0.1:3000/up")
    assert_match(/not retrieved: 127.0.0.1 resolves to 127.0.0.1/, res.error)
  end

  test "retrieval from a host name with an internal address is refused before connecting" do
    port, requests, stop = serve { http(200, { "Content-Type" => "application/json" }, "{}") }
    res = HttpResolver.new(allow_private: false).get("http://localhost:#{port}/p")
    assert_match(/not retrieved: localhost resolves to .*, which is not a public address/, res.error)
    assert_empty requests
  ensure
    stop&.call
  end

  test "the connection goes to the checked address, Host stays the host name" do
    port, requests, stop = serve do
      http(200, { "Content-Type" => "application/json", "Vary" => "Accept" }, '{"a":1}')
    end
    with_pin_test do
      res = HttpResolver.new(allow_private: false).get("http://pin.test:#{port}/p", accept: "application/json")
      assert_nil res.error
      assert_equal 200, res.status
      assert_equal '{"a":1}', res.body
      assert_equal "1.1", res.http_version
      assert_equal ["Accept"], res.headers["vary"]
    end
    assert_includes requests.first, "GET /p HTTP/1.1"
    assert_includes requests.first.map(&:downcase), "host: pin.test:#{port}"
    assert_includes requests.first.map(&:downcase), "accept: application/json"
  ensure
    stop&.call
  end

  test "a redirect to a host name with an internal address is refused" do
    port, requests, stop = serve { |_| http(302, { "Location" => "http://localhost:#{port}/inner" }) }
    with_pin_test do
      res = HttpResolver.new(allow_private: false).get("http://pin.test:#{port}/outer")
      assert_match(/not retrieved: localhost resolves to/, res.error)
    end
    assert_equal 1, requests.size
  ensure
    stop&.call
  end

  test "redirects are followed, header fields are lists, HEAD and ranged GET probe a URL" do
    port, requests, stop = serve do |lines|
      case lines.first
      when %r{\AGET /start } then http(301, { "Location" => "/end" })
      when %r{\AGET /end } then "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nVary: Accept\r\nVary: Origin\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
      when %r{\AHEAD /nohead } then http(405)
      else http(206)
      end
    end
    resolver = HttpResolver.new(allow_private: true)
    res = resolver.get("http://127.0.0.1:#{port}/start")
    assert_equal "http://127.0.0.1:#{port}/end", res.url
    assert_equal "ok", res.body
    assert_equal %w[Accept Origin], res.headers["vary"]
    assert_equal 206, resolver.probe("http://127.0.0.1:#{port}/nohead").status
    assert(requests.any? { |r| r.first.start_with?("GET /nohead") && r.map(&:downcase).include?("range: bytes=0-0") })
    assert_same res, resolver.get("http://127.0.0.1:#{port}/start"), "cached per run"
  ensure
    stop&.call
  end

  test "more than five redirects give an error" do
    port, _requests, stop = serve { |_| http(302, { "Location" => "/again" }) }
    res = HttpResolver.new(allow_private: true).get("http://127.0.0.1:#{port}/loop")
    assert_equal "more than 5 redirects", res.error
  ensure
    stop&.call
  end
end
