# Test-only HTTP client for driving gateways and mock upstreams. It is deliberately separate from
# the gateway's own `GatewayKit.Finch` so client-side pooling never masks the behaviour under test.
{:ok, _client} = Finch.start_link(name: GatewayKit.TestClient)

ExUnit.start()
