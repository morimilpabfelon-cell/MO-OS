# MO OS Morimil Executor Foundation

## Architectural rule

> **Morimil decides. Debian governs. Arch executes. Android remains outside MO-OS.**

MO OS is a pure Debian and Arch Linux hybrid. Morimil remains external and is the request and canonical-memory authority. Debian owns trust, policy, durable state and receipts. Arch is a subordinate execution domain. Android components are not installed in Debian, Arch or the ISO.

## Components

```text
/usr/local/sbin/mo-executord
  durable coordinator: lock, staging, request state, recovery and daemon queues

/usr/local/sbin/mo-bodyd
  cryptographic and operation core: identity, pairing, signatures and allowlisted operations

/usr/local/libexec/mo-arch-dispatch
  Debian authority boundary for the fixed Arch operation

/usr/local/libexec/mo-arch-worker
  fixed Bash worker copied into Arch
```

The executor identity has authority `receipt_signing_only`. It cannot grant authority, replace the controller, write canonical memory or become `active_writer`.

## Signed request path

```text
external Morimil authority
  signs exact canonical request bytes
        |
        v
Debian / mo-executord
  snapshots the bundle and serializes processing
        |
        v
Debian / mo-bodyd
  validates Ed25519 identity, signature, target, time, parameters and operation
        |
        | system.status: Debian-local
        | arch.status: fixed delegated operation
        v
Debian / mo-arch-dispatch
  verifies machine identity, root identity and worker SHA-256
        |
        v
Arch / mo-arch-worker
  emits canonical status evidence
        |
        v
Debian validates evidence, signs the receipt and finalizes durable state
```

## Trust state

Before accepting a request, the executor validates:

1. exact identity and pairing schemas;
2. an Ed25519 executor keypair matching the recorded fingerprint and executor ID;
3. an Ed25519 controller public key matching the pairing record;
4. the fixed policies `receipt_signing_only` and `exclusive_request_signer`;
5. exact Instance, controller and executor identifiers;
6. canonical request bytes, bounded sizes, validity interval and empty parameters for current operations.

Pairing rejects RSA, EC and every non-Ed25519 controller key. Pairing remains one-time and fail-closed in Alpha `0.6.0-alpha.1`.

## Request contract

Each bundle contains only:

```text
request.json
request.sig
```

`request.json` must be UTF-8 canonical JSON with sorted keys, compact separators and one final newline. It contains exactly:

```text
schema_version
request_id
instance_id
controller_body_id
target_executor_id
operation
issued_at
expires_at
nonce
parameters
```

`request.sig` is base64 text for one raw 64-byte Ed25519 signature. Verification is performed against the same request bytes already read and hashed.

Requests are valid for at most five minutes and allow at most sixty seconds of future clock skew.

## Durable request state

Each accepted request has one canonical state file:

```text
/var/lib/mo-bodyd/requests/REQUEST_ID.json
```

The state binds the request ID to the exact request SHA-256, operation, timestamps, receipt directory and terminal error when applicable.

Allowed states:

```text
accepted
executing
completed
failed
```

Allowed transitions:

```text
accepted  -> executing
accepted  -> failed
executing -> completed
executing -> failed
```

`completed` and `failed` are terminal. Reuse of a terminal `request_id` is replay. Reuse of the same ID with another payload digest is a conflict.

Processing and recovery use an exclusive lock backed by a regular file opened with `O_NOFOLLOW` and protected with `flock`. State and receipt publication use atomic replacement plus file and parent-directory `fsync`.

## Interruption recovery

`mo-executord` never automatically repeats an interrupted accepted operation.

- interruption after `accepted`: publish a signed `failed` receipt with `request_interrupted_after_acceptance`;
- interruption during `executing`: publish a signed `failed` receipt with `request_execution_outcome_unknown_after_interruption`;
- interruption after receipt publication: verify canonical receipt bytes, Ed25519 signature, executor, operation, request ID and digest, then reconcile the pending state without replacing the receipt.

MO OS does not claim exactly-once semantics for external effects. Current operations are read-only.

## Operations

### `system.status`

Executed locally by Debian. `parameters` must be `{}`.

### `arch.status`

Authorized by Debian and delegated through:

```text
/bin/bash /usr/local/libexec/mo-arch-dispatch status
```

The dispatcher:

- accepts exactly one fixed action, `status`;
- requires the fixed `mo-dev` machine to be already running;
- never starts Arch as a side effect of a request;
- resolves the machine root and both worker paths canonically;
- rejects symlinks and intermediate path escapes;
- compares the Arch worker SHA-256 against Debian's authoritative worker;
- reads `State`, `RootDirectory` and `Leader` through `machinectl`;
- checks that `/proc/LEADER/root` and `/var/lib/machines/mo-dev` identify the same filesystem object by device and inode;
- enters only the leader's mount, UTS, IPC, network, PID and cgroup namespaces through `nsenter`;
- executes only `/usr/local/libexec/mo-arch-worker status`;
- verifies that the machine leader remains stable during execution;
- validates the exact evidence schema, `domain=arch` and `os_release.ID=arch`.

No controller-provided command or free-form argument reaches Arch. The dispatcher does not depend on `machinectl shell` or on a system bus inside the guest.

The Arch worker is Bash-only. It reads the fixed `/usr/lib/os-release`, uses `/usr/bin/uname`, rejects duplicate relevant release fields and emits canonical JSON. It performs no network access, package installation or filesystem mutation.

## Receipts and queues

Receipts are assembled in a private temporary directory, signed with the executor Ed25519 identity and renamed atomically into:

```text
/var/lib/mo-bodyd/outbox/REQUEST_ID/
├── receipt.json
└── receipt.sig
```

Handled bundles move to `processed/`. Bundles that cannot be processed move to `quarantine/` so they are not retried indefinitely. Security events are appended to `/var/lib/mo-bodyd/journal.jsonl`; this journal is local audit evidence, not Genesis canonical memory.

## Commands

```bash
sudo mo executor init
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id CONTROLLER_ID
mo executor status
sudo mo executor recover
sudo mo executor process --bundle BUNDLE_DIRECTORY
```

## Validation

```bash
make check
make executor-test
make arch-dispatch-test
sudo make arch-real-integration-test
```

Controlled tests cover deterministic negative cases: Ed25519 enforcement, exact-byte signatures, replay, payload conflict, durable transitions, simulated interruption, state and receipt tampering, path escapes, stopped machines, wrong roots, invalid or changing leaders, malformed evidence and worker-integrity failure.

The system workflow also performs real integration on every candidate run:

1. downloads the pinned Arch bootstrap `2026.07.01` over HTTPS;
2. verifies the fixed SHA-256 before extraction;
3. creates `/var/lib/machines/mo-dev` without running `pacman` or installing guest packages;
4. starts a real `systemd-nspawn` machine with private networking;
5. runs the production dispatcher through the verified `nsenter` path;
6. requires canonical Arch evidence;
7. alters the guest worker and requires `arch_worker_integrity_mismatch`;
8. terminates and removes the registered machine, root and temporary host helpers.

The same workflow validates the signed executor, updates, ISO metadata, Secure Boot, live boot, encrypted installation and rollback.

## Deliberate limits

Alpha `0.6.0-alpha.1` does not authorize arbitrary commands, package installation by request, mutable delegated operations, autonomous network access, GPU or device access, controller replacement, key rotation, canonical-memory writes or transfer of `active_writer`. Physical installation remains blocked pending production key custody, device-specific hardware validation, recovery media and a supported hardware matrix.
