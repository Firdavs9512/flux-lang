# Fintech Backend - Database Schema
# Double-entry accounting: every debit has a credit. Amounts in integer cents.

# Accounts: entities that can hold money
tbl accounts
  id           serial pk
  owner        int ref:users.id
  currency     str              # ISO 4217 (USD, EUR, etc)
  type         sym              # :checking, :savings, :merchant, :holding
  status       sym              # :active, :suspended, :closed
  balance_cents int              # cached balance in minor units (cents)
  created      now
  updated      now

# Ledger entries: immutable money movements, double-entry principle
tbl ledger_entries
  id           serial pk
  transaction_id int ref:transactions.id
  account_id   int ref:accounts.id
  direction    sym              # :debit or :credit (money out/in)
  amount_cents int              # amount in minor units (NEVER float)
  created      now

# Transactions: high-level money movements
tbl transactions
  id           serial pk
  kind         sym              # :transfer, :deposit, :withdrawal, :fee, :reversal
  status       sym              # :pending, :completed, :failed, :rolled_back
  idempotency_key str uniq      # unique constraint for idempotency
  created      now
  updated      now

# Transfers: account-to-account movements
tbl transfers
  id           serial pk
  from_account_id int ref:accounts.id
  to_account_id   int ref:accounts.id
  amount_cents    int              # always positive, direction encoded in ledger
  currency        str              # must match both accounts
  status          sym              # :pending, :completed, :failed
  idempotency_key str uniq
  created         now
  updated         now

# Payment methods: cards, bank accounts, etc
tbl payment_methods
  id           serial pk
  owner        int ref:users.id
  kind         sym              # :card, :ach, :wire
  last4        str              # last 4 digits for display
  status       sym              # :active, :expired, :revoked
  created      now

# Audit log: immutable record of all state changes for compliance
tbl audit_log
  id           serial pk
  actor        int              # user/system id that made change
  action       str              # "create_account", "transfer_initiated", etc
  entity       str              # "accounts", "transfers", etc
  entity_id    int              # id of affected entity
  before_json  json             # state before change
  after_json   json             # state after change
  created      now

# Placeholder for users (foreign key references)
# In real system this would be defined elsewhere
tbl users
  id    serial pk
  email str uniq
  name  str
  created now

# Daily reconciliation state: track when we've verified ledger sums
tbl reconciliation_log
  id              serial pk
  reconciliation_date str
  accounts_checked int
  discrepancies    int
  details_json    json
  status          sym              # :success, :failed
  created         now
