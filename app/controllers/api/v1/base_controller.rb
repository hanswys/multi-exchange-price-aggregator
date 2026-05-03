module Api
  module V1
    class BaseController < ActionController::API
      before_action :set_no_store

      private

      # The body carries `as_of`; any cache duration would let a downstream
      # cache return a response that lies about its own timestamp. `no-store`
      # forbids storage entirely.
      def set_no_store
        response.headers["Cache-Control"] = "no-store"
      end
    end
  end
end
