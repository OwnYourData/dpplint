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
#
# device_features: forbidden looks, without running any script, for browser
# interfaces that use functions of the reader's device (DEVICE_INTERFACES) in
# the inline scripts, event handler attributes and javascript: URLs of the
# document and in the scripts it loads from its own host (at most MAX_SCRIPTS,
# the first MAX_SCRIPT_BYTES of each; a script that cannot be retrieved is not
# checked), and in the markup for frames granted device permissions
# (DEVICE_PERMISSIONS), file inputs with capture and permission elements.
class HtmlCheck
  Outcome = Struct.new(:skipped, :code, :messages, keyword_init: true)

  DEVICE_INTERFACES = [
    ["location", /\.geolocation\b|\bgetCurrentPosition\b|\bwatchPosition\b/],
    ["camera, microphone or screen", /\bgetUserMedia\b|\bgetDisplayMedia\b|\.mediaDevices\b/],
    ["notifications", /\bNotification\s*\.\s*requestPermission\b|\bnew\s+Notification\s*\(|\.showNotification\s*\(|\b[Pp]ushManager\b/],
    ["contacts", /\bnavigator\s*\.\s*contacts\b/],
    ["Bluetooth, USB, serial, HID or NFC", /\bnavigator\s*\.\s*(?:bluetooth|usb|serial|hid)\b|\bNDEFReader\b/],
    ["motion or orientation sensors",
     /\b(?:on)?(?:devicemotion|deviceorientation(?:absolute)?)\b|\bDevice(?:Motion|Orientation)Event\s*\.\s*requestPermission\b|\bnew\s+(?:Accelerometer|Gyroscope|Magnetometer|AbsoluteOrientationSensor|RelativeOrientationSensor|LinearAccelerationSensor|GravitySensor|AmbientLightSensor)\s*\(/],
    ["context or network information", /\bnavigator\s*\.\s*connection\b|\bgetBattery\s*\(|\bIdleDetector\b/],
    ["one-time codes from SMS", /\bOTPCredential\b|\btransport\s*:\s*\[\s*["']sms["']/],
    ["app installation", /\bbeforeinstallprompt\b|\bgetInstalledRelatedApps\b/],
    ["device behaviour", /\bnavigator\s*\.\s*(?:wakeLock|vibrate)\b/]
  ].freeze
  DEVICE_PERMISSIONS = %w[camera microphone geolocation display-capture bluetooth usb serial hid accelerometer gyroscope
                          magnetometer ambient-light-sensor idle-detection screen-wake-lock].freeze
  JS_TYPES = %w[text/javascript application/javascript application/ecmascript text/ecmascript module
                application/x-javascript text/jscript text/x-javascript].freeze
  URL_ATTRIBUTES = %w[href src action formaction].freeze
  MAX_SCRIPTS = 10
  MAX_SCRIPT_BYTES = 2 * 1024 * 1024
  MAX_FINDINGS = 10

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
    messages << device_message(res) if @check["device_features"] == "forbidden"
    Outcome.new(messages: messages.compact)
  end

  # Device interfaces found in a piece of script: [[label, matched text], …].
  def self.device_uses(code)
    DEVICE_INTERFACES.filter_map do |label, pattern|
      match = code.to_s.match(pattern)
      [label, match[0].gsub(/\s+/, " ")] if match
    end
  end

  def self.javascript_type?(type)
    type = type.to_s.split(";").first.to_s.strip.downcase
    type.empty? || JS_TYPES.include?(type)
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

  def device_message(res)
    doc = Nokogiri::HTML5(res.body.to_s)
    findings = markup_findings(doc) + inline_findings(doc) + script_findings(doc, res.url.to_s)
    return nil if findings.empty?

    listed = findings.first(MAX_FINDINGS)
    more = findings.size > MAX_FINDINGS ? " and #{findings.size - MAX_FINDINGS} more" : ""
    { severity: "violation", message: "the HTML view uses functions of the reader's device: #{listed.join('; ')}#{more}" }
  end

  def markup_findings(doc)
    found = []
    doc.css("iframe[allow]").each do |e|
      granted = e["allow"].to_s.split(";").map { |d| d.strip.split(/\s+/).first.to_s.downcase } & DEVICE_PERMISSIONS
      found << "iframe allow grants #{granted.join(', ')}" if granted.any?
    end
    found << "file input with capture" if doc.css("input[capture]").any?
    %w[permission geolocation].each { |name| found << "#{name} element" if doc.css(name).any? }
    found
  end

  def inline_findings(doc)
    found = []
    doc.css("script").each_with_index do |e, i|
      next if e["src"] || !self.class.javascript_type?(e["type"])

      self.class.device_uses(e.content).each { |label, use| found << "#{label} (#{use} in inline script #{i + 1})" }
    end
    doc.xpath("//@*").each do |a|
      name = a.name.downcase
      code = if name.start_with?("on") then a.value
             elsif URL_ATTRIBUTES.include?(name) && a.value.to_s.strip.downcase.start_with?("javascript:") then a.value
             end
      next unless code

      self.class.device_uses(code).each { |label, use| found << "#{label} (#{use} in attribute #{name} of #{a.parent.name})" }
    end
    found
  end

  # Scripts loaded from the host of the page, fetched as text and searched.
  def script_findings(doc, page_url)
    own = self.class.web_host(page_url)
    base = self.class.absolute(doc.at_css("base[href]")&.[]("href"), page_url) || page_url
    urls = doc.css("script[src]").select { |e| self.class.javascript_type?(e["type"]) }.map { |e| e["src"] }
    urls += doc.css("link[href]").select { |e| e["rel"].to_s.downcase.split.include?("modulepreload") }.map { |e| e["href"] }
    urls = urls.filter_map { |u| self.class.absolute(u, base) }.uniq.select { |u| self.class.web_host(u) == own }
    urls.first(MAX_SCRIPTS).flat_map do |url|
      res = @resolver.get(url, accept: "*/*")
      next [] unless res.success?

      self.class.device_uses(res.body.to_s.byteslice(0, MAX_SCRIPT_BYTES).to_s.dup.force_encoding(Encoding::UTF_8).scrub).map { |label, use| "#{label} (#{use} in #{url})" }
    end
  end

  def describe(res)
    return res.error if res.error

    "HTTP status #{res.status}, Content-Type #{res.content_type.presence || 'missing'}"
  end
end
