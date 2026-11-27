"""Freeze recipients and answer policy before a shared send is attempted."""

from __future__ import annotations

from addresses import Addresses


def is_group_address(address: str) -> bool:
    return address.startswith(("group:", "group-id:"))


def prepare_send(record: dict, addresses: Addresses) -> dict:
    group_addresses = [
        address for address in record["addresses"] if is_group_address(address)
    ]
    if group_addresses:
        if len(record["addresses"]) != 1:
            return {"refusal": {"code": "unsupported",
                                "message": "A group must be the only address in a send."}}
        if record.get("organization"):
            return {"refusal": {"code": "invalid_field",
                                "message": "The group selector identifies its organization."}}
        address = group_addresses[0]
        prefix, _, value = address.partition(":")
        if not value.strip():
            return {"refusal": {"code": "invalid_field", "message": "The group selector is blank."}}
        group = {"kind": "group", "group_id" if prefix == "group-id" else "name": value}
    else:
        address = None
        group = None

    mapped = {
        address: addresses.users[address.removeprefix("user:")]
        for address in record["addresses"]
        if address.startswith("user:") and address.removeprefix("user:") in addresses.users
    }
    missing = [
        {"address": address, "status": "not_reachable", "reason": "no_person_mapping"}
        for address in record["addresses"]
        if address not in mapped
    ]
    rule = record["answer_rule"]
    policy = rule
    if rule and rule["kind"] == "named":
        decider = addresses.users.get(rule["address"].removeprefix("user:"))
        if decider is None or (group is None and decider not in mapped.values()):
            return {"refusal": {"code": "decider_unreachable",
                                "message": "The named decider must be reachable on this send."}}
        policy = {"kind": "named", "people": [decider]}

    return {
        "selector": group or {"kind": "people", "people": list(mapped.values())},
        "group_address": address,
        "mapped": mapped,
        "missing": missing if group is None else [],
        "organization": record.get("organization"),
        "title": record["title"],
        "body": record["body"],
        "choices": record["choices"],
        "answer_policy": policy,
    }


def delivery_outcomes(request: dict, wire_outcomes: list[dict] | dict, delivered: bool) -> list[dict]:
    selector = request["selector"]
    if selector["kind"] == "group":
        if (not delivered or not isinstance(wire_outcomes, dict)
                or set(wire_outcomes) != {"kind", "group_id"} or wire_outcomes["kind"] != "group"
                or not isinstance(wire_outcomes["group_id"], str) or not wire_outcomes["group_id"]
                or selector.get("group_id", wire_outcomes["group_id"]) != wire_outcomes["group_id"]):
            raise ValueError("Harklight returned an invalid group delivery receipt")
        return [{"address": request["group_address"], "status": "reached"}]
    by_person = {outcome["person_id"]: outcome["status"] for outcome in wire_outcomes}
    outcomes = request["missing"].copy()
    for address, person_id in request["mapped"].items():
        status = by_person[person_id]
        if status == "unreachable":
            outcome = {"address": address, "status": "not_reachable"}
        elif status == "reached" and delivered:
            outcome = {"address": address, "status": "reached"}
        elif status == "reached":
            outcome = {"address": address, "status": "refused", "reason": "not_delivered"}
        else:
            raise ValueError("unknown Harklight recipient status")
        outcomes.append(outcome)
    return outcomes
