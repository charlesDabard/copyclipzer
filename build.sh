#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Copyclipzer"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "→ Compilation en release..."
swift build -c release

echo "→ Nettoyage du bundle précédent..."
rm -rf "$APP_BUNDLE"

echo "→ Montage du bundle .app..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp Resources/Info.plist "$CONTENTS/Info.plist"

# Les traductions (Localizable.strings fr/en) sont compilées par SwiftPM dans un bundle
# SÉPARÉ, pas dans le binaire. L'accesseur `Bundle.module` généré par SwiftPM le cherche
# à côté de l'app et dans Contents/Resources, et fait un fatalError s'il ne le trouve
# pas : sans cette copie, l'application empaquetée plante au premier appel de
# NSLocalizedString. Le nom vient du paquet et de la cible (voir Localisation.swift).
cp -R "$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle" "$RESOURCES_DIR/"

echo "→ Signature ad-hoc..."
# Identite STABLE, et non plus ad-hoc. Une signature ad-hoc change d'empreinte a
# chaque construction, et macOS invalide alors l'autorisation Accessibilite SANS
# decocher la case : il fallait retirer puis rajouter l'app apres chaque build.
# Avec ce certificat local, l'exigence designee devient
#   identifier "io.github.copyclipzer" and certificate leaf = H"..."
# qui ne cite aucune empreinte de binaire, donc l'autorisation survit aux builds.
# Le certificat se recree avec docs/CERTIFICAT-LOCAL.md s'il disparait du trousseau.
IDENTITE="Copyclipzer Local"
if security find-identity 2>/dev/null | grep -q "$IDENTITE"; then
	codesign --force --deep --sign "$IDENTITE" "$APP_BUNDLE"
else
	echo "  ! certificat \"$IDENTITE\" absent du trousseau, repli en ad-hoc"
	echo "  ! l'autorisation Accessibilite devra etre refaite apres CHAQUE build"
	codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo
echo "✓ $APP_BUNDLE construit"
echo "  Lancer   : open $APP_BUNDLE"
echo "  Installer: ./install.sh"
echo
echo "  Après CHAQUE reconstruction, l'empreinte de la signature ad-hoc change, et"
echo "  macOS cesse d'honorer l'autorisation Accessibilité sans décocher la case."
echo "  Réglages Système > Confidentialité et sécurité > Accessibilité : retirer"
echo "  Copyclipzer avec le bouton moins, puis le rajouter."
