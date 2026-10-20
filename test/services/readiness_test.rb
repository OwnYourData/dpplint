require "test_helper"
require "socket"
require "tmpdir"

# Readiness of a replica: the SOyA web-cli and its repository answer. The
# result is held, so that the readiness probe stays cheap.
class ReadinessTest < ActiveSupport::TestCase
  WEB_CLI_VERSION = SlowServer.http(200, '{"name":"soya-web-cli","version":"1.0.0"}', "Content-Type" => "application/json")

  class Clock
    attr_accessor :now

    def initialize = @now = 100.0
    def call = @now
  end

  setup do
    @dir = Dir.mktmpdir
    File.write(File.join(@dir, "DigitalProductPassport"), "{}")
    File.write(File.join(@dir, "BatteryPassport"), "{}")
    @clock = Clock.new
    @servers = []
  end

  teardown do
    @servers.each(&:stop)
    FileUtils.remove_entry(@dir)
  end

  def server(&handler) = SlowServer.new(&handler).tap { |s| @servers << s }

  def web_cli(answer = WEB_CLI_VERSION) = server { [0, answer] }

  def repository = server { [0, SlowServer.http(200)] }

  def closed_url
    tcp = TCPServer.new("127.0.0.1", 0)
    port = tcp.addr[1]
    tcp.close
    "http://127.0.0.1:#{port}"
  end

  def readiness(web_cli_url, repository_url, dir: @dir)
    Readiness.new(web_cli: web_cli_url, repository: repository_url, structures_dir: dir, clock: @clock)
  end

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    value = yield
    [value, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  test "web-cli and repository answer: ready, after one request to each" do
    cli = web_cli
    repo = repository
    result = readiness(cli.url, repo.url).status
    assert result.ready
    assert_nil result.reason
    assert_equal ["GET /api/v1/version HTTP/1.1"], cli.requests.map(&:first)
    assert_equal ["HEAD /BatteryPassport HTTP/1.1"], repo.requests.map(&:first), "one structure of the image, the first by name"
  end

  test "web-cli not running: not ready, and the repository is not asked" do
    repo = repository
    result = readiness(closed_url, repo.url).status
    assert_not result.ready
    assert_equal "SOyA web-cli not reachable", result.reason
    assert_empty repo.requests
  end

  test "web-cli answers with an error or without its version: not ready" do
    assert_equal "SOyA web-cli answered HTTP 500",
                 readiness(web_cli(SlowServer.http(500, "Error")).url, repository.url).status.reason
    assert_equal "SOyA web-cli answered without its version",
                 readiness(web_cli(SlowServer.http(200, "<html></html>", "Content-Type" => "text/html")).url, repository.url).status.reason
    assert_equal "SOyA web-cli answered without its version",
                 readiness(web_cli(SlowServer.http(200, "{", "Content-Type" => "application/json")).url, repository.url).status.reason
  end

  test "web-cli hangs: the question ends well within the 2 s of the probe, and no request stays open" do
    cli = server { [0, nil] }
    result, took = timed { readiness(cli.url, repository.url).status }
    assert_not result.ready
    assert_equal "SOyA web-cli not reachable", result.reason
    assert_operator took, :<, 1.0
    assert cli.all_given_up?
  end

  test "repository missing, without the structure or without structures: not ready" do
    assert_equal "SOyA repository not reachable", readiness(web_cli.url, closed_url).status.reason
    assert_equal "SOyA repository answered HTTP 404 for BatteryPassport",
                 readiness(web_cli.url, server { [0, SlowServer.http(404)] }.url).status.reason
    Dir.mktmpdir do |empty|
      assert_equal "no SOyA structures in this image", readiness(web_cli.url, repository.url, dir: empty).status.reason
    end
  end

  test "ready: the result is held and the web-cli is asked again only after 30 s" do
    cli = web_cli
    check = readiness(cli.url, repository.url)
    assert check.status.ready
    @clock.now += 29
    assert check.status.ready
    assert_equal 1, cli.requests.size
    @clock.now += 1
    assert check.status.ready
    assert_equal 2, cli.requests.size
  end

  test "not ready: asked again at most every second, and ready once the web-cli answers" do
    answers = [SlowServer.http(503, "starting"), SlowServer.http(503, "starting"), WEB_CLI_VERSION]
    cli = server { [0, answers.shift || WEB_CLI_VERSION] }
    check = readiness(cli.url, repository.url)
    assert_not check.status.ready
    @clock.now += 0.5
    assert_not check.status.ready
    assert_equal 1, cli.requests.size, "no new request within a second"
    @clock.now += 0.5
    assert_not check.status.ready
    @clock.now += 1
    assert check.status.ready
    assert_equal 3, cli.requests.size
  end

  test "web-cli stops after it was ready: not ready at the next question" do
    cli = web_cli
    check = readiness(cli.url, repository.url)
    assert check.status.ready
    cli.stop
    @clock.now += 30
    result = check.status
    assert_not result.ready
    assert_equal "SOyA web-cli not reachable", result.reason
  end

  test "one question at a time: a caller during a question gets the held result at once" do
    cli = server { [0.4, WEB_CLI_VERSION] }
    check = readiness(cli.url, repository.url)
    first = Thread.new { check.status }
    sleep 0.1
    second, took = timed { check.status }
    assert_equal "not checked yet", second.reason
    assert_operator took, :<, 0.1
    assert first.value.ready
    assert_equal 1, cli.requests.size
  end
end
