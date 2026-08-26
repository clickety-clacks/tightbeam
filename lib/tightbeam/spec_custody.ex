defmodule Tightbeam.SpecCustody do
  @moduledoc """
  Immutable, content-addressed custody for ruling text named by a work item's
  existing `specRefName` and `specRefSha256` fields.

  A syntactically valid digest is metadata. It becomes resolved only when this
  table holds the exact bytes whose SHA-256 is that digest. Re-recording the
  same digest and bytes is a replay. The work-item name remains history on the
  work item; custody is keyed by the digest, so a renamed path does not make the
  same ruling bytes disappear.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS spec_custody (
    sha256     TEXT PRIMARY KEY
               CHECK(length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    rulingText TEXT NOT NULL CHECK(length(trim(rulingText)) > 0),
    recordedAt INTEGER NOT NULL
  );
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc false
  @spec admit_in_txn(Txn.t(), String.t() | nil, String.t() | nil, term()) ::
          {:ok, boolean()} | map()
  def admit_in_txn(_txn, nil, nil, nil), do: {:ok, false}
  def admit_in_txn(_txn, _name, _sha256, nil), do: {:ok, false}

  def admit_in_txn(%Txn{} = txn, name, sha256, ruling_text)
      when is_binary(name) and is_binary(sha256) and is_binary(ruling_text) do
    cond do
      String.trim(ruling_text) == "" ->
        admission_error(
          "invalid_spec_ruling",
          "spec ruling text must be non-blank"
        )

      digest(ruling_text) != sha256 ->
        admission_error(
          "spec_digest_mismatch",
          "spec ruling text does not match specRefSha256"
        )

      true ->
        admit_verified_in_txn(txn, sha256, ruling_text)
    end
  end

  def admit_in_txn(_txn, _name, _sha256, _ruling_text) do
    admission_error(
      "invalid_spec_ruling",
      "specRefText requires a complete spec reference and text bytes"
    )
  end

  @doc false
  def resolve(%Txn{} = txn, _name, sha256),
    do: resolve_rows(Txn.q(txn, lookup_sql(), [sha256]), sha256)

  def resolve(db, _name, sha256) do
    {:ok, rows} = DB.query(db, lookup_sql(), [sha256])
    resolve_rows(rows, sha256)
  end

  def resolution(source, name, sha256) do
    source
    |> authorized_resolution(name, sha256)
    |> Map.delete(:rulingText)
  end

  # Callers of this detailed projection must establish authorization before
  # exposing it. Public work-item and work-state projections use resolution/3.
  @doc false
  def authorized_resolution(_source, nil, nil), do: %{status: "none"}

  def authorized_resolution(source, name, sha256) do
    case resolve(source, name, sha256) do
      {:ok, ruling_text} ->
        %{status: "resolved", rulingText: ruling_text}

      {:error, reason} ->
        %{status: "unresolved", reason: reason}
    end
  end

  defp admit_verified_in_txn(txn, sha256, ruling_text) do
    case Txn.q(txn, lookup_sql(), [sha256]) do
      [] ->
        Txn.q(
          txn,
          "INSERT INTO spec_custody (sha256, rulingText, recordedAt) VALUES (?1, ?2, ?3)",
          [sha256, ruling_text, System.system_time(:millisecond)]
        )

        {:ok, true}

      [[^ruling_text]] ->
        {:ok, false}

      [[_existing_text]] ->
        admission_error(
          "spec_custody_conflict",
          "specRefSha256 already has different canonical custody"
        )
    end
  end

  defp resolve_rows([], _sha256), do: {:error, "missing_custody"}

  defp resolve_rows([[ruling_text]], sha256) do
    if digest(ruling_text) == sha256,
      do: {:ok, ruling_text},
      else: {:error, "custody_digest_mismatch"}
  end

  defp lookup_sql, do: "SELECT rulingText FROM spec_custody WHERE sha256 = ?1"

  defp digest(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp admission_error(code, message), do: %{code: code, message: message}
end
