import Config

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:application, :cell, :agent, :swarm]

config :colony_core,
  swarm_dir: Path.expand("../swarm", __DIR__)

config :colony_demo,
  event_topic: "colony.agent.events",
  command_topic: "colony.agent.commands"

config :colony_cell,
  cell_supervisor_name: ColonyCell.DynamicSupervisor,
  registry_name: ColonyCell.Registry

config :colony_kafka,
  adapter: ColonyKafka.Adapters.Brod,
  brokers: [
    {"localhost", 19092}
  ]

if config_env() == :test do
  config :colony_kafka, adapter: ColonyKafka.Adapters.Unconfigured
  config :colony_core, llm_adapter: ColonyCore.LLM.Fixture
end
