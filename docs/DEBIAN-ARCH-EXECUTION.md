# Debian governs. Arch executes.

## Architectural rule

MO OS is one improved hybrid Linux system with separated Debian and Arch roots and one authority path:

```text
signed Morimil request
        |
        v
Debian host
  sovereign control, policy, durable state and validation
        |
        | fixed allowlisted dispatch
        v
Arch Linux systemd-nspawn domain
  subordinate execution
        |
        | canonical structured evidence
        v
Debian validates and signs the final receipt
```

Debian owns boot, kernel, devices, networking, storage, encryption, recovery, trust policy and the executor boundary. Arch owns recent compilers, SDKs, engines and subordinate work. `apt` and `pacman` never administer the same root.

Android is not part of MO OS. No Android SDK, APK, Jetpack, Room, Gradle Android or mobile runtime is installed in Debian or Arch.

## Native components

```text
/usr/local/libexec/mo-arch-dispatch   authoritative Debian dispatcher
/usr/local/libexec/mo-arch-worker     fixed Bash worker copied into Arch
```

## Debian dispatcher

`mo-arch-dispatch`:

- accepts exactly one internal action: `status`;
- rejects extra arguments and arbitrary commands;
- requires the fixed and already-running `mo-dev` machine;
- never starts Arch in response to `arch.status`;
- resolves the machine root and worker paths canonically;
- rejects linked roots, linked workers and intermediate path escapes;
- compares the guest worker SHA-256 with Debian's authoritative worker before execution;
- reads the machine `State`, `RootDirectory` and `Leader` through `machinectl` with bounded timeouts;
- requires `State=running` and the registered root `/var/lib/machines/mo-dev`;
- compares `/proc/LEADER/root` with the authorized root by filesystem device and inode;
- rechecks the leader before and after delegated execution;
- enters only the leader's mount, UTS, IPC, network, PID and cgroup namespaces through `nsenter`;
- executes only `/usr/local/libexec/mo-arch-worker status`;
- validates the exact evidence schema and Arch identity;
- emits normalized canonical JSON.

The dispatcher does not use `machinectl shell` and does not depend on a system bus inside Arch. A stopped machine, changed leader, wrong root, modified worker, missing worker, path escape or malformed result is rejected.

Starting Arch remains an explicit Debian administrative action through `mo dev` or systemd policy, never a side effect of a signed status request.

## Arch worker

`mo-arch-worker`:

- is implemented in Bash and accepts exactly `status`;
- reads only the fixed `/usr/lib/os-release`;
- requires `ID=arch` and rejects duplicate relevant fields;
- uses `/usr/bin/uname` for kernel release and architecture;
- emits the fixed `mo.arch.worker.status.v0.1` canonical JSON schema;
- performs no network access, package installation or filesystem mutation;
- does not require Python or a guest system bus.

`mo-dev-init` installs the worker with mode `0755`, verifies its SHA-256 against the Debian source and executes the fixed status operation before enabling the container service.

## Signed activation

The boundary is connected to the signed executor as `arch.status`:

```text
arch.status request signed by the paired controller
        -> mo-executord snapshots the bundle and serializes processing
        -> mo-bodyd verifies exact bytes, Ed25519 authority and policy
        -> Debian records durable accepted/executing state
        -> Debian confirms that mo-dev is already running
        -> Debian calls mo-arch-dispatch status
        -> nsenter executes the fixed worker in the verified Arch namespaces
        -> Debian validates the returned evidence
        -> mo-executord publishes an atomic signed receipt and terminal state
```

Both `system.status` and `arch.status` require an empty `parameters` object. No shell, package operation, network operation, container start or project build is authorized.

A request rejected before acceptance receives status `rejected`. A valid accepted request whose Arch execution or evidence validation fails receives status `failed`. A repeated accepted `request_id` is rejected as replay and does not create a second receipt.

## Validation scope

Run:

```bash
make executor-test
make arch-dispatch-test
sudo make arch-real-integration-test
```

The controlled tests verify signatures, Ed25519 key enforcement, replay, worker integrity, canonical paths, stopped-machine rejection, root and leader identity, fixed namespace arguments, malformed evidence and failure semantics.

The real integration test runs on every candidate workflow:

1. downloads `archlinux-bootstrap-2026.07.01-x86_64.tar.zst` over HTTPS;
2. verifies the pinned SHA-256 before extraction;
3. creates the real root `/var/lib/machines/mo-dev`;
4. installs matching host and guest workers;
5. starts a real `systemd-nspawn` machine with registration and private networking;
6. executes the production dispatcher without test mode;
7. requires canonical evidence with `domain=arch` and `os_release.ID=arch`;
8. modifies the guest worker and requires `arch_worker_integrity_mismatch`;
9. terminates the machine and verifies complete cleanup.

The integration test does not run `pacman`, install guest packages or enable arbitrary guest commands. The system workflow then validates ISO construction, exact checksum and PVD metadata, Secure Boot, live boot, encrypted installation and rollback.

## Deliberate limits

The validated operation remains read-only `arch.status`. Mutable delegated operations, project builds, autonomous networking, hardware access and arbitrary commands remain forbidden. Physical-hardware deployment still requires production key custody, device-specific driver and power validation, recovery media and a supported hardware matrix.
