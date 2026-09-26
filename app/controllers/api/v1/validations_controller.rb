module Api
  module V1
    class ValidationsController < ActionController::API
      # GET /api/v1/validate/<product identifier>
      def show
        product_id = params[:product_id].to_s
        product_id += "?#{request.query_string}" if request.query_string.present?
        product_id = product_id.sub(%r{\A(https?):/(?!/)}, '\1://')
        resolver = HttpResolver.new
        fetch = PassportFetcher.new(resolver).fetch(product_id)
        render json: PassportLinter.new(resolver: resolver)
          .run(passport: fetch.json, product_id: product_id, retrieval: fetch.info)
      end

      # POST /api/v1/validate with a passport as JSON body
      def create
        passport = JSON.parse(request.raw_post)
        return render(json: { error: "body is not a JSON object" }, status: :unprocessable_entity) unless passport.is_a?(Hash)

        render json: PassportLinter.new.run(passport: passport)
      rescue JSON::ParserError => e
        render json: { error: "invalid JSON: #{e.message}" }, status: :unprocessable_entity
      end
    end
  end
end
