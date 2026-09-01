defmodule Tightbeam.Visitor.Keyring.Native do
  @moduledoc false

  @on_load :load_nif

  def load_nif do
    path = :tightbeam |> :code.priv_dir() |> Path.join("visitor_keyring_nif")
    :erlang.load_nif(path, 0)
  end

  def read(_directory, _expected_uid), do: :erlang.nif_error(:nif_not_loaded)
end
