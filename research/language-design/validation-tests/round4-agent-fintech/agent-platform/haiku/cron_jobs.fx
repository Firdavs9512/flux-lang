# Cron jobs for background tasks and analytics
use db time

# Daily usage aggregation: summarize agent usage per day
exp fn aggregate_daily_usage
  # Get all unique agents
  agents_list = db.q "select distinct agent_id from messages"

  log "Starting daily usage aggregation"

  each a in agents_list
    agent_id = a.agent_id

    # Get today's date (format YYYY-MM-DD)
    now_ts = time.now
    today = time.fmt now_ts "YYYY-MM-DD"

    # Count conversations started today
    conv_count_row = db.one "select count(*) c from conversations where agent_id=$1 and created::date = $2::date" [agent_id today]
    conv_count = conv_count_row.c ?? 0

    # Count messages sent today
    msg_count_row = db.one "select count(*) c from messages m join conversations c on m.conversation_id=c.id where c.agent_id=$1 and m.created::date = $2::date and m.role=:assistant" [agent_id today]
    msg_count = msg_count_row.c ?? 0

    # Count tool calls today
    tc_count_row = db.one "select count(*) c from tool_invocations ti join messages m on ti.message_id=m.id join conversations c on m.conversation_id=c.id where c.agent_id=$1 and ti.created::date = $2::date" [agent_id today]
    tc_count = tc_count_row.c ?? 0

    # Sum total cost
    cost_row = db.one "select sum(cost) s from messages m join conversations c on m.conversation_id=c.id where c.agent_id=$1 and m.created::date = $2::date" [agent_id today]
    total_cost = cost_row.s ?? 0

    # Sum total tokens
    token_row = db.one "select sum(tokens_in + tokens_out) t from messages m join conversations c on m.conversation_id=c.id where c.agent_id=$1 and m.created::date = $2::date" [agent_id today]
    total_tokens = token_row.t ?? 0

    log "Agent ${agent_id}: ${conv_count} convs, ${msg_count} msgs, ${tc_count} tools, cost ${total_cost}"

    # Check if usage record exists for today
    existing = db.one "select id from agent_usage where agent_id=$1 and date=$2" [agent_id today]

    if existing
      # Update existing record
      db.up "agent_usage" {
        conversations: conv_count
        messages: msg_count
        tool_calls: tc_count
        total_cost: total_cost
        total_tokens: total_tokens
      } {agent_id: agent_id date: today}
    else
      # Insert new record
      db.ins "agent_usage" {
        agent_id: agent_id
        date: today
        conversations: conv_count
        messages: msg_count
        tool_calls: tc_count
        total_cost: total_cost
        total_tokens: total_tokens
      }

  log "Daily usage aggregation complete"
  ret :ok

# Hourly check: log usage snapshot (optional, more granular)
exp fn check_hourly_usage
  log "Hourly usage check"
  ret :ok

# Setup cron jobs
exp fn setup_crons
  # Run daily at 00:00
  cron.dy 0 0 aggregate_daily_usage
  log "Cron jobs set up"
  ret :ok
