require "test_helper"

class HttpResolverTest < ActiveSupport::TestCase
  test "internal addresses are refused" do
    %w[127.0.0.1 10.1.2.3 172.16.0.1 192.168.1.1 169.254.169.254 100.64.0.1 ::1 fe80::1 fd00::1 ::ffff:127.0.0.1 localhost].each do |host|
      assert_raises(HttpResolver::Blocked, host) { HttpResolver.public_address!(host) }
    end
  end

  test "public addresses are allowed" do
    assert_equal "89.58.20.114", HttpResolver.public_address!("89.58.20.114")
    assert_equal "2a03:4000:6:1::1", HttpResolver.public_address!("2a03:4000:6:1::1")
  end

  test "retrieval from an internal address is refused" do
    res = HttpResolver.new(allow_private: false).get("http://127.0.0.1:3000/up")
    assert_match(/not retrieved: 127.0.0.1 resolves to 127.0.0.1/, res.error)
  end
end
