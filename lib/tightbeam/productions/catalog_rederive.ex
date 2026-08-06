defmodule Tightbeam.Productions.CatalogRederive do
  @moduledoc """
  The catalog re-derivation production (spec first-boot-journey-v1 O4/I5;
  production-machine-v1): the first non-session-wake consumer of the
  condition-fact stream (N2). It RECOGNIZES the `credential-present` fact from
  durable state and re-derives the affected catalog — the trigger is the fact,
  recognized by a named production, never `credentials.ex` (or the gateway)
  reaching into `ModelCatalog` directly.

  Built the same way `Tightbeam.Productions.Bubble` is, and for the same reason:
  a production that acts on durable working memory does NOT use
  `Wakes.fire_matching` (that dispatches to SESSIONS, not GenServers). It is a
  named rule — a declared LHS over durable state (`catalog_rederive_matches?/2`)
  and a procedural RHS (`rederive/3`) — triggered by a wired POST-COMMIT
  RECOGNITION HOOK (`recognize/3`, called at the onboarding-commit site with the
  filed fact's id after the transaction commits, exactly as the lane calls
  `Bubble.recognize_terminal/2` with a committed turn's seq). The subject
  `{host, provider}` is read FROM the fact, not passed in — the fact is the
  source, not a decoration.

  A PLAIN module, not a GenServer: with the existing TTL sweep as the backstop
  (I5) there is no cursor and thus no sweeper process. Simpler than Bubble in
  two more ways: the RHS is idempotent (a catalog re-derivation is a pure re-read
  of world-state), so there is no lineage walk and no exactly-once dedup —
  recognition may run twice for free. A dropped edge self-heals when the catalog
  is next read (`ModelCatalog`'s read-triggered TTL re-derivation), which is
  exactly when it matters — a spawn, turn, or readiness consult; the wired cast
  is what meets AC4's "immediate".
  """

  alias Tightbeam.{DB, ModelCatalog}

  require Logger

  @kind "credential-present"

  @doc """
  Post-commit recognition site for a filed `credential-present` fact, named by
  its id — mirrors `Bubble.recognize_terminal/2`. The credential code files the
  fact and calls this; the production is the only thing that pokes the catalog.
  Best-effort and crash-isolated: the fact is already durable and the TTL sweep
  is the backstop, so a recognition failure is logged, never raised into the
  onboarding commit it runs after.
  """
  @spec recognize(DB.server(), GenServer.server(), integer()) :: :ok
  def recognize(db, catalog, fact_id) do
    case catalog_rederive_matches?(db, fact_id) do
      {:ok, host, provider} -> rederive(catalog, host, provider)
      :no_match -> :ok
    end

    :ok
  rescue
    error ->
      Logger.error(
        "catalog re-derivation recognition of fact #{fact_id} crashed and was contained: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  @doc """
  The production's LHS, in one function over durable state only
  (production-machine-v1 §Legibility): the fact named by `fact_id` is a
  `credential-present` fact, and its `<host>:<provider>` scope parses. Returns
  the recognized `{host, provider}` or `:no_match`. `credential-present` is an
  OCCURRENCE fact (a transition marker, not a standing assert/retract pair), so
  recognition is per filed occurrence, never a `standing?/3` question.
  """
  @spec catalog_rederive_matches?(DB.server(), integer()) ::
          {:ok, String.t(), atom()} | :no_match
  def catalog_rederive_matches?(db, fact_id) do
    case DB.query(db, "SELECT scope FROM condition_facts WHERE id = ?1 AND kind = ?2", [
           fact_id,
           @kind
         ]) do
      {:ok, [[scope]]} -> parse_scope(scope)
      _ -> :no_match
    end
  end

  # RHS. Re-derive the catalog for the provider whose credential just landed. The
  # catalog is a CONSUMER poked here — it re-reads world-state as the authority
  # (I5: the fact only says "re-recognize now"); which `{host, harness}` keys
  # that touches is the catalog's own provider→harness mapping. A cast, so the
  # hook never blocks derivation (I4).
  defp rederive(catalog, host, provider) do
    ModelCatalog.credential_present(host, provider, catalog)
  end

  # Scope is "<host>:<provider>", written by the one filing site. A scope that
  # does not parse to a known provider is DIRT — logged and declined, never poked
  # with a guessed value.
  defp parse_scope(scope) when is_binary(scope) do
    case String.split(scope, ":", parts: 2) do
      [host, provider] when host != "" and provider != "" ->
        try do
          {:ok, host, String.to_existing_atom(provider)}
        rescue
          ArgumentError -> unparseable(scope)
        end

      _ ->
        unparseable(scope)
    end
  end

  defp parse_scope(scope), do: unparseable(scope)

  defp unparseable(scope) do
    Logger.error("credential-present fact has an unrecognized scope #{inspect(scope)}; declined")
    :no_match
  end
end
