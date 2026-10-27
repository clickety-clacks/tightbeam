#!/usr/bin/env python3
"""Run one real pull-request fact check using only a published Tightbeam package.

Called by verify_mix.sh --package-input. The repository supplies this driver;
the gateway, CLI, and watcher under test come from the verified release tarball.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tarfile
import time
import urllib.request

REPOSITORY = "clickety-clacks/tightbeam"
SCOPE = re.compile(r"^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)#([1-9][0-9]*)$")
RELEASE_TAG = re.compile(r"^v0\.1\.13\+[0-9]+$")


class AcceptanceError(Exception):
    pass


def require(test, message):
    if not test:
        raise AcceptanceError(message)


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def command(args, env, timeout=60):
    done = subprocess.run(args, env=env, text=True, capture_output=True, timeout=timeout)
    if done.returncode:
        raise AcceptanceError(f"{args[0]} exited {done.returncode}: {done.stderr.strip()}")
    return done


def gh_json(args, env):
    return json.loads(command(["gh", *args], env).stdout)


def asset(assets, name):
    matches = [entry for entry in assets if entry["name"] == name]
    require(len(matches) == 1, f"release needs exactly one {name} asset")
    return matches[0]


def verify_package(args, gh_env, scratch):
    require(RELEASE_TAG.fullmatch(args.tag), "expected a published v0.1.13+N tag")
    package = Path(args.package).expanduser().resolve(strict=True)
    require(package.is_file(), "package input is not a regular file")
    require(re.fullmatch(r"tightbeam-0\.1\.13-darwin-aarch64-[0-9a-f]+\.tgz", package.name),
            "package input is not the 0.1.13 Darwin asset")
    release = gh_json(["release", "view", args.tag, "--repo", REPOSITORY,
                       "--json", "tagName,isDraft,isPrerelease,publishedAt,assets"], gh_env)
    require(release["tagName"] == args.tag and release["publishedAt"] and not release["isDraft"]
            and not release["isPrerelease"], "release is not published and final")
    assets = release["assets"]
    require(asset(assets, package.name)["digest"] == "sha256:" + digest(package),
            "package differs from published release asset")
    command(["gh", "release", "download", args.tag, "--repo", REPOSITORY,
             "--pattern", "SHA256SUMS", "--pattern", "release-provenance.json",
             "--dir", str(scratch)], gh_env, timeout=180)
    for name in ("SHA256SUMS", "release-provenance.json"):
        require(asset(assets, name)["digest"] == "sha256:" + digest(scratch / name),
                f"{name} differs from published release asset")
    lines = (scratch / "SHA256SUMS").read_text().splitlines()
    matches = [line.split() for line in lines if line.split()[-1:] == [package.name]]
    require(len(matches) == 1 and matches[0][0] == digest(package),
            "SHA256SUMS does not pin package input")
    provenance = json.loads((scratch / "release-provenance.json").read_text())
    require(provenance["repository"] == REPOSITORY and provenance["tag"] == args.tag
            and provenance["checksums"] == "SHA256SUMS"
            and provenance["assets"].count(package.name) == 1,
            "release provenance does not name this repository and tag")
    source = provenance["commit"]
    require(re.fullmatch(r"[0-9a-f]{40}", source), "release source commit is malformed")
    require(package.name.endswith(f"-{source[:7]}.tgz"),
            "package name differs from release source commit")
    tagged = gh_json(["api", f"repos/{REPOSITORY}/commits/{args.tag}"], gh_env)["sha"]
    require(tagged == source, "release provenance differs from published tag commit")
    compare = gh_json(["api", f"repos/{REPOSITORY}/compare/{args.feature_commit}...{source}"], gh_env)
    require(compare["status"] in ("ahead", "identical"), "release source lacks required feature commit")

    with tarfile.open(package, "r:gz") as archive:
        require(all(not name.startswith("/") and ".." not in Path(name).parts
                    for name in archive.getnames()), "package contains an escaping path")
        archive.extractall(scratch)
    root = scratch / "tightbeam"
    cli = root / "bin/tightbeam"
    gateway = root / "bin/tightbeam-gateway"
    require(cli.is_file() and gateway.is_file(), "package has no CLI or gateway")
    bundled = json.loads((root / "release-provenance.json").read_text())
    require(bundled.get("format") == "tightbeam-release-provenance/v1"
            and all(bundled.get(field) == provenance[field]
                    for field in ("repository", "tag", "commit")),
            "package provenance differs from published sidecar")
    require(json.loads((root / "package.json").read_text())["version"] == "0.1.13",
            "package manifest version differs")
    require(command([str(cli), "--version"], gh_env).stdout.strip() == "0.1.13",
            "packaged CLI version differs")
    start_erl = (root / "release/releases/start_erl.data").read_text().split()
    require(len(start_erl) >= 2 and start_erl[1] == "0.1.13", "packaged gateway version differs")
    watcher_files = list((root / "release/lib").glob(
        "tightbeam-*/priv/kungfu/agentic-engineering/sentinels/landing-watch"))
    require(len(watcher_files) == 1, "package needs exactly one landing watcher")
    print(f"published package={package.name} sha256={digest(package)} source={source}", flush=True)
    return cli, gateway, watcher_files[0], source


def wait_until(label, predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(1)
    raise AcceptanceError(f"timed out waiting for {label}")


def available_port(port):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", port))


def github_pr(scope, gh_env):
    owner, repo, number = SCOPE.fullmatch(scope).groups()
    query = f'''query {{ repository(owner:"{owner}",name:"{repo}") {{ pullRequest(number:{number}) {{
      state headRefOid commits(last:1) {{ nodes {{ commit {{ statusCheckRollup {{
        contexts(first:100) {{ pageInfo {{ hasNextPage }} nodes {{
          __typename ... on CheckRun {{ name status conclusion isRequired(pullRequestNumber:{number}) }}
          ... on StatusContext {{ context state isRequired(pullRequestNumber:{number}) }}
        }} }} }} }} }} }} }} }} }}'''
    data = gh_json(["api", "graphql", "-f", "query=" + query], gh_env)["data"]
    pull = data["repository"]["pullRequest"]
    require(pull and pull["state"] == "OPEN", "real PR is no longer open")
    rollup = pull["commits"]["nodes"][0]["commit"]["statusCheckRollup"]
    require(rollup and not rollup["contexts"]["pageInfo"]["hasNextPage"],
            "required-check preflight is incomplete")
    required = [node for node in rollup["contexts"]["nodes"] if node.get("isRequired")]
    require(required, "real PR has no required check")
    require(all((n.get("status") == "COMPLETED" and n.get("conclusion"))
                or n.get("state") not in (None, "PENDING", "EXPECTED") for n in required),
            "real PR required checks are not terminal")
    return pull["headRefOid"]


def gh_shim(scratch, real_gh):
    shim_dir = scratch / "shim"
    shim_dir.mkdir()
    shim = shim_dir / "gh"
    shim.write_text('''#!/usr/bin/env python3
import json, os, re, sys
args = sys.argv[1:]
query = next((a[6:] for a in args if a.startswith("query=")), "")
operation = re.search(r"query ([A-Za-z]+)", query)
number = next((a[7:] for a in args if a.startswith("number=")), None)
with open(os.environ["GH_AUDIT_LOG"], "a") as out:
    out.write(json.dumps({"operation": operation.group(1) if operation else None,
                          "number": number}) + "\\n")
os.execv(os.environ["REAL_GH"], [os.environ["REAL_GH"], *args])
''')
    shim.chmod(0o700)
    return shim_dir


def run_acceptance(args, cli, gateway, watcher, source, gh_env, scratch):
    scope = args.scope.lower()
    require(SCOPE.fullmatch(scope), "--scope must be owner/repo#number")
    available_port(args.port)
    head = github_pr(scope, gh_env)
    base = scratch / "base"
    base.mkdir()
    gateway_log = open(scratch / "gateway.log", "w")
    watcher_log = open(scratch / "watcher.log", "w")
    gateway_env = {"PATH": str(cli.parent) + os.pathsep + os.environ["PATH"],
                   "HOME": str(scratch), "TIGHTBEAM_BASE_DIR": str(base),
                   "TIGHTBEAM_PORT": str(args.port)}
    watcher_env = {**gateway_env, "GH_CONFIG_DIR": str(Path(args.gh_config_dir).resolve()),
                   "GH_AUDIT_LOG": str(scratch / "gh-reads.jsonl"),
                   "REAL_GH": shutil.which("gh", path=gh_env["PATH"])}
    shim_dir = gh_shim(scratch, watcher_env["REAL_GH"])
    watcher_env["PATH"] = str(shim_dir) + os.pathsep + watcher_env["PATH"]
    require("LANDING_REPOS" not in watcher_env, "static repositories must be unset")
    server = None
    producer = None
    stopped = False
    try:
        server = subprocess.Popen([str(gateway), "start"], env=gateway_env,
                                  stdout=gateway_log, stderr=subprocess.STDOUT)

        def version_ready():
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{args.port}/version", timeout=2) as response:
                    value = json.load(response)
                return value if value.get("version") == "0.1.13" else None
            except (OSError, ValueError):
                return None

        version = wait_until("packaged gateway version", version_ready, 90)
        stamped_sha = version.get("sha")
        require(isinstance(stamped_sha, str) and len(stamped_sha) >= 7
                and source.startswith(stamped_sha),
                "running gateway source differs from package")
        command([str(cli), "add-user", "acceptance"], gateway_env)
        producer = subprocess.Popen([str(watcher)], env=watcher_env,
                                    stdout=watcher_log, stderr=subprocess.STDOUT)

        def claim_live():
            data = json.loads(command([str(cli), "fact-producers"], gateway_env).stdout)
            return any(item["producer"] == "landing-watch" and item["live"]
                       and "pr.checks-completed" in item["kinds"] for item in data["producers"])

        wait_until("live watcher claim", claim_live, 60)
        wake = command([str(cli), "wake", "--user", "acceptance", "--when-fact",
                        "pr.checks-completed", "--when-scope", scope, "--fallback-after", "2h",
                        "--prompt", "Read the completed required checks", "--as-user", "acceptance"],
                       gateway_env)
        wake_result = json.loads(wake.stdout)
        require(not wake_result.get("warnings"),
                "wait creation warned that no producer was live")
        wake_id = wake_result["wakeId"]
        db = base / "state.db"

        def fired():
            with sqlite3.connect(db) as connection:
                row = connection.execute("SELECT state, firedBy FROM wakes WHERE wakeId=?", (wake_id,)).fetchone()
                facts = connection.execute(
                    "SELECT id FROM condition_facts WHERE kind=? AND scope=?",
                    ("pr.checks-completed", scope)).fetchall()
            return row if row and row[0] == "fired" and facts else None

        row = wait_until("real PR condition wake", fired, 180)
        require(row[1] == "condition", f"wake fired by {row[1]}, not condition")
        require(github_pr(scope, gh_env) == head, "PR head changed during acceptance")

        def demand_gone():
            data = json.loads(command([str(cli), "fact-demand", "--kind-prefix", "pr."],
                                      gateway_env).stdout)
            return not any(item["kind"] == "pr.checks-completed" and item["scope"] == scope
                           for item in data["demand"])

        wait_until("demand to clear", demand_gone, 30)
        reads = scratch / "gh-reads.jsonl"
        before = reads.read_text().splitlines()
        time.sleep(75)
        after = reads.read_text().splitlines()
        later = [json.loads(line) for line in after[len(before):]]
        number = scope.rsplit("#", 1)[1]
        require(not any(item["number"] == number and item["operation"] in
                        ("LandingPull", "LandingPullChecks", "LandingMergeChecks") for item in later),
                "watcher continued reading an undemanded PR")
        require(producer.poll() is None, "watcher stopped during acceptance")
        stopped = True
    finally:
        if producer is not None:
            producer.terminate()
            try:
                producer.wait(timeout=15)
            except subprocess.TimeoutExpired:
                stopped = False
        if server is not None:
            try:
                command([str(gateway), "stop"], gateway_env, timeout=30)
                server.wait(timeout=30)
            except (AcceptanceError, subprocess.TimeoutExpired):
                stopped = False
        gateway_log.close()
        watcher_log.close()
        if not stopped:
            print(f"acceptance scratch retained for inspection: {scratch}", file=sys.stderr)
            if sys.exc_info()[0] is None:
                raise AcceptanceError("acceptance processes did not stop cleanly")
    print(f"PASS scope={scope} head={head} wake={wake_id} firedBy=condition packageSource={source}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--feature-commit", required=True)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--gh-config-dir", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--scratch", required=True, help="new directory owned by this run")
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-f]{40}", args.feature_commit), "feature commit must be a full SHA")
    require(12000 <= args.port <= 65535, "acceptance port must be at least 12000")
    scratch = Path(args.scratch).expanduser().resolve()
    require(scratch.is_absolute() and not scratch.exists(), "scratch directory must not exist")
    require(Path(args.gh_config_dir).is_dir(), "existing GH_CONFIG_DIR is required")
    gh_env = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"],
              "GH_CONFIG_DIR": str(Path(args.gh_config_dir).resolve())}
    scratch.mkdir(mode=0o700)
    try:
        cli, gateway, watcher, source = verify_package(args, gh_env, scratch)
        run_acceptance(args, cli, gateway, watcher, source, gh_env, scratch)
    except Exception:
        print(f"acceptance scratch retained for inspection: {scratch}", file=sys.stderr)
        raise
    else:
        shutil.rmtree(scratch)


if __name__ == "__main__":
    try:
        main()
    except (AcceptanceError, OSError, ValueError, KeyError) as error:
        print(f"package acceptance: {error}", file=sys.stderr)
        sys.exit(1)
