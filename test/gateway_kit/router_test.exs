defmodule GatewayKit.RouterTest do
  use ExUnit.Case, async: true

  alias GatewayKit.Config.Route
  alias GatewayKit.Router

  defp route(path, methods) do
    %Route{
      id: System.unique_integer([:positive]),
      path: path,
      segments: String.split(path, "/", trim: true),
      methods: methods
    }
  end

  setup do
    router =
      Router.new([
        route("/api", ["GET", "PATCH"]),
        route("/api/users", ["GET", "POST"]),
        route("/api/users/admin", ["DELETE"]),
        route("/api/orders", ["GET"]),
        route("/api/orders", ["PUT"])
      ])

    %{router: router}
  end

  describe "GatewayKit.Router.match/3" do
    test "matches the longest prefix and returns the remaining segments", %{router: router} do
      assert {:ok, %Route{path: "/api/users"}, ["42", "posts"]} = Router.match(router, "GET", ~w(api users 42 posts))
      assert {:ok, %Route{path: "/api/users/admin"}, []} = Router.match(router, "DELETE", ~w(api users admin))
      assert {:ok, %Route{path: "/api"}, []} = Router.match(router, "GET", ~w(api))
    end

    test "prefixes are segment-aligned, not textual", %{router: router} do
      assert {:ok, %Route{path: "/api"}, ["userspace"]} = Router.match(router, "GET", ~w(api userspace))
      assert {:error, :not_found} = Router.match(router, "GET", ~w(apiary))
    end

    test "falls through to the next-longest prefix that allows the method", %{router: router} do
      assert {:ok, %Route{path: "/api/users"}, ["admin"]} = Router.match(router, "GET", ~w(api users admin))
      assert {:ok, %Route{path: "/api"}, ["users", "admin"]} = Router.match(router, "PATCH", ~w(api users admin))
    end

    test "same-length routes are tried in config order", %{router: router} do
      assert {:ok, %Route{path: "/api/orders", methods: ["GET"]}, []} = Router.match(router, "GET", ~w(api orders))
      assert {:ok, %Route{path: "/api/orders", methods: ["PUT"]}, []} = Router.match(router, "PUT", ~w(api orders))
    end

    test "a matched path with no allowed method is 405 with the union of allowed methods", %{router: router} do
      assert {:error, {:method_not_allowed, ["GET", "PATCH", "POST"]}} = Router.match(router, "OPTIONS", ~w(api users))
      assert {:error, {:method_not_allowed, ["GET", "PATCH", "PUT"]}} = Router.match(router, "DELETE", ~w(api orders))
    end

    test "an unmatched path is not found", %{router: router} do
      assert {:error, :not_found} = Router.match(router, "GET", ~w(other))
      assert {:error, :not_found} = Router.match(router, "GET", [])
    end

    test "a root route is a catch-all with the lowest priority" do
      router = Router.new([route("/", ["GET"]), route("/api", ["GET"])])

      assert {:ok, %Route{path: "/api"}, ["x"]} = Router.match(router, "GET", ~w(api x))
      assert {:ok, %Route{path: "/"}, ["anything"]} = Router.match(router, "GET", ~w(anything))
      assert {:ok, %Route{path: "/"}, []} = Router.match(router, "GET", [])
    end
  end
end
