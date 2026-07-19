# MO OS Morimil Executor Foundation

MO OS is Morimil's native work system and remains a pure Debian and Arch Linux hybrid.

> Debian governs. Arch executes.

Alpha `0.6.0-alpha.1` provides `mo-bodyd`, a Linux-native executor controlled by one paired external Morimil authority. Android remains outside MO OS; the ISO contains no Android runtime, SDK, APK or mobile dependency.

The executor:

- creates a local Ed25519 identity used only to sign receipts;
- pairs exactly one Morimil Instance and one controller identity;
- accepts canonical Ed25519-signed requests;
- verifies Instance, controller, executor target, validity and replay state;
- executes `system.status` locally under Debian;
- delegates `arch.status` through Debian's fixed dispatcher to the Arch worker;
- rejects parameters, free-form commands and non-Arch evidence;
- writes signed receipts and a local append-only audit journal.

The only current operations are:

```text
system.status  — Debian-local status
arch.status    — Debian-authorized status executed by Arch
```

For `arch.status`, Debian invokes only:

```text
/bin/bash /usr/local/libexec/mo-arch-dispatch status
```

The dispatcher invokes only `/usr/local/libexec/mo-arch-worker status` inside `mo-dev`. Debian validates the returned schema, `domain=arch` and `os_release.ID=arch` before signing the receipt.

No shell command from a request is forwarded. There is no package installation, filesystem mutation, autonomous network access, GPU/device access, canonical-memory writing or self-granted authority.

Initialize and pair:

```bash
sudo mo executor init
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id CONTROLLER_ID
```

Inspect status:

```bash
mo executor status
```

Request bundles are placed below `/var/lib/mo-bodyd/inbox/`. Signed receipts are written below `/var/lib/mo-bodyd/outbox/`. Full protocol and security documentation is maintained at `docs/MORIMIL-EXECUTOR.md` in the MO-OS repository.
