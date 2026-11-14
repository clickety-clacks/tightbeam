#!/usr/bin/env python3
"""Manual TestFlight crash-submission sentinel for the Tightbeam organization."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable
from urllib.parse import quote, urlsplit


TOOL_NAME = "TestFlight sentinel"
PROCESS_IDENTITY = "testflight-sentinel"
ASC_HELPER = Path.home() / ".appstoreconnect" / "asc-api.py"
SHARED_WORKSPACE = Path("/mnt/shared-workspace")
CRASH_LOG_ROOT = SHARED_WORKSPACE / "shared/testflight-sentinel/crash-logs"
STATE_ROOT = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / PROCESS_IDENTITY
STATE_FILE = STATE_ROOT / "state.json"
LOG_FILE = STATE_ROOT / "testflight-sentinel.log"
API_HOST = "api.appstoreconnect.apple.com"
JWT_RE = re.compile(r"\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b")
JWT_FRAGMENT_RE = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\b")
PEM_PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
    re.DOTALL,
)


class SentinelError(Exception):
    """An error safe to show to the operator."""


class APIReadError(SentinelError):
    """A safe App Store Connect read failure."""


@dataclass(frozen=True)
class Report:
    app_id: str
    app_name: str
    report_id: str
    build_number: str | None
    app_version: str | None
    build_bundle_id: str | None
    device_model: str
    os_version: str
    submitted_at: str
    comment: str


@dataclass(frozen=True)
class PendingDelivery:
    report: Report
    log_path: Path | None
    log_reason: str | None


def _state_template() -> dict[str, Any]:
    return {"version": 1, "registrations": {}, "delivered": {}}


def load_state(path: Path = STATE_FILE) -> dict[str, Any]:
    if not path.exists():
        return _state_template()
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SentinelError(f"cannot read state file ({type(error).__name__})") from None
    if not isinstance(state, dict) or state.get("version") != 1:
        raise SentinelError("state file has an unknown format; refusing to change it")
    registrations = state.get("registrations")
    delivered = state.get("delivered")
    if not isinstance(registrations, dict) or not isinstance(delivered, dict):
        raise SentinelError("state file has an unknown format; refusing to change it")
    for app_id, recipients in registrations.items():
        if not _valid_app_id(app_id) or not isinstance(recipients, list):
            raise SentinelError("state file has an unknown format; refusing to change it")
        if any(not isinstance(recipient, str) or not recipient for recipient in recipients):
            raise SentinelError("state file has an unknown format; refusing to change it")
        if len(set(recipients)) != len(recipients):
            raise SentinelError("state file has an unknown format; refusing to change it")
    for app_id, recipients in delivered.items():
        if not _valid_app_id(app_id) or not isinstance(recipients, dict):
            raise SentinelError("state file has an unknown format; refusing to change it")
        for recipient, report_ids in recipients.items():
            if (
                not isinstance(recipient, str)
                or not recipient
                or not isinstance(report_ids, list)
                or any(not isinstance(report_id, str) or not report_id for report_id in report_ids)
                or len(set(report_ids)) != len(report_ids)
            ):
                raise SentinelError("state file has an unknown format; refusing to change it")
    return state


def save_state(state: dict[str, Any], path: Path = STATE_FILE) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temp_path = path.with_name(f".{path.name}.tmp")
    data = (json.dumps(state, sort_keys=True, indent=2) + "\n").encode("utf-8")
    fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, path)
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def _valid_app_id(value: Any) -> bool:
    return isinstance(value, str) and value.isascii() and value.isdigit()


def _validate_app_id(app_id: str) -> None:
    if not _valid_app_id(app_id):
        raise SentinelError("app ID must contain only digits")


def register_app(app_id: str, recipients: Iterable[str], state_path: Path = STATE_FILE) -> str:
    _validate_app_id(app_id)
    recipient_list = list(dict.fromkeys(recipients))
    if not recipient_list or any(not recipient for recipient in recipient_list):
        raise SentinelError("register needs one or more recipient session keys")
    state = load_state(state_path)
    current = state["registrations"].setdefault(app_id, [])
    added = [recipient for recipient in recipient_list if recipient not in current]
    if not added:
        return f"app {app_id}: already registered"
    current.extend(added)
    current.sort()
    save_state(state, state_path)
    if len(added) == 1:
        return f"app {app_id}: registered recipient {added[0]}"
    return f"app {app_id}: registered {len(added)} recipients"


def unregister_app(
    app_id: str,
    recipient: str | None = None,
    state_path: Path = STATE_FILE,
) -> str:
    _validate_app_id(app_id)
    state = load_state(state_path)
    recipients = state["registrations"].get(app_id)
    if recipients is None:
        return f"app {app_id}: not registered"
    if recipient is None:
        del state["registrations"][app_id]
        save_state(state, state_path)
        return f"app {app_id}: unregistered"
    if recipient not in recipients:
        return f"app {app_id}: recipient not registered"
    remaining = [current for current in recipients if current != recipient]
    if remaining:
        state["registrations"][app_id] = remaining
    else:
        del state["registrations"][app_id]
    save_state(state, state_path)
    return f"app {app_id}: unregistered recipient {recipient}"


def registration_lines(state_path: Path = STATE_FILE) -> list[str]:
    state = load_state(state_path)
    return [
        f"app {app_id}: {', '.join(recipients)}"
        for app_id, recipients in sorted(state["registrations"].items())
    ]


def load_asc_helper(path: Path = ASC_HELPER) -> Any:
    if not path.is_file():
        raise SentinelError("the existing App Store Connect helper was not found")
    try:
        spec = importlib.util.spec_from_file_location("testflight_sentinel_asc_helper", path)
        if spec is None or spec.loader is None:
            raise ImportError
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if not callable(getattr(module, "api_get", None)):
            raise ImportError
        return module
    except Exception:
        raise SentinelError("the existing App Store Connect helper could not be loaded") from None


def helper_secret_values(helper: Any) -> tuple[str, ...]:
    """Return helper-held identifiers only for in-memory redaction; never display them."""
    return tuple(
        value
        for value in (getattr(helper, "KEY_ID", ""), getattr(helper, "ISSUER_ID", ""))
        if isinstance(value, str) and value
    )


def sanitize(text: str, secrets: Iterable[str] = ()) -> str:
    text = PEM_PRIVATE_KEY_RE.sub("[redacted private key]", text)
    text = JWT_RE.sub("[redacted token]", text)
    text = JWT_FRAGMENT_RE.sub("[redacted token]", text)
    for secret in secrets:
        text = text.replace(secret, "[redacted]")
    return text


def log_event(message: str, log_path: Path = LOG_FILE, secrets: Iterable[str] = ()) -> None:
    try:
        log_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(log_path.parent, 0o700)
        safe_message = sanitize(message, secrets).replace("\r", " ").replace("\n", " ")
        timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            with os.fdopen(fd, "a", encoding="utf-8") as stream:
                stream.write(f"{timestamp} {safe_message}\n")
        finally:
            os.chmod(log_path, 0o600)
    except OSError as error:
        raise SentinelError(f"sentinel log could not be written ({error.errno or 'file error'})") from None


def _safe_error_code(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value if re.fullmatch(r"[A-Za-z0-9_-]{1,80}", value) else None


def _raise_for_api_errors(body: Any) -> None:
    if not isinstance(body, dict) or not body.get("errors"):
        return
    first = body["errors"][0] if isinstance(body["errors"], list) else {}
    if not isinstance(first, dict):
        first = {}
    status = _safe_error_code(first.get("status"))
    code = _safe_error_code(first.get("code"))
    detail = " ".join(part for part in (status, code) if part)
    raise APIReadError(f"App Store Connect error {detail}" if detail else "App Store Connect returned an error")


def api_get(helper: Any, endpoint: str) -> Any:
    try:
        body = helper.api_get(endpoint)
    except Exception:
        raise APIReadError("App Store Connect request failed") from None
    _raise_for_api_errors(body)
    return body


def _data_resource(body: Any, description: str) -> dict[str, Any]:
    _raise_for_api_errors(body)
    if not isinstance(body, dict) or not isinstance(body.get("data"), dict):
        raise APIReadError(f"App Store Connect did not return {description}")
    return body["data"]


def _next_endpoint(next_link: Any, current_endpoint: str) -> str | None:
    if next_link is None:
        return None
    if not isinstance(next_link, str) or not next_link:
        raise APIReadError("App Store Connect returned an invalid pagination link")
    parsed = urlsplit(next_link)
    if parsed.scheme or parsed.netloc:
        if parsed.scheme != "https" or parsed.netloc != API_HOST or not parsed.path.startswith("/v1/"):
            raise APIReadError("App Store Connect returned an invalid pagination link")
        return parsed.path[len("/v1/") :] + (f"?{parsed.query}" if parsed.query else "")
    if parsed.path.startswith("/v1/"):
        return parsed.path[len("/v1/") :] + (f"?{parsed.query}" if parsed.query else "")
    if not parsed.path and parsed.query:
        return current_endpoint.split("?", 1)[0] + f"?{parsed.query}"
    if parsed.path.startswith("apps/"):
        return parsed.path + (f"?{parsed.query}" if parsed.query else "")
    raise APIReadError("App Store Connect returned an invalid pagination link")


def iter_submissions(helper: Any, app_id: str) -> Iterable[dict[str, Any]]:
    endpoint: str | None = f"apps/{quote(app_id, safe='')}/betaFeedbackCrashSubmissions?limit=200"
    seen_pages: set[str] = set()
    while endpoint is not None:
        if endpoint in seen_pages:
            raise APIReadError("App Store Connect pagination repeated a page")
        seen_pages.add(endpoint)
        body = api_get(helper, endpoint)
        if not isinstance(body, dict) or not isinstance(body.get("data"), list):
            raise APIReadError("App Store Connect did not return crash submissions")
        for resource in body["data"]:
            if not isinstance(resource, dict) or not isinstance(resource.get("id"), str):
                raise APIReadError("App Store Connect returned an invalid crash submission")
            yield resource
        links = body.get("links") if isinstance(body.get("links"), dict) else {}
        endpoint = _next_endpoint(links.get("next"), endpoint)


def _relationship_id(resource: dict[str, Any], name: str) -> str | None:
    relationships = resource.get("relationships")
    if not isinstance(relationships, dict):
        return None
    relationship = relationships.get(name)
    if not isinstance(relationship, dict):
        return None
    data = relationship.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("id"), str):
        return None
    return data["id"]


def _fetch_build(helper: Any, build_id: str) -> tuple[str | None, str | None]:
    try:
        resource = _data_resource(
            api_get(helper, f"builds/{quote(build_id, safe='')}"),
            "build details",
        )
    except APIReadError:
        return None, None
    attributes = resource.get("attributes") if isinstance(resource.get("attributes"), dict) else {}
    build_number = attributes.get("version")
    if not isinstance(build_number, (str, int)) or not str(build_number):
        build_number = None
    pre_release_id = _relationship_id(resource, "preReleaseVersion")
    app_version = None
    if pre_release_id:
        try:
            pre_release = _data_resource(
                api_get(helper, f"preReleaseVersions/{quote(pre_release_id, safe='')}"),
                "app version",
            )
            pre_release_attributes = (
                pre_release.get("attributes") if isinstance(pre_release.get("attributes"), dict) else {}
            )
            version = pre_release_attributes.get("version")
            if isinstance(version, str) and version:
                app_version = version
        except APIReadError:
            # A crash-log header can supply version/build lines when this read is incomplete.
            app_version = None
    return str(build_number) if build_number is not None else None, app_version


def _string_attribute(attributes: dict[str, Any], name: str, fallback: str) -> str:
    value = attributes.get(name)
    return value if isinstance(value, str) and value else fallback


def _required_string_attribute(attributes: dict[str, Any], name: str, label: str) -> str:
    value = attributes.get(name)
    if not isinstance(value, str) or not value:
        raise APIReadError(f"App Store Connect did not return {label}")
    return value


def _pending_reports(
    helper: Any,
    app_id: str,
    recipients: list[str],
    delivered: dict[str, list[str]],
) -> tuple[str, list[Report]]:
    app_resource = _data_resource(api_get(helper, f"apps/{quote(app_id, safe='')}"), "app details")
    app_attributes = app_resource.get("attributes") if isinstance(app_resource.get("attributes"), dict) else {}
    app_name = app_attributes.get("name")
    if not isinstance(app_name, str) or not app_name:
        raise APIReadError("App Store Connect did not return an app name")
    submissions = list(iter_submissions(helper, app_id))
    pending = [
        submission
        for submission in submissions
        if any(submission["id"] not in delivered.get(recipient, []) for recipient in recipients)
    ]
    builds: dict[str, tuple[str | None, str | None]] = {}
    reports: list[Report] = []
    for submission in pending:
        build_id = _relationship_id(submission, "build")
        if build_id and build_id not in builds:
            builds[build_id] = _fetch_build(helper, build_id)
        build_number, app_version = (
            builds[build_id] if build_id else (None, None)
        )
        attributes = submission.get("attributes") if isinstance(submission.get("attributes"), dict) else {}
        submitted_at = _required_string_attribute(attributes, "createdDate", "submission time")
        try:
            parsed_time = datetime.fromisoformat(submitted_at.replace("Z", "+00:00"))
        except ValueError:
            raise APIReadError("App Store Connect returned an invalid submission time") from None
        if parsed_time.tzinfo is None:
            raise APIReadError("App Store Connect returned a submission time without a time zone")
        reports.append(
            Report(
                app_id=app_id,
                app_name=app_name,
                report_id=submission["id"],
                build_number=build_number,
                app_version=app_version,
                build_bundle_id=_string_attribute(attributes, "buildBundleId", "") or None,
                device_model=_required_string_attribute(attributes, "deviceModel", "device model"),
                os_version=_required_string_attribute(attributes, "osVersion", "OS version"),
                submitted_at=submitted_at,
                comment=_string_attribute(attributes, "comment", "no comment"),
            )
        )
    return app_name, reports


def _save_crash_log(
    helper: Any,
    app_id: str,
    report_id: str,
    crash_log_root: Path,
    secrets: Iterable[str],
) -> tuple[Path | None, str | None, str | None]:
    path = crash_log_root / app_id / f"{report_id}.crash"
    if path.is_file():
        try:
            return path, None, path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return path, None, None
    try:
        body = api_get(
            helper,
            f"betaFeedbackCrashSubmissions/{quote(report_id, safe='')}/crashLog",
        )
        if not isinstance(body, dict) or not isinstance(body.get("data"), dict):
            return None, "App Store Connect returned no crash log", None
        resource = body["data"]
        attributes = resource.get("attributes") if isinstance(resource.get("attributes"), dict) else {}
        log_text = attributes.get("logText")
        if not isinstance(log_text, str):
            return None, "App Store Connect returned no crash log text", None
    except APIReadError as error:
        return None, str(error), None
    safe_log_text = sanitize(log_text, secrets)
    try:
        path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        temp_path = path.with_name(f".{path.name}.tmp")
        fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
                stream.write(safe_log_text)
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(temp_path, 0o644)
            os.replace(temp_path, path)
        finally:
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass
    except OSError as error:
        return None, f"crash log could not be saved ({error.errno or 'file error'})", None
    return path, None, safe_log_text


def _single_line(value: str) -> str:
    return re.sub(r"[\r\n\t]+", " ", value).strip()


def _crash_header_build(log_text: str) -> tuple[str | None, str | None]:
    app_version = None
    build_number = None
    for line in log_text.splitlines():
        version_match = re.fullmatch(r"\s*Version:\s*(.*?)\s*", line, re.IGNORECASE)
        if version_match and version_match.group(1):
            value = version_match.group(1)
            combined = re.fullmatch(r"(.+?)\s+\(([^()]+)\)", value)
            if combined:
                app_version = app_version or combined.group(1).strip()
                build_number = build_number or combined.group(2).strip()
            else:
                app_version = app_version or value.strip()
        build_match = re.fullmatch(r"\s*Build:\s*(\S+)\s*", line, re.IGNORECASE)
        if build_match:
            build_number = build_number or build_match.group(1)
        if re.match(
            r"^(?:Exception Type|Exception Subtype|Termination Reason|Triggered by Thread|Thread \d+|Binary Images):",
            line,
        ):
            break
    return app_version, build_number


def _report_with_crash_header(report: Report, log_text: str | None) -> Report:
    if not log_text:
        return report
    header_version, header_build = _crash_header_build(log_text)
    return replace(
        report,
        build_number=report.build_number or header_build,
        app_version=report.app_version or header_version,
    )


def build_wake(
    reports: list[PendingDelivery],
    secrets: Iterable[str] = (),
    workspace_root: Path = SHARED_WORKSPACE,
) -> str:
    count = len(reports)
    lines = [f"{TOOL_NAME}: {count} new crash report{'s' if count != 1 else ''}"]
    for delivery in reports:
        report = delivery.report
        comment = json.dumps(report.comment, ensure_ascii=False)
        build_field = "build not reported"
        if report.build_number:
            build = report.build_number
            if report.app_version:
                build = f"{report.app_version} ({build})"
            build_field = f"build {_single_line(build)}"
        elif report.build_bundle_id:
            build_field = (
                f"buildBundleId: {_single_line(report.build_bundle_id)}; "
                "build not reported"
            )
        fields = [
            report.report_id,
            f"{_single_line(report.app_name)} ({report.app_id})",
            build_field,
            _single_line(report.device_model),
            f"iOS {_single_line(report.os_version)}",
            _single_line(report.submitted_at),
            f"comment: {comment}",
        ]
        if not report.build_number and report.app_version:
            fields.append(f"app version: {_single_line(report.app_version)}")
        if delivery.log_path:
            relative = delivery.log_path.relative_to(workspace_root)
            fields.append(f"log: {delivery.log_path} ({relative.as_posix()})")
        else:
            fields.append(f"crash log not saved: {delivery.log_reason or 'reason unavailable'}")
        lines.append(" · ".join(fields))
    return sanitize("\n".join(lines), secrets)


def send_wake(recipient: str, prompt: str) -> bool:
    try:
        result = subprocess.run(
            [
                "tightbeam",
                "wake",
                "--session",
                recipient,
                "--prompt",
                prompt,
                "--as-process",
                PROCESS_IDENTITY,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return False
    return result.returncode == 0


def run_check(
    state_path: Path = STATE_FILE,
    log_path: Path = LOG_FILE,
    crash_log_root: Path = CRASH_LOG_ROOT,
    workspace_root: Path = SHARED_WORKSPACE,
    helper: Any | None = None,
    wake: Callable[[str, str], bool] = send_wake,
) -> dict[str, int]:
    state = load_state(state_path)
    if not state["registrations"]:
        return {"reports": 0, "wakes": 0, "errors": 0}
    if helper is None:
        helper = load_asc_helper()
    secrets = helper_secret_values(helper)
    by_recipient: dict[str, list[PendingDelivery]] = {}
    failed_apps = 0
    for app_id, recipients in sorted(state["registrations"].items()):
        delivered = state["delivered"].get(app_id, {})
        try:
            _, reports = _pending_reports(helper, app_id, recipients, delivered)
        except APIReadError as error:
            log_event(f"app {app_id}: {error}", log_path, secrets)
            failed_apps += 1
            continue
        for report in reports:
            pending_recipients = [
                recipient
                for recipient in recipients
                if report.report_id not in delivered.get(recipient, [])
            ]
            if not pending_recipients:
                continue
            log_path_for_report, log_reason, log_text = _save_crash_log(
                helper, app_id, report.report_id, crash_log_root, secrets
            )
            if log_reason:
                log_event(f"app {app_id} report {report.report_id}: {log_reason}", log_path, secrets)
            report = _report_with_crash_header(report, log_text)
            for recipient in pending_recipients:
                by_recipient.setdefault(recipient, []).append(
                    PendingDelivery(report, log_path_for_report, log_reason)
                )

    sent_reports = 0
    accepted_wakes = 0
    failed_wakes = 0
    for recipient, deliveries in sorted(by_recipient.items()):
        prompt = build_wake(deliveries, secrets, workspace_root)
        if not wake(recipient, prompt):
            log_event(f"recipient {recipient}: Tightbeam wake failed", log_path, secrets)
            failed_wakes += 1
            continue
        accepted_wakes += 1
        try:
            for delivery in deliveries:
                app_delivery = state["delivered"].setdefault(delivery.report.app_id, {}).setdefault(recipient, [])
                if delivery.report.report_id not in app_delivery:
                    app_delivery.append(delivery.report.report_id)
                    app_delivery.sort()
            save_state(state, state_path)
            sent_reports += len(deliveries)
        except OSError as error:
            log_event(
                f"recipient {recipient}: accepted wake but delivery history could not be saved ({error.errno or 'file error'})",
                log_path,
                secrets,
            )
            failed_wakes += 1
    return {"reports": sent_reports, "wakes": accepted_wakes, "errors": failed_apps + failed_wakes}


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="testflight-sentinel", description=TOOL_NAME)
    commands = parser.add_subparsers(dest="command", required=True)
    register = commands.add_parser("register", help="register an App Store Connect app and recipient")
    register.add_argument("--app", required=True)
    register.add_argument("--recipient", action="append", required=True)
    unregister = commands.add_parser("unregister", help="unregister an app or one recipient")
    unregister.add_argument("--app", required=True)
    unregister.add_argument("--recipient")
    commands.add_parser("list", help="list current registrations")
    commands.add_parser("check", help="read registered crash submissions and deliver new reports")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.command == "register":
            print(register_app(args.app, args.recipient))
            return 0
        if args.command == "unregister":
            print(unregister_app(args.app, args.recipient))
            return 0
        if args.command == "list":
            lines = registration_lines()
            print("\n".join(lines) if lines else "no apps registered")
            return 0
        result = run_check()
        print(
            f"check complete: {result['reports']} reports delivered in {result['wakes']} wakes; "
            f"{result['errors']} errors"
        )
        return 1 if result["errors"] else 0
    except SentinelError as error:
        safe_error = sanitize(str(error))
        print(f"testflight-sentinel: {safe_error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(
            f"testflight-sentinel: local file operation failed ({error.errno or 'file error'})",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
