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
    snapshot = snapshot()
    on_exit(fn -> restore(snapshot) end)
    :ok
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
