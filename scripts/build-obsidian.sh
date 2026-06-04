#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib-license.sh
source "$(dirname "$0")/lib-license.sh"

VERSION=$(curl -sL \
  ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
  "https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest" \
  | jq -r .tag_name)

if [ "$VERSION" = "null" ] || [ -z "$VERSION" ]; then
  echo "ERROR: Could not resolve latest Obsidian version"
  exit 1
fi

VERSION_NUM="${VERSION#v}"

echo "========================================"
echo " Obsidian Standalone Builder"
echo " Version: ${VERSION}"
echo "========================================"

mkdir -p build dist

ASSET="Obsidian-${VERSION_NUM}.AppImage"
URL="https://github.com/obsidianmd/obsidian-releases/releases/download/${VERSION}/${ASSET}"
echo "Downloading ${URL}..."
wget -q "$URL" -O build/obsidian
chmod +x build/obsidian

echo "Packaging..."
tar czf "dist/obsidian-standalone-${VERSION}-x86_64-linux.tar.gz" -C build obsidian

LICENSE=$(gh_license "obsidianmd/obsidian-releases")
printf 'name=obsidian\nversion=%s\nlicense=%s\n' "${VERSION}" "${LICENSE}" > dist/BUILD_INFO.txt

echo "=== Done: obsidian ${VERSION} ==="
ls -lh dist/
