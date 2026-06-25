# ============================================================
# MediaServer Process Monitor  v1.0.0
# Captures process-level and system-level performance counters
# to diagnose MediaServer crashes and resource exhaustion.
#
# Usage:
#   .\monitor-mediaserver.ps1
#   .\monitor-mediaserver.ps1 -ProcessName "mediaserver" -SampleIntervalSec 2 -OutputDir "C:\logs"
#   .\monitor-mediaserver.ps1 -MediaServerUrl "http://localhost:14000" -HealthCheck
#
# Config-driven (from config.json MonitorProcess section):
#   .\monitor-mediaserver.ps1 -ConfigPath ".\config.json"
# ============================================================

param(
    [string]$ConfigPath = "",
    [string]$ProcessName = "mediaserver",
    [string]$MediaServerUrl = "http://localhost:14000",
    [int]$SampleIntervalSec = 2,
    [string]$OutputDir = "",
    [string]$CrashDumpDir = "",
    [switch]$HealthCheck
)

# ── Load from config.json if provided ──
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    try {
        $cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg.MonitorProcess) {
            if ($cfg.MonitorProcess.ProcessName)       { $ProcessName       = $cfg.MonitorProcess.ProcessName }
            if ($cfg.MonitorProcess.SampleIntervalSec)  { $SampleIntervalSec  = [int]$cfg.MonitorProcess.SampleIntervalSec }
            if ($cfg.MonitorProcess.OutputDir)          { $OutputDir          = $cfg.MonitorProcess.OutputDir }
            if ($cfg.MonitorProcess.CrashDumpDir)       { $CrashDumpDir       = $cfg.MonitorProcess.CrashDumpDir }
            if ($cfg.MonitorProcess.MediaServerUrl)     { $MediaServerUrl     = $cfg.MonitorProcess.MediaServerUrl }
            if ($cfg.MonitorProcess.HealthCheck -ne $null) { $HealthCheck    = [bool]$cfg.MonitorProcess.HealthCheck }
        }
    } catch {
        Write-Warning "Failed to parse config.json: $($_.Exception.Message) — using defaults"
    }
}

# ── Defaults ──
if (-not $OutputDir) {
    $OutputDir = Join-Path $PSScriptRoot "monitor_logs"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$csvPath  = Join-Path $OutputDir "mediaserver_monitor_$timestamp.csv"
$summaryPath = Join-Path $OutputDir "mediaserver_monitor_$timestamp.summary.json"
$dumpLogPath = Join-Path $OutputDir "mediaserver_monitor_$timestamp.dumps.log"

# ── Header ──
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      MediaServer Process Monitor  v1.0.0             ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Process:        $ProcessName" -ForegroundColor White
Write-Host "  Sample Interval: ${SampleIntervalSec}s" -ForegroundColor White
Write-Host "  Health Check:    $(if($HealthCheck){'Enabled (' + $MediaServerUrl + ')'}else{'Disabled'})" -ForegroundColor White
Write-Host "  Output Dir:      $OutputDir" -ForegroundColor White
Write-Host "  Crash Dump Dir:  $(if($CrashDumpDir){$CrashDumpDir}else{'Not monitored'})" -ForegroundColor White
Write-Host ""

# ── Find the target process ──
$targetProcess = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $targetProcess) {
    # Try with .exe suffix
    $targetProcess = Get-Process -Name "$ProcessName" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $targetProcess) {
    # Try wildcard match
    $targetProcess = Get-Process | Where-Object { $_.ProcessName -like "*$ProcessName*" } | Select-Object -First 1
}

if (-not $targetProcess) {
    Write-Host "[ERROR] Process '$ProcessName' not found. Waiting for it to start..." -ForegroundColor Red
    Write-Host "        Monitoring will begin when the process appears." -ForegroundColor Yellow
    $processFound = $false
} else {
    $processFound = $true
    Write-Host "[INFO] Found process: $($targetProcess.ProcessName) (PID: $($targetProcess.Id))" -ForegroundColor Green
    Write-Host "       Start Time: $($targetProcess.StartTime)" -ForegroundColor Gray
    Write-Host "       Command:    $($targetProcess.MainModule.FileName)" -ForegroundColor Gray
}

# ── Initialize CSV with headers ──
$csvHeaders = @(
    "Timestamp", "ElapsedSec",
    "PID", "ProcessName",
    "CPU_Pct", "CPU_TimeSec",
    "WorkingSet_MB", "PrivateMemory_MB", "VirtualMemory_MB",
    "PeakWorkingSet_MB", "PagedMemory_MB",
    "HandleCount", "ThreadCount",
    "GDIObjects", "USERObjects",
    "ReadOps", "WriteOps", "ReadBytes_MB", "WriteBytes_MB",
    "System_CPU_Pct", "System_MemAvail_MB", "System_MemTotal_MB",
    "Process_Responding", "HealthCheck_HTTP", "HealthCheck_Ms",
    "ProcessExists"
)
$csvHeaders -join "," | Out-File -FilePath $csvPath -Encoding UTF8

# ── State variables ──
$startTime = Get-Date
$sampleCount = 0
$lastReadOps = 0
$lastWriteOps = 0
$lastCPUTime = [TimeSpan]::Zero
$lastSampleTime = $startTime
$healthFailures = 0
$consecutiveHealthFailures = 0
$processExitDetected = $false
$processExitTime = $null
$processExitCode = $null
$seenDumps = @{}

# Get total system memory once
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$totalSystemMemMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 0)

Write-Host ""
Write-Host "═══════════ Monitoring Started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ═══════════" -ForegroundColor Cyan
Write-Host ""

# ── Main monitoring loop ──
while ($true) {
    $now = Get-Date
    $elapsedSec = [math]::Round(($now - $startTime).TotalSeconds, 1)

    # ── Resolve process (may have restarted) ──
    if (-not $processFound -or $processExitDetected) {
        $targetProcess = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $targetProcess) {
            $targetProcess = Get-Process | Where-Object { $_.ProcessName -like "*$ProcessName*" } | Select-Object -First 1
        }
        if ($targetProcess) {
            if ($processExitDetected) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Process RESTARTED — PID: $($targetProcess.Id)" -ForegroundColor Yellow
                $processExitDetected = $false
                # Reset I/O baselines for new process
                $lastReadOps = 0; $lastWriteOps = 0; $lastCPUTime = [TimeSpan]::Zero
                $lastSampleTime = $now
            } else {
                $processFound = $true
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Process FOUND — PID: $($targetProcess.Id)" -ForegroundColor Green
            }
        }
    }

    $pidVal = 0
    $procNameStr = "-"
    $cpuPct = 0
    $cpuTimeSec = 0
    $wsMB = 0
    $privMB = 0
    $vmemMB = 0
    $peakWSMB = 0
    $pagedMB = 0
    $handles = 0
    $threads = 0
    $gdiObj = 0
    $userObj = 0
    $readOps = 0
    $writeOps = 0
    $readMB = 0
    $writeMB = 0
    $responding = $false
    $healthHttp = "-"
    $healthMs = 0
    $procExists = $false

    if ($targetProcess -and -not $processExitDetected) {
        try {
            # Refresh process info (needed for CPU calc)
            $targetProcess.Refresh()

            # Check if process exited
            if ($targetProcess.HasExited) {
                $processExitDetected = $true
                $processExitTime = $targetProcess.ExitTime
                try { $processExitCode = $targetProcess.ExitCode } catch { $processExitCode = "unknown" }
                Write-Host ""
                Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Red
                Write-Host "║  PROCESS EXIT DETECTED                               ║" -ForegroundColor Red
                Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Red
                Write-Host "  Exit Time:   $processExitTime" -ForegroundColor Red
                Write-Host "  Exit Code:   $processExitCode" -ForegroundColor Red
                Write-Host "  Runtime:     $([math]::Round(($processExitTime - $targetProcess.StartTime).TotalMinutes, 1)) minutes" -ForegroundColor Red
                Write-Host "  Samples:     $sampleCount" -ForegroundColor Red
                Write-Host ""
                # Still log this row with the exit info
                $procExists = $false
            } else {
                $procExists = $true
                $pidVal = $targetProcess.Id
                $procNameStr = $targetProcess.ProcessName

                # CPU calculation (delta between samples)
                $currentCPUTime = $targetProcess.TotalProcessorTime
                $timeDelta = ($now - $lastSampleTime).TotalSeconds
                if ($timeDelta -gt 0 -and $lastCPUTime -ne [TimeSpan]::Zero) {
                    $cpuDelta = ($currentCPUTime - $lastCPUTime).TotalMilliseconds
                    $cpuPct = [math]::Round(($cpuDelta / ($timeDelta * 1000)) * 100 / [Environment]::ProcessorCount, 2)
                    if ($cpuPct -lt 0) { $cpuPct = 0 }
                }
                $lastCPUTime = $currentCPUTime
                $cpuTimeSec = [math]::Round($currentCPUTime.TotalSeconds, 1)

                # Memory
                $wsMB    = [math]::Round($targetProcess.WorkingSet64 / 1MB, 1)
                $privMB  = [math]::Round($targetProcess.PrivateMemorySize64 / 1MB, 1)
                $vmemMB  = [math]::Round($targetProcess.VirtualMemorySize64 / 1MB, 1)
                $peakWSMB = [math]::Round($targetProcess.PeakWorkingSet64 / 1MB, 1)
                $pagedMB  = [math]::Round($targetProcess.PagedMemorySize64 / 1MB, 1)

                # Handles & threads
                $handles = $targetProcess.HandleCount
                $threads = $targetProcess.Threads.Count

                # GDI/USER objects (may fail on some systems)
                try {
                    $gdiObj  = (Get-Process -Id $targetProcess.Id).GDIObjects
                    $userObj = (Get-Process -Id $targetProcess.Id).USERObjects
                } catch { $gdiObj = 0; $userObj = 0 }

                # I/O counters
                try {
                    $readOps  = $targetProcess.ReadOperationCount
                    $writeOps = $targetProcess.WriteOperationCount
                    if ($lastReadOps -gt 0) {
                        $readMB  = [math]::Round(($targetProcess.ReadTransferCount - ($lastReadOps * 1MB)) / 1MB, 2) # approximate
                    }
                    if ($lastWriteOps -gt 0) {
                        $writeMB = [math]::Round(($targetProcess.WriteTransferCount - ($lastWriteOps * 1MB)) / 1MB, 2)
                    }
                    $lastReadOps  = $targetProcess.ReadOperationCount
                    $lastWriteOps = $targetProcess.WriteOperationCount
                    # Real I/O byte counters
                    $readMB  = [math]::Round($targetProcess.ReadTransferCount / 1MB, 2)
                    $writeMB = [math]::Round($targetProcess.WriteTransferCount / 1MB, 2)
                } catch { }

                # Responsive?
                try { $responding = $targetProcess.Responding } catch { $responding = $false }

                # Progress indicator
                if ($sampleCount -eq 0) {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] PID=$pidVal | CPU=$cpuPct% | WS=$wsMB MB | Threads=$threads | Handles=$handles" -ForegroundColor Gray
                }
            }
        } catch {
            # Process likely exited between refresh and property access
            $procExists = $false
            if (-not $processExitDetected) {
                $processExitDetected = $true
                $processExitTime = Get-Date
                $processExitCode = "unknown (error during sampling: $($_.Exception.Message))"
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Process EXITED (detected via error): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # ── System-level counters ──
    $sysCpuPct = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $availMemMB = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
    $sysMemTotalMB = $totalSystemMemMB

    # ── Health check (optional) ──
    if ($HealthCheck) {
        try {
            $hcSw = [System.Diagnostics.Stopwatch]::StartNew()
            $hcResp = Invoke-WebRequest -Uri "$MediaServerUrl/action=getstatus" -Method Get -TimeoutSec 5 -UseBasicParsing
            $hcSw.Stop()
            $healthHttp = $hcResp.StatusCode
            $healthMs = $hcSw.ElapsedMilliseconds
            $consecutiveHealthFailures = 0
        } catch {
            $healthHttp = "FAIL"
            $healthMs = 0
            $consecutiveHealthFailures++
            $healthFailures++
            if ($consecutiveHealthFailures -eq 1) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Health check FAILED: $($_.Exception.Message)" -ForegroundColor Yellow
            } elseif ($consecutiveHealthFailures % 10 -eq 0) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Health check FAILED ($consecutiveHealthFailures consecutive): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # ── Crash dump detection ──
    if ($CrashDumpDir -and (Test-Path $CrashDumpDir)) {
        $currentDumps = Get-ChildItem -Path $CrashDumpDir -Filter "*.dmp" -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -gt $startTime }
        foreach ($dump in $currentDumps) {
            if (-not $seenDumps.ContainsKey($dump.FullName)) {
                $seenDumps[$dump.FullName] = $true
                $dumpInfo = "DUMP FOUND: $($dump.Name) | Size: $([math]::Round($dump.Length/1MB,1)) MB | Created: $($dump.LastWriteTime)"
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $dumpInfo" -ForegroundColor Magenta
                Add-Content -Path $dumpLogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $dumpInfo"
            }
        }
    }

    # ── Write CSV row ──
    $csvRow = @(
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"),
        $elapsedSec,
        $pidVal,
        $procNameStr,
        $cpuPct,
        $cpuTimeSec,
        $wsMB,
        $privMB,
        $vmemMB,
        $peakWSMB,
        $pagedMB,
        $handles,
        $threads,
        $gdiObj,
        $userObj,
        $readOps,
        $writeOps,
        $readMB,
        $writeMB,
        $sysCpuPct,
        $availMemMB,
        $sysMemTotalMB,
        $(if ($procExists) { $responding } else { "-" }),
        $healthHttp,
        $healthMs,
        $(if ($procExists) { 1 } elseif ($processExitDetected) { 0 } else { -1 })
    )
    $csvRow -join "," | Out-File -FilePath $csvPath -Append -Encoding UTF8
    $sampleCount++

    # ── Periodic summary to console ──
    if ($sampleCount % 30 -eq 0 -and $procExists) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Sample #$sampleCount | CPU=$cpuPct% | WS=$wsMB MB (peak=$peakWSMB) | Threads=$threads | Handles=$handles | SysCPU=$sysCpuPct% | AvailMem=$availMemMB MB" -ForegroundColor Gray
    }

    # ── Stop conditions ──
    # If process exited and we've logged it, keep running briefly then exit
    if ($processExitDetected) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Process has exited. Flushing remaining data..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        break
    }

    # Graceful exit: check for stop file
    $stopFile = Join-Path $OutputDir "monitor_stop.txt"
    if (Test-Path $stopFile) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Stop signal received." -ForegroundColor Yellow
        Remove-Item $stopFile -Force
        break
    }

    Start-Sleep -Seconds $SampleIntervalSec
    $lastSampleTime = $now
}

# ── Generate summary JSON ──
Write-Host ""
Write-Host "═══════════ Generating Summary ═══════════" -ForegroundColor Cyan

$csvData = Import-Csv -Path $csvPath
$procRows = $csvData | Where-Object { $_.ProcessExists -eq "1" }

$summary = [PSCustomObject]@{
    MonitorStartTime     = $startTime.ToString("yyyy-MM-dd HH:mm:ss")
    MonitorEndTime       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    TotalDurationSec     = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    TotalSamples         = $sampleCount
    ProcessName          = $ProcessName
    ProcessExitDetected  = $processExitDetected
    ProcessExitTime      = if ($processExitTime) { $processExitTime.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
    ProcessExitCode      = $processExitCode
    MaxCPU_Pct           = if ($procRows.Count) { [math]::Round(($procRows | ForEach-Object { [double]$_.CPU_Pct } | Measure-Object -Maximum).Maximum, 2) } else { 0 }
    AvgCPU_Pct           = if ($procRows.Count) { [math]::Round(($procRows | ForEach-Object { [double]$_.CPU_Pct } | Measure-Object -Average).Average, 2) } else { 0 }
    MaxWorkingSet_MB     = if ($procRows.Count) { [math]::Round(($procRows | ForEach-Object { [double]$_.WorkingSet_MB } | Measure-Object -Maximum).Maximum, 1) } else { 0 }
    AvgWorkingSet_MB     = if ($procRows.Count) { [math]::Round(($procRows | ForEach-Object { [double]$_.WorkingSet_MB } | Measure-Object -Average).Average, 1) } else { 0 }
    MaxPrivateMemory_MB  = if ($procRows.Count) { [math]::Round(($procRows | ForEach-Object { [double]$_.PrivateMemory_MB } | Measure-Object -Maximum).Maximum, 1) } else { 0 }
    MaxVirtualMemory_MB  = if ($procRows.Count) { [math]::Round(($procRows | ForEach-Object { [double]$_.VirtualMemory_MB } | Measure-Object -Maximum).Maximum, 1) } else { 0 }
    PeakWorkingSet_MB    = if ($procRows.Count) { [math]::Round(($procRows | ForEach-Object { [double]$_.PeakWorkingSet_MB } | Measure-Object -Maximum).Maximum, 1) } else { 0 }
    MaxHandles           = if ($procRows.Count) { ($procRows | ForEach-Object { [int]$_.HandleCount } | Measure-Object -Maximum).Maximum } else { 0 }
    MaxThreads           = if ($procRows.Count) { ($procRows | ForEach-Object { [int]$_.ThreadCount } | Measure-Object -Maximum).Maximum } else { 0 }
    MaxGDIObjects        = if ($procRows.Count) { ($procRows | ForEach-Object { [int]$_.GDIObjects } | Measure-Object -Maximum).Maximum } else { 0 }
    MaxUSERObjects       = if ($procRows.Count) { ($procRows | ForEach-Object { [int]$_.USERObjects } | Measure-Object -Maximum).Maximum } else { 0 }
    FinalWorkingSet_MB   = if ($procRows.Count) { [double]($procRows | Select-Object -Last 1).WorkingSet_MB } else { 0 }
    FinalPrivateMemory_MB= if ($procRows.Count) { [double]($procRows | Select-Object -Last 1).PrivateMemory_MB } else { 0 }
    SystemMaxCPU_Pct     = if ($procRows.Count) { [math]::Round(($procRows | ForEach-Object { [double]$_.System_CPU_Pct } | Measure-Object -Maximum).Maximum, 2) } else { 0 }
    SystemMinAvailMem_MB = if ($procRows.Count) { [math]::Round(($procRows | ForEach-Object { [double]$_.System_MemAvail_MB } | Measure-Object -Minimum).Minimum, 0) } else { 0 }
    HealthChecksFailed   = $healthFailures
    HealthChecksTotal    = if ($HealthCheck -and $procRows.Count) { ($csvData | Where-Object { $_.HealthCheck_HTTP -ne "-" }).Count } else { 0 }
    CsvPath              = $csvPath
    SummaryPath          = $summaryPath
    DumpLogPath           = if ($CrashDumpDir) { $dumpLogPath } else { $null }
}

$summary | ConvertTo-Json -Depth 3 | Out-File -FilePath $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "═══════════ Monitoring Complete ═══════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Samples:           $sampleCount" -ForegroundColor White
Write-Host "  Duration:          $($summary.TotalDurationSec)s" -ForegroundColor White
Write-Host "  Process Exit:      $processExitDetected" -ForegroundColor $(if($processExitDetected){'Red'}else{'Green'})
if ($processExitDetected) {
    Write-Host "  Exit Time:         $processExitTime" -ForegroundColor Red
    Write-Host "  Exit Code:         $processExitCode" -ForegroundColor Red
}
Write-Host ""
Write-Host "  Max CPU:           $($summary.MaxCPU_Pct)%" -ForegroundColor White
Write-Host "  Avg CPU:           $($summary.AvgCPU_Pct)%" -ForegroundColor White
Write-Host "  Max Working Set:   $($summary.MaxWorkingSet_MB) MB" -ForegroundColor $(if($summary.MaxWorkingSet_MB -gt 2000){'Red'}else{'White'})
Write-Host "  Avg Working Set:   $($summary.AvgWorkingSet_MB) MB" -ForegroundColor White
Write-Host "  Max Private Mem:   $($summary.MaxPrivateMemory_MB) MB" -ForegroundColor $(if($summary.MaxPrivateMemory_MB -gt 2000){'Red'}else{'White'})
Write-Host "  Max Virtual Mem:   $($summary.MaxVirtualMemory_MB) MB" -ForegroundColor White
Write-Host "  Max Handles:       $($summary.MaxHandles)" -ForegroundColor $(if($summary.MaxHandles -gt 10000){'Red'}else{'White'})
Write-Host "  Max Threads:       $($summary.MaxThreads)" -ForegroundColor $(if($summary.MaxThreads -gt 500){'Red'}else{'White'})
Write-Host "  Max GDI Objects:   $($summary.MaxGDIObjects)" -ForegroundColor White
Write-Host "  Max USER Objects:  $($summary.MaxUSERObjects)" -ForegroundColor White
Write-Host ""
Write-Host "  System Max CPU:    $($summary.SystemMaxCPU_Pct)%" -ForegroundColor White
Write-Host "  System Min Avail Mem: $($summary.SystemMinAvailMem_MB) MB" -ForegroundColor $(if($summary.SystemMinAvailMem_MB -lt 500){'Red'}else{'White'})
if ($HealthCheck) {
    Write-Host "  Health Failures:   $($summary.HealthChecksFailed) / $($summary.HealthChecksTotal)" -ForegroundColor $(if($healthFailures -gt 0){'Red'}else{'Green'})
}
Write-Host ""
Write-Host "  CSV Data:          $csvPath" -ForegroundColor Cyan
Write-Host "  Summary JSON:      $summaryPath" -ForegroundColor Cyan
if ($CrashDumpDir) {
    Write-Host "  Dump Log:          $dumpLogPath" -ForegroundColor Cyan
}
Write-Host ""

# Return summary as output object
return $summary
