defmodule GatewayKit.Config.DurationTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.Duration

  doctest Duration

  describe "GatewayKit.Config.Duration.parse/1" do
    test "parses every supported unit into milliseconds" do
      assert Duration.parse("250ms") == {:ok, 250}
      assert Duration.parse("30s") == {:ok, 30_000}
      assert Duration.parse("5m") == {:ok, 300_000}
      assert Duration.parse("1h") == {:ok, 3_600_000}
    end

    test "accepts zero and surrounding whitespace" do
      assert Duration.parse("0s") == {:ok, 0}
      assert Duration.parse("  10s ") == {:ok, 10_000}
    end

    test "rejects bare numbers, unknown units, negatives, and decimals" do
      for invalid <- [60, "60", "10x", "-5s", "1.5s", "", "s", nil, :s] do
        assert Duration.parse(invalid) == :error, "expected #{inspect(invalid)} to be rejected"
      end
    end
  end
end
