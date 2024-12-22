# app.rb
module ShippingApp
  class App < Sinatra::Base
    enable :sessions

    before do
      headers({
        'Access-Control-Allow-Origin' => '*',
        'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers' => 'Content-Type'
      })
    end

    options "*" do
      response.headers["Allow"] = "GET, POST, OPTIONS"
      200
    end

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

    get '/proxy_print/:order_number' do
      order_number = params[:order_number]
      api_key = ENV['TINDIE_API_KEY']
      
      puts "Attempting to fetch PDF for order number: #{order_number}"
      
      tindie_url = URI("https://www.tindie.com/orders/print/#{order_number}")
      
      begin
        pdf_content = Net::HTTP.start(tindie_url.host, tindie_url.port, use_ssl: true) do |http|
          request = Net::HTTP::Get.new(tindie_url)
          request['User-Agent'] = 'Mozilla/5.0'
          request['Accept'] = 'application/pdf'
          request['Cookie'] = "apikey=#{api_key}"
          
          response = http.request(request)
          
          case response
          when Net::HTTPSuccess
            response.body
          when Net::HTTPRedirection
            redirect_url = URI.join(tindie_url, response['location'])
            puts "Following redirect to: #{redirect_url}"
            redirect_response = Net::HTTP.get_response(redirect_url)
            redirect_response.body
          else
            halt 500, "Failed to fetch PDF: #{response.code} - #{response.message}"
          end
        end
        
        if pdf_content.nil? || pdf_content.empty?
          halt 500, "Received empty PDF content"
        end
        
        content_type 'application/pdf'
        attachment "order_#{order_number}.pdf"
        pdf_content
        
      rescue => e
        puts "Error: #{e.class} - #{e.message}"
        puts e.backtrace.join("\n")
        halt 500, "Error: #{e.message}"
      end
    end
    

    get '/print' do
      erb :print
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