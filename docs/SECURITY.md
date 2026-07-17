# Seguridad de MO OS

## Principio

MO OS se diseña suponiendo que aplicaciones, paquetes o código de proyectos pueden ser hostiles. La seguridad no depende de ocultar nombres o rutas.

## Límites iniciales

- Ningún servicio de red entrante se habilita por defecto.
- SSH servidor no se instala en Alpha 0.1.
- El dominio Arch no administra el kernel ni el arranque.
- `apt` y `pacman` nunca escriben en la misma raíz.
- La creación del dominio Arch usa un archivo oficial fijado por versión y SHA-256.
- El instalador de disco permanece deshabilitado.
- No se almacenan claves, contraseñas ni tokens en Git.

## Modelo de privilegios

```text
Usuario normal
├── puede programar
├── puede administrar sus proyectos
└── solicita operaciones del sistema

MO Core privilegiado
├── valida la operación
├── registra el cambio
├── exige confirmación cuando hay riesgo
└── ejecuta una acción limitada
```

El objetivo futuro es incorporar Secure Boot, cifrado LUKS2, AppArmor, actualizaciones firmadas, raíz inmutable y recuperación externa.

## Regla de instalación

Mientras el instalador no supere pruebas automatizadas sobre discos virtuales, `mo install` debe negarse a particionar cualquier dispositivo.
