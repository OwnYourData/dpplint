require "test_helper"
require "tmpdir"

# Links to the readable description of a criterion in criteria/README.md.
class CriteriaCatalogueTest < ActiveSupport::TestCase
  test "links to the README of the commit in the image, anchored by the lower-case ID" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "README.md"), "# DPP criteria catalogue\n")
      assert_equal "https://github.com/OwnYourData/dpp-criteria/blob/abc1234/criteria/README.md#dpp-dat-016",
                   CriteriaCatalogue.new(dir, "abc1234").description_url("DPP-DAT-016")
    end
  end

  test "no link without README or without a known commit" do
    Dir.mktmpdir do |dir|
      assert_nil CriteriaCatalogue.new(dir, "abc1234").description_url("DPP-DAT-016")
      File.write(File.join(dir, "README.md"), "# DPP criteria catalogue\n")
      assert_nil CriteriaCatalogue.new(dir, "unknown").description_url("DPP-DAT-016")
    end
  end
end
