# MO OS

MO OS es una distribución Linux propia en desarrollo para programación, creación de software y operación local soberana.

## Arquitectura

- **Dominio estable:** Debian para arranque, kernel, hardware, red, seguridad y recuperación.
- **Dominio de desarrollo:** Arch Linux dentro de `systemd-nspawn` para compiladores y herramientas recientes.
- **Capa MO:** comandos, políticas, construcción, instalación y experiencia unificada.

Para el usuario es un solo sistema. `apt` y `pacman` nunca administran la misma raíz.

## Estado actual

**Alpha 0.5 — Secure Boot UKI Foundation (`0.5.0-alpha.2`)**

Esta fase conserva las actualizaciones firmadas de Alpha 0.5.1 y añade una cadena de arranque confiable virtual:

- Extracción del kernel y del initramfs reales desde la ISO de MO OS.
- Construcción de una Unified Kernel Image mediante `ukify`.
- Firma temporal RSA-3072/SHA-256 del UKI.
- Enrolamiento temporal de PK, KEK y `db` dentro de una variable store OVMF nueva.
- Arranque bajo OVMF con Secure Boot y SMM activados.
- Aceptación obligatoria del UKI firmado hasta alcanzar `MO_OS_BOOT_READY`.
- Rechazo obligatorio del mismo UKI sin firma.
- Rechazo obligatorio del UKI firmado después de modificar un byte.
- Eliminación de la clave privada temporal al finalizar cada ejecución.

Las actualizaciones continúan protegidas mediante:

- Verificación RSA-SHA256 del manifiesto.
- SHA-256 obligatorio del payload.
- Secuencia monotónica contra replay y downgrade.
- Snapshot Btrfs de solo lectura antes de aplicar cambios.
- Lista estricta de rutas y límites de tamaño.

## Raíz cifrada y recuperación

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

## Frontera de confianza

Las claves privadas de actualizaciones y Secure Boot no deben entrar al repositorio, ISO, sistema instalado, bundle ni artefactos.

La futura clave pública de actualizaciones se ubicará en:

```text
/etc/mo/trust/update-public.pem
```

Alpha 0.5 usa claves efímeras generadas por CI. Esto demuestra la cadena criptográfica, pero todavía no define custodia, rotación, revocación ni claves de producción.

## Instalación virtual cifrada

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

## Construcción

```bash
sudo apt-get update
sudo apt-get install -y live-build debootstrap xorriso squashfs-tools shellcheck make
make check
sudo make update-test
sudo make iso
```

La imagen resultante aparece en:

```text
artifacts/mo-os-alpha-0.5-amd64.iso
```

## Pruebas

```bash
make boot-test
make secure-boot-test
sudo make update-test
make install-test
```

`secure-boot-test` construye un UKI desde el kernel y el initramfs de la ISO, firma el UKI, enrola una variable store OVMF desechable, exige un arranque válido y comprueba el rechazo de las variantes sin firma y alterada.

`update-test` genera una clave temporal, firma un bundle, crea una raíz Btrfs desechable, aplica la actualización, comprueba el snapshot previo, rechaza repetir la secuencia y rechaza una copia alterada.

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
mo update verify --bundle DIRECTORIO
mo update apply --bundle DIRECTORIO
mo update status
```

La instalación sobre hardware real permanecerá bloqueada hasta validar claves de producción, rotación y revocación, recuperación ante actualizaciones interrumpidas, copias externas y una matriz del hardware específico de la laptop.
