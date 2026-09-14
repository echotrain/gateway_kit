import Config

config :logger, level: :warning

# Tests boot their own gateway instances on ephemeral ports (see `GatewayKit.GatewayCase`), so the
# application must not read `./gateway.yaml` or bind port 8080 when the test suite starts.
config :gateway_kit, serve: false
