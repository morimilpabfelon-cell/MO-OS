# MO OS Morimil Executor Foundation

## Purpose

MO OS is Morimil's native work system and remains a pure Debian and Arch Linux hybrid.

> Debian governs. Arch executes.

In Alpha `0.6.0-alpha.1`, Morimil remains the external controller and canonical-memory authority. MO OS accepts signed requests, applies Debian policy, delegates only explicitly permitted work to Arch and returns signed evidence.

No Android runtime, Android SDK, APK, mobile database or application component is installed in Debian or Arch. The request contract describes authority and evidence; it is not an Android integration layer.

## Execution path

```text
External Morimil authority
  signs one canonical request
        |
        v
Debian / mo-bodyd
  verifies signature, identity, target, time and replay state
        |
        | local operation: system.status
        | delegated operation: arch.status
        v
Debian / mo-arch-dispatch
  accepts only the fixed verb status
  applies a 20-second boundary timeout
        |
        v
Arch / mo-arch-worker
  returns structured Arch evidence
        |
        v
Debian validates the evidence
  and signs the final receipt
```

This phase does not make MO OS an `active_writer` for canonical Genesis memory. The executor key may sign receipts only. It cannot grant itself authority, change Morimil identity or write canonical memory.

## Native-system boundary

MO OS contains only Linux-native system components:

1. Debian owns boot, kernel, hardware, security, storage, networking, recovery and request authorization.
2. Arch Linux provides a subordinate work domain through `systemd-nspawn`.
3. The MO layer coordinates policy and evidence between the two Linux domains.
4. External clients communicate through signed files or a future neutral transport.
5. Client technology never becomes part of the MO OS root filesystem merely because it controls requests.

## Trust requirements

`mo-bodyd` requires all of the following before processing work:

1. a locally initialized executor receipt-signing identity;
2. exactly one paired Morimil Instance;
3. exactly one registered controller identity;
4. the controller's Ed25519 public key;
5. a canonical request JSON document;
6. a valid Ed25519 signature from the paired controller;
7. an exact executor target;
8. a validity window no longer than five minutes;
9. a request identifier never accepted before;
10. an operation present in the closed policy set.

## Current operations

### `system.status`

Executed locally by Debian. Parameters must be empty. The result reports:

- MO OS release information;
- whether the Arch domain exists;
- local Debian-governed operations;
- operations delegated to Arch.

### `arch.status`

Authorized by Debian and executed through the fixed Arch worker. Parameters must be empty.

`mo-bodyd` invokes only:

```text
/bin/bash /usr/local/libexec/mo-arch-dispatch status
```

The dispatcher invokes only:

```text
/usr/local/libexec/mo-arch-worker status
```

No shell command supplied by the controller is forwarded. No free-form argument is accepted.

The worker result must contain exactly:

```text
schema_version
domain
kernel_release
machine
os_release
```

Debian rejects the result unless:

- `schema_version` is `mo.arch.worker.status.v0.1`;
- `domain` is `arch`;
- `os_release.ID` is `arch`;
- all fields match strict type and length constraints.

The signed receipt exposes:

```json
{
  "governance": "debian",
  "execution": "arch",
  "arch_status": {}
}
```

## Executor identity

Initialize the executor locally:

```bash
sudo mo executor init
```

This generates an Ed25519 keypair under:

```text
/var/lib/mo-bodyd/identity/
```

The private key is mode `0600`. The identity declares authority `receipt_signing_only`.

## Controller pairing

```bash
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id CONTROLLER_ID
```

`controller_body_id` is a protocol identifier retained for compatibility with Morimil's Body model. It does not introduce an Android dependency.

Pairing is one-time and fail-closed in this phase. Only the controller public key and exact identifiers are stored.

## Request bundle

Each inbox directory contains:

```text
request.json
request.sig
```

`request.sig` is the base64 representation of the raw 64-byte Ed25519 signature over the exact bytes of `request.json`.

The request contains exactly:

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

JSON must use UTF-8, sorted keys, compact separators and one final newline. Unknown or missing fields are rejected.

## Replay and expiry

After cryptographic and policy validation, the request identifier is recorded atomically under:

```text
/var/lib/mo-bodyd/accepted/
```

The same identifier cannot be accepted again. Requests expire after at most five minutes and tolerate no more than sixty seconds of future clock skew.

## Signed receipts and audit

Every processed request produces:

```text
/var/lib/mo-bodyd/outbox/REQUEST_ID/
├── receipt.json
└── receipt.sig
```

The receipt includes the request digest, executor identifier, operation, status, timestamps, output or rejection reason. It is signed by the executor's receipt-only Ed25519 key.

Security events are appended to:

```text
/var/lib/mo-bodyd/journal.jsonl
```

This journal is local append-only evidence, not a canonical Genesis memory stream.

## Validation

Run:

```bash
make executor-test
make arch-dispatch-test
```

The tests verify:

- valid signed `system.status`;
- valid signed `arch.status`;
- signed receipt verification;
- replay rejection;
- tampered-request rejection;
- wrong-target rejection;
- unsupported-operation rejection;
- expired-request rejection;
- rejection of parameters for `arch.status`;
- rejection of malformed or non-Arch evidence;
- rejection of arbitrary dispatcher operations;
- rejection when the Arch domain is absent.

## Deliberate limits

Alpha `0.6.0-alpha.1` does not provide:

- a network transport or controller UI;
- arbitrary commands or an interactive executor shell;
- package installation through signed requests;
- filesystem mutation;
- autonomous network requests;
- GPU or device access;
- executor key rotation or controller replacement;
- canonical-memory writes;
- transfer of `active_writer` authority.

Future capabilities must be added individually with a narrow signed contract, resource limits, negative tests and a signed receipt.
