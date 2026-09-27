require "test_helper"

class PassportFetcherTest < ActiveSupport::TestCase
  include SigningHelper

  UPI = "https://dpp.example.org/01/09520123456788/21/0001".freeze

  # Answers GET requests by Accept header instead of the network.
  class FakeResolver
    def initialize(responses) = @responses = responses

    def get(_url, accept: nil)
      status, type, body = @responses.fetch(accept) { [406, "text/plain", ""] }
      HttpResolver::Response.new(url: UPI, status: status, content_type: type, body: body)
    end
  end

  def passport = { "uniqueProductIdentifier" => UPI, "economicOperatorId" => did_key }

  test "JSON passport without JWS" do
    result = PassportFetcher.new(FakeResolver.new("application/json" => [200, "application/json", passport.to_json])).fetch(UPI)
    assert_equal UPI, result.json["uniqueProductIdentifier"]
    assert_nil result.jws
  end

  test "JWS offered by content negotiation is kept next to the JSON passport" do
    jws = sign_jws(passport, kid: "#{did_key}##{key_multibase}")
    resolver = FakeResolver.new("application/json" => [200, "application/json", passport.to_json],
                                Jws::ACCEPT => [200, "application/vc+jwt", jws])
    result = PassportFetcher.new(resolver).fetch(UPI)
    assert_equal jws, result.jws.compact
    refute result.jws_only
    assert_equal "json and jws", result.info[:securedAs]
  end

  test "JWS delivered instead of JSON becomes the passport" do
    jws = sign_jws(passport, kid: "#{did_key}##{key_multibase}")
    result = PassportFetcher.new(FakeResolver.new("application/json" => [200, "application/vc+jwt", jws])).fetch(UPI)
    assert_equal UPI, result.json["uniqueProductIdentifier"]
    assert result.jws_only
  end

  test "server ignoring the JOSE Accept header gives no JWS" do
    resolver = FakeResolver.new("application/json" => [200, "application/json", passport.to_json],
                                Jws::ACCEPT => [200, "application/json", passport.to_json])
    assert_nil PassportFetcher.new(resolver).fetch(UPI).jws
  end
end
