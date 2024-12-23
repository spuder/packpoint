# app.rb
module ShippingApp
  class App < Sinatra::Base
    enable :sessions

    COUNTRY_FLAGS = {
      'US' => '🇺🇸',
      'CA' => '🇨🇦',
      'GB' => '🇬🇧',
      'PR' => '🇵🇷',
      'AU' => '🇦🇺'
    }.freeze

    configure do
      Environment.setup
    end

    helpers do
      def with_vcr
        if Environment.development?
          puts "Using VCR cassette"
          VCR.use_cassette('tindie_orders', record: :once) { yield }
        else
          puts "Not using VCR cassette"
          yield
        end
      end

      def purchased_labels
        session[:orders] || {}
      end
    end

    get '/orders' do
      tindie_api = TindieApi::TindieOrdersAPI.new(
        ENV['TINDIE_USERNAME'],
        ENV['TINDIE_API_KEY']
      )
      
      orders = with_vcr { tindie_api.get_orders_json(false) }
      
      erb :orders, locals: {
        orders: orders,
        purchased_labels: purchased_labels,
        username: ENV['TINDIE_USERNAME'],
        api_key: ENV['TINDIE_API_KEY'],
        countries: COUNTRY_FLAGS
      }
    end

    post '/buy_label/:order_number' do
      order_number = params[:order_number]
      order_data = JSON.parse(params[:order_data])
      
      result = ShippingService.new.create_label(order_number, order_data)
      
      # Store the label information in the session
      session[:orders] ||= {}
      session[:orders][order_number] = {
        tracking_code: result[:tracking_code],
        label_url: result[:label_url]
      }
      
      content_type :json
      result.to_json
    end

    get '/' do
      redirect '/orders'
    end
  end
end