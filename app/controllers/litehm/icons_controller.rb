# frozen_string_literal: true

module LiteHM
  class IconsController < ApplicationController
    ICON_PATH = File.expand_path("../../assets/images/litehm/icon.png", __dir__)

    # The dashboard refreshes every few seconds; let the browser keep the icon.
    skip_before_action :disable_litehm_caching!

    def show
      expires_in 1.day, public: false
      send_file ICON_PATH, type: "image/png", disposition: "inline"
    end
  end
end
