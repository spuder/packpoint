module ShippingApp
    class VCRSanitizer
      FAKE_DATA_MAPPING = {}
  
      class << self
        def sanitize_interaction(interaction)
          sanitize_request(interaction.request)
          sanitize_response(interaction.response)
        end
  
        private
  
        def sanitize_request(request)
          request.uri.gsub!(/api_key=([^&]+)/, 'api_key=<FILTERED>')
          sanitize_headers(request.headers)
        end
  
        def sanitize_headers(headers)
          headers.transform_values! do |values|
            values.map do |value|
              next unless value.is_a?(String)
              value.gsub(ENV['TINDIE_API_KEY'], '<FILTERED>')
                   .gsub(ENV['TINDIE_USERNAME'], '<FILTERED>')
            end
          end
        end
  
        def sanitize_response(response)
          return unless response.body.is_a?(String)
          
          begin
            data = JSON.parse(response.body)
            sanitize_orders(data['orders']) if data['orders']
            response.body = data.to_json
          rescue JSON::ParserError => e
            puts "Warning: Could not parse JSON in response body: #{e.message}"
          end
        end
  
        def sanitize_orders(orders)
          orders.each do |order|
            sanitize_order_fields(order)
          end
        end
  
        def sanitize_order_fields(order)
          {
            'number' => -> { rand(100000..999999).to_s },
            'email' => -> { Faker::Internet.unique.email },
            'shipping_name' => -> { Faker::Name.unique.name },
            'phone' => -> { Faker::PhoneNumber.cell_phone_in_e164 },
            'shipping_street' => -> { Faker::Address.unique.street_address },
            'shipping_city' => -> { Faker::Address.city },
            'shipping_postcode' => -> { Faker::Address.zip_code },
            'company_title' => -> { Faker::Company.name },
            'message' => -> { Faker::Lorem.sentence }
          }.each do |field, generator|
            if order[field].to_s.strip.length > 0
              order[field] = FAKE_DATA_MAPPING[order[field]] ||= generator.call
            end
          end
        end
      end
    end
  end