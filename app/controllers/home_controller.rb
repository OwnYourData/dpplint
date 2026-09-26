# Start page: a form for a product identifier; results come from the API.
class HomeController < ActionController::Base
  def show
    @product_id = params[:productId].to_s
    @criteria_ref = Rails.configuration.x.dpplint.criteria_ref
  end
end
