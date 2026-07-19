# MO OS Morimil Executor Foundation

MO OS is Morimil's native work system. Alpha `0.6.0-alpha.1` introduces `mo-bodyd`, a subordinate executor controlled exclusively by the paired Morimil Android Body.

The executor:

- creates a local Ed25519 identity used only to sign receipts;
- pairs exactly one Morimil Instance and Android controller Body;
- accepts canonical Ed25519-signed requests;
- verifies the Instance, controller Body, executor target and validity window;
- rejects replayed request identifiers;
- permits only explicitly allowlisted operations;
- writes signed receipts and a local append-only audit journal.

The initial operation allowlist contains only `system.status`. There is no arbitrary command execution, network access, filesystem mutation, Arch execution, canonical-memory writing or self-granted authority.

Initialize and pair:

```bash
sudo mo executor init
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id BODY_ID
```

Inspect status:

```bash
mo executor status
```

Request bundles are placed below `/var/lib/mo-bodyd/inbox/`. Signed receipts are written below `/var/lib/mo-bodyd/outbox/`. Full protocol and security documentation is maintained in the MO-OS repository at `docs/MORIMIL-EXECUTOR.md`.
