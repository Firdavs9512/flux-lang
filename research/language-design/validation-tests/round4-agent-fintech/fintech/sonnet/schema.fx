# schema.fx — double-entry ledger database schema
use db

# Core accounts table
tbl accounts
  id          serial pk
  owner       str
  currency    str
  type        sym
  status      sym
  created     now

# Transactions: the top-level money-movement record
tbl transactions
  id              serial pk
  kind            sym
  status          sym
  idempotency_key str uniq
  created         now

# Ledger entries: every credit and debit as immutable record
# direction: :debit (money leaves account) or :credit (money enters account)
# amount: integer minor units (cents) — NEVER floats
tbl ledger_entries
  id              serial pk
  transaction_id  int ref:transactions.id
  account_id      int ref:accounts.id
  direction       sym
  amount          int
  created         now

# Denormalized balance cache for performance; must always equal ledger sum
tbl balances
  id          serial pk
  account_id  int ref:accounts.id uniq
  available   int
  pending     int
  updated     now

# Transfers: a specific kind of transaction between two accounts
tbl transfers
  id              serial pk
  from_account    int ref:accounts.id
  to_account      int ref:accounts.id
  amount          int
  currency        str
  status          sym
  idempotency_key str uniq
  created         now

# Payment methods attached to an owner
tbl payment_methods
  id      serial pk
  owner   str
  kind    sym
  last4   str
  status  sym
  created now

# Audit log: immutable record of every state change
tbl audit_log
  id        serial pk
  actor     str
  action    str
  entity    str
  before    json
  after     json
  created   now
