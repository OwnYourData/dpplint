require "test_helper"

class ProofCheckTest < ActiveSupport::TestCase
  include SigningHelper

  CHECK = { "type" => "proof", "key_from" => "$.economicOperatorId",
            "formats" => %w[vc-data-integrity vc-jose-cose did-oyd-log] }.freeze
  OYD = "did:oyd:zQmOperator".freeze

  # Returns a fixed DID document instead of asking didlint.
  class FakeDidlint
    def initialize(doc = nil, unavailable: false) = (@doc, @unavailable = doc, unavailable)

    def resolve!(_did)
      raise Didlint::Unavailable, "didlint not reachable (test)" if @unavailable

      @doc
    end
  end

  def passport(operator = did_key) = { "uniqueProductIdentifier" => "https://dpp.example.org/01/1", "economicOperatorId" => operator, "dppStatus" => "Active" }

  def outcome(passport, didlint: FakeDidlint.new) = ProofCheck.new(CHECK, passport, didlint: didlint).outcome

  def oyd_document(key = signing_key)
    { "id" => OYD, "verificationMethod" => [
      { "id" => "#{OYD}#key-doc", "type" => "Ed25519VerificationKey2020", "controller" => OYD, "publicKeyMultibase" => key_multibase(key) }
    ] }
  end

  test "W3C test vector for eddsa-jcs-2022 verifies" do
    signed = JSON.parse(file_fixture("w3c/eddsa-jcs-2022-signed.json").read)
    key = ProofCheck.ed25519_key(JSON.parse(file_fixture("w3c/public-key.json").read)["publicKeyMultibase"])
    signature = Base58.decode(signed["proof"]["proofValue"].delete_prefix("z"))
    assert ProofCheck.eddsa_jcs_valid?(signed, signed["proof"], key, signature)
    refute ProofCheck.eddsa_jcs_valid?(signed.merge("name" => "changed"), signed["proof"], key, signature)
  end

  test "passport without proof is skipped" do
    result = outcome(passport)
    assert_match(/carries no integrity proof/, result.skipped)
    assert_match(/vc-jose-cose, did-oyd-log/, result.skipped)
  end

  test "proof by a did:key of the economic operator passes" do
    signed = sign(passport, verification_method: "#{did_key}##{key_multibase}")
    assert_empty outcome(signed).messages
  end

  test "changed passport fails" do
    signed = sign(passport, verification_method: "#{did_key}##{key_multibase}")
    result = outcome(signed.merge("dppStatus" => "Inactive"))
    assert_equal ["violation"], result.messages.map { |m| m[:severity] }
    assert_match(/does not verify/, result.messages.first[:message])
  end

  test "proof by another key than the economic operator fails" do
    other = OpenSSL::PKey.generate_key("ED25519")
    signed = sign(passport, verification_method: "#{did_key(other)}##{key_multibase(other)}", key: other)
    assert_match(/not with a key of the economic operator/, outcome(signed).messages.first[:message])
  end

  test "key from the resolved DID document of the economic operator" do
    signed = sign(passport(OYD), verification_method: "#{OYD}#key-doc")
    assert_empty outcome(signed, didlint: FakeDidlint.new(oyd_document)).messages
  end

  test "relative verification method ids in the DID document are matched" do
    doc = oyd_document
    doc["verificationMethod"].first["id"] = "#key-doc"
    signed = sign(passport(OYD), verification_method: "#{OYD}#key-doc")
    assert_empty outcome(signed, didlint: FakeDidlint.new(doc)).messages
  end

  test "verification method missing from the DID document fails" do
    signed = sign(passport(OYD), verification_method: "#{OYD}#key-other")
    assert_match(/is not an Ed25519 key/, outcome(signed, didlint: FakeDidlint.new(oyd_document)).messages.first[:message])
  end

  test "other proof purpose gives a warning" do
    signed = sign(passport, verification_method: "#{did_key}##{key_multibase}", purpose: "authentication")
    assert_equal ["warning"], outcome(signed).messages.map { |m| m[:severity] }
  end

  test "unsupported cryptosuite is skipped" do
    signed = sign(passport, verification_method: "#{did_key}##{key_multibase}")
    signed["proof"]["cryptosuite"] = "ecdsa-rdfc-2019"
    assert_match(/not verified in this version/, outcome(signed).skipped)
  end

  test "economic operator that is not a DID is skipped" do
    signed = sign(passport("urn:example:operator"), verification_method: "#{did_key}##{key_multibase}")
    assert_match(/not a DID/, outcome(signed).skipped)
  end

  test "unreachable didlint is passed on" do
    signed = sign(passport(OYD), verification_method: "#{OYD}#key-doc")
    assert_raises(Didlint::Unavailable) { outcome(signed, didlint: FakeDidlint.new(unavailable: true)) }
  end
end
