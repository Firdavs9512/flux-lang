# Conversation management
use db json

# Start a new conversation
exp fn create_conversation agent_id user_id
  conv = db.ins "conversations" {
    agent_id: agent_id
    user_id: user_id
    created: time.now
    updated: time.now
  }
  ret conv

# Get a conversation by ID
exp fn get_conversation conv_id
  ret db.one "select * from conversations where id=$1" [conv_id]

# List conversations for an agent
exp fn list_conversations agent_id
  ret db.q "select * from conversations where agent_id=$1 order by updated desc" [agent_id]

# Get conversation history (all messages in order)
exp fn get_history conv_id
  rows = db.q "select id, role, content, tool_calls, tool_results, cost, tokens_in, tokens_out, created from messages where conversation_id=$1 order by created asc" [conv_id]

  # Parse JSON fields
  messages <- []
  each m in rows
    msg_obj = {
      id: m.id
      role: m.role
      content: m.content
      tool_calls: if m.tool_calls
        json.dec m.tool_calls
      else
        nil
      tool_results: if m.tool_results
        json.dec m.tool_results
      else
        nil
      cost: m.cost
      tokens_in: m.tokens_in
      tokens_out: m.tokens_out
      created: m.created
    }
    messages <- messages.push msg_obj

  ret messages

# Add a message to conversation (for storing results of the agentic loop)
exp fn add_message conv_id role content tool_calls tool_results cost tokens_in tokens_out ms
  msg = db.ins "messages" {
    conversation_id: conv_id
    role: role
    content: content
    tool_calls: if tool_calls nil
      json.enc tool_calls
    else
      nil
    tool_results: if tool_results nil
      json.enc tool_results
    else
      nil
    cost: cost
    tokens_in: tokens_in
    tokens_out: tokens_out
    ms: ms
  }

  # Update conversation updated_at
  db.up "conversations" {updated:time.now} {id:conv_id}

  ret msg

# Log a tool invocation (for audit trail and performance tracking)
exp fn log_tool_invocation message_id tool_name input_json output_json error_msg ms ok
  ret db.ins "tool_invocations" {
    message_id: message_id
    tool_name: tool_name
    input_json: json.enc input_json
    output_json: if output_json nil
      json.enc output_json
    else
      nil
    error_msg: error_msg
    ms: ms
    ok: ok
  }
