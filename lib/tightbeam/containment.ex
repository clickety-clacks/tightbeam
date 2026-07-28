defmodule Tightbeam.Containment do
  @moduledoc """
  Write-root validation, and containment profile rendering for the host's OS.

  ## What containment is for

  Containment keeps agents ON THE RAILS. It is not a defence against a malicious
  agent, and it is not a security boundary. A circumvention that requires an agent
  to be deliberately hostile is explicitly OUT OF SCOPE: we do not design for it,
  and a finding premised on it is not work.

  This is a standing product ruling, not a default to be re-litigated per change.
  Weigh a proposed hardening by whether it keeps honest work inside its lines —
  parity, correctness, legibility — and decline it when the only story that
  reaches it is malice. Reviewers do not hold this frame and will raise
  security-shaped findings by default; that alone does not make them work.

  The neutral truth is the SET OF WRITE ROOTS. Seatbelt SBPL is macOS's encoding
  of that set, not the set itself, so only the encoding is per-OS: this module
  stays the single authority on which roots are granted, because that draws on
  product knowledge the wrapper does not have. The wrapper dispatches on its own
  target OS to apply what it is handed.

  `rail_profile/1` for a rail check script is the ONLY seam. Adapter-level
  containment (a second seam that sandboxed the harness adapter process) was
  ruled out and deleted (#36): containment is a rails mechanism, and no rail
  routes through the adapter. When the seams coexisted they got DIFFERENT
  grants, because sharing one renderer's list let a harness-driven grant widen
  the rail wall by accident.

  A platform-specific mechanism carries a parity obligation and a per-OS proof
  obligation at the moment it is chosen. Both mechanisms and both obligations
  are written down in the shared containment spec; a supported platform without
  a named mechanism raises here rather than rendering something inapplicable.

  Profile rendering validates every write root, including filesystem
  canonicality, so a configured grant can never silently miss its real path.
  Validation is neutral truth about the filesystem and runs identically on
  every platform.
  """

  # A rail check script is not a harness turn, so it gets NO harness additions. It used
  # to: the harness-additions hook (deleted with adapter containment, #36) arrived with
  # the adapter-seam refactor (63fc9e7, two days after rails were contained in 0be38de)
  # and was appended to the one renderer both seams happened to share. On macOS that
  # silently widened rail profiles by
  # `/private/tmp`; on linux it granted `/dev`, and `/dev/shm` is world-writable tmpfs —
  # a DURABLE write channel outside the scratch root, surviving the scratch rm_rf. Proven
  # on shrdlu: a rail script under a real rail profile wrote /dev/shm and returned PASS.
  #
  # `/dev/null` is granted deliberately and is the only fixed grant: `>/dev/null` is in
  # shipped conformance rail scripts (c5_script_guards), so the need is measured rather
  # than assumed, and a discard sink cannot carry anything out of the scratch root. Every
  # other node under /dev — `/dev/shm` above all — is no longer reachable. Narrower than
  # before on BOTH platforms, which is the only direction a parity difference may resolve.
  @rail_grants [{"/dev/null", "rail scripts redirect to the discard sink"}]

  @spec rail_profile([String.t()]) :: String.t()
  def rail_profile(write_roots) do
    render(write_roots, @rail_grants)
  end

  defp render(write_roots, extra_grants) do
    validate_roots!(write_roots)

    grants = Enum.map(write_roots, &{&1, nil}) ++ extra_grants

    case :os.type() do
      {:unix, :darwin} -> seatbelt(grants)
      {:unix, :linux} -> landlock(grants)
      other -> raise ArgumentError, "no containment mechanism for #{inspect(other)}"
    end
  end

  defp seatbelt(grants) do
    rendered =
      grants
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{path, comment}, index} ->
        closing = if index == length(grants) - 1, do: ")", else: ""
        line = ~s|  (subpath "#{path}")#{closing}|
        if comment, do: String.pad_trailing(line, 34) <> ";; " <> comment, else: line
      end)

    """
    (version 1)
    (deny default)

    ;; read anywhere: materials, dyld, adapter code, caches, creds-via-symlink
    (allow file-read*)

    ;; writes: deny-by-default; org trees + spike-required system paths
    (allow file-write*
    #{rendered}

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

  # Landlock consumes a set of path rules, so the grant list is the whole profile: the
  # wrapper handles the write-shaped access rights and grants them beneath these paths,
  # leaving reads, execs, and network unhandled — the same posture the SBPL above states
  # in prose. Rendered by hand rather than by encoding a map, so the bytes are
  # deterministic and assertable; `validate_roots!/1` has already refused the bytes that
  # would need escaping.
  defp landlock(grants) do
    roots = Enum.map_join(grants, ",", fn {path, _comment} -> JSON.encode!(path) end)
    ~s({"tightbeam_containment":1,"write_roots":[#{roots}]})
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
