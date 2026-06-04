# Schema definitions for the AI agent platform

tbl agents
  id       serial pk
  owner    str                          # user_id or org_id
  name     str
  system_prompt str
  model    str                          # e.g. "claude-3-haiku"
  status   sym                          # :active :paused :archived
  created  now
  updated  now

tbl tools
  id          serial pk
  agent_id    int ref:agents.id
  name        str                       # e.g. "web_search", "calculator"
  description str
  params_schema json                    # JSON schema for params
  handler_kind sym                      # :builtin :webhook :lambda
  webhook_url str null                  # for :webhook kind
  created     now

tbl conversations
  id         serial pk
  agent_id   int ref:agents.id
  user_id    str
  title      str null
  created    now
  updated    now

tbl messages
  id              serial pk
  conversation_id int ref:conversations.id
  role            sym                   # :user :assistant :system
  content         str
  tool_calls      json null             # [{name tool_name input json}]
  tool_results    json null             # [{tool_name output error}]
  cost            flt null              # AI cost for this message
  tokens_in       int null
  tokens_out      int null
  ms              int null              # latency
  created         now

tbl tool_invocations
  id              serial pk
  message_id      int ref:messages.id
  tool_name       str
  input_json      json
  output_json     json null
  error_msg       str null
  ms              int                   # execution time
  ok              bool                  # success flag
  created         now

tbl agent_memory
  id         serial pk
  agent_id   int ref:agents.id
  key        str
  value_json json
  updated    now

tbl agent_usage
  id           serial pk
  agent_id     int ref:agents.id
  date         str                      # YYYY-MM-DD for daily rollup
  conversations int
  messages     int
  tool_calls   int
  total_cost   flt
  total_tokens int
  created      now
