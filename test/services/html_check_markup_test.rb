require "test_helper"

# html with markup_errors: forbidden (DPP-DAT-020): the HTML view is posted to
# the Nu Html Checker; every error fails the criterion, warnings and other
# info messages do not count. The checker here is a local server that gives
# the answers the Nu Html Checker gave to the test vectors (recorded in
# test/fixtures/files/html/DPP-DAT-020/checker, see README.md there).
class HtmlCheckMarkupTest < ActiveSupport::TestCase
  UPI = "https://dpp.example.org/01/09520123456788/21/0001".freeze
  CHECK = { "type" => "html", "markup_errors" => "forbidden" }.freeze
  VECTORS = Rails.root.join("test/fixtures/files/html/DPP-DAT-020")
  CHARSETS = { "legacy-encoding" => "windows-1252" }.freeze

  class FakeResolver
    attr_reader :requested

    def initialize(page, type, status: 200) = (@page, @type, @status, @requested = page, type, status, [])

    def get(url, accept: nil)
      @requested << [url, accept]
      HttpResolver::Response.new(url: url, status: @status, content_type: @type, body: @page, headers: {})
    end
  end

  setup { @servers = [] }

  teardown { @servers.each(&:stop) }

  def server(&handler) = SlowServer.new(&handler).tap { |s| @servers << s }

  def json(body) = SlowServer.http(200, body, "Content-Type" => "application/json; charset=utf-8")

  # A checker that answers each test vector as recorded.
  def recorded_checker
    answers = Dir[VECTORS.join("{valid,invalid}", "*.html")].to_h do |file|
      [File.binread(file), File.read(VECTORS.join("checker", "#{File.basename(File.dirname(file))}-#{File.basename(file, '.html')}.json"))]
    end
    server { |_lines, body| [0, answers.key?(body.to_s.b) ? json(answers[body.to_s.b]) : SlowServer.http(500)] }
  end

  def content_type(file) = "text/html; charset=#{CHARSETS.fetch(File.basename(file, '.html'), 'utf-8')}"

  def outcome(page, type: "text/html; charset=utf-8", checker: recorded_checker, check: CHECK)
    nu = checker.is_a?(NuChecker) ? checker : NuChecker.new(checker.url("/"))
    HtmlCheck.new(check, UPI, FakeResolver.new(page, type), nu_checker: nu).outcome
  end

  def vector(name) = VECTORS.join(name)

  test "DPP-DAT-020 test vectors: valid ones pass, invalid ones fail" do
    checker = recorded_checker
    valid = Dir[VECTORS.join("valid", "*.html")].sort
    invalid = Dir[VECTORS.join("invalid", "*.html")].sort
    assert_operator valid.size, :>=, 3
    assert_operator invalid.size, :>=, 6
    valid.each do |f|
      o = outcome(File.binread(f), type: content_type(f), checker: checker)
      assert_nil o.skipped, f
      assert_empty o.messages, f
    end
    invalid.each do |f|
      assert_equal ["violation"], outcome(File.binread(f), type: content_type(f), checker: checker).messages.map { |m| m[:severity] }, f
    end
  end

  test "the HTML view is posted as received, with its media type and charset" do
    checker = recorded_checker
    page = File.binread(vector("invalid/legacy-encoding.html"))
    outcome(page, type: "text/html; charset=windows-1252", checker: checker)
    lines = checker.requests.last
    assert_equal "POST /?out=json HTTP/1.1", lines.first
    assert_includes lines, "Content-Type: text/html; charset=windows-1252"
    assert_includes lines, "Accept: application/json"
  end

  test "findings name the line and the message of each error" do
    assert_equal "the Nu Html Checker reports 1 error(s) in the HTML view: line 10: Duplicate ID “product”.",
                 outcome(File.binread(vector("invalid/duplicate-id.html"))).messages.first[:message]
    assert_equal "the Nu Html Checker reports 2 error(s) in the HTML view: Legacy encoding “windows-1252” used. " \
                 "Documents must use UTF-8.; line 4: The only allowed value for the “charset” attribute for the “meta” " \
                 "element is “utf-8”.",
                 outcome(File.binread(vector("invalid/legacy-encoding.html")), type: "text/html; charset=windows-1252").messages.first[:message]
  end

  test "warnings and other info messages do not count" do
    recorded = JSON.parse(File.read(vector("checker/valid-warnings-only.json")))["messages"]
    assert_equal %w[info info], recorded.map { |m| m["type"] }
    assert_empty outcome(File.binread(vector("valid/warnings-only.html"))).messages
  end

  test "more than ten errors are cut short" do
    errors = (1..12).map { |i| { "type" => "error", "lastLine" => i, "message" => "Error #{i}." } }
    checker = server { [0, json({ "messages" => errors }.to_json)] }
    message = outcome("<p>x", checker: checker).messages.first[:message]
    assert_match(/\Athe Nu Html Checker reports 12 error\(s\) in the HTML view: line 1: Error 1\.; /, message)
    assert_match(/line 10: Error 10\. and 2 more\z/, message)
  end

  test "without a configured checker the criterion is skipped" do
    o = outcome("<p>x", checker: NuChecker.new(""))
    assert_equal "not_evaluated", o.code
    assert_equal "no Nu Html Checker is configured for this instance", o.skipped
  end

  test "a checker that cannot be reached, answers with an error page or cannot check the document skips the criterion" do
    gone = NuChecker.new("http://127.0.0.1:9/")
    assert_match(/\Athe Nu Html Checker is not reachable/, outcome("<p>x", checker: gone).skipped)
    assert_equal "the Nu Html Checker answered with HTTP 500", outcome("<p>x", checker: server { [0, SlowServer.http(500)] }).skipped
    assert_equal "the Nu Html Checker answered with invalid JSON", outcome("<p>x", checker: server { [0, json("<html>")] }).skipped
    refused = { "messages" => [{ "type" => "non-document-error", "subType" => "io", "message" => "Non-XML Content-Type: “application/pdf”." }] }
    o = outcome("<p>x", checker: server { [0, json(refused.to_json)] })
    assert_equal "not_evaluated", o.code
    assert_equal "the Nu Html Checker could not check the document: Non-XML Content-Type: “application/pdf”.", o.skipped
  end

  test "a checker that does not answer ends with the time limit of the check" do
    hanging = server { [0, nil] }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(CheckDeadline::Reached) do
      NuChecker.new(hanging.url("/"), deadline: CheckDeadline.new(1)).messages("<p>x", "text/html")
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert hanging.all_given_up?
  end

  test "the checker is asked only with the option and only for an HTML view" do
    checker = recorded_checker
    HtmlCheck.new({ "type" => "html", "device_features" => "forbidden" }, UPI, FakeResolver.new("<p>x", "text/html"),
                  nu_checker: NuChecker.new(checker.url("/"))).outcome
    o = HtmlCheck.new(CHECK, UPI, FakeResolver.new("{}", "application/json"), nu_checker: NuChecker.new(checker.url("/"))).outcome
    assert_equal "no_evidence", o.code
    assert_empty checker.requests
  end

  test "a base URL without a trailing slash works" do
    checker = server { [0, json('{"messages":[]}')] }
    assert_equal [], NuChecker.new(checker.url("/").chomp("/")).messages("<p>x", "text/html")
    assert_equal "POST /?out=json HTTP/1.1", checker.requests.last.first
  end
end
