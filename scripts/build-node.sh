#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib-license.sh
source "$(dirname "$0")/lib-license.sh"

NODEJS_VERSION="${NODEJS_VERSION:-$(curl -sL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)] | first | .version' | tr -d 'v')}"

echo "========================================"
echo " Node.js Standalone Builder"
echo " Node.js: ${NODEJS_VERSION}"
echo "========================================"

mkdir -p tmp

NODEJS_URL="https://nodejs.org/dist/v${NODEJS_VERSION}/node-v${NODEJS_VERSION}-linux-x64.tar.xz"
NODEJS_ARCHIVE="tmp/node-v${NODEJS_VERSION}-linux-x64.tar.xz"
if [ ! -f "$NODEJS_ARCHIVE" ]; then
  echo "Downloading Node.js from ${NODEJS_URL}..."
  wget -qO "$NODEJS_ARCHIVE" "$NODEJS_URL"
fi

echo "Extracting Node.js..."
rm -rf build dist
mkdir -p build/node-runtime dist
tar xf "$NODEJS_ARCHIVE" -C build/node-runtime --strip-components 1

cat > build/node << 'WRAPPER'
#!/bin/bash
set -eu
SOURCE="$0"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -- "$(dirname "$SOURCE")" >/dev/null 2>&1; pwd -P)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in
    /*) ;;
    *) SOURCE="$DIR/$SOURCE" ;;
  esac
done
SCRIPT_PATH="$(cd -- "$(dirname "$SOURCE")" >/dev/null 2>&1; pwd -P)"
exec "$SCRIPT_PATH/node-runtime/bin/node" "$@"
WRAPPER
chmod +x build/node

echo "Bundling node-standalone-${NODEJS_VERSION}..."
tar czf "dist/node-standalone-${NODEJS_VERSION}-x86_64-linux.tar.gz" -C build node node-runtime
NODE_LICENSE=$(gh_license "nodejs/node")
printf 'name=node\nversion=%s\nlicense=%s\n' "${NODEJS_VERSION}" "${NODE_LICENSE}" > dist/BUILD_INFO.txt

echo "=== Done ==="
ls -lh dist/