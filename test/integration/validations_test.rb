require "test_helper"

class ValidationsTest < ActionDispatch::IntegrationTest
  include SigningHelper
  wait_for_web_cli

  def reference
    JSON.parse(file_fixture("reference-passport.json").read)
  end

  def lint(passport)
    post "/api/v1/validate", params: passport.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :success
    JSON.parse(response.body)
  end

  def lint_text(text)
    post "/api/v1/validate", params: text, headers: { "Content-Type" => "application/json" }
    assert_response :success
    JSON.parse(response.body)
  end

  def criterion(result, id) = result["criteria"].find { |c| c["id"] == id }

  test "reference passport passes all structure checks" do
    result = lint(reference)
    %w[DPP-DAT-014 DPP-INT-005 DPP-ROL-016 DPP-DAT-015 DPP-CFG-005].each do |id|
      assert_equal "passed", criterion(result, id)["result"], id
    end
    assert_equal 0, result["summary"]["failed"]
    assert_match(/\A\d+ of \d+ automated checks passed\z/, result["summary"]["text"])
    assert_kind_of Array, result["notices"]
  end

  test "missing economic operator fails the header and responsibility checks" do
    result = lint(reference.except("economicOperatorId"))
    assert_equal "failed", criterion(result, "DPP-DAT-014")["result"]
    assert_equal "failed", criterion(result, "DPP-ROL-016")["result"]
    assert_equal "skipped", criterion(result, "DPP-ID-009")["result"]
  end

  test "capitalised granularity gives a warning" do
    result = lint(reference.merge("granularity" => "Item"))
    assert_equal "warning", criterion(result, "DPP-DAT-015")["result"]
  end

  test "GTIN with the GS1 prefix 952 for examples gives a warning on the product identifier scheme" do
    result = criterion(lint(reference), "DPP-CAR-002")
    assert_equal "warning", result["result"]
    assert_equal ["warning"], result["messages"].map { |m| m["severity"] }
    assert_match(/\AThe GTIN of the GS1 Digital Link carries the GS1 prefix 952,/, result["messages"].first["message"])
    passport = reference.merge("uniqueProductIdentifier" => "https://dpp.example.org/01/00000095212340/21/000001")
    assert_equal "warning", criterion(lint(passport), "DPP-CAR-002")["result"], "GTIN-8 with the GS1-8 prefix 952, padded to 14 digits"
  end

  test "GTIN with another prefix passes the product identifier scheme without a warning" do
    passport = reference.merge("uniqueProductIdentifier" => "https://dpp.example.org/01/04012345000016/21/000001")
    assert_equal "passed", criterion(lint(passport), "DPP-CAR-002")["result"]
    passport = reference.merge("uniqueProductIdentifier" => "https://dpp.example.org/01/95201234567897/21/000001")
    assert_equal "passed", criterion(lint(passport), "DPP-CAR-002")["result"], "prefix 520 after the indicator digit 9"
  end

  test "product identifier in the form the EU DPP registry accepts" do
    assert_equal "passed", criterion(lint(reference), "DPP-REG-024")["result"]
    result = criterion(lint(reference.merge("uniqueProductIdentifier" => "did:web:dpp.example.org:product:4711")), "DPP-REG-024")
    assert_equal "failed", result["result"]
    assert_match(/2000 characters/, result["messages"].first["message"])
    long = "https://dpp.example.org/01/04012345000016/21/#{'1' * 2000}"
    assert_equal "failed", criterion(lint(reference.merge("uniqueProductIdentifier" => long)), "DPP-REG-024")["result"]
  end

  test "value data type that EN 18223 excludes fails" do
    assert_equal "passed", criterion(lint(reference), "DPP-DAT-026")["result"]
    passport = reference
    passport["elements"][0]["elements"][0]["valueDataType"] = "xsd:token"
    result = criterion(lint(passport), "DPP-DAT-026")
    assert_equal "failed", result["result"]
    assert_match(/derived from string/, result["messages"].first["message"])
  end

  test "identifiers outside ISO/IEC 646 or the URI syntax fail" do
    assert_equal "passed", criterion(lint(reference), "DPP-ID-015")["result"]
    passport = reference.merge("uniqueProductIdentifier" => "https://dpp.example.org/01/04012345000016/21/\u00c41")
    assert_equal "failed", criterion(lint(passport), "DPP-ID-015")["result"], "non-ASCII character"
    passport = reference.merge("economicOperatorId" => "did:web:example.org:operator 1")
    assert_equal "failed", criterion(lint(passport), "DPP-ID-015")["result"], "space in a URI"
    passport = reference.merge("uniqueProductIdentifier" => "https://dpp.example.org/01/04012345000016/21/A%C3%841")
    assert_equal "passed", criterion(lint(passport), "DPP-ID-015")["result"], "percent-encoded"
  end

  test "product DID with another method than did:web, did:ethr or did:ebsi gives a warning" do
    assert_equal "skipped", criterion(lint(reference), "DPP-ID-054")["result"], "product identifier is no DID"
    result = criterion(lint(reference.merge("uniqueProductIdentifier" => "did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK")), "DPP-ID-054")
    assert_equal "warning", result["result"]
    assert_match(/did:web, did:ethr or did:ebsi/, result["messages"].first["message"])
    assert_equal "passed", criterion(lint(reference.merge("uniqueProductIdentifier" => "did:web:dpp.example.org:product:4711")), "DPP-ID-054")["result"]
  end

  test "elementIds of the reference passport are unique at each level and in the whole passport" do
    result = lint(reference)
    assert_equal "passed", criterion(result, "DPP-DAT-017")["result"]
    assert_equal "passed", criterion(result, "DPP-DAT-021")["result"]
  end

  test "an elementId repeated within a collection fails, one used in two collections gives a warning" do
    passport = reference
    collection = passport["elements"].first
    collection["elements"] << collection["elements"].first.merge("value" => "other")
    result = lint(passport)
    assert_equal "failed", criterion(result, "DPP-DAT-017")["result"]
    assert_match(/ModelIdentifier 2 times in ProductIdentification/, criterion(result, "DPP-DAT-017")["messages"].first["message"])

    passport = reference
    passport["elements"].last["elements"] << passport["elements"].first["elements"].first
    result = lint(passport)
    assert_equal "passed", criterion(result, "DPP-DAT-017")["result"]
    assert_equal "warning", criterion(result, "DPP-DAT-021")["result"]
  end

  test "a compressed passport posted with a repeated member name fails DPP-DAT-017" do
    result = lint_text(file_fixture("element_ids/DPP-DAT-017/invalid/compressed-repeated-member.json").read)
    assert_equal "failed", criterion(result, "DPP-DAT-017")["result"]
    assert_equal %w[skipped not_evaluated], criterion(result, "DPP-DAT-021").values_at("result", "reason_code")
  end

  test "optional facility identifier is skipped when absent" do
    assert_equal "skipped", criterion(lint(reference), "DPP-ID-010")["result"]
  end

  test "checks that request the product identifier need one" do
    result = lint(reference)
    %w[DPP-ID-001 DPP-ID-013 DPP-DAT-003 DPP-DAT-016 DPP-DAT-020 DPP-SEC-014 DPP-SEC-020 DPP-SEC-021].each do |id|
      assert_equal "skipped", criterion(result, id)["result"], id
    end
    assert_equal "rated by dpp-validator from its daily runs", criterion(result, "DPP-ID-002")["reason"]
    assert_equal "not_evaluated", criterion(result, "DPP-ID-002")["reason_code"]
  end

  test "DID check is skipped when didlint cannot be reached" do
    result = criterion(lint(reference), "DPP-ID-016")
    assert_equal "skipped", result["result"]
    assert_match(/didlint not reachable/, result["reason"])
  end

  test "passport without proof or related resources skips both checks" do
    result = lint(reference)
    assert_match(/carries no integrity proof/, criterion(result, "DPP-SEC-002")["reason"])
    # didlint is not reachable in the tests, so did-oyd-log of the passport DID
    # cannot be checked: not_evaluated. With a reachable didlint and no
    # payloadHash the code is no_evidence (unit tests of ProofCheck).
    assert_match(/did-oyd-log not checked/, criterion(result, "DPP-SEC-002")["reason"])
    assert_equal "not_evaluated", criterion(result, "DPP-SEC-002")["reason_code"]
    assert_equal "no RelatedResource elements", criterion(result, "DPP-DAT-011")["reason"]
    assert_equal "not_applicable", criterion(result, "DPP-DAT-011")["reason_code"]
  end

  test "passport signed by its economic operator passes the integrity and issuer checks" do
    passport = reference.merge("economicOperatorId" => did_key)
    signed = lint(sign(passport, verification_method: "#{did_key}##{key_multibase}"))
    assert_equal "passed", criterion(signed, "DPP-SEC-002")["result"]
    assert_equal "passed", criterion(signed, "DPP-SEC-013")["result"]
    changed = lint(sign(passport, verification_method: "#{did_key}##{key_multibase}").merge("dppStatus" => "Inactive"))
    assert_equal "failed", criterion(changed, "DPP-SEC-002")["result"]
    assert_equal "skipped", criterion(changed, "DPP-SEC-013")["result"]
  end

  test "passport signed by another key passes the integrity check with a warning on the issuer" do
    other = OpenSSL::PKey.generate_key("ED25519")
    passport = reference.merge("economicOperatorId" => did_key)
    result = lint(sign(passport, verification_method: "#{did_key(other)}##{key_multibase(other)}", key: other))
    assert_equal "passed", criterion(result, "DPP-SEC-002")["result"]
    assert_equal "warning", criterion(result, "DPP-SEC-013")["result"]
  end

  test "passport posted as JWS is checked and its signature verified" do
    passport = reference.merge("economicOperatorId" => did_key)
    jws = sign_jws(passport, kid: "#{did_key}##{key_multibase}")
    post "/api/v1/validate", params: jws, headers: { "Content-Type" => "application/vc+jwt" }
    assert_response :success
    result = JSON.parse(response.body)
    assert_equal "passed", criterion(result, "DPP-SEC-002")["result"]
    assert_equal "passed", criterion(result, "DPP-DAT-014")["result"]
  end

  test "body that is not a JWS is rejected" do
    post "/api/v1/validate", params: "{}", headers: { "Content-Type" => "application/vc+jwt" }
    assert_response :unprocessable_entity
  end

  test "related resource without content type fails" do
    passport = reference.deep_dup
    passport["elements"] << { "elementId" => "userManual", "objectType" => "RelatedResource", "url" => "manual.pdf" }
    result = criterion(lint(passport), "DPP-DAT-011")
    assert_equal "failed", result["result"]
    assert_equal ["userManual: contentType is missing", "userManual: url manual.pdf is not an absolute HTTP(S) URL"],
                 result["messages"].map { |m| m["message"] }
  end

  test "invalid JSON is rejected" do
    post "/api/v1/validate", params: "{not json", headers: { "Content-Type" => "application/json" }
    assert_response :unprocessable_entity
  end

  test "start page offers the form and keeps a given product identifier" do
    get "/", params: { productId: "https://dpp.example.org/01/09520123456788" }
    assert_response :success
    assert_includes response.body, 'id="productId"'
    assert_includes response.body, 'value="https://dpp.example.org/01/09520123456788"'
    assert_includes response.body, "no certification"
  end

  test "version names service, criteria and web-cli" do
    get "/version"
    body = JSON.parse(response.body)
    assert_equal "dpplint", body["service"]
    assert body["soya-web-cli"].present?
    assert body.key?("soya-context")
  end
end
