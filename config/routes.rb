# frozen_string_literal: true

LiteHM::Engine.routes.draw do
  root "operations#index"
  resources :operations, only: %i[index show], param: :plan_id do
    post :command, on: :member
  end
end
