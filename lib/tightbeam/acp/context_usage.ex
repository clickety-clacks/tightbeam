defmodule Tightbeam.Acp.ContextUsage do
  @moduledoc """
  Session-bound observations from ACP usage updates.

  `size` is the receiver's reported context window, not a submission budget.
  It does not certify the tokenizer, response reserve, transport limit, or
  whether the receiver seeded its window from a heuristic. Consumers must not
  turn `size - used` into an authoritative remaining-input allowance.

  These observations belong to one resident adapter. Loading, changing its
  model, or submitting another prompt invalidates the previous observation;
  restarting the adapter starts with no observations.
  """

  alias Tightbeam.Model

  def observe(update, %Model{} = model, at) do
    case update do
      %{"used" => used, "size" => size}
      when is_integer(used) and used >= 0 and is_integer(size) and size > 0 and used <= size ->
        {:ok,
         %{
           used: used,
           size: size,
           model: model,
           observed_at: at,
           reported_model: reported_model(update),
           authority: :reported_context_usage
         }}

      _ ->
        {:error, :invalid_context_usage}
    end
  end

  def observe(_update, _unknown_model, _at), do: {:error, :model_readback_unavailable}

  def read(observation, model, at, max_age_ms) when is_integer(max_age_ms) and max_age_ms >= 0 do
    case observation do
      {:ok, %{model: ^model, observed_at: observed_at} = usage} ->
        age = at - observed_at

        if age >= 0 and age <= max_age_ms,
          do: {:ok, usage},
          else: {:error, :stale_context_usage}

      {:ok, _other_model} ->
        {:error, :stale_context_usage}

      {:error, _} = error ->
        error

      nil ->
        {:error, :context_usage_unavailable}
    end
  end

  def read(_observation, _model, _at, _invalid_age), do: {:error, :invalid_context_usage_age}

  defp reported_model(%{"_meta" => %{"_claude/model" => model}}) when is_binary(model),
    do: model

  defp reported_model(_update), do: nil
end
