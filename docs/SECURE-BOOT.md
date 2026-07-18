# MO OS Secure Boot UKI Foundation

## Objetivo

Alpha `0.5.0-alpha.2` demuestra dentro de QEMU que el firmware UEFI puede validar una Unified Kernel Image que contiene el kernel y el initramfs reales de MO OS.

Esta fase no crea claves de producción ni habilita instalación sobre hardware físico.

## Cadena validada

```text
OVMF Secure Boot
└── UEFI db temporal
    └── UKI firmado
        ├── systemd-stub
        ├── kernel MO OS
        ├── initramfs MO OS
        ├── command line fija
        └── metadatos de versión
            └── live filesystem de la ISO
                └── mo-boot-test.target
                    └── MO_OS_BOOT_READY
```

La prueba extrae `/live/vmlinuz` y `/live/initrd.img` de la ISO recién construida. No utiliza un kernel de demostración ni un ejecutable EFI independiente.

## Material criptográfico

CI genera temporalmente:

```text
RSA-3072 private key
X.509 certificate
PK
KEK
db
```

El mismo certificado de prueba se utiliza para PK, KEK y `db` únicamente dentro de una variable store OVMF desechable. Esta simplificación es aceptable para demostrar el flujo, pero no es el diseño de custodia de producción.

La clave privada:

- se crea dentro de `mktemp`;
- tiene permisos `0600`;
- no se copia a diagnósticos;
- no entra a la ISO;
- no entra al repositorio;
- se elimina mediante el trap de salida.

## Casos obligatorios

### UKI firmado

Debe:

1. ser validado mediante `sbverify`;
2. ser aceptado por OVMF Secure Boot;
3. iniciar el kernel incorporado;
4. encontrar el sistema live en la ISO;
5. alcanzar `mo-boot-test.target`;
6. emitir `MO_OS_BOOT_READY`.

### UKI sin firma

Debe ser rechazado y nunca emitir `MO_OS_BOOT_READY`.

### UKI firmado y modificado

Después de alterar un byte, la firma debe quedar inválida y OVMF no debe permitir que alcance `MO_OS_BOOT_READY`.

## Herramientas

- `ukify`: construye el UKI.
- `sbsigntool`: inspecciona la firma Authenticode.
- `virt-fw-vars`: enrola PK, KEK y `db` en una variable store OVMF.
- `OVMF_CODE*.secboot.fd`: firmware con soporte Secure Boot.
- QEMU `q35` con SMM: ejecuta la máquina virtual de validación.

## Límites actuales

Esta fase todavía no proporciona:

- claves offline de producción;
- separación real entre PK, KEK y `db`;
- ceremonia de generación de claves;
- rotación de certificados;
- actualización autenticada de variables UEFI;
- lista `dbx` de revocaciones;
- SBAT de producción;
- firma persistente del instalador y del disco final;
- integración con TPM o measured boot;
- recuperación de claves perdida;
- soporte para firmware físico específico.

## Regla de avance

No se habilitará instalación sobre hardware físico hasta que exista:

1. custodia documentada de claves;
2. rotación y revocación probadas;
3. imagen de recuperación firmada;
4. validación en USB live sin escritura;
5. inventario completo del hardware objetivo;
6. copia externa verificada de los datos existentes.
