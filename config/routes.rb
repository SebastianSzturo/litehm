# frozen_string_literal: true

LiteHM::Engine.routes.draw do
  root "operations#index"
  get "icon.png", to: "icons#show", as: :icon
  resources :operations, only: %i[index show], param: :plan_id do
    post :command, on: :member
  end
end
