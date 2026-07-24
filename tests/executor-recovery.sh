#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
coordinator="${MO_TEST_EXECUTORD:-$repo_root/config/includes.chroot/usr/local/sbin/mo-executord}"
core="${MO_TEST_BODYD_CORE:-$repo_root/config/includes.chroot/usr/local/sbin/mo-bodyd}"
coordinator_cmd=(python3 "$coordinator")
coordinator_module_dir="$(cd "$(dirname "$coordinator")/../libexec/mo-executord" && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
root="$workdir/root"
mkdir -p "$root/etc" "$root/var/lib/machines/mo-dev"
cat > "$root/etc/mo-release" <<'EOF_RELEASE'
NAME="MO OS"
VERSION="0.6.0-alpha.1"
ARCHITECTURE="amd64"
EOF_RELEASE
export MO_BODYD_ALLOW_TEST_ROOT=1
export MO_EXECUTORD_CORE="$core"

PYTHONPYCACHEPREFIX="$workdir/pycache" python3 -m py_compile \
  "$coordinator" "$core" "$coordinator_module_dir"/*.py
"${coordinator_cmd[@]}" --root "$root" init > "$workdir/identity.json"
openssl genpkey -algorithm ED25519 -out "$workdir/controller-private.pem" >/dev/null 2>&1
openssl pkey -in "$workdir/controller-private.pem" -pubout \
  -out "$workdir/controller-public.pem" >/dev/null 2>&1
"${coordinator_cmd[@]}" --root "$root" pair \
  --controller-key "$workdir/controller-public.pem" \
  --instance-id "instance:test-001" \
  --controller-body-id "controller:morimil-001" > "$workdir/pairing.json"

executor_id="$("${coordinator_cmd[@]}" --root "$root" status | python3 -c 'import json,sys; print(json.load(sys.stdin)["executor_id"])')"

make_request() {
  local bundle=$1 request_id=$2 nonce=${3:-abcdefghijklmnopQRSTUVWX01234567}
  mkdir -p "$bundle"
  python3 - "$bundle/request.json" "$request_id" "$executor_id" "$nonce" <<'PY_REQUEST'
import datetime as dt
import json
import pathlib
import sys
path, request_id, executor_id, nonce = sys.argv[1:]
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
format_time = lambda value: value.isoformat().replace("+00:00", "Z")
request = {
    "schema_version": "morimil.executor.request.v0.1",
    "request_id": request_id,
    "instance_id": "instance:test-001",
    "controller_body_id": "controller:morimil-001",
    "target_executor_id": executor_id,
    "operation": "system.status",
    "issued_at": format_time(now),
    "expires_at": format_time(now + dt.timedelta(seconds=240)),
    "nonce": nonce,
    "parameters": {},
}
pathlib.Path(path).write_text(
    json.dumps(request, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY_REQUEST
  openssl pkeyutl -sign \
    -inkey "$workdir/controller-private.pem" \
    -rawin -in "$bundle/request.json" \
    -out "$bundle/request.sig.bin"
  base64 -w0 "$bundle/request.sig.bin" > "$bundle/request.sig"
  printf '\n' >> "$bundle/request.sig"
  rm "$bundle/request.sig.bin"
}

assert_state() {
  local request_id=$1 expected=$2
  python3 - "$root/var/lib/mo-bodyd/requests/${request_id}.json" "$expected" <<'PY_STATE'
import json
import pathlib
import sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert state["schema_version"] == "morimil.executor.request-state.v0.1", state
assert state["status"] == sys.argv[2], state
PY_STATE
}

assert_receipt() {
  local request_id=$1 expected_status=$2 expected_error=${3:-}
  local receipt_dir="$root/var/lib/mo-bodyd/outbox/$request_id"
  python3 - "$receipt_dir/receipt.json" "$request_id" "$expected_status" "$expected_error" <<'PY_RECEIPT'
import json
import pathlib
import sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["request_id"] == sys.argv[2], receipt
assert receipt["status"] == sys.argv[3], receipt
if sys.argv[4]:
    assert receipt["error"] == sys.argv[4], receipt
PY_RECEIPT
  base64 -d "$receipt_dir/receipt.sig" > "$workdir/${request_id}.sig.bin"
  openssl pkeyutl -verify -pubin \
    -inkey "$root/var/lib/mo-bodyd/identity/executor-public.pem" \
    -sigfile "$workdir/${request_id}.sig.bin" -rawin \
    -in "$receipt_dir/receipt.json" >/dev/null
}

run_crash() {
  local phase=$1 bundle=$2
  set +e
  MO_EXECUTORD_TEST_CRASH_AFTER="$phase" \
    "${coordinator_cmd[@]}" --root "$root" process --bundle "$bundle" \
    >"$workdir/crash-${phase}.out" 2>"$workdir/crash-${phase}.err"
  local rc=$?
  set -e
  [[ "$rc" -eq 97 ]] || {
    echo "Crash injection at $phase returned $rc instead of 97." >&2
    cat "$workdir/crash-${phase}.err" >&2 || true
    exit 1
  }
}

# Interruption after durable acceptance: fail closed without execution.
accepted_bundle="$workdir/request-accepted"
make_request "$accepted_bundle" req-recover-accepted
run_crash accepted "$accepted_bundle"
assert_state req-recover-accepted accepted
"${coordinator_cmd[@]}" --root "$root" recover > "$workdir/recover-accepted.json"
grep -Fq '"recovered":1' "$workdir/recover-accepted.json"
assert_state req-recover-accepted failed
assert_receipt req-recover-accepted failed request_interrupted_after_acceptance

# Interruption after entering executing: outcome is unknown and is never retried.
executing_bundle="$workdir/request-executing"
make_request "$executing_bundle" req-recover-executing
run_crash executing "$executing_bundle"
assert_state req-recover-executing executing
"${coordinator_cmd[@]}" --root "$root" recover > "$workdir/recover-executing.json"
assert_state req-recover-executing failed
assert_receipt req-recover-executing failed request_execution_outcome_unknown_after_interruption

# Receipt published before terminal state: verify and reconcile without rewriting it.
receipt_bundle="$workdir/request-receipt"
make_request "$receipt_bundle" req-recover-receipt
run_crash receipt "$receipt_bundle"
assert_state req-recover-receipt executing
receipt_before="$(sha256sum "$root/var/lib/mo-bodyd/outbox/req-recover-receipt/receipt.json")"
signature_before="$(sha256sum "$root/var/lib/mo-bodyd/outbox/req-recover-receipt/receipt.sig")"
"${coordinator_cmd[@]}" --root "$root" recover > "$workdir/recover-receipt.json"
assert_state req-recover-receipt completed
assert_receipt req-recover-receipt completed
[[ "$receipt_before" == "$(sha256sum "$root/var/lib/mo-bodyd/outbox/req-recover-receipt/receipt.json")" ]]
[[ "$signature_before" == "$(sha256sum "$root/var/lib/mo-bodyd/outbox/req-recover-receipt/receipt.sig")" ]]

# Two processes with one request_id: exactly one execution succeeds.
concurrent_a="$workdir/request-concurrent-a"
concurrent_b="$workdir/request-concurrent-b"
make_request "$concurrent_a" req-concurrent
cp -a "$concurrent_a" "$concurrent_b"
set +e
"${coordinator_cmd[@]}" --root "$root" process --bundle "$concurrent_a" \
  >"$workdir/concurrent-a.out" 2>"$workdir/concurrent-a.err" &
pid_a=$!
"${coordinator_cmd[@]}" --root "$root" process --bundle "$concurrent_b" \
  >"$workdir/concurrent-b.out" 2>"$workdir/concurrent-b.err" &
pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
set -e
if ! { [[ "$rc_a" -eq 0 && "$rc_b" -ne 0 ]] || [[ "$rc_b" -eq 0 && "$rc_a" -ne 0 ]]; }; then
  echo "Concurrent processing did not produce exactly one success: $rc_a $rc_b" >&2
  exit 1
fi
cat "$workdir/concurrent-a.err" "$workdir/concurrent-b.err" | grep -Fq request_replay_rejected
assert_state req-concurrent completed
assert_receipt req-concurrent completed

# Same request_id with another signed payload is a conflict, not a replay alias.
conflict_bundle="$workdir/request-conflict"
make_request "$conflict_bundle" req-concurrent zyxwvutsrqponmlkJIHGFEDCBA987654
if "${coordinator_cmd[@]}" --root "$root" process --bundle "$conflict_bundle" \
  >"$workdir/conflict.out" 2>"$workdir/conflict.err"; then
  echo 'A different payload reused an accepted request_id.' >&2
  exit 1
fi
grep -Fq request_id_conflict "$workdir/conflict.err"

# A modified receipt cannot be used to reconcile state.
tampered_bundle="$workdir/request-tampered-receipt"
make_request "$tampered_bundle" req-tampered-receipt
run_crash receipt "$tampered_bundle"
cp "$root/var/lib/mo-bodyd/outbox/req-tampered-receipt/receipt.json" "$workdir/receipt.backup"
python3 - "$root/var/lib/mo-bodyd/outbox/req-tampered-receipt/receipt.json" <<'PY_TAMPER_RECEIPT'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
receipt = json.loads(path.read_text(encoding="utf-8"))
receipt["output"]["tampered"] = True
path.write_text(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY_TAMPER_RECEIPT
if "${coordinator_cmd[@]}" --root "$root" recover \
  >"$workdir/tampered.out" 2>"$workdir/tampered.err"; then
  echo 'Recovery accepted a modified receipt.' >&2
  exit 1
fi
grep -Fq recovery_receipt_signature_invalid "$workdir/tampered.err"
assert_state req-tampered-receipt executing
cp "$workdir/receipt.backup" "$root/var/lib/mo-bodyd/outbox/req-tampered-receipt/receipt.json"
"${coordinator_cmd[@]}" --root "$root" recover >/dev/null
assert_state req-tampered-receipt completed

# State files must be regular, canonical, and non-symlinked.
ln -s /etc/passwd "$root/var/lib/mo-bodyd/requests/req-linked-state.json"
if "${coordinator_cmd[@]}" --root "$root" recover \
  >"$workdir/linked.out" 2>"$workdir/linked.err"; then
  echo 'Recovery followed a linked request state.' >&2
  exit 1
fi
grep -Fq request_state_open_failed "$workdir/linked.err"
rm "$root/var/lib/mo-bodyd/requests/req-linked-state.json"

state_to_tamper="$root/var/lib/mo-bodyd/requests/req-concurrent.json"
cp "$state_to_tamper" "$workdir/state.backup"
python3 - "$state_to_tamper" <<'PY_TAMPER_STATE'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
state = json.loads(path.read_text(encoding="utf-8"))
state["request_sha256"] = "sha256:" + "0" * 64
path.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY_TAMPER_STATE
if "${coordinator_cmd[@]}" --root "$root" recover \
  >"$workdir/state-tamper.out" 2>"$workdir/state-tamper.err"; then
  echo 'Recovery accepted an altered request state.' >&2
  exit 1
fi
grep -Fq recovery_receipt_digest_mismatch "$workdir/state-tamper.err"
cp "$workdir/state.backup" "$state_to_tamper"

# An idle daemon must not monopolize the global executor lock.
"${coordinator_cmd[@]}" --root "$root" serve --poll-seconds 0.1 \
  >"$workdir/serve-idle.out" 2>"$workdir/serve-idle.err" &
idle_serve_pid=$!
sleep 0.5
timeout -k 1s 3s "${coordinator_cmd[@]}" --root "$root" status \
  >"$workdir/status-while-serving.json"
kill "$idle_serve_pid"
wait "$idle_serve_pid" 2>/dev/null || true
python3 - "$workdir/status-while-serving.json" <<'PY_STATUS_WHILE_SERVING'
import json
import pathlib
import sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert status["pending_requests"] == 0, status
PY_STATUS_WHILE_SERVING

# Restarting serve recovers pending state first and quarantines the replay bundle.
serve_bundle="$root/var/lib/mo-bodyd/inbox/serve-bundle"
make_request "$serve_bundle" req-serve-recovery
set +e
MO_EXECUTORD_TEST_CRASH_AFTER=accepted \
  "${coordinator_cmd[@]}" --root "$root" serve --poll-seconds 0.1 \
  >"$workdir/serve-crash.out" 2>"$workdir/serve-crash.err"
serve_crash_rc=$?
set -e
[[ "$serve_crash_rc" -eq 97 ]]
assert_state req-serve-recovery accepted
set +e
timeout -k 1s 2s "${coordinator_cmd[@]}" --root "$root" serve --poll-seconds 0.1 \
  >"$workdir/serve-restart.out" 2>"$workdir/serve-restart.err"
serve_restart_rc=$?
set -e
[[ "$serve_restart_rc" -eq 124 ]]
assert_state req-serve-recovery failed
assert_receipt req-serve-recovery failed request_interrupted_after_acceptance
find "$root/var/lib/mo-bodyd/quarantine" -mindepth 1 -maxdepth 1 -type d -name 'serve-bundle*' | grep -q .

"${coordinator_cmd[@]}" --root "$root" status > "$workdir/status.json"
python3 - "$workdir/status.json" <<'PY_STATUS'
import json
import pathlib
import sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert status["request_state_schema"] == "morimil.executor.request-state.v0.1", status
assert status["pending_requests"] == 0, status
assert status["recovery_required"] is False, status
assert status["terminal_requests"] >= 6, status
PY_STATUS

grep -Fq request_accepted_durable "$root/var/lib/mo-bodyd/journal.jsonl"
grep -Fq request_execution_started "$root/var/lib/mo-bodyd/journal.jsonl"
grep -Fq request_recovered_as_failed "$root/var/lib/mo-bodyd/journal.jsonl"
grep -Fq request_state_reconciled_from_receipt "$root/var/lib/mo-bodyd/journal.jsonl"

if find "$repo_root/config/includes.chroot" -type f \( -name '*.pyc' -o -name '*.pyo' \) -print -quit | grep -q .; then
  echo 'Python bytecode leaked into the ISO source tree.' >&2
  exit 1
fi

printf '%s\n' 'MO OS durable acceptance, interruption recovery, concurrency and signed evidence passed.'
