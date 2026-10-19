# Start page: a form for a product identifier; results come from the API.
class HomeController < ActionController::Base
  # Runs the check for the page; included in the page, tested on its own with
  # node (test/javascript).
  CHECK_CLIENT = Rails.root.join("app/javascript/check_client.js").read.freeze

  def show
    @product_id = params[:productId].to_s
    @criteria_ref = Rails.configuration.x.dpplint.criteria_ref
    @check_timeout = Rails.configuration.x.dpplint.check_timeout.round
    @check_client = CHECK_CLIENT
  end
end
