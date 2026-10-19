require "test_helper"

class HomeTest < ActionDispatch::IntegrationTest
  # The two blocks of colour tokens in the page style: light first, then the
  # overrides for a browser set to dark.
  LIGHT_BLOCK = /:root \{ color-scheme: light dark;(.*?)\}/m
  DARK_BLOCK = /@media \(prefers-color-scheme: dark\) \{\s*:root \{(.*?)\}\s*\}/m

  test "start page shows the mark as icon and the funding notice in the footer" do
    get "/"
    assert_response :success
    assert_includes response.body, '<link rel="icon" href="/oyd-mark.svg" type="image/svg+xml">'
    assert_includes response.body, "<h1>Digital product passport checks</h1>"
    assert_includes response.body, %(<div class="funding">#{FundingNotice.html}</div>)
    assert_equal 1, response.body.scan("917177").size
  end

  test "header spans the window with the mark and name and links to the DPP Service and the repository" do
    get "/"
    body = response.body
    header = body[%r{<header>.*</header>}m]
    assert header, "header"
    assert body.index("</header>") < body.index("<main"), "header outside main, so its line spans the window"
    assert_includes header, %(<a class="brand" href="/"><img class="mark" src="/oyd-mark.svg" alt="" width="15" height="28">DPP Linter <span>&middot; OwnYourData</span></a>)
    nav = header[%r{<nav>.*</nav>}m]
    assert nav, "nav"
    assert_equal [["https://dpp-service.ownyourdata.eu/", "DPP Service"], ["https://github.com/OwnYourData/dpplint", "GitHub"]],
                 nav.scan(%r{<a href="([^"]+)">([^<]+)</a>})
    assert_equal 1, body.scan("<h1").size, "one page title"
    assert_includes body, "<title>DPP Linter – Digital Product Passport checks</title>"
  end

  test "footer spans the window and names operator, imprint, privacy and funding" do
    get "/"
    body = response.body
    footer = body[%r{<footer>.*</footer>}m]
    assert footer, "footer"
    assert body.index("</main>") < body.index("<footer>"), "footer outside main, so its line spans the window"
    assert_includes footer, %(Operated by <a href="https://www.ownyourdata.eu/en/">OwnYourData</a>)
    assert_includes footer, %(<a href="https://www.ownyourdata.eu/en/imprint/">Imprint</a>)
    assert_includes footer, %(<a href="https://www.ownyourdata.eu/en/privacy-policy/">Privacy</a>)
    assert_includes footer, %(<a href="/api-docs">API</a>)
    assert_includes footer, "Criteria: dpp-criteria"
    assert_includes footer, "The DPP Linter is part of a research project and shares what we currently know; " \
                            "the checks make no claim to be complete and are not a legal assessment."
    assert_includes footer, %(<div class="funding">#{FundingNotice.html}</div>)
  end

  test "the page reads a result only from a JSON answer and shows the notices of the check" do
    get "/"
    script = response.body[%r{<script>.*</script>}m]
    assert script, "script"
    check = script.index('if (!/json/i.test(res.headers.get("Content-Type") || ""))')
    assert check, "content type is checked"
    assert check < script.index("await res.json()"), "before the answer is parsed"
    assert_includes script, '"the server answered HTTP " + res.status + " without a result. Please try again later."'
    assert_includes script, "(d.notices || []).map("
  end

  test "the mark is served as a static file" do
    assert File.file?(Rails.public_path.join("oyd-mark.svg"))
  end

  test "colours come from tokens defined for a light and a dark scheme" do
    get "/"
    css = page_css
    assert_includes css, "color-scheme: light dark;"
    light = scheme_tokens(:light)
    dark = scheme_tokens(:dark)
    assert_equal %w[accent bg fail fg field line muted on-accent on-status panel pass skip warn], light.keys.sort
    assert_equal light.keys.sort, dark.keys.sort, "both schemes define the same tokens"
    rules = css.sub(LIGHT_BLOCK, "").sub(DARK_BLOCK, "")
    assert_no_match(/#\h{3,8}\b|rgba?\(|hsla?\(/, rules, "rules use the tokens, not fixed colours")
  end

  test "text and controls meet the WCAG AA contrast in both schemes" do
    get "/"
    %i[light dark].each do |scheme|
      t = scheme_tokens(scheme)
      text = [%w[fg bg], %w[fg panel], %w[muted bg], %w[muted panel], %w[accent bg], %w[accent panel],
              %w[on-accent accent], %w[on-status pass], %w[on-status warn], %w[on-status fail], %w[on-status skip]]
      text.each do |fg, bg|
        ratio = contrast(t.fetch(fg), t.fetch(bg))
        assert_operator ratio, :>=, 4.5, "#{scheme}: --#{fg} on --#{bg} has #{ratio.round(2)}:1"
      end
      ratio = contrast(t.fetch("field"), t.fetch("bg"))
      assert_operator ratio, :>=, 3.0, "#{scheme}: border of the input field has #{ratio.round(2)}:1"
    end
  end

  test "the mark stays visible on the light and the dark background" do
    get "/"
    svg = File.read(Rails.public_path.join("oyd-mark.svg"))
    assert_no_match(/currentColor|var\(/, svg, "the mark keeps its own colours")
    fills = svg.scan(/fill="rgb\(([\d.]+)%,\s*([\d.]+)%,\s*([\d.]+)%\)"/).map do |rgb|
      format("#%02x%02x%02x", *rgb.map { |p| (p.to_f * 2.55).round })
    end
    assert_equal 2, fills.size
    %i[light dark].each do |scheme|
      ratios = fills.map { |fill| contrast(fill, scheme_tokens(scheme).fetch("bg")) }
      assert_operator ratios.min, :>=, 2.0, "#{scheme}: no part of the mark blends into the background (#{ratios.map { |r| r.round(2) }})"
      assert_operator ratios.max, :>=, 3.0, "#{scheme}: one part of the mark has at least 3:1 (#{ratios.map { |r| r.round(2) }})"
    end
  end

  private

  def page_css
    response.body[%r{<style>(.*?)</style>}m, 1]
  end

  def scheme_tokens(scheme)
    block = page_css[scheme == :light ? LIGHT_BLOCK : DARK_BLOCK, 1]
    assert block, "#{scheme} tokens"
    block.scan(/--([a-z-]+):\s*(#\h{6});/).to_h
  end

  def luminance(hex)
    r, g, b = hex.delete("#").scan(/../).map { |c| c.to_i(16) / 255.0 }
    lin = ->(c) { c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
    (0.2126 * lin.call(r)) + (0.7152 * lin.call(g)) + (0.0722 * lin.call(b))
  end

  def contrast(a, b)
    lo, hi = [luminance(a), luminance(b)].minmax
    (hi + 0.05) / (lo + 0.05)
  end
end
