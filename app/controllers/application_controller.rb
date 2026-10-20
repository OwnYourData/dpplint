class ApplicationController < ActionController::API
  def version
    render json: {
      service: "dpplint",
      version: Dpplint::VERSION,
      "dpp-criteria": Rails.configuration.x.dpplint.criteria_ref,
      "soya-web-cli": SoyaWebCli.new.version,
      "soya-context": SoyaContext.new.version_info
    }
  end

  # For the readiness probe: 200 when this replica can check passports, 503
  # with the reason when the SOyA web-cli or its repository does not answer.
  def ready
    result = Readiness.current.status
    body = result.ready ? { ready: true } : { ready: false, reason: result.reason }
    render json: body, status: result.ready ? :ok : :service_unavailable
  end
end
