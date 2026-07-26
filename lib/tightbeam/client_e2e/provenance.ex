defmodule Tightbeam.ClientE2E.Provenance do
  @moduledoc """
  What a scorecard's header means when it names a commit.

  A run document says "this is what the code did". That claim is only checkable
  if the sha in its header identifies the tree that produced it — a scorecard
  from an uncommitted tree cannot be reproduced from its own header, and a
  cross-review caught exactly that: a PASS credited to a sha whose tree did not
  yet contain the logic it credited.

  So `stamp/1` returns:

  - `{:clean, sha}` — the worktree matches HEAD; the sha is the whole story.
  - `{:dirty, sha, fingerprint, listing}` — it does not, with a fingerprint of
    what differs. The caller decides whether to refuse (the default) or run and
    stamp the scorecard DIRTY.

  The fingerprint covers UNTRACKED files by content, not just by name.
  `git diff HEAD` omits untracked files entirely, so a driver source that exists
  only as an untracked file would fingerprint identically no matter what it
  said — two different runs, one provenance. Hashing the porcelain listing, the
  tracked diff, and each untracked file's bytes closes that.

  This lives in `lib` rather than in the runner script on purpose: it is the
  part of provenance a test can hold, and both review rounds found their
  provenance defects in code that no test could reach.
  """

  @type stamp :: {:clean, String.t()} | {:dirty, String.t(), String.t(), String.t()}

  @doc "The provenance of `repo_root`'s worktree (defaults to the cwd)."
  @spec stamp(String.t() | nil) :: stamp()
  def stamp(repo_root \\ nil) do
    sha = git(repo_root, ["rev-parse", "--short", "HEAD"]) |> String.trim()
    sha = if sha == "", do: "unknown", else: sha
    listing = git(repo_root, ["status", "--porcelain"])

    if String.trim(listing) == "" do
      {:clean, sha}
    else
      {:dirty, sha, fingerprint(repo_root, listing), listing}
    end
  end

  @doc "How the stamp appears in a scorecard header."
  @spec to_header(stamp()) :: String.t()
  def to_header({:clean, sha}), do: sha
  def to_header({:dirty, sha, fingerprint, _listing}), do: "#{sha} DIRTY (diff #{fingerprint})"

  @doc """
  A 12-hex digest of everything that makes this worktree differ from HEAD: the
  porcelain listing, the tracked diff, and the CONTENT of every untracked file.
  """
  @spec fingerprint(String.t() | nil, String.t()) :: String.t()
  def fingerprint(repo_root, listing) do
    diff = git(repo_root, ["diff", "HEAD"])

    untracked =
      listing
      |> untracked_paths()
      |> Enum.map_join("\n", fn path ->
        full = if repo_root, do: Path.join(repo_root, path), else: path

        case File.read(full) do
          {:ok, bytes} -> path <> ":" <> hex(bytes)
          _ -> path <> ":unreadable"
        end
      end)

    hex(listing <> diff <> untracked) |> binary_part(0, 12)
  end

  @doc "Untracked paths named by a `git status --porcelain` listing."
  @spec untracked_paths(String.t()) :: [String.t()]
  def untracked_paths(listing) do
    listing
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "?? "))
    |> Enum.map(&String.replace_prefix(&1, "?? ", ""))
    |> Enum.sort()
  end

  defp git(nil, args), do: elem(System.cmd("git", args, stderr_to_stdout: true), 0)
  defp git(root, args), do: elem(System.cmd("git", args, cd: root, stderr_to_stdout: true), 0)

  defp hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
