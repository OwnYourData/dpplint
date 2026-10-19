require "test_helper"

# A check through the API ends within CHECK_DEADLINE, also when the passport
# host does not answer, and leaves no request behind.
class CheckTimeLimitTest < ActionDispatch::IntegrationTest
  LIMIT = 3

  setup do
    @config = Rails.configuration.x.dpplint
    @previous_deadline = @config.check_deadline
    @config.check_deadline = LIMIT
    @previous_private = ENV["DPPLINT_ALLOW_PRIVATE_NETWORKS"]
    ENV["DPPLINT_ALLOW_PRIVATE_NETWORKS"] = "1"
  end

  teardown do
    @config.check_deadline = @previous_deadline
    ENV["DPPLINT_ALLOW_PRIVATE_NETWORKS"] = @previous_private
  end

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  test "hanging passport host: the check answers within the time limit with every criterion accounted for" do
    server = SlowServer.new { [0, nil] }
    took = timed { get "/api/v1/validate/#{server.url('/01/09520123456788/21/000001')}" }
    assert_response :success
    report = response.parsed_body

    assert_operator took, :<, LIMIT + 1, "answered after #{took.round(1)} s"
    assert_equal({ "seconds" => LIMIT.to_f, "reached" => true }, report["timeLimit"])
    assert_match(/\Anot retrieved: the time limit of 3 s for this check was reached\z/, report.dig("retrieval", "error"))
    assert(report["criteria"].all? { |c| c["result"] == "skipped" }, "nothing could be evaluated")
    assert(report["criteria"].any? { |c| c["reason"] == "the time limit of 3 s for this check was reached" })
    assert(report["notices"].any? { |n| n.start_with?("The time limit of the check was reached (3 s)") })
    assert server.all_given_up?, "no request of the check is left open"
  ensure
    server&.stop
  end
end
