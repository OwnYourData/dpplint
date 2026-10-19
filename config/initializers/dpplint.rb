# Locations and services dpplint depends on. All of them live inside the image,
# except didlint, which checks DIDs (DIDLINT_URL). A check waits for didlint at
# most DIDLINT_TIMEOUT seconds per request and DIDLINT_BUDGET seconds in total.
# SOYA_CONTEXT.json records which SOyA context the structures of the image were
# built with (fetched or a cached copy, and from when).
Rails.application.config.x.dpplint = ActiveSupport::OrderedOptions.new.tap do |c|
  c.soya_web_cli    = ENV.fetch("SOYA_WEB_CLI", "http://127.0.0.1:8080")
  c.didlint         = ENV.fetch("DIDLINT_URL", "https://didlint.ownyourdata.eu")
  c.didlint_timeout = ENV.fetch("DIDLINT_TIMEOUT", "10").to_f
  c.didlint_budget  = ENV.fetch("DIDLINT_BUDGET", "20").to_f
  c.criteria_dir    = ENV.fetch("DPP_CRITERIA_DIR", Rails.root.join("criteria").to_s)
  c.structures_dir  = ENV.fetch("DPP_STRUCTURES_DIR", Rails.root.join("structures").to_s)
  c.criteria_ref    = (File.read(Rails.root.join("CRITERIA_REF")).strip rescue "unknown")
  c.soya_context    = (JSON.parse(File.read(ENV.fetch("SOYA_CONTEXT_FILE", Rails.root.join("SOYA_CONTEXT.json").to_s))) rescue {})
end
