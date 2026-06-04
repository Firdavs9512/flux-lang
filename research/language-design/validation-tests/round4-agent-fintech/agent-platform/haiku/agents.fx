# Agent lifecycle and configuration
use db json

# Create a new agent
exp fn create_agent owner name system_prompt model
  agent = db.ins "agents" {
    owner: owner
    name: name
    system_prompt: system_prompt
    model: model
    status: :active
  }
  ret agent

# Get an agent by ID
exp fn get_agent agent_id
  ret db.one "select * from agents where id=$1" [agent_id]

# List agents owned by a user
exp fn list_agents owner
  ret db.q "select * from agents where owner=$1 order by created desc" [owner]

# Update agent configuration
exp fn update_agent agent_id updates
  db.up "agents" updates {id:agent_id}
  ret get_agent agent_id

# Register a tool for an agent
exp fn register_tool agent_id name description params_schema handler_kind webhook_url
  tool = db.ins "tools" {
    agent_id: agent_id
    name: name
    description: description
    params_schema: json.enc params_schema
    handler_kind: handler_kind
    webhook_url: webhook_url
  }
  ret tool

# Get all tools for an agent
exp fn get_agent_tools agent_id
  rows = db.q "select id, name, description, params_schema, handler_kind, webhook_url from tools where agent_id=$1" [agent_id]

  # Parse params_schema from JSON strings
  tools <- []
  each t in rows
    parsed_schema = json.dec t.params_schema
    tool_obj = {
      id: t.id
      name: t.name
      description: t.description
      params_schema: parsed_schema
      handler_kind: t.handler_kind
      webhook_url: t.webhook_url
    }
    tools <- tools.push tool_obj

  ret tools

# Delete a tool
exp fn delete_tool tool_id
  db.del "tools" {id:tool_id}
  ret nil

# Get a specific tool by ID (for dispatch)
exp fn get_tool tool_id
  row = db.one "select * from tools where id=$1" [tool_id]
  if !row
    ret nil
  ret {
    id: row.id
    name: row.name
    description: row.description
    params_schema: json.dec row.params_schema
    handler_kind: row.handler_kind
    webhook_url: row.webhook_url
  }
