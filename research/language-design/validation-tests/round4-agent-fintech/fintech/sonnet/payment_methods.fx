# payment_methods.fx — payment method management (cards, bank accounts, etc.)

use db http
use ./audit as audit_mod

exp fn add_payment_method owner kind last4
  allowed_kinds = [:card :bank_account :wallet]
  if !(allowed_kinds.has kind)
    fail "invalid payment method kind: ${kind}"
  if str.len last4 != 4
    fail "last4 must be exactly 4 characters"

  pm = db.ins "payment_methods" {
    owner:owner
    kind:kind
    last4:last4
    status::active
  }
  audit_mod.write_audit owner "add_payment_method" "payment_method:${pm.id}" {} pm
  pm

exp fn deactivate_payment_method pm_id actor
  pm = db.one "select * from payment_methods where id=$1" [pm_id]
  if pm == nil
    fail "payment method ${pm_id} not found"
  db.up "payment_methods" {status::inactive} {id:pm_id}
  audit_mod.write_audit actor "deactivate_payment_method" "payment_method:${pm_id}" pm {status::inactive}
  {ok:true}

# HTTP routes
http.on :post "/payment-methods" \req ->
  if !req.body.owner
    ret rep 400 {error:"owner required"}
  if !req.body.kind
    ret rep 400 {error:"kind required"}
  if !req.body.last4
    ret rep 400 {error:"last4 required"}
  pm = add_payment_method req.body.owner req.body.kind req.body.last4
  rep 201 pm

http.on :get "/payment-methods" \req ->
  if !req.query.owner
    ret rep 400 {error:"owner query param required"}
  methods = db.q "select * from payment_methods where owner=$1 order by created desc" [req.query.owner]
  rep 200 methods

http.on :del "/payment-methods/:id" \req ->
  actor = req.headers.x_actor ?? "system"
  result = deactivate_payment_method req.params.id actor
  rep 200 result
