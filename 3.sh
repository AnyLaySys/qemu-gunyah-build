#!/usr/bin/env bash
set -euo pipefail

# 检查必要工具
for cmd in git wget curl ar tar cmake ninja pkg-config make perl awk sed patchelf; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "错误：缺少必要工具 '$cmd'，请先安装。" >&2
        exit 1
    fi
done
# 检查 tar 是否支持 --zstd
if ! tar --version | grep -q 'zstd'; then
    echo "警告：当前 tar 不支持 --zstd，解压 Termux 包时可能失败，建议安装 GNU tar 或使用 zstd 工具。" >&2
fi

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
  echo "错误：未找到宿主 C 编译器，请设置 HOST_CC 或安装 cc" >&2
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

# ==================== 函数定义 ====================
neededLibs() { "$readelf" -d "$1" | awk 'index($0, "Shared library: [") { name = $0; sub(/^.*Shared library: [[]/, "", name); sub(/[]].*$/, "", name); print name }'; }
isSystemLib() {
  case "$1" in
    libc.so|libm.so|libdl.so|liblog.so|libz.so|libandroid.so|libaaudio.so|libOpenSLES.so|libEGL.so|libGLESv2.so) return 0 ;;
    *) return 1 ;;
  esac
}
findLib() {
  local neededName=$1
  local baseName="$neededName"
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
fetchDeb() {
  local packageName=$1
  local subPath=$2
  local packageUrl="${baseUrl}/${subPath}/"
  local debName
  debName=$(curl -sL -A "Mozilla/5.0" "$packageUrl" | grep -oE "${packageName}_[^_]+_aarch64[.]deb" | sort -V | tail -n1 || true)
  if [ -z "$debName" ]; then
    debName=$(curl -sL -A "Mozilla/5.0" "$packageUrl" | grep -oE "${packageName}_[^_]+_all[.]deb" | sort -V | tail -n1 || true)
  fi
  if [ -n "$debName" ]; then
    wget -q -c "${packageUrl}${debName}"
  else
    echo "警告：未找到软件包 $packageName 在 $packageUrl" >&2
  fi
}

# collectLib 内部定义了 copyLib，共享 pendingElfs 数组
collectLib() {
  local pendingElfs=("$@")
  local queueIndex=0
  local elfPath neededName

  copyLib() {
    local neededName=$1
    local elfPath=$2
    local destPath="$qvmLib/$neededName"
    local sourcePath
    if isSystemLib "$neededName"; then
      return 0
    fi
    if ! sourcePath="$(findLib "$neededName")"; then
      echo "缺少依赖: $neededName (从 $elfPath)" >&2
      return 1
    fi
    if [ ! -f "$destPath" ]; then
      cp -Lf "$sourcePath" "$destPath"
      patchelf --set-soname "$neededName" "$destPath" || true
      pendingElfs+=("$destPath")
    fi
  }

  while [ "$queueIndex" -lt "${#pendingElfs[@]}" ]; do
    elfPath="${pendingElfs[$queueIndex]}"
    queueIndex=$((queueIndex + 1))
    while IFS= read -r neededName; do
      [ -z "$neededName" ] && continue
      if [ "$neededName" = "libandroid-support.so" ]; then
        patchelf --remove-needed "$neededName" "$elfPath" || true
        continue
      fi
      copyLib "$neededName" "$elfPath"
    done < <(neededLibs "$elfPath")
  done
}

# ==================== 编译流程 ====================
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
  # 手动创建 libucontext.pc（原源码不提供）
  printf '%s\n' \
    "prefix=$prefix" \
    "exec_prefix=\${prefix}" \
    "libdir=\${exec_prefix}/lib" \
    "includedir=\${prefix}/include" \
    "" \
    "Name: libucontext" \
    "Description: ucontext implementation for systems that lack it" \
    "Version: 1.2" \
    "Requires:" \
    "Libs: -L\${libdir} -lucontext" \
    "Cflags: -I\${includedir}" > "$prefix/lib/pkgconfig/libucontext.pc"
  cp -f include/libucontext/libucontext.h "$prefix/include/libucontext/"
  popd
  printf '%s\n' \
    "#ifndef _ANDROID_UCONTEXT_SHIM_H" \
    "#define _ANDROID_UCONTEXT_SHIM_H" \
    "#include <libucontext/libucontext.h>" \
    "#endif" > "$prefix/include/ucontext.h"
fi

if [ ! -f "$bitsInstalled" ]; then
  mkdir -p "$prefix/include/libucontext"
  printf '%s\n' \
    "#ifndef LIBUCONTEXT_BITS_H" \
    "#define LIBUCONTEXT_BITS_H" \
    "#include <stddef.h>" \
    "typedef struct sigcontext {" \
    "	unsigned long long fault_address;" \
    "	unsigned long long regs[31];" \
    "	unsigned long long sp;" \
    "	unsigned long long pc;" \
    "	unsigned long long pstate;" \
    "	unsigned char __reserved[4096] __attribute__((__aligned__(16)));" \
    "} mcontext_t;" \
    "typedef struct {" \
    "	void *ss_sp;" \
    "	int ss_fla
