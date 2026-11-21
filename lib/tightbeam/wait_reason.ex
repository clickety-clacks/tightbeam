defmodule Tightbeam.WaitReason do
  @moduledoc false

  @limit 140

  def validate(reason, option) do
    cond do
      is_nil(reason) or (is_binary(reason) and String.trim(reason) == "") ->
        failure("missing_reason", "Recording a wait requires a nonblank #{option}.")

      not is_binary(reason) or Regex.match?(~r/\R/u, reason) ->
        failure("invalid_wait_reason", "#{option} must be a single line of text.")

      String.length(reason) > @limit ->
        failure("wait_reason_too_long", "#{option} must be at most #{@limit} characters.")

      true ->
        :ok
    end
  end

  defp failure(code, message), do: {:error, %{code: code, message: message}}
end
