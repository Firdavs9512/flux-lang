# audit.fx — write before/after audit records for every state change.
# Call this INSIDE the same db.tx as the mutation so the audit row rolls back
# together with the change if the transaction fails.

use db json

# record an audit line. `before` / `after` are maps (or nil) — stored as JSON.
exp fn write actor action entity before after
  db.ins "audit_log" {
    actor: actor
    action: action
    entity: entity
    before: (json.enc (before ?? {}))
    after: (json.enc (after ?? {}))
  }
