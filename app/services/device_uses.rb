# Where a piece of JavaScript uses functions of the reader's device
# (device_features in CRITERIA-FORMAT.md of dpp-criteria, DPP-SEC-021).
#
# Only code counts, read with JsTokens: comments, and names inside strings,
# template literals and regular expressions, are not code. A use is
# - a call of a device method (METHODS, navigator.vibrate) on any object, also
#   as obj["name"](…), .call(…) or .apply(…);
# - a call of a method of a device interface (INTERFACES: mediaDevices,
#   pushManager, navigator.contacts, .bluetooth, .usb, .serial, .hid,
#   .wakeLock), or reading a property of navigator.connection;
# - a permission request: requestPermission of Notification,
#   DeviceMotionEvent, DeviceOrientationEvent or IdleDetector;
# - new with Notification, NDEFReader, IdleDetector or a sensor class;
# - a listener for devicemotion, deviceorientation, deviceorientationabsolute
#   or beforeinstallprompt, registered with addEventListener or on, or by
#   assigning the on… property;
# - transport: ["sms"] (a one-time code from an SMS).
#
# Hooking into an interface is not a use. Polyfills such as zone.js test
# whether the interface exists, pass it to a function together with the
# names of its methods and replace those methods with wrappers; feature
# detection only tests whether it exists. None of this calls a device method.
#
# A doubt is a reference after which a use may follow that cannot be seen
# without running the script:
# - a device method, a member of a device interface or requestPermission read
#   without being called or replaced (it may be called later under another
#   name);
# - a device interface stored or passed on in another way than above (its
#   members may be used under another name);
# - one of the event names passed as an argument to another function than
#   addEventListener or on (frameworks register listeners that way).
#
# If the text cannot be read as JavaScript (JsTokens::Error), the names of
# the device interfaces are searched for as text (MENTIONS) and every one
# found is a doubt.
class DeviceUses
  Finding = Struct.new(:kind, :label, :text)

  LOCATION = "location".freeze
  MEDIA = "camera, microphone or screen".freeze
  NOTIFICATIONS = "notifications".freeze
  CONTACTS = "contacts".freeze
  DEVICES = "Bluetooth, USB, serial, HID or NFC".freeze
  SENSORS = "motion or orientation sensors".freeze
  CONTEXT = "context or network information".freeze
  OTP = "one-time codes from SMS".freeze
  APPS = "app installation".freeze
  BEHAVIOUR = "device behaviour".freeze
  LABELS = [LOCATION, MEDIA, NOTIFICATIONS, CONTACTS, DEVICES, SENSORS, CONTEXT, OTP, APPS, BEHAVIOUR].freeze

  # Device methods: calling one on any object is a use.
  METHODS = {
    "getCurrentPosition" => LOCATION, "watchPosition" => LOCATION, "getUserMedia" => MEDIA, "getDisplayMedia" => MEDIA,
    "showNotification" => NOTIFICATIONS, "getBattery" => CONTEXT, "getInstalledRelatedApps" => APPS
  }.freeze
  # Device methods of navigator.
  NAVIGATOR_METHODS = { "vibrate" => BEHAVIOUR }.freeze
  # Device interfaces: name => [label, object they are read from (nil: any),
  # their members]. The members of geolocation that use the device are
  # METHODS; clearWatch only ends a use.
  INTERFACES = {
    "geolocation" => [LOCATION, nil, %w[getCurrentPosition watchPosition clearWatch]],
    "mediaDevices" => [MEDIA, nil, %w[getUserMedia getDisplayMedia enumerateDevices getSupportedConstraints selectAudioOutput]],
    "pushManager" => [NOTIFICATIONS, nil, %w[subscribe getSubscription permissionState]],
    "contacts" => [CONTACTS, "navigator", %w[select getProperties]],
    "bluetooth" => [DEVICES, "navigator", %w[requestDevice getDevices getAvailability]],
    "usb" => [DEVICES, "navigator", %w[requestDevice getDevices]],
    "serial" => [DEVICES, "navigator", %w[requestPort getPorts]],
    "hid" => [DEVICES, "navigator", %w[requestDevice getDevices]],
    "wakeLock" => [BEHAVIOUR, "navigator", %w[request]],
    "connection" => [CONTEXT, "navigator", %w[effectiveType downlink downlinkMax rtt saveData type]]
  }.freeze
  # Classes whose requestPermission asks for a device permission.
  PERMISSION_CLASSES = {
    "Notification" => NOTIFICATIONS, "DeviceMotionEvent" => SENSORS, "DeviceOrientationEvent" => SENSORS,
    "IdleDetector" => CONTEXT
  }.freeze
  # Classes whose construction uses a device function.
  CONSTRUCTORS = {
    "Notification" => NOTIFICATIONS, "NDEFReader" => DEVICES, "IdleDetector" => CONTEXT
  }.merge(%w[Accelerometer Gyroscope Magnetometer AbsoluteOrientationSensor RelativeOrientationSensor
             LinearAccelerationSensor GravitySensor AmbientLightSensor].to_h { |c| [c, SENSORS] }).freeze
  # Events whose listeners use a device function.
  EVENTS = {
    "devicemotion" => SENSORS, "deviceorientation" => SENSORS, "deviceorientationabsolute" => SENSORS,
    "beforeinstallprompt" => APPS
  }.freeze
  ASSIGNMENTS = %w[= ||= &&= ??=].freeze
  # Tokens after and before an interface that only test whether it exists.
  TESTS_AFTER = %w[&& ? === !== == !=].freeze
  TESTS_BEFORE = %w[! === !== == != typeof in instanceof].freeze
  # A "[" or "(" after one of these keywords is no member access or call.
  KEYWORDS = (JsTokens::BEFORE_EXPRESSION + %w[if while for with switch catch let const var]).freeze

  # Every finding, also of MENTIONS, contains one of these names; a script
  # without any of them is not read further.
  NEEDED = Regexp.union((METHODS.keys + NAVIGATOR_METHODS.keys + INTERFACES.keys + CONSTRUCTORS.keys + EVENTS.keys +
                         %w[requestPermission sms PushManager OTPCredential]).uniq)
  # The interface names searched for as text if the script cannot be read.
  MENTIONS = [
    [LOCATION, /\.geolocation\b|\bgetCurrentPosition\b|\bwatchPosition\b/],
    [MEDIA, /\bgetUserMedia\b|\bgetDisplayMedia\b|\.mediaDevices\b/],
    [NOTIFICATIONS, /\bNotification\s*\.\s*requestPermission\b|\bnew\s+Notification\s*\(|\.showNotification\s*\(|\b[Pp]ushManager\b/],
    [CONTACTS, /\bnavigator\s*\.\s*contacts\b/],
    [DEVICES, /\bnavigator\s*\.\s*(?:bluetooth|usb|serial|hid)\b|\bNDEFReader\b/],
    [SENSORS,
     /\b(?:on)?(?:devicemotion|deviceorientation(?:absolute)?)\b|\bDevice(?:Motion|Orientation)Event\s*\.\s*requestPermission\b|\bnew\s+(?:Accelerometer|Gyroscope|Magnetometer|AbsoluteOrientationSensor|RelativeOrientationSensor|LinearAccelerationSensor|GravitySensor|AmbientLightSensor)\s*\(/],
    [CONTEXT, /\bnavigator\s*\.\s*connection\b|\bgetBattery\s*\(|\bIdleDetector\b/],
    [OTP, /\bOTPCredential\b|\btransport\s*:\s*\[\s*["']sms["']/],
    [APPS, /\bbeforeinstallprompt\b|\bgetInstalledRelatedApps\b/],
    [BEHAVIOUR, /\bnavigator\s*\.\s*(?:wakeLock|vibrate)\b/]
  ].freeze

  # Findings in a piece of script, one per label: a use if there is one,
  # otherwise a doubt; uses first. partial: the text is the start of a longer
  # script.
  def self.call(code, partial: false)
    code = code.to_s
    code = code.dup.force_encoding(Encoding::UTF_8).scrub unless code.encoding == Encoding::UTF_8 && code.valid_encoding?
    return [] unless code.match?(NEEDED)

    new(JsTokens.call(code, partial: partial)).findings
  rescue JsTokens::Error
    MENTIONS.filter_map do |label, pattern|
      match = code.match(pattern)
      Finding.new(:doubt, label, "#{match[0].gsub(/\s+/, ' ')} mentioned, but the script cannot be read") if match
    end
  end

  def initialize(tokens)
    @t = tokens
    @found = {}
    @open = []    # for each token: index of the innermost bracket around it
    @opening = {} # index of a closing bracket => index of its opening one
    @closing = {} # and the other way round
    brackets
  end

  def findings
    @t.each_with_index do |tok, i|
      case tok.type
      when :name then name_at(i, tok.value)
      when :string then string_at(i, tok.value)
      end
    end
    @found.values.sort_by { |f| [f.kind == :use ? 0 : 1, LABELS.index(f.label)] }
  end

  private

  def brackets
    stack = []
    @t.each_with_index do |tok, k|
      @open << stack.last
      next unless tok.type == :punct

      case tok.value
      when "(", "[", "{" then stack.push(k)
      when ")", "]", "}"
        o = stack.pop
        (@opening[k] = o) && (@closing[o] = k) if o
      end
    end
  end

  def name_at(i, v)
    member(i, v, i) if member?(i)
    construction(i) if v == "new"
    listener(i, v) if punct?(i + 1, "(")
    handler_property(i, v) if v.start_with?("on") && EVENTS.key?(v[2..])
    sms(i) if v == "transport"
  end

  # A string is a member name in obj["name"], or an event name passed to a
  # function.
  def string_at(i, v)
    if punct?(i - 1, "[") && punct?(i + 1, "]") && expression_end?(i - 2)
      member(i, v, i + 1)
    elsif EVENTS.key?(v) && (p = call_parenthesis(i)) && !(p == i - 1 && listener?(p - 1))
      doubt(EVENTS[v], "\"#{v}\" passed to a function other than addEventListener")
    end
  end

  # The member v of an object, read at index i and ending at index e ("]" for
  # obj["v"]); the object is the token before "." or "[".
  def member(i, v, e)
    object = value(i - 2)
    if (label = METHODS[v]) then method_use(e, label, ".#{v}")
    elsif (label = NAVIGATOR_METHODS[v]) && object == "navigator" then method_use(e, label, "navigator.#{v}")
    elsif v == "requestPermission" && (label = PERMISSION_CLASSES[object])
      method_use(e, label, "#{object}.requestPermission")
    end
    interface(i, e, v, object)
  end

  def method_use(e, label, text)
    if called?(e) then use(label, "#{text}()")
    elsif !assigned?(e) then doubt(label, "#{text} read without a call")
    end
  end

  def interface(i, e, v, object)
    label, from, members = INTERFACES[v]
    return unless label && (from.nil? || object == from)

    text = "#{from ? "#{from}." : '.'}#{v}"
    if (m = member_after(e))
      interface_member(label, v, text, *m)
    elsif !assigned?(e) && !tested?(i, e) && !hooked?(i, members)
      doubt(label, "#{text} stored or passed on")
    end
  end

  def interface_member(label, v, text, name, e)
    return if v == "geolocation" || assigned?(e)

    if v == "connection" then use(label, "#{text}.#{name}")
    elsif called?(e) then use(label, "#{text}.#{name}()")
    else doubt(label, "#{text}.#{name} read without a call")
    end
  end

  # The member read right after index e: [name, index of its last token].
  def member_after(e)
    if (punct?(e + 1, ".") || punct?(e + 1, "?.")) && @t[e + 2]&.type == :name
      [@t[e + 2].value, e + 2]
    elsif punct?(e + 1, "[") && @t[e + 2]&.type == :string && punct?(e + 3, "]")
      [@t[e + 2].value, e + 3]
    elsif punct?(e + 1, "?.") && punct?(e + 2, "[") && @t[e + 3]&.type == :string && punct?(e + 4, "]")
      [@t[e + 3].value, e + 4]
    end
  end

  # Whether the interface read at index i (ending at e) is only tested:
  # a && …, a ? …, a === …, !a, typeof a, "x" in a, or in the head of if or
  # while.
  def tested?(i, e)
    return true if TESTS_AFTER.include?(punct_value(e + 1))

    s = chain_start(i)
    return true if TESTS_BEFORE.include?(punct_value(s - 1) || value(s - 1))

    (p = @open[i]) && punct?(p, "(") && %w[if while].include?(value(p - 1))
  end

  # Whether the interface read at index i is passed to a function together
  # with the name of one of its members, as hooks do:
  # wrap(navigator.geolocation, ["getCurrentPosition", "watchPosition"]).
  def hooked?(i, members)
    p = call_parenthesis(chain_start(i))
    return false unless p

    ((p + 1)...(@closing[p] || @t.size)).any? { |k| @t[k].type == :string && members.include?(@t[k].value) }
  end

  # The first token of the member chain whose last member is at index i
  # (a.b["c"](x).d: a).
  def chain_start(i)
    k = i
    loop do
      intro = k - 1
      return k unless punct?(intro, ".") || punct?(intro, "?.") || (punct?(intro, "[") && @t[k].type == :string)

      o = intro - 1
      if value(o) then k = o
      elsif punct?(o, "]") && (b = @opening[o]) && @t[b + 1]&.type == :string then k = b + 1
      elsif punct?(o, ")") && (b = @opening[o]) && value(b - 1) then k = b - 1
      else return [o, 0].max
      end
    end
  end

  # If the token at index i is an argument of a call: the index of the "(".
  # A call may follow a function expression: function (a, b) {…}(x, y).
  def call_parenthesis(i)
    p = @open[i]
    return unless (punct?(i - 1, "(") || punct?(i - 1, ",")) && p && punct?(p, "(")

    p if expression_end?(p - 1) || punct?(p - 1, "}")
  end

  # new C(…), also new window.C(…).
  def construction(i)
    j = i + 1
    j += 2 while value(j) && punct?(j + 1, ".")
    c = value(j)
    use(CONSTRUCTORS[c], "new #{c}()") if CONSTRUCTORS.key?(c)
  end

  # addEventListener("devicemotion", …) or .on("devicemotion", …).
  def listener(i, v)
    return unless listener?(i)

    event = @t[i + 2]
    use(EVENTS[event.value], "#{v}(\"#{event.value}\")") if event&.type == :string && EVENTS.key?(event.value)
  end

  def listener?(i) = value(i) == "addEventListener" || (value(i) == "on" && member?(i))

  # window.ondevicemotion = …, but not = null.
  def handler_property(i, v)
    return unless assigned?(i) && value(i + 2) != "null"

    use(EVENTS[v[2..]], "#{v} =")
  end

  def sms(i)
    return unless punct?(i + 1, ":") && punct?(i + 2, "[") && @t[i + 3]&.type == :string && @t[i + 3].value == "sms"

    use(OTP, "transport: [\"sms\"]")
  end

  # The member ending at index e is called: m(…), m?.(…), m.call(…),
  # m.apply(…).
  def called?(e)
    return true if punct?(e + 1, "(") || (punct?(e + 1, "?.") && punct?(e + 2, "("))

    (punct?(e + 1, ".") || punct?(e + 1, "?.")) && %w[call apply].include?(value(e + 2)) && punct?(e + 3, "(")
  end

  # The member ending at index e is replaced: m = …
  def assigned?(e) = ASSIGNMENTS.include?(punct_value(e + 1))

  def member?(i) = punct?(i - 1, ".") || punct?(i - 1, "?.")

  # Whether the token at index i ends an expression, so that "(" or "["
  # after it is a call or a member access.
  def expression_end?(i)
    return false if i.negative? || @t[i].nil?

    tok = @t[i]
    case tok.type
    when :name then !KEYWORDS.include?(tok.value)
    when :punct then %w[) \]].include?(tok.value)
    else %i[string template regexp private].include?(tok.type)
    end
  end

  def punct?(i, v) = punct_value(i) == v

  def punct_value(i) = i >= 0 && @t[i]&.type == :punct ? @t[i].value : nil

  def value(i) = i >= 0 && @t[i]&.type == :name ? @t[i].value : nil

  def use(label, text)
    return if @found[label]&.kind == :use

    @found[label] = Finding.new(:use, label, text)
  end

  def doubt(label, text)
    @found[label] ||= Finding.new(:doubt, label, text)
  end
end
