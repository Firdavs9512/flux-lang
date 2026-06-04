# Fintech Backend - HTTP API
# Comprehensive payments & ledger backend with idempotency, audit, fraud checks
use http db json
use ./schema          # just for reference; schema defined at startup
use ./accounts
use ./transfers
use ./fraud
use ./ai_features
use ./reconciliation
use ./cron_jobs as cron_module
use ./idempotency

# ===== Account Management =====

http.on :post "/accounts" \req ->
  # Create new account
  # Body: {owner: int, currency: str, type: symbol}

  if !req.body.owner
    ret rep 400 {error:"owner required"}
  if !req.body.currency
    ret rep 400 {error:"currency required"}
  if !req.body.type
    ret rep 400 {error:"type required"}

  type_str = str.str req.body.type
  type_sym = match type_str
    "checking" -> :checking
    "savings" -> :savings
    "merchant" -> :merchant
    "holding" -> :holding
    _ -> (fail "invalid type")

  acc = accounts.create_account req.body.owner req.body.currency type_sym
  rep 201 acc

http.on :get "/accounts/:id" \req ->
  # Get account with fresh balance
  account_id = str.int req.params.id
  if !account_id
    ret rep 400 {error:"invalid id"}

  acc = accounts.get_account account_id
  if !acc
    ret rep 404 {error:"account not found"}

  rep 200 acc

http.on :get "/accounts/:id/balance" \req ->
  # Get balance (computed from ledger)
  account_id = str.int req.params.id
  if !account_id
    ret rep 400 {error:"invalid id"}

  # Verify account exists
  acc = accounts.get_account account_id
  if !acc
    ret rep 404 {error:"account not found"}

  balance = accounts.get_balance account_id
  rep 200 {account_id:account_id balance_cents:balance}

http.on :get "/accounts/owner/:owner_id" \req ->
  # List all accounts for an owner
  owner_id = str.int req.params.owner_id
  if !owner_id
    ret rep 400 {error:"invalid owner_id"}

  accounts_list = accounts.list_accounts owner_id
  rep 200 accounts_list

http.on :patch "/accounts/:id/status" \req ->
  # Update account status (suspend/close)
  account_id = str.int req.params.id
  if !account_id
    ret rep 400 {error:"invalid id"}
  if !req.body.status
    ret rep 400 {error:"status required"}

  status_str = str.str req.body.status
  status_sym = match status_str
    "active" -> :active
    "suspended" -> :suspended
    "closed" -> :closed
    _ -> (fail "invalid status")

  updated = accounts.update_account_status account_id status_sym
  rep 200 updated

# ===== Money Operations =====

http.on :post "/accounts/:id/deposit" \req ->
  # Deposit money (increase balance)
  account_id = str.int req.params.id
  if !account_id
    ret rep 400 {error:"invalid id"}
  if !req.body.amount_cents
    ret rep 400 {error:"amount_cents required"}

  amount = str.int (str.str req.body.amount_cents)
  if amount <= 0
    ret rep 400 {error:"amount must be positive"}

  txn = accounts.deposit account_id amount
  rep 201 {transaction:txn}

http.on :post "/accounts/:id/withdraw" \req ->
  # Withdraw money (decrease balance)
  account_id = str.int req.params.id
  if !account_id
    ret rep 400 {error:"invalid id"}
  if !req.body.amount_cents
    ret rep 400 {error:"amount_cents required"}

  amount = str.int (str.str req.body.amount_cents)
  if amount <= 0
    ret rep 400 {error:"amount must be positive"}

  txn = accounts.withdraw account_id amount
  rep 201 {transaction:txn}

# ===== Transfers =====

http.on :post "/transfers" \req ->
  # Transfer between accounts
  # Body: {from_account_id, to_account_id, amount_cents, currency, idempotency_key}
  # IDEMPOTENT: same key = same result, no double-charge

  if !req.body.from_account_id
    ret rep 400 {error:"from_account_id required"}
  if !req.body.to_account_id
    ret rep 400 {error:"to_account_id required"}
  if !req.body.amount_cents
    ret rep 400 {error:"amount_cents required"}
  if !req.body.currency
    ret rep 400 {error:"currency required"}
  if !req.body.idempotency_key
    ret rep 400 {error:"idempotency_key required"}

  from_id = str.int (str.str req.body.from_account_id)
  to_id = str.int (str.str req.body.to_account_id)
  amount = str.int (str.str req.body.amount_cents)
  currency = str.str req.body.currency
  idempotency_key = str.str req.body.idempotency_key

  if from_id == to_id
    ret rep 400 {error:"cannot transfer to same account"}

  result = transfers.transfer from_id to_id amount currency idempotency_key

  if result.status == :already_processed
    # Return 200 (idempotent already succeeded) with original result
    rep 200 result
  else
    rep 201 result

http.on :get "/transfers/:id" \req ->
  # Get transfer details
  transfer_id = str.int req.params.id
  if !transfer_id
    ret rep 400 {error:"invalid id"}

  xfer = transfers.get_transfer transfer_id
  if !xfer
    ret rep 404 {error:"transfer not found"}

  rep 200 xfer

http.on :get "/accounts/:account_id/transfers" \req ->
  # List transfers for account (as source or dest)
  account_id = str.int req.params.account_id
  if !account_id
    ret rep 400 {error:"invalid account_id"}

  xfers = transfers.list_transfers account_id
  rep 200 xfers

http.on :post "/transfers/:id/reverse" \req ->
  # Reverse a transfer: undo it with inverse transaction
  transfer_id = str.int req.params.id
  if !transfer_id
    ret rep 400 {error:"invalid id"}

  reversal = transfers.reverse_transfer transfer_id
  rep 201 {reversal:reversal}

# ===== Fraud & Risk =====

http.on :post "/transfers/check-fraud" \req ->
  # Check if a proposed transfer would be fraud-flagged
  # Body: {from_account_id, to_account_id, amount_cents, currency}
  # (Does NOT execute transfer, just evaluates rules)

  if !req.body.from_account_id
    ret rep 400 {error:"from_account_id required"}
  if !req.body.to_account_id
    ret rep 400 {error:"to_account_id required"}
  if !req.body.amount_cents
    ret rep 400 {error:"amount_cents required"}
  if !req.body.currency
    ret rep 400 {error:"currency required"}

  from_id = str.int (str.str req.body.from_account_id)
  to_id = str.int (str.str req.body.to_account_id)
  amount = str.int (str.str req.body.amount_cents)
  currency = str.str req.body.currency

  result = fraud.check_transfer from_id to_id amount currency

  rep 200 result

# ===== AI Features =====

http.on :post "/transactions/:id/explain" \req ->
  # AI explanation of a transaction: what happened and why?
  transaction_id = str.int req.params.id
  if !transaction_id
    ret rep 400 {error:"invalid id"}

  explanation = ai_features.explain_transaction transaction_id
  rep 200 explanation

http.on :post "/transactions/:id/fraud-score" \req ->
  # AI structured fraud scoring
  transaction_id = str.int req.params.id
  if !transaction_id
    ret rep 400 {error:"invalid id"}

  score = ai_features.score_transaction_for_fraud transaction_id
  rep 200 score

# ===== Reconciliation =====

http.on :post "/admin/reconcile" \req ->
  # Run reconciliation manually
  # Verify all account balances = ledger sums
  result = reconciliation.reconcile_all
  rep 200 result

http.on :get "/admin/reconciliation-log" \req ->
  # Get recent reconciliation results
  since_days = req.query.since_days ?? "7"
  since = str.int since_days

  discrepancies = reconciliation.get_discrepancies since
  rep 200 {discrepancies:discrepancies}

http.on :post "/admin/fix-balance/:id" \req ->
  # Emergency: fix a balance discrepancy
  account_id = str.int req.params.id
  if !account_id
    ret rep 400 {error:"invalid id"}

  fixed = reconciliation.fix_balance account_id
  rep 200 fixed

# ===== Health & Startup =====

http.on :get "/health" \req ->
  rep 200 {status::ok message:"fintech backend running"}

http.on :post "/admin/init-schema" \req ->
  # Initialize database schema (called once at startup)
  # In real world: migrations
  log "Initializing schema..."
  idempotency.create_schema
  cron_module.setup_cron_jobs
  rep 200 {status::ok message:"schema initialized and cron jobs scheduled"}

# ===== Server Start =====

log "Starting fintech backend..."
http.serve 8080
log "Server listening on :8080"
