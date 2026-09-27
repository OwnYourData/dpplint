# Signs passports for tests of DPP-SEC-002: as eddsa-jcs-2022 Data Integrity
# proofs and as compact JWS (EdDSA or ES256).
module SigningHelper
  def signing_key = @signing_key ||= OpenSSL::PKey.generate_key("ED25519")

  def key_multibase(key = signing_key)
    if key.is_a?(OpenSSL::PKey::EC)
      "z#{Base58.encode(KeyResolver::P256_MULTICODEC + key.public_key.to_octet_string(:compressed))}"
    else
      "z#{Base58.encode(KeyResolver::ED25519_MULTICODEC + key.public_to_der[-32..])}"
    end
  end

  def did_key(key = signing_key) = "did:key:#{key_multibase(key)}"

  def sign(passport, verification_method:, key: signing_key, purpose: "assertionMethod")
    proof = { "type" => "DataIntegrityProof", "cryptosuite" => "eddsa-jcs-2022", "created" => "2026-09-27T10:00:00Z",
              "verificationMethod" => verification_method, "proofPurpose" => purpose }
    data = Digest::SHA256.digest(Jcs.dump(proof)) + Digest::SHA256.digest(Jcs.dump(passport))
    passport.merge("proof" => proof.merge("proofValue" => "z#{Base58.encode(key.sign(nil, data))}"))
  end

  def b64url(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

  def sign_jws(passport, kid:, key: signing_key)
    alg = key.is_a?(OpenSSL::PKey::EC) ? "ES256" : "EdDSA"
    input = "#{b64url({ 'alg' => alg, 'kid' => kid, 'typ' => 'vc+jwt' }.to_json)}.#{b64url(passport.to_json)}"
    signature = if alg == "ES256"
                  OpenSSL::ASN1.decode(key.sign("SHA256", input)).value.map { |i| i.value.to_s(2).rjust(32, "\x00".b) }.join
                else
                  key.sign(nil, input)
                end
    "#{input}.#{b64url(signature)}"
  end
end
