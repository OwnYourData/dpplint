require "httpx"
require "ipaddr"
require "resolv"
require "timeout"

# Plain HTTP(S) GET like a phone scanning a data carrier: no credentials,
# redirects followed, optional Accept header. Responses are cached per run.
# Header fields of the final response are kept as a Hash of lower-case field
# name => list of values.
#
# Requests go through httpx, which negotiates HTTP/2 via ALPN and falls back
# to HTTP/1.1 for servers without HTTP/2 (DPP services may refuse HTTP/1.x,
# DPP-DEX-006). The HTTP version of the final response is kept.
#
# Only public addresses are contacted: host names that resolve to loopback,
# private, link-local or other internal ranges are refused (also after a
# redirect), so that passports cannot make dpplint reach internal services.
# The connection is pinned to the address that was checked (httpx option
# `addresses`), while TLS SNI, certificate check and Host header keep the
# host name. DPPLINT_ALLOW_PRIVATE_NETWORKS=1 lifts this for local development.
#
# Each request waits at most DNS_TIMEOUT for the name, CONNECT_TIMEOUT for the
# connection and GET_TIMEOUT (HEAD_TIMEOUT for probes) for the answer, per
# redirect, but never beyond the time limit of the check (CheckDeadline): once
# that is reached, CheckDeadline::Reached is raised instead of an answer.
class HttpResolver
  Response = Struct.new(:url, :status, :content_type, :body, :error, :headers, :http_version, keyword_init: true) do
    def media_type = content_type.to_s.split(";").first.to_s.strip.downcase
    def success? = error.nil? && status.between?(200, 299)
  end

  MAX_REDIRECTS = 5
  DNS_TIMEOUT = 5
  CONNECT_TIMEOUT = 10
  GET_TIMEOUT = 20
  HEAD_TIMEOUT = 10
  # Share of the time left that resolving a name may take at most.
  DNS_SHARE = 0.2

  BLOCKED = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
    192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
    ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  class Blocked < StandardError; end
  class DnsTimeout < Blocked; end

  def initialize(allow_private: ENV["DPPLINT_ALLOW_PRIVATE_NETWORKS"] == "1", deadline: CheckDeadline.new)
    @allow_private = allow_private
    @deadline = deadline
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

  # Raises Blocked unless every address of the host is public, or if the name
  # cannot be resolved within `timeout` seconds.
  def self.public_address!(host, timeout: DNS_TIMEOUT)
    addresses = host.match?(/\A[\d.]+\z|:/) ? [host.delete("[]")] : resolve_name(host, timeout)
    raise Blocked, "#{host} cannot be resolved" if addresses.empty?

    addresses.each do |a|
      ip = IPAddr.new(a)
      ip = ip.native if ip.ipv4_mapped?
      raise Blocked, "#{host} resolves to #{a}, which is not a public address" if BLOCKED.any? { |net| net.include?(ip) }
    end
    addresses.first
  end

  # Resolv answers through the DNS servers of the system; its own retries can
  # take far longer than a check may, so the lookup as a whole is limited.
  def self.resolve_name(host, timeout)
    Timeout.timeout(timeout) { Resolv.getaddresses(host) }
  rescue Timeout::Error
    raise DnsTimeout, "#{host} cannot be resolved within #{timeout.round(1)} s"
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
      if res.status.between?(300, 399) && res.headers["location"]
        uri += res.headers["location"]
        return Response.new(url: uri.to_s, error: "redirect to a URL that is not HTTP(S)") unless uri.is_a?(URI::HTTP)

        next
      end
      body = mode == :get ? res.body.to_s : nil
      return Response.new(url: uri.to_s, status: res.status, content_type: res.headers["content-type"], body: body,
                          headers: header_lists(res.headers), http_version: res.version)
    end
    Response.new(url: uri.to_s, error: "more than #{MAX_REDIRECTS} redirects")
  rescue URI::InvalidURIError
    Response.new(url: url, error: "not a valid URL")
  rescue CheckDeadline::Reached
    raise
  rescue Blocked => e
    Response.new(url: uri.to_s, error: "not retrieved: #{e.message}")
  rescue StandardError => e
    Response.new(url: uri.to_s, error: "retrieval failed: #{e.message}")
  end

  def request(uri, accept, mode)
    headers = {}
    headers["accept"] = accept if accept
    headers["range"] = "bytes=0-0" if mode == :range
    options = {}
    options[:addresses] = [public_address(uri.host)] unless @allow_private
    limits = @deadline.split(CONNECT_TIMEOUT, mode == :get ? GET_TIMEOUT : HEAD_TIMEOUT)
    options[:timeout] = { connect_timeout: limits.connect, settings_timeout: limits.read, request_timeout: limits.read }
    session = HTTPX.with(**options)
    res = mode == :head ? session.head(uri.to_s, headers: headers) : session.get(uri.to_s, headers: headers)
    if res.is_a?(HTTPX::ErrorResponse)
      @deadline.timed_out!(limits) if res.error.is_a?(HTTPX::TimeoutError)
      raise res.error
    end

    res
  end

  # The checked address of the host; the name lookup gets at most a share of
  # the time left.
  def public_address(host)
    @deadline.check!
    dns = [DNS_TIMEOUT, @deadline.remaining * DNS_SHARE].min
    self.class.public_address!(host, timeout: dns)
  rescue DnsTimeout
    @deadline.timed_out!(CheckDeadline::Limits.new(dns, dns, dns < DNS_TIMEOUT))
    raise
  end

  # httpx keeps every field as a list of values under its lower-case name.
  def header_lists(headers)
    headers.to_hash.keys.to_h { |name| [name, headers.get(name).dup] }
  end
end
