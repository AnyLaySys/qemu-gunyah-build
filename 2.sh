#!/usr/bin/env bash
set -euo pipefail
apiLevel="36"
buildDir="$(pwd)/build"
bitsInstalled="$buildDir/sysroot/include/libucontext/bits.h"
fwSrc="$buildDir/sysroot/share/qemu"
gitClone="git clone --depth 1 --single-branch --no-tags --filter=blob:none --recurse-submodules --shallow-submodules --also-filter-submodules --jobs $(nproc)"
hostOs=$(uname -s | tr '[:upper:]' '[:lower:]')
epoxyGitUrl="https://github.com/anholt/libepoxy.git"
epoxySrc="$buildDir/src/libepoxy"
libucontextGitUrl="https://github.com/kaniini/libucontext.git"
libucontextH="$buildDir/sysroot/include/libucontext/libucontext.h"
libucontextSrc="$buildDir/libucontext"
liburingGitUrl="https://github.com/axboe/liburing.git"
liburingSrc="$buildDir/liburing"
nCpu="$(nproc || sysctl -n hw.ncpu)"
ndkPath="$HOME/android-ndk-r30-beta1"
outDir="$buildDir/out/qemu"
prefix="$buildDir/sysroot"
qvmDir="qemu-gunyah"
qvmFw="$qvmDir/fw"
qvmGitUrl="https://github.com/AnyLaySys/qemu-gunyah.git"
qvmLib="$qvmDir/lib"
qvmSrc="$buildDir/src/qemu-gunyah-main"
scriptDir="$(cd "$(dirname "$0")" && pwd)"
sdlConfigH="$buildDir/src/SDL2/include/SDL_config_android.h"
sdlSrc="$buildDir/src/SDL2"
sdlXinput2H="$buildDir/src/SDL2/src/video/x11/SDL_x11xinput2.h"
virglGitUrl="https://gitlab.freedesktop.org/virgl/virglrenderer.git"
virglSrc="$buildDir/src/virglrenderer"
x11DirSrc="$scriptDir/patch/x11-dir.c"
sysBin="$prefix/bin"
sysLib="$prefix/lib"
targetTriple=aarch64-linux-android
termuxRepo="https://packages.termux.dev/apt/termux-main"
termuxPackages="$buildDir/termux-Packages"
wrapPc="$outDir/android-pkg-config"
case "$hostOs" in
  darwin) hostTag="darwin-x86_64" ;;
  linux) hostTag="linux-x86_64" ;;
  *) echo "不支持的系统: $hostOs" >&2; exit 1 ;;
esac
hostCC="${HOST_CC:-$(command -v cc || true)}"
if [ -z "$hostCC" ]; then
  exit 1
fi
toolchain="$ndkPath/toolchains/llvm/prebuilt/$hostTag"
readelf="$toolchain/bin/llvm-readelf"
strip="$toolchain/bin/llvm-strip"
displayOpts=(-Dsdl=enabled -Dopengl=enabled)
export AR="$toolchain/bin/llvm-ar"
export CC="$toolchain/bin/${targetTriple}${apiLevel}-clang"
export CFLAGS="-fPIC -Os -ffunction-sections -fdata-sections -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -fmerge-all-constants -mbranch-protection=none -ftls-model=global-dynamic -Wno-error -I$prefix/include -DSDL_MAIN_HANDLED -I$prefix/include/pixman-1 -DANDROID_PLATFORM=android-${apiLevel}"
export CPPFLAGS="$CFLAGS"
export CXX="$toolchain/bin/${targetTriple}${apiLevel}-clang++"
export LD="$toolchain/bin/ld.lld"
export LDFLAGS="-L$prefix/lib -Wl,--gc-sections -Wl,--icf=all -Wl,-s -lucontext"
export NM="$toolchain/bin/llvm-nm"
export OBJCOPY="$toolchain/bin/llvm-objcopy"
export RANLIB="$toolchain/bin/llvm-ranlib"
export STRIP="$toolchain/bin/llvm-strip"
collectLib() {
  local elfPath
  local neededName
  local queueIndex=0
  pendingElfs=("$@")
  while [ "$queueIndex" -lt "${#pendingElfs[@]}" ]; do
    elfPath="${pendingElfs[$queueIndex]}"
    queueIndex=$((queueIndex + 1))
    while IFS= read -r neededName; do
      [ -z "$neededName" ] && continue
      if [ "$neededName" = "libandroid-support.so" ]; then
        patchelf --remove-needed "$neededName" "$elfPath" || true
        continue
      fi
      copyLib "$neededName"
    done < <(neededLibs "$elfPath")
  done
}
copyLib() {
  local destPath
  local neededName=$1
  local sourcePath
  destPath="$qvmLib/$neededName"
  if isSystemLib "$neededName"; then
    return 0
  fi
  if ! sourcePath="$(findLib "$neededName")"; then
    echo "缺少依赖: $neededName" >&2
    return 1
  fi
  if [ ! -f "$destPath" ]; then
    cp -Lf "$sourcePath" "$destPath"
    patchelf --set-soname "$neededName" "$destPath" || true
    pendingElfs+=("$destPath")
  fi
}
buildX11PathShim() {
  "$CC" -shared -fPIC -Os -Wl,--gc-sections -Wl,-s \
    -o "$prefix/lib/libX11-dir.so" "$x11DirSrc" -ldl
}
writeMesonCross() {
  local file=$1
  local extraC=${2:-}
  local extraLink=${3:-}
  cat > "$file" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$PKG_CONFIG'
[built-in options]
c_args = ['-fPIC','-Os','-ffunction-sections','-fdata-sections','-fomit-frame-pointer','-ftls-model=global-dynamic','-Wno-error','-I$prefix/include'$extraC]
cpp_args = ['-fPIC','-Os','-ffunction-sections','-fdata-sections','-fomit-frame-pointer','-ftls-model=global-dynamic','-Wno-error','-I$prefix/include'$extraC]
c_link_args = ['-L$prefix/lib','-Wl,--gc-sections','-Wl,--icf=all','-Wl,-s'$extraLink]
cpp_link_args = ['-L$prefix/lib','-Wl,--gc-sections','-Wl,--icf=all','-Wl,-s'$extraLink]
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
}
x11SocketPlaceholders() {
  local file
  local x11From
  local ximFrom
  x11From="$(printf '/data/data/com.termux/files/usr/tmp/%s' '.X11-unix/X')"
  ximFrom="$(printf '/data/data/com.termux/files/usr/tmp/%s' '.XIM-unix/XIM')"
  for file in "$@"; do
    [ -f "$file" ] || continue
    X11_FROM="$x11From" XIM_FROM="$ximFrom" perl -0pi -e '
      sub fit { $_[1] . "\0" x (length($_[0]) - length($_[1])) }
      my $x11_to = "X11_TMPDIR_PLACEHOLDER/.X11-unix/X";
      my $xim_to = "X11_TMPDIR_PLACEHOLDER/.XIM-unix/XIM";
      s/\Q$ENV{X11_FROM}\E/fit($ENV{X11_FROM}, $x11_to)/eg;
      s/\Q$ENV{XIM_FROM}\E/fit($ENV{XIM_FROM}, $xim_to)/eg;
    ' "$file"
  done
}
fetchDeb() {
  local debName
  local packageName=$1
  local packagePath
  if [ ! -s "$termuxPackages" ]; then
    curl -L --fail --retry 3 -o "$termuxPackages" "$termuxRepo/dists/stable/main/binary-aarch64/Packages"
  fi
  packagePath=$(awk -v p="$packageName" '
    BEGIN { RS=""; FS="\n" }
    {
      name = file = arch = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Package: /) name = substr($i, 10)
        if ($i ~ /^Architecture: /) arch = substr($i, 15)
        if ($i ~ /^Filename: /) file = substr($i, 11)
      }
      if (name == p && (arch == "aarch64" || arch == "all")) print file
    }' "$termuxPackages" | tail -n1)
  if [ -z "$packagePath" ]; then
    echo "缺少 Termux 包: $packageName" >&2
    return 1
  fi
  debName="$(basename "$packagePath")"
  if [ ! -f "$debName" ]; then
    curl -L --fail --retry 3 -C - -o "$debName" "$termuxRepo/$packagePath"
  fi
}
findLib() {
  local baseName
  local neededName=$1
  baseName=$neededName
  if [ -f "$sysLib/$neededName" ]; then
    echo "$sysLib/$neededName"
    return 0
  fi
  while [[ "$baseName" == *.so.* ]]; do
    baseName="${baseName%.*}"
    if [ -f "$sysLib/$baseName" ]; then
      echo "$sysLib/$baseName"
      return 0
    fi
  done
  return 1
}
isSystemLib() {
  case "$1" in
    libc.so|libm.so|libdl.so|liblog.so|libz.so|libandroid.so|libaaudio.so|libOpenSLES.so) return 0 ;;
    *) return 1 ;;
  esac
}
neededLibs() { "$readelf" -d "$1" | awk 'index($0, "Shared library: [") { name = $0; sub(/^.*Shared library: [[]/, "", name); sub(/[]].*$/, "", name); print name }'; }
if [ ! -d "$qvmSrc" ]; then
  $gitClone "$qvmGitUrl" "$qvmSrc"
fi
if [ ! -d "$libucontextSrc" ]; then
  $gitClone "$libucontextGitUrl" "$libucontextSrc"
fi
if [ ! -f "$prefix/lib/libucontext.a" ]; then
  pushd "$libucontextSrc"
  make clean || true
  make ARCH=aarch64 CC="$CC" AR="$AR" RANLIB="$RANLIB" FREESTANDING=yes EXPORT_UNPREFIXED=yes -j "$nCpu" libucontext.a libucontext.pc
  mkdir -p "$prefix/lib" "$prefix/lib/pkgconfig" "$prefix/include/libucontext"
  cp -f libucontext.a "$prefix/lib/"
  cp -f libucontext.pc "$prefix/lib/pkgconfig/"
  cp -f include/libucontext/libucontext.h "$prefix/include/libucontext/"
  popd
fi
if [ ! -d "$liburingSrc" ]; then
  git clone --depth 1 --branch liburing-2.8 "$liburingGitUrl" "$liburingSrc"
fi
if [ ! -f "$prefix/lib/liburing.a" ] || [ ! -f "$prefix/lib/pkgconfig/liburing.pc" ]; then
  pushd "$liburingSrc"
  make clean || true
  ./configure --prefix="$prefix" --cc="$CC" --cxx="$CXX"
  make library ENABLE_SHARED=0 -j "$nCpu"
  make install ENABLE_SHARED=0
  rm -f "$prefix/lib"/liburing.so* "$prefix/lib"/liburing-ffi.so*
  popd
fi
mkdir -p "$prefix/include/libucontext"
cat > "$prefix/include/ucontext.h" <<'EOF'
#ifndef _ANDROID_UCONTEXT_SHIM_H
#define _ANDROID_UCONTEXT_SHIM_H
#include <sys/ucontext.h>
#include <libucontext/libucontext.h>
#endif
EOF
cat > "$bitsInstalled" <<'EOF'
#ifndef LIBUCONTEXT_BITS_H
#define LIBUCONTEXT_BITS_H
#include <stddef.h>
typedef struct {
	unsigned long long fault_address;
	unsigned long long regs[31];
	unsigned long long sp;
	unsigned long long pc;
	unsigned long long pstate;
	unsigned char __reserved[4096] __attribute__((__aligned__(16)));
} libucontext_mcontext_t;
typedef struct {
	void *ss_sp;
	int ss_flags;
	size_t ss_size;
} libucontext_stack_t;
typedef struct libucontext_ucontext {
	unsigned long uc_flags;
	struct libucontext_ucontext *uc_link;
	libucontext_stack_t uc_stack;
	unsigned char __pad[136];
	libucontext_mcontext_t uc_mcontext;
} libucontext_ucontext_t;
#endif
EOF
if [ -f "$libucontextH" ] && grep -Fq 'void (*)()' "$libucontextH"; then
  perl -0pi -e 's[void [(][*][)][(][)]][void (*)(void)]g' "$libucontextH"
fi
rm -rf "$outDir"
mkdir -p "$outDir"
mkdir -p "$prefix/lib" "$prefix/bin"
{
  echo '#!/usr/bin/env bash'
  echo "export PKG_CONFIG_PATH='$prefix/lib/pkgconfig:$prefix/share/pkgconfig'"
  echo "export PKG_CONFIG_LIBDIR='$prefix/lib/pkgconfig:$prefix/share/pkgconfig'"
  echo 'exec pkg-config "$@"'
} > "$wrapPc"
chmod +x "$wrapPc"
export PKG_CONFIG="$wrapPc"
staleAlsRoot="$(printf '/data/local/tmp/%s' 'als')"
if grep -a -q "$staleAlsRoot" "$prefix/lib/libX11.so" "$prefix/lib/libxcb.so"; then
  rm -f "$prefix/lib"/libX11.so* "$prefix/lib"/libxcb.so*
fi
if [ ! -f "$prefix/lib/libX11.so" ] || [ ! -f "$prefix/lib/libandroid-shmem.so" ] || [ ! -f "$prefix/lib/libEGL_angle.so" ]; then
  mkdir -p "$buildDir/x11_tmp" && pushd "$buildDir/x11_tmp"
  fetchDeb "angle-android" "a/angle-android"
  fetchDeb "libandroid-shmem" "liba/libandroid-shmem"
  fetchDeb "libx11" "libx/libx11"
  fetchDeb "libxau" "libx/libxau"
  fetchDeb "libxcb" "libx/libxcb"
  fetchDeb "libxcursor" "libx/libxcursor"
  fetchDeb "libxdmcp" "libx/libxdmcp"
  fetchDeb "libxext" "libx/libxext"
  fetchDeb "libxfixes" "libx/libxfixes"
  fetchDeb "libxi" "libx/libxi"
  fetchDeb "libxrandr" "libx/libxrandr"
  fetchDeb "libxrender" "libx/libxrender"
  fetchDeb "xorgproto" "x/xorgproto"
  for deb in *.deb; do
    ar x "$deb"
    if [ -f data.tar.zst ]; then
      tar --zstd -xf data.tar.zst
    elif [ -f data.tar.xz ]; then
      tar -xf data.tar.xz
    fi
    rm -f "$deb" data.tar.* control.tar.* debian-binary
  done
  mkdir -p "$prefix/include" "$prefix/lib"
  for d in usr data/data/com.termux/files/usr; do
    [ -d "$d/include" ] && cp -rf "$d/include/"* "$prefix/include/"
    [ -d "$d/lib" ] && cp -rf "$d/lib/"* "$prefix/lib/"
  done
  if [ -d "data/data/com.termux/files/usr/opt/angle-android/vulkan" ]; then
    cp -Lf data/data/com.termux/files/usr/opt/angle-android/vulkan/libEGL_angle.so "$prefix/lib/libEGL.so"
    cp -Lf data/data/com.termux/files/usr/opt/angle-android/vulkan/libEGL_angle.so "$prefix/lib/libEGL_angle.so"
    cp -Lf data/data/com.termux/files/usr/opt/angle-android/vulkan/libGLESv1_CM_angle.so "$prefix/lib/libGLESv1_CM.so"
    cp -Lf data/data/com.termux/files/usr/opt/angle-android/vulkan/libGLESv2_angle.so "$prefix/lib/libGLESv2.so"
    cp -Lf data/data/com.termux/files/usr/opt/angle-android/vulkan/libGLESv1_CM_angle.so "$prefix/lib/libGLESv1_CM_angle.so"
    cp -Lf data/data/com.termux/files/usr/opt/angle-android/vulkan/libGLESv2_angle.so "$prefix/lib/libGLESv2_angle.so"
    cp -Lf data/data/com.termux/files/usr/opt/angle-android/vulkan/libfeature_support_angle.so "$prefix/lib/"
  fi
  find "$prefix/lib/pkgconfig" -name "*.pc" -type f -exec sed -i "s|/data/data/com.termux/files/usr|$prefix|g" {} +
  popd && rm -rf "$buildDir/x11_tmp"
fi
x11SocketPlaceholders "$prefix/lib/libxcb.so" "$prefix/lib/libX11.so"
buildX11PathShim
if [ ! -f "$prefix/lib/pkgconfig/epoxy.pc" ] || [ ! -f "$prefix/lib/libepoxy.so.0.0.0" ]; then
  if [ ! -d "$epoxySrc" ]; then
    git clone --depth 1 "$epoxyGitUrl" "$epoxySrc"
  fi
  writeMesonCross "$outDir/epoxy.cross"
  rm -rf "$outDir/epoxy"
  meson setup "$outDir/epoxy" "$epoxySrc" --cross-file "$outDir/epoxy.cross" --prefix "$prefix" -Ddefault_library=shared -Degl=yes -Dglx=no -Dx11=false -Dtests=false
  meson compile -C "$outDir/epoxy" -j "$nCpu"
  meson install -C "$outDir/epoxy"
fi
if [ ! -f "$prefix/lib/pkgconfig/virglrenderer.pc" ] || ! ls "$prefix/lib"/libvirglrenderer.so* >/dev/null 2>&1; then
  if [ ! -d "$virglSrc" ]; then
    git clone --depth 1 "$virglGitUrl" "$virglSrc"
  fi
  virglRendererC="$virglSrc/src/vrend/vrend_renderer.c"
  if ! grep -Fq 'clear_feature(feat_dual_src_blend);' "$virglRendererC"; then
    perl -0pi -e 's/(init_features\(gles \? 0 : gl_ver,\s*\n\s*gles \? gl_ver : 0\);\n)/$1   if (gles)\n      clear_feature(feat_dual_src_blend);\n/s' "$virglRendererC"
  fi
  perl -0pi -e 's/(if \(!surf\) \{\n)(\s*)vrend_report_context_error\(ctx, VIRGL_ERROR_CTX_ILLEGAL_SURFACE,\n\s*surf_handle\);/${1}${2}if (!surf_handle)\n${2}   return;\n${2}vrend_report_context_error(ctx, VIRGL_ERROR_CTX_ILLEGAL_SURFACE,\n${2}                           surf_handle);/s' "$virglRendererC"
  perl -0pi -e 's/\n\s*caps->v2\.capability_bits \|= VIRGL_CAP_TRANSFER;\n/\n/s; s/\n\s*caps->v2\.capability_bits \|= VIRGL_CAP_COPY_TRANSFER;\n/\n/s; s/\n\s*caps->v2\.capability_bits_v2 \|= VIRGL_CAP_V2_COPY_TRANSFER_BOTH_DIRECTIONS;\n/\n/s' "$virglRendererC"
  virglDecodeC="$virglSrc/src/vrend/vrend_decode.c"
  perl -0pi -e 's/(static int vrend_unsupported\([^{}]*\)\s*\{\s*\(void\)ctx;\s*\(void\)buf;\s*\(void\)length;\s*return )EINVAL(;)/${1}0$2/s' "$virglDecodeC"
  compatDir="$prefix/include/compat"
  mkdir -p "$compatDir/log" "$compatDir/cutils"
  cat > "$compatDir/log/log.h" <<'EOF'
#ifndef _COMPAT_LOG_LOG_H
#define _COMPAT_LOG_LOG_H
#include <android/log.h>
#ifndef LOG_PRI
#define LOG_PRI(priority, tag, ...) __android_log_print(priority, tag, __VA_ARGS__)
#endif
#endif
EOF
  cat > "$compatDir/cutils/properties.h" <<'EOF'
#ifndef _COMPAT_CUTILS_PROPERTIES_H
#define _COMPAT_CUTILS_PROPERTIES_H
#include <string.h>
#ifndef PROPERTY_VALUE_MAX
#define PROPERTY_VALUE_MAX 92
#endif
#ifndef PROPERTY_KEY_MAX
#define PROPERTY_KEY_MAX 32
#endif
static inline int property_get(const char *key, char *value, const char *def) {
    (void)key;
    if (def) {
        strncpy(value, def, PROPERTY_VALUE_MAX - 1);
        value[PROPERTY_VALUE_MAX - 1] = 0;
        return strlen(value);
    }
    *value = 0;
    return 0;
}
#endif
EOF
  writeMesonCross "$outDir/virgl.cross" ",'-I$compatDir'" ",'-llog'"
  rm -rf "$outDir/virglrenderer"
  meson setup "$outDir/virglrenderer" "$virglSrc" --cross-file "$outDir/virgl.cross" --prefix "$prefix" -Ddefault_library=shared -Dtests=false -Dcheck-gl-errors=false
  meson compile -C "$outDir/virglrenderer" -j "$nCpu"
  meson install -C "$outDir/virglrenderer"
fi
if [ ! -d "$sdlSrc" ]; then
  $gitClone --branch SDL2 https://github.com/libsdl-org/SDL.git "$sdlSrc"
fi
if [ -d "$sdlSrc" ]; then
  if git -C "$sdlSrc" rev-parse --is-inside-work-tree; then
    git -C "$sdlSrc" checkout -- CMakeLists.txt include/SDL_config_android.h src/SDL.c src/video/x11/SDL_x11opengles.c src/video/x11/SDL_x11xinput2.h
  fi
  if [ -f "$sdlConfigH" ]; then
    sed -i '/SDL_VIDEO_DRIVER_X11/d;/SDL_VIDEO_DRIVER_ANDROID/d' "$sdlConfigH"
    awk '{ print } index($0, "/* Enable various video drivers */") { print "#define SDL_VIDEO_DRIVER_X11 1" }' "$sdlConfigH" > "$sdlConfigH.tmp" && mv "$sdlConfigH.tmp" "$sdlConfigH"
    sed -i '/SDL_VIDEO_OPENGL_ES/d;/SDL_VIDEO_OPENGL_ES2/d;/SDL_VIDEO_OPENGL_EGL/d;/SDL_VIDEO_RENDER_OGL_ES/d;/SDL_VIDEO_RENDER_OGL_ES2/d' "$sdlConfigH"
  fi
  if [ -f "$sdlSrc/src/SDL.c" ]; then
    perl -0pi -e 's[if [(][!]SDL_MainIsReady[)]][if (0 && !SDL_MainIsReady)]g' "$sdlSrc/src/SDL.c"
  fi
  if [ -f "$sdlXinput2H" ]; then
    sed -i '/^#ifndef SDL_VIDEO_DRIVER_X11_SUPPORTS_GENERIC_EVENTS$/,/^#endif$/d' "$sdlXinput2H"
  fi
  if ! grep -q 'ANDROID_X11_LIBS' "$sdlSrc/CMakeLists.txt"; then
    awk -v prefix="$prefix" '
      !done && index($0, "if(ANDROID)") {
        print
        print "  link_directories(" prefix "/lib)"
        print "  set(HAVE_X11 TRUE)"
        print "  set(HAVE_SDL_VIDEO TRUE)"
        print "  set(SDL_VIDEO_DRIVER_X11 1)"
        print "  set(ANDROID_X11_LIBS X11 Xext xcb Xau Xdmcp Xrender X11-xcb android-shmem)"
        print "  file(GLOB X11_SOURCES ${SDL2_SOURCE_DIR}/src/video/x11/*.c)"
        print "  list(APPEND SOURCE_FILES ${X11_SOURCES})"
        print "  list(APPEND SOURCE_FILES ${SDL2_SOURCE_DIR}/src/core/unix/SDL_poll.c)"
        print "  foreach(_LIB ${ANDROID_X11_LIBS})"
        print "    list(APPEND EXTRA_LIBS " prefix "/lib/lib${_LIB}.so)"
        print "  endforeach()"
        done = 1
        next
      }
      { print }
    ' "$sdlSrc/CMakeLists.txt" > "$sdlSrc/CMakeLists.txt.tmp" && mv "$sdlSrc/CMakeLists.txt.tmp" "$sdlSrc/CMakeLists.txt"
  fi
fi
rm -rf "$sdlSrc/build-android"
rm -f "$prefix/lib/libSDL2.so" "$prefix/lib/pkgconfig/sdl2.pc"
mkdir -p "$sdlSrc/build-android"
pushd "$sdlSrc/build-android"
cmake .. -DCMAKE_TOOLCHAIN_FILE="$ndkPath/build/cmake/android.toolchain.cmake" -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$apiLevel -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_FIND_ROOT_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_INCLUDE_PATH="$prefix/include" -DCMAKE_LIBRARY_PATH="$prefix/lib" -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CPPFLAGS" -DCMAKE_SHARED_LINKER_FLAGS="-L$prefix/lib -landroid-shmem" -DCMAKE_EXE_LINKER_FLAGS="-L$prefix/lib -landroid-shmem" -DCMAKE_VERBOSE_MAKEFILE=ON -DSDL_STATIC=OFF -DSDL_SHARED=ON -DSDL_RENDER=ON -DSDL_X11=OFF -DSDL_X11_SHARED=OFF -DSDL_VULKAN=OFF -DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF -DSDL_ANDROID=ON -DHAVE_X11_XLIB_H=1 -DX11_X11_LIB="$prefix/lib/libX11.so" -DX11_Xext_LIB="$prefix/lib/libXext.so" -DX11_Xrender_LIB="$prefix/lib/libXrender.so"
make -j "$nCpu" install
popd
if pkg-config --exists pixman-1; then pixmanOpt="--enable-pixman"; else pixmanOpt="--disable-pixman"; fi
cd "$outDir"
"$qvmSrc/configure" --prefix="$prefix" --host-cc="$hostCC" --cross-prefix="${targetTriple}-" --cc="$CC" --cxx="$CXX" --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS -lX11 -lXext -lxcb -lXau -lXdmcp -lXrender -lX11-xcb -landroid-shmem -lEGL -lGLESv2" --with-coroutine=ucontext --disable-docs --disable-guest-agent --disable-cocoa --disable-curses --disable-capstone --disable-gnutls --disable-gcrypt --disable-plugins --disable-libusb --audio-drv-list=aaudio --disable-virtfs --disable-pie -Dtools=disabled -Dtcg=disabled -Dcoroutine_pool=false -Dvirglrenderer=enabled -Ddbus_display=disabled -Dgunyah=enabled -Dcoroutine_backend=sigaltstack -Dlinux_io_uring=enabled -Dxen=disabled -Dxen_pci_passthrough=disabled -Dmultiprocess=disabled -Dreplication=disabled -Dzstd=disabled -Dl2tpv3=disabled -Dattr=disabled "$pixmanOpt" "${displayOpts[@]}" --target-list="aarch64-softmmu"
meson="$outDir/pyvenv/bin/meson"
if [ ! -x "$meson" ]; then meson="$(command -v meson)"; fi
"$meson" compile -C "$outDir" qemu-system-aarch64 -j "$nCpu"
mkdir -p "$prefix/bin" "$prefix/share/qemu/keymaps"
cp -f "$outDir/qemu-system-aarch64" "$prefix/bin/qemu-system-aarch64"
[ -f "$qvmSrc/pc-bios/efi-virtio.rom" ] && cp -f "$qvmSrc/pc-bios/efi-virtio.rom" "$prefix/share/qemu/efi-virtio.rom"
[ -f "$qvmSrc/pc-bios/keymaps/en-us" ] && cp -f "$qvmSrc/pc-bios/keymaps/en-us" "$prefix/share/qemu/keymaps/en-us"
cd "$scriptDir"
rm -rf "$qvmDir"
mkdir -p "$qvmLib"
[ -f "$sysBin/qemu-system-aarch64" ] && $strip --strip-all "$sysBin/qemu-system-aarch64" -o "$qvmDir/qemu-system-aarch64"
patchelf --set-rpath '$ORIGIN/lib' "$qvmDir/qemu-system-aarch64" || true
collectLib "$qvmDir/qemu-system-aarch64"
for neededName in libEGL_angle.so libGLESv1_CM_angle.so libGLESv2_angle.so libfeature_support_angle.so; do
  [ -f "$sysLib/$neededName" ] && cp -Lf "$sysLib/$neededName" "$qvmLib/"
done
x11SocketPlaceholders "$qvmLib/libxcb.so" "$qvmLib/libX11.so"
cp -f "$prefix/lib/libX11-dir.so" "$qvmLib/"
if [ -d "$fwSrc" ]; then
  mkdir -p "$qvmFw/keymaps"
  [ -f "$fwSrc/efi-virtio.rom" ] && cp -a "$fwSrc/efi-virtio.rom" "$qvmFw/"
  [ -f "$fwSrc/keymaps/en-us" ] && cp -a "$fwSrc/keymaps/en-us" "$qvmFw/keymaps/"
fi
