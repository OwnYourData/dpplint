# Locations and services dpplint depends on. All of them live inside the image,
# except didlint, which checks DIDs (DIDLINT_URL).
Rails.application.config.x.dpplint = ActiveSupport::OrderedOptions.new.tap do |c|
  c.soya_web_cli   = ENV.fetch("SOYA_WEB_CLI", "http://127.0.0.1:8080")
  c.didlint        = ENV.fetch("DIDLINT_URL", "https://didlint.ownyourdata.eu")
  c.criteria_dir   = ENV.fetch("DPP_CRITERIA_DIR", Rails.root.join("criteria").to_s)
  c.structures_dir = ENV.fetch("DPP_STRUCTURES_DIR", Rails.root.join("structures").to_s)
  c.criteria_ref   = (File.read(Rails.root.join("CRITERIA_REF")).strip rescue "unknown")
end
