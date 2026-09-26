# Reads the criteria of dpp-criteria that are baked into the image.
class CriteriaCatalogue
  def initialize(dir = Rails.configuration.x.dpplint.criteria_dir)
    @dir = dir
  end

  # Automated criteria whose target is the passport, in ID order.
  def passport_criteria
    all.select { |c| c["target"] == "passport" && c["method"] == "automated" && c["status"] != "deprecated" }
  end

  def all
    @all ||= Dir.glob(File.join(@dir, "*", "*.yaml")).sort.map { |f| YAML.safe_load_file(f) }.sort_by { |c| c["id"] }
  end
end
