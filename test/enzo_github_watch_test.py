"""Offline synthetic endpoints for the shipped observer and its acceptance test."""

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

PROGRAM = Path(__file__).resolve().parents[1] / "priv/kungfu/uncle-enzo/sentinels/github-watch"
PREFIX = "uncle-enzo/github-watch/"
ROOT = "https://api.github.com/repos/example/widget/"
PULL = "https://github.com/example/widget/pull/"
HEAD = "a" * 40
MERGE = "b" * 40


def load(program):
    loader = importlib.machinery.SourceFileLoader("enzo_watch", str(program))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


class Fixture:
    def __init__(self, demand, pattern):
        self.demand = demand
        self.pattern = pattern
        self.posts = []
        self.reads = []
        self.fail_post = False

    def tightbeam_json(self, args):
        if args[:2] == ["sentinel", "demand"]:
            return {"demand": self.demand, "extra": "ignored"}
        if args[:2] == ["sentinel", "post"]:
            if self.fail_post:
                raise OSError("simulated lost acknowledgement")
            self.posts.append(dict(zip(("event", "key", "scope", "revision", "observation"),
                                       (args[3], args[5], *(item.split("=", 1)[1] for item in args[7::2])))))
        return {}

    def rest(self, endpoint):
        self.reads.append(endpoint)
        path = endpoint.split("?")[0]
        ref = "main" if self.pattern.startswith("trunk") else "release/2.x"
        if path.endswith("/pulls/17") and self.pattern == "trunk-open":
            return {"head": {"sha": HEAD}, "base": {"ref": ref}, "state": "open"}
        if path.endswith("/pulls/17"):
            return {"head": {"sha": HEAD, "repo": {"full_name": "fork/widget"}},
                    "base": {"ref": ref}, "state": "closed", "merge_commit_sha": MERGE,
                    "extra": {"ignored": True}}
        if path.endswith("/issues/17/timeline"):
            return [{"event": "merged", "id": 1, "created_at": "2026-01-01T00:00:00Z",
                     "commit_id": MERGE}]
        if path.endswith("/pulls/89"):
            return {"head": {"sha": HEAD}, "base": {"ref": ref}, "state": "open"}
        if path.endswith("/check-runs"):
            return {"check_runs": [{"id": 2, "name": "ci", "status": "completed",
                                    "conclusion": "failure", "extra": 1}]}
        if path.endswith("/statuses"):
            return []
        if "/git/ref/" in path:
            return {"object": {"type": "commit", "sha": MERGE}}
        if "/releases/tags/" in path:
            return {"draft": False, "published_at": "2026-01-01T00:00:00Z",
                    "id": 3, "tag_name": "v2.3.1", "prerelease": False,
                    "html_url": "https://github.com/example/widget/releases/tag/v2.3.1"}
        raise AssertionError(endpoint)


def demand(kind, scope):
    return {"kind": PREFIX + kind, "filter": {"scope": [scope]}}


class WatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cursor = Path(self.tmp.name)
        self.watch = load(PROGRAM)

    def test_ignores_no_scope_legacy_and_noncanonical_demand(self):
        fixture = Fixture([
            {"kind": "landing.settled", "filter": {"scope": [PULL + "17"]}},
            {"kind": PREFIX + "pr.merged", "filter": {}},
            demand("branch.check-failed", ROOT + "git/ref/heads/release/2.x"),
        ], "trunk")
        self.assertTrue(self.watch.Observer(fixture, self.cursor).poll())
        self.assertEqual(fixture.reads, [])

    def test_trunk_merge_replays_identically_after_restart(self):
        fixture = Fixture([demand("pr.merged", PULL + "17"), demand("pr.settled", PULL + "17")], "trunk")
        observer = self.watch.Observer(fixture, self.cursor)
        fixture.fail_post = True
        self.assertFalse(observer.poll())
        self.assertEqual(list(self.cursor.iterdir()), [])
        fixture.fail_post = False
        self.assertTrue(observer.poll())
        self.assertTrue(self.watch.Observer(fixture, self.cursor).poll())
        self.assertEqual(fixture.posts[:2], fixture.posts[2:])
        self.assertEqual(fixture.posts[0]["revision"], MERGE)
        self.assertEqual(json.loads(fixture.posts[0]["observation"])["headRepository"], "fork/widget")

    def test_release_branch_tag_publication_and_advisory_red_checks_are_distinct(self):
        fixture = Fixture([
            demand("pr.checks-completed", PULL + "89"),
            demand("branch.check-failed", ROOT + "git/ref/heads/release%2F2.x"),
            demand("tag.observed", ROOT + "git/ref/tags/v2.3.1"),
            demand("release.published", ROOT + "releases/tags/v2.3.1"),
        ], "backport")
        self.assertTrue(self.watch.Observer(fixture, self.cursor).poll())
        self.assertEqual({row["event"] for row in fixture.posts}, {row["kind"] for row in fixture.demand})
        completed = json.loads(fixture.posts[0]["observation"])
        self.assertEqual(completed["state"], "observed-checks-terminal")
        self.assertNotIn("pass", completed)
        self.assertNotIn("required", completed)

    def test_empty_and_unknown_checks_do_not_establish_completion(self):
        class MissingCheck(Fixture):
            def rest(self, endpoint):
                if "/check-runs?" in endpoint:
                    return {"check_runs": self.checks}
                return super().rest(endpoint)

        for checks in ([], [{"id": 2, "name": "ci", "status": "completed", "conclusion": "future"}]):
            fixture = MissingCheck([demand("pr.checks-completed", PULL + "89")], "backport")
            fixture.checks = checks
            self.assertTrue(self.watch.Observer(fixture, self.cursor).poll())
            self.assertEqual(fixture.posts, [])


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--gh-fixture":
        with open(os.environ["ENZO_FIXTURE_READS"], "a", encoding="utf-8") as reads:
            print(sys.argv[2], file=reads)
        print(json.dumps(Fixture([], os.environ["ENZO_FIXTURE_PATTERN"]).rest(sys.argv[2])))
    else:
        unittest.main()
