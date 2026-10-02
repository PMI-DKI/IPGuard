<#
    Install-IPGuard.ps1
    Dipanggil oleh INSTALL.bat (sudah otomatis minta hak Administrator).

    Yang dilakukan:
      1. Mencari adapter yang SAAT INI memakai IP statis 192.168.7.70 atau
         192.168.7.237, lalu merekam pengaturannya (IP, subnet mask, gateway, DNS)
         sebagai pengaturan "yang benar".
      2. Menyalin IPGuard.ps1 + config.xml ke C:\ProgramData\IPGuard
         (hanya SYSTEM & Administrators yang bisa mengubah folder ini).
      3. Membuat Scheduled Task "IPGuard" (akun SYSTEM) yang jalan saat startup
         dan setiap N menit.
      4. Memasang & mengunci wallpaper info IP untuk semua user.

    Parameter opsional (jalankan dari PowerShell Administrator):
      -TargetIP 192.168.7.70      IP yang dicari (default: 192.168.7.70 dan 192.168.7.237)
      -IntervalMinutes 1          Interval pengecekan dalam menit (1-60, default 1)
      -SkipWallpaper              Tidak memasang wallpaper
      -Force                      Tidak minta konfirmasi
#>
param(
    [string[]]$TargetIP = @('192.168.7.70', '192.168.7.237'),
    [ValidateRange(1, 60)][int]$IntervalMinutes = 1,
    [switch]$SkipWallpaper,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$SourceDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:ProgramData 'IPGuard'
$TaskName   = 'IPGuard'
$TcpipKey   = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
$PolicyKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Fail {
    param([string]$Text)
    Say ''
    Say ('GAGAL: ' + $Text) 'Red'
    exit 1
}

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @Arguments 2>&1
    return @{ Code = $LASTEXITCODE; Output = (($out | Out-String).Trim()) }
}

# Sama persis dengan fungsi di IPGuard.ps1 agar hasil perbandingan konsisten
function Join-List {
    param($Items)
    $clean = @($Items | Where-Object { $_ -and ([string]$_ -ne '0.0.0.0') } | ForEach-Object { ([string]$_).Trim() })
    return ($clean -join ',')
}

function Get-AdapterConfig {
    param([string]$Guid)

    $props = Get-ItemProperty -Path (Join-Path $TcpipKey $Guid) -ErrorAction SilentlyContinue
    if (-not $props) { return $null }

    $dns = @()
    if ($props.NameServer) {
        $dns = @(([string]$props.NameServer) -split '[,\s]+' | Where-Object { $_ })
    }

    $gw = @($props.DefaultGateway | Where-Object { $_ -and ([string]$_ -ne '0.0.0.0') })
    $firstGw = ''
    if ($gw.Count -gt 0) { $firstGw = ([string]$gw[0]).Trim() }

    return @{
        Dhcp         = [int]$props.EnableDHCP
        IPAddress    = Join-List $props.IPAddress
        SubnetMask   = Join-List $props.SubnetMask
        Gateway      = $firstGw
        GatewayCount = $gw.Count
        DNS          = Join-List $dns
    }
}

function Show-Value {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '(kosong)' }
    return $Value
}

# ------------------------------------------------------------------ 0. cek admin
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'Script ini harus dijalankan sebagai Administrator. Klik kanan INSTALL.bat > Run as administrator.'
}

$guardSource = Join-Path $SourceDir 'IPGuard.ps1'
if (-not (Test-Path $guardSource)) {
    Fail "IPGuard.ps1 tidak ditemukan di $SourceDir. Pastikan semua file sudah di-extract dari ZIP ke satu folder."
}

Say ''
Say '=================================================================' 'Cyan'
Say ' IPGuard - penjaga IP PC penerima hasil alat' 'Cyan'
Say '=================================================================' 'Cyan'
Say ''

# ------------------------------------------------------------------ 1. cari adapter
Say ('Mencari adapter dengan IP statis: {0} ...' -f ($TargetIP -join ' / '))

$adapters = @(Get-WmiObject -Class Win32_NetworkAdapter | Where-Object { $_.GUID -and $_.MACAddress })
$found = @()
foreach ($nic in $adapters) {
    $c = Get-AdapterConfig $nic.GUID
    if (-not $c) { continue }
    if ($c.Dhcp -ne 0) { continue }
    $ips = @($c.IPAddress -split ',')
    foreach ($t in $TargetIP) {
        if ($ips -contains $t) {
            $found += @{ Nic = $nic; Config = $c; IP = $t }
        }
    }
}

if ($found.Count -eq 0) {
    Say ''
    Say 'Adapter yang ada di PC ini:' 'Yellow'
    foreach ($nic in $adapters) {
        $c = Get-AdapterConfig $nic.GUID
        if (-not $c -or -not $nic.NetConnectionID) { continue }
        $mode = 'statis'
        if ($c.Dhcp -ne 0) { $mode = 'DHCP' }
        Say ('  - {0} [{1}] IP: {2} ({3})' -f $nic.NetConnectionID, $nic.Name, (Show-Value $c.IPAddress), $mode) 'Yellow'
    }
    Fail ('Tidak ada adapter yang memakai IP statis {0}. Set dulu IP PC ini secara manual ke IP yang benar (lengkap dengan subnet mask, gateway, DNS), pastikan alat bisa kirim hasil, lalu jalankan INSTALL.bat lagi.' -f ($TargetIP -join ' / '))
}

if ($found.Count -gt 1) {
    foreach ($f in $found) {
        Say ('  - {0} memakai {1}' -f $f.Nic.NetConnectionID, $f.IP) 'Yellow'
    }
    Fail 'Ditemukan lebih dari satu adapter/IP target. Jalankan dari PowerShell Administrator dengan parameter, contoh: .\Install-IPGuard.ps1 -TargetIP 192.168.7.70'
}

$sel = $found[0]
$nic = $sel.Nic
$c   = $sel.Config

Say ''
Say 'Pengaturan yang akan DIJAGA:' 'Green'
Say ('  Adapter     : {0} ({1})' -f $nic.NetConnectionID, $nic.Name)
Say ('  MAC address : {0}' -f $nic.MACAddress)
Say ('  IP address  : {0}' -f $c.IPAddress)
Say ('  Subnet mask : {0}' -f $c.SubnetMask)
Say ('  Gateway     : {0}' -f (Show-Value $c.Gateway))
Say ('  DNS         : {0}' -f (Show-Value $c.DNS))
Say ('  Cek setiap  : {0} menit + saat startup' -f $IntervalMinutes)
if ($c.GatewayCount -gt 1) {
    Say '  Catatan     : adapter punya lebih dari 1 gateway; hanya gateway pertama yang dijaga.' 'Yellow'
}
Say ''

if (-not $Force) {
    $ans = Read-Host 'Pastikan pengaturan di atas sudah BENAR. Lanjutkan instalasi? (Y/N)'
    if ($ans -notmatch '^[Yy]') {
        Say 'Dibatalkan.' 'Yellow'
        exit 0
    }
}

# ------------------------------------------------------------------ 2. folder + file
Say ''
Say '[1/5] Menyiapkan folder C:\ProgramData\IPGuard ...'

# Hentikan task lama (kalau install ulang)
Invoke-Native 'schtasks.exe' @('/End', '/TN', $TaskName) | Out-Null

if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
}

# Hak akses: SYSTEM & Administrators = Full, Users = Read/Execute saja.
# Penting, karena script di folder ini dijalankan sebagai SYSTEM.
$acl = Invoke-Native 'icacls.exe' @($InstallDir, '/inheritance:r', '/grant:r',
    '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX')
if ($acl.Code -ne 0) { Fail ('Gagal mengatur hak akses folder: ' + $acl.Output) }

$guardTarget = Join-Path $InstallDir 'IPGuard.ps1'
Copy-Item -Path $guardSource -Destination $guardTarget -Force
if (Get-Command Unblock-File -ErrorAction SilentlyContinue) {
    Unblock-File -Path $guardTarget -ErrorAction SilentlyContinue
}

$config = @{
    Version        = 1
    TargetIP       = $sel.IP
    InterfaceGuid  = [string]$nic.GUID
    MacAddress     = [string]$nic.MACAddress
    Description    = [string]$nic.Name
    ConnectionName = [string]$nic.NetConnectionID
    IPAddress      = $c.IPAddress
    SubnetMask     = $c.SubnetMask
    Gateway        = $c.Gateway
    DNS            = $c.DNS
    CapturedAt     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    ComputerName   = $env:COMPUTERNAME
}
$config | Export-Clixml -Path (Join-Path $InstallDir 'config.xml') -Force

$statusFile = Join-Path $InstallDir 'status.txt'
if (Test-Path $statusFile) { Remove-Item $statusFile -Force }

# ------------------------------------------------------------------ 3. event log source
Say '[2/5] Mendaftarkan sumber log di Event Viewer ...'
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists('IPGuard')) {
        New-EventLog -LogName Application -Source 'IPGuard'
    }
} catch {
    Say ('      (dilewati: ' + $_.Exception.Message + ')') 'Yellow'
}

# ------------------------------------------------------------------ 4. scheduled task
Say ('[3/5] Membuat Scheduled Task "{0}" (SYSTEM, startup + tiap {1} menit) ...' -f $TaskName, $IntervalMinutes)

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $guardTarget
$start = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Menjaga pengaturan IP PC penerima hasil alat ($($sel.IP)). Mengembalikan IP otomatis bila diubah.</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT30S</Delay>
    </BootTrigger>
    <TimeTrigger>
      <Repetition>
        <Interval>PT$($IntervalMinutes)M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$start</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$([Security.SecurityElement]::Escape($psExe))</Command>
      <Arguments>$([Security.SecurityElement]::Escape($psArgs))</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlFile = Join-Path $env:TEMP 'IPGuard-task.xml'
Set-Content -Path $xmlFile -Value $taskXml -Encoding Unicode
$res = Invoke-Native 'schtasks.exe' @('/Create', '/TN', $TaskName, '/XML', $xmlFile, '/F')
Remove-Item $xmlFile -Force -ErrorAction SilentlyContinue
if ($res.Code -ne 0) { Fail ('Gagal membuat Scheduled Task: ' + $res.Output) }

# ------------------------------------------------------------------ 5. wallpaper
if ($SkipWallpaper) {
    Say '[4/5] Wallpaper dilewati (-SkipWallpaper).'
} else {
    $wpSource = $null
    foreach ($ext in @('jpg', 'png', 'bmp')) {
        $p = Join-Path $SourceDir ('wallpaper-{0}.{1}' -f $sel.IP, $ext)
        if (Test-Path $p) { $wpSource = $p; break }
    }

    if (-not $wpSource) {
        Say ('[4/5] File wallpaper-{0}.jpg tidak ditemukan, wallpaper dilewati.' -f $sel.IP) 'Yellow'
    } else {
        Say ('[4/5] Memasang & mengunci wallpaper {0} untuk semua user ...' -f (Split-Path -Leaf $wpSource))
        $wpTarget = Join-Path $InstallDir ('wallpaper' + [IO.Path]::GetExtension($wpSource))
        Copy-Item -Path $wpSource -Destination $wpTarget -Force

        if (-not (Test-Path $PolicyKey)) { New-Item -Path $PolicyKey -Force | Out-Null }
        New-ItemProperty -Path $PolicyKey -Name 'Wallpaper'      -Value $wpTarget -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $PolicyKey -Name 'WallpaperStyle' -Value '4'       -PropertyType String -Force | Out-Null   # 4 = Fill
    }
}

# ------------------------------------------------------------------ 6. jalankan & verifikasi
Say '[5/5] Menjalankan IPGuard pertama kali ...'
Invoke-Native 'schtasks.exe' @('/Run', '/TN', $TaskName) | Out-Null
Start-Sleep -Seconds 6

$logFile = Join-Path $InstallDir 'IPGuard.log'
Say ''
if (Test-Path $logFile) {
    Say 'Log terakhir:' 'Cyan'
    Get-Content $logFile | Select-Object -Last 3 | ForEach-Object { Say ('  ' + $_) }
} else {
    Say 'Log belum terbentuk. Cek lagi 1 menit lagi di C:\ProgramData\IPGuard\IPGuard.log' 'Yellow'
}

Say ''
Say '=================================================================' 'Green'
Say (' SELESAI. IP {0} sekarang dijaga otomatis.' -f $sel.IP) 'Green'
Say '=================================================================' 'Green'
Say ''
Say ' - Wallpaper tampil setelah user sign out / restart.'
Say ' - Log      : C:\ProgramData\IPGuard\IPGuard.log'
Say '              (juga di Event Viewer > Windows Logs > Application, Source: IPGuard)'
Say ' - Maintenance (sementara matikan penjaga):'
Say '     schtasks /Change /TN IPGuard /DISABLE    lalu    /ENABLE'
Say ' - Ganti IP resmi: matikan task, ubah IP manual, lalu jalankan INSTALL.bat lagi.'
Say ''
