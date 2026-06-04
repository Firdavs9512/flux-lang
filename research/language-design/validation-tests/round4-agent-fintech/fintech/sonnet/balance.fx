# balance.fx — balance queries and reconciliation check
#
# Two balance surfaces:
#   1. Cached balance in `balances` table (fast, may lag if a bug exists)
#   2. Authoritative ledger sum (always correct by definition)
#
# The reconciliation check computes (2) and compares to (1).

use db http
use ./ledger as ledger_mod

# Returns both cached and ledger-computed balance for an account.
exp fn full_balance account_id
  acct = db.one "select * from accounts where id=$1" [account_id]
  if acct == nil
    fail "account ${account_id} not found"
  cached  = ledger_mod.get_balance account_id
  ledger  = ledger_mod.compute_balance account_id
  {
    account_id:account_id
    currency:acct.currency
    cached_available:(cached.available ?? 0)
    cached_pending:(cached.pending ?? 0)
    ledger_credits:ledger.credits
    ledger_debits:ledger.debits
    ledger_net:ledger.net
    in_sync:(cached.available ?? 0) == ledger.net
  }

# Reconcile a single account: returns discrepancy map or nil if in sync.
exp fn reconcile_account account_id
  b = full_balance account_id
  if b.in_sync
    ret nil
  {
    account_id:account_id
    cached:b.cached_available
    ledger:b.ledger_net
    discrepancy:(b.cached_available - b.ledger_net)
  }

# HTTP: GET /accounts/:id/balance
http.on :get "/accounts/:id/balance" \req ->
  acct = db.one "select * from accounts where id=$1" [req.params.id]
  if acct == nil
    ret rep 404 {error:"account not found"}
  b = full_balance req.params.id
  rep 200 b

# HTTP: GET /accounts/:id/reconcile — on-demand reconciliation for one account
http.on :get "/accounts/:id/reconcile" \req ->
  acct = db.one "select * from accounts where id=$1" [req.params.id]
  if acct == nil
    ret rep 404 {error:"account not found"}
  disc = reconcile_account req.params.id
  if disc == nil
    ret rep 200 {status:"ok" account_id:req.params.id message:"balance in sync with ledger"}
  rep 200 {status:"discrepancy" detail:disc}
