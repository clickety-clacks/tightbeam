defmodule Tightbeam.ToplinesRailsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Toplines}

  setup do
    # {System.unique_integer([:positive])}
    db = :toplines_rails_
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    insert_user!(db, "flynn")
    insert_user!(db, "kay")
    insert_work_item!(db, "wi_one", "flynn")
    insert_work_item!(db, "wi_two", "kay")

    :ok =
      DB.execute(
        db,
        """
        INSERT INTO wakes
          (wakeId, sessionKey, origin, prompt, consumer, dueAt, state, createdAt)
        VALUES ('w_one', 'agent:main:clawline:flynn:main', 'test',
                'Choose placement', 'prompt', 10, 'pending', 10);
        INSERT INTO causal_events (seq, at, jobRef, kind, detail)
          VALUES (100, 10, 'wi_one', 'disposition_transition', '{}'),
                 (101, 10, 'wi_two', 'disposition_transition', '{}');
        """
      )

    :ok = Toplines.ensure_schema(db)
    %{db: db}
  end

  test "AC65 rejects every invalid Topline shape through direct SQL", %{db: db} do
    invalid = [
      %{state: "other"},
      %{createdActorRef: nil},
      %{closedAt: 11},
      %{state: "closed", closedAt: nil},
      %{state: "closed", closedAt: "later"},
      %{updatedAt: 9},
      %{title: 1},
      %{title: "\u00a0Intent"},
      %{title: "Cafe\u0301"},
      %{title: ""},
      %{title: String.duplicate("a", 2_001)}
    ]

    Enum.each(invalid, fn overrides ->
      assert_rejected(db, "toplines", Map.merge(topline_row("tl_invalid"), overrides))
    end)
  end

  test "AC66 rejects invalid membership actors, reasons, and end tuples", %{db: db} do
    insert!(db, "toplines", topline_row("tl_one"))

    invalid = [
      %{linkedActorRef: nil},
      %{linkReason: " "},
      %{unlinkedAt: 20},
      ended_membership(%{unlinkedActorKind: "process"}),
      ended_membership(%{unlinkedAt: "later"}),
      ended_membership(%{unlinkedAt: 9})
    ]

    Enum.each(invalid, fn overrides ->
      assert_rejected(
        db,
        "topline_work_memberships",
        Map.merge(membership_row("tlm_invalid", "tl_one", "wi_one", "flynn"), overrides)
      )
    end)
  end

  test "AC67 rejects invalid Concern state, actors, resolution, time, and titles", %{db: db} do
    insert!(db, "toplines", topline_row("tl_one"))

    invalid = [
      %{state: "other"},
      %{createdActorRef: nil},
      %{resolveReason: "done"},
      resolved_concern(%{resolveReason: nil}),
      resolved_concern(%{resolvedAt: "later"}),
      resolved_concern(%{resolvedAt: 9}),
      %{title: " Intent"},
      %{title: String.duplicate("a", 2_001)}
    ]

    Enum.each(invalid, fn overrides ->
      assert_rejected(
        db,
        "topline_concerns",
        Map.merge(concern_row("tlc_invalid", "tl_one"), overrides)
      )
    end)
  end

  test "AC68 rejects invalid Concern-reference actors, reasons, and end tuples", %{db: db} do
    seed_reference_parents!(db, "tl_one", "tlm_one", "tlc_one")

    invalid = [
      %{linkedActorRef: nil},
      %{linkReason: " "},
      %{unlinkedAt: 20},
      ended_reference(%{unlinkedAt: "later"}),
      ended_reference(%{unlinkedAt: 9})
    ]

    Enum.each(invalid, fn overrides ->
      assert_rejected(
        db,
        "topline_concern_refs",
        Map.merge(reference_row("tlcr_invalid", "tl_one", "tlc_one", "tlm_one"), overrides)
      )
    end)
  end

  test "AC69 rejects invalid placement shapes and causal parent tuples", %{db: db} do
    invalid = [
      %{cause: "other"},
      %{state: "other"},
      %{openedActorRef: nil},
      %{openedActorKind: "process", openedActorRef: "tightbeam"},
      %{
        cause: "migration",
        causeRef: "migration",
        openedActorKind: "process",
        openedActorRef: "other"
      },
      %{
        cause: "reopened",
        sourceCausalEventSeq: 100,
        openedActorKind: "process",
        openedActorRef: "other"
      },
      %{dueAt: 11},
      %{promptWakeId: " "},
      %{resolutionReason: "done"},
      resolved_placement("left_unlinked", %{resolutionReason: nil}),
      resolved_placement("linked", %{
        resolutionActorKind: "process",
        resolutionActorRef: "tightbeam"
      }),
      resolved_placement("work_terminal", %{
        resolutionActorKind: "process",
        resolutionActorRef: "tightbeam",
        resolutionReason: "work_item_closed"
      }),
      resolved_placement("work_terminal", %{
        resolutionReason: "reupgrade_terminal_reconciliation_closed"
      }),
      resolved_placement("work_terminal", %{
        resolutionActorKind: "process",
        resolutionActorRef: "other",
        resolutionReason: "reupgrade_terminal_reconciliation_closed",
        resolutionCausalEventSeq: 100
      }),
      %{openedAt: "now", dueAt: "now"},
      %{historyCausalSeq: "zero"},
      %{historyCausalSeq: -1},
      %{cause: "reopened"},
      %{sourceCausalEventSeq: 100},
      resolved_placement("work_terminal", %{
        resolutionActorKind: "process",
        resolutionActorRef: "tightbeam",
        resolutionReason: "reupgrade_terminal_reconciliation_closed"
      }),
      resolved_placement("work_terminal", %{
        resolutionReason: "work_item_closed",
        resolutionCausalEventSeq: 100
      }),
      %{causeRef: "wi_other"},
      %{cause: "last_membership_unlinked", causeRef: "not-a-membership"},
      %{
        cause: "reopened",
        causeRef: "wi_one",
        sourceCausalEventSeq: 101
      },
      resolved_placement("work_terminal", %{
        resolutionActorKind: "process",
        resolutionActorRef: "tightbeam",
        resolutionReason: "reupgrade_terminal_reconciliation_closed",
        resolutionCausalEventSeq: 101
      })
    ]

    Enum.each(invalid, fn overrides ->
      assert_rejected(
        db,
        "topline_placement_obligations",
        Map.merge(placement_row("tlp_invalid"), overrides)
      )
    end)

    insert!(
      db,
      "topline_placement_obligations",
      placement_row("tlp_source")
      |> Map.merge(%{
        cause: "reopened",
        sourceCausalEventSeq: 100,
        state: "linked",
        resolutionActorKind: "user",
        resolutionActorRef: "flynn",
        resolutionReason: "placed",
        resolvedAt: 11
      })
    )

    assert_rejected(
      db,
      "topline_placement_obligations",
      placement_row("tlp_source_duplicate")
      |> Map.merge(%{
        cause: "reopened",
        sourceCausalEventSeq: 100,
        state: "linked",
        resolutionActorKind: "user",
        resolutionActorRef: "flynn",
        resolutionReason: "placed",
        resolvedAt: 11
      })
    )

    insert!(
      db,
      "topline_placement_obligations",
      placement_row("tlp_resolution")
      |> Map.merge(
        resolved_placement("work_terminal", %{
          resolutionActorKind: "process",
          resolutionActorRef: "tightbeam",
          resolutionReason: "reupgrade_terminal_reconciliation_closed",
          resolutionCausalEventSeq: 100
        })
      )
    )

    assert_rejected(
      db,
      "topline_placement_obligations",
      placement_row("tlp_resolution_duplicate")
      |> Map.merge(
        resolved_placement("work_terminal", %{
          resolutionActorKind: "process",
          resolutionActorRef: "tightbeam",
          resolutionReason: "reupgrade_terminal_reconciliation_closed",
          resolutionCausalEventSeq: 100
        })
      )
    )
  end

  test "AC70 rejects invalid event kinds, actors, times, detail, and identifiers", %{db: db} do
    seed_reference_parents!(db, "tl_one", "tlm_one", "tlc_one")
    insert!(db, "topline_concern_refs", reference_row("tlcr_one", "tl_one", "tlc_one", "tlm_one"))

    invalid = [
      %{kind: "other"},
      %{actorRef: nil},
      %{actorKind: "process"},
      %{seq: "one"},
      %{seq: 0},
      %{eventAt: "now"},
      %{detail: "{"},
      %{detail: "{}"},
      %{detail: ~s({"title":1})},
      %{detail: ~s({"title":"Intent","extra":1})},
      %{membershipId: "tlm_one"}
    ]

    Enum.each(invalid, fn overrides ->
      assert_rejected(
        db,
        "topline_events",
        Map.merge(event_row("tl_one"), overrides)
      )
    end)
  end

  test "AC71 rejects both possible owner values for a cross-owner membership", %{db: db} do
    insert!(db, "toplines", topline_row("tl_one"))

    for owner <- ["flynn", "kay"] do
      assert_rejected(
        db,
        "topline_work_memberships",
        membership_row("tlm_cross_owner", "tl_one", "wi_two", owner)
      )
    end
  end

  test "AC72 rejects a Concern reference whose parents belong to different Toplines", %{db: db} do
    insert_work_item!(db, "wi_three", "flynn")
    insert!(db, "toplines", topline_row("tl_one"))
    insert!(db, "toplines", %{topline_row("tl_two") | ownerUserId: "flynn"})
    insert!(db, "topline_concerns", concern_row("tlc_one", "tl_one"))

    insert!(
      db,
      "topline_work_memberships",
      membership_row("tlm_two", "tl_two", "wi_three", "flynn")
    )

    assert_rejected(
      db,
      "topline_concern_refs",
      reference_row("tlcr_cross_topline", "tl_one", "tlc_one", "tlm_two")
    )
  end

  defp seed_reference_parents!(db, topline_id, membership_id, concern_id) do
    insert!(db, "toplines", topline_row(topline_id))

    insert!(
      db,
      "topline_work_memberships",
      membership_row(membership_id, topline_id, "wi_one", "flynn")
    )

    insert!(db, "topline_concerns", concern_row(concern_id, topline_id))
  end

  defp topline_row(id) do
    %{
      id: id,
      ownerUserId: "flynn",
      title: "Intent",
      state: "open",
      createdActorKind: "user",
      createdActorRef: "flynn",
      createdAt: 10,
      updatedAt: 10,
      closedAt: nil
    }
  end

  defp membership_row(id, topline_id, work_item_id, owner) do
    %{
      id: id,
      toplineId: topline_id,
      workItemId: work_item_id,
      ownerUserId: owner,
      linkReason: "groups work",
      linkedActorKind: "user",
      linkedActorRef: owner,
      linkedAt: 10,
      unlinkReason: nil,
      unlinkedActorKind: nil,
      unlinkedActorRef: nil,
      unlinkedAt: nil
    }
  end

  defp ended_membership(overrides) do
    Map.merge(
      %{
        unlinkReason: "split",
        unlinkedActorKind: "user",
        unlinkedActorRef: "flynn",
        unlinkedAt: 20
      },
      overrides
    )
  end

  defp concern_row(id, topline_id) do
    %{
      id: id,
      toplineId: topline_id,
      title: "Risk",
      state: "open",
      createdActorKind: "user",
      createdActorRef: "flynn",
      createdAt: 10,
      updatedAt: 10,
      resolveReason: nil,
      resolvedActorKind: nil,
      resolvedActorRef: nil,
      resolvedAt: nil
    }
  end

  defp resolved_concern(overrides) do
    Map.merge(
      %{
        state: "resolved",
        resolveReason: "done",
        resolvedActorKind: "user",
        resolvedActorRef: "flynn",
        resolvedAt: 20
      },
      overrides
    )
  end

  defp reference_row(id, topline_id, concern_id, membership_id) do
    %{
      id: id,
      toplineId: topline_id,
      concernId: concern_id,
      membershipId: membership_id,
      linkReason: "addresses risk",
      linkedActorKind: "user",
      linkedActorRef: "flynn",
      linkedAt: 10,
      unlinkReason: nil,
      unlinkedActorKind: nil,
      unlinkedActorRef: nil,
      unlinkedAt: nil
    }
  end

  defp ended_reference(overrides), do: ended_membership(overrides)

  defp placement_row(id) do
    %{
      id: id,
      workItemId: "wi_one",
      ownerUserId: "flynn",
      cause: "created",
      causeRef: "wi_one",
      sourceCausalEventSeq: nil,
      resolutionCausalEventSeq: nil,
      historyCausalSeq: 0,
      openedActorKind: "user",
      openedActorRef: "flynn",
      state: "pending",
      openedAt: 10,
      dueAt: 10,
      promptWakeId: "w_one",
      resolutionActorKind: nil,
      resolutionActorRef: nil,
      resolutionReason: nil,
      resolvedAt: nil
    }
  end

  defp resolved_placement(state, overrides) do
    Map.merge(
      %{
        state: state,
        resolutionActorKind: "user",
        resolutionActorRef: "flynn",
        resolutionReason: "placed",
        resolvedAt: 20
      },
      overrides
    )
  end

  defp event_row(topline_id) do
    %{
      toplineId: topline_id,
      seq: 1,
      kind: "topline_created",
      membershipId: nil,
      concernId: nil,
      concernReferenceId: nil,
      actorKind: "user",
      actorRef: "flynn",
      reason: nil,
      eventAt: 10,
      detail: ~s({"title":"Intent"})
    }
  end

  defp insert_user!(db, id) do
    {:ok, columns} = DB.query(db, "PRAGMA table_info(users)")

    if Enum.any?(columns, fn [_cid, name | _] -> name == "creationKind" end) do
      :ok =
        DB.execute(
          db,
          "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('#{id}',0,'admin_add',1)"
        )
    else
      :ok = DB.execute(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('#{id}',0,1)")
    end
  end

  defp insert_work_item!(db, id, owner) do
    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO work_items
                 (id, title, ownerUserId, state, createdByUser, createdContextKnown, createdAt)
               VALUES (?1, ?2, ?3, 'open', ?3, 1, 1)
               """,
               [id, "Work #{id}", owner]
             )
  end

  defp assert_rejected(db, table, row) do
    assert {:error, %DB.Error{}} = insert(db, table, row),
           "expected direct SQL rejection for #{table}: #{inspect(row)}"
  end

  defp insert!(db, table, row) do
    assert {:ok, []} = insert(db, table, row)
  end

  defp insert(db, table, row) do
    entries = Enum.sort_by(row, fn {key, _value} -> Atom.to_string(key) end)
    columns = Enum.map_join(entries, ",", fn {key, _value} -> Atom.to_string(key) end)
    placeholders = Enum.map_join(1..length(entries), ",", &"?#{&1}")
    values = Enum.map(entries, &elem(&1, 1))
    DB.query(db, "INSERT INTO #{table} (#{columns}) VALUES (#{placeholders})", values)
  end
end
