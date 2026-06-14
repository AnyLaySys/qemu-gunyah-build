#!/usr/bin/env bash
set -euo pipefail
sudo apt install -y python3 python3-venv python3-pip cmake ninja-build meson pkg-config git curl
ndkPath="$HOME/android-ndk-r30-beta1"
apiLevel="36"
nCpu="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
buildDir="$(pwd)/build"
outDir="$buildDir/out"
prefix="$buildDir/sysroot"
srcDir="$buildDir/src"
libffiVer="3.4.4"
pcre2Ver="10.44"
glibVer="2.83.0"
pixmanVer="0.42.2"
libusbVer="1.0.27"
buildPixman="1"
epoxyGitUrl="https://github.com/anholt/libepoxy.git"
virglGitUrl="https://gitlab.freedesktop.org/virgl/virglrenderer.git"
hostOs=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$hostOs" in
  linux)   hostTag="linux-x86_64" ;;
  darwin)  hostTag="darwin-x86_64" ;;
  *) echo "不支持此系统: $hostOs" >&2; exit 1 ;;
esac
toolchain="$ndkPath/toolchains/llvm/prebuilt/$hostTag"
targetTriple=aarch64-linux-android
mesonCpu=aarch64
cmakeAbi="arm64-v8a"
export CC="$toolchain/bin/${targetTriple}${apiLevel}-clang"
export CXX="$toolchain/bin/${targetTriple}${apiLevel}-clang++"
export AR="$toolchain/bin/llvm-ar"
export NM="$toolchain/bin/llvm-nm"
export STRIP="$toolchain/bin/llvm-strip"
export RANLIB="$toolchain/bin/llvm-ranlib"
export LD="$toolchain/bin/ld"
export OBJCOPY="$toolchain/bin/llvm-objcopy"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
export CFLAGS="-fPIC -fPIE -ftls-model=global-dynamic"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-pie"
mkdir -p "$prefix" "$srcDir" "$outDir"
fetch() {
  local url="$1" out="$2"
  if [ ! -f "$out" ]; then
    echo "下载 $url"
    curl -L --fail -o "$out" "$url"
  fi
}
cd "$srcDir"
fetch "https://github.com/libffi/libffi/releases/download/v${libffiVer}/libffi-${libffiVer}.tar.gz" "libffi-${libffiVer}.tar.gz"
[ -d "libffi-${libffiVer}" ] || tar xf "libffi-${libffiVer}.tar.gz"
mkdir -p "$outDir/libffi"
cd "$outDir/libffi"
if [ -f Makefile ]; then make distclean || true; fi
echo "配置 libffi ${libffiVer}"
"$srcDir/libffi-${libffiVer}/configure" \
  --host="${targetTriple}" \
  --prefix="$prefix" \
  --enable-shared \
  --disable-static \
  --disable-exec-static-tramp
echo "编译 libffi"
make -j"$nCpu"
make install
cd "$srcDir"
fetch "https://github.com/PhilipHazel/pcre2/releases/download/pcre2-${pcre2Ver}/pcre2-${pcre2Ver}.tar.bz2" "pcre2-${pcre2Ver}.tar.bz2"
[ -d "pcre2-${pcre2Ver}" ] || tar xf "pcre2-${pcre2Ver}.tar.bz2"
mkdir -p "$outDir/pcre2"
cd "$outDir/pcre2"
echo "配置 PCRE2 ${pcre2Ver}"
cmake -G Ninja "$srcDir/pcre2-${pcre2Ver}" \
  -DCMAKE_TOOLCHAIN_FILE="$ndkPath/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$cmakeAbi" \
  -DANDROID_PLATFORM="android-${apiLevel}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DCMAKE_C_FLAGS="-ftls-model=global-dynamic" \
  -DBUILD_SHARED_LIBS=ON \
  -DPCRE2_BUILD_PCRE2_8=ON \
  -DPCRE2_BUILD_PCRE2_16=OFF \
  -DPCRE2_BUILD_PCRE2_32=OFF \
  -DPCRE2_SUPPORT_JIT=OFF
echo "编译 PCRE2"
cmake --build . -j"$nCpu"
cmake --install .
cd "$srcDir"
fetch "https://download.gnome.org/sources/glib/${glibVer%.*}/glib-${glibVer}.tar.xz" "glib-${glibVer}.tar.xz"
[ -d "glib-${glibVer}" ] || tar xf "glib-${glibVer}.tar.xz"
perl -0pi -e "s/\\n  'lchmod',//" "glib-${glibVer}/meson.build"
perl -0pi -e "s/if cc\\.has_header_symbol\\('pthread\\.h', 'pthread_getaffinity_np', prefix : pthread_prefix\\)/if false and cc.has_header_symbol('pthread.h', 'pthread_getaffinity_np', prefix : pthread_prefix)/" "glib-${glibVer}/meson.build"
mesonCross="$outDir/glib.cross"
cat > "$mesonCross" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-fPIC','-fPIE','-ftls-model=global-dynamic']
c_link_args = ['-pie']
[host_machine]
system = 'linux'
cpu_family = '${mesonCpu}'
cpu = '${mesonCpu}'
endian = 'little'
EOF
mkdir -p "$outDir/glib"
cd "$outDir/glib"
[ -f build.ninja ] && rm -rf *
echo "配置 GLib ${glibVer}"
meson setup . "$srcDir/glib-${glibVer}" \
  --cross-file "$mesonCross" \
  --prefix "$prefix" \
  -Ddefault_library=shared \
  -Doptimization=2 \
  -Ddebug=false \
  -Dglib_debug=disabled \
  -Dtests=false \
  -Dman-pages=disabled \
  -Ddocumentation=false \
  -Dselinux=disabled \
  -Dlibmount=disabled \
  -Dnls=disabled
echo "编译 GLib"
meson compile -j"$nCpu"
meson install
if [ "$buildPixman" = "1" ]; then
  cd "$srcDir"
  fetch "https://www.cairographics.org/releases/pixman-${pixmanVer}.tar.gz" "pixman-${pixmanVer}.tar.gz"
  [ -d "pixman-${pixmanVer}" ] || tar xf "pixman-${pixmanVer}.tar.gz"
  mkdir -p "$outDir/pixman"
  cd "$outDir/pixman"
  if [ -f Makefile ]; then make distclean || true; fi
  echo "配置 pixman ${pixmanVer}"
  "$srcDir/pixman-${pixmanVer}/configure" \
    --host="${targetTriple}" \
    --prefix="$prefix" \
    --disable-static \
    --disable-arm-a64-neon
  echo "编译 pixman"
  make -j"$nCpu"
  make install
fi
cd "$srcDir"
fetch "https://github.com/libusb/libusb/releases/download/v${libusbVer}/libusb-${libusbVer}.tar.bz2" "libusb-${libusbVer}.tar.bz2"
[ -d "libusb-${libusbVer}" ] || tar xf "libusb-${libusbVer}.tar.bz2"
mkdir -p "$outDir/libusb"
cd "$outDir/libusb"
if [ -f Makefile ]; then make distclean || true; fi
echo "配置 libusb ${libusbVer}"
"$srcDir/libusb-${libusbVer}/configure" \
  --host="${targetTriple}" \
  --prefix="$prefix" \
  --enable-shared \
  --disable-static \
  --disable-udev
echo "编译 libusb"
make -j"$nCpu"
make install
epoxySrc="$srcDir/libepoxy"
if [ ! -d "$epoxySrc" ]; then
  echo "克隆 libepoxy"
  git clone --depth 1 "$epoxyGitUrl" "$epoxySrc"
fi
mesonCrossEpoxy="$outDir/epoxy.cross"
cat > "$mesonCrossEpoxy" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-fPIC','-fPIE','-ftls-model=global-dynamic']
c_link_args = ['-pie']
[host_machine]
system = 'linux'
cpu_family = '${mesonCpu}'
cpu = '${mesonCpu}'
endian = 'little'
EOF
mkdir -p "$outDir/epoxy"
cd "$outDir/epoxy"
[ -f build.ninja ] && rm -rf *
echo "配置 libepoxy"
meson setup . "$epoxySrc" \
  --cross-file "$mesonCrossEpoxy" \
  --prefix "$prefix" \
  -Ddefault_library=shared \
  -Degl=yes \
  -Dglx=no \
  -Dx11=false \
  -Dtests=false
echo "编译 libepoxy"
meson compile -j"$nCpu"
meson install
virglSrc="$srcDir/virglrenderer"
if [ ! -d "$virglSrc" ]; then
  echo "克隆 virglrenderer"
  git clone --depth 1 "$virglGitUrl" "$virglSrc"
fi
virglPatch="$(cd "$(dirname "$0")" && pwd)/patch/virglrenderer_android.patch"
if [ -f "$virglPatch" ]; then
  echo "应用 VirGLRenderer Android 补丁"
  if git -C "$virglSrc" apply --check "$virglPatch" 2>/dev/null; then
    git -C "$virglSrc" apply "$virglPatch"
    echo "VirGLRenderer Android 补丁应用成功"
  else
    echo "VirGLRenderer Android 补丁已存在或不需要，跳过"
  fi
fi
compatDir="$prefix/include/compat"
mkdir -p "$compatDir/log" "$compatDir/cutils"
echo "为 VirGLRenderer 创建 Android NDK 兼容头文件"
cat > "$compatDir/log/log.h" <<'SHIM_LOG'
#ifndef _COMPAT_LOG_LOG_H
#define _COMPAT_LOG_LOG_H
#include <android/log.h>
#ifndef LOG_PRI
#define LOG_PRI(priority, tag, ...) \
    __android_log_print(priority, tag, __VA_ARGS__)
#endif
#endif
SHIM_LOG
cat > "$compatDir/cutils/properties.h" <<'SHIM_PROP'
#ifndef _COMPAT_CUTILS_PROPERTIES_H
#define _COMPAT_CUTILS_PROPERTIES_H
#include <string.h>
#ifndef PROPERTY_VALUE_MAX
#define PROPERTY_VALUE_MAX 92
#endif
#ifndef PROPERTY_KEY_MAX
#define PROPERTY_KEY_MAX 32
#endif
static inline int property_get(const char *key, char *value,
                               const char *default_value) {
    (void)key;
    if (default_value) {
        strncpy(value, default_value, PROPERTY_VALUE_MAX - 1);
        value[PROPERTY_VALUE_MAX - 1] = '\0';
        return (int)strlen(value);
    }
    value[0] = '\0';
    return 0;
}
#endif
SHIM_PROP
mesonCrossVirGL="$outDir/virgl.cross"
cat > "$mesonCrossVirGL" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-fPIC','-fPIE','-ftls-model=global-dynamic','-I${compatDir}']
c_link_args = ['-pie','-llog']
[host_machine]
system = 'linux'
cpu_family = '${mesonCpu}'
cpu = '${mesonCpu}'
endian = 'little'
EOF
mkdir -p "$outDir/virglrenderer"
cd "$outDir/virglrenderer"
[ -f build.ninja ] && rm -rf *
echo "配置 VirGLRenderer"
meson setup . "$virglSrc" --cross-file "$mesonCrossVirGL" --prefix "$prefix" -Ddefault_library=shared -Dtests=false
echo "编译 VirGLRenderer"
meson compile -j"$nCpu"
meson install
