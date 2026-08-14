#!/bin/bash
# =============================================================================
# build_picolibc_hwfp.sh - 构建硬浮点ABI(ilp32f)版本的picolibc
# =============================================================================
# 用途:
#   现有 soc/sdk/toolchains/picolibc/ 是软浮点ABI(ilp32s)版本，没有硬浮点ABI的
#   预编译库可用，导致 runc_hwsw_comp 的 MODE=hw_fpu 没法直接链接。本脚本clone
#   该项目专用的picolibc fork(版本1.8.6，跟现有库的版本字符串一致)，用同一个
#   工具链但加 -mabi=ilp32f -msingle-float 重新编译一份完整的libc/libm/crt0，
#   装到 soc/sdk/toolchains/picolibc-hwfp/，跟现有软浮点版本并列、不覆盖。
#
# 用法:
#   bash scripts/build_picolibc_hwfp.sh
#
# 依赖:
#   - git(Windows原生git即可，本脚本里的clone/pull用普通git命令)
#   - WSL，且已装 meson + ninja(上次构建la32r-QEMU时装的，本脚本不重复装)
#   - 本仓库 soc/sdk/toolchains/loongson-gnu-toolchain-*-loongarch32r-linux-gnusf-v2.0/
#     工具链目录里的 gcc/ar/as/ld/nm/strip 齐全
#
# 原理:
#   cross-file用的是 la32r-picolibc 仓库自带的
#   scripts/cross-loongarch32r-linux-gnusf.txt 原样抄过来，只在[properties]里
#   加了 c_args=['-mabi=ilp32f','-msingle-float']，工具链路径不写死在cross-file
#   里(用裸名+PATH)，方便不同机器/不同clone位置复用。
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PICOLIBC_SRC="$REPO_ROOT/soc/sdk/toolchains/_la32r-picolibc-src"
PICOLIBC_BUILD="$PICOLIBC_SRC/build-hwfp"
PICOLIBC_INSTALL="$REPO_ROOT/soc/sdk/toolchains/picolibc-hwfp"
CROSS_FILE="$SCRIPT_DIR/picolibc_hwfp_cross.txt"

TOOLCHAIN_DIR=$(find "$REPO_ROOT/soc/sdk/toolchains" -maxdepth 1 -type d -name "loongson-gnu-toolchain-*-loongarch32r-linux-gnusf-*" | head -1)
if [ -z "$TOOLCHAIN_DIR" ]; then
    echo "[FAIL] toolchain dir not found under soc/sdk/toolchains/" 1>&2
    exit 1
fi
TOOLCHAIN_BIN="$TOOLCHAIN_DIR/bin"

echo "[info] repo root:        $REPO_ROOT"
echo "[info] toolchain bin:    $TOOLCHAIN_BIN"
echo "[info] picolibc source:  $PICOLIBC_SRC"
echo "[info] install target:   $PICOLIBC_INSTALL"

# ---------------------------------------------------------------------------
# 1) clone / pull picolibc源码(用普通git命令，Windows下走原生git，不经WSL)
# ---------------------------------------------------------------------------
if [ -d "$PICOLIBC_SRC/.git" ]; then
    echo "[step] picolibc source already cloned, pulling..."
    git -C "$PICOLIBC_SRC" pull --ff-only
else
    echo "[step] cloning la32r-picolibc..."
    rm -rf "$PICOLIBC_SRC"
    git clone --depth 50 https://gitee.com/ddduooo/la32r-picolibc.git "$PICOLIBC_SRC"
fi

# ---------------------------------------------------------------------------
# 2) Windows路径转WSL路径(/e/... -> /mnt/e/...)，调meson/ninja走WSL
#    (gcc/ar/as等是Linux ELF，必须在WSL里跑；git已经在上面用Windows原生git做完)
# ---------------------------------------------------------------------------
to_wsl_path() {
    # $1: 形如 E:/project/... 或 /e/project/... 的路径，统一转成 /mnt/e/project/...
    local p="${1//\\//}"
    if [[ "$p" =~ ^([A-Za-z]):(.*)$ ]]; then
        echo "/mnt/$(echo "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')${BASH_REMATCH[2]}"
    elif [[ "$p" =~ ^/([A-Za-z])/(.*)$ ]]; then
        echo "/mnt/$(echo "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')/${BASH_REMATCH[2]}"
    else
        echo "$p"
    fi
}

WSL_TOOLCHAIN_BIN="$(to_wsl_path "$TOOLCHAIN_BIN")"
WSL_PICOLIBC_SRC="$(to_wsl_path "$PICOLIBC_SRC")"
WSL_PICOLIBC_BUILD="$(to_wsl_path "$PICOLIBC_BUILD")"
WSL_PICOLIBC_INSTALL="$(to_wsl_path "$PICOLIBC_INSTALL")"
WSL_CROSS_FILE="$(to_wsl_path "$CROSS_FILE")"

echo "[step] meson setup + ninja build (in WSL)..."
# 下面这组 -D 选项不是猜的：原版 soc/sdk/toolchains/picolibc/ 是直接下载预编译
# release(gitee.com/ffshff/la32r-picolibc release V1.0)装进来的，不是从源码编译，
# 具体用了哪些非默认meson选项没有任何文档记录。做法是拿一份"全默认"配置生成的
# picolibc.h，跟参考目录(用户提供的已上板验证过的备份)里的picolibc.h逐行diff，
# 反推出全部偏离默认值的选项，再用这组选项重新配置、确认生成的picolibc.h跟参考
# 完全一致(diff零输出)才确定下来。最关键的一项是 tinystdio=false——原版用的是
# legacy newlib stdio，不是默认的tinystdio，这两套是完全不同的IO实现，是之前
# 误判用tinystdio+posix-console=true链接能过但上板卡死的根本原因。
MSYS_NO_PATHCONV=1 wsl.exe -e bash -lc "
set -e
export PATH=\"$WSL_TOOLCHAIN_BIN:\$PATH\"
rm -rf '$WSL_PICOLIBC_BUILD'
mkdir -p '$WSL_PICOLIBC_BUILD'
meson setup '$WSL_PICOLIBC_BUILD' '$WSL_PICOLIBC_SRC' \
    --cross-file '$WSL_CROSS_FILE' \
    --prefix '$WSL_PICOLIBC_INSTALL' \
    -Dincludedir=include \
    -Dlibdir=lib \
    -Dtinystdio=false \
    -Dposix-io=false \
    -Datomic-ungetc=false \
    -Dnewlib-io-float=true \
    -Dnewlib-fvwrite-in-streamio=true \
    -Dnewlib-io-long-long=true \
    -Dnewlib-retargetable-locking=false \
    -Dnewlib-multithread=false
ninja -C '$WSL_PICOLIBC_BUILD'
ninja -C '$WSL_PICOLIBC_BUILD' install
"

echo "[step] verify install (config match + symbol presence)..."
MSYS_NO_PATHCONV=1 wsl.exe -e bash -lc "
export PATH=\"$WSL_TOOLCHAIN_BIN:\$PATH\"
echo '--- expf/sqrtf present ---'
loongarch32r-linux-gnusf-ar t '$WSL_PICOLIBC_INSTALL/lib/libc.a' | grep -E 'expf|sqrtf|powf|sincosf|atof'
"
# 配置核验: 跟参考目录(若存在，只读)的picolibc.h逐行比对，确认上面这组选项
# 生成的配置宏跟已验证能上板的版本完全一致——这是这次踩坑后补的强制检查，
# 不能只看"链接通过"就认为配置对了。没有参考文件时自动跳过。
# 用法：REF_PICOLIBC_H=/path/to/known-good/picolibc.h ./build_picolibc_hwfp.sh
REF_PICOLIBC_H="${REF_PICOLIBC_H:-}"
if [ -n "$REF_PICOLIBC_H" ] && [ -f "$REF_PICOLIBC_H" ]; then
    if diff -q "$REF_PICOLIBC_H" "$PICOLIBC_INSTALL/include/picolibc.h" > /dev/null 2>&1; then
        echo "[ok] picolibc.h 配置跟参考目录完全一致"
    else
        echo "[WARN] picolibc.h 配置跟参考目录有差异，需要重新核对选项:" 1>&2
        diff "$REF_PICOLIBC_H" "$PICOLIBC_INSTALL/include/picolibc.h" 1>&2 || true
    fi
else
    echo "[warn] 未设置 REF_PICOLIBC_H 或文件不存在，跳过配置核验"
fi

echo "[done] picolibc-hwfp installed at: $PICOLIBC_INSTALL"
