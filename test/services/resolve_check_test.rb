require "test_helper"

class ResolveCheckTest < ActiveSupport::TestCase
  UPI = "https://dpp.example.org/01/09520123456788/21/0001".freeze

  # Answers GET requests from a table instead of the network.
  class FakeResolver
    def initialize(responses) = @responses = responses

    def get(_url, accept: nil)
      status, type, body = @responses.fetch(accept) { @responses.fetch(:default) }
      HttpResolver::Response.new(url: UPI, status: status, content_type: type, body: body)
    end
  end

  def passport(upi = UPI) = { "uniqueProductIdentifier" => upi }.to_json

  def violations(check, responses) = ResolveCheck.new(check, UPI, FakeResolver.new(responses)).violations

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
end
