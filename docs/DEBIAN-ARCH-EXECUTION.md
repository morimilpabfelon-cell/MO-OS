# Debian governs. Arch executes.

## Architectural rule

MO OS is one improved hybrid Linux system with two separated roots and one authority path:

```text
signed Morimil request
        |
        v
Debian host
  sovereign control, policy and validation
        |
        | fixed allowlisted dispatch
        v
Arch Linux systemd-nspawn domain
  subordinate work execution
        |
        | structured evidence
        v
Debian validates and signs the final receipt
```

Debian owns boot, kernel, devices, networking, storage, encryption, recovery, trust policy and the executor boundary. Arch owns recent compilers, SDKs, engines and subordinate work. `apt` and `pacman` never administer the same root.

Android is not part of MO OS. No Android SDK, APK, Jetpack, Room or mobile runtime is installed in Debian or Arch.

## Native components

```text
/usr/local/libexec/mo-arch-dispatch   authoritative Debian dispatcher
/usr/local/libexec/mo-arch-worker     fixed worker copied into Arch
```

### Debian dispatcher

`mo-arch-dispatch`:

- accepts exactly one internal action: `status`;
- rejects extra arguments and arbitrary commands;
- requires the fixed `mo-dev` machine root;
- compares the SHA-256 of the Arch worker with Debian's authoritative copy before execution;
- starts `mo-dev` through `machinectl`;
- invokes only `/usr/local/libexec/mo-arch-worker status`;
- applies a 20-second timeout;
- validates the exact output schema and Arch identity;
- emits normalized JSON.

A modified, missing, symlinked or non-executable worker is rejected before the container is invoked.

### Arch worker

`mo-arch-worker`:

- accepts exactly `status`;
- verifies that `/etc/os-release` identifies Arch Linux;
- reports only the fixed status schema;
- performs no network access, package installation or filesystem mutation.

`mo-dev-init` installs the worker with mode `0755`, verifies its SHA-256 against the Debian source, and runs it once before enabling the container service.

## Signed activation

The boundary is connected to the signed executor as `arch.status`:

```text
arch.status request signed by the paired controller
        -> mo-bodyd verifies exact request bytes and policy
        -> Debian records replay protection
        -> Debian calls mo-arch-dispatch status
        -> Arch runs the fixed worker
        -> Debian validates the returned evidence
        -> mo-bodyd creates an atomic signed receipt
```

Both `system.status` and `arch.status` require an empty `parameters` object. No shell, package operation, network operation or project build is authorized.

A request rejected before acceptance receives status `rejected`. A valid accepted request whose Arch execution or evidence validation fails receives status `failed`. A repeated accepted `request_id` is rejected as replay and does not create a second receipt.

## Validation scope

Run:

```bash
make executor-test
make arch-dispatch-test
```

The automated tests verify signatures, Ed25519 key enforcement, replay under a different bundle name, worker integrity, fixed operation dispatch, malformed evidence, wrong-domain evidence and failure semantics.

The CI contract test uses controlled substitutes for `machinectl` and the Arch machine root. The system workflow separately validates ISO construction, Secure Boot, live boot, encrypted installation and rollback. It does **not** currently download the Arch bootstrap and boot a real `mo-dev` container on every CI run; that remains a distinct integration test to add before hardware deployment.
