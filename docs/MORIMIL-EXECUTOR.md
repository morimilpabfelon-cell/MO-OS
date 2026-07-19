# MO OS Morimil Executor Foundation

## Purpose

MO OS is Morimil's native work system. It remains a pure Debian and Arch Linux hybrid. In Alpha `0.6.0-alpha.1`, Morimil remains the exclusive controller and canonical-memory authority while MO OS begins as a subordinate native executor that accepts only explicitly signed work requests and returns signed evidence.

The controller is external to MO OS. Morimil-app may act as the current controller, but no Android runtime, Android SDK, APK, mobile database or application component is installed in Debian or Arch.

```text
External Morimil authority
  exclusive request authority
        |
        | canonical Ed25519-signed request
        v
MO OS / Debian / mo-bodyd
  validates identity, target, time and replay state
        |
        | allowlisted operation only
        v
Arch Linux domain when explicitly authorized
        |
        v
signed execution receipt
```

This phase does not make MO OS an `active_writer` for canonical Genesis memory. The executor key may sign receipts only. It cannot grant itself authority, change Morimil identity or write canonical memory.

## Native-system boundary

MO OS contains only Linux-native system components:

1. Debian owns boot, kernel, hardware, security, storage, networking and recovery.
2. Arch Linux provides a subordinate work domain through `systemd-nspawn`.
3. The MO layer coordinates policies and execution between the two Linux domains.
4. External clients communicate through signed files or a future neutral transport.
5. Client technology never becomes part of the MO OS root filesystem merely because it controls requests.

The request contract describes authority and evidence. It is not an Android integration layer.

## Initial trust boundary

`mo-bodyd` requires all of the following before it can process work:

1. a locally initialized executor receipt-signing identity;
2. exactly one paired Morimil Instance;
3. exactly one registered controller identity;
4. the controller's Ed25519 public key;
5. a canonical request JSON document;
6. a valid Ed25519 signature from the paired controller;
7. an exact executor target;
8. a validity window no longer than five minutes;
9. a request identifier that has never been accepted before;
10. an operation present in the local allowlist.

The initial allowlist contains only:

```text
system.status
```

No shell command, package installation, file mutation, network request, device access or Arch-domain execution is authorized by this foundation.

## Executor identity

Initialize the executor locally:

```bash
sudo mo executor init
```

This generates an Ed25519 keypair under:

```text
/var/lib/mo-bodyd/identity/
```

The private key is mode `0600`. The public-key fingerprint derives the executor identifier. The identity declares its authority as `receipt_signing_only`.

## Controller pairing

Pair one authorized Morimil controller:

```bash
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id CONTROLLER_ID
```

`controller_body_id` is a protocol identifier retained for compatibility with Morimil's Body model. It does not imply that Android is installed in MO OS or that the executor depends on a mobile runtime.

Pairing is fail-closed and one-time in this phase. It stores only the controller public key and the exact Instance and controller identifiers. A second controller cannot silently replace the first one.

After successful pairing, the command enables and starts `mo-bodyd.service`.

## Request bundle

Each inbox directory contains:

```text
request.json
request.sig
```

`request.sig` is the base64 representation of the raw 64-byte Ed25519 signature over the exact bytes of `request.json`.

The request object contains exactly:

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

A request is consumed only after its signature, authority, target, operation and validity window pass. Its identifier is then recorded atomically under:

```text
/var/lib/mo-bodyd/accepted/
```

The same identifier cannot be accepted again. Requests expire after at most five minutes and tolerate no more than sixty seconds of future clock skew.

## Signed receipts

Every processed request produces:

```text
/var/lib/mo-bodyd/outbox/REQUEST_ID/
├── receipt.json
└── receipt.sig
```

The receipt includes the request digest, executor identifier, operation, status, timestamps, output or rejection reason. It is signed by the executor's receipt-only Ed25519 key.

The controlling Morimil component must verify the executor identity and receipt signature before trusting the result. A valid receipt proves which executor processed which exact request; it does not grant the executor new authority.

## Audit state

Security-relevant events are appended to:

```text
/var/lib/mo-bodyd/journal.jsonl
```

The journal records identity initialization, controller pairing, processed requests and bundle-level failures. This first journal is local append-only evidence, not yet a Genesis canonical-memory stream.

## Service hardening

`mo-bodyd.service` runs with:

- no Linux capabilities;
- `NoNewPrivileges`;
- a read-only system filesystem;
- only `/var/lib/mo-bodyd` writable;
- protected home, kernel, logs and control groups;
- memory that cannot become executable;
- a restrictive `0077` umask.

## Validation

Run:

```bash
make executor-test
```

The test generates temporary Ed25519 identities and verifies:

- one valid signed request;
- signed receipt verification;
- replay rejection;
- tampered-request rejection;
- wrong-target rejection;
- unsupported-operation rejection;
- expired-request rejection;
- initialized and paired status reporting.

## Deliberate limits

Alpha `0.6.0-alpha.1` does not yet provide:

- a network transport or controller UI;
- network communication;
- Arch execution sessions;
- arbitrary commands;
- filesystem mutation;
- GPU or device access;
- signed capability grants beyond `system.status`;
- executor key rotation or controller replacement;
- canonical-memory writes;
- transfer of `active_writer` authority.

Those capabilities must be added individually, each with a narrow signed contract, resource limits, negative tests and a signed receipt. Any Android-side implementation remains in Morimil-app and never becomes an MO OS package or system dependency.
