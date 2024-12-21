require 'sinatra/base'
require 'tindie_api'
require 'dotenv'
require './lib/foobar/helpers' # TODO: rename foobar
require 'easypost'


class App < Sinatra::Base
  enable :sessions

  configure do
    set :country_flags, {
      # ISO3166 country codes
      # TODO: convert to using emoji_flags gem
      'US' => '🇺🇸',
      'CA' => '🇨🇦',
      'GB' => '🇬🇧',
      'PR' => '🇵🇷',
      'AU' => '🇦🇺'
    }
    Dotenv.load

    # set :easypost_client, EasyPost::Client.new(api_key: ENV['EASYPOST_TEST_API_KEY'])

  end

  helpers Foobar::Helpers

  get '/orders' do
    @username = ENV['TINDIE_USERNAME']
    @api_key = ENV['TINDIE_API_KEY']
    @api = TindieApi::TindieOrdersAPI.new(@username, @api_key)
    orders = @api.get_orders_json(false)

    puts orders.inspect


    erb :orders, locals: { orders: orders, username: @username, api_key: @api_key, countries: settings.country_flags }
  end

  post '/buy_label/:order_number' do
    order_number = params[:order_number]
    order = JSON.parse(params[:order_data])

    client = EasyPost::Client.new(api_key: ENV['EASYPOST_TEST_API_KEY'])

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

  # Run if this file is executed directly
  run! if app_file == $0
end
