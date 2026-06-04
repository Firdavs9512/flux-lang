# Built-in tools available to agents
use http json
use ./memory

# web_search: stub via HTTP to a search API
# In production: call external search service
exp fn tool_web_search query
  # Stub: pretend to search, return mock results
  log "web_search: ${query}"

  # In real system, call: http.get "https://api.search.example.com/search?q=${query}"
  # For now, return structured mock
  ret {
    results: [
      {title:"Result 1" url:"http://example.com/1" snippet:"Mock snippet about ${query}"}
      {title:"Result 2" url:"http://example.com/2" snippet:"Another result for ${query}"}
    ]
  }

# calculator: basic math
exp fn tool_calculator expression
  # Parse and eval simple expressions (stub implementation)
  # Real: use expression evaluator or call external service

  log "calculator: ${expression}"

  # Simulate parsing and evaluation
  # For now, return a stub result
  ret {
    expression: expression
    result: 0
    note: "Calculator is a stub — pass expressions as strings"
  }

# get_memory: agent reads own persistent memory
exp fn tool_get_memory agent_id key
  value = memory.get_memory agent_id key
  ret {
    key: key
    value: value
    found: !(value == nil)
  }

# set_memory: agent writes own persistent memory
exp fn tool_set_memory agent_id key value
  memory.set_memory agent_id key value
  ret {
    key: key
    value: value
    status: :ok
  }

# Helper: dispatch a builtin tool by name with input
# This is critical for the agentic loop
exp fn dispatch_builtin tool_name agent_id input_map
  match tool_name
    "web_search" -> ret tool_web_search input_map.query
    "calculator" -> ret tool_calculator input_map.expression
    "get_memory" -> ret tool_get_memory agent_id input_map.key
    "set_memory" -> ret tool_set_memory agent_id input_map.key input_map.value
    _ -> ret {error:"Unknown builtin tool: ${tool_name}"}
