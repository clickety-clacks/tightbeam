defmodule Tightbeam.ObligationFacts do
  @moduledoc """
  Registration boundary for facts that may participate in statutes, remedies,
  prods, and turn-end sweeps.
  """

  @registrations [{"subagent_", :observability_only}]

  @doc "Register a referenced fact for obligation-producing rule paths."
  @spec register!(String.t()) :: :ok
  def register!(fact) do
    case classification(fact) do
      :observability_only ->
        raise ArgumentError,
              "fact #{inspect(fact)} is observability-only and cannot predicate an obligation"

      :obligation ->
        :ok
    end
  end

  @doc "The registered obligation classification for a fact name."
  @spec classification(String.t()) :: :observability_only | :obligation
  def classification(fact) do
    Enum.find_value(@registrations, :obligation, fn {prefix, classification} ->
      if String.starts_with?(fact, prefix), do: classification
    end)
  end
end
