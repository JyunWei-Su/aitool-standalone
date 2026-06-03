#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib-license.sh
source "$(dirname "$0")/lib-license.sh"

echo "========================================"
echo " Building: npx wrapper"
echo "========================================"

rm -rf build dist
mkdir -p build dist

cat > build/npx << 'WRAPPER'
#!/bin/bash
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# When bundled: npx lives in lib/npx/, tools live in ../../bin/
if [ -d "$SELF_DIR/../../bin" ]; then
  AITOOL_DIR="$(cd "$SELF_DIR/../../bin" && pwd)"
else
  AITOOL_DIR="$SELF_DIR"
fi
args=()
for arg in "$@"; do
  case "$arg" in
    --no-install|--yes|-y|--) ;;
    *) args+=("$arg") ;;
  esac
done
tool="${args[0]:-}"
if [ -z "$tool" ]; then
  echo "npx: no package specified" >&2
  exit 1
fi
if [ ! -x "$AITOOL_DIR/$tool" ]; then
  echo "npx: '$tool' not found in $AITOOL_DIR" >&2
  exit 1
fi
exec "$AITOOL_DIR/$tool" "${args[@]:1}"
WRAPPER
chmod +x build/npx

tar czf "dist/npx-standalone-x86_64-linux.tar.gz" -C build npx
sha256sum dist/*.tar.gz > dist/SHA256SUMS
printf 'name=npx\nversion=local\nlicense=MIT\n' > dist/BUILD_INFO.txt

echo "=== Done ==="
ls -lh dist/
