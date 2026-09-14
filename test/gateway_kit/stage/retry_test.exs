defmodule GatewayKit.Stage.RetryTest do
  use GatewayKit.GatewayCase, async: true

  alias GatewayKit.Config.{Retry, Route}
  alias GatewayKit.Context
  alias GatewayKit.Context.{Request, Response}
  alias GatewayKit.Stage

  @moduletag :capture_log

  @retry %Retry{attempts: 3, backoff: :fixed, initial_delay_ms: 0, on: [502, 503, 504]}
  @route %Route{id: 1, path: "/api", retry: @retry}

  # A fake terminal stage that answers from a scripted list of outcomes, counting calls.
  defp scripted(outcomes) do
    {:ok, script} = Agent.start_link(fn -> outcomes end)

    next = fn ctx ->
      outcome = Agent.get_and_update(script, fn [head | tail] -> {head, tail} end)

      case outcome do
        {:upstream, status} -> Context.respond(ctx, %Response{status: status, body: "attempt"})
        {:halted, status, error} -> ctx |> Context.put_error(error) |> Context.halt(status, %{error: "x"})
      end
    end

    {next, fn -> Agent.get(script, &length/1) end}
  end

  defp run(outcomes) do
    {next, remaining} = scripted(outcomes)
    ctx = Stage.Retry.call(Context.new(%Request{}, @route), next)
    {ctx, length(outcomes) - remaining.()}
  end

  describe "GatewayKit.Stage.Retry.call/2" do
    test "retries a configured upstream status until it succeeds" do
      {ctx, calls} = run([{:upstream, 503}, {:upstream, 502}, {:upstream, 200}, {:upstream, 200}])

      assert {200, 3, 3} = {ctx.response.status, calls, ctx.assigns.attempts}
    end

    test "gives up after the configured total attempts and returns the last response" do
      {ctx, calls} = run([{:upstream, 503}, {:upstream, 503}, {:upstream, 504}, {:upstream, 200}])

      assert {504, 3} = {ctx.response.status, calls}
    end

    test "does not retry statuses outside the configured list" do
      {ctx, calls} = run([{:upstream, 500}, {:upstream, 200}])

      assert {500, 1} = {ctx.response.status, calls}
    end

    test "replays a request that never reached the upstream" do
      {ctx, calls} = run([{:halted, 502, :econnrefused}, {:halted, 502, :nxdomain}, {:upstream, 200}])

      assert {200, 3} = {ctx.response.status, calls}
    end

    test "never replays after a timeout, even when 504 is a retryable status" do
      {ctx, calls} = run([{:halted, 504, :timeout}, {:upstream, 200}])

      assert {504, 1} = {ctx.response.status, calls}
      assert ctx.halted?
    end

    test "is only enabled for routes with a retry block" do
      assert Stage.Retry.enabled?(@route)
      refute Stage.Retry.enabled?(%Route{@route | retry: nil})
    end
  end

  describe "retry end to end" do
    setup %{flaky_failures: failures} do
      upstream = start_supervised!({MockUpstream, flaky_failures: failures})
      port = MockUpstream.port(upstream)
      gateway = start_gateway_from_yaml("test/support/configs/retry.yaml", %{UPSTREAM_PORT: port})
      %{gateway: gateway, upstream: upstream}
    end

    @tag flaky_failures: 2
    test "an upstream that fails twice succeeds on the third attempt", %{gateway: gateway, upstream: upstream} do
      {:ok, response} = request(gateway, :post, "/api/flaky", body: "payload")

      assert response.status == 200
      assert %{"attempt" => 3} = json(response)
      assert ["payload", "payload", "payload"] = Enum.map(MockUpstream.requests(upstream), & &1.body)
    end

    @tag flaky_failures: 3
    test "an upstream that keeps failing gets the last response after all attempts", context do
      %{gateway: gateway, upstream: upstream} = context

      {:ok, response} = request(gateway, :get, "/api/flaky")

      assert response.status == 503
      assert length(MockUpstream.requests(upstream)) == 3
    end

    @tag flaky_failures: 0
    test "a slow upstream times out once and is not replayed", %{gateway: gateway, upstream: upstream} do
      {:ok, response} = request(gateway, :get, "/api/flaky/slow/1000")

      assert response.status == 504
      assert length(MockUpstream.requests(upstream)) == 1
    end
  end
end
