# MO OS Morimil Executor Foundation

## Purpose

MO OS remains a pure Debian and Arch Linux hybrid:

> Debian governs. Arch executes.

Morimil is external to MO OS and remains the request authority and canonical-memory authority. Android is not installed in Debian, Arch or the ISO.

## Execution path

```text
external Morimil authority
  signs exact canonical request bytes
        |
        v
Debian / mo-bodyd
  validates Ed25519 key, signature, identity, target, time and replay
        |
        | system.status: local Debian operation
        | arch.status: fixed delegated operation
        v
Debian / mo-arch-dispatch
  verifies the Arch worker SHA-256 and accepts only status
        |
        v
Arch / mo-arch-worker
  emits structured Arch status evidence
        |
        v
Debian validates evidence and atomically publishes a signed receipt
```

The executor identity has authority `receipt_signing_only`. It cannot grant authority, write canonical memory or become `active_writer`.

## Trust state

Before any request is processed, `mo-bodyd` validates:

1. the exact identity and pairing schemas;
2. an Ed25519 executor keypair whose public key matches the recorded fingerprint and executor ID;
3. an Ed25519 controller public key whose fingerprint matches the pairing record;
4. the fixed policies `receipt_signing_only` and `exclusive_request_signer`;
5. exact Instance, controller and executor identifiers.

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

`request.sig` is base64 text for one raw 64-byte Ed25519 signature. The signature file is size-limited. Verification is performed against a temporary copy of the exact request bytes already read and hashed, preventing a file-change race between parsing and signature verification.

Requests are valid for at most five minutes and allow at most sixty seconds of future clock skew.

## Operations

### `system.status`

Executed locally by Debian. `parameters` must be empty. It reports MO OS release data, Arch-domain presence and the local/delegated operation sets.

### `arch.status`

Authorized by Debian and delegated through:

```text
/bin/bash /usr/local/libexec/mo-arch-dispatch status
```

The dispatcher:

- accepts no extra argument;
- verifies that the worker inside `/var/lib/machines/mo-dev` is a regular executable file;
- compares its SHA-256 against Debian's authoritative `/usr/local/libexec/mo-arch-worker`;
- invokes only `/usr/local/libexec/mo-arch-worker status` through `machinectl`;
- applies a timeout;
- validates the exact schema and Arch identity.

No controller-provided shell command or free-form argument reaches Arch.

## Replay and result semantics

After signature, policy, target, parameters and time validation, `request_id` is created atomically under:

```text
/var/lib/mo-bodyd/accepted/
```

A repeated accepted `request_id` is rejected as `request_replay_rejected`, returns a non-zero result and creates no second receipt.

Receipt status has precise meaning:

- `completed`: accepted request and successful operation;
- `failed`: accepted request whose delegated execution or evidence validation failed;
- `rejected`: request rejected before acceptance because authentication, policy, target, parameters or time was invalid.

## Receipts and daemon queues

Receipts are assembled in a temporary directory, signed, and renamed atomically into:

```text
/var/lib/mo-bodyd/outbox/RECEIPT_DIRECTORY/
├── receipt.json
└── receipt.sig
```

The daemon moves handled bundles to `processed/`. Bundles that cannot be processed, including replay bundles, are moved to `quarantine/` so they are not retried forever.

Security events are appended to `/var/lib/mo-bodyd/journal.jsonl`. This journal is local audit evidence, not Genesis canonical memory.

## Commands

```bash
sudo mo executor init
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id CONTROLLER_ID
mo executor status
```

## Validation

```bash
make executor-test
make arch-dispatch-test
```

The tests cover Ed25519-only pairing, exact-byte signatures, oversized signatures, replay under another bundle name, identity-policy tampering, signed `system.status`, signed `arch.status`, worker-integrity mismatch, malformed evidence, wrong-domain evidence and result-status semantics.

The contract tests use controlled substitutes for `machinectl` and the Arch root. The system workflow separately validates ISO construction, Secure Boot, live boot, encrypted installation and rollback. A real Arch bootstrap and real `mo-dev` container boot are not yet performed on every CI run and must be added before physical-hardware deployment.

## Deliberate limits

Alpha `0.6.0-alpha.1` does not authorize arbitrary commands, package installation, filesystem mutation, autonomous network access, GPU or device access, controller replacement, key rotation, canonical-memory writes or transfer of `active_writer`.
