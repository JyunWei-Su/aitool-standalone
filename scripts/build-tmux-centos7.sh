#!/bin/bash
set -euo pipefail

echo "========================================"
echo " Setting up CentOS 7 build toolchain"
echo "========================================"

# The base oraclelinux:7 image only enables ol7_latest; EPEL (for jq) is not
# predefined, so `yum-config-manager --enable <id>` on those IDs is a silent
# no-op. Add it explicitly with its real base URL instead.
cat > /etc/yum.repos.d/ol7-extra.repo << 'REPOEOF'
[ol7_developer_EPEL]
name=Oracle Linux 7 Development Packages (EPEL)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL7/developer_EPEL/x86_64/
gpgcheck=1
gpgkey=https://yum.oracle.com/RPM-GPG-KEY-oracle-ol7
enabled=1
REPOEOF

yum install -y git wget curl tar gzip xz jq findutils gcc make pkgconfig bison gawk

# shellcheck source=scripts/lib-license.sh
source "$(dirname "$0")/lib-license.sh"

TMUX_VERSION="${TMUX_VERSION:-$(curl -sL \
  ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
  "https://api.github.com/repos/tmux/tmux/releases/latest" | jq -r .tag_name)}"

LIBEVENT_TAG="${LIBEVENT_VERSION:-$(curl -sL \
  ${GH_TOKEN:+-H "Authorization: Bearer ${GH_TOKEN}"} \
  "https://api.github.com/repos/libevent/libevent/releases/latest" | jq -r .tag_name)}"
LIBEVENT_VER="${LIBEVENT_TAG#release-}"

NCURSES_VERSION="${NCURSES_VERSION:-$(curl -sL https://ftp.gnu.org/gnu/ncurses/ \
  | grep -oE 'ncurses-[0-9]+\.[0-9]+\.tar\.gz' | sort -Vu | tail -1 \
  | sed -E 's/ncurses-(.*)\.tar\.gz/\1/')}"

echo "========================================"
echo " tmux Standalone Builder (CentOS 7 / glibc 2.17)"
echo " tmux:     ${TMUX_VERSION}"
echo " libevent: ${LIBEVENT_VER}"
echo " ncurses:  ${NCURSES_VERSION}"
echo "========================================"

rm -rf build dist
mkdir -p build dist
STAGE="$PWD/build/staging"
mkdir -p "$STAGE"

# ---------------------------------------------------------------------------
# libevent (static): tmux links against libevent at runtime. To make the
# resulting binary independent of whatever (or whether) libevent is installed
# on the target system, build it from source as a static archive and link it
# into tmux directly.
# ---------------------------------------------------------------------------
echo "Building libevent ${LIBEVENT_VER} (static)..."
LIBEVENT_URL="https://github.com/libevent/libevent/releases/download/${LIBEVENT_TAG}/libevent-${LIBEVENT_VER}.tar.gz"
wget -qO build/libevent.tar.gz "$LIBEVENT_URL"
tar xzf build/libevent.tar.gz -C build
( cd "build/libevent-${LIBEVENT_VER}" \
  && ./configure --prefix="$STAGE" --disable-shared --enable-static \
       --disable-openssl --disable-samples --disable-libevent-regress \
       --disable-thread-support \
  && make -j"$(nproc)" \
  && make install )

# ---------------------------------------------------------------------------
# ncurses (static): same rationale as libevent above, plus tmux needs the
# terminfo-querying functions (tigetstr/setupterm/...). Build with wide-char
# (UTF-8) support and --enable-overwrite so headers/libs land directly in
# $STAGE/include and $STAGE/lib (no ncursesw/ subdir), keeping the tmux
# configure flags simple.
#
# `make install` also compiles+installs ncurses' own terminfo database into
# $STAGE/share/terminfo via misc/run_tic.sh, but ncurses 6.6's terminfo.src
# has a 'scrt' entry that overflows tic's legacy entry-size limit and aborts
# the install. We don't need that database here: tmux only needs the static
# libs/headers/pkg-config files, and the target CentOS 7 host already has its
# own terminfo database at runtime. Replace run_tic.sh with a no-op so
# `make install` skips that step.
# ---------------------------------------------------------------------------
echo "Building ncurses ${NCURSES_VERSION} (static)..."
NCURSES_URL="https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VERSION}.tar.gz"
wget -qO build/ncurses.tar.gz "$NCURSES_URL"
tar xzf build/ncurses.tar.gz -C build
( cd "build/ncurses-${NCURSES_VERSION}" \
  && ./configure --prefix="$STAGE" \
       --without-shared --without-debug --without-ada \
       --without-manpages --without-tests --without-progs \
       --enable-widec --enable-overwrite \
  && make -j"$(nproc)" \
  && printf '#!/bin/sh\nexit 0\n' > misc/run_tic.sh \
  && make install )

# tmux's configure.ac probes for the terminfo library under several names
# (tinfo, tinfow, ncurses, ncursesw, curses) depending on version. With
# --enable-widec (no --with-termlib) everything lives in libncursesw.a /
# ncursesw.pc; add aliases under the other names so whichever one tmux's
# configure looks for resolves to the same static archive.
echo "Adding ncurses library/pkg-config aliases..."
( cd "$STAGE/lib" \
  && for alias in libtinfo.a libtinfow.a libncurses.a libcurses.a; do
       [ -e "$alias" ] || ln -s libncursesw.a "$alias"
     done )
( cd "$STAGE/lib/pkgconfig" \
  && for alias in tinfo.pc tinfow.pc ncurses.pc curses.pc; do
       [ -e "$alias" ] || cp ncursesw.pc "$alias"
     done )

# ---------------------------------------------------------------------------
# tmux: link against the static libevent/ncurses above. glibc itself stays
# dynamically linked — building in this glibc 2.17 container makes the
# resulting binary forward-compatible with newer glibc on the target host
# (same approach as nvim-centos7).
# ---------------------------------------------------------------------------
echo "Building tmux ${TMUX_VERSION}..."
TMUX_URL="https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz"
wget -qO build/tmux.tar.gz "$TMUX_URL"
tar xzf build/tmux.tar.gz -C build
( cd "build/tmux-${TMUX_VERSION}" \
  && export PKG_CONFIG_PATH="$STAGE/lib/pkgconfig" \
  && export CPPFLAGS="-I$STAGE/include" \
  && export LDFLAGS="-L$STAGE/lib" \
  && ./configure --prefix="$PWD/dist-install" \
  && make -j"$(nproc)" \
  && make install )

echo "Packaging..."
mkdir -p build/pkg
cp "build/tmux-${TMUX_VERSION}/dist-install/bin/tmux" build/pkg/tmux-centos7
chmod +x build/pkg/tmux-centos7

# Confirm libevent/ncurses were statically linked (no .so dependency on
# them), and that the binary actually runs in this glibc 2.17 environment.
echo "Checking linked libraries..."
ldd build/pkg/tmux-centos7
if ldd build/pkg/tmux-centos7 | grep -qiE 'libevent|libncurses|libtinfo'; then
  echo "ERROR: tmux-centos7 is dynamically linked against libevent/ncurses" >&2
  exit 1
fi

echo "Verifying built binary runs..."
build/pkg/tmux-centos7 -V

tar czf "dist/tmux-centos7-standalone-${TMUX_VERSION}-x86_64-linux.tar.gz" -C build/pkg .
sha256sum dist/*.tar.gz > dist/SHA256SUMS

LICENSE=$(gh_license "tmux/tmux")
printf 'name=tmux-centos7\nversion=%s\nlicense=%s\n' "${TMUX_VERSION}" "${LICENSE}" > dist/BUILD_INFO.txt

echo "=== Done: tmux-centos7 ${TMUX_VERSION} ==="
ls -lh dist/
