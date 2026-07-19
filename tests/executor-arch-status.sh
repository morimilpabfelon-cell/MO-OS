#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bodyd="${MO_TEST_BODYD:-$repo_root/config/includes.chroot/usr/local/sbin/mo-bodyd}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
root="$workdir/root"
mkdir -p "$root/etc" "$root/var/lib/machines/mo-dev"
cat > "$root/etc/mo-release" <<'EOF_RELEASE'
NAME="MO OS"
VERSION="0.6.0-alpha.1"
ARCHITECTURE="amd64"
EOF_RELEASE

fake_dispatch="$workdir/mo-arch-dispatch"
cat > "$fake_dispatch" <<'EOF_DISPATCH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 && "$1" == status ]]
case "${MO_TEST_ARCH_MODE:-valid}" in
  valid)
    printf '%s\n' '{"domain":"arch","kernel_release":"6.12.0-test","machine":"x86_64","os_release":{"ID":"arch","NAME":"Arch Linux","VERSION_ID":"rolling"},"schema_version":"mo.arch.worker.status.v0.1"}'
    ;;
  wrong-domain)
    printf '%s\n' '{"domain":"debian","kernel_release":"6.12.0-test","machine":"x86_64","os_release":{"ID":"arch","NAME":"Arch Linux","VERSION_ID":"rolling"},"schema_version":"mo.arch.worker.status.v0.1"}'
    ;;
  malformed)
    printf '%s\n' 'not-json'
    ;;
  *) exit 64 ;;
esac
EOF_DISPATCH
chmod 0755 "$fake_dispatch"

export MO_BODYD_ALLOW_TEST_ROOT=1
export MO_BODYD_ARCH_DISPATCH="$fake_dispatch"
bodyd_cmd=(python3 "$bodyd")

PYTHONPYCACHEPREFIX="$workdir/pycache" python3 -m py_compile "$bodyd"
"${bodyd_cmd[@]}" --root "$root" init >/dev/null
openssl genpkey -algorithm ED25519 -out "$workdir/controller-private.pem" >/dev/null 2>&1
openssl pkey -in "$workdir/controller-private.pem" -pubout \
  -out "$workdir/controller-public.pem" >/dev/null 2>&1
"${bodyd_cmd[@]}" --root "$root" pair \
  --controller-key "$workdir/controller-public.pem" \
  --instance-id instance:test-arch \
  --controller-body-id body:controller-arch >/dev/null

executor_id="$(python3 - "$root" <<'PY_EXECUTOR'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1]) / "var/lib/mo-bodyd/identity/identity.json"
print(json.loads(path.read_text(encoding="utf-8"))["executor_id"])
PY_EXECUTOR
)"

make_request() {
  local bundle=$1 request_id=$2 parameters_json=$3
  mkdir -p "$bundle"
  python3 - "$bundle/request.json" "$request_id" "$executor_id" "$parameters_json" <<'PY_REQUEST'
import datetime as dt
import json
import pathlib
import sys
path, request_id, executor_id, parameters_json = sys.argv[1:]
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
request = {
    "schema_version": "morimil.executor.request.v0.1",
    "request_id": request_id,
    "instance_id": "instance:test-arch",
    "controller_body_id": "body:controller-arch",
    "target_executor_id": executor_id,
    "operation": "arch.status",
    "issued_at": now.isoformat().replace("+00:00", "Z"),
    "expires_at": (now + dt.timedelta(minutes=4)).isoformat().replace("+00:00", "Z"),
    "nonce": "archStatusNonce0123456789ABCDEFGH",
    "parameters": json.loads(parameters_json),
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

valid="$workdir/arch-valid"
make_request "$valid" arch-valid '{}'
receipt_dir="$("${bodyd_cmd[@]}" --root "$root" process --bundle "$valid")"
python3 - "$receipt_dir/receipt.json" <<'PY_VALID'
import json
import pathlib
import sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["status"] == "completed", receipt
assert receipt["operation"] == "arch.status", receipt
assert receipt["output"]["governance"] == "debian", receipt
assert receipt["output"]["execution"] == "arch", receipt
assert receipt["output"]["arch_status"]["domain"] == "arch", receipt
assert receipt["output"]["arch_status"]["os_release"]["ID"] == "arch", receipt
PY_VALID
base64 -d "$receipt_dir/receipt.sig" > "$workdir/receipt.sig.bin"
openssl pkeyutl -verify -pubin \
  -inkey "$root/var/lib/mo-bodyd/identity/executor-public.pem" \
  -sigfile "$workdir/receipt.sig.bin" -rawin \
  -in "$receipt_dir/receipt.json" >/dev/null

with_parameters="$workdir/arch-parameters"
make_request "$with_parameters" arch-parameters '{"command":"uname"}'
parameters_receipt="$("${bodyd_cmd[@]}" --root "$root" process --bundle "$with_parameters")"
python3 - "$parameters_receipt/receipt.json" <<'PY_PARAMETERS'
import json
import pathlib
import sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["status"] == "rejected", receipt
assert receipt["error"] == "arch_status_parameters_must_be_empty", receipt
PY_PARAMETERS
[[ ! -e "$root/var/lib/mo-bodyd/accepted/arch-parameters" ]]

export MO_TEST_ARCH_MODE=wrong-domain
wrong_domain="$workdir/arch-wrong-domain"
make_request "$wrong_domain" arch-wrong-domain '{}'
wrong_receipt="$("${bodyd_cmd[@]}" --root "$root" process --bundle "$wrong_domain")"
python3 - "$wrong_receipt/receipt.json" <<'PY_WRONG'
import json
import pathlib
import sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["status"] == "failed", receipt
assert receipt["error"] == "arch_status_domain_invalid", receipt
PY_WRONG
[[ -e "$root/var/lib/mo-bodyd/accepted/arch-wrong-domain" ]]
unset MO_TEST_ARCH_MODE

export MO_TEST_ARCH_MODE=malformed
malformed="$workdir/arch-malformed"
make_request "$malformed" arch-malformed '{}'
malformed_receipt="$("${bodyd_cmd[@]}" --root "$root" process --bundle "$malformed")"
python3 - "$malformed_receipt/receipt.json" <<'PY_MALFORMED'
import json
import pathlib
import sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert receipt["status"] == "failed", receipt
assert receipt["error"] == "arch_dispatch_output_invalid", receipt
PY_MALFORMED
unset MO_TEST_ARCH_MODE

printf '%s\n' 'Signed arch.status passed Debian policy, failure semantics and Arch evidence validation.'
