defmodule GatewayKit.PipelineLoggingTest do
  # Not async: the assertion needs the global Logger level lowered to :info.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GatewayKit.Config.{HealthCheck, Route, Target, Upstream}
  alias GatewayKit.Pipeline

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  describe "GatewayKit.Pipeline.compile/1" do
    test "logs configured-but-unimplemented features once at info" do
      target = %Target{url: "http://localhost:1", uri: URI.parse("http://localhost:1"), weight: 1}

      route = %Route{
        id: 1,
        path: "/x",
        segments: ["x"],
        methods: ["GET"],
        upstream: %Upstream{targets: [target], timeout_ms: 1_000, ring: {target}},
        health_check: %HealthCheck{path: "/healthz"}
      }

      log = capture_log(fn -> Pipeline.compile(route) end)

      assert log =~ "Route /x: active health checks is configured but not implemented yet; ignoring"
    end
  end
end
