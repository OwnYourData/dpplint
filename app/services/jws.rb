require "openssl"

# Compact JWS (RFC 7515), the JOSE serialisation of VC-JOSE-COSE
# (application/vc+jwt). Supported algorithms: EdDSA (Ed25519) and ES256.
class Jws
  MEDIA_TYPES = %w[application/vc+jwt application/jwt application/jose].freeze
  ACCEPT = "application/vc+jwt, application/jwt;q=0.9, application/jose;q=0.8".freeze
  ALGORITHMS = %w[EdDSA Ed25519 ES256].freeze

  attr_reader :compact, :header, :payload, :signature, :signing_input

  # A Jws, or nil if text is not a compact JWS with a JSON header.
  def self.parse(text)
    compact = text.to_s.strip
    parts = compact.split(".", -1)
    return unless parts.size == 3 && parts.all? { |p| p.match?(/\A[A-Za-z0-9_-]*\z/) } && parts[0].present?

    header = JSON.parse(decode(parts[0]))
    return unless header.is_a?(Hash)

    payload = begin
      JSON.parse(decode(parts[1]))
    rescue JSON::ParserError
      nil
    end
    new(compact, header, payload, decode(parts[2]), "#{parts[0]}.#{parts[1]}")
  rescue ArgumentError, JSON::ParserError
    nil
  end

  def self.decode(part) = Base64.urlsafe_decode64(part + ("=" * ((4 - (part.length % 4)) % 4)))

  def initialize(compact, header, payload, signature, signing_input)
    @compact = compact
    @header = header
    @payload = payload
    @signature = signature
    @signing_input = signing_input
  end

  def alg = header["alg"]
  def supported? = ALGORITHMS.include?(alg) && header["b64"] != false && header["crit"].nil?

  # Whether the signature verifies with the OpenSSL public key.
  def valid_with?(key)
    case alg
    when "EdDSA", "Ed25519"
      key.oid == "ED25519" && key.verify(nil, signature, signing_input)
    when "ES256"
      key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name == "prime256v1" && signature.bytesize == 64 &&
        key.verify("SHA256", der_signature, signing_input)
    else false
    end
  rescue OpenSSL::PKey::PKeyError
    false
  end

  private

  # JWS carries r || s; OpenSSL expects an ASN.1 sequence of two integers.
  def der_signature
    r, s = signature.unpack("a32a32").map { |b| OpenSSL::BN.new(b, 2) }
    OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(r), OpenSSL::ASN1::Integer(s)]).to_der
  end
end
