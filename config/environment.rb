# config/environment.rb
require 'sinatra/base'
require 'tindie_api'
require 'dotenv'
require 'easypost'
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

      VALID_ENVIRONMENTS = %w[development test production].freeze

      def setup
        begin
          Dotenv.load
        rescue Errno::ENOENT
          puts "Warning: .env file not found. Using existing environment variables."
        end
      
        ENV['APP_ENV'] = ENV['APP_ENV'].to_s.downcase
        ENV['APP_ENV'] = 'development' unless VALID_ENVIRONMENTS.include?(ENV['APP_ENV'])
        ENV['RACK_ENV'] = ENV['APP_ENV']
      
        puts "Running in #{ENV['APP_ENV']} environment"
      
        validate_required_env_vars(['TINDIE_USERNAME', 'TINDIE_API_KEY'])
        setup_test_environment if development?
        set_easypost_address
      
        puts "Application setup completed"
      end
      
      
      private
      
      def validate_required_env_vars(vars)
        vars.each do |var|
          raise "#{var} environment variable is empty" if ENV[var].to_s.empty?
        end
      end
      
      def set_easypost_address
        address_key = development? ? 'EASYPOST_TEST_FROM_ADDRESS' : 'EASYPOST_PROD_FROM_ADDRESS'
        raise "#{address_key} environment variable is required in #{ENV['APP_ENV']} environment" if ENV[address_key].to_s.empty?
        ENV['EASYPOST_FROM_ADDRESS'] = ENV[address_key]
      end
      
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