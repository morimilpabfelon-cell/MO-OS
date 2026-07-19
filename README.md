# MO OS

MO OS es el sistema de trabajo nativo de Morimil. Está diseñado como una distribución Linux híbrida propia para ejecución local soberana, programación, creación de software y operación controlada por la instancia Morimil.

## Arquitectura

- **Dominio estable:** Debian para arranque, kernel, hardware, red, seguridad, identidad técnica y recuperación.
- **Dominio de trabajo:** Arch Linux dentro de `systemd-nspawn` para compiladores, motores y herramientas recientes.
- **Capa MO:** comandos, políticas, construcción, instalación y coordinación entre Debian y Arch.

Para Morimil es un solo sistema. `apt` y `pacman` nunca administran la misma raíz. Debian gobierna el sistema; Arch ejecuta trabajo dentro de una frontera subordinada.

MO OS permanece Linux nativo y puro en su composición. No incorpora Android, Android SDK, APK, Jetpack, Room ni dependencias móviles. Morimil-app controla el sistema desde fuera mediante una frontera criptográfica neutral; el transporte o cliente que entregue una solicitud no se integra en la raíz Debian ni en el dominio Arch.

## Estado actual

**Alpha 0.6 — Morimil Executor Foundation (`0.6.0-alpha.1`)**

Esta fase conserva la instalación virtual cifrada, snapshots, rollback, actualizaciones firmadas y Secure Boot UKI de Alpha 0.5, y añade la primera frontera nativa de trabajo controlada externamente por Morimil:

- Servicio Linux nativo `mo-bodyd` ejecutado por Debian.
- Identidad Ed25519 local del executor usada únicamente para firmar recibos.
- Emparejamiento exclusivo con una instancia Morimil y una autoridad de control registrada.
- Solicitudes JSON canónicas firmadas por la autoridad de control.
- Verificación exacta de `instance_id`, `controller_body_id` y `target_executor_id`.
- Ventana máxima de validez de cinco minutos.
- Protección atómica contra replay mediante `request_id`.
- Lista local y cerrada de operaciones permitidas.
- Recibos JSON firmados por el executor.
- Journal local append-only de eventos de seguridad.
- Servicio systemd sin capacidades Linux y con filesystem del sistema protegido.

La operación inicial permitida es únicamente:

```text
system.status
```

Alpha 0.6 no permite comandos arbitrarios, escritura de memoria canónica, acceso a dispositivos, red, archivos protegidos ni ejecución dentro de Arch. Morimil conserva todo el control y sigue siendo la autoridad exclusiva de solicitudes.

## Frontera externa de control

```text
Morimil-app / autoridad Morimil
  fuera de MO OS
  identidad, memoria y decisión
          |
          | solicitud Ed25519 firmada
          v
MO OS / Debian / mo-bodyd
  valida autoridad y política
          |
          | operación Linux permitida
          v
Arch Linux subordinado
  futuro dominio de ejecución aislada
          |
          | recibo Ed25519 firmado
          v
Morimil verifica el resultado
```

La clave del executor declara autoridad `receipt_signing_only`. No puede concederse permisos, modificar la identidad de Morimil ni convertirse en escritor de memoria canónica.

El contrato de solicitudes es neutral y no instala componentes del cliente dentro de MO OS. Morimil-app puede producir solicitudes compatibles, pero Android permanece completamente fuera del sistema operativo.

## Inicialización del executor

```bash
sudo mo executor init
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id BODY_ID
mo executor status
```

El emparejamiento es único y fail-closed durante esta fase. Al completarse, se habilita `mo-bodyd.service`.

La especificación completa está en `docs/MORIMIL-EXECUTOR.md`.

## Secure Boot y actualizaciones

La cadena virtual conserva:

- extracción del kernel y del initramfs reales desde la ISO;
- construcción de una Unified Kernel Image mediante `ukify`;
- firma temporal RSA-3072/SHA-256 del UKI;
- aceptación del UKI firmado bajo OVMF Secure Boot;
- rechazo del UKI sin firma o modificado;
- actualización firmada con secuencia monotónica;
- snapshot Btrfs previo a cada actualización permitida.

Las claves de Secure Boot y actualización siguen siendo efímeras de CI. No son claves de producción.

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
make executor-test
sudo make update-test
sudo make iso
```

La imagen resultante aparece en:

```text
artifacts/mo-os-alpha-0.6-amd64.iso
```

## Pruebas

```bash
make executor-test
make boot-test
make secure-boot-test
sudo make update-test
make install-test
```

`executor-test` genera claves Ed25519 temporales y comprueba una solicitud válida, la firma del recibo, replay, manipulación, destino incorrecto, operación no permitida y expiración.

`secure-boot-test` construye un UKI desde el kernel y el initramfs de la ISO, firma el UKI, enrola una variable store OVMF desechable, exige un arranque válido y comprueba el rechazo de las variantes sin firma y alterada.

`update-test` genera una clave temporal, firma un bundle, crea una raíz Btrfs desechable, aplica la actualización, comprueba el snapshot previo, rechaza repetir la secuencia y rechaza una copia alterada.

## Comandos dentro de MO OS

```text
mo status
mo doctor
mo dev-init
mo dev
mo dev-status
mo executor init
mo executor pair --controller-key FILE --instance-id ID --controller-body-id ID
mo executor status
mo executor process --bundle DIRECTORIO
mo executor start
mo executor stop
mo snapshot create NOMBRE
mo snapshot list
mo recovery rollback --virtual --firmware uefi --disk /dev/vda --snapshot NOMBRE
mo update verify --bundle DIRECTORIO
mo update apply --bundle DIRECTORIO
mo update status
```

La instalación sobre hardware real permanecerá bloqueada hasta validar claves de producción, rotación y revocación, recuperación ante actualizaciones interrumpidas, copias externas y una matriz del hardware específico de la computadora objetivo.
