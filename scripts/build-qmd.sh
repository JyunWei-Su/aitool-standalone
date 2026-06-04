#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib-license.sh
source "$(dirname "$0")/lib-license.sh"

NODEJS_VERSION="${NODEJS_VERSION:-$(curl -sL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)] | first | .version' | tr -d 'v')}"
QMD_VERSION="${QMD_VERSION:-latest}"

echo "========================================"
echo " qmd Standalone Builder"
echo " Node.js: ${NODEJS_VERSION}"
echo " qmd:     ${QMD_VERSION}"
echo "========================================"

if [ -f /opt/rh/gcc-toolset-12/enable ]; then
  source /opt/rh/gcc-toolset-12/enable
fi

export PATH="$PWD/build/.node/bin:${PATH:-}"
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

PKG_SPEC="@tobilu/qmd"
if [ "$QMD_VERSION" != "latest" ] && [ -n "$QMD_VERSION" ]; then
  PKG_SPEC="@tobilu/qmd@${QMD_VERSION}"
fi
echo "Installing ${PKG_SPEC}..."
# Force native modules (better-sqlite3, tree-sitter-*) to compile from source
# against the local glibc 2.28, instead of fetching a prebuilt binary that
# needs 2.29.
export npm_config_build_from_source=true
# node-gyp's bundled gyp uses the walrus operator (:=), which needs Python
# >= 3.8. Oracle Linux 8's default python3 is 3.6.8, so point node-gyp at
# python3.11 (installed in the build container) instead.
export PYTHON=/usr/bin/python3.11
export npm_config_python=/usr/bin/python3.11
./.node/bin/npm install "$PKG_SPEC"

# Dynamically extract model default URIs from the installed llm.js
echo "Extracting model defaults from llm.js..."
cat > /tmp/extract_models.js << 'JSEOF'
const src = require('fs').readFileSync(
  './node_modules/@tobilu/qmd/dist/llm.js', 'utf8');
function extract(name) {
  const idx = src.indexOf(name);
  if (idx === -1) return '';
  const segment = src.slice(idx, idx + 300);
  const m = segment.match(/hf:[^\s"'`]+/);
  return m ? m[0] : '';
}
console.log(extract('QMD_EMBED_MODEL'));
console.log(extract('QMD_GENERATE_MODEL'));
console.log(extract('QMD_RERANK_MODEL'));
JSEOF

MODEL_LINES=$(./.node/bin/node /tmp/extract_models.js)
EMBED_URI=$(echo "$MODEL_LINES"   | sed -n '1p')
GENERATE_URI=$(echo "$MODEL_LINES" | sed -n '2p')
RERANK_URI=$(echo "$MODEL_LINES"  | sed -n '3p')

echo "  EMBED:    ${EMBED_URI}"
echo "  GENERATE: ${GENERATE_URI}"
echo "  RERANK:   ${RERANK_URI}"

# Download GGUF models via huggingface_hub (handles XET storage correctly)
# HF_HUB_DISABLE_XET=1 forces standard CDN path, bypassing cas-bridge.xethub.hf.co
/usr/bin/python3.11 -m ensurepip --upgrade 2>/dev/null || true
/usr/bin/python3.11 -m pip install -q huggingface_hub
export HF_HUB_DISABLE_XET=1
mkdir -p models

cat > /tmp/hf_download.py << 'PYEOF'
import sys
from huggingface_hub import hf_hub_download
parts = sys.argv[1].split('/', 2)   # user/repo/filename
repo_id  = parts[0] + '/' + parts[1]
filename = parts[2]
print(f"  {repo_id} / {filename}")
hf_hub_download(repo_id, filename, local_dir='models')
PYEOF

for uri in "${EMBED_URI}" "${GENERATE_URI}" "${RERANK_URI}"; do
  if [ -z "$uri" ]; then
    echo "WARNING: empty model URI, skipping download"
    continue
  fi
  filename="${uri##*/}"
  if [ ! -f "models/${filename}" ]; then
    echo "Downloading ${filename}..."
    /usr/bin/python3.11 /tmp/hf_download.py "${uri#hf:}"
  else
    echo "Already cached: ${filename}"
  fi
done

EMBED_FILENAME="${EMBED_URI##*/}"
GENERATE_FILENAME="${GENERATE_URI##*/}"
RERANK_FILENAME="${RERANK_URI##*/}"

cat > qmd << WRAPPER
#!/bin/bash
set -eu
SOURCE="\$0"
while [ -L "\$SOURCE" ]; do
  DIR="\$(cd -- "\$(dirname "\$SOURCE")" >/dev/null 2>&1; pwd -P)"
  SOURCE="\$(readlink "\$SOURCE")"
  case "\$SOURCE" in
    /*) ;;
    *) SOURCE="\$DIR/\$SOURCE" ;;
  esac
done
SCRIPT_PATH="\$(cd -- "\$(dirname "\$SOURCE")" >/dev/null 2>&1; pwd -P)"
export PATH="\$SCRIPT_PATH/.node/bin:\$PATH"
export QMD_EMBED_MODEL="\${QMD_EMBED_MODEL:-\$SCRIPT_PATH/models/${EMBED_FILENAME}}"
export QMD_GENERATE_MODEL="\${QMD_GENERATE_MODEL:-\$SCRIPT_PATH/models/${GENERATE_FILENAME}}"
export QMD_RERANK_MODEL="\${QMD_RERANK_MODEL:-\$SCRIPT_PATH/models/${RERANK_FILENAME}}"
exec "\$SCRIPT_PATH/node_modules/.bin/qmd" "\$@"
WRAPPER
chmod +x qmd
mkdir -p bin
ln -s ../qmd bin/qmd

popd

VERSION_TAG=$( build/.node/bin/node \
  -e "console.log(require('./build/node_modules/@tobilu/qmd/package.json').version)" )

echo "Bundling qmd-standalone-${VERSION_TAG}..."
rm -rf dist && mkdir dist
pushd build
tar czf "../dist/qmd-standalone-${VERSION_TAG}-x86_64-linux.tar.gz" .
popd
sha256sum dist/*.tar.gz > dist/SHA256SUMS
QMD_REPO=$(curl -sL "https://registry.npmjs.org/@tobilu/qmd/${VERSION_TAG}" \
  | jq -r '.repository.url // ""' \
  | sed 's|.*github\.com/||;s|\.git$||')
if [ -n "$QMD_REPO" ] && [ "$QMD_REPO" != "null" ]; then
  QMD_LICENSE=$(gh_license "$QMD_REPO")
else
  QMD_LICENSE=$( build/.node/bin/node \
    -e "console.log(require('./build/node_modules/@tobilu/qmd/package.json').license || 'Unknown')" )
fi
printf 'name=qmd\nversion=%s\nlicense=%s\n' "${VERSION_TAG}" "${QMD_LICENSE}" > dist/BUILD_INFO.txt

echo "=== Done ==="
ls -lh dist/
cat dist/SHA256SUMS
