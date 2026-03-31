import Config

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:application, :cell, :agent, :swarm]

config :colony_demo,
  event_topic: "colony.agent.events",
  command_topic: "colony.agent.commands"

config :colony_cell,
  cell_supervisor_name: ColonyCell.DynamicSupervisor,
  registry_name: ColonyCell.Registry

config :colony_kafka,
  adapter: ColonyKafka.Adapters.Brod,
  brokers: [
    {"3.250.29.185", 19092}
  ]
