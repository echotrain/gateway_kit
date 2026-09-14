defmodule GatewayKit.BackoffTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Backoff
  alias GatewayKit.Config.Retry

  describe "GatewayKit.Backoff.delay_ms/2" do
    test "fixed backoff always waits the initial delay" do
      retry = %Retry{attempts: 4, backoff: :fixed, initial_delay_ms: 250}
      assert Enum.map(1..3, &Backoff.delay_ms(retry, &1)) == [250, 250, 250]
    end

    test "exponential backoff doubles from the initial delay" do
      retry = %Retry{attempts: 4, backoff: :exponential, initial_delay_ms: 1_000}
      assert Enum.map(1..3, &Backoff.delay_ms(retry, &1)) == [1_000, 2_000, 4_000]
    end
  end
end
