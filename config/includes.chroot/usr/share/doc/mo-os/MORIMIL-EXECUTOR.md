# MO OS Morimil Executor Foundation

MO OS remains a pure Debian and Arch Linux hybrid.

> Debian governs. Arch executes.

Alpha `0.6.0-alpha.1` provides a Linux-native executor controlled by one paired external Morimil authority. Android remains outside MO OS.

`mo-bodyd`:

- uses an Ed25519 receipt-signing identity with authority `receipt_signing_only`;
- accepts only an Ed25519 controller public key;
- verifies the exact canonical request bytes already read and hashed;
- validates identity, pairing, target, time, parameters and replay state;
- executes `system.status` locally under Debian;
- delegates `arch.status` through Debian's fixed dispatcher;
- publishes signed receipt directories atomically;
- quarantines bundles that cannot be processed.

Current operations:

```text
system.status  — Debian-local status
arch.status    — Debian-authorized status executed by Arch
```

For `arch.status`, Debian compares the SHA-256 of the worker inside `mo-dev` with its authoritative `/usr/local/libexec/mo-arch-worker`, invokes only the fixed `status` verb, and validates `domain=arch` and `os_release.ID=arch`.

Receipt status:

```text
completed  accepted and successful
failed     accepted, but execution or evidence validation failed
rejected   rejected before acceptance
```

A repeated accepted `request_id` is rejected as replay and does not create a second receipt.

There is no request-controlled shell, package installation, filesystem mutation, autonomous network access, GPU/device access, canonical-memory writing or self-granted authority.

```bash
sudo mo executor init
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id CONTROLLER_ID
mo executor status
```

Bundles enter `/var/lib/mo-bodyd/inbox/`; receipts are written under `/var/lib/mo-bodyd/outbox/`. Full documentation is maintained in `docs/MORIMIL-EXECUTOR.md` in the repository.
