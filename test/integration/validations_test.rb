require "test_helper"

class ValidationsTest < ActionDispatch::IntegrationTest
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

  test "invalid JSON is rejected" do
    post "/api/v1/validate", params: "{not json", headers: { "Content-Type" => "application/json" }
    assert_response :unprocessable_entity
  end

  test "version names service, criteria and web-cli" do
    get "/version"
    body = JSON.parse(response.body)
    assert_equal "dpplint", body["service"]
    assert body["soya-web-cli"].present?
  end
end
