# MO OS Alpha 0.3 — UEFI Virtual Installer

Alpha 0.3 valida una instalación persistente exclusivamente dentro de QEMU/KVM mediante firmware OVMF.

## Flujo validado

1. Arrancar la ISO mediante UEFI.
2. Autorizar únicamente el disco VirtIO `/dev/vda`.
3. Crear GPT, una ESP FAT32 de 512 MiB y una raíz ext4.
4. Copiar MO OS al disco.
5. Crear una cuenta persistente.
6. Instalar GRUB x86_64-efi en `EFI/BOOT/BOOTX64.EFI`.
7. Apagar la máquina virtual.
8. Arrancar con una copia nueva de las variables OVMF y sin la ISO.

## Frontera de seguridad

- Solo QEMU/KVM.
- Solo `/dev/vda`.
- Requiere `--virtual`, `--firmware uefi` y `--erase`.
- Rechaza discos físicos, SATA y NVMe.
- El modo CI crea una cuenta bloqueada; no hay contraseña predeterminada.
- No está autorizado para reemplazar Windows ni instalarse en hardware real.
