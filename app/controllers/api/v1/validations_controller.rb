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
          .run(passport: fetch.json, product_id: product_id, retrieval: fetch.info, jws: fetch.jws, jws_only: fetch.jws_only)
      end

      # POST /api/v1/validate with a passport as JSON body, or as compact JWS
      # (Content-Type application/vc+jwt, application/jwt or application/jose)
      def create
        return create_from_jws if Jws::MEDIA_TYPES.include?(request.media_type)

        passport = JSON.parse(request.raw_post)
        return render(json: { error: "body is not a JSON object" }, status: :unprocessable_entity) unless passport.is_a?(Hash)

        render json: PassportLinter.new.run(passport: passport)
      rescue JSON::ParserError => e
        render json: { error: "invalid JSON: #{e.message}" }, status: :unprocessable_entity
      end

      private

      def create_from_jws
        jws = Jws.parse(request.raw_post)
        return render(json: { error: "body is not a compact JWS" }, status: :unprocessable_entity) unless jws
        return render(json: { error: "JWS payload is not a JSON object" }, status: :unprocessable_entity) unless jws.payload.is_a?(Hash)

        render json: PassportLinter.new.run(passport: jws.payload, jws: jws, jws_only: true)
      end
    end
  end
end
