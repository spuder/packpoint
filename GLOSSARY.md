# PackPoint

The shipping station: pulls unshipped orders from every Store into one place, buys and prints Labels, and records orders as Shipped.

## Language

### Sources of orders

**Store**:
One source of orders: the Tindie shop, or a single Stripe account.
_Avoid_: Shop, channel, account

**Platform**:
The kind of system a Store runs on: Tindie or Stripe.
_Avoid_: Store type

**Return Address**:
The address a Label ships from and undeliverable packages come back to. Each Store has exactly one.
_Avoid_: From address, ship-from address

**Operator**:
The person at the shipping station using PackPoint.
_Avoid_: User, packer, admin

### Orders

**Order**:
A customer's purchase from a Store that needs to be packed and shipped.

**Unshipped**:
An Order with no Label yet.

**Labeled**:
An Order with a Label bought but not yet confirmed Shipped. Only the Operator's browser knows an Order is Labeled; the Store still sees it as Unshipped.

**Shipped**:
An Order the Store's own record says has shipped. For a Stripe Store PackPoint records this; for Tindie the Operator enters the tracking code on tindie.com.

**Archive**:
A view of Orders Shipped in the last 30 days. It is not a state.

### Labels

**Quote**:
The carrier prices offered for an Order's parcel at its entered size and weight.
_Avoid_: Rate, price check

**Label**:
Postage bought for an Order, with a carrier and tracking code.
_Avoid_: Postage, shipment

**External Label**:
A Label bought outside PackPoint (e.g. directly in EasyPost) and entered by hand when marking the Order Shipped.
_Avoid_: Ad hoc label, manual label

**Shipped Notification**:
The message PackPoint sends a Store when one of its Orders becomes Shipped; the Store emails the customer itself.
_Avoid_: Tracking email, order-status webhook

### Customs

**Customs Declaration**:
The customs form attached to an international Label, made up of Customs Items.
_Avoid_: Customs form, customs info

**Customs Item**:
One line of a Customs Declaration: description, HS tariff number, origin country, and value.

**Customs Catalog**:
Default Customs Item details for each Tindie SKU; Stripe products carry their own.
