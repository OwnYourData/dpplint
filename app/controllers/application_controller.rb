class ApplicationController < ActionController::API
  def version
    render json: {
      service: "dpplint",
      version: Dpplint::VERSION,
      "dpp-criteria": Rails.configuration.x.dpplint.criteria_ref,
      "soya-web-cli": SoyaWebCli.new.version
    }
  end
end
