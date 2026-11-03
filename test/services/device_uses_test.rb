require "test_helper"

# DeviceUses: calls, permission requests and listeners count; hooks, feature
# detection and names outside code do not; references that may lead to a
# use are doubts.
class DeviceUsesTest < ActiveSupport::TestCase
  def findings(code) = DeviceUses.call(code).map { |f| [f.kind, f.label, f.text] }

  def kinds(code) = DeviceUses.call(code).map { |f| [f.kind, f.label] }

  test "hooks into device interfaces are no use" do
    [
      't.navigator&&t.navigator.geolocation&&wrap(t.navigator.geolocation,["getCurrentPosition","watchPosition"])',
      "g.navigator && g.navigator.geolocation && function (o, names) { names.forEach(function (n) { var f = o[n]; " \
      "o[n] = function () { return f.apply(this, arguments); }; }); }(g.navigator.geolocation, " \
      "['getCurrentPosition', 'watchPosition']);",
      "if (g['navigator'] && g['navigator'].geolocation) { patch(g['navigator'].geolocation, ['getCurrentPosition']); }",
      'Object.defineProperty(navigator.geolocation, "getCurrentPosition", { value: wrapped });',
      "navigator.geolocation.getCurrentPosition = wrapped; navigator.geolocation.watchPosition ||= wrapped;",
      'var events = ["devicemotion", "deviceorientation", "beforeinstallprompt"]; events.forEach(patchOnProperty);',
      "window.ondevicemotion = null;",
      'wrap(reg.pushManager, ["subscribe"]); wrap(navigator.mediaDevices, ["getUserMedia", "enumerateDevices"]);'
    ].each { |code| assert_empty findings(code), code }
  end

  test "feature detection is no use" do
    [
      'if ("geolocation" in navigator) { show(); }',
      "if (navigator.geolocation) { show(); }",
      "if (window.navigator.geolocation || legacy) { show(); }",
      "const camera = !!navigator.mediaDevices;",
      'const known = typeof navigator.connection !== "undefined";',
      "const ok = navigator.connection ? 1 : 0;",
      'const has = "getCurrentPosition" in navigator.geolocation;',
      "return navigator.wakeLock && supported;",
      "const n = navigator.connection === undefined;"
    ].each { |code| assert_empty findings(code), code }
  end

  test "names in comments, strings, template literals and regular expressions are no use" do
    [
      "// navigator.geolocation.getCurrentPosition(f)",
      "/* navigator.vibrate(200); new Notification('x') */ const a = 1;",
      'const s = "navigator.mediaDevices.getUserMedia({ video: true })";',
      "const t = `${x} navigator.getBattery() ${y}`;",
      "const r = /navigator\\.geolocation\\.watchPosition\\(/g;",
      "<!-- navigator.vibrate(1)\nconst a = 1;"
    ].each { |code| assert_empty findings(code), code }
  end

  test "own methods with the name of a device method are only counted when called" do
    assert_empty findings("class Player { getCurrentPosition() { return this.t; } }")
    assert_empty findings("const api = { watchPosition: function () {} };")
  end

  test "calls are found also next to a hook, under another name and in other forms" do
    {
      't.navigator.geolocation&&wrap(t.navigator.geolocation,["getCurrentPosition"]);navigator.geolocation.watchPosition(f)' =>
        [:use, "location", ".watchPosition()"],
      "const geo = navigator.geolocation; geo.getCurrentPosition(show);" => [:use, "location", ".getCurrentPosition()"],
      'navigator.geolocation["getCurrentPosition"](show);' => [:use, "location", ".getCurrentPosition()"],
      "navigator.geolocation.getCurrentPosition.call(navigator.geolocation, f);" => [:use, "location", ".getCurrentPosition()"],
      "navigator.geolocation?.watchPosition?.(f);" => [:use, "location", ".watchPosition()"],
      "navigator.mediaDevices.enumerateDevices().then(list);" =>
        [:use, "camera, microphone or screen", ".mediaDevices.enumerateDevices()"],
      'navigator["vibrate"](100);' => [:use, "device behaviour", "navigator.vibrate()"],
      'jQuery(window).on("deviceorientation", f);' => [:use, "motion or orientation sensors", 'on("deviceorientation")'],
      "window.ondeviceorientation = f;" => [:use, "motion or orientation sensors", "ondeviceorientation ="],
      "new window.Notification('x');" => [:use, "notifications", "new Notification()"],
      "IdleDetector.requestPermission();" => [:use, "context or network information", "IdleDetector.requestPermission()"],
      "if (navigator.connection) { show(navigator.connection.effectiveType); }" =>
        [:use, "context or network information", "navigator.connection.effectiveType"],
      "navigator.serial.requestPort();" => [:use, "Bluetooth, USB, serial, HID or NFC", "navigator.serial.requestPort()"]
    }.each { |code, expected| assert_equal [expected], findings(code), code }
  end

  test "references that may lead to a use are doubts" do
    {
      "const locate = navigator.geolocation.getCurrentPosition.bind(navigator.geolocation);" =>
        [:doubt, "location", ".getCurrentPosition read without a call"],
      "const original = navigator.geolocation.watchPosition;" => [:doubt, "location", ".watchPosition read without a call"],
      "const c = navigator.connection || navigator.mozConnection;" =>
        [:doubt, "context or network information", "navigator.connection stored or passed on"],
      "start(navigator.mediaDevices);" => [:doubt, "camera, microphone or screen", ".mediaDevices stored or passed on"],
      "const ask = Notification.requestPermission;" => [:doubt, "notifications", "Notification.requestPermission read without a call"],
      'listen("deviceorientation", handler);' =>
        [:doubt, "motion or orientation sensors", '"deviceorientation" passed to a function other than addEventListener'],
      'listen(window, "devicemotion", handler);' =>
        [:doubt, "motion or orientation sensors", '"devicemotion" passed to a function other than addEventListener'],
      "const s = 'not closed\nnavigator.geolocation;" =>
        [:doubt, "location", ".geolocation mentioned, but the script cannot be read"]
    }.each { |code, expected| assert_equal [expected], findings(code), code }
  end

  test "one finding per function: a use replaces a doubt, uses come first" do
    assert_equal [[:use, "location"]], kinds("const g = navigator.geolocation; g.watchPosition(f);")
    assert_equal [[:use, "device behaviour"], [:doubt, "context or network information"]],
                 kinds("const c = navigator.connection; navigator.vibrate(1);")
  end

  test "a script cut in the middle of a literal is read up to the cut" do
    cut = "navigator.geolocation.getCurrentPosition(f); const s = 'cut her"
    assert_equal [[:doubt, "location"]], DeviceUses.call(cut).map { |f| [f.kind, f.label] }
    assert_equal [[:use, "location"]], DeviceUses.call(cut, partial: true).map { |f| [f.kind, f.label] }
  end

  test "a script without any of the names is not read" do
    assert_empty DeviceUses.call("const s = 'not closed\nlet a = 1;")
  end
end
