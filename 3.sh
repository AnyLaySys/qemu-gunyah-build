#!/usr/bin/env bash
set -euo pipefail
apiLevel="36"
baseUrl="https://packages.termux.dev/apt/termux-main/pool/main"
buildDir="$(pwd)/build"
libucontextGitUrl="https://github.com/kaniini/libucontext.git"
nCpu="$(nproc || sysctl -n hw.ncpu)"
ndkPath="$HOME/android-ndk-r30-beta1"
qvmDir="qemu-gunyah"
qvmGitUrl="https://github.com/AnyLaySys/qemu-gunyah.git"
targetTriple=aarch64-linux-android
outDir="$buildDir/out/qemu"
prefix="$buildDir/sysroot"
scriptDir="$(cd "$(dirname "$0")" && pwd)"
srcDir="$buildDir/src"
bitsInstalled="$prefix/include/libucontext/bits.h"
fwSrc="$prefix/share/qemu"
libucontextH="$prefix/include/libucontext/libucontext.h"
libucontextSrc="$buildDir/libucontext"
qvmFw="$qvmDir/fw"
qvmLib="$qvmDir/lib"
qvmSrc="$srcDir/qemu-gunyah-main"
sdlConfigH="$srcDir/SDL2/include/SDL_config_android.h"
sdlSrc="$srcDir/SDL2"
sdlXinput2H="$srcDir/SDL2/src/video/x11/SDL_x11xinput2.h"
sysBin="$prefix/bin"
sysLib="$prefix/lib"
wrapPc="$outDir/android-pkg-config"
hostOs=$(uname -s | tr '[:upper:]' '[:lower:]')
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
displayOpts=(--disable-gtk -Dgtk=disabled --disable-vnc -Dvnc=disabled --enable-sdl -Dsdl=enabled -Dopengl=disabled)
export AR="$toolchain/bin/llvm-ar"
export CC="$toolchain/bin/${targetTriple}${apiLevel}-clang"
export CFLAGS="-fPIC -Os -ffunction-sections -fdata-sections -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -fmerge-all-constants -mbranch-protection=none -ftls-model=global-dynamic -Wno-error -I$prefix/include -DSDL_MAIN_HANDLED -I$prefix/include/pixman-1 -DANDROID_PLATFORM=android-${apiLevel}"
export CPPFLAGS="$CFLAGS"
export CXX="$toolchain/bin/${targetTriple}${apiLevel}-clang++"
export LD="$toolchain/bin/ld.lld"
export LDFLAGS="-L$prefix/lib -Wl,--gc-sections -Wl,--icf=all -Wl,-s -lucontext"
export NM="$toolchain/bin/llvm-nm"
export OBJCOPY="$toolchain/bin/llvm-objcopy"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
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
fetchDeb() {
  local debName
  local packageName=$1
  local packageUrl
  local subPath=$2
  packageUrl="${baseUrl}/${subPath}/"
  debName=$(curl -sL -A "Mozilla/5.0" "$packageUrl" | grep -oE "${packageName}_[^_]+_aarch64[.]deb" | sort -V | tail -n1 || true)
  if [ -z "$debName" ]; then
    debName=$(curl -sL -A "Mozilla/5.0" "$packageUrl" | grep -oE "${packageName}_[^_]+_all[.]deb" | sort -V | tail -n1 || true)
  fi
  if [ -n "$debName" ]; then
    wget -q -c "${packageUrl}${debName}"
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
    libc.so|libm.so|libdl.so|liblog.so|libz.so|libandroid.so|libaaudio.so|libOpenSLES.so|libEGL.so|libGLESv2.so) return 0 ;;
    *) return 1 ;;
  esac
}
neededLibs() { "$readelf" -d "$1" | awk 'index($0, "Shared library: [") { name = $0; sub(/^.*Shared library: [[]/, "", name); sub(/[]].*$/, "", name); print name }'; }
if [ ! -d "$qvmSrc" ]; then
  git clone --depth 1 "$qvmGitUrl" "$qvmSrc"
fi
if [ ! -d "$libucontextSrc" ]; then
  git clone --depth 1 "$libucontextGitUrl" "$libucontextSrc"
fi
if [ ! -f "$prefix/lib/libucontext.a" ]; then
  pushd "$libucontextSrc"
  make clean || true
  make ARCH=aarch64 CC="$CC" AR="$AR" RANLIB="$RANLIB" FREESTANDING=yes EXPORT_UNPREFIXED=yes -j "$nCpu" libucontext.a
  mkdir -p "$prefix/lib" "$prefix/lib/pkgconfig" "$prefix/include/libucontext"
  cp -f libucontext.a "$prefix/lib/"
  cp -f libucontext.pc "$prefix/lib/pkgconfig/"
  cp -f include/libucontext/libucontext.h "$prefix/include/libucontext/"
  popd
  cat > "$prefix/include/ucontext.h" <<'EOF'
#ifndef _ANDROID_UCONTEXT_SHIM_H
#define _ANDROID_UCONTEXT_SHIM_H
#include <libucontext/libucontext.h>
#endif
EOF
fi
if [ ! -f "$bitsInstalled" ]; then
  mkdir -p "$prefix/include/libucontext"
  cat > "$bitsInstalled" <<'EOF'
#ifndef LIBUCONTEXT_BITS_H
#define LIBUCONTEXT_BITS_H
#include <stddef.h>
typedef struct sigcontext {
	unsigned long long fault_address;
	unsigned long long regs[31];
	unsigned long long sp;
	unsigned long long pc;
	unsigned long long pstate;
	unsigned char __reserved[4096] __attribute__((__aligned__(16)));
} mcontext_t;
typedef struct {
	void *ss_sp;
	int ss_flags;
	size_t ss_size;
} libucontext_stack_t;
typedef struct libucontext_ucontext {
	unsigned long uc_flags;
	struct libucontext_ucontext *uc_link;
	libucontext_stack_t uc_stack;
	unsigned char __pad[128];
	mcontext_t uc_mcontext;
} libucontext_ucontext_t;
#endif
EOF
fi
if [ -f "$libucontextH" ] && grep -Fq 'void (*)()' "$libucontextH"; then
  perl -0pi -e 's[void [(][*][)][(][)]][void (*)(void)]g' "$libucontextH"
fi
if [ ! -d "$outDir" ]; then
  mkdir -p "$outDir"
fi
mkdir -p "$prefix/lib" "$prefix/bin"
if [ ! -f "$wrapPc" ]; then
  {
    echo '#!/usr/bin/env bash'
    echo "export PKG_CONFIG_PATH='$prefix/lib/pkgconfig:$prefix/share/pkgconfig'"
    echo "export PKG_CONFIG_LIBDIR='$prefix/lib/pkgconfig:$prefix/share/pkgconfig'"
    echo 'exec pkg-config "$@"'
  } > "$wrapPc"
fi
chmod +x "$wrapPc"
export PKG_CONFIG="$wrapPc"
if [ ! -f "$prefix/lib/libX11.so" ] || [ ! -f "$prefix/lib/libandroid-shmem.so" ]; then
  mkdir -p "$buildDir/x11_tmp" && pushd "$buildDir/x11_tmp"
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
  find "$prefix/lib/pkgconfig" -name "*.pc" -type f -exec sed -i "s|/data/data/com.termux/files/usr|$prefix|g" {} +
  popd && rm -rf "$buildDir/x11_tmp"
fi
if [ ! -d "$sdlSrc" ]; then
  git clone --depth 1 --branch SDL2 https://github.com/libsdl-org/SDL.git "$sdlSrc"
fi
if [ -d "$sdlSrc" ]; then
  if git -C "$sdlSrc" rev-parse --is-inside-work-tree; then
    git -C "$sdlSrc" checkout -- CMakeLists.txt include/SDL_config_android.h src/SDL.c src/video/x11/SDL_x11xinput2.h
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
  sed -i 's/set(ANDROID_X11_LIBS X11 Xext xcb Xau Xdmcp Xrender X11-xcb)$/set(ANDROID_X11_LIBS X11 Xext xcb Xau Xdmcp Xrender X11-xcb android-shmem)/' "$sdlSrc/CMakeLists.txt"
  sed -i 's/set(SDL_X11_DEFAULT OFF)/set(SDL_X11_DEFAULT OFF)/g' "$sdlSrc/CMakeLists.txt"
  sed -i 's/set(SDL_X11 OFF)/set(SDL_X11 OFF)/g' "$sdlSrc/CMakeLists.txt"
fi
rm -rf "$sdlSrc/build-android"
rm -f "$prefix/lib/libSDL2.so" "$prefix/lib/pkgconfig/sdl2.pc"
mkdir -p "$sdlSrc/build-android"
pushd "$sdlSrc/build-android"
cmake .. -DCMAKE_TOOLCHAIN_FILE="$ndkPath/build/cmake/android.toolchain.cmake" -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$apiLevel -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_FIND_ROOT_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_INCLUDE_PATH="$prefix/include" -DCMAKE_LIBRARY_PATH="$prefix/lib" -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CPPFLAGS" -DCMAKE_SHARED_LINKER_FLAGS="-L$prefix/lib -landroid-shmem" -DCMAKE_EXE_LINKER_FLAGS="-L$prefix/lib -landroid-shmem" -DCMAKE_VERBOSE_MAKEFILE=ON -DSDL_STATIC=OFF -DSDL_SHARED=ON -DSDL_X11=OFF -DSDL_X11_SHARED=OFF -DSDL_VULKAN=OFF -DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF -DSDL_ANDROID=ON -DHAVE_X11_XLIB_H=1 -DX11_X11_LIB="$prefix/lib/libX11.so" -DX11_Xext_LIB="$prefix/lib/libXext.so" -DX11_Xrender_LIB="$prefix/lib/libXrender.so"
make -j "$nCpu" install
popd
if pkg-config --exists pixman-1; then pixmanOpt="--enable-pixman"; else pixmanOpt="--disable-pixman"; fi
cd "$outDir"
"$qvmSrc/configure" --prefix="$prefix" --host-cc="$hostCC" --cross-prefix="${targetTriple}-" --cc="$CC" --cxx="$CXX" --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS -lX11 -lXext -lxcb -lXau -lXdmcp -lXrender -lX11-xcb -landroid-shmem" --with-coroutine=ucontext --disable-docs --disable-guest-agent --disable-cocoa --disable-curses --disable-capstone --disable-gnutls --disable-gcrypt --disable-plugins --disable-libusb --disable-usb-redir --disable-tpm --disable-vhost-kernel --disable-vhost-net --disable-vhost-vdpa --audio-drv-list=[] --enable-slirp --disable-vhost-user --disable-virtfs --disable-tcg --disable-pie -Dtcg=disabled -Dcoroutine_pool=false -Dvirglrenderer=disabled -Ddbus_display=disabled -Dgunyah=enabled -Dcoroutine_backend=sigaltstack -Dwhpx=disabled -Dhvf=disabled -Dnvmm=disabled -Dxen=disabled -Dxen_pci_passthrough=disabled -Dreplication=disabled -Dbochs=disabled -Ddmg=disabled -Dqcow1=disabled -Dvdi=disabled -Dvhdx=disabled -Dvmdk=disabled -Dvpc=disabled -Dvvfat=disabled -Dqed=disabled -Dparallels=disabled -Dzstd=disabled -Dl2tpv3=disabled -Dattr=disabled -Dhv_balloon=disabled -Dlibvduse=disabled -Dvduse_blk_export=disabled "$pixmanOpt" "${displayOpts[@]}" --target-list="aarch64-softmmu"
meson="$outDir/pyvenv/bin/meson"
if [ ! -x "$meson" ]; then meson="$(command -v meson)"; fi
ninja="$(command -v ninja || true)"
if [ -n "$ninja" ]; then "$ninja" -C "$outDir" -t clean qemu-system-aarch64 qemu-img; fi
"$meson" compile -C "$outDir" qemu-system-aarch64 qemu-img -j "$nCpu"
mkdir -p "$prefix/bin" "$prefix/share/qemu/keymaps"
cp -f "$outDir/qemu-system-aarch64" "$prefix/bin/qemu-system-aarch64"
cp -f "$outDir/qemu-img" "$prefix/bin/qemu-img"
if [ -f "$outDir/subprojects/slirp/libslirp.so.0.4.0" ]; then
  cp -Lf "$outDir/subprojects/slirp/libslirp.so.0.4.0" "$prefix/lib/libslirp.so.0.4.0"
  ln -sf libslirp.so.0.4.0 "$prefix/lib/libslirp.so.0"
  ln -sf libslirp.so.0 "$prefix/lib/libslirp.so"
fi
[ -f "$qvmSrc/pc-bios/efi-virtio.rom" ] && cp -f "$qvmSrc/pc-bios/efi-virtio.rom" "$prefix/share/qemu/efi-virtio.rom"
[ -f "$qvmSrc/pc-bios/keymaps/en-us" ] && cp -f "$qvmSrc/pc-bios/keymaps/en-us" "$prefix/share/qemu/keymaps/en-us"
cd "$scriptDir"
rm -rf "$qvmDir"
mkdir -p "$qvmLib"
[ -f "$sysBin/qemu-system-aarch64" ] && $strip --strip-all "$sysBin/qemu-system-aarch64" -o "$qvmDir/qemu-system-aarch64"
[ -f "$sysBin/qemu-img" ] && $strip --strip-all "$sysBin/qemu-img" -o "$qvmDir/qemu-img"
patchelf --set-rpath '$ORIGIN/lib' "$qvmDir/qemu-system-aarch64" "$qvmDir/qemu-img" || true
collectLib "$qvmDir/qemu-system-aarch64" "$qvmDir/qemu-img"
if [ -d "$fwSrc" ]; then
  mkdir -p "$qvmFw/keymaps"
  [ -f "$fwSrc/efi-virtio.rom" ] && cp -a "$fwSrc/efi-virtio.rom" "$qvmFw/"
  [ -f "$fwSrc/keymaps/en-us" ] && cp -a "$fwSrc/keymaps/en-us" "$qvmFw/keymaps/"
fi
# dir is $qvmdir
