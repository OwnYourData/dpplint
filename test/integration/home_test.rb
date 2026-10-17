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

  test "the mark is served as a static file" do
    assert File.file?(Rails.public_path.join("oyd-mark.svg"))
  end
end
