ENV["RAILS_ENV"] ||= "test"
# Integration tests must not depend on the public didlint; DID checks have unit tests with a fake.
ENV["DIDLINT_URL"] ||= "http://127.0.0.1:9"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # The tests talk to the SOyA web-cli started by docker/init.sh.
    def self.wait_for_web_cli
      60.times do
        return if SoyaWebCli.new.version
        sleep 0.5
      end
      raise "SOyA web-cli not reachable"
    end
  end
end
