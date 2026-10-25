require "test_helper"

# html with device_features: forbidden (DPP-SEC-021): static search for
# browser interfaces that use functions of the reader's device.
class HtmlCheckDeviceTest < ActiveSupport::TestCase
  UPI = "https://dpp.example.org/01/09520123456788/21/0001".freeze
  CHECK = { "type" => "html", "device_features" => "forbidden" }.freeze
  VECTORS = Rails.root.join("test/fixtures/files/html/DPP-SEC-021")

  # The page for the product identifier; scripts under /scripts/ from the
  # test vectors; every other URL is recorded and answered with 404.
  class FakeResolver
    attr_reader :requested

    def initialize(page, scripts: {}) = (@page, @scripts, @requested = page, scripts, [])

    def get(url, accept: nil)
      @requested << [url, accept]
      return response(url, 200, "text/html; charset=utf-8", @page) if url == UPI
      return response(url, 200, "text/javascript", @scripts[url]) if @scripts.key?(url)

      response(url, 404, "text/plain", "not found")
    end

    def response(url, status, type, body) = HttpResolver::Response.new(url: url, status: status, content_type: type, body: body, headers: {})
  end

  def scripts
    Dir[VECTORS.join("scripts", "*.js")].to_h { |f| ["https://dpp.example.org/scripts/#{File.basename(f)}", File.read(f)] }
  end

  def outcome(html, check: CHECK)
    resolver = FakeResolver.new(html, scripts: scripts)
    [HtmlCheck.new(check, UPI, resolver).outcome, resolver]
  end

  def page(head = "", body = "") = "<!doctype html><html><head>#{head}</head><body>#{body}</body></html>"

  def finding(html) = outcome(html).first.messages.first&.dig(:message)

  test "DPP-SEC-021 test vectors: valid ones pass, invalid ones fail" do
    valid = Dir[VECTORS.join("valid", "*.html")].sort
    invalid = Dir[VECTORS.join("invalid", "*.html")].sort
    assert_operator valid.size, :>=, 5
    assert_operator invalid.size, :>=, 8
    valid.each { |f| assert_empty outcome(File.read(f)).first.messages, f }
    invalid.each { |f| assert_equal ["violation"], outcome(File.read(f)).first.messages.map { |m| m[:severity] }, f }
  end

  test "findings name the function, the interface and the place" do
    assert_equal "the HTML view uses functions of the reader's device: location (.geolocation in inline script 1)",
                 finding(VECTORS.join("invalid/inline-script-location.html").read)
    assert_match(/notifications \(Notification\.requestPermission in attribute onclick of button\)/,
                 finding(VECTORS.join("invalid/event-handler-notifications.html").read))
    assert_match(%r{camera, microphone or screen \(\.mediaDevices in https://dpp\.example\.org/scripts/scanner\.js\)},
                 finding(VECTORS.join("invalid/own-script-camera.html").read))
    assert_match(%r{motion or orientation sensors \(devicemotion in https://dpp\.example\.org/scripts/sensors\.js\)},
                 finding(VECTORS.join("invalid/modulepreload-sensors.html").read))
    assert_match(/iframe allow grants camera\z/, finding(VECTORS.join("invalid/iframe-allow-camera.html").read))
    assert_match(/file input with capture/, finding(VECTORS.join("invalid/file-input-capture.html").read))
    assert_match(/device behaviour \(navigator\.vibrate in attribute href of a\)/,
                 finding(VECTORS.join("invalid/javascript-url-vibration.html").read))
    assert_match(/permission element/, finding(VECTORS.join("invalid/permission-element.html").read))
  end

  test "only scripts from the page's own host are fetched, as */*" do
    _, resolver = outcome(page('<script src="/scripts/render.js"></script><script src="https://cdn.example.net/geo.js"></script>' \
                               '<script type="application/ld+json" src="/data.json"></script>'))
    assert_equal [[UPI, "text/html"], ["https://dpp.example.org/scripts/render.js", "*/*"]], resolver.requested
  end

  test "at most ten scripts are fetched" do
    tags = (1..12).map { |i| %(<script src="/s#{i}.js"></script>) }.join
    _, resolver = outcome(page(tags))
    assert_equal 11, resolver.requested.size
  end

  test "a script that cannot be retrieved is not checked" do
    assert_empty outcome(page('<script src="/missing.js"></script>')).first.messages
  end

  test "each interface group is recognised" do
    {
      "navigator.geolocation.watchPosition(f)" => "location",
      "navigator.mediaDevices.getDisplayMedia()" => "camera, microphone or screen",
      "reg.pushManager.subscribe()" => "notifications",
      "new Notification('x')" => "notifications",
      "navigator.contacts.select(['tel'])" => "contacts",
      "navigator.bluetooth.requestDevice({})" => "Bluetooth, USB, serial, HID or NFC",
      "new NDEFReader()" => "Bluetooth, USB, serial, HID or NFC",
      "DeviceOrientationEvent.requestPermission()" => "motion or orientation sensors",
      "new Gyroscope({ frequency: 60 })" => "motion or orientation sensors",
      "window.ondeviceorientation = f" => "motion or orientation sensors",
      "navigator.connection.effectiveType" => "context or network information",
      "navigator.getBattery()" => "context or network information",
      "new IdleDetector()" => "context or network information",
      "navigator.credentials.get({ otp: { transport: ['sms'] } })" => "one-time codes from SMS",
      "addEventListener('beforeinstallprompt', f)" => "app installation",
      "navigator.wakeLock.request('screen')" => "device behaviour"
    }.each do |code, label|
      assert_equal [label], HtmlCheck.device_uses(code).map(&:first), code
    end
  end

  test "ordinary code and words without interface calls are not counted" do
    ["const location = window.location.href;", "fetch('/dpp.json').then(r => r.json())",
     "document.title = 'geolocation of the factory';", "navigator.language", "Notification"].each do |code|
      assert_empty HtmlCheck.device_uses(code), code
    end
  end

  test "a page without device use passes, together with external_resources" do
    o, = outcome(page('<script src="/scripts/render.js"></script>'), check: CHECK.merge("external_resources" => "forbidden"))
    assert_empty o.messages
  end

  test "both options give a message each" do
    o, = outcome(page('<script src="https://cdn.example.net/a.js"></script><script>navigator.vibrate(1)</script>'),
                 check: CHECK.merge("external_resources" => "forbidden"))
    assert_equal 2, o.messages.size
  end
end
