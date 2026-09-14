defmodule GatewayKit.Config.ErrorTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.Error

  describe "GatewayKit.Config.Error.format_report/2" do
    test "aligns messages in a column after the longest path" do
      errors = [
        Error.new("routes[1].rate_limit.window", ~s(expected a duration like "60s", got: 60)),
        Error.new("gateway.port", ~s(expected an integer 1..65535, got: "8080"))
      ]

      assert Error.format_report("examples/invalid.yaml", errors) == """
             Invalid gateway config (examples/invalid.yaml):
               routes[1].rate_limit.window   expected a duration like "60s", got: 60
               gateway.port                  expected an integer 1..65535, got: "8080"\
             """
    end

    test "renders a top-level error with an empty path" do
      assert Error.format_report("x.yaml", [Error.new("", "expected a map")]) ==
               "Invalid gateway config (x.yaml):\n     expected a map"
    end
  end
end
