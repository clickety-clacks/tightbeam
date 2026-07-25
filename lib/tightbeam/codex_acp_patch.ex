defmodule Tightbeam.CodexAcpPatch do
  @moduledoc """
  The vendored codex-acp 1.1.4 passthrough carried until it is upstream.

  The patch forwards Tight Beam's ACP `_meta.developerInstructions` to both
  `thread/start` and `thread/resume`, and surfaces Codex `account/updated`
  through a session update so the credential lifecycle can consume the
  pinned logged-out signal.
  """

  @version "1.1.4"

  @replacements [
    {
      "      modelProvider: this.getModelProvider(),\n      cwd: request.cwd\n",
      "      modelProvider: this.getModelProvider(),\n      cwd: request.cwd,\n      developerInstructions: request._meta?.developerInstructions\n"
    },
    {
      "      modelProvider: await this.getResumeModelProvider(),\n      threadId: request.sessionId\n",
      "      modelProvider: await this.getResumeModelProvider(),\n      threadId: request.sessionId,\n      developerInstructions: request._meta?.developerInstructions\n"
    },
    {
      "      case \"account/updated\":\n      case \"fs/changed\":",
      "      case \"account/updated\":\n        return this.createCodexSessionInfoUpdate({ accountUpdated: notification.params });\n      case \"fs/changed\":"
    }
  ]

  @doc "Apply the pinned patch idempotently to one installed codex-acp binary."
  @spec ensure!(String.t()) :: :ok
  def ensure!(binary_path) do
    {package, bundle} = installed_paths(binary_path)
    %{"version" => @version} = package |> File.read!() |> JSON.decode!()
    source = File.read!(bundle)
    patched = patch(source)

    if patched != source do
      temporary = bundle <> ".tightbeam-patch"
      File.write!(temporary, patched)
      File.chmod!(temporary, 0o644)
      File.rename!(temporary, bundle)
    end

    :ok
  end

  @doc "A shell-safe Node program used to patch a remote installation."
  @spec remote_script(String.t()) :: String.t()
  def remote_script(binary_path) do
    {_package, bundle} = installed_paths(binary_path)

    encoded =
      @replacements
      |> Enum.map(fn {before, replacement} -> [before, replacement] end)
      |> JSON.encode!()
      |> Base.encode64()

    """
    const fs=require('fs');const p=#{JSON.encode!(bundle)};
    const rs=JSON.parse(Buffer.from(#{JSON.encode!(encoded)},'base64').toString());
    let s=fs.readFileSync(p,'utf8');
    for(const [a,b] of rs){if(!s.includes(a)&&!s.includes(b))throw new Error('unsupported codex-acp 1.1.4 bundle');s=s.replace(a,b)}
    fs.writeFileSync(p,s);
    """
    |> String.replace("\n", "")
  end

  @doc false
  @spec patch(binary()) :: binary()
  def patch(source) do
    Enum.reduce(@replacements, source, fn {before, replacement}, bytes ->
      cond do
        String.contains?(bytes, replacement) -> bytes
        String.contains?(bytes, before) -> String.replace(bytes, before, replacement, global: false)
        true -> raise "unsupported codex-acp #{@version} bundle; passthrough patch did not apply"
      end
    end)
  end

  defp installed_paths(binary_path) do
    node_modules = binary_path |> Path.dirname() |> Path.dirname()

    {
      Path.join([node_modules, "@agentclientprotocol", "codex-acp", "package.json"]),
      Path.join([node_modules, "@agentclientprotocol", "codex-acp", "dist", "index.js"])
    }
  end
end
