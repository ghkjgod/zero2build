param(
    [Parameter(Mandatory = $true)]
    [int]$DiskNumber,

    [Parameter(Mandatory = $true)]
    [string]$Image
)

$ErrorActionPreference = 'Stop'

$disk = Get-Disk -Number $DiskNumber
if ($disk.IsBoot -or $disk.IsSystem -or $DiskNumber -in @(0, 1)) {
    throw "拒绝写入系统磁盘 Disk $DiskNumber。请先确认这是 TF 卡。"
}

if ($disk.OperationalStatus -ne 'Online') {
    throw "Disk $DiskNumber 当前不是 Online 状态。"
}

$imagePath = (Resolve-Path $Image).Path
$hash = (Get-FileHash $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()
$target = "\\.\PhysicalDrive$DiskNumber"
$installRoots = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$imagerDir = Get-ItemProperty $installRoots -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Raspberry Pi Imager' -and $_.InstallLocation } |
    Select-Object -First 1 -ExpandProperty InstallLocation
if (-not $imagerDir) {
    $imagerDir = 'C:\Program Files\Raspberry Pi Ltd\Imager'
}
$imager = Join-Path $imagerDir 'rpi-imager.exe'
$wrapper = Join-Path $imagerDir 'rpi-imager-cli.cmd'
if (Test-Path $wrapper) { $imager = $wrapper }
if (-not (Test-Path $imager)) {
    throw "未找到 Raspberry Pi Imager CLI，请先安装 Raspberry Pi Imager。"
}

Write-Host "目标磁盘：Disk $DiskNumber / $($disk.FriendlyName) / $([math]::Round($disk.Size / 1GB, 2)) GB"
Write-Host "镜像文件：$imagePath"
Write-Host "SHA256：$hash"
Write-Host "物理目标：$target"
Write-Host '即将整卡写入并覆盖目标磁盘。'
$confirm = Read-Host '输入 FLASH-ZERO2 继续'
if ($confirm -cne 'FLASH-ZERO2') {
    throw '未确认写盘，操作已取消。'
}

$args = @('--cli', '--sha256', $hash, $imagePath, $target)
Start-Process -FilePath $imager -ArgumentList $args -Verb RunAs -Wait
