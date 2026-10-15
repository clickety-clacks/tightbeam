defmodule Tightbeam.RecognitionRestartProbe do
  @moduledoc false
  alias Tightbeam.DB.Txn

  def recognition_callback do
    fn txn, :committed ->
      unless Txn.q(txn, "SELECT ready FROM recognition_gate") == [[1]], do: raise("not ready")
      Txn.q(txn, "INSERT INTO restart_rows VALUES(2)")
      :recognized
    end
  end

  def publication_callback(expected) do
    fn result ->
      true = result == expected
      unless File.exists?(result.gate), do: raise("not ready")
      File.write!(result.publication, "published")
      :published
    end
  end
end
