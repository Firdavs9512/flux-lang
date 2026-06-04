# Account management: creation, balance queries, suspension/closure
use db json

exp fn create_account owner currency account_type
  # Validate inputs
  if !owner
    fail "owner required"
  if !currency
    fail "currency required"
  if !account_type
    fail "account_type required"

  # Create account in transaction
  acc <- nil
  db.tx \->
    acc = db.ins "accounts"
      owner:owner
      currency:currency
      type:account_type
      status::active
      balance_cents:0
      created:time.now
      updated:time.now

    # Audit: account creation
    db.ins "audit_log"
      actor:owner
      action:"create_account"
      entity:"accounts"
      entity_id:acc.id
      before_json:nil
      after_json:(json.enc acc)
      created:time.now

  acc

exp fn get_account id
  # Get account with balance recomputed from ledger
  acc = db.one "select * from accounts where id=$1" [id]
  if !acc
    ret nil

  # Recompute balance: sum of debits - sum of credits
  ledger_sum = db.one
    "select coalesce(sum(case when direction='credit' then amount_cents else -amount_cents end), 0) as balance from ledger_entries where account_id=$1"
    [id]

  # Return account with fresh balance
  acc.balance_cents = ledger_sum.balance
  acc

exp fn get_balance account_id
  # Just the balance, freshly computed from ledger
  result = db.one
    "select coalesce(sum(case when direction='credit' then amount_cents else -amount_cents end), 0) as balance from ledger_entries where account_id=$1"
    [account_id]

  if result
    ret result.balance
  ret 0

exp fn update_account_status id new_status
  # Update account status (suspend/close)
  if !id
    fail "id required"
  if !new_status
    fail "status required"

  # Validate status
  match new_status
    :active -> nil
    :suspended -> nil
    :closed -> nil
    _ -> fail "invalid status"

  updated_acc <- nil
  db.tx \->
    old_acc = db.one "select * from accounts where id=$1" [id]
    if !old_acc
      fail "account not found"

    db.up "accounts" {status:new_status updated:time.now} {id:id}
    updated_acc = db.one "select * from accounts where id=$1" [id]

    # Audit
    db.ins "audit_log"
      actor:0
      action:"update_account_status"
      entity:"accounts"
      entity_id:id
      before_json:(json.enc old_acc)
      after_json:(json.enc updated_acc)
      created:time.now

  updated_acc

exp fn list_accounts owner_id
  # Get all accounts for an owner
  db.q "select * from accounts where owner=$1 order by created desc" [owner_id]

exp fn check_sufficient_balance account_id amount_cents
  # Verify account has at least amount_cents available
  # Returns true/false
  balance = get_balance account_id
  balance >= amount_cents

exp fn deposit account_id amount_cents
  # Deposit money into account
  if !account_id
    fail "account_id required"
  if amount_cents <= 0
    fail "amount must be positive"

  txn <- nil
  db.tx \->
    # Verify account exists and is active
    acc = db.one "select * from accounts where id=$1" [account_id]
    if !acc
      fail "account not found"
    if acc.status != :active
      fail "account not active"

    # Create transaction
    txn = db.ins "transactions"
      kind::deposit
      status::completed
      idempotency_key:("deposit_${account_id}_${time.now}")
      created:time.now
      updated:time.now

    # Create credit ledger entry
    db.ins "ledger_entries"
      transaction_id:txn.id
      account_id:account_id
      direction::credit
      amount_cents:amount_cents
      created:time.now

    # Audit
    db.ins "audit_log"
      actor:0
      action:"deposit"
      entity:"transactions"
      entity_id:txn.id
      before_json:nil
      after_json:(json.enc txn)
      created:time.now

  txn

exp fn withdraw account_id amount_cents
  # Withdraw money from account
  if !account_id
    fail "account_id required"
  if amount_cents <= 0
    fail "amount must be positive"

  txn <- nil
  db.tx \->
    # Verify account exists and is active
    acc = db.one "select * from accounts where id=$1" [account_id]
    if !acc
      fail "account not found"
    if acc.status != :active
      fail "account not active"

    # Check balance
    balance = get_balance account_id
    if balance < amount_cents
      fail "insufficient balance"

    # Create transaction
    txn = db.ins "transactions"
      kind::withdrawal
      status::completed
      idempotency_key:("withdraw_${account_id}_${time.now}")
      created:time.now
      updated:time.now

    # Create debit ledger entry
    db.ins "ledger_entries"
      transaction_id:txn.id
      account_id:account_id
      direction::debit
      amount_cents:amount_cents
      created:time.now

    # Audit
    db.ins "audit_log"
      actor:0
      action:"withdraw"
      entity:"transactions"
      entity_id:txn.id
      before_json:nil
      after_json:(json.enc txn)
      created:time.now

  txn
