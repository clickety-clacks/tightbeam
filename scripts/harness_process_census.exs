Code.require_file("../test/support/harness_process_census.ex", __DIR__)

snapshot = Tightbeam.HarnessProcessCensus.capture()
IO.puts(Tightbeam.HarnessProcessCensus.format(snapshot))

if "--assert-zero" in System.argv() and snapshot.count != 0, do: System.halt(1)
