require "openssl"

# Finds the public key of a verification method: from a did:key directly, or
# from the DID document resolved by didlint. Supports Ed25519 and P-256 keys as
# publicKeyMultibase (multicodec 0xed / 0x1200) or publicKeyJwk.
class KeyResolver
  ED25519_MULTICODEC = "\xed\x01".b.freeze
  P256_MULTICODEC = "\x80\x24".b.freeze
  ED25519_SPKI_PREFIX = ["302a300506032b6570032100"].pack("H*").freeze

  def initialize(didlint = Didlint.new)
    @didlint = didlint
  end

  # OpenSSL public key for verification method vm of did, or nil.
  # Raises Didlint::Unavailable if the DID document is needed and didlint cannot be reached.
  def key(vm, did)
    return self.class.from_multibase(did.delete_prefix("did:key:")) if did.start_with?("did:key:")

    method = methods(@didlint.resolve!(did), did).find { |m| m[:id] == vm }&.dig(:data)
    return unless method
    return self.class.from_multibase(method["publicKeyMultibase"]) if method["publicKeyMultibase"]

    self.class.from_jwk(method["publicKeyJwk"])
  end

  def self.from_multibase(multibase)
    return unless multibase.is_a?(String) && multibase.start_with?("z")

    bytes = Base58.decode(multibase[1..])
    if bytes.bytesize == 34 && bytes.start_with?(ED25519_MULTICODEC)
      ed25519(bytes[2..])
    elsif bytes.bytesize == 35 && bytes.start_with?(P256_MULTICODEC)
      p256(bytes[2..])
    end
  rescue Base58::Error
    nil
  end

  def self.from_jwk(jwk)
    return unless jwk.is_a?(Hash)

    if jwk["kty"] == "OKP" && jwk["crv"] == "Ed25519"
      raw = Jws.decode(jwk["x"].to_s)
      ed25519(raw) if raw.bytesize == 32
    elsif jwk["kty"] == "EC" && jwk["crv"] == "P-256"
      x = Jws.decode(jwk["x"].to_s)
      y = Jws.decode(jwk["y"].to_s)
      p256("\x04".b + x + y) if x.bytesize == 32 && y.bytesize == 32
    end
  rescue ArgumentError
    nil
  end

  def self.ed25519(raw)
    OpenSSL::PKey.read(ED25519_SPKI_PREFIX + raw)
  rescue OpenSSL::PKey::PKeyError
    nil
  end

  def self.p256(point)
    algorithm = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::ObjectId("id-ecPublicKey"), OpenSSL::ASN1::ObjectId("prime256v1")])
    OpenSSL::PKey.read(OpenSSL::ASN1::Sequence([algorithm, OpenSSL::ASN1::BitString(point)]).to_der)
  rescue OpenSSL::PKey::PKeyError, OpenSSL::ASN1::ASN1Error
    nil
  end

  private

  def methods(doc, did)
    return [] unless doc

    entries = Array(doc["verificationMethod"]) + Array(doc["assertionMethod"]).select { |m| m.is_a?(Hash) }
    entries.filter_map do |m|
      next unless m.is_a?(Hash) && m["id"].is_a?(String)

      { id: m["id"].start_with?("#") ? "#{did}#{m['id']}" : m["id"], data: m }
    end
  end
end
