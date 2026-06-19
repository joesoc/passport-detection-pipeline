# FaceDetection_ObjectRecognition F1 Benchmark Suite  v1.3.0
# Tests the pipeline against True Positive and False Positive file sets
# Generates a detailed HTML report with F1 score and optimization insights

param(
    [string]$MediaServerUrl,
    [string]$ConfigName,
    [string]$TPFolder,
    [string]$FPFolder,
    [string]$OutputReport,
    [int]$TimeoutSec = 120,
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
}

if (Test-Path $configPath) {
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    foreach ($key in $configDefaults.Keys) {
        if (-not $PSBoundParameters.ContainsKey($key)) {
            $configValue = $config.$key
            if ($null -ne $configValue) {
                if ($key -eq "UseHttps") {
                    Set-Variable -Name $key -Value ([switch]$configValue)
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
        [int]$Timeout = 120
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
        $uri = "$MediaServerUrl/action=process&Source=$([uri]::EscapeDataString($FilePath))&ConfigName=$Config&Synchronous=true"
        Write-DebugLog "URI: $uri"
        
        $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $Timeout -UseBasicParsing
        $sw.Stop()
        $result.ResponseTimeMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        $result.StatusCode = $response.StatusCode
        $result.RawXml = $response.Content
        
        Write-DebugLog "HTTP $($response.StatusCode) | ResponseTime: $($result.ResponseTimeMs)ms | ContentLength: $($response.Content.Length) chars"

        if ($response.StatusCode -eq 200) {
            # Extract session token from response
            if ($response.Content -match '<token>([^<]+)</token>') {
                $result.SessionToken = $Matches[1]
                Write-DebugLog "SessionToken extracted: $($result.SessionToken)"
            } else {
                Write-DebugLog "WARNING: No <token> found in response. Raw XML (first 500 chars): $($response.Content.Substring(0, [Math]::Min(500, $response.Content.Length)))"
            }
            
            # Check for error in response before declaring success
            if ($response.Content -match '<response>ERROR</response>' -or $response.Content -match '<error>') {
                $result.ErrorMessage = "Media Server returned error"
                if ($response.Content -match '<errorstring>([^<]+)</errorstring>') {
                    $result.ErrorMessage = $Matches[1]
                }
                return $result
            }
            
            $result.Success = $true
            
            # Read the output XML file written to disk
            if ($result.SessionToken) {
                $outputFile = Join-Path $MediaServerOutputDir "$($result.SessionToken)\face_object.xml"
                Write-DebugLog "Looking for output file: $outputFile"
                if (Test-Path $outputFile) {
                    $result.OutputFilePath = $outputFile
                    $outputXml = Get-Content -Path $outputFile -Raw -Encoding UTF8
                    Write-DebugLog "Output file found | Size: $($outputXml.Length) chars"
                    Write-DebugLog "Output XML (first 1000 chars): $($outputXml.Substring(0, [Math]::Min(1000, $outputXml.Length)))"
                    Parse-MediaServerResponse -Result $result -XmlContent $outputXml
                } else {
                    Write-DebugLog "WARNING: Output file NOT found at: $outputFile"
                    # List what's in the output directory to help diagnose
                    $parentDir = Split-Path $outputFile -Parent
                    if (Test-Path $parentDir) {
                        $contents = (Get-ChildItem $parentDir -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ", "
                        Write-DebugLog "Directory contents of $parentDir : $contents"
                    } else {
                        Write-DebugLog "Parent directory $parentDir does not exist"
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
        [string]$XmlContent
    )

    try {
        [xml]$xml = $XmlContent

        # List all track names found in the XML
        $allTracks = Select-Xml -Xml $xml -XPath "//track" | ForEach-Object { $_.Node.name }
        Write-DebugLog "Tracks found in output XML: $($allTracks -join ', ')"

        # --- Parse Face Detection Results ---
        # Face data is in <track name="FaceDetect.Result">/<record>/<FaceResult>/<face>
        $faceResults = Select-Xml -Xml $xml -XPath "//track[@name='FaceDetect.Result']/record/FaceResult"
        Write-DebugLog "FaceDetect.Result XPath returned: $($faceResults.Count) FaceResult node(s)"
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
                Write-DebugLog "Face #$($faceConfidences.Count+1): confidence=$($faceInfo.Confidence)% angleX=$($faceInfo.OutOfPlaneAngleX) angleY=$($faceInfo.OutOfPlaneAngleY) sizeInImg=$($faceInfo.PercentageInImage)%"
                $Result.FaceDetails += $faceInfo
                $faceConfidences += $faceInfo.Confidence
            }
            $Result.FaceConfidence = [math]::Round(($faceConfidences | Measure-Object -Average).Average, 2)
        }

        # --- Parse Object Recognition Results ---
        # Object data is in <track name="ObjectRecognize.Result">/<record>/<ObjectRecognitionResult>
        $objResults = Select-Xml -Xml $xml -XPath "//track[@name='ObjectRecognize.Result']/record/ObjectRecognitionResult"
        Write-DebugLog "ObjectRecognize.Result XPath returned: $($objResults.Count) ObjectRecognitionResult node(s)"
        if ($objResults) {
            $Result.ObjectRecognized = $true
            
            $objConfidences = @()
            foreach ($or in $objResults) {
                $identity = $or.Node.identity
                $identName = if ($identity.identifier) { $identity.identifier } else { "Unknown" }
                $identDB   = if ($identity.database) { $identity.database } else { "" }
                $identConf = if ($identity.confidence) { [double]$identity.confidence } else { 0 }
                
                Write-DebugLog "ObjectRecognition: identity='$identName' db='$identDB' confidence=$identConf (threshold=55)"
                
                # Confidence threshold filter: only count results >= 55
                if ($identConf -lt 55) {
                    Write-DebugLog "  -> Filtered OUT (below threshold)"
                    continue
                }
                
                $objInfo = [PSCustomObject]@{
                    Identity   = "$identName ($identDB)"
                    Confidence = $identConf
                }
                $Result.ObjectDetails += $objInfo
                $objConfidences += $identConf
                
                # Check if any recognized object is passport-related
                if ($identName -match "passport|AUS_Passport") {
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
# PROCESS ALL FILES
# ============================================================

function Test-FileSet {
    param(
        [string]$FolderPath,
        [string]$SetLabel  # "TP" or "FP"
    )

    $results = @()
    
    if (-not (Test-Path $FolderPath)) {
        Write-Log "Folder not found: $FolderPath" "ERROR"
        return $results
    }

    $files = Get-ChildItem -Path $FolderPath -File

    if ($files.Count -eq 0) {
        Write-Log "No files found in $FolderPath" "WARN"
        return $results
    }

    Write-Log "Processing $($files.Count) files from [$SetLabel] set..." "INFO"

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
        [string]$OutputPath
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

    # Stats rows for face detection
    $faceStatsRows = ""
    if ($faceDetectedCount -gt 0) {
        $faceRecords = $AllResults | Where-Object { $_.FaceDetected }
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
Write-Host ""

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

# Process both sets
$tpResults = Test-FileSet -FolderPath $TPFolder -SetLabel "TP"
Write-Host ""
$fpResults = Test-FileSet -FolderPath $FPFolder -SetLabel "FP"
Write-Host ""

$allResults = @($tpResults) + @($fpResults)

if ($allResults.Count -eq 0) {
    Write-Log "No results to analyze. Exiting." "ERROR"
    exit 1
}

# Calculate F1
$matrix = Get-ConfusionMatrix -AllResults $allResults

# Print summary to console
Write-Host ""
Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  F1 BENCHMARK RESULTS" -ForegroundColor Cyan
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

# Generate HTML report
New-HtmlReport -AllResults $allResults -Matrix $matrix -OutputPath $OutputReport

Write-Host ""
Write-Log "Benchmark complete!" "PASS"
Write-Log "Open report: $OutputReport" "INFO"
