require "openssl"

# Runs a criterion with check.type proof (DPP-SEC-002): integrity proofs of the
# passport are verified against a key of the DID found at check.key_from (the
# economic operator).
#
# Supported formats:
# - vc-data-integrity: W3C Data Integrity proofs (member "proof") with the
#   cryptosuite eddsa-jcs-2022;
# - vc-jose-cose: the passport as compact JWS (application/vc+jwt), signed
#   with EdDSA or ES256, whose header kid names the key. If the passport was
#   also delivered as plain JSON, the JWS payload has to be the same passport.
# Passports without a proof, and proofs in formats this version does not
# verify, are skipped. Keys come from did:key directly or from the DID
# document resolved by didlint.
class ProofCheck
  Outcome = Struct.new(:skipped, :messages, keyword_init: true)

  CRYPTOSUITES = %w[eddsa-jcs-2022].freeze
  CHECKED_FORMATS = %w[vc-data-integrity vc-jose-cose].freeze

  # passport: the passport as JSON; jws: a Jws of the passport, if one was delivered;
  # jws_only: true if the passport is the JWS payload (nothing to compare it with).
  def initialize(check, passport, jws: nil, jws_only: false, didlint: Didlint.new)
    @check = check
    @passport = passport
    @jws = jws
    @jws_only = jws_only
    @keys = KeyResolver.new(didlint)
  end

  def outcome
    return skip(no_proof_reason) unless @passport.key?("proof") || @jws

    operator = @passport[@check["key_from"].to_s.delete_prefix("$.")]
    return skip("#{@check['key_from']} is not a DID, so the key of the economic operator cannot be determined") unless did?(operator)

    @messages = []
    @verified = 0
    @unsupported = []
    data_integrity(operator) if @passport.key?("proof")
    jose(operator) if @jws

    if @messages.empty? && @verified.zero?
      return skip("proof format #{@unsupported.uniq.join(', ')} is not verified in this version " \
                  "(supported: DataIntegrityProof #{CRYPTOSUITES.join(', ')}; JWS #{Jws::ALGORITHMS.join(', ')})")
    end

    Outcome.new(messages: @messages)
  end

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
    key.oid == "ED25519" && key.verify(nil, signature, data)
  rescue OpenSSL::PKey::PKeyError, ArgumentError
    false
  end

  private

  def no_proof_reason
    others = Array(@check["formats"]) - CHECKED_FORMATS
    reason = "passport carries no integrity proof (neither a Data Integrity proof nor a JWS)"
    others.any? ? "#{reason}; #{others.join(', ')} not checked in this version" : reason
  end

  def data_integrity(operator)
    proofs = @passport["proof"].is_a?(Array) ? @passport["proof"] : [@passport["proof"]]
    proofs.each do |proof|
      next @messages << violation("proof is not a JSON object") unless proof.is_a?(Hash)
      if proof["type"] != "DataIntegrityProof" || !CRYPTOSUITES.include?(proof["cryptosuite"])
        next @unsupported << [proof["type"], proof["cryptosuite"]].compact.join(" ")
      end

      record(verify_data_integrity(proof, operator))
    end
  end

  def verify_data_integrity(proof, operator)
    vm = proof["verificationMethod"]
    vm = vm["id"] if vm.is_a?(Hash)
    return [violation("proof has no verificationMethod")] unless vm.is_a?(String)

    key, problem = operator_key(vm, operator, "proof")
    return [problem] if problem

    signature = decode_multibase(proof["proofValue"])
    return [violation("proofValue is not a multibase base58btc value")] unless signature

    out = []
    unless self.class.eddsa_jcs_valid?(@passport, proof, key, signature)
      out << violation("signature of the #{proof['cryptosuite']} proof by #{vm} does not verify: the passport content does not match the signed content")
    end
    if proof["proofPurpose"] != "assertionMethod"
      out << warning("proofPurpose is #{proof['proofPurpose'].inspect}, expected \"assertionMethod\"")
    end
    out
  end

  def jose(operator)
    return @unsupported << "JWS #{@jws.alg}" unless @jws.supported?

    record(verify_jws(operator))
  end

  def verify_jws(operator)
    kid = @jws.header["kid"]
    return [violation("JWS header has no kid, so the signing key cannot be determined")] unless kid.is_a?(String) && kid.present?

    vm = kid.start_with?("#") ? "#{operator}#{kid}" : kid
    key, problem = operator_key(vm, operator, "JWS")
    return [problem] if problem
    return [violation("JWS signature (#{@jws.alg}) by #{vm} does not verify")] unless @jws.valid_with?(key)
    return [violation("JWS payload is not a JSON object")] unless @jws.payload.is_a?(Hash)
    return [] if @jws_only || Jcs.dump(@jws.payload) == Jcs.dump(@passport.except("proof"))

    [violation("JWS payload differs from the passport delivered as JSON")]
  end

  def operator_key(vm, operator, what)
    unless vm.split("#").first == operator
      return [nil, violation("#{what} is signed with #{vm}, not with a key of the economic operator #{operator}")]
    end

    key = @keys.key(vm, operator)
    key ? [key, nil] : [nil, violation("verification method #{vm} is not an Ed25519 or P-256 key in the DID document of #{operator}")]
  end

  def record(messages)
    @messages.concat(messages)
    @verified += 1 if messages.none? { |m| m[:severity] == "violation" }
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
