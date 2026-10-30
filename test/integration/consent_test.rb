require "test_helper"

# Consent banner and Google Ads conversion (README "Consent banner and
# conversion"): without a conversion ID nothing of it is on the page; with an
# ID the page embeds /consent.js and the "Cookie settings" link, and still
# names no Google address itself.
class ConsentTest < ActionDispatch::IntegrationTest
  GOOGLE = /googletagmanager|google-analytics|googleadservices|googlesyndication|doubleclick|gstatic|gtag/i
  ID = "AW-894120911".freeze
  LABEL = "VeXiCK3G_K4dEM_nrKoD".freeze

  def with_env(values)
    previous = values.keys.to_h { |k| [k, ENV[k]] }
    values.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def footer = response.body[%r{<footer>.*</footer>}m]

  test "without GOOGLE_ADS_ID: no script, no cookie settings, and /consent.js does nothing" do
    with_env("GOOGLE_ADS_ID" => nil, "GOOGLE_ADS_LABEL_LINTER_CHECK" => LABEL) do
      get "/"
      assert_response :success
      assert_not_includes response.body, %(<script src="/consent.js")
      assert_not_includes response.body, "data-consent-settings"
      assert_not_includes response.body, "Cookie settings"
      assert_no_match GOOGLE, response.body
      assert_includes footer, %(<a href="https://dpp-service.ownyourdata.eu/privacy">Privacy</a>)
      get "/consent.js"
      assert_response :success
      assert_equal "text/javascript", response.media_type
      assert_equal "/* Conversion measurement is not configured on this instance. */\n", response.body
    end
  end

  test "an empty or malformed GOOGLE_ADS_ID counts as missing" do
    ["", " ", "AW-12", "UA-123456789", "AW-894120911x"].each do |value|
      with_env("GOOGLE_ADS_ID" => value) do
        assert_not GoogleAds.enabled?, value.inspect
        get "/"
        assert_not_includes response.body, %(<script src="/consent.js"), value.inspect
      end
    end
  end

  test "with GOOGLE_ADS_ID: the page embeds /consent.js and the cookie settings, and names no Google address" do
    with_env("GOOGLE_ADS_ID" => ID, "GOOGLE_ADS_LABEL_LINTER_CHECK" => LABEL) do
      get "/?productId=https%3A%2F%2Fdpp.example%2F01%2F1"
      assert_response :success
      head = response.body[%r{<head>.*</head>}m]
      assert_includes head, %(<script src="/consent.js" defer></script>)
      assert_includes footer, %(<a href="https://dpp-service.ownyourdata.eu/privacy">Privacy</a>)
      assert_includes footer, %(<a href="https://dpp-service.ownyourdata.eu/privacy#conversion-tracking" data-consent-settings hidden>Cookie settings</a>)
      assert_no_match GOOGLE, response.body, "the page itself loads nothing from Google"
      assert_not_includes response.body, ID, "the ID is only in /consent.js"
    end
  end

  test "/consent.js carries the ID and the conversion, sets no config and passes no user data" do
    with_env("GOOGLE_ADS_ID" => ID, "GOOGLE_ADS_LABEL_LINTER_CHECK" => LABEL) do
      get "/consent.js"
      assert_response :success
      assert_equal "text/javascript", response.media_type
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      body = response.body
      assert_includes body, %({"id":"#{ID}","conversions":{"linter_check":"#{ID}/#{LABEL}"}})
      assert_no_match(/gtag\("config"/, body, "the tag is not configured for the ID")
      assert_includes body, %(gtag("consent", "update", { ad_storage: "granted", ad_user_data: "granted" });)
      assert_includes body, "ad_personalization: \"denied\""
      assert_includes body, "analytics_storage: \"denied\""
      assert_includes body, "allow_ad_personalization_signals: false"
      assert_includes body, "page_location: ids.conversionLocation(window.location.href)"
      assert_no_match(/(?<!ad_)user_data|enhanced_conversions|productId|summary|criteria/, body, "no user data, no product identifier, no result")
    end
  end

  test "a conversion without a valid label is not configured, the banner still is" do
    with_env("GOOGLE_ADS_ID" => ID, "GOOGLE_ADS_LABEL_LINTER_CHECK" => "not a label") do
      get "/consent.js"
      assert_includes response.body, %({"id":"#{ID}","conversions":{}})
    end
  end

  test "the page sends the conversion once per completed check, through consent.js only" do
    get "/"
    script = response.body.scan(%r{<script>(.*?)</script>}m).last.first
    assert_equal 1, script.scan("oydConsent.convert(").size
    assert_match(/render\(outcome\.data\);\s*\/\/[^\n]*\n\s*\/\/[^\n]*\n\s*if \(window\.oydConsent\) window\.oydConsent\.convert\("linter_check"\);/, script)
    assert_includes script, "history.replaceState(null, \"\", DppLintClickIds.queryWithProductId(location.search, productId));"
    assert_includes response.body, HomeController::CLICK_IDS
  end
end
