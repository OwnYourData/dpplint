require "openssl"

# Runs criteria with check.type proof.
#
# Without check.key_from (DPP-SEC-002): the integrity of the passport has to be
# verifiable with at least one of check.formats; every proof found is verified
# with the key it names.
# With check.key_from (DPP-SEC-013): at least one verified proof has to be
# issued by the DID at key_from (the economic operator); otherwise a warning.
#
# Formats:
# - vc-data-integrity: W3C Data Integrity proofs (member "proof") with the
#   cryptosuite eddsa-jcs-2022; key from verificationMethod;
# - vc-jose-cose: the passport as compact JWS (application/vc+jwt), signed
#   with EdDSA or ES256; key from the header kid. If the passport was also
#   delivered as plain JSON, the JWS payload has to be the same passport;
# - did-oyd-log: the DID document of digitalProductPassportId (did:oyd,
#   resolved by didlint, current version) carries in its service of type
#   DigitalProductPassport a payloadHash: SHA-256 multihash (base58btc) of the
#   passport bytes as delivered by that service's serviceEndpoint in the full
#   representation (the serviceEndpoint is requested with
#   representation=full, EN 18222 8.1; without it an EN 18222 service answers
#   in the compressed representation). The bytes delivered for the product
#   identifier have to be the same. The attestation is made with the key of
#   the passport DID.
# Passports without a proof, and proofs in formats this version does not
# verify, are skipped. Keys come from did:key directly or from the DID
# document resolved by didlint. A skip carries a reason_code ("Results" in
# CRITERIA-FORMAT.md): no_evidence if the passport offers nothing to verify,
# not_evaluated if a proof or DID could not be checked by this version,
# not_applicable if key_from is not a DID.
class ProofCheck
  Outcome = Struct.new(:skipped, :code, :messages, keyword_init: true)
  # One proof found in the passport: format, DID of the signer, and the
  # messages of its verification (none with severity violation = verified).
  Proof = Struct.new(:format, :signer, :messages, keyword_init: true) do
    def verified? = messages.none? { |m| m[:severity] == "violation" }
  end

  CRYPTOSUITES = %w[eddsa-jcs-2022].freeze
  PASSPORT_SERVICE = "DigitalProductPassport".freeze

  # passport: the passport as JSON; raw: its bytes as delivered for the product
  # identifier (nil for POST); jws: a Jws of the passport, if one was delivered;
  # jws_only: true if the passport is the JWS payload (nothing to compare it with).
  def initialize(check, passport, raw: nil, jws: nil, jws_only: false, didlint: Didlint.new, resolver: HttpResolver.new)
    @check = check
    @passport = passport
    @raw = raw
    @jws = jws
    @jws_only = jws_only
    @didlint = didlint
    @resolver = resolver
    @keys = KeyResolver.new(didlint)
  end

  def outcome
    analyse
    @check["key_from"] ? issuer_outcome : integrity_outcome
  end

  # SHA-256 multihash, base58btc with prefix z (zQm...).
  def self.multihash(bytes) = "z#{Base58.encode("\x12\x20".b + Digest::SHA256.digest(bytes.to_s.b))}"

  # The serviceEndpoint with the query flag representation=full (EN 18222
  # 8.1), added to an existing query; an existing representation parameter is
  # replaced. Services that do not know the flag ignore it.
  def self.full_representation(url)
    uri = URI.parse(url)
    params = URI.decode_www_form(uri.query.to_s).reject { |k, _| k == "representation" }
    uri.query = URI.encode_www_form(params + [%w[representation full]])
    uri.to_s
  rescue URI::InvalidURIError
    url
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

  def formats = Array(@check["formats"])

  def analyse
    @proofs = []
    @unsupported = []
    @notes = []
    data_integrity if formats.include?("vc-data-integrity") && @passport.key?("proof")
    jose if formats.include?("vc-jose-cose") && @jws
    oyd_log if formats.include?("did-oyd-log")
  end

  def integrity_outcome
    return skip(skip_reason) if @proofs.empty?

    Outcome.new(messages: @proofs.flat_map(&:messages))
  end

  def issuer_outcome
    verified = @proofs.select(&:verified?)
    if verified.empty?
      return skip("no verified integrity proof (#{skip_reason.presence || 'see the integrity check'})", @proofs.empty? ? skip_code : "no_evidence")
    end

    operator = @passport[@check["key_from"].delete_prefix("$.")]
    unless did?(operator)
      return skip("#{@check['key_from']} is not a DID, so the issuer of the proof cannot be compared with it", "not_applicable")
    end
    return Outcome.new(messages: []) if verified.any? { |p| p.signer == operator }

    Outcome.new(messages: verified.map { |p| warning(issuer_message(p, operator)) })
  end

  def issuer_message(proof, operator)
    if proof.format == "did-oyd-log"
      "the content is attested with the key of the passport DID #{proof.signer}, which is not linked to the economic operator #{operator}"
    else
      "the #{proof.format} proof is signed by #{proof.signer}, not by the economic operator #{operator}; an authorised representative cannot be recognised automatically"
    end
  end

  def skip_reason
    reasons = []
    unless @passport.key?("proof") || @jws || @notes.any? { |n| n.start_with?("the DID document") }
      reasons << "passport carries no integrity proof (no Data Integrity proof, no JWS, no payloadHash for the passport DID)"
    end
    if @unsupported.any?
      reasons << "proof format #{@unsupported.uniq.join(', ')} is not verified in this version " \
                 "(supported: DataIntegrityProof #{CRYPTOSUITES.join(', ')}; JWS #{Jws::ALGORITHMS.join(', ')}; did-oyd-log)"
    end
    (reasons + @notes).join("; ")
  end

  # --- vc-data-integrity ---

  def data_integrity
    proofs = @passport["proof"].is_a?(Array) ? @passport["proof"] : [@passport["proof"]]
    proofs.each do |proof|
      next add("vc-data-integrity", nil, [violation("proof is not a JSON object")]) unless proof.is_a?(Hash)
      if proof["type"] != "DataIntegrityProof" || !CRYPTOSUITES.include?(proof["cryptosuite"])
        next @unsupported << [proof["type"], proof["cryptosuite"]].compact.join(" ")
      end

      vm = proof["verificationMethod"]
      vm = vm["id"] if vm.is_a?(Hash)
      add("vc-data-integrity", vm.is_a?(String) ? vm.split("#").first : nil, verify_data_integrity(proof, vm))
    end
  end

  def verify_data_integrity(proof, vm)
    return [violation("proof has no verificationMethod")] unless vm.is_a?(String) && did?(vm)

    key = @keys.key(vm, vm.split("#").first)
    return [violation("verification method #{vm} is not an Ed25519 or P-256 key that can be resolved")] unless key

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

  # --- vc-jose-cose ---

  def jose
    return @unsupported << "JWS #{@jws.alg}" unless @jws.supported?

    kid = @jws.header["kid"]
    vm = kid.is_a?(String) && kid.start_with?("#") && did?(@jws.header["iss"]) ? "#{@jws.header['iss']}#{kid}" : kid
    add("vc-jose-cose", vm.is_a?(String) ? vm.split("#").first : nil, verify_jws(vm))
  end

  def verify_jws(vm)
    return [violation("JWS header has no kid with a DID URL, so the signing key cannot be determined")] unless vm.is_a?(String) && did?(vm)

    key = @keys.key(vm, vm.split("#").first)
    return [violation("verification method #{vm} is not an Ed25519 or P-256 key that can be resolved")] unless key
    return [violation("JWS signature (#{@jws.alg}) by #{vm} does not verify")] unless @jws.valid_with?(key)
    return [violation("JWS payload is not a JSON object")] unless @jws.payload.is_a?(Hash)
    return [] if @jws_only || Jcs.dump(@jws.payload) == Jcs.dump(@passport.except("proof"))

    [violation("JWS payload differs from the passport delivered as JSON")]
  end

  # --- did-oyd-log ---

  def oyd_log
    did = @passport["digitalProductPassportId"]
    return unless did.is_a?(String) && did.start_with?("did:oyd:")

    doc = @didlint.resolve!(did)
    return @notes << "#{did} cannot be resolved, so did-oyd-log is not checked" unless doc

    service = Array(doc["service"]).find { |s| s.is_a?(Hash) && Array(s["type"]).include?(PASSPORT_SERVICE) }
    expected = service && service["payloadHash"]
    unless expected.is_a?(String)
      return @notes << "the DID document of #{did} binds only the location of the passport, not its content (no payloadHash)"
    end

    add("did-oyd-log", did, compare_payload(expected, service["serviceEndpoint"]))
  rescue Didlint::Unavailable => e
    @notes << "did-oyd-log not checked (#{e.message})"
  end

  def compare_payload(expected, endpoint)
    attested = endpoint.is_a?(String) ? @resolver.get(self.class.full_representation(endpoint)) : nil
    unless attested&.success?
      problem = attested ? (attested.error || "HTTP #{attested.status}") : "no serviceEndpoint"
      return [] if @raw && self.class.multihash(@raw) == expected

      return [violation("attested passport at the serviceEndpoint cannot be retrieved (#{problem}), so payloadHash #{expected} cannot be compared")]
    end

    actual = self.class.multihash(attested.body)
    return [violation("passport at the serviceEndpoint #{endpoint} does not match payloadHash #{expected} of the passport DID (SHA-256 is #{actual})")] if actual != expected
    return (same_content?(attested.body) ? [] : [violation("passport sent for checking differs from the passport attested by payloadHash #{expected}")]) unless @raw
    return [] if self.class.multihash(@raw) == expected

    if same_content?(attested.body)
      [warning("passport delivered for the product identifier has the attested content but not the attested bytes, so payloadHash cannot be checked on it directly")]
    else
      [violation("passport delivered for the product identifier differs from the passport attested by payloadHash #{expected}")]
    end
  end

  def same_content?(body)
    JSON.parse(body) == @passport
  rescue JSON::ParserError
    false
  end

  # --- helpers ---

  def add(format, signer, messages) = @proofs << Proof.new(format: format, signer: signer, messages: messages)

  def decode_multibase(value)
    return unless value.is_a?(String) && value.start_with?("z")

    Base58.decode(value[1..])
  rescue Base58::Error
    nil
  end

  def did?(value) = value.is_a?(String) && value.match?(/\Adid:[a-z0-9]+:.+/)
  def skip(reason, code = skip_code) = Outcome.new(skipped: reason, code: code)

  # not_evaluated if a proof format is not verified in this version or a DID
  # or did-oyd-log could not be checked; otherwise no_evidence (no proof, or
  # a DID document without payloadHash).
  def skip_code
    unchecked = @notes.reject { |n| n.include?("binds only the location of the passport") }
    @unsupported.any? || unchecked.any? ? "not_evaluated" : "no_evidence"
  end
  def violation(message) = { severity: "violation", message: message }
  def warning(message) = { severity: "warning", message: message }
end
