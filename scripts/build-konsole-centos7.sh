#!/bin/bash
set -euo pipefail

# Version matrix — all overridable via environment variables
CMAKE_VERSION="${CMAKE_VERSION:-3.29.6}"
FREETYPE_VERSION="${FREETYPE_VERSION:-2.13.3}"
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
  libxkbcommon-devel libxkbcommon-x11-devel xkeyboard-config \
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
echo " cmake:     ${CMAKE_VERSION}"
echo " FreeType:  ${FREETYPE_VERSION}"
echo " Qt:        ${QT_VERSION}"
echo " KF6:       ${KF_VERSION}"
echo " Konsole:   ${KONSOLE_VERSION}"
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
# Phase 1.5: FreeType from source
# CentOS 7 ships FreeType 2.8.0; Qt 6.7 uses FT_Done_MM_Var added in 2.9.
# Build without HarfBuzz to avoid the FreeType↔HarfBuzz circular dependency.
# --------------------------------------------------------------------------
echo "--- Phase 1.5: FreeType ${FREETYPE_VERSION} ---"
wget -qO build/freetype.tar.xz \
  "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
tar xJf build/freetype.tar.xz -C build
cmake -S "build/freetype-${FREETYPE_VERSION}" -B build/freetype-build \
  -DCMAKE_INSTALL_PREFIX="$STAGE" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DFT_DISABLE_HARFBUZZ=TRUE \
  -DFT_DISABLE_BZIP2=TRUE \
  -DFT_REQUIRE_ZLIB=TRUE \
  -DFT_REQUIRE_PNG=TRUE
cmake --build build/freetype-build -j"$(nproc)"
cmake --install build/freetype-build

# --------------------------------------------------------------------------
# Phase 1.6: xcb-util-cursor from source
# Qt 6.5+ xcb platform plugin requires xcb-cursor; not packaged in OL7.
# Build from source so Qt finds it via PKG_CONFIG_PATH at configure time.
# The resulting shared lib is bundled in Phase 5 (copied from $STAGE/lib).
# --------------------------------------------------------------------------
echo "--- Phase 1.6: xcb-util-cursor ---"
wget -qO build/xcb-util-cursor.tar.gz \
  "https://xcb.freedesktop.org/dist/xcb-util-cursor-0.1.4.tar.gz"
tar xzf build/xcb-util-cursor.tar.gz -C build
( cd build/xcb-util-cursor-0.1.4 \
  && ./configure --prefix="$STAGE" \
  && make -j"$(nproc)" \
  && make install )

# --------------------------------------------------------------------------
# Phase 2: Qt 6 (qtbase + qtsvg)
# qtbase covers Core, Gui, Widgets, DBus, Network, PrintSupport, and the
# xcb platform plugin for X11.  qtsvg is required for KDE icon themes.
# --------------------------------------------------------------------------
echo "--- Phase 2: Qt ${QT_VERSION} ---"
QT_MM="${QT_VERSION%.*}"   # e.g. 6.7

# Qt releases are eventually moved from official_releases/ to archive/; try both.
qt_wget() {
  local file="$1" dest="$2"
  wget -qO "$dest" \
    "https://download.qt.io/official_releases/qt/${QT_MM}/${QT_VERSION}/submodules/${file}" \
  || wget -qO "$dest" \
    "https://download.qt.io/archive/qt/${QT_MM}/${QT_VERSION}/submodules/${file}"
}

qt_wget "qtbase-everywhere-src-${QT_VERSION}.tar.xz" build/qtbase.tar.xz
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
  -DFEATURE_opengl=ON \
  -DFEATURE_dbus=ON \
  -DFEATURE_network=ON \
  -DFEATURE_printdialog=ON
cmake --build build/qtbase-build -j"$(nproc)"
cmake --install build/qtbase-build

qt_wget "qtsvg-everywhere-src-${QT_VERSION}.tar.xz" build/qtsvg.tar.xz
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

# qtshadertools: provides Qt Shader Baker and RHI shader compilation support.
# Qt Quick's cmake feature check looks for Qt6ShaderTools at configure time;
# without it, the 'quick' feature can be silently disabled in qtdeclarative.
qt_wget "qtshadertools-everywhere-src-${QT_VERSION}.tar.xz" build/qtshadertools.tar.xz
tar xJf build/qtshadertools.tar.xz -C build
cmake -S "build/qtshadertools-everywhere-src-${QT_VERSION}" -B build/qtshadertools-build \
  -DCMAKE_INSTALL_PREFIX="$STAGE" \
  -DCMAKE_PREFIX_PATH="$STAGE" \
  -DCMAKE_BUILD_TYPE=Release \
  -GNinja \
  -DQT_BUILD_TESTS=OFF \
  -DQT_BUILD_EXAMPLES=OFF
cmake --build build/qtshadertools-build -j"$(nproc)"
cmake --install build/qtshadertools-build

# qtdeclarative (Qt6::Qml + Qt6::Quick) is required by Konsole 26.04.0
# INPUT_quick / INPUT_quickwidgets are the cmake input variables that Qt's
# feature system checks when FEATURE_quick is declared PRIVATE (the PRIVATE
# keyword makes the feature non-settable via -DFEATURE_quick on some Qt
# versions; INPUT_ variables bypass that restriction).
qt_wget "qtdeclarative-everywhere-src-${QT_VERSION}.tar.xz" build/qtdeclarative.tar.xz
tar xJf build/qtdeclarative.tar.xz -C build
cmake -S "build/qtdeclarative-everywhere-src-${QT_VERSION}" -B build/qtdeclarative-build \
  -DCMAKE_INSTALL_PREFIX="$STAGE" \
  -DCMAKE_PREFIX_PATH="$STAGE" \
  -DCMAKE_BUILD_TYPE=Release \
  -GNinja \
  -DQT_BUILD_TESTS=OFF \
  -DQT_BUILD_EXAMPLES=OFF \
  -DFEATURE_quick=ON \
  -DFEATURE_quickwidgets=ON \
  -DINPUT_quick=yes \
  -DINPUT_quickwidgets=yes
cmake --build build/qtdeclarative-build -j"$(nproc)"
cmake --install build/qtdeclarative-build

echo "=== Qt cmake modules after qtdeclarative install ==="
find "$STAGE/lib/cmake" -maxdepth 1 -type d -name "Qt6*" | sort || true
if [ ! -f "$STAGE/lib/cmake/Qt6Quick/Qt6QuickConfig.cmake" ]; then
  echo "ERROR: Qt6QuickConfig.cmake was not installed — Quick module was not built!" >&2
  echo "Installed Qt6 cmake modules:" >&2
  find "$STAGE/lib/cmake" -maxdepth 1 -type d -name "Qt6*" | sort >&2
  exit 1
fi
echo "Qt6Quick: OK"

# qttools (Qt6LinguistTools — lrelease/lupdate) required by ECMPoQmTools
qt_wget "qttools-everywhere-src-${QT_VERSION}.tar.xz" build/qttools.tar.xz
tar xJf build/qttools.tar.xz -C build
cmake -S "build/qttools-everywhere-src-${QT_VERSION}" -B build/qttools-build \
  -DCMAKE_INSTALL_PREFIX="$STAGE" \
  -DCMAKE_PREFIX_PATH="$STAGE" \
  -DCMAKE_BUILD_TYPE=Release \
  -GNinja \
  -DQT_BUILD_TESTS=OFF \
  -DQT_BUILD_EXAMPLES=OFF \
  -DFEATURE_assistant=OFF \
  -DFEATURE_clang=OFF \
  -DFEATURE_qdoc=OFF \
  -DFEATURE_designer=OFF \
  -DFEATURE_pixeltool=OFF \
  -DFEATURE_kmap2qmap=OFF \
  -DFEATURE_qtplugininfo=OFF \
  -DFEATURE_qtdiag=OFF
cmake --build build/qttools-build -j"$(nproc)"
cmake --install build/qttools-build

# Confirm Qt was built with xcb support.  qtx11extras_p.h is a private
# header installed only when the xcb platform plugin is fully configured
# (requires xcb-util-cursor).  kdbusaddons unconditionally includes it on
# Linux, so a missing header here means a guaranteed kdbusaddons failure.
if [ ! -f "$STAGE/include/QtGui/${QT_VERSION}/QtGui/private/qtx11extras_p.h" ]; then
  echo "ERROR: Qt xcb private headers not installed — kdbusaddons will fail" >&2
  echo "xcb platform plugin present?" >&2
  find "$STAGE/plugins" "$STAGE/lib/qt6/plugins" -name "libqxcb.so" 2>/dev/null \
    | head -5 >&2 || echo "  libqxcb.so not found in staging" >&2
  exit 1
fi
echo "Qt xcb private headers: OK"

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
    -DWITH_WAYLAND=OFF \
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
build_kf kwindowsystem -DKWINDOWSYSTEM_WAYLAND=OFF
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
