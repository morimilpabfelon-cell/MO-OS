# MO OS

MO OS es el sistema de trabajo nativo de Morimil: una distribución Linux híbrida propia para ejecución local soberana, desarrollo y operación controlada.

> **Morimil decide. Debian gobierna. Arch ejecuta. Android permanece fuera de MO-OS.**

## Arquitectura

- **Morimil:** autoridad externa que firma solicitudes y conserva la autoridad sobre memoria canónica.
- **Debian:** arranque, kernel, hardware, red, almacenamiento, cifrado, recuperación, confianza, autorización y validación.
- **Arch Linux:** dominio subordinado `systemd-nspawn` para compiladores, SDK, motores y trabajo reciente.
- **Capa MO:** políticas, comandos, construcción, instalación, estados durables y evidencia entre ambos dominios.

`apt` y `pacman` nunca administran la misma raíz. Android no forma parte de MO OS: no se incluyen Android SDK, APK, Jetpack, Room, Gradle Android ni dependencias móviles. Morimil-app controla desde fuera mediante solicitudes firmadas y no se instala en Debian, Arch ni la ISO.

## Estado actual

**Alpha 0.6 — Audited Debian-Governed Arch Executor (`0.6.0-alpha.1`)**

La rama conserva instalación virtual LUKS2/Btrfs, snapshots, rollback, actualizaciones firmadas y Secure Boot UKI. Añade:

- `/usr/local/sbin/mo-bodyd`, núcleo criptográfico y de operaciones permitidas;
- `/usr/local/sbin/mo-executord`, coordinador durable del executor;
- identidad Ed25519 limitada a `receipt_signing_only`;
- emparejamiento exclusivo con una autoridad externa Ed25519;
- validación exacta de identidad, pairing, clave, destino, tiempo y replay;
- firma sobre los mismos bytes canónicos que fueron leídos y hashados;
- límites de tamaño para solicitudes, claves, firmas y salida;
- estados durables `accepted`, `executing`, `completed` y `failed`;
- recibos firmados publicados mediante directorio atómico;
- recuperación tras interrupciones sin reejecución automática;
- colas `processed` y `quarantine` para impedir reintentos infinitos;
- `mo-arch-dispatch` como única puerta Debian→Arch;
- verificación SHA-256 del worker Arch contra la copia autorizada de Debian;
- validación real de un contenedor Arch mediante `systemd-nspawn` en CI;
- `mo doctor` extendido a toda la frontera.

## Operaciones permitidas

```text
system.status  — ejecutada localmente por Debian
arch.status    — autorizada por Debian y ejecutada por el worker fijo de Arch
```

Ambas exigen `parameters: {}`. No existe shell arbitraria, instalación de paquetes por solicitud, escritura de memoria canónica, acceso autónomo a red, GPU, dispositivos ni archivos protegidos.

## Flujo firmado y durable

```text
Morimil firma request.json
        ↓
Debian / mo-executord serializa y conserva el estado durable
        ↓
Debian / mo-bodyd valida Ed25519, política, destino, tiempo y operación
        ↓
Debian autoriza system.status o arch.status
        ↓
mo-arch-dispatch verifica identidad, root y SHA-256 del worker
        ↓
Arch / mo-arch-worker produce evidencia estructurada
        ↓
Debian valida la evidencia, firma el recibo y finaliza el estado
```

Cada solicitud aceptada tiene un estado canónico en:

```text
/var/lib/mo-bodyd/requests/REQUEST_ID.json
```

Transiciones permitidas:

```text
accepted  → executing
accepted  → failed
executing → completed
executing → failed
```

`completed` y `failed` son terminales. Un `request_id` terminal no puede reutilizarse y un mismo identificador con otro payload se rechaza como conflicto.

Si el proceso cae después de `accepted`, la recuperación publica un recibo `failed` y no ejecuta la operación. Si cae durante `executing`, no repite la operación y registra un resultado desconocido tras la interrupción. MO OS no promete semántica exactamente-una-vez para efectos externos.

## Frontera Debian → Arch

Para `arch.status`, Debian:

1. exige el dominio fijo `mo-dev` ya iniciado;
2. verifica `State`, `RootDirectory` y `Leader` mediante `machinectl`;
3. comprueba que `/proc/LEADER/root` y `/var/lib/machines/mo-dev` representan el mismo objeto de filesystem;
4. rechaza roots y workers no canónicos o enlazados;
5. compara el SHA-256 del worker Arch con la copia autorizada del host;
6. entra únicamente en los namespaces del líder mediante `nsenter`;
7. ejecuta solo `/usr/local/libexec/mo-arch-worker status`;
8. confirma que el líder no cambió durante la ejecución;
9. valida el esquema exacto, `domain=arch` y `os_release.ID=arch`.

El worker está escrito en Bash y usa únicamente `/usr/lib/os-release` y `/usr/bin/uname`. No depende de Python, de un bus de sistema dentro de Arch ni de paquetes añadidos durante la prueba.

## Inicialización del executor

```bash
sudo mo executor init
sudo mo executor pair \
  --controller-key morimil-controller-public.pem \
  --instance-id INSTANCE_ID \
  --controller-body-id BODY_ID
mo executor status
sudo mo executor recover
```

El emparejamiento es único y fail-closed en esta Alpha. La especificación está en `docs/MORIMIL-EXECUTOR.md`; la frontera Debian→Arch está en `docs/DEBIAN-ARCH-EXECUTION.md`; la recuperación durable está en `docs/EXECUTOR-RECOVERY.md`.

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

El instalador deriva `MO_INSTALLER_VERSION` de `/etc/mo-release`. Rechaza discos físicos, SATA, NVMe, entornos no virtualizados, discos menores de 8 GiB, objetivos montados y ejecuciones sin confirmación explícita.

**No debe usarse todavía para reemplazar Windows ni instalar sobre una laptop o teléfono real.**

## Construcción

```bash
sudo apt-get update
sudo apt-get install -y live-build debootstrap xorriso squashfs-tools shellcheck make
make check
make executor-test
make arch-dispatch-test
sudo make arch-real-integration-test
sudo make update-test
sudo make iso
```

La imagen aparece en:

```text
artifacts/mo-os-alpha-0.6-amd64.iso
```

La construcción rechaza `.pyc`, `.pyo` y directorios `__pycache__` dentro del árbol copiado a la ISO.

## Alcance real de CI

CI ejecuta dos niveles complementarios:

- pruebas controladas para errores deterministas: firmas, replay, conflictos, estados, recuperación, roots no canónicos, cambio de líder, evidencia malformada y worker alterado;
- integración real Debian→Arch: descarga el bootstrap Arch `2026.07.01`, verifica su SHA-256 fijado, crea `/var/lib/machines/mo-dev`, arranca `systemd-nspawn`, ejecuta el dispatcher de producción mediante `nsenter`, exige identidad Arch, prueba alteración del worker y destruye los recursos temporales.

El contenedor de integración no ejecuta `pacman`, no instala paquetes y utiliza red privada. La misma cadena construye la ISO, verifica checksum y PVD, valida Secure Boot, arranca en QEMU e instala, modifica y revierte una raíz LUKS2/Btrfs.

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
mo executor recover
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

## Límites deliberados

La instalación física permanece bloqueada hasta contar con claves de producción bajo custodia adecuada, rotación y revocación, matriz del hardware objetivo, drivers y energía validados, recuperación externa y pruebas prolongadas en dispositivos reales. La Alpha tampoco autoriza operaciones delegadas mutables, comandos arbitrarios ni afirmaciones de compilación hermética o reproducibilidad bit a bit.
