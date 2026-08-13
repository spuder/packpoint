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

      def initialize
        @client = create_client
      end

      # Creates the shipment (which is how EasyPost computes rates) without
      # buying a label, so the buy window can show a price before the user
      # commits. Returns the shipment id (to buy later via create_label's
      # shipment_id:) plus the same lowest rate buying it would charge.
      #
      # parcel_override, if given, must have :length, :width, :height and
      # :weight all present - anything else falls back to DEFAULT_PARCEL.
      def get_rate(order_number, order_data, from_address_id, parcel_override = nil)
        shipment = create_shipment(order_number, order_data, from_address_id, parcel_override)
        rate = shipment.lowest_rate
        {
          shipment_id: shipment.id,
          carrier: rate.carrier,
          service: rate.service,
          rate: rate.rate,
          currency: rate.currency
        }
      end

      # parcel_override, if given, must have :length, :width, :height and
      # :weight all present - anything else falls back to DEFAULT_PARCEL.
      # If shipment_id is given (from a prior get_rate call), that same
      # shipment is bought instead of creating a new one - so the price
      # charged matches the price already shown to the user, and
      # order_data/parcel_override are ignored.
      def create_label(order_number, order_data, from_address_id, parcel_override = nil, shipment_id: nil)
        shipment = shipment_id ? @client.shipment.retrieve(shipment_id) : create_shipment(order_number, order_data, from_address_id, parcel_override)
        buy_shipment(shipment)
      end

      private

      def create_client
        EasyPost::Client.new(api_key: ENV['EASYPOST_API_KEY'])
      end

      def create_shipment(order_number, order_data, from_address_id, parcel_override)
        @client.shipment.create(
          reference: order_number,
          to_address: build_to_address(order_data),
          from_address: retrieve_from_address(from_address_id),
          parcel: build_parcel(parcel_override)
        )
      end

      def build_to_address(order_data)
        {
          name: order_data['shipping_name'],
          street1: order_data['shipping_street'],
          city: order_data['shipping_city'],
          state: order_data['shipping_state'],
          zip: order_data['shipping_postcode'],
          country: order_data['shipping_country'],
          phone: order_data['shipping_phone'],
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

      def buy_shipment(shipment)
        bought_shipment = @client.shipment.buy(shipment.id, rate: shipment.lowest_rate)
        {
          tracking_code: bought_shipment.tracking_code,
          label_url: bought_shipment.postage_label.label_url
        }
      end
    end
  end