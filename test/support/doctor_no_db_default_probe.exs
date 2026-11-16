[payload, base] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
nil = Process.whereis(Tightbeam.DB)

System.delete_env("CLAUDE_CODE_EXECUTABLE")
System.delete_env("CODEX_PATH")

bin = Path.join(base, "bin")
File.mkdir_p!(bin)

for {name, version} <- [
      {"claude", "Claude Code 2.1.322 (doctor fixture)"},
      {"codex", "Codex 0.167.0 (doctor fixture)"}
    ] do
  path = Path.join(bin, name)
  File.write!(path, "#!/bin/sh\nprintf '%s\\n' '#{version}'\n")
  File.chmod!(path, 0o755)
end

System.put_env("PATH", bin)

entry = %{
  family: "doctor-probe-fixture",
  context: nil,
  display_name: "doctor-probe-fixture",
  name: "doctor-probe-fixture",
  efforts: ["medium"],
  max_input_tokens: nil,
  capabilities: %{},
  provider: :anthropic
}

catalog =
  {:ok, %{"claude" => [entry], "codex" => [], "cursor" => [], "pi" => [], "fixture" => []}}

inputs = [
  base_dir: base,
  default_model: Tightbeam.Model.new("doctor-probe-fixture", effort: "medium"),
  default_harness: :claude,
  advertised_url: "https://tightbeam.invalid",
  hosts: %{"local-test" => %{ssh: nil, base_dir: base, cli_bin: bin}},
  local_host_name: "local-test",
  cli_bin: bin,
  github_gh_path: nil,
  credential_state: fn _provider -> :present end
]

{_status, report} = Mix.Tasks.Tightbeam.Doctor.evaluate(catalog, inputs)

for {harness, version} <- [
      {"claude", "Claude Code 2.1.322 (doctor fixture)"},
      {"codex", "Codex 0.167.0 (doctor fixture)"}
    ] do
  check = Enum.find(report.checks, &(&1.name == "harness_binary:#{harness}"))
  true = check.ok
  true = check.detail == version
end

nil = Process.whereis(Tightbeam.DB)
IO.puts("doctor-no-db-default-probe: ok")
