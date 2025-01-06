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
      
      unshipped_orders = with_vcr { tindie_api.get_all_orders(false) }
      # puts unshipped_orders.inspect
      
      erb :orders, locals: {
        orders: unshipped_orders,
        purchased_labels: purchased_labels,
        username: ENV['TINDIE_USERNAME'],
        api_key: ENV['TINDIE_API_KEY'],
        countries: COUNTRY_FLAGS,
        total_count: unshipped_orders.length
      }
    end

    post '/buy_label/:order_number' do
      order_number = params[:order_number]
      puts "Buying label for order: #{order_number}"
      
      order_data = {
        'shipping_name' => params[:shipping_name],
        'shipping_street' => params[:shipping_street],
        'shipping_city' => params[:shipping_city],
        'shipping_state' => params[:shipping_state],
        'shipping_postcode' => params[:shipping_postcode],
        'shipping_country' => params[:shipping_country],
        'shipping_phone' => params[:shipping_phone].to_s.empty? ? nil : params[:shipping_phone],
        'email' => params[:email].to_s.empty? ? nil : params[:email]
      }
      puts "Order Data: #{order_data.inspect}"
      
      result = ShippingApp::ShippingService.new.create_label(order_number, order_data)
      
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
        
        # Cache handling code remains the same
        cache_dir = File.join(Dir.pwd, 'cache', 'labels')
        FileUtils.mkdir_p(cache_dir)
        
        original_filename = File.basename(URI.parse(label_url).path)
        cached_file = File.join(cache_dir, original_filename)
        
        unless File.exist?(cached_file)
          URI.open(label_url) do |url_file|
            File.open(cached_file, 'wb') do |file|
              puts "Caching label: #{cached_file}"
              file.write(url_file.read)
            end
          end
        end
        
        printer = CupsPrinter.new("PM-241-BT", :hostname => ENV['CUPS_HOST'], :port => 631)
        puts "Printing label: #{cached_file}"
        job = printer.print_file(cached_file)
        
        begin
          status = job.status
        rescue RuntimeError => e
          if e.message.include?('Job not found')
            # If job is not found, it likely completed successfully
            status = "completed (fast job)"
          else
            raise e
          end
        end
        
        { success: true, message: "Print job sent successfully. Status: #{status}" }.to_json
      rescue => e
        puts "ERROR in print_label: #{e.class} - #{e.message}"
        puts e.backtrace
        { success: false, message: "Error: #{e.message}" }.to_json
      end
    end  

    get '/' do
      redirect '/orders'
    end
  end
end