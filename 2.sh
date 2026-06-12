#!/usr/bin/env bash
set -euo pipefail
NdkPath="$HOME/android-ndk-r30-beta1"
ApiLevel="36"
NCpu="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
BuildDir="$(pwd)/build"
Prefix="$BuildDir/sysroot"
OutDir="$BuildDir/out/qemu"
SrcDir="$BuildDir/src"
QvmGitUrl="https://github.com/AnyLaySys/qemu-gunyah.git"
QvmSrc="$SrcDir/qemu-gunyah-main"
CrosvmGitUrl="https://github.com/Droid-VM/crosvm.git"
CrosvmSrc="$SrcDir/crosvm"
GfxstreamGitUrl="https://github.com/google/gfxstream.git"
GfxstreamSrc="$SrcDir/gfxstream"
EpoxyGitUrl="https://github.com/anholt/libepoxy.git"
EpoxySrc="$SrcDir/libepoxy"
LibucontextGitUrl="https://github.com/kaniini/libucontext.git"
LibucontextSrc="$BuildDir/libucontext"
HostOS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$HostOS" in
  linux) HostTag="linux-x86_64" ;;
  darwin) HostTag="darwin-x86_64" ;;
  *) echo "Unsupported OS: $HostOS" >&2; exit 1 ;;
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
export CFLAGS="-fPIC -fvisibility=default -mbranch-protection=none -ftls-model=global-dynamic -Wno-error -I$Prefix/include -DSDL_MAIN_HANDLED -I$Prefix/include/pixman-1 -DANDROID_PLATFORM=android-${ApiLevel}"
export CPPFLAGS="$CFLAGS"
export LDFLAGS="-L$Prefix/lib -Wl,--export-dynamic -lucontext"
HostCc="${HOST_CC:-$(command -v cc || true)}"
if [ -z "$HostCc" ]; then
  exit 1
fi
ScriptDir="$(cd "$(dirname "$0")" && pwd)"
SlirpPatch="$ScriptDir/patch/slirp_android_dns.patch"
if [ ! -d "$QvmSrc" ]; then
  git clone --depth 1 "$QvmGitUrl" "$QvmSrc"
fi
QvmRutabagaC="$QvmSrc/hw/display/virtio-gpu-rutabaga.c"
QvmVirtioGpuH="$QvmSrc/include/hw/virtio/virtio-gpu.h"
if [ -f "$QvmVirtioGpuH" ] && ! grep -q 'GHashTable \*rutabaga_contexts;' "$QvmVirtioGpuH"; then
  perl -0pi -e 's/(    uint32_t num_capsets;\n    struct rutabaga \*rutabaga;)/    uint32_t num_capsets;\n    GHashTable *rutabaga_contexts;\n    struct rutabaga *rutabaga;/' "$QvmVirtioGpuH"
fi
if [ -f "$QvmRutabagaC" ]; then
  if ! grep -q '#include "system/gunyah.h"' "$QvmRutabagaC"; then
    sed -i '/#include "hw\/virtio\/virtio-iommu.h"/a #include "system/gunyah.h"' "$QvmRutabagaC"
  fi
  if ! grep -q '#include "system/gunyah_int.h"' "$QvmRutabagaC"; then
    sed -i '/#include "system\/gunyah.h"/a #include "system/gunyah_int.h"' "$QvmRutabagaC"
  fi
  sed -i '/num_capsets = virtio_gpu_rutabaga_get_num_capsets(gpudev);/,+3{/if (!num_capsets) {/,+2d}' "$QvmRutabagaC"
  if ! grep -q 'struct rutabaga_ctx_state' "$QvmRutabagaC"; then
    perl -0pi -e 's/(struct rutabaga_aio_data \{\n    struct VirtIOGPURutabaga \*vr;\n    struct rutabaga_fence fence;\n\};\n)/$1\nstruct rutabaga_ctx_state {\n    bool pending_destroy;\n    GHashTable *resources;\n};\n\nstatic void rutabaga_ctx_state_free(gpointer opaque)\n{\n    struct rutabaga_ctx_state *state = opaque;\n\n    if (state->resources) {\n        g_hash_table_destroy(state->resources);\n    }\n    g_free(state);\n}\n\nstatic GHashTable *rutabaga_contexts(VirtIOGPURutabaga *vr)\n{\n    if (!vr->rutabaga_contexts) {\n        vr->rutabaga_contexts = g_hash_table_new_full(g_direct_hash,\n                                                      g_direct_equal,\n                                                      NULL,\n                                                      rutabaga_ctx_state_free);\n    }\n    return vr->rutabaga_contexts;\n}\n\nstatic struct rutabaga_ctx_state *\nrutabaga_context_lookup(VirtIOGPURutabaga *vr, uint32_t ctx_id)\n{\n    if (!vr->rutabaga_contexts) {\n        return NULL;\n    }\n    return g_hash_table_lookup(vr->rutabaga_contexts,\n                               GUINT_TO_POINTER(ctx_id));\n}\n\nstatic struct rutabaga_ctx_state *\nrutabaga_context_insert(VirtIOGPURutabaga *vr, uint32_t ctx_id)\n{\n    struct rutabaga_ctx_state *state = g_new0(struct rutabaga_ctx_state, 1);\n\n    state->resources = g_hash_table_new(g_direct_hash, g_direct_equal);\n    g_hash_table_insert(rutabaga_contexts(vr), GUINT_TO_POINTER(ctx_id), state);\n    return state;\n}\n\nstatic void rutabaga_context_remove(VirtIOGPURutabaga *vr, uint32_t ctx_id)\n{\n    if (vr->rutabaga_contexts) {\n        g_hash_table_remove(vr->rutabaga_contexts, GUINT_TO_POINTER(ctx_id));\n    }\n}\n/' "$QvmRutabagaC"
  fi
  if ! grep -q 'rutabaga_context_insert(vr, cc.hdr.ctx_id);' "$QvmRutabagaC"; then
    perl -0pi -e 's/(    int32_t result;\n    struct virtio_gpu_ctx_create cc;\n\n    VirtIOGPURutabaga \*vr = VIRTIO_GPU_RUTABAGA\(g\);)/    int32_t result;\n    struct virtio_gpu_ctx_create cc;\n    struct rutabaga_ctx_state *state;\n\n    VirtIOGPURutabaga *vr = VIRTIO_GPU_RUTABAGA(g);/' "$QvmRutabagaC"
    perl -0pi -e 's/(    VIRTIO_GPU_FILL_CMD\(cc\);\n    trace_virtio_gpu_cmd_ctx_create\(cc\.hdr\.ctx_id,\n                                    cc\.debug_name\);\n\n)/$1    state = rutabaga_context_lookup(vr, cc.hdr.ctx_id);\n    if (state \&\& state->pending_destroy) {\n        result = rutabaga_context_destroy(vr->rutabaga, cc.hdr.ctx_id);\n        CHECK(!result, cmd);\n        rutabaga_context_remove(vr, cc.hdr.ctx_id);\n    }\n\n/' "$QvmRutabagaC"
    perl -0pi -e 's/(    result = rutabaga_context_create\(vr->rutabaga, cc\.hdr\.ctx_id,\n                                     cc\.context_init, cc\.debug_name, cc\.nlen\);\n    CHECK\(!result, cmd\);\n)/$1\n    rutabaga_context_insert(vr, cc.hdr.ctx_id);\n/' "$QvmRutabagaC"
  fi
  if ! grep -q 'state = rutabaga_context_lookup(vr, cd.hdr.ctx_id);' "$QvmRutabagaC"; then
    perl -0pi -e 's/(    int32_t result;\n    struct virtio_gpu_ctx_destroy cd;\n\n    VirtIOGPURutabaga \*vr = VIRTIO_GPU_RUTABAGA\(g\);)/    int32_t result;\n    struct virtio_gpu_ctx_destroy cd;\n    struct rutabaga_ctx_state *state;\n\n    VirtIOGPURutabaga *vr = VIRTIO_GPU_RUTABAGA(g);/' "$QvmRutabagaC"
    perl -0pi -e 's/(    VIRTIO_GPU_FILL_CMD\(cd\);\n    trace_virtio_gpu_cmd_ctx_destroy\(cd\.hdr\.ctx_id\);\n\n)(    result = rutabaga_context_destroy\(vr->rutabaga, cd\.hdr\.ctx_id\);\n    CHECK\(!result, cmd\);\n)/$1    state = rutabaga_context_lookup(vr, cd.hdr.ctx_id);\n    CHECK(state \&\& !state->pending_destroy, cmd);\n\n    state->pending_destroy = true;\n/' "$QvmRutabagaC"
  fi
  if ! grep -q 'state = rutabaga_context_lookup(vr, cs.hdr.ctx_id);' "$QvmRutabagaC"; then
    perl -0pi -e 's/(    int32_t result;\n    struct virtio_gpu_cmd_submit cs;\n    struct rutabaga_command rutabaga_cmd = \{ 0 \};\n)/$1    struct rutabaga_ctx_state *state;\n/' "$QvmRutabagaC"
    perl -0pi -e 's/(    VIRTIO_GPU_FILL_CMD\(cs\);\n    trace_virtio_gpu_cmd_ctx_submit\(cs\.hdr\.ctx_id, cs\.size\);\n\n)/$1    state = rutabaga_context_lookup(vr, cs.hdr.ctx_id);\n    CHECK(state \&\& !state->pending_destroy, cmd);\n\n/' "$QvmRutabagaC"
  fi
  if ! grep -q 'state = rutabaga_context_lookup(vr, t3d.hdr.ctx_id);' "$QvmRutabagaC"; then
    perl -0pi -e 's/(rutabaga_cmd_transfer_to_host_3d\(VirtIOGPU \*g,\n                                 struct virtio_gpu_ctrl_command \*cmd\)\n\{\n    int32_t result;\n    struct rutabaga_transfer transfer = \{ 0 \};\n    struct virtio_gpu_transfer_host_3d t3d;\n)/$1    struct rutabaga_ctx_state *state;\n/' "$QvmRutabagaC"
    perl -0pi -e 's/(rutabaga_cmd_transfer_from_host_3d\(VirtIOGPU \*g,\n                                   struct virtio_gpu_ctrl_command \*cmd\)\n\{\n    int32_t result;\n    struct rutabaga_transfer transfer = \{ 0 \};\n    struct virtio_gpu_transfer_host_3d t3d;\n)/$1    struct rutabaga_ctx_state *state;\n/' "$QvmRutabagaC"
    perl -0pi -e 's/(    VIRTIO_GPU_FILL_CMD\(t3d\);\n    trace_virtio_gpu_cmd_res_xfer_toh_3d\(t3d\.resource_id\);\n\n)/$1    state = rutabaga_context_lookup(vr, t3d.hdr.ctx_id);\n    CHECK(state \&\& !state->pending_destroy, cmd);\n\n/' "$QvmRutabagaC"
    perl -0pi -e 's/(    VIRTIO_GPU_FILL_CMD\(t3d\);\n    trace_virtio_gpu_cmd_res_xfer_fromh_3d\(t3d\.resource_id\);\n\n)/$1    state = rutabaga_context_lookup(vr, t3d.hdr.ctx_id);\n    CHECK(state \&\& !state->pending_destroy, cmd);\n\n/' "$QvmRutabagaC"
  fi
  if ! grep -q 'state = rutabaga_context_lookup(vr, att_res.hdr.ctx_id);' "$QvmRutabagaC"; then
    perl -0pi -e 's/(    int32_t result;\n    struct virtio_gpu_ctx_resource att_res;\n\n    VirtIOGPURutabaga \*vr = VIRTIO_GPU_RUTABAGA\(g\);)/    int32_t result;\n    struct virtio_gpu_ctx_resource att_res;\n    struct rutabaga_ctx_state *state;\n\n    VirtIOGPURutabaga *vr = VIRTIO_GPU_RUTABAGA(g);/' "$QvmRutabagaC"
    perl -0pi -e 's/(    trace_virtio_gpu_cmd_ctx_res_attach\(att_res\.hdr\.ctx_id,\n                                        att_res\.resource_id\);\n\n)(    result = rutabaga_context_attach_resource\(vr->rutabaga, att_res\.hdr\.ctx_id,\n                                              att_res\.resource_id\);\n    CHECK\(!result, cmd\);\n)/$1    state = rutabaga_context_lookup(vr, att_res.hdr.ctx_id);\n    CHECK(state \&\& !state->pending_destroy, cmd);\n\n$2\n    g_hash_table_add(state->resources, GUINT_TO_POINTER(att_res.resource_id));\n/' "$QvmRutabagaC"
  fi
  if ! grep -q 'state = rutabaga_context_lookup(vr, det_res.hdr.ctx_id);' "$QvmRutabagaC"; then
    perl -0pi -e 's/(    int32_t result;\n    struct virtio_gpu_ctx_resource det_res;\n\n    VirtIOGPURutabaga \*vr = VIRTIO_GPU_RUTABAGA\(g\);)/    int32_t result;\n    struct virtio_gpu_ctx_resource det_res;\n    struct rutabaga_ctx_state *state;\n\n    VirtIOGPURutabaga *vr = VIRTIO_GPU_RUTABAGA(g);/' "$QvmRutabagaC"
    perl -0pi -e 's/(    trace_virtio_gpu_cmd_ctx_res_detach\(det_res\.hdr\.ctx_id,\n                                        det_res\.resource_id\);\n\n)(    result = rutabaga_context_detach_resource\(vr->rutabaga, det_res\.hdr\.ctx_id,\n                                              det_res\.resource_id\);\n    CHECK\(!result, cmd\);\n)/$1    state = rutabaga_context_lookup(vr, det_res.hdr.ctx_id);\n    if (!state || !g_hash_table_contains(state->resources,\n                                         GUINT_TO_POINTER(det_res.resource_id))) {\n        return;\n    }\n\n$2\n    g_hash_table_remove(state->resources,\n                        GUINT_TO_POINTER(det_res.resource_id));\n\n    if (state->pending_destroy \&\& !g_hash_table_size(state->resources)) {\n        result = rutabaga_context_destroy(vr->rutabaga, det_res.hdr.ctx_id);\n        CHECK(!result, cmd);\n        rutabaga_context_remove(vr, det_res.hdr.ctx_id);\n    }\n/' "$QvmRutabagaC"
  fi
  if ! grep -q 'state = rutabaga_context_lookup(vr, cblob.hdr.ctx_id);' "$QvmRutabagaC"; then
    perl -0pi -e 's/(    struct virtio_gpu_resource_create_blob cblob;\n    struct rutabaga_create_blob rc_blob = \{ 0 \};\n\n    VirtIOGPURutabaga \*vr = VIRTIO_GPU_RUTABAGA\(g\);)/    struct virtio_gpu_resource_create_blob cblob;\n    struct rutabaga_create_blob rc_blob = { 0 };\n    struct rutabaga_ctx_state *state = NULL;\n\n    VirtIOGPURutabaga *vr = VIRTIO_GPU_RUTABAGA(g);/' "$QvmRutabagaC"
    perl -0pi -e 's/(    CHECK\(cblob\.resource_id != 0, cmd\);\n\n)/$1    if (cblob.hdr.ctx_id) {\n        state = rutabaga_context_lookup(vr, cblob.hdr.ctx_id);\n        CHECK(state \&\& !state->pending_destroy, cmd);\n    }\n\n/' "$QvmRutabagaC"
  fi
  if ! grep -q 'static void rutabaga_context_remove_resource' "$QvmRutabagaC"; then
    perl -0pi -e 's/(static void rutabaga_context_remove\(VirtIOGPURutabaga \*vr, uint32_t ctx_id\)\n\{\n    if \(vr->rutabaga_contexts\) \{\n        g_hash_table_remove\(vr->rutabaga_contexts, GUINT_TO_POINTER\(ctx_id\)\);\n    \}\n\}\n)/$1\nstatic void rutabaga_context_remove_resource(VirtIOGPURutabaga *vr,\n                                             uint32_t resource_id)\n{\n    GHashTableIter iter;\n    gpointer key;\n    gpointer value;\n    GArray *ctx_ids;\n\n    if (!vr->rutabaga_contexts) {\n        return;\n    }\n\n    ctx_ids = g_array_new(false, false, sizeof(uint32_t));\n    g_hash_table_iter_init(\&iter, vr->rutabaga_contexts);\n    while (g_hash_table_iter_next(\&iter, \&key, \&value)) {\n        struct rutabaga_ctx_state *state = value;\n        uint32_t ctx_id;\n\n        g_hash_table_remove(state->resources, GUINT_TO_POINTER(resource_id));\n        if (!state->pending_destroy || g_hash_table_size(state->resources)) {\n            continue;\n        }\n\n        ctx_id = GPOINTER_TO_UINT(key);\n        g_array_append_val(ctx_ids, ctx_id);\n    }\n\n    for (guint i = 0; i < ctx_ids->len; i++) {\n        uint32_t ctx_id = g_array_index(ctx_ids, uint32_t, i);\n\n        rutabaga_context_remove(vr, ctx_id);\n    }\n\n    g_array_free(ctx_ids, true);\n}\n/' "$QvmRutabagaC"
  fi
  if ! grep -q 'rutabaga_context_remove_resource(vr, res->resource_id);' "$QvmRutabagaC"; then
    perl -0pi -e 's/(    VirtIOGPURutabaga \*vr = VIRTIO_GPU_RUTABAGA\(g\);\n\n)(    for \(uint32_t i = 0; i < MAX_SLOTS; i\+\+\) \{)/$1    rutabaga_context_remove_resource(vr, res->resource_id);\n\n$2/' "$QvmRutabagaC"
  fi
  perl -0pi -e 's/    if \(state \&\& state->pending_destroy\) \{\n        result = rutabaga_context_destroy\(vr->rutabaga, cc\.hdr\.ctx_id\);\n        CHECK\(!result, cmd\);\n        rutabaga_context_remove\(vr, cc\.hdr\.ctx_id\);\n    \}/    if (state \&\& state->pending_destroy) {\n        rutabaga_context_remove(vr, cc.hdr.ctx_id);\n    }/' "$QvmRutabagaC"
  if ! grep -q 'result = rutabaga_context_destroy(vr->rutabaga, cd.hdr.ctx_id);' "$QvmRutabagaC"; then
    perl -0pi -e 's/    state->pending_destroy = true;\n/    result = rutabaga_context_destroy(vr->rutabaga, cd.hdr.ctx_id);\n    CHECK(!result, cmd);\n\n    state->pending_destroy = true;\n    if (!g_hash_table_size(state->resources)) {\n        rutabaga_context_remove(vr, cd.hdr.ctx_id);\n    }\n/' "$QvmRutabagaC"
  fi
  perl -0pi -e 's/    state = rutabaga_context_lookup\(vr, det_res\.hdr\.ctx_id\);\n    if \(!state \|\| !g_hash_table_contains\(state->resources,\n                                         GUINT_TO_POINTER\(det_res\.resource_id\)\)\) \{\n        return;\n    \}\n\n    result = rutabaga_context_detach_resource\(vr->rutabaga, det_res\.hdr\.ctx_id,\n                                              det_res\.resource_id\);\n    CHECK\(!result, cmd\);\n\n    g_hash_table_remove\(state->resources,\n                        GUINT_TO_POINTER\(det_res\.resource_id\)\);\n\n    if \(state->pending_destroy \&\& !g_hash_table_size\(state->resources\)\) \{\n        result = rutabaga_context_destroy\(vr->rutabaga, det_res\.hdr\.ctx_id\);\n        CHECK\(!result, cmd\);\n        rutabaga_context_remove\(vr, det_res\.hdr\.ctx_id\);\n    \}/    state = rutabaga_context_lookup(vr, det_res.hdr.ctx_id);\n    CHECK(state, cmd);\n    CHECK(g_hash_table_contains(state->resources,\n                                GUINT_TO_POINTER(det_res.resource_id)), cmd);\n\n    if (!state->pending_destroy) {\n        result = rutabaga_context_detach_resource(vr->rutabaga,\n                                                  det_res.hdr.ctx_id,\n                                                  det_res.resource_id);\n        CHECK(!result, cmd);\n    }\n\n    g_hash_table_remove(state->resources,\n                        GUINT_TO_POINTER(det_res.resource_id));\n\n    if (state->pending_destroy \&\& !g_hash_table_size(state->resources)) {\n        rutabaga_context_remove(vr, det_res.hdr.ctx_id);\n    }/' "$QvmRutabagaC"
  perl -0pi -e 's/\n    if \(state\) \{\n        g_hash_table_add\(state->resources, GUINT_TO_POINTER\(cblob\.resource_id\)\);\n    \}\n//g' "$QvmRutabagaC"
  perl -0pi -e 's/if \(i == res->scanout_bitmask\) \{/if (res->scanout_bitmask \& (1 << i)) {/g' "$QvmRutabagaC"
  perl -0pi -e 's/scanout->width = ss\.r\.width;\n    scanout->height = ss\.r\.height;\n    res->scanout_bitmask = ss\.scanout_id;/scanout->resource_id = res->resource_id;\n    scanout->x = ss.r.x;\n    scanout->y = ss.r.y;\n    scanout->width = ss.r.width;\n    scanout->height = ss.r.height;\n    res->scanout_bitmask |= (1 << ss.scanout_id);/g' "$QvmRutabagaC"
  perl -0pi -e 's/    pixman_format_code_t format;\n    uint8_t \*dst;\n    g_autofree uint8_t \*tmp = NULL;\n    int bpp;\n    int stride;/    pixman_format_code_t format;/g' "$QvmRutabagaC"
  perl -0pi -e 's/    transfer\.x = x;\n    transfer\.y = y;\n    transfer\.z = 0;\n    transfer\.w = w;\n    transfer\.h = h;\n    transfer\.d = 1;\n\n    bpp = PIXMAN_FORMAT_BPP\(pixman_image_get_format\(res->image\)\) \/ 8;\n    stride = pixman_image_get_stride\(res->image\);\n    dst = \(uint8_t \*\)pixman_image_get_data\(res->image\);\n    tmp = g_malloc\(w \* h \* bpp\);\n\n    transfer_iovec\.iov_base = tmp;\n    transfer_iovec\.iov_len = w \* h \* bpp;\n\n    result = rutabaga_resource_transfer_read\(vr->rutabaga, 0,\n                                             rf\.resource_id, &transfer,\n                                             &transfer_iovec\);\n    CHECK\(!result, cmd\);\n\n    for \(i = 0; i < h; i\+\+\) \{\n        memcpy\(dst \+ \(y \+ i\) \* stride \+ x \* bpp,\n               tmp \+ i \* w \* bpp,\n               w \* bpp\);\n    \}/    transfer.x = 0;\n    transfer.y = 0;\n    transfer.z = 0;\n    transfer.w = res->width;\n    transfer.h = res->height;\n    transfer.d = 1;\n\n    transfer_iovec.iov_base = pixman_image_get_data(res->image);\n    transfer_iovec.iov_len = pixman_image_get_stride(res->image) * res->height;\n\n    result = rutabaga_resource_transfer_read(vr->rutabaga, 0,\n                                             rf.resource_id, &transfer,\n                                             &transfer_iovec);\n    CHECK(!result, cmd);/g' "$QvmRutabagaC"
  if ! grep -q 'pixman_image_get_stride(res->image) \* res->height' "$QvmRutabagaC"; then
    perl -0pi -e 's/static void\nrutabaga_cmd_resource_flush\(VirtIOGPU \*g, struct virtio_gpu_ctrl_command \*cmd\)\n\{\n    int32_t result, i;\n    struct virtio_gpu_scanout \*scanout = NULL;\n    struct virtio_gpu_simple_resource \*res;\n    struct rutabaga_transfer transfer = \{ 0 \};\n    struct iovec transfer_iovec;\n    struct virtio_gpu_resource_flush rf;\n    bool found = false;/static void\nrutabaga_cmd_resource_flush(VirtIOGPU *g, struct virtio_gpu_ctrl_command *cmd)\n{\n    int32_t result, i;\n    struct virtio_gpu_scanout *scanout = NULL;\n    struct virtio_gpu_simple_resource *res;\n    struct rutabaga_transfer transfer = { 0 };\n    struct iovec transfer_iovec;\n    struct virtio_gpu_resource_flush rf;\n    bool found = false;\n    pixman_format_code_t format;\n    uint32_t x;\n    uint32_t y;\n    uint32_t w;\n    uint32_t h;\n    uint32_t sx;\n    uint32_t sy;\n    uint32_t ex;\n    uint32_t ey;\n    uint32_t sw;\n    uint32_t sh;/' "$QvmRutabagaC"
    perl -0pi -e 's/res = virtio_gpu_find_resource\(g, rf\.resource_id\);\n    CHECK\(res, cmd\);\n\n    for \(i = 0; i < vb->conf\.max_outputs; i\+\+\) \{/res = virtio_gpu_find_resource(g, rf.resource_id);\n    CHECK(res, cmd);\n\n    if (!res->image) {\n        format = virtio_gpu_get_pixman_format(res->format);\n        CHECK(format, cmd);\n\n        res->image = pixman_image_create_bits(format,\n                                              res->width,\n                                              res->height,\n                                              NULL, 0);\n        CHECK(res->image, cmd);\n        pixman_image_ref(res->image);\n    }\n\n    for (i = 0; i < vb->conf.max_outputs; i++) {/' "$QvmRutabagaC"
    perl -0pi -e 's/    transfer\.x = 0;\n    transfer\.y = 0;\n    transfer\.z = 0;\n    transfer\.w = res->width;\n    transfer\.h = res->height;\n    transfer\.d = 1;\n\n    transfer_iovec\.iov_base = pixman_image_get_data\(res->image\);\n    transfer_iovec\.iov_len = res->width \* res->height \* 4;\n\n    result = rutabaga_resource_transfer_read\(vr->rutabaga, 0,\n                                             rf\.resource_id, &transfer,\n                                             &transfer_iovec\);\n    CHECK\(!result, cmd\);\n    dpy_gfx_update_full\(scanout->con\);/    x = rf.r.x;\n    y = rf.r.y;\n    w = rf.r.width;\n    h = rf.r.height;\n\n    if (x >= res->width || y >= res->height || !w || !h) {\n        return;\n    }\n    if (x + w > res->width) {\n        w = res->width - x;\n    }\n    if (y + h > res->height) {\n        h = res->height - y;\n    }\n\n    transfer.x = 0;\n    transfer.y = 0;\n    transfer.z = 0;\n    transfer.w = res->width;\n    transfer.h = res->height;\n    transfer.d = 1;\n\n    transfer_iovec.iov_base = pixman_image_get_data(res->image);\n    transfer_iovec.iov_len = pixman_image_get_stride(res->image) * res->height;\n\n    result = rutabaga_resource_transfer_read(vr->rutabaga, 0,\n                                             rf.resource_id, &transfer,\n                                             &transfer_iovec);\n    CHECK(!result, cmd);\n\n    sx = MAX(x, (uint32_t)scanout->x);\n    sy = MAX(y, (uint32_t)scanout->y);\n    ex = MIN(x + w, (uint32_t)(scanout->x + scanout->width));\n    ey = MIN(y + h, (uint32_t)(scanout->y + scanout->height));\n    if (sx >= ex || sy >= ey) {\n        return;\n    }\n    sw = ex - sx;\n    sh = ey - sy;\n    if (sw && sh) {\n        dpy_gfx_update(scanout->con, sx - scanout->x, sy - scanout->y,\n                       sw, sh);\n    }/' "$QvmRutabagaC"
  fi
fi
if [ ! -d "$CrosvmSrc" ]; then
  git clone --depth 1 --branch droidvm "$CrosvmGitUrl" "$CrosvmSrc"
fi
if [ ! -d "$GfxstreamSrc" ]; then
  git clone --depth 1 --filter=blob:none "$GfxstreamGitUrl" "$GfxstreamSrc"
fi
if [ -d "$GfxstreamSrc" ]; then
  GfxCMake="$GfxstreamSrc/CMakeLists.txt"
  GfxEglCMake="$GfxstreamSrc/host/gl/glestranslator/egl/CMakeLists.txt"
  GfxCerealCMake="$GfxstreamSrc/host/vulkan/cereal/CMakeLists.txt"
  GfxVulkanCMake="$GfxstreamSrc/host/vulkan/CMakeLists.txt"
  GfxGlesDispatchCMake="$GfxstreamSrc/host/gl/OpenGLESDispatch/CMakeLists.txt"
  GfxHostCMake="$GfxstreamSrc/host/CMakeLists.txt"
  GfxBaseCMake="$GfxstreamSrc/common/base/CMakeLists.txt"
  if git -C "$GfxstreamSrc" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$GfxstreamSrc" checkout -- CMakeLists.txt common/base/CMakeLists.txt host/CMakeLists.txt host/gl/OpenGLESDispatch/CMakeLists.txt host/gl/glestranslator/egl/CMakeLists.txt host/vulkan/CMakeLists.txt host/vulkan/cereal/CMakeLists.txt
  fi
  if [ -f "$GfxCMake" ]; then
    perl -0pi -e 's/if \(APPLE\)\n    add_compile_definitions\(VK_USE_PLATFORM_MACOS_MVK\)/if (ANDROID)\n    add_compile_definitions(VK_USE_PLATFORM_ANDROID_KHR)\nelseif (APPLE)\n    add_compile_definitions(VK_USE_PLATFORM_MACOS_MVK)/' "$GfxCMake"
  fi
  if [ -f "$GfxEglCMake" ]; then
    perl -0pi -e 's/if \(APPLE\)\n    add_compile_definitions\(__APPLE__\)\nelseif\(UNIX\)\n    add_compile_definitions\(USE_X11\)\nendif\(\)/if (ANDROID)\nelseif (APPLE)\n    add_compile_definitions(__APPLE__)\nelseif(UNIX)\n    add_compile_definitions(USE_X11)\nendif()/' "$GfxEglCMake"
    perl -0pi -e 's/set\(egl-translator-android-sources\n    egl_os_api_x11\.cpp\)/set(egl-translator-android-sources\n    egl_os_api_egl.cpp)/' "$GfxEglCMake"
    perl -0pi -e 's/elseif \(QNX\)\n    add_library\(EGL_translator_static\n        \$\{egl-translator-common-sources\}\n        \$\{egl-translator-qnx-sources\}\)/elseif (QNX)\n    add_library(EGL_translator_static\n        ${egl-translator-common-sources}\n        ${egl-translator-qnx-sources})\nelseif (ANDROID)\n    add_library(EGL_translator_static\n        ${egl-translator-common-sources}\n        ${egl-translator-android-sources})/' "$GfxEglCMake"
    perl -0pi -e 's/elseif \(QNX\)\n    target_link_libraries\(EGL_translator_static PUBLIC "-lscreen -lregex -lEGL -lGLESv2"\)\nelse\(\)\n    target_link_libraries\(EGL_translator_static PUBLIC "-ldl -lpthread"\)/elseif (QNX)\n    target_link_libraries(EGL_translator_static PUBLIC "-lscreen -lregex -lEGL -lGLESv2")\nelseif (ANDROID)\n    target_link_libraries(EGL_translator_static PUBLIC "-ldl")\nelse()\n    target_link_libraries(EGL_translator_static PUBLIC "-ldl -lpthread")/' "$GfxEglCMake"
  fi
  if [ -f "$GfxBaseCMake" ]; then
    perl -0pi -e 's/elseif\(LINUX\)\n    set\(gfxstream_common_base_platform_deps\n        dl\n        rt\)/elseif(ANDROID)\n    set(gfxstream_common_base_platform_deps\n        dl)\nelseif(LINUX)\n    set(gfxstream_common_base_platform_deps\n        dl\n        rt)/' "$GfxBaseCMake"
  fi
  if [ -f "$GfxCerealCMake" ]; then
    perl -0pi -e 's/if \(WIN32\)/if (ANDROID)\n    target_compile_definitions(OpenglRender_vulkan_cereal PRIVATE -DVK_USE_PLATFORM_ANDROID_KHR)\nelseif (WIN32)/' "$GfxCerealCMake"
  fi
  if [ -f "$GfxVulkanCMake" ]; then
    perl -0pi -e 's/target_compile_definitions\(gfxstream-vulkan-server PRIVATE -DVK_USE_PLATFORM_XCB_KHR\)/if (ANDROID)\n    target_compile_definitions(gfxstream-vulkan-server PRIVATE -DVK_USE_PLATFORM_ANDROID_KHR)\nelse()\n    target_compile_definitions(gfxstream-vulkan-server PRIVATE -DVK_USE_PLATFORM_XCB_KHR)\nendif()/' "$GfxVulkanCMake"
  fi
  if [ -f "$GfxGlesDispatchCMake" ]; then
    perl -0pi -e 's/if \(APPLE\)\n    add_compile_definitions\(__APPLE__\)\nelseif\(UNIX\)\n    add_compile_definitions\(USE_X11\)\nendif\(\)/if (ANDROID)\nelseif (APPLE)\n    add_compile_definitions(__APPLE__)\nelseif(UNIX)\n    add_compile_definitions(USE_X11)\nendif()/' "$GfxGlesDispatchCMake"
  fi
  if [ -f "$GfxHostCMake" ]; then
    perl -0pi -e 's/if \(APPLE\)\n    set\(stream-server-core-platform-sources native_sub_window_cocoa\.mm\)/if (ANDROID)\n    set(stream-server-core-platform-sources native_sub_window_android.cpp)\nelseif (APPLE)\n    set(stream-server-core-platform-sources native_sub_window_cocoa.mm)/' "$GfxHostCMake"
    perl -0pi -e 's/if \(ANDROID\)\n    target_link_libraries\(gfxstream_backend PRIVATE android log\)\nendif\(\)\n\n# Suppress some warnings/# Suppress some warnings/' "$GfxHostCMake"
    perl -0pi -e 's/(target_link_libraries\(\n    gfxstream_backend\n    PUBLIC\n    gfxstream_common_utils\n    gfxstream_features\n    gfxstream_host_common\n    gfxstream_host_tracing\n    gfxstream_backend_static\n    PRIVATE\n    \)\n)/$1if (ANDROID)\n    target_link_libraries(gfxstream_backend PRIVATE android log)\nendif()\n/' "$GfxHostCMake"
  fi
fi
RutabagaFfiRs="$CrosvmSrc/rutabaga_gfx/ffi/src/lib.rs"
if [ -f "$RutabagaFfiRs" ]; then
  if git -C "$CrosvmSrc" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$CrosvmSrc" checkout -- rutabaga_gfx/ffi/src/lib.rs
  fi
  sed -i 's/ptr\.snapshot(directory)/ptr.snapshot(Path::new(directory))/g;s/ptr\.restore(directory)/ptr.restore(Path::new(directory))/g' "$RutabagaFfiRs"
  perl -0pi -e 's/(\.set_use_external_blob\(false\)\n            \.set_use_egl\(true\)\n)(            \.set_wsi\(rutabaga_wsi\))/$1            .set_use_surfaceless(matches!(rutabaga_wsi, RutabagaWsi::Surfaceless))\n$2/' "$RutabagaFfiRs"
fi
if [ ! -d "$LibucontextSrc" ]; then
  git clone --depth 1 "$LibucontextGitUrl" "$LibucontextSrc"
fi
if [ ! -f "$Prefix/lib/libucontext.a" ]; then
  pushd "$LibucontextSrc" >/dev/null
  make clean 2>/dev/null || true
  make ARCH=aarch64 CC="$CC" AR="$AR" RANLIB="$RANLIB" FREESTANDING=yes EXPORT_UNPREFIXED=yes -j "$NCpu" libucontext.a
  mkdir -p "$Prefix/lib" "$Prefix/lib/pkgconfig" "$Prefix/include/libucontext"
  cp -f libucontext.a "$Prefix/lib/"
  cp -f libucontext.pc "$Prefix/lib/pkgconfig/"
  cp -f include/libucontext/libucontext.h "$Prefix/include/libucontext/"
  popd >/dev/null
  cat > "$Prefix/include/ucontext.h" <<'EOF'
#ifndef _ANDROID_UCONTEXT_SHIM_H
#define _ANDROID_UCONTEXT_SHIM_H
#include <libucontext/libucontext.h>
#endif
EOF
fi
BitsInstalled="$Prefix/include/libucontext/bits.h"
if [ ! -f "$BitsInstalled" ]; then
  mkdir -p "$Prefix/include/libucontext"
  cat > "$BitsInstalled" <<'EOF'
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
LibucontextH="$Prefix/include/libucontext/libucontext.h"
if [ -f "$LibucontextH" ] && grep -q 'void (\*)()' "$LibucontextH"; then
  sed -i 's|void (\*)()|void (*)(void)|g' "$LibucontextH"
fi
if [ ! -d "$OutDir" ]; then
  mkdir -p "$OutDir"
fi
mkdir -p "$Prefix/lib" "$Prefix/bin"
WrapPc="$OutDir/android-pkg-config"
if [ ! -f "$WrapPc" ]; then
  cat > "$WrapPc" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_PATH="$Prefix/lib/pkgconfig:$Prefix/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$Prefix/lib/pkgconfig:$Prefix/share/pkgconfig"
exec pkg-config "\$@"
EOF
fi
chmod +x "$WrapPc"
export PKG_CONFIG="$WrapPc"
if [ ! -f "$Prefix/lib/libX11.so" ]; then
  mkdir -p "$BuildDir/x11_tmp" && pushd "$BuildDir/x11_tmp" >/dev/null
  BASE_URL="https://packages.termux.dev/apt/termux-main/pool/main"
  fetch_deb() {
    local pkg=$1
    local subpath=$2
    local url="${BASE_URL}/${subpath}/"
    local deb_name=$(curl -sL -A "Mozilla/5.0" "$url" | grep -oE "${pkg}_[^_]+_aarch64\.deb" | sort -V | tail -n1 || true)
    if [ -z "$deb_name" ]; then
      deb_name=$(curl -sL -A "Mozilla/5.0" "$url" | grep -oE "${pkg}_[^_]+_all\.deb" | sort -V | tail -n1 || true)
    fi
    if [ -n "$deb_name" ]; then
      wget -q -c "${url}${deb_name}"
    fi
  }
  fetch_deb "libx11" "libx/libx11"
  fetch_deb "libxext" "libx/libxext"
  fetch_deb "libxcb" "libx/libxcb"
  fetch_deb "libxau" "libx/libxau"
  fetch_deb "libxdmcp" "libx/libxdmcp"
  fetch_deb "libxrender" "libx/libxrender"
  fetch_deb "libxfixes" "libx/libxfixes"
  fetch_deb "libxcursor" "libx/libxcursor"
  fetch_deb "libxrandr" "libx/libxrandr"
  fetch_deb "libxi" "libx/libxi"
  fetch_deb "xorgproto" "x/xorgproto"
  for deb in *.deb; do
    ar x "$deb"
    if [ -f data.tar.zst ]; then
      tar --zstd -xf data.tar.zst
    elif [ -f data.tar.xz ]; then
      tar -xf data.tar.xz
    fi
    rm -f "$deb" data.tar.* control.tar.* debian-binary
  done
  mkdir -p "$Prefix/include" "$Prefix/lib"
  for d in usr data/data/com.termux/files/usr; do
    [ -d "$d/include" ] && cp -rf "$d/include/"* "$Prefix/include/"
    [ -d "$d/lib" ] && cp -rf "$d/lib/"* "$Prefix/lib/"
  done
  find "$Prefix/lib/pkgconfig" -name "*.pc" -type f -exec sed -i "s|/data/data/com.termux/files/usr|$Prefix|g" {} +
  popd >/dev/null && rm -rf "$BuildDir/x11_tmp"
fi
TermuxMirror="https://packages.termux.dev/apt/termux-main"
TermuxPkgIndex="$BuildDir/termux-main-Packages"
TermuxDebDir="$BuildDir/termux_debs"
TermuxRoot="$BuildDir/termux_root"
fetch_termux_pkg() {
  local pkg="$1" filename deb
  mkdir -p "$TermuxDebDir"
  if [ ! -s "$TermuxPkgIndex" ]; then
    curl -fsSL "$TermuxMirror/dists/stable/main/binary-aarch64/Packages" -o "$TermuxPkgIndex"
  fi
  filename="$(awk -v p="$pkg" 'BEGIN{RS="\n\n"} {split($1,a,":"); if ($1=="Package:" && $2==p) for (i=1;i<=NF;i++) if ($i=="Filename:") {print $(i+1); exit}}' "$TermuxPkgIndex")"
  [ -n "$filename" ] || exit 1
  deb="$TermuxDebDir/$(basename "$filename")"
  [ -f "$deb" ] || curl -fL "$TermuxMirror/$filename" -o "$deb"
  printf '%s\n' "$deb"
}
extract_termux_pkg() {
  local deb="$1" tmp="$BuildDir/termux_extract"
  rm -rf "$tmp"
  mkdir -p "$tmp" "$TermuxRoot"
  pushd "$tmp" >/dev/null
  ar x "$deb"
  if [ -f data.tar.zst ]; then
    tar --zstd -xf data.tar.zst -C "$TermuxRoot"
  elif [ -f data.tar.xz ]; then
    tar -xf data.tar.xz -C "$TermuxRoot"
  elif [ -f data.tar.gz ]; then
    tar -xzf data.tar.gz -C "$TermuxRoot"
  fi
  popd >/dev/null
  rm -rf "$tmp"
}
if [ ! -f "$Prefix/include/GL/glx.h" ] || [ ! -f "$Prefix/lib/libGL.so" ] || [ ! -f "$Prefix/lib/libGLX.so" ] || [ ! -f "$Prefix/lib/libiconv.so" ]; then
  rm -rf "$TermuxRoot"
  mkdir -p "$TermuxRoot"
  for pkg in libc++ libandroid-support libandroid-shmem libffi libiconv libexpat libxml2 libicu ncurses zlib zstd libllvm libdrm libwayland libxfixes libxshmfence libxxf86vm vulkan-loader-generic libglvnd libglvnd-dev mesa mesa-dev; do
    extract_termux_pkg "$(fetch_termux_pkg "$pkg")"
  done
  TermuxUsr="$TermuxRoot/data/data/com.termux/files/usr"
  mkdir -p "$Prefix/include" "$Prefix/lib" "$Prefix/share"
  [ -d "$TermuxUsr/include" ] && cp -rf "$TermuxUsr/include/"* "$Prefix/include/"
  [ -d "$TermuxUsr/lib" ] && cp -rf "$TermuxUsr/lib/"* "$Prefix/lib/"
  [ -d "$TermuxUsr/share" ] && cp -rf "$TermuxUsr/share/"* "$Prefix/share/"
  find "$Prefix/lib/pkgconfig" -name "*.pc" -type f -exec sed -i "s|/data/data/com.termux/files/usr|$Prefix|g" {} +
fi
if [ ! -d "$EpoxySrc" ]; then
  git clone --depth 1 "$EpoxyGitUrl" "$EpoxySrc"
fi
EpoxyDispatch="$EpoxySrc/src/dispatch_common.c"
if [ -f "$EpoxyDispatch" ]; then
  if git -C "$EpoxySrc" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$EpoxySrc" checkout -- src/dispatch_common.c
  fi
  perl -0pi -e 's/#elif defined\(__ANDROID__\)\n#define GLX_LIB "libGLESv2\.so"\n#define EGL_LIB "libEGL\.so"\n#define GLES1_LIB "libGLESv1_CM\.so"\n#define GLES2_LIB "libGLESv2\.so"/#elif defined(__ANDROID__)\n#define GLVND_GLX_LIB "libGLX.so"\n#define GLX_LIB "libGL.so"\n#define EGL_LIB "libEGL.so"\n#define GLES1_LIB "libGLESv1_CM.so"\n#define GLES2_LIB "libGLESv2.so"\n#define OPENGL_LIB "libOpenGL.so"/' "$EpoxyDispatch"
  perl -0pi -e 's/#elif defined\(__ANDROID__\)\n    \/\*\*\n     \* All symbols must be resolved through eglGetProcAddress\n     \* on Android\n     \*\/\n    int core_symbol_support = 0;/#elif defined(__ANDROID__)\n    int core_symbol_support = epoxy_current_context_is_glx() ? 12 : 0;/' "$EpoxyDispatch"
fi
EpoxyNeedsBuild=0
if ! pkg-config --exists epoxy; then
  EpoxyNeedsBuild=1
elif ! pkg-config --variable=epoxy_has_glx epoxy 2>/dev/null | grep -q '^1$'; then
  EpoxyNeedsBuild=1
elif [ ! -f "$Prefix/lib/libepoxy.so" ] || ! strings "$Prefix/lib/libepoxy.so" | grep -q 'libGLX.so'; then
  EpoxyNeedsBuild=1
fi
if [ "$EpoxyNeedsBuild" -eq 1 ]; then
  EpoxyOut="$BuildDir/out/epoxy-glx"
  EpoxyCross="$BuildDir/out/epoxy-glx.cross"
  rm -rf "$EpoxyOut"
  rm -f "$Prefix/lib/libepoxy.so" "$Prefix/lib/libepoxy.so."*
  mkdir -p "$EpoxyOut"
  cat > "$EpoxyCross" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$PKG_CONFIG'
[built-in options]
c_args = ['-fPIC','-fvisibility=default','-mbranch-protection=none','-ftls-model=global-dynamic','-Wno-error','-I$Prefix/include','-DSDL_MAIN_HANDLED','-I$Prefix/include/pixman-1','-DANDROID_PLATFORM=android-$ApiLevel']
c_link_args = ['-L$Prefix/lib']
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
  meson setup "$EpoxyOut" "$EpoxySrc" \
    --cross-file "$EpoxyCross" \
    --prefix "$Prefix" \
    -Ddefault_library=shared \
    -Degl=yes \
    -Dglx=yes \
    -Dx11=true \
    -Dtests=false
  meson compile -C "$EpoxyOut" -j "$NCpu"
  meson install -C "$EpoxyOut"
fi
if [ ! -f "$Prefix/lib/libgfxstream_backend.so" ]; then
  GfxOut="$BuildDir/out/gfxstream-android"
  rm -rf "$GfxOut"
  cmake -S "$GfxstreamSrc" -B "$GfxOut" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NdkPath/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-$ApiLevel \
    -DCMAKE_INSTALL_PREFIX="$Prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DDEPENDENCY_RESOLUTION=SYSTEM \
    -DBUILD_STANDALONE=ON \
    -DENABLE_VKCEREAL_TESTS=OFF \
    -DBUILD_GRAPHICS_DETECTOR=OFF \
    -DWITH_BENCHMARK=OFF \
    -DCMAKE_C_FLAGS="-I$GfxstreamSrc/third_party/android/include" \
    -DCMAKE_CXX_FLAGS="-I$GfxstreamSrc/third_party/android/include"
  cmake --build "$GfxOut" --target gfxstream_backend -j "$NCpu"
  if [ -f "$GfxOut/libgfxstream_backend.so" ]; then
    cp -f "$GfxOut/libgfxstream_backend.so" "$Prefix/lib/libgfxstream_backend.so"
  else
    cp -f "$GfxOut/host/libgfxstream_backend.so" "$Prefix/lib/libgfxstream_backend.so"
  fi
  cat > "$Prefix/lib/pkgconfig/gfxstream_backend.pc" <<EOF
prefix=$Prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: gfxstream_backend
Description: gfxstream backend
Version: 0
Libs: -L\${libdir} -lgfxstream_backend
Cflags:
EOF
fi
if ! pkg-config --exists rutabaga_gfx_ffi || ! "$NdkPath/toolchains/llvm/prebuilt/$HostTag/bin/llvm-readelf" -d "$Prefix/lib/librutabaga_gfx_ffi.so" 2>/dev/null | grep -q 'libgfxstream_backend.so'; then
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  Cargo="$(command -v cargo || true)"
  Rustup="$(command -v rustup || true)"
  if [ -z "$Cargo" ] || [ -z "$Rustup" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    . "$HOME/.cargo/env"
    Cargo="$(command -v cargo || true)"
    Rustup="$(command -v rustup || true)"
  fi
  if [ -z "$Cargo" ] || [ -z "$Rustup" ]; then
    exit 1
  fi
  "$Rustup" target add aarch64-linux-android
  RutabagaTarget="$BuildDir/out/rutabaga"
  rm -rf "$RutabagaTarget"
  rm -f "$Prefix/lib/librutabaga_gfx_ffi.so" "$Prefix/lib/librutabaga_gfx_ffi.so.0" "$Prefix/lib/librutabaga_gfx_ffi.so.0.1.3" "$Prefix/lib/librutabaga_gfx_ffi.a" "$Prefix/lib/pkgconfig/rutabaga_gfx_ffi.pc"
  mkdir -p "$RutabagaTarget" "$Prefix/lib" "$Prefix/lib/pkgconfig" "$Prefix/include/rutabaga_gfx"
  CARGO_TARGET_DIR="$RutabagaTarget" \
  PREFIX="$Prefix" \
  GFXSTREAM_PATH="$Prefix/lib" \
  CC_aarch64_linux_android="$CC" \
  CXX_aarch64_linux_android="$CXX" \
  AR_aarch64_linux_android="$AR" \
  CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC" \
  "$Cargo" build --manifest-path "$CrosvmSrc/rutabaga_gfx/ffi/Cargo.toml" --target aarch64-linux-android --release --features gfxstream
  cp -f "$RutabagaTarget/aarch64-linux-android/release/librutabaga_gfx_ffi.so" "$Prefix/lib/librutabaga_gfx_ffi.so.0.1.3"
  ln -sf librutabaga_gfx_ffi.so.0.1.3 "$Prefix/lib/librutabaga_gfx_ffi.so.0"
  ln -sf librutabaga_gfx_ffi.so.0 "$Prefix/lib/librutabaga_gfx_ffi.so"
  [ -f "$RutabagaTarget/aarch64-linux-android/release/librutabaga_gfx_ffi.a" ] && cp -f "$RutabagaTarget/aarch64-linux-android/release/librutabaga_gfx_ffi.a" "$Prefix/lib/"
  cp -f "$RutabagaTarget/release/rutabaga_gfx_ffi.pc" "$Prefix/lib/pkgconfig/rutabaga_gfx_ffi.pc"
  cp -f "$CrosvmSrc/rutabaga_gfx/ffi/src/include/rutabaga_gfx_ffi.h" "$Prefix/include/rutabaga_gfx/"
fi
SdlSrc="$SrcDir/SDL2"
if [ ! -d "$SdlSrc" ]; then
  git clone --depth 1 --branch SDL2 https://github.com/libsdl-org/SDL.git "$SdlSrc"
fi
if [ -d "$SdlSrc" ]; then
  if git -C "$SdlSrc" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SdlSrc" checkout -- CMakeLists.txt include/SDL_config_android.h src/SDL.c src/video/x11/SDL_x11opengles.c src/video/x11/SDL_x11xinput2.h
  fi
  SdlConfigH="$SdlSrc/include/SDL_config_android.h"
  if [ -f "$SdlConfigH" ]; then
    sed -i '/SDL_VIDEO_DRIVER_X11/d;/SDL_VIDEO_DRIVER_ANDROID/d' "$SdlConfigH"
    sed -i '/\/\* Enable various video drivers \*\//a #define SDL_VIDEO_DRIVER_X11 1' "$SdlConfigH"
    sed -i '/SDL_VIDEO_OPENGL /d;/SDL_VIDEO_OPENGL_GLX/d;/SDL_VIDEO_RENDER_OGL /d;/SDL_VIDEO_OPENGL_ES/d;/SDL_VIDEO_OPENGL_ES2/d;/SDL_VIDEO_OPENGL_EGL/d;/SDL_VIDEO_RENDER_OGL_ES/d;/SDL_VIDEO_RENDER_OGL_ES2/d' "$SdlConfigH"
    sed -i '/\/\* Enable various video drivers \*\//a #define SDL_VIDEO_RENDER_OGL 1\n#define SDL_VIDEO_OPENGL_GLX 1\n#define SDL_VIDEO_OPENGL 1' "$SdlConfigH"
  fi
  if [ -f "$SdlSrc/src/SDL.c" ]; then
    sed -i 's/if (!SDL_MainIsReady)/if (0 \&\& !SDL_MainIsReady)/g' "$SdlSrc/src/SDL.c"
  fi
  SdlXinput2H="$SdlSrc/src/video/x11/SDL_x11xinput2.h"
  if [ -f "$SdlXinput2H" ]; then
    sed -i '/^#ifndef SDL_VIDEO_DRIVER_X11_SUPPORTS_GENERIC_EVENTS$/,/^#endif$/d' "$SdlXinput2H"
  fi
  SdlX11GlesC="$SdlSrc/src/video/x11/SDL_x11opengles.c"
  if [ -f "$SdlX11GlesC" ]; then
    sed -i 's/SDL_EGL_LoadLibrary(_this, path, (NativeDisplayType) data->display, 0)/SDL_EGL_LoadLibrary(_this, path, (NativeDisplayType) data->display, EGL_PLATFORM_X11_EXT)/g' "$SdlX11GlesC"
  fi
  if ! grep -q 'ANDROID_X11_LIBS' "$SdlSrc/CMakeLists.txt"; then
    sed -i "0,/if(ANDROID)/s@if(ANDROID)@if(ANDROID)\\
  link_directories($Prefix/lib)\\
  set(HAVE_X11 TRUE)\\
  set(HAVE_SDL_VIDEO TRUE)\\
  set(SDL_VIDEO_DRIVER_X11 1)\\
  set(SDL_VIDEO_OPENGL 1)\\
  set(SDL_VIDEO_OPENGL_GLX 1)\\
  set(SDL_VIDEO_RENDER_OGL 1)\\
  set(ANDROID_X11_LIBS X11 Xext xcb Xau Xdmcp Xrender X11-xcb android-shmem GL GLX GLdispatch OpenGL)\\
  file(GLOB X11_SOURCES \${SDL2_SOURCE_DIR}/src/video/x11/*.c)\\
  list(APPEND SOURCE_FILES \${X11_SOURCES})\\
  list(APPEND SOURCE_FILES \${SDL2_SOURCE_DIR}/src/core/unix/SDL_poll.c)\\
  foreach(_LIB \${ANDROID_X11_LIBS})\\
    list(APPEND EXTRA_LIBS $Prefix/lib/lib\${_LIB}.so)\\
  endforeach()@" "$SdlSrc/CMakeLists.txt"
  fi
  sed -i 's/list(APPEND EXTRA_LIBS GLESv1_CM GLESv2)/list(APPEND EXTRA_LIBS GLESv2)/g' "$SdlSrc/CMakeLists.txt"
  sed -i '/set(SDL_VIDEO_OPENGL_EGL 1)/d;/set(SDL_VIDEO_OPENGL_ES 1)/d;/set(SDL_VIDEO_OPENGL_ES2 1)/d;/set(SDL_VIDEO_RENDER_OGL_ES 1)/d;/set(SDL_VIDEO_RENDER_OGL_ES2 1)/d;/list(APPEND EXTRA_LIBS GLESv2)/d' "$SdlSrc/CMakeLists.txt"
  sed -i 's/set(SDL_X11_DEFAULT OFF)/set(SDL_X11_DEFAULT OFF)/g' "$SdlSrc/CMakeLists.txt"
  sed -i 's/set(SDL_X11 OFF)/set(SDL_X11 OFF)/g' "$SdlSrc/CMakeLists.txt"
fi
rm -rf "$SdlSrc/build-android"
rm -f "$Prefix/lib/libSDL2.so" "$Prefix/lib/pkgconfig/sdl2.pc"
mkdir -p "$SdlSrc/build-android"
pushd "$SdlSrc/build-android" >/dev/null
cmake .. \
  -DCMAKE_TOOLCHAIN_FILE="$NdkPath/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-$ApiLevel \
  -DCMAKE_INSTALL_PREFIX="$Prefix" \
  -DCMAKE_FIND_ROOT_PATH="$Prefix" \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
  -DCMAKE_PREFIX_PATH="$Prefix" \
  -DCMAKE_INCLUDE_PATH="$Prefix/include" \
  -DCMAKE_LIBRARY_PATH="$Prefix/lib" \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CPPFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="-L$Prefix/lib" \
  -DCMAKE_EXE_LINKER_FLAGS="-L$Prefix/lib" \
  -DCMAKE_VERBOSE_MAKEFILE=ON \
  -DSDL_STATIC=OFF \
  -DSDL_SHARED=ON \
  -DSDL_X11=OFF \
  -DSDL_X11_SHARED=OFF \
  -DSDL_VULKAN=OFF \
  -DSDL_OPENGL=ON \
  -DSDL_OPENGLES=OFF \
  -DSDL_ANDROID=ON \
  -DHAVE_X11_XLIB_H=1 \
  -DX11_X11_LIB="$Prefix/lib/libX11.so" \
  -DX11_Xext_LIB="$Prefix/lib/libXext.so" \
  -DX11_Xrender_LIB="$Prefix/lib/libXrender.so"
make -j "$NCpu" install
popd >/dev/null
if pkg-config --exists pixman-1; then
  PixmanOpt="--enable-pixman"
else
  PixmanOpt="--disable-pixman"
fi
DisplayOpts=(--disable-gtk -Dgtk=disabled -Dvnc=enabled -Dvnc_jpeg=disabled -Dvnc_sasl=disabled)
if pkg-config --exists sdl2; then
  DisplayOpts+=(--enable-sdl -Dsdl=enabled -Dopengl=enabled)
else
  DisplayOpts+=(--disable-sdl -Dsdl=disabled)
fi
cd "$OutDir"
"$QvmSrc/configure" --prefix="$Prefix" --host-cc="$HostCc" --cross-prefix="${TargetTriple}-" --cc="$CC" --cxx="$CXX" --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS -lX11 -lXext -lxcb -lXau -lXdmcp -lXrender -lX11-xcb" --with-coroutine=ucontext --disable-docs --disable-guest-agent --disable-cocoa --disable-curses --disable-capstone --disable-gnutls --disable-gcrypt --disable-plugins --disable-libusb --disable-usb-redir --disable-tpm --disable-vhost-kernel --disable-vhost-net --disable-vhost-vdpa --audio-drv-list=[] --enable-slirp --disable-vhost-user --disable-virtfs -Dcoroutine_pool=false -Dopengl=enabled -Dvirglrenderer=enabled -Drutabaga_gfx=enabled -Dgunyah=enabled -Dcoroutine_backend=sigaltstack -Dwhpx=disabled -Dhvf=disabled -Dnvmm=disabled -Dxen=disabled -Dxen_pci_passthrough=disabled "$PixmanOpt" "${DisplayOpts[@]}" --target-list="aarch64-softmmu"
Meson="$OutDir/pyvenv/bin/meson"
if [ ! -x "$Meson" ]; then
  Meson="$(command -v meson)"
fi
Ninja="$(command -v ninja || true)"
if [ -f "$SlirpPatch" ] && git -C "$QvmSrc/subprojects/slirp" apply --check "$SlirpPatch" 2>/dev/null; then
  git -C "$QvmSrc/subprojects/slirp" apply "$SlirpPatch"
fi
if [ -n "$Ninja" ]; then
  "$Ninja" -C "$OutDir" -t clean qemu-system-aarch64 qemu-img >/dev/null
fi
"$Meson" compile -C "$OutDir" qemu-system-aarch64 qemu-img -j "$NCpu"
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
retagSoname() { [ -f "$1" ] && patchelf --set-soname "$(basename "$1")" "$1"; }
rn() { patchelf --replace-needed "$1" "$2" "$3" 2>/dev/null || true; }
strip_needed() { [ -f "$2" ] && patchelf --remove-needed "$1" "$2" 2>/dev/null || true; }
copyLib() { local src="$1" dst="$2"; [ -f "$src" ] && cp -Lf "$src" "$dst"; }
copyLibPattern() {
  local src base
  for src in "$SysLib"/$1; do
    [ -e "$src" ] || continue
    base="$(basename "$src")"
    case "$base" in
      libEGL.so|libEGL.so.1|libGLESv1_CM.so*|liblzma.so*|libvulkan.so) continue ;;
    esac
    cp -Lf "$src" "$QvmLib/$base"
  done
}
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
[ -f "$SysLib/libgfxstream_backend.so" ] && copyLib "$SysLib/libgfxstream_backend.so" "$QvmLib/libgfxstream_backend.so"
[ -f "$SysLib/librutabaga_gfx_ffi.so" ] && copyLib "$SysLib/librutabaga_gfx_ffi.so" "$QvmLib/librutabaga_gfx_ffi.so"
[ -f "$SysLib/libSDL2.so" ]          && copyLib "$SysLib/libSDL2.so"          "$QvmLib/libSDL2.so"
[ -f "$SysLib/libX11.so" ]           && copyLib "$SysLib/libX11.so"           "$QvmLib/libX11.so"
[ -f "$SysLib/libXext.so" ]          && copyLib "$SysLib/libXext.so"          "$QvmLib/libXext.so"
[ -f "$SysLib/libxcb.so" ]           && copyLib "$SysLib/libxcb.so"           "$QvmLib/libxcb.so"
[ -f "$SysLib/libXau.so" ]           && copyLib "$SysLib/libXau.so"           "$QvmLib/libXau.so"
[ -f "$SysLib/libXdmcp.so" ]         && copyLib "$SysLib/libXdmcp.so"         "$QvmLib/libXdmcp.so"
[ -f "$SysLib/libXrender.so" ]       && copyLib "$SysLib/libXrender.so"       "$QvmLib/libXrender.so"
[ -f "$SysLib/libX11-xcb.so" ]      && copyLib "$SysLib/libX11-xcb.so"      "$QvmLib/libX11-xcb.so"
for pat in 'libGL.so*' 'libGLX.so*' 'libGLX_mesa.so*' 'libGLdispatch.so*' 'libOpenGL.so*' 'libEGL_mesa.so*' 'libgallium-*.so' 'libgbm.so*' 'libdrm*.so*' 'libxcb*.so*' 'libandroid-shmem.so*' 'libandroid-support.so*' 'libc++_shared.so*' 'libxshmfence.so*' 'libXfixes.so*' 'libXxf86vm.so*' 'libwayland-*.so*' 'libz.so*' 'libzstd.so*' 'libLLVM*.so*' 'libncurses*.so*' 'libxml2.so*' 'libiconv.so*' 'libexpat.so*' 'libicu*.so*'; do
  copyLibPattern "$pat"
done
if [ -d "$SysLib/dri" ]; then
  mkdir -p "$QvmLib/dri"
  find "$SysLib/dri" -maxdepth 1 \( -type f -o -type l \) -name '*.so' -exec cp -Lf {} "$QvmLib/dri/" \;
fi
if [ -d "$SysLib/gbm" ]; then
  mkdir -p "$QvmLib/gbm"
  find "$SysLib/gbm" -maxdepth 1 \( -type f -o -type l \) -name '*.so' -exec cp -Lf {} "$QvmLib/gbm/" \;
fi
if [ -d "$Prefix/share/glvnd" ]; then
  mkdir -p "$QvmDir/share"
  cp -a "$Prefix/share/glvnd" "$QvmDir/share/"
fi
adb pull /system/lib64/libvulkan.so "$QvmLib/libvulkan.so.1" >/dev/null 2>&1 || true
[ -f "$SysBin/qemu-system-aarch64" ] && $Strip --strip-all "$SysBin/qemu-system-aarch64" -o "$QvmDir/qemu-system-aarch64"
[ -f "$SysBin/qemu-img" ] && $Strip --strip-all "$SysBin/qemu-img" -o "$QvmDir/qemu-img"
for so in "$QvmLib"/*.so; do retagSoname "$so"; done
strip_needed libandroid-support.so "$QvmLib/libX11.so"
strip_needed libandroid-support.so "$QvmLib/libX11-xcb.so"
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
if [ -f "$QvmLib/librutabaga_gfx_ffi.so" ]; then
  rn "$SysLib/libgfxstream_backend.so" libgfxstream_backend.so "$QvmLib/librutabaga_gfx_ffi.so"
  rn libgfxstream_backend.so libgfxstream_backend.so "$QvmLib/librutabaga_gfx_ffi.so"
fi
if [ -f "$QvmLib/libSDL2.so" ]; then
  rn libX11.so.6   libX11.so   "$QvmLib/libSDL2.so"
  rn libXext.so.6  libXext.so  "$QvmLib/libSDL2.so"
  rn libXrender.so.1 libXrender.so "$QvmLib/libSDL2.so"
  rn libX11-xcb.so.1 libX11-xcb.so "$QvmLib/libSDL2.so"
fi
[ -f "$QvmLib/libX11.so" ] && rn libxcb.so.1 libxcb.so "$QvmLib/libX11.so"
[ -f "$QvmLib/libX11-xcb.so" ] && rn libxcb.so.1 libxcb.so "$QvmLib/libX11-xcb.so"
if [ -f "$QvmLib/libxcb.so" ]; then
  rn libXau.so.6   libXau.so   "$QvmLib/libxcb.so"
  rn libXdmcp.so.6 libXdmcp.so "$QvmLib/libxcb.so"
fi
exe="$QvmDir/qemu-system-aarch64"
if [ -f "$exe" ]; then
  rn libslirp.so.0       libslirp.so       "$exe"
  rn libgio-2.0.so.0     libgio-2.0.so     "$exe"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$exe"
  rn libglib-2.0.so.0    libglib-2.0.so    "$exe"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$exe"
  rn libintl.so.8        libintl.so        "$exe"
  rn libepoxy.so.0       libepoxy.so       "$exe"
  rn libvirglrenderer.so.1 libvirglrenderer.so "$exe"
  rn "$SysLib/librutabaga_gfx_ffi.so" librutabaga_gfx_ffi.so "$exe"
  rn librutabaga_gfx_ffi.so.0 librutabaga_gfx_ffi.so "$exe"
  rn librutabaga_gfx_ffi.so.0.1.3 librutabaga_gfx_ffi.so "$exe"
  rn libSDL2-2.0.so.0    libSDL2.so        "$exe"
  rn libX11.so.6         libX11.so         "$exe"
  rn libXext.so.6        libXext.so        "$exe"
  rn libxcb.so.1         libxcb.so         "$exe"
fi
exe="$QvmDir/qemu-img"
if [ -f "$exe" ]; then
  rn libgio-2.0.so.0     libgio-2.0.so     "$exe"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$exe"
  rn libglib-2.0.so.0    libglib-2.0.so    "$exe"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$exe"
  rn libintl.so.8        libintl.so        "$exe"
fi
if [ -d "$FwSrc" ]; then
  mkdir -p "$QvmFw/keymaps"
  [ -f "$FwSrc/efi-virtio.rom" ] && cp -a "$FwSrc/efi-virtio.rom" "$QvmFw/"
  [ -f "$FwSrc/keymaps/en-us" ] && cp -a "$FwSrc/keymaps/en-us" "$QvmFw/keymaps/"
fi
Edk2Fd="$SrcDir/edk2-aarch64-gunyah/Build/ArmVirtGunyah-AArch64/RELEASE_GCC5/FV/edk2-aarch64-gunyah.fd"
if [ -f "$Edk2Fd" ]; then
  mkdir -p "$QvmFw"
  cp -Lf "$Edk2Fd" "$QvmDir/edk2-aarch64-gunyah.fd"
  cp -Lf "$Edk2Fd" "$QvmFw/edk2-aarch64-gunyah.fd"
fi
while IFS= read -r link; do
  target="$(readlink -f "$link")"
  rm -f "$link"
  cp -a "$target" "$link"
done < <(find "$QvmDir" -type l)
adb shell 'rm -rf /data/local/tmp/als/qemu-gunyah && mkdir -p /data/local/tmp/als'
adb push "$QvmDir" /data/local/tmp/als
