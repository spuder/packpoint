module ShippingApp
  # Stripe::StripeError instances carry a structured Stripe::ErrorObject
  # (type/code/message/request_log_url) with everything needed to actually
  # fix the problem - e.g. which permission a restricted key is missing.
  # Rescuing and only logging e.message throws that away, so this formats
  # the full picture for both server logs and the /orders warning banner.
  module StripeErrorFormatter
    def self.describe(context, error)
      detail = error.respond_to?(:error) ? error.error : nil

      parts = ["Stripe error (#{context}): #{error.message}"]
      parts << "code=#{detail.code}" if detail&.code
      parts << "type=#{detail.type}" if detail&.type
      parts << "fix at #{detail.request_log_url}" if detail&.request_log_url

      parts.join(' | ')
    end
  end
end
