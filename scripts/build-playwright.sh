#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib-license.sh
source "$(dirname "$0")/lib-license.sh"

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

echo "Installing browsers: ${BROWSERS}..."
# NOTE: no --with-deps. Playwright's dependency installer only supports
# apt-based distros; on Oracle/RHEL it falls back to apt-get and fails.
# System libraries are installed on the RHEL target instead (see DEPS.txt
# written below). The browser binaries themselves are bundled here.
export PLAYWRIGHT_BROWSERS_PATH=0
./.node/bin/npx playwright install ${BROWSERS}

cat > playwright << 'WRAPPER'
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
export PATH="$SCRIPT_PATH/.node/bin:$PATH"
export PLAYWRIGHT_BROWSERS_PATH="$SCRIPT_PATH/node_modules/playwright-core/.local-browsers"
exec "$SCRIPT_PATH/node_modules/.bin/playwright" "$@"
WRAPPER
chmod +x playwright
mkdir -p bin
ln -s ../playwright bin/playwright

popd

echo "Writing RHEL dependency notes..."
cat > build/DEPS.txt << 'DEPS'
Playwright browsers need these system libraries on the RHEL 8.10 target.
Run once as root (or with sudo):

  dnf install -y \
    nss nspr atk at-spi2-atk at-spi2-core cups-libs libdrm \
    libxkbcommon libXcomposite libXdamage libXfixes libXrandr \
    mesa-libgbm pango cairo alsa-lib libXtst gtk3 dbus-glib

After that, ./bin/playwright works without any further setup.
DEPS

echo "Bundling..."
rm -rf dist && mkdir dist
pushd build
tar czf "../dist/playwright-standalone-${PLAYWRIGHT_VERSION}-x86_64-linux.tar.gz" .
popd
sha256sum dist/*.tar.gz > dist/SHA256SUMS
PLAYWRIGHT_LICENSE=$(gh_license "microsoft/playwright")
printf 'name=playwright\nversion=%s\nlicense=%s\n' "${PLAYWRIGHT_VERSION}" "${PLAYWRIGHT_LICENSE}" > dist/BUILD_INFO.txt

echo "=== Done ==="
ls -lh dist/
cat dist/SHA256SUMS
