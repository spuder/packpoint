module ShippingApp
    class ShippingService
      # Openspool orders have always shipped in this box, so it's still the
      # default when the buy form doesn't supply parcel dimensions (i.e. the
      # Openspool case, where the UI doesn't ask for them - see orders.rhtml).
      DEFAULT_PARCEL = {
        length: 6,
        width: 4,
        height: 4,
        weight: 5
      }.freeze

      # Carrier families quoted in the buy window's price check, and the
      # only ones create_label will buy from. USPS is first/default - see
      # cheapest_rate. "Family" because a carrier account's actual name on
      # EasyPost isn't necessarily the bare carrier name - e.g. this
      # account's rates come back as carrier "FedExDefault" / "UPSDAP", not
      # "FedEx" / "UPS" - so rates are matched by prefix, not exact string.
      QUOTED_CARRIERS = %w[usps fedex ups].freeze

      def initialize
        @client = create_client
      end

      # Creates the shipment (which is how EasyPost computes rates) without
      # buying a label, so the buy window can show a price before the user
      # commits. Returns the shipment id (to buy later via create_label's
      # shipment_id:) plus each QUOTED_CARRIERS carrier's cheapest rate -
      # carriers with no rate for this shipment (unsupported service,
      # oversized/overweight, etc.) are just omitted.
      #
      # parcel_override, if given, must have :length, :width, :height and
      # :weight all present - anything else falls back to DEFAULT_PARCEL.
      def get_rates(order_number, order_data, from_address_id, parcel_override = nil)
        shipment = create_shipment(order_number, order_data, from_address_id, parcel_override)
        rates = QUOTED_CARRIERS.filter_map { |family| quote(shipment, family) }
        log_rate_gaps(shipment, rates)
        { shipment_id: shipment.id, rates: rates }
      end

      # parcel_override, if given, must have :length, :width, :height and
      # :weight all present - anything else falls back to DEFAULT_PARCEL.
      # If shipment_id is given (from a prior get_rates call), that same
      # shipment is bought instead of creating a new one - so the price
      # charged matches the price already shown to the user, and
      # order_data/parcel_override are ignored. carrier picks which of
      # QUOTED_CARRIERS to buy from - defaults to USPS.
      def create_label(order_number, order_data, from_address_id, parcel_override = nil, shipment_id: nil, carrier: 'usps')
        shipment = shipment_id ? @client.shipment.retrieve(shipment_id) : create_shipment(order_number, order_data, from_address_id, parcel_override)
        buy_shipment(shipment, carrier)
      end

      private

      def quote(shipment, family)
        rate = cheapest_rate(shipment, family)
        return nil unless rate

        { carrier: family, service: rate.service, rate: rate.rate, currency: rate.currency }
      end

      # Matches shipment.rates by whether the rate's actual carrier name
      # (e.g. "FedExDefault", "UPSDAP") starts with the family we're
      # quoting (e.g. "fedex", "ups") - see QUOTED_CARRIERS comment.
      def cheapest_rate(shipment, family)
        Array(shipment.rates)
          .select { |rate| rate.carrier.to_s.downcase.start_with?(family) }
          .min_by { |rate| rate.rate.to_f }
      end

      # shipment.messages is where EasyPost puts the carrier's own
      # explanation for a missing rate (bad credentials, weight/size limits,
      # service not enabled, etc.) - logged whenever a QUOTED_CARRIERS entry
      # comes back empty, so "why didn't FedEx/UPS show up" is answered in
      # the logs instead of just silently disappearing.
      def log_rate_gaps(shipment, rates)
        missing = QUOTED_CARRIERS - rates.map { |r| r[:carrier] }
        return if missing.empty?

        puts "No rate for #{missing.join(', ')} on shipment #{shipment.id}:"
        Array(shipment.messages).each do |message|
          puts "  #{message.carrier}: #{message.type} - #{message.message}"
        end
      end

      def create_client
        EasyPost::Client.new(api_key: ENV['EASYPOST_API_KEY'])
      end

      def create_shipment(order_number, order_data, from_address_id, parcel_override)
        from_address = retrieve_from_address(from_address_id)
        @client.shipment.create(
          reference: order_number,
          to_address: build_to_address(order_data, from_address.phone),
          from_address: from_address,
          parcel: build_parcel(parcel_override)
        )
      end

      # Some carriers (FedEx in particular) reject label purchase entirely
      # with PHONENUMBER.EMPTY if to_address has no phone, even though
      # EasyPost's own Address schema treats phone as optional. Tindie/
      # Stripe orders don't always have a recipient phone on file, so fall
      # back to the return address's own phone rather than failing the buy.
      def build_to_address(order_data, fallback_phone)
        {
          name: order_data['shipping_name'],
          street1: order_data['shipping_street'],
          city: order_data['shipping_city'],
          state: order_data['shipping_state'],
          zip: order_data['shipping_postcode'],
          country: order_data['shipping_country'],
          phone: order_data['shipping_phone'].to_s.empty? ? fallback_phone : order_data['shipping_phone'],
          email: order_data['email']
        }
      end

      def retrieve_from_address(from_address_id)
        @client.address.retrieve(from_address_id)
      end

      def build_parcel(parcel_override)
        required = %i[length width height weight]
        return DEFAULT_PARCEL unless parcel_override && required.all? { |key| parcel_override[key].to_s != '' }

        parcel_override.slice(*required)
      end

      def buy_shipment(shipment, carrier)
        bought_shipment = @client.shipment.buy(shipment.id, rate: pick_rate(shipment, carrier))
        {
          tracking_code: bought_shipment.tracking_code,
          label_url: bought_shipment.postage_label.label_url
        }
      end

      # The requested carrier family's cheapest rate - but if this shipment
      # has no rate at all for that family (e.g. it disappeared between
      # quoting and buying, or an unrecognized carrier was passed in), fall
      # back first to USPS, then to the cheapest rate from any carrier,
      # rather than failing the purchase outright.
      def pick_rate(shipment, carrier)
        cheapest_rate(shipment, carrier) ||
          cheapest_rate(shipment, 'usps') ||
          Array(shipment.rates).min_by { |rate| rate.rate.to_f } ||
          raise(EasyPost::Errors::FilteringError.new(EasyPost::Constants::NO_MATCHING_RATES))
      end
    end
  end