require 'net/http'
require 'uri'
require 'json'

module ShippingApp
  module ShippingProviders
    # ShipStation's V2 API (https://docs.shipstation.com/apis/openapi) - the
    # first store to use this is Jurassic Stacks (a Stripe store, see
    # StoreShippingConfig), with Tindie staying on EasyPost. There's no
    # official Ruby client for it, so this talks to it directly over HTTPS
    # with Net::HTTP rather than pull in a new gem for a handful of
    # endpoints. (V2's error payloads carry "error_source": "shipengine" -
    # it's ShipEngine's API under a ShipStation-branded base URL/key.)
    #
    # One ShipStation account per PackPoint instance (SHIPSTATION_API_KEY);
    # what varies per store is only the ship-from address, given at
    # construction time - see ShippingProviders.build / StoreShippingConfig.
    #
    # Unlike EasyPost (one shipment, buy whichever carrier's rate you like,
    # at buy time), ShipStation buys a specific previously-quoted *rate*
    # (POST /v2/labels/rates/{rate_id}) - so #get_rates's shipment_id here
    # is this provider's own opaque token carrying the rate_id for each
    # CARRIER_FAMILIES member that had one, not just ShipStation's shipment
    # id - see #encode_token/#decode_token.
    class ShipStationProvider
      BASE_URL = 'https://api.shipstation.com'.freeze
      REQUEST_TIMEOUT_SECONDS = 30

      REQUEST_CLASSES = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.freeze

      # Openspool orders have always shipped in this box - matches
      # EasyPostProvider::DEFAULT_PARCEL, see that constant's comment.
      DEFAULT_PARCEL = {
        length: 6,
        width: 4,
        height: 4,
        weight: 5
      }.freeze

      # Best-effort mapping of ShipStation/ShipEngine's `carrier_code`
      # (which identifies *how* a carrier is connected - e.g. USPS via
      # Stamps.com vs. Endicia - not the bare carrier name) onto the
      # CARRIER_FAMILIES vocabulary shared with EasyPostProvider, so
      # views/orders.rhtml renders the same carrier icon/label regardless
      # of provider. Confirmed against a live ShipStation sandbox account's
      # connected carriers (stamps_com/ups/fedex) while building this - if
      # a differently-connected carrier (e.g. a UPS reseller integration)
      # shows up with a carrier_code not listed here, it's just quietly
      # excluded from quotes, the same tolerant behavior as EasyPost's own
      # carrier prefix matching. Extend this table if that happens.
      CARRIER_CODE_FAMILIES = {
        'stamps_com' => 'usps',
        'endicia' => 'usps',
        'usps' => 'usps',
        'ups' => 'ups',
        'ups_walleted' => 'ups',
        'fedex' => 'fedex',
        'fedex_walleted' => 'fedex',
        'dhl_express' => 'dhl',
        'dhl_express_worldwide' => 'dhl',
        'dhl_express_mydhl' => 'dhl'
      }.freeze

      def initialize(ship_from)
        @ship_from = ship_from || {}
        @api_key = ENV['SHIPSTATION_API_KEY'].to_s
        raise CarrierError, 'SHIPSTATION_API_KEY is not configured' if @api_key.empty?
      end

      # See ShippingProviders module doc for the shared contract - mirrors
      # EasyPostProvider#get_rates.
      def get_rates(order_number, order_data, parcel_override = nil, customs_items: nil)
        rate_response = quote_shipment(order_number, order_data, parcel_override, customs_items)
        by_family = cheapest_by_family(rate_response['rates'])

        rates = CARRIER_FAMILIES.filter_map do |family|
          rate = by_family[family]
          next unless rate

          { carrier: family, service: rate['service_type'], rate: rate_total(rate),
            currency: rate.dig('shipping_amount', 'currency') || 'usd' }
        end
        log_rate_gaps(rate_response, rates)

        {
          shipment_id: encode_token(rate_response['shipment_id'], by_family.transform_values { |rate| rate['rate_id'] }),
          rates: rates
        }
      end

      # See ShippingProviders module doc for the shared contract - mirrors
      # EasyPostProvider#create_label. If shipment_id is given (from a
      # prior get_rates call), the exact rate already shown to the user is
      # bought, same as EasyPost's shipment_id reuse - otherwise a fresh
      # quote is taken first.
      def create_label(order_number, order_data, parcel_override = nil, shipment_id: nil, carrier: 'usps', customs_items: nil)
        token = decode_token(shipment_id)
        rate_ids = if token
                     token[:rate_ids]
                   else
                     rate_response = quote_shipment(order_number, order_data, parcel_override, customs_items)
                     cheapest_by_family(rate_response['rates']).transform_values { |rate| rate['rate_id'] }
                   end

        buy_rate(pick_rate_id(rate_ids, carrier))
      end

      # See ShippingProviders module doc for the shared contract - mirrors
      # EasyPostProvider#verify_address. Informational, not a gate - same
      # rationale as EasyPost's version.
      def verify_address(order_data)
        result = Array(request(:post, '/v2/addresses/validate', [build_ship_to(order_data)])).first || {}

        {
          verified: result['status'] == 'verified',
          messages: verification_messages(result['messages']),
          normalized_address: format_address(result['matched_address'] || result['original_address'])
        }
      rescue CarrierError => e
        { verified: false, messages: [e.message], normalized_address: nil }
      end

      private

      def quote_shipment(order_number, order_data, parcel_override, customs_items)
        body = {
          rate_options: { carrier_ids: carrier_ids },
          shipment: build_shipment_payload(order_number, order_data, parcel_override, customs_items)
        }
        request(:post, '/v2/rates', body).fetch('rate_response', {})
      end

      def buy_rate(rate_id)
        puts "ShipStation: buying label for rate #{rate_id}"
        label = request(:post, "/v2/labels/rates/#{rate_id}", { label_format: 'pdf', label_layout: '4x6' })
        puts "ShipStation: bought label #{label['label_id']}, tracking_number=#{label['tracking_number']}"
        {
          tracking_code: label['tracking_number'],
          label_url: label.dig('label_download', 'pdf') || label.dig('label_download', 'href')
        }
      end

      # The requested carrier family's rate_id from this shipment's quote -
      # but if that family isn't in rate_ids (e.g. it disappeared between
      # quoting and buying, or an unrecognized carrier was passed in), fall
      # back first to USPS, then to whichever rate is available, rather
      # than failing the purchase outright - same fallback order as
      # EasyPostProvider#pick_rate.
      def pick_rate_id(rate_ids, carrier)
        rate_ids = Hash(rate_ids).transform_keys(&:to_s)
        rate_ids[carrier.to_s] || rate_ids['usps'] || rate_ids.values.first ||
          raise(CarrierError, 'No ShipStation rate available to buy a label from')
      end

      # carrier_ids (which carriers to request rates from) is refetched
      # per instance rather than cached across requests, so a carrier
      # connected/disconnected in the ShipStation dashboard shows up
      # without restarting PackPoint - one extra GET, which is cheap next
      # to the rate/label calls themselves.
      def carrier_ids
        @carrier_ids ||= request(:get, '/v2/carriers').fetch('carriers', []).map { |c| c['carrier_id'] }
      end

      def build_shipment_payload(order_number, order_data, parcel_override, customs_items)
        payload = {
          external_order_id: order_number,
          ship_from: ship_from_payload,
          ship_to: build_ship_to(order_data),
          packages: build_packages(parcel_override)
        }
        customs = build_customs(Array(customs_items))
        payload[:customs] = customs if customs
        payload
      end

      def ship_from_payload
        compact_blank(
          name: @ship_from[:name],
          company_name: @ship_from[:company],
          phone: @ship_from[:phone],
          address_line1: @ship_from[:street1],
          address_line2: @ship_from[:street2],
          city_locality: @ship_from[:city],
          state_province: @ship_from[:state],
          postal_code: @ship_from[:zip],
          country_code: @ship_from[:country]
        )
      end

      # Some carriers reject label purchase entirely if to_address has no
      # phone (see EasyPostProvider#build_to_address for the FedEx
      # specifics) - Tindie/Stripe orders don't always have a recipient
      # phone on file, so fall back to the return address's own phone
      # rather than failing the buy.
      def build_ship_to(order_data)
        compact_blank(
          name: order_data['shipping_name'],
          phone: order_data['shipping_phone'].to_s.empty? ? @ship_from[:phone] : order_data['shipping_phone'],
          email: order_data['email'],
          address_line1: order_data['shipping_street'],
          city_locality: order_data['shipping_city'],
          state_province: order_data['shipping_state'],
          postal_code: order_data['shipping_postcode'],
          country_code: order_data['shipping_country']
        )
      end

      def build_packages(parcel_override)
        parcel = build_parcel(parcel_override)
        [{
          weight: { value: parcel[:weight].to_f, unit: 'ounce' },
          dimensions: { unit: 'inch', length: parcel[:length].to_f, width: parcel[:width].to_f, height: parcel[:height].to_f }
        }]
      end

      def build_parcel(parcel_override)
        required = %i[length width height weight]
        return DEFAULT_PARCEL unless parcel_override && required.all? { |key| parcel_override[key].to_s != '' }

        parcel_override.slice(*required)
      end

      # ShipStation's customs_items (unlike EasyPost's) don't take a
      # per-item weight, so there's no need for EasyPostProvider's
      # weight-splitting - description/quantity/value/HS code/origin
      # country carry over as-is from the international ship panel's draft
      # items (see CustomsInfoBuilder).
      def build_customs(items)
        return nil if items.empty?

        {
          contents: 'merchandise',
          non_delivery: 'return_to_sender',
          customs_items: items.map do |item|
            {
              description: item[:description].to_s.empty? ? 'Merchandise' : item[:description],
              quantity: [item[:quantity].to_i, 1].max,
              value: { currency: 'usd', amount: item[:value].to_f },
              harmonized_tariff_code: item[:hs_tariff_number].to_s.strip,
              country_of_origin: item[:origin_country].to_s.strip.upcase
            }
          end
        }
      end

      def cheapest_by_family(rates)
        Array(rates).each_with_object({}) do |rate, best|
          family = CARRIER_CODE_FAMILIES[rate['carrier_code'].to_s]
          next unless family

          best[family] = rate if best[family].nil? || rate_total(rate) < rate_total(best[family])
        end
      end

      # ShipStation splits a rate's total across shipping/insurance/
      # confirmation/other (e.g. fuel surcharge, residential fee) amounts
      # rather than one all-in price like EasyPost - summed here so the
      # buy window's displayed price actually matches what gets charged.
      def rate_total(rate)
        %w[shipping_amount insurance_amount confirmation_amount other_amount].sum do |key|
          rate.dig(key, 'amount').to_f
        end
      end

      # rate_response.invalid_rates/errors is where ShipStation puts why a
      # carrier didn't return a rate (bad credentials, weight/size limits,
      # service not enabled, etc.) - logged whenever a CARRIER_FAMILIES
      # entry comes back empty, mirroring EasyPostProvider#log_rate_gaps.
      def log_rate_gaps(rate_response, rates)
        missing = CARRIER_FAMILIES - rates.map { |r| r[:carrier] }
        return if missing.empty?

        puts "No rate for #{missing.join(', ')} on ShipStation shipment #{rate_response['shipment_id']}:"
        Array(rate_response['invalid_rates']).each { |invalid| puts "  #{invalid.inspect}" }
        Array(rate_response['errors']).each { |error| puts "  #{error.inspect}" }
      end

      def verification_messages(messages)
        Array(messages).map { |message| message.is_a?(Hash) ? (message['message'] || message.to_s) : message.to_s }
      end

      def format_address(address)
        return nil unless address

        [address['address_line1'], address['address_line2'], address['city_locality'],
         address['state_province'], address['postal_code'], address['country_code']]
          .compact.reject { |part| part.to_s.empty? }.join(', ')
      end

      def compact_blank(hash)
        hash.reject { |_, value| value.to_s.empty? }
      end

      # create_label's shipment_id is opaque to callers (see
      # ShippingProviders module doc) - packs ShipStation's own shipment id
      # (informational only) with the rate_id actually quoted per carrier
      # family, since buying means POSTing to a specific rate_id, not "this
      # shipment, whichever carrier" like EasyPost.
      def encode_token(shipment_id, rate_ids_by_family)
        JSON.generate(shipment_id: shipment_id, rate_ids: rate_ids_by_family)
      end

      # Tolerant of garbage/stale input (a token from a different provider,
      # a hand-edited form field, ...) - just treated as "no prior quote",
      # same as shipment_id: nil, rather than raising.
      def decode_token(token)
        return nil if token.to_s.empty?

        parsed = JSON.parse(token, symbolize_names: true)
        parsed[:rate_ids] ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def request(method, path, body = nil)
        response = perform_request(method, path, body)
        parsed = parse_response(response)
        raise CarrierError, error_message(parsed, response) if !response.is_a?(Net::HTTPSuccess) || provider_errors(parsed).any?

        parsed
      rescue CarrierError
        raise
      rescue StandardError => e
        raise CarrierError, "ShipStation request failed: #{e.class} - #{e.message}"
      end

      def perform_request(method, path, body)
        uri = URI.join(BASE_URL, path)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = REQUEST_TIMEOUT_SECONDS
        http.read_timeout = REQUEST_TIMEOUT_SECONDS

        req = REQUEST_CLASSES.fetch(method).new(uri)
        req['api-key'] = @api_key
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body) unless body.nil?

        http.request(req)
      end

      def parse_response(response)
        body = response.body.to_s
        body.empty? ? {} : JSON.parse(body)
      end

      # /v2/addresses/validate (unlike every other endpoint used here)
      # responds with a top-level JSON array, not object, so there's no
      # top-level `errors` field to check there - only Hash responses carry
      # one.
      def provider_errors(parsed)
        parsed.is_a?(Hash) ? Array(parsed['errors']) : []
      end

      def error_message(parsed, response)
        messages = provider_errors(parsed).map { |error| error.is_a?(Hash) ? error['message'] : error.to_s }
        messages = ["ShipStation HTTP #{response.code}"] if messages.empty?
        messages.join('; ')
      end
    end
  end
end
