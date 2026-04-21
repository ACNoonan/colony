import Config

# Runtime configuration — evaluated at application start, so env vars
# reflect the shell that launched the BEAM (plus anything we load
# below). .env is auto-loaded if present; explicit shell env vars win.

env_file = Path.expand("../.env", __DIR__)

if File.exists?(env_file) do
  env_file
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.each(fn line ->
    line = String.trim(line)

    cond do
      line == "" ->
        :skip

      String.starts_with?(line, "#") ->
        :skip

      true ->
        case String.split(line, "=", parts: 2) do
          [key, val] ->
            key = String.trim(key)
            val = val |> String.trim() |> String.trim("\"") |> String.trim("'")
            if System.get_env(key) == nil, do: System.put_env(key, val)

          _ ->
            :skip
        end
    end
  end)
end

config :colony_core, :llm_anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  model: System.get_env("COLONY_ANTHROPIC_MODEL", "claude-opus-4-7")

config :colony_core, :llm_openai,
  api_key: System.get_env("OPENAI_API_KEY"),
  model: System.get_env("COLONY_OPENAI_MODEL", "gpt-4o")

llm_adapter =
  case System.get_env("COLONY_LLM_ADAPTER") do
    "anthropic" -> ColonyCore.LLM.Anthropic
    "fixture" -> ColonyCore.LLM.Fixture
    _ -> ColonyCore.LLM.OpenAI
  end

config :colony_core, llm_adapter: llm_adapter

if System.get_env("COLONY_DISABLE_KAFKA") == "1" do
  config :colony_kafka, adapter: ColonyKafka.Adapters.Unconfigured
end
