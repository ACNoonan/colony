import Config

# Runtime configuration — evaluated at application start, so env vars
# reflect the shell that launched the BEAM (or whatever `source .env`
# step the operator ran first).

config :colony_core, :llm_anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: System.get_env("COLONY_ANTHROPIC_MODEL", "claude-opus-4-7")

config :colony_core, :llm_openai,
  api_key: System.get_env("OPENAI_API_KEY"),
  model: System.get_env("COLONY_OPENAI_MODEL", "gpt-4o")

llm_adapter =
  case System.get_env("COLONY_LLM_ADAPTER") do
    "openai" -> ColonyCore.LLM.OpenAI
    "fixture" -> ColonyCore.LLM.Fixture
    _ -> ColonyCore.LLM.Anthropic
  end

config :colony_core, llm_adapter: llm_adapter

if System.get_env("COLONY_DISABLE_KAFKA") == "1" do
  config :colony_kafka, adapter: ColonyKafka.Adapters.Unconfigured
end
