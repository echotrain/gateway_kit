defmodule GatewayKit.PipelineTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.{Route, Target, Upstream}
  alias GatewayKit.Context
  alias GatewayKit.Context.{Request, Response}
  alias GatewayKit.Pipeline

  defmodule Trace do
    @moduledoc false
    defmacro __using__(opts) do
      quote do
        @behaviour GatewayKit.Stage
        @name unquote(opts[:name])

        def enabled?(%Route{auth: auth}), do: unquote(opts[:when]) == :always or auth != nil

        def call(ctx, next) do
          ctx |> trace({:enter, @name}) |> next.() |> trace({:leave, @name})
        end

        defp trace(%Context{assigns: assigns} = ctx, event) do
          %{ctx | assigns: Map.update(assigns, :trace, [event], &(&1 ++ [event]))}
        end
      end
    end
  end

  defmodule Outer do
    @moduledoc false
    use Trace, name: :outer, when: :always
  end

  defmodule NeedsAuth do
    @moduledoc false
    use Trace, name: :auth, when: :only_with_auth
  end

  defmodule Terminal do
    @moduledoc false
    @behaviour GatewayKit.Stage
    def enabled?(_route), do: true
    def call(ctx, _next), do: Context.respond(ctx, %Response{status: 200, body: "terminal"})
  end

  defp route(overrides \\ %{}) do
    target = %Target{url: "http://localhost:1", uri: URI.parse("http://localhost:1"), weight: 1}
    upstream = %Upstream{targets: [target], timeout_ms: 1_000, ring: {target}}
    struct!(Route, Map.merge(%{id: 1, path: "/x", segments: ["x"], methods: ["GET"], upstream: upstream}, overrides))
  end

  describe "GatewayKit.Pipeline.build/2" do
    test "wraps stages outermost-first and omits disabled stages at build time" do
      pipeline = Pipeline.build(route(), [Outer, NeedsAuth, Terminal])
      ctx = pipeline.(Context.new(%Request{}, route()))

      assert ctx.response.body == "terminal"
      assert ctx.assigns.trace == [enter: :outer, leave: :outer]
    end

    test "includes a stage when its enabled?/1 is true for the route" do
      with_auth = route(%{auth: %GatewayKit.Config.Auth{type: :api_key, header: "x", keys: ["k"]}})
      pipeline = Pipeline.build(with_auth, [Outer, NeedsAuth, Terminal])
      ctx = pipeline.(Context.new(%Request{}, with_auth))

      assert ctx.assigns.trace == [enter: :outer, enter: :auth, leave: :auth, leave: :outer]
    end

    test "the default stage list ends with the proxy" do
      assert List.last(Pipeline.stages()) == GatewayKit.Stage.Proxy
    end
  end

  describe "GatewayKit.Pipeline.compile/1" do
    test "attaches a pipeline closure to the route" do
      assert %Route{pipeline: pipeline} = Pipeline.compile(route())
      assert is_function(pipeline, 1)
    end
  end
end
