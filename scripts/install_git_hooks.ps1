# =============================================================================
# install_git_hooks.ps1 - 安装仓库 Git hooks
# =============================================================================
# 用途:
#   将仓库内的 hooks 目录写入 git core.hooksPath，方便统一提交检查。
#
# 典型用法:
#   powershell -File scripts/install_git_hooks.ps1
#   powershell -File scripts/install_git_hooks.ps1 -HooksPath .githooks
#
# 参数:
#   -HooksPath  hooks 目录，相对仓库根目录，默认 .githooks
# =============================================================================

param(
    [string]$HooksPath = ".githooks"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$hooksResolved = (Resolve-Path (Join-Path $repoRoot $HooksPath)).Path

git -C $repoRoot config core.hooksPath $HooksPath
Write-Host "Configured core.hooksPath = $HooksPath"
Write-Host "Resolved hooks directory: $hooksResolved"
