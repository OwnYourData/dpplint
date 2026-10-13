require "nokogiri"

# Runs a criterion with check.type html: the HTML view of the passport.
#
# The product identifier is requested with Accept: text/html (redirects
# followed). Without a final 200 text/html response there is nothing to
# check; whether the HTML view exists is rated by DPP-DAT-016.
#
# external_resources: forbidden collects the URLs a browser fetches without
# user action while it displays the document (see "Check types", html, in
# CRITERIA-FORMAT.md of dpp-criteria) and reports every http(s) URL whose host
# differs from the host of the final response URL. Links the user has to
# follow are not counted; resources added by scripts at run time cannot be
# seen in the document.
class HtmlCheck
  Outcome = Struct.new(:skipped, :code, :messages, keyword_init: true)

  SRC_ELEMENTS = %w[script img iframe frame embed audio video source track].freeze
  SRCSET_ELEMENTS = %w[img source].freeze
  LINK_RELS = %w[stylesheet icon apple-touch-icon mask-icon manifest preload modulepreload
                 prefetch prerender preconnect dns-prefetch].freeze
  CSS_URL = /url\(\s*(?:"([^"]*)"|'([^']*)'|([^)"'\s]*))\s*\)/i
  CSS_IMPORT = /@import\s+(?:"([^"]*)"|'([^']*)')/i
  MAX_LISTED = 10

  def initialize(check, product_id, resolver)
    @check = check
    @product_id = product_id
    @resolver = resolver
  end

  def outcome
    res = @resolver.get(@product_id, accept: "text/html")
    unless res.error.nil? && res.status == 200 && res.media_type == "text/html"
      return Outcome.new(skipped: "no HTML view (#{describe(res)}); rated by DPP-DAT-016", code: "no_evidence")
    end

    messages = []
    messages << external_message(res) if @check["external_resources"] == "forbidden"
    Outcome.new(messages: messages.compact)
  end

  # The URLs a browser loads without user action, resolved, with the element
  # or construct they come from: [[url, source], …].
  def self.loaded_urls(html, page_url)
    doc = Nokogiri::HTML5(html.to_s)
    base = absolute(doc.at_css("base[href]")&.[]("href"), page_url) || page_url
    found = []
    add = ->(value, source) { (u = absolute(value, base)) && found << [u, source] }

    doc.css(SRC_ELEMENTS.join(",")).each { |e| add.(e["src"], e.name) if e["src"] }
    doc.css('input[src]').each { |e| add.(e["src"], "input") if e["type"].to_s.casecmp?("image") }
    doc.css(SRCSET_ELEMENTS.join(",")).each do |e|
      srcset(e["srcset"]).each { |u| add.(u, "#{e.name} srcset") }
    end
    doc.css("video[poster]").each { |e| add.(e["poster"], "video poster") }
    doc.css("object[data]").each { |e| add.(e["data"], "object") }
    doc.xpath("//*[local-name()='image']").each do |e|
      (e["href"] || e["xlink:href"] || e.attribute_with_ns("href", "http://www.w3.org/1999/xlink")&.value)
        .then { |v| add.(v, "svg image") if v }
    end
    doc.css("link[href]").each do |e|
      rels = e["rel"].to_s.downcase.split
      next if (rels & LINK_RELS).empty?

      add.(e["href"], "link rel=#{rels.join(' ')}")
    end
    doc.css("style").each { |e| css_urls(e.content).each { |u| add.(u, "style") } }
    doc.css("[style]").each { |e| css_urls(e["style"]).each { |u| add.(u, "style attribute") } }
    doc.css("meta[http-equiv]").each do |e|
      next unless e["http-equiv"].to_s.casecmp?("refresh")

      target = e["content"].to_s[/url\s*=\s*['"]?([^'"\s]+)/i, 1]
      add.(target, "meta refresh") if target
    end
    found.uniq
  end

  def self.absolute(value, base)
    value = value.to_s.strip
    return nil if value.empty?

    URI.join(base.to_s, value).to_s
  rescue URI::Error, ArgumentError
    # A URL the URI library cannot parse (spaces, non-ASCII characters) still
    # counts if its host can be read.
    host = value[%r{\A(?:https?:)?//([^/?#\s:]+)}i, 1]
    host && "https://#{host}/"
  end

  def self.srcset(value)
    value.to_s.split(",").map { |c| c.strip.split(/\s+/).first }.compact.reject(&:empty?)
  end

  def self.css_urls(css)
    css.to_s.scan(CSS_URL).map { |m| m.compact.first } + css.to_s.scan(CSS_IMPORT).map { |m| m.compact.first }
  end

  # Host of an http(s) URL, lower case, or nil for other schemes.
  def self.web_host(url)
    uri = URI.parse(url)
    return nil unless %w[http https].include?(uri.scheme&.downcase)

    uri.host&.downcase&.delete_prefix("[")&.delete_suffix("]")
  rescue URI::Error
    nil
  end

  private

  def external_message(res)
    own = self.class.web_host(res.url.to_s)
    external = self.class.loaded_urls(res.body, res.url.to_s).select do |url, _|
      (host = self.class.web_host(url)) && host != own
    end
    return nil if external.empty?

    listed = external.first(MAX_LISTED).map { |url, source| "#{url} (#{source})" }
    more = external.size > MAX_LISTED ? " and #{external.size - MAX_LISTED} more" : ""
    { severity: "violation",
      message: "the HTML view loads #{external.size} resource(s) from other hosts than #{own}: #{listed.join(', ')}#{more}" }
  end

  def describe(res)
    return res.error if res.error

    "HTTP status #{res.status}, Content-Type #{res.content_type.presence || 'missing'}"
  end
end
