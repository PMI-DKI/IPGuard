<#
    Uninstall-IPGuard.ps1
    Dipanggil oleh UNINSTALL.bat. Menghapus Scheduled Task, kunci wallpaper,
    sumber Event Log, dan folder C:\ProgramData\IPGuard.
    Pengaturan IP PC TIDAK diubah.
#>
param([switch]$Force)

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:ProgramData 'IPGuard'
$TaskName   = 'IPGuard'
$PolicyKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'GAGAL: jalankan sebagai Administrator.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'IPGuard akan DIHAPUS dari PC ini (IP tidak lagi dijaga otomatis).' -ForegroundColor Yellow
if (-not $Force) {
    $ans = Read-Host 'Lanjutkan? (Y/N)'
    if ($ans -notmatch '^[Yy]') { Write-Host 'Dibatalkan.'; exit 0 }
}

$ErrorActionPreference = 'Continue'

Write-Host '[1/4] Menghapus Scheduled Task ...'
& schtasks.exe /End /TN $TaskName 2>&1 | Out-Null
& schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null

Write-Host '[2/4] Membuka kunci wallpaper ...'
try {
    $wp = (Get-ItemProperty -Path $PolicyKey -ErrorAction SilentlyContinue).Wallpaper
    if ($wp -and ([string]$wp).StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-ItemProperty -Path $PolicyKey -Name 'Wallpaper' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $PolicyKey -Name 'WallpaperStyle' -ErrorAction SilentlyContinue
    }
} catch { }

Write-Host '[3/4] Menghapus sumber Event Log ...'
try {
    if ([System.Diagnostics.EventLog]::SourceExists('IPGuard')) { Remove-EventLog -Source 'IPGuard' }
} catch { }

Write-Host '[4/4] Menghapus folder C:\ProgramData\IPGuard ...'
Start-Sleep -Seconds 2
if (Test-Path $InstallDir) { Remove-Item -Path $InstallDir -Recurse -Force }

Write-Host ''
Write-Host 'Selesai. IPGuard sudah dihapus. Wallpaper bisa diganti lagi setelah sign out / restart.' -ForegroundColor Green
Write-Host ''
