require "openssl"

# Runs a criterion with check.type proof (DPP-SEC-002): an integrity proof
# carried by the passport is verified against a key of the DID found at
# check.key_from (the economic operator).
#
# Supported: W3C Data Integrity proofs (member "proof") with the cryptosuite
# eddsa-jcs-2022. Passports without a proof, and proofs in formats this
# version does not verify, are skipped. Keys come from did:key directly or
# from the DID document resolved by didlint.
class ProofCheck
  Outcome = Struct.new(:skipped, :messages, keyword_init: true)

  CRYPTOSUITES = %w[eddsa-jcs-2022].freeze
  ED25519_MULTICODEC = "\xed\x01".b.freeze
  ED25519_SPKI_PREFIX = ["302a300506032b6570032100"].pack("H*").freeze

  def initialize(check, passport, didlint: Didlint.new)
    @check = check
    @passport = passport
    @didlint = didlint
  end

  def outcome
    return skip(no_proof_reason) unless @passport.key?("proof")

    operator = @passport[@check["key_from"].to_s.delete_prefix("$.")]
    return skip("#{@check['key_from']} is not a DID, so the key of the economic operator cannot be determined") unless did?(operator)

    proofs = @passport["proof"].is_a?(Array) ? @passport["proof"] : [@passport["proof"]]
    messages = []
    verified = 0
    unsupported = []
    proofs.each do |proof|
      unless proof.is_a?(Hash)
        messages << violation("proof is not a JSON object")
        next
      end
      if proof["type"] != "DataIntegrityProof" || !CRYPTOSUITES.include?(proof["cryptosuite"])
        unsupported << [proof["type"], proof["cryptosuite"]].compact.join(" ")
        next
      end
      result = verify(proof, operator)
      messages.concat(result)
      verified += 1 if result.none? { |m| m[:severity] == "violation" }
    end

    if messages.empty? && verified.zero?
      return skip("proof format #{unsupported.uniq.join(', ')} is not verified in this version (supported: DataIntegrityProof #{CRYPTOSUITES.join(', ')})")
    end

    Outcome.new(messages: messages)
  end

  private

  def no_proof_reason
    others = Array(@check["formats"]) - ["vc-data-integrity"]
    reason = "passport carries no integrity proof"
    others.any? ? "#{reason} (#{others.join(', ')} not checked in this version)" : reason
  end

  def verify(proof, operator)
    vm = proof["verificationMethod"]
    vm = vm["id"] if vm.is_a?(Hash)
    return [violation("proof has no verificationMethod")] unless vm.is_a?(String)
    unless vm.split("#").first == operator
      return [violation("proof is signed with #{vm}, not with a key of the economic operator #{operator}")]
    end

    key = public_key(vm, operator)
    return [violation("verification method #{vm} is not an Ed25519 key in the DID document of #{operator}")] unless key

    signature = decode_multibase(proof["proofValue"])
    return [violation("proofValue is not a multibase base58btc value")] unless signature

    out = []
    unless valid_signature?(key, signature, proof)
      out << violation("signature of the #{proof['cryptosuite']} proof by #{vm} does not verify: the passport content does not match the signed content")
    end
    if proof["proofPurpose"] != "assertionMethod"
      out << warning("proofPurpose is #{proof['proofPurpose'].inspect}, expected \"assertionMethod\"")
    end
    out
  end

  def valid_signature?(key, signature, proof) = self.class.eddsa_jcs_valid?(@passport, proof, key, signature)

  # eddsa-jcs-2022: SHA-256 of the canonical proof options, followed by
  # SHA-256 of the canonical document without its proof, signed with Ed25519.
  def self.eddsa_jcs_valid?(secured, proof, key, signature)
    options = proof.except("proofValue")
    document = secured.except("proof")
    if options.key?("@context")
      return false unless Array(document["@context"]).first(Array(options["@context"]).size) == Array(options["@context"])

      document = document.merge("@context" => options["@context"])
    end
    data = Digest::SHA256.digest(Jcs.dump(options)) + Digest::SHA256.digest(Jcs.dump(document))
    key.verify(nil, signature, data)
  rescue OpenSSL::PKey::PKeyError, ArgumentError
    false
  end

  # OpenSSL public key for a multibase Ed25519 key (z6Mk...), or nil.
  def self.ed25519_key(multibase)
    bytes = multibase.is_a?(String) && multibase.start_with?("z") ? Base58.decode(multibase[1..]) : nil
    return unless bytes&.bytesize == 34 && bytes.start_with?(ED25519_MULTICODEC)

    OpenSSL::PKey.read(ED25519_SPKI_PREFIX + bytes[2..])
  rescue Base58::Error, OpenSSL::PKey::PKeyError
    nil
  end

  def public_key(vm, did)
    return self.class.ed25519_key(did.delete_prefix("did:key:")) if did.start_with?("did:key:")

    method = verification_methods(@didlint.resolve!(did), did).find { |m| m[:id] == vm }&.dig(:data)
    return unless method
    return self.class.ed25519_key(method["publicKeyMultibase"]) if method["publicKeyMultibase"]

    jwk = method["publicKeyJwk"]
    return unless jwk.is_a?(Hash) && jwk["kty"] == "OKP" && jwk["crv"] == "Ed25519"

    raw = Base64.urlsafe_decode64(jwk["x"].to_s)
    OpenSSL::PKey.read(ED25519_SPKI_PREFIX + raw) if raw.bytesize == 32
  rescue ArgumentError, OpenSSL::PKey::PKeyError
    nil
  end

  def verification_methods(doc, did)
    return [] unless doc

    entries = Array(doc["verificationMethod"]) + Array(doc["assertionMethod"]).select { |m| m.is_a?(Hash) }
    entries.filter_map do |m|
      next unless m.is_a?(Hash) && m["id"].is_a?(String)

      { id: m["id"].start_with?("#") ? "#{did}#{m['id']}" : m["id"], data: m }
    end
  end

  def decode_multibase(value)
    return unless value.is_a?(String) && value.start_with?("z")

    Base58.decode(value[1..])
  rescue Base58::Error
    nil
  end

  def did?(value) = value.is_a?(String) && value.match?(/\Adid:[a-z0-9]+:.+/)
  def skip(reason) = Outcome.new(skipped: reason)
  def violation(message) = { severity: "violation", message: message }
  def warning(message) = { severity: "warning", message: message }
end
