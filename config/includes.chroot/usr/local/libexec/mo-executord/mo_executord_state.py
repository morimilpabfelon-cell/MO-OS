from __future__ import annotations

import base64
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
from typing import Any

from mo_executord_base import *
from mo_executord_core import verify_signature

def state_path(layout: Layout, request_id: str) -> pathlib.Path:
    return layout.requests / f"{request_id}.json"


def validate_state(value: dict[str, Any], raw: bytes, request_id: str | None = None) -> dict[str, Any]:
    if set(value) != STATE_KEYS or value.get("schema_version") != SCHEMA_STATE:
        raise ExecutorError("request_state_schema_invalid")
    if canonical_json(value) != raw:
        raise ExecutorError("request_state_not_canonical")
    validate_id(value.get("request_id"), "request_id")
    validate_id(value.get("operation"), "operation")
    if request_id is not None and value["request_id"] != request_id:
        raise ExecutorError("request_state_id_mismatch")
    digest = value.get("request_sha256")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ExecutorError("request_state_digest_invalid")
    if value.get("status") not in ALL_STATES:
        raise ExecutorError("request_state_status_invalid")
    parse_time(value.get("accepted_at"), "state_accepted_at")
    parse_time(value.get("updated_at"), "state_updated_at")
    executing_at = value.get("executing_at")
    if executing_at is not None:
        parse_time(executing_at, "state_executing_at")
    if value["status"] == "accepted" and executing_at is not None:
        raise ExecutorError("request_state_transition_invalid")
    if value["status"] in {"executing", "completed"} and executing_at is None:
        raise ExecutorError("request_state_transition_invalid")
    receipt_id = value.get("receipt_directory_id")
    error = value.get("error")
    if value["status"] in PENDING_STATES:
        if receipt_id is not None or error is not None:
            raise ExecutorError("request_state_pending_fields_invalid")
    else:
        if receipt_id != value["request_id"]:
            raise ExecutorError("request_state_receipt_id_invalid")
        if value["status"] == "completed" and error is not None:
            raise ExecutorError("request_state_completed_error_invalid")
        if value["status"] == "failed" and (not isinstance(error, str) or not error):
            raise ExecutorError("request_state_failed_error_invalid")
    return value


def read_state(layout: Layout, request_id: str) -> dict[str, Any]:
    value, raw = read_json_regular(state_path(layout, request_id), MAX_RECEIPT_BYTES, "request_state")
    return validate_state(value, raw, request_id)


def new_state(verified: VerifiedRequest) -> dict[str, Any]:
    now = format_time(utc_now())
    return {
        "schema_version": SCHEMA_STATE,
        "request_id": verified.request_id,
        "request_sha256": verified.digest,
        "operation": verified.operation,
        "status": "accepted",
        "accepted_at": now,
        "executing_at": None,
        "updated_at": now,
        "receipt_directory_id": None,
        "error": None,
    }


def update_state(layout: Layout, state: dict[str, Any], target: str, error: str | None = None) -> dict[str, Any]:
    current = state["status"]
    allowed = {
        "accepted": {"executing", "failed"},
        "executing": {"completed", "failed"},
        "completed": set(),
        "failed": set(),
    }
    if target not in allowed[current]:
        raise ExecutorError("request_state_transition_invalid")
    updated = dict(state)
    now = format_time(utc_now())
    updated["status"] = target
    updated["updated_at"] = now
    if target == "executing":
        updated["executing_at"] = now
    if target in TERMINAL_STATES:
        updated["receipt_directory_id"] = updated["request_id"]
        updated["error"] = error if target == "failed" else None
    validate_state(updated, canonical_json(updated), updated["request_id"])
    write_atomic_durable(state_path(layout, updated["request_id"]), canonical_json(updated))
    return updated


def staging_path(layout: Layout, request_id: str, digest: str) -> pathlib.Path:
    return layout.staging / f"{request_id}-{digest.removeprefix('sha256:')[:16]}"


def snapshot_bundle(layout: Layout, bundle: pathlib.Path) -> pathlib.Path:
    if not bundle.is_dir() or bundle.is_symlink():
        raise ExecutorError("request_bundle_missing")
    request_raw = read_regular_limited(bundle / "request.json", MAX_REQUEST_BYTES, "request")
    signature_text = read_regular_limited(
        bundle / "request.sig", MAX_SIGNATURE_TEXT_BYTES, "request_signature",
    )
    temporary = pathlib.Path(tempfile.mkdtemp(prefix=".incoming.", dir=layout.staging))
    try:
        os.chmod(temporary, 0o700)
        write_exclusive_durable(temporary / "request.json", request_raw)
        write_exclusive_durable(temporary / "request.sig", signature_text)
        fsync_directory(temporary)
        fsync_directory(temporary.parent)
        return temporary
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def adopt_staging(layout: Layout, incoming: pathlib.Path, verified: VerifiedRequest) -> pathlib.Path:
    destination = staging_path(layout, verified.request_id, verified.digest)
    if destination.exists() or destination.is_symlink():
        raise ExecutorError("request_staging_already_exists")
    os.rename(incoming, destination)
    fsync_directory(destination.parent)
    return destination


def cleanup_staging(layout: Layout, state: dict[str, Any]) -> None:
    path = staging_path(layout, state["request_id"], state["request_sha256"])
    if path.exists() and not path.is_symlink():
        shutil.rmtree(path)
        fsync_directory(path.parent)


def sign_receipt(layout: Layout, receipt_path: pathlib.Path, signature_path: pathlib.Path) -> None:
    if not layout.private_key.is_file() or layout.private_key.is_symlink():
        raise ExecutorError("executor_private_key_missing")
    with tempfile.NamedTemporaryFile(prefix="mo-executord-signature-") as signature_file:
        completed = subprocess.run(
            ["openssl", "pkeyutl", "-sign", "-inkey", str(layout.private_key),
             "-rawin", "-in", str(receipt_path), "-out", signature_file.name],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=False,
        )
        if completed.returncode != 0:
            raise ExecutorError("receipt_signing_failed")
        signature_file.seek(0)
        signature = signature_file.read()
    if len(signature) != 64:
        raise ExecutorError("receipt_signature_length_invalid")
    write_exclusive_durable(signature_path, base64.b64encode(signature) + b"\n")


def write_failed_receipt(layout: Layout, core: dict[str, Any], state: dict[str, Any], error: str) -> pathlib.Path:
    destination = layout.outbox / state["request_id"]
    if destination.exists() or destination.is_symlink():
        raise ExecutorError("receipt_already_exists")
    temporary = pathlib.Path(tempfile.mkdtemp(prefix=f".{state['request_id']}.", dir=layout.outbox))
    try:
        receipt = {
            "schema_version": SCHEMA_RECEIPT,
            "request_id": state["request_id"],
            "request_sha256": state["request_sha256"],
            "executor_id": core["executor_id"],
            "operation": state["operation"],
            "status": "failed",
            "started_at": state["accepted_at"],
            "completed_at": format_time(utc_now()),
            "output": None,
            "error": error,
        }
        receipt_path = temporary / "receipt.json"
        write_exclusive_durable(receipt_path, canonical_json(receipt))
        sign_receipt(layout, receipt_path, temporary / "receipt.sig")
        os.chmod(temporary, 0o700)
        os.rename(temporary, destination)
        fsync_directory(layout.outbox)
        return destination
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def verify_receipt(layout: Layout, core: dict[str, Any], state: dict[str, Any]) -> tuple[pathlib.Path, dict[str, Any]]:
    directory = layout.outbox / state["request_id"]
    if not directory.is_dir() or directory.is_symlink():
        raise ExecutorError("recovery_receipt_missing")
    receipt, raw = read_json_regular(directory / "receipt.json", MAX_RECEIPT_BYTES, "recovery_receipt")
    if set(receipt) != RECEIPT_KEYS or receipt.get("schema_version") != SCHEMA_RECEIPT:
        raise ExecutorError("recovery_receipt_schema_invalid")
    if canonical_json(receipt) != raw:
        raise ExecutorError("recovery_receipt_not_canonical")
    if receipt.get("request_id") != state["request_id"]:
        raise ExecutorError("recovery_receipt_request_mismatch")
    if receipt.get("request_sha256") != state["request_sha256"]:
        raise ExecutorError("recovery_receipt_digest_mismatch")
    if receipt.get("executor_id") != core["executor_id"]:
        raise ExecutorError("recovery_receipt_executor_mismatch")
    if receipt.get("operation") != state["operation"]:
        raise ExecutorError("recovery_receipt_operation_mismatch")
    if receipt.get("status") not in TERMINAL_STATES:
        raise ExecutorError("recovery_receipt_status_invalid")
    parse_time(receipt.get("started_at"), "receipt_started_at")
    parse_time(receipt.get("completed_at"), "receipt_completed_at")
    if receipt["status"] == "completed":
        if receipt.get("error") is not None or not isinstance(receipt.get("output"), dict):
            raise ExecutorError("recovery_receipt_completed_fields_invalid")
    else:
        if not isinstance(receipt.get("error"), str) or not receipt["error"]:
            raise ExecutorError("recovery_receipt_failed_fields_invalid")
    signature_text = read_regular_limited(directory / "receipt.sig", MAX_SIGNATURE_TEXT_BYTES, "recovery_receipt_signature")
    verify_signature(layout.public_key, raw, signature_text, "recovery_receipt_signature")
    return directory, receipt


def ensure_legacy_marker(layout: Layout, state: dict[str, Any]) -> None:
    marker = layout.legacy_accepted / state["request_id"]
    if marker.exists() or marker.is_symlink():
        existing = read_regular_limited(marker, 256, "legacy_acceptance")
        if existing != (state["request_sha256"] + "\n").encode("ascii"):
            raise ExecutorError("legacy_acceptance_digest_mismatch")
        return
    write_exclusive_durable(marker, (state["request_sha256"] + "\n").encode("ascii"))


def recover_state(layout: Layout, core: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    if state["status"] in TERMINAL_STATES:
        return state
    receipt_directory = layout.outbox / state["request_id"]
    if receipt_directory.exists() or receipt_directory.is_symlink():
        _, receipt = verify_receipt(layout, core, state)
        error = receipt["error"] if receipt["status"] == "failed" else None
        recovered = update_state(layout, state, receipt["status"], error)
        append_journal(layout, {
            "event": "request_state_reconciled_from_receipt",
            "request_id": state["request_id"], "request_sha256": state["request_sha256"],
            "status": recovered["status"],
        })
        cleanup_staging(layout, recovered)
        return recovered
    if state["status"] == "accepted":
        error = "request_interrupted_after_acceptance"
    else:
        error = "request_execution_outcome_unknown_after_interruption"
    write_failed_receipt(layout, core, state, error)
    verify_receipt(layout, core, state)
    ensure_legacy_marker(layout, state)
    recovered = update_state(layout, state, "failed", error)
    append_journal(layout, {
        "event": "request_recovered_as_failed", "request_id": state["request_id"],
        "request_sha256": state["request_sha256"], "previous_status": state["status"],
        "error": error,
    })
    cleanup_staging(layout, recovered)
    return recovered


def recover_legacy(layout: Layout, core: dict[str, Any]) -> int:
    migrated = 0
    for marker in sorted(layout.legacy_accepted.iterdir()):
        if marker.name.startswith("."):
            continue
        request_id = validate_id(marker.name, "legacy_request_id")
        current_path = state_path(layout, request_id)
        if current_path.exists() or current_path.is_symlink():
            continue
        raw_digest = read_regular_limited(marker, 256, "legacy_acceptance").decode("ascii", "strict").strip()
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", raw_digest):
            raise ExecutorError("legacy_acceptance_digest_invalid")
        receipt_dir = layout.outbox / request_id
        if not receipt_dir.is_dir() or receipt_dir.is_symlink():
            raise ExecutorError("legacy_pending_request_requires_manual_recovery")
        receipt, receipt_raw = read_json_regular(receipt_dir / "receipt.json", MAX_RECEIPT_BYTES, "legacy_receipt")
        if set(receipt) != RECEIPT_KEYS or canonical_json(receipt) != receipt_raw:
            raise ExecutorError("legacy_receipt_invalid")
        operation = validate_id(receipt.get("operation"), "legacy_operation")
        if receipt.get("request_id") != request_id or receipt.get("request_sha256") != raw_digest:
            raise ExecutorError("legacy_receipt_identity_mismatch")
        accepted_at = receipt.get("started_at")
        parse_time(accepted_at, "legacy_started_at")
        status_value = receipt.get("status")
        if status_value not in TERMINAL_STATES:
            raise ExecutorError("legacy_receipt_status_invalid")
        state = {
            "schema_version": SCHEMA_STATE,
            "request_id": request_id,
            "request_sha256": raw_digest,
            "operation": operation,
            "status": status_value,
            "accepted_at": accepted_at,
            "executing_at": accepted_at,
            "updated_at": receipt.get("completed_at"),
            "receipt_directory_id": request_id,
            "error": receipt.get("error") if status_value == "failed" else None,
        }
        parse_time(state["updated_at"], "legacy_completed_at")
        validate_state(state, canonical_json(state), request_id)
        verify_receipt(layout, core, state)
        write_exclusive_durable(current_path, canonical_json(state))
        append_journal(layout, {"event": "legacy_request_state_migrated", "request_id": request_id})
        migrated += 1
    return migrated


def recover_locked(
    layout: Layout, core: dict[str, Any], *, verify_terminal: bool = False,
) -> dict[str, int]:
    migrated = recover_legacy(layout, core)
    recovered = 0
    terminal = 0
    for path in sorted(layout.requests.iterdir()):
        if path.name.startswith("."):
            continue
        if path.suffix != ".json":
            raise ExecutorError("request_state_filename_invalid")
        request_id = path.stem
        state = read_state(layout, request_id)
        previous = state["status"]
        if previous in TERMINAL_STATES and verify_terminal:
            _, receipt = verify_receipt(layout, core, state)
            if receipt["status"] != previous:
                raise ExecutorError("request_state_receipt_status_mismatch")
        state = recover_state(layout, core, state)
        if previous in PENDING_STATES:
            recovered += 1
        if state["status"] in TERMINAL_STATES:
            terminal += 1
    return {"migrated": migrated, "recovered": recovered, "terminal": terminal}


def maybe_crash(layout: Layout, phase: str) -> None:
    requested = os.environ.get("MO_EXECUTORD_TEST_CRASH_AFTER")
    if requested != phase:
        return
    if layout.root == pathlib.Path("/") or os.environ.get("MO_BODYD_ALLOW_TEST_ROOT") != "1":
        raise ExecutorError("test_crash_injection_forbidden")
    os._exit(97)
