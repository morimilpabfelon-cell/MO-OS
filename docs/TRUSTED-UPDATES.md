# MO OS trusted updates

Alpha 0.5 introduces the first update trust boundary. It does not yet claim
production Secure Boot or unattended recovery.

## Trust model

- Release signing happens outside the installed system.
- The ISO and installed system contain only a public verification key.
- Private signing keys are never committed, copied into an image, or included
  in an update artifact.
- Every bundle contains `manifest.env`, `manifest.sig`, and `payload.tar`.
- The manifest is verified with RSA-SHA256 before any payload inspection or
  modification.
- The payload SHA-256 must exactly match the signed manifest.
- Update sequences must increase monotonically; replaying an old or equal
  sequence is rejected.
- A read-only Btrfs root snapshot is created before extraction.

## Foundation payload boundary

This phase intentionally allows only:

- `etc/mo-update-version`
- regular files below `usr/local/share/mo-update/`

Absolute paths, `..`, symbolic links, hard links, devices, FIFOs, unknown
paths, more than 128 files, and payloads larger than 32 MiB are rejected.

## Commands

```bash
mo update verify --bundle DIR
sudo mo update apply --bundle DIR
mo update status
```

The default public key location is:

```text
/etc/mo/trust/update-public.pem
```

Alpha 0.5 does not ship a production trust key. CI generates a temporary key
pair for validation and destroys it with the disposable runner.

## CI acceptance

The signed-update test must demonstrate:

1. a valid signed manifest is accepted;
2. its payload hash is verified;
3. a read-only `pre-update-SEQUENCE` snapshot is created;
4. the payload is applied to a disposable Btrfs root;
5. replaying the same sequence is rejected;
6. modifying the payload after signing is rejected.

## Remaining work

Secure Boot requires a separate verified chain: enrolled OVMF keys, signed EFI
loader, signed kernel, negative tamper tests, key rotation, and revocation.
Hardware installation remains blocked until that chain and recovery from an
interrupted update are validated.
