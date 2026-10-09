require "test_helper"

class ProofCheckTest < ActiveSupport::TestCase
  include SigningHelper

  CHECK = { "type" => "proof", "formats" => %w[vc-data-integrity vc-jose-cose did-oyd-log] }.freeze
  ISSUER = CHECK.merge("key_from" => "$.economicOperatorId").freeze
  OYD = "did:oyd:zQmOperator".freeze

  # Returns a fixed DID document instead of asking didlint.
  class FakeDidlint
    def initialize(doc = nil, unavailable: false, docs: {}) = (@doc, @unavailable, @docs = doc, unavailable, docs)

    def resolve!(did)
      raise Didlint::Unavailable, "didlint not reachable (test)" if @unavailable

      @docs.fetch(did, @doc)
    end
  end

  # Answers GET requests from a table of URL => body instead of the network.
  class FakeResolver
    def initialize(bodies) = @bodies = bodies

    def get(url, accept: nil)
      body = @bodies[url]
      return HttpResolver::Response.new(url: url, status: 404, content_type: "text/plain", body: "") unless body

      HttpResolver::Response.new(url: url, status: 200, content_type: "application/json", body: body)
    end
  end

  def passport(operator = did_key) = { "uniqueProductIdentifier" => "https://dpp.example.org/01/1", "economicOperatorId" => operator, "dppStatus" => "Active" }

  def outcome(passport, didlint: FakeDidlint.new, jws: nil, jws_only: false, raw: nil, resolver: FakeResolver.new({}), check: CHECK)
    ProofCheck.new(check, passport, raw: raw, jws: jws, jws_only: jws_only, didlint: didlint, resolver: resolver).outcome
  end

  def oyd_document(key = signing_key)
    { "id" => OYD, "verificationMethod" => [
      { "id" => "#{OYD}#key-doc", "type" => "Ed25519VerificationKey2020", "controller" => OYD, "publicKeyMultibase" => key_multibase(key) }
    ] }
  end

  test "W3C test vector for eddsa-jcs-2022 verifies" do
    signed = JSON.parse(file_fixture("w3c/eddsa-jcs-2022-signed.json").read)
    key = KeyResolver.from_multibase(JSON.parse(file_fixture("w3c/public-key.json").read)["publicKeyMultibase"])
    signature = Base58.decode(signed["proof"]["proofValue"].delete_prefix("z"))
    assert ProofCheck.eddsa_jcs_valid?(signed, signed["proof"], key, signature)
    refute ProofCheck.eddsa_jcs_valid?(signed.merge("name" => "changed"), signed["proof"], key, signature)
  end

  test "passport without proof is skipped" do
    result = outcome(passport)
    assert_match(/carries no integrity proof/, result.skipped)
    assert_match(/no payloadHash for the passport DID/, result.skipped)
    assert_equal "no_evidence", result.code
  end

  test "proof by a did:key of the economic operator passes both checks" do
    signed = sign(passport, verification_method: "#{did_key}##{key_multibase}")
    assert_empty outcome(signed).messages
    assert_empty outcome(signed, check: ISSUER).messages
  end

  test "changed passport fails" do
    signed = sign(passport, verification_method: "#{did_key}##{key_multibase}")
    result = outcome(signed.merge("dppStatus" => "Inactive"))
    assert_equal ["violation"], result.messages.map { |m| m[:severity] }
    assert_match(/does not verify/, result.messages.first[:message])
  end

  test "proof by another key verifies but gives a warning on the issuer" do
    other = OpenSSL::PKey.generate_key("ED25519")
    signed = sign(passport, verification_method: "#{did_key(other)}##{key_multibase(other)}", key: other)
    assert_empty outcome(signed).messages
    result = outcome(signed, check: ISSUER)
    assert_equal ["warning"], result.messages.map { |m| m[:severity] }
    assert_match(/not by the economic operator .* authorised representative cannot be recognised automatically/, result.messages.first[:message])
  end

  test "issuer check is skipped without a verified proof" do
    assert_match(/no verified integrity proof/, outcome(passport, check: ISSUER).skipped)
    signed = sign(passport, verification_method: "#{did_key}##{key_multibase}").merge("dppStatus" => "Inactive")
    assert_match(/no verified integrity proof/, outcome(signed, check: ISSUER).skipped)
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
    assert_match(/is not an Ed25519 or P-256 key/, outcome(signed, didlint: FakeDidlint.new(oyd_document)).messages.first[:message])
  end

  test "other proof purpose gives a warning" do
    signed = sign(passport, verification_method: "#{did_key}##{key_multibase}", purpose: "authentication")
    assert_equal ["warning"], outcome(signed).messages.map { |m| m[:severity] }
  end

  test "unsupported cryptosuite is skipped" do
    signed = sign(passport, verification_method: "#{did_key}##{key_multibase}")
    signed["proof"]["cryptosuite"] = "ecdsa-rdfc-2019"
    assert_match(/not verified in this version/, outcome(signed).skipped)
    assert_equal "not_evaluated", outcome(signed).code
  end

  test "economic operator that is not a DID skips only the issuer check" do
    signed = sign(passport("urn:example:operator"), verification_method: "#{did_key}##{key_multibase}")
    assert_empty outcome(signed).messages
    assert_match(/not a DID/, outcome(signed, check: ISSUER).skipped)
    assert_equal "not_applicable", outcome(signed, check: ISSUER).code
  end

  test "unreachable didlint is passed on" do
    signed = sign(passport(OYD), verification_method: "#{OYD}#key-doc")
    assert_raises(Didlint::Unavailable) { outcome(signed, didlint: FakeDidlint.new(unavailable: true)) }
  end

  test "passport delivered as JWS signed by the economic operator passes" do
    jws = Jws.parse(sign_jws(passport, kid: "#{did_key}##{key_multibase}"))
    assert_empty outcome(jws.payload, jws: jws, jws_only: true).messages
  end

  test "JWS signed with ES256 and a key from the DID document passes" do
    ec = OpenSSL::PKey::EC.generate("prime256v1")
    doc = { "id" => OYD, "verificationMethod" => [{ "id" => "#key-p256", "type" => "Multikey", "publicKeyMultibase" => key_multibase(ec) }] }
    jws = Jws.parse(sign_jws(passport(OYD), kid: "#key-p256", key: ec, iss: OYD))
    assert_empty outcome(jws.payload, jws: jws, jws_only: true, didlint: FakeDidlint.new(doc)).messages
  end

  test "JWS with changed payload fails" do
    header, _payload, signature = sign_jws(passport, kid: "#{did_key}##{key_multibase}").split(".")
    jws = Jws.parse([header, b64url(passport.merge("dppStatus" => "Inactive").to_json), signature].join("."))
    assert_match(/does not verify/, outcome(jws.payload, jws: jws, jws_only: true).messages.first[:message])
  end

  test "JWS whose payload differs from the JSON passport fails" do
    jws = Jws.parse(sign_jws(passport, kid: "#{did_key}##{key_multibase}"))
    result = outcome(passport.merge("dppStatus" => "Inactive"), jws: jws)
    assert_equal ["JWS payload differs from the passport delivered as JSON"], result.messages.map { |m| m[:message] }
  end

  test "JWS without kid fails" do
    header = b64url({ "alg" => "EdDSA" }.to_json)
    body = b64url(passport.to_json)
    jws = Jws.parse("#{header}.#{body}.#{b64url(signing_key.sign(nil, "#{header}.#{body}"))}")
    assert_match(/no kid/, outcome(jws.payload, jws: jws, jws_only: true).messages.first[:message])
  end

  test "JWS with an unsupported algorithm is skipped" do
    jws = Jws.parse("#{b64url({ 'alg' => 'RS256', 'kid' => 'x' }.to_json)}.#{b64url(passport.to_json)}.AAAA")
    assert_match(/JWS RS256 is not verified/, outcome(jws.payload, jws: jws, jws_only: true).skipped)
  end

  PASSPORT_DID = "did:oyd:zQmPassport".freeze
  ENDPOINT = "https://custodian.example.org/dpp/v1/dppsByProductId/1".freeze
  # The serviceEndpoint is requested in the full representation (EN 18222 8.1).
  FULL_ENDPOINT = "#{ENDPOINT}?representation=full".freeze

  def attested_passport = passport("did:oyd:zQmOperator").merge("digitalProductPassportId" => PASSPORT_DID)
  def attested_bytes = JSON.generate(attested_passport)

  def passport_did_document(payload_hash: ProofCheck.multihash(attested_bytes))
    service = { "id" => "#{PASSPORT_DID}#payload", "type" => "DigitalProductPassport", "serviceEndpoint" => ENDPOINT }
    service["payloadHash"] = payload_hash if payload_hash
    { "id" => PASSPORT_DID, "service" => [service] }
  end

  def oyd_outcome(raw:, passport: attested_passport, document: passport_did_document, endpoint_body: attested_bytes)
    outcome(passport, raw: raw, didlint: FakeDidlint.new(docs: { PASSPORT_DID => document }),
                      resolver: FakeResolver.new(FULL_ENDPOINT => endpoint_body))
  end

  # Bytes of https://dpp.oydapp.eu/01/09520123456788/21/000002 as delivered on 27.09.2026,
  # and the payloadHash in the DID document of its digitalProductPassportId.
  test "the serviceEndpoint is requested with representation=full" do
    assert_equal "https://c.example/dpp/v1/dppsByProductId/1?representation=full",
                 ProofCheck.full_representation("https://c.example/dpp/v1/dppsByProductId/1")
    assert_equal "https://c.example/p?a=1&representation=full", ProofCheck.full_representation("https://c.example/p?a=1")
    assert_equal "https://c.example/p?representation=full", ProofCheck.full_representation("https://c.example/p?representation=compressed")
  end

  test "an endpoint that answers only without representation=full is not the attested source" do
    result = outcome(attested_passport, raw: nil, didlint: FakeDidlint.new(docs: { PASSPORT_DID => passport_did_document }),
                                        resolver: FakeResolver.new(ENDPOINT => attested_bytes))
    assert_match(/cannot be retrieved/, result.messages.first[:message])
  end

  test "multihash matches the payloadHash of the example passport 000002" do
    assert_equal "zQmRdgMsgR8RRaQEadHFSJ2Zw4cReM6MpeZWJJTEjRzbSfw", ProofCheck.multihash(file_fixture("passport-000002.json").binread)
  end

  test "passport whose bytes match the payloadHash of its DID passes" do
    assert_empty oyd_outcome(raw: attested_bytes).messages
  end

  test "passport at the serviceEndpoint that does not match the payloadHash fails" do
    result = oyd_outcome(raw: attested_bytes, document: passport_did_document(payload_hash: ProofCheck.multihash("{}")))
    assert_match(/does not match payloadHash/, result.messages.first[:message])
  end

  test "product identifier delivering other content than attested fails" do
    changed = attested_passport.merge("dppStatus" => "Inactive")
    result = oyd_outcome(raw: JSON.generate(changed), passport: changed)
    assert_match(/differs from the passport attested/, result.messages.first[:message])
  end

  test "same content in other bytes gives a warning" do
    result = oyd_outcome(raw: JSON.pretty_generate(attested_passport))
    assert_equal ["warning"], result.messages.map { |m| m[:severity] }
  end

  test "posted passport is compared by content" do
    assert_empty oyd_outcome(raw: nil).messages
    changed = attested_passport.merge("dppStatus" => "Inactive")
    assert_match(/sent for checking differs/, oyd_outcome(raw: nil, passport: changed).messages.first[:message])
  end

  test "DID document without payloadHash is skipped" do
    result = oyd_outcome(raw: attested_bytes, document: passport_did_document(payload_hash: nil))
    assert_match(/binds only the location of the passport, not its content/, result.skipped)
    assert_equal "no_evidence", result.code
  end

  test "unreachable serviceEndpoint still passes when the delivered bytes match" do
    assert_empty oyd_outcome(raw: attested_bytes, endpoint_body: nil).messages
    assert_match(/cannot be retrieved/, oyd_outcome(raw: nil, endpoint_body: nil).messages.first[:message])
  end

  test "content attested by the passport DID gives a warning on the issuer" do
    result = outcome(attested_passport, raw: attested_bytes, check: ISSUER,
                                        didlint: FakeDidlint.new(docs: { PASSPORT_DID => passport_did_document }),
                                        resolver: FakeResolver.new(FULL_ENDPOINT => attested_bytes))
    assert_match(/attested with the key of the passport DID #{PASSPORT_DID}, which is not linked/, result.messages.first[:message])
  end

  test "did-oyd-log without didlint is skipped" do
    result = outcome(attested_passport, raw: attested_bytes, didlint: FakeDidlint.new(unavailable: true))
    assert_match(/did-oyd-log not checked \(didlint not reachable/, result.skipped)
    assert_equal "not_evaluated", result.code
  end
end
