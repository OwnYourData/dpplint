# Google Ads conversion measurement on the start page (ConsentController,
# app/javascript/consent.js, README "Consent banner and conversion").
#
# Everything comes from the environment. Without a valid GOOGLE_ADS_ID the
# feature is off: no consent banner, no script, no "Cookie settings" link and
# no request to Google. Without a valid label the banner still works, but no
# conversion is measured.
#
#   GOOGLE_ADS_ID                   AW-<digits>, the conversion ID of the account
#   GOOGLE_ADS_LABEL_LINTER_CHECK   a check of a product identifier completed on the start page
module GoogleAds
  ID_FORMAT = /\AAW-\d{6,15}\z/
  LABEL_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/

  CONVERSIONS = {
    "linter_check" => "GOOGLE_ADS_LABEL_LINTER_CHECK"
  }.freeze

  module_function

  # The conversion ID, or nil when it is missing or malformed. A malformed
  # value counts as missing: a typo must not load a tag nobody can account for.
  def id
    value = ENV["GOOGLE_ADS_ID"].to_s.strip
    value if value.match?(ID_FORMAT)
  end

  def enabled? = !id.nil?

  # send_to targets ("AW-…/label") by conversion name, only those with a valid
  # label.
  def conversions
    return {} unless enabled?

    CONVERSIONS.each_with_object({}) do |(name, variable), targets|
      label = ENV[variable].to_s.strip
      targets[name] = "#{id}/#{label}" if label.match?(LABEL_FORMAT)
    end
  end

  # What the consent script needs, nil when the feature is off.
  def client_config
    return nil unless enabled?

    { "id" => id, "conversions" => conversions }
  end
end
