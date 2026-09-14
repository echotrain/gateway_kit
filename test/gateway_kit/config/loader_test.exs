defmodule GatewayKit.Config.LoaderTest do
  # Not async: resolve_path/1 reads process-global state (application env, OS environment).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GatewayKit.Config
  alias GatewayKit.Config.{Error, Loader}

  @valid_yaml """
  gateway:
    port: 9090
  routes:
    - path: /api
      upstream:
        url: http://localhost:4000
  """

  defp write_tmp(contents) do
    path = Path.join(System.tmp_dir!(), "gateway_kit_#{System.unique_integer([:positive])}.yaml")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "GatewayKit.Config.Loader.resolve_path/1" do
    setup do
      original_env = System.get_env("GATEWAY_CONFIG")

      on_exit(fn ->
        Application.delete_env(:gateway_kit, :config_path)
        if original_env, do: System.put_env("GATEWAY_CONFIG", original_env), else: System.delete_env("GATEWAY_CONFIG")
      end)

      System.delete_env("GATEWAY_CONFIG")
      :ok
    end

    test "falls back to ./gateway.yaml" do
      assert Loader.resolve_path() == "gateway.yaml"
    end

    test "prefers the explicit path, then the app env, then the environment variable" do
      System.put_env("GATEWAY_CONFIG", "from_env.yaml")
      assert Loader.resolve_path() == "from_env.yaml"

      Application.put_env(:gateway_kit, :config_path, "from_flag.yaml")
      assert Loader.resolve_path() == "from_flag.yaml"

      assert Loader.resolve_path(path: "explicit.yaml") == "explicit.yaml"
    end
  end

  describe "GatewayKit.Config.Loader.load/1" do
    test "returns a validated config" do
      path = write_tmp(@valid_yaml)
      assert {:ok, %Config{port: 9090, routes: [%{path: "/api"}]}} = Loader.load(path)
    end

    test "reports a missing file without raising" do
      assert {:error, {:file, :enoent}} = Loader.load("nope/missing.yaml")

      assert Loader.format_error("nope/missing.yaml", {:file, :enoent}) =~
               "Could not read gateway config (nope/missing.yaml)"
    end

    test "reports unparseable YAML" do
      path = write_tmp("gateway: [unclosed\n")
      assert {:error, {:yaml, message}} = Loader.load(path)
      assert Loader.format_error(path, {:yaml, message}) =~ "Could not parse gateway config"
    end

    test "reports validation errors as an aligned report" do
      path = write_tmp("gateway:\n  port: 0\nroutes:\n  - path: /a\n    upstream: {}\n")

      assert {:error, {:invalid, [%Error{}, %Error{}] = errors}} = Loader.load(path)

      assert Loader.format_error(path, {:invalid, errors}) == """
             Invalid gateway config (#{path}):
               gateway.port         expected an integer 1..65535, got: 0
               routes[0].upstream   must have either "url" or "targets"\
             """
    end

    test "logs unknown keys as warnings and still loads" do
      path = write_tmp(@valid_yaml <> "      timeuot: 5s\n")

      log = capture_log(fn -> assert {:ok, %Config{}} = Loader.load(path) end)
      assert log =~ "routes[0].upstream.timeuot unknown key, ignored"
    end
  end
end
