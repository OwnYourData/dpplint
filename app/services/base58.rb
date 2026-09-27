# Base58 (Bitcoin alphabet), as used by multibase "z" values in DID documents
# and Data Integrity proofs.
module Base58
  ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".freeze
  INDEX = ALPHABET.each_char.with_index.to_h.freeze

  class Error < StandardError; end

  def self.decode(string)
    number = string.each_char.reduce(0) do |acc, ch|
      digit = INDEX[ch] or raise Error, "invalid base58 character #{ch.inspect}"
      acc * 58 + digit
    end
    hex = number.zero? ? "" : number.to_s(16)
    hex = "0#{hex}" if hex.length.odd?
    ("\x00" * string[/\A1*/].length + [hex].pack("H*")).b
  end

  def self.encode(bytes)
    bytes = bytes.b
    number = bytes.unpack1("H*").then { |h| h.empty? ? 0 : h.to_i(16) }
    out = +""
    while number.positive?
      number, rem = number.divmod(58)
      out << ALPHABET[rem]
    end
    ("1" * bytes[/\A\x00*/n].length) + out.reverse
  end
end
