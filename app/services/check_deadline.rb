# The overall time limit of one check (CHECK_DEADLINE, default 35 s).
#
# Every request of the check (passport, redirects, JWS, resolve, HTML view,
# links, SOyA web-cli, didlint) keeps its own limits, but waits at most the
# time that is left: `split` gives the connect and read limits for one
# request so that both together end within the time left. A request that
# times out on limits cut by the time limit, or that would start after it,
# raises Reached; the criterion it belongs to is reported as not_evaluated
# with `reason`. So a check ends in time with a partial result, and nothing of
# it keeps running afterwards.
class CheckDeadline
  class Reached < StandardError; end

  # Connect and read limits of one request; cut if the time limit shortened them.
  Limits = Struct.new(:connect, :read, :cut)

  # A request needs at least this much time; with less left, none is started.
  MIN_WAIT = 0.5
  # Share of the time left that connecting may take at most.
  CONNECT_SHARE = 0.3

  attr_reader :seconds

  def initialize(seconds = Rails.configuration.x.dpplint.check_deadline)
    @seconds = seconds.to_f
    @ends = now + @seconds
  end

  def remaining = [@ends - now, 0.0].max

  def reached? = remaining < MIN_WAIT

  def reason = "the time limit of #{format_seconds(@seconds)} for this check was reached"

  # Whether a step of the check was cut off by the time limit.
  def hit? = @hit == true

  # Raises Reached if no further request can be started.
  def check!
    reached! if reached?
  end

  # Connect and read limits for one request: its own limits, but together
  # never longer than the time left. Raises Reached if no time is left.
  def split(connect, read)
    check!
    left = remaining
    capped_connect = [connect.to_f, left * CONNECT_SHARE].min
    capped_read = [read.to_f, left - capped_connect].min
    Limits.new(capped_connect, capped_read, capped_connect < connect.to_f || capped_read < read.to_f)
  end

  # After a timeout of a request: raises Reached if its limits were cut by the
  # time limit (or the time is up), so that the timeout is not blamed on the
  # host; otherwise returns and the timeout counts as the host's.
  def timed_out!(limits)
    reached! if limits&.cut || reached?
  end

  private

  def reached!
    @hit = true
    raise Reached, reason
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def format_seconds(value) = "#{value.round(1).to_s.delete_suffix('.0')} s"
end
