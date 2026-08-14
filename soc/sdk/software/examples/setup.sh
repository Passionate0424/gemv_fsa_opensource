#!/bin/bash

# 设置 LA32RSOC LoongArch32 工具链环境变量
# 使用方法：source setup.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 工具链路径（相对本仓库 soc/sdk/toolchains/，需自行构建，见 scripts/build_gcc_ilp32f_multilib.sh）
export PATH="$SDK_DIR/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin:$PATH"

# 项目主目录
export LA32RSOC_WINDOWS_HOME="$(cd "$SDK_DIR/.." && pwd)"

echo "✓ LoongArch32 environment configured successfully"
echo "  LA32RSOC_WINDOWS_HOME: $LA32RSOC_WINDOWS_HOME"
echo "  Toolchain: $(which loongarch32r-linux-gnusf-gcc)"
