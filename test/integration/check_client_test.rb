require "test_helper"
require "open3"

# The check client of the start page (app/javascript/check_client.js) has its
# own tests in JavaScript, against a local server that answers with error
# pages, not at all, or without JSON. They run with node as part of the suite.
class CheckClientTest < ActiveSupport::TestCase
  test "the JavaScript tests of the check client pass" do
    out, status = Open3.capture2e("node", "--test", "--test-reporter=tap", "--test-timeout=20000", Rails.root.join("test/javascript/check_client.test.js").to_s)
    assert status.success?, out
    assert_match(/^# fail 0$/, out)
    assert_match(/^# pass [1-9]\d*$/, out)
  end
end

# The click identifiers of the start page (app/javascript/click_ids.js) have
# their own tests in JavaScript, run with node as part of the suite.
class ClickIdsTest < ActiveSupport::TestCase
  test "the JavaScript tests of the click identifiers pass" do
    out, status = Open3.capture2e("node", "--test", "--test-reporter=tap", Rails.root.join("test/javascript/click_ids.test.js").to_s)
    assert status.success?, out
    assert_match(/^# fail 0$/, out)
    assert_match(/^# pass [1-9]\d*$/, out)
  end
end
