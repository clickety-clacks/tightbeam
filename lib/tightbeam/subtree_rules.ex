defmodule Tightbeam.SubtreeRules do
  @moduledoc false

  @doc """
  Plain-text `contains`, shared by statutes and reactions.

  Either side may be a string or a list of strings. The check holds when any
  text on the left contains any text on the right, ignoring case. Values that
  are not text, and empty needles, never match. No pattern syntax is
  interpreted.
  """
  def contains?(haystack, needles) do
    needles = needles |> texts() |> Enum.reject(&(&1 == ""))

    needles != [] and
      Enum.any?(texts(haystack), fn text -> Enum.any?(needles, &String.contains?(text, &1)) end)
  end

  defp texts(value) when is_binary(value), do: [fold(value)]

  defp texts(values) when is_list(values),
    do: for(value <- values, is_binary(value), do: fold(value))

  defp texts(_), do: []

  defp fold(text), do: String.downcase(text)
end
