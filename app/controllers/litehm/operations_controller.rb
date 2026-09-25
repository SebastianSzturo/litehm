# frozen_string_literal: true

module LiteHM
  class OperationsController < ApplicationController
    COMMANDS = {
      "pause" => :pause,
      "resume" => :resume,
      "retry" => :retry_operation,
      "cutover" => :request_cutover,
      "abort" => :request_abort,
      "cleanup" => :request_cleanup
    }.freeze

    def index
      @operations = LiteHM.operations(connection: litehm_connection)
    end

    def show
      @operation = LiteHM.status(params[:plan_id], connection: litehm_connection)
      raise ActionController::RoutingError, "LiteHM operation not found" if @operation.missing?
    end

    def command
      method = COMMANDS.fetch(params[:operation_command]) do
        raise ActionController::BadRequest, "unknown LiteHM command"
      end
      LiteHM.public_send(method, params[:plan_id], connection: litehm_connection)
      redirect_to operation_path(params[:plan_id]), status: :see_other
    end
  end
end
