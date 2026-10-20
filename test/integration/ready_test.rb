require "test_helper"
require "minitest/mock"
require "socket"

# GET /ready is the readiness probe of a replica; GET /version answers as
# before, whether or not the SOyA web-cli answers.
class ReadyTest < ActionDispatch::IntegrationTest
  wait_for_web_cli

  def closed_url
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    tcp.close
    "http://127.0.0.1:#{port}"
  end

  test "ready: 200 when the SOyA web-cli and its repository answer" do
    get "/ready"
    assert_response :ok
    assert_equal({ "ready" => true }, response.parsed_body)
  end

  test "not ready: 503 with the reason when the SOyA web-cli does not answer" do
    Readiness.stub(:current, Readiness.new(web_cli: closed_url)) do
      get "/ready"
    end
    assert_response :service_unavailable
    assert_equal({ "ready" => false, "reason" => "SOyA web-cli not reachable" }, response.parsed_body)
  end

  test "version: 200 with the same fields, also when the SOyA web-cli does not answer" do
    config = Rails.configuration.x.dpplint
    previous = config.soya_web_cli
    config.soya_web_cli = closed_url
    get "/version"
    assert_response :ok
    body = response.parsed_body
    assert_equal %w[service version dpp-criteria soya-web-cli soya-context], body.keys
    assert_nil body["soya-web-cli"]
  ensure
    config.soya_web_cli = previous
  end
end
