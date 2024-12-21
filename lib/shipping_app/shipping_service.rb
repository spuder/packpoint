module ShippingApp
    class ShippingService
      def initialize(env = ENV['APP_ENV'])
        @client = create_client(env)
      end
  
      def create_label(order_number, order_data)
        shipment = create_shipment(order_number, order_data)
        buy_shipment(shipment)
      end
  
      private
  
      def create_client(env)
        api_key = case env
        when 'development' then ENV['EASYPOST_TEST_API_KEY']
        when 'production' then ENV['EASYPOST_PROD_API_KEY']
        else
          raise "Unknown APP_ENV: #{env}"
        end
        
        EasyPost::Client.new(api_key: api_key)
      end
  
      def create_shipment(order_number, order_data)
        @client.shipment.create(
          reference: order_number,
          to_address: build_to_address(order_data),
          from_address: retrieve_from_address,
          parcel: default_parcel
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
  
      def retrieve_from_address
        @client.address.retrieve(ENV['EASYPOST_FROM_ADDRESS'])
      end
  
      def default_parcel
        {
          length: 6,
          width: 4,
          height: 4,
          weight: 5
        }
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