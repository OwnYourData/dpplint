# Runs a criterion with check.type links (DPP-DAT-011): every element of
# check.element_type (RelatedResource, EN 18223 4.1.2.7), wherever it occurs
# in the passport, must carry the attributes in check.required and a URL that
# answers. A URL that does not answer is reported with the severity in
# check.unreachable (default warning), so that outages of third-party sites do
# not fail the passport. At most MAX_LINKS URLs are requested, in parallel.
class LinksCheck
  MAX_LINKS = 20

  def initialize(check, passport, resolver: HttpResolver.new)
    @check = check
    @passport = passport
    @resolver = resolver
  end

  def resources = collect(@passport)

  # Messages as [{severity:, message:}]
  def messages
    out = []
    to_probe = []
    resources.each_with_index do |r, i|
      label = r["elementId"].is_a?(String) ? r["elementId"] : "#{@check['element_type']} #{i + 1}"
      Array(@check["required"]).each do |attr|
        out << violation("#{label}: #{attr} is missing") unless r[attr].is_a?(String) && r[attr].strip.present?
      end
      url = r["url"]
      next unless url.is_a?(String) && url.strip.present?

      if url.match?(%r{\Ahttps?://[^/\s]+}i)
        to_probe << [label, url.strip]
      else
        out << violation("#{label}: url #{url} is not an absolute HTTP(S) URL")
      end
    end
    out + reachability(to_probe)
  end

  private

  def reachability(links)
    unique = links.uniq { |_, url| url }
    out = []
    if unique.size > MAX_LINKS
      out << warning("only the first #{MAX_LINKS} of #{unique.size} URLs were requested")
      unique = unique.first(MAX_LINKS)
    end
    results = unique.map { |label, url| Thread.new { [label, url, @resolver.probe(url)] } }.map(&:value)
    severity = @check["unreachable"] == "error" ? "violation" : "warning"
    results.each do |label, url, res|
      next if res.error.nil? && res.status.between?(200, 399)

      out << { severity: severity, message: "#{label}: #{url} does not answer (#{res.error || "HTTP #{res.status}"})" }
    end
    out
  end

  def collect(node)
    case node
    when Hash
      own = node["objectType"] == @check["element_type"] ? [node] : []
      own + node.values.flat_map { |v| collect(v) }
    when Array then node.flat_map { |v| collect(v) }
    else []
    end
  end

  def violation(message) = { severity: "violation", message: message }
  def warning(message) = { severity: "warning", message: message }
end
