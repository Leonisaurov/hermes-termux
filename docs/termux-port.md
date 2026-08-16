# Hermes Agent — Port Termux / Android

Este port ejecuta Hermes Agent directamente en Termux (Android), sin
contenedores intermedios, usando el `python` y los paquetes nativos de
Termux. El binario standalone se compila con **Nuitka** en un entorno
Termux real (el mismo ABI `aarch64` que el dispositivo) y se distribuye
como GitHub Release.

## Arquitectura del port

| Pieza | Ruta | Rol |
|---|---|---|
| Setup on-device | `scripts/setup_termux.sh` | Instala paquetes `pkg`, crea el venv `--system-site-packages`, instala `.[termux]`, usa la `python-cryptography` nativa de Termux y opcionalmente compila con Nuitka (`--standalone`) |
| Constraints | `constraints-termux.txt` | Pins que mantienen estable el árbol de dependencias en Termux |
| Extra curado | `.[termux]` en `pyproject.toml` | Perfil de dependencias compatible con Android (el `[all]` completo arrastra voice deps incompatibles) |
| Política de rutas | `tools/termux_path_policy.py` | Defensa en profundidad: el agente solo puede tocar `$HOME` de Termux, nunca `/sdcard`, `$PREFIX` ni rutas del sistema |
| Build CI | `scripts/build-termux-standalone-ci.sh` | Corre dentro de un contenedor `termux/termux-docker`: `pkg update` → setup → Nuitka → verifica ELF aarch64 → empaqueta |
| Workflow | `.github/workflows/termux-release.yml` | Runner arm64 nativo, publica el binario como Release en tags `v*` |

## Decisiones clave (por qué está así)

- **Venv `--system-site-packages`**: Termux compila sus paquetes Python
  contra el loader de Android. Un wheel de PyPI (p. ej. `cryptography`
  abi3) puede instalarse en arm64 pero falla en import con `PyLong_Type`
  sin resolver. Por eso el venv reusa los paquetes nativos de Termux y
  `setup_termux.sh` elimina del venv la copia de `cryptography` que lo
  sombrearía.
- **Nuitka en contenedor Termux, no en Linux**: el binario standalone
  debe enlazar contra bionic (libc de Android). Compilar en un runner
  Linux normal produce un binario glibc inútil en el teléfono. El
  contenedor `termux/termux-docker` es Termux real: mismo `pkg`, mismo
  toolchain clang/rust, mismo ABI.
- **Runner arm64 nativo**: GitHub Actions ofrece `ubuntu-24.04-arm`, así
  que el contenedor arm64 corre sin QEMU ni proot — rápido y fiel.
  (El contenedor `termux/termux-docker:latest` es multiarch; en arm64
  Docker baja la variante nativa automáticamente.)

## Construir localmente (en el teléfono)

```bash
pkg install -y python git clang rust make pkg-config libffi openssl ca-certificates curl ripgrep ffmpeg termux-api
git clone <tu-repo> ~/hermes-termux
cd ~/hermes-termux
scripts/setup_termux.sh --standalone --no-tcr
# Resultado:
#   dist/hermes-termux/hermes-termux.dist/hermes-termux
```

Sin `--standalone` solo se prepara el entorno (venv + `hermes` en PATH).

> `--no-tcr` evita el wrapper de throttling térmico `tcr` (solo existe en
> algunos dispositivos con root/termux-services). En un teléfono normal
> puedes usar `tcr` si lo tienes instalado.

## Compilar en GitHub Actions (CI)

El workflow `.github/workflows/termux-release.yml`:

1. Corre en `ubuntu-24.04-arm` (aarch64 nativo).
2. Monta el checkout en `termux/termux-docker` y ejecuta
   `scripts/build-termux-standalone-ci.sh` dentro del contenedor.
3. Sube `dist/hermes-termux-aarch64.tar.gz` como artifact.
4. En un push de tag `v*` (o con el input `create_release` en un run
   manual) publica el tarball como GitHub Release.

### Disparar un build

```bash
# Manual (solo artifact):
gh workflow run termux-release.yml

# Manual + Release con tag ci-<run-id>:
gh workflow run termux-release.yml -f create_release=true

# Automático al pushear un tag de versión:
git tag v0.1.0 && git push origin v0.1.0
```

### Verificaciones que hace CI

- `pkg update` con reintentos (el contenedor limpia su caché apt).
- Build Nuitka `--standalone --follow-imports` con los paquetes
  `agent`, `hermes_cli`, `tools`, `providers`.
- Comprobación del campo `e_machine` del ELF: **183 = aarch64**, para
  detectar un toolchain mal resuelto antes de publicar.
- Smoke test `hermes-termux --version` dentro del mismo contenedor.

## Instalar el binario standalone en el teléfono

```bash
# Desde la GitHub Release (o el artifact de CI):
curl -fsSL -o hermes-termux-aarch64.tar.gz \
  <url-del-tarball-de-la-release>
tar -xzf hermes-termux-aarch64.tar.gz
cd hermes-termux.dist
./hermes-termux --help
```

El tarball contiene el árbol `hermes-termux.dist/` completo (binario +
extensiones + dependencias empaquetadas). Se puede mover a
`~/hermes-termux.dist` y crear un wrapper:

```bash
mkdir -p ~/bin
printf '#!/data/data/com.termux/files/usr/bin/bash\nexec ~/hermes-termux.dist/hermes-termux "$@"\n' > ~/bin/hermes
chmod +x ~/bin/hermes
```

## Limitaciones conocidas

- El port usa el extra `.[termux]` curado; extras pesados (voice, matrix,
  etc.) se instalan bajo demanda con `tools/lazy_deps.py` y pueden requerir
  compilación en el dispositivo.
- `termux-api` (y la app Termux:API en Android) es opcional pero
  recomendado para TTS/STT (`termux-tts-speak`, `termux-speech-to-text`).
- La política de rutas de `tools/termux_path_policy.py` no es un sandbox
  del SO: es defensa en profundidad dentro del terminal local.
