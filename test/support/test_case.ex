defmodule Tightbeam.TestCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  @persistent_keys [
    Tightbeam.Rules,
    Tightbeam.Rails,
    Tightbeam.Archetypes,
    Tightbeam.Producers,
    {Tightbeam.Application, :draining}
  ]

  setup do
    assert_hermetic_tmp!()
    snapshot = snapshot()
    on_exit(fn -> restore(snapshot) end)
    :ok
  end

  # Per-test scratch dirs are named with System.unique_integer/1, which is unique
  # only within one BEAM. They stay collision-free because config/test.exs points
  # TMPDIR at a per-BEAM root. If that root goes missing, System.tmp_dir!/0 falls
  # back to the shared /tmp, concurrent `mix test` processes mint the same scratch
  # names, and each one's rm_rf cleanup deletes fixtures another is still using —
  # which reads as a passing assertion over an absent file, not as a failure.
  defp assert_hermetic_tmp! do
    suite_tmp = Application.fetch_env!(:tightbeam, :test_suite_tmp)
    actual = System.tmp_dir!()

    if actual != suite_tmp do
      raise "test tmp root is not hermetic: expected #{suite_tmp}, got #{actual}"
    end
  end

  @doc false
  def snapshot do
    %{
      application: Map.new(Application.get_all_env(:tightbeam)),
      persistent: Map.new(@persistent_keys, &{&1, persistent_value(&1)}),
      system: System.get_env()
    }
  end

  @doc false
  def restore(snapshot) do
    restore_application(snapshot.application)
    restore_persistent(snapshot.persistent)
    restore_system(snapshot.system)
  end

  defp persistent_value(key) do
    sentinel = make_ref()

    case :persistent_term.get(key, sentinel) do
      ^sentinel -> :absent
      value -> {:present, value}
    end
  end

  defp restore_application(expected) do
    current = Map.new(Application.get_all_env(:tightbeam))

    expected
    |> Map.keys()
    |> Kernel.++(Map.keys(current))
    |> Enum.uniq()
    |> Enum.each(fn key ->
      case {Map.fetch(expected, key), Map.fetch(current, key)} do
        {{:ok, value}, {:ok, value}} -> :ok
        {{:ok, value}, _} -> Application.put_env(:tightbeam, key, value)
        {:error, {:ok, _value}} -> Application.delete_env(:tightbeam, key)
        {:error, :error} -> :ok
      end
    end)
  end

  defp restore_persistent(expected) do
    Enum.each(expected, fn {key, expected_value} ->
      case {expected_value, persistent_value(key)} do
        {value, value} -> :ok
        {:absent, _current} -> :persistent_term.erase(key)
        {{:present, value}, _current} -> :persistent_term.put(key, value)
      end
    end)
  end

  defp restore_system(expected) do
    current = System.get_env()

    expected
    |> Map.keys()
    |> Kernel.++(Map.keys(current))
    |> Enum.uniq()
    |> Enum.each(fn key ->
      case {Map.fetch(expected, key), Map.fetch(current, key)} do
        {{:ok, value}, {:ok, value}} -> :ok
        {{:ok, value}, _} -> System.put_env(key, value)
        {:error, {:ok, _value}} -> System.delete_env(key)
        {:error, :error} -> :ok
      end
    end)
  end
end
