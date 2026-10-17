require "test_helper"

class HomeTest < ActionDispatch::IntegrationTest
  test "start page shows the mark next to the title and the funding notice in the footer" do
    get "/"
    assert_response :success
    assert_includes response.body, '<link rel="icon" href="/oyd-mark.svg" type="image/svg+xml">'
    assert_includes response.body, '<h1 class="brand"><img class="mark" src="/oyd-mark.svg" alt=""'
    assert_includes response.body, %(<div class="funding">#{FundingNotice.html}</div>)
    assert_equal 1, response.body.scan("917177").size
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
    assert_includes footer, %(<div class="funding">#{FundingNotice.html}</div>)
  end

  test "the mark is served as a static file" do
    assert File.file?(Rails.public_path.join("oyd-mark.svg"))
  end
end
