# accounts.fx — account creation, deposit, withdraw
use db http
use ./ledger as ledger_mod
use ./audit as audit_mod

# Create a new account for an owner.
exp fn create_account owner currency type
  if owner == nil | owner == ""
    fail "owner is required"
  if currency == nil | currency == ""
    fail "currency is required"
  allowed_types = [:checking :savings :merchant :escrow]
  if !(allowed_types.has type)
    fail "invalid account type: ${type}"

  acct = db.ins "accounts" {
    owner:owner
    currency:currency
    type:type
    status::active
  }
  # Create balance row
  db.ins "balances" {account_id:acct.id available:0 pending:0}
  audit_mod.write_audit owner "create_account" "account:${acct.id}" {} acct
  acct

# Deposit money into an account (integer cents only).
exp fn deposit account_id amount_cents actor idempotency_key
  if amount_cents <= 0
    fail "deposit amount must be a positive integer (cents)"

  # Idempotency check
  existing_txn = db.one "select * from transactions where idempotency_key=$1" [idempotency_key]
  if existing_txn != nil
    existing_entry = db.one "select * from ledger_entries where transaction_id=$1" [existing_txn.id]
    ret {transaction:existing_txn entry:existing_entry idempotent:true}

  acct = db.one "select * from accounts where id=$1" [account_id]!
  if acct.status != :active
    fail "account ${account_id} is not active"

  result <- nil
  db.tx \->
    txn = db.ins "transactions" {
      kind::deposit
      status::completed
      idempotency_key:idempotency_key
    }
    entry = ledger_mod.post_entry txn.id account_id :credit amount_cents
    ledger_mod.adjust_balance account_id amount_cents
    before_bal = {available:(db.one "select available from balances where account_id=$1" [account_id]).available - amount_cents}
    after_bal  = {available:(db.one "select available from balances where account_id=$1" [account_id]).available}
    audit_mod.write_audit actor "deposit" "account:${account_id}" before_bal after_bal
    result <- {transaction:txn entry:entry idempotent:false}
  result

# Withdraw money from an account (integer cents only).
exp fn withdraw account_id amount_cents actor idempotency_key
  if amount_cents <= 0
    fail "withdrawal amount must be a positive integer (cents)"

  # Idempotency check
  existing_txn = db.one "select * from transactions where idempotency_key=$1" [idempotency_key]
  if existing_txn != nil
    existing_entry = db.one "select * from ledger_entries where transaction_id=$1" [existing_txn.id]
    ret {transaction:existing_txn entry:existing_entry idempotent:true}

  acct = db.one "select * from accounts where id=$1" [account_id]!
  if acct.status != :active
    fail "account ${account_id} is not active"

  result <- nil
  db.tx \->
    # Balance check happens inside tx so the debit and check are consistent
    ledger_mod.adjust_balance account_id (0 - amount_cents)
    txn = db.ins "transactions" {
      kind::withdrawal
      status::completed
      idempotency_key:idempotency_key
    }
    entry = ledger_mod.post_entry txn.id account_id :debit amount_cents
    before_bal = {available:(db.one "select available from balances where account_id=$1" [account_id]).available + amount_cents}
    after_bal  = {available:(db.one "select available from balances where account_id=$1" [account_id]).available}
    audit_mod.write_audit actor "withdrawal" "account:${account_id}" before_bal after_bal
    result <- {transaction:txn entry:entry idempotent:false}
  result

# Get full account info.
exp fn get_account account_id
  db.one "select * from accounts where id=$1" [account_id]!

# HTTP routes for accounts
http.on :post "/accounts" \req ->
  if !req.body.owner
    ret rep 400 {error:"owner required"}
  if !req.body.currency
    ret rep 400 {error:"currency required"}
  acct_type = req.body.type ?? :checking
  acct = create_account req.body.owner req.body.currency acct_type
  rep 201 acct

http.on :get "/accounts/:id" \req ->
  acct = db.one "select * from accounts where id=$1" [req.params.id]
  if acct == nil
    ret rep 404 {error:"account not found"}
  rep 200 acct

http.on :post "/accounts/:id/deposit" \req ->
  if !req.body.amount
    ret rep 400 {error:"amount required (integer cents)"}
  if !req.body.idempotency_key
    ret rep 400 {error:"idempotency_key required"}
  actor = req.headers.x_actor ?? "system"
  result = deposit req.params.id req.body.amount actor req.body.idempotency_key
  rep 200 result

http.on :post "/accounts/:id/withdraw" \req ->
  if !req.body.amount
    ret rep 400 {error:"amount required (integer cents)"}
  if !req.body.idempotency_key
    ret rep 400 {error:"idempotency_key required"}
  actor = req.headers.x_actor ?? "system"
  result = withdraw req.params.id req.body.amount actor req.body.idempotency_key
  rep 200 result
