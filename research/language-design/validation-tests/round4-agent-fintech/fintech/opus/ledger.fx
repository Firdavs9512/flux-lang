# ledger.fx — double-entry primitives and balance computation.
#
# Accounting convention used here (asset/user accounts, "normal debit balance"):
#   balance(account) = SUM(debit amounts) - SUM(credit amounts)
#
#   - A DEPOSIT into a user account => debit that account (balance up).
#   - A WITHDRAW from a user account => credit that account (balance down).
#   - A TRANSFER => debit the destination, credit the source. The source goes
#     down, the destination goes up, and debits == credits within the txn.
#
# Every amount is an integer in minor units (cents). No floats anywhere.
#
# INVARIANT (must always hold): for any transaction, sum(debits) == sum(credits).
# And: an account's stored/derived balance == sum of its ledger lines.

use db

# Compute available balance for an account purely from the ledger.
# Returns an integer (cents). Empty ledger => 0.
exp fn balance account_id
  r = db.one "select coalesce(sum(case when dir='debit' then amount else -amount end),0) bal from ledger_entries where account=$1" [account_id]
  ret r.bal ?? 0

# Sum of pending (not-yet-posted) ledger movement for an account.
# Entries belonging to transactions whose status is still :pending.
exp fn pending account_id
  r = db.one "select coalesce(sum(case when dir='debit' then le.amount else -le.amount end),0) bal from ledger_entries le join transactions t on t.id = le.txn where le.account=$1 and t.status='pending'" [account_id]
  ret r.bal ?? 0

# Post a balanced pair of entries inside an already-open db.tx.
# debit_acct gets a :debit line, credit_acct gets a :credit line, same amount.
# Caller MUST have validated currency match and amount > 0 already.
# Returns the two inserted ledger rows as a list.
exp fn post_pair txn_id debit_acct credit_acct amount currency
  if amount <= 0
    fail "ledger: amount must be positive (got ${amount})"
  d = db.ins "ledger_entries" {
    txn: txn_id account: debit_acct dir::debit amount: amount currency: currency
  }
  c = db.ins "ledger_entries" {
    txn: txn_id account: credit_acct dir::credit amount: amount currency: currency
  }
  ret [d c]

# Verify the double-entry invariant for a single transaction:
# sum(debits) == sum(credits). Returns bool.
exp fn txn_balanced txn_id
  r = db.one "select coalesce(sum(case when dir='debit' then amount else 0 end),0) d, coalesce(sum(case when dir='credit' then amount else 0 end),0) c from ledger_entries where txn=$1" [txn_id]
  ret (r.d ?? 0) == (r.c ?? 0)
