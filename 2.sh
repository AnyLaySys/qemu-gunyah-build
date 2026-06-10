#!/usr/bin/env bash
set -euo pipefail
NdkPath="$HOME/android-ndk-r30-beta1"
ApiLevel="36"
NCpu="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
BuildDir="$(pwd)/build"
Prefix="$BuildDir/sysroot"
OutDir="$BuildDir/out/qemu"
SrcDir="$BuildDir/src"
QvmVersion="master"
QvmGitUrl="https://github.com/AnyLaySys/qemu-gunyah.git"
QvmGitRef="master"
QvmSrc="$SrcDir/qemu-gunyah-${QvmVersion}"
LibucontextGitUrl="https://github.com/kaniini/libucontext.git"
LibucontextSrc="$BuildDir/libucontext"
HostOS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$HostOS" in
  linux)   HostTag="linux-x86_64" ;;
  darwin)  HostTag="darwin-x86_64" ;;
  *) echo "不支持此系统: $HostOS" >&2; exit 1 ;;
esac
Toolchain="$NdkPath/toolchains/llvm/prebuilt/$HostTag"
TargetTriple=aarch64-linux-android
export CC="$Toolchain/bin/${TargetTriple}${ApiLevel}-clang"
export CXX="$Toolchain/bin/${TargetTriple}${ApiLevel}-clang++"
export AR="$Toolchain/bin/llvm-ar"
export NM="$Toolchain/bin/llvm-nm"
export RANLIB="$Toolchain/bin/llvm-ranlib"
export STRIP="$Toolchain/bin/llvm-strip"
export OBJCOPY="$Toolchain/bin/llvm-objcopy"
export LD="$Toolchain/bin/ld.lld"
export PKG_CONFIG_PATH="$Prefix/lib/pkgconfig:$Prefix/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$Prefix/lib/pkgconfig:$Prefix/share/pkgconfig"
export CFLAGS="-fPIC -fvisibility=default -mbranch-protection=none -ftls-model=global-dynamic -Wno-error -I$Prefix/include -DSDL_MAIN_HANDLED -I$Prefix/include/pixman-1 -DANDROID_PLATFORM="android-${ApiLevel}" "
export CPPFLAGS="$CFLAGS"
export LDFLAGS="-L$Prefix/lib -Wl,--export-dynamic -lucontext -lEGL -lGLESv2"
HostCc="${HOST_CC:-$(command -v cc || true)}"
if [ -z "$HostCc" ]; then
  echo "未找到本地 C 编译器" >&2
  exit 1
fi
ScriptDir="$(cd "$(dirname "$0")" && pwd)"
SlirpPatch="$ScriptDir/patch/slirp_android_dns.patch"
EglPatch="$ScriptDir/patch/qemu_android_egl.patch"
if [ ! -d "$QvmSrc" ]; then
  echo "克隆 QEMU 源码 ($QvmGitUrl) ref=$QvmGitRef 到 $QvmSrc"
  git clone --depth 1 --branch "$QvmGitRef" "$QvmGitUrl" "$QvmSrc"
else
  echo "使用已有的 QEMU 源码目录: $QvmSrc"
fi
if [ -f "$EglPatch" ]; then
  echo "应用 Android EGL 补丁"
  if git -C "$QvmSrc" apply --check "$EglPatch" 2>/dev/null; then
    git -C "$QvmSrc" apply "$EglPatch"
    echo "Android EGL 补丁应用成功"
  else
    echo "Android EGL 补丁已存在或不需要，跳过"
  fi
fi
if [ ! -d "$LibucontextSrc" ]; then
  echo "克隆 libucontext"
  git clone --depth 1 "$LibucontextGitUrl" "$LibucontextSrc"
fi
if [ ! -f "$Prefix/lib/libucontext.a" ]; then
  echo "编译 libucontext for Android aarch64"
  pushd "$LibucontextSrc" >/dev/null
  make clean 2>/dev/null || true
  make ARCH=aarch64 CC="$CC" AR="$AR" RANLIB="$RANLIB" FREESTANDING=yes EXPORT_UNPREFIXED=yes -j "$NCpu" libucontext.a
  mkdir -p "$Prefix/lib" "$Prefix/lib/pkgconfig" "$Prefix/include/libucontext"
  cp -f libucontext.a "$Prefix/lib/"
  cp -f libucontext.pc "$Prefix/lib/pkgconfig/" 2>/dev/null || true
  cp -f include/libucontext/libucontext.h "$Prefix/include/libucontext/" 2>/dev/null || true
  popd >/dev/null
  echo "创建 ucontext.h 兼容头文件到 $Prefix/include"
  cat > "$Prefix/include/ucontext.h" <<'UCONTEXT_SHIM'
#ifndef _ANDROID_UCONTEXT_SHIM_H
#define _ANDROID_UCONTEXT_SHIM_H
#include <libucontext/libucontext.h>
#endif
UCONTEXT_SHIM
  echo "libucontext 已安装"
else
  echo "libucontext 已存在，跳过"
fi
BitsInstalled="$Prefix/include/libucontext/bits.h"
if [ ! -f "$BitsInstalled" ]; then
  mkdir -p "$Prefix/include/libucontext"
  echo "生成 freestanding bits.h for aarch64"
  cat > "$BitsInstalled" <<'GEN_BITS_H'
#ifndef LIBUCONTEXT_BITS_H
#define LIBUCONTEXT_BITS_H
#include <stddef.h>
#ifndef _UAPI__ASM_SIGCONTEXT_H
typedef struct sigcontext {
	unsigned long long fault_address;
	unsigned long long regs[31];
	unsigned long long sp;
	unsigned long long pc;
	unsigned long long pstate;
	unsigned char __reserved[4096] __attribute__((__aligned__(16)));
} mcontext_t;
#else
typedef struct sigcontext mcontext_t;
#endif
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
GEN_BITS_H
  echo "bits.h 生成完毕"
else
  echo "bits.h 已存在，跳过"
fi
LibucontextH="$Prefix/include/libucontext/libucontext.h"
if [ -f "$LibucontextH" ] && grep -q 'void (\*)()' "$LibucontextH" && [ -w "$LibucontextH" ]; then
  echo "修复 libucontext.h 函数原型"
  sed -i.bak 's|void (\*)()|void (*)(void)|g' "$LibucontextH"
  rm -f "$LibucontextH.bak"
  echo "libucontext.h 已修复"
elif [ -f "$LibucontextH" ] && grep -q 'void (\*)()' "$LibucontextH"; then
  echo "libucontext.h 需要修复，但文件是只读的，跳过"
else
  echo "libucontext.h 已正常，不需要修复"
fi
if [ -d "$OutDir" ]; then
  echo "尝试清理输出目录 $OutDir"
  rm -rf "$OutDir" 2>/dev/null || true
fi
if [ ! -d "$OutDir" ]; then
  mkdir -p "$OutDir"
else
  echo "输出目录已存在，继续使用"
fi
mkdir -p "$Prefix/lib" "$Prefix/bin"
WrapPc="$OutDir/android-pkg-config"
if [ ! -f "$WrapPc" ]; then
  TempWrapPc="$(mktemp -t android-pkg-config.XXXXXXXXXX)"
  cat > "$TempWrapPc" <<'EOF'
#!/usr/bin/env bash
exec pkg-config "$@"
EOF
  chmod +x "$TempWrapPc"
  cp -f "$TempWrapPc" "$WrapPc" 2>/dev/null || true
  rm -f "$TempWrapPc"
  if [ -f "$WrapPc" ]; then
    export PKG_CONFIG="$WrapPc"
  else
    echo "无法创建 android-pkg-config，将使用系统 pkg-config"
    export PKG_CONFIG="pkg-config"
  fi
else
  echo "android-pkg-config 已存在"
  export PKG_CONFIG="$WrapPc"
fi
echo "pkg-config 检查 (Android 交叉编译依赖在 $Prefix)"
for lib in glib-2.0 pixman-1 epoxy virglrenderer sdl2 x11 gtk+-3.0 gtk+-x11-3.0; do
  echo "$lib: $(pkg-config --modversion $lib 2>/dev/null || echo '未找到')"
done
if pkg-config --exists pixman-1; then
  PixmanOpt="--enable-pixman"
else
  PixmanOpt="--disable-pixman"
fi
DisplayOpts=(--disable-gtk -Dgtk=disabled -Dvnc=enabled -Dvnc_jpeg=disabled -Dvnc_sasl=disabled)
if pkg-config --exists sdl2 x11; then
  DisplayOpts+=(--enable-sdl -Dsdl=enabled)
else
  DisplayOpts+=(--disable-sdl -Dsdl=disabled)
fi
cd "$OutDir"
"$QvmSrc/configure" --prefix="$Prefix" --host-cc="$HostCc" --cross-prefix="${TargetTriple}-" --cc="$CC" --cxx="$CXX" --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" --with-coroutine=ucontext --disable-docs --disable-guest-agent --disable-cocoa --disable-curses --disable-capstone --disable-gnutls --disable-gcrypt --disable-plugins --disable-libusb --disable-usb-redir --disable-tpm --disable-vhost-kernel --disable-vhost-net --disable-vhost-vdpa --audio-drv-list=[] --enable-slirp --disable-vhost-user --disable-virtfs -Dcoroutine_pool=false -Dopengl=enabled -Dvirglrenderer=enabled -Dgunyah=enabled -Dcoroutine_backend=sigaltstack -Dwhpx=disabled -Dhvf=disabled -Dnvmm=disabled -Dxen=disabled -Dxen_pci_passthrough=disabled "$PixmanOpt" "${DisplayOpts[@]}" --target-list="aarch64-softmmu"
Meson="$OutDir/pyvenv/bin/meson"
if [ ! -x "$Meson" ]; then
  Meson="$(command -v meson)"
fi
if [ ! -x "$Meson" ]; then
  echo "未找到 meson" >&2
  exit 1
fi
if [ -f "$SlirpPatch" ]; then
  echo "应用 SLIRP Android DNS 补丁"
  if git -C "$QvmSrc/subprojects/slirp" apply --check "$SlirpPatch" 2>/dev/null; then
    git -C "$QvmSrc/subprojects/slirp" apply "$SlirpPatch"
    echo "SLIRP 补丁应用成功"
  else
    echo "SLIRP 补丁已存在或不需要，跳过"
  fi
fi
"$Meson" compile -C "$OutDir" \
  qemu-system-aarch64 \
  qemu-img \
  -j "$NCpu"
mkdir -p "$Prefix/bin" "$Prefix/share/qemu/keymaps"
cp -f "$OutDir/qemu-system-aarch64" "$Prefix/bin/qemu-system-aarch64"
cp -f "$OutDir/qemu-img" "$Prefix/bin/qemu-img"
if [ -f "$OutDir/subprojects/slirp/libslirp.so.0.4.0" ]; then
  cp -Lf "$OutDir/subprojects/slirp/libslirp.so.0.4.0" "$Prefix/lib/libslirp.so.0.4.0"
  ln -sf libslirp.so.0.4.0 "$Prefix/lib/libslirp.so.0"
  ln -sf libslirp.so.0 "$Prefix/lib/libslirp.so"
fi
[ -f "$QvmSrc/pc-bios/efi-virtio.rom" ] && cp -f "$QvmSrc/pc-bios/efi-virtio.rom" "$Prefix/share/qemu/efi-virtio.rom"
[ -f "$QvmSrc/pc-bios/keymaps/en-us" ] && cp -f "$QvmSrc/pc-bios/keymaps/en-us" "$Prefix/share/qemu/keymaps/en-us"
echo "编译安装完成"
echo "二进制文件安装到: $Prefix/bin"
ls -l "$Prefix/bin"/qemu-system-* 2>/dev/null || true
ls -l "$Prefix/bin"/qemu-img 2>/dev/null || true
cd "$ScriptDir"
SysLib="$Prefix/lib"
SysBin="$Prefix/bin"
QvmDir="qemu-gunyah"
QvmLib="$QvmDir/lib"
FwSrc="$Prefix/share/qemu"
QvmFw="$QvmDir/fw"
Readelf="$NdkPath/toolchains/llvm/prebuilt/$HostTag/bin/llvm-readelf"
Strip="$NdkPath/toolchains/llvm/prebuilt/$HostTag/bin/llvm-strip"
rm -rf "$QvmDir"
mkdir -p "$QvmLib"
command -v patchelf >/dev/null 2>&1 || { echo "需要 patchelf" >&2; exit 1; }
need() { [ -f "$1" ] || { echo "缺少: $1" >&2; exit 1; }; }
retagSoname() { [ -f "$1" ] && patchelf --set-soname "$(basename "$1")" "$1"; }
rn() { patchelf --replace-needed "$1" "$2" "$3" 2>/dev/null || true; }
copyLib() { local src="$1" dst="$2"; need "$src"; cp -Lf "$src" "$dst"; }
copyLib "$SysLib/libgio-2.0.so.0"     "$QvmLib/libgio-2.0.so"
copyLib "$SysLib/libgobject-2.0.so.0" "$QvmLib/libgobject-2.0.so"
copyLib "$SysLib/libglib-2.0.so.0"    "$QvmLib/libglib-2.0.so"
copyLib "$SysLib/libgmodule-2.0.so.0" "$QvmLib/libgmodule-2.0.so"
copyLib "$SysLib/libintl.so.8"        "$QvmLib/libintl.so"
copyLib "$SysLib/libpcre2-8.so"       "$QvmLib/libpcre2-8.so"
copyLib "$SysLib/libslirp.so.0"       "$QvmLib/libslirp.so"
copyLib "$SysLib/libpixman-1.so"      "$QvmLib/libpixman-1.so"
[ -f "$SysLib/libgthread-2.0.so.0" ] && copyLib "$SysLib/libgthread-2.0.so.0" "$QvmLib/libgthread-2.0.so"
[ -f "$SysLib/libffi.so" ]           && copyLib "$SysLib/libffi.so"           "$QvmLib/libffi.so"
[ -f "$SysLib/libepoxy.so" ]         && copyLib "$SysLib/libepoxy.so"         "$QvmLib/libepoxy.so"
[ -f "$SysLib/libvirglrenderer.so" ] && copyLib "$SysLib/libvirglrenderer.so" "$QvmLib/libvirglrenderer.so"
[ -f "$SysLib/libSDL2.so" ]          && copyLib "$SysLib/libSDL2.so"          "$QvmLib/libSDL2.so"
[ -f "$SysLib/libX11.so" ]           && copyLib "$SysLib/libX11.so"           "$QvmLib/libX11.so"
[ -f "$SysLib/libXext.so" ]          && copyLib "$SysLib/libXext.so"          "$QvmLib/libXext.so"
[ -f "$SysLib/libxcb.so" ]           && copyLib "$SysLib/libxcb.so"           "$QvmLib/libxcb.so"
[ -f "$SysLib/libXau.so" ]           && copyLib "$SysLib/libXau.so"           "$QvmLib/libXau.so"
[ -f "$SysLib/libXdmcp.so" ]         && copyLib "$SysLib/libXdmcp.so"         "$QvmLib/libXdmcp.so"
exe="$SysBin/qemu-system-aarch64"
if [ -f "$exe" ]; then
  $Strip --strip-all "$exe" -o "$QvmDir/qemu-system-aarch64"
else
  echo "跳过缺失 $exe"
fi
exe="$SysBin/qemu-img"
if [ -f "$exe" ]; then
  $Strip --strip-all "$exe" -o "$QvmDir/qemu-img"
else
  echo "跳过缺失 $exe"
fi
for so in "$QvmLib"/*.so; do
  retagSoname "$so"
done
rn libglib-2.0.so.0    libglib-2.0.so    "$QvmLib/libgio-2.0.so"
rn libgobject-2.0.so.0 libgobject-2.0.so "$QvmLib/libgio-2.0.so"
rn libgmodule-2.0.so.0 libgmodule-2.0.so "$QvmLib/libgio-2.0.so"
rn libintl.so.8        libintl.so        "$QvmLib/libgio-2.0.so"
rn libglib-2.0.so.0    libglib-2.0.so    "$QvmLib/libgobject-2.0.so"
rn libintl.so.8        libintl.so        "$QvmLib/libgobject-2.0.so"
rn libglib-2.0.so.0    libglib-2.0.so    "$QvmLib/libgmodule-2.0.so"
rn libintl.so.8        libintl.so        "$QvmLib/libglib-2.0.so"
rn libglib-2.0.so.0    libglib-2.0.so    "$QvmLib/libslirp.so"
rn libintl.so.8        libintl.so        "$QvmLib/libslirp.so"
if [ -f "$QvmLib/libvirglrenderer.so" ]; then
  rn libepoxy.so.0       libepoxy.so       "$QvmLib/libvirglrenderer.so"
  rn libglib-2.0.so.0    libglib-2.0.so    "$QvmLib/libvirglrenderer.so"
  rn libintl.so.8        libintl.so        "$QvmLib/libvirglrenderer.so"
fi
if [ -f "$QvmLib/libSDL2.so" ]; then
  rn libX11.so.6   libX11.so   "$QvmLib/libSDL2.so"
  rn libXext.so.6  libXext.so  "$QvmLib/libSDL2.so"
fi
if [ -f "$QvmLib/libX11.so" ]; then
  rn libxcb.so.1 libxcb.so "$QvmLib/libX11.so"
fi
if [ -f "$QvmLib/libxcb.so" ]; then
  rn libXau.so.6   libXau.so   "$QvmLib/libxcb.so"
  rn libXdmcp.so.6 libXdmcp.so "$QvmLib/libxcb.so"
fi
exe="$QvmDir/qemu-system-aarch64"
if [ -f "$exe" ]; then
  echo "修补 NEEDED 条目 $(basename "$exe")"
  rn libslirp.so.0       libslirp.so       "$exe"
  rn libgio-2.0.so.0     libgio-2.0.so     "$exe"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$exe"
  rn libglib-2.0.so.0    libglib-2.0.so    "$exe"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$exe"
  rn libintl.so.8        libintl.so        "$exe"
  rn libepoxy.so.0       libepoxy.so       "$exe"
  rn libvirglrenderer.so.1 libvirglrenderer.so "$exe"
  rn libSDL2-2.0.so.0    libSDL2.so        "$exe"
  rn libX11.so.6         libX11.so         "$exe"
  rn libXext.so.6        libXext.so        "$exe"
  rn libxcb.so.1         libxcb.so         "$exe"
fi
exe="$QvmDir/qemu-img"
if [ -f "$exe" ]; then
  echo "修补 NEEDED 条目 $(basename "$exe")"
  rn libgio-2.0.so.0     libgio-2.0.so     "$exe"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$exe"
  rn libglib-2.0.so.0    libglib-2.0.so    "$exe"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$exe"
  rn libintl.so.8        libintl.so        "$exe"
fi
for so in "$QvmLib"/*.so; do
  basename "$so"
  $Readelf -d "$so" | grep -E 'SONAME|NEEDED' || true
done
for exe in "$QvmDir"/qemu-system-* "$QvmDir"/qemu-img; do
  [ -f "$exe" ] || continue
  basename "$exe"
  $Readelf -d "$exe" | grep -E 'NEEDED' || true
done
if [ -d "$FwSrc" ]; then
  echo "复制固件从 $FwSrc 至 $QvmFw"
  mkdir -p "$QvmFw/keymaps"
  [ -f "$FwSrc/efi-virtio.rom" ]   && cp -a "$FwSrc/efi-virtio.rom"   "$QvmFw/"
  [ -f "$FwSrc/keymaps/en-us" ]    && cp -a "$FwSrc/keymaps/en-us"    "$QvmFw/keymaps/"
  echo "固件已复制至 $QvmFw"
fi
echo "产物已存至 $QvmDir"
adb push "$QvmDir" /data/local/tmp/als
