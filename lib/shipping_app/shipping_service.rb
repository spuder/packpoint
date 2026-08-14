module ShippingApp
    # Raised for our own request-shape problems (e.g. an international buy
    # with no customs items) - as opposed to EasyPost::Errors::EasyPostError,
    # which covers the carrier/EasyPost API rejecting a well-formed request.
    # app.rb maps this to a 422, same as an EasyPost error.
    class ValidationError < StandardError; end

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
      # DHL only has rates on international shipments in practice, but it's
      # left in this one list rather than split out - quote() already
      # tolerates a carrier having no rate for a given shipment (see
      # log_rate_gaps), so a domestic quote just quietly won't include it.
      QUOTED_CARRIERS = %w[usps fedex ups dhl].freeze

      # contents_type EasyPost puts on every customs form this app
      # generates - shipments here are always store orders, never gifts,
      # returns, samples, etc.
      DEFAULT_CONTENTS_TYPE = 'merchandise'.freeze

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
      # customs_items, if given, is an Array of Hashes (see
      # build_customs_items) and triggers a customs form on the shipment -
      # see create_shipment.
      def get_rates(order_number, order_data, from_address_id, parcel_override = nil, customs_items: nil)
        shipment = create_shipment(order_number, order_data, from_address_id, parcel_override, customs_items)
        rates = QUOTED_CARRIERS.filter_map { |family| quote(shipment, family) }
        log_rate_gaps(shipment, rates)
        { shipment_id: shipment.id, rates: rates }
      end

      # parcel_override, if given, must have :length, :width, :height and
      # :weight all present - anything else falls back to DEFAULT_PARCEL.
      # If shipment_id is given (from a prior get_rates call), that same
      # shipment is bought instead of creating a new one - so the price
      # charged matches the price already shown to the user, and
      # order_data/parcel_override/customs_items are ignored (the customs
      # form was already attached when that shipment was created). carrier
      # picks which of QUOTED_CARRIERS to buy from - defaults to USPS.
      def create_label(order_number, order_data, from_address_id, parcel_override = nil, shipment_id: nil, carrier: 'usps', customs_items: nil)
        shipment = shipment_id ? @client.shipment.retrieve(shipment_id) : create_shipment(order_number, order_data, from_address_id, parcel_override, customs_items)
        buy_shipment(shipment, carrier)
      end

      # Verifies a to-address against EasyPost/carrier data without
      # creating a shipment - used by /verify_address to give the person
      # buying the label a heads-up before they commit. International
      # addresses frequently fail this even when they're perfectly
      # deliverable (EasyPost's delivery verification coverage varies a lot
      # by country), so the result is informational: `verified: false`
      # doesn't mean "don't ship this", it means "double check it".
      def verify_address(order_data)
        address = @client.address.create_and_verify(build_to_address(order_data, nil))
        verifications = address.respond_to?(:verifications) ? address.verifications : nil
        delivery = verifications.respond_to?(:delivery) ? verifications.delivery : nil

        {
          verified: !!(delivery && delivery.success),
          messages: verification_messages(delivery),
          normalized_address: format_address(address)
        }
      rescue EasyPost::Errors::EasyPostError => e
        { verified: false, messages: [e.message], normalized_address: nil }
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

      def create_shipment(order_number, order_data, from_address_id, parcel_override, customs_items_params)
        from_address = retrieve_from_address(from_address_id)
        parcel = build_parcel(parcel_override)
        items = Array(customs_items_params)

        shipment_params = {
          reference: order_number,
          to_address: build_to_address(order_data, from_address.phone),
          from_address: from_address,
          parcel: parcel
        }
        # customs_items only arrives at all from the international ship
        # panel (views/orders.rhtml) - the domestic form doesn't send it -
        # so its presence, not a from/to country comparison, is what decides
        # whether this shipment gets a customs form. app.rb's /rate_label
        # and /buy_label already refuse an international buy with no
        # customs items before this is ever called - see
        # ShippingApp::ValidationError.
        shipment_params[:customs_info] = build_customs_info(items, parcel, from_address) unless items.empty?

        @client.shipment.create(**shipment_params)
      end

      # Builds the EasyPost customs_info hash a shipment.create needs to
      # generate a customs form.
      def build_customs_info(items, parcel, from_address)
        # EasyPost requires a signer name to certify the customs form;
        # falls back to the return address's own name if CUSTOMS_SIGNER_NAME
        # isn't set, since the shipper is a reasonable default signer.
        signer = ENV['CUSTOMS_SIGNER_NAME'].to_s.empty? ? from_address.name : ENV['CUSTOMS_SIGNER_NAME']
        {
          customs_certify: true,
          customs_signer: signer,
          contents_type: DEFAULT_CONTENTS_TYPE,
          restriction_type: 'none',
          non_delivery_option: 'return',
          customs_items: build_customs_items(items, parcel)
        }
      end

      # EasyPost requires a weight per customs item, but the buy form only
      # collects one weight for the whole package (see build_parcel) - so
      # items without their own explicit weight_oz split whatever weight is
      # left over evenly, by quantity. Good enough for a customs form; not
      # meant to be gram-accurate.
      def build_customs_items(items, parcel)
        explicit = items.select { |item| item[:weight_oz].to_s != '' }
        explicit_qty = explicit.sum { |item| item[:quantity].to_i }
        explicit_weight = explicit.sum { |item| item[:weight_oz].to_f * item[:quantity].to_i }

        total_qty = items.sum { |item| [item[:quantity].to_i, 1].max }
        remaining_qty = [total_qty - explicit_qty, 1].max
        remaining_weight = [parcel[:weight].to_f - explicit_weight, 0.1].max
        default_unit_weight = remaining_weight / remaining_qty

        items.map do |item|
          quantity = [item[:quantity].to_i, 1].max
          unit_weight = item[:weight_oz].to_s.empty? ? default_unit_weight : item[:weight_oz].to_f
          {
            description: item[:description].to_s.empty? ? 'Merchandise' : item[:description],
            quantity: quantity,
            value: item[:value].to_f,
            weight: (unit_weight * quantity).round(2),
            hs_tariff_number: item[:hs_tariff_number].to_s.strip,
            origin_country: item[:origin_country].to_s.strip.upcase,
            currency: 'USD'
          }
        end
      end

      def verification_messages(delivery)
        return [] unless delivery

        Array(delivery.errors).map { |error| error.respond_to?(:message) ? error.message : error.to_s }
      end

      def format_address(address)
        [address.street1, address.street2, address.city, address.state, address.zip, address.country]
          .compact.reject(&:empty?).join(', ')
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
