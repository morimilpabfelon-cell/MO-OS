# Arquitectura de MO OS

## 1. Definición

MO OS será una distribución Linux propia que arranca directamente en hardware y ofrece un único entorno para terminal, programación, GitHub, navegador, aplicaciones y desarrollo del propio sistema.

## 2. Arquitectura inicial

```text
Hardware
└── UEFI
    └── Linux
        └── MO OS
            ├── Dominio estable Debian
            ├── MO Core
            └── Dominio de desarrollo Arch
```

### Dominio estable

Responsable de:

- Arranque y kernel.
- Firmware y controladores.
- systemd.
- Red y almacenamiento.
- Herramientas de recuperación.
- Construcción de la ISO.

### Dominio Arch

Arch se ejecuta como árbol de sistema independiente bajo `systemd-nspawn` y utiliza el mismo kernel del host. Proporciona:

- GCC y Clang recientes.
- Rust.
- Python.
- Node.js.
- Herramientas web.
- Futuras herramientas Android y de IA.

Arch no escribe en la raíz Debian y `pacman` nunca administra los archivos del host.

### MO Core

La capa propia comienza con:

- Comando `mo`.
- Identidad de versión.
- Políticas de separación.
- Construcción reproducible.
- Diagnóstico.
- Preparación del dominio Arch.

## 3. Regla de integración

```text
Un producto visible
Dos dominios de paquetes
Una política de control
```

MO OS no mezcla las bases de datos de `apt` y `pacman`. Los proyectos se compartirán mediante rutas autorizadas, no compartiendo `/usr` ni `/lib`.

## 4. Decisión sobre Bedrock

Bedrock Linux no forma parte de Alpha 0.1. Podrá evaluarse en un laboratorio independiente, pero no será una dependencia del arranque hasta demostrar actualización, recuperación, escritorio y compatibilidad de hardware.

## 5. Fases

### Alpha 0.1 — Terminal Foundation

ISO live, comandos MO, red, diagnóstico y dominio Arch inicial.

### Alpha 0.2 — Installer Lab

Instalación exclusivamente en discos virtuales, cifrado, bootloader, snapshots y rollback.

### Alpha 0.3 — Developer Workstation

Escritorio, Firefox, VS Code, GitHub CLI, toolchains y proyectos compartidos.

### Alpha 0.4 — Hardware Candidate

Pruebas de Wi-Fi, audio, GPU, suspensión, batería, cámara y recuperación USB.

### Alpha 1.0 — Laptop Release

Solo después de superar la matriz de hardware y recuperación se permitirá reemplazar Windows.
