#!/bin/bash
set -euo pipefail

# Version matrix — all overridable via environment variables
CMAKE_VERSION="${CMAKE_VERSION:-3.29.6}"
QT_VERSION="${QT_VERSION:-6.7.3}"
KF_VERSION="${KF_VERSION:-6.12.0}"
KONSOLE_VERSION="${KONSOLE_VERSION:-26.04.0}"

echo "========================================"
echo " Setting up CentOS 7 build toolchain"
echo "========================================"

# The base oraclelinux:7 image only enables ol7_latest; SCL (devtoolset)
# and EPEL repos are not predefined, so add them explicitly.
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

yum install -y \
  git wget curl tar xz gzip bzip2 jq findutils which patch bison flex gettext \
  devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-make \
  perl python3 ninja-build patchelf \
  libX11-devel libXext-devel libXrender-devel libXi-devel \
  libXrandr-devel libXfixes-devel libXcursor-devel libXinerama-devel \
  libxcb-devel xcb-util-devel xcb-util-image-devel xcb-util-keysyms-devel \
  xcb-util-renderutil-devel xcb-util-wm-devel \
  mesa-libGL-devel mesa-libEGL-devel libdrm-devel \
  fontconfig-devel freetype-devel libpng-devel libjpeg-turbo-devel zlib-devel \
  openssl-devel dbus-devel glib2-devel \
  libxml2-devel libxslt-devel \
  polkit-devel libcap-devel libudev-devel \
  libacl-devel libattr-devel libmount-devel

rpm -q devtoolset-11-gcc devtoolset-11-gcc-c++ devtoolset-11-make

# shellcheck source=scripts/lib-license.sh
source "$(dirname "$0")/lib-license.sh"

# shellcheck source=/dev/null
source /opt/rh/devtoolset-11/enable

# Ninja alias (EPEL installs as ninja-build, cmake looks for ninja)
ln -sf /usr/bin/ninja-build /usr/local/bin/ninja

rm -rf build dist
mkdir -p build dist
STAGE="$PWD/build/staging"
mkdir -p "$STAGE"

echo "========================================"
echo " Konsole Standalone Builder (CentOS 7 / glibc 2.17)"
echo " cmake:   ${CMAKE_VERSION}"
echo " Qt:      ${QT_VERSION}"
echo " KF6:     ${KF_VERSION}"
echo " Konsole: ${KONSOLE_VERSION}"
echo "========================================"

# --------------------------------------------------------------------------
# Phase 1: CMake from source
# EPEL provides cmake 3.17; Qt 6 and KF6 require cmake >=3.19 to build.
# Build cmake with the system gcc (4.8) since cmake only needs C++11.
# --------------------------------------------------------------------------
echo "--- Phase 1: cmake ${CMAKE_VERSION} ---"
wget -qO build/cmake.tar.gz \
  "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}.tar.gz"
tar xzf build/cmake.tar.gz -C build
( cd "build/cmake-${CMAKE_VERSION}" \
  && ./bootstrap --prefix="$STAGE" --parallel="$(nproc)" -- -DCMAKE_BUILD_TYPE=Release \
  && make -j"$(nproc)" install )

export PATH="$STAGE/bin:$PATH"
export PKG_CONFIG_PATH="$STAGE/lib/pkgconfig:$STAGE/lib64/pkgconfig"
echo "cmake: $(cmake --version | head -1)"

# --------------------------------------------------------------------------
# Phase 2: Qt 6 (qtbase + qtsvg)
# qtbase covers Core, Gui, Widgets, DBus, Network, PrintSupport, and the
# xcb platform plugin for X11.  qtsvg is required for KDE icon themes.
# --------------------------------------------------------------------------
echo "--- Phase 2: Qt ${QT_VERSION} ---"
QT_MM="${QT_VERSION%.*}"   # e.g. 6.7

wget -qO build/qtbase.tar.xz \
  "https://download.qt.io/official_releases/qt/${QT_MM}/${QT_VERSION}/submodules/qtbase-everywhere-src-${QT_VERSION}.tar.xz"
tar xJf build/qtbase.tar.xz -C build
cmake -S "build/qtbase-everywhere-src-${QT_VERSION}" -B build/qtbase-build \
  -DCMAKE_INSTALL_PREFIX="$STAGE" \
  -DCMAKE_BUILD_TYPE=Release \
  -GNinja \
  -DQT_BUILD_TESTS=OFF \
  -DQT_BUILD_EXAMPLES=OFF \
  -DFEATURE_sql=OFF \
  -DFEATURE_testlib=OFF \
  -DFEATURE_vulkan=OFF \
  -DFEATURE_wayland=OFF \
  -DFEATURE_xcb=ON \
  -DFEATURE_opengl=ON \
  -DFEATURE_dbus=ON \
  -DFEATURE_network=ON \
  -DFEATURE_printdialog=ON
cmake --build build/qtbase-build -j"$(nproc)"
cmake --install build/qtbase-build

wget -qO build/qtsvg.tar.xz \
  "https://download.qt.io/official_releases/qt/${QT_MM}/${QT_VERSION}/submodules/qtsvg-everywhere-src-${QT_VERSION}.tar.xz"
tar xJf build/qtsvg.tar.xz -C build
cmake -S "build/qtsvg-everywhere-src-${QT_VERSION}" -B build/qtsvg-build \
  -DCMAKE_INSTALL_PREFIX="$STAGE" \
  -DCMAKE_PREFIX_PATH="$STAGE" \
  -DCMAKE_BUILD_TYPE=Release \
  -GNinja \
  -DQT_BUILD_TESTS=OFF \
  -DQT_BUILD_EXAMPLES=OFF
cmake --build build/qtsvg-build -j"$(nproc)"
cmake --install build/qtsvg-build

# --------------------------------------------------------------------------
# Phase 3: KDE Frameworks 6
# Build order respects the full dependency chain required by Konsole.
# --------------------------------------------------------------------------
echo "--- Phase 3: KDE Frameworks ${KF_VERSION} ---"

build_kf() {
  local name="$1"; shift
  echo "  > ${name}"
  wget -qO "build/${name}.tar.gz" \
    "https://github.com/KDE/${name}/archive/refs/tags/v${KF_VERSION}.tar.gz"
  tar xzf "build/${name}.tar.gz" -C build
  cmake -S "build/${name}-${KF_VERSION}" -B "build/${name}-build" \
    -DCMAKE_INSTALL_PREFIX="$STAGE" \
    -DCMAKE_PREFIX_PATH="$STAGE" \
    -DCMAKE_BUILD_TYPE=Release \
    -GNinja \
    -DBUILD_TESTING=OFF \
    -DBUILD_QCH=OFF \
    "$@"
  cmake --build "build/${name}-build" -j"$(nproc)"
  cmake --install "build/${name}-build"
}

build_kf extra-cmake-modules
build_kf kcoreaddons
build_kf ki18n
build_kf kconfig
build_kf kdbusaddons
build_kf kguiaddons
build_kf kwidgetsaddons
build_kf kcolorscheme
build_kf kconfigwidgets
build_kf kwindowsystem
build_kf kcrash
build_kf kauth
build_kf kjobwidgets
build_kf kcompletion
build_kf kservice
build_kf kglobalaccel
build_kf kitemviews
build_kf kiconthemes
build_kf knotifications
build_kf ktextwidgets
build_kf kxmlgui
build_kf kbookmarks
build_kf solid
build_kf kio
build_kf kparts
build_kf knotifyconfig
build_kf kpty

# --------------------------------------------------------------------------
# Phase 4: Konsole
# --------------------------------------------------------------------------
echo "--- Phase 4: Konsole ${KONSOLE_VERSION} ---"
wget -qO build/konsole.tar.gz \
  "https://github.com/KDE/konsole/archive/refs/tags/v${KONSOLE_VERSION}.tar.gz"
tar xzf build/konsole.tar.gz -C build
cmake -S "build/konsole-${KONSOLE_VERSION}" -B build/konsole-build \
  -DCMAKE_INSTALL_PREFIX="$STAGE" \
  -DCMAKE_PREFIX_PATH="$STAGE" \
  -DCMAKE_BUILD_TYPE=Release \
  -GNinja \
  -DBUILD_TESTING=OFF \
  -DBUILD_QCH=OFF
cmake --build build/konsole-build -j"$(nproc)"
cmake --install build/konsole-build

# --------------------------------------------------------------------------
# Phase 5: Bundle
# Collect Qt + KF6 shared libs, Qt plugins, data files, and the binary.
# devtoolset-11 libstdc++.so.6 is bundled because OL7's system libstdc++
# (gcc 4.8, version 6.0.19) is too old to satisfy C++17 ABIs.
# --------------------------------------------------------------------------
echo "--- Phase 5: Bundling ---"
PKG="build/pkg"
mkdir -p "$PKG/bin" "$PKG/lib" "$PKG/share"

cp "$STAGE/bin/konsole" "$PKG/bin/konsole"

# Shared libraries we built (Qt + KF6) — both actual files and .so symlinks
find "$STAGE/lib" -maxdepth 1 \( -name "*.so" -o -name "*.so.*" \) -print0 \
  | xargs -0 -I{} cp -P {} "$PKG/lib/"

# devtoolset-11 libstdc++ (runtime ABI newer than CentOS 7 system provides)
DEVTOOL_LIBSTDCXX=$(find /opt/rh/devtoolset-11 -name "libstdc++.so.6" -type f 2>/dev/null | head -1 || true)
if [ -n "$DEVTOOL_LIBSTDCXX" ]; then
  cp "$DEVTOOL_LIBSTDCXX" "$PKG/lib/libstdc++.so.6"
fi

# Qt plugins (xcb platform, image formats, icon engine, SVG)
# Qt 6 installs plugins under $prefix/plugins/
if [ -d "$STAGE/plugins" ]; then
  cp -r "$STAGE/plugins" "$PKG/plugins"
fi
# Some Qt builds place plugins under lib/qt6/plugins instead
if [ -d "$STAGE/lib/qt6/plugins" ]; then
  cp -r "$STAGE/lib/qt6/plugins" "$PKG/plugins"
fi

# KF6 plugins (kio workers, kparts components, etc.)
for kf_plugin_dir in kf6 kio kparts; do
  for base in "$STAGE/lib/qt6/plugins/$kf_plugin_dir" "$STAGE/plugins/$kf_plugin_dir"; do
    if [ -d "$base" ]; then
      mkdir -p "$PKG/plugins/$(basename "$base")"
      cp -rn "$base/." "$PKG/plugins/$(basename "$base")/" 2>/dev/null || true
    fi
  done
done

# Application data (color schemes, session profiles, notification configs)
for d in konsole kconf_update knotifications6 kservices6 kservicetypes6; do
  [ -d "$STAGE/share/$d" ] && cp -r "$STAGE/share/$d" "$PKG/share/"
done

# Strip debug info to reduce tarball size
find "$PKG" \( -name "*.so*" -o -name "konsole" \) -type f \
  | xargs strip --strip-unneeded 2>/dev/null || true

# Entry-point wrapper: sets LD_LIBRARY_PATH so bundled Qt/KF6/libstdc++ are
# found before the system's older copies, and tells Qt where its plugins are.
cat > "$PKG/konsole-centos7" << 'WRAPPER'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export LD_LIBRARY_PATH="$SCRIPT_DIR/lib:${LD_LIBRARY_PATH:-}"
export QT_PLUGIN_PATH="$SCRIPT_DIR/plugins"
export XDG_DATA_DIRS="$SCRIPT_DIR/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$SCRIPT_DIR/bin/konsole" "$@"
WRAPPER
chmod +x "$PKG/konsole-centos7" "$PKG/bin/konsole"

echo "Verifying dynamic links (no bundled lib should appear as 'not found')..."
ldd "$PKG/bin/konsole" || true
MISSING=$(LD_LIBRARY_PATH="$PKG/lib" ldd "$PKG/bin/konsole" 2>/dev/null \
  | grep "not found" | grep -v "libX\|libxcb\|libGL\|libEGL\|libdbus\|libudev" || true)
if [ -n "$MISSING" ]; then
  echo "ERROR: unresolved dependencies:"
  echo "$MISSING"
  exit 1
fi

echo "Packaging..."
tar czf "dist/konsole-centos7-standalone-${KONSOLE_VERSION}-x86_64-linux.tar.gz" -C "$PKG" .
sha256sum dist/*.tar.gz > dist/SHA256SUMS

LICENSE=$(gh_license "KDE/konsole")
printf 'name=konsole-centos7\nversion=%s\nlicense=%s\n' "${KONSOLE_VERSION}" "${LICENSE}" > dist/BUILD_INFO.txt

echo "=== Done: konsole-centos7 ${KONSOLE_VERSION} ==="
ls -lh dist/
