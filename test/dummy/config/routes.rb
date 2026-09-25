# frozen_string_literal: true

Rails.application.routes.draw do
  mount LiteHM::Engine => "/litehm"
end
