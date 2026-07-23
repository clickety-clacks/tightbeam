defmodule Tightbeam.Containment do
  @moduledoc """
  macOS Seatbelt profile rendering and write-root validation.

  Profile rendering validates every write root, including filesystem
  canonicality, so a configured grant can never silently miss its real path.
  """

  @spec profile([String.t()]) :: String.t()
  def profile(write_roots) do
    validate_roots!(write_roots)

    roots = Enum.map_join(write_roots, "\n", &~s|  (subpath "#{&1}")|)

    """
    (version 1)
    (deny default)

    ;; read anywhere: materials, dyld, adapter code, caches, creds-via-symlink
    (allow file-read*)

    ;; writes: deny-by-default; org trees + spike-required system paths
    (allow file-write*
    #{roots}
      (subpath "/private/tmp")        ;; claude Terminal per-command workdir
      (subpath "/dev"))               ;; claude session-new PTY allocation

    ;; process lifecycle
    (allow process-fork)
    (allow process-exec)
    (allow signal (target self))

    ;; macOS runtime baseline
    (allow mach-lookup)
    (allow sysctl-read)

    ;; network — v1 posture: open egress
    (allow network-outbound)
    """
  end

  @spec validate_roots!([String.t()]) :: :ok
  def validate_roots!(write_roots) do
    Enum.each(write_roots, fn root ->
      validate_root!(root)
      validate_components!(root)
    end)

    :ok
  end

  defp validate_root!(root) do
    cond do
      not is_binary(root) or Path.type(root) != :absolute ->
        raise ArgumentError, "containment write root must be absolute: #{inspect(root)}"

      String.contains?(root, ["\"", "\\"]) or contains_control?(root) ->
        raise ArgumentError, "containment write root contains a rejected byte: #{inspect(root)}"

      true ->
        :ok
    end
  end

  defp contains_control?(root), do: Enum.any?(:binary.bin_to_list(root), &(&1 < 0x20))

  defp validate_components!(root) do
    root
    |> String.split("/", trim: true)
    |> Enum.reduce_while("/", fn component, parent ->
      path = Path.join(parent, component)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          raise ArgumentError,
                "containment write root has symlink component #{inspect(path)}: #{inspect(root)}"

        {:ok, _stat} ->
          {:cont, path}

        {:error, :enoent} ->
          {:halt, path}

        {:error, reason} ->
          raise ArgumentError,
                "containment write root cannot be validated at #{inspect(path)} (#{reason}): #{inspect(root)}"
      end
    end)

    :ok
  end
end
