# Windows + Docker 一键构建
#
# 前置：
#   1. 先运行 .\build\bootstrap-sdk.ps1（或手动 git clone + 打补丁）
#   2. Docker Desktop 正在运行
#
# 重要：仓库必须在 WSL2 的 ext4 上（\\wsl$\Ubuntu\home\<user>\...），
# 放在 NTFS（C:\ 或 F:\）会导致内核编译慢一个数量级，甚至卡死。

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $root
try {
    $repoWsl = (wsl -e wslpath -a "$root" 2>$null)
    if (-not $repoWsl) { $repoWsl = "/mnt/" + ($root -replace '^([A-Za-z]):\\', '$1/').Replace('\', '/') }
    if ($repoWsl -match '^/mnt/[a-z]/') {
        Write-Warning "仓库位于 NTFS（$repoWsl）。构建会极慢，建议移到 WSL2 的 ext4 目录。"
        $answer = Read-Host '仍要继续？输入 YES'
        if ($answer -cne 'YES') { throw '已取消' }
    }

    Write-Host "构建镜像 orangepi:zero2-build ..."
    docker build -t orangepi:zero2-build -f "$root\sdk\userpatches\Dockerfile" "$root\sdk"
    if ($LASTEXITCODE -ne 0) { throw "docker build 失败" }

    Write-Host "运行构建容器 zero2-xfce ..."
    docker run --rm --privileged `
        --cap-add=SYS_ADMIN --cap-add=MKNOD --cap-add=SYS_PTRACE `
        --security-opt apparmor=unconfined `
        -v "${root}\sdk:/root/orangepi" `
        -e COLUMNS=120 -e LINES=40 `
        orangepi:zero2-build zero2-xfce
    if ($LASTEXITCODE -ne 0) { throw "构建失败，退出码 $LASTEXITCODE" }

    Write-Host "`n产物："
    Get-ChildItem "$root\sdk\output\images\*.img" | ForEach-Object {
        $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "{0}`n  {1} 字节`n  SHA256 {2}" -f $_.Name, $_.Length, $h
    }
} finally {
    Pop-Location
}
