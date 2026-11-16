#!/usr/bin/env python3
"""Render an exact release bundle from the reviewed maintenance sequence."""

import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
HEX64 = re.compile(r"^[0-9a-f]{64}$")
TOKEN = re.compile(r"^[a-zA-Z0-9._+/-]+$")


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def read_input(path):
    data = json.loads(path.read_text())
    data.pop("candidate", None)
    require(data["format"] == 1, "unsupported manifest format")
    require(data.get("purpose") in ("candidate-soak", "release-install"),
            "install purpose must name candidate-soak or release-install")
    old, new, paths, service = (data[k] for k in ("predecessor", "release", "paths", "service"))
    for value in (old["version"], new["version"]):
        require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){2}", value), "invalid version")
    for value in (old["build"], new["build"]):
        require(type(value) is int and value > 0, "invalid build number")
    for value in (old["build_id"],):
        require(re.fullmatch(r"sha256-[0-9a-f]{64}", value), "invalid predecessor build ID")
    require(re.fullmatch(r"[0-9a-f]{7,40}", old["source_prefix"]), "invalid predecessor source prefix")
    require(re.fullmatch(r"[0-9a-f]{40}", new["source_commit"]), "invalid source_commit")
    for key in ("package_sha256", "checksums_sha256", "provenance_sha256"):
        require(HEX64.fullmatch(new[key]), f"invalid {key}")
    require(new["build_id"] == "sha256-" + new["package_sha256"], "new build ID differs from package digest")
    require(new["build_id"] != old["build_id"], "release and predecessor builds are identical")
    require(new["tag"] == f'v{new["version"]}+{new["build"]}', "tag does not match version/build")
    require(new["package"] == f'tightbeam-{new["version"]}-linux-x86_64-{new["source_commit"][:7]}.tgz',
            "package name does not match the published Linux asset")
    for key in ("schema_effect", "startup_effects"):
        require(type(new.get(key)) is str and 0 < len(new[key]) <= 500 and
                not any(ord(ch) < 32 for ch in new[key]), f"invalid {key}")
    for value in list(paths.values()) + [service[k] for k in ("gateway", "maintenance", "user", "group", "working_directory")] + [new["package"], old["schema"], new["schema"]]:
        require(TOKEN.fullmatch(value), "manifest contains an unsafe token")
    for value in paths.values():
        require(value.startswith("/") and ".." not in Path(value).parts, "paths must be absolute and normalized")
    require(paths["database"] == paths["base"] + "/state.db", "database path differs from base")
    require(paths["current"] == paths["root"] + "/current", "selector path differs from root")
    require(paths["backup"].startswith(paths["backup_parent"] + "/"), "backup is outside its parent")
    require(set(data["required_paths"]) == {
        paths["database"], paths["base"] + "/gateway.json", paths["base"] + "/identity",
        paths["base"] + "/adapters", paths["base"] + "/homes", paths["base"] + "/state/users"
    }, "required paths do not match the maintenance sequence")
    require(service["gateway"] == "tightbeam.service", "unsupported gateway unit")
    require(service["maintenance"].endswith(".service"), "invalid maintenance unit")
    require(re.fullmatch(r"[a-z_][a-z0-9_-]*", service["user"]) and
            re.fullmatch(r"[a-z_][a-z0-9_-]*", service["group"]), "invalid service account")
    require(service["working_directory"].startswith("/") and
            ".." not in Path(service["working_directory"]).parts, "invalid working directory")
    for key, limit in (("stop_timeout_usec", 120_000_000),
                       ("start_timeout_usec", 90_000_000)):
        value = service[key]
        require(type(value) is str, f"invalid {key}")
        match = re.fullmatch(r"(?:(?:(\d+)min(?: (\d+)s)?)|(?:(\d+)s)|(\d+))", value)
        require(match is not None, f"invalid {key}")
        minutes, seconds, simple_seconds, microseconds = match.groups()
        duration = ((int(minutes or 0) * 60 + int(seconds or 0)) * 1_000_000
                    if minutes is not None else int(simple_seconds) * 1_000_000
                    if simple_seconds is not None else int(microseconds))
        require(0 < duration <= limit, f"{key} exceeds the reviewed service limit")
    require(type(data.get("preflight_files", [])) is list, "invalid preflight files")
    for file in data.get("preflight_files", []):
        require(type(file) is dict and set(file) == {"path", "sha256"} and
                isinstance(file["path"], str) and file["path"].startswith(paths["base"] + "/") and
                ".." not in Path(file["path"]).parts and
                type(file["sha256"]) is str and HEX64.fullmatch(file["sha256"]),
                "invalid preflight file")
    rehearsal = data.get("rehearsal")
    if rehearsal is not None:
        require(type(rehearsal) is dict, "rehearsal measurement must be an object")
        source_digest = rehearsal.get("source_bundle_sha256")
        require(type(source_digest) is str and HEX64.fullmatch(source_digest),
                "invalid rehearsal source bundle digest")
        for key in ("total_seconds", "outage_seconds", "expected_outage_max_seconds"):
            require(type(rehearsal.get(key)) is int and rehearsal[key] > 0,
                    f"invalid rehearsal {key}")
        require(rehearsal["outage_seconds"] <= rehearsal["total_seconds"],
                "outage exceeds total rehearsal duration")
        require(rehearsal["expected_outage_max_seconds"] >= rehearsal["outage_seconds"],
                "expected outage is below the measured outage")
        require(type(rehearsal.get("limits")) is str and
                0 < len(rehearsal["limits"]) <= 500 and "\n" not in rehearsal["limits"],
                "invalid rehearsal limits")
    return data


def render_job(data):
    old, new, paths, service = (data[k] for k in ("predecessor", "release", "paths", "service"))
    seed = (HERE / "maintenance-job.seed.sh").read_text()
    swaps = [
        ("__DATABASE__", paths["database"]),
        ("__BACKUP__", paths["backup"]),
        ("__BACKUP_PARENT__", paths["backup_parent"]),
        ("__LOG__", paths["log"]),
        ("__NODE__", paths["node"]),
        ("__BASE__", paths["base"]),
        ("__SERVICE_USER__", service["user"]),
        ("__SERVICE_GROUP__", service["group"]),
        ("__STOP_TIMEOUT_USEC__", service["stop_timeout_usec"]),
        ("__START_TIMEOUT_USEC__", service["start_timeout_usec"]),
        ("0\\.1\\.11", re.escape(new["version"])),
        ("0\\.1\\.9", re.escape(old["version"])),
        ("306f423d331405c544ef0dfce4649e0a5c208a0a", new["source_commit"]),
        ("9361f8b65b8f213941845da2481dc6aa3ca8ca9ad57afdc08cfbd47d4d07d7bd", new["package_sha256"]),
        ("sha256-e1af45213d14cbf37a256e72c8fa371027375ce7fb82dd70b5987564c521ee39", old["build_id"]),
        ("decision-request-row-schema-v2-019", old["schema"]),
        ("launch-preparation-boot-v1-0110", new["schema"]),
        ("tightbeam-0111-maintenance.service", service["maintenance"]),
        ("/opt/tightbeam", paths["root"]),
        ("8433d22", old["source_prefix"][:7]),
        ("306f423", new["source_commit"][:7]),
        ("3390", str(new["build"])),
        ("2908", str(old["build"])),
        ("0.1.11", new["version"]),
        ("0.1.9", old["version"]),
    ]
    for before, _ in swaps:
        require(before in seed, f"maintenance seed changed: {before}")
    replacements = dict(swaps)
    pattern = re.compile("|".join(re.escape(before) for before in
                                  sorted(replacements, key=len, reverse=True)))
    seed = pattern.sub(lambda match: replacements[match.group()], seed)
    require(not re.search(r"__[A-Z_]+__", seed), "unrendered maintenance placeholder")
    require("RUN " not in seed and "entry-confirmation" not in seed, "second confirmation remains")
    return seed


def render_rehearsal_summary(data):
    rehearsal = data.get("rehearsal")
    if rehearsal is None:
        return ("HOLD: This exact bundle has no completed full-size rehearsal or measured "
                "install duration and outage range. Record the exact capacity or test gap, "
                "complete the rehearsal, and render the measured bundle before an install request.")

    def minutes(seconds):
        return f"{seconds // 60} min {seconds % 60} sec"

    return (
        "The full-size synthetic rehearsal measured "
        f"{minutes(rehearsal['total_seconds'])} for the whole install and "
        f"{minutes(rehearsal['outage_seconds'])} from gateway stop to verified service readiness. "
        f"The proposed outage allowance is {minutes(rehearsal['expected_outage_max_seconds'])}; "
        "the matching exact-bundle rehearsal record must confirm it. "
        f"The timing source bundle has SHA-256 {rehearsal['source_bundle_sha256']}. "
        f"Limits: {rehearsal['limits']}"
    )


def render_purpose_summary(data):
    if data["purpose"] == "candidate-soak":
        candidate = data["candidate"]
        return (
            "This is an unpublished candidate built from main at the exact source commit above. "
            f"Candidate workflow run {candidate['run_id']} produced the package and proof manifest "
            f"{candidate['proof_manifest_sha256']}. The release tag {data['release']['tag']} is "
            "planned metadata only; no tag or GitHub Release exists for this candidate. "
            "The user must separately approve this exact install before its production soak. "
            "Publish these identical package bytes only if the soak is healthy. If the candidate "
            "fails a check or the soak finds a defect, keep it unpublished, fix the source through "
            "a reviewed main change, and build a fresh candidate."
        )
    return ("This is a later installation of the published release. Confirm the recorded "
            "candidate approval and healthy soak, and verify that promotion kept the exact "
            "package SHA-256. The earlier candidate-install yes does not authorize this install; "
            "request a separate exact whole-action yes.")


def verify_candidate_proof(data, assets, provenance, candidate_artifact=False):
    release = data["release"]
    candidate = provenance.get("candidate")
    require(type(candidate) is dict, "candidate provenance is missing its candidate run")
    run_id = candidate.get("run_id")
    workflow = candidate.get("workflow")
    workflow_sha = candidate.get("workflow_sha")
    proof_sha = candidate.get("proof_manifest_sha256")
    require(type(run_id) is str and run_id.isdigit(), "candidate provenance has an invalid run ID")
    require(type(workflow) is str and workflow.startswith("https://"),
            "candidate provenance has no HTTPS workflow run")
    require(type(workflow_sha) is str and re.fullmatch(r"[0-9a-f]{40}", workflow_sha),
            "candidate provenance has an invalid workflow SHA")
    require(type(proof_sha) is str and HEX64.fullmatch(proof_sha),
            "candidate provenance has an invalid proof-manifest digest")
    require(workflow.endswith(f"/clickety-clacks/tightbeam/actions/runs/{run_id}"),
            "candidate workflow URL does not bind its run ID and repository")

    proof_path = assets / "release-candidate-manifest.json"
    require(proof_path.is_file() and digest(proof_path) == proof_sha,
            "candidate proof manifest hash mismatch")
    proof_bytes = proof_path.read_bytes()
    proof = json.loads(proof_bytes)
    require(proof_bytes == (json.dumps(proof, sort_keys=True, separators=(",", ":")) + "\n").encode(),
            "candidate proof manifest is not canonical JSON")
    require(proof.get("schema") == "tightbeam-release-candidate-proof/v1" and
            proof.get("repository") == "clickety-clacks/tightbeam" and
            proof.get("candidate_ref") == "refs/heads/main" and
            proof.get("run_id") == run_id and
            proof.get("source_sha") == release["source_commit"] and
            proof.get("workflow_sha") == workflow_sha == release["source_commit"],
            "candidate proof does not bind this main run and exact source commit")

    packages = proof.get("packages")
    require(type(packages) is list and len(packages) == 2,
            "candidate proof must contain both platform packages")
    expected_platforms = ("darwin-aarch64", "linux-x86_64")
    selected_digest = None
    for row, platform in zip(packages, expected_platforms):
        require(type(row) is dict and row.get("platform") == platform and
                row.get("path") == f"packages/{platform}/tightbeam-{release['version']}-{platform}.tgz" and
                type(row.get("sha256")) is str and HEX64.fullmatch(row["sha256"]),
                f"candidate proof has an invalid {platform} package row")
        if platform == "linux-x86_64":
            selected_digest = row["sha256"]
    require(selected_digest == release["package_sha256"],
            "candidate Linux package bytes differ from the proof manifest")
    require(provenance.get("repository") == "clickety-clacks/tightbeam" and
            provenance.get("tag") == release["tag"] and
            provenance.get("commit") == release["source_commit"] and
            provenance.get("checksums") == "SHA256SUMS" and
            isinstance(provenance.get("workflow"), str) and provenance["workflow"] and
            (not candidate_artifact or provenance.get("workflow") == workflow) and
            isinstance(provenance.get("assets"), list) and
            provenance["assets"].count(release["package"]) == 1 and
            provenance["assets"].count("release-candidate-manifest.json") == 1,
            "candidate provenance does not bind this run, tag, source and assets")
    checksum_lines = (assets / "SHA256SUMS").read_text().splitlines()
    require(f"{release['package_sha256']}  {release['package']}" in checksum_lines and
            f"{proof_sha}  release-candidate-manifest.json" in checksum_lines,
            "candidate SHA256SUMS does not bind the package and proof manifest")
    return {
        "run_id": run_id,
        "workflow": workflow,
        "workflow_sha": workflow_sha,
        "proof_manifest_sha256": proof_sha,
    }


def main():
    require(len(sys.argv) == 4, "usage: render_release.py INPUT_JSON RELEASE_ASSETS_DIR OUTPUT_DIR")
    source = Path(sys.argv[1]); assets = Path(sys.argv[2]); out = Path(sys.argv[3])
    data = read_input(source)
    new = data["release"]
    require(not out.exists(), "output directory already exists")
    for name, expected in ((new["package"], new["package_sha256"]),
                           ("SHA256SUMS", new["checksums_sha256"]),
                           ("release-provenance.json", new["provenance_sha256"])):
        require((assets / name).is_file() and digest(assets / name) == expected, f"asset hash mismatch: {name}")
    provenance = json.loads((assets / "release-provenance.json").read_text())
    published_sums = (assets / "SHA256SUMS").read_text().splitlines()
    require(f'{new["package_sha256"]}  {new["package"]}' in published_sums,
            "release checksums do not bind the package")
    if data["purpose"] == "candidate-soak":
        require(provenance.get("format") == "tightbeam-release-candidate-provenance/v1",
                "candidate-soak requires unpublished candidate provenance")
        data["candidate"] = verify_candidate_proof(data, assets, provenance, candidate_artifact=True)
    else:
        require(provenance.get("repository") == "clickety-clacks/tightbeam" and
                provenance.get("tag") == new["tag"] and
                provenance.get("commit") == new["source_commit"] and
                provenance.get("checksums") == "SHA256SUMS" and
                isinstance(provenance.get("workflow"), str) and provenance["workflow"] and
                isinstance(provenance.get("assets"), list) and
                provenance["assets"].count(new["package"]) == 1,
                "release provenance does not bind this tag, source and package")
        candidate = provenance.get("candidate")
        if (data["purpose"] == "release-install" and type(candidate) is dict and
                type(candidate.get("workflow_sha")) is str and
                (assets / "release-candidate-manifest.json").is_file()):
            data["candidate"] = verify_candidate_proof(data, assets, provenance)
    out.mkdir(parents=True)
    job = out / "maintenance-job.sh"
    job.write_text(render_job(data)); job.chmod(0o500)
    data["job_sha256"] = digest(job)
    for name in (new["package"], "release-provenance.json"):
        shutil.copyfile(assets / name, out / name)
    if "candidate" in data:
        shutil.copyfile(assets / "release-candidate-manifest.json",
                        out / "release-candidate-manifest.json")
    shutil.copyfile(assets / "SHA256SUMS", out / "release-SHA256SUMS")
    manifest = out / "manifest.json"
    manifest.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    launcher = out / "install.sh"
    shutil.copyfile(HERE / "install.sh", launcher); launcher.chmod(0o500)
    sheet = out / "install-sheet.md"
    sheet.write_text((HERE / "install-sheet.md.in").read_text().format(
        tag=new["tag"], source=new["source_commit"], package=new["package"],
        package_sha=new["package_sha256"], job_sha=data["job_sha256"], manifest_sha=digest(manifest),
        launcher_sha=digest(launcher),
        purpose_summary=render_purpose_summary(data),
        old_version=data["predecessor"]["version"], old_build=data["predecessor"]["build"],
        old_schema=data["predecessor"]["schema"], new_schema=new["schema"],
        schema_effect=new["schema_effect"], startup_effects=new["startup_effects"],
        root=data["paths"]["root"], base=data["paths"]["base"], backup=data["paths"]["backup"],
        log=data["paths"]["log"], unit=data["service"]["gateway"],
        rehearsal_summary=render_rehearsal_summary(data)
    ))
    names = ["manifest.json", "maintenance-job.sh", "install.sh", "install-sheet.md",
             new["package"], "release-provenance.json", "release-SHA256SUMS"]
    if "candidate" in data:
        names.append("release-candidate-manifest.json")
    (out / "SHA256SUMS").write_text("".join(f"{digest(out / name)}  {name}\n" for name in names))
    print(json.dumps({"bundle": str(out), "manifest_sha256": digest(manifest),
                      "job_sha256": data["job_sha256"], "launcher_sha256": digest(launcher),
                      "checksums_sha256": digest(out / "SHA256SUMS")}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit(f"release bundle refused: {error}")
