# Signs passports with a fresh Ed25519 key as eddsa-jcs-2022 Data Integrity
# proofs, for tests of DPP-SEC-002.
module SigningHelper
  def signing_key = @signing_key ||= OpenSSL::PKey.generate_key("ED25519")

  def key_multibase(key = signing_key) = "z#{Base58.encode(ProofCheck::ED25519_MULTICODEC + key.public_to_der[-32..])}"

  def did_key(key = signing_key) = "did:key:#{key_multibase(key)}"

  def sign(passport, verification_method:, key: signing_key, purpose: "assertionMethod")
    proof = { "type" => "DataIntegrityProof", "cryptosuite" => "eddsa-jcs-2022", "created" => "2026-09-27T10:00:00Z",
              "verificationMethod" => verification_method, "proofPurpose" => purpose }
    data = Digest::SHA256.digest(Jcs.dump(proof)) + Digest::SHA256.digest(Jcs.dump(passport))
    passport.merge("proof" => proof.merge("proofValue" => "z#{Base58.encode(key.sign(nil, data))}"))
  end
end
