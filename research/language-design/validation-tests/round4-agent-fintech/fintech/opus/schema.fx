# schema.fx — double-entry ledger schema
# All money is stored as integer minor units (cents). NEVER floats.
# `int` is used for every amount column. See "Spec gaps" re: int width/overflow.

use db

# accounts — one row per ledger account
tbl accounts
  id       serial pk
  owner    str                  # owner identifier (user/customer id, opaque string)
  currency str                  # ISO-4217 code, e.g. "USD". Money math only valid within one currency.
  type     sym                  # :asset :liability :user (account classification)
  status   sym                  # :active :frozen :closed
  created  now

# transactions — the unit of a money movement (groups balanced ledger entries)
tbl transactions
  id              serial pk
  kind            sym           # :deposit :withdraw :transfer
  status          sym           # :pending :posted :failed
  idempotency_key str uniq      # unique → DB rejects duplicates (see idempotency.fx)
  created         now

# ledger_entries — the immutable double-entry lines.
# For each transaction the SUM of debits must equal the SUM of credits.
tbl ledger_entries
  id       serial pk
  txn      int ref:transactions.id
  account  int ref:accounts.id
  dir      sym                  # :debit or :credit
  amount   int                  # minor units, always > 0; sign carried by `dir`
  currency str
  created  now

# transfers — a user-facing transfer request (1 transfer → 1 transaction)
tbl transfers
  id              serial pk
  from_account    int ref:accounts.id
  to_account      int ref:accounts.id
  amount          int
  currency        str
  status          sym           # :pending :posted :failed :rejected
  txn             int ref:transactions.id null
  idempotency_key str uniq
  created         now

# payment_methods
tbl payment_methods
  id      serial pk
  owner   str
  kind    sym                   # :card :bank :wallet
  last4   str
  status  sym                   # :active :removed
  created now

# audit_log — every state change records before/after as JSON
tbl audit_log
  id      serial pk
  actor   str
  action  str
  entity  str
  before  json
  after   json
  created now

# idempotency_keys — stores the cached response for each money-moving key.
# A row here is the source of truth for "have we seen this key before".
tbl idempotency_keys
  id        serial pk
  ikey      str uniq
  scope     str                 # endpoint name, e.g. "transfer" / "deposit"
  response  json                # the original response body we returned
  status    int                 # the original HTTP status we returned
  created   now
