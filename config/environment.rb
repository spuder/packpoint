# config/environment.rb
require 'sinatra/base'
require 'tindie_api'
require 'dotenv'
require 'easypost'
require 'uri'
require 'tempfile'
Dir['./lib/**/*.rb'].each { |file| require file }

module ShippingApp
  class Environment
    class << self
      def development?
        ENV['APP_ENV'] == 'development'
      end

      def production?
        ENV['APP_ENV'] == 'production'
      end

      def setup
        Dotenv.load
        setup_test_environment if development?
      end

      private

      def setup_test_environment
        require 'vcr'
        require 'webmock'
        require 'faker'
        require 'digest'
        require 'fileutils'
        configure_vcr
      end

      def configure_vcr
        FileUtils.mkdir_p 'spec/vcr_cassettes'
        VCR.configure do |config|
          configure_vcr_basics(config)
          configure_vcr_matchers(config)
          configure_vcr_sanitization(config)
        end
      end

      def configure_vcr_basics(config)
        config.cassette_library_dir = 'spec/vcr_cassettes'
        config.hook_into :webmock
        config.debug_logger = File.open('vcr.log', 'w')
        config.allow_http_connections_when_no_cassette = true
        config.default_cassette_options = {
          match_requests_on: [:tindie_orders_matcher],
          record: :new_episodes
        }
      end

      def configure_vcr_matchers(config)
        config.register_request_matcher :tindie_orders_matcher do |request1, request2|
          uri1 = URI(request1.uri)
          uri2 = URI(request2.uri)
          uri1.path.match?(%r{/api/v1/orders?/?}) && uri2.path.match?(%r{/api/v1/orders?/?})
        end
      end

      def configure_vcr_sanitization(config)
        config.filter_sensitive_data('<TINDIE_API_KEY>') { ENV['TINDIE_API_KEY'] }
        config.filter_sensitive_data('<TINDIE_USERNAME>') { ENV['TINDIE_USERNAME'] }
        config.before_record do |interaction|
          VCRSanitizer.sanitize_interaction(interaction)
        end
      end
    end
  end
end