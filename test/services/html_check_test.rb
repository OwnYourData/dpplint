require "test_helper"

class HtmlCheckTest < ActiveSupport::TestCase
  UPI = "https://dpp.example.org/01/09520123456788/21/0001".freeze
  CHECK = { "type" => "html", "external_resources" => "forbidden" }.freeze

  # Answers every GET with one response; records the Accept header.
  class FakeResolver
    attr_reader :accept

    def initialize(status, type, body, url: UPI, error: nil) = (@status, @type, @body, @url, @error = status, type, body, url, error)

    def get(_url, accept: nil)
      @accept = accept
      return HttpResolver::Response.new(url: @url, error: @error) if @error

      HttpResolver::Response.new(url: @url, status: @status, content_type: @type, body: @body, headers: {})
    end
  end

  def outcome(body, status: 200, type: "text/html; charset=utf-8", url: UPI, error: nil)
    HtmlCheck.new(CHECK, UPI, FakeResolver.new(status, type, body, url: url, error: error)).outcome
  end

  def page(head = "", body = "") = "<!doctype html><html><head>#{head}</head><body>#{body}</body></html>"

  test "requests the HTML view" do
    resolver = FakeResolver.new(200, "text/html", page)
    HtmlCheck.new(CHECK, UPI, resolver).outcome
    assert_equal "text/html", resolver.accept
  end

  test "page with own and relative resources passes" do
    o = outcome(page('<link rel="stylesheet" href="/app.css"><script src="https://dpp.example.org/app.js"></script>',
                     '<img src="logo.png"><img src="data:image/png;base64,AAAA"><a href="https://other.example/info">info</a>'))
    assert_nil o.skipped
    assert_empty o.messages
  end

  test "external script, font and image fail" do
    o = outcome(page('<script src="https://cdn.example.net/lib.js"></script>' \
                     '<link rel="preconnect" href="https://fonts.gstatic.com">' \
                     '<style>@import "https://fonts.googleapis.com/css2?family=Inter"; body { background: url(//img.example.com/bg.png) }</style>',
                     '<img srcset="/a.png 1x, https://pix.example.com/b.png 2x">'))
    assert_equal ["violation"], o.messages.map { |m| m[:severity] }
    msg = o.messages.first[:message]
    %w[cdn.example.net fonts.gstatic.com fonts.googleapis.com img.example.com pix.example.com].each { |h| assert_includes msg, h }
    assert_match(/5 resource\(s\)/, msg)
  end

  test "another host of the same operator counts as external" do
    o = outcome(page('<link rel="icon" href="https://static.example.org/favicon.ico">'))
    assert_match(/static\.example\.org/, o.messages.first[:message])
  end

  test "host comparison ignores case and port" do
    assert_empty outcome(page('<script src="https://DPP.example.org:443/a.js"></script>')).messages
  end

  test "own host is the host of the final URL after redirects" do
    o = outcome(page('<script src="https://view.example.com/a.js"></script>'), url: "https://view.example.com/p/1")
    assert_empty o.messages
  end

  test "base href is used for relative URLs" do
    o = outcome(page('<base href="https://cdn.example.net/"><script src="a.js"></script>'))
    assert_match(%r{https://cdn\.example\.net/a\.js \(script\)}, o.messages.first[:message])
  end

  test "style attribute, meta refresh, object, video poster and svg image count" do
    o = outcome(page('<meta http-equiv="Refresh" content="0; url=https://track.example.com/r">',
                     '<div style="background-image: url(\'https://a.example.com/x.png\')"></div>' \
                     '<object data="https://b.example.com/o.svg"></object><video poster="https://c.example.com/p.jpg"></video>' \
                     '<svg><image href="https://d.example.com/i.png"/></svg>'))
    msg = o.messages.first[:message]
    %w[track.example.com a.example.com b.example.com c.example.com d.example.com].each { |h| assert_includes msg, h }
  end

  test "link relations that do not load are not counted" do
    o = outcome(page('<link rel="alternate" type="application/json" href="https://api.example.com/p.json">' \
                     '<link rel="canonical" href="https://www.example.com/p">'))
    assert_empty o.messages
  end

  test "more than ten external URLs are summarised" do
    imgs = (1..12).map { |i| %(<img src="https://h#{i}.example.com/i.png">) }.join
    msg = outcome(page("", imgs)).messages.first[:message]
    assert_match(/12 resource\(s\)/, msg)
    assert_match(/and 2 more\z/, msg)
  end

  test "an unparsable external URL still counts" do
    assert_match(/bad\.example\.com/, outcome(page('<img src="https://bad.example.com/a b|c.png">')).messages.first[:message])
  end

  test "without an HTML view the check is skipped" do
    o = outcome('{"a":1}', type: "application/json")
    assert_equal "no_evidence", o.code
    assert_match(/DPP-DAT-016/, o.skipped)
    assert_equal "no_evidence", outcome(page, status: 406).code
    assert_equal "no_evidence", outcome(nil, error: "retrieval failed: timeout (test)").code
  end
end
