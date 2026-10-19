require "test_helper"

# The time limit of a check: every kind of request ends within it, a request
# cut off by it is reported as not evaluated, and none keeps running after it.
class CheckDeadlineTest < ActiveSupport::TestCase
  DID = "did:web:operator.example.org".freeze
  LIMIT = 1.5

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    value = yield
    [value, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def hanging = SlowServer.new { [0, nil] }

  def resolver(deadline) = HttpResolver.new(allow_private: true, deadline: deadline)

  test "connect and read limits of a request end within the time left, and say whether the limit cut them" do
    deadline = CheckDeadline.new(10)
    far = deadline.split(1, 2)
    assert_equal [1.0, 2.0, false], far.to_a
    near = deadline.split(10, 20)
    assert_operator near.connect + near.read, :<=, 10
    assert_in_delta 3.0, near.connect, 0.05
    assert near.cut
  end

  test "once the time is up, no request starts, and the check remembers that it was cut off" do
    deadline = CheckDeadline.new(0.4)
    assert_not deadline.hit?
    error = assert_raises(CheckDeadline::Reached) { deadline.split(1, 1) }
    assert_equal "the time limit of 0.4 s for this check was reached", error.message
    assert deadline.hit?
  end

  test "a timeout on limits not cut by the time limit is the host's" do
    deadline = CheckDeadline.new(10)
    assert_nil deadline.timed_out!(deadline.split(1, 1))
    assert_raises(CheckDeadline::Reached) { deadline.timed_out!(deadline.split(10, 20)) }
  end

  test "hanging passport host: the request ends at the time limit and the connection is closed" do
    server = hanging
    _, took = elapsed do
      assert_raises(CheckDeadline::Reached) { resolver(CheckDeadline.new(LIMIT)).get(server.url("/01/1/21/1"), accept: "application/json") }
    end
    assert_operator took, :<, LIMIT + 0.3
    assert server.all_given_up?, "no request of the check is left open"
  ensure
    server&.stop
  end

  test "slow redirects: the chain is not followed beyond the time limit" do
    server = SlowServer.new do |lines|
      hop = lines.first[%r{/hop/(\d+)}, 1].to_i
      [0.4, SlowServer.http(302, "", "Location" => "/hop/#{hop + 1}")]
    end
    _, took = elapsed do
      assert_raises(CheckDeadline::Reached) { resolver(CheckDeadline.new(LIMIT)).get(server.url("/hop/0")) }
    end
    assert_operator took, :<, LIMIT + 0.3
    assert_operator server.requests.size, :<, HttpResolver::MAX_REDIRECTS, "fewer hops than without a time limit"
    assert server.all_given_up?
  ensure
    server&.stop
  end

  def links_passport(server, count)
    resources = Array.new(count) do |i|
      { "elementId" => "doc#{i}", "objectType" => "RelatedResource", "contentType" => "application/pdf", "url" => server.url("/doc#{i}.pdf") }
    end
    { "elements" => [{ "elementId" => "Documents", "objectType" => "DataElementCollection", "elements" => resources }] }
  end

  LINKS = { "type" => "links", "element_type" => "RelatedResource", "required" => %w[contentType url], "unreachable" => "warning" }.freeze

  test "many slow links: all requests end at the time limit, and none keeps running" do
    server = SlowServer.new { [5, SlowServer.http(200)] }
    _, took = elapsed do
      check = LinksCheck.new(LINKS, links_passport(server, LinksCheck::MAX_LINKS), resolver: resolver(CheckDeadline.new(LIMIT)))
      assert_raises(CheckDeadline::Reached) { check.messages }
    end
    assert_operator took, :<, LIMIT + 0.3
    assert_equal LinksCheck::MAX_LINKS, server.requests.size, "the links are requested in parallel"
    assert_equal 0, Thread.list.count { |t| t.name == "dpplint links" && t.alive? }, "no request thread of the check is left"
  ensure
    server&.stop
  end

  test "many links that answer in time are all checked" do
    server = SlowServer.new { [0.3, SlowServer.http(200)] }
    messages, took = elapsed do
      LinksCheck.new(LINKS, links_passport(server, LinksCheck::MAX_LINKS), resolver: resolver(CheckDeadline.new(5))).messages
    end
    assert_empty messages
    assert_operator took, :<, 2
  ensure
    server&.stop
  end

  test "slow SOyA web-cli: the call ends at the time limit" do
    server = hanging
    _, took = elapsed do
      assert_raises(CheckDeadline::Reached) do
        SoyaWebCli.new(server.url.chomp("/"), deadline: CheckDeadline.new(LIMIT)).validate("DigitalProductPassport", {})
      end
    end
    assert_operator took, :<, LIMIT + 0.3
    assert server.all_given_up?
  ensure
    server&.stop
  end

  test "slow didlint: the request ends at the time limit, also within the didlint budget" do
    server = hanging
    didlint = Didlint.new(server.url.chomp("/"), timeout: 10, budget: 20, deadline: CheckDeadline.new(LIMIT))
    _, took = elapsed do
      assert_raises(CheckDeadline::Reached) { didlint.validate(DID) }
      assert_raises(CheckDeadline::Reached) { didlint.resolve(DID) }
    end
    assert_operator took, :<, LIMIT + 0.3
    assert_equal 1, server.requests.size
    assert server.all_given_up?
  ensure
    server&.stop
  end

  class FakeCatalogue
    def initialize(criteria) = @criteria = criteria
    def passport_criteria = @criteria
    def description_url(_id) = nil
  end

  def criterion(id, check) = { "id" => id, "title" => "t", "level" => "MUST", "status" => "active", "check" => check }

  test "time limit reached: the results so far stay, the rest is not evaluated with the reason" do
    passport_host = SlowServer.new do |lines|
      html = lines.any? { |l| l.match?(/\Aaccept: text\/html/i) }
      html ? [0, nil] : [0, SlowServer.http(200, "{}", "Content-Type" => "application/json")]
    end
    didlint_host = hanging
    deadline = CheckDeadline.new(LIMIT)
    criteria = [
      criterion("DPP-T-001", { "type" => "resolve", "accept" => "application/json", "expect" => { "status" => [200] } }),
      criterion("DPP-T-002", { "type" => "resolve", "accept" => "text/html", "expect" => { "status" => [200] } }),
      criterion("DPP-T-003", { "type" => "did", "paths" => ["$.economicOperatorId"] }),
      criterion("DPP-T-004", { "type" => "did", "paths" => ["$.facilityId"] })
    ]
    linter = PassportLinter.new(catalogue: FakeCatalogue.new(criteria), deadline: deadline, resolver: resolver(deadline),
                                didlint: Didlint.new(didlint_host.url.chomp("/"), timeout: 10, budget: 20, deadline: deadline))
    report, took = elapsed { linter.run(passport: { "economicOperatorId" => DID }, product_id: passport_host.url("/01/1/21/1")) }

    assert_operator took, :<, LIMIT + 0.3
    results = report[:criteria].map { |c| [c[:id], c[:result], c[:reason_code], c[:reason]] }
    reason = "the time limit of 1.5 s for this check was reached"
    assert_equal [["DPP-T-001", "passed", nil, nil],
                  ["DPP-T-002", "skipped", "not_evaluated", reason],
                  ["DPP-T-003", "skipped", "not_evaluated", reason],
                  ["DPP-T-004", "skipped", "not_applicable", "no DID in $.facilityId"]], results
    assert_equal({ seconds: 1.5, reached: true }, report[:timeLimit])
    assert_includes report[:notices], "The time limit of the check was reached (1.5 s); 2 criteria were not evaluated in time."
    assert_equal "1 of 1 automated checks passed", report[:summary][:text]
    assert_equal({ "not_evaluated" => 2, "not_applicable" => 1 }, report[:summary][:skipped_by_reason])
    assert passport_host.all_given_up?
    assert_empty didlint_host.requests, "didlint is not asked once the time is up"
  ensure
    passport_host&.stop
    didlint_host&.stop
  end

  test "time limit reached during the JWS request: the passport is kept, the integrity check is not evaluated" do
    host = SlowServer.new do |lines|
      jws = lines.any? { |l| l.match?(%r{\Aaccept: application/vc\+jwt}i) }
      jws ? [0, nil] : [0, SlowServer.http(200, '{"a":1}', "Content-Type" => "application/json")]
    end
    deadline = CheckDeadline.new(LIMIT)
    fetch, took = elapsed { PassportFetcher.new(resolver(deadline)).fetch(host.url("/01/1/21/1")) }
    assert_operator took, :<, LIMIT + 0.3
    assert_equal({ "a" => 1 }, fetch.json)
    assert_nil fetch.jws
    assert_equal "the passport was not requested as JWS: the time limit of 1.5 s for this check was reached", fetch.jws_unchecked
    report = PassportLinter.new(catalogue: FakeCatalogue.new([criterion("DPP-T-005", { "type" => "proof" })]), deadline: deadline)
                           .run(passport: fetch.json, jws_unchecked: fetch.jws_unchecked)
    assert_equal ["skipped", "not_evaluated", fetch.jws_unchecked], report[:criteria].first.values_at(:result, :reason_code, :reason)
    assert host.all_given_up?
  ensure
    host&.stop
  end

  test "a check within the time limit reports that it was not reached" do
    report = PassportLinter.new(catalogue: FakeCatalogue.new([]), deadline: CheckDeadline.new(5)).run(passport: {})
    assert_equal({ seconds: 5.0, reached: false }, report[:timeLimit])
    assert_empty report[:notices]
  end
end
