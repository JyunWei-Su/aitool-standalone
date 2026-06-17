#!/bin/bash
set -euo pipefail

echo "========================================"
echo " Setting up CentOS 7 build toolchain"
echo "========================================"

# The base oraclelinux:7 image only enables ol7_latest; the SCL
# (devtoolset) and EPEL (cmake3) repos are not predefined, so
# `yum-config-manager --enable <id>` on those IDs is a silent no-op.
# Add them explicitly with their real base URLs instead.
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

yum install -y git wget curl tar xz jq findutils sudo which \
  gettext libtool autoconf automake pkgconfig unzip patch ncurses \
  devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-make cmake3

# yum silently skips packages it cannot find instead of failing the
# whole command, so verify the critical toolchain packages landed.
rpm -q devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-make cmake3

# shellcheck source=scripts/lib-license.sh
source "$(dirname "$0")/lib-license.sh"

NVIM_VERSION="${NVIM_VERSION:-$(curl -sL \
  ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
  "https://api.github.com/repos/neovim/neovim/releases/latest" | jq -r .tag_name)}"

echo "========================================"
echo " Neovim Standalone Builder (CentOS 7 / glibc 2.17)"
echo " Version: ${NVIM_VERSION}"
echo "========================================"

# devtoolset-11 provides a GCC new enough for Neovim's C11 requirements;
# OL7's stock gcc 4.8.5 is not. cmake3 (EPEL) satisfies Neovim's
# cmake_minimum_required(VERSION 3.16) — OL7's stock cmake (2.8.x) does not.
# shellcheck source=/dev/null
source /opt/rh/devtoolset-11/enable
ln -sf /usr/bin/cmake3 /usr/local/bin/cmake

rm -rf build dist
mkdir -p dist

SRC_URL="https://github.com/neovim/neovim/archive/refs/tags/${NVIM_VERSION}.tar.gz"
echo "Downloading ${SRC_URL}..."
wget -qO source.tar.gz "$SRC_URL"
tar xzf source.tar.gz
SRC_DIR=$(find . -maxdepth 1 -type d -name "neovim-*" | head -1)
mv "$SRC_DIR" build
cd build

# Build from source against this container's glibc 2.17, so the resulting
# binary runs on CentOS 7 / Oracle Linux 7 and any newer glibc (forward
# compatible), unlike upstream's prebuilt nvim-linux-x86_64.tar.gz.
echo "Building Neovim (this takes a while)..."
make CMAKE_BUILD_TYPE=RelWithDebInfo \
     CMAKE_INSTALL_PREFIX="$PWD/dist-install" \
     -j"$(nproc)"
make install

cd ..

echo "Packaging..."
mkdir -p build/pkg/bin build/pkg/share/nvim build/pkg/lib
cp build/dist-install/bin/nvim build/pkg/bin/nvim
cp -r build/dist-install/share/nvim/runtime build/pkg/share/nvim/runtime
cp -r build/dist-install/lib/nvim build/pkg/lib/nvim

# OL7's ncurses (5.9, ~2011) terminfo lacks the "Ms" (OSC 52 clipboard)
# capability. Without it, Neovim queries the terminal directly on startup via
# an XTGETTCAP escape sequence (DCS "+q4D73" ... ST); terminals/multiplexers
# that don't consume that sequence echo it back as garbage. Patch the common
# xterm/screen/tmux terminfo entries with "Ms" so Neovim skips the query.
echo "Patching terminfo with Ms (OSC52 clipboard) capability..."
mkdir -p build/pkg/share/terminfo
cat > /tmp/cap-ms.txt << 'EOF'
	Ms=\E]52;%p1%s;%p2%s\007,
EOF
for term in xterm xterm-256color screen screen-256color tmux tmux-256color; do
  if infocmp "$term" > /tmp/ti-src 2>/dev/null; then
    # infocmp prefixes output with a "# Reconstructed via infocmp..." comment
    # line for entries with extended capabilities; strip it so line 1 is the
    # actual "name|name|description," header that tic requires.
    grep -v '^#' /tmp/ti-src > /tmp/ti-src.new
    grep -q 'Ms=' /tmp/ti-src.new || sed -i '1r /tmp/cap-ms.txt' /tmp/ti-src.new
    tic -x -o build/pkg/share/terminfo /tmp/ti-src.new
  else
    echo "  skip ${term}: not in base terminfo"
  fi
done

# Top-level entry point: bundler runs lib/nvim-centos7/nvim-centos7 directly.
# Keep it as a thin wrapper around bin/nvim so the bin/../share/nvim/runtime
# layout that Neovim auto-detects for its runtime files stays intact.
cat > build/pkg/nvim-centos7 << 'WRAPPER'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export TERMINFO_DIRS="$SCRIPT_DIR/share/terminfo:"
exec "$SCRIPT_DIR/bin/nvim" "$@"
WRAPPER
chmod +x build/pkg/nvim-centos7 build/pkg/bin/nvim

# Smoke test: confirm the binary actually runs in this glibc 2.17 environment
# (catches missing runtime files / dynamic linking issues before shipping).
echo "Verifying built binary runs..."
if ! build/pkg/nvim-centos7 --headless -u NONE \
  +'lua vim.cmd("new test.lua"); vim.bo.filetype = "lua"; vim.treesitter.start()' \
  +qall!; then
  echo "ERROR: nvim-centos7 failed to run (see output above)" >&2
  exit 1
fi
build/pkg/nvim-centos7 --version | head -3

tar czf "dist/nvim-centos7-standalone-${NVIM_VERSION}-x86_64-linux.tar.gz" -C build/pkg .
sha256sum dist/*.tar.gz > dist/SHA256SUMS

LICENSE=$(gh_license "neovim/neovim")
printf 'name=nvim-centos7\nversion=%s\nlicense=%s\n' "${NVIM_VERSION}" "${LICENSE}" > dist/BUILD_INFO.txt

echo "=== Done: nvim-centos7 ${NVIM_VERSION} ==="
ls -lh dist/
