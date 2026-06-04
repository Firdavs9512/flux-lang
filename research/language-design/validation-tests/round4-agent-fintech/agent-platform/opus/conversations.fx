# conversations.fx — conversation lifecycle + history reads.

use db
use ./agents as agents

# Start a new conversation for an agent + user.
exp fn start owner agent_id user_id
  a = agents.get owner agent_id
  if !a
    fail "agent not found"
  ret db.ins "conversations" {
    agent:agent_id
    user_id:user_id
    total_tokens:0
    total_cost:0.0
  }

# Fetch a conversation with its running cost totals.
exp fn get conv_id
  ret db.one "select * from conversations where id=$1" [conv_id]

# Full message history of a conversation, oldest first.
exp fn history conv_id
  ret db.q "select * from messages where conversation=$1 order by id" [conv_id]

# All tool invocations in a conversation (joined via messages), for
# auditing/observability.
exp fn invocations conv_id
  ret db.q "select ti.* from tool_invocations ti
            join messages m on m.id = ti.message
            where m.conversation=$1 order by ti.id" [conv_id]

# Pending confirmations for a conversation (the UI polls these).
exp fn pending_confirmations conv_id
  ret db.q "select * from confirmations where conversation=$1 and status=$2 order by id" [conv_id :pending]
