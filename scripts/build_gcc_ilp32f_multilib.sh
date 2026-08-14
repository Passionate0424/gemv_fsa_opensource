#!/bin/bash
# =============================================================================
# build_gcc_ilp32f_multilib.sh - 重新构建支持ilp32s+ilp32f双ABI的GCC交叉编译器
# =============================================================================
# 用途:
#   现有 soc/sdk/toolchains/loongson-gnu-toolchain-8.3-...-v2.0/ 是龙芯官方预编译
#   发布包，configure时只选了--with-abi=ilp32s、没开--enable-multilib，所以只打包
#   了一份ilp32s(软浮点)版libgcc.a。当应用代码用-mabi=ilp32f编译时，GCC前端能正确
#   生成硬件浮点指令，但链接阶段找不到ilp32f版libgcc.a——实测会先打印
#   "ABI 'ilp32f' is not enabled at configure-time"警告，然后直接Segmentation fault。
#
#   本脚本用龙芯官方GCC 8.3源码(原生支持ilp32d/ilp32f/ilp32s三种ABI)+配套binutils，
#   重新configure+build一遍，加--enable-multilib --with-multilib-list=ilp32s/base,
#   ilp32f/base，一次性产出两份独立的libgcc.a。装到跟现有v2.0版本并列的新目录，
#   不覆盖、互不影响。
#
# 用法:
#   bash scripts/build_gcc_ilp32f_multilib.sh
#
# 依赖:
#   - git(Windows原生git即可，本脚本里的clone/pull用普通git命令)
#   - WSL(Ubuntu)，已装宿主编译器gcc/g++/make，以及GCC自举所需的
#     bison/flex/libgmp-dev/libmpfr-dev/libmpc-dev(本脚本开头会检测，缺失则报错退出，
#     不会自动sudo apt install——按需手动:
#     sudo apt update && sudo apt install -y bison flex libgmp-dev libmpfr-dev libmpc-dev)
#
# 原理:
#   gcc/config/loongarch/loongarch.opt里原生定义了ilp32d/ilp32f/ilp32s三个ABI枚举，
#   gcc/config.gcc里loongarch32r-*-*-*目标的abi_pattern="ilp32[dfs]"——发布包只build
#   出ilp32s是打包时的选择，不是技术能力缺失。--with-multilib-list=ilp32s/base,
#   ilp32f/base配合--enable-multilib会被loongarch专属逻辑解析(config.gcc第
#   4769-4927行)，驱动TM_MULTILIB_CONFIG生成两份ABI的编译规则；不带--enable-multilib
#   该参数会被忽略、回退到单一ABI。
#
#   只做"产出可用的multilib工具链"，不要求跟原发布包完整对等(不需要C++异常处理/
#   libstdc++/libgomp等)，所以用--disable-bootstrap单阶段构建(原发布包本身也是这样
#   构建的)、--enable-languages=c(只要C前端)、--without-headers --with-newlib(裸机
#   环境，不需要目标侧完整libc头文件来构建stage1)。
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BINUTILS_SRC="$REPO_ROOT/soc/sdk/toolchains/_la32r-binutils-src"
GCC_SRC="$REPO_ROOT/soc/sdk/toolchains/_la32r-gcc-src"
BINUTILS_BUILD="$REPO_ROOT/soc/sdk/toolchains/_build-binutils"
GCC_BUILD="$REPO_ROOT/soc/sdk/toolchains/_build-gcc"
INSTALL_PREFIX="$REPO_ROOT/soc/sdk/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-multilib"

echo "[info] repo root:      $REPO_ROOT"
echo "[info] install target: $INSTALL_PREFIX"

# ---------------------------------------------------------------------------
# 0) Windows路径转WSL路径(/e/... -> /mnt/e/...)
# ---------------------------------------------------------------------------
to_wsl_path() {
    local p="${1//\\//}"
    if [[ "$p" =~ ^([A-Za-z]):(.*)$ ]]; then
        echo "/mnt/$(echo "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')${BASH_REMATCH[2]}"
    elif [[ "$p" =~ ^/([A-Za-z])/(.*)$ ]]; then
        echo "/mnt/$(echo "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')/${BASH_REMATCH[2]}"
    else
        echo "$p"
    fi
}

# ---------------------------------------------------------------------------
# 1) 检测WSL构建依赖(不自动安装，缺失就报错退出)
# ---------------------------------------------------------------------------
echo "[step] checking WSL build dependencies..."
MISSING=$(MSYS_NO_PATHCONV=1 wsl.exe -e bash -lc "
for pkg in bison flex libgmp-dev libmpfr-dev libmpc-dev; do
    dpkg -s \$pkg >/dev/null 2>&1 || echo \$pkg
done
")
if [ -n "$MISSING" ]; then
    echo "[FAIL] WSL缺少构建依赖: $MISSING" 1>&2
    echo "       请手动执行: sudo apt update && sudo apt install -y bison flex libgmp-dev libmpfr-dev libmpc-dev" 1>&2
    exit 1
fi
echo "[ok] all WSL build dependencies present"

# ---------------------------------------------------------------------------
# 2) clone / pull binutils + gcc源码(用普通git命令，Windows下走原生git)
# ---------------------------------------------------------------------------
if [ -d "$BINUTILS_SRC/.git" ]; then
    echo "[step] la32r_binutils source already cloned, pulling..."
    git -C "$BINUTILS_SRC" pull --ff-only
else
    echo "[step] cloning la32r_binutils..."
    git clone --depth 50 https://gitee.com/loongson-edu/la32r_binutils.git "$BINUTILS_SRC"
fi

if [ -d "$GCC_SRC/.git" ]; then
    echo "[step] la32r_gcc-8.3.0 source already cloned, pulling..."
    git -C "$GCC_SRC" pull --ff-only
else
    echo "[step] cloning la32r_gcc-8.3.0..."
    git clone --depth 50 https://gitee.com/loongson-edu/la32r_gcc-8.3.0.git "$GCC_SRC"
fi

# 版本核验: 不能假设默认分支就是对的版本，跟现有工具链ld版本字符串对照
BFD_VERSION=$(grep -oE '\[[0-9.]+\]' "$BINUTILS_SRC/bfd/version.m4" | tr -d '[]')
GCC_VERSION=$(cat "$GCC_SRC/gcc/BASE-VER")
echo "[info] binutils BFD_VERSION=$BFD_VERSION, gcc BASE-VER=$GCC_VERSION"
echo "[info] 对照现有工具链版本: $(find "$REPO_ROOT/soc/sdk/toolchains" -maxdepth 1 -type d -name "loongson-gnu-toolchain-*-v2.0" | head -1 | xargs basename 2>/dev/null)"

WSL_BINUTILS_SRC="$(to_wsl_path "$BINUTILS_SRC")"
WSL_GCC_SRC="$(to_wsl_path "$GCC_SRC")"
WSL_BINUTILS_BUILD="$(to_wsl_path "$BINUTILS_BUILD")"
WSL_GCC_BUILD="$(to_wsl_path "$GCC_BUILD")"
WSL_INSTALL_PREFIX="$(to_wsl_path "$INSTALL_PREFIX")"

# ---------------------------------------------------------------------------
# 3) build binutils
# ---------------------------------------------------------------------------
echo "[step] building binutils (in WSL)..."
MSYS_NO_PATHCONV=1 wsl.exe -e bash -lc "
set -e
rm -rf '$WSL_BINUTILS_BUILD'
mkdir -p '$WSL_BINUTILS_BUILD' '$WSL_INSTALL_PREFIX'
cd '$WSL_BINUTILS_BUILD'
'$WSL_BINUTILS_SRC/configure' --target=loongarch32r-linux-gnusf --prefix='$WSL_INSTALL_PREFIX' --disable-werror --disable-nls
make -j\$(nproc)
make install
"
echo "[ok] binutils installed"

# ---------------------------------------------------------------------------
# 4) build GCC (单阶段, --enable-multilib产出ilp32s+ilp32f两份libgcc.a)
# ---------------------------------------------------------------------------
echo "[step] building GCC with ilp32s+ilp32f multilib (in WSL, this takes ~20min)..."
MSYS_NO_PATHCONV=1 wsl.exe -e bash -lc "
set -e
export PATH='$WSL_INSTALL_PREFIX/bin':\$PATH
rm -rf '$WSL_GCC_BUILD'
mkdir -p '$WSL_GCC_BUILD'
cd '$WSL_GCC_BUILD'
'$WSL_GCC_SRC/configure' \
    --target=loongarch32r-linux-gnusf \
    --prefix='$WSL_INSTALL_PREFIX' \
    --with-build-time-tools='$WSL_INSTALL_PREFIX/bin' \
    --enable-languages=c \
    --disable-bootstrap --disable-shared --disable-threads \
    --without-headers --with-newlib \
    --enable-multilib --with-multilib-list=ilp32s/base,ilp32f/base \
    --disable-nls --disable-libssp --disable-libquadmath
make -j\$(nproc) all-gcc all-target-libgcc
make install-gcc install-target-libgcc
"
echo "[ok] GCC installed"

# ---------------------------------------------------------------------------
# 5) 验证: 两份libgcc.a都存在、路径不同、配置警告消失
# ---------------------------------------------------------------------------
echo "[step] verifying multilib..."
MSYS_NO_PATHCONV=1 wsl.exe -e bash -lc "
export PATH='$WSL_INSTALL_PREFIX/bin':\$PATH
echo '--- print-multi-lib ---'
loongarch32r-linux-gnusf-gcc -print-multi-lib
echo '--- ilp32f libgcc path ---'
LIBGCC_F=\$(loongarch32r-linux-gnusf-gcc -mabi=ilp32f -print-libgcc-file-name)
echo \"\$LIBGCC_F\"
test -f \"\$LIBGCC_F\" && echo '[ok] ilp32f libgcc.a exists' || { echo '[FAIL] ilp32f libgcc.a not found' 1>&2; exit 1; }
echo '--- configure-time warning check ---'
loongarch32r-linux-gnusf-gcc -mabi=ilp32f -c -x c /dev/null -o /tmp/probe.o 2>&1 | grep -i 'not enabled at configure-time' && { echo '[FAIL] warning still present' 1>&2; exit 1; } || echo '[ok] warning gone'
"

# ---------------------------------------------------------------------------
# 6) 清理构建中间产物(.o文件等，已install提取出最终产物，源码clone保留供复用)
# ---------------------------------------------------------------------------
echo "[step] cleaning build intermediates (keeping source clones for reuse)..."
rm -rf "$BINUTILS_BUILD" "$GCC_BUILD"

echo "[done] multilib toolchain installed at: $INSTALL_PREFIX"
echo "[done] 详见同目录 README.md 的'怎么用'一节。"
