require_relative 'config/environment'
require_relative 'app'

# Configure Rack for external connections
use Rack::ShowExceptions if ENV['RACK_ENV'] == 'development'

run ShippingApp::App