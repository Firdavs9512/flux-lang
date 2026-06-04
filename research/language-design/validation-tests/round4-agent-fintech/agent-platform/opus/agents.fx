# agents.fx — agent lifecycle + per-agent tool registration.
# Isolation is by agent_id: every query is scoped to one agent, so two
# agents on the same platform never see each other's tools/memory.

use db
use ./tools as builtins

# Create an agent and seed it with the built-in tool catalog.
exp fn create owner name system_prompt model
  agent = db.ins "agents" {
    owner:owner
    name:name
    system_prompt:system_prompt
    model:(model ?? "default")
    status::active
  }
  # Seed built-in tools for this agent so it can act out of the box.
  each t in builtins.builtin_catalog
    db.ins "tools" {
      agent:agent.id
      name:t.name
      description:t.description
      params_schema:t.params_schema
      handler_kind:t.handler_kind
      destructive:t.destructive
    }
  ret agent

# Fetch one agent (owner-scoped for isolation).
exp fn get owner agent_id
  ret db.one "select * from agents where id=$1 and owner=$2" [agent_id owner]

# Update mutable config: prompt, model, status.
exp fn configure owner agent_id patch
  a = get owner agent_id
  if !a
    fail "agent not found"
  db.up "agents" patch {id:agent_id}
  ret (get owner agent_id)

# List an owner's agents.
exp fn list owner
  ret db.q "select * from agents where owner=$1 order by created desc" [owner]

# Register a custom tool against an agent.
exp fn register_tool owner agent_id spec
  a = get owner agent_id
  if !a
    fail "agent not found"
  ret db.ins "tools" {
    agent:agent_id
    name:spec.name
    description:spec.description
    params_schema:(spec.params_schema ?? {})
    handler_kind:(spec.handler_kind ?? :http)
    destructive:(spec.destructive ?? false)
  }

# All tools available to an agent (built-in + custom).
exp fn tools_for agent_id
  ret db.q "select * from tools where agent=$1 order by id" [agent_id]

# Look up one tool of an agent by its string name. Central to dispatch:
# the LLM gives us a name, we resolve it to a tool ROW here.
exp fn tool_by_name agent_id name
  ret db.one "select * from tools where agent=$1 and name=$2" [agent_id name]
