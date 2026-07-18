# MO OS

MO OS es una distribución Linux propia en desarrollo para programación, creación de software y operación local soberana.

## Arquitectura

- **Dominio estable:** Debian para arranque, kernel, hardware, red, seguridad y recuperación.
- **Dominio de desarrollo:** Arch Linux dentro de `systemd-nspawn` para compiladores y herramientas recientes.
- **Capa MO:** comandos, políticas, construcción, instalación y experiencia unificada.

Para el usuario es un solo sistema. `apt` y `pacman` nunca administran la misma raíz.

## Estado actual

**Alpha 0.5 — Trusted Updates Foundation**

Esta fase conserva todo lo validado en Alpha 0.4 y añade:

- Verificación RSA-SHA256 de manifiestos de actualización.
- SHA-256 obligatorio del contenido firmado.
- Número de secuencia monotónico para impedir repetición o retroceso.
- Snapshot Btrfs de solo lectura antes de aplicar cambios.
- Lista estricta de rutas permitidas.
- Rechazo de rutas absolutas, traversal, enlaces y archivos especiales.
- Límites de 128 archivos y 32 MiB durante esta primera fundación.
- Prueba automática de firma válida, manipulación, snapshot y anti-replay.
- Comando nativo `mo update`.

La raíz persistente continúa protegida mediante LUKS2 y Btrfs:

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

La clave pública de actualizaciones se ubicará en:

```text
/etc/mo/trust/update-public.pem
```

La rama Alpha 0.5 no incluye todavía una clave pública de producción. CI genera una clave temporal para las pruebas. Ninguna clave privada debe entrar al repositorio, ISO, sistema instalado, bundle o artefactos.

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
sudo make update-test
make install-test
```

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

La instalación sobre hardware real permanecerá bloqueada hasta validar Secure Boot, rotación y revocación de claves, recuperación ante actualizaciones interrumpidas, copias externas y una matriz del hardware específico de la laptop.
