#!/usr/bin/env bash
# Prépare une version publiable : numéro dans Info.plist, build signé, archive, notes de
# version, appcast signé EdDSA. Ne publie RIEN : la release GitHub se crée à la main, avec
# la commande affichée à la fin, une fois le changement de version fusionné sur main.
#
#   ./publier-version.sh 1.1.0
#
# Ce que lit l'app installée : SUFeedURL (Info.plist) pointe vers
#   https://github.com/charlesDabard/copyclipzer/releases/latest/download/appcast.xml
# donc l'appcast DOIT être attaché à la release, à côté du zip. Une release sans appcast
# rend toutes les mises à jour invisibles, puisque « latest » n'en porte plus.
#
# La clé privée EdDSA vit dans le trousseau de session, compte « copyclipzer » (créée le
# 2026-11-08 par `generate_keys --account copyclipzer`). Sans elle, plus aucune mise à jour
# ne peut être signée : en garder une copie hors du Mac (`generate_keys --account
# copyclipzer -x fichier`, à ranger dans un coffre, jamais dans le dépôt).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "usage : ./publier-version.sh X.Y.Z" >&2
	exit 2
fi

PLIST="Resources/Info.plist"
BIN=".build/artifacts/sparkle/Sparkle/bin"
DEPOT="charlesDabard/copyclipzer"
TAG="v$VERSION"
DIST="dist/$TAG"
ARCHIVE="Copyclipzer-$VERSION.zip"

if [ -n "$(git status --porcelain)" ]; then
	echo "! arbre de travail modifié : commiter ou ranger avant de préparer une version" >&2
	exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
	echo "! le tag $TAG existe déjà" >&2
	exit 1
fi

# Sparkle compare `sparkle:version` à CFBundleVersion, PAS au numéro affiché : il doit
# grandir à chaque version. Un entier, incrémenté ici, jamais saisi à la main.
ANCIEN_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NOUVEAU_BUILD=$((ANCIEN_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NOUVEAU_BUILD" "$PLIST"
echo "→ version $VERSION (build $ANCIEN_BUILD → $NOUVEAU_BUILD)"

./build.sh

# Une release signée en ad-hoc changerait d'empreinte à chaque build : l'Accessibilité de
# chaque utilisateur sauterait à chaque mise à jour. Seul le certificat stable la garde.
# La sortie est lue d'abord, puis cherchée : `codesign | grep -q` sous `pipefail` refusait
# une app bien signée, grep -q quittant tôt et codesign mourant de SIGPIPE (2026-11-08).
SIGNATURE=$(codesign -dv --verbose=2 Copyclipzer.app 2>&1 || true)
if ! grep -q "Authority=Copyclipzer Local" <<<"$SIGNATURE"; then
	echo "! Copyclipzer.app n'est pas signée par « Copyclipzer Local » : release refusée" >&2
	echo "  recréer le certificat avec docs/CERTIFICAT-LOCAL.md" >&2
	exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST"
ditto -c -k --sequesterRsrc --keepParent Copyclipzer.app "$DIST/$ARCHIVE"

# Les notes de version : les sujets de commit depuis la version précédente, sans les
# fusions. generate_appcast les prend dans le .html qui porte le nom de l'archive.
PRECEDENT=$(git describe --tags --abbrev=0 2>/dev/null || true)
{
	echo "<h2>Copyclipzer $VERSION</h2>"
	echo "<ul>"
	git log --no-merges --format='%s' ${PRECEDENT:+"$PRECEDENT"..HEAD} |
		grep -vE '^chore\(release\)' |
		sed -E 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/^(.*)$/<li>\1<\/li>/'
	echo "</ul>"
} >"$DIST/${ARCHIVE%.zip}.html"

"$BIN/generate_appcast" \
	--account copyclipzer \
	--download-url-prefix "https://github.com/$DEPOT/releases/download/$TAG/" \
	--embed-release-notes \
	--link "https://github.com/$DEPOT" \
	--maximum-deltas 0 \
	-o "$DIST/appcast.xml" \
	"$DIST"

grep -q 'sparkle:edSignature=' "$DIST/appcast.xml" || {
	echo "! l'appcast ne porte aucune signature EdDSA" >&2
	exit 1
}

echo
echo "✓ $DIST prêt : $ARCHIVE, appcast.xml signé, notes de version"
echo
echo "  Reste, dans l'ordre :"
echo "  1. commiter $PLIST (chore(release): version $VERSION), PR, fusion sur main"
echo "  2. publier, depuis main à jour :"
echo "     gh release create $TAG --repo $DEPOT --target main --title \"Copyclipzer $VERSION\" \\"
echo "       --notes-file \"$DIST/${ARCHIVE%.zip}.html\" \"$DIST/$ARCHIVE\" \"$DIST/appcast.xml\""
