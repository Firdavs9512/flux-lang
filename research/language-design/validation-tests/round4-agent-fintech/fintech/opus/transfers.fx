# transfers.fx — atomic transfer between two accounts.
#
# A transfer:
#   1. validates accounts exist, are active, same currency, amount > 0
#   2. enforces the daily limit (fraud.fx)
#   3. inside ONE db.tx:
#        - creates a transaction row
#        - posts a balanced debit/credit pair (debit dest, credit source)
#        - re-checks available balance of the source
#        - records the transfer row
#        - writes audit before/after
#        - records the idempotency key
#      If any step fails (insufficient funds, uniq violation, etc.) the WHOLE
#      tx rolls back — no half-applied transfer, no orphan ledger lines.
#
# All amounts are integer cents.

use db json
use ./ledger
use ./accounts
use ./audit
use ./fraud
use ./idempotency as idem

# Validate currency match. Returns nil on success or an error map on mismatch.
fn currency_error from_acct to_acct amount
  if !from_acct
    ret {status:404 body:{error:"source account not found"}}
  if !to_acct
    ret {status:404 body:{error:"destination account not found"}}
  if from_acct.status != :active
    ret {status:409 body:{error:"source account not active"}}
  if to_acct.status != :active
    ret {status:409 body:{error:"destination account not active"}}
  if from_acct.id == to_acct.id
    ret {status:422 body:{error:"cannot transfer to the same account"}}
  if from_acct.currency != to_acct.currency
    ret {status:422 body:{error:"currency mismatch: ${from_acct.currency} -> ${to_acct.currency}"}}
  if amount <= 0
    ret {status:422 body:{error:"amount must be a positive integer in minor units"}}
  ret nil

# Perform a transfer. Returns {status, body}.
exp fn perform from_id to_id amount currency ikey
  # 1. Idempotency: already done? Return the original response verbatim.
  hit = idem.lookup ikey "transfer"
  if hit
    ret hit

  from_acct = accounts.get from_id
  to_acct   = accounts.get to_id

  err = currency_error from_acct to_acct amount
  if err
    ret err

  # Caller-declared currency must also match the accounts.
  if currency != from_acct.currency
    ret {status:422 body:{error:"declared currency ${currency} does not match account currency ${from_acct.currency}"}}

  # 2. Daily limit (deterministic, authoritative).
  lim = fraud.check_daily_limit from_id amount
  if !lim.ok
    # Record a rejected transfer for the audit trail (own tx).
    db.tx \->
      t = db.ins "transfers" {
        from_account: from_id to_account: to_id amount: amount
        currency: currency status::rejected idempotency_key: ikey
      }
      audit.write from_acct.owner "transfer.rejected" "transfer:${t.id}" nil {
        reason:"daily_limit" used: lim.used limit: lim.limit
      }
    ret {status:429 body:{error:"daily transfer limit exceeded" used: lim.used limit: lim.limit}}

  # Pre-check balance for a clean 422 in the common case. The authoritative
  # check is repeated inside the tx (via `fail`) which is what actually
  # guarantees no overdraft under rollback semantics.
  if (ledger.balance from_id) < amount
    ret {status:422 body:{error:"insufficient funds"}}

  # 3. The atomic money movement.
  result = db.tx \->
    # Re-read source balance INSIDE the tx. NOTE: without row-level locking
    # (SELECT ... FOR UPDATE — not exposed by the spec) two transfers racing on
    # the same source can both pass this check. See "Spec gaps". We mitigate by
    # keeping the read + writes in one tx; a correct impl needs a row lock or an
    # atomic conditional update.
    avail = ledger.balance from_id
    if avail < amount
      fail "insufficient funds: available ${avail}, requested ${amount}"

    txn = db.ins "transactions" {
      kind::transfer status::posted idempotency_key: ikey
    }
    # debit destination (its balance up), credit source (its balance down)
    ledger.post_pair txn.id to_id from_id amount currency

    # Defensive invariant check before committing.
    if !(ledger.txn_balanced txn.id)
      fail "internal: transaction ${txn.id} is not balanced"

    xfer = db.ins "transfers" {
      from_account: from_id to_account: to_id amount: amount currency: currency
      status::posted txn: txn.id idempotency_key: ikey
    }

    new_from = ledger.balance from_id
    new_to   = ledger.balance to_id

    audit.write from_acct.owner "transfer.posted" "transfer:${xfer.id}" {
      from_balance: avail
    } {
      transfer: xfer.id txn: txn.id amount: amount
      from_balance: new_from to_balance: new_to
    }

    body = {
      ok:true transfer: xfer.id txn: txn.id
      from_account: from_id to_account: to_id amount: amount currency: currency
      from_balance: new_from to_balance: new_to status::posted
    }
    # Record idempotency LAST: a uniq violation here (concurrent dup) rolls the
    # whole transfer back, and the loser re-reads the winner's cached response.
    idem.record ikey "transfer" 201 body
    ret {status:201 body: body}

  ret result
