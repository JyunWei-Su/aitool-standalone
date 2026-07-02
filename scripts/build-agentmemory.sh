#!/bin/bash
set -euo pipefail

if [ -f /etc/oracle-release ] && grep -q 'release 7' /etc/oracle-release; then
  echo "========================================"
  echo " Setting up CentOS 7 build toolchain"
  echo "========================================"
  cat > /etc/yum.repos.d/ol7-extra.repo << 'REPOEOF'
[ol7_optional_latest]
name=Oracle Linux 7 Optional Latest
baseurl=https://yum.oracle.com/repo/OracleLinux/OL7/optional/latest/x86_64/
gpgcheck=1
gpgkey=https://yum.oracle.com/RPM-GPG-KEY-oracle-ol7
enabled=1

[ol7_software_collections]
name=Oracle Linux 7 Software Collections
baseurl=https://yum.oracle.com/repo/OracleLinux/OL7/SoftwareCollections/x86_64/
gpgcheck=1
gpgkey=https://yum.oracle.com/RPM-GPG-KEY-oracle-ol7
enabled=1

[ol7_developer_EPEL]
name=Oracle Linux 7 Development Packages (EPEL)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL7/developer_EPEL/x86_64/
gpgcheck=1
gpgkey=https://yum.oracle.com/RPM-GPG-KEY-oracle-ol7
enabled=1
REPOEOF
  yum install -y git wget curl tar xz jq findutils which \
    devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-make
  rpm -q devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-make
fi

# shellcheck source=scripts/lib-license.sh
source "$(dirname "$0")/lib-license.sh"

NODEJS_VERSION="${NODEJS_VERSION:-$(curl -sL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)] | first | .version' | tr -d 'v')}"
NODEJS_TARGET="${NODEJS_TARGET:-linux-x64-glibc-217}"
AGENTMEMORY_VERSION="${AGENTMEMORY_VERSION:-$(curl -sL https://registry.npmjs.org/@agentmemory/agentmemory/latest | jq -r '.version')}"
III_VERSION="${AGENTMEMORY_III_VERSION:-0.11.2}"
EMBEDDING_MODEL="${AGENTMEMORY_EMBEDDING_MODEL:-Xenova/all-MiniLM-L6-v2}"

echo "========================================"
echo " agentmemory Standalone Builder"
echo " Node.js:      ${NODEJS_VERSION}"
echo " Node target:  ${NODEJS_TARGET}"
echo " agentmemory:  ${AGENTMEMORY_VERSION}"
echo " iii-engine:   ${III_VERSION}"
echo " embedding:    ${EMBEDDING_MODEL}"
echo "========================================"

mkdir -p tmp

case "$NODEJS_TARGET" in
  linux-x64)
    NODEJS_BASE_URL="https://nodejs.org/dist"
    ;;
  linux-x64-glibc-217)
    NODEJS_BASE_URL="https://unofficial-builds.nodejs.org/download/release"
    ;;
  *)
    echo "ERROR: unsupported NODEJS_TARGET '${NODEJS_TARGET}'" >&2
    exit 1
    ;;
esac

NODEJS_URL="${NODEJS_BASE_URL}/v${NODEJS_VERSION}/node-v${NODEJS_VERSION}-${NODEJS_TARGET}.tar.xz"
NODEJS_ARCHIVE="tmp/node-v${NODEJS_VERSION}-${NODEJS_TARGET}.tar.xz"
if [ ! -f "$NODEJS_ARCHIVE" ]; then
  echo "Downloading Node.js from ${NODEJS_URL}..."
  wget -qO "$NODEJS_ARCHIVE" "$NODEJS_URL"
fi

III_URL="https://github.com/iii-hq/iii/releases/download/iii/v${III_VERSION}/iii-x86_64-unknown-linux-gnu.tar.gz"
III_ARCHIVE="tmp/iii-v${III_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
if [ ! -f "$III_ARCHIVE" ]; then
  echo "Downloading iii-engine from ${III_URL}..."
  wget -qO "$III_ARCHIVE" "$III_URL"
fi

echo "Extracting Node.js, agentmemory, iii-engine, and embedding cache..."
rm -rf build dist
mkdir -p build/.node build/.iii build/.hf build/lib dist
tar xf "$NODEJS_ARCHIVE" -C build/.node --strip-components 1
tar xf "$III_ARCHIVE" -C build/.iii

echo "Bundling C++ runtime libraries..."
for libname in libstdc++.so.6 libgcc_s.so.1; do
  libpath=""
  for libdir in \
    /opt/rh/devtoolset-11/root/usr/lib64 \
    /opt/rh/gcc-toolset-12/root/usr/lib64 \
    /usr/lib64; do
    if [ -f "${libdir}/${libname}" ]; then
      libpath="${libdir}/${libname}"
      break
    fi
  done
  if [ -n "$libpath" ]; then
    cp -L "$libpath" "build/lib/${libname}"
    echo "  bundled ${libname} from ${libpath}"
  else
    echo "WARNING: ${libname} not found; relying on target system runtime"
  fi
done

pushd build

# npm is a shell script with a /usr/bin/env node shebang, so the bundled
# Node.js must be on PATH before we invoke it.
export PATH="$PWD/.node/bin:$PATH"
export LD_LIBRARY_PATH="$PWD/lib:${LD_LIBRARY_PATH:-}"
./.node/bin/node -e "console.log('node runtime OK:', process.version)"

cat > package.json <<'PKG'
{
  "name": "agentmemory-standalone-build",
  "private": true,
  "overrides": {
    "iii-sdk": "0.11.2"
  }
}
PKG

echo "Installing @agentmemory/agentmemory@${AGENTMEMORY_VERSION}..."
# agentmemory depends on sharp, whose native linux-x64 payload is installed via
# optional dependencies/install scripts. Omitting either creates a bundle that
# installs but fails at runtime with a missing sharp-linux-x64.node.
./.node/bin/npm install "@agentmemory/agentmemory@${AGENTMEMORY_VERSION}" --include=optional --no-fund --no-audit --ignore-scripts=false
./.node/bin/node -e "require('sharp'); console.log('sharp native module OK')"

echo "Installing @xenova/transformers for local embeddings..."
./.node/bin/npm install "@xenova/transformers" --no-fund --no-audit --ignore-scripts

echo "Prewarming embedding model cache for ${EMBEDDING_MODEL}..."
export HF_HOME="$PWD/.hf"
export HF_HUB_CACHE="$PWD/.hf/hub"
export TRANSFORMERS_CACHE="$PWD/.hf/transformers"
export XDG_CACHE_HOME="$PWD/.hf/xdg"
cat > prewarm-embedding.mjs <<'JSEOF'
import { pipeline } from '@xenova/transformers';

(async () => {
  const extractor = await pipeline('feature-extraction', process.env.EMBEDDING_MODEL);
  await extractor(['bundle warmup'], { pooling: 'mean', normalize: true });
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
JSEOF
for attempt in 1 2 3 4 5; do
  if EMBEDDING_MODEL="$EMBEDDING_MODEL" ./.node/bin/node prewarm-embedding.mjs; then
    break
  fi
  if [ "$attempt" -eq 5 ]; then
    echo "ERROR: embedding model prewarm failed after ${attempt} attempts"
    exit 1
  fi
  sleep_seconds=$((attempt * 60))
  echo "Embedding model prewarm failed; retrying in ${sleep_seconds}s (${attempt}/5)..."
  sleep "$sleep_seconds"
done

cat > agentmemory << 'WRAPPER'
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
export PATH="$SCRIPT_PATH/.iii:$SCRIPT_PATH/.node/bin:$PATH"
export LD_LIBRARY_PATH="$SCRIPT_PATH/lib:${LD_LIBRARY_PATH:-}"
export NODE_PATH="$SCRIPT_PATH/node_modules"
export HF_HOME="$SCRIPT_PATH/.hf"
export HF_HUB_CACHE="$SCRIPT_PATH/.hf/hub"
export TRANSFORMERS_CACHE="$SCRIPT_PATH/.hf/transformers"
export XDG_CACHE_HOME="$SCRIPT_PATH/.hf/xdg"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export AGENTMEMORY_III_VERSION="${AGENTMEMORY_III_VERSION:-__III_VERSION__}"
exec "$SCRIPT_PATH/node_modules/.bin/agentmemory" "$@"
WRAPPER
chmod +x agentmemory
sed -i "s/__III_VERSION__/${III_VERSION}/g" agentmemory

mkdir -p bin
ln -s ../agentmemory bin/agentmemory

popd

echo "Bundling agentmemory-standalone-${AGENTMEMORY_VERSION}..."
tar czf "dist/agentmemory-standalone-${AGENTMEMORY_VERSION}-x86_64-linux.tar.gz" -C build .
sha256sum dist/*.tar.gz > dist/SHA256SUMS
AGENTMEMORY_LICENSE=$(gh_license "rohitg00/agentmemory")
printf 'name=agentmemory\nversion=%s\nlicense=%s\n' "${AGENTMEMORY_VERSION}" "${AGENTMEMORY_LICENSE}" > dist/BUILD_INFO.txt

echo "=== Done ==="
ls -lh dist/
cat dist/SHA256SUMS
