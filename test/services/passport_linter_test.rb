require "test_helper"

# Overall result of a resolve criterion: failed if a check with severity error
# fails, otherwise warning if a check with severity warning fails, otherwise passed.
class PassportLinterTest < ActiveSupport::TestCase
  UPI = "https://dpp.example.org/01/09520123456788/21/0001".freeze

  class FakeCatalogue
    def initialize(criteria) = @criteria = criteria
    def passport_criteria = @criteria
  end

  class FakeResolver
    def initialize(responses) = @responses = responses

    def get(_url, accept: nil)
      status, type, body, headers = @responses.fetch(accept)
      HttpResolver::Response.new(url: UPI, status: status, content_type: type, body: body, headers: headers || {})
    end
  end

  CHECK = {
    "type" => "resolve", "accept" => "text/html",
    "expect" => { "status" => [200], "content_type" => "text/html",
                  "headers" => [{ "name" => "Vary", "contains" => "Accept", "severity" => "warning" }] },
    "further_requests" => [{ "accept" => "*/*", "severity" => "warning",
                             "expect" => { "status" => [200], "content_type" => "application/json" } }]
  }.freeze

  def criterion(check = CHECK) = { "id" => "DPP-DAT-016", "title" => "t", "level" => "MUST", "target" => "passport", "method" => "automated", "check" => check }

  def lint(responses, check = CHECK)
    PassportLinter.new(catalogue: FakeCatalogue.new([criterion(check)]), resolver: FakeResolver.new(responses))
                  .run(passport: nil, product_id: UPI)
  end

  HTML = [200, "text/html", "<html></html>", { "vary" => ["Accept"] }].freeze
  JSON_OK = [200, "application/json", '{"uniqueProductIdentifier":"x"}'].freeze

  test "no failing check passes" do
    report = lint("text/html" => HTML, "*/*" => JSON_OK)
    assert_equal "passed", report[:criteria].first[:result]
    assert_equal "1 of 1 automated checks passed", report[:summary][:text]
  end

  test "failing warning checks give a warning, which still counts as passed" do
    report = lint("text/html" => [200, "text/html", "<html></html>", { "vary" => ["Origin"] }], "*/*" => [200, "text/html", "<html></html>"])
    result = report[:criteria].first
    assert_equal "warning", result[:result]
    assert_equal %w[warning warning], result[:messages].map { |m| m[:severity] }
    assert_equal({ passed: 1, failed: 0, warnings: 1 }, report[:summary].slice(:passed, :failed, :warnings))
  end

  test "a failing error check fails the criterion, whatever the warnings" do
    report = lint("text/html" => [200, "application/json", '{"a":1}', { "vary" => ["Origin"] }], "*/*" => JSON_OK)
    result = report[:criteria].first
    assert_equal "failed", result[:result]
    assert_equal %w[violation warning], result[:messages].map { |m| m[:severity] }
    assert_equal "0 of 1 automated checks passed", report[:summary][:text]
  end

  test "a further request without severity fails the criterion" do
    check = CHECK.merge("further_requests" => [{ "accept" => "*/*", "expect" => { "status" => [200], "content_type" => "application/json" } }])
    report = lint({ "text/html" => HTML, "*/*" => [200, "text/html", "<html></html>"] }, check)
    assert_equal "failed", report[:criteria].first[:result]
  end

  test "expect parts not evaluated for resolve skip the criterion" do
    check = { "type" => "resolve", "expect" => { "status" => [200], "json" => [{ "path" => "$.a", "exists" => true }] } }
    result = lint({}, check)[:criteria].first
    assert_equal "skipped", result[:result]
    assert_equal "expect json is not evaluated for check type resolve in this version", result[:reason]
  end
end
