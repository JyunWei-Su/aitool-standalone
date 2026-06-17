#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib-license.sh
source "$(dirname "$0")/lib-license.sh"

NVIM_VERSION="${NVIM_VERSION:-$(curl -sL \
  ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
  "https://api.github.com/repos/neovim/neovim/releases/latest" | jq -r .tag_name)}"

echo "========================================"
echo " Neovim Standalone Builder"
echo " Version: ${NVIM_VERSION}"
echo "========================================"

# Extra build deps for Neovim's bundled third-party libs (libuv, luajit,
# tree-sitter, libvterm, unibilium, libtermkey, ...) not in the base image.
dnf install -y gettext libtool autoconf automake pkgconfig unzip patch

rm -rf build dist
mkdir -p dist

SRC_URL="https://github.com/neovim/neovim/archive/refs/tags/${NVIM_VERSION}.tar.gz"
echo "Downloading ${SRC_URL}..."
wget -qO source.tar.gz "$SRC_URL"
tar xzf source.tar.gz
SRC_DIR=$(find . -maxdepth 1 -type d -name "neovim-*" | head -1)
mv "$SRC_DIR" build
cd build

# Build from source against the build container's glibc 2.28, instead of
# using upstream's prebuilt nvim-linux-x86_64.tar.gz (built on a newer
# Ubuntu/glibc), which fails with "GLIBC_2.3x not found" on older systems.
echo "Building Neovim (this takes a while)..."
make CMAKE_BUILD_TYPE=RelWithDebInfo \
     CMAKE_INSTALL_PREFIX="$PWD/dist-install" \
     -j"$(nproc)"
make install

cd ..

echo "Packaging..."
mkdir -p build/pkg/bin build/pkg/share/nvim
cp build/dist-install/bin/nvim build/pkg/bin/nvim
cp -r build/dist-install/share/nvim/runtime build/pkg/share/nvim/runtime
for nvim_libdir in lib lib64; do
  if [ -d "build/dist-install/${nvim_libdir}/nvim" ]; then
    mkdir -p "build/pkg/${nvim_libdir}"
    cp -r "build/dist-install/${nvim_libdir}/nvim" "build/pkg/${nvim_libdir}/nvim"
  fi
done
mkdir -p build/pkg/share/nvim/runtime/parser
while IFS= read -r parser_dir; do
  cp -r "${parser_dir}/." build/pkg/share/nvim/runtime/parser/
done < <(find build/dist-install -path '*/nvim/parser' -type d)
if [ ! -f build/pkg/share/nvim/runtime/parser/lua.so ]; then
  echo "ERROR: bundled Lua treesitter parser not found under runtime/parser" >&2
  echo "Installed parser directories:" >&2
  find build/dist-install -path '*/nvim/parser' -type d -print >&2 || true
  exit 1
fi

# Top-level entry point: bundler runs lib/nvim/nvim directly. Keep it as a
# thin wrapper around bin/nvim so the bin/../share/nvim/runtime layout that
# Neovim auto-detects for its runtime files stays intact.
cat > build/pkg/nvim << 'WRAPPER'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "$SCRIPT_DIR/bin/nvim" "$@"
WRAPPER
chmod +x build/pkg/nvim build/pkg/bin/nvim

echo "Verifying built binary and bundled Lua parser..."
build/pkg/nvim --headless -u NONE \
  +'lua assert(vim.tbl_contains(vim.api.nvim_get_runtime_file("parser/lua.*", false), vim.fn.fnamemodify("build/pkg/share/nvim/runtime/parser/lua.so", ":p")), "runtime Lua parser not found")' \
  +'lua assert(vim.treesitter.language.add("lua"))' \
  +'lua vim.cmd("new test.lua"); vim.bo.filetype = "lua"; vim.treesitter.start()' \
  +qall!

tar czf "dist/nvim-standalone-${NVIM_VERSION}-x86_64-linux.tar.gz" -C build/pkg .
sha256sum dist/*.tar.gz > dist/SHA256SUMS

LICENSE=$(gh_license "neovim/neovim")
printf 'name=nvim\nversion=%s\nlicense=%s\n' "${NVIM_VERSION}" "${LICENSE}" > dist/BUILD_INFO.txt

echo "=== Done: nvim ${NVIM_VERSION} ==="
ls -lh dist/
