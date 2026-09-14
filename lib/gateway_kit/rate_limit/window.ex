defmodule GatewayKit.RateLimit.Window do
  @moduledoc """
  Windowed counters in ETS, shared by the rate-limit strategies.

  Rows are `{{key, index}, count, expires_at_ms}`. `index` is the window number
  (`div(now_ms, window_ms)`), so every caller agrees on window boundaries without coordinating.

  Increments are single atomic `:ets.update_counter/4` calls: no read-modify-write, no lock, no
  lost updates when many connection processes hit the same bucket at once. Rows carry an expiry
  two windows after they start — long enough for the sliding-window strategy to still read the
  previous window — so `GatewayKit.Store` can sweep them without knowing any policy's window size.
  """

  @type key :: term()
  @type index :: integer()

  @doc "The window number `now_ms` falls in."
  @spec index(integer(), pos_integer()) :: index()
  def index(now_ms, window_ms), do: div(now_ms, window_ms)

  @doc "The instant window `index` starts."
  @spec starts_at(index(), pos_integer()) :: integer()
  def starts_at(index, window_ms), do: index * window_ms

  @doc "Atomically increments the counter for `key` in window `index`; returns the new count."
  @spec increment(atom(), key(), index(), pos_integer()) :: pos_integer()
  def increment(table, key, index, window_ms) do
    expires_at = (index + 2) * window_ms
    :ets.update_counter(table, {key, index}, {2, 1}, {{key, index}, 0, expires_at})
  end

  @doc "Atomically decrements the counter (never below zero); returns the new count."
  @spec decrement(atom(), key(), index(), pos_integer()) :: non_neg_integer()
  def decrement(table, key, index, window_ms) do
    expires_at = (index + 2) * window_ms
    :ets.update_counter(table, {key, index}, {2, -1, 0, 0}, {{key, index}, 0, expires_at})
  end

  @doc "The current count for `key` in window `index` (0 when absent)."
  @spec count(atom(), key(), index()) :: non_neg_integer()
  def count(table, key, index) do
    case :ets.lookup(table, {key, index}) do
      [{_key, count, _expires_at}] -> count
      [] -> 0
    end
  end
end
