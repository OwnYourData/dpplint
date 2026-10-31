require "test_helper"

class ApiDocsTest < ActionDispatch::IntegrationTest
  test "the API description is titled DPP Linter API" do
    get "/api-docs/v1/swagger.yaml"
    assert_response :success
    assert_equal "DPP Linter API", YAML.safe_load(response.body).dig("info", "title")
  end

  test "the API documentation page offers the description as DPP Linter API v1" do
    get "/api-docs/index.html"
    assert_response :success
    assert_includes response.body, "DPP Linter API v1"
    assert_not_includes response.body, "dpplint API"
  end

  test "the API documentation page loads nothing from Google, not even web fonts" do
    get "/api-docs/index.html"
    assert_response :success
    assert_includes response.body, "swagger-ui-bundle.js"
    assert_no_match(/googleapis|gstatic|googletagmanager|doubleclick/i, response.body)
  end
end
