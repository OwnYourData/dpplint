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
    assert_includes footer, %(<div>Operated by <a href="https://www.ownyourdata.eu/en/">OwnYourData</a></div>)
    assert_includes footer, %(<a href="https://www.ownyourdata.eu/en/imprint/">Imprint</a>)
    assert_includes footer, %(<a href="https://www.ownyourdata.eu/en/privacy-policy/">Privacy</a>)
    assert_includes footer, %(<a href="/api-docs">API</a>)
    assert_includes footer, "Criteria: dpp-criteria"
    assert_includes footer, "The DPP Linter is part of a research project and shares what we currently know; " \
                            "the checks make no claim to be complete and are not a legal assessment."
    assert_includes footer, %(<div class="funding">#{FundingNotice.html}</div>)
  end

  test "footer is laid out like the DPP Service: operator and links in one row, then notes and funding" do
    get "/"
    footer = response.body[%r{<footer>.*</footer>}m]
    blocks = footer.scan(%r{^    <div(?: class="([a-z]+)")?>}).flatten
    assert_equal [nil, "legal", "about", "funding"], blocks
    legal = footer[%r{<div class="legal">.*?</div>}m]
    assert_equal %w[API Source Imprint Privacy], legal.scan(%r{<a href="[^"]+">([^<]+)</a>}).flatten
    assert_not_includes footer, "<br>"
    assert_match(/footer \.about, footer \.funding \{ flex-basis: 100%;/, response.body)
  end

  test "the page runs each check through the check client, which reads a result only from a JSON answer" do
    get "/"
    body = response.body
    client = HomeController::CHECK_CLIENT
    assert_includes body, client
    assert_not_includes client, "</script", "the client can be included in the page"
    assert client.index("if (!isJson(contentType))") < client.index("await res.json()"), "content type is checked before the answer is parsed"
    assert body.index("function runCheck(") < body.index("DppLintCheck.runCheck(apiUrl, { timeoutMs })"), "client before its use"
    assert_no_match(/\bfetch\(/, page_script, "the page itself does not fetch")
    assert_includes page_script, "(d.notices || []).map("
  end

  test "the page waits at most the didlint budget plus the retrieval of the passport" do
    config = Rails.configuration.x.dpplint
    assert_equal config.didlint_budget + 20, config.check_timeout
    get "/"
    assert_includes response.body, %(<form id="form" data-timeout-seconds="40">)
    assert_includes page_script, "const timeoutMs = Number(form.dataset.timeoutSeconds) * 1000;"
    assert_includes page_script, 'Retrieving and checking the passport … (at most ${timeoutMs / 1000}\u00a0s)'
    previous = config.check_timeout
    config.check_timeout = 12.4
    get "/"
    assert_includes response.body, %(<form id="form" data-timeout-seconds="12">)
  ensure
    config.check_timeout = previous if previous
  end

  test "a failed check shows what happened, the API call and a button to try again, and the form stays usable" do
    get "/"
    body = response.body
    failure = body[%r{<div id="failure".*?<button type="button" id="retry">Try again</button>\s*</div>}m]
    assert failure, "failure box with a retry button"
    assert_includes failure, %(<div id="failure" class="failure" role="alert" hidden>)
    assert_includes failure, "<strong>The check could not be run</strong>"
    assert_includes failure, %(<p id="failure-text"></p>)
    assert_includes failure, %(The check is also available through the API: <a id="failure-api" href="/api-docs">GET /api/v1/validate/…</a>)
    assert_includes failure, %((<a href="/api-docs">documentation</a>))
    assert_includes body, %(<div id="status" role="status"></div>)
    script = page_script
    assert_includes script, "failureText.textContent = text;"
    assert_includes script, "failureApi.href = apiUrl;"
    assert_includes script, "if (!outcome.ok) return fail(DppLintCheck.failureText(outcome, timeoutMs));"
    assert_includes script, %(fail("The page could not show the result: " + e.message);)
    assert_match(/finally \{\s*button\.disabled = false;\s*retry\.disabled = false;\s*\}/, script)
    assert_includes script, %(retry.addEventListener("click", () => { if (lastProductId) run(lastProductId); });)
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

  # The inline script of the page itself (the last one, after the check client).
  def page_script
    response.body.scan(%r{<script>(.*?)</script>}m).last.first
  end

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
