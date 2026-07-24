# MO OS Morimil Executor Foundation

> **Morimil decides. Debian governs. Arch executes. Android remains outside MO-OS.**

Alpha `0.6.0-alpha.1` provides a Linux-native executor controlled by one paired external Morimil Ed25519 authority.

## Components

- `/usr/local/sbin/mo-executord`: durable lock, staging, request states, recovery and daemon queues.
- `/usr/local/sbin/mo-bodyd`: identity, pairing, signature verification and fixed operations.
- `/usr/local/libexec/mo-arch-dispatch`: Debian authority boundary for `arch.status`.
- `/usr/local/libexec/mo-arch-worker`: fixed Bash worker copied into Arch.

Current operations:

```text
system.status  — Debian-local status
arch.status    — Debian-authorized status executed by Arch
```

Both require `parameters: {}`. There is no request-controlled shell, package installation, filesystem mutation, autonomous network access, GPU/device access, canonical-memory writing or self-granted authority.

## Durable state and recovery

Each accepted request has one canonical state file:

```text
/var/lib/mo-bodyd/requests/REQUEST_ID.json
```

Allowed states are `accepted`, `executing`, `completed` and `failed`. Terminal states cannot return to pending states. Replay and reuse of an ID with another request digest are rejected.

`mo-executord` never automatically repeats an interrupted accepted operation. Interruption before execution or during execution produces a signed `failed` receipt. A receipt published before a crash is cryptographically verified and reconciled without replacement. MO OS does not claim exactly-once semantics for external effects.

## Debian to Arch

For `arch.status`, Debian:

- requires the fixed `mo-dev` machine already running;
- verifies canonical roots and worker paths;
- compares guest and host worker SHA-256 values;
- validates `State`, `RootDirectory` and `Leader` through `machinectl`;
- compares the machine root and `/proc/LEADER/root` by device and inode;
- enters fixed namespaces with `nsenter`;
- executes only `/usr/local/libexec/mo-arch-worker status`;
- validates canonical JSON, `domain=arch` and `os_release.ID=arch`.

The worker uses Bash, `/usr/lib/os-release` and `/usr/bin/uname`. It does not require Python or a guest system bus.

## Commands

```bash
sudo mo executor init
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id CONTROLLER_ID
mo executor status
sudo mo executor recover
```

Bundles enter `/var/lib/mo-bodyd/inbox/`; signed receipts are written under `/var/lib/mo-bodyd/outbox/`. Full documentation is maintained in `docs/MORIMIL-EXECUTOR.md` and `docs/EXECUTOR-RECOVERY.md`.
