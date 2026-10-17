require "test_helper"

# The wording lives in config/funding.yml. The start page renders it from
# there; the README carries a copy that `bin/rails funding:write` rewrites.
class FundingNoticeTest < ActiveSupport::TestCase
  test "names this component, the project and the grant" do
    md = FundingNotice.markdown
    assert md.start_with?("The DPP Linter is part of [PACE-DPP](https://dpp-austria.at/) – Promoting and Accelerating"), md
    assert_includes md, "under grant number [917177](https://projekte.ffg.at/projekt/5128301)"
    assert md.end_with?("supported by the German Research Promotion Agency (DLR-PT)."), md
  end

  test "turns the links into anchors for the footer and leaves out the title" do
    html = FundingNotice.html
    assert html.start_with?('The DPP Linter is part of <a href="https://dpp-austria.at/">PACE-DPP</a>. This Lighthouse Project'), html
    assert_includes html, '(<a href="https://www.bmimi.gv.at/en.html">BMIMI</a>, formerly BMK)'
    assert_includes html, '<a href="https://projekte.ffg.at/projekt/5128301">917177</a>'
    refute_includes html, "Promoting and Accelerating"
    refute_includes html, "]("
  end

  test "keeps the Funding section of the README as the configuration says, before the licence" do
    content = File.read(FundingNotice::README, encoding: "UTF-8")
    assert_equal FundingNotice.markdown, FundingNotice.current, "README differs from config/funding.yml: run bin/rails funding:write"
    assert content.index("## Funding") < content.index("## License")
  end
end
