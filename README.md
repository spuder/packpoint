<p align=center>
    <img src="./images/logo.png" width="200">
</p>


# PackPoint

The shipping station software for Tindie / Stripe orders, buying labels through EasyPost and/or ShipStation.




## Usage

Create a `.env` file with your settings. You can use the provided examples. 

`cp .env.sample .env`

Stripe support is optional and can pull orders from multiple Stripe stores/accounts at once - add a
`STRIPE_STORE_<id>_NAME` / `STRIPE_STORE_<id>_SECRET_KEY` trio per store (see `.env.sample`), plus that
store's shipping config (see "Shipping providers" below). Orders are matched to Stripe Checkout Sessions
that have collected a shipping address; "shipped" status, tracking code, and label URL are written back to
Stripe as metadata on the PaymentIntent when you buy a label, so fulfillment state lives in Stripe rather
than only in this app's session.

### Shipping providers

Each store - Tindie, and each Stripe store - buys labels through its own shipping provider and ships from
its own return address, configured independently per store so a given store can be moved to a different
provider (or given a different return address) with an env var change and no code change. Two providers are
built in:

- **EasyPost** (the default for every store, and the only option Tindie orders currently use) - set
  `<prefix>_EASYPOST_FROM_ADDRESS` to an EasyPost address id (`adr_...`) for an address already saved in
  your EasyPost account. Requires the account-wide `EASYPOST_API_KEY`.
- **ShipStation** (V2 API, [docs](https://docs.shipstation.com/apis/openapi)) - set
  `<prefix>_SHIPPING_PROVIDER=shipstation` plus `<prefix>_SHIPSTATION_FROM_NAME` / `_COMPANY` (optional) /
  `_PHONE` / `_STREET1` / `_STREET2` (optional) / `_CITY` / `_STATE` / `_POSTAL_CODE` / `_COUNTRY`
  (defaults to `US`). Unlike EasyPost, ShipStation hard-rejects a rate/label request with no phone number
  anywhere on it - set `_PHONE` to a real number, since plenty of Tindie/Stripe orders have no customer
  phone on file and this is the only fallback. ShipStation
  has no equivalent of a saved EasyPost address id unless you've set up a warehouse, so the return address is
  given inline instead. Requires the account-wide `SHIPSTATION_API_KEY`. Carriers quoted are whichever are
  connected to that ShipStation account (`GET /v2/carriers`) - no separate carrier account config needed
  here.

`<prefix>` is `TINDIE` for the one Tindie store, or `STRIPE_STORE_<id>` for a given Stripe store - see
`.env.sample` for a worked example (a "Jurassic Stacks" Stripe store on ShipStation alongside a Tindie store
still on EasyPost). A store with no `<prefix>_SHIPPING_PROVIDER` set defaults to EasyPost. Misconfigured
stores (missing/incomplete address for the provider they're set to) log a warning at boot rather than
failing to start - see `ShippingApp::StoreShippingConfig`/`ShippingApp::ShippingProviders`.

Everything above is env-var/Docker-only for now, matching how the rest of PackPoint is configured - a future
version may move this into the web UI so it can be changed without redeploying.

### International shipping

International orders get their own panel (instead of a link out to
easypost.com/shipstation.com): a carrier choice (USPS/FedEx/UPS/DHL, quoted the same way as
domestic - whichever have a rate for the shipment), an address check against
the store's shipping provider, and an editable customs form. Works the same regardless of which provider a
store is using.

- **Carrier / rates**: the "Check Price" flow quotes all of
  `ShippingApp::ShippingProviders::CARRIER_FAMILIES`, DHL included - it just
  won't show a carrier that has no rate for the shipment (e.g. DHL not
  connected on that store's provider account, or a service that doesn't reach that
  country). Requires a DHL Express carrier account connected (in EasyPost or ShipStation, whichever that
  store uses) if you want DHL rates at all.
- **Address verification**: expanding an international order's row checks
  the shipping address via the store's provider, and shows the result as a banner. This is informational, not a gate -
  foreign addresses frequently fail strict verification (missing region
  codes, transliteration, limited per-country coverage) even when they're
  perfectly deliverable, so a failed check just means "double check this
  one," not "don't ship it."
- **Customs**: international labels require a customs form.
  Each product's HS tariff code / country of origin / customs description
  is pre-filled where possible and always editable in the panel before
  buying:
  - **Stripe** products carry this as native Product metadata - add
    `hs_tariff_number`, `customs_origin_country`, `customs_description`,
    and (optionally) `customs_value` metadata keys on the Product in the
    Stripe dashboard.
  - **Tindie** has no per-product customs fields in its API, so it's
    hardcoded in [`config/customs_catalog.yml`](config/customs_catalog.yml)
    by SKU - see that file for the format. A product with no catalog entry
    just shows up with blank, required fields in the panel rather than
    silently shipping with an empty customs form.
  - `CUSTOMS_SIGNER_NAME` (optional, see `.env.sample`) sets who certifies
    the customs form; defaults to the shipping store's return address name.

Then start the server
`rackup`

localhost:9292

## Development
```
APP_ENV=development rackup
```



## Production
```
APP_ENV=production RACK_ENV=production bundle exec rackup --host 0.0.0.0
```

## Production Docker/Podman

```bash
podman build -t spuder/packpoint . 
podman run  --env-file .env -e APP_ENV=production -e RACK_ENV=production -p 9292:9292 localhost/spuder/packpoint:latest
```

## Example
This example uses Faker to generate dummy addresses and usernames. 

![](images/demo2.png)