# Reads the criteria of dpp-criteria that are baked into the image.
class CriteriaCatalogue
  DESCRIPTION_URL = "https://github.com/OwnYourData/dpp-criteria/blob/%<ref>s/criteria/README.md#%<anchor>s".freeze

  def initialize(dir = Rails.configuration.x.dpplint.criteria_dir, ref = Rails.configuration.x.dpplint.criteria_ref)
    @dir = dir
    @ref = ref
  end

  # Link to the readable description of a criterion in criteria/README.md of
  # the dpp-criteria commit in the image (anchor: the ID in lower case). nil if
  # that commit has no such page or the commit is not known.
  def description_url(id)
    return nil if @ref.blank? || @ref == "unknown" || !File.file?(File.join(@dir, "README.md"))

    format(DESCRIPTION_URL, ref: @ref, anchor: id.to_s.downcase)
  end

  # Automated criteria whose target is the passport, in ID order.
  def passport_criteria
    all.select { |c| c["target"] == "passport" && c["method"] == "automated" && c["status"] != "deprecated" }
  end

  def all
    @all ||= Dir.glob(File.join(@dir, "*", "*.yaml")).sort.map { |f| YAML.safe_load_file(f) }.sort_by { |c| c["id"] }
  end
end
