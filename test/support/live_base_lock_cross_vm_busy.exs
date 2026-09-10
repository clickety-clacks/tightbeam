import ExUnit.Assertions
[_, _, locks] = System.argv()
assert {:error, :lock_busy} = Tightbeam.LiveBaseLock.acquire(Path.join(locks, "cross-vm.lock"))
IO.puts("cross-vm-busy: ok")
