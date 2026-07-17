# MO OS

MO OS es una distribución Linux propia en desarrollo para programación, creación de software y operación local soberana.

## Arquitectura

- **Dominio estable:** Debian para arranque, kernel, hardware, red, seguridad y recuperación.
- **Dominio de desarrollo:** Arch Linux dentro de `systemd-nspawn` para compiladores y herramientas recientes.
- **Capa MO:** comandos, políticas, construcción, instalación y experiencia unificada.

Para el usuario es un solo sistema. `apt` y `pacman` nunca administran la misma raíz.

## Estado actual

**Alpha 0.2 — Virtual Disk Installer**

Esta fase proporciona:

- ISO híbrida BIOS/UEFI construida de forma reproducible.
- Arranque de terminal validado en QEMU.
- Instalador persistente restringido a un disco QEMU/KVM desechable.
- Reinicio desde el disco instalado sin depender de la ISO.
- Bootstrap verificable del dominio Arch.
- Comando nativo `mo`.

La ruta destructiva inicial está deliberadamente limitada:

```bash
mo install --virtual --disk /dev/vda --erase
```

El instalador rechaza discos físicos, `/dev/sda`, NVMe, entornos no virtualizados, discos menores de 8 GiB, objetivos montados y cualquier ejecución sin confirmación explícita.

**No debe utilizarse todavía para reemplazar Windows ni instalar sobre una laptop real.**

## Construcción

```bash
sudo apt-get update
sudo apt-get install -y live-build debootstrap xorriso squashfs-tools shellcheck make
make check
sudo make iso
```

La imagen resultante aparece en `artifacts/mo-os-alpha-0.2-amd64.iso`.

## Pruebas

Arranque live:

```bash
make boot-test
```

Instalación completa en un disco virtual desechable y segundo arranque sin ISO:

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
mo install --virtual --disk /dev/vda --erase
```

La instalación sobre hardware real permanecerá bloqueada hasta validar UEFI, cifrado, rollback, recuperación y una matriz de hardware.
