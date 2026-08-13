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

    CUPS_TIMEOUT_SECONDS = 8

    # How far back the (lazily-loaded) archive tab looks for shipped
    # orders. Kept bounded on purpose - Stripe can filter this server-side
    # via `created`, but Tindie's gem can't, so this also caps how much of
    # Tindie's shipped history gets pulled and filtered client-side.
    ARCHIVE_WINDOW_DAYS = 30

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

      # Stripe support is optional and can span multiple stores/accounts -
      # see StripeStoreConfig for the STRIPE_STORE_*_* env var format.
      set :stripe_stores, StripeStoreConfig.stores
      if settings.stripe_stores.any?
        puts "Configured Stripe stores: #{settings.stripe_stores.map(&:name).join(', ')}"
        settings.stripe_stores.each do |store|
          if store.from_address.to_s.empty?
            puts "WARNING: STRIPE_STORE_#{store.key.upcase}_EASYPOST_FROM_ADDRESS is not set - " \
                 "buying a label for '#{store.name}' orders will fail"
          end
        end
      else
        puts "No Stripe stores configured (STRIPE_STORE_<id>_SECRET_KEY not set)"
      end

      # Debug: List all available printer names at startup (after Environment.setup)
      begin
        printer_names = Timeout.timeout(CUPS_TIMEOUT_SECONDS) do
          CupsPrinter.get_all_printer_names(:hostname => ENV['CUPS_HOST'], :port => 631)
        end
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

      def order_age(date)
        seconds = (Time.now - date.to_time).to_i
        return "#{seconds / 60}m" if seconds < 3600
        return "#{seconds / 3600}h" if seconds < 86400
        "#{seconds / 86400}d"
      end

      def order_aging?(date)
        (Time.now - date.to_time) > 48 * 3600
      end

      def order_status(order)
        return 'intl' unless order.address_dict[:country_code] == 'US'
        label = purchased_labels[order.order_number.to_s]
        label && label[:tracking_code] && label[:label_url] ? 'ready' : 'need'
      end

      # Tindie order numbers are already short; Stripe's are long session
      # ids, so those provide their own shortened form to display instead.
      def display_order_number(order)
        order.respond_to?(:short_order_number) ? order.short_order_number : order.order_number.to_s
      end

      # Pulls together unshipped orders from Tindie and every configured
      # Stripe store into one flat list, each wrapped in a StoreOrder so the
      # view can render a store badge and buy_label knows where to route
      # the "mark as shipped" call. Any Stripe store that fails to fetch
      # (bad key, missing permissions, etc.) is recorded in @stripe_warnings
      # instead of just being logged, so the /orders page actually shows
      # that something's wrong rather than quietly rendering as if that
      # store simply has no orders.
      def fetch_all_orders
        @stripe_warnings = []

        tindie_api = TindieApi::TindieOrdersAPI.new(ENV['TINDIE_USERNAME'], ENV['TINDIE_API_KEY'])
        tindie_orders = with_vcr { tindie_api.get_all_orders(false) }
        orders = tindie_orders.map do |order|
          ShippingApp::StoreOrder.new(order, store_type: 'tindie', store_key: 'tindie', store_display_name: 'Tindie')
        end

        settings.stripe_stores.each { |store| orders.concat(fetch_stripe_orders(store, shipped: false)) }
        orders
      end

      # Same idea as fetch_all_orders, but for the (lazily-loaded) archive
      # tab: shipped orders from the last ARCHIVE_WINDOW_DAYS days only.
      # Stripe supports filtering this server-side (created[gte]); Tindie's
      # gem doesn't expose a date filter, so that side is fetched in full
      # and filtered client-side - fine for a bounded, on-demand view, but
      # worth revisiting if a store's shipped history gets very large.
      def fetch_archived_orders
        @stripe_warnings ||= []
        cutoff = Time.now - (ARCHIVE_WINDOW_DAYS * 86400)

        tindie_api = TindieApi::TindieOrdersAPI.new(ENV['TINDIE_USERNAME'], ENV['TINDIE_API_KEY'])
        tindie_orders = with_vcr { tindie_api.get_all_orders(true) }
        tindie_orders = tindie_orders.select { |order| order.date.to_time >= cutoff }
        orders = tindie_orders.map do |order|
          ShippingApp::StoreOrder.new(order, store_type: 'tindie', store_key: 'tindie', store_display_name: 'Tindie')
        end

        settings.stripe_stores.each do |store|
          orders.concat(fetch_stripe_orders(store, shipped: true, created_after: cutoff))
        end
        orders
      end

      # Fetches + wraps one Stripe store's orders, recording (not raising)
      # any Stripe::StripeError into @stripe_warnings - shared by both
      # fetch_all_orders and fetch_archived_orders.
      def fetch_stripe_orders(store, shipped:, created_after: nil)
        stripe_orders = ShippingApp::StripeOrdersAPI.new(store.key, store.name, store.secret_key)
                         .get_all_orders(shipped, created_after: created_after)
        stripe_orders.map do |order|
          ShippingApp::StoreOrder.new(order, store_type: 'stripe', store_key: store.key, store_display_name: store.name)
        end
      rescue Stripe::StripeError => e
        warning = ShippingApp::StripeErrorFormatter.describe(store.name, e)
        puts "WARNING: #{warning}"
        (@stripe_warnings ||= []) << warning
        []
      end

      # One tab per store (even Stripe stores with zero unshipped orders
      # right now), used to render the store tab bar.
      def store_tabs(orders)
        tabs = [{ key: 'tindie', name: 'Tindie', count: orders.count { |o| o.store_type == 'tindie' } }]
        settings.stripe_stores.each do |store|
          tabs << {
            key: store.key,
            name: store.name,
            count: orders.count { |o| o.store_type == 'stripe' && o.store_key == store.key }
          }
        end
        tabs
      end

      def find_stripe_store(store_key)
        settings.stripe_stores.find { |store| store.key == store_key }
      end

      # Each store ships from its own return address, so a Stripe store's
      # packages don't go out under Tindie's address (or vice versa). See
      # TINDIE_EASYPOST_FROM_ADDRESS / STRIPE_STORE_<id>_EASYPOST_FROM_ADDRESS
      # in .env.sample.
      def find_from_address(store_type, store_key)
        if store_type == 'stripe'
          store = find_stripe_store(store_key)
          raise "Cannot buy label: unknown store_key '#{store_key}'" unless store
          raise "Cannot buy label: no EASYPOST_FROM_ADDRESS configured for Stripe store '#{store_key}'" if store.from_address.to_s.empty?

          store.from_address
        else
          from_address = ENV['TINDIE_EASYPOST_FROM_ADDRESS'].to_s
          raise 'Cannot buy label: TINDIE_EASYPOST_FROM_ADDRESS is not configured' if from_address.empty?

          from_address
        end
      end

      # Shared by /rate_label and /buy_label, which both post the same
      # shipping/parcel fields from the buy-label-form.
      def order_data_from_params
        {
          'shipping_name' => params[:shipping_name],
          'shipping_street' => params[:shipping_street],
          'shipping_city' => params[:shipping_city],
          'shipping_state' => params[:shipping_state],
          'shipping_postcode' => params[:shipping_postcode],
          'shipping_country' => params[:shipping_country],
          'shipping_phone' => params[:shipping_phone].to_s.empty? ? nil : params[:shipping_phone],
          'email' => params[:email].to_s.empty? ? nil : params[:email]
        }
      end

      def parcel_override_from_params
        {
          length: params[:parcel_length],
          width: params[:parcel_width],
          height: params[:parcel_height],
          weight: params[:parcel_weight]
        }
      end

      # Marks a Stripe order as shipped via the Stripe API (Checkout Session
      # metadata - see ShippingApp::StripeOrdersAPI for why it's the session
      # and not the PaymentIntent). Buying the label already succeeded by
      # the time this runs, so a failure here doesn't fail the request -
      # but it's returned (rather than merely logged) so /buy_label can
      # surface it to the UI instead of the label appearing to have shipped
      # fine when Stripe never got updated.
      def mark_stripe_order_shipped(store_key, session_id, label_result)
        store = find_stripe_store(store_key)
        unless store
          warning = "Cannot mark Stripe order shipped: unknown store_key '#{store_key}'"
          puts "WARNING: #{warning}"
          return warning
        end
        unless session_id
          warning = "Cannot mark Stripe order shipped: missing session id"
          puts "WARNING: #{warning}"
          return warning
        end

        ShippingApp::StripeOrdersAPI.new(store.key, store.name, store.secret_key).mark_shipped(
          session_id,
          tracking_code: label_result[:tracking_code],
          label_url: label_result[:label_url]
        )
        nil
      rescue Stripe::StripeError => e
        warning = ShippingApp::StripeErrorFormatter.describe("marking #{store_key} order shipped", e)
        puts "WARNING: #{warning}"
        warning
      end
    end

    get '/orders' do
      unshipped_orders = fetch_all_orders

      # Check printer availability for UI feedback (don't create instance, just check)
      printer_available = false
      printer_error = nil
      begin
        available_printers = Timeout.timeout(CUPS_TIMEOUT_SECONDS) do
          CupsPrinter.get_all_printer_names(:hostname => ENV['CUPS_HOST'], :port => 631)
        end
        printer_available = available_printers.include?('PM-241-BT')
        puts "Printer check: PM-241-BT #{printer_available ? 'available' : 'not found'} in #{available_printers.inspect}"
      rescue => e
        printer_error = e.message
        puts "Printer availability check failed: #{e.class} - #{e.message}"
      end
      
      erb :orders, locals: {
        orders: unshipped_orders,
        stores: store_tabs(unshipped_orders),
        stripe_warnings: @stripe_warnings,
        purchased_labels: purchased_labels,
        username: ENV['TINDIE_USERNAME'],
        api_key: ENV['TINDIE_API_KEY'],
        countries: COUNTRY_FLAGS,
        total_count: unshipped_orders.length,
        printer_available: printer_available,
        printer_error: printer_error,
        archive_days: ARCHIVE_WINDOW_DAYS
      }
    end

    # Lazily-loaded archive: only fetched when the Archive tab is actually
    # opened, not on every /orders load. Returns an HTML fragment (no
    # layout) that the page injects directly.
    get '/orders/archive' do
      archived_orders = fetch_archived_orders.sort_by { |order| order.date.to_time }.reverse

      erb :_archived_orders, layout: false, locals: {
        orders: archived_orders,
        stripe_warnings: @stripe_warnings,
        countries: COUNTRY_FLAGS,
        archive_days: ARCHIVE_WINDOW_DAYS
      }
    end

    # Quotes a shipment (creates it, but doesn't buy a label) so the buy
    # window can show a price for the entered box dimensions before the
    # user commits. Returns the shipment id so /buy_label can buy this
    # exact shipment afterward instead of quoting again.
    post '/rate_label/:order_number' do
      order_number = params[:order_number]
      store_type = params[:store_type].to_s.empty? ? 'tindie' : params[:store_type]
      store_key = params[:store_key]
      order_data = order_data_from_params
      parcel_override = parcel_override_from_params
      puts "Rating label for order: #{order_number} (store_type=#{store_type}), Parcel: #{parcel_override.inspect}"

      content_type :json
      begin
        from_address_id = find_from_address(store_type, store_key)
        result = ShippingApp::ShippingService.new.get_rates(order_number, order_data, from_address_id, parcel_override)
        { success: true }.merge(result).to_json
      rescue EasyPost::Errors::EasyPostError => e
        puts "EasyPost error rating label for #{order_number}: #{e.class} - #{e.message}"
        status 422
        { success: false, message: e.message }.to_json
      rescue => e
        puts "ERROR in rate_label: #{e.class} - #{e.message}"
        puts e.backtrace.join("\n")
        status 500
        { success: false, message: e.message }.to_json
      end
    end

    post '/buy_label/:order_number' do
      order_number = params[:order_number]
      store_type = params[:store_type].to_s.empty? ? 'tindie' : params[:store_type]
      store_key = params[:store_key]
      shipment_id = params[:shipment_id].to_s.empty? ? nil : params[:shipment_id]
      carrier = params[:carrier].to_s.empty? ? 'usps' : params[:carrier]
      puts "Buying label for order: #{order_number} (store_type=#{store_type}, carrier=#{carrier})"

      order_data = order_data_from_params
      parcel_override = parcel_override_from_params
      puts "Order Data: #{order_data.inspect}, Parcel: #{parcel_override.inspect}, Shipment: #{shipment_id.inspect}"

      content_type :json
      begin
        from_address_id = find_from_address(store_type, store_key)
        result = ShippingApp::ShippingService.new.create_label(order_number, order_data, from_address_id, parcel_override, shipment_id: shipment_id, carrier: carrier)

        # Store the label information in the session
        session[:orders] ||= {}
        session[:orders][order_number] = {
          tracking_code: result[:tracking_code],
          label_url: result[:label_url]
        }

        stripe_warning = mark_stripe_order_shipped(store_key, order_number, result) if store_type == 'stripe'

        response_body = { success: true, tracking_code: result[:tracking_code], label_url: result[:label_url] }
        response_body[:warning] = "Label bought, but Stripe wasn't updated: #{stripe_warning}" if stripe_warning
        response_body.to_json
      rescue EasyPost::Errors::EasyPostError => e
        puts "EasyPost error buying label for #{order_number}: #{e.class} - #{e.message}"
        status 422
        { success: false, message: e.message }.to_json
      rescue => e
        puts "ERROR in buy_label: #{e.class} - #{e.message}"
        puts e.backtrace.join("\n")
        status 500
        { success: false, message: e.message }.to_json
      end
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
          available_printers = Timeout.timeout(CUPS_TIMEOUT_SECONDS) do
            CupsPrinter.get_all_printer_names(:hostname => ENV['CUPS_HOST'], :port => 631)
          end
          unless available_printers.include?('PM-241-BT')
            raise "PM-241-BT not found in available printers: #{available_printers.inspect}"
          end
          puts "SUCCESS: Confirmed PM-241-BT is available on remote server"

          # Try cupsffi first (since you prefer the library approach)
          puts "Attempting print via cupsffi library..."
          begin
            job_status = Timeout.timeout(CUPS_TIMEOUT_SECONDS) do
              printer = CupsPrinter.new("PM-241-BT", :hostname => ENV['CUPS_HOST'], :port => 631)
              puts "SUCCESS: Created printer instance with cupsffi"

              job = printer.print_file(cached_file)
              puts "SUCCESS: cupsffi printing worked!"

              begin
                job.status
              rescue RuntimeError => e
                puts "Error getting job status: #{e.class} - #{e.message}"
                "submitted via cupsffi"
              end
            end
            status = job_status

          rescue RuntimeError => cupsffi_error
            puts "cupsffi printing failed: #{cupsffi_error.message}"
            puts "Falling back to native CUPS lp command..."

            # Fallback to native CUPS command with explicit server
            cups_server = "#{ENV['CUPS_HOST']}:631"
            lp_command = "lp -h #{cups_server} -d PM-241-BT #{cached_file}"
            puts "Running: #{lp_command}"

            result = Timeout.timeout(CUPS_TIMEOUT_SECONDS) { `#{lp_command} 2>&1` }
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