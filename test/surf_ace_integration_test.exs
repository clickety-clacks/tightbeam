defmodule Tightbeam.SurfAceIntegrationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Archetypes

  setup do
    on_exit(fn -> :persistent_term.erase(Tightbeam.Archetypes) end)
    :ok
  end

  test "Surf Ace identity projects the public MCP server and complete agent skill" do
    root =
      Path.expand(
        "../integrations/surf-ace",
        __DIR__
      )

    archetype = Archetypes.load!(root)["surf-ace-controller"]

    assert archetype.skills == ["surf-ace"]
    assert archetype.where == ["*"]

    assert Archetypes.acp_mcp_servers(archetype) == [
             %{
               "name" => "surf-ace",
               "command" => "tightbeam-surf-ace",
               "args" => ["mcp"],
               "env" => []
             }
           ]

    skill = File.read!(Path.join([root, "identity", "skills", "surf-ace", "SKILL.md"]))

    for tool <- ~w(
      surf_ace_list
      surf_ace_push
      surf_ace_read
      surf_ace_topology_intent
      surf_ace_topology_realize
      surf_ace_clear
      surf_ace_annotations_remove
      surf_ace_capture_pane
      surf_ace_surface_intent
      surf_ace_target_register
      surf_ace_target_apply
    ) do
      assert skill =~ tool
    end

    assert skill =~ "operationReceipt"
    assert skill =~ ~r/lifecycle\s+connection/
    assert skill =~ "surface-scoped connection"
    refute skill =~ "SURF_ACE_SURFACE_ID"
    refute skill =~ "provider ownership"
    assert skill =~ "Never access OpenClaw process state or private stores"

    manifest =
      File.read!(
        Path.join([
          root,
          "identity",
          "archetypes",
          "surf-ace-controller.toml"
        ])
      )

    for host <- ~w(eezo racter tars) do
      refute manifest =~ host
    end
  end
end
