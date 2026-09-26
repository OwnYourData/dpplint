# Runs a criterion with check.type did (DPP-ID-016): every DID found at the
# given paths of the passport must pass didlint (DID Core, DID Resolution);
# verifiable presentations linked from the DID document (service type
# LinkedVerifiablePresentation) must use the VC Data Model 2.0 context.
# Values that are not DIDs are ignored.
class DidCheck
  VC2_CONTEXT = "https://www.w3.org/ns/credentials/v2".freeze
  LINKED_VP = "LinkedVerifiablePresentation".freeze

  def initialize(check, passport, didlint: Didlint.new, resolver: HttpResolver.new)
    @check = check
    @passport = passport
    @didlint = didlint
    @resolver = resolver
  end

  def dids
    Array(@check["paths"]).filter_map do |path|
      value = @passport[path.delete_prefix("$.")]
      value if value.is_a?(String) && value.start_with?("did:")
    end.uniq
  end

  # Messages as [{severity:, message:}]
  def messages
    dids.flat_map { |did| lint(did) + credentials(did) }
  end

  private

  def lint(did)
    result = @didlint.validate(did)
    return [] if result["valid"] == true

    details = Array(result["errors"]).map { |e| e["error"] || e[:error] }.compact
    [violation("#{did}: #{([result['error']] + details).compact.join('; ').presence || 'not valid according to didlint'}")]
  end

  def credentials(did)
    doc = @didlint.resolve(did)
    return [] unless doc

    endpoints = Array(doc["service"]).select { |s| Array(s["type"]).include?(LINKED_VP) }
                                     .flat_map { |s| Array(s["serviceEndpoint"]) }
                                     .select { |e| e.is_a?(String) }
    return [warning("#{did}: no linked verifiable credentials found (no service of type #{LINKED_VP})")] if endpoints.empty?

    endpoints.flat_map { |url| presentation(did, url) }
  end

  def presentation(did, url)
    res = @resolver.get(url, accept: "application/json")
    return [warning("#{did}: linked presentation #{url} could not be retrieved (#{res.error || "HTTP #{res.status}"})")] unless res.success?

    json = JSON.parse(res.body) rescue nil
    return [warning("#{did}: linked presentation #{url} is not JSON; only JSON-LD presentations are checked")] unless json.is_a?(Hash)
    return [] if Array(json["@context"]).include?(VC2_CONTEXT)

    [violation("#{did}: linked presentation #{url} does not use the VC Data Model 2.0 context #{VC2_CONTEXT}")]
  end

  def violation(message) = { severity: "violation", message: message }
  def warning(message) = { severity: "warning", message: message }
end
