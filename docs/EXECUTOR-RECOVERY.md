# MO OS executor interruption recovery

## Authority boundary

The durable coordinator entry point is `/usr/local/sbin/mo-executord`. Its fixed modules live under `/usr/local/libexec/mo-executord`. Debian runs the entry point through `mo-bodyd.service`. The existing `/usr/local/sbin/mo-bodyd` remains the narrow cryptographic and operation core and is loaded as a fixed local Python module.

Morimil signs requests externally. Debian validates, accepts, records, executes or delegates, and signs the final evidence. Arch receives only the fixed `status` worker path already authorized by Debian. No request supplies a shell command.

## Durable state

Every authenticated and accepted request receives exactly one canonical state file under:

```text
/var/lib/mo-bodyd/requests/<request_id>.json
```

The state is bound to the exact SHA-256 of the canonical `request.json` bytes. The allowed states are:

```text
accepted -> executing -> completed
                    \-> failed
accepted ----------------> failed
```

`completed` and `failed` are terminal. Reusing a terminal `request_id` with the same payload is replay. Reusing it with another payload is a conflict.

A global regular-file lock at `/var/lib/mo-bodyd/executor.lock` serializes validation, acceptance, execution and recovery. The lock is opened with `O_NOFOLLOW` and held with an exclusive `flock`.

## Exact input snapshot

Before validation, the coordinator copies `request.json` and `request.sig` into a private staging directory. Validation and the core operate on that snapshot. A source bundle cannot be changed between validation and execution.

The core path must be a regular, canonical file and must not be group- or world-writable. Test-only path overrides are accepted only below a test root with `MO_BODYD_ALLOW_TEST_ROOT=1`.

## Interruption semantics

### Interrupted after `accepted`

The operation is not executed. Recovery publishes a signed `failed` receipt with:

```text
request_interrupted_after_acceptance
```

### Interrupted after `executing`

The operation is never repeated automatically. Recovery publishes a signed `failed` receipt with:

```text
request_execution_outcome_unknown_after_interruption
```

This is deliberately conservative. MO OS does not claim exactly-once semantics for external effects.

### Receipt exists but state is pending

Recovery verifies:

- canonical receipt JSON;
- Ed25519 receipt signature;
- executor identity;
- request ID;
- request SHA-256;
- operation;
- terminal status.

The existing receipt is preserved byte-for-byte and the state is reconciled. A modified receipt or state blocks recovery.

## Durability

New states use exclusive creation with `O_CREAT | O_EXCL | O_NOFOLLOW`. Updates and receipts use temporary files or directories, atomic rename, file `fsync`, and parent-directory `fsync`. State directories and the lock are non-symlinked and private to root.

Python bytecode generation is disabled while loading the core so `__pycache__` cannot leak into the ISO source tree.

## Commands

```text
mo executor status
mo executor recover
mo executor process --bundle DIR
mo executor start
mo executor stop
```

The daemon runs recovery before reading the inbox. A recovered bundle that remains in the inbox is treated as replay and moved to quarantine; it is not executed again.

## Current operation limit

Only these operations remain accepted:

```text
system.status
arch.status
```

Both require an empty parameters object. Mutable operations, package installation, arbitrary builds, arbitrary networking, canonical-memory writes and shell execution remain forbidden.
