"""Explicit Tightbeam user and Harklight person mapping."""

from __future__ import annotations


class Addresses:
    def __init__(self, users: dict[str, str]):
        if not isinstance(users, dict) or any(
            not isinstance(user, str) or not user.strip()
            or not isinstance(person, str) or not person.strip()
            for user, person in users.items()
        ):
            raise ValueError("users must map nonempty Tightbeam user IDs to Harklight person IDs")
        self.people = {person: user for user, person in users.items()}
        if len(self.people) != len(users):
            raise ValueError("a Harklight person can map to only one Tightbeam user")
        self.users = users.copy()

    def speaker(self, server_id: str, speaker: dict | None) -> dict | None:
        if speaker is None or speaker["kind"] != "person":
            return None
        person_id = speaker["id"]
        user = self.people.get(person_id)
        if user is None:
            return {
                "server_id": server_id,
                "person_id": person_id,
                "display_name": speaker["display_name"],
            }
        return {"address": f"user:{user}", "display_name": speaker["display_name"]}
