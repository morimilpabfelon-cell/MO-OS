# Debian governs. Arch executes.

## Architectural rule

MO OS is one improved hybrid Linux system with two separated domains:

```text
Debian host
  sovereign control domain
        |
        | fixed allowlisted dispatch
        v
Arch Linux systemd-nspawn domain
  subordinate work domain
        |
        | canonical evidence
        v
Debian validates and signs the final receipt
```

Debian owns boot, kernel, devices, networking, storage, encryption, recovery, trust policy and the Morimil executor boundary. Arch owns recent compilers, SDKs, engines and work execution. `apt` and `pacman` never administer the same root.

## Native components

The first governed execution path contains only Linux-native components:

```text
/usr/local/libexec/mo-arch-dispatch   Debian side
/usr/local/libexec/mo-arch-worker     copied into Arch
```

There is no Android SDK, APK, Jetpack, Room or mobile runtime in MO OS.

## Debian dispatcher

`mo-arch-dispatch`:

- runs on Debian;
- accepts exactly one action: `status`;
- rejects extra arguments and arbitrary commands;
- requires the pinned `mo-dev` machine root;
- requires the fixed worker path;
- starts the `mo-dev` container through `machinectl`;
- invokes only `/usr/local/libexec/mo-arch-worker status`;
- applies a 20-second timeout;
- rejects malformed, unknown or non-Arch output;
- emits canonical validated JSON.

It never forwards user-supplied command strings into Arch.

## Arch worker

`mo-arch-worker`:

- runs inside the Arch domain;
- accepts exactly `status`;
- verifies that `/etc/os-release` identifies Arch Linux;
- reports a fixed schema containing the Arch identity, machine architecture and shared kernel release;
- performs no network access, package installation or filesystem mutation.

`mo-dev-init` installs this worker into the Arch root and runs it once before enabling the container service. Initialization fails closed if the worker cannot prove that the domain is Arch.

## Current activation state

This commit establishes and tests the Debian-to-Arch execution boundary. It does not yet expose `arch.status` through a signed Morimil request. That connection will be enabled only after the dispatcher and worker pass CI as isolated components.

The next activation step is narrow:

```text
signed Morimil request: arch.status
        -> mo-bodyd validates authority
        -> Debian calls mo-arch-dispatch status
        -> Arch runs mo-arch-worker status
        -> Debian validates evidence
        -> mo-bodyd signs the receipt
```

No arbitrary shell, package operation, network operation or project build is authorized by this status foundation.

## Validation

Run:

```bash
make arch-dispatch-test
```

The test verifies:

- valid canonical Arch evidence;
- rejection of arbitrary operations;
- rejection of malformed worker evidence;
- rejection when the Arch domain is missing;
- Bash syntax and ShellCheck validation when available.
