require "test_helper"

class LinksCheckTest < ActiveSupport::TestCase
  CHECK = { "type" => "links", "element_type" => "RelatedResource", "required" => %w[contentType url], "unreachable" => "warning" }.freeze

  # Answers probes from a table instead of the network.
  class FakeResolver
    attr_reader :probed

    def initialize(responses = {}) = (@responses, @probed = responses, [])

    def probe(url)
      @probed << url
      status, error = @responses.fetch(url, [200, nil])
      HttpResolver::Response.new(url: url, status: status, error: error)
    end
  end

  def resource(id, url: "https://data.example.com/#{id}.pdf", content_type: "application/pdf")
    { "elementId" => id, "objectType" => "RelatedResource", "contentType" => content_type, "url" => url }.compact
  end

  def passport(*resources)
    { "elements" => [{ "elementId" => "Documents", "objectType" => "DataElementCollection", "elements" => resources }] }
  end

  def messages(passport, resolver = FakeResolver.new, check: CHECK) = LinksCheck.new(check, passport, resolver: resolver).messages

  test "passport without related resources has none" do
    assert_empty LinksCheck.new(CHECK, passport, resolver: FakeResolver.new).resources
  end

  test "nested related resources that answer pass" do
    resolver = FakeResolver.new
    assert_empty messages(passport(resource("manual"), resource("declaration")), resolver)
    assert_equal 2, resolver.probed.size
  end

  test "missing content type fails" do
    result = messages(passport(resource("manual", content_type: nil)))
    assert_equal [{ severity: "violation", message: "manual: contentType is missing" }], result
  end

  test "URL that is not absolute fails without a request" do
    resolver = FakeResolver.new
    result = messages(passport(resource("manual", url: "/manual.pdf")), resolver)
    assert_match(/not an absolute HTTP\(S\) URL/, result.first[:message])
    assert_empty resolver.probed
  end

  test "URL that does not answer gives a warning" do
    url = "https://data.example.com/manual.pdf"
    result = messages(passport(resource("manual", url: url)), FakeResolver.new(url => [404, nil]))
    assert_equal [{ severity: "warning", message: "manual: #{url} does not answer (HTTP 404)" }], result
  end

  test "unreachable as error fails" do
    url = "https://data.example.com/manual.pdf"
    result = messages(passport(resource("manual", url: url)), FakeResolver.new(url => [nil, "retrieval failed: timeout"]),
                      check: CHECK.merge("unreachable" => "error"))
    assert_equal "violation", result.first[:severity]
  end

  test "same URL is requested once and the number of requests is limited" do
    resolver = FakeResolver.new
    many = (1..25).map { |i| resource("doc#{i}") } + [resource("again", url: "https://data.example.com/doc1.pdf")]
    result = messages(passport(*many), resolver)
    assert_equal LinksCheck::MAX_LINKS, resolver.probed.size
    assert_match(/only the first 20 of 25 URLs/, result.first[:message])
  end
end
