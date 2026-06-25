# FaceDetection_ObjectRecognition F1 Benchmark Suite  v1.4.0
# Tests the pipeline against True Positive and False Positive file sets
# Generates a detailed HTML report with F1 score and optimization insights

param(
    [string]$MediaServerUrl,
    [string]$ConfigName,
    [string]$TPFolder,
    [string]$FPFolder,
    [string]$OutputReport,
    [int]$TimeoutSec = 120,
    [int]$ThreadCount = 0,
    [int]$LoadTestIterations = 0,
    [switch]$UseHttps,
    [switch]$Debug
)

# Load environment-specific settings from config.json (located next to this script)
$configPath = Join-Path $PSScriptRoot "config.json"
$configDefaults = @{
    MediaServerUrl = "http://localhost:14000"
    ConfigName     = "FaceDetection_ObjectRecognition"
    TPFolder       = "C:\IDOL\images\TP"
    FPFolder       = "C:\IDOL\images\FP"
    OutputReport   = "C:\IDOL\code\reports\f1_face_object_report.html"
    UseHttps       = $false
    MediaServerOutputDir = "C:\IDOL\MediaServer_26.2.0_WINDOWS_X86_64\output"
    PassportIdentityPattern = "AUS_Passport"
    PassportDatabasePattern = "Documents"
    ThreadCount    = 1
    LoadTestIterations = 1
    MonitorEnabled = $true
    AutoStart    = $false
    MediaServerActionsDir = "C:\IDOL\MediaServer_26.2.0_WINDOWS_X86_64\actions"
    MediaServerLogsDir    = "C:\IDOL\MediaServer_26.2.0_WINDOWS_X86_64\logs"
    MediaServerStartScript = "C:\IDOL\MediaServer_26.2.0_WINDOWS_X86_64\start-mediaserver.bat"
    MediaServerProcessName = "mediaserver"
    MediaServerCrashDumpPath = "C:\IDOL\MediaServer_26.2.0_WINDOWS_X86_64\autn_report.dmp"
}

if (Test-Path $configPath) {
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    foreach ($key in $configDefaults.Keys) {
        if (-not $PSBoundParameters.ContainsKey($key)) {
            $configValue = $config.$key
            if ($null -ne $configValue) {
                if ($key -eq "UseHttps") {
                    Set-Variable -Name $key -Value ([switch]$configValue)
                } elseif ($key -eq "ThreadCount" -or $key -eq "LoadTestIterations") {
                    Set-Variable -Name $key -Value ([int]$configValue)
                } elseif ($key -eq "MonitorEnabled" -or $key -eq "AutoStart") {
                    Set-Variable -Name $key -Value ([bool]$configValue)
                } elseif ($key -eq "MediaServerActionsDir" -or $key -eq "MediaServerLogsDir" -or $key -eq "MediaServerStartScript" -or $key -eq "MediaServerProcessName" -or $key -eq "MediaServerCrashDumpPath") {
                    Set-Variable -Name $key -Value ([string]$configValue)
                } else {
                    Set-Variable -Name $key -Value ([string]$configValue)
                }
            }
        }
    }
} else {
    Write-Warning "config.json not found at $configPath — copy config.example.json to config.json and edit it"
    # Apply hardcoded fallbacks for any params not explicitly passed
    foreach ($key in $configDefaults.Keys) {
        if (-not $PSBoundParameters.ContainsKey($key)) {
            if ($key -eq "UseHttps") {
                Set-Variable -Name $key -Value ([switch]$configDefaults[$key])
            } elseif ($key -eq "ThreadCount" -or $key -eq "LoadTestIterations") {
                Set-Variable -Name $key -Value ([int]$configDefaults[$key])
            } elseif ($key -eq "MonitorEnabled" -or $key -eq "AutoStart") {
                Set-Variable -Name $key -Value ([bool]$configDefaults[$key])
            } elseif ($key -eq "MediaServerActionsDir" -or $key -eq "MediaServerLogsDir" -or $key -eq "MediaServerStartScript" -or $key -eq "MediaServerProcessName" -or $key -eq "MediaServerCrashDumpPath") {
                Set-Variable -Name $key -Value $configDefaults[$key]
            } else {
                Set-Variable -Name $key -Value $configDefaults[$key]
            }
        }
    }
}

# Convert URL scheme from HTTP to HTTPS when the -UseHttps flag is set
if ($UseHttps) {
    $MediaServerUrl = $MediaServerUrl -replace '^http://', 'https://'
}

# Validate and clamp concurrency settings
if ($ThreadCount -lt 1) { $ThreadCount = 1 }
if ($LoadTestIterations -lt 1) { $LoadTestIterations = 1 }
$ThreadCount = [int]$ThreadCount
$LoadTestIterations = [int]$LoadTestIterations

# Store flags in script scope so functions can access them
$script:Debug = $Debug

$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = (Get-Date -Format "HH:mm:ss.fff")
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "PASS"  { "Green" }
        "FAIL"  { "Red" }
        "DEBUG" { "Magenta" }
        default { "White" }
    }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

function Write-DebugLog {
    param([string]$Message)
    if ($script:Debug) {
        Write-Log -Message $Message -Level "DEBUG"
    }
}

# ============================================================
# MEDIA SERVER API CALL
# ============================================================

function Invoke-MediaServerProcess {
    param(
        [string]$FilePath,
        [string]$Config,
        [int]$Timeout = 120,
        [string]$MediaServerUrlParam = $MediaServerUrl,
        [string]$MediaServerOutputDirParam = $MediaServerOutputDir,
        [string]$PassportIdentityPatternParam = $PassportIdentityPattern,
        [string]$PassportDatabasePatternParam = $PassportDatabasePattern,
        [bool]$DebugParam = $Debug
    )
    
    $result = [PSCustomObject]@{
        Success          = $false
        StatusCode       = 0
        RawXml           = ""
        SessionToken     = ""
        OutputFilePath   = ""
        FaceDetected     = $false
        FaceCount        = 0
        FaceConfidence   = 0.0
        FaceDetails      = @()
        ObjectRecognized = $false
        ObjectCount      = 0
        ObjectConfidence = 0.0
        ObjectDetails    = @()
        PassportDetected = $false
        ErrorMessage     = ""
        ResponseTimeMs   = 0
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        # Submit async job: Synchronous=false returns token immediately
        $uri = "$MediaServerUrlParam/action=process&Source=$([uri]::EscapeDataString($FilePath))&ConfigName=$Config&Synchronous=false"
        if ($DebugParam) { Write-Host "[DEBUG] URI (async submit): $uri" -ForegroundColor Magenta }
        
        $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $Timeout -UseBasicParsing
        $result.StatusCode = $response.StatusCode
        $result.RawXml = $response.Content
        
        if ($DebugParam) { Write-Host "[DEBUG] Async submit HTTP $($response.StatusCode) | ContentLength: $($response.Content.Length) chars" -ForegroundColor Magenta }

        if ($response.StatusCode -eq 200) {
            # Extract session token from response
            if ($response.Content -match '<token>([^<]+)</token>') {
                $result.SessionToken = $Matches[1]
                if ($DebugParam) { Write-Host "[DEBUG] SessionToken extracted: $($result.SessionToken)" -ForegroundColor Magenta }
            } else {
                if ($DebugParam) { Write-Host "[DEBUG] WARNING: No <token> found in response. Raw XML (first 500 chars): $($response.Content.Substring(0, [Math]::Min(500, $response.Content.Length)))" -ForegroundColor Magenta }
                return $result
            }
            
            # Check for error in response before continuing
            if ($response.Content -match '<response>ERROR</response>' -or $response.Content -match '<error>') {
                $result.ErrorMessage = "Media Server returned error on submit"
                if ($response.Content -match '<errorstring>([^<]+)</errorstring>') {
                    $result.ErrorMessage = $Matches[1]
                }
                return $result
            }
            
            # Poll for completion: repeatedly check queue status until Finished or timeout
            $pollIntervalMs = 500
            $maxPollMs = $Timeout * 1000
            $elapsedPollMs = 0
            
            while ($elapsedPollMs -lt $maxPollMs) {
                Start-Sleep -Milliseconds $pollIntervalMs
                $elapsedPollMs += $pollIntervalMs
                
                try {
                    $pollUri = "$MediaServerUrlParam/action=queueinfo&QueueName=Process&QueueAction=getstatus&token=$($result.SessionToken)"
                    $pollResponse = Invoke-WebRequest -Uri $pollUri -Method Get -TimeoutSec 10 -UseBasicParsing
                    
                    if ($DebugParam) { Write-Host "[DEBUG] Poll ${elapsedPollMs}ms: HTTP $($pollResponse.StatusCode)" -ForegroundColor Magenta }
                    
                    if ($pollResponse.StatusCode -eq 200) {
                        # Check for Finished status
                        if ($pollResponse.Content -match '<status>Finished</status>' -or $pollResponse.Content -match '<status>Processed</status>') {
                            if ($DebugParam) { Write-Host "[DEBUG] Job finished after ${elapsedPollMs}ms" -ForegroundColor Magenta }
                            $result.Success = $true
                            break
                        }
                        # Check for error status
                        if ($pollResponse.Content -match '<status>Error</status>' -or $pollResponse.Content -match '<status>Failed</status>') {
                            $result.ErrorMessage = "Media Server job failed"
                            if ($pollResponse.Content -match '<errorstring>([^<]+)</errorstring>') {
                                $result.ErrorMessage = $Matches[1]
                            }
                            if ($DebugParam) { Write-Host "[DEBUG] Job FAILED: $($result.ErrorMessage)" -ForegroundColor Red }
                            $sw.Stop()
                            $result.ResponseTimeMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
                            return $result
                        }
                    }
                } catch {
                    if ($DebugParam) { Write-Host "[DEBUG] Poll error (will retry): $($_.Exception.Message)" -ForegroundColor Magenta }
                    # Continue polling — transient network issue
                }
            }
            
            $sw.Stop()
            $result.ResponseTimeMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
            
            if (-not $result.Success) {
                $result.ErrorMessage = "Async job timed out after $Timeout seconds"
                return $result
            }
            
            # Read the output XML file written to disk by the async job
            if ($result.SessionToken) {
                $outputFile = Join-Path $MediaServerOutputDirParam "$($result.SessionToken)\face_object.xml"
                if ($DebugParam) { Write-Host "[DEBUG] Looking for output file: $outputFile" -ForegroundColor Magenta }
                if (Test-Path $outputFile) {
                    $result.OutputFilePath = $outputFile
                    $outputXml = Get-Content -Path $outputFile -Raw -Encoding UTF8
                    if ($DebugParam) { Write-Host "[DEBUG] Output file found | Size: $($outputXml.Length) chars" -ForegroundColor Magenta }
                    if ($DebugParam) { Write-Host "[DEBUG] Output XML (first 1000 chars): $($outputXml.Substring(0, [Math]::Min(1000, $outputXml.Length)))" -ForegroundColor Magenta }
                    Parse-MediaServerResponse -Result $result -XmlContent $outputXml -PassportIdentityPatternParam $PassportIdentityPatternParam -PassportDatabasePatternParam $PassportDatabasePatternParam -DebugParam $DebugParam
                } else {
                    if ($DebugParam) { Write-Host "[DEBUG] WARNING: Output file NOT found at: $outputFile" -ForegroundColor Magenta }
                    # List what's in the output directory to help diagnose
                    $parentDir = Split-Path $outputFile -Parent
                    if (Test-Path $parentDir) {
                        $contents = (Get-ChildItem $parentDir -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ", "
                        if ($DebugParam) { Write-Host "[DEBUG] Directory contents of $parentDir : $contents" -ForegroundColor Magenta }
                    } else {
                        if ($DebugParam) { Write-Host "[DEBUG] Parent directory $parentDir does not exist" -ForegroundColor Magenta }
                    }
                    $result.ErrorMessage += " | Output file not found: $outputFile"
                }
            }
        }
    }
    catch [System.Net.WebException] {
        $sw.Stop()
        $result.ResponseTimeMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        $result.ErrorMessage = $_.Exception.Message
        if ($_.Exception.Response) {
            $result.StatusCode = [int]$_.Exception.Response.StatusCode
        }
    }
    catch {
        $sw.Stop()
        $result.ResponseTimeMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        $result.ErrorMessage = $_.Exception.Message
    }

    return $result
}

# ============================================================
# XML RESPONSE PARSING
# ============================================================

function Parse-MediaServerResponse {
    param(
        [PSCustomObject]$Result,
        [string]$XmlContent,
        [string]$PassportIdentityPatternParam = $PassportIdentityPattern,
        [string]$PassportDatabasePatternParam = $PassportDatabasePattern,
        [bool]$DebugParam = $Debug
    )

    try {
        [xml]$xml = $XmlContent

        # List all track names found in the XML
        $allTracks = Select-Xml -Xml $xml -XPath "//track" | ForEach-Object { $_.Node.name }
        if ($DebugParam) { Write-Host "[DEBUG] Tracks found in output XML: $($allTracks -join ', ')" -ForegroundColor Magenta }

        # --- Parse Face Detection Results ---
        # Face data is in <track name="FaceDetect.Result">/<record>/<FaceResult>/<face>
        $faceResults = Select-Xml -Xml $xml -XPath "//track[@name='FaceDetect.Result']/record/FaceResult"
        if ($DebugParam) { Write-Host "[DEBUG] FaceDetect.Result XPath returned: $($faceResults.Count) FaceResult node(s)" -ForegroundColor Magenta }
        if ($faceResults) {
            $Result.FaceDetected = $true
            $Result.FaceCount = $faceResults.Count
            
            $faceConfidences = @()
            foreach ($fr in $faceResults) {
                $face = $fr.Node.face
                $faceInfo = [PSCustomObject]@{
                    Confidence        = if ($face.confidence) { [double]$face.confidence } else { 0 }
                    OutOfPlaneAngleX  = if ($face.outOfPlaneAngleX) { [double]$face.outOfPlaneAngleX } else { 0 }
                    OutOfPlaneAngleY  = if ($face.outOfPlaneAngleY) { [double]$face.outOfPlaneAngleY } else { 0 }
                    PercentageInImage = if ($face.percentageInImage) { [double]$face.percentageInImage } else { 0 }
                }
                if ($DebugParam) { Write-Host "[DEBUG] Face #$($faceConfidences.Count+1): confidence=$($faceInfo.Confidence)% angleX=$($faceInfo.OutOfPlaneAngleX) angleY=$($faceInfo.OutOfPlaneAngleY) sizeInImg=$($faceInfo.PercentageInImage)%" -ForegroundColor Magenta }
                $Result.FaceDetails += $faceInfo
                $faceConfidences += $faceInfo.Confidence
            }
            $Result.FaceConfidence = [math]::Round(($faceConfidences | Measure-Object -Average).Average, 2)
        }

        # --- Parse Object Recognition Results ---
        # Object data is in <track name="ObjectRecognize.Result">/<record>/<ObjectRecognitionResult>
        $objResults = Select-Xml -Xml $xml -XPath "//track[@name='ObjectRecognize.Result']/record/ObjectRecognitionResult"
        if ($DebugParam) { Write-Host "[DEBUG] ObjectRecognize.Result XPath returned: $($objResults.Count) ObjectRecognitionResult node(s)" -ForegroundColor Magenta }
        if ($objResults) {
            $Result.ObjectRecognized = $true
            
            $objConfidences = @()
            foreach ($or in $objResults) {
                $identity = $or.Node.identity
                $identName = if ($identity.identifier) { $identity.identifier } else { "Unknown" }
                $identDB   = if ($identity.database) { $identity.database } else { "" }
                $identConf = if ($identity.confidence) { [double]$identity.confidence } else { 0 }
                
                if ($DebugParam) { Write-Host "[DEBUG] ObjectRecognition: identity='$identName' db='$identDB' confidence=$identConf (threshold=55)" -ForegroundColor Magenta }
                
                # Confidence threshold filter: only count results >= 55
                if ($identConf -lt 55) {
                    if ($DebugParam) { Write-Host "[DEBUG]   -> Filtered OUT (below threshold)" -ForegroundColor Magenta }
                    continue
                }
                
                $objInfo = [PSCustomObject]@{
                    Identity   = "$identName ($identDB)"
                    Confidence = $identConf
                }
                $Result.ObjectDetails += $objInfo
                $objConfidences += $identConf
                
                # Check if any recognized object is passport-related
                if ($identName -match $PassportIdentityPatternParam -or $identDB -match $PassportDatabasePatternParam) {
                    $Result.PassportDetected = $true
                }
            }
            $Result.ObjectCount = $objConfidences.Count
            $Result.ObjectConfidence = if ($objConfidences.Count -gt 0) { [math]::Round(($objConfidences | Measure-Object -Average).Average, 2) } else { 0 }
        }
    }
    catch {
        $Result.ErrorMessage += " | XML Parse: $($_.Exception.Message)"
    }
}

# ============================================================
# PARALLEL FILE PROCESSING — Batch Async (Submit All → Poll All → Parse All)
# ============================================================

function Invoke-ParallelFileSet {
    param(
        [array]$Files,
        [string]$SetLabel,
        [int]$ThreadCount,
        [string]$MediaServerUrl,
        [string]$ConfigName,
        [int]$TimeoutSec,
        [string]$MediaServerOutputDir,
        [string]$PassportIdentityPattern,
        [string]$PassportDatabasePattern,
        [bool]$Debug
    )

    Write-Log "Processing $($Files.Count) files from [$SetLabel] set with $ThreadCount concurrent threads (batch-async)..." "INFO"

    $psVersion = $PSVersionTable.PSVersion.Major
    $useForEachParallel = ($psVersion -ge 7)

    # ── Phase 1: Submit ALL files in parallel (Synchronous=false → immediate tokens) ──
    Write-Log "[Phase 1/3] Submitting $($Files.Count) files in parallel..." "INFO"
    $phase1Sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($useForEachParallel) {
        $submissions = $Files | ForEach-Object -ThrottleLimit $ThreadCount -Parallel {
            $file = $_
            $submitMs = 0
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $uri = "$($using:MediaServerUrl)/action=process&Source=$([uri]::EscapeDataString($file.FullName))&ConfigName=$($using:ConfigName)&Synchronous=false"
                $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $using:TimeoutSec -UseBasicParsing
                $sw.Stop(); $submitMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
                $token = ""; $error = ""
                if ($response.StatusCode -eq 200) {
                    if ($response.Content -match '<token>([^<]+)</token>') { $token = $Matches[1] }
                    else { $error = "No token in submit response" }
                    if ($response.Content -match '<response>ERROR</response>' -or $response.Content -match '<error>') {
                        $error = "Server error on submit"
                        if ($response.Content -match '<errorstring>([^<]+)</errorstring>') { $error = $Matches[1] }
                    }
                } else { $error = "HTTP $($response.StatusCode)" }
                [PSCustomObject]@{ FileName = $file.Name; FullPath = $file.FullName; FileSizeKB = [math]::Round($file.Length/1KB,1); Extension = $file.Extension.ToLower(); Token = $token; SubmitError = $error; SubmitTimeMs = $submitMs }
            } catch {
                $sw.Stop()
                [PSCustomObject]@{ FileName = $file.Name; FullPath = $file.FullName; FileSizeKB = [math]::Round($file.Length/1KB,1); Extension = $file.Extension.ToLower(); Token = ""; SubmitError = $_.Exception.Message; SubmitTimeMs = [math]::Round($sw.Elapsed.TotalMilliseconds,1) }
            }
        }
    } else {
        # PowerShell 5.1: RunspacePool for submit phase
        $rsPool = [runspacefactory]::CreateRunspacePool(1, $ThreadCount)
        $rsPool.Open()
        $rsJobs = @()
        foreach ($file in $Files) {
            $ps = [powershell]::Create(); $ps.RunspacePool = $rsPool
            $sb = {
                param($f, $msUrl, $cfg, $to)
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $uri = "$msUrl/action=process&Source=$([uri]::EscapeDataString($f.FullName))&ConfigName=$cfg&Synchronous=false"
                    $r = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $to -UseBasicParsing
                    $sw.Stop()
                    $t = ""; $e = ""
                    if ($r.StatusCode -eq 200) {
                        if ($r.Content -match '<token>([^<]+)</token>') { $t = $Matches[1] } else { $e = "No token" }
                        if ($r.Content -match '<response>ERROR</response>') { $e = "Server error" }
                    } else { $e = "HTTP $($r.StatusCode)" }
                    [PSCustomObject]@{ Token = $t; SubmitError = $e; SubmitTimeMs = [math]::Round($sw.Elapsed.TotalMilliseconds,1) }
                } catch { $sw.Stop(); [PSCustomObject]@{ Token = ""; SubmitError = $_.Exception.Message; SubmitTimeMs = [math]::Round($sw.Elapsed.TotalMilliseconds,1) } }
            }
            [void]$ps.AddScript($sb.ToString())
            [void]$ps.AddArgument($file); [void]$ps.AddArgument($MediaServerUrl); [void]$ps.AddArgument($ConfigName); [void]$ps.AddArgument($TimeoutSec)
            $h = $ps.BeginInvoke()
            $rsJobs += [PSCustomObject]@{ PS = $ps; Handle = $h; File = $file }
        }
        $submissions = @()
        foreach ($j in $rsJobs) {
            try {
                $r = $j.PS.EndInvoke($j.Handle)
                $submissions += [PSCustomObject]@{ FileName = $j.File.Name; FullPath = $j.File.FullName; FileSizeKB = [math]::Round($j.File.Length/1KB,1); Extension = $j.File.Extension.ToLower(); Token = $r.Token; SubmitError = $r.SubmitError; SubmitTimeMs = $r.SubmitTimeMs }
            } catch {
                $submissions += [PSCustomObject]@{ FileName = $j.File.Name; FullPath = $j.File.FullName; FileSizeKB = [math]::Round($j.File.Length/1KB,1); Extension = $j.File.Extension.ToLower(); Token = ""; SubmitError = $_.Exception.Message; SubmitTimeMs = 0 }
            } finally { $j.PS.Dispose() }
        }
        $rsPool.Dispose()
    }

    $phase1Sw.Stop()
    $submitErrors = ($submissions | Where-Object { $_.SubmitError }).Count
    Write-Log "[Phase 1/3] Complete: $($submissions.Count) submitted in $($phase1Sw.ElapsedMilliseconds)ms ($submitErrors errors)" "INFO"

    # ── Phase 2: Poll ALL tokens in a single loop ──
    $validSubs = @($submissions | Where-Object { -not $_.SubmitError -and $_.Token })
    Write-Log "[Phase 2/3] Polling $($validSubs.Count) async jobs..." "INFO"
    $phase2Sw = [System.Diagnostics.Stopwatch]::StartNew()

    $pending = @($validSubs)
    $completedSubs = [System.Collections.ArrayList]::new()
    $maxPollMs = $TimeoutSec * 1000
    $pollCount = 0

    while ($pending.Count -gt 0 -and $phase2Sw.ElapsedMilliseconds -lt $maxPollMs) {
        Start-Sleep -Milliseconds 500
        $pollCount++
        $stillPending = [System.Collections.ArrayList]::new()

        foreach ($sub in $pending) {
            try {
                $pUri = "$MediaServerUrl/action=queueinfo&QueueName=Process&QueueAction=getstatus&token=$($sub.Token)"
                $pResp = Invoke-WebRequest -Uri $pUri -Method Get -TimeoutSec 10 -UseBasicParsing
                if ($pResp.StatusCode -eq 200) {
                    if ($pResp.Content -match '<status>Finished</status>' -or $pResp.Content -match '<status>Processed</status>') {
                        $sub | Add-Member -NotePropertyName PollStatus -NotePropertyValue "Finished" -Force
                        $sub | Add-Member -NotePropertyName PollDurationMs -NotePropertyValue $phase2Sw.ElapsedMilliseconds -Force
                        [void]$completedSubs.Add($sub)
                        continue
                    }
                    if ($pResp.Content -match '<status>Error</status>' -or $pResp.Content -match '<status>Failed</status>') {
                        $sub | Add-Member -NotePropertyName PollStatus -NotePropertyValue "Failed" -Force
                        $sub | Add-Member -NotePropertyName PollDurationMs -NotePropertyValue $phase2Sw.ElapsedMilliseconds -Force
                        [void]$completedSubs.Add($sub)
                        continue
                    }
                }
            } catch {
                if ($Debug) { Write-Host "[DEBUG] Poll transient error for $($sub.FileName): $($_.Exception.Message)" -ForegroundColor Magenta }
            }
            [void]$stillPending.Add($sub)
        }
        $pending = $stillPending

        # Progress update every ~10 polls or when poll count is low
        if ($pollCount % 10 -eq 0 -or $pending.Count -le 3) {
            Write-Log "  Poll #${pollCount}: $($completedSubs.Count)/$($validSubs.Count) done, $($pending.Count) pending ($([math]::Round($phase2Sw.Elapsed.TotalSeconds,1))s)" "INFO"
        }
    }

    $phase2Sw.Stop()
    # Handle timeouts
    if ($pending.Count -gt 0) {
        Write-Log "  $($pending.Count) job(s) timed out after ${TimeoutSec}s" "WARN"
        foreach ($p in $pending) {
            $p | Add-Member -NotePropertyName PollStatus -NotePropertyValue "Timeout" -Force
            $p | Add-Member -NotePropertyName PollDurationMs -NotePropertyValue $phase2Sw.ElapsedMilliseconds -Force
            [void]$completedSubs.Add($p)
        }
    }
    Write-Log "[Phase 2/3] Complete: $($completedSubs.Count) jobs resolved in $([math]::Round($phase2Sw.Elapsed.TotalSeconds,1))s" "INFO"

    # ── Phase 3: Read output files and parse XML ──
    Write-Log "[Phase 3/3] Reading output files and parsing results..." "INFO"
    $phase3Sw = [System.Diagnostics.Stopwatch]::StartNew()

    $results = @()

    # Handle submission errors first
    foreach ($sub in ($submissions | Where-Object { $_.SubmitError })) {
        $results += [PSCustomObject]@{
            Filename          = $sub.FileName
            FullPath          = $sub.FullPath
            Set               = $SetLabel
            FileSizeKB        = $sub.FileSizeKB
            Extension         = $sub.Extension
            Success           = $false
            StatusCode        = 0
            FaceDetected      = $false
            FaceCount         = 0
            FaceConfidence    = 0.0
            FaceDetails       = @()
            ObjectRecognized  = $false
            ObjectCount       = 0
            ObjectConfidence  = 0.0
            ObjectDetails     = @()
            PassportDetected  = $false
            ErrorMessage      = "Submit error: $($sub.SubmitError)"
            ResponseTimeMs    = $sub.SubmitTimeMs
            RawXml            = ""
            ThreadId          = 0
        }
    }

    # Process completed jobs
    foreach ($sub in $completedSubs) {
        $apiResult = [PSCustomObject]@{
            Success          = $false
            StatusCode       = 0
            RawXml           = ""
            SessionToken     = $sub.Token
            OutputFilePath   = ""
            FaceDetected     = $false
            FaceCount        = 0
            FaceConfidence   = 0.0
            FaceDetails      = @()
            ObjectRecognized = $false
            ObjectCount      = 0
            ObjectConfidence = 0.0
            ObjectDetails    = @()
            PassportDetected = $false
            ErrorMessage     = ""
            ResponseTimeMs   = $sub.SubmitTimeMs + $sub.PollDurationMs
        }

        if ($sub.PollStatus -eq "Finished") {
            $outputFile = Join-Path $MediaServerOutputDir "$($sub.Token)\face_object.xml"
            if (Test-Path $outputFile) {
                $apiResult.OutputFilePath = $outputFile
                $apiResult.Success = $true
                try {
                    $outputXml = Get-Content -Path $outputFile -Raw -Encoding UTF8
                    $apiResult.RawXml = $outputXml
                    Parse-MediaServerResponse -Result $apiResult -XmlContent $outputXml `
                        -PassportIdentityPatternParam $PassportIdentityPattern `
                        -PassportDatabasePatternParam $PassportDatabasePattern `
                        -DebugParam $Debug
                } catch {
                    $apiResult.ErrorMessage = "Parse error: $($_.Exception.Message)"
                }
            } else {
                $apiResult.ErrorMessage = "Output file not found: $outputFile"
            }
        } elseif ($sub.PollStatus -eq "Failed") {
            $apiResult.ErrorMessage = "Media Server job failed"
        } elseif ($sub.PollStatus -eq "Timeout") {
            $apiResult.ErrorMessage = "Async job timed out after $TimeoutSec seconds"
        }

        $results += [PSCustomObject]@{
            Filename          = $sub.FileName
            FullPath          = $sub.FullPath
            Set               = $SetLabel
            FileSizeKB        = $sub.FileSizeKB
            Extension         = $sub.Extension
            Success           = $apiResult.Success
            StatusCode        = $apiResult.StatusCode
            FaceDetected      = $apiResult.FaceDetected
            FaceCount         = $apiResult.FaceCount
            FaceConfidence    = $apiResult.FaceConfidence
            FaceDetails       = $apiResult.FaceDetails
            ObjectRecognized  = $apiResult.ObjectRecognized
            ObjectCount       = $apiResult.ObjectCount
            ObjectConfidence  = $apiResult.ObjectConfidence
            ObjectDetails     = $apiResult.ObjectDetails
            PassportDetected  = $apiResult.PassportDetected
            ErrorMessage      = $apiResult.ErrorMessage
            ResponseTimeMs    = $apiResult.ResponseTimeMs
            RawXml            = $apiResult.RawXml
            ThreadId          = 0
        }
    }

    $phase3Sw.Stop()
    Write-Log "[Phase 3/3] Complete: $($results.Count) results parsed in $([math]::Round($phase3Sw.Elapsed.TotalSeconds,1))s" "INFO"

    # ── Display per-file status ──
    Write-Host ""
    Write-Log "──────────── [$SetLabel] Results ────────────" "INFO"
    foreach ($r in $results) {
        $timeStr = if ($r.ResponseTimeMs -ge 1000) { "$([math]::Round($r.ResponseTimeMs / 1000, 2))s" } else { "$([math]::Round($r.ResponseTimeMs, 0))ms" }
        if (-not $r.Success) {
            Write-Host "  [$($r.Set)] $($r.Filename) ... ERROR ($timeStr)" -ForegroundColor Red
        } elseif ($r.Set -eq "TP" -and $r.PassportDetected) {
            Write-Host "  [$($r.Set)] $($r.Filename) ... PASS (Face:$($r.FaceDetected) Obj:$($r.ObjectRecognized) Passport:YES $timeStr)" -ForegroundColor Green
        } elseif ($r.Set -eq "TP" -and -not $r.PassportDetected) {
            Write-Host "  [$($r.Set)] $($r.Filename) ... MISS (Face:$($r.FaceDetected) Obj:$($r.ObjectRecognized) Passport:NO $timeStr)" -ForegroundColor Red
        } elseif ($r.Set -eq "FP" -and -not $r.PassportDetected) {
            Write-Host "  [$($r.Set)] $($r.Filename) ... PASS (Face:$($r.FaceDetected) Obj:$($r.ObjectRecognized) Passport:NO $timeStr)" -ForegroundColor Green
        } elseif ($r.Set -eq "FP" -and $r.PassportDetected) {
            Write-Host "  [$($r.Set)] $($r.Filename) ... FALSE+ (Face:$($r.FaceDetected) Obj:$($r.ObjectRecognized) Passport:YES $timeStr)" -ForegroundColor Yellow
        }
    }

    # ── Batch-async timing summary ──
    $totalElapsed = [math]::Round(($phase1Sw.Elapsed + $phase2Sw.Elapsed + $phase3Sw.Elapsed).TotalSeconds, 1)
    Write-Host ""
    Write-Log "[$SetLabel] Batch-async timing: Submit=$($phase1Sw.ElapsedMilliseconds)ms | Poll=$([math]::Round($phase2Sw.Elapsed.TotalSeconds,1))s | Parse=$([math]::Round($phase3Sw.Elapsed.TotalSeconds,1))s | Total=${totalElapsed}s" "INFO"
    Write-Host ""

    return @($results)
}

# ============================================================
# PROCESS ALL FILES (supports both sequential & parallel modes)
# ============================================================

function Test-FileSet {
    param(
        [string]$FolderPath,
        [string]$SetLabel,  # "TP" or "FP"
        [int]$Concurrency = 1
    )

    if (-not (Test-Path $FolderPath)) {
        Write-Log "Folder not found: $FolderPath" "ERROR"
        return @()
    }

    $files = Get-ChildItem -Path $FolderPath -File

    if ($files.Count -eq 0) {
        Write-Log "No files found in $FolderPath" "WARN"
        return @()
    }

    # Branch: parallel vs sequential
    if ($Concurrency -gt 1 -and $files.Count -gt 1) {
        return Invoke-ParallelFileSet -Files $files -SetLabel $SetLabel -ThreadCount $Concurrency `
            -MediaServerUrl $MediaServerUrl -ConfigName $ConfigName -TimeoutSec $TimeoutSec `
            -MediaServerOutputDir $MediaServerOutputDir -PassportIdentityPattern $PassportIdentityPattern `
            -PassportDatabasePattern $PassportDatabasePattern -Debug $Debug
    }

    # Sequential mode
    $results = @()
    Write-Log "Processing $($files.Count) files from [$SetLabel] set (sequential)..." "INFO"

    foreach ($file in $files) {
        Write-Host -NoNewline "  [$SetLabel] $($file.Name) ... "
        
        $apiResult = Invoke-MediaServerProcess -FilePath $file.FullName -Config $ConfigName -Timeout $TimeoutSec
        
        $record = [PSCustomObject]@{
            Filename          = $file.Name
            FullPath          = $file.FullName
            Set               = $SetLabel
            FileSizeKB        = [math]::Round($file.Length / 1KB, 1)
            Extension         = $file.Extension.ToLower()
            Success           = $apiResult.Success
            StatusCode        = $apiResult.StatusCode
            FaceDetected      = $apiResult.FaceDetected
            FaceCount         = $apiResult.FaceCount
            FaceConfidence    = $apiResult.FaceConfidence
            FaceDetails       = $apiResult.FaceDetails
            ObjectRecognized  = $apiResult.ObjectRecognized
            ObjectCount       = $apiResult.ObjectCount
            ObjectConfidence  = $apiResult.ObjectConfidence
            ObjectDetails     = $apiResult.ObjectDetails
            PassportDetected  = $apiResult.PassportDetected
            ErrorMessage      = $apiResult.ErrorMessage
            ResponseTimeMs    = $apiResult.ResponseTimeMs
            RawXml            = $apiResult.RawXml
            ThreadId          = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        }

        $results += $record

        # Status output
        $timeStr = if ($apiResult.ResponseTimeMs -ge 1000) { "$([math]::Round($apiResult.ResponseTimeMs / 1000, 2))s" } else { "$([math]::Round($apiResult.ResponseTimeMs, 0))ms" }
        if (-not $apiResult.Success) {
            Write-Host "ERROR ($timeStr)" -ForegroundColor Red
        }
        elseif ($SetLabel -eq "TP" -and $record.PassportDetected) {
            Write-Host "PASS (Face:$($apiResult.FaceDetected) Obj:$($apiResult.ObjectRecognized) Passport:YES $timeStr)" -ForegroundColor Green
        }
        elseif ($SetLabel -eq "TP" -and -not $record.PassportDetected) {
            Write-Host "MISS (Face:$($apiResult.FaceDetected) Obj:$($apiResult.ObjectRecognized) Passport:NO $timeStr)" -ForegroundColor Red
        }
        elseif ($SetLabel -eq "FP" -and -not $record.PassportDetected) {
            Write-Host "PASS (Face:$($apiResult.FaceDetected) Obj:$($apiResult.ObjectRecognized) Passport:NO $timeStr)" -ForegroundColor Green
        }
        elseif ($SetLabel -eq "FP" -and $record.PassportDetected) {
            Write-Host "FALSE+ (Face:$($apiResult.FaceDetected) Obj:$($apiResult.ObjectRecognized) Passport:YES $timeStr)" -ForegroundColor Yellow
        }
    }

    return $results
}

# ============================================================
# F1 CALCULATION
# ============================================================

function Get-ConfusionMatrix {
    param([array]$AllResults)

    $tp = ($AllResults | Where-Object { $_.Set -eq "TP" -and $_.PassportDetected }).Count
    $fn = ($AllResults | Where-Object { $_.Set -eq "TP" -and -not $_.PassportDetected }).Count
    $fp = ($AllResults | Where-Object { $_.Set -eq "FP" -and $_.PassportDetected }).Count
    $tn = ($AllResults | Where-Object { $_.Set -eq "FP" -and -not $_.PassportDetected }).Count

    $precision = if (($tp + $fp) -gt 0) { [math]::Round($tp / ($tp + $fp), 4) } else { 0 }
    $recall    = if (($tp + $fn) -gt 0) { [math]::Round($tp / ($tp + $fn), 4) } else { 0 }
    $f1        = if (($precision + $recall) -gt 0) { [math]::Round(2 * $precision * $recall / ($precision + $recall), 4) } else { 0 }
    $accuracy  = if (($tp + $tn + $fp + $fn) -gt 0) { [math]::Round(($tp + $tn) / ($tp + $tn + $fp + $fn), 4) } else { 0 }
    $specificity = if (($tn + $fp) -gt 0) { [math]::Round($tn / ($tn + $fp), 4) } else { 0 }

    return [PSCustomObject]@{
        TruePositive  = $tp
        FalseNegative = $fn
        FalsePositive = $fp
        TrueNegative  = $tn
        Precision     = $precision
        Recall        = $recall
        F1            = $f1
        Accuracy      = $accuracy
        Specificity   = $specificity
        Total         = $tp + $fn + $fp + $tn
    }
}

# ============================================================
# HTML REPORT GENERATOR
# ============================================================

function New-HtmlReport {
    param(
        [array]$AllResults,
        $Matrix,
        [string]$OutputPath,
        $PerformanceMetrics = $null,
        [array]$IterationMetrics = @(),
        [int]$ThreadCount = 1,
        [int]$LoadTestIterations = 1,
        [bool]$CrashDumpDetected = $false,
        [string]$CrashDumpPath = ""
    )

    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $duration = [math]::Round(((Get-Date) - $script:StartTime).TotalSeconds, 1)

    # Smart time formatter: seconds for >= 1s, milliseconds for < 1s
    function Format-TimeSmart {
        param([double]$Ms)
        if ($Ms -ge 1000) { return "$([math]::Round($Ms / 1000, 2)) s" }
        else { return "$([math]::Round($Ms, 0)) ms" }
    }

    # Stats
    $totalFiles = $AllResults.Count
    $avgTimeMs = if ($totalFiles -gt 0) { ($AllResults | Measure-Object -Property ResponseTimeMs -Average).Average } else { 0 }
    $totalTimeMs = ($AllResults | Measure-Object -Property ResponseTimeMs -Sum).Sum
    $avgTimeDisplay = Format-TimeSmart $avgTimeMs
    $totalTimeDisplay = Format-TimeSmart $totalTimeMs
    $faceDetectedCount = ($AllResults | Where-Object { $_.FaceDetected }).Count
    $objRecognizedCount = ($AllResults | Where-Object { $_.ObjectRecognized }).Count
    
    # Per-set stats
    $tpSet = $AllResults | Where-Object { $_.Set -eq "TP" }
    $fpSet = $AllResults | Where-Object { $_.Set -eq "FP" }
    $tpAvgTimeMs = if ($tpSet.Count -gt 0) { ($tpSet | Measure-Object -Property ResponseTimeMs -Average).Average } else { 0 }
    $fpAvgTimeMs = if ($fpSet.Count -gt 0) { ($fpSet | Measure-Object -Property ResponseTimeMs -Average).Average } else { 0 }
    $tpAvgTimeDisplay = Format-TimeSmart $tpAvgTimeMs
    $fpAvgTimeDisplay = Format-TimeSmart $fpAvgTimeMs

    # F1 color coding
    $f1Color = if ($Matrix.F1 -ge 0.9) { "#27ae60" } elseif ($Matrix.F1 -ge 0.7) { "#f39c12" } else { "#e74c3c" }
    $f1Label = if ($Matrix.F1 -ge 0.9) { "Excellent" } elseif ($Matrix.F1 -ge 0.7) { "Fair" } else { "Poor" }

    # Generate table rows
    $tableRows = ""
    $idx = 0
    foreach ($r in $AllResults) {
        $idx++
        $rowClass = ""
        $statusBadge = ""
        $statusLabel = ""
        
        if ($r.Set -eq "TP" -and $r.PassportDetected) {
            $rowClass = "row-pass"
            $statusBadge = "badge pass"
            $statusLabel = "TP +"
        }
        elseif ($r.Set -eq "TP" -and -not $r.PassportDetected) {
            $rowClass = "row-fail"
            $statusBadge = "badge fail"
            $statusLabel = "FN -"
        }
        elseif ($r.Set -eq "FP" -and -not $r.PassportDetected) {
            $rowClass = "row-pass"
            $statusBadge = "badge pass"
            $statusLabel = "TN +"
        }
        elseif ($r.Set -eq "FP" -and $r.PassportDetected) {
            $rowClass = "row-fp"
            $statusBadge = "badge fp"
            $statusLabel = "FP !!"
        }
        
        if (-not $r.Success) {
            $rowClass = "row-error"
            $statusBadge = "badge error"
            $statusLabel = "ERR"
        }

        $faceInfo = if ($r.FaceDetected) { "+ ($($r.FaceCount) faces, $($r.FaceConfidence)%)" } else { "-" }
        $objInfo = if ($r.ObjectRecognized) { "+ ($($r.ObjectCount) objs, $($r.ObjectConfidence)%)" } else { "-" }
        
        $objectIdentities = ""
        if ($r.ObjectDetails.Count -gt 0) {
            $objectIdentities = ($r.ObjectDetails | ForEach-Object { "$($_.Identity)($($_.Confidence))" }) -join ", "
        }

        $timeDisplay = if ($r.ResponseTimeMs -ge 1000) { "$([math]::Round($r.ResponseTimeMs / 1000, 2)) s" } else { "$([math]::Round($r.ResponseTimeMs, 0)) ms" }
        $tableRows += @"
        <tr class="$rowClass">
          <td>$idx</td>
          <td class="mono" title="$($r.FullPath)">$($r.Filename)</td>
          <td><span class="set-tag set-$($r.Set.ToLower())">$($r.Set)</span></td>
          <td>$($r.FileSizeKB) KB</td>
          <td>$faceInfo</td>
          <td>$objInfo</td>
          <td class="mono">$objectIdentities</td>
          <td><span class="$statusBadge">$statusLabel</span></td>
          <td class="mono time-cell">$timeDisplay</td>
        </tr>
"@
    }

    # Build performance metrics HTML section
    $aggPerf = if ($PerformanceMetrics) { $PerformanceMetrics } else { Get-PerformanceMetrics -Results $AllResults -TotalDurationSec $duration }
    $perfHtml = @"
  <div class="card">
    <h3>⚡ Performance Metrics</h3>
    <table class="perf-table">
      <thead>
        <tr>
          <th>Metric</th>
          <th>Value</th>
        </tr>
      </thead>
      <tbody>
        <tr><td>Concurrent Threads</td><td class="perf-val">$ThreadCount</td></tr>
        <tr><td>Load Test Iterations</td><td class="perf-val">$LoadTestIterations</td></tr>
        <tr><td>Throughput</td><td class="perf-val">$($aggPerf.ThroughputFilesPerSec) files/sec</td></tr>
        <tr><td>Avg Response Time</td><td class="perf-val">$($aggPerf.AvgResponseTimeMs) ms</td></tr>
        <tr><td>Min Response Time</td><td class="perf-val">$($aggPerf.MinResponseTimeMs) ms</td></tr>
        <tr><td>Max Response Time</td><td class="perf-val">$($aggPerf.MaxResponseTimeMs) ms</td></tr>
        <tr><td>P50 (Median)</td><td class="perf-val">$($aggPerf.P50Ms) ms</td></tr>
        <tr><td>P95 Latency</td><td class="perf-val">$($aggPerf.P95Ms) ms</td></tr>
        <tr><td>P99 Latency</td><td class="perf-val">$($aggPerf.P99Ms) ms</td></tr>
        <tr><td>Total Duration</td><td class="perf-val">$($aggPerf.TotalTimeSec) s</td></tr>
        <tr><td>Total API Calls</td><td class="perf-val">$($aggPerf.TotalCalls)</td></tr>
        <tr><td>Errors</td><td class="perf-val">$($aggPerf.ErrorCount)</td></tr>
      </tbody>
    </table>
    <details class="perf-legend">
      <summary>📊 Understanding P50 / P95 / P99</summary>
      <div class="perf-legend-body">
        <p>These are <strong>percentiles</strong> that show how response time is distributed across all API calls — not just the average.</p>
        <table class="perf-legend-table">
          <tr><th>Percentile</th><th>What it means</th><th>Why it matters</th></tr>
          <tr><td><strong>P50</strong> (Median)</td><td>50% of requests were faster than this. The "typical" experience.</td><td>The response time most users actually see.</td></tr>
          <tr><td><strong>P95</strong></td><td>95% of requests were faster than this. Only 1 in 20 calls is slower.</td><td>Reveals "bad but not worst" tail latency — often used for SLO targets.</td></tr>
          <tr><td><strong>P99</strong></td><td>99% of requests were faster than this. Only 1 in 100 calls is slower.</td><td>Worst-case outliers: GC pauses, queuing bottlenecks, disk I/O spikes.</td></tr>
        </table>
        <p class="perf-legend-note">💡 Averages can be misleading. If 99 calls take 100 ms and 1 call takes 10 s, the average is ~199 ms — but P99 reveals the 10 s outlier. A large gap between P50 and P99 indicates inconsistent performance worth investigating.</p>
      </div>
    </details>
  </div>
"@

    # Iteration breakdown table (only when load testing)
    $iterTableHtml = ""
    if ($LoadTestIterations -gt 1 -and $IterationMetrics.Count -gt 0) {
        $iterRows = ""
        foreach ($im in $IterationMetrics) {
            $iterRows += @"
        <tr>
          <td>$($im.Iteration)</td>
          <td class="time-cell">$($im.Throughput)</td>
          <td class="time-cell">$($im.AvgTimeMs) ms</td>
          <td class="time-cell">$($im.MinTimeMs) ms</td>
          <td class="time-cell">$($im.MaxTimeMs) ms</td>
          <td class="time-cell">$($im.P50Ms) ms</td>
          <td class="time-cell">$($im.P95Ms) ms</td>
          <td class="time-cell">$($im.P99Ms) ms</td>
          <td>$($im.DurationSec) s</td>
          <td>$($im.TotalCalls)</td>
          <td>$($im.Errors)</td>
        </tr>
"@
        }
        $iterTableHtml = @"
  <div class="card">
    <h3>🔄 Load Test Iteration Breakdown</h3>
    <table>
      <thead>
        <tr>
          <th>Iteration</th>
          <th>Throughput (f/s)</th>
          <th>Avg (ms)</th>
          <th>Min (ms)</th>
          <th>Max (ms)</th>
          <th>P50 (ms)</th>
          <th>P95 (ms)</th>
          <th>P99 (ms)</th>
          <th>Duration (s)</th>
          <th>Calls</th>
          <th>Errors</th>
        </tr>
      </thead>
      <tbody>
        $iterRows
      </tbody>
    </table>
  </div>
"@
    }

    # Stats rows for face detection
    $faceStatsRows = ""
    if ($faceDetectedCount -gt 0) {
        $faceConfidences = @()
        foreach ($fr in $faceRecords) {
            foreach ($fd in $fr.FaceDetails) {
                $faceConfidences += $fd.Confidence
            }
        }
        $avgFaceConf = if ($faceConfidences.Count -gt 0) { [math]::Round(($faceConfidences | Measure-Object -Average).Average, 2) } else { 0 }
        $minFaceConf = if ($faceConfidences.Count -gt 0) { [math]::Round(($faceConfidences | Measure-Object -Minimum).Minimum, 2) } else { 0 }
        $maxFaceConf = if ($faceConfidences.Count -gt 0) { [math]::Round(($faceConfidences | Measure-Object -Maximum).Maximum, 2) } else { 0 }
        
        $faceStatsRows = @"
        <h3>🔍 Face Detection Details</h3>
        <div class="stats-grid">
          <div class="stat-card"><div class="stat-value">$faceDetectedCount</div><div class="stat-label">Files w/ Faces</div></div>
          <div class="stat-card teal"><div class="stat-value">$avgFaceConf%</div><div class="stat-label">Avg Face Confidence</div></div>
          <div class="stat-card"><div class="stat-value">$minFaceConf%</div><div class="stat-label">Min Face Confidence</div></div>
          <div class="stat-card"><div class="stat-value">$maxFaceConf%</div><div class="stat-label">Max Face Confidence</div></div>
        </div>
"@
    }

    # Optimization insights
    $insights = @()
    if ($Matrix.FalseNegative -gt 0) {
        $fnFiles = ($AllResults | Where-Object { $_.Set -eq "TP" -and -not $_.PassportDetected })
        $fnNoFace = ($fnFiles | Where-Object { -not $_.FaceDetected }).Count
        $fnFaceNoObj = ($fnFiles | Where-Object { $_.FaceDetected -and -not $_.ObjectRecognized }).Count
        
        if ($fnNoFace -gt 0) {
            $insights += "<li><strong>$fnNoFace false negatives</strong> had NO face detected. Consider: lowering <code>MinSize</code> threshold in FaceDetect, or checking image quality/resolution.</li>"
        }
        if ($fnFaceNoObj -gt 0) {
            $insights += "<li><strong>$fnFaceNoObj false negatives</strong> had faces but NO object recognition. Consider: training object database with more passport variants, checking face-to-passport spatial relationship in Lua filter.</li>"
        }
    }
    if ($Matrix.FalsePositive -gt 0) {
        $insights += "<li><strong>$($Matrix.FalsePositive) false positives</strong> — non-passport images flagged. Consider: tightening <code>faceFilter.lua</code> with frontal-face or minimum confidence thresholds, refining object database.</li>"
    }
    if ($Matrix.F1 -lt 0.8) {
        $insights += "<li>F1 score below 0.8 — review the <code>ObjectRecognition</code> database training data and ensure it covers Australian passport variations (angles, lighting, partial occlusions).</li>"
    }
    $fpFaceDetected = ($fpSet | Where-Object { $_.FaceDetected }).Count
    if ($fpFaceDetected -gt 0 -and $Matrix.FalsePositive -eq 0) {
        $insights += "<li>$fpFaceDetected false-positive images had faces but were correctly NOT flagged as passports. Face filter is working as a good gate.</li>"
    }

    $insightHtml = if ($insights.Count -gt 0) {
        "<div class='insights'><h3>💡 Optimization Recommendations</h3><ul>$($insights -join "`n")</ul></div>"
    } else { "" }

    # Build HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>F1 Benchmark Report – $ConfigName</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Segoe UI', Arial, sans-serif;
      background: #f0f4f8;
      color: #333;
      padding: 30px 40px;
    }
    header { margin-bottom: 28px; }
    header h1 { font-size: 1.8rem; color: #1a3a5c; }
    header h2 { font-size: 1.1rem; color: #4a90d9; margin-top: 4px; font-weight: normal; }
    header p.meta { font-size: 0.85rem; color: #888; margin-top: 6px; }
    .stats-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
      gap: 16px;
      margin-bottom: 30px;
    }
    .stat-card {
      background: #fff;
      border-radius: 10px;
      padding: 18px 16px;
      text-align: center;
      box-shadow: 0 2px 8px rgba(0,0,0,0.08);
      border-top: 4px solid #4a90d9;
    }
    .stat-card.green  { border-top-color: #27ae60; }
    .stat-card.red    { border-top-color: #e74c3c; }
    .stat-card.orange { border-top-color: #f39c12; }
    .stat-card.teal   { border-top-color: #16a085; }
    .stat-card.purple { border-top-color: #8e44ad; }
    .stat-card.gold   { border-top-color: #f1c40f; }
    .stat-value {
      font-size: 2rem;
      font-weight: 700;
      color: #1a3a5c;
      line-height: 1.1;
    }
    .stat-value.big  { font-size: 2.6rem; }
    .stat-label {
      font-size: 0.78rem;
      color: #888;
      margin-top: 5px;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }
    .perf-table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 12px;
    }
    .perf-table th {
      text-align: left;
      padding: 10px 14px;
      background: #f0f4f8;
      color: #1a3a5c;
      font-size: 0.82rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      border-bottom: 2px solid #d0d8e0;
    }
    .perf-table td {
      padding: 9px 14px;
      border-bottom: 1px solid #e8ecf0;
      font-size: 0.92rem;
    }
    .perf-table tbody tr:hover { background: #f8fafc; }
    .perf-val {
      font-weight: 600;
      color: #1a3a5c;
      text-align: left;
      font-family: 'Segoe UI', Consolas, monospace;
    }
    .perf-legend {
      margin-top: 16px;
      padding: 0 14px 14px 14px;
      cursor: pointer;
    }
    .perf-legend summary {
      font-size: 0.85rem;
      color: #4a90d9;
      font-weight: 600;
      outline: none;
    }
    .perf-legend summary:hover { color: #2b6cb0; }
    .perf-legend-body {
      margin-top: 10px;
      font-size: 0.84rem;
      color: #555;
      line-height: 1.6;
    }
    .perf-legend-body p { margin: 8px 0; }
    .perf-legend-table {
      width: 100%;
      border-collapse: collapse;
      margin: 10px 0;
      font-size: 0.82rem;
    }
    .perf-legend-table th {
      text-align: left;
      padding: 7px 10px;
      background: #f0f4f8;
      color: #1a3a5c;
      border-bottom: 1px solid #d0d8e0;
    }
    .perf-legend-table td {
      padding: 7px 10px;
      border-bottom: 1px solid #e8ecf0;
      vertical-align: top;
    }
    .perf-legend-note {
      background: #fffbe6;
      border-left: 3px solid #f1c40f;
      padding: 8px 12px;
      border-radius: 4px;
      font-style: italic;
    }
    .card {
      background: #fff;
      border-radius: 10px;
      box-shadow: 0 2px 8px rgba(0,0,0,0.08);
      overflow: hidden;
      margin-bottom: 24px;
    }
    .card h3 {
      padding: 14px 18px;
      background: #1a3a5c;
      color: #fff;
      font-size: 0.95rem;
      font-weight: 600;
      letter-spacing: 0.03em;
    }
    table {
      width: 100%;
      border-collapse: collapse;
    }
    thead tr { background: #2c5f8a; color: #fff; }
    thead th {
      padding: 10px 12px;
      text-align: left;
      font-size: 0.82rem;
      font-weight: 600;
      letter-spacing: 0.04em;
    }
    tbody tr { border-bottom: 1px solid #eef0f3; transition: background 0.15s; }
    tbody tr:last-child { border-bottom: none; }
    tbody tr:hover { background: #f5f9ff; }
    tbody tr.row-pass { background: #f0fff4; }
    tbody tr.row-fail { background: #fff5f5; }
    tbody tr.row-fp   { background: #fffdf0; }
    tbody tr.row-error { background: #fef0f0; }
    tbody tr.row-pass:hover { background: #e6ffee; }
    tbody tr.row-fail:hover { background: #ffe8e8; }
    tbody tr.row-fp:hover   { background: #fff9e0; }
    td { padding: 8px 12px; font-size: 0.85rem; }
    .mono { font-family: 'Cascadia Code', 'Consolas', monospace; font-size: 0.82rem; }
    .time-cell { color: #2c7be5; font-weight: 600; }
    .badge {
      display: inline-block;
      padding: 3px 10px;
      border-radius: 12px;
      font-size: 0.75rem;
      font-weight: 700;
      letter-spacing: 0.05em;
    }
    .badge.pass  { background: #d4edda; color: #155724; }
    .badge.fail  { background: #f8d7da; color: #721c24; }
    .badge.fp    { background: #fff3cd; color: #856404; }
    .badge.error { background: #f8d7da; color: #721c24; }
    .set-tag {
      display: inline-block;
      padding: 2px 8px;
      border-radius: 8px;
      font-size: 0.72rem;
      font-weight: 700;
      letter-spacing: 0.05em;
    }
    .set-tp { background: #d4edda; color: #155724; }
    .set-fp { background: #f8d7da; color: #721c24; }
    .confusion-grid {
      display: grid;
      grid-template-columns: 120px 1fr 1fr;
      gap: 2px;
      margin: 16px 18px;
    }
    .confusion-grid .header { font-weight: 700; text-align: center; padding: 8px; background: #eef0f3; font-size: 0.85rem; }
    .confusion-grid .cell {
      text-align: center;
      padding: 16px;
      font-size: 1.4rem;
      font-weight: 700;
      border-radius: 6px;
    }
    .cell.tp { background: #d4edda; color: #155724; }
    .cell.fn { background: #f8d7da; color: #721c24; }
    .cell.fp { background: #fff3cd; color: #856404; }
    .cell.tn { background: #d4edda; color: #155724; }
    .insights {
      background: #fff;
      border-radius: 10px;
      box-shadow: 0 2px 8px rgba(0,0,0,0.08);
      padding: 18px 24px;
      margin-bottom: 24px;
    }
    .insights h3 { color: #1a3a5c; margin-bottom: 10px; }
    .insights ul { padding-left: 20px; }
    .insights li { margin-bottom: 8px; font-size: 0.9rem; line-height: 1.5; }
    .insights code {
      background: #eef0f3;
      padding: 2px 6px;
      border-radius: 4px;
      font-family: 'Cascadia Code', 'Consolas', monospace;
      font-size: 0.82rem;
    }
    .pipeline-flow {
      display: flex;
      align-items: center;
      gap: 10px;
      flex-wrap: wrap;
      padding: 16px 18px;
      background: #f7f9fc;
      border-radius: 8px;
      margin: 16px 18px;
    }
    .pipeline-step {
      background: #1a3a5c;
      color: #fff;
      padding: 8px 16px;
      border-radius: 20px;
      font-size: 0.82rem;
      font-weight: 600;
    }
    .pipeline-arrow { color: #888; font-size: 1.2rem; }
    .crash-alert {
      background: #fff5f5;
      border: 2px solid #e74c3c;
      border-left: 6px solid #e74c3c;
      border-radius: 10px;
      margin-bottom: 24px;
      overflow: hidden;
    }
    .crash-alert-title {
      background: #e74c3c;
      color: #fff;
      padding: 12px 18px;
      font-size: 1rem;
      font-weight: 700;
    }
    .crash-alert-body {
      padding: 16px 18px;
      font-size: 0.88rem;
      color: #721c24;
      line-height: 1.6;
    }
    .crash-dump-path {
      display: inline-block;
      background: #fce4e4;
      padding: 4px 10px;
      border-radius: 4px;
      font-family: 'Cascadia Code', 'Consolas', monospace;
      font-size: 0.82rem;
      color: #c0392b;
      margin: 6px 0;
      word-break: break-all;
    }
    footer {
      margin-top: 30px;
      font-size: 0.8rem;
      color: #aaa;
      text-align: center;
    }
  </style>
</head>
<body>
  <header>
    <h1>📊 F1 Benchmark Report</h1>
    <h2>Pipeline: <strong>FaceDetection → Lua Filter → ObjectRecognition</strong></h2>
    <p class="meta">Config: <strong>$ConfigName</strong> &mdash; Generated: $now &mdash; Duration: ${duration}s</p>
  </header>

  <!-- Crash dump alert (shown if dump was detected after benchmark) -->
  $(if ($CrashDumpDetected) {
    @"
    <div class="crash-alert">
      <div class="crash-alert-title">⚠️ MediaServer Crash Detected</div>
      <div class="crash-alert-body">
        A crash dump file was generated during or after this benchmark run:
        <br><code class="crash-dump-path">$CrashDumpPath</code>
        <br><br>This indicates that the MediaServer process terminated unexpectedly.
        Review the dump file for root cause analysis. If process monitoring was enabled,
        check the monitor CSV for resource usage trends leading up to the crash.
      </div>
    </div>
"@
  } else { "" })

  <!-- F1 Score Card -->
  <div class="stats-grid">
    <div class="stat-card gold">
      <div class="stat-value big" style="color: $f1Color">$($Matrix.F1.ToString("0.000"))</div>
      <div class="stat-label">F1 Score — $f1Label</div>
    </div>
    <div class="stat-card teal">
      <div class="stat-value">$($Matrix.Precision.ToString("0.000"))</div>
      <div class="stat-label">Precision</div>
    </div>
    <div class="stat-card purple">
      <div class="stat-value">$($Matrix.Recall.ToString("0.000"))</div>
      <div class="stat-label">Recall</div>
    </div>
    <div class="stat-card">
      <div class="stat-value">$($Matrix.Accuracy.ToString("0.000"))</div>
      <div class="stat-label">Accuracy</div>
    </div>
    <div class="stat-card">
      <div class="stat-value">$($Matrix.Specificity.ToString("0.000"))</div>
      <div class="stat-label">Specificity (TNR)</div>
    </div>
    <div class="stat-card">
      <div class="stat-value">$($Matrix.Total)</div>
      <div class="stat-label">Total Files</div>
    </div>
  </div>

  <!-- Pipeline Flow -->
  <div class="card">
    <h3>⚙️ Pipeline Configuration</h3>
    <div class="pipeline-flow">
      <span class="pipeline-step">Source (file)</span>
      <span class="pipeline-arrow">→</span>
      <span class="pipeline-step">FaceDetect</span>
      <span class="pipeline-arrow">→</span>
      <span class="pipeline-step">FaceFilter (Lua)</span>
      <span class="pipeline-arrow">→</span>
      <span class="pipeline-step">ObjectRecognition</span>
      <span class="pipeline-arrow">→</span>
      <span class="pipeline-step">Result</span>
    </div>
  </div>

  <!-- Confusion Matrix -->
  <div class="card">
    <h3>🎯 Confusion Matrix</h3>
    <div class="confusion-grid">
      <div class="header"></div>
      <div class="header">Predicted: Passport</div>
      <div class="header">Predicted: No Passport</div>
      <div class="header">Actual: Passport</div>
      <div class="cell tp">TP = $($Matrix.TruePositive)</div>
      <div class="cell fn">FN = $($Matrix.FalseNegative)</div>
      <div class="header">Actual: No Passport</div>
      <div class="cell fp">FP = $($Matrix.FalsePositive)</div>
      <div class="cell tn">TN = $($Matrix.TrueNegative)</div>
    </div>
  </div>

  <!-- Per-Set Performance -->
  <div class="stats-grid">
    <div class="stat-card green">
      <div class="stat-value">$($tpSet.Count)</div>
      <div class="stat-label">TP Set (Passport Files)</div>
    </div>
    <div class="stat-card red">
      <div class="stat-value">$($fpSet.Count)</div>
      <div class="stat-label">FP Set (Non-Passport)</div>
    </div>
    <div class="stat-card">
      <div class="stat-value">$faceDetectedCount</div>
      <div class="stat-label">Files w/ Face Detected</div>
    </div>
    <div class="stat-card">
      <div class="stat-value">$objRecognizedCount</div>
      <div class="stat-label">Files w/ Object Recognized</div>
    </div>
    <div class="stat-card teal">
      <div class="stat-value">$avgTimeDisplay</div>
      <div class="stat-label">Avg Response Time</div>
    </div>
    <div class="stat-card">
      <div class="stat-value">$totalTimeDisplay</div>
      <div class="stat-label">Total Processing Time</div>
    </div>
    <div class="stat-card">
      <div class="stat-value">$tpAvgTimeDisplay</div>
      <div class="stat-label">TP Avg Time</div>
    </div>
    <div class="stat-card">
      <div class="stat-value">$fpAvgTimeDisplay</div>
      <div class="stat-label">FP Avg Time</div>
    </div>
  </div>

  $perfHtml

  $iterTableHtml

  $faceStatsRows

  $insightHtml

  <!-- Detailed Results Table -->
  <div class="card">
    <h3>📋 Detailed Results — Per File</h3>
    <table>
      <thead>
        <tr>
          <th>#</th>
          <th>Filename</th>
          <th>Set</th>
          <th>Size</th>
          <th>Face Detection</th>
          <th>Object Recognition</th>
          <th>Object Identities</th>
          <th>Result</th>
          <th>Time</th>
        </tr>
      </thead>
      <tbody>
        $tableRows
      </tbody>
    </table>
  </div>

  <footer>
    IDOL MediaServer F1 Benchmark &mdash; $ConfigName &mdash; $now &mdash; TP: C:\IDOL\images\TP &mdash; FP: C:\IDOL\images\FP
  </footer>
</body>
</html>
"@

    # Ensure output directory exists
    $outDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $html | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
    Write-Log "Report saved to: $OutputPath" "PASS"
}

# ============================================================
# MAIN EXECUTION
# ============================================================

# Display configuration summary
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   FaceDetection + ObjectRecognition F1 Benchmark    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
$protocol = if ($UseHttps) { "HTTPS" } else { "HTTP" }
Write-Log "Protocol: $protocol"
Write-Log "Server URL: $MediaServerUrl"
if ($Debug) { Write-Log "DEBUG MODE ENABLED — verbose tracing active" "DEBUG" }
Write-Log "Config: $ConfigName"
Write-Log "TP Folder: $TPFolder"
Write-Log "FP Folder: $FPFolder"
Write-Log "Concurrency: $ThreadCount thread(s)"
Write-Log "Load Test Iterations: $LoadTestIterations"
Write-Log "Process Monitor: $(if($MonitorEnabled){'Enabled'}else{'Disabled'})"
Write-Log "Actions Dir: $MediaServerActionsDir"
Write-Log "Logs Dir:    $MediaServerLogsDir"
Write-Host ""

# ── Pre-run cleanup: delete actions and logs folders ──
if ($MediaServerActionsDir -and (Test-Path $MediaServerActionsDir)) {
    Write-Log "Clearing actions folder: $MediaServerActionsDir" "WARN"
    Remove-Item -Path $MediaServerActionsDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Actions folder cleared" "PASS"
} else {
    Write-Log "Actions folder not found (skipping): $MediaServerActionsDir" "INFO"
}

if ($MediaServerLogsDir -and (Test-Path $MediaServerLogsDir)) {
    Write-Log "Clearing logs folder: $MediaServerLogsDir" "WARN"
    Remove-Item -Path $MediaServerLogsDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Logs folder cleared" "PASS"
} else {
    Write-Log "Logs folder not found (skipping): $MediaServerLogsDir" "INFO"
}

if ($MediaServerCrashDumpPath -and (Test-Path $MediaServerCrashDumpPath)) {
    Write-Log "Deleting previous crash dump: $MediaServerCrashDumpPath" "WARN"
    Remove-Item -Path $MediaServerCrashDumpPath -Force -ErrorAction SilentlyContinue
    Write-Log "Crash dump deleted" "PASS"
}
Write-Host ""

# ── Ensure MediaServer process is running; start it if not (only when AutoStart=true) ──
if ($AutoStart) {
    $script:MediaServerWasStarted = $false
    $msProc = Get-Process -Name $MediaServerProcessName -ErrorAction SilentlyContinue
    if (-not $msProc) {
        Write-Log "MediaServer ($MediaServerProcessName) is NOT running — AutoStart is ON, attempting to start..." "WARN"
        if (-not (Test-Path $MediaServerStartScript)) {
            Write-Log "MediaServer start script not found: $MediaServerStartScript" "ERROR"
            Write-Log "Check the MediaServerStartScript config value." "ERROR"
            exit 1
        }
        $msInstallDir = Split-Path $MediaServerStartScript -Parent
        Write-Log "Starting: $MediaServerStartScript (working dir: $msInstallDir)" "INFO"
        $script:MediaServerProcess = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c", "`"$MediaServerStartScript`"" `
            -WorkingDirectory $msInstallDir `
            -WindowStyle Hidden `
            -PassThru
        $script:MediaServerWasStarted = $true
        Write-Log "MediaServer launched (PID: $($script:MediaServerProcess.Id)) — waiting for it to come online..." "INFO"

        # Poll the health endpoint until it responds or we time out
        $startupTimeout = 60
        $startupElapsed = 0
        $startupInterval = 2
        $online = $false
        while ($startupElapsed -lt $startupTimeout) {
            Start-Sleep -Seconds $startupInterval
            $startupElapsed += $startupInterval
            try {
                $check = Invoke-WebRequest -Uri "$MediaServerUrl/action=getstatus" -Method Get -TimeoutSec 3 -UseBasicParsing
                if ($check.StatusCode -eq 200) {
                    $online = $true
                    Write-Log "MediaServer is online after $startupElapsed seconds (PID: $($script:MediaServerProcess.Id))" "PASS"
                    break
                }
            } catch {
                Write-Host "    ... waiting ($startupElapsed s / ${startupTimeout}s)" -ForegroundColor DarkGray
            }
        }
        if (-not $online) {
            Write-Log "MediaServer did not come online within ${startupTimeout}s — check the process manually." "ERROR"
            exit 1
        }
    } else {
        Write-Log "MediaServer ($MediaServerProcessName) is already running (PID: $($msProc.Id))" "PASS"
    }
} else {
    Write-Log "AutoStart is OFF — MediaServer must already be running (e.g. as a service)" "INFO"
}
Write-Host ""

# ── Launch MediaServer process monitor (background job) ──
$monitorJob = $null
if ($MonitorEnabled) {
    $monitorScript = Join-Path $PSScriptRoot "monitor-mediaserver.ps1"
    if (Test-Path $monitorScript) {
        Write-Log "Starting MediaServer process monitor (background)..." "INFO"
        $monitorArgs = @("-ConfigPath", $configPath)
        $monitorJob = Start-Job -Name "MediaServerMonitor" -FilePath $monitorScript -ArgumentList $monitorArgs
        Write-Log "Monitor job started (ID: $($monitorJob.Id))" "PASS"
        Start-Sleep -Seconds 2  # Let the monitor initialize
    } else {
        Write-Log "Monitor script not found: $monitorScript — skipping" "WARN"
        $MonitorEnabled = $false
    }
}

# Check if Media Server is reachable via action=getstatus
try {
    $healthCheck = Invoke-WebRequest -Uri "$MediaServerUrl/action=getstatus" -Method Get -TimeoutSec 5 -UseBasicParsing
    Write-Log "Media Server is reachable at $MediaServerUrl ($protocol $($healthCheck.StatusCode))" "PASS"
} catch {
    Write-Log "Cannot reach Media Server at $MediaServerUrl. Ensure it is running." "ERROR"
    Write-Log "Start it with: .\mediaserver.exe from the MediaServer_26.2.0 folder" "WARN"
    Write-Log "Error details: $($_.Exception.Message)" "ERROR"
    exit 1
}

# ============================================================
# Performance metrics helper
# ============================================================
function Get-PerformanceMetrics {
    param([array]$Results, [double]$TotalDurationSec)
    $times = $Results | ForEach-Object { $_.ResponseTimeMs } | Sort-Object
    $count = $times.Count
    if ($count -eq 0) {
        return [PSCustomObject]@{
            ThroughputFilesPerSec = 0
            AvgResponseTimeMs = 0; MinResponseTimeMs = 0; MaxResponseTimeMs = 0
            P50Ms = 0; P95Ms = 0; P99Ms = 0
            TotalTimeSec = $TotalDurationSec; TotalCalls = 0; ErrorCount = 0
        }
    }
    $errorCount = ($Results | Where-Object { -not $_.Success }).Count
    [PSCustomObject]@{
        ThroughputFilesPerSec = if ($TotalDurationSec -gt 0) { [math]::Round($count / $TotalDurationSec, 2) } else { 0 }
        AvgResponseTimeMs     = [math]::Round(($times | Measure-Object -Average).Average, 1)
        MinResponseTimeMs     = [math]::Round($times[0], 1)
        MaxResponseTimeMs     = [math]::Round($times[-1], 1)
        P50Ms                 = [math]::Round($times[[Math]::Floor($count * 0.50)], 1)
        P95Ms                 = [math]::Round($times[[Math]::Floor($count * 0.95)], 1)
        P99Ms                 = [math]::Round($times[[Math]::Floor($count * 0.99)], 1)
        TotalTimeSec          = [math]::Round($TotalDurationSec, 1)
        TotalCalls            = $count
        ErrorCount            = $errorCount
    }
}

# ============================================================
# Load Test Iteration Loop
# ============================================================

$allIterationResults = @()
$iterationMetrics = @()

for ($iter = 1; $iter -le $LoadTestIterations; $iter++) {
    if ($LoadTestIterations -gt 1) {
        Write-Host ""
        Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host "  LOAD TEST ITERATION $iter of $LoadTestIterations" -ForegroundColor Cyan
        Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
    }

    $iterStartTime = Get-Date

    # Process both sets
    $tpResults = Test-FileSet -FolderPath $TPFolder -SetLabel "TP" -Concurrency $ThreadCount
    Write-Host ""
    $fpResults = Test-FileSet -FolderPath $FPFolder -SetLabel "FP" -Concurrency $ThreadCount
    Write-Host ""

    $allResults = @($tpResults) + @($fpResults)

    if ($allResults.Count -eq 0) {
        Write-Log "No results to analyze. Exiting." "ERROR"
        exit 1
    }

    # Tag results with iteration number
    foreach ($r in $allResults) {
        $r | Add-Member -NotePropertyName Iteration -NotePropertyValue $iter -Force
    }
    $allIterationResults += $allResults

    # Per-iteration performance metrics
    $iterDuration = ((Get-Date) - $iterStartTime).TotalSeconds
    $iterPerf = Get-PerformanceMetrics -Results $allResults -TotalDurationSec $iterDuration
    $iterationMetrics += [PSCustomObject]@{
        Iteration   = $iter
        Throughput  = $iterPerf.ThroughputFilesPerSec
        AvgTimeMs   = $iterPerf.AvgResponseTimeMs
        MinTimeMs   = $iterPerf.MinResponseTimeMs
        MaxTimeMs   = $iterPerf.MaxResponseTimeMs
        P50Ms       = $iterPerf.P50Ms
        P95Ms       = $iterPerf.P95Ms
        P99Ms       = $iterPerf.P99Ms
        DurationSec = $iterPerf.TotalTimeSec
        TotalCalls  = $iterPerf.TotalCalls
        Errors      = $iterPerf.ErrorCount
    }

    # Calculate F1 for this iteration
    $matrix = Get-ConfusionMatrix -AllResults $allResults

    # Print summary to console
    Write-Host ""
    Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
    if ($LoadTestIterations -gt 1) {
        Write-Host "  ITERATION $iter F1 RESULTS" -ForegroundColor Cyan
    } else {
        Write-Host "  F1 BENCHMARK RESULTS" -ForegroundColor Cyan
    }
    Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("  True Positives:  " + $matrix.TruePositive) -ForegroundColor Green
    Write-Host ("  False Negatives: " + $matrix.FalseNegative) -ForegroundColor Red
    Write-Host ("  False Positives: " + $matrix.FalsePositive) -ForegroundColor Yellow
    Write-Host ("  True Negatives:  " + $matrix.TrueNegative) -ForegroundColor Green
    Write-Host ""
    Write-Host ("  Precision:  " + $matrix.Precision.ToString("0.000")) -ForegroundColor White
    Write-Host ("  Recall:     " + $matrix.Recall.ToString("0.000")) -ForegroundColor White
    Write-Host ("  F1 Score:   " + $matrix.F1.ToString("0.000")) -ForegroundColor $(if ($matrix.F1 -ge 0.9) { "Green" } elseif ($matrix.F1 -ge 0.7) { "Yellow" } else { "Red" })
    Write-Host ("  Accuracy:   " + $matrix.Accuracy.ToString("0.000")) -ForegroundColor White
    Write-Host ""
    Write-Host ("  Throughput: $($iterPerf.ThroughputFilesPerSec) files/sec | Avg: $($iterPerf.AvgResponseTimeMs)ms | P95: $($iterPerf.P95Ms)ms | P99: $($iterPerf.P99Ms)ms") -ForegroundColor White
    Write-Host ""
}

# ── Stop the process monitor and collect results ──
$monitorSummary = $null
if ($monitorJob) {
    Write-Host ""
    Write-Log "Stopping MediaServer process monitor..." "INFO"
    # Create stop-file to signal graceful shutdown
    $stopFile = $null
    try {
        $monitorConfig = (Get-Content -Path $configPath -Raw | ConvertFrom-Json).MonitorProcess
        if ($monitorConfig -and $monitorConfig.OutputDir) {
            $stopFile = Join-Path $monitorConfig.OutputDir "monitor_stop.txt"
            "stop" | Out-File -FilePath $stopFile -Force
        }
    } catch { }
    # Wait for monitor to exit gracefully
    $null = Wait-Job -Job $monitorJob -Timeout 15
    if ($monitorJob.State -ne 'Completed') {
        Write-Log "Monitor did not stop gracefully, forcing..." "WARN"
        Stop-Job -Job $monitorJob
    }
    $monitorSummary = Receive-Job -Job $monitorJob -ErrorAction SilentlyContinue
    Remove-Job -Job $monitorJob -Force
    Write-Log "Monitor stopped." "PASS"
    if ($stopFile -and (Test-Path $stopFile)) { Remove-Item $stopFile -Force -ErrorAction SilentlyContinue }
}

# ── Check for crash dump ──
$crashDumpDetected = $false
if ($MediaServerCrashDumpPath -and (Test-Path $MediaServerCrashDumpPath)) {
    $crashDumpDetected = $true
    $dumpFileInfo = Get-Item $MediaServerCrashDumpPath
    Write-Host ""
    Write-Log "⚠️ CRASH DUMP DETECTED!" "ERROR"
    Write-Log "  Path: $MediaServerCrashDumpPath" "ERROR"
    Write-Log "  Size: $([math]::Round($dumpFileInfo.Length / 1MB, 2)) MB" "ERROR"
    Write-Log "  Created: $($dumpFileInfo.LastWriteTime)" "ERROR"
    Write-Log "  MediaServer may have crashed during the benchmark. Check the dump file and monitor logs." "WARN"
}

# Use the last iteration for the confusion matrix in the report
$matrix = Get-ConfusionMatrix -AllResults ($allIterationResults | Where-Object { $_.Iteration -eq $LoadTestIterations })

# Aggregate performance metrics across all iterations
$totalDuration = ((Get-Date) - $script:StartTime).TotalSeconds
$aggregatePerf = Get-PerformanceMetrics -Results $allIterationResults -TotalDurationSec $totalDuration

# Generate HTML report
New-HtmlReport -AllResults $allIterationResults -Matrix $matrix -OutputPath $OutputReport `
    -PerformanceMetrics $aggregatePerf -IterationMetrics $iterationMetrics `
    -ThreadCount $ThreadCount -LoadTestIterations $LoadTestIterations `
    -CrashDumpDetected $crashDumpDetected -CrashDumpPath $MediaServerCrashDumpPath

Write-Host ""
Write-Log "Benchmark complete!" "PASS"
Write-Log "Open report: $OutputReport" "INFO"

# Final performance summary
Write-Host ""
Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  PERFORMANCE SUMMARY" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ("  Concurrency:          $ThreadCount thread(s)") -ForegroundColor White
Write-Host ("  Load Test Iterations: $LoadTestIterations") -ForegroundColor White
Write-Host ("  Total Calls:          $($aggregatePerf.TotalCalls)") -ForegroundColor White
Write-Host ("  Total Errors:         $($aggregatePerf.ErrorCount)") -ForegroundColor $(if($aggregatePerf.ErrorCount -gt 0){"Red"}else{"White"})
Write-Host ("  Total Duration:       $($aggregatePerf.TotalTimeSec) sec") -ForegroundColor White
Write-Host ("  Throughput:           $($aggregatePerf.ThroughputFilesPerSec) files/sec") -ForegroundColor White
Write-Host ("  Avg Response Time:    $($aggregatePerf.AvgResponseTimeMs) ms") -ForegroundColor White
Write-Host ("  Min Response Time:    $($aggregatePerf.MinResponseTimeMs) ms") -ForegroundColor White
Write-Host ("  Max Response Time:    $($aggregatePerf.MaxResponseTimeMs) ms") -ForegroundColor White
Write-Host ("  P50 (Median):         $($aggregatePerf.P50Ms) ms") -ForegroundColor White
Write-Host ("  P95 Latency:          $($aggregatePerf.P95Ms) ms") -ForegroundColor White
Write-Host ("  P99 Latency:          $($aggregatePerf.P99Ms) ms") -ForegroundColor White
Write-Host ""

# ── Display monitor summary if run ──
if ($monitorSummary) {
    Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  PROCESS MONITOR SUMMARY" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ("  Max CPU:              $($monitorSummary.MaxCPU_Pct)%") -ForegroundColor White
    Write-Host ("  Max Working Set:      $($monitorSummary.MaxWorkingSet_MB) MB") -ForegroundColor $(if($monitorSummary.MaxWorkingSet_MB -gt 2000){'Red'}else{'White'})
    Write-Host ("  Max Private Memory:   $($monitorSummary.MaxPrivateMemory_MB) MB") -ForegroundColor $(if($monitorSummary.MaxPrivateMemory_MB -gt 2000){'Red'}else{'White'})
    Write-Host ("  Max Handles:          $($monitorSummary.MaxHandles)") -ForegroundColor $(if($monitorSummary.MaxHandles -gt 10000){'Red'}else{'White'})
    Write-Host ("  Max Threads:          $($monitorSummary.MaxThreads)") -ForegroundColor $(if($monitorSummary.MaxThreads -gt 500){'Red'}else{'White'})
    if ($monitorSummary.ProcessExitDetected) {
        Write-Host ("  PROCESS CRASHED:      Exit code $($monitorSummary.ProcessExitCode)") -ForegroundColor Red
    } else {
        Write-Host ("  Process exit:         No") -ForegroundColor Green
    }
    if ($monitorSummary.HealthChecksFailed -gt 0) {
        Write-Host ("  Health failures:      $($monitorSummary.HealthChecksFailed) / $($monitorSummary.HealthChecksTotal)") -ForegroundColor Red
    }
    Write-Host ("  Monitor CSV:          $($monitorSummary.CsvPath)") -ForegroundColor Gray
    Write-Host ("  Monitor Summary JSON: $($monitorSummary.SummaryPath)") -ForegroundColor Gray
    Write-Host ""
}
