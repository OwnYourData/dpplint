require "test_helper"

class ResolveCheckTest < ActiveSupport::TestCase
  UPI = "https://dpp.example.org/01/09520123456788/21/0001".freeze

  # Answers GET requests from a table of Accept header => [status, content type,
  # body, header fields] instead of the network, and records the Accept headers
  # requested. A value of :error stands for a failed retrieval.
  class FakeResolver
    attr_reader :requested

    def initialize(responses) = (@responses, @requested = responses, [])

    def get(_url, accept: nil)
      @requested << accept
      status, type, body, headers = @responses.fetch(accept) { @responses.fetch(:default) }
      return HttpResolver::Response.new(url: UPI, error: "retrieval failed: timeout (test)") if status == :error

      HttpResolver::Response.new(url: UPI, status: status, content_type: type, body: body, headers: headers || {})
    end
  end

  def passport(upi = UPI) = { "uniqueProductIdentifier" => upi }.to_json

  def messages(check, responses) = ResolveCheck.new(check, UPI, FakeResolver.new(responses)).messages
  def violations(check, responses) = messages(check, responses).map { |m| m[:message] }
  def severities(check, responses) = messages(check, responses).map { |m| m[:severity] }

  test "identifier resolves to its passport" do
    assert_empty violations({ "type" => "resolve" }, default: [200, "application/json", passport])
  end

  test "passport with another identifier fails" do
    assert_match(/uniqueProductIdentifier/, violations({ "type" => "resolve" }, default: [200, "application/json", passport("https://other.example/1")]).first)
  end

  test "a list of passports fails" do
    assert_match(/single JSON object/, violations({ "type" => "resolve" }, default: [200, "application/json", "[#{passport}]"]).first)
  end

  test "expected status and JSON object pass" do
    check = { "type" => "resolve", "expect" => { "status" => [200], "content_type" => "application/json" } }
    assert_empty violations(check, default: [200, "application/json; charset=utf-8", passport])
  end

  test "JSON content type with a non-object body fails" do
    check = { "type" => "resolve", "expect" => { "status" => [200], "content_type" => "application/json" } }
    assert_match(/single JSON object/, violations(check, default: [200, "application/json", "[1,2]"]).first)
  end

  test "HTML requested but JSON delivered fails" do
    check = { "type" => "resolve", "accept" => "text/html", "expect" => { "status" => [200], "content_type" => "text/html" } }
    result = violations(check, "text/html" => [200, "application/json", passport], default: [200, "application/json", passport])
    assert_match(/Content-Type is application\/json, expected text\/html/, result.first)
  end

  test "HTML delivered on request passes" do
    check = { "type" => "resolve", "accept" => "text/html", "expect" => { "status" => [200], "content_type" => "text/html" } }
    assert_empty violations(check, "text/html" => [200, "text/html; charset=utf-8", "<html></html>"], default: [200, "application/json", passport])
  end

  test "login required fails the retrieval without credentials" do
    check = { "type" => "resolve", "expect" => { "status" => [200] } }
    assert_match(/HTTP status is 401/, violations(check, default: [401, "application/json", "{}"]).first)
  end

  # further_requests

  HTML = { "status" => [200], "content_type" => "text/html" }.freeze
  JSON_EXPECT = { "status" => [200], "content_type" => "application/json" }.freeze

  test "further request is sent with its own Accept header after the first request" do
    check = { "type" => "resolve", "accept" => "text/html", "expect" => HTML,
              "further_requests" => [{ "accept" => "*/*", "expect" => JSON_EXPECT }] }
    resolver = FakeResolver.new("text/html" => [200, "text/html", "<html></html>"], "*/*" => [200, "application/json", passport])
    assert_empty ResolveCheck.new(check, UPI, resolver).messages
    assert_equal ["text/html", "*/*"], resolver.requested
  end

  test "failing further request without severity is a violation" do
    check = { "type" => "resolve", "accept" => "text/html", "expect" => HTML,
              "further_requests" => [{ "accept" => "*/*", "expect" => JSON_EXPECT }] }
    result = messages(check, "text/html" => [200, "text/html", "<html></html>"], "*/*" => [200, "text/html", "<html></html>"])
    assert_equal [{ severity: "violation", message: "request with Accept */*: Content-Type is text/html, expected application/json" }], result
  end

  test "failing further request with severity warning is a warning" do
    check = { "type" => "resolve", "accept" => "text/html", "expect" => HTML,
              "further_requests" => [{ "accept" => "*/*", "severity" => "warning", "expect" => JSON_EXPECT }] }
    result = messages(check, "text/html" => [200, "text/html", "<html></html>"], "*/*" => [404, "text/html", "<html></html>"])
    assert_equal %w[warning warning], result.map { |m| m[:severity] }
    assert_match(/\Arequest with Accept \*\/\*: HTTP status is 404/, result.first[:message])
  end

  test "severity warning of a further request also covers a failed retrieval" do
    check = { "type" => "resolve", "expect" => JSON_EXPECT,
              "further_requests" => [{ "accept" => "text/html", "severity" => "warning", "expect" => HTML }] }
    result = messages(check, "text/html" => [:error], default: [200, "application/json", passport])
    assert_equal [{ severity: "warning", message: "request with Accept text/html: retrieval failed: timeout (test)" }], result
  end

  test "further requests are evaluated independently of a failing first request" do
    check = { "type" => "resolve", "accept" => "text/html", "expect" => HTML,
              "further_requests" => [{ "accept" => "*/*", "severity" => "warning", "expect" => JSON_EXPECT },
                                     { "accept" => "application/json", "expect" => JSON_EXPECT }] }
    result = messages(check, "text/html" => [:error], "*/*" => [404, "application/json", "{}"], "application/json" => [200, "application/json", passport])
    assert_equal [{ severity: "violation", message: "retrieval failed: timeout (test)" },
                  { severity: "warning", message: "request with Accept */*: HTTP status is 404, expected 200" }], result
  end

  test "further request passes while the first request fails" do
    check = { "type" => "resolve", "accept" => "text/html", "expect" => HTML,
              "further_requests" => [{ "accept" => "*/*", "severity" => "warning", "expect" => JSON_EXPECT }] }
    result = messages(check, "text/html" => [200, "application/json", passport], "*/*" => [200, "application/json", passport])
    assert_equal ["violation"], result.map { |m| m[:severity] }
  end

  # expect.headers within resolve

  test "header assertion with severity warning gives a warning, without severity a violation" do
    headers = [{ "name" => "Vary", "contains" => "Accept", "severity" => "warning" }, { "name" => "Cache-Control", "exists" => true }]
    check = { "type" => "resolve", "expect" => JSON_EXPECT.merge("headers" => headers) }
    result = messages(check, default: [200, "application/json", passport, { "vary" => ["Origin"] }])
    assert_equal [["warning", 'header Vary is "Origin", expected a member "Accept"'], ["violation", "header Cache-Control is missing"]],
                 result.map { |m| [m[:severity], m[:message]] }
  end

  test "header assertions of a further request are checked on its own response" do
    check = { "type" => "resolve", "expect" => JSON_EXPECT,
              "further_requests" => [{ "accept" => "text/html", "expect" => HTML.merge("headers" => [{ "name" => "Vary", "contains" => "accept" }]) }] }
    result = messages(check, default: [200, "application/json", passport], "text/html" => [200, "text/html", "<html></html>", { "Vary" => ["Origin, Accept"] }])
    assert_empty result
  end

  test "expect parts not evaluated for resolve are reported" do
    check = { "type" => "resolve", "expect" => { "status" => [200], "json" => [{ "path" => "$.a", "exists" => true }] },
              "further_requests" => [{ "accept" => "*/*", "expect" => { "body_equals_step" => 1 } }] }
    assert_equal %w[json body_equals_step], ResolveCheck.new(check, UPI, FakeResolver.new({})).unsupported
    assert_empty ResolveCheck.new({ "type" => "resolve", "expect" => HTML }, UPI, FakeResolver.new({})).unsupported
  end

  # DPP-DAT-016 version 2 (dpp-criteria 4c155ee)

  DAT_016 = {
    "type" => "resolve", "accept" => "text/html",
    "expect" => { "status" => [200], "content_type" => "text/html",
                  "headers" => [{ "name" => "Vary", "contains" => "Accept", "severity" => "warning" }] },
    "further_requests" => [{ "accept" => "*/*", "severity" => "warning",
                             "expect" => { "status" => [200], "content_type" => "application/json" } }]
  }.freeze

  test "DPP-DAT-016: HTML with Vary Accept and JSON for */* passes" do
    assert_empty messages(DAT_016, "text/html" => [200, "text/html; charset=utf-8", "<html></html>", { "vary" => ["Accept, Origin"] }],
                                   "*/*" => [200, "application/json", passport])
  end

  test "DPP-DAT-016: HTML without Vary Accept and HTML for */* gives two warnings" do
    result = severities(DAT_016, "text/html" => [200, "text/html", "<html></html>", { "vary" => ["*"] }],
                                 "*/*" => [200, "text/html", "<html></html>"])
    assert_equal %w[warning warning], result
  end

  test "DPP-DAT-016: JSON on an HTML request is a violation" do
    result = messages(DAT_016, "text/html" => [200, "application/json; charset=utf-8", passport, { "vary" => ["Origin"] }],
                               "*/*" => [200, "application/json", passport])
    assert_equal [["violation", "Content-Type is application/json; charset=utf-8, expected text/html"],
                  ["warning", 'header Vary is "Origin", expected a member "Accept"']],
                 result.map { |m| [m[:severity], m[:message]] }
  end
end
