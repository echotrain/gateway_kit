# onXmaps Elixir Code Standards

This document establishes coding standards for Elixir projects at onXmaps, derived from analysis of 2,000+ PR review comments across our repositories (subscriptions, xgps, offerings).

**Purpose**: Provide consistent, actionable guidelines that reduce review friction and improve code quality.

**Scope**: All Elixir/Phoenix/LiveView code in onXmaps repositories.

---

## Table of Contents

1. [Pattern Matching & Control Flow](#1-pattern-matching--control-flow)
2. [Error Handling & Safety](#2-error-handling--safety)
3. [Database & Ecto Patterns](#3-database--ecto-patterns)
4. [Testing Practices](#4-testing-practices)
5. [Code Organization & Readability](#5-code-organization--readability)
6. [Concurrency & Performance](#6-concurrency--performance)
7. [Phoenix & LiveView Patterns](#7-phoenix--liveview-patterns)
8. [API & External Services](#8-api--external-services)
9. [Documentation](#9-documentation)
10. [Configuration & Environment](#10-configuration--environment)
11. [Static Analysis](#11-static-analysis)
12. [Elixir Anti-Patterns & Code Smells](#12-elixir-anti-patterns--code-smells)
13. [Elixir Deprecations](#13-elixir-deprecations)

---

## 1. Pattern Matching & Control Flow

### 1.1 `with` vs `case`

#### The Basic Rule

**Use `case`** for a single operation with multiple outcomes you need to handle differently:

```elixir
# GOOD - single operation, multiple error patterns = case
case create_subscription(product) do
  {:ok, subscription} -> {:ok, subscription}
  {:error, %Ecto.Changeset{} = changeset} -> {:error, :validation_failed}
  {:error, :duplicate} -> {:error, :already_subscribed}
end
```

**Use `with`** when chaining multiple operations that can each fail:

```elixir
# GOOD - multiple operations chained with with + else for error handling
with {:ok, product} <- find_product(sku),
     {:ok, subscription} <- create_subscription(product),
     {:ok, _event} <- create_event(subscription) do
  {:ok, subscription}
else
  {:error, :not_found} -> {:error, :product_not_found}
  {:error, %Ecto.Changeset{}} -> {:error, :validation_failed}
  {:error, reason} -> {:error, reason}
end
```

#### Single-Clause `with` Is Often Correct

A single-clause `with` without `else` is idiomatic when you want errors to pass through to the caller. This keeps the caller's `with` chain clean.

```elixir
# GOOD - single-clause with, errors pass through to caller's with chain
def find_and_transform(id) do
  with {:ok, data} <- fetch_data(id) do
    {:ok, transform(data)}
  end
end

# Caller benefits from pass-through errors
with {:ok, transformed} <- find_and_transform(id),
     {:ok, _saved} <- save(transformed) do
  :ok
end
```

**The anti-pattern** is adding an `else` that just re-matches errors without transforming them:

```elixir
# BAD - else only re-matches without transforming
with {:ok, result} <- some_function(arg) do
  {:ok, result}
else
  {:error, :not_found} -> {:error, :not_found}  # pointless
  {:error, reason} -> {:error, reason}          # pointless
end
```

If you need to handle each error pattern differently at this level, use `case` instead.

**Credo**: `Credo.Check.Readability.WithSingleClause` flags single-clause `with` with redundant `else`.

#### Normalize Errors When Traceability Matters

When you need to know *which step* failed (for logging/debugging), wrap each step. Log at the source before transforming.

```elixir
with {:ok, product} <- find_validated_product(sku),
     {:ok, subscription} <- safe_create_subscription(product) do
  {:ok, subscription}
end

defp find_validated_product(sku) do
  case find_product(sku) do
    {:ok, product} -> {:ok, product}
    {:error, :not_found} ->
      Logger.error("Product not found: #{sku}")
      {:error, :product_not_found}
  end
end
```

Don't wrap purely to satisfy `with` — if you're just passing through `{:error, reason}` unchanged, the wrapping adds no value.

**Credo**: `Credo.Check.Refactor.WithClauses`

#### Match on Structs in `with` Clauses

In success clauses, match on **structs** rather than generic `{:ok, value}` when possible. In failure clauses, match on **specific atoms** or **reusable generics** like `%Ecto.Changeset{}`. Avoid `{:step_name, function_call()}` tagged-tuple workarounds to distinguish which step failed — if you need that, the function's return type is probably wrong.

```elixir
# BAD - tagged tuples to distinguish steps
with {:find, %Product{} = product} <- {:find, Products.get(sku)},
     {:create, {:ok, sub}} <- {:create, Subscriptions.create(product)} do
  {:ok, sub}
else
  {:find, nil} -> {:error, :not_found}
  {:create, {:error, changeset}} -> {:error, changeset}
end

# GOOD - functions return explicit tagged tuples, match on structs and specific errors
with {:ok, %Product{} = product} <- Products.fetch(sku),
     {:ok, %Subscription{} = sub} <- Subscriptions.create(product) do
  {:ok, sub}
else
  {:error, :product_not_found} -> {:error, :product_not_found}
  {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
end
```

If a function returns bare `nil` on failure (like `Repo.get/2`), wrap it in a helper that returns `{:ok, struct}` or `{:error, atom}` — don't match on `nil` in `else` clauses, as it's ambiguous when multiple steps could return `nil`.

#### Avoid Nesting `case` Inside `with`

Extract to a helper function instead:

```elixir
# BAD - case nested inside with
with {:ok, data} <- fetch_data(id) do
  case process_data(data) do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, reason}
  end
end

# GOOD - extract to separate function
with {:ok, data} <- fetch_data(id),
     {:ok, result} <- safe_process_data(data) do
  {:ok, result}
end

defp safe_process_data(data) do
  case process_data(data) do
    {:ok, result} ->
      {:ok, result}

    {:error, reason} ->
      Logger.warning("Processing failed", reason: inspect(reason))
      {:error, :processing_failed}
  end
end
```

### 1.2 Use Pattern Matching in Function Heads

Pattern match in function heads for different code paths. This is more readable than conditionals and more performant than string operations.

```elixir
# BAD - conditionals in body instead of dispatch via heads
def process(data) when is_map(data) do
  if Map.has_key?(data, :type) do
    case data.type do
      :apple -> handle_apple(data)
      :google -> handle_google(data)
    end
  end
end

# GOOD - different code paths via function heads
def process(%{type: :apple} = data), do: handle_apple(data)
def process(%{type: :google} = data), do: handle_google(data)
def process(_data), do: {:error, :unknown_type}

# BAD - string operations at runtime
defp parse_env_prefix(prefix) do
  cond do
    String.starts_with?(prefix, "Daily-") -> {:ok, :daily}
    String.starts_with?(prefix, "Stg-") -> {:ok, :staging}
    String.starts_with?(prefix, "Prod-") -> {:ok, :production}
    true -> :skip
  end
end

# GOOD - binary pattern matching in function heads
defp parse_env_prefix("Daily-" <> _), do: {:ok, :daily}
defp parse_env_prefix("Stg-" <> _), do: {:ok, :staging}
defp parse_env_prefix("Staging-" <> _), do: {:ok, :staging}
defp parse_env_prefix("Prod-" <> _), do: {:ok, :production}
defp parse_env_prefix(_), do: :skip
```

### 1.3 Use Action Resolvers for Complex Control Flow

When decision logic is too complex for guards or requires data extraction, extract it into an **action resolver** - a function that returns descriptive atoms or values indicating what action to take.

```elixir
# BAD - inline logic obscures intent
def call(%Plug.Conn{} = conn, _opts) do
  platform = conn |> get_req_header("onx-application-platform") |> List.first()

  cond do
    platform == "ios" ->
      %{conn | request_path: "/redirect/apple", path_info: ["redirect", "apple"]}

    platform == "android" ->
      %{conn | request_path: "/redirect/google", path_info: ["redirect", "google"]}

    true ->
      conn
  end
end

# GOOD - action resolver with if (binary outcome)
def call(%Plug.Conn{} = conn, _opts) do
  path =
    conn
    |> get_req_header("onx-application-platform")
    |> List.first()
    |> redirect_path()

  if path do
    %{conn | request_path: path, path_info: get_path_info(path)}
  else
    conn
  end
end

defp redirect_path("ios"), do: "/redirect/apple"
defp redirect_path("android"), do: "/redirect/google"
defp redirect_path(_), do: nil
```

For multiple distinct outcomes, combine an action resolver with `case`:

```elixir
# GOOD - action resolver with case (multiple outcomes)
def process_notification(notification) do
  case resolve_notification_action(notification) do
    :send_email -> EmailWorker.enqueue(notification)
    :send_push -> PushWorker.enqueue(notification)
    :send_both -> send_all_channels(notification)
    :skip -> {:ok, :skipped}
  end
end

defp resolve_notification_action(%{preferences: %{email: true, push: true}}), do: :send_both
defp resolve_notification_action(%{preferences: %{email: true}}), do: :send_email
defp resolve_notification_action(%{preferences: %{push: true}}), do: :send_push
defp resolve_notification_action(_), do: :skip
```

**Use action resolvers when:**

- The decision requires extracting or transforming data first
- Guards would be too complex or repetitive
- The calling code should read as "resolve action, then execute"
- Multiple callers might need the same decision logic

### 1.4 Avoid Misusing `tap/2` and `then/2`

`tap/2` and `then/2` are useful in specific situations but are often misused to compress multiple lines into one, making code harder to read and debug.

> "I don't believe we should necessarily be leading people to encode more logic into pipelines."
> — Jose Valim, [elixir-lang-core discussion](https://groups.google.com/g/elixir-lang-core/c/QRz7ru9bfUU)

```elixir
# BAD - tap for side effects obscures the error tuple
_ -> tap({:error, :missing_deps}, &Logger.error("not found: #{inspect(&1)}"))

# GOOD - explicit and debuggable
_ ->
  Logger.error("subscription_id not found")
  {:error, :missing_deps}

# BAD - then with capture operator creates hard-to-read pipelines
subscription
|> get_in(safe_path([:id]))
|> then(&%{from_subscription: &1})
|> StripeSubscriptionSchedule.create(idempotency_key: key)

# GOOD - just use a variable
subscription_id = get_in(subscription, safe_path([:id]))
StripeSubscriptionSchedule.create(%{from_subscription: subscription_id}, idempotency_key: key)

# BAD - then wrapping a function call at end of pipeline
params
|> maybe_add_discounts()
|> then(&StripeSchedule.update(id, &1, expand: ["subscription"]))

# GOOD - use a variable if the function signature doesn't fit the pipeline
params = maybe_add_discounts(params)
StripeSchedule.update(id, params, expand: ["subscription"])
```

**When `tap/2` IS appropriate** — side effects in the *middle* of a pipeline:

```elixir
# GOOD - tap for logging, value flows through unchanged
data
|> transform()
|> tap(&Logger.debug("Transformed: #{inspect(&1)}"))
|> persist()
```

**When `then/2` IS appropriate** — bridging a piped value into a function whose argument order you don't control:

```elixir
# GOOD - external function doesn't accept the query as its first argument
Oban.Job
|> where([j], j.queue in ^queue_strings)
|> where([j], j.state == "discarded")
|> where([j], j.attempt >= j.max_attempts)
|> where([j], j.discarded_at > ^cutoff_time)
|> group_by([j], j.queue)
|> select([j], {j.queue, count(j.id)})
|> then(&Oban.Repo.all(config, &1))
|> Map.new()
```

**Guidelines:**

- **Prefer rearranging your own function's argument order** so the piped value is first — avoid reaching for `then/2` when you control the function
- **For external functions whose argument order you can't change**, `then(&fun.(x, &1, y))` is the intended use
- **If `then/2` wraps logic complex enough that a named helper or `case` would be clearer**, use those instead
- If `tap/2` is at the end of a pipeline, you probably shouldn't use `tap/2`
- For error handling (`{:ok, _}` / `{:error, _}`), prefer `with` over `then/2`

---

## 2. Error Handling & Safety

### 2.1 Atom Conversion

#### Prefer Letting `String.to_existing_atom/1` Raise

For domain values (apps, gateways, subscription levels, etc.), let `String.to_existing_atom/1` raise. An unknown value indicates a bug — either the caller passed bad data or a new value wasn't properly introduced to the system.

```elixir
# GOOD - let it raise for domain values
def parse_gateway(gateway_string) when is_binary(gateway_string) do
  String.to_existing_atom(gateway_string)
end
# Raises ArgumentError if "stripe" comes through but :stripe atom doesn't exist
# This is correct — it surfaces integration bugs immediately
```

This approach:

- Fails fast when new domain values are introduced without corresponding atoms
- Surfaces configuration mismatches between systems early
- Avoids silent failures that propagate bad data

#### When to Validate First

Only validate against a known list when you're at a **system boundary** receiving truly untrusted input (user-facing APIs, external webhooks) and want to return a meaningful error instead of a 500.

```elixir
# At system boundary - validate for user-friendly errors
@valid_apps ~w(hunt fish backcountry offroad)

defp parse_app_param(app) when is_binary(app) do
  if app in @valid_apps do
    {:ok, String.to_existing_atom(app)}
  else
    {:error, :invalid_app}
  end
end
```

#### Never Use `String.to_atom/1`

`String.to_atom/1` creates atoms from arbitrary input, exhausting the atom table (atoms are never garbage collected). Always use `String.to_existing_atom/1`.

```elixir
# BAD - creates atoms, potential memory leak
String.to_atom(user_input)

# GOOD - only converts to existing atoms
String.to_existing_atom(user_input)
```

**Credo**: `Credo.Check.Warning.UnsafeToAtom` (consider enabling)

### 2.2 Safe Logger Interpolation

Complex types can raise `Protocol.UndefinedError` during interpolation.

```elixir
# BAD - can raise if reason is a tuple/map
Logger.error("Failed to fetch token: #{reason}")

# GOOD - always inspect complex values
Logger.error("Failed to fetch token: #{inspect(reason)}")

# GOOD - use metadata for structured logging
Logger.error("Failed to fetch token", reason: inspect(reason), account_id: account_id)
```

### 2.3 Handle Nil in Function Clauses

```elixir
# BAD - nil flows through and causes errors downstream
defp lookup_product(gateway, product_code) do
  ProductsCache.get_product_by_sku(gateway, product_code)
end

# GOOD - fail early on nil
defp lookup_product(_gateway, nil), do: {:error, :not_found}
defp lookup_product(nil, _product_code), do: {:error, :invalid_gateway}

defp lookup_product(gateway, product_code) do
  case ProductsCache.get_product_by_sku(gateway, product_code) do
    {:ok, _product} = result -> result
    {:error, :not_found} -> try_other_gateways(gateway, product_code)
  end
end
```

---

## 3. Database & Ecto Patterns

### 3.1 Consistent Timestamp Precision

Use microsecond precision for all timestamps.

```elixir
# GOOD - consistent precision
schema "my_table" do
  field :name, :string
  timestamps(type: :utc_datetime_usec)
end

# BAD - inconsistent precision
timestamps() # defaults to :naive_datetime
```

### 3.2 Use Ecto.Multi for Transactions

`Ecto.Multi` provides named steps, composability, and detailed failure information - not just atomicity (which `Repo.transaction/1` also provides).

```elixir
# ACCEPTABLE - works, but errors are opaque
Repo.transaction(fn ->
  with {:ok, offer} <- Repo.insert(offer_changeset),
       {:ok, details} <- Repo.insert(details_changeset(offer)) do
    {offer, details}
  else
    {:error, changeset} -> Repo.rollback(changeset)
  end
end)

# BETTER - named steps make failures traceable
Ecto.Multi.new()
|> Ecto.Multi.insert(:promotion_offer, offer_changeset)
|> Ecto.Multi.insert(:display_details, fn %{promotion_offer: offer} ->
  details_changeset(offer)
end)
|> Repo.transaction()
|> case do
  {:ok, %{promotion_offer: offer, display_details: details}} -> {:ok, offer}
  {:error, :promotion_offer, changeset, _} -> {:error, :offer_invalid}
  {:error, :display_details, changeset, _} -> {:error, :details_invalid}
end
```

**When to use Multi:**

- Multiple dependent inserts/updates
- Need to know *which* step failed
- Building reusable transaction components via `Ecto.Multi.merge/2`

### 3.3 Avoid N+1 Queries

```elixir
# BAD - N+1 query in iteration
paywall.paywall_product_groups
|> Enum.each(fn ppg ->
  details = Repo.get(ProductGroupDisplayDetails, ppg.display_details_id)
  # Each iteration hits the database
end)

# GOOD - preload associations
@preload_all [
  paywall_product_groups: [
    :product_group_display_details,
    product_group: [:product_group_products]
  ]
]

def get_paywall(id) do
  Paywall
  |> preload(^@preload_all)
  |> Repo.get(id)
end

# GOOD - batch query with single DB call
defp build_sku_product_map(gateway, tiers) do
  tiers
  |> Enum.map(& &1.sku)
  |> Enum.uniq()
  |> Map.new(fn sku ->
    {sku, ProductsCache.get_product_by_sku(gateway, sku)}
  end)
end
```

### 3.4 Avoid Expensive Empty Checks

`length/1` traverses the entire list — use pattern matching or `Enum.empty?/1` instead:

```elixir
# BAD - O(n) operation
if length(list) == 0 do
  # empty case
end

# GOOD - direct comparison, simplest option
if list == [] do
  # empty case
end

# GOOD - also O(1), works with any enumerable
if Enum.empty?(list) do
  # empty case
end
```

**Credo**: `Credo.Check.Warning.ExpensiveEmptyEnumCheck`

### 3.5 Escape LIKE Wildcards

Prevent SQL injection when building LIKE queries with user input.

```elixir
defp maybe_filter_by_description(query, description) when is_binary(description) do
  pattern = "%#{escape_like(description)}%"
  where(query, [r], ilike(r.description, ^pattern))
end

defp escape_like(value) when is_binary(value) do
  value
  |> String.replace("\\", "\\\\")
  |> String.replace("%", "\\%")
  |> String.replace("_", "\\_")
end
```

---

## 4. Testing Practices

### 4.1 Avoid `Process.sleep` - Use Message-Based Synchronization

```elixir
# BAD - arbitrary sleep
test "handles async operation" do
  start_worker()
  Process.sleep(100)
  assert result == expected
end

# GOOD - message-based synchronization
test "handles async operation" do
  test_pid = self()

  stub(Builder, :upsert_paywall, fn _config ->
    send(test_pid, :seeding_attempted)
    {:ok, %Paywall{}}
  end)

  start_supervised(OfferingsSeeder)
  assert_receive :seeding_attempted, 1_000
end
```

### 4.2 Use Oban Inline Mode for Workflow Tests

```elixir
# BAD - mocking Relay internals
stub(Oban.Pro.Relay, :async, fn _job -> {:ok, %Oban.Job{}} end)
expect(Oban.Pro.Relay, :await, fn _job -> {:ok, %{}} end)

# GOOD - inline mode executes real worker
expect(GatewayMigrator, :migrate, fn ^account_id, :apple, :realtime ->
  {:ok, %{status: :completed}}
end)

Oban.Testing.with_testing_mode(:inline, fn ->
  assert {:ok, _} = MigrationGate.maybe_migrate(account_id, :apple)
end)
```

### 4.3 Document Skipped Tests

```elixir
# BAD - skipped without explanation
@tag :skip
test "ordering by inserted_at" do
  # ...
end

# GOOD - explain why it's skipped
@tag skip: "Flaky due to timestamp precision - see GD-1234"
test "ordering by inserted_at" do
  # ...
end
```

**Credo**: `Credo.Check.Design.SkipTestWithoutComment` (consider enabling)

### 4.4 Test Cascade Deletes

```elixir
describe "delete/1" do
  test "cascades delete to associated display_details" do
    paywall = paywall_fixture()
    display_details = display_details_fixture(paywall_id: paywall.id)

    assert {:ok, _} = Paywalls.delete(paywall)
    assert Repo.get(ProductGroupDisplayDetails, display_details.id) == nil
  end
end
```

### 4.5 Use Deterministic Test Data

```elixir
# BAD - random UUIDs make ordering tests non-deterministic
test "streams filter by gateway" do
  insert_purchase(%{account_id: Ecto.UUID.generate(), type: :apple})
  insert_purchase(%{account_id: Ecto.UUID.generate(), type: :google})
  # Order depends on random UUID values
end

# GOOD - fixed UUIDs ensure deterministic ordering
test "streams filter by gateway" do
  apple_ids = ["f0000000-0000-0000-0000-000000000001"]
  google_ids = ["00000000-0000-0000-0000-000000000001"]

  Enum.each(apple_ids, &insert_purchase(%{account_id: &1, type: :apple}))
  Enum.each(google_ids, &insert_purchase(%{account_id: &1, type: :google}))

  assert {:ok, [^apple_ids]} = PurchaseQuery.fetch_batch(gateway: :apple)
end
```

---

## 5. Code Organization & Readability

### 5.1 Alphabetize Aliases

```elixir
# BAD
alias Offerings.EctoUtils
alias Offerings.Management.Rules
alias OfferingsWeb.Forms.UUID
alias OfferingsWeb.Forms.CreateRule

# GOOD
alias Offerings.EctoUtils
alias Offerings.Management.Rules
alias OfferingsWeb.Forms.CreateRule
alias OfferingsWeb.Forms.UUID
```

**Credo**: `Credo.Check.Readability.AliasOrder`

### 5.2 Add Type Specifications to Public Functions

```elixir
# BAD - no spec
def list_rules_for_promotion_offer(promotion_offer_id) do
  # ...
end

# GOOD - with spec
@spec list_rules_for_promotion_offer(Ecto.UUID.t()) :: {:ok, [Rule.t()]} | {:error, :not_found}
def list_rules_for_promotion_offer(promotion_offer_id) do
  # ...
end
```

**Credo**: `Credo.Check.Readability.Specs` (consider enabling for public functions)

### 5.3 Store Static Data in Module Attributes

```elixir
# BAD - computed at runtime on every call
defp individual_targeting_rule?(rule) do
  matchers = get_in(rule, ["condition", "matchers"]) || []
  targeting_types = ["IN_SEGMENT", "WHITELIST", "EQUAL_TO_SET"]

  Enum.any?(matchers, &(&1["type"] in targeting_types))
end

# GOOD - computed at compile time
@individual_targeting_types MapSet.new(["IN_SEGMENT", "WHITELIST", "EQUAL_TO_SET"])

defp individual_targeting_rule?(rule) do
  matchers = get_in(rule, ["condition", "matchers"]) || []
  Enum.any?(matchers, &(&1["type"] in @individual_targeting_types))
end
```

### 5.4 Extract Duplicated Logic

```elixir
# BAD - duplicated filter logic
def all_products do
  products
  |> Enum.reject(&(&1.status == :archived))
end

def filter_products(criteria) do
  products
  |> Enum.reject(&(&1.status == :archived))
  |> Enum.filter(&matches_criteria?(&1, criteria))
end

# GOOD - extracted helper
defp active_products(products) do
  Enum.reject(products, &(&1.status == :archived))
end

def all_products, do: active_products(products)

def filter_products(criteria) do
  products
  |> active_products()
  |> Enum.filter(&matches_criteria?(&1, criteria))
end
```

### 5.5 Don't Extract Single-Use Helpers Prematurely

It's fine to keep private helper logic inline until you genuinely need it in more than one place. Extracting a single-use function forces the reader to jump between a public function at the top of the file and a helper somewhere at the bottom, which can hurt readability more than it helps.

```elixir
# UNNECESSARY EXTRACTION - helper used only once, forces reader to jump around
def process(data) do
  data
  |> validate()
  |> do_transform()
end

defp do_transform(data) do
  Map.update!(data, :value, &(&1 * 2))
end

# SIMPLER - inline until extraction is needed
def process(data) do
  data
  |> validate()
  |> Map.update!(:value, &(&1 * 2))
end
```

**Extract when** there's actual duplication (as in [5.4](#54-extract-duplicated-logic)), the logic is complex enough to warrant a descriptive name, or you need to test it independently.

### 5.6 Module Documentation

```elixir
defmodule Offerings.EctoUtils do
  @moduledoc """
  Utility functions for working with `Ecto.Changeset` structs.

  Provides helpers for formatting validation errors into human-readable
  maps suitable for API responses.
  """

  @doc """
  Formats changeset errors into a map of human-readable messages.

  ## Examples

      iex> changeset = %Ecto.Changeset{errors: [name: {"can't be blank", []}]}
      iex> format_changeset_errors(changeset)
      %{name: ["can't be blank"]}
  """
  @spec format_changeset_errors(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def format_changeset_errors(changeset) do
    # ...
  end
end
```

**Credo**: `Credo.Check.Readability.ModuleDoc`

### 5.7 Context Boundaries and Namespace Depth

If you find yourself reaching four or more namespaces deep to call a function, it's a sign that a context boundary module should be introduced.

```elixir
# BAD - reaching too deep into nested modules
MoneyMogul.BackfillMigration.Workers.AccountMigrationWorker.migrate(account_id)
Offerings.Management.PromotionOffers.Rules.attach_rule(offer_id, rule_id)

# GOOD - expose through a context boundary
MoneyMogul.BackfillMigration.migrate_account(account_id)
Offerings.PromotionOffers.attach_rule(offer_id, rule_id)
```

Context modules should:

- Serve as the public API for a domain
- Hide internal implementation details
- Delegate to internal modules as needed

```elixir
defmodule Offerings.PromotionOffers do
  @moduledoc """
  Context boundary for promotion offer operations.
  """

  alias Offerings.Management.PromotionOffers.Rules

  defdelegate attach_rule(offer_id, rule_id), to: Rules
  defdelegate detach_rule(offer_id, rule_id), to: Rules

  # Or implement directly if simple enough
  def get(id), do: Repo.get(PromotionOffer, id)
end
```

**Rule of thumb**: External modules should rarely need to alias anything deeper than `App.Context.Schema`. If they do, consider whether the context boundary is missing functionality.

**See also:** [7.5 LiveView Context Boundaries](#75-liveview-context-boundaries) for Phoenix-specific guidance on separating presentation from business logic.

---

## 6. Concurrency & Performance

### 6.1 Prefer List Prepending and Head Matching

Prepending to a list is O(1) because it only reads the head pointer. Appending with `++` copies the entire left-hand list (O(n)).

```elixir
# BAD - O(n) append, copies the entire list
updated = list ++ [new_value]

# GOOD - O(1) prepend
updated = [new_value | list]
```

Head matching in function clauses is idiomatic and efficient — particularly useful when processing platform-specific data (e.g., Stripe events):

```elixir
# GOOD - match the head in function clauses
def process_events([event | rest]) do
  handle(event)
  process_events(rest)
end

def process_events([]), do: :ok
```

If final ordering matters, build the list with prepend and call `Enum.reverse/1` once at the end — still cheaper than repeated appending.

#### Combining Two Lists (Single Concat)

When joining two already-flat lists once, use `++` or `Enum.concat/2` — they are equivalent (`Enum.concat/2` is literally `left ++ right` for two lists) and both faster than `List.flatten/1`:

```elixir
# GOOD - O(length(list_1)), right list shared by reference
combined = list_1 ++ list_2

# GOOD - identical performance, more readable in pipelines
combined = Enum.concat(list_1, list_2)

# BAD - walks every element of both lists checking for nesting, 3–6x slower
combined = List.flatten([list_1 | list_2])
```

`List.flatten/1` is necessary only when you actually have nested lists. Benchmarked on OTP 28: `List.flatten` is 3–6x slower than `++` for a single concat of two flat lists, regardless of list size.

#### Repeated Concatenation in a Loop (Accumulator Pattern)

The rule changes when you're concatenating inside a `reduce` or recursive accumulator. Using `++` against a growing accumulator is O(N²) because the left side is copied on every iteration:

```elixir
# BAD - O(N²), left side grows and is copied every iteration
Enum.reduce(items, [], fn item, acc ->
  acc ++ transform(item)
end)

# GOOD - O(N), prepend then reverse once
items
|> Enum.reduce([], fn item, acc -> [transform(item) | acc] end)
|> Enum.reverse()

# GOOD - or use Enum.flat_map/2 directly
Enum.flat_map(items, &transform/1)
```

Benchmarks show repeated `++` in a 1,000-iteration reduce is **259x slower** than cons+reverse for large lists (OTP 28). The fast-elixir tip about `List.flatten([list | acc])` applies specifically to this accumulator pattern — not to single two-list concatenation.

### 6.2 Use `Task.async_stream` for Parallel Operations

```elixir
# BAD - sequential, slow
defp fetch_all_apps do
  Enum.map(@apps, fn app ->
    {app, Manager.get_feature_flag_definition(app, @feature_flag)}
  end)
end

# GOOD - parallel with backpressure
defp fetch_all_apps do
  @apps
  |> Task.async_stream(
    fn app -> {app, Manager.get_feature_flag_definition(app, @feature_flag)} end,
    timeout: 15_000
  )
  |> Enum.reduce({%{}, %{}}, fn {:ok, {app, result}}, {data, errs} ->
    case result do
      {:ok, flag} -> {Map.put(data, app, flag), errs}
      {:error, reason} -> {data, Map.put(errs, app, reason)}
    end
  end)
end
```

### 6.3 ETS Table Ownership

Named ETS tables should be owned by a supervised process. Create unconditionally in `init/1` - if the process restarts, you want a fresh table anyway.

```elixir
# BAD - conditional creation doesn't prevent race conditions
def init(_) do
  if :ets.whereis(@table_name) == :undefined do
    :ets.new(@table_name, [:set, :named_table])
  end
  {:ok, %{}}
end

# GOOD - unconditional creation in supervised GenServer
def init(_) do
  :ets.new(@table_name, [:set, :named_table, :protected, read_concurrency: true])
  {:ok, %{}, {:continue, :initial_fetch}}
end

# GOOD - for tables that must survive process restarts, use a dedicated owner
defmodule MyApp.TableOwner do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    :ets.new(:my_cache, [:set, :named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end
end

# Add TableOwner early in supervision tree, before processes that use the table
```

**Why unconditional?** If your GenServer crashed and restarted, the old table died with the old process. A fresh `init/1` means a fresh table. The `whereis` check suggests the table might exist from a previous run - but named tables don't survive their owner's death. If you need persistence across restarts, use a dedicated table owner process started early in your supervision tree.

### 6.4 Move Expensive Computations Out of LiveView Renders

```elixir
# BAD - computed on every render
def render(assigns) do
  location_description = compute_location_description(assigns.location)
  flag_content = compute_flag_content(assigns.flags)
  # ...
end

# GOOD - compute in handle_info, store in assigns
def handle_info(:load_data, socket) do
  location_description = compute_location_description(socket.assigns.location)
  flag_content = compute_flag_content(socket.assigns.flags)

  {:noreply,
   socket
   |> assign(:location_description, location_description)
   |> assign(:flag_content, flag_content)}
end
```

### 6.5 Avoid Hardcoded Timeouts

Don't hardcode operational values like timeouts. See [Section 10](#10-configuration--environment) for complete configuration patterns.

```elixir
# BAD - hardcoded
defp fetch_data do
  Finch.request(request, MyFinch, receive_timeout: 10_000)
end

# GOOD - configurable (see Section 10 for compile_env! vs get_env tradeoffs)
defp fetch_data do
  timeout = Application.get_env(:app, :request_timeout_ms, 10_000)
  Finch.request(request, MyFinch, receive_timeout: timeout)
end
```

---

## 7. Phoenix & LiveView Patterns

### 7.1 Use `live_session` for Authorization

```elixir
# BAD - checking role on every page load in mount
def mount(_params, _session, socket) do
  if has_editor_role?(socket.assigns.current_user) do
    {:ok, socket}
  else
    {:ok, push_navigate(socket, to: "/")}
  end
end

# GOOD - check once in router via live_session
live_session :admin_editor,
  on_mount: [
    {OfferingsWeb.InternalUserAuth, :ensure_authenticated},
    {OfferingsWeb.InternalUserAuth, {:require_role, :editor}},
    OfferingsWeb.Hooks.AssignCurrentPath
  ] do
  live "/paywalls/new", PaywallsLive.New, :new
  live "/product_groups/new", ProductGroupsLive.New, :new
end
```

### 7.2 Use Pattern Matching in Function Components

For `Phoenix.Component` function components, use pattern matching in function heads for variants:

```elixir
# BAD - conditionals in single render
def button(assigns) do
  ~H"""
  <%= if @type == :primary do %>
    <button class="btn-primary">{@label}</button>
  <% else %>
    <button class="btn-secondary">{@label}</button>
  <% end %>
  """
end

# GOOD - separate function clauses (Phoenix.Component only)
def button(%{type: :primary} = assigns) do
  ~H"""<button class="btn-primary">{@label}</button>"""
end

def button(%{type: :secondary} = assigns) do
  ~H"""<button class="btn-secondary">{@label}</button>"""
end
```

**Note:** This pattern works for function components. A `Phoenix.LiveView` module's `render/1` receives the full assigns map and cannot have multiple clauses - extract variants to function components instead.

### 7.3 Use Design System Components

```elixir
# BAD - inconsistent styling
<button class="px-4 py-2 bg-blue-500 text-white rounded">
  Refresh
</button>

# GOOD - design system components
<.ys_button variant="primary" phx-click="refresh">
  Refresh
</.ys_button>
```

### 7.4 Use CSS Variables for Theming

```elixir
# BAD - hardcoded colors
<div class="text-[#1a1a2e]">

# GOOD - CSS variables (Tailwind v4 syntax)
<div class="text-(--ys-color-text-primary)">
```

### 7.5 LiveView Context Boundaries

LiveViews are presentation layer - delegate business logic to Contexts.

```elixir
# BAD - business logic and Repo access in LiveView
def handle_event("cancel_subscription", %{"id" => id}, socket) do
  subscription = Repo.get!(Subscription, id)

  if subscription.status == :active and subscription.cancel_at == nil do
    subscription
    |> Ecto.Changeset.change(%{cancel_at: DateTime.utc_now()})
    |> Repo.update()
  end

  {:noreply, socket}
end

# BAD - passing socket to context
def handle_event("save", params, socket) do
  Subscriptions.create_with_socket(params, socket)
end

# GOOD - delegate to context, LiveView only handles presentation
def handle_event("cancel_subscription", %{"id" => id}, socket) do
  case Subscriptions.cancel(id) do
    {:ok, subscription} ->
      {:noreply, assign(socket, :subscription, subscription)}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, error_message(reason))}
  end
end
```

**Boundaries:**

- LiveView handles: user events, assigns, flash messages, navigation
- Context handles: business rules, data access, validations, side effects

### 7.6 Real-Time Patterns

LiveViews are processes - use PubSub for real-time updates.

```elixir
# Subscribe in mount (only when connected)
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "subscriptions:#{socket.assigns.account_id}")
  end

  {:ok, assign(socket, :subscription, nil)}
end

# Handle broadcasts with explicit pattern matching
def handle_info({:subscription_updated, subscription}, socket) do
  {:noreply, assign(socket, :subscription, subscription)}
end

def handle_info({:subscription_cancelled, reason}, socket) do
  {:noreply,
   socket
   |> assign(:subscription, nil)
   |> put_flash(:info, "Subscription cancelled: #{reason}")}
end

# Catch-all for unexpected messages (defensive)
def handle_info(msg, socket) do
  Logger.warning("Unexpected message in #{__MODULE__}: #{inspect(msg)}")
  {:noreply, socket}
end

# Broadcast from context
defmodule MyApp.Subscriptions do
  def cancel(id) do
    with {:ok, subscription} <- do_cancel(id) do
      Phoenix.PubSub.broadcast(MyApp.PubSub, "subscriptions:#{subscription.account_id}",
        {:subscription_cancelled, subscription.id})
      {:ok, subscription}
    end
  end
end
```

**When to use what:**

- **LiveView + PubSub**: Server-initiated updates to connected users (state changes, notifications)
- **Channels**: Bidirectional real-time (chat, collaborative editing, gaming)
- **Polling**: External data sources that don't support push

### 7.7 Use Streams for Large Collections

For lists that grow over time or are too large to hold in memory, use `stream/3`:

```elixir
# BAD - holds entire list in socket assigns
def mount(_params, _session, socket) do
  transactions = Transactions.list_recent(socket.assigns.account_id)
  {:ok, assign(socket, :transactions, transactions)}
end

# GOOD - stream for append-only or paginated data
def mount(_params, _session, socket) do
  {:ok, stream(socket, :transactions, Transactions.list_recent(socket.assigns.account_id))}
end

def handle_info({:new_transaction, transaction}, socket) do
  {:noreply, stream_insert(socket, :transactions, transaction, at: 0)}
end
```

In your template, use `@streams` with `phx-update="stream"`:

```heex
<div id="transactions" phx-update="stream">
  <div :for={{dom_id, transaction} <- @streams.transactions} id={dom_id}>
    <%= transaction.description %> - <%= transaction.amount %>
  </div>
</div>
```

**Critical:** Each stream item needs a unique DOM ID. LiveView uses `dom_id` (the first element of the tuple) for tracking.

**Use streams when:**

- Displaying audit logs, transaction histories, activity feeds
- Data is append-only or paginated
- The full list would consume significant memory

### 7.8 Declare Component Attributes

Function components should declare their API surface with `attr` and `slot`:

```elixir
# BAD - undeclared assigns, no type checking
def status_badge(assigns) do
  ~H"""
  <span class={@class}>{@status}</span>
  """
end

# GOOD - explicit contract with types and defaults
attr :status, :atom, required: true, values: [:active, :cancelled, :pending]
attr :class, :string, default: ""

def status_badge(assigns) do
  ~H"""
  <span class={["badge", status_class(@status), @class]}>{@status}</span>
  """
end

defp status_class(:active), do: "badge-success"
defp status_class(:cancelled), do: "badge-error"
defp status_class(:pending), do: "badge-warning"
```

**Benefits:**

- Compile-time warnings for missing required attrs
- Documentation via `attr` declarations
- HEEx validation catches typos in callers

### 7.9 Prefer JS Commands Over Custom Hooks

Use `Phoenix.LiveView.JS` for client-side interactions that don't need server state:

```elixir
# BAD - round-trip to server for simple toggle
def handle_event("toggle_menu", _, socket) do
  {:noreply, assign(socket, :menu_open, !socket.assigns.menu_open)}
end

# GOOD - JS command, no server round-trip
<button phx-click={JS.toggle(to: "#dropdown-menu")}>
  Menu
</button>
<div id="dropdown-menu" class="hidden">...</div>
```

**Note:** `JS.toggle` works by adding/removing the `hidden` class. The element must have `class="hidden"` initially if you want it hidden on first render.

```elixir
# GOOD - combine JS commands
<button phx-click={
  JS.hide(to: "#modal")
  |> JS.push("confirm_action")
}>
  Confirm
</button>
```

**Use JS commands for:** show/hide, toggle classes, transitions, focus management

**Use hooks when:** integrating third-party JS libraries, complex DOM manipulation, accessing browser APIs not exposed by LiveView

---

## 8. API & External Services

### 8.1 Consistent Error Tuple Formats

```elixir
# Standard error formats
{:error, :not_found}                      # Known error atoms
{:error, %Ecto.Changeset{}}               # Validation errors
{:error, {400, :bad_request}}             # HTTP status codes
{:error, {:validation, field, reason}}    # Structured validation errors

# BAD - map errors (not handled by FallbackController)
{:error, %{error: "Something went wrong"}}

# GOOD - atom errors (handled by FallbackController)
{:error, :something_went_wrong}
```

### 8.2 Document Breaking Metric Changes

```elixir
# When renaming telemetry events, document the change
@moduledoc """
## Telemetry Events

- `[:app, :permit, :fetch_role]` - Duration of role fetch
- Renamed from `[:app, :permit, :get_role]` in v2.0
"""
```

### 8.3 Use Consistent gRPC Status Tags

```elixir
# BAD - nil values in tags
tags: %{function: function, grpc_status: nil}

# GOOD - consistent sentinel values
tag_values: fn metadata ->
  %{
    function: Map.get(metadata, :function),
    grpc_status: Map.get(metadata, :grpc_status, "n/a")
  }
end
```

---

## 9. Documentation

### 9.1 Keep Docstrings in Sync with Behavior

```elixir
# BAD - docstring describes old behavior
@doc """
Returns `:has_failures` based on status == :failed.
"""
def migration_status(id) do
  # Actually checks both status AND failures list
end

# GOOD - docstring matches implementation
@doc """
Returns migration status.

- `:has_failures` - if status is `:failed` OR failures list is non-empty
- `:completed` - if status is `:completed` with no failures
"""
def migration_status(id) do
  # ...
end
```

### 9.2 Remove Debug Code

```elixir
# BAD - debug code in production
def fetch_batch(opts) do
  query
  |> build_query(opts)
  |> dbg() # Remove before merge!
  |> Repo.all()
end

# GOOD - no debug code
def fetch_batch(opts) do
  query
  |> build_query(opts)
  |> Repo.all()
end
```

**Credo**: `Credo.Check.Warning.Dbg`, `Credo.Check.Warning.IoInspect`, `Credo.Check.Warning.IExPry`

### 9.3 Delete Dead Code

Don't comment out code or leave empty files. Delete unused code - it's in git history if needed.

---

## 10. Configuration & Environment

### 10.1 Compile-Time vs Runtime Config

Choose based on how the value will be used:

```elixir
# compile_env! - for values that define application structure
# Catches missing config at build time, requires recompilation to change
@adapter Application.compile_env!(:app, :payment_adapter)
@feature_flags Application.compile_env!(:app, :enabled_features)

# get_env/3 - for operational tuning values
# Can be adjusted in production without redeploying
def fetch_data do
  timeout = Application.get_env(:app, :request_timeout_ms, 10_000)
  batch_size = Application.get_env(:app, :batch_size, 100)
  # ...
end
```

| Use `compile_env!` for | Use `get_env/3` for |
| ---------------------- | ------------------- |
| Adapter modules        | Timeouts            |
| Feature flags          | Batch sizes         |
| Endpoint config        | Retry counts        |
| Required secrets       | Rate limits         |

### 10.2 Safe Configuration Access

Always provide defaults when config might be missing:

```elixir
# BAD - raises if config is nil
config = Application.get_env(:offerings, Offerings.Goth)
config[:credentials] # raises if config is nil

# GOOD - provide defaults
config = Application.get_env(:offerings, Offerings.Goth, [])
Keyword.get(config, :credentials)
```

### 10.3 Config Key Consistency

```elixir
# BAD - mismatched keys
# In test fixture:
setup_config(query_timeout_ms: 5000)

# In module:
Application.get_env(:app, :batch_query_timeout_ms) # Different key!

# GOOD - consistent keys
setup_config(batch_query_timeout_ms: 5000)
Application.get_env(:app, :batch_query_timeout_ms)
```

### 10.4 Validate Required Config at Startup

```elixir
# Use compile_env! for required compile-time config
@base_url Application.compile_env!(:app, :external_api_url)

# Validate in application.ex for required runtime config
def start(_type, _args) do
  validate_required_config!()
  # ...
end

defp validate_required_config! do
  if is_nil(System.get_env("BASE_URL")) do
    raise "BASE_URL environment variable is required"
  end
end
```

**Credo**: `Credo.Check.Warning.ApplicationConfigInModuleAttribute` warns about runtime `get_env` in module attributes - `compile_env!` silences it correctly.

---

## 11. Static Analysis

### 11.1 Enabling Credo and Dialyzer

Both tools should be enabled in every Elixir project. Add to `mix.exs`:

```elixir
defp deps do
  [
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
  ]
end
```

Add aliases for convenience:

```elixir
defp aliases do
  [
    quality: ["format --check-formatted", "credo --strict", "dialyzer"]
  ]
end
```

Run both as part of local development and CI:

```bash
mix credo --strict    # Lint
mix dialyzer          # Type analysis
mix quality           # All checks (with alias above)
```

### 11.2 Credo Rules Reference

#### Currently Enabled (Key Rules)

| Rule                                          | Description                                  |
| --------------------------------------------- | -------------------------------------------- |
| `Credo.Check.Refactor.WithClauses`            | Checks for overly complex `with` statements  |
| `Credo.Check.Readability.WithSingleClause`    | Single-clause `with` should be `case`        |
| `Credo.Check.Refactor.Nesting`                | Deep nesting should be refactored            |
| `Credo.Check.Warning.ExpensiveEmptyEnumCheck` | Use `Enum.empty?/1` not `length(x) == 0`     |
| `Credo.Check.Readability.AliasOrder`          | Aliases should be alphabetized               |
| `Credo.Check.Readability.ModuleDoc`           | Modules should have `@moduledoc`             |
| `Credo.Check.Warning.Dbg`                     | No `dbg()` in production code                |
| `Credo.Check.Warning.IoInspect`               | No `IO.inspect` in production code           |
| `Credo.Check.Warning.MapGetUnsafePass`        | Unsafe `Map.get` with default that may raise |

#### Recommended to Enable

| Rule                                        | Description                          | Rationale                |
| ------------------------------------------- | ------------------------------------ | ------------------------ |
| `Credo.Check.Warning.UnsafeToAtom`          | Warns on `String.to_atom/1`          | Prevents memory leaks    |
| `Credo.Check.Readability.Specs`             | Public functions should have `@spec` | Improves documentation   |
| `Credo.Check.Design.SkipTestWithoutComment` | Skipped tests need explanation       | Prevents forgotten tests |
| `Credo.Check.Warning.LazyLogging`           | Use lazy logging for expensive args  | Performance              |

#### Credo Configuration

See `.credo.exs` for full configuration. Run with:

```bash
mix credo                         # Standard check
mix credo --min-priority=higher   # Stricter check
mix credo --strict                # All checks including low priority
mix credo diff origin/main        # Only check files changed on your branch
```

**Tip:** Use `mix credo diff origin/main` locally to only lint files you've changed. This speeds up feedback and avoids noise from pre-existing issues in unchanged files.

---

## 12. Elixir Anti-Patterns & Code Smells

This section consolidates guidance from the official [Elixir Anti-Patterns](https://hexdocs.pm/elixir/what-anti-patterns.html) documentation and the [Elixir Code Smells](https://github.com/lucasvegi/Elixir-Code-Smells) catalog.

### 12.1 Design-Related Anti-Patterns

#### Using Exceptions for Control Flow

**Problem**: Forcing callers to use `try/rescue` instead of pattern matching.

```elixir
# BAD - forces rescue
def fetch_user!(id) do
  case Repo.get(User, id) do
    nil -> raise "User not found"
    user -> user
  end
end

# Caller must use try/rescue
try do
  user = fetch_user!(id)
rescue
  RuntimeError -> handle_not_found()
end

# GOOD - return tagged tuples
def fetch_user(id) do
  case Repo.get(User, id) do
    nil -> {:error, :not_found}
    user -> {:ok, user}
  end
end

# Caller uses pattern matching
case fetch_user(id) do
  {:ok, user} -> handle_user(user)
  {:error, :not_found} -> handle_not_found()
end
```

#### Code Organization by Process

**Problem**: Using processes (GenServer, Agent) when modules and functions suffice.

```elixir
# BAD - unnecessary process for simple state
defmodule Counter do
  use Agent

  def start_link(initial), do: Agent.start_link(fn -> initial end, name: __MODULE__)
  def increment, do: Agent.update(__MODULE__, &(&1 + 1))
  def get, do: Agent.get(__MODULE__, & &1)
end

# GOOD - if state doesn't need to be shared across processes, use plain functions
defmodule Counter do
  def increment(count), do: count + 1
  def decrement(count), do: count - 1
end
```

#### Agent Obsession

**Problem**: Spreading Agent interactions across multiple modules.

```elixir
# BAD - Agent access scattered everywhere
defmodule ModuleA do
  def do_something do
    value = Agent.get(MyAgent, & &1)
    # ...
  end
end

defmodule ModuleB do
  def do_other do
    Agent.update(MyAgent, &(&1 + 1))
  end
end

# GOOD - encapsulate Agent access in one module
defmodule MyState do
  use Agent

  def start_link(initial), do: Agent.start_link(fn -> initial end, name: __MODULE__)
  def get, do: Agent.get(__MODULE__, & &1)
  def increment, do: Agent.update(__MODULE__, &(&1 + 1))
end
```

#### Unsupervised Processes

**Problem**: Long-running processes outside supervision trees.

```elixir
# BAD - unsupervised process
def start do
  spawn(fn -> loop() end)
end

# GOOD - supervised
def start_link(opts) do
  GenServer.start_link(__MODULE__, opts, name: __MODULE__)
end

# Add to supervision tree
children = [
  {MyWorker, []}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

#### Data Manipulation in Migrations

**Problem**: Mixing schema changes with data manipulation.

```elixir
# BAD - data manipulation in migration
def change do
  alter table(:users) do
    add :status, :string, default: "active"
  end

  # Don't do this in migrations
  execute "UPDATE users SET status = 'active' WHERE status IS NULL"
end

# GOOD - separate concerns
# Migration: schema only
def change do
  alter table(:users) do
    add :status, :string
  end
end

# Separate data migration task
defmodule Mix.Tasks.Backfill.UserStatus do
  def run(_) do
    # Data manipulation here
  end
end
```

### 12.2 Low-Level Anti-Patterns

#### Working with Invalid Data

**Problem**: Functions accept invalid parameters, causing confusing errors deep in call stacks.

```elixir
# BAD - no validation
def process_order(order) do
  # Crashes deep inside if order is nil or wrong type
  order.items |> Enum.map(&calculate_price/1)
end

# GOOD - validate early with guards or pattern matching
def process_order(%Order{items: items}) when is_list(items) do
  Enum.map(items, &calculate_price/1)
end

def process_order(_), do: {:error, :invalid_order}
```

#### Speculative Assumptions

**Problem**: Code makes assumptions and returns incorrect values instead of failing fast.

```elixir
# BAD - silent failure
def get_user_role(user) do
  user[:role] || :guest # Returns :guest for ANY missing/invalid data
end

# GOOD - explicit handling
def get_user_role(%{role: role}) when role in [:admin, :user, :guest], do: role
def get_user_role(%{role: nil}), do: {:error, :role_not_set}
def get_user_role(_), do: {:error, :invalid_user}
```

#### Dynamic Atom Creation

**Problem**: Creating atoms from user input exhausts the atom table (atoms are never garbage collected). See [2.1 Safe Atom Conversion](#21-safe-atom-conversion) for the solution pattern.

#### Unnecessary Macros

**Problem**: Using macros when functions would work.

```elixir
# BAD - macro for simple code
defmacro add(a, b) do
  quote do
    unquote(a) + unquote(b)
  end
end

# GOOD - just use a function
def add(a, b), do: a + b
```

### 12.3 Process-Related Anti-Patterns

#### Large Messages Between Processes

**Problem**: Sending large data structures as messages blocks the sender.

```elixir
# BAD - sending large data
def process_large_file(pid, file_path) do
  content = File.read!(file_path) # Could be huge
  send(pid, {:process, content})
end

# GOOD - send reference, let receiver fetch
def process_large_file(pid, file_path) do
  send(pid, {:process_file, file_path})
end

# Or use ETS for shared large data
def process_large_data(pid, data) do
  ref = make_ref()
  :ets.insert(:shared_data, {ref, data})
  send(pid, {:process, ref})
end
```

---

## 13. Elixir Deprecations

Avoid deprecated features. Key deprecations for our Elixir version:

### Deprecated in Recent Versions

| Feature                         | Replacement                    | Notes                       |
| ------------------------------- | ------------------------------ | --------------------------- |
| `unless` (any form)             | Swap branches in `if` — never introduce `unless` as a fix for `if !cond` | Soft-deprecated since v1.18 |
| `Logger.warn/2`                 | `Logger.warning/2`             | Since v1.15                 |
| Single-quoted charlists `'foo'` | `~c"foo"`                      | Since v1.17                 |
| `List.zip/1`                    | `Enum.zip/1`                   | Use Enum version            |
| `Regex.regex?/1`                | `Kernel.is_struct(x, Regex)`   | Since v1.15                 |
| `Exception.exception?/1`        | `Kernel.is_exception/1`        | Since v1.15                 |
| `left..right` in patterns       | `left..right//step`            | Patterns only, since v1.17  |
| `<%#` in EEx                    | `<%!--` or `<% #`              | Since v1.18                 |

---

## Contributing to This Document

This document should evolve with our codebase. To propose changes:

1. Open a PR with your proposed update
2. Include examples from actual code reviews
3. Reference the Credo rule if applicable
4. Get team consensus before merging

---

## References

- [Elixir Anti-Patterns](https://hexdocs.pm/elixir/what-anti-patterns.html)
- [Elixir Code Smells Catalog](https://github.com/lucasvegi/Elixir-Code-Smells)
- [Elixir Deprecations](https://hexdocs.pm/elixir/compatibility-and-deprecations.html)

---

*Last updated: 2026-05-08*

*Based on analysis of 2,042 PR review comments across subscriptions, xgps, and offerings repositories.*
