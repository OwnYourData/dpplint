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

  def criterion(result, id) = result["criteria"].find { |c| c["id"] == id }

  test "reference passport passes all structure checks" do
    result = lint(reference)
    %w[DPP-DAT-014 DPP-INT-005 DPP-ROL-016 DPP-DAT-015 DPP-CFG-005].each do |id|
      assert_equal "passed", criterion(result, id)["result"], id
    end
    assert_equal 0, result["summary"]["failed"]
    assert_match(/\A\d+ of \d+ automated checks passed\z/, result["summary"]["text"])
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

  test "optional facility identifier is skipped when absent" do
    assert_equal "skipped", criterion(lint(reference), "DPP-ID-010")["result"]
  end

  test "checks that request the product identifier need one" do
    result = lint(reference)
    %w[DPP-ID-001 DPP-ID-013 DPP-DAT-003 DPP-DAT-016].each do |id|
      assert_equal "skipped", criterion(result, id)["result"], id
    end
    assert_equal "rated by dpp-validator from its daily runs", criterion(result, "DPP-ID-002")["reason"]
  end

  test "DID check is skipped when didlint cannot be reached" do
    result = criterion(lint(reference), "DPP-ID-016")
    assert_equal "skipped", result["result"]
    assert_match(/didlint not reachable/, result["reason"])
  end

  test "passport without proof or related resources skips both checks" do
    result = lint(reference)
    assert_match(/carries no integrity proof/, criterion(result, "DPP-SEC-002")["reason"])
    assert_equal "no RelatedResource elements", criterion(result, "DPP-DAT-011")["reason"]
  end

  test "passport signed by its economic operator passes the integrity check" do
    passport = reference.merge("economicOperatorId" => did_key)
    signed = sign(passport, verification_method: "#{did_key}##{key_multibase}")
    assert_equal "passed", criterion(lint(signed), "DPP-SEC-002")["result"]
    changed = signed.merge("dppStatus" => "Inactive")
    assert_equal "failed", criterion(lint(changed), "DPP-SEC-002")["result"]
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
  end
end
