defmodule Tightbeam.GuardRuntimeFixture do
  @moduledoc false
  import ExUnit.Assertions

  def run!(tmp, script, expected, opts \\ []) do
    %{executable: executable, args: args, env: env} = prepare!(tmp, script)

    {output, status} =
      System.cmd(executable, args ++ Keyword.get(opts, :args, []),
        env: env,
        stderr_to_stdout: true
      )

    File.write!(Path.join(tmp, "runtime.log"), output)
    assert status == Keyword.get(opts, :exit, 0), output
    assert output =~ expected
  end

  # Assemble a real payload the guard can identify: the dev build root cannot
  # serve as one, because Mix leaves `priv` a symlink and ships no manifest.
  # This prepares arguments only; it starts no process and no DB.
  def prepare!(tmp, script) do
    payload = Path.join(tmp, "tightbeam")
    File.mkdir_p!(payload)
    source = Application.app_dir(:tightbeam)
    File.cp_r!(Path.join(source, "ebin"), Path.join(payload, "ebin"))
    # Dereference only the known build-root priv alias while assembling; the
    # admitted payload itself contains no symlinks and no source is modified.
    priv = Tightbeam.LiveBaseAdmission.canonical!(Path.join(source, "priv"))
    File.cp_r!(priv, Path.join(payload, "priv"))

    files =
      Path.wildcard(Path.join(payload, "**/*"), match_dot: true)
      |> Enum.flat_map(fn path ->
        case File.lstat!(path).type do
          :directory -> []
          :regular -> [{Path.relative_to(path, payload), File.read!(path)}]
          other -> raise "nonregular assembled input: #{inspect(other)}"
        end
      end)

    {:ok, manifest} = Tightbeam.LiveBaseGuard.generate_manifest(files)
    File.write!(Path.join(payload, "build-manifest.json"), JSON.encode!(manifest))
    base = Path.join(tmp, "base")

    paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.reject(&(Path.expand(&1) == Path.expand(Path.join(source, "ebin"))))

    args =
      ["--erl", "+S 2:2"] ++
        Enum.flat_map(paths, &["-pa", &1]) ++
        [
          "-pa",
          Path.join(payload, "ebin"),
          Path.join("test/support", script),
          payload,
          base
        ]

    # The arena inherits no live release's base directory, endpoint, or node
    # identity, and writes nothing outside its own temporary directory.
    env =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(
        &(String.starts_with?(&1, "TIGHTBEAM_") or String.starts_with?(&1, "RELEASE_"))
      )
      |> Enum.map(&{&1, nil})

    env = env ++ [{"TMPDIR", tmp}, {"TIGHTBEAM_BASE_DIR", base}]

    %{
      executable: System.find_executable("elixir"),
      args: args,
      env: env,
      payload: payload,
      base: base
    }
  end
end
