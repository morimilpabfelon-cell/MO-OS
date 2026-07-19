# MO OS Morimil Executor Foundation

## Purpose

MO OS is Morimil's native work system. In Alpha `0.6.0-alpha.1`, the Android Body remains the exclusive controller and canonical-memory authority. MO OS begins as a subordinate executor that accepts only explicitly signed work requests and returns signed evidence.

```text
Morimil Android Body
  exclusive request authority
        |
        | canonical Ed25519-signed request
        v
MO OS / mo-bodyd
  validates identity, target, time and replay state
        |
        | allowlisted operation only
        v
signed execution receipt
```

This phase does not make MO OS an `active_writer` for canonical Genesis memory. The executor key may sign receipts only. It cannot grant itself authority, change Morimil identity or write canonical memory.

## Initial trust boundary

`mo-bodyd` requires all of the following before it can process work:

1. a locally initialized executor receipt-signing identity;
2. exactly one paired Morimil Instance;
3. exactly one paired Android controller Body;
4. the controller Body's Ed25519 public key;
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

Pair one Morimil Android Body:

```bash
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id BODY_ID
```

Pairing is fail-closed and one-time in this phase. It stores only the controller public key and the exact Instance and Body identifiers. A second controller cannot silently replace the first one.

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

Morimil-app must verify the executor identity and receipt signature before trusting the result. A valid receipt proves which executor processed which exact request; it does not grant the executor new authority.

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

- Android transport or pairing UI;
- network communication;
- Arch execution sessions;
- arbitrary commands;
- filesystem mutation;
- GPU or device access;
- signed capability grants beyond `system.status`;
- executor key rotation or controller replacement;
- canonical-memory writes;
- transfer of `active_writer` authority.

Those capabilities must be added individually, each with a narrow signed contract, resource limits, negative tests and a signed receipt.
