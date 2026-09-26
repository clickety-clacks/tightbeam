[payload, base] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
File.mkdir_p!(base)

import ExUnit.Assertions
alias Tightbeam.{Breathing, DB, Schema}

start = fn ->
  DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])
end

{:ok, first_pid} = start.()

try do
  :ok = Schema.ensure_all(first_pid)
  :ok = DB.assert_base_admitted!(first_pid, base)

  :ok =
    DB.execute(first_pid, """
    INSERT INTO users (userId,isAdmin,createdAt)
    VALUES ('owner',0,1);

    INSERT INTO sessions
      (sessionKey,displayName,kind,isBuiltIn,ownerUserId,origin,
       archetype,identityName,harness,provider,model,thinkingLevel,createdAt,updatedAt,state)
    VALUES
      ('active','Active','custom',0,'owner','user:owner','default','default',
       'codex','openai','model','medium',1,1,'active');

    INSERT INTO turns
      (seq,sessionKey,messageId,origin,prompt,status,adapterGen,createdAt,startedAt)
    VALUES
      (1,'active','m_1','user:owner','work','running',7,1,1);
    """)

  before = Breathing.query(first_pid, "session", "active")
  :ok = GenServer.stop(first_pid)

  {:ok, second_pid} = start.()

  try do
    after_restart = Breathing.query(second_pid, "session", "active")
    assert after_restart == before
    refute inspect(after_restart) =~ "cliToken"
    refute inspect(after_restart) =~ "identityToken"
    IO.puts("breathing-restart-stable: ok")
  after
    GenServer.stop(second_pid)
  end
after
  if Process.alive?(first_pid), do: GenServer.stop(first_pid)
end
