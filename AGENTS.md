# Entorno de ejecución: Hermes en Termux

La referencia modular ampliada está en `~/.codex/termux-context/README.md` globalmente y en `.codex/termux-context/README.md` dentro de Hermes. Consultar el módulo pertinente cuando una tarea lo requiera.

## Plataforma

- Ejecutar suponiendo Termux sobre Android, no una distribución GNU/Linux de escritorio.
- Arquitectura observada: `aarch64` / ABI principal `arm64-v8a`.
- Kernel observado: Linux `4.19.113-27223811`, con configuración Android.
- Rutas Android relevantes: `ANDROID_ROOT=/system`, `ANDROID_DATA=/data`.
- Prefijo de Termux observado: `/data/data/com.termux/files/usr`.
- La compatibilidad de syscalls, permisos, namespaces, almacenamiento compartido y APIs puede diferir de Linux convencional.

## Herramientas y comandos

- Shell disponible: `/data/data/com.termux/files/usr/bin/sh`; Bash también está instalado.
- No asumir que existen herramientas opcionales: `rg`, `node`, npm, Docker, systemd, sudo o una jerarquía FHS completa pueden faltar.
- Preferir `find`, `grep`, `sed`, `awk`, `command -v` y scripts ya presentes cuando una herramienta no esté disponible.
- Detectar arquitectura, rutas y binarios antes de escoger comandos o instalar dependencias.
- Evitar comandos que dependan de systemd, servicios privilegiados, GUI de escritorio o capacidades de root.

## Seguridad y cambios

- Respetar el sandbox y los permisos de Android; no asumir acceso root por estar bajo `/data`.
- No escribir fuera del workspace sin autorización explícita y sin confirmar el destino exacto.
- No borrar de forma recursiva rutas amplias; preferir cambios reversibles y acotados.
- No exponer tokens, `auth.json`, bases SQLite, historiales ni variables sensibles al inspeccionar configuración.

## Verificación

- Tras cambios de código, usar las pruebas y comandos disponibles en el proyecto.
- Si falta una dependencia, informar exactamente qué falta y distinguir una limitación de Termux de un fallo del proyecto.
- Para paquetes nativos, considerar ABI `arm64-v8a`, toolchains de Android y disponibilidad real en repositorios de Termux.
