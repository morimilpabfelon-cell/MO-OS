#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bodyd="${MO_TEST_BODYD:-$repo_root/config/includes.chroot/usr/local/sbin/mo-bodyd}"
bodyd_cmd=(python3 "$bodyd")
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

PYTHONPYCACHEPREFIX="$workdir/pycache" python3 -m py_compile "$bodyd"
"${bodyd_cmd[@]}" --root "$root" init > "$workdir/identity.json"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 \
  -out "$workdir/rsa-private.pem" >/dev/null 2>&1
openssl pkey -in "$workdir/rsa-private.pem" -pubout \
  -out "$workdir/rsa-public.pem" >/dev/null 2>&1
if "${bodyd_cmd[@]}" --root "$root" pair \
  --controller-key "$workdir/rsa-public.pem" \
  --instance-id "instance:test-001" \
  --controller-body-id "controller:morimil-001" \
  >"$workdir/rsa-pair.out" 2>"$workdir/rsa-pair.err"; then
  echo 'A non-Ed25519 controller key was accepted.' >&2
  exit 1
fi
grep -Fq 'controller_key_not_ed25519' "$workdir/rsa-pair.err"
[[ ! -e "$root/etc/mo/executor/morimil-controller.pem" ]]
[[ ! -e "$root/etc/mo/executor/pairing.json" ]]

openssl genpkey -algorithm ED25519 -out "$workdir/controller-private.pem" >/dev/null 2>&1
openssl pkey -in "$workdir/controller-private.pem" -pubout \
  -out "$workdir/controller-public.pem" >/dev/null 2>&1
"${bodyd_cmd[@]}" --root "$root" pair \
  --controller-key "$workdir/controller-public.pem" \
  --instance-id "instance:test-001" \
  --controller-body-id "controller:morimil-001" > "$workdir/pairing.json"

executor_id="$(python3 - "$root" <<'PY_EXECUTOR_ID'
import json
import pathlib
import sys
identity = pathlib.Path(sys.argv[1]) / "var/lib/mo-bodyd/identity/identity.json"
print(json.loads(identity.read_text(encoding="utf-8"))["executor_id"])
PY_EXECUTOR_ID
)"

make_request() {
  local bundle=$1 request_id=$2 target=$3 operation=$4 expiry_offset=${5:-240}
  mkdir -p "$bundle"
  python3 - "$bundle/request.json" "$request_id" "$target" "$operation" "$expiry_offset" <<'PY_REQUEST'
import datetime as dt
import json
import pathlib
import sys
path, request_id, target, operation, expiry_offset = sys.argv[1:]
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
format_time = lambda value: value.isoformat().replace("+00:00", "Z")
request = {
    "schema_version": "morimil.executor.request.v0.1",
    "request_id": request_id,
    "instance_id": "instance:test-001",
    "controller_body_id": "controller:morimil-001",
    "target_executor_id": target,
    "operation": operation,
    "issued_at": format_time(now),
    "expires_at": format_time(now + dt.timedelta(seconds=int(expiry_offset))),
    "nonce": "abcdefghijklmnopQRSTUVWX01234567",
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

valid="$workdir/req-001"
make_request "$valid" req-001 "$executor_id" system.status
receipt_dir="$("${bodyd_cmd[@]}" --root "$root" process --bundle "$valid")"
python3 - "$receipt_dir/receipt.json" <<'PY_VALID_RECEIPT'
import json
import pathlib
import sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["status"] == "completed", receipt
assert receipt["request_id"] == "req-001", receipt
assert receipt["operation"] == "system.status", receipt
assert receipt["output"]["arch_domain_initialized"] is True, receipt
assert receipt["output"]["supported_operations"] == ["system.status"], receipt
assert receipt["output"]["delegated_operations"] == ["arch.status"], receipt
PY_VALID_RECEIPT
base64 -d "$receipt_dir/receipt.sig" > "$workdir/receipt.sig.bin"
openssl pkeyutl -verify -pubin \
  -inkey "$root/var/lib/mo-bodyd/identity/executor-public.pem" \
  -sigfile "$workdir/receipt.sig.bin" -rawin \
  -in "$receipt_dir/receipt.json" >/dev/null

replay_copy="$workdir/replay-under-another-name"
cp -a "$valid" "$replay_copy"
if "${bodyd_cmd[@]}" --root "$root" process --bundle "$replay_copy" \
  >"$workdir/replay.out" 2>"$workdir/replay.err"; then
  echo 'Replay request was accepted under another bundle name.' >&2
  exit 1
fi
grep -Fq 'request_replay_rejected' "$workdir/replay.err"
grep -Fq 'request_replay_rejected' "$root/var/lib/mo-bodyd/journal.jsonl"

tampered="$workdir/req-002"
make_request "$tampered" req-002 "$executor_id" system.status
python3 - "$tampered/request.json" <<'PY_TAMPER'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["nonce"] = "tamperedNonce0123456789ABCDEFGH"
path.write_text(
    json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY_TAMPER
tampered_receipt="$("${bodyd_cmd[@]}" --root "$root" process --bundle "$tampered")"
python3 - "$tampered_receipt/receipt.json" <<'PY_REJECTED_RECEIPT'
import json
import pathlib
import sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["status"] == "rejected", receipt
assert receipt["error"] == "request_signature_invalid", receipt
assert receipt["output"] is None, receipt
assert receipt["request_id"] == "req-002", receipt
PY_REJECTED_RECEIPT

oversized_signature="$workdir/req-oversized-signature"
make_request "$oversized_signature" req-oversized-signature "$executor_id" system.status
python3 - "$oversized_signature/request.sig" <<'PY_OVERSIZED'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text("A" * 1024, encoding="ascii")
PY_OVERSIZED
oversized_receipt="$("${bodyd_cmd[@]}" --root "$root" process --bundle "$oversized_signature")"
python3 - "$oversized_receipt/receipt.json" <<'PY_OVERSIZED_RECEIPT'
import json
import pathlib
import sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["status"] == "rejected", receipt
assert receipt["error"] == "request_signature_size_invalid", receipt
PY_OVERSIZED_RECEIPT

wrong_target="$workdir/req-003"
make_request "$wrong_target" req-003 mo-executor:wrong-target system.status
wrong_receipt="$("${bodyd_cmd[@]}" --root "$root" process --bundle "$wrong_target")"
python3 - "$wrong_receipt/receipt.json" <<'PY_WRONG_TARGET'
import json
import pathlib
import sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["status"] == "rejected", receipt
assert receipt["request_id"] == "req-003", receipt
assert receipt["error"] == "executor_target_mismatch", receipt
PY_WRONG_TARGET

unsupported="$workdir/req-004"
make_request "$unsupported" req-004 "$executor_id" shell.execute
unsupported_receipt="$("${bodyd_cmd[@]}" --root "$root" process --bundle "$unsupported")"
python3 - "$unsupported_receipt/receipt.json" <<'PY_UNSUPPORTED'
import json
import pathlib
import sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["status"] == "rejected", receipt
assert receipt["error"] == "operation_not_allowed", receipt
PY_UNSUPPORTED

expired="$workdir/req-005"
make_request "$expired" req-005 "$executor_id" system.status -5
expired_receipt="$("${bodyd_cmd[@]}" --root "$root" process --bundle "$expired")"
python3 - "$expired_receipt/receipt.json" <<'PY_EXPIRED'
import json
import pathlib
import sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["status"] == "rejected", receipt
assert receipt["error"] in {"request_validity_window_invalid", "request_expired"}, receipt
PY_EXPIRED

"${bodyd_cmd[@]}" --root "$root" status > "$workdir/status.json"
python3 - "$workdir/status.json" <<'PY_STATUS'
import json
import pathlib
import sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert status["identity_initialized"] is True
assert status["controller_paired"] is True
assert status["instance_id"] == "instance:test-001"
assert status["controller_body_id"] == "controller:morimil-001"
PY_STATUS

python3 - "$root/var/lib/mo-bodyd/identity/identity.json" <<'PY_POLICY_TAMPER'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["authority"] = "active_writer"
path.write_text(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY_POLICY_TAMPER
if "${bodyd_cmd[@]}" --root "$root" process --bundle "$valid" \
  >"$workdir/policy.out" 2>"$workdir/policy.err"; then
  echo 'A modified executor authority policy was accepted.' >&2
  exit 1
fi
grep -Fq 'identity_authority_invalid' "$workdir/policy.err"

if find "$repo_root/config/includes.chroot" -type f \( -name '*.pyc' -o -name '*.pyo' \) -print -quit | grep -q .; then
  echo 'Python bytecode leaked into the ISO source tree.' >&2
  exit 1
fi

printf '%s\n' 'MO OS executor key type, exact signatures, replay, policy and receipts passed.'
