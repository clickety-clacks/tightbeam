# L0 live smoke — real derived catalog fetch at boot, no hang, freshness, validation.
# Reads the REAL claude token + codex cache. No DB, no port, read-only.
alias Tightbeam.ModelCatalog

base = System.get_env("TB_SMOKE_BASE") || Path.expand("~/.tightbeam-beam")
IO.puts("[l0-smoke] base_dir=#{base}")

t0 = System.monotonic_time(:millisecond)
{:ok, _pid} = ModelCatalog.start_link(base_dir: base, name: :smoke_cat)

deadline = t0 + 20_000

poll = fn poll ->
  {c_entries, c_health} = ModelCatalog.get("claude", :smoke_cat)
  {x_entries, x_health} = ModelCatalog.get("codex", :smoke_cat)
  ready = c_health == :fresh and x_health == :fresh
  cond do
    ready -> {c_entries, c_health, x_entries, x_health}
    System.monotonic_time(:millisecond) > deadline -> {c_entries, c_health, x_entries, x_health}
    true -> Process.sleep(250); poll.(poll)
  end
end

{c_entries, c_health, x_entries, x_health} = poll.(poll)
elapsed = System.monotonic_time(:millisecond) - t0

IO.puts("[l0-smoke] settled in #{elapsed}ms  claude=#{inspect(c_health)} (#{length(c_entries)} refs)  codex=#{inspect(x_health)} (#{length(x_entries)} refs)")
IO.puts("[l0-smoke] sample claude refs: #{inspect(Enum.map(Enum.take(c_entries, 6), & &1.ref))}")
IO.puts("[l0-smoke] sample codex refs:  #{inspect(Enum.map(Enum.take(x_entries, 6), & &1.ref))}")

# Validation semantics (the gate a spawn passes through):
host = Tightbeam.Placement.local_host_name()
default_ref = Tightbeam.Model.new("claude-sonnet-5", effort: "medium")  # the canonical default
dead_ref = Tightbeam.Model.new("claude-fable-5")   # bare ref for a with-efforts model: dead
bogus = ModelCatalog.route(host, "claude", Tightbeam.Model.new("definitely-not-a-real-model-xyz"), :smoke_cat)
default_present = ModelCatalog.route(host, "claude", default_ref, :smoke_cat)
dead = ModelCatalog.route(host, "claude", dead_ref, :smoke_cat)

IO.puts("[l0-smoke] route(canonical default #{Tightbeam.Model.to_ref(default_ref)}) => #{inspect(default_present)}")
IO.puts("[l0-smoke] route(dead bare #{Tightbeam.Model.to_ref(dead_ref)}) => #{inspect(dead)}")
IO.puts("[l0-smoke] route(bogus) => #{inspect(bogus)}")

no_hang = elapsed < 20_000
real_fresh = c_health == :fresh and length(c_entries) > 0
codex_fresh = x_health == :fresh and length(x_entries) > 0
# The canonical default must route; the other two must be refused BY THEIR OWN
# CAUSE — a tierless ref for a tiered model needs a tier, a made-up family is absent.
validation_ok =
  match?({:ok, _}, default_present) and
    match?({:error, %Tightbeam.Unroutable{cause: :needs_effort}}, dead) and
    match?({:error, %Tightbeam.Unroutable{cause: :family_absent}}, bogus)

pass = no_hang and real_fresh and codex_fresh and validation_ok
IO.puts("[l0-smoke] no_hang=#{no_hang} claude_fresh=#{real_fresh} codex_fresh=#{codex_fresh} validation_ok=#{validation_ok}")
IO.puts(if pass, do: "[l0-smoke] PASS", else: "[l0-smoke] FAIL")
System.halt(if pass, do: 0, else: 1)
