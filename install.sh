#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Copyclipzer"
APP_BUNDLE="$APP_NAME.app"
DESTINATION="/Applications/$APP_BUNDLE"

./build.sh

# Remplacer un bundle pendant qu'il tourne laisse un processus dont le code a été
# effacé sous ses pieds. On arrête d'abord, et on ne relance pas : c'est à
# l'utilisateur de rouvrir. L'autorisation Accessibilité, elle, survit au
# remplacement depuis que la signature est stable (mesuré le 2026-09-28, voir
# docs/CERTIFICAT-LOCAL.md).
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
	echo "→ $APP_NAME tourne, arrêt avant remplacement..."
	pkill -x "$APP_NAME" || true
	sleep 1
fi

echo "→ Installation dans /Applications..."
rm -rf "$DESTINATION"
cp -R "$APP_BUNDLE" "$DESTINATION"

echo
echo "✓ $DESTINATION installé"
echo "  Lancer : open \"$DESTINATION\""
echo
echo "  L'autorisation Accessibilité survit au remplacement : la signature est"
echo "  stable et l'exigence désignée ne dépend pas du binaire. Si le geste Cmd"
echo "  ne répond plus, la réparation est dans docs/CERTIFICAT-LOCAL.md : purger"
echo "  avec tccutil reset Accessibility io.github.copyclipzer, puis cocher"
echo "  /Applications/Copyclipzer.app. Ne jamais cocher le bundle du projet."
