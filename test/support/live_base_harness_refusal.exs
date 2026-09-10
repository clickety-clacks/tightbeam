[payload, base, _locks] = System.argv()
true = Path.expand(Application.app_dir(:tightbeam)) == Path.expand(payload)
{:ok, _} = Application.ensure_all_started(:logger)
bin = Path.join(Path.dirname(base), "broken-cli")
File.mkdir_p!(bin)

for name <- ["claude", "codex"] do
  path = Path.join(bin, name)
  File.write!(path, "#!/bin/sh\necho broken >&2\nexit 1\n")
  File.chmod!(path, 0o755)
end

Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :autostart, true)
Application.put_env(:tightbeam, :fixture_harness, false)
System.put_env("PATH", bin)
false = File.exists?(base)
# This must terminate this disposable VM with the actual production exit.
Tightbeam.Application.start(:normal, [])
raise "production harness refusal returned instead of halting"
