require "test_helper"

# html with device_features: forbidden (DPP-SEC-021): static search for uses
# of functions of the reader's device (DeviceUses).
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

  test "DPP-SEC-021 test vectors: valid ones pass, invalid ones fail, the others warn" do
    valid = Dir[VECTORS.join("valid", "*.html")].sort
    invalid = Dir[VECTORS.join("invalid", "*.html")].sort
    warning = Dir[VECTORS.join("warning", "*.html")].sort
    assert_operator valid.size, :>=, 8
    assert_operator invalid.size, :>=, 9
    assert_operator warning.size, :>=, 4
    valid.each { |f| assert_empty outcome(File.read(f)).first.messages, f }
    invalid.each { |f| assert_equal ["violation"], outcome(File.read(f)).first.messages.map { |m| m[:severity] }, f }
    warning.each { |f| assert_equal ["warning"], outcome(File.read(f)).first.messages.map { |m| m[:severity] }, f }
  end

  test "findings name the function, the interface and the place" do
    assert_equal "the HTML view uses functions of the reader's device: location (.getCurrentPosition() in inline script 1)",
                 finding(VECTORS.join("invalid/inline-script-location.html").read)
    assert_match(/notifications \(Notification\.requestPermission\(\) in attribute onclick of button\)/,
                 finding(VECTORS.join("invalid/event-handler-notifications.html").read))
    assert_match(%r{camera, microphone or screen \(\.mediaDevices\.getUserMedia\(\) in https://dpp\.example\.org/scripts/scanner\.js\)},
                 finding(VECTORS.join("invalid/own-script-camera.html").read))
    assert_match(%r{motion or orientation sensors \(addEventListener\("devicemotion"\) in https://dpp\.example\.org/scripts/sensors\.js\)},
                 finding(VECTORS.join("invalid/modulepreload-sensors.html").read))
    assert_match(/iframe allow grants camera\z/, finding(VECTORS.join("invalid/iframe-allow-camera.html").read))
    assert_match(/file input with capture/, finding(VECTORS.join("invalid/file-input-capture.html").read))
    assert_match(/device behaviour \(navigator\.vibrate\(\) in attribute href of a\)/,
                 finding(VECTORS.join("invalid/javascript-url-vibration.html").read))
    assert_match(/permission element/, finding(VECTORS.join("invalid/permission-element.html").read))
  end

  test "a polyfill that hooks into the location interface is no use, a call next to it is" do
    assert_empty outcome(VECTORS.join("valid/polyfill-hooks-device-interfaces.html").read).first.messages
    assert_equal "the HTML view uses functions of the reader's device: " \
                 "location (.getCurrentPosition() in https://dpp.example.org/scripts/locate.js)",
                 finding(VECTORS.join("invalid/polyfill-and-location-call.html").read)
  end

  test "doubts give a warning that names them" do
    assert_equal "no use of functions of the reader's device was found, but the HTML view may use them: " \
                 "location (.getCurrentPosition read without a call in inline script 1)",
                 finding(VECTORS.join("warning/method-read-without-call.html").read)
    assert_match(/context or network information \(navigator\.connection stored or passed on in inline script 1\)/,
                 finding(VECTORS.join("warning/interface-stored.html").read))
    assert_match(/motion or orientation sensors \("deviceorientation" passed to a function other than addEventListener/,
                 finding(VECTORS.join("warning/event-passed-to-function.html").read))
    assert_match(/location \(\.geolocation mentioned, but the script cannot be read in inline script 1\)/,
                 finding(VECTORS.join("warning/script-not-readable.html").read))
  end

  test "a use and a doubt give only the violation" do
    o, = outcome(page("<script>const c = navigator.connection; navigator.vibrate(5);</script>"))
    assert_equal [["violation", "the HTML view uses functions of the reader's device: " \
                                "device behaviour (navigator.vibrate() in inline script 1)"]],
                 o.messages.map { |m| m.values_at(:severity, :message) }
  end

  test "a script cut after MAX_SCRIPT_BYTES is read up to the cut" do
    script = "navigator.geolocation.watchPosition(f);\nconst text = '#{'x' * HtmlCheck::MAX_SCRIPT_BYTES}';\n"
    resolver = FakeResolver.new(page('<script src="/big.js"></script>'), scripts: { "https://dpp.example.org/big.js" => script })
    message = HtmlCheck.new(CHECK, UPI, resolver).outcome.messages.first
    assert_equal "violation", message[:severity]
    assert_match(%r{location \(\.watchPosition\(\) in https://dpp\.example\.org/big\.js\)}, message[:message])
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
