defmodule Tightbeam.Model do
  @moduledoc """
  A model identity, as fields. This is the only shape Tightbeam passes around
  internally; every packed string is a LINE FORMAT owned by the seam that needs
  one line of text.

  The fields answer different questions and are never packed into one slot:

    * `family` — which model, the vendor's undecorated name (`claude-fable-5`,
      `gpt-5.6-sol`).
    * `context` — the vendor's context-window variant when it offers more than
      one (`1m`). `nil` is the model's default window.
    * `effort` — reasoning level, TIGHTBEAM's vocabulary (`low`…`max`). `nil`
      when the model has no effort tiers.

  Why this module exists: Anthropic spells a context variant `name[1m]` and
  Tightbeam used to spell a reasoning level `name[high]`. The syntaxes matched,
  so the catalog read the vendor's suffix as ours — it dropped `[1m]`, and the
  1M-context model silently ceased to exist. Family and context are the
  VENDOR's business; effort is OURS; nothing may put them in the same slot
  again.

  `to_ref/1` and `parse_ref/1` are the vendor line format both current harnesses
  use: the identity WITHOUT effort, because effort travels as its own config
  option at every boundary that takes one. A harness whose vendor spells
  variants differently renders at its own seam instead.
  """

  @enforce_keys [:family]
  defstruct [:family, :effort, :context]

  @type t :: %__MODULE__{
          family: String.t(),
          effort: String.t() | nil,
          context: String.t() | nil
        }

  @doc """
  Build an identity from a family and optional `:effort` / `:context`.

      iex> Tightbeam.Model.new("gpt-5.6-sol", effort: "medium")
      %Tightbeam.Model{family: "gpt-5.6-sol", effort: "medium", context: nil}
  """
  @spec new(String.t(), keyword()) :: t()
  def new(family, opts \\ []) when is_binary(family) do
    %__MODULE__{
      family: family,
      effort: blank_to_nil(Keyword.get(opts, :effort)),
      context: blank_to_nil(Keyword.get(opts, :context))
    }
  end

  @doc """
  Parse a vendor identifier into family and context. Effort is never read from
  a vendor identifier — the bracket is the vendor's context variant.

      iex> Tightbeam.Model.parse_ref("claude-fable-5[1m]")
      %Tightbeam.Model{family: "claude-fable-5", effort: nil, context: "1m"}

      iex> Tightbeam.Model.parse_ref("gpt-5.6-sol")
      %Tightbeam.Model{family: "gpt-5.6-sol", effort: nil, context: nil}
  """
  @spec parse_ref(String.t()) :: t()
  def parse_ref(ref) when is_binary(ref) do
    case Regex.run(~r/^(.*?)\[(.*?)\]$/, ref) do
      [_, family, context] -> new(family, context: context)
      _ -> new(ref)
    end
  end

  @doc """
  Render the vendor identifier: family, plus the context variant when there is
  one. Effort is NOT rendered here — it crosses as its own field.

      iex> Tightbeam.Model.to_ref(Tightbeam.Model.new("claude-fable-5", context: "1m", effort: "high"))
      "claude-fable-5[1m]"
  """
  @spec to_ref(t()) :: String.t()
  def to_ref(%__MODULE__{family: family, context: nil}), do: family
  def to_ref(%__MODULE__{family: family, context: context}), do: "#{family}[#{context}]"

  @doc """
  A human-readable line naming every field, for prose read by an operator or an
  agent (adjudication briefs, tombstones). Unambiguous on purpose: nothing here
  is parsed back.

      iex> Tightbeam.Model.describe(Tightbeam.Model.new("claude-fable-5", context: "1m", effort: "high"))
      "claude-fable-5 (context 1m, effort high)"
  """
  @spec describe(t() | nil) :: String.t()
  def describe(nil), do: "unknown"

  def describe(%__MODULE__{} = model) do
    qualifiers =
      [
        model.context && "context #{model.context}",
        model.effort && "effort #{model.effort}"
      ]
      |> Enum.reject(&is_nil/1)

    case qualifiers do
      [] -> model.family
      parts -> "#{model.family} (#{Enum.join(parts, ", ")})"
    end
  end

  @doc """
  The model fields a caller NAMED — and ONLY those. A field the caller omitted
  is an ABSENT KEY, never a key holding `nil`.

  That distinction is load-bearing, not stylistic. `context: nil` is a real
  selection: it means the model's default window, which is a different request
  from "the caller said nothing about context". Collapsing them into one `nil`
  is how selecting the default-window row silently kept a session on the 1M
  variant — the completing code read the explicit nil as an omission and
  inherited over it.

  A partial selection is not an identity either — `--effort high` alone says
  something real but does not say which model — so this does not build a
  `%Model{}`. The caller completes it against a default.
  """
  @spec named_fields(map()) :: %{optional(:family | :effort | :context) => String.t() | nil}
  def named_fields(params) when is_map(params) do
    %{}
    |> put_named(:family, named_family(params))
    |> put_named(:effort, named(params, :effort))
    |> put_named(:context, named(params, :context))
  end

  # PRESENCE, not value. Reading the params with `Map.get` collapses "the caller
  # omitted this" into "the caller said nil" — the very distinction this
  # function exists to carry — so the two are kept apart all the way through.
  defp put_named(fields, _key, :absent), do: fields
  defp put_named(fields, key, {:present, value}), do: Map.put(fields, key, value)

  defp named(params, key) do
    case fetch_either(params, key) do
      :error -> :absent
      {:ok, value} -> {:present, blank_to_nil(value)}
    end
  end

  # The family is the ONE field with no meaningful explicit nil: `context: nil`
  # is the vendor's default window and `effort: nil` is "no tier", both real
  # answers, but there is no model you select by declining to name one. So an
  # explicitly nil family IS absence, and says so here rather than leaving a
  # `%Model{family: nil}` to be built downstream.
  defp named_family(params) do
    case named(params, :model) do
      {:present, nil} -> named(params, :family)
      :absent -> named(params, :family)
      present -> present
    end
  end

  defp fetch_either(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(params, Atom.to_string(key))
    end
  end

  @doc """
  Read a COMPLETE identity out of a map with string or atom keys. `nil` when no
  family is present — for a caller that requires one and refuses without it.
  """
  @spec from_params(map()) :: t() | nil
  def from_params(params) when is_map(params) do
    case field(params, :model) || field(params, :family) do
      family when is_binary(family) and family != "" ->
        new(family, effort: field(params, :effort), context: field(params, :context))

      _ ->
        nil
    end
  end

  defp field(params, key) do
    case fetch_either(params, key) do
      {:ok, value} -> blank_to_nil(value)
      :error -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
