# app.rb

# Monkey patch until this is merged
# https://github.com/nehresma/cupsffi/pull/30      `
class File
  def self.exists?(filename)
    self.exist?(filename)
  end
end

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


    post '/print_label' do
      content_type :json
      begin
        data = JSON.parse(request.body.read)
        puts "Downloading label: #{data}"
        label_url = data['label_url']
        
        # Create cache directory if it doesn't exist
        cache_dir = File.join(Dir.pwd, 'cache', 'labels')
        FileUtils.mkdir_p(cache_dir)
        
        # Extract original filename from URL
        original_filename = File.basename(URI.parse(label_url).path)
        cached_file = File.join(cache_dir, original_filename)
        
        # Download and cache the file if it doesn't exist
        unless File.exist?(cached_file)
          URI.open(label_url) do |url_file|
            File.open(cached_file, 'wb') do |file|
              puts "Caching label: #{cached_file}"
              file.write(url_file.read)
            end
          end
        end
        
        # Rest of your code remains the same
        printer = CupsPrinter.new("PM-241-BT", :hostname => "packpoint.local", :port => 631)
        job = printer.print_file(cached_file)
        status = job.status
        
        { success: true, message: "Print job status: #{status}" }.to_json
      rescue => e
        { success: false, message: "Error: #{e.message}" }.to_json
      end
    end    

    get '/' do
      redirect '/orders'
    end
  end
end