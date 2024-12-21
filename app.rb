require 'sinatra/base'
require 'tindie_api'
require 'dotenv'
require './lib/foobar/helpers'
require 'easypost'

class App < Sinatra::Base
  enable :sessions

  configure do
    Dotenv.load
    puts "APP_ENV: #{ENV['APP_ENV']}"

    if ENV['APP_ENV'] == 'development'
      require 'vcr'
      require 'webmock'
      require 'faker'
      require 'digest'
      require 'fileutils'
      FileUtils.mkdir_p 'spec/vcr_cassettes'
      
      VCR.configure do |config|
        config.cassette_library_dir = 'spec/vcr_cassettes'
        config.hook_into :webmock
        
        # Only record tindie orders to 'https://www.tindie.com/api/v1/orders'
        # ignore any query parameters as they may contain sensitive data
        config.register_request_matcher :tindie_orders_matcher do |request1, request2|
          uri1 = URI(request1.uri)
          uri2 = URI(request2.uri)
          
          path1 = uri1.path
          path2 = uri2.path
          path1.match?(%r{/api/v1/orders?/?}) && path2.match?(%r{/api/v1/orders?/?})
        end

        # Add debug logging
        config.debug_logger = File.open('vcr.log', 'w')
        
        # Filter out sensitive data
        config.filter_sensitive_data('<TINDIE_API_KEY>') { ENV['TINDIE_API_KEY'] }
        config.filter_sensitive_data('<TINDIE_USERNAME>') { ENV['TINDIE_USERNAME'] }
        
        # Create consistent fake data mappings
        FAKE_DATA_MAPPING = {}
        
        config.before_record do |interaction|
          puts "Recording interaction: #{interaction.request.uri}"
          
          # Sanitize URL
          interaction.request.uri.gsub!(/api_key=([^&]+)/, 'api_key=<FILTERED>')
          
          # Sanitize headers
          interaction.request.headers.transform_values! do |values|
            values.map do |value|
              value.gsub(ENV['TINDIE_API_KEY'], '<FILTERED>') if value.is_a?(String)
              value.gsub(ENV['TINDIE_USERNAME'], '<FILTERED>') if value.is_a?(String)
            end
          end
          
          # Handle response body sanitization
          if interaction.response.body.is_a?(String)
            begin
              data = JSON.parse(interaction.response.body)
              
              if data['orders']
                data['orders'].each do |order|
                  # Create fake data based on original values
                  order['number'] = FAKE_DATA_MAPPING[order['number']] ||= rand(100000..999999).to_s
                  order['email'] = FAKE_DATA_MAPPING[order['email']] ||= Faker::Internet.unique.email
                  order['shipping_name'] = FAKE_DATA_MAPPING[order['shipping_name']] ||= Faker::Name.unique.name
                  order['phone'] = FAKE_DATA_MAPPING[order['phone']] ||= Faker::PhoneNumber.cell_phone_in_e164
                  
                  # Address information
                  order['shipping_street'] = FAKE_DATA_MAPPING[order['shipping_street']] ||= Faker::Address.unique.street_address
                  order['shipping_city'] = FAKE_DATA_MAPPING[order['shipping_city']] ||= Faker::Address.city
                  order['shipping_postcode'] = FAKE_DATA_MAPPING[order['shipping_postcode']] ||= Faker::Address.zip_code
                  
                  # Sanitize company title if present
                  if order['company_title'].to_s.strip.length > 0
                    order['company_title'] = FAKE_DATA_MAPPING[order['company_title']] ||= Faker::Company.name
                  end
                  
                  # Handle message field
                  if order['message'].to_s.strip.length > 0
                    order['message'] = FAKE_DATA_MAPPING[order['message']] ||= Faker::Lorem.sentence
                  end
                end
                
                interaction.response.body = data.to_json
              end
            rescue JSON::ParserError => e
              puts "Warning: Could not parse JSON in response body: #{e.message}"
            end
          end
        end
        
        config.default_cassette_options = {
          match_requests_on: [:tindie_orders_matcher],
          record: :new_episodes
        }
        config.allow_http_connections_when_no_cassette = true
      end
    end
    
    set :country_flags, {
      'US' => '🇺🇸',
      'CA' => '🇨🇦',
      'GB' => '🇬🇧',
      'PR' => '🇵🇷',
      'AU' => '🇦🇺'
    }
    
  end

  def with_vcr
    if ENV['APP_ENV'] == 'development'
      puts "Using VCR cassette"
      ::VCR.use_cassette('tindie_orders', record: :once) do
        yield
      end
    else
      puts "Not using VCR cassette"
      yield
    end
  end
  
  # Your existing routes remain the same...
  get '/orders' do
    @username = ENV['TINDIE_USERNAME']
    @api_key = ENV['TINDIE_API_KEY']
    @api = TindieApi::TindieOrdersAPI.new(@username, @api_key)
    
    orders = with_vcr { @api.get_orders_json(false) }
    
    @purchased_labels = session[:orders] || {}
    puts "Session data retrieved: #{@purchased_labels.inspect}"
    
    erb :orders, locals: {
      orders: orders,
      username: @username,
      api_key: @api_key,
      countries: settings.country_flags
    }
  end

  post '/buy_label/:order_number' do
    order_number = params[:order_number]
    order = JSON.parse(params[:order_data])

    if ENV['APP_ENV'] == 'development'
      client = EasyPost::Client.new(api_key: ENV['EASYPOST_TEST_API_KEY'])
    elsif ENV['APP_ENV'] == 'production'
      client = EasyPost::Client.new(api_key: ENV['EASYPOST_PROD_API_KEY'])
    else
      raise "Unknown APP_ENV: #{ENV['APP_ENV']}"
    end

    from_address = client.address.retrieve(ENV['EASYPOST_FROM_ADDRESS'])

    #puts order
  
    shipment = client.shipment.create(
      reference: order_number,
      to_address: {
        name: order['shipping_name'],
        street1: order['shipping_street'],
        city: order['shipping_city'],
        state: order['shipping_state'],
        zip: order['shipping_postcode'],
        country: order['shipping_country'],
        phone: order['shipping_phone'],
        email: order['email']
      },
      from_address: from_address,
      parcel: {
        length: 6,
        width: 4,
        height: 4,
        weight: 5
      }
    )

    bought_shipment = client.shipment.buy(shipment.id, rate: shipment.lowest_rate)
    tracking_code = bought_shipment.tracking_code
    label_url = bought_shipment.postage_label.label_url

    # tracking_code = 123456789
    # label_url = "https://example.com/label.pdf"
    #puts shipment
    puts "tracking code is #{tracking_code}"

  
    content_type :json
    {
      tracking_code: tracking_code,
      label_url: label_url
    }.to_json
  end

  get '/' do
    redirect '/orders'
  end

  run! if app_file == $0
end