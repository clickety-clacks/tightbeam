defmodule Tightbeam.Harness.AdapterPatch do
  @moduledoc false

  @doc false
  def ensure!(binary_path, package_name, bundle_name, version, replacements, label, opts \\ []) do
    {package, bundle} = installed_paths(binary_path, package_name, bundle_name, opts)
    %{"version" => installed_version} = package |> File.read!() |> JSON.decode!()
    ^version = installed_version
    source = File.read!(bundle)
    patched = patch(source, replacements, label, version)

    if patched != source do
      # Preserve the bundle's own mode: npm marks bin-target bundles executable,
      # and node_modules/.bin symlinks exec them directly — a hardcoded 644 here
      # stripped the x-bit and broke every codex adapter spawn (Permission denied).
      %File.Stat{mode: mode} = File.stat!(bundle)
      temporary = bundle <> ".tightbeam-patch"
      File.write!(temporary, patched)
      File.chmod!(temporary, mode)
      File.rename!(temporary, bundle)
    end

    :ok
  end

  @doc false
  def remote_script(binary_path, package_name, bundle_name, replacements, label, opts \\ []) do
    {package, bundle} = installed_paths(binary_path, package_name, bundle_name, opts)

    encoded =
      replacements
      |> Enum.map(&encode_replacement/1)
      |> JSON.encode!()
      |> Base.encode64()

    version_check =
      case Keyword.fetch(opts, :version) do
        {:ok, version} ->
          "const v=JSON.parse(fs.readFileSync(#{JSON.encode!(package)},'utf8')).version;" <>
            "if(v!==#{JSON.encode!(version)})throw new Error('unsupported #{label} adapter version '+v);"

        :error ->
          ""
      end

    """
    const fs=require('fs');#{version_check}const p=#{JSON.encode!(bundle)};
    const rs=JSON.parse(Buffer.from(#{JSON.encode!(encoded)},'base64').toString());
    let s=fs.readFileSync(p,'utf8');
    for(const row of rs){const a=row[0],b=row[1],optional=row[2]&&row[2].optional;if(s.includes(b))continue;if(!s.includes(a)){if(optional)continue;throw new Error('unsupported #{label} adapter bundle');}s=s.replace(a,b);}
    fs.writeFileSync(p,s);
    """
    |> String.replace("\n", "")
  end

  @doc false
  def patch(source, replacements, label, version) do
    Enum.reduce(replacements, source, fn entry, bytes ->
      {before, replacement, opts} = normalize_replacement(entry)

      cond do
        String.contains?(bytes, replacement) ->
          bytes

        String.contains?(bytes, before) ->
          String.replace(bytes, before, replacement, global: false)

        Keyword.get(opts, :optional, false) ->
          bytes

        true ->
          raise "unsupported #{label} adapter #{version} bundle; patch did not apply"
      end
    end)
  end

  defp normalize_replacement({before, replacement}), do: {before, replacement, []}

  defp normalize_replacement({before, replacement, opts}) when is_list(opts),
    do: {before, replacement, opts}

  defp encode_replacement({before, replacement}), do: [before, replacement]

  defp encode_replacement({before, replacement, opts}) when is_list(opts),
    do: [before, replacement, Map.new(opts)]

  defp installed_paths(binary_path, package_name, bundle_name, opts) do
    node_modules = binary_path |> Path.dirname() |> Path.dirname()

    package_dir =
      case Keyword.get(opts, :scope, :agentclientprotocol) do
        :agentclientprotocol -> Path.join([node_modules, "@agentclientprotocol", package_name])
        :unscoped -> Path.join(node_modules, package_name)
      end

    {
      Path.join(package_dir, "package.json"),
      Path.join([package_dir, "dist", bundle_name])
    }
  end
end
