# Which SOyA context the structures of this image were built with. The
# structures embed the context, so dpplint does not contact SOyA when it checks
# a passport. If the context could not be retrieved when the image was built,
# the build used a cached copy (dpp-criteria, soya/context/); results checked
# against such a structure say so.
class SoyaContext
  def initialize(stand = Rails.configuration.x.dpplint.soya_context, criteria_ref = Rails.configuration.x.dpplint.criteria_ref)
    @stand = stand.is_a?(Hash) ? stand : {}
    @criteria_ref = criteria_ref
  end

  # For /version: when the structures were built and with which contexts, or nil if not recorded.
  def version_info
    return nil if @stand.empty?

    { built_at: @stand["built_at"],
      contexts: contexts.map { |c| c.slice("url", "source", "fetched_at") } }
  end

  # Notices for the structures a check used whose context is a cached copy.
  def notices(structures)
    Array(structures).uniq.filter_map do |name|
      context = context_of(name)
      next unless context && context["source"] == "cached"

      "Structure #{name} (dpp-criteria #{@criteria_ref}) was evaluated with a cached copy of the SOyA context " \
        "#{context['url']} from #{context['fetched_at']}; SOyA was not reachable when this image was built."
    end
  end

  private

  def contexts = Array(@stand["contexts"]).select { |c| c.is_a?(Hash) }

  def context_of(name)
    url = Array(@stand["structures"]).find { |s| s.is_a?(Hash) && s["name"] == name }&.dig("context")
    url && contexts.find { |c| c["url"] == url }
  end
end
