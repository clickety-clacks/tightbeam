defmodule Tightbeam.Harness.BinarySelection do
  @moduledoc false

  alias Tightbeam.Harness.Support

  @marker "TIGHTBEAM_VENDOR_SELECTION "
  @external_resource Path.join(__DIR__, "binary_selection.js")
  @script File.read!(@external_resource)

  def script(module) do
    "const vendor=" <>
      JSON.encode!(module.cli_binary()) <>
      ";" <>
      "const pinName=" <>
      JSON.encode!(module.binary_cli_env_name()) <>
      ";" <>
      module.binary_cli_bundle_script() <> @script
  end

  def wrap_launch(plan, module, target) do
    command = Keyword.fetch!(plan, :cmd)
    adapter = List.last(command)
    root = Path.join(target.host_config.base_dir, "adapters")
    args = ["node", "-e", script(module), root, "launch", adapter]
    # The selector emits a shell-quoted exec command, never a new retry loop.
    shell =
      "choice=$(" <>
        Enum.map_join(args, " ", &Support.shell_quote/1) <>
        ") || exit $?; eval \"$choice\""

    wrapped =
      if Support.local?(target) do
        ["/bin/sh", "-c", shell]
      else
        Enum.drop(command, -1) ++ ["/bin/sh", "-c", Support.shell_quote(shell)]
      end

    plan
    |> Keyword.put(:cmd, wrapped)
    |> Keyword.put(:harness_binary_selection, true)
  end

  @doc false
  def probe_plan(plan, args, target) do
    if Support.local?(target) do
      Keyword.put(plan, :cmd, ["/bin/sh", "-c", Enum.map_join(args, " ", &Support.shell_quote/1)])
    else
      prefix = plan |> Keyword.fetch!(:cmd) |> Enum.drop(-1)
      Keyword.put(plan, :cmd, prefix ++ Enum.map(args, &Support.shell_quote/1))
    end
  end

  # The selector writes before exec; read only this attempt's bounded prefix.
  # Failure to read diagnostic evidence never blocks or changes the launch.
  def read_capture(file, offset, module) do
    with {:ok, io} <- :file.open(String.to_charlist(file), [:read, :binary]) do
      try do
        case :file.pread(io, offset, 16_384) do
          {:ok, bytes} ->
            bytes
            |> String.split("\n")
            |> Enum.find_value(fn line ->
              if String.starts_with?(line, @marker) do
                case JSON.decode(String.replace_prefix(line, @marker, "")) do
                  {:ok, capture} ->
                    Map.put(capture, "adapter", %{
                      "package" => module.install_package(),
                      "version" => module.adapter_version()
                    })

                  _ ->
                    nil
                end
              end
            end)

          _ ->
            nil
        end
      after
        :file.close(io)
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
