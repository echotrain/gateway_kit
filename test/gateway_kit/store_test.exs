defmodule GatewayKit.StoreTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Store

  describe "GatewayKit.Store.init/1" do
    test "owns every public table with concurrent access enabled" do
      owner = Process.whereis(Store)

      for table <- Store.tables() do
        assert :ets.info(table, :owner) == owner
        assert :ets.info(table, :protection) == :public
        assert :ets.info(table, :write_concurrency) in [true, :auto]
      end
    end

    test "exposes a distinct table per kind of state" do
      tables = [Store.windows(), Store.breakers(), Store.balancer(), Store.upstream_health()]

      assert Enum.sort(tables) == Enum.sort(Store.tables())
      assert length(Enum.uniq(tables)) == 4
    end
  end
end
