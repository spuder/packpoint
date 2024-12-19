require 'sinatra/base'
require 'tindie_api'
require 'dotenv'
require './lib/foobar/helpers' #TODO: rename foobar

class App < Sinatra::Base
    configure do
        Dotenv.load
    end

    helpers Foobar::Helpers


    get "/orders" do
        @username = ENV['TINDIE_USERNAME']
        @api_key = ENV['TINDIE_API_KEY']
        @api = TindieApi::TindieOrdersAPI.new(@username, @api_key)
        orders = @api.get_orders_json(false)
        # orders.sort_by! { |order| DateTime.parse(order["date"]) }.reverse!

        puts orders.inspect

        erb :orders, locals: { orders: orders, username: @username, api_key: @api_key }
    end   
    
    get "/" do
        redirect "/orders"
    end

    # Run if this file is executed directly
    run! if app_file == $0
end