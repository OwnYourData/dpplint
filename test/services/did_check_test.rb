require "test_helper"

class DidCheckTest < ActiveSupport::TestCase
  DID = "did:web:operator.example.org".freeze
  CHECK = { "type" => "did", "paths" => ["$.economicOperatorId", "$.facilityId"], "vc_data_model" => "2.0" }.freeze

  class FakeDidlint
    def initialize(valid: true, services: []) = (@valid, @services = valid, services)
    def validate(_did) = @valid ? { "valid" => true } : { "valid" => false, "error" => "did not found" }
    def resolve(did) = { "id" => did, "service" => @services }
  end

  class FakeResolver
    def initialize(body) = @body = body
    def get(url, accept: nil) = HttpResolver::Response.new(url: url, status: 200, content_type: "application/json", body: @body)
  end

  def run_check(passport, didlint:, body: "{}")
    DidCheck.new(CHECK, passport, didlint: didlint, resolver: FakeResolver.new(body))
  end

  def linked(url = "https://operator.example.org/vp.json")
    [{ "id" => "#vp", "type" => "LinkedVerifiablePresentation", "serviceEndpoint" => url }]
  end

  test "values that are not DIDs are ignored" do
    assert_empty run_check({ "economicOperatorId" => "0088:9520123000001" }, didlint: FakeDidlint.new).dids
  end

  test "operator and facility DIDs are both checked" do
    check = run_check({ "economicOperatorId" => DID, "facilityId" => "did:web:plant.example.org" }, didlint: FakeDidlint.new)
    assert_equal [DID, "did:web:plant.example.org"], check.dids
  end

  test "DID rejected by didlint is a violation" do
    messages = run_check({ "economicOperatorId" => DID }, didlint: FakeDidlint.new(valid: false)).messages
    assert(messages.any? { |m| m[:severity] == "violation" && m[:message].include?("did not found") })
  end

  test "valid DID without linked credentials gives a warning" do
    messages = run_check({ "economicOperatorId" => DID }, didlint: FakeDidlint.new).messages
    assert_equal ["warning"], messages.map { |m| m[:severity] }
  end

  test "linked presentation with VC 2.0 context passes" do
    body = { "@context" => ["https://www.w3.org/ns/credentials/v2"], "type" => ["VerifiablePresentation"] }.to_json
    assert_empty run_check({ "economicOperatorId" => DID }, didlint: FakeDidlint.new(services: linked), body: body).messages
  end

  test "linked presentation with VC 1.1 context is a violation" do
    body = { "@context" => ["https://www.w3.org/2018/credentials/v1"], "type" => ["VerifiablePresentation"] }.to_json
    messages = run_check({ "economicOperatorId" => DID }, didlint: FakeDidlint.new(services: linked), body: body).messages
    assert_equal ["violation"], messages.map { |m| m[:severity] }
  end
end
