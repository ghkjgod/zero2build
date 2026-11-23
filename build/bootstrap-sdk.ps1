# Windows 侧引导：克隆固定提交的上游 SDK，并在 WSL 里应用补丁与 overlay。
#
# 用法（在仓库根目录）：
#   .\build\bootstrap-sdk.ps1
#
# 说明：补丁必须用 Linux 的 git 应用，否则 CRLF 和符号链接会出错。
# 因此这里把实际工作交给 WSL 执行的 build/bootstrap-sdk.sh。

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sdk = Join-Path $root 'sdk'

# 把 Windows 路径换成 WSL 路径
$wslRoot = (& wsl -e wslpath -a "$root" 2>$null)
if (-not $wslRoot) {
    throw '未找到 WSL。请先安装 WSL2（wsl --install）并至少启动一次 Ubuntu。'
}

Write-Host "仓库（WSL 路径）：$wslRoot"

if ($wslRoot -match '^/mnt/[a-z]/') {
    Write-Warning @"
仓库位于 NTFS（$wslRoot）。
内核编译在此文件系统上会慢一到两个数量级，强烈建议把仓库放到 WSL2 的 ext4 下，例如：
  \\wsl$\Ubuntu\home\<user>\zero2build
"@
}

Write-Host "`n检查 WSL 内的构建依赖 ..."
& wsl -e bash -lc 'for c in git patch make gcc bc flex bison; do command -v $c >/dev/null || echo "缺少: $c"; done'
if ($LASTEXITCODE -ne 0) { throw 'WSL 命令执行失败' }

Write-Host "`n执行 bootstrap-sdk.sh（克隆 SDK + 打补丁 + 安装 userpatches）..."
& wsl -e bash -lc "cd '$wslRoot' && chmod +x build/*.sh build/linux/*.sh && ./build/bootstrap-sdk.sh"
if ($LASTEXITCODE -ne 0) { throw "bootstrap 失败，退出码 $LASTEXITCODE" }

Write-Host "`n完成。下一步："
Write-Host "  .\tools\windows\build-zero2.ps1"
