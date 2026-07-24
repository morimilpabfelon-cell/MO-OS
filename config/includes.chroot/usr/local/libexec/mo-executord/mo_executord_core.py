from __future__ import annotations

import base64
import binascii
import contextlib
import datetime as dt
import hashlib
import importlib.machinery
import importlib.util
import io
import pathlib
import subprocess
import sys
import tempfile
from typing import Any

from mo_executord_base import *

_CORE_MODULES: dict[str, Any] = {}


def load_core(layout: Layout) -> Any:
    path = layout.core()
    key = str(path)
    cached = _CORE_MODULES.get(key)
    if cached is not None:
        return cached
    module_name = "mo_bodyd_core_" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
    loader = importlib.machinery.SourceFileLoader(module_name, str(path))
    spec = importlib.util.spec_from_loader(module_name, loader)
    if spec is None:
        raise ExecutorError("executor_core_import_invalid")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        sys.modules.pop(module_name, None)
        raise ExecutorError("executor_core_import_failed") from exc
    required = {
        "Layout", "BodydError", "initialize", "pair_controller", "show_status",
        "process_bundle",
    }
    if not all(hasattr(module, name) for name in required):
        raise ExecutorError("executor_core_api_invalid")
    _CORE_MODULES[key] = module
    return module


def run_core(layout: Layout, arguments: list[str], *, allow_failure: bool = False) -> CoreResult:
    core = load_core(layout)
    core_layout = core.Layout(layout.root)
    stdout = io.StringIO()
    stderr = io.StringIO()
    returncode = 0
    try:
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            command = arguments[0] if arguments else ""
            if command == "init" and len(arguments) == 1:
                core.initialize(core_layout)
            elif command == "pair":
                values: dict[str, str] = {}
                iterator = iter(arguments[1:])
                for item in iterator:
                    if item not in {"--controller-key", "--instance-id", "--controller-body-id"}:
                        raise ExecutorError("executor_core_arguments_invalid")
                    try:
                        values[item] = next(iterator)
                    except StopIteration as exc:
                        raise ExecutorError("executor_core_arguments_invalid") from exc
                if set(values) != {"--controller-key", "--instance-id", "--controller-body-id"}:
                    raise ExecutorError("executor_core_arguments_invalid")
                core.pair_controller(
                    core_layout, pathlib.Path(values["--controller-key"]),
                    values["--instance-id"], values["--controller-body-id"],
                )
            elif command == "status" and len(arguments) == 1:
                core.show_status(core_layout)
            elif command == "process" and len(arguments) == 3 and arguments[1] == "--bundle":
                print(core.process_bundle(core_layout, pathlib.Path(arguments[2])))
            else:
                raise ExecutorError("executor_core_arguments_invalid")
    except core.BodydError as exc:
        returncode = 1
        print(str(exc), file=stderr)
    output = stdout.getvalue().encode("utf-8")
    errors = stderr.getvalue().encode("utf-8")
    if len(output) > MAX_CORE_OUTPUT_BYTES or len(errors) > MAX_CORE_OUTPUT_BYTES:
        raise ExecutorError("executor_core_output_too_large")
    result = CoreResult(returncode=returncode, stdout=output, stderr=errors)
    if returncode != 0 and not allow_failure:
        detail = errors.decode("utf-8", "replace").strip()
        raise ExecutorError(detail or "executor_core_failed")
    return result


def core_status(layout: Layout) -> dict[str, Any]:
    completed = run_core(layout, ["status"])
    try:
        value = json.loads(completed.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ExecutorError("executor_core_status_invalid") from exc
    required = {"executor_id", "instance_id", "controller_body_id"}
    if not isinstance(value, dict) or not required.issubset(value):
        raise ExecutorError("executor_core_not_ready")
    for field in required:
        validate_id(value[field], field)
    return value


def verify_signature(public_key: pathlib.Path, payload: bytes, signature_text: bytes, prefix: str) -> None:
    if not signature_text or len(signature_text) > MAX_SIGNATURE_TEXT_BYTES:
        raise ExecutorError(f"{prefix}_size_invalid")
    try:
        signature = base64.b64decode(signature_text.strip(), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ExecutorError(f"{prefix}_encoding_invalid") from exc
    if len(signature) != 64:
        raise ExecutorError(f"{prefix}_length_invalid")
    key_bytes = read_regular_limited(public_key, 16 * 1024, f"{prefix}_key")
    with tempfile.NamedTemporaryFile(prefix="mo-executord-key-") as key_file, \
         tempfile.NamedTemporaryFile(prefix="mo-executord-payload-") as payload_file, \
         tempfile.NamedTemporaryFile(prefix="mo-executord-signature-") as signature_file:
        key_file.write(key_bytes)
        key_file.flush()
        payload_file.write(payload)
        payload_file.flush()
        signature_file.write(signature)
        signature_file.flush()
        completed = subprocess.run(
            ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", key_file.name,
             "-sigfile", signature_file.name, "-rawin", "-in", payload_file.name],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=False,
        )
    if completed.returncode != 0:
        raise ExecutorError(f"{prefix}_invalid")


def validate_request(layout: Layout, bundle: pathlib.Path, status: dict[str, Any]) -> VerifiedRequest:
    if not bundle.is_dir() or bundle.is_symlink():
        raise ExecutorError("request_bundle_missing")
    request, raw = read_json_regular(bundle / "request.json", MAX_REQUEST_BYTES, "request")
    signature_text = read_regular_limited(bundle / "request.sig", MAX_SIGNATURE_TEXT_BYTES, "request_signature")
    if set(request) != REQUEST_KEYS:
        raise ExecutorError("request_fields_invalid")
    if canonical_json(request) != raw:
        raise ExecutorError("request_not_canonical")
    verify_signature(layout.controller_key, raw, signature_text, "request_signature")
    if request.get("schema_version") != SCHEMA_REQUEST:
        raise ExecutorError("request_schema_unsupported")
    request_id = validate_id(request.get("request_id"), "request_id")
    operation = validate_id(request.get("operation"), "operation")
    if operation not in SUPPORTED_OPERATIONS:
        raise ExecutorError("operation_not_allowed")
    for field in ("instance_id", "controller_body_id", "target_executor_id"):
        validate_id(request.get(field), field)
    if request["instance_id"] != status["instance_id"]:
        raise ExecutorError("instance_mismatch")
    if request["controller_body_id"] != status["controller_body_id"]:
        raise ExecutorError("controller_mismatch")
    if request["target_executor_id"] != status["executor_id"]:
        raise ExecutorError("executor_target_mismatch")
    if not isinstance(request.get("nonce"), str) or not NONCE_PATTERN.fullmatch(request["nonce"]):
        raise ExecutorError("nonce_invalid")
    if not isinstance(request.get("parameters"), dict):
        raise ExecutorError("parameters_object_required")
    if request["parameters"]:
        raise ExecutorError(f"{operation.replace('.', '_')}_parameters_must_be_empty")
    issued = parse_time(request.get("issued_at"), "issued_at")
    expires = parse_time(request.get("expires_at"), "expires_at")
    current = utc_now()
    if expires <= issued or (expires - issued).total_seconds() > MAX_VALIDITY_SECONDS:
        raise ExecutorError("request_validity_window_invalid")
    if issued > current + dt.timedelta(seconds=MAX_FUTURE_SKEW_SECONDS):
        raise ExecutorError("request_issued_in_future")
    if expires < current:
        raise ExecutorError("request_expired")
    digest = "sha256:" + hashlib.sha256(raw).hexdigest()
    validate_id(request_id, "request_id")
    return VerifiedRequest(request=request, raw=raw, signature_text=signature_text, digest=digest)

