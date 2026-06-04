# cron_jobs.fx — scheduled background tasks
# Hourly: log per-agent usage (conversations, tool calls, total cost).

use db cron

# ── Hourly usage report ───────────────────────────────────────────────────────
fn hourly_usage_report
  log "=== Hourly agent usage report ==="

  agents = db.q "select id, name, status from agents order by id"

  each agent in agents
    # Count conversations in the last hour
    conv_count_row = db.one "
      select count(*) c
      from conversations
      where agent_id=$1 and created > $2
    " [agent.id (time.ago 1 :hr)]

    conv_count = conv_count_row.c ?? 0

    # Count tool invocations linked to this agent's conversations in last hour
    inv_count_row = db.one "
      select count(*) c
      from tool_invocations ti
      join messages m on m.id = ti.message_id
      join conversations cv on cv.id = m.conversation_id
      where cv.agent_id=$1 and ti.id > 0 and cv.created > $2
    " [agent.id (time.ago 1 :hr)]

    inv_count = inv_count_row.c ?? 0

    # Sum up cost for this agent's conversations
    cost_row = db.one "
      select coalesce(sum(cc.tokens),0) total_tokens,
             coalesce(sum(cc.cost),0.0) total_cost
      from conversation_cost cc
      join conversations cv on cv.id = cc.conversation_id
      where cv.agent_id=$1
    " [agent.id]

    total_tokens = cost_row.total_tokens ?? 0
    total_cost   = cost_row.total_cost   ?? 0.0

    log "agent=${agent.id} name=${agent.name} status=${agent.status} conversations_1h=${conv_count} tool_calls_1h=${inv_count} total_tokens=${total_tokens} total_cost=${total_cost}"

  log "=== End hourly report ==="

# ── Register the cron job: run at the top of every hour (minute 0) ────────────
cron.hr 0 hourly_usage_report
