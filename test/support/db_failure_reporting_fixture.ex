defmodule Tightbeam.TestSupport.DBFailureReportingFixture do
  alias Tightbeam.DB

  def handler(db, observer, sentinel) do
    fn _call ->
      send(observer, {:db_failure_reporting_handler_called, self()})

      {:error, exception} =
        DB.transaction(db, fn txn ->
          send(observer, {:db_failure_reporting_callback_called, self()})
          :ok = DB.Txn.exec(txn, "ROLLBACK")
          raise "primary DB failure password=#{sentinel}"
        end)

      raise exception
    end
  end
end
