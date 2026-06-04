# idempotency.fx — make money-moving endpoints safe to retry.
#
# Contract: every money-moving endpoint takes an idempotency_key. If we have
# already processed that key, we return the ORIGINAL cached response and do NOT
# perform the operation again (no double-charge).
#
# Strategy:
#   1. `lookup` — has this key already been recorded? If yes, return cached resp.
#   2. The caller performs the work inside a db.tx that ALSO inserts the
#      idempotency_keys row (uniq on `ikey`). Because the insert of the unique
#      key and the money movement share ONE transaction, either both commit or
#      both roll back. If a concurrent request already committed the same key,
#      the unique-constraint violation makes our insert `fail`, which rolls back
#      our whole tx — so we never double-apply. The loser then re-reads the
#      cached response via `lookup`.
#
# See "Spec gaps" — the spec gives `uniq` columns and db.tx rollback-on-fail,
# but does NOT specify how a unique-violation surfaces (catchable error vs.
# propagated `!`). We treat any failure of `reserve` as "key already taken".

use db json

# Return the cached {status, body} for a key, or nil if unseen.
exp fn lookup ikey scope
  row = db.one "select * from idempotency_keys where ikey=$1 and scope=$2" [ikey scope]
  if !row
    ret nil
  ret {status: row.status body: (json.dec row.response)}

# Insert the idempotency record. MUST be called inside the caller's db.tx,
# as the LAST step, after the money movement, so that a uniq violation rolls
# the entire operation back. `response` is the body map we are about to return.
exp fn record ikey scope status response
  db.ins "idempotency_keys" {
    ikey: ikey
    scope: scope
    status: status
    response: (json.enc response)
  }

# Guard helper for handlers: returns the cached response if present so the
# handler can early-`ret` it. nil => proceed with the operation.
exp fn cached ikey scope
  hit = lookup ikey scope
  if !hit
    ret nil
  ret rep hit.status hit.body
