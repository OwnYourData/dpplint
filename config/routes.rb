Rails.application.routes.draw do
  mount Rswag::Ui::Engine => "/api-docs"
  mount Rswag::Api::Engine => "/api-docs"

  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      get  "validate/*product_id", to: "validations#show", format: false
      post "validate",             to: "validations#create"
    end
  end

  root "home#show"
  get "version", to: "application#version"
  get "up",      to: "rails/health#show", as: :rails_health_check
end
