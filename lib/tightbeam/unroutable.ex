defmodule Tightbeam.Unroutable do
  @moduledoc """
  Why a model selection cannot be routed, as a value, plus the one sentence that
  says it.

  Four mechanisms used to decide routability: the harness resolver,
  spawn/tune's `validate_catalog_model`, readiness's model column, and
  `ModelCatalog.member?`, whose `present?: false` meant three different things at
  once and so could not be reported honestly by anyone holding it. Each named its
  own causes, and one of them was false: a tiered model named with NO tier came
  back "not in the live catalog" while it sat in the live catalog. What was
  missing was the tier.

  So every cause is named as ITSELF here, once. Reporting "not in inventory" for a
  model that is plainly there sends the reader after the wrong thing, and a lesson
  learned by one mechanism (the codex `client_version` filter, below) reached only
  that one mechanism.

  This struct is a FACT about routability. The remedy voice belongs to the caller:
  boot readiness names the environment variable to set, adjudication names the
  flag. `message/1` says what is true, and each caller appends what to do about it.
  """

  alias Tightbeam.{Harness, Model, ModelCatalog}

  @typedoc """
  Why the selection could not be routed:

  - `:no_catalog` — the inventory consulted is not fresh, so it is evidence about
    nothing, least of all about this model;
  - `:family_absent` — the inventory IS fresh and nothing in it names this family
    and context variant;
  - `:needs_effort` — the model is there and tiered, and the selection names no
    tier, so it is incomplete;
  - `:effort_not_offered` — the model is there and does not offer the tier named;
  - `:ambiguous` — more than one harness could take the complete selection, so
    nothing but the caller can pick (a fleet-wide answer only).
  """
  @type cause :: :no_catalog | :family_absent | :needs_effort | :effort_not_offered | :ambiguous

  @typedoc "A live alternative bearing on the refusal, and the harness offering it."
  @type offer :: %{harness: String.t(), entry: ModelCatalog.entry()}

  @typedoc """
  `harness` is the harness asked about, or nil when the answer is about the whole
  fleet on that host. `health` is what each inventory consulted reported — one
  element for a single-harness answer, one per harness for a fleet answer.
  `offered` is what the operator could pick instead: for an effort cause, the
  entries naming this model; for `:family_absent`, the inventory that does not
  have it; for `:ambiguous`, the entries that could each take it.
  """
  @type t :: %__MODULE__{
          cause: cause(),
          host: String.t(),
          harness: String.t() | nil,
          selection: Model.t(),
          health: [{String.t(), ModelCatalog.health()}],
          offered: [offer()]
        }

  @enforce_keys [:cause, :host, :selection]
  defstruct [:cause, :host, :harness, :selection, health: [], offered: []]

  @doc """
  The wire code for a cause. `:needs_effort` is `invalid` — the selection is
  malformed, not unavailable — and a catalog that could not be read is
  `catalog_unavailable`, never a verdict on the model itself.
  """
  @spec code(t()) :: String.t()
  def code(%__MODULE__{cause: :no_catalog}), do: "catalog_unavailable"
  def code(%__MODULE__{cause: :family_absent}), do: "model_unavailable"
  def code(%__MODULE__{cause: :needs_effort}), do: "invalid"
  def code(%__MODULE__{cause: :effort_not_offered}), do: "model_unavailable"
  def code(%__MODULE__{cause: :ambiguous}), do: "ambiguous_ref"

  @doc """
  Every code a routability refusal can carry, so a caller deciding whether a
  denial is ABOUT ROUTING asks here instead of keeping its own list of strings
  that a new cause would silently fall out of.
  """
  @spec codes() :: [String.t()]
  def codes do
    [:no_catalog, :family_absent, :needs_effort, :effort_not_offered, :ambiguous]
    |> Enum.map(&code(%__MODULE__{cause: &1, host: "", selection: %Model{family: ""}}))
    |> Enum.uniq()
  end

  @doc "The one honest sentence for this refusal."
  @spec message(t()) :: String.t()
  def message(%__MODULE__{cause: :no_catalog} = unroutable) do
    "cannot route #{Model.describe(unroutable.selection)} on #{unroutable.host}: " <>
      Enum.map_join(unroutable.health, "; ", &catalog_story(&1, unroutable.host))
  end

  def message(%__MODULE__{cause: :family_absent, harness: nil} = unroutable) do
    "#{Model.to_ref(unroutable.selection)} is not in a fresh harness inventory on " <>
      "#{unroutable.host}" <> offered_hint(unroutable)
  end

  # Opens on the SELECTION, like every other cause, so a caller can put its own
  # subject in front of it ("default model …") without the sentence saying
  # "model" twice.
  def message(%__MODULE__{cause: :family_absent} = unroutable) do
    "#{inspect(Model.describe(unroutable.selection))} is not offered by " <>
      "#{unroutable.harness} on host #{unroutable.host}" <> offered_hint(unroutable)
  end

  def message(%__MODULE__{cause: :needs_effort, harness: nil} = unroutable) do
    "#{Model.to_ref(unroutable.selection)} has effort tiers on " <>
      "#{harness_tiers(unroutable)}; the selection must name one"
  end

  def message(%__MODULE__{cause: :needs_effort} = unroutable) do
    "#{Model.to_ref(unroutable.selection)} has effort tiers on #{unroutable.harness} on host " <>
      "#{unroutable.host} (#{tiers(unroutable)}); the selection must name one"
  end

  # A model offered with NO tiers refuses one, which is a different sentence from
  # a model that offers tiers and not this one. Both are the entry's call.
  def message(%__MODULE__{cause: :effort_not_offered, offered: offered} = unroutable) do
    if offered != [] and Enum.all?(offered, &(&1.entry.efforts == [])) do
      "#{Model.to_ref(unroutable.selection)} has no effort tiers on #{scope(unroutable)}, so " <>
        "the selection must not name one (it names #{inspect(unroutable.selection.effort)})"
    else
      "#{Model.to_ref(unroutable.selection)} does not offer effort " <>
        "#{inspect(unroutable.selection.effort)} on #{scope(unroutable)}" <>
        tiers_hint(unroutable)
    end
  end

  # No "name the harness" remedy: a selection IS a model, with no harness field,
  # and every caller of the fleet answer hands one straight in. Telling an
  # operator to do something the API cannot express is the same failure as naming
  # the wrong cause.
  def message(%__MODULE__{cause: :ambiguous} = unroutable) do
    "#{Model.to_ref(unroutable.selection)} appears in more than one fresh harness inventory " <>
      "on #{unroutable.host} (#{Enum.map_join(unroutable.offered, ", ", & &1.harness)}), so " <>
      "nothing can choose between them; name a model only one of them offers"
  end

  defp catalog_story({harness, {:unavailable, {:needs_onboarding, reason}}}, host) do
    provider = Harness.parse!(harness).credential_provider()

    "no #{harness} model catalog there, because #{provider} has no usable credential on " <>
      "#{host} (#{inspect(reason)}). A catalog is derived on the host that runs the turn, so " <>
      "this is #{host}'s grant to fix; run " <>
      "#{Tightbeam.Credentials.onboard_command(provider)} on #{host}"
  end

  # The codex models endpoint filters by the caller's client_version and says
  # nothing about it: too old a binary and every model is dropped, with a 200.
  # Blaming the account would send the operator to re-onboard a grant that was
  # never the problem. This lesson existed in exactly ONE of the four mechanisms;
  # it lives here now, so the rest inherit it.
  defp catalog_story(
         {harness, {:unavailable, {:empty_catalog_for_client_version, version}}},
         host
       ) do
    "the provider returned an EMPTY model list for client_version #{inspect(version)}, which " <>
      "is the #{harness} binary's own version on #{host}. The credential is not implicated; " <>
      "upgrade #{harness} on #{host}"
  end

  # A stale inventory is not evidence that a model is absent — it is evidence of
  # nothing — so it is reported as the inventory's fault, never as the model's.
  defp catalog_story({harness, :stale}, host) do
    "the #{harness} catalog on #{host} is STALE, not re-derived within its TTL, so it says " <>
      "nothing about this model"
  end

  defp catalog_story({harness, health}, host) do
    "no usable #{harness} model catalog on #{host} (#{inspect(health)})"
  end

  # A refusal that names only the rejected value makes the operator guess. The
  # catalog is already in hand, so say what IS offered.
  defp offered_hint(%__MODULE__{offered: []}), do: ""

  defp offered_hint(%__MODULE__{harness: nil} = unroutable) do
    "; offered: " <>
      (unroutable.offered
       |> Enum.map(&"#{&1.harness}: #{ModelCatalog.describe_entry(&1.entry)}")
       |> Enum.sort()
       |> Enum.join(", "))
  end

  defp offered_hint(%__MODULE__{} = unroutable) do
    "; offered: " <>
      (unroutable.offered
       |> Enum.map(&ModelCatalog.describe_entry(&1.entry))
       |> Enum.sort()
       |> Enum.join(", "))
  end

  defp scope(%__MODULE__{harness: nil, host: host}), do: "any fresh harness on #{host}"
  defp scope(%__MODULE__{harness: harness, host: host}), do: "#{harness} on host #{host}"

  defp tiers_hint(%__MODULE__{offered: []}), do: ""

  defp tiers_hint(%__MODULE__{harness: nil} = unroutable),
    do: "; offered: " <> harness_tiers(unroutable)

  defp tiers_hint(unroutable), do: "; offered: " <> tiers(unroutable)

  defp harness_tiers(%__MODULE__{offered: offered}),
    do: Enum.map_join(offered, ", ", &"#{&1.harness} (#{efforts(&1.entry)})")

  defp tiers(%__MODULE__{offered: offered}),
    do: Enum.map_join(offered, ", ", &efforts(&1.entry))

  defp efforts(%{efforts: []}), do: "no tiers"
  defp efforts(%{efforts: efforts}), do: Enum.join(efforts, "|")
end
