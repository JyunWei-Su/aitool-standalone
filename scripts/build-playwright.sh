#!/bin/bash
set -euo pipefail

NODEJS_VERSION="${NODEJS_VERSION:-$(curl -sL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)] | first | .version' | tr -d 'v')}"
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-$(curl -sL https://registry.npmjs.org/@playwright/test/latest | jq -r '.version')}"
BROWSERS="${BROWSERS:-chromium firefox}"

echo "========================================"
echo " Playwright Standalone Builder"
echo " Node.js:    ${NODEJS_VERSION}"
echo " Playwright: ${PLAYWRIGHT_VERSION}"
echo " Browsers:   ${BROWSERS}"
echo "========================================"

export PATH="$PWD/build/.node/bin:/usr/bin"
mkdir -p tmp

NODEJS_URL="https://nodejs.org/dist/v${NODEJS_VERSION}/node-v${NODEJS_VERSION}-linux-x64.tar.xz"
NODEJS_ARCHIVE="tmp/node-v${NODEJS_VERSION}-linux-x64.tar.xz"
if [ ! -f "$NODEJS_ARCHIVE" ]; then
  echo "Downloading Node.js from ${NODEJS_URL}..."
  wget -qO "$NODEJS_ARCHIVE" "$NODEJS_URL"
fi

echo "Extracting Node.js..."
rm -rf build
mkdir -p build/.node
tar xf "$NODEJS_ARCHIVE" -C build/.node --strip-components 1

pushd build

echo "Installing @playwright/test@${PLAYWRIGHT_VERSION}..."
./.node/bin/npm install "@playwright/test@${PLAYWRIGHT_VERSION}"

echo "Installing browsers (with system deps): ${BROWSERS}..."
export PLAYWRIGHT_BROWSERS_PATH=0
./.node/bin/npx playwright install --with-deps ${BROWSERS}

cat > playwright << 'WRAPPER'
#!/bin/bash
set -eu
SCRIPT_PATH="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
export PATH="$SCRIPT_PATH/.node/bin:$PATH"
export PLAYWRIGHT_BROWSERS_PATH="$SCRIPT_PATH/node_modules/playwright-core/.local-browsers"
exec npx playwright "$@"
WRAPPER
chmod +x playwright

popd

echo "Bundling..."
rm -rf dist && mkdir dist
pushd build
tar czf "../dist/playwright-standalone-${PLAYWRIGHT_VERSION}-x86_64-linux.tar.gz" .
popd
sha256sum dist/*.tar.gz > dist/SHA256SUMS
printf 'name=playwright\nversion=%s\n' "${PLAYWRIGHT_VERSION}" > dist/BUILD_INFO.txt

echo "=== Done ==="
ls -lh dist/
cat dist/SHA256SUMS
