defmodule Tightbeam.GithubAuth do
  @moduledoc """
  The gateway-side brain for the GitHub host capability: where the banked
  credential lives, which hostnames count as GitHub, and whether a host is
  actually live — judged against the store agents read, never the operator's
  ambient one. See docs/GITHUB-AUTH.md for the capability model.

  This deliberately mirrors the model-provider split: the Rust CLI owns the
  ceremony (`tightbeam onboard github`) and the agent-side guard
  (`tightbeam github-auth-check`), because those must run where the gateway
  does not exist — agent shells, satellites. Everything gateway-resident
  (doctor, placement, future readiness gates) asks this module instead of
  growing its own opinion. The two sides are pinned to the same spec and the
  same probe sequence; neither consults the other at runtime.
  """

  @doc """
  The banked GitHub CLI config dir for a base dir. One shared dir, not
  per-hostname: GH_CONFIG_DIR is single-valued while gh's hosts.yml natively
  holds every hostname.
  """
  @spec config_dir(String.t()) :: String.t()
  def config_dir(base_dir), do: Path.join([base_dir, "auth", "github", "gh"])

  @doc """
  The environment every GitHub probe and every agent process gets.
  Unconditional, banked or not: an absent dir must probe as needs_onboarding,
  never as whatever the operator shell's ambient gh config (or the login
  keychain, unreadable from daemon-descended processes) can reach.
  """
  @spec env(String.t()) :: [{String.t(), String.t()}]
  def env(base_dir), do: [{"GH_CONFIG_DIR", config_dir(base_dir)}]

  @doc """
  The GitHub hostname of a remote URL, or nil when the remote is not a
  recognized GitHub host. Currently github.com and *.github.com only — GHE
  hostnames onboard and operate through gh's native multi-host support, but
  are not yet recognized here or by the shell guard.
  """
  @spec hostname(term()) :: String.t() | nil
  def hostname(remote_url) when is_binary(remote_url) do
    cond do
      String.starts_with?(remote_url, "https://") or String.starts_with?(remote_url, "http://") ->
        remote_url |> URI.parse() |> Map.get(:host) |> known_host()

      String.starts_with?(remote_url, "ssh://") ->
        remote_url |> URI.parse() |> Map.get(:host) |> known_host()

      String.starts_with?(remote_url, "git@") ->
        case String.split(remote_url, ["@", ":"], parts: 3) do
          ["git", host, _path] -> known_host(host)
          _ -> nil
        end

      true ->
        nil
    end
  end

  def hostname(_remote_url), do: nil

  @doc """
  The live readiness probe: gh auth, gh api identity, and git ls-remote for
  the given remote, all run with the banked GH_CONFIG_DIR. Returns
  `{:ok, %{account: name, git_protocol: protocol}}` or
  `{:error, state, scrubbed_detail}` with the spec's state names.
  """
  @spec probe(String.t(), String.t(), String.t()) ::
          {:ok, %{account: String.t(), git_protocol: String.t() | nil}}
          | {:error, atom(), String.t()}
  def probe(base_dir, hostname, remote_url) do
    env = env(base_dir)

    with {:gh, path} when is_binary(path) <- {:gh, System.find_executable("gh")},
         {:auth, {_out, 0}} <-
           {:auth,
            System.cmd("gh", ["auth", "status", "--active", "--hostname", hostname],
              stderr_to_stdout: true,
              env: env
            )},
         {:api, {account, 0}} <-
           {:api,
            System.cmd("gh", ["api", "--hostname", hostname, "user", "--jq", ".login"], env: env)},
         {:git, {_out, 0}} <-
           {:git,
            System.cmd("git", ["ls-remote", remote_url, "HEAD"],
              stderr_to_stdout: true,
              env: env
            )} do
      {:ok, %{account: String.trim(account), git_protocol: git_protocol(env)}}
    else
      {:gh, nil} ->
        {:error, :missing_cli, "gh is missing from PATH"}

      {:auth, {detail, _status}} ->
        {:error, :needs_onboarding, scrub_detail(detail)}

      {:api, {detail, _status}} ->
        {:error, classify_api_failure(detail), scrub_detail(detail)}

      {:git, {detail, _status}} ->
        {:error, :git_unready, scrub_detail(detail)}
    end
  rescue
    ErlangError ->
      {:error, :unknown, "GitHub readiness probe could not run"}
  end

  @doc "Redact token material from probe output before it is surfaced anywhere."
  @spec scrub_detail(term()) :: String.t()
  def scrub_detail(detail) do
    detail
    |> to_string()
    |> String.replace(~r/github_pat_[A-Za-z0-9_]+/, "[redacted]")
    |> String.replace(~r/gh[opusr]_[A-Za-z0-9_]+/, "[redacted]")
    |> String.replace(~r{https://[^/\s:]+:[^@\s]+@}, "https://[redacted]@")
    |> String.trim()
  end

  defp known_host(nil), do: nil

  defp known_host(host) do
    cond do
      host == "github.com" -> host
      String.ends_with?(host, ".github.com") -> host
      true -> nil
    end
  end

  defp git_protocol(env) do
    case System.cmd("gh", ["config", "get", "git_protocol"], env: env) do
      {protocol, 0} ->
        protocol = String.trim(protocol)
        if protocol == "", do: nil, else: protocol

      _ ->
        nil
    end
  rescue
    ErlangError -> nil
  end

  defp classify_api_failure(detail) do
    down = String.downcase(to_string(detail))

    cond do
      String.contains?(down, "scope") or String.contains?(down, "forbidden") or
          String.contains?(down, "403") ->
        :insufficient_scope

      String.contains?(down, "auth") or String.contains?(down, "401") ->
        :needs_onboarding

      true ->
        :unknown
    end
  end
end
