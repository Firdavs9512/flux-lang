# audit.fx — immutable audit log writer
use db json

# Write one audit entry. before/after must be maps (will be JSON-encoded).
# Called inside or outside db.tx; when called inside a tx, it participates
# in the same transaction (rollback safety is inherited from the caller).
exp fn write_audit actor action entity before after
  db.ins "audit_log" {
    actor:actor
    action:action
    entity:entity
    before:(json.enc before)
    after:(json.enc after)
  }
