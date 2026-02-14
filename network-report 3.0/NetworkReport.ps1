# NetworkReport.ps1 - pure ASCII, no Unicode, no WHOIS, fast tracert
# Версия скрипта – меняй вручную при каждом значимом обновлении
$scriptVersion = "3.1"


$maxHops = 30
$pingTimeout = 500

# =============== АВТООБНОВЛЕНИЕ ===============
$updateRepoUrl = "https://raw.githubusercontent.com/Yozmor/network-report/refs/heads/main/network-report%203.0/NetworkReport.ps1"

function Get-ScriptPath {
    # Возвращает путь к текущему скрипту
    if ($MyInvocation.MyCommand.Path) {
        return $MyInvocation.MyCommand.Path
    } elseif ($PSScriptRoot) {
        # Если скрипт запущен как модуль или через точку, используем PSScriptRoot + имя файла
        return Join-Path $PSScriptRoot "NetworkReport.ps1"
    } else {
        return $null
    }
}

function Get-LocalVersion {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return "0.0" }
    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return "0.0" }
    if ($content -match '#\s*VERSION\s*=\s*([\d\.]+)') {
        return $matches[1]
    }
    if ($content -match '\$scriptVersion\s*=\s*"([\d\.]+)"') {
        return $matches[1]
    }
    return "0.0"
}

function Check-ForUpdates {
    Write-Host "`nПроверка обновлений..." -ForegroundColor Cyan

    if (-not $updateRepoUrl -or $updateRepoUrl -notmatch "^https://raw\.githubusercontent\.com/") {
        Write-Host " Raw-ссылка на GitHub не настроена." -ForegroundColor Red
        return
    }

    try {
        # Скачиваем raw-файл
        $remoteScript = Invoke-WebRequest -Uri $updateRepoUrl -TimeoutSec 5 -UseBasicParsing
        $remoteContent = $remoteScript.Content

        # Ищем маркер версии в remote
        $remoteVersion = $null
        $lines = $remoteContent -split "`n"
        foreach ($line in $lines) {
            if ($line -match '#\s*VERSION\s*=\s*([\d\.]+)') {
                $remoteVersion = $matches[1]
                break
            }
            if ($line -match '\$scriptVersion\s*=\s*"([\d\.]+)"') {
                $remoteVersion = $matches[1]
                break
            }
        }

        if (-not $remoteVersion) {
            Write-Host " Не удалось определить версию в remote-файле. Проверьте raw-ссылку." -ForegroundColor Red
            return
        }

        # Получаем локальную версию
        $scriptPath = Get-ScriptPath
        $localVersion = Get-LocalVersion -Path $scriptPath

        if ($remoteVersion -eq $localVersion) {
            Write-Host " У вас актуальная версия ($localVersion)." -ForegroundColor Green
        } else {
            Write-Host " Доступна новая версия: $remoteVersion (текущая: $localVersion)." -ForegroundColor Yellow
            $choice = Read-Host "Хотите обновиться? (y/n)"
            if ($choice -eq 'y' -or $choice -eq 'Y') {
                Update-Script -RemoteContent $remoteContent -RemoteVersion $remoteVersion
            }
        }
    } catch {
        Write-Host " Ошибка при проверке обновлений: $_" -ForegroundColor Red
    }
}

function Update-Script {
    param([string]$RemoteContent, [string]$RemoteVersion)

    $scriptPath = Get-ScriptPath
    if (-not $scriptPath) {
        Write-Host " Не удалось определить путь к текущему скрипту." -ForegroundColor Red
        return
    }

    # Резервная копия
    $backupDir = Split-Path $scriptPath -Parent
    $backupFile = Join-Path $backupDir "NetworkReport_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss').ps1"
    try {
        Copy-Item -Path $scriptPath -Destination $backupFile -Force
        Write-Host " Резервная копия сохранена: $backupFile" -ForegroundColor Gray
    } catch {
        Write-Host " Не удалось создать резервную копию." -ForegroundColor Red
        return
    }

    # Запись новой версии
    try {
        $RemoteContent | Out-File -FilePath $scriptPath -Encoding utf8 -Force
        Write-Host " Скрипт обновлён до версии $RemoteVersion. Перезапустите его для применения." -ForegroundColor Green
        Write-Host "Нажмите Enter для выхода..."
        Read-Host | Out-Null
        exit
    } catch {
        Write-Host " Не удалось записать обновление. Попробуйте запустить PowerShell от администратора." -ForegroundColor Red
    }
}

# =============== ОЧИСТКА СТАРЫХ ЛОГОВ ===============
function Remove-OldLogs {
    param([int]$DaysOld = 180)
    $cutoffDate = (Get-Date).AddDays(-$DaysOld)
    $oldFiles = Get-ChildItem $baseLogFolder -Recurse -File | Where-Object {
        $_.LastWriteTime -lt $cutoffDate
    }
    if ($oldFiles) {
        $oldFiles | Remove-Item -Force
        Write-Host "Очищено $($oldFiles.Count) старых логов (старше $DaysOld дней)." -ForegroundColor Gray
    }
}

# =============== НАСТРОЙКИ ЛОГИРОВАНИЯ ===============
$baseLogFolder = Join-Path $PSScriptRoot "Logs"
$maxLogAgeDays = 180  # полгода

# Функция получения пути к логу с учётом типа подключения
function Get-LogFilePath {
    param(
        [string]$FolderKey,  # http, trace, ports, dns_full, all
        [string]$Suffix = "" # для отдельных трассировок
    )
    $connInfo = Get-ConnectionTypeDetailed
    $connFolder = Join-Path $baseLogFolder $connInfo.FullString
    $targetFolder = Join-Path $connFolder $FolderKey
    if (-not (Test-Path $targetFolder)) {
        New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
    }
    $date = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $fileName = if ($Suffix) { "${date}_${Suffix}.txt" } else { "${date}.txt" }
    return Join-Path $targetFolder $fileName
}

# При запуске чистим старые логи
Remove-OldLogs -DaysOld $maxLogAgeDays


# =============== ДЕТАЛЬНОЕ ОПРЕДЕЛЕНИЕ ТИПА ПОДКЛЮЧЕНИЯ ===============
function Get-ConnectionTypeDetailed {
    $result = @{
        BaseType     = "Неизвестно"
        Detail       = "—"
        VpnName      = $null
        VpnActive    = $false
        FullString   = ""
        LinkSpeed    = $null
    }

    # ========== 1. ОПРЕДЕЛЕНИЕ VPN (только по факту) ==========
    # --- Способ 1: стандартные VPN Windows ---
    try {
        $vpnConnections = Get-VpnConnection -ErrorAction SilentlyContinue
        $activeVpn = $vpnConnections | Where-Object { $_.ConnectionStatus -eq "Connected" } | Select-Object -First 1
        if ($activeVpn) {
            $result.VpnName = $activeVpn.Name -replace '[\\/:*?"<>|]', '_'
            $result.VpnActive = $true
        }
    } catch { }

    # --- Способ 2: адаптеры TAP/TUN/WireGuard (активные) ---
    if (-not $result.VpnActive) {
        $vpnAdapters = Get-NetAdapter | Where-Object {
            $_.Name -match "(VPN|TAP|TUN|Wintun|WireGuard|OpenVPN|IKEv2|PPTP|L2TP)" -or
            $_.InterfaceDescription -match "(VPN|TAP|TUN|Wintun|WireGuard|OpenVPN)"
        }
        $upVpn = $vpnAdapters | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        if ($upVpn) {
            $result.VpnName = $upVpn.Name -replace '[\\/:*?"<>|]', '_'
            $result.VpnActive = $true
        }
    }

    # ========== 2. ОПРЕДЕЛЕНИЕ ОСНОВНОГО АДАПТЕРА (по маршруту по умолчанию) ==========
    $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Where-Object { $_.ifIndex -ne 0 } |
                    Sort-Object -Property RouteMetric | Select-Object -First 1

    if ($defaultRoute) {
        $adapter = Get-NetAdapter -ifIndex $defaultRoute.ifIndex
        if ($adapter) {
            $result.LinkSpeed = $adapter.LinkSpeed

            # --- Пытаемся получить профиль подключения (есть только у Wi-Fi) ---
            $profile = Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue

            if ($profile) {
                # Это Wi-Fi (есть профиль)
                $result.BaseType = "Wi-Fi"
                $result.Detail = $profile.Name -replace '[\\/:*?"<>|]', '_'
            } else {
                # Нет профиля — значит не Wi-Fi. Определяем по описанию.
                $desc = $adapter.InterfaceDescription
                if ($desc -match "(Remote NDIS|Mobile Broadband|LTE|4G|5G|Cellular)") {
                    $result.BaseType = "Модем"
                } else {
                    $result.BaseType = "Проводное"
                }
                $result.Detail = $adapter.Name -replace '[\\/:*?"<>|]', '_'
            }
        }
    } else {
        # На всякий случай fallback
        $activeAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
        $adapter = $activeAdapters | Select-Object -First 1
        if ($adapter) {
            $result.BaseType = "Адаптер"
            $result.Detail = $adapter.Name -replace '[\\/:*?"<>|]', '_'
        }
    }

    # ========== 3. ФОРМИРОВАНИЕ ИТОГОВОЙ СТРОКИ ==========
    $result.FullString = $result.BaseType
    if ($result.Detail -and $result.Detail -ne "—") {
        $result.FullString += "_$($result.Detail)"
    }
    if ($result.VpnActive) {
        $result.FullString += "+VPN_$($result.VpnName)"
    }

    $result.FullString = $result.FullString -replace '[\\/:*?"<>|]', '_'

    return $result
}

# =============== НАСТРОЙКИ DNS ===============
$dnsCheckEnabled = $true  # Включить/отключить DNS-модуль
$dnsTrustedServer = "8.8.8.8"  # Эталонный DNS
$dnsTargets = @()  # Загрузится из файла
# ==============================================

# =============== ЗАГРУЗКА СПИСКОВ ИЗ ФАЙЛОВ ===============
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Универсальная загрузка текстового списка (построчно) ---
function Load-TextList {
    param($FileName, $DefaultContent)
    $path = Join-Path $scriptPath $FileName
    if (Test-Path $path) {
        $lines = Get-Content $path -Encoding UTF8 | Where-Object { 
            $_.Trim() -ne "" -and $_ -notmatch '^\s*#'
        }
        if ($lines) { return $lines }
    }
    # Если файла нет или он пустой — создаём с примерами
    $DefaultContent -join "`n" | Out-File $path -Encoding UTF8
    Write-Host " Создан файл $FileName. Отредактируй его и запусти скрипт снова." -ForegroundColor Yellow
    return $DefaultContent
}

# --- Загрузка целей для сканирования портов (формат: IP;комментарий) ---
# --- Загрузка целей для сканирования портов (формат: IP;комментарий) ---
function Load-ScanTargets {
    param($FileName)
    $path = Join-Path $scriptPath $FileName
    $default = @()
    if (-not (Test-Path $path)) {
        @"
# Файл со списком целей для сканирования портов
# Формат: IP;комментарий

"@ | Out-File $path -Encoding UTF8
        Write-Host " Создан файл $FileName. Добавь свои цели и запусти скрипт снова." -ForegroundColor Yellow
        return $default
    }
    $result = @()
    $lines = Get-Content $path -Encoding UTF8 | Where-Object { $_.Trim() -ne "" -and $_ -notmatch '^\s*#' }
    foreach ($line in $lines) {
        $parts = $line.Split(';')
        if ($parts.Count -ge 1) {
            $ip = $parts[0].Trim()
            $comment = if ($parts.Count -ge 2) { $parts[1].Trim() } else { "" }
            $result += [PSCustomObject]@{
                IP      = $ip
                Comment = $comment
            }
        }
    }
    return $result
}

# --- Загрузка целей для трассировки (формат: IP;комментарий) ---
function Load-TraceTargets {
    param($FileName)
    $path = Join-Path $scriptPath $FileName
    $default = @()
    if (-not (Test-Path $path)) {
        @"
# Файл со списком целей для трассировки
# Формат: IP;комментарий

"@ | Out-File $path -Encoding UTF8
        Write-Host " Создан файл $FileName. Добавь свои цели и комментарии, затем запусти скрипт снова." -ForegroundColor Yellow
        return $default
    }
    $result = @()
    $lines = Get-Content $path -Encoding UTF8 | Where-Object {
        $_.Trim() -ne "" -and $_ -notmatch '^\s*#'
    }
    foreach ($line in $lines) {
        $parts = $line.Split(';')
        if ($parts.Count -ge 1) {
            $ip = $parts[0].Trim()
            $comment = if ($parts.Count -ge 2) { $parts[1].Trim() } else { "" }
            $result += [PSCustomObject]@{
                IP      = $ip
                Comment = $comment
            }
        }
    }
    return $result
}

# --- Загрузка DNS-серверов (формат: хост;комментарий) ---
function Load-DnsTargets {
    param($FileName)
    $path = Join-Path $scriptPath $FileName
    $default = @(
        @{Host="8.8.8.8"; Comment="Google Public DNS"}
    
    )
    if (-not (Test-Path $path)) {
        @"

"@ | Out-File $path -Encoding UTF8
        Write-Host " Создан файл $FileName. Отредактируй его и запусти скрипт снова." -ForegroundColor Yellow
        return $default
    }
    $result = @()
    $lines = Get-Content $path -Encoding UTF8 | Where-Object { 
        $_.Trim() -ne "" -and $_ -notmatch '^\s*#' 
    }
    foreach ($line in $lines) {
        $parts = $line.Split(';')
        if ($parts.Count -ge 1) {
            $hostname = $parts[0].Trim()
            $comment = if ($parts.Count -ge 2) { $parts[1].Trim() } else { "—" }
            $result += @{Host = $hostname; Comment = $comment}
        }
    }
    if ($result.Count -gt 0) { return $result } else { return $default }
}

# --- ЗАГРУЖАЕМ ВСЕ СПИСКИ ---
$sites         = Load-TextList -FileName "sites.txt"        
$traceTargets  = Load-TraceTargets -FileName "trace_targets.txt" 
$scanTargets   = Load-ScanTargets -FileName "scan_targets.txt"
$dnsTargets    = Load-DnsTargets  -FileName "dns_targets.txt"
# ============================================================
function Write-Log {
    param(
        [string]$Text,
        [string]$Color = "White",
        [string]$LogFile
    )
    Write-Host $Text -ForegroundColor $Color
    if ($LogFile) {
        Add-Content -Path $LogFile -Value $Text
    }
}

# --- ПРОВЕРКА ПОРТОВ (TCPING) ---
function Invoke-ServiceScan {
    param(
        [string]$LogFile,
        [array]$Targets,
        [int[]]$Ports = @(21,22,23,25,53,80,110,111,135,139,143,443,445,993,995,1723,3306,3389,5432,5900,6379,8080,8443,27017,27018),
        [int]$TimeoutMs = 500,
        [int]$BannerTimeoutMs = 2000
    )

    Write-Log "`n--- СКАНИРОВАНИЕ СЕРВИСОВ (по баннерам) ---" -Color Green -LogFile $LogFile

    if ($Targets.Count -eq 0) {
        Write-Log " Нет целей для сканирования." -Color Red -LogFile $LogFile
        return
    }

    Write-Log "Целей: $($Targets.Count), портов: $($Ports.Count), таймаут: $TimeoutMs мс" -Color Cyan -LogFile $LogFile

    # --- Словарь популярных сервисов по портам ---
    $wellKnown = @{
        21   = "FTP"
        22   = "SSH"
        23   = "Telnet"
        25   = "SMTP"
        53   = "DNS"
        80   = "HTTP"
        110  = "POP3"
        111  = "RPC"
        135  = "RPC"
        139  = "NetBIOS"
        143  = "IMAP"
        443  = "HTTPS"
        445  = "SMB"
        993  = "IMAPS"
        995  = "POP3S"
        1723 = "PPTP"
        3306 = "MySQL"
        3389 = "RDP"
        5432 = "PostgreSQL"
        5900 = "VNC"
        6379 = "Redis"
        8080 = "HTTP-Alt"
        8443 = "HTTPS-Alt"
        27017= "MongoDB"
        27018= "MongoDB"
    }

    # --- Локальная база уязвимостей ---
    $vulnDB = @{
        "OpenSSH" = @(
            @{ VersionPattern = "8\.[0-5]"; CVE = "CVE-2021-28041"; Description = "Double-free vulnerability" }
            @{ VersionPattern = "8\.[0-2]"; CVE = "CVE-2020-15778"; Description = "Command injection in scp" }
            @{ VersionPattern = "7\.[0-9]"; CVE = "CVE-2016-6210"; Description = "User enumeration" }
        )
        "Apache" = @(
            @{ VersionPattern = "2\.4\.49"; CVE = "CVE-2021-41773"; Description = "Path traversal" }
            @{ VersionPattern = "2\.4\.50"; CVE = "CVE-2021-42013"; Description = "Path traversal (bypass)" }
            @{ VersionPattern = "2\.4\.48"; CVE = "CVE-2021-34798"; Description = "NULL pointer dereference" }
        )
        "nginx" = @(
            @{ VersionPattern = "1\.20\.[0-1]"; CVE = "CVE-2021-23017"; Description = "DNS resolver memory leak" }
            @{ VersionPattern = "1\.18\.[0-9]"; CVE = "CVE-2020-11724"; Description = "Request smuggling" }
        )
        "ProFTPD" = @(
            @{ VersionPattern = "1\.3\.5"; CVE = "CVE-2015-3306"; Description = "File copy vulnerability" }
        )
        "MySQL" = @(
            @{ VersionPattern = "5\.7\.[0-9]"; CVE = "CVE-2020-2760"; Description = "Privilege escalation" }
            @{ VersionPattern = "8\.0\.[0-9]"; CVE = "CVE-2020-14586"; Description = "Buffer overflow" }
        )
        "PostgreSQL" = @(
            @{ VersionPattern = "9\.[0-6]"; CVE = "CVE-2019-10208"; Description = "Bypass authentication" }
        )
        "vsftpd" = @(
            @{ VersionPattern = "2\.3\.[2-4]"; CVE = "CVE-2011-0762"; Description = "Backdoor command execution" }
        )
    }

    # --- Функция проверки уязвимостей ---
    function Test-Vulnerabilities {
        param($Service, $Version)
        $found = @()
        if ($vulnDB.ContainsKey($Service)) {
            foreach ($entry in $vulnDB[$Service]) {
                if ($Version -match $entry.VersionPattern) {
                    $found += $entry
                }
            }
        }
        return $found
    }

    # --- Функция получения баннера и парсинга ---
    function Get-BannerInfo {
        param($hostIP, $port, $timeout)
        $tcp = New-Object System.Net.Sockets.TcpClient
        $banner = $null
        try {
            $connect = $tcp.BeginConnect($hostIP, $port, $null, $null)
            $wait = $connect.AsyncWaitHandle.WaitOne($timeout, $false)
            if ($wait -and $tcp.Connected) {
                $tcp.EndConnect($connect)
                $stream = $tcp.GetStream()
                $stream.ReadTimeout = $timeout

                if ($port -eq 80 -or $port -eq 8080) {
                    $request = [System.Text.Encoding]::ASCII.GetBytes("HEAD / HTTP/1.0`r`n`r`n")
                    $stream.Write($request, 0, $request.Length)
                } elseif ($port -eq 443 -or $port -eq 8443) {
                    # HTTPS пропускаем (можно добавить SslStream, но сложно)
                }

                $buffer = New-Object byte[] 1024
                $bytesRead = $stream.Read($buffer, 0, $buffer.Length)
                if ($bytesRead -gt 0) {
                    $banner = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesRead).Trim()
                }
                $stream.Close()
            }
        } catch {
            # ошибка чтения баннера
        } finally {
            $tcp.Close()
        }

        # Парсинг баннера
        $service = $wellKnown[$port]
        $version = $null
        $os = $null

        if ($banner) {
            if ($banner -match '(Apache|nginx|Microsoft-IIS|lighttpd)[/ ]?([\d\.]+)') {
                $service = $matches[1]
                $version = $matches[2]
                if ($banner -match '\(Ubuntu\)') { $os = "Ubuntu" }
                elseif ($banner -match '\(Debian\)') { $os = "Debian" }
                elseif ($banner -match '\(CentOS\)') { $os = "CentOS" }
                elseif ($banner -match 'Win') { $os = "Windows" }
            } elseif ($banner -match 'OpenSSH[_ ]?([\d\.]+)') {
                $version = $matches[1]
                if ($banner -match 'Ubuntu') { $os = "Ubuntu" }
                elseif ($banner -match 'Debian') { $os = "Debian" }
            } elseif ($banner -match 'ProFTPD ([\d\.]+)') {
                $service = "ProFTPD"
                $version = $matches[1]
            } elseif ($banner -match 'MySQL') {
                $service = "MySQL"
                if ($banner -match '([\d\.]+)-') { $version = $matches[1] }
            } elseif ($banner -match 'PostgreSQL') {
                $service = "PostgreSQL"
                if ($banner -match '([\d\.]+)') { $version = $matches[1] }
            } elseif ($banner -match 'ESMTP') {
                $service = "ESMTP"
            }
        }
        return [PSCustomObject]@{
            Port    = $port
            Open    = $true
            Service = $service
            Version = $version
            OS      = $os
            Banner  = $banner
        }
    }

    foreach ($target in $Targets) {
        Write-Log "`n Сканирование $($target.IP) [$($target.Comment)]" -Color Magenta -LogFile $LogFile
        Write-Log " Используется последовательное сканирование. Рекомендуется PowerShell 7." -Color Yellow -LogFile $LogFile

        $results = @()  # соберём все результаты

        # Сканируем все порты и собираем информацию
        foreach ($port in $Ports) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $open = $false
            try {
                $connect = $tcp.BeginConnect($target.IP, $port, $null, $null)
                $wait = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
                if ($wait -and $tcp.Connected) {
                    $tcp.EndConnect($connect)
                    $open = $true
                }
            } catch {
                # порт закрыт
            } finally {
                $tcp.Close()
            }

            if ($open) {
                $info = Get-BannerInfo -hostIP $target.IP -port $port -timeout $BannerTimeoutMs
                $results += $info
            } else {
                $results += [PSCustomObject]@{
                    Port    = $port
                    Open    = $false
                    Service = $null
                    Version = $null
                    OS      = $null
                    Banner  = $null
                }
            }
        }

        # Определяем общую информацию (ОС)
        $osDetected = $null
        foreach ($r in $results | Where-Object { $_.Open }) {
            if ($r.OS) { $osDetected = $r.OS; break }
        }

        # Выводим общую информацию
        if ($osDetected) {
            Write-Log "   Операционная система: $osDetected" -Color Cyan -LogFile $LogFile
        }

        $openCount = ($results | Where-Object { $_.Open }).Count
        Write-Log "   Открыто портов: $openCount" -Color Green -LogFile $LogFile

        # Выводим каждый порт в одну строку
        $openPortsInfo = @()
        foreach ($r in $results | Sort-Object Port) {
            if ($r.Open) {
                $serviceName = if ($r.Service) { $r.Service } else { $wellKnown[$r.Port] }
                Write-Log "  $($r.Port)/tcp – $serviceName – ОТКРЫТ" -Color Green -LogFile $LogFile
                $openPortsInfo += $r
            } else {
                Write-Log "  $($r.Port)/tcp – ЗАКРЫТ" -Color Red -LogFile $LogFile
            }
        }

        # --- Проверка уязвимостей для открытых портов ---
        $vulnsFound = @()
        foreach ($r in $openPortsInfo) {
            if ($r.Version) {
                $vulns = Test-Vulnerabilities -Service $r.Service -Version $r.Version
                if ($vulns) {
                    $vulnsFound += [PSCustomObject]@{
                        Port    = $r.Port
                        Service = $r.Service
                        Version = $r.Version
                        Vulns   = $vulns
                    }
                }
            }
        }

        if ($vulnsFound.Count -gt 0) {
            Write-Log "`n   --- НАЙДЕННЫЕ УЯЗВИМОСТИ ---" -Color Red -LogFile $LogFile
            foreach ($item in $vulnsFound) {
                Write-Log "   $($item.Service) v$($item.Version) (порт $($item.Port)):" -Color Yellow -LogFile $LogFile
                foreach ($v in $item.Vulns) {
                    Write-Log "     - $($v.CVE): $($v.Description)" -Color Gray -LogFile $LogFile
                }
            }
        } else {
            Write-Log "`n    Уязвимостей не найдено." -Color Green -LogFile $LogFile
        }
    }
}

# --- ДОСТУПНОСТЬ САЙТОВ ---
function Invoke-WebCheck {
    param($LogFile)
    Write-Log "--- ДОСТУПНОСТЬ САЙТОВ ---" -Color Green -LogFile $LogFile
    foreach ($site in $sites) {
        $url = if ($site.StartsWith("http")) { $site } else { "https://$site" }
        $start = Get-Date
        try {
            $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 5
            $ms = ((Get-Date) - $start).TotalMilliseconds
            if ($response.StatusCode -eq 200) {
                Write-Log "[OK] $site - доступен ($([math]::Round($ms)) мс)" -Color Green -LogFile $LogFile
            } else {
                Write-Log "[?] $site - код ответа $($response.StatusCode)" -Color Yellow -LogFile $LogFile
            }
        } catch [System.Net.WebException] {
            if ($_.Exception.Message -like "*404*") {
                Write-Log "[?] $site - не найден (404)" -Color Yellow -LogFile $LogFile
            } elseif ($_.Exception.Message -like "*timed out*") {
                Write-Log "[FAIL] $site - нет ответа 5 сек" -Color Red -LogFile $LogFile
            } else {
                Write-Log "[FAIL] $site - $($_.Exception.Message)" -Color Red -LogFile $LogFile
            }
        } catch {
            Write-Log "[ERROR] $site - $($_.Exception.Message)" -Color Red -LogFile $LogFile
        }
    }
}

# =============== ФУНКЦИИ DNS-МОДУЛЯ ===============

# --- Получить текущие DNS системы (только IPv4) ---
function Get-CurrentDnsServers {
    try {
        $adapters = Get-DnsClientServerAddress | Where-Object { $_.ServerAddresses -ne $null }
        $servers = @()
        foreach ($adapter in $adapters) {
            foreach ($addr in $adapter.ServerAddresses) {
                # Проверяем, что это IPv4 адрес (формат: четыре октета)
                if ($addr -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                    $servers += $addr
                }
            }
        }
        # Убираем дубликаты и возвращаем
        return $servers | Select-Object -Unique
    } catch {
        return @()
    }
}



# --- ПОЛНАЯ ДИАГНОСТИКА: HTTP + СИСТЕМНЫЙ DNS + ВСЕ DNS ИЗ ФАЙЛА ---
function Invoke-WebAndDnsDiagnostics {
    param($LogFile)
    Write-Log "`n--- ПОЛНАЯ ДИАГНОСТИКА (HTTP + ВСЕ DNS) ---" -Color Green -LogFile $LogFile

    # --- Получаем системный DNS (первый IPv4) ---
    $systemDns = (Get-CurrentDnsServers | Select-Object -First 1)
    if ($systemDns) {
        Write-Log "Системный DNS: $systemDns" -Color Cyan -LogFile $LogFile
    } else {
        Write-Log "Не удалось определить системный DNS." -Color Yellow -LogFile $LogFile
    }

    # --- Составляем общий список DNS для проверки ---
    $allDnsServers = @()
    if ($systemDns) {
        $allDnsServers += @{ Host = $systemDns; Comment = "Системный DNS" }
    }
    if ($dnsTargets.Count -gt 0) {
        $allDnsServers += $dnsTargets
    } else {
        Write-Log "Нет публичных DNS для сравнения (файл dns_targets.txt пуст)." -Color Yellow -LogFile $LogFile
    }

    if ($allDnsServers.Count -eq 0) {
        Write-Log "  Нет DNS-серверов для проверки." -Color Red -LogFile $LogFile
        return
    }

    Write-Log "Участвуют DNS-серверы:" -Color Cyan -LogFile $LogFile
    foreach ($dns in $allDnsServers) {
        Write-Log "  $($dns.Host) [$($dns.Comment)]" -Color Gray -LogFile $LogFile
    }
    Write-Log "" -LogFile $LogFile

    $results = @()
    $total = $sites.Count
    $i = 0

    foreach ($domain in $sites) {
        $i++
        Write-Progress -Activity "Диагностика сайтов" -Status "$domain" -PercentComplete (($i / $total) * 100)

        # ----- HTTP-доступность -----
        $httpStatus = " Ошибка"
        $httpTime = $null
        $url = if ($domain.StartsWith("http")) { $domain } else { "https://$domain" }
        $start = Get-Date
        try {
            $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 5
            $httpTime = ((Get-Date) - $start).TotalMilliseconds
            if ($response.StatusCode -eq 200) {
                $httpStatus = " Доступен"
            } else {
                $httpStatus = " Код $($response.StatusCode)"
            }
        } catch { }

        # ----- Собираем ответы от всех DNS -----
        $dnsResults = @()
        $anyMismatch = $false
        $referenceIp = $null  # эталонный IP для сравнения

        foreach ($dns in $allDnsServers) {
            $ip = "нет ответа"
            $time = "--"
            try {
                $dnsStart = Get-Date
                $res = Resolve-DnsName -Name $domain -Server $dns.Host -Type A -ErrorAction Stop
                $time = [math]::Round(((Get-Date) - $dnsStart).TotalMilliseconds, 0)
                $ip = ($res.IPAddress | Select-Object -First 1)
            } catch { }

            $dnsResults += [PSCustomObject]@{
                Host    = $dns.Host
                Comment = $dns.Comment
                IP      = $ip
                Time    = $time
            }

            # Определяем эталонный IP: первый успешный ответ среди всех DNS
            if ($ip -ne "нет ответа" -and $null -eq $referenceIp) {
                $referenceIp = $ip
            }

            # Если уже есть эталон и текущий IP отличается (и не ошибка) — расхождение
            if ($referenceIp -and $ip -ne "нет ответа" -and $ip -ne $referenceIp) {
                $anyMismatch = $true
            }
        }

        $results += [PSCustomObject]@{
            Domain      = $domain
            HttpStatus  = $httpStatus
            HttpTime    = if ($httpTime) { [math]::Round($httpTime, 0) } else { "--" }
            DnsResults  = $dnsResults
            HasMismatch = $anyMismatch
        }
    }

    Write-Progress -Activity "Диагностика сайтов" -Completed

    # --- Разделяем проблемные и честные ---
    $problemSites = $results | Where-Object {
        ($_.HttpStatus -notmatch " Доступен") -or $_.HasMismatch
    }
    $okSites = $results | Where-Object {
        ($_.HttpStatus -match " Доступен") -and (-not $_.HasMismatch)
    }

    # --- Функция отрисовки таблицы ---
    function Show-SiteTable {
        param($Sites, $Title, $TitleColor)

        if ($Sites.Count -eq 0) { return }

        Write-Log "" -Color $TitleColor -LogFile $LogFile
        Write-Log "$Title ($($Sites.Count)):" -Color $TitleColor -LogFile $LogFile

        # --- Ширина колонок ---
        $domainWidth = ($Sites | ForEach-Object { $_.Domain.Length } | Measure-Object -Maximum).Maximum
        $domainWidth = [math]::Max($domainWidth, 4) + 2
        $httpWidth = 16
        $dnsColWidth = 27   # примерно "8.8.8.8: 149.154.167.99 (12ms)"

        # --- Заголовок ---
        $header = "Сайт".PadRight($domainWidth) + " │ " + "Доступность".PadRight($httpWidth)
        foreach ($dns in $allDnsServers) {
            $colName = "$($dns.Host) [$($dns.Comment)]"
            # Обрежем, если слишком длинное
            if ($colName.Length -gt $dnsColWidth) { $colName = $colName.Substring(0, $dnsColWidth - 3) + ".." }
            $header += " │ " + $colName.PadRight($dnsColWidth)
        }
        Write-Log $header -Color Cyan -LogFile $LogFile

        # --- Разделитель ---
        $separator = "".PadRight($domainWidth, '─') + "─┼─" + "".PadRight($httpWidth, '─')
        foreach ($dns in $allDnsServers) {
            $separator += "─┼─" + "".PadRight($dnsColWidth, '─')
        }
        Write-Log $separator -Color Gray -LogFile $LogFile

        # --- Строки сайтов ---
        foreach ($s in $Sites) {
            $line = $s.Domain.PadRight($domainWidth) + " │ " + $s.HttpStatus.PadRight($httpWidth)
            foreach ($dnsResult in $s.DnsResults) {
                $cell = "$($dnsResult.IP) ($($dnsResult.Time)ms)"
                $line += " │ " + $cell.PadRight($dnsColWidth)
            }
            $color = if ($Title -match "ПРОБЛЕМНЫЕ") { "Red" } else { "Green" }
            Write-Log $line -Color $color -LogFile $LogFile
        }

        Write-Log $separator -Color Gray -LogFile $LogFile
    }

    # --- Выводим проблемные сайты ---
    Show-SiteTable -Sites $problemSites -Title " ПРОБЛЕМНЫЕ САЙТЫ" -TitleColor Red

    # --- Выводим честные сайты ---
    Show-SiteTable -Sites $okSites -Title " ДОСТУПНЫЕ БЕЗ ПОДМЕНЫ IP " -TitleColor Green

    # --- Итоговая статистика ---
    Write-Log "`n Всего сайтов: $total, проблем: $($problemSites.Count), OK: $($okSites.Count)" -Color Cyan -LogFile $LogFile
}

# --- ТРАССИРОВКА ---
function Analyze-Trace {
    param(
        $TargetInfo,   # объект с полями IP и Comment
        $LogFile
    )

    $target = $TargetInfo.IP
    $comment = $TargetInfo.Comment
    if ($comment) { $displayTarget = "$target ($comment)" } else { $displayTarget = $target }

    # Свой заголовок (выводится в меню, но если нужно, можно оставить здесь, но у нас он уже есть в меню)
    # Write-Log "`nТрассировка до $displayTarget ..." -Color Magenta -LogFile $LogFile

    try {
        $traceOutput = tracert -d -h $maxHops -w $pingTimeout $target 2>&1
        $lines = $traceOutput -split "`n"

        # Пропускаем первую строку заголовка, если она содержит "Трассировка маршрута"
        $startIndex = 0
        if ($lines.Count -gt 0 -and $lines[0] -match 'Трассировка маршрута') {
            $startIndex = 1
        }

        # Извлекаем целевой IP из заголовка (все равно нужно)
        $targetIP = $null
        foreach ($line in $lines) {
            if ($line -match '\[(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\]') {
                $targetIP = $matches[1]
                break
            }
        }
        if (-not $targetIP -and ($target -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')) {
            $targetIP = $target
        }

        $hops = @()
        $lastRespondingHop = $null
        $lastRespondingIP = $null
        $pingCache = @{}

        # Выводим строки начиная с индекса $startIndex
        for ($i = $startIndex; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]

            # Строка с IP-адресом
            if ($line -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})') {
                $ip = $matches[1]
                $hopNumber = if ($line -match '^\s*(\d+)') { [int]$matches[1] } else { 0 }
                $hasResponse = $line -match '\d+\s*ms' -or $line -match '\d+\s*мс'

                # Если хоп 0 (заголовок) – не обрабатываем
                if ($hopNumber -eq 0) {
                    # Но если мы уже пропустили первую строку, сюда не попадем
                    continue
                }

                $hops += [PSCustomObject]@{
                    Number      = $hopNumber
                    IP          = $ip
                    HasResponse = $hasResponse
                }

                if ($hasResponse) {
                    $lastRespondingHop = $hopNumber
                    $lastRespondingIP = $ip
                }

                # Формируем строку вывода с информацией о потерях
                $outLine = $line

                if ($ip -notmatch '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.)') {
                    if (-not $pingCache.ContainsKey($ip)) {
                        $pingResult = Test-Connection -ComputerName $ip -Count 3 -ErrorAction SilentlyContinue
                        if ($pingResult) {
                            $received = ($pingResult | Where-Object { $_.StatusCode -eq 0 }).Count
                            $lost = 3 - $received
                            $lossPercent = ($lost / 3) * 100
                            if ($received -gt 0) {
                                $avg = [math]::Round(($pingResult | Measure-Object ResponseTime -Average).Average, 0)
                                $min = ($pingResult | Measure-Object ResponseTime -Minimum).Minimum
                                $max = ($pingResult | Measure-Object ResponseTime -Maximum).Maximum
                                $pingCache[$ip] = " [loss $lossPercent% $avg ms]"
                            } else {
                                $pingCache[$ip] = " [loss 100% no reply]"
                            }
                        } else {
                            $pingCache[$ip] = " [ping failed]"
                        }
                    }
                    $outLine += $pingCache[$ip]
                } else {
                    $outLine += " [local]"
                }

                $lineColor = if ($hasResponse) { "Gray" } else { "Red" }
                Write-Log $outLine -Color $lineColor -LogFile $LogFile
            }
            # Строка с тремя звёздочками (потеря пакетов на хопе)
            elseif ($line -match '^\s*\d+\s+\*\s+\*\s+\*') {
                Write-Log $line -Color Red -LogFile $LogFile
            }
            # Строка "Трассировка завершена."
            elseif ($line -match 'Трассировка завершена') {
                Write-Log $line -Color Gray -LogFile $LogFile
            }
            # Все остальные строки (например, сообщения об ошибках) выводим серым
            else {
                Write-Log $line -Color Gray -LogFile $LogFile
            }
        }

        # Анализ достижения цели (оставляем как есть)
        if ($hops.Count -eq 0) {
            Write-Log "    Не найдено ни одного IP-адреса." -Color Yellow -LogFile $LogFile
            return
        }

        $lastHop = $hops | Sort-Object Number | Select-Object -Last 1

        if ($targetIP) {
            if ($lastHop.IP -eq $targetIP) {
                if ($lastHop.HasResponse) {
                    Write-Log "     Цель достигнута, ответ получен. $comment" -Color Green -LogFile $LogFile
                } else {
                    Write-Log "     Цель достигнута, но не отвечает на ping. $comment" -Color Yellow -LogFile $LogFile
                }
                Write-Log "   Целевой IP: $targetIP" -Color Gray -LogFile $LogFile
            } else {
                Write-Log "     Цель НЕ ДОСТИГНУТА. Возможная блокировка." -Color Red -LogFile $LogFile
                if ($lastRespondingIP) {
                    Write-Log "       Последний отвечающий узел: $lastRespondingIP (хоп $lastRespondingHop)" -Color Red -LogFile $LogFile
                } else {
                    Write-Log "       Нет отвечающих узлов." -Color Red -LogFile $LogFile
                }
                Write-Log "   Целевой IP: $targetIP" -Color Gray -LogFile $LogFile
            }
        } else {
            Write-Log "     Не удалось определить целевой IP." -Color Yellow -LogFile $LogFile
            if ($lastHop.HasResponse) {
                Write-Log "    Последний узел: $($lastHop.IP) (ответ получен)" -Color Green -LogFile $LogFile
            } else {
                Write-Log "    Последний узел: $($lastHop.IP) (не отвечает на ping)" -Color Yellow -LogFile $LogFile
            }
        }

    } catch {
        Write-Log "Ошибка трассировки: $($_.Exception.Message)" -Color Red -LogFile $LogFile
    }
}



# ---СТАРТОВЫЙ ЗАГОЛОВОК---
function Start-Report {
    param(
        [string]$FolderKey  # например, "http", "trace", "ports", "dns_full", "all"
    )
    $logFile = Get-LogFilePath -FolderKey $FolderKey
    $timestamp = Get-Date -Format "dd.MM.yyyy HH:mm:ss"
    try {
        $myIP = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 3 -ErrorAction Stop).Trim()
    } catch {
        try {
            $myIP = (Invoke-RestMethod -Uri "https://ifconfig.me/ip" -TimeoutSec 3 -ErrorAction Stop).Trim()
        } catch {
            try {
                $myIP = (Invoke-RestMethod -Uri "https://icanhazip.com" -TimeoutSec 3 -ErrorAction Stop).Trim()
            } catch {
                $myIP = "Unknown"
            }
        }
    }

    Write-Log "" -Color Cyan -LogFile $logFile
    Write-Log "================ ОТЧЁТ О СОСТОЯНИИ СЕТИ ================" -Color Cyan -LogFile $logFile
    Write-Log "Дата и время: $timestamp" -Color Yellow -LogFile $logFile
    Write-Log "IP проверяющего: $myIP" -Color Yellow -LogFile $logFile
    Write-Log "Лог-файл: $logFile" -Color Yellow -LogFile $logFile
    Write-Log "========================================================" -Color Cyan -LogFile $logFile

    return $logFile
}


# =============== МЕНЮ ===============
function Show-Menu {
    Write-Host "`n========== МЕНЮ ==========" -ForegroundColor Cyan
    Write-Host "1 - Проверить сайты (только HTTP)" -ForegroundColor Yellow
    Write-Host "2 - Трассировка (из списка)" -ForegroundColor Yellow
    Write-Host "3 - Трассировка (свой хост)" -ForegroundColor Yellow
    Write-Host "4 - Сканирование серверов" -ForegroundColor Yellow
    Write-Host "5 - Полная диагностика (HTTP + DNS)" -ForegroundColor Yellow
    Write-Host "6 - Всё вместе (трассировка + порты + диагностика)" -ForegroundColor Yellow
    Write-Host "7 - Инструкция" -ForegroundColor Yellow
    Write-Host "8 - Проверить обновления" -ForegroundColor Yellow
    Write-Host "0 - Выход" -ForegroundColor Yellow
    Write-Host "===========================" -ForegroundColor Cyan
}

do {
    Show-Menu
    $choice = Read-Host "Выберите действие"

    switch ($choice) {
        "1" {
	    $logFile = Start-Report -FolderKey "http"
            Invoke-WebCheck -LogFile $logFile
        }
        "2" {
	    $logFile = Start-Report -FolderKey "trace"
            Write-Log "`n--- ТРАССИРОВКА (макс. $maxHops хопов, таймаут ${pingTimeout}мс) ---" -Color Green -LogFile $logFile
            foreach ($target in $traceTargets) {
                Analyze-Trace -TargetInfo $target -LogFile $logFile
            }
        }
        "3" {
            $custom = Read-Host "Введите IP или домен"
    if ($custom) {
        $logFile = Start-Report -FolderKey "trace"
        Write-Log "`n--- ТРАССИРОВКА (макс. $maxHops хопов, таймаут ${pingTimeout}мс) ---" -Color Green -LogFile $logFile
        # Создаём объект с пустым комментарием
        $targetObj = [PSCustomObject]@{ IP = $custom; Comment = "" }
        Analyze-Trace -TargetInfo $targetObj -LogFile $logFile
            }
        }
        
        "4" {
	    $logFile = Start-Report -FolderKey "service_scan"
        Invoke-ServiceScan -LogFile $logFile -Targets $scanTargets
        }
        "5" {
	    $logFile = Start-Report -FolderKey "dns_full"
            if ($dnsCheckEnabled) {
                Invoke-WebAndDnsDiagnostics -LogFile $logFile
            } else {
                Write-Log "DNS-проверка отключена в настройках." -Color Red -LogFile $logFile
            }
        }
        "6" {
	    $logFile = Start-Report -FolderKey "all"
            Invoke-WebCheck -LogFile $logFile
            Write-Log "" -LogFile $logFile
            Write-Log "`n--- ТРАССИРОВКА (макс. $maxHops хопов, таймаут ${pingTimeout}мс) ---" -Color Green -LogFile $logFile
            foreach ($target in $traceTargets) {
                Analyze-Trace -TargetInfo $target -LogFile $logFile
            }
            Write-Log "" -LogFile $logFile
            Invoke-ServiceScan -LogFile $logFile -Targets $scanTargets
            Write-Log "" -LogFile $logFile
            if ($dnsCheckEnabled) {
                Invoke-WebAndDnsDiagnostics -LogFile $logFile
            } else {
                Write-Log "DNS-проверка отключена в настройках." -Color Yellow -LogFile $logFile
            }
        }
	"7" {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                      ИНСТРУКЦИЯ ПО СКРИПТУ                       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. ФАЙЛЫ НАСТРОЕК (лежат в папке со скриптом, создаются при первом запуске):"
    Write-Host "   ----------------------------------------------------------------"
    Write-Host "   📄 sites.txt           — список сайтов для проверки доступности."
    Write-Host "                           Каждый сайт с новой строки."
    Write-Host "                           Пример: t.me, discord.com, youtube.com"
    Write-Host ""
    Write-Host "   📄 trace_targets.txt   — цели для трассировки (IP или домены)."
    Write-Host "                           Каждая цель с новой строки."
    Write-Host ""
    Write-Host "   📄 port_targets.txt    — цели для проверки портов."
    Write-Host "                           Формат: хост;порт;комментарий"
    Write-Host "                           Пример: 94.131.109.144;443;Старый сервер"
    Write-Host ""
    Write-Host "   📄 dns_targets.txt     — DNS-серверы для сравнения (Сетевой стоит по умолчанию)."
    Write-Host "                           Формат: IP;комментарий"
    Write-Host "                           Пример: 8.8.8.8;Google Public DNS"
    Write-Host ""
    Write-Host "   💡 Все файлы можно редактировать Блокнотом. Строки, начинающиеся с #,"
    Write-Host "      игнорируются (можно оставлять комментарии)."
    Write-Host ""
    Write-Host "2. ЛОГИ (сохраняются в папку Logs в папке пользователя Desktop):"
    Write-Host "   ----------------------------------------------------------------"
    Write-Host "   📁 Logs/"
    Write-Host "      └─── [Тип подключения]_[Детали]+[VPN]/"
    Write-Host "           └─── session/"
    Write-Host "                ДД_ММ_ГГГГ_ЧЧММСС.txt"
    Write-Host ""
    Write-Host "   🔹 Тип подключения: Wi-Fi / Модем / Проводное"
    Write-Host "   🔹 Детали: для Wi-Fi — имя сети (SSID), для остальных — имя адаптера."
    Write-Host "   🔹 VPN: добавляется суффикс +VPN_Имя, если активен VPN."
    Write-Host ""
    Write-Host "   Пример: Wi-Fi_Stonehenge+VPN_WorkVPN\session\2026-02-13_211300.txt"
    Write-Host ""
    Write-Host "3. ЧТО ДЕЛАЕТ КАЖДЫЙ ПУНКТ МЕНЮ:"
    Write-Host "   ----------------------------------------------------------------"
    Write-Host "   1  Проверить сайты (только HTTP)"
    Write-Host "        • Проверяет доступность сайтов из sites.txt."
    Write-Host "        • Использует команду: Invoke-WebRequest -Method Head."
    Write-Host "        • Результат: [OK] — доступен, [FAIL] — нет ответа 5 сек,"
    Write-Host "          [ERROR] — ошибка соединения."
    Write-Host ""
    Write-Host "   2  Трассировка (из списка)"
    Write-Host "        • Запускает tracert для каждой цели из trace_targets.txt."
    Write-Host "        • Показывает маршрут до цели, имена узлов (если есть)."
    Write-Host "        • Анализ: определяет, достигнута ли цель и есть ли ответ."
    Write-Host ""
    Write-Host "   3  Трассировка (свой хост)"
    Write-Host "        • То же, что пункт 2, но для одного введённого вручную IP/домена."
    Write-Host ""
    Write-Host "   4  Проверить порты"
    Write-Host "        • Проверяет открытые порты для целей из port_targets.txt."
    Write-Host "        • Использует .NET TcpClient (таймаут 1 сек)."
    Write-Host "        • Результат: [ОТКРЫТ] — порт отвечает, [ЗАКРЫТ/ФИЛЬТР] — нет,"
    Write-Host "          [ОШИБКА] — ошибка подключения."
    Write-Host ""
    Write-Host "   5  Полная диагностика (HTTP + все DNS)"
    Write-Host "        • Для каждого сайта из sites.txt:"
    Write-Host "            - HTTP-доступность."
    Write-Host "            - Сравнение ответов от всех DNS из dns_targets.txt."
    Write-Host "        • Выводит таблицу с IP и временем ответа."
    Write-Host "        • Если IP различаются — подсвечивает строку красным (подмена)."
    Write-Host ""
    Write-Host "   6  Всё вместе (трассировка + порты + диагностика)"
    Write-Host "        • Последовательно выполняет пункты 1, 2, 4, 5 в одном отчёте."
    Write-Host ""
    Write-Host "   7  Инструкция (этот текст)"
    Write-Host ""
    Write-Host "   0  Выход"
    Write-Host ""
    Write-Host "4. КАК ПОНИМАТЬ РЕЗУЛЬТАТЫ:"
    Write-Host "   ----------------------------------------------------------------"
    Write-Host "    Доступен /  ОТКРЫТ — всё хорошо."
    Write-Host "    Ошибка / [ЗАКРЫТ/ФИЛЬТР] — ресурс недоступен (возможно, блокировка)."
    Write-Host "    ПОДМЕНА — DNS вернул IP, отличный от эталонного (8.8.8.8)."
    Write-Host "    Цель не достигнута — трассировка оборвалась (возможная блокировка)."
    Write-Host ""
    Write-Host "   📍 Коды ответов HTTP:"
    Write-Host "        200 — OK"
    Write-Host "        404 — не найдено"
    Write-Host "        405 — метод не поддерживается"
    Write-Host "        308 — постоянный редирект"
    Write-Host ""
    Write-Host "Нажмите Enter, чтобы вернуться в меню..."
    Read-Host | Out-Null
        }
        "8" {
            Check-ForUpdates
            Write-Host "`nНажмите Enter, чтобы вернуться в меню..." -ForegroundColor Gray
            Read-Host | Out-Null
            }
        "0" {
            Write-Host "Работа завершена." -ForegroundColor Green
        }
        default {
            Write-Host "Неверный ввод, попробуйте снова." -ForegroundColor Red
        }
    }

        if ($choice -ne "0" -and $choice -ne "7") {
        Write-Log "`n========================================================" -Color Cyan -LogFile $logFile
        Write-Log "Отчёт сохранён в файл:" -Color Cyan -LogFile $logFile
        Write-Log "   $logFile" -Color Yellow -LogFile $logFile
        Write-Log "========================================================" -Color Cyan -LogFile $logFile
        Write-Host "`nНажмите Enter для продолжения..." -ForegroundColor Gray
        Read-Host | Out-Null
    } elseif ($choice -eq "7") {
        # Для инструкции просто ждём Enter без сохранения
        Write-Host "`nНажмите Enter, чтобы вернуться в меню..." -ForegroundColor Gray
        Read-Host | Out-Null
    }
} while ($choice -ne "0")
