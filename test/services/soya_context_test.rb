require "test_helper"

# The SOyA structures embed their SOyA context when the image is built. If the
# context could not be retrieved then, the build used the cached copy of
# dpp-criteria, and results checked against such a structure say so.
class SoyaContextTest < ActiveSupport::TestCase
  URL = "https://ns.ownyourdata.eu/ns/soya-context.json".freeze

  def stand(source, reason: nil)
    context = { "url" => URL, "source" => source, "fetched_at" => "2026-10-19" }
    context["reason"] = reason if reason
    { "built_at" => "2026-10-19T09:44:19.812Z",
      "structures" => [{ "name" => "DigitalProductPassport", "context" => URL }],
      "contexts" => [context] }
  end

  test "a cached context gives a notice with structure, criteria commit, context and date" do
    notices = SoyaContext.new(stand("cached", reason: "HTTP 503"), "08ee851").notices(["DigitalProductPassport"])
    assert_equal ["Structure DigitalProductPassport (dpp-criteria 08ee851) was evaluated with a cached copy of the SOyA context " \
                  "#{URL} from 2026-10-19; SOyA was not reachable when this image was built."], notices
  end

  test "a fetched context and unknown structures give no notice" do
    assert_empty SoyaContext.new(stand("fetched"), "08ee851").notices(["DigitalProductPassport"])
    assert_empty SoyaContext.new(stand("cached"), "08ee851").notices(["Other"])
    assert_empty SoyaContext.new({}, "08ee851").notices(["DigitalProductPassport"])
  end

  test "version info names build time and contexts without the reason" do
    info = SoyaContext.new(stand("cached", reason: "HTTP 503"), "08ee851").version_info
    assert_equal "2026-10-19T09:44:19.812Z", info[:built_at]
    assert_equal [{ "url" => URL, "source" => "cached", "fetched_at" => "2026-10-19" }], info[:contexts]
    assert_nil SoyaContext.new({}, "x").version_info
  end

  class FakeCatalogue
    def initialize(criteria) = @criteria = criteria
    def passport_criteria = @criteria
    def description_url(_id) = nil
  end

  class FakeWebCli
    def acquire(_structure, passport) = passport
    def validate(_structure, _instance) = { "isValid" => true, "results" => [], "classChecks" => [] }
  end

  def shacl(structure) = { "id" => "DPP-DAT-014", "title" => "t", "level" => "MUST", "status" => "active",
                           "check" => { "type" => "shacl", "structure" => structure } }

  def with_config(**values)
    config = Rails.configuration.x.dpplint
    saved = values.keys.to_h { |k| [k, config[k]] }
    values.each { |k, v| config[k] = v }
    yield
  ensure
    saved&.each { |k, v| config[k] = v }
  end

  test "results checked against a structure with a cached context carry the notice" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "DigitalProductPassport"), "{}")
      with_config(structures_dir: dir, soya_context: stand("cached", reason: "HTTP 503")) do
        report = PassportLinter.new(catalogue: FakeCatalogue.new([shacl("DigitalProductPassport")]), web_cli: FakeWebCli.new)
                               .run(passport: { "uniqueProductIdentifier" => "x" })
        assert_equal "passed", report[:criteria].first[:result]
        assert_equal 1, report[:notices].size
        assert_match(/cached copy of the SOyA context #{Regexp.escape(URL)} from 2026-10-19/, report[:notices].first)
      end
      with_config(structures_dir: dir, soya_context: stand("fetched")) do
        report = PassportLinter.new(catalogue: FakeCatalogue.new([shacl("DigitalProductPassport")]), web_cli: FakeWebCli.new)
                               .run(passport: { "uniqueProductIdentifier" => "x" })
        assert_empty report[:notices]
      end
    end
  end

  test "a structure that is not in the image is reported clearly and not fetched from SOyA" do
    Dir.mktmpdir do |dir|
      with_config(structures_dir: dir, soya_context: stand("cached")) do
        report = PassportLinter.new(catalogue: FakeCatalogue.new([shacl("Missing")]), web_cli: FakeWebCli.new)
                               .run(passport: { "uniqueProductIdentifier" => "x" })
        result = report[:criteria].first
        assert_equal "skipped", result[:result]
        assert_equal "not_evaluated", result[:reason_code]
        assert_match(/\ASOyA structure Missing is not part of this image \(dpp-criteria [^)]+\); dpplint does not fetch structures from SOyA/, result[:reason])
        assert_empty report[:notices]
      end
    end
  end
end
