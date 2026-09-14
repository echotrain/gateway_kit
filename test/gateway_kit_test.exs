defmodule GatewayKitTest do
  use ExUnit.Case
  doctest GatewayKit

  test "greets the world" do
    assert GatewayKit.hello() == :world
  end
end
