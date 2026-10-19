require "socket"

# A plain HTTP server on 127.0.0.1 for tests of time limits. The block gets
# the request line and header lines and returns [delay, response]: the
# response is sent after `delay` seconds; nil means the server never answers
# and waits until the client gives up. `open_requests` counts the requests
# the client has not given up yet, so a test can see that nothing of a check
# keeps running after it.
class SlowServer
  def initialize(&handler)
    @handler = handler
    @tcp = TCPServer.new("127.0.0.1", 0)
    @lock = Mutex.new
    @requests = []
    @open = 0
    @clients = []
    @thread = Thread.new do
      loop { serve(@tcp.accept) }
    rescue IOError, SystemCallError
      nil
    end
  end

  def url(path = "/") = "http://127.0.0.1:#{@tcp.addr[1]}#{path}"

  def requests = @lock.synchronize { @requests.dup }

  def open_requests = @lock.synchronize { @open }

  # Waits up to `within` seconds until the client has given up every request.
  def all_given_up?(within: 1)
    ends = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    sleep 0.02 while open_requests.positive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < ends
    open_requests.zero?
  end

  def stop
    @tcp.close
    @lock.synchronize { @clients.each { |c| c.close unless c.closed? } }
    @thread.join(2)
  end

  def self.http(status, body = "", headers = {})
    head = { "Content-Length" => body.bytesize, "Connection" => "close" }.merge(headers).map { |k, v| "#{k}: #{v}\r\n" }.join
    "HTTP/1.1 #{status} X\r\n#{head}\r\n#{body}"
  end

  private

  def serve(client)
    @lock.synchronize { @clients << client }
    Thread.new(client) do |c|
      lines = []
      while (line = c.gets) && line != "\r\n"
        lines << line.chomp
      end
      @lock.synchronize { @requests << lines }
      delay, response = @handler.call(lines)
      if response
        sleep delay.to_f
        c.write(response)
      else
        @lock.synchronize { @open += 1 }
        begin
          c.read
        ensure
          @lock.synchronize { @open -= 1 }
        end
      end
    rescue IOError, SystemCallError
      nil
    ensure
      c.close unless c.closed?
    end
  end
end
