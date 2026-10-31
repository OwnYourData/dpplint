# GET /consent.js: the consent banner and the Google Ads conversion tag of the
# start page (README "Consent banner and conversion"). The start page embeds it
# only when GoogleAds is enabled; without a conversion ID it is an empty
# script that does nothing.
class ConsentController < ActionController::Base
  SCRIPT = Rails.root.join("app/javascript/consent.js").read.freeze

  # A script meant to be embedded by the start page; there is no session to
  # protect.
  skip_forgery_protection

  def show
    config = GoogleAds.client_config
    body = if config
             "(function (config) {\n#{SCRIPT}\n})(#{ERB::Util.json_escape(config.to_json)});\n"
           else
             "/* Conversion measurement is not configured on this instance. */\n"
           end
    response.set_header("Cache-Control", "public, max-age=300")
    response.set_header("X-Content-Type-Options", "nosniff")
    render plain: body, content_type: "text/javascript"
  end
end
