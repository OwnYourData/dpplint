require "net/http"
require "ipaddr"
require "resolv"

# Plain HTTP(S) GET like a phone scanning a data carrier: no credentials,
# redirects followed, optional Accept header. Responses are cached per run.
# Header fields of the final response are kept as a Hash of lower-case field
# name => list of values (one entry per field line).
#
# Only public addresses are contacted: host names that resolve to loopback,
# private, link-local or other internal ranges are refused (also after a
# redirect), so that passports cannot make dpplint reach internal services.
# DPPLINT_ALLOW_PRIVATE_NETWORKS=1 lifts this for local development.
class HttpResolver
  Response = Struct.new(:url, :status, :content_type, :body, :error, :headers, keyword_init: true) do
    def media_type = content_type.to_s.split(";").first.to_s.strip.downcase
    def success? = error.nil? && status.between?(200, 299)
  end

  MAX_REDIRECTS = 5

  BLOCKED = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
    192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
    ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  class Blocked < StandardError; end

  def initialize(allow_private: ENV["DPPLINT_ALLOW_PRIVATE_NETWORKS"] == "1")
    @allow_private = allow_private
    @cache = {}
    @lock = Mutex.new
  end

  def get(url, accept: nil)
    cached([:get, url, accept]) { fetch(url, accept, :get) }
  end

  # Whether a URL answers, without downloading it: HEAD, and a ranged GET if
  # the server does not support HEAD. The body is not kept.
  def probe(url)
    cached([:probe, url]) do
      res = fetch(url, nil, :head)
      [405, 501].include?(res.status) ? fetch(url, nil, :range) : res
    end
  end

  # Raises Blocked unless every address of the host is public.
  def self.public_address!(host)
    addresses = host.match?(/\A[\d.]+\z|:/) ? [host.delete("[]")] : Resolv.getaddresses(host)
    raise Blocked, "#{host} cannot be resolved" if addresses.empty?

    addresses.each do |a|
      ip = IPAddr.new(a)
      ip = ip.native if ip.ipv4_mapped?
      raise Blocked, "#{host} resolves to #{a}, which is not a public address" if BLOCKED.any? { |net| net.include?(ip) }
    end
    addresses.first
  end

  private

  def cached(key)
    hit = @lock.synchronize { @cache[key] }
    return hit if hit

    value = yield
    @lock.synchronize { @cache[key] = value }
  end

  def fetch(url, accept, mode)
    uri = URI.parse(url)
    return Response.new(url: url, error: "not an HTTP(S) URL") unless uri.is_a?(URI::HTTP) && uri.host.present?

    MAX_REDIRECTS.times do
      res = request(uri, accept, mode)
      if res.is_a?(Net::HTTPRedirection) && res["location"]
        uri += res["location"]
        return Response.new(url: uri.to_s, error: "redirect to a URL that is not HTTP(S)") unless uri.is_a?(URI::HTTP)

        next
      end
      body = mode == :get ? res.body : nil
      return Response.new(url: uri.to_s, status: res.code.to_i, content_type: res["content-type"], body: body, headers: res.to_hash)
    end
    Response.new(url: uri.to_s, error: "more than #{MAX_REDIRECTS} redirects")
  rescue URI::InvalidURIError
    Response.new(url: url, error: "not a valid URL")
  rescue Blocked => e
    Response.new(url: uri.to_s, error: "not retrieved: #{e.message}")
  rescue StandardError => e
    Response.new(url: uri.to_s, error: "retrieval failed: #{e.message}")
  end

  def request(uri, accept, mode)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = mode == :get ? 20 : 10
    http.ipaddr = self.class.public_address!(uri.host) unless @allow_private || http.proxy?
    headers = accept ? { "Accept" => accept } : {}
    req = case mode
          when :head then Net::HTTP::Head.new(uri, headers)
          when :range then Net::HTTP::Get.new(uri, headers.merge("Range" => "bytes=0-0"))
          else Net::HTTP::Get.new(uri, headers)
          end
    http.start { |h| h.request(req) }
  end
end
