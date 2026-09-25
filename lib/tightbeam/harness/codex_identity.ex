defmodule Tightbeam.Harness.CodexIdentity do
  @moduledoc false

  alias Tightbeam.Harness.Support

  @relative_dir "codex-context"
  @max_bytes 1_048_576

  @doc "The stock Codex SessionStart hook reads a snapshot by its engine thread ID."
  def hook_settings(rails) do
    hooks =
      case rails do
        nil -> %{}
        bytes when is_binary(bytes) -> bytes |> JSON.decode!() |> Map.fetch!("hooks")
        settings when is_map(settings) -> Map.fetch!(settings, "hooks")
      end

    hook = %{
      "type" => "command",
      "command" => "node -e #{Support.shell_quote(hook_script())}",
      "additionalContextLimit" => 0
    }

    JSON.encode!(%{"hooks" => Map.put(hooks, "SessionStart", [%{"hooks" => [hook]}])})
  end

  @doc "Project the complete composed guidance before a Codex thread can run a turn."
  def project(target, session_id, guidance)
      when is_binary(session_id) and is_binary(guidance) do
    snapshot = superseding_snapshot(guidance)

    with :ok <- valid_session_id(session_id),
         :ok <- valid_guidance(snapshot) do
      if Support.local?(target) do
        project_local(target.host_config.base_dir, session_id, snapshot)
      else
        project_remote(target, session_id, snapshot)
      end
    end
  rescue
    error -> {:error, {:codex_identity_projection_failed, Exception.message(error)}}
  end

  def project(_target, _session_id, _guidance),
    do: {:error, {:codex_identity_projection_failed, "invalid session ID or guidance"}}

  @doc "A complete current snapshot supersedes only earlier Tightbeam identity snapshots."
  def superseding_snapshot(guidance) when is_binary(guidance) do
    digest = Base.encode16(:crypto.hash(:sha256, guidance), case: :lower)

    """
    Tightbeam identity snapshot SHA-256: #{digest}
    This complete current Tightbeam identity snapshot supersedes every earlier Tightbeam identity snapshot in this Codex thread. Earlier Tightbeam identity clauses absent below are no longer active. This statement applies only to Tightbeam-owned identity; it does not override higher-priority instructions, user authorization, unrelated developer instructions, or other product and security constraints.

    <tightbeam-current-identity>
    #{guidance}
    </tightbeam-current-identity>
    """
  end

  @doc "The adapter gate must observe the hook, not just a successful model turn."
  def verify_hook(target, session_id) do
    if Support.local?(target) do
      base = Path.join(target.host_config.base_dir, @relative_dir)

      with {:ok, guidance} <- File.read(Path.join(base, session_id)),
           {:ok, seen} <- File.read(Path.join(base, session_id <> ".seen")),
           true <- seen == Base.encode16(:crypto.hash(:sha256, guidance), case: :lower) do
        :ok
      else
        _ -> {:error, :codex_identity_hook_not_observed}
      end
    else
      verify_remote_hook(target, session_id)
    end
  end

  defp valid_session_id(session_id) do
    if byte_size(session_id) <= 128 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, session_id),
      do: :ok,
      else: {:error, {:codex_identity_projection_failed, "invalid Codex session ID"}}
  end

  defp valid_guidance(guidance) do
    if byte_size(guidance) <= @max_bytes,
      do: :ok,
      else:
        {:error,
         {:codex_identity_projection_failed, "Codex guidance exceeds #{@max_bytes} bytes"}}
  end

  defp project_local(base_dir, session_id, guidance) do
    directory = Path.join(base_dir, @relative_dir)
    File.mkdir_p!(directory)
    path = Path.join(directory, session_id)
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    try do
      File.write!(temporary, guidance)
      File.chmod!(temporary, 0o600)
      File.rename!(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  end

  defp project_remote(target, session_id, guidance) do
    remote_dir = Path.join(target.host_config.base_dir, @relative_dir)
    staging = Path.join([target.base_dir, "staging", target.host_name, @relative_dir])
    File.mkdir_p!(staging)
    name = "#{session_id}.#{System.unique_integer([:positive])}.tmp"
    local_path = Path.join(staging, name)
    remote_path = Path.join(remote_dir, name)

    try do
      File.write!(local_path, guidance)
      File.chmod!(local_path, 0o600)

      Support.run!(
        target,
        [
          "ssh" | Support.ssh_opts()
        ] ++ [target.host_config.ssh, "mkdir", "-p", remote_dir]
      )

      Support.run!(target, [
        "rsync",
        "-a",
        "-e",
        Enum.join(["ssh" | Support.ssh_opts()], " "),
        local_path,
        "#{target.host_config.ssh}:#{remote_path}"
      ])

      Support.run!(
        target,
        [
          "ssh" | Support.ssh_opts()
        ] ++ [target.host_config.ssh, "mv", remote_path, Path.join(remote_dir, session_id)]
      )

      :ok
    after
      File.rm(local_path)
    end
  end

  defp verify_remote_hook(target, session_id) do
    base = Path.join(target.host_config.base_dir, @relative_dir)

    script =
      "const f=require('node:fs'),c=require('node:crypto'),p=require('node:path');" <>
        "const b=process.argv[1],s=process.argv[2];" <>
        "const x=f.readFileSync(p.join(b,s)),y=f.readFileSync(p.join(b,s+'.seen'),'utf8');" <>
        "process.exit(y===c.createHash('sha256').update(x).digest('hex')?0:1)"

    command =
      "node -e #{Support.shell_quote(script)} #{Support.shell_quote(base)} #{Support.shell_quote(session_id)}"

    case target.sh.(["ssh" | Support.ssh_opts()] ++ [target.host_config.ssh, command]) do
      {_output, 0} -> :ok
      _ -> {:error, :codex_identity_hook_not_observed}
    end
  end

  defp hook_script do
    """
    const fs=require("node:fs"),path=require("node:path"),crypto=require("node:crypto"),readline=require("node:readline");
    const fail=(why)=>process.stdout.write(JSON.stringify({continue:false,stopReason:"Tightbeam Codex developer instructions unavailable: "+why}));
    const previouslyDelivered=async(transcript,snapshot)=>{
      if(typeof transcript!=="string"||!transcript) return false;
      const stream=fs.createReadStream(transcript,{encoding:"utf8"});
      const lines=readline.createInterface({input:stream,crlfDelay:Infinity});
      try {
        for await(const line of lines) {
          let row;
          try {row=JSON.parse(line);} catch(_) {continue;}
          const item=row.type==="response_item"?row.payload:null;
          const kinds=item?.internal_chat_message_metadata_passthrough?.content_item_kinds;
          if(item?.role==="developer"&&Array.isArray(kinds)&&kinds.includes("hooks.additional_context")&&item.content?.some(part=>part.type==="input_text"&&part.text===snapshot)) return true;
        }
      } catch(_) {return false;}
      finally {lines.close();stream.destroy();}
      return false;
    };
    (async()=>{try {
      const event=JSON.parse(fs.readFileSync(0,"utf8"));
      const sid=event.session_id,base=process.env.TIGHTBEAM_HOME;
      if(typeof sid!=="string"||! /^[A-Za-z0-9_-]{1,128}$/.test(sid)||!base) fail("invalid session or home");
      else {
        const bytes=fs.readFileSync(path.join(base,"#{@relative_dir}",sid));
        if(bytes.length>#{@max_bytes}) fail("snapshot exceeds #{@max_bytes} bytes");
        else {
          fs.writeFileSync(path.join(base,"#{@relative_dir}",sid+".seen"),crypto.createHash("sha256").update(bytes).digest("hex"),{mode:0o600});
          const snapshot=bytes.toString("utf8");
          if(await previouslyDelivered(event.transcript_path,snapshot)) process.stdout.write("{}");
          else process.stdout.write(JSON.stringify({hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:snapshot}}));
        }
      }
    } catch(error) {fail(error.code||error.message||"snapshot missing");}})();
    """
    |> String.replace("\n", "")
  end
end
