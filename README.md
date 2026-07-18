# MO OS

MO OS es una distribución Linux propia en desarrollo para programación, creación de software y operación local soberana.

## Arquitectura

- **Dominio estable:** Debian para arranque, kernel, hardware, red, seguridad y recuperación.
- **Dominio de desarrollo:** Arch Linux dentro de `systemd-nspawn` para compiladores y herramientas recientes.
- **Capa MO:** comandos, políticas, construcción, instalación y experiencia unificada.

Para el usuario es un solo sistema. `apt` y `pacman` nunca administran la misma raíz.

## Estado actual

**Alpha 0.4 — Encrypted Recovery Foundation**

Esta fase proporciona:

- ISO híbrida BIOS/UEFI construida de forma reproducible.
- Arranque live validado en QEMU.
- Instalador UEFI restringido a un disco QEMU/KVM desechable.
- ESP FAT32 y `/boot` ext4 separados.
- Raíz cifrada mediante LUKS2.
- Btrfs con subvolúmenes `@`, `@home` y `@snapshots`.
- Snapshot inicial de solo lectura.
- Comandos `mo snapshot` y `mo recovery`.
- Prueba automatizada de instalación, desbloqueo, mutación, rollback y segundo arranque.
- Bootstrap verificable del dominio Arch.

La ruta destructiva continúa deliberadamente limitada:

```bash
mo install \
  --virtual \
  --firmware uefi \
  --disk /dev/vda \
  --erase \
  --username NOMBRE
```

El instalador rechaza discos físicos, `/dev/sda`, NVMe, entornos no virtualizados, discos menores de 8 GiB, objetivos montados y cualquier ejecución sin confirmación explícita.

**No debe utilizarse todavía para reemplazar Windows ni instalar sobre una laptop real.**

## Diseño de disco Alpha 0.4

```text
GPT
├── /dev/vda1  ESP FAT32 — 512 MiB
├── /dev/vda2  /boot ext4 — 1 GiB
└── /dev/vda3  LUKS2
    └── Btrfs
        ├── @
        ├── @home
        └── @snapshots
```

`@home` permanece separado del rollback de la raíz. La recuperación crea una copia de seguridad de la raíz actual antes de restaurar el snapshot seleccionado.

## Construcción

```bash
sudo apt-get update
sudo apt-get install -y live-build debootstrap xorriso squashfs-tools shellcheck make
make check
sudo make iso
```

La imagen resultante aparece en:

```text
artifacts/mo-os-alpha-0.4-amd64.iso
```

## Pruebas

Arranque live:

```bash
make boot-test
```

Instalación cifrada, desbloqueo, mutación, rollback y segundo arranque:

```bash
make install-test
```

## Comandos dentro de MO OS

```text
mo status
mo doctor
mo dev-init
mo dev
mo dev-status
mo snapshot create NOMBRE
mo snapshot list
mo recovery rollback --virtual --firmware uefi --disk /dev/vda --snapshot NOMBRE
```

La instalación sobre hardware real permanecerá bloqueada hasta validar recuperación ante interrupciones, copias externas, Secure Boot y una matriz del hardware específico de la laptop.
