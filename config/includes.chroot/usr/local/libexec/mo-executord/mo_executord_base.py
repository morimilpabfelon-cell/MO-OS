from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import pathlib
import re
import stat
import tempfile
from dataclasses import dataclass
from typing import Any, Iterator

SCHEMA_REQUEST = "morimil.executor.request.v0.1"


SCHEMA_RECEIPT = "morimil.executor.receipt.v0.1"


SCHEMA_STATE = "morimil.executor.request-state.v0.1"


SUPPORTED_OPERATIONS = {"system.status", "arch.status"}


TERMINAL_STATES = {"completed", "failed"}


PENDING_STATES = {"accepted", "executing"}


ALL_STATES = TERMINAL_STATES | PENDING_STATES


MAX_REQUEST_BYTES = 64 * 1024


MAX_SIGNATURE_TEXT_BYTES = 256


MAX_RECEIPT_BYTES = 128 * 1024


MAX_CORE_OUTPUT_BYTES = 128 * 1024


MAX_VALIDITY_SECONDS = 300


MAX_FUTURE_SKEW_SECONDS = 60


ID_PATTERN = re.compile(r"[a-z0-9][a-z0-9._:-]{0,127}")


NONCE_PATTERN = re.compile(r"[A-Za-z0-9_-]{16,128}")


REQUEST_KEYS = {
    "schema_version", "request_id", "instance_id", "controller_body_id",
    "target_executor_id", "operation", "issued_at", "expires_at", "nonce",
    "parameters",
}


STATE_KEYS = {
    "schema_version", "request_id", "request_sha256", "operation", "status",
    "accepted_at", "executing_at", "updated_at", "receipt_directory_id", "error",
}


RECEIPT_KEYS = {
    "schema_version", "request_id", "request_sha256", "executor_id", "operation",
    "status", "started_at", "completed_at", "output", "error",
}


class ExecutorError(RuntimeError):
    """Expected security or state-machine failure."""


@dataclass(frozen=True)
class CoreResult:
    returncode: int
    stdout: bytes
    stderr: bytes


@dataclass(frozen=True)
class VerifiedRequest:
    request: dict[str, Any]
    raw: bytes
    signature_text: bytes
    digest: str

    @property
    def request_id(self) -> str:
        return str(self.request["request_id"])

    @property
    def operation(self) -> str:
        return str(self.request["operation"])


class Layout:
    def __init__(self, root: pathlib.Path):
        self.root = root
        self.state = root / "var/lib/mo-bodyd"
        self.inbox = self.state / "inbox"
        self.outbox = self.state / "outbox"
        self.legacy_accepted = self.state / "accepted"
        self.failed = self.state / "failed"
        self.processed = self.state / "processed"
        self.quarantine = self.state / "quarantine"
        self.requests = self.state / "requests"
        self.staging = self.state / "staging"
        self.lock_file = self.state / "executor.lock"
        self.journal = self.state / "journal.jsonl"
        self.private_key = self.state / "identity/executor-private.pem"
        self.public_key = self.state / "identity/executor-public.pem"
        self.controller_key = root / "etc/mo/executor/morimil-controller.pem"

    def ensure(self) -> None:
        self.state.mkdir(parents=True, exist_ok=True)
        for path in (
            self.state, self.inbox, self.outbox, self.legacy_accepted, self.failed,
            self.processed, self.quarantine, self.requests, self.staging,
        ):
            path.mkdir(parents=True, exist_ok=True)
            metadata = path.lstat()
            if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
                raise ExecutorError("executor_state_directory_invalid")
            os.chmod(path, 0o700)

    def core(self) -> pathlib.Path:
        default = self.root / "usr/local/sbin/mo-bodyd"
        override = os.environ.get("MO_EXECUTORD_CORE")
        if override:
            if self.root == pathlib.Path("/") or os.environ.get("MO_BODYD_ALLOW_TEST_ROOT") != "1":
                raise ExecutorError("executor_core_override_forbidden")
            candidate = pathlib.Path(override)
        else:
            candidate = default
        if candidate.is_symlink() or not candidate.is_file():
            raise ExecutorError("executor_core_invalid")
        resolved = candidate.resolve()
        if resolved != candidate.absolute():
            raise ExecutorError("executor_core_path_not_canonical")
        metadata = candidate.stat()
        if metadata.st_mode & 0o022:
            raise ExecutorError("executor_core_permissions_invalid")
        return resolved


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def format_time(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_time(value: Any, field: str) -> dt.datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ExecutorError(f"{field}_invalid")
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise ExecutorError(f"{field}_invalid") from exc
    if parsed.microsecond or format_time(parsed) != value:
        raise ExecutorError(f"{field}_noncanonical")
    return parsed


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def resolve_root(value: str) -> pathlib.Path:
    root = pathlib.Path(value).resolve()
    if root != pathlib.Path("/"):
        if os.environ.get("MO_BODYD_ALLOW_TEST_ROOT") != "1":
            raise ExecutorError("non_root_target_requires_test_mode")
        if not (str(root).startswith("/tmp/") or str(root).startswith("/mnt/")):
            raise ExecutorError("test_root_must_be_below_tmp_or_mnt")
    return root


def require_root(root: pathlib.Path) -> None:
    if root == pathlib.Path("/") and os.geteuid() != 0:
        raise ExecutorError("root_privileges_required")


def validate_id(value: Any, field: str) -> str:
    if not isinstance(value, str) or not ID_PATTERN.fullmatch(value):
        raise ExecutorError(f"{field}_invalid")
    return value


def fsync_directory(path: pathlib.Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise ExecutorError("durable_write_failed")
        view = view[written:]


def read_regular_limited(path: pathlib.Path, maximum: int, prefix: str) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError as exc:
        raise ExecutorError(f"{prefix}_missing") from exc
    except OSError as exc:
        raise ExecutorError(f"{prefix}_open_failed") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ExecutorError(f"{prefix}_not_regular")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(8192, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise ExecutorError(f"{prefix}_size_invalid")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def read_json_regular(path: pathlib.Path, maximum: int, prefix: str) -> tuple[dict[str, Any], bytes]:
    raw = read_regular_limited(path, maximum, prefix)
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ExecutorError(f"{prefix}_invalid") from exc
    if not isinstance(value, dict):
        raise ExecutorError(f"{prefix}_object_required")
    return value, raw


def write_atomic_durable(path: pathlib.Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        if path.exists() or path.is_symlink():
            read_regular_limited(path, MAX_RECEIPT_BYTES, "state_existing")
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def write_exclusive_durable(path: pathlib.Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, mode)
    except FileExistsError as exc:
        raise ExecutorError("request_state_already_exists") from exc
    except OSError as exc:
        raise ExecutorError("request_state_create_failed") from exc
    try:
        write_all(descriptor, data)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    fsync_directory(path.parent)


def append_journal(layout: Layout, event: dict[str, Any]) -> None:
    record = dict(event)
    record["recorded_at"] = format_time(utc_now())
    descriptor = os.open(layout.journal, os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        write_all(descriptor, canonical_json(record))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


@contextlib.contextmanager
def executor_lock(layout: Layout) -> Iterator[None]:
    layout.ensure()
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(layout.lock_file, flags, 0o600)
    except OSError as exc:
        raise ExecutorError("executor_lock_open_failed") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ExecutorError("executor_lock_not_regular")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)

