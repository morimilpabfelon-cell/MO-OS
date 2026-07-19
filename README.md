# MO OS

MO OS es el sistema de trabajo nativo de Morimil: una distribución Linux híbrida propia para ejecución local soberana, desarrollo y operación controlada.

> **Debian gobierna. Arch ejecuta.**

## Arquitectura

- **Debian:** arranque, kernel, hardware, red, almacenamiento, cifrado, recuperación, confianza y autorización.
- **Arch Linux:** dominio subordinado `systemd-nspawn` para compiladores, SDK, motores y trabajo reciente.
- **Capa MO:** políticas, comandos, construcción, instalación y evidencia entre ambos dominios.

`apt` y `pacman` nunca administran la misma raíz. Android no forma parte de MO OS: no se incluyen Android SDK, APK, Jetpack, Room ni dependencias móviles. Morimil-app puede controlar desde fuera mediante solicitudes firmadas, pero no entra en Debian, Arch ni la ISO.

## Estado actual

**Alpha 0.6 — Signed Debian-Governed Arch Executor (`0.6.0-alpha.1`)**

La rama conserva instalación virtual LUKS2/Btrfs, snapshots, rollback, actualizaciones firmadas y Secure Boot UKI. Añade:

- `mo-bodyd`, executor Linux nativo ejecutado bajo política Debian;
- identidad Ed25519 limitada a `receipt_signing_only`;
- emparejamiento exclusivo con una autoridad externa Ed25519;
- validación exacta de identidad, pairing, clave, destino, tiempo y replay;
- firma sobre los mismos bytes canónicos que fueron leídos y hashados;
- límite de tamaño para solicitudes, claves, firmas y salida de comandos;
- recibos firmados publicados mediante directorio atómico;
- colas `processed` y `quarantine` para impedir reintentos infinitos;
- `mo-arch-dispatch` como única puerta Debian→Arch;
- verificación SHA-256 del worker Arch contra la copia autorizada de Debian;
- `mo doctor` extendido a toda la frontera.

## Operaciones permitidas

```text
system.status  — ejecutada localmente por Debian
arch.status    — autorizada por Debian y ejecutada por el worker fijo de Arch
```

Ambas exigen `parameters: {}`. No existe shell arbitraria, instalación de paquetes por solicitud, escritura de memoria canónica, acceso autónomo a red, GPU, dispositivos ni archivos protegidos.

## Flujo firmado

```text
Morimil firma request.json
        ↓
Debian / mo-bodyd valida Ed25519, política, destino, tiempo y replay
        ↓
Debian autoriza system.status o arch.status
        ↓
mo-arch-dispatch verifica el worker y permite solo status
        ↓
Arch / mo-arch-worker produce evidencia estructurada
        ↓
Debian valida la evidencia y firma el recibo
```

Los estados del recibo son:

```text
completed  solicitud aceptada y operación exitosa
failed     solicitud aceptada, pero ejecución o evidencia falló
rejected   solicitud rechazada antes de ser aceptada
```

Un `request_id` aceptado no puede reutilizarse bajo otro nombre de bundle. El replay termina con error y no crea un segundo recibo.

## Inicialización del executor

```bash
sudo mo executor init
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id BODY_ID
mo executor status
```

El emparejamiento es único y fail-closed en esta Alpha. La especificación está en `docs/MORIMIL-EXECUTOR.md`; la frontera Debian→Arch está en `docs/DEBIAN-ARCH-EXECUTION.md`.

## Instalación virtual cifrada

```bash
mo install \
  --virtual \
  --firmware uefi \
  --disk /dev/vda \
  --erase \
  --username NOMBRE
```

La instalación crea:

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

El instalador deriva `MO_INSTALLER_VERSION` de `/etc/mo-release`; no mantiene una versión histórica fija. Rechaza discos físicos, SATA, NVMe, entornos no virtualizados, discos menores de 8 GiB, objetivos montados y ejecuciones sin confirmación explícita.

**No debe usarse todavía para reemplazar Windows ni instalar sobre una laptop real.**

## Construcción

```bash
sudo apt-get update
sudo apt-get install -y live-build debootstrap xorriso squashfs-tools shellcheck make
make check
make executor-test
make arch-dispatch-test
sudo make update-test
sudo make iso
```

La imagen aparece en:

```text
artifacts/mo-os-alpha-0.6-amd64.iso
```

La construcción rechaza `.pyc`, `.pyo` y directorios `__pycache__` dentro del árbol que se copia a la ISO.

## Pruebas

```bash
make executor-test
make arch-dispatch-test
make boot-test
make secure-boot-test
sudo make update-test
make install-test
```

Las pruebas cubren Ed25519-only, firmas exactas, firma sobredimensionada, replay con otro nombre, manipulación de política, `system.status`, `arch.status`, worker modificado, evidencia malformada, dominio incorrecto, Secure Boot, ISO live, actualización firmada, instalación cifrada y rollback.

### Alcance real de CI

La prueba Debian→Arch usa sustitutos controlados de `machinectl` y del root Arch para comprobar el contrato, la lista cerrada y la evidencia. El workflow del sistema valida por separado la ISO, Secure Boot, arranque live, instalación cifrada y rollback.

CI **todavía no descarga el bootstrap de Arch ni arranca un contenedor `mo-dev` real en cada ejecución**. Esa prueba de integración debe añadirse antes de habilitar instalación en hardware físico o operaciones de trabajo más amplias.

## Comandos

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

La instalación física seguirá bloqueada hasta validar claves de producción, rotación y revocación, recuperación ante interrupciones, copias externas, un contenedor Arch real y la matriz del hardware objetivo.
