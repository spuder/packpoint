require 'yaml'

module ShippingApp
  # Loads config/customs_catalog.yml (see that file for the format/why) and
  # looks entries up by Tindie SKU/model. A missing file or a product with
  # no entry both just resolve to {} - CustomsInfoBuilder treats that as
  # "needs to be filled in by hand" rather than raising, since a brand new
  # product shouldn't block *other* orders from shipping.
  class CustomsCatalog
    DEFAULT_PATH = File.join(Dir.pwd, 'config', 'customs_catalog.yml')

    class << self
      # Memoized so the file is only parsed once per process - reloading
      # requires a restart, same as every other ENV-driven config here.
      def instance
        @instance ||= new(ENV['CUSTOMS_CATALOG_PATH'] || DEFAULT_PATH)
      end
    end

    def initialize(path)
      @entries = load_entries(path)
    end

    # sku/model are matched case-insensitively - Tindie SKUs get typed by
    # hand in a few different places and don't always match case exactly.
    def lookup(sku:, model:)
      @entries[normalize(sku)] || @entries[normalize(model)] || {}
    end

    private

    def normalize(value)
      value.to_s.strip.downcase
    end

    def load_entries(path)
      unless File.exist?(path)
        puts "No customs catalog found at #{path} - international Tindie orders will need customs info filled in by hand"
        return {}
      end

      raw = YAML.safe_load(File.read(path)) || {}
      (raw['products'] || {}).each_with_object({}) do |(key, fields), out|
        fields ||= {}
        out[normalize(key)] = {
          hs_tariff_number: fields['hs_tariff_number'],
          origin_country: fields['origin_country'],
          customs_description: fields['customs_description'],
          value: fields['value'] && fields['value'].to_f
        }
      end
    rescue => e
      puts "WARNING: failed to load customs catalog from #{path}: #{e.class} - #{e.message}"
      {}
    end
  end
end
