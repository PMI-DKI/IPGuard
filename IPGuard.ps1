<#
    IPGuard.ps1
    Menjaga pengaturan IP PC penerima hasil alat agar tidak berubah.
    Dijalankan otomatis oleh Task Scheduler (akun SYSTEM) saat startup
    dan berulang setiap beberapa menit. Jangan dijalankan manual kecuali untuk tes.

    Cara kerja:
      1. Baca pengaturan "yang benar" dari config.xml (dibuat oleh installer).
      2. Cari adapter jaringan berdasarkan GUID / MAC address.
      3. Bandingkan pengaturan IPv4 yang tersimpan di registry Windows
         (DHCP, IP, subnet mask, gateway, DNS) dengan config.xml.
      4. Jika berbeda -> kembalikan dengan netsh, catat di log + Event Viewer,
         dan tampilkan pesan ke user yang sedang login.

    Kompatibel: Windows 7 / 8 / 10 / 11 (PowerShell 2.0 ke atas).
#>

$ErrorActionPreference = 'Stop'

$BaseDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $BaseDir 'config.xml'
$LogFile    = Join-Path $BaseDir 'IPGuard.log'
$StatusFile = Join-Path $BaseDir 'status.txt'
$TcpipKey   = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
$EventSource = 'IPGuard'

# ---------------------------------------------------------------- logging
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) {
            Move-Item -Path $LogFile -Destination ($LogFile + '.old') -Force
        }
        Add-Content -Path $LogFile -Value $line
    } catch { }

    try {
        $type = 'Information'; $id = 1000
        if ($Level -eq 'WARN')  { $type = 'Warning'; $id = 2000 }
        if ($Level -eq 'ERROR') { $type = 'Error';   $id = 3000 }
        Write-EventLog -LogName Application -Source $EventSource -EntryType $type -EventId $id -Message $Message
    } catch { }
}

function Get-LastStatus {
    if (Test-Path $StatusFile) {
        return [string](Get-Content -Path $StatusFile | Select-Object -First 1)
    }
    return ''
}

# Catat hanya jika status berubah, supaya log tidak penuh setiap menit.
function Set-Status {
    param([string]$Status, [string]$Message, [string]$Level = 'INFO')
    if ((Get-LastStatus) -ne $Status) {
        Write-Log -Message $Message -Level $Level
        try { Set-Content -Path $StatusFile -Value $Status } catch { }
    }
}

# ---------------------------------------------------------------- helpers
function Join-List {
    param($Items)
    $clean = @($Items | Where-Object { $_ -and ([string]$_ -ne '0.0.0.0') } | ForEach-Object { ([string]$_).Trim() })
    return ($clean -join ',')
}

function Show-Value {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '(kosong)' }
    return $Value
}

# Baca pengaturan IPv4 adapter langsung dari registry. Ini adalah pengaturan
# yang tersimpan (yang diisi lewat Control Panel / Settings / netsh), dan
# tetap terbaca walaupun kabel LAN sedang dicabut.
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
        Dhcp       = [int]$props.EnableDHCP
        IPAddress  = Join-List $props.IPAddress
        SubnetMask = Join-List $props.SubnetMask
        Gateway    = $firstGw
        DNS        = Join-List $dns
    }
}

function Compare-AdapterConfig {
    param($Want, $Have)

    $diff = @()
    if ($Have.Dhcp -ne 0) { $diff += 'diubah ke DHCP (Obtain IP automatically)' }
    if ($Have.IPAddress -ne $Want.IPAddress) {
        $diff += ('IP {0} -> {1}' -f $Want.IPAddress, (Show-Value $Have.IPAddress))
    }
    if ($Have.SubnetMask -ne $Want.SubnetMask) {
        $diff += ('Subnet mask {0} -> {1}' -f $Want.SubnetMask, (Show-Value $Have.SubnetMask))
    }
    if ($Have.Gateway -ne $Want.Gateway) {
        $diff += ('Gateway {0} -> {1}' -f (Show-Value $Want.Gateway), (Show-Value $Have.Gateway))
    }
    if ($Have.DNS -ne $Want.DNS) {
        $diff += ('DNS {0} -> {1}' -f (Show-Value $Want.DNS), (Show-Value $Have.DNS))
    }
    return $diff
}

function Find-Adapter {
    param($Config)

    $all = @(Get-WmiObject -Class Win32_NetworkAdapter | Where-Object { $_.GUID })
    $nic = $all | Where-Object { $_.GUID -eq $Config.InterfaceGuid } | Select-Object -First 1
    if (-not $nic -and $Config.MacAddress) {
        # GUID bisa berubah kalau driver di-install ulang; MAC address tetap.
        $nic = $all | Where-Object { $_.MACAddress -eq $Config.MacAddress -and $_.PhysicalAdapter } | Select-Object -First 1
    }
    return $nic
}

function Invoke-Netsh {
    param([string[]]$NetshArgs)

    $ErrorActionPreference = 'Continue'
    $out = & netsh.exe @NetshArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw ('netsh {0} gagal (kode {1}): {2}' -f ($NetshArgs -join ' '), $code, (($out | Out-String).Trim()))
    }
}

function Restore-AdapterConfig {
    param($Want, [int]$Index)

    $name  = 'name=' + $Index
    $ips   = @(([string]$Want.IPAddress)  -split ',' | Where-Object { $_ })
    $masks = @(([string]$Want.SubnetMask) -split ',' | Where-Object { $_ })
    $dns   = @(([string]$Want.DNS)        -split ',' | Where-Object { $_ })

    $gwArg = 'gateway=none'
    if ($Want.Gateway) { $gwArg = 'gateway=' + $Want.Gateway }

    # IP utama + gateway (otomatis mematikan DHCP dan menghapus IP lain)
    Invoke-Netsh @('interface', 'ipv4', 'set', 'address', $name, 'source=static',
                   ('address=' + $ips[0]), ('mask=' + $masks[0]), $gwArg)

    # IP tambahan (jika dari awal memang ada lebih dari satu)
    for ($i = 1; $i -lt $ips.Count; $i++) {
        Invoke-Netsh @('interface', 'ipv4', 'add', 'address', $name,
                       ('address=' + $ips[$i]), ('mask=' + $masks[$i]))
    }

    # DNS
    if ($dns.Count -eq 0) {
        Invoke-Netsh @('interface', 'ipv4', 'set', 'dnsservers', $name, 'source=static', 'address=none')
    } else {
        Invoke-Netsh @('interface', 'ipv4', 'set', 'dnsservers', $name, 'source=static',
                       ('address=' + $dns[0]), 'register=primary', 'validate=no')
        for ($i = 1; $i -lt $dns.Count; $i++) {
            Invoke-Netsh @('interface', 'ipv4', 'add', 'dnsservers', $name,
                           ('address=' + $dns[$i]), ('index=' + ($i + 1)), 'validate=no')
        }
    }
}

function Test-IPConflict {
    param([int]$Index, [string]$IP)
    # Hanya Windows 8 ke atas yang punya Get-NetIPAddress
    if (-not (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue)) { return $false }
    $addr = Get-NetIPAddress -InterfaceIndex $Index -IPAddress $IP -ErrorAction SilentlyContinue
    if ($addr -and ([string]$addr.AddressState -eq 'Duplicate')) { return $true }
    return $false
}

function Get-ActiveUser {
    try {
        $u = (Get-WmiObject -Class Win32_ComputerSystem).UserName
        if ($u) { return [string]$u }
    } catch { }
    return '(tidak ada user login)'
}

function Send-UserNotice {
    param([string]$Text)
    $msgExe = Join-Path $env:SystemRoot 'System32\msg.exe'
    if (-not (Test-Path $msgExe)) { return }   # msg.exe tidak ada di Windows edisi Home
    try {
        $ErrorActionPreference = 'Continue'
        $Text | & $msgExe '*' '/TIME:120' 2>&1 | Out-Null
    } catch { }
}

# ---------------------------------------------------------------- main
try {
    if (-not (Test-Path $ConfigFile)) {
        Set-Status 'NO_CONFIG' "config.xml tidak ditemukan di $BaseDir. Jalankan ulang INSTALL.bat." 'ERROR'
        exit 1
    }
    $cfg = Import-Clixml -Path $ConfigFile

    $nic = Find-Adapter $cfg
    if (-not $nic) {
        Set-Status 'NO_ADAPTER' ("Adapter jaringan '{0}' (MAC {1}) tidak ditemukan. Cek kartu jaringan / driver." -f $cfg.Description, $cfg.MacAddress) 'WARN'
        exit 0
    }

    # Adapter di-disable -> aktifkan lagi
    if ($nic.NetEnabled -eq $false) {
        $res = $nic.Enable()
        if ($res.ReturnValue -eq 0) {
            Write-Log ("Adapter '{0}' dalam keadaan DISABLED, sudah diaktifkan kembali (user aktif: {1})." -f $nic.NetConnectionID, (Get-ActiveUser)) 'WARN'
            Start-Sleep -Seconds 5
            $nic = Find-Adapter $cfg
        } else {
            Set-Status 'ENABLE_FAILED' ("Adapter '{0}' disabled dan gagal diaktifkan (kode {1})." -f $nic.NetConnectionID, $res.ReturnValue) 'ERROR'
            exit 1
        }
    }

    $have = Get-AdapterConfig $nic.GUID
    if (-not $have) {
        Set-Status 'NO_REGISTRY' ("Pengaturan TCP/IP untuk adapter {0} tidak ditemukan di registry." -f $nic.GUID) 'ERROR'
        exit 1
    }

    $diff = @(Compare-AdapterConfig $cfg $have)
    if ($diff.Count -gt 0) {
        $lastStatus = Get-LastStatus
        if ($lastStatus -ne 'REPAIR_FAILED') {
            Write-Log ("Pengaturan IP adapter '{0}' DIUBAH (user aktif: {1}): {2}" -f $nic.NetConnectionID, (Get-ActiveUser), ($diff -join '; ')) 'WARN'
        }

        $repairError = ''
        try {
            Restore-AdapterConfig $cfg ([int]$nic.InterfaceIndex)
        } catch {
            $repairError = $_.Exception.Message
        }

        Start-Sleep -Seconds 2
        $after = Get-AdapterConfig $nic.GUID
        $left = @(Compare-AdapterConfig $cfg $after)

        if ($left.Count -eq 0) {
            Write-Log ("Pengaturan IP berhasil DIKEMBALIKAN ke {0} / {1}, gateway {2}, DNS {3}." -f $cfg.IPAddress, $cfg.SubnetMask, (Show-Value $cfg.Gateway), (Show-Value $cfg.DNS)) 'INFO'
            try { Set-Content -Path $StatusFile -Value 'OK' } catch { }
            Send-UserNotice ("PERHATIAN: Pengaturan IP PC ini telah diubah dan sudah DIKEMBALIKAN otomatis ke {0}. PC ini dipakai alat untuk mengirim hasil pemeriksaan. Mohon jangan mengubah pengaturan jaringan. Hubungi Tim IT bila perlu perubahan." -f $cfg.TargetIP)
        } else {
            Set-Status 'REPAIR_FAILED' ("GAGAL mengembalikan pengaturan IP. Sisa perbedaan: {0}. {1}" -f ($left -join '; '), $repairError) 'ERROR'
        }
        exit 0
    }

    if (Test-IPConflict ([int]$nic.InterfaceIndex) ([string]$cfg.TargetIP)) {
        Set-Status 'CONFLICT' ("IP {0} BENTROK dengan perangkat lain di jaringan (IP conflict). Cek perangkat lain / DHCP server." -f $cfg.TargetIP) 'WARN'
        exit 0
    }

    Set-Status 'OK' ("Pengaturan IP sesuai: {0} pada adapter '{1}'. IPGuard aktif." -f $cfg.IPAddress, $nic.NetConnectionID) 'INFO'
    exit 0
}
catch {
    Write-Log ('Error tak terduga: ' + $_.Exception.Message) 'ERROR'
    exit 1
}
