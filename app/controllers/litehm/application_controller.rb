# frozen_string_literal: true

module LiteHM
  class ApplicationController < LiteHM.configuration.base_controller_class.constantize
    before_action :authorize_litehm!
    before_action :disable_litehm_caching!
    rescue_from LiteHM::Error, with: :render_litehm_error

    private

    def authorize_litehm!
      authorization = LiteHM.configuration.authorization
      return if authorization && authorization.call(self)

      head :forbidden
    end

    def litehm_connection
      LiteHM.configured_connection
    end

    def disable_litehm_caching!
      response.headers["Cache-Control"] = "no-store"
      response.headers.delete("ETag")
      response.headers.delete("Last-Modified")
    end

    def render_litehm_error(error)
      render plain: error.message, status: :unprocessable_content
    end
  end
end
