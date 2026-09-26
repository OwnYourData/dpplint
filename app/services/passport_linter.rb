# Runs the passport criteria of dpp-criteria against one passport.
#
# Criteria with check.type shacl are validated through the SOyA web-cli:
# acquire and validate against the structure named in the criterion. A result
# belongs to a criterion when its message starts with "[<criterion ID>]".
# Criteria with check.type resolve request the product identifier itself and
# therefore need one (GET /api/v1/validate/<product identifier>). Criteria with
# check.type did hand the DIDs of the passport to didlint.
class PassportLinter
  SH = "http://www.w3.org/ns/shacl#".freeze

  def initialize(catalogue: CriteriaCatalogue.new, web_cli: SoyaWebCli.new, resolver: HttpResolver.new, didlint: Didlint.new)
    @catalogue = catalogue
    @web_cli = web_cli
    @resolver = resolver
    @didlint = didlint
  end

  def run(passport:, product_id: nil, retrieval: nil)
    @product_id = product_id
    reports = {}
    criteria = @catalogue.passport_criteria.map { |c| evaluate(c, passport, reports) }
    counted = criteria.select { |c| %w[passed warning failed].include?(c[:result]) }
    passed = counted.count { |c| c[:result] != "failed" }
    {
      productId: product_id || passport&.dig("uniqueProductIdentifier"),
      retrieval: retrieval,
      summary: {
        text: "#{passed} of #{counted.size} automated checks passed",
        passed: passed,
        failed: counted.size - passed,
        warnings: criteria.count { |c| c[:result] == "warning" },
        skipped: criteria.count { |c| c[:result] == "skipped" }
      },
      criteria: criteria,
      notice: "Results of automated checks only. They are no certification and establish no presumption of conformity.",
      "dpp-criteria": Rails.configuration.x.dpplint.criteria_ref
    }
  end

  private

  def evaluate(criterion, passport, reports)
    base = { id: criterion["id"], title: criterion["title"], level: criterion["level"] }
    check = criterion["check"] || {}

    return resolve(base, check) if check["type"] == "resolve"
    unless %w[shacl did].include?(check["type"])
      return base.merge(result: "skipped", reason: "check type #{check['type']} is not implemented in this version")
    end
    return base.merge(result: "skipped", reason: "passport could not be retrieved") if passport.nil?
    return did(base, check, passport) if check["type"] == "did"

    if criterion["applies_if"] && !AppliesIf.holds?(criterion["applies_if"], passport)
      return base.merge(result: "skipped", reason: "condition not met")
    end
    return base.merge(result: "skipped", reason: "no shapes available for #{check['shapes_select']}") unless check["structure"]

    report = (reports[check["structure"]] ||= validate(check["structure"], passport))
    return base.merge(result: "skipped", reason: report[:error]) if report[:error]

    own = report[:results].select { |r| r[:message].start_with?("[#{criterion['id']}]") }
    messages = own.map { |r| { severity: r[:severity], message: r[:message].delete_prefix("[#{criterion['id']}]").strip } }
    base.merge(result: result_for(messages), messages: messages)
  end

  def resolve(base, check)
    return base.merge(result: "skipped", reason: "rated by dpp-validator from its daily runs") if check["history"]
    return base.merge(result: "skipped", reason: "needs a product identifier") if @product_id.blank?

    messages = ResolveCheck.new(check, @product_id, @resolver).violations.map { |m| { severity: "violation", message: m } }
    base.merge(result: messages.empty? ? "passed" : "failed", messages: messages)
  end

  def did(base, check, passport)
    did_check = DidCheck.new(check, passport, didlint: @didlint, resolver: @resolver)
    return base.merge(result: "skipped", reason: "no DID in #{check['paths'].join(', ')}") if did_check.dids.empty?

    messages = did_check.messages
    base.merge(result: result_for(messages), messages: messages)
  rescue Didlint::Unavailable => e
    base.merge(result: "skipped", reason: e.message)
  end

  def result_for(messages)
    if messages.any? { |m| m[:severity] == "violation" } then "failed"
    elsif messages.any? then "warning"
    else "passed"
    end
  end

  def validate(structure, passport)
    unless File.file?(File.join(Rails.configuration.x.dpplint.structures_dir, structure))
      return { error: "SOyA structure #{structure} is not available" }
    end

    data = @web_cli.validate(structure, @web_cli.acquire(structure, passport))
    missing = Array(data["classChecks"]).map { |c| "#{c['message']}: #{c['name']}" }
    return { error: missing.join("; ") } if missing.any?

    results = Array(data["results"]).map do |r|
      { severity: r.dig("severity", "value").to_s.delete_prefix(SH).downcase,
        message: Array.wrap(r["message"]).first&.dig("value").to_s }
    end
    { results: results }
  rescue SoyaWebCli::Error => e
    { error: e.message }
  end
end
