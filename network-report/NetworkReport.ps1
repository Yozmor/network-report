# NetworkReport.ps1 - pure ASCII, no Unicode, no WHOIS, fast tracert
$scriptVersion = "4.0"

# =============== БЕЗОПАСНОЕ ОПРЕДЕЛЕНИЕ ПУТИ К СКРИПТУ ===============
$scriptPath = $null
if ($MyInvocation.MyCommand.Path) {
    $scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $scriptPath -and $PSScriptRoot) {
    $scriptPath = $PSScriptRoot
}
if (-not $scriptPath) {
    try {
        $scriptPath = [System.IO.Path]::GetDirectoryName([System.Reflection.Assembly]::GetExecutingAssembly().Location)
    } catch { }
}
if (-not $scriptPath) {
    $scriptPath = Get-Location
}

# --- ОПРЕДЕЛЕНИЕ ОСНОВНЫХ ПАПОК (после того как $scriptPath известен) ---
$baseLogFolder = Join-Path $scriptPath "Logs"
$toolsDir = Join-Path $scriptPath "Tools"
$configPath = Join-Path $scriptPath "config.json"

# --- Функции конфигурации ---
function Save-Config {
    param($config)
    $config | ConvertTo-Json | Out-File $configPath -Encoding UTF8
    Write-Host "Настройки сохранены в config.json" -ForegroundColor Gray
}

function Load-Config {
    if (Test-Path $configPath) {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        # Добавляем недостающие поля
        $defaults = @{
            MaxHops = 30
            PingTimeout = 500
            ConnectionTimeout = 500
            BannerTimeout = 2000
            HttpTimeout = 5
            SpeedtestRetries = 2
            MaxLogAgeDays = 180
        }
        foreach ($key in $defaults.Keys) {
            if ($null -eq $config.$key) {
                $config | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
            }
        }
    } else {
        $config = @{
            MaxHops = 30
            PingTimeout = 500
            ConnectionTimeout = 500
            BannerTimeout = 2000
            HttpTimeout = 5
            SpeedtestRetries = 2
            MaxLogAgeDays = 180
        }
        Save-Config $config
    }
    return $config
}

# --- Загрузка конфигурации ---
$config = Load-Config
$maxHops = $config.MaxHops
$maxLogAgeDays = $config.MaxLogAgeDays
$global:nexttracePath = $null

# --- Безопасная очистка логов ---
function Remove-OldLogs {
    if ([string]::IsNullOrWhiteSpace($baseLogFolder)) {
        Write-Host "Очистка логов пропущена: папка логов не определена." -ForegroundColor Yellow
        return
    }
    if (-not (Test-Path $baseLogFolder)) {
        Write-Host "Очистка логов пропущена: папка '$baseLogFolder' не существует." -ForegroundColor Yellow
        return
    }
    $dangerPaths = @("C:\", "D:\", "C:\Windows", "C:\Windows\System32", $env:TEMP, $env:WINDIR)
    if ($dangerPaths -contains $baseLogFolder) {
        Write-Host "Очистка логов запрещена для папки '$baseLogFolder'." -ForegroundColor Red
        return
    }
    $cutoffDate = (Get-Date).AddDays(-$config.MaxLogAgeDays)
    $oldFiles = Get-ChildItem $baseLogFolder -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoffDate }
    if ($oldFiles) {
        $oldFiles | Remove-Item -Force
        Write-Host "Очищено $($oldFiles.Count) старых логов (старше $($config.MaxLogAgeDays) дней)." -ForegroundColor Gray
    }
}

# --- Вызов очистки ---
Remove-OldLogs

# =============== АВТООБНОВЛЕНИЕ ===============
$updateRepoUrl = "https://raw.githubusercontent.com/Yozmor/network-report/refs/heads/main/network-report/NetworkReport.ps1"



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
        $remoteScript = Invoke-WebRequest -Uri $updateRepoUrl -TimeoutSec 5 -UseBasicParsing
        $remoteContent = $remoteScript.Content
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
            Write-Host " Не удалось определить версию в remote-файле." -ForegroundColor Red
            return
        }

        $scriptFile = Join-Path $scriptPath "NetworkReport.ps1"
        $localVersion = Get-LocalVersion -Path $scriptFile

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

function Check-Version {
    try {
        $remoteScript = Invoke-WebRequest -Uri $updateRepoUrl -TimeoutSec 5 -UseBasicParsing
        $remoteContent = $remoteScript.Content
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
        $scriptFile = Join-Path $scriptPath "NetworkReport.ps1"
        $localVersion = Get-LocalVersion -Path $scriptFile
        if ($remoteVersion -ne $localVersion) {
            Write-Host " Доступна новая версия: $remoteVersion (текущая: $localVersion)." -ForegroundColor Yellow
        }
    } catch {
        # игнорируем ошибки сети
    }
}

function Update-Script {
    param($RemoteContent, $RemoteVersion)
    $repoUrl = "https://github.com/Yozmor/network-report/archive/refs/heads/main.zip"
    $tempZip = Join-Path $env:TEMP "network-report-update.zip"
    $tempExtract = Join-Path $env:TEMP "network-report-update"

    Write-Host "`nСкачивание обновлений..." -ForegroundColor Cyan
    try {
        # 1. Скачиваем архив репозитория
        Invoke-WebRequest -Uri $repoUrl -OutFile $tempZip -UseBasicParsing -ErrorAction Stop
        
        # 2. Распаковываем архив
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
        
        # 3. Находим папку с содержимым (обычно network-report-main)
        $sourceDir = Get-ChildItem $tempExtract -Directory | Select-Object -First 1
        if (-not $sourceDir) { throw "Не найдена папка с обновлениями" }
        
        # 4. Копируем обновления в папку со скриптом
        Write-Host "Копирование обновлённых файлов..." -ForegroundColor Gray
        Copy-Item -Path "$($sourceDir.FullName)\*" -Destination $scriptPath -Recurse -Force
        
        Write-Host "Обновление завершено. Перезапустите программу." -ForegroundColor Green
        Read-Host "Нажмите Enter для выхода"
        exit
    } catch {
        Write-Host "Ошибка обновления: $_" -ForegroundColor Red
    } finally {
        # 5. Удаляем временные файлы
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}




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
        $activeVpn = $vpnConnections | Where-Object { $_.ConnectionStatus -eq "Connected" } 
        if ($activeVpn) {
            $result.VpnName = $activeVpn.Name -replace '[\\/:*?"<>|]', '_'
            $result.VpnActive = $true
        }
    } catch { }

    # --- Способ 2: адаптеры TAP/TUN/WireGuard (активные) ---
    if (-not $result.VpnActive -or $result.VpnName -eq "Yggdrasil") {
        $vpnAdapters = Get-NetAdapter -IncludeHidden | Where-Object {
            $_.Name -match "(VPN|TAP|TUN|Wintun|WireGuard|OpenVPN|IKEv2|PPTP|L2TP|Amnezia|awg|WG Tunnel)" -or
            $_.InterfaceDescription -match "(VPN|TAP|TUN|Wintun|WireGuard|OpenVPN|Amnezia|awg|Tunnel)"
        }
        $upVpn = $vpnAdapters | Where-Object { $_.Status -eq "Up" } 
        if ($upVpn) {
            $result.VpnName = $upVpn.Name -replace '[\\/:*?"<>|]', '_'
            $result.VpnActive = $true
        }
    }

    # ========== 2. ОПРЕДЕЛЕНИЕ ОСНОВНОГО АДАПТЕРА (по маршруту по умолчанию) ==========
    $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" | 
        Where-Object { 
            $adapter = Get-NetAdapter -ifIndex $_.ifIndex -ErrorAction SilentlyContinue
            if (-not $adapter) { return $false }
            # Исключаем VPN-адаптеры по ключевым словам
            $isVpn = ($adapter.Name -match "(VPN|TAP|TUN|Wintun|WireGuard|OpenVPN|IKEv2|PPTP|L2TP|Amnezia|awg|Tunnel)") -or
            ($adapter.InterfaceDescription -match "(VPN|TAP|TUN|Wintun|WireGuard|OpenVPN|Amnezia|awg|Tunnel)")
            -not $isVpn   # оставляем только НЕ VPN
        } | Sort-Object -Property RouteMetric | Sort-Object -Property ifMetric | Select-Object -First 1

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

function Load-ItemList {
    param($FileName, $DefaultItems = @(), $HeaderComment = "# Список целей`n# Формат: значение;комментарий")
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        Write-Host "Не удалось определить путь к скрипту. Загрузка $FileName невозможна." -ForegroundColor Red
        return $DefaultItems
    }
    $path = Join-Path $scriptPath $FileName
    if (-not (Test-Path $path)) {
        $HeaderComment | Out-File $path -Encoding UTF8
        Write-Host "Создан $FileName. Добавьте данные и перезапустите." -ForegroundColor Yellow
        return $DefaultItems
    }
    $fileSize = (Get-Item $path).Length
    if ($fileSize -eq 0) {
        Write-Host "Файл '$FileName' пуст" -ForegroundColor Yellow
        return $DefaultItems
    }
    $result = @()
    Get-Content $path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line -match '^\s*#') { return }
        $parts = $line.Split(';')
        $value = $parts[0].Trim()
        $comment = if ($parts.Count -ge 2) { $parts[1].Trim() } else { "" }
        $result += [PSCustomObject]@{ Value = $value; Comment = $comment }
    }
    if ($result.Count -eq 0) {
        Write-Host "Файл '$FileName' пуст" -ForegroundColor Yellow
        return $DefaultItems
    }
    return $result
}


# --- ЗАГРУЖАЕМ ВСЕ СПИСКИ ---
$sites         = Load-ItemList -FileName "sites.txt"        
$traceTargets  = Load-ItemList -FileName "trace_targets.txt" 
$scanTargets   = Load-ItemList -FileName "scan_targets.txt"
$dnsTargets    = Load-ItemList -FileName "dns_targets.txt"
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
# --- Автоматическая установка NextTrace в папку скрипта ---
function Initialize-NextTrace {
    # Используем глобальную переменную scriptPath (определена в основном скрипте)
    if (-not $scriptPath) {
        Write-Host " Ошибка: глобальная переменная scriptPath не определена." -ForegroundColor Red
        return $null
    }
    $toolsDir = Join-Path $scriptPath "Tools"
    $nexttracePath = Join-Path $toolsDir "nexttrace.exe"

    if (Test-Path $nexttracePath) {
        return $nexttracePath
    }

    Write-Host " Начинаю установку NextTrace в $toolsDir ..." -ForegroundColor Yellow

    if (-not (Test-Path $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }

    $nexttraceUrl = "https://github.com/sjlleo/nexttrace/releases/latest/download/nexttrace_windows_amd64.exe"
    try {
        Write-Host " Скачиваю nexttrace.exe ..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $nexttraceUrl -OutFile $nexttracePath -UseBasicParsing -ErrorAction Stop
        Write-Host " nexttrace.exe успешно загружен." -ForegroundColor Green
    } catch {
        Write-Host " Ошибка скачивания nexttrace.exe: $_" -ForegroundColor Red
        return $null
    }

    Write-Host " Запускаю установку необходимых драйверов (Npcap, WinDivert)..." -ForegroundColor Yellow
    Write-Host " Для установки драйверов требуются права администратора." -ForegroundColor Yellow
    try {
        $process = Start-Process -FilePath $nexttracePath -ArgumentList "--init" -Verb RunAs -PassThru -Wait
        if ($process.ExitCode -eq 0) {
            Write-Host " Драйверы успешно установлены." -ForegroundColor Green
        } else {
            Write-Host " Установка драйверов завершилась с кодом $($process.ExitCode)." -ForegroundColor Yellow
            Write-Host "   Возможно, потребуется ручная установка Npcap с сайта https://npcap.com/" -ForegroundColor Yellow
        }
    } catch {
        Write-Host " Не удалось запустить установку драйверов. Ошибка: $_" -ForegroundColor Yellow
        Write-Host "   Для работы TCP/UDP режимов может потребоваться ручная установка Npcap с https://npcap.com/" -ForegroundColor Yellow
    }

    Write-Host " Установка NextTrace завершена." -ForegroundColor Green
    return $nexttracePath
}
# --- Автоматическая установка LibreSpeed CLI ---
function Ensure-LibreSpeed {
    $toolsDir = Join-Path $scriptPath "Tools"
    $librespeedPath = Join-Path $toolsDir "librespeed-cli.exe"
    if (Test-Path $librespeedPath) {
        return $librespeedPath
    }
    Write-Host " Установка LibreSpeed CLI..." -ForegroundColor Yellow
    if (-not (Test-Path $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }
    $downloadUrl = "https://github.com/librespeed/speedtest-cli/releases/download/v1.0.11/librespeed-cli_1.0.11_windows_amd64.zip"
    $zipPath = Join-Path $toolsDir "librespeed-cli.zip"
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $zipPath -DestinationPath $toolsDir -Force
        Remove-Item $zipPath -Force
        Write-Host " LibreSpeed CLI установлен" -ForegroundColor Green
    } catch {
        Write-Host " Ошибка установки LibreSpeed CLI: $_" -ForegroundColor Red
        return $null
    }
    return $librespeedPath
}

# --- ПРОВЕРКА ПОРТОВ (TCPING) ---
function Invoke-ServiceScan {
    param(
        [string]$LogFile,
        [array]$Targets,
        [int[]]$Ports = @(21,22,23,25,53,80,110,111,135,139,143,443,445,993,995,1723,3306,3389,5432,5900,6379,8080,8443,25565,27017,27018),
        [int]$TimeoutMs,
        [int]$BannerTimeoutMs
    )
    # Если параметры не заданы, берём из конфига
    if (-not $PSBoundParameters.ContainsKey('TimeoutMs')) {
        $TimeoutMs = $config.ConnectionTimeout
    }
    if (-not $PSBoundParameters.ContainsKey('BannerTimeoutMs')) {
        $BannerTimeoutMs = $config.BannerTimeout
    }

    Write-Log "`n--- СКАНИРОВАНИЕ СЕРВИСОВ (по баннерам) ---" -Color Green -LogFile $LogFile

    if ($Targets.Count -eq 0) {
        Write-Log " Нет целей для сканирования." -Color Red -LogFile $LogFile
        return $false
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
        25565 = "Minecrafte"
        27017= "MongoDB"
        27018= "MongoDB"
    }

    # --- Локальная база уязвимостей (актуальная на апрель 2026) ---
$vulnDB = @{
    "OpenSSH" = @(
        @{ VersionPattern = "8\.[0-9]|9\.[0-9]"; CVE = "CVE-2025-61984"; Description = "Уязвимость в обработке управляющих символов в именах пользователей при использовании ProxyCommand, позволяющая выполнить произвольный код" }
        @{ VersionPattern = "8\.[0-9]|9\.[0-9]"; CVE = "CVE-2025-61985"; Description = "Обработка NULL-символов в ssh:// URI, потенциально приводящая к выполнению произвольного кода при использовании ProxyCommand" }
        @{ VersionPattern = "8\.[0-9]p?|9\.[0-9]p?"; CVE = "CVE-2026-3497"; Description = "Ошибка в GSSAPI Key Exchange может привести к отказу в обслуживании (DoS) или выполнению произвольного кода" }
        @{ VersionPattern = "8\.[0-9]p?|9\.[0-9]p?"; CVE = "CVE-2025-26465"; Description = "Клиент и сервер уязвимы к отказу в обслуживании (DoS) при обработке пакетов SSH2_MSG_PING" }
        @{ VersionPattern = "8\.[0-9]p?|9\.[0-9]p?"; CVE = "CVE-2025-32728"; Description = "Директива DisableForwarding в sshd не соответствует документации и не отключает X11 и forwarding агента" }
    )
    "Apache" = @(
        @{ VersionPattern = "2\.4\.[0-9]+"; CVE = "CVE-2025-59775"; Description = "SSRF-уязвимость в Windows с AllowEncodedSlashes On и MergeSlashes Off, приводящая к утечке NTLM-хэшей" }
        @{ VersionPattern = "2\.4\.[0-9]+"; CVE = "CVE-2025-66200"; Description = "Обход mod_userdir+suexec через AllowOverride FileInfo, позволяющий CGI-скриптам выполняться от неожиданного пользователя" }
        @{ VersionPattern = "2\.4\.[0-9]+"; CVE = "CVE-2025-58098"; Description = "Вставка строки запроса в #exec cmd=... в SSI, раскрывающая конфиденциальную информацию" }
    )
    "nginx" = @(
        @{ VersionPattern = "1\.[0-9]+\.[0-9]+"; CVE = "CVE-2026-1642"; Description = "Атака внедрения в SSL upstream, позволяющая внедрять данные в ответ от SSL-бэкенда" }
        @{ VersionPattern = "1\.[0-9]+\.[0-9]+"; CVE = "CVE-2025-23419"; Description = "Обход client certificate authentication через возобновление сессий TLS, если несколько серверных блоков используют общий IP и порт" }
        @{ VersionPattern = "1\.[0-9]+\.[0-9]+"; CVE = "CVE-2025-15566"; Description = "RCE-уязвимость в Ingress-Nginx через инъекцию конфигурации в аннотацию auth-proxy-set-headers" }
        @{ VersionPattern = "1\.[0-9]+\.[0-9]+"; CVE = "CVE-2026-27944"; Description = "Неавторизованный доступ к резервным копиям сервера Nginx UI с возможностью их расшифровки, раскрывая конфиденциальные данные" }
    )
    "MySQL" = @(
        @{ VersionPattern = "5\.7\.[0-9]+|8\.0\.[0-9]+|9\.[0-9]+\.[0-9]+"; CVE = "CVE-2025-50088"; Description = "DoS-уязвимость в компоненте InnoDB (повешение или повторяемый крах)" }
        @{ VersionPattern = "5\.7\.[0-9]+|8\.0\.[0-9]+|9\.[0-9]+\.[0-9]+"; CVE = "CVE-2025-50087"; Description = "Модификация критических данных через компонент Server: Optimizer" }
        @{ VersionPattern = "5\.7\.[0-9]+|8\.0\.[0-9]+|9\.[0-9]+\.[0-9]+"; CVE = "CVE-2025-50085"; Description = "Нарушение целостности и DoS через компонент InnoDB" }
    )
    "PostgreSQL" = @(
        @{ VersionPattern = "13\.[0-9]+|14\.[0-9]+|15\.[0-9]+|16\.[0-9]+|17\.[0-9]+"; CVE = "CVE-2025-8714"; Description = "Внедрение произвольного кода в клиент psql через pg_dump/pg_dumpall/pg_restore" }
        @{ VersionPattern = "13\.[0-9]+|14\.[0-9]+|15\.[0-9]+"; CVE = "CVE-2025-12817"; Description = "Отсутствие авторизации в CREATE STATISTICS, приводящее к DoS" }
        @{ VersionPattern = "13\.[0-9]+|14\.[0-9]+|15\.[0-9]+|16\.[0-9]+|17\.[0-9]+"; CVE = "CVE-2025-12818"; Description = "Integer wraparound в libpq, вызывающий segmentation fault" }
    )
    "ProFTPD" = @(
        @{ VersionPattern = "1\.3\.[0-9]+[a-z]?"; CVE = "CVE-2024-57392"; Description = "Переполнение буфера, приводящее к удаленному выполнению кода или DoS" }
        @{ VersionPattern = "1\.3\.[0-9]+[a-z]?"; CVE = "CVE-2024-xxxx"; Description = "Уязвимость Terrapin (machine-in-the-middle) при использовании шифра chacha20-poly1305" }
    )
    "vsftpd" = @(
        @{ VersionPattern = "3\.[0-9]+\.[0-9]+"; CVE = "CVE-2025-14242"; Description = "Integer overflow в парсинге ls команды через STAT команду, приводящий к DoS" }
        @{ VersionPattern = "2\.[0-9]+\.[0-9]+|3\.[0-9]+\.[0-9]+"; CVE = "CVE-2025-44654"; Description = "Неправильное включение chroot_local_user, приводящее к эскалации привилегий" }
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
        $ip = if ($target.IP) { $target.IP } 
              elseif ($target.Value) { $target.Value }
              else { $null }
        $comment = $target.Comment
        if ([string]::IsNullOrWhiteSpace($ip)) {
            Write-Log "Пропуск цели: отсутствует IP/домен (комментарий: $comment)" -Color Yellow -LogFile $LogFile
            continue
        }
        $displayName = if ($comment) { "$ip ($comment)" } else { $ip }
        Write-Log "`n Сканирование $displayName" -Color Magenta -LogFile $LogFile
        $results = @()  # соберём все результаты

        # Сканируем все порты и собираем информацию
        foreach ($port in $Ports) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $open = $false
            try {
                $connect = $tcp.BeginConnect($ip, $port, $null, $null)
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
                $info = Get-BannerInfo -hostIP $ip -port $port -timeout $BannerTimeoutMs
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
    return $true
}

# --- ДОСТУПНОСТЬ САЙТОВ ---
function Invoke-WebCheck {
    param($LogFile)
    if ($sites.Count -eq 0) {
        Write-Log "Нет сайтов для проверки. Заполните sites.txt." -Color Red -LogFile $LogFile
        return $false
    }
    Write-Log "--- ДОСТУПНОСТЬ САЙТОВ ---" -Color Green -LogFile $LogFile

    $timeout = if ($config.HttpTimeout -and $config.HttpTimeout -gt 0) { $config.HttpTimeout } else { 5 }

    foreach ($item in $sites) {
        $site = if ($item -is [string]) { $item } else { $item.Value }
        $url = if ($site.StartsWith("http")) { $site } else { "https://$site" }
        $start = Get-Date
        $output = curl.exe -L -k -I -s -o nul -w "%{http_code}" $url --connect-timeout $timeout 2>&1
        $httpCode = $output -join "`n"
        $ms = [math]::Round(((Get-Date) - $start).TotalMilliseconds, 0)

        if ($LASTEXITCODE -eq 0 -and $httpCode -match '^\d{3}$') {
            $code = [int]$httpCode
            if ($code -eq 200) {
                Write-Log "[OK] $site - доступен ($ms мс)" -Color Green -LogFile $LogFile
            } else {
                Write-Log "[?] $site - конечный код $code ($ms мс)" -Color Red -LogFile $LogFile
            }
        } else {
            $errMsg = if ($output -match 'curl:.*') { $matches[0] } else { "нет ответа" }
            Write-Log "[FAIL] $site - $errMsg ($ms мс)" -Color Red -LogFile $LogFile
        }
    }
    return $true
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
    if ($sites.Count -eq 0) {
        Write-Log "Нет сайтов для диагностики. Заполните sites.txt." -Color Red -LogFile $LogFile
        return $false
    }
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
        $hostAddr = if ($dns.Host) { $dns.Host } elseif ($dns.Value) { $dns.Value } else { "Неизвестно" }
        Write-Log "  $hostAddr [$($dns.Comment)]" -Color Gray -LogFile $LogFile
    }
    Write-Log "" -LogFile $LogFile

    $results = @()
    $total = $sites.Count
    $i = 0

    foreach ($item in $sites) {
        $domain = $null
        if ($item -is [string]) {
            $domain = $item
        } elseif ($item -is [PSCustomObject] -or $item -is [hashtable]) {
            if ($item.Value) { $domain = $item.Value }
            elseif ($item.IP) { $domain = $item.IP }
            elseif ($item.Host) { $domain = $item.Host }
            elseif ($item.Site) { $domain = $item.Site }
            else { $domain = $null }
        }
        if ([string]::IsNullOrWhiteSpace($domain)) {
            Write-Log "Пропуск: не удалось извлечь домен из элемента: $($item | Out-String)" -Color Yellow -LogFile $LogFile
            continue
        }    
        $i++
        Write-Progress -Activity "Диагностика сайтов" -Status "$domain" -PercentComplete (($i / $total) * 100)

        # ----- HTTP-доступность -----
        $httpStatus = " Ошибка"
        $httpTime = $null
        $url = if ($domain.StartsWith("http")) { $domain } else { "https://$domain" }
        $start = Get-Date

        $timeout = if ($config.HttpTimeout -and $config.HttpTimeout -gt 0) { $config.HttpTimeout } else { 5 }
        $response = curl.exe -L -k -I -s -o nul -w "%{http_code}" $url --connect-timeout $timeout 2>&1
        $ms = [math]::Round(((Get-Date) - $start).TotalMilliseconds, 0)

        if ($LASTEXITCODE -eq 0 -and $response -match '^\d{3}$') {
            $code = [int]$response
            if ($code -ge 200 -and $code -lt 400) {
                $httpStatus = " Доступен"
                $httpTime = $ms
            } else {
                $httpStatus = " Код $code"
                $httpTime = $ms
            }
        } else {
            $httpStatus = " Ошибка"
            $httpTime = $null
        }

        # ----- Собираем ответы от всех DNS -----
        $dnsResults = @()
        $anyMismatch = $false
        $referenceIp = $null

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

            if ($ip -ne "нет ответа" -and $null -eq $referenceIp) {
                $referenceIp = $ip
            }
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

        $domainWidth = ($Sites | ForEach-Object { $_.Domain.Length } | Measure-Object -Maximum).Maximum
        $domainWidth = [math]::Max($domainWidth, 4) + 2
        $httpWidth = 16
        $dnsColWidth = 27

        $header = "Сайт".PadRight($domainWidth) + " │ " + "Доступность".PadRight($httpWidth)
        foreach ($dns in $allDnsServers) {
            $hostAddr = if ($null -ne $dns.Host) { $dns.Host } elseif ($null -ne $dns.Value) { $dns.Value } else { "?" }
            $comment = if ($null -ne $dns.Comment) { $dns.Comment } else { "" }
            $colName = "$hostAddr [$comment]"
            if ($colName.Length -gt $dnsColWidth) { 
                $colName = $colName.Substring(0, $dnsColWidth - 3) + ".." 
            }
            $header += " │ " + $colName.PadRight($dnsColWidth)
        }
        Write-Log $header -Color Cyan -LogFile $LogFile

        $separator = "".PadRight($domainWidth, '─') + "─┼─" + "".PadRight($httpWidth, '─')
        foreach ($dns in $allDnsServers) {
            $separator += "─┼─" + "".PadRight($dnsColWidth, '─')
        }
        Write-Log $separator -Color Gray -LogFile $LogFile

        foreach ($s in $Sites) {
            $line = $s.Domain.PadRight($domainWidth) + " │ " + $s.HttpStatus.PadRight($httpWidth)
            foreach ($dnsResult in $s.DnsResults) {
                $cell = "$($dnsResult.IP) ($($dnsResult.Time)ms)"
                if ($s.HasMismatch) { $cell += " !!!" }
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
    return $true
}

# --- ТРАССИРОВКА ---
function Analyze-Trace {
    param($TargetInfo, $LogFile)

    # Извлечение цели
    if ($TargetInfo -is [string]) {
        $target = $TargetInfo
        $comment = ""
    } else {
        $target = if ($TargetInfo.IP) { $TargetInfo.IP } 
                  elseif ($TargetInfo.Value) { $TargetInfo.Value } 
                  else { $null }
        $comment = if ($TargetInfo.Comment) { $TargetInfo.Comment } else { "" }
    }

    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Log "Ошибка: отсутствует IP/домен для трассировки (комментарий: $comment)" -Color Red -LogFile $LogFile
        return $false
    }

    $displayTarget = if ($comment) { "$target ($comment)" } else { $target }
    Write-Log "`n--- ТРАССИРОВКА TCP ДО $displayTarget ---" -Color Cyan -LogFile $LogFile

    # Инициализация nexttrace
    if (-not $global:nexttracePath) {
        $global:nexttracePath = Initialize-NextTrace
    }
    $nexttracePath = $global:nexttracePath
    if (-not $nexttracePath -or -not (Test-Path $nexttracePath)) {
        Write-Log "Ошибка: NextTrace не найден. Трассировка невозможна." -Color Red -LogFile $LogFile
        return $false
    }

    $protocolFlag = if ($target -match ':') { "--ipv6" } else { "--ipv4" }
    $port = 22   # можно изменить на 443 или другой
    $arguments = @("--tcp", "--port", "$port", "--json", $protocolFlag, $target)

    try {
        # Устанавливаем кодировку UTF-8 для чтения вывода
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        $output = & $nexttracePath $arguments 2>&1
        $rawJson = $output -join "`n"

        # Парсим JSON
        $traceData = $rawJson | ConvertFrom-Json

        if (-not $traceData -or -not $traceData.Hops) {
            Write-Log "Не удалось получить данные трассировки (возможно, порт $port закрыт)." -Color Yellow -LogFile $LogFile
            return
        }

        # Выводим заголовок таблицы
        Write-Log ("{0,-4} {1,-16} {2,-8} {3,-8} {4,-8} {5}" -f "Hop", "IP", "Time1", "Time2", "Time3", "Location / Provider") -Color Cyan -LogFile $LogFile

        $hopNumber = 1
        foreach ($hopGroup in $traceData.Hops) {
            # hopGroup — массив из трёх попыток (объекты)
            $times = @()
            $ip = $null
            $location = ""
            $provider = ""
            foreach ($attempt in $hopGroup) {
                if ($attempt.Success -and $attempt.Address) {
                    $ip = $attempt.Address.IP
                    $rtt = [math]::Round($attempt.RTT / 1e6, 2)  # RTT в наносекундах? Похоже, что в наносекундах, делим на 1e6? Давайте проверим: в выводе RTT=79053600 -> 79.05 ms? 79 053 600 / 1 000 000 = 79.05 ms, так и есть.
                    $times += "$($rtt)ms"
                    # Берём гео из первой успешной попытки
                    if ($attempt.Geo -and $attempt.Geo.country_en) {
                        $country = $attempt.Geo.country_en
                        $city = $attempt.Geo.city_en
                        if ($city -and $city -ne "") {
                            $location = "$country, $city"
                        } else {
                            $location = $country
                        }
                        $provider = $attempt.Geo.isp
                    }
                } else {
                    $times += "*"
                }
            }
            # Дополняем массив до трёх элементов
            while ($times.Count -lt 3) { $times += "*" }
            $time1 = $times[0]
            $time2 = $times[1]
            $time3 = $times[2]
            $extra = if ($location -or $provider) { "$location $provider".Trim() } else { "—" }
            Write-Log ("{0,-4} {1,-16} {2,-8} {3,-8} {4,-8} {5}" -f $hopNumber, $ip, $time1, $time2, $time3, $extra) -Color Gray -LogFile $LogFile
            $hopNumber++
        }
    } catch {
        Write-Log "Ошибка выполнения nexttrace: $($_.Exception.Message)" -Color Red -LogFile $LogFile
        Write-Log "Сырой вывод (первые 200 символов): $($rawJson.Substring(0, [Math]::Min(200, $rawJson.Length)))" -Color Yellow -LogFile $LogFile
    }
    return $true
}

function Invoke-SpeedTest {
    param($LogFile)

     # Проверяем/устанавливаем утилиту
    $librespeedPath = Ensure-LibreSpeed
    if (-not $librespeedPath) {
        Write-Log " Не удалось установить LibreSpeed CLI. Проверка скорости пропущена." -Color Red -LogFile $LogFile
        return $false
    }

    $toolsDir = Join-Path $scriptPath "Tools"
    $librespeedPath = Join-Path $toolsDir "librespeed-cli.exe"

    if (-not (Test-Path $librespeedPath)) {
        Write-Log " librespeed-cli.exe не найден в папке Tools." -Color Red -LogFile $LogFile
        return $false
    }

    Write-Log "`n--- ТЕСТ СКОРОСТИ ИНТЕРНЕТА ---" -Color Green -LogFile $LogFile
    Write-Log "  В РФ для стабильной работы теста рекомендуется использовать VPN." -Color Yellow -LogFile $LogFile
    Write-Log " Выполняется тест, подождите..." -Color Gray -LogFile $LogFile

    Push-Location $toolsDir
    try {
        $jsonOutput = & .\librespeed-cli.exe --json 2>$null
        $result = ($jsonOutput | ConvertFrom-Json)[0]

        $server = $result.server.name
        $ping = [math]::Round($result.ping, 2)
        $download = [math]::Round($result.download, 2)
        $upload = [math]::Round($result.upload, 2)

        Write-Log "`n   Результаты теста:" -Color Cyan -LogFile $LogFile
        Write-Log ("   {0,-12} {1}" -f "Сервер:", $server) -Color Gray -LogFile $LogFile
        Write-Log ("   {0,-12} {1,8} ms" -f "Пинг:", $ping) -Color Gray -LogFile $LogFile
        Write-Log ("   {0,-12} {1,8} Mbit/s" -f "Загрузка:", $download) -Color Gray -LogFile $LogFile
        Write-Log ("   {0,-12} {1,8} Mbit/s" -f "Отдача:", $upload) -Color Gray -LogFile $LogFile

        return $true
    } catch {
        Write-Log " Ошибка выполнения теста: $_" -Color Red -LogFile $LogFile
        return $false
    } finally {
        Pop-Location
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
    Write-Host "1 - Проверить доступность сайтов" -ForegroundColor Yellow
    Write-Host "2 - Трассировка" -ForegroundColor Yellow
    Write-Host "3 - Сканирование портов" -ForegroundColor Yellow
    Write-Host "4 - Проверить скорость интернета" -ForegroundColor Yellow
    Write-Host "5 - Настройки" -ForegroundColor Yellow
    Write-Host "0 - Выход" -ForegroundColor Yellow
    Write-Host "===========================" -ForegroundColor Cyan
}
function Show-Menu-Invoke {
    Write-Host "`n========== Доступность сайтов ==========" -ForegroundColor Cyan
    Write-Host "1 - Проверить сайты (только HTTP)" -ForegroundColor Yellow
    Write-Host "2 - Полная диагностика (HTTP + DNS)" -ForegroundColor Yellow
    Write-Host "3 - Полная диагностика (свой хост)" -ForegroundColor Yellow
    Write-Host "0 - Назад" -ForegroundColor Yellow
}
function Show-Menu-Trace {
    Write-Host "`n========== Трассировка ==========" -ForegroundColor Cyan
    Write-Host "1 - Трассировка (из списка)" -ForegroundColor Yellow
    Write-Host "2 - Трассировка (свой хост)" -ForegroundColor Yellow
    Write-Host "0 - Назад" -ForegroundColor Yellow
}
function Show-Menu-Scan {
    Write-Host "`n========== Сканирование портов ==========" -ForegroundColor Cyan
    Write-Host "1 - Сканирование портов (из списка)" -ForegroundColor Yellow
    Write-Host "2 - Сканирование портов (свой хост)" -ForegroundColor Yellow
    Write-Host "0 - Назад" -ForegroundColor Yellow
}
function Show-Menu-Settings {
    Write-Host "`n========== Настройки ==========" -ForegroundColor Cyan
    Write-Host "1 - Показать текущие настройки" -ForegroundColor Yellow
    Write-Host "2 - Изменить таймаут соединения (сейчас $($config.ConnectionTimeout) мс)" -ForegroundColor Yellow
    Write-Host "3 - Изменить таймаут чтения баннера (сейчас $($config.BannerTimeout) мс)" -ForegroundColor Yellow
    Write-Host "4 - Изменить таймаут для http запросов (сейчас $($config.HttpTimeout) мс)" -ForegroundColor Yellow
    Write-Host "5 - Изменить период хранения логов (сейчас $($config.MaxLogAgeDays) дней)" -ForegroundColor Yellow
    Write-Host "6 - Сбросить настройки по умолчанию" -ForegroundColor Yellow
    Write-Host "7 - Инструкция" -ForegroundColor Yellow
    Write-Host "8 - Проверить обновления" -ForegroundColor Yellow
    Write-Host "0 - Назад" -ForegroundColor Yellow
}
do {
    Write-Host "`nVersion $scriptVersion" -ForegroundColor Gray
    Check-Version
    Show-Menu
    $choice = Read-Host "Выберите действие"

    switch ($choice) {
        "1" {
            do {
                Show-Menu-Invoke
                $choice_invoke = Read-Host "Выберите действие"
                $success = $false
                switch ($choice_invoke) {
                    "1" {
	                    $logFile = Start-Report -FolderKey "http"
                        $success = Invoke-WebCheck -LogFile $logFile
                    }        
                    "2" {
	                    $logFile = Start-Report -FolderKey "dns_full"
                        if ($dnsCheckEnabled) {
                            $success = Invoke-WebAndDnsDiagnostics -LogFile $logFile
                        } else {
                            Write-Log "DNS-проверка отключена в настройках." -Color Red -LogFile $logFile
                        }
                    }
                    "3" {
                        $custom = Read-Host "Введите IP или домен"
                        if (-not $custom) {
                            Write-Host "Ничего не введено. Возврат в меню." -ForegroundColor Yellow
                            break
                        }
                        $oldSites = $sites
                        $sites = @( [PSCustomObject]@{ Value = $custom; Comment = "Ручной ввод" })
                        $logFile = Start-Report -FolderKey "dns_full"
                        $success = Invoke-WebAndDnsDiagnostics -LogFile $logFile
                        $sites = $oldSites
                    }
                    "0" {}      
                    default {
                        Write-Host "Неверный ввод, попробуйте снова." -ForegroundColor Red
                    }
                }

                if ($choice_invoke -ne "0" -and $success) {
                    Write-Log "`n========================================================" -Color Cyan -LogFile $logFile
                    Write-Log "Отчёт сохранён в файл:" -Color Cyan -LogFile $logFile
                    Write-Log "   $logFile" -Color Yellow -LogFile $logFile
                    Write-Log "========================================================" -Color Cyan -LogFile $logFile
                    Write-Host "`nНажмите Enter для продолжения..." -ForegroundColor Gray
                    Read-Host | Out-Null
                } 
            } while ($choice_invoke -ne "0")
            
        }
        "2" {            
            do {
                Show-Menu-Trace
                $choice_trace = Read-Host "Выберите действие"
                $success = $false
                switch ($choice_trace) {
                    "1" {
                        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                        if (-not $isAdmin) {
                            Write-Log "Для TCP-трассировки требуются права администратора." -Color Red -LogFile $logFile
                        } else {
	                        $logFile = Start-Report -FolderKey "trace"
                            Write-Log "`n--- ТРАССИРОВКА (макс. $maxHops хопов, таймаут ${pingTimeout}мс) ---" -Color Green -LogFile $logFile
                            foreach ($target in $traceTargets) {
                                $success = Analyze-Trace -TargetInfo $target -LogFile $logFile
                            }
                        }
                    }
                    "2" {
                        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                        if (-not $isAdmin) {
                            Write-Log "Для TCP-трассировки требуются права администратора." -Color Red -LogFile $logFile
                        } else {
                            $custom = Read-Host "Введите IP или домен"
                            if ($custom) {
                                $logFile = Start-Report -FolderKey "trace"
                                Write-Log "`n--- ТРАССИРОВКА (макс. $maxHops хопов, таймаут ${pingTimeout}мс) ---" -Color Green -LogFile $logFile
                                $targetObj = [PSCustomObject]@{ IP = $custom; Comment = "" }
                                $success = Analyze-Trace -TargetInfo $targetObj -LogFile $logFile
                            }
                        }    
                    }
                    "0" {}
                    default {
                        Write-Host "Неверный ввод, попробуйте снова." -ForegroundColor Red
                    }
                }

                if ($choice_trace -ne "0" -and $success) {
                    Write-Log "`n========================================================" -Color Cyan -LogFile $logFile
                    Write-Log "Отчёт сохранён в файл:" -Color Cyan -LogFile $logFile
                    Write-Log "   $logFile" -Color Yellow -LogFile $logFile
                    Write-Log "========================================================" -Color Cyan -LogFile $logFile
                    Write-Host "`nНажмите Enter для продолжения..." -ForegroundColor Gray
                    Read-Host | Out-Null
                } 
            } while ($choice_trace -ne "0")
        }
        "3" {            
            do {
                Show-Menu-Scan
                $choice_scan = Read-Host "Выберите действие"
                $success = $false
                switch ($choice_scan) {
                    "1" {
	                    $logFile = Start-Report -FolderKey "service_scan"
                        $success = Invoke-ServiceScan -LogFile $logFile -Targets $scanTargets
                    }
                    "2" {
                            $custom = Read-Host "Введите IP или домен"
                            if ($custom) {
                                $logFile = Start-Report -FolderKey "service_scan"
                                $scanTargets = [PSCustomObject]@{ IP = $custom; Comment = "" }
                                $success = Invoke-ServiceScan -LogFile $logFile -Targets $scanTargets
                            }
                    }    
                    "0" {}
                    default {
                        Write-Host "Неверный ввод, попробуйте снова." -ForegroundColor Red
                    }
                }

                if ($choice_scan -ne "0" -and $success) {
                    Write-Log "`n========================================================" -Color Cyan -LogFile $logFile
                    Write-Log "Отчёт сохранён в файл:" -Color Cyan -LogFile $logFile
                    Write-Log "   $logFile" -Color Yellow -LogFile $logFile
                    Write-Log "========================================================" -Color Cyan -LogFile $logFile
                    Write-Host "`nНажмите Enter для продолжения..." -ForegroundColor Gray
                    Read-Host | Out-Null
                } 
            } while ($choice_scan -ne "0")
        }
        "4" {
	        $logFile = Start-Report -FolderKey "speedtest"
            $success = Invoke-SpeedTest -LogFile $logFile
        }
        "5" {            
            do {
                Show-Menu-Settings
                $choice_settings = Read-Host "Выберите действие"
                switch ($choice_settings) {
                    "1" {
                        Write-Host "`n══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                        Write-Host "                   ТЕКУЩИЕ НАСТРОЙКИ" -ForegroundColor Cyan
                        Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
                        Write-Host ""
                        Write-Host "ConnectionTimeout: $($config.ConnectionTimeout) мс — таймаут установки TCP-соединения при сканировании портов." -ForegroundColor White
                        Write-Host "BannerTimeout: $($config.BannerTimeout) мс — таймаут ожидания баннера (приветствия) после подключения." -ForegroundColor White
                        Write-Host "HttpTimeout: $($config.HttpTimeout) мс — таймаут для http запроса." -ForegroundColor White
                        Write-Host "MaxLogAgeDays: $($config.MaxLogAgeDays) дней — срок хранения логов (старше удаляются)." -ForegroundColor White
                        Write-Host ""
                        Write-Host "Нажмите Enter для продолжения..." -ForegroundColor Gray
                        Read-Host | Out-Null
                    }
                    "2" {
                        $newValue = Read-Host "Введите новый таймаут соединения (мс, текущий $($config.ConnectionTimeout))"
                        if ($newValue -match '^\d+$') {
                            $config.ConnectionTimeout = [int]$newValue
                            Save-Config
                        } else { Write-Host "Неверный ввод" -ForegroundColor Red }
                    }
                    "3" {
                        $newValue = Read-Host "Введите новый таймаут чтения баннера (мс, текущий $($config.BannerTimeout))"
                        if ($newValue -match '^\d+$') {
                            $config.BannerTimeout = [int]$newValue
                            Save-Config
                        } else { Write-Host "Неверный ввод" -ForegroundColor Red }
                    }
                    "4" {
                        $newValue = Read-Host "Введите новый таймаут для http (мс, текущий $($config.HttpTimeout))"
                        if ($newValue -match '^\d+$') {
                            $config.HttpTimeout = [int]$newValue
                            Save-Config
                        } else { Write-Host "Неверный ввод" -ForegroundColor Red }
                    }
                    "5" {
                        $newValue = Read-Host "Введите период хранения логов в днях (текущий $($config.MaxLogAgeDays))"
                        if ($newValue -match '^\d+$') {
                            $config.MaxLogAgeDays = [int]$newValue
                            $maxLogAgeDays = $config.MaxLogAgeDays
                            Save-Config
                        } else { Write-Host "Неверный ввод" -ForegroundColor Red }
                    }
                    "6" {
                        $config = @{
                            ConnectionTimeout = 500
                            BannerTimeout = 2000
                            HttpTimeout = 5
                            MaxLogAgeDays = 180
                        }
                        Save-Config
                        $maxHops = $config.MaxHops
                        $pingTimeout = $config.PingTimeout
                        $maxLogAgeDays = $config.MaxLogAgeDays
                        Write-Host "Настройки сброшены к значениям по умолчанию." -ForegroundColor Green
                    }
"7" {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                      ИНСТРУКЦИЯ ПО СКРИПТУ                       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. ФАЙЛЫ НАСТРОЕК (создаются автоматически, редактируйте Блокнотом):"
    Write-Host "   ----------------------------------------------------------------"
    Write-Host "    sites.txt           – список сайтов (по одному на строку)."
    Write-Host "                           Пример: t.me, google.com, youtube.com"
    Write-Host ""
    Write-Host "    trace_targets.txt   – цели для TCP-трассировки."
    Write-Host "                           Формат: IP/домен;комментарий"
    Write-Host "                           Пример: 94.131.109.144;Франкфурт"
    Write-Host ""
    Write-Host "    scan_targets.txt    – цели для сканирования портов."
    Write-Host "                           Формат: IP;комментарий"
    Write-Host "                           Пример: 212.41.7.181;Питер"
    Write-Host ""
    Write-Host "    dns_targets.txt     – DNS-серверы для сравнения."
    Write-Host "                           Формат: IP;комментарий"
    Write-Host "                           Пример: 8.8.8.8;Google Public DNS"
    Write-Host ""
    Write-Host "    config.json         – настройки программы (редактируйте через меню 5)."
    Write-Host ""
    Write-Host "2. ЛОГИ (сохраняются в папку Logs):"
    Write-Host "   ----------------------------------------------------------------"
    Write-Host "    Logs/"
    Write-Host "      └─── [Тип подключения]_[Детали]+[VPN]/"
    Write-Host "           └─── [тип проверки]/"
    Write-Host "                └───ГГГГ-ММ-ДД_ЧЧММСС.txt"
    Write-Host ""
    Write-Host "   Типы проверок: http, dns_full, trace, service_scan, speedtest"
    Write-Host "   Пример: Logs\Wi-Fi_Stonehenge+VPN_AmneziaVPN\trace\2026-04-11_195624.txt"
    Write-Host ""
    Write-Host "3. ГЛАВНОЕ МЕНЮ:"
    Write-Host "   ----------------------------------------------------------------"
    Write-Host "   1 – Доступность сайтов"
    Write-Host "   2 – Трассировка"
    Write-Host "   3 – Сканирование портов"
    Write-Host "   4 – Проверка скорости интернета"
    Write-Host "   5 – Настройки (изменение таймаутов, инструкция, обновления)"
    Write-Host "   0 – Выход"
    Write-Host ""
    Write-Host "4. ПОДРОБНОЕ ОПИСАНИЕ ПУНКТОВ:"
    Write-Host "   ----------------------------------------------------------------"
    Write-Host ""
    Write-Host "    1 → Доступность сайтов (подменю):"
    Write-Host "       1.1  Проверить сайты (только HTTP)"
    Write-Host "            • Выполняет HEAD-запрос к каждому сайту через curl."
    Write-Host "            • Вывод: [OK] – доступен (время ответа в мс),"
    Write-Host "                     [?] – код ответа (редирект, ошибка),"
    Write-Host "                     [FAIL] – нет ответа за таймаут (настраивается)."
    Write-Host "                     Коды HTTP: 200 – OK, 301/302 – редирект, 403 – запрещено, 404 – не найдено."
    Write-Host "            • Настройка: таймаут HTTP-запроса (меню 5 → 4)."
    Write-Host ""
    Write-Host "       1.2  Полная диагностика (HTTP + DNS)"
    Write-Host "            • Для каждого сайта: HTTP-доступность + разрешение имени через системный DNS"
    Write-Host "              и все DNS из dns_targets.txt."
    Write-Host "            • Выводится таблица: сайт, HTTP-статус, для каждого DNS – IP и время ответа."
    Write-Host "            • При расхождении IP между разными DNS добавляется пометка !!!."
    Write-Host "            • Настройка: те же таймауты HTTP и DNS (см. выше)."
    Write-Host ""
    Write-Host "       1.3  Полная диагностика (свой хост)"
    Write-Host "            • То же, что 1.2, но для одного введённого вручную домена/IP."
    Write-Host ""
    Write-Host "    2 → Трассировка (TCP, утилита nexttrace):"
    Write-Host "       2.1  Трассировка (из списка)"
    Write-Host "            • Выполняет TCP-трассировку до каждой цели из trace_targets.txt (порт 22)."
    Write-Host "            • Отображает таблицу: хоп, IP, три времени отклика (мс), геолокация/провайдер."
    Write-Host "            • Звёздочка (*) – пакет потерян или узел не отвечает."
    Write-Host "            • Для работы требуются права администратора (драйверы WinDivert/Npcap)."
    Write-Host "            • Настройки: максимальное число хопов и таймаут пинга (в меню 5, но в текущей версии не выставлены; можно изменить в config.json)."
    Write-Host ""
    Write-Host "       2.2  Трассировка (свой хост)"
    Write-Host "            • То же, но для одного IP/домена, введённого вручную."
    Write-Host ""
    Write-Host "    3 → Сканирование портов (TCP):"
    Write-Host "       3.1  Сканирование (из списка)"
    Write-Host "            • Проверяет список портов на всех IP из scan_targets.txt."
    Write-Host "            • Выводит: операционную систему (если удалось определить), количество открытых портов,"
    Write-Host "              для каждого порта – статус (ОТКРЫТ/ЗАКРЫТ) и имя сервиса."
    Write-Host "            • Для открытых портов с версией проверяет уязвимости по локальной базе CVE."
    Write-Host "            • Настройки: таймаут соединения и таймаут баннера (меню 5 → 2,3)."
    Write-Host ""
    Write-Host "       3.2  Сканирование (свой хост)"
    Write-Host "            • То же, но для одного IP/домена."
    Write-Host ""
    Write-Host "    4 → Проверка скорости интернета (LibreSpeed):"
    Write-Host "            • Использует утилиту librespeed-cli (автоматически скачивается в папку Tools)."
    Write-Host "            • Выводит: выбранный сервер (город, провайдер), пинг (ms), скорость загрузки и отдачи (Mbit/s)."
    Write-Host "            • Пример вывода:"
    Write-Host "                Сервер:      Frankfurt, Germany (Clouvider)"
    Write-Host "                Пинг:          111,55 ms"
    Write-Host "                Загрузка:       57,52 Mbit/s"
    Write-Host "                Отдача:         69,23 Mbit/s"
    Write-Host "            • В РФ для стабильной работы рекомендуется использовать VPN."
    Write-Host "            • Настройки: количество повторных попыток (в config.json)."
    Write-Host ""
    Write-Host "    5 → Настройки:"
    Write-Host "       5.1  Показать текущие настройки (таймауты, срок хранения логов)."
    Write-Host "       5.2  Изменить таймаут TCP-соединения (ConnectionTimeout) – влияет на сканирование портов."
    Write-Host "       5.3  Изменить таймаут баннера (BannerTimeout) – ожидание приветствия после подключения."
    Write-Host "       5.4  Изменить таймаут HTTP-запроса (HttpTimeout) – для проверки сайтов."
    Write-Host "       5.5  Изменить период хранения логов (MaxLogAgeDays) – логи старше удаляются при запуске."
    Write-Host "       5.6  Сбросить настройки по умолчанию."
    Write-Host "       5.7  Инструкция (этот текст)."
    Write-Host "       5.8  Проверить обновления – сравнивает версию с GitHub и предлагает обновить весь скрипт."
    Write-Host ""
    Write-Host "5. ПРИМЕЧАНИЯ:"
    Write-Host "   ----------------------------------------------------------------"
    Write-Host "   • При первом запуске создаются пустые файлы настроек. Заполните их данными."
    Write-Host "   • Отчёты автоматически сортируются по типу подключения и активному VPN."
    Write-Host "   • Логи старше заданного количества дней удаляются автоматически."
    Write-Host "   • TCP-трассировка требует прав администратора (для драйверов WinDivert/Npcap)."
    Write-Host "   • Для работы speedtest необходима утилита librespeed-cli (скачивается автоматически)."
    Write-Host ""
    Write-Host "Нажмите Enter, чтобы вернуться в меню..." -ForegroundColor Gray
    Read-Host | Out-Null
}
        
        "8" {
            Check-ForUpdates
        }
        "0" {}
                    default {
                        Write-Host "Неверный ввод, попробуйте снова." -ForegroundColor Red
                    }
                }
            } 
                while ($choice_settings -ne "0")
        }        
        "0" {
            Write-Host "Работа завершена." -ForegroundColor Green
        }
        default {
            Write-Host "Неверный ввод, попробуйте снова." -ForegroundColor Red
        }
    }

        if ($choice -ne "0" -and $choice -ne "1" -and $choice -ne "2" -and $choice -ne "3" -and $choice -ne "5") {
        Write-Log "`n========================================================" -Color Cyan -LogFile $logFile
        Write-Log "Отчёт сохранён в файл:" -Color Cyan -LogFile $logFile
        Write-Log "   $logFile" -Color Yellow -LogFile $logFile
        Write-Log "========================================================" -Color Cyan -LogFile $logFile
        Write-Host "`nНажмите Enter для продолжения..." -ForegroundColor Gray
        Read-Host | Out-Null
    }
    
} while ($choice -ne "0")

