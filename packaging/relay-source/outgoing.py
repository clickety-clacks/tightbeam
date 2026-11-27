"""Freeze recipients and answer policy before a shared send is attempted."""

from __future__ import annotations

from addresses import Addresses


def prepare_send(record: dict, addresses: Addresses) -> dict:
    if any(address.startswith("group:") for address in record["addresses"]):
        return {"refusal": {"code": "unsupported",
                            "message": "Group selectors require the Harklight groups interface."}}

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
        if decider is None or decider not in mapped.values():
            return {"refusal": {"code": "decider_unreachable",
                                "message": "The named decider must be reachable on this send."}}
        policy = {"kind": "named", "people": [decider]}

    return {
        "selector": {"kind": "people", "people": list(mapped.values())},
        "mapped": mapped,
        "missing": missing,
        "organization": record.get("organization"),
        "title": record["title"],
        "body": record["body"],
        "choices": record["choices"],
        "answer_policy": policy,
    }


def delivery_outcomes(request: dict, wire_outcomes: list[dict], delivered: bool) -> list[dict]:
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
