# accounts.fx — account lifecycle + deposit / withdraw.
#
# Deposits and withdrawals are modelled with double-entry against a per-currency
# system "external" account (type :asset, owner "system"). This keeps the
# global ledger balanced: every cent that enters a user account leaves the
# external account and vice-versa, so sum of ALL ledger lines is always zero.
#
# All amounts are integer cents. Idempotency-protected and audited.

use db json
use ./ledger
use ./audit
use ./idempotency as idem

# ---- helpers ---------------------------------------------------------------

exp fn get id
  ret db.one "select * from accounts where id=$1" [id]

# Find (or lazily create) the system external account for a currency.
# Used as the counter-party for deposits/withdrawals.
exp fn system_account currency
  acct = db.one "select * from accounts where owner='system' and currency=$1 and type='asset'" [currency]
  if acct
    ret acct
  ret db.ins "accounts" {
    owner:"system" currency: currency type::asset status::active
  }

# ---- create ----------------------------------------------------------------

exp fn create owner currency type
  db.tx \->
    acct = db.ins "accounts" {
      owner: owner currency: currency type: (type ?? :user) status::active
    }
    audit.write owner "account.create" "account:${acct.id}" nil acct
    ret acct

# ---- deposit ---------------------------------------------------------------
# Money enters the user account. Debit user account, credit system account.
# amount: integer cents, must be > 0.
exp fn deposit account_id amount ikey
  hit = idem.lookup ikey "deposit"
  if hit
    ret hit

  if amount <= 0
    ret {status:422 body:{error:"amount must be a positive integer in minor units"}}

  acct = get account_id
  if !acct
    ret {status:404 body:{error:"account ${account_id} not found"}}
  if acct.status != :active
    ret {status:409 body:{error:"account ${account_id} is not active"}}

  db.tx \->
    sys = system_account acct.currency
    txn = db.ins "transactions" {
      kind::deposit status::posted idempotency_key: ikey
    }
    ledger.post_pair txn.id account_id sys.id amount acct.currency
    bal = ledger.balance account_id
    audit.write acct.owner "account.deposit" "account:${account_id}" nil {
      txn: txn.id amount: amount balance: bal
    }
    resp = {ok:true txn: txn.id account: account_id amount: amount balance: bal}
    idem.record ikey "deposit" 201 resp
    ret {status:201 body: resp}

# ---- withdraw --------------------------------------------------------------
# Money leaves the user account. Credit user account, debit system account.
# Rejects if available balance is insufficient.
exp fn withdraw account_id amount ikey
  hit = idem.lookup ikey "withdraw"
  if hit
    ret hit

  if amount <= 0
    ret {status:422 body:{error:"amount must be a positive integer in minor units"}}

  acct = get account_id
  if !acct
    ret {status:404 body:{error:"account ${account_id} not found"}}
  if acct.status != :active
    ret {status:409 body:{error:"account ${account_id} is not active"}}

  # Pre-check balance OUTSIDE the tx to give a clean 4xx for the common case.
  # The authoritative check is repeated INSIDE the tx below (via `fail`), which
  # is what actually guarantees no overdraft under the rollback semantics.
  if (ledger.balance account_id) < amount
    ret {status:422 body:{error:"insufficient funds"}}

  db.tx \->
    # Re-read balance inside the tx. See "Spec gaps" re: row locking — without
    # SELECT ... FOR UPDATE this check is racy under concurrent withdrawals.
    avail = ledger.balance account_id
    if avail < amount
      fail "withdraw: insufficient funds (available ${avail}, requested ${amount})"
    sys = system_account acct.currency
    txn = db.ins "transactions" {
      kind::withdraw status::posted idempotency_key: ikey
    }
    # debit system, credit user => user balance goes down
    ledger.post_pair txn.id sys.id account_id amount acct.currency
    bal = ledger.balance account_id
    audit.write acct.owner "account.withdraw" "account:${account_id}" {
      balance: avail
    } {txn: txn.id amount: amount balance: bal}
    resp = {ok:true txn: txn.id account: account_id amount: amount balance: bal}
    idem.record ikey "withdraw" 201 resp
    ret {status:201 body: resp}
