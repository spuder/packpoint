# Ensure Ruby flushes output immediately for Docker logging
STDOUT.sync = true
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
      'US' => '🇺🇸',  # United States
      'CA' => '🇨🇦',  # Canada
      'GB' => '🇬🇧',  # United Kingdom
      'PR' => '🇵🇷',  # Puerto Rico
      'AU' => '🇦🇺',  # Australia
      'AT' => '🇦🇹',  # Austria
      'DE' => '🇩🇪',  # Germany
      'ES' => '🇪🇸',  # Spain
      'FR' => '🇫🇷',  # France
      'PL' => '🇵🇱',  # Poland
      'SG' => '🇸🇬',  # Singapore
      'SK' => '🇸🇰',  # Slovakia
      'SE' => '🇸🇪',  # Sweden
    }.freeze

    configure do
      Environment.setup
      
      # Disable all Rack protection to allow external connections
      set :protection, false
      
      # Allow any host in development
      if Environment.development?
        set :bind, '0.0.0.0'
        set :port, 9292
        # Allow any host by setting permitted_hosts to empty array
        set :host_authorization, { permitted_hosts: [] }
      end

      # Debug: List all available printer names at startup (after Environment.setup)
      begin
        printer_names = CupsPrinter.get_all_printer_names(:hostname => ENV['CUPS_HOST'], :port => 631)
        puts "Available printer names at startup: #{printer_names.inspect}"
      rescue => e
        puts "Error getting printer names at startup: #{e.class} - #{e.message}"
      end
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
      
      # Check printer availability for UI feedback (don't create instance, just check)
      printer_available = false
      printer_error = nil
      begin
        available_printers = CupsPrinter.get_all_printer_names(:hostname => ENV['CUPS_HOST'], :port => 631)
        printer_available = available_printers.include?('PM-241-BT')
        puts "Printer check: PM-241-BT #{printer_available ? 'available' : 'not found'} in #{available_printers.inspect}"
      rescue => e
        printer_error = e.message
        puts "Printer availability check failed: #{e.class} - #{e.message}"
      end
      
      erb :orders, locals: {
        orders: unshipped_orders,
        purchased_labels: purchased_labels,
        username: ENV['TINDIE_USERNAME'],
        api_key: ENV['TINDIE_API_KEY'],
        countries: COUNTRY_FLAGS,
        total_count: unshipped_orders.length,
        printer_available: printer_available,
        printer_error: printer_error
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

        # Log ENV variables and printer config
        puts "ENV['CUPS_HOST']: #{ENV['CUPS_HOST']}"
        puts "Printer name: PM-241-BT"
        puts "CUPS port: 631"

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

        # Create printer instance for remote CUPS server (fresh connection each time)
        puts "Creating CupsPrinter instance for PM-241-BT on #{ENV['CUPS_HOST']}:631"
        
        begin
          # Verify printer is available using cupsffi (this works)
          available_printers = CupsPrinter.get_all_printer_names(:hostname => ENV['CUPS_HOST'], :port => 631)
          unless available_printers.include?('PM-241-BT')
            raise "PM-241-BT not found in available printers: #{available_printers.inspect}"
          end
          puts "SUCCESS: Confirmed PM-241-BT is available on remote server"
          
          # Try cupsffi first (since you prefer the library approach)
          puts "Attempting print via cupsffi library..."
          begin
            printer = CupsPrinter.new("PM-241-BT", :hostname => ENV['CUPS_HOST'], :port => 631)
            puts "SUCCESS: Created printer instance with cupsffi"
            
            job = printer.print_file(cached_file)
            puts "SUCCESS: cupsffi printing worked!"
            
            begin
              status = job.status
              puts "Print job status: #{status}"
            rescue RuntimeError => e
              puts "Error getting job status: #{e.class} - #{e.message}"
              status = "submitted via cupsffi"
            end
            
          rescue RuntimeError => cupsffi_error
            puts "cupsffi printing failed: #{cupsffi_error.message}"
            puts "Falling back to native CUPS lp command..."
            
            # Fallback to native CUPS command with explicit server
            cups_server = "#{ENV['CUPS_HOST']}:631"
            lp_command = "lp -h #{cups_server} -d PM-241-BT #{cached_file}"
            puts "Running: #{lp_command}"
            
            result = `#{lp_command} 2>&1`
            exit_code = $?.exitstatus
            
            if exit_code == 0
              puts "SUCCESS: Native lp command worked: #{result.strip}"
              status = "submitted via lp command"
            else
              raise "Both cupsffi and lp command failed. lp error: #{result}"
            end
          end
          
        rescue => e
          puts "Failed to print: #{e.class} - #{e.message}"
          raise
        end

        { success: true, message: "Print job sent successfully. Status: #{status}" }.to_json
      rescue => e
        puts "ERROR in print_label: #{e.class} - #{e.message}"
        puts "Backtrace:"
        puts e.backtrace.join("\n")
        puts "ENV['CUPS_HOST']: #{ENV['CUPS_HOST']}"
        { success: false, message: "Error: #{e.message}" }.to_json
      end
    end  

    get '/' do
      redirect '/orders'
    end
  end
end