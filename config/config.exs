import Config

# Application behaviour is driven entirely by the YAML gateway config (see README). Mix config is
# limited to logging and test-environment switches.
config :logger, level: :info

if config_env() == :test, do: import_config("test.exs")
