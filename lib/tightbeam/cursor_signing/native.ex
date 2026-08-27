defmodule Tightbeam.CursorSigning.Native do
  @moduledoc false

  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:tightbeam), ~c"cursor_signing_native")
    :erlang.load_nif(path, 0)
  end

  def acquire(_path, _mode, _target), do: :erlang.nif_error(:nif_not_loaded)
  def release(_lock), do: :erlang.nif_error(:nif_not_loaded)
  def rename_noreplace(_source, _destination), do: :erlang.nif_error(:nif_not_loaded)
end
