require "test_helper"

# Overall result of a resolve criterion: failed if a check with severity error
# fails, otherwise warning if a check with severity warning fails, otherwise passed.
class PassportLinterTest < ActiveSupport::TestCase
  UPI = "https://dpp.example.org/01/09520123456788/21/0001".freeze

  class FakeCatalogue
    def initialize(criteria) = @criteria = criteria
    def passport_criteria = @criteria
    def description_url(id) = "https://example.org/criteria/README.md##{id.downcase}"
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

  def criterion(check = CHECK) = { "id" => "DPP-DAT-016", "title" => "t", "level" => "MUST", "target" => "passport", "method" => "automated", "status" => "active", "check" => check }

  def lint(responses, check = CHECK)
    PassportLinter.new(catalogue: FakeCatalogue.new([criterion(check)]), resolver: FakeResolver.new(responses))
                  .run(passport: nil, product_id: UPI)
  end

  HTML = [200, "text/html", "<html></html>", { "vary" => ["Accept"] }].freeze
  JSON_OK = [200, "application/json", '{"uniqueProductIdentifier":"x"}'].freeze

  test "each criterion links to its description" do
    result = lint({ "text/html" => HTML, "*/*" => JSON_OK })[:criteria].first
    assert_equal "https://example.org/criteria/README.md#dpp-dat-016", result[:description_url]
  end

  test "only active criteria count; proposed ones are summarised separately" do
    proposed = criterion.merge("id" => "DPP-DAT-099", "status" => "proposed")
    deprecated_like = criterion.merge("id" => "DPP-DAT-098", "status" => "deprecated")
    report = PassportLinter.new(catalogue: FakeCatalogue.new([criterion, proposed, deprecated_like]),
                                resolver: FakeResolver.new("text/html" => HTML, "*/*" => JSON_OK))
                           .run(passport: nil, product_id: UPI)
    assert_equal "1 of 1 automated checks passed", report[:summary][:text]
    assert_equal "1 of 1 automated checks passed", report[:summary][:proposed_not_counted][:text]
    assert_equal [true, false, false], report[:criteria].map { |c| c[:counted] }
    assert_equal %w[active proposed deprecated], report[:criteria].map { |c| c[:status] }
  end

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
    report = lint("text/html" => [200, "application/json", '{"a":1}', { "vary" => ["Origin"] }], "*/*" => [200, "text/html", "<html></html>"])
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

  test "applies_if with a matches pattern that is not valid ECMA-262 skips the criterion with a reason" do
    criterion = { "id" => "DPP-ID-099", "title" => "t", "level" => "MUST", "target" => "passport", "method" => "automated", "status" => "active",
                  "applies_if" => [{ "path" => "$.granularity", "matches" => "a**" }], "check" => { "type" => "did", "paths" => ["$.facilityId"] } }
    report = PassportLinter.new(catalogue: FakeCatalogue.new([criterion]), resolver: FakeResolver.new({}))
                           .run(passport: { "granularity" => "item" })
    result = report[:criteria].first
    assert_equal "skipped", result[:result]
    assert_match(/\Aregular expression "a\*\*" in applies_if is not a valid ECMA-262 regular expression/, result[:reason])
  end

  test "applies_if with ^ in search() skips the criterion with a reason instead of evaluating it" do
    criterion = { "id" => "DPP-BAT-002", "title" => "t", "level" => "MUST", "target" => "passport", "method" => "automated", "status" => "active",
                  "applies_if" => [{ "path" => "$.contentSpecificationIds[?search(@, '^[Bb]atter')]", "exists" => false }],
                  "check" => { "type" => "did", "paths" => ["$.facilityId"] } }
    report = PassportLinter.new(catalogue: FakeCatalogue.new([criterion]), resolver: FakeResolver.new({}))
                           .run(passport: { "contentSpecificationIds" => ["Battery"] })
    result = report[:criteria].first
    assert_equal "skipped", result[:result]
    assert_match(/of search\(\) in applies_if path .* contains \^ outside a character class/, result[:reason])
    assert_equal "0 of 0 automated checks passed", report[:summary][:text]
  end

  test "applies_if with search() whose condition does not hold skips the criterion" do
    criterion = { "id" => "DPP-BAT-002", "title" => "t", "level" => "MUST", "target" => "passport", "method" => "automated", "status" => "active",
                  "applies_if" => [{ "path" => "$.contentSpecificationIds[?search(@, '[Bb]atter')]", "exists" => true }],
                  "check" => { "type" => "did", "paths" => ["$.facilityId"] } }
    report = PassportLinter.new(catalogue: FakeCatalogue.new([criterion]), resolver: FakeResolver.new({}))
                           .run(passport: { "contentSpecificationIds" => ["BATTERY"] })
    assert_equal({ result: "skipped", reason: "condition not met" }, report[:criteria].first.slice(:result, :reason))
  end

  test "a pattern that is not valid ECMA-262 skips the criterion with a reason, without a request" do
    check = CHECK.merge("expect" => CHECK["expect"].merge("headers" => [{ "name" => "Vary", "matches" => "(?i)accept" }]))
    result = lint({}, check)[:criteria].first
    assert_equal "skipped", result[:result]
    assert_match(/\Aregular expression "\(\?i\)accept" for header Vary is not a valid ECMA-262 regular expression/, result[:reason])
  end

  test "a pattern outside the portable subset skips the criterion with a reason" do
    check = CHECK.merge("further_requests" => [{ "accept" => "*/*", "expect" => { "headers" => [{ "name" => "Vary", "matches" => "(?=Accept)" }] } }])
    result = lint({}, check)[:criteria].first
    assert_equal "skipped", result[:result]
    assert_match(/uses a feature outside the portable subset of CRITERIA-FORMAT.md that dpplint does not evaluate \(lookahead\)/, result[:reason])
  end
end
