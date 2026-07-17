# MO OS

MO OS es una distribución Linux propia en desarrollo para programación, creación de software y operación local soberana.

## Objetivo

Construir una ISO arrancable e instalable que reemplace Windows cuando haya superado pruebas reales de hardware, recuperación y actualización.

MO OS utiliza dos dominios complementarios:

- **Dominio estable:** base Debian para arranque, hardware, red, seguridad y recuperación.
- **Dominio de desarrollo:** Arch Linux dentro de `systemd-nspawn` para compiladores y herramientas recientes.
- **Capa MO:** comandos, políticas, construcción de imagen y experiencia unificada.

Para el usuario es un solo sistema. Internamente los gestores de paquetes permanecen separados para evitar conflictos entre `apt` y `pacman`.

## Estado actual

**Alpha 0.1 — Terminal Foundation**

Esta fase proporciona:

- Configuración reproducible de una ISO live de terminal.
- Identidad inicial de MO OS.
- Comando nativo `mo`.
- Bootstrap verificable de un dominio Arch Linux.
- Validaciones automáticas del repositorio.

No incluye todavía un instalador de disco habilitado. No debe usarse para borrar Windows ni modificar una laptop principal.

## Construcción

Requiere una máquina Debian o derivada con privilegios de administrador:

```bash
sudo apt-get update
sudo apt-get install -y live-build debootstrap xorriso squashfs-tools shellcheck make
make check
sudo make iso
```

La imagen resultante aparecerá en `artifacts/`.

## Prueba segura

La primera prueba debe realizarse en QEMU:

```bash
make run
```

## Comandos previstos dentro de MO OS

```text
mo status
mo doctor
mo dev-init
mo dev
mo dev-status
mo install
```

`mo install` permanece bloqueado hasta que exista un instalador con pruebas destructivas aisladas, confirmación explícita y recuperación validada.
