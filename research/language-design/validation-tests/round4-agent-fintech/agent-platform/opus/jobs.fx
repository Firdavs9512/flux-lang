# jobs.fx — scheduled background work.
# Hourly: log per-agent usage (conversations, tool calls, total cost)
# over the trailing hour. Registered from main.fx.

use db cron time

# Compute + log usage for every agent for the trailing hour.
exp fn hourly_usage
  since = time.ago 1 :hr
  agents = db.q "select id, name from agents"
  log "=== hourly agent usage @ ${time.now} ==="
  each a in agents
    convs = db.one "select count(*) c from conversations
                    where agent=$1 and created > $2" [a.id since]
    calls = db.one "select count(*) c from tool_invocations ti
                    join messages m on m.id = ti.message
                    join conversations cv on cv.id = m.conversation
                    where cv.agent=$1 and ti.created > $2" [a.id since]
    cost = db.one "select sum(total_cost) s from conversations
                   where agent=$1 and created > $2" [a.id since]
    log "agent ${a.id} (${a.name}): convos=${convs.c ?? 0} tool_calls=${calls.c ?? 0} cost=${cost.s ?? 0.0}"
  ret :ok

# Register the cron schedule. Called once at startup.
exp fn schedule
  cron.hr 0 hourly_usage
