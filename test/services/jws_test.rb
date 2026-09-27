require "test_helper"

class JwsTest < ActiveSupport::TestCase
  # RFC 8037, Appendix A.4 (Ed25519) and RFC 7515, Appendix A.3 (ES256).
  RFC8037 = "eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc." \
            "hgyY0il_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_MuM0KAg".freeze
  RFC8037_KEY = { "kty" => "OKP", "crv" => "Ed25519", "x" => "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo" }.freeze
  RFC7515 = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ." \
            "DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q".freeze
  RFC7515_KEY = { "kty" => "EC", "crv" => "P-256", "x" => "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
                  "y" => "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0" }.freeze

  test "RFC 8037 Ed25519 example verifies" do
    jws = Jws.parse(RFC8037)
    assert jws.valid_with?(KeyResolver.from_jwk(RFC8037_KEY))
    assert_nil jws.payload
  end

  test "RFC 7515 ES256 example verifies and carries a JSON payload" do
    jws = Jws.parse(RFC7515)
    assert jws.valid_with?(KeyResolver.from_jwk(RFC7515_KEY))
    assert_equal "joe", jws.payload["iss"]
  end

  test "signature does not verify with the other key" do
    refute Jws.parse(RFC8037).valid_with?(KeyResolver.from_jwk(RFC7515_KEY))
    refute Jws.parse(RFC7515).valid_with?(KeyResolver.from_jwk(RFC8037_KEY))
  end

  test "JSON and other text are not a JWS" do
    assert_nil Jws.parse('{"a":1}')
    assert_nil Jws.parse("a.b")
    assert_nil Jws.parse("not.a.jws!")
  end

  test "unsecured and detached JWS are not supported" do
    refute Jws.parse("#{Base64.urlsafe_encode64('{"alg":"none"}', padding: false)}.e30.").supported?
    refute Jws.parse("#{Base64.urlsafe_encode64('{"alg":"EdDSA","b64":false,"crit":["b64"]}', padding: false)}..AAAA").supported?
  end
end
