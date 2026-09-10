defmodule Tightbeam.Identity.IncludeError do
  @moduledoc "A typed refusal for an invalid served-identity include graph."

  defexception [
    :message,
    :cause,
    :origin,
    :path,
    :line,
    :chain,
    :paths,
    :tree_fingerprint,
    :expected_prior
  ]

  @impl true
  def exception(fields) do
    cause = Keyword.fetch!(fields, :cause)
    origin = Keyword.fetch!(fields, :origin)
    path = Keyword.get(fields, :path)
    line = Keyword.get(fields, :line)
    chain = Keyword.get(fields, :chain, [])
    paths = Keyword.get(fields, :paths, [])

    location =
      [path, line && "line #{line}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(":")

    detail =
      [
        "identity_include_invalid",
        "cause=#{cause}",
        "origin=#{origin}",
        if(location == "", do: nil, else: "at=#{location}"),
        if(chain == [], do: nil, else: "chain=#{Enum.join(chain, " -> ")}"),
        if(paths == [], do: nil, else: "paths=#{Enum.join(paths, ", ")}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    %__MODULE__{
      message: detail,
      cause: cause,
      origin: origin,
      path: path,
      line: line,
      chain: chain,
      paths: paths
    }
  end

  @doc false
  def with_candidate(%__MODULE__{} = error, fingerprint, expected_prior) do
    %{error | tree_fingerprint: fingerprint, expected_prior: expected_prior}
  end
end
