defmodule GatewayKit.CLITest do
  use ExUnit.Case, async: true

  alias GatewayKit.CLI

  describe "GatewayKit.CLI.config_path/2" do
    test "accepts the path as a flag, as a positional argument, or not at all" do
      assert CLI.config_path(["--config", "a.yaml"], "gateway") == {:ok, "a.yaml"}
      assert CLI.config_path(["a.yaml"], "gateway") == {:ok, "a.yaml"}
      assert CLI.config_path([], "gateway") == {:ok, nil}
    end

    test "rejects unknown options and more than one path, with usage" do
      assert {:error, message} = CLI.config_path(["--bogus"], "gateway")
      assert message =~ "unknown option --bogus"
      assert message =~ "Usage: mix gateway [--config PATH | PATH]"

      assert {:error, message} = CLI.config_path(["--config", "a.yaml", "b.yaml"], "upstreams")
      assert message =~ ~s(expected one config path, got ["a.yaml", "b.yaml"])
      assert message =~ "mix upstreams"
    end
  end
end
