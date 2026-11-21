#!/bin/bash
# Publica una versión nueva de Roro Touch en la página de descargas:
#   https://tecnopatard.github.io/roro-touch-descargas/
# Arma el instalador desde main de Roro Touch, revisa que sea la app del estudio (firmada y para chip Apple)
# y lo sube como versión nueva de GitHub (Releases). El botón de la página siempre baja la última.
#
# Uso:  publicar.sh [--sin-armar] ["Qué cambió"]
#   --sin-armar   sube el .dmg que ya está en dist/ sin volver a compilar.
# Opcional: RORO_REPO (repo del código, ~/Proyectos/Rotouch AI) y REPO_DESCARGAS (tecnopatard/roro-touch-descargas).
set -euo pipefail
RORO_REPO="${RORO_REPO:-$HOME/Proyectos/Rotouch AI}"
REPO_DESCARGAS="${REPO_DESCARGAS:-tecnopatard/roro-touch-descargas}"
APP_ID_ESPERADO="com.leskyestudio.rorotouch"
FIRMA_ESPERADA="Lesky Estudio"
DMG="$RORO_REPO/dist/Roro Touch Instalador.dmg"
NOMBRE_DESCARGA="Roro-Touch-Instalador.dmg"   # el botón de la página apunta a este nombre

ARMAR=1
if [ "${1:-}" = "--sin-armar" ]; then ARMAR=0; shift; fi
NOTAS="${1:-}"

falla() { echo "ERROR: $*" >&2; exit 1; }

command -v gh >/dev/null || falla "falta gh (GitHub CLI)."
gh auth status >/dev/null 2>&1 || falla "gh no tiene sesión iniciada. Corre: gh auth login"
[ -d "$RORO_REPO/.git" ] || falla "no encontré el repo de Roro Touch en $RORO_REPO"

RAMA="$(git -C "$RORO_REPO" rev-parse --abbrev-ref HEAD)"
COMMIT="$(git -C "$RORO_REPO" rev-parse --short HEAD)"

if [ "$ARMAR" = 1 ]; then
  [ "$RAMA" = "main" ] || falla "Roro Touch está en la rama «$RAMA». Publica solo desde main."
  git -C "$RORO_REPO" diff --quiet HEAD -- . ':!.claude' || falla "Roro Touch tiene cambios sin guardar en main."
  echo "Armando el instalador desde main ($COMMIT)…"
  "$RORO_REPO/scripts/crear-instalador.sh"
fi
[ -f "$DMG" ] || falla "no existe $DMG"

echo "Revisando el instalador…"
MONTAJE="$(mktemp -d)"
TMP="$(mktemp -d)"
limpiar() { hdiutil detach "$MONTAJE" -quiet 2>/dev/null || true; rm -rf "$TMP"; rmdir "$MONTAJE" 2>/dev/null || true; }
trap limpiar EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$MONTAJE" "$DMG" >/dev/null
APP="$MONTAJE/Roro Touch.app"
[ -d "$APP" ] || falla "el .dmg no tiene «Roro Touch.app»."
PLIST="$APP/Contents/Info.plist"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
[ "$APP_ID" = "$APP_ID_ESPERADO" ] || falla "es una app de prueba ($APP_ID), no $APP_ID_ESPERADO."
[[ " $(lipo -archs "$APP/Contents/MacOS/RoroTouch") " == *" arm64 "* ]] || falla "la app no es para chip Apple."
codesign --verify --deep --strict "$APP" || falla "la firma de la app no es válida."
FIRMA_INFO="$(codesign -dvv "$APP" 2>&1)"
[[ "$FIRMA_INFO" == *"Authority=$FIRMA_ESPERADA"* ]] \
  || falla "la app no está firmada con «$FIRMA_ESPERADA» (¿firma ad-hoc?). El Llavero volvería a preguntar en cada Mac."
MODELOS="$(ls "$APP/Contents/Resources/Modelos" 2>/dev/null | wc -l | tr -d ' ')"
[ "$MODELOS" -gt 0 ] || echo "AVISO: el instalador no trae modelos de IA." >&2
hdiutil detach "$MONTAJE" -quiet

TAG="v$VERSION-$BUILD"
TITULO="Roro Touch $VERSION ($BUILD)"
if gh release view "$TAG" --repo "$REPO_DESCARGAS" >/dev/null 2>&1; then
  falla "la versión $TAG ya está publicada. Haz un commit nuevo en main (sube el número) y vuelve a correr."
fi

cp "$DMG" "$TMP/$NOMBRE_DESCARGA"
SHA="$(shasum -a 256 "$TMP/$NOMBRE_DESCARGA" | cut -d' ' -f1)"
TAMANO="$(du -h "$TMP/$NOMBRE_DESCARGA" | cut -f1 | tr -d " ")"
ARMADO="$(date -r "$DMG" '+%Y-%m-%d %H:%M')"
{
  [ -n "$NOTAS" ] && printf '%s\n\n' "$NOTAS"
  echo "- Versión $VERSION, compilación $BUILD ($APP_ID)."
  [ "$ARMAR" = 1 ] && echo "- Armada desde main $COMMIT." || echo "- Instalador armado el $ARMADO (repo en $RAMA $COMMIT al publicar)."
  echo "- Firmada con «$FIRMA_ESPERADA». Solo Mac con chip Apple, macOS 14 o más nuevo."
  echo "- Modelos de IA dentro: $MODELOS."
  echo "- SHA-256: \`$SHA\`"
  echo
  echo "Cómo instalar: https://tecnopatard.github.io/roro-touch-descargas/"
} > "$TMP/notas.md"

echo "Publicando $TITULO ($TAMANO) en $REPO_DESCARGAS…"
gh release create "$TAG" "$TMP/$NOMBRE_DESCARGA" --repo "$REPO_DESCARGAS" \
  --title "$TITULO" --notes-file "$TMP/notas.md" --latest
echo "Listo: https://tecnopatard.github.io/roro-touch-descargas/"
