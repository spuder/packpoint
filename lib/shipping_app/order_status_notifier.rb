require 'net/http'
require 'uri'
require 'json'

module ShippingApp
  # Notifies a Stripe store's own order-status webhook once its order has
  # actually been confirmed shipped in PackPoint (see App#post
  # '/confirm_shipped/:order_number' - the only caller, since it's the only
  # place that always has a real carrier: PackPoint just bought the label).
  #
  # This is a fire of one HTTP call, not an email - the receiving store is
  # expected to send its own customer-facing email once it gets this (e.g.
  # jurassicstacks' src/pages/api/order-status.ts calls Resend itself on
  # receipt). PackPoint never touches Resend directly.
  #
  # Contract (matches jurassicstacks' /api/order-status - see its README's
  # "Order status notifications" section):
  #
  #   POST <STRIPE_STORE_<id>_ORDER_STATUS_WEBHOOK_URL>
  #   Authorization: Bearer <STRIPE_STORE_<id>_ORDER_STATUS_WEBHOOK_SECRET>
  #   { "orderId": "...", "email": "...", "status": "shipped",
  #     "tracking": { "carrier": "USPS", "trackingNumber": "...", "trackingUrl": "..." } }
  #
  # Both env vars are optional per store - a store that hasn't configured
  # them just gets a log line saying so, since the order is already shipped
  # in Stripe by the time this runs and that can't be undone by a
  # notification failing.
  class OrderStatusNotifier
    HTTP_TIMEOUT_SECONDS = 8

    # jurassicstacks drops this straight into email copy ("shipped via
    # USPS"), so it wants a display name, not PackPoint's internal lowercase
    # carrier family (see ShippingService::QUOTED_CARRIERS).
    CARRIER_LABELS = { 'usps' => 'USPS', 'fedex' => 'FedEx', 'ups' => 'UPS', 'dhl' => 'DHL' }.freeze

    class << self
      def notify_shipped(store:, order_number:, recipient_email:, carrier:, tracking_code:, tracking_url: nil)
        return log_skip(store, order_number, "STRIPE_STORE_#{store.key.upcase}_ORDER_STATUS_WEBHOOK_URL not set") if store.order_status_webhook_url.to_s.empty?
        return log_skip(store, order_number, "STRIPE_STORE_#{store.key.upcase}_ORDER_STATUS_WEBHOOK_SECRET not set") if store.order_status_webhook_secret.to_s.empty?
        return log_skip(store, order_number, 'no recipient email on file for this order') if recipient_email.to_s.empty?

        body = build_body(order_number: order_number, recipient_email: recipient_email, carrier: carrier,
                           tracking_code: tracking_code, tracking_url: tracking_url)

        response = post_json(store.order_status_webhook_url, body, 'Authorization' => "Bearer #{store.order_status_webhook_secret}")
        if response.is_a?(Net::HTTPSuccess)
          puts "OrderStatusNotifier[#{store.name}]: sent order-status webhook for order #{order_number} to #{store.order_status_webhook_url} (#{response.code})"
        else
          puts "WARNING: OrderStatusNotifier[#{store.name}]: order-status webhook for order #{order_number} to #{store.order_status_webhook_url} returned #{response.code}: #{response.body}"
        end
      rescue => e
        puts "WARNING: OrderStatusNotifier[#{store.name}]: failed to send order-status webhook for order #{order_number}: #{e.class} - #{e.message}"
      end

      # Builds the exact same request notify_shipped would send - as a curl
      # command, for the "Info" button next to Mark as Shipped (see POST
      # /confirm_shipped/:order_number/preview in app.rb) - without actually
      # sending it or touching Stripe, so the operator can sanity-check
      # store/order/email/tracking before really confirming shipment. The
      # webhook secret never leaves the server unredacted - only its last 4
      # characters make it into the curl command shown in the browser.
      def preview(store:, order_number:, recipient_email:, carrier:, tracking_code:, tracking_url: nil)
        if store.order_status_webhook_url.to_s.empty?
          return { configured: false, reason: "STRIPE_STORE_#{store.key.upcase}_ORDER_STATUS_WEBHOOK_URL not set - nothing will be called" }
        end
        if store.order_status_webhook_secret.to_s.empty?
          return { configured: false, reason: "STRIPE_STORE_#{store.key.upcase}_ORDER_STATUS_WEBHOOK_SECRET not set - nothing will be called" }
        end

        body = build_body(order_number: order_number, recipient_email: recipient_email, carrier: carrier,
                           tracking_code: tracking_code, tracking_url: tracking_url)
        { configured: true, url: store.order_status_webhook_url, body: body, curl: curl_command(store, body) }
      end

      private

      def build_body(order_number:, recipient_email:, carrier:, tracking_code:, tracking_url:)
        {
          orderId: order_number,
          email: recipient_email,
          status: 'shipped',
          tracking: {
            carrier: CARRIER_LABELS[carrier.to_s.downcase] || carrier.to_s,
            trackingNumber: tracking_code,
            trackingUrl: tracking_url
          }.compact
        }
      end

      def curl_command(store, body)
        json = JSON.generate(body).gsub("'", %q('"'"'))
        "curl -X POST '#{store.order_status_webhook_url}' \\\n" \
          "  -H 'Authorization: Bearer #{redact(store.order_status_webhook_secret)}' \\\n" \
          "  -H 'Content-Type: application/json' \\\n" \
          "  -d '#{json}'"
      end

      # Shows just enough of the real secret (last 4 chars) to confirm it's
      # the expected one without exposing the whole thing to the browser.
      def redact(secret)
        return '*' * secret.length if secret.length <= 4

        "#{'*' * (secret.length - 4)}#{secret[-4..]}"
      end

      def log_skip(store, order_number, reason)
        puts "OrderStatusNotifier[#{store.name}]: skipping order-status webhook for order #{order_number} - #{reason}"
        nil
      end

      def post_json(url, payload, headers)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = HTTP_TIMEOUT_SECONDS
        http.read_timeout = HTTP_TIMEOUT_SECONDS

        request = Net::HTTP::Post.new(uri.request_uri)
        request['Content-Type'] = 'application/json'
        headers.each { |key, value| request[key] = value }
        request.body = payload.to_json

        http.request(request)
      end
    end
  end
end
