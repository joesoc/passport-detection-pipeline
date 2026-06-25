IDOL MediaServer pipeline that detects faces in images, filters candidates via a Lua script, then performs object recognition to identify passports (e.g., Australian passports). The suite benchmarks the pipeline against True Positive (passport) and False Positive (non-passport) image sets and generates an F1 score HTML report.

## Files

| File | Purpose |
|---|---|
| `FaceDetection_ObjectRecognition.cfg` | MediaServer pipeline configuration (FaceDetect → Lua Filter → ObjectRecognition) |
| `faceFilter.lua` | Lua script that gates which detected faces proceed to object recognition |
| `run_f1_test.ps1` | PowerShell benchmark script — sends images through the pipeline and computes F1 metrics |
| `config.example.json` | Template config file — copy to `config.json` and edit for your environment |
| `config.json` | Environment-specific settings (ignored by git) — MediaServer URL and HTTPS toggle |
| `f1_face_object_report.html` | Sample/generated HTML report with confusion matrix and per-file details |

## Prerequisites

- **IDOL MediaServer** (tested on 24.3.1, 25.3.0, 26.1.0, 26.2.0)
- **PowerShell 5.1+** (Windows) or **PowerShell 7+** (cross-platform)
- Image sets organized into `TP/` (passport images) and `FP/` (non-passport images)

## Configuration

Environment-specific settings live in `config.json` (git-ignored). Copy the template to get started:

```powershell
copy config.example.json config.json
```

Edit `config.json` for your environment:

```json
{
    "MediaServerUrl": "http://my-mediaserver:14000",
    "UseHttps": false,
    "ConfigName": "FaceDetection_ObjectRecognition",
    "TPFolder": "C:\\IDOL\\images\\TP",
    "FPFolder": "C:\\IDOL\\images\\FP",
    "OutputReport": "C:\\IDOL\\code\\reports\\f1_face_object_report.html",
    "MediaServerOutputDir": "C:\\IDOL\\MediaServer_26.2.0_WINDOWS_X86_64\\output",
    "PassportIdentityPattern": "passport|AUS_Passport",
    "PassportDatabasePattern": "passport|AUS_Passport",
    "ThreadCount": 1,
    "LoadTestIterations": 1,
    "MonitorEnabled": false,
    "AutoStart": false,
    "MediaServerActionsDir": "C:\\IDOL\\MediaServer_26.2.0_WINDOWS_X86_64\\actions",
    "MediaServerLogsDir": "C:\\IDOL\\MediaServer_26.2.0_WINDOWS_X86_64\\logs",
    "MediaServerStartScript": "C:\\IDOL\\MediaServer_26.2.0_WINDOWS_X86_64\\start-mediaserver.bat",
    "MediaServerProcessName": "mediaserver",
    "MediaServerCrashDumpPath": "C:\\IDOL\\MediaServer_26.2.0_WINDOWS_X86_64\\autn_report.dmp"
}
```

| Key | Type | Description |
|---|---|---|
| `MediaServerUrl` | `string` | Base URL of the MediaServer (scheme + host + port) |
| `UseHttps` | `boolean` | Set to `true` to convert `http://` → `https://` |
| `ConfigName` | `string` | MediaServer pipeline configuration name |
| `TPFolder` | `string` | Path to True Positive images (contain passports) |
| `FPFolder` | `string` | Path to False Positive images (no passports) |
| `OutputReport` | `string` | Path where the HTML report will be written |
| `MediaServerOutputDir` | `string` | MediaServer output directory (where pipeline XML results are written by MediaServer) |
| `PassportIdentityPattern` | `string` | Regex pattern to match object identity names that indicate a passport |
| `PassportDatabasePattern` | `string` | Regex pattern to match object database names that indicate a passport |
| `ThreadCount` | `int` | Number of concurrent threads for parallel API calls. Set to 1 for sequential processing. |
| `LoadTestIterations` | `int` | Number of times to repeat the full benchmark suite. Set >1 for sustained load testing. |
| `MonitorEnabled` | `boolean` | Enable process-level monitoring of mediaserver.exe (CPU, memory, handles, threads, crash detection). |
| `AutoStart` | `boolean` | If `true`, auto-starts `mediaserver.exe` when not running. Set `false` when MediaServer runs as a service. |
| `MediaServerActionsDir` | `string` | Path to MediaServer `actions` folder — cleared before each benchmark run. |
| `MediaServerLogsDir` | `string` | Path to MediaServer `logs` folder — cleared before each benchmark run. |
| `MediaServerStartScript` | `string` | Full path to `start-mediaserver.bat`. Used by AutoStart to launch MediaServer via `cmd.exe /c`. |
| `MediaServerProcessName` | `string` | Process name to check/start (without `.exe`). Default: `mediaserver`. |
| `MediaServerCrashDumpPath` | `string` | Path to `autn_report.dmp`. Checked after the run — if present, the report highlights a crash. |

CLI arguments always override config.json values, so you can do one-off runs without editing the file.

## Quick Start

```powershell
# First time: copy the example config and edit for your environment
copy config.example.json config.json
# Edit config.json — set all paths and settings for your environment

# Default: uses settings from config.json
.\run_f1_test.ps1

# CLI arguments override config.json for one-off runs
.\run_f1_test.ps1 -MediaServerUrl "http://other-server:14000" -UseHttps
.\run_f1_test.ps1 -TPFolder "D:\testdata\passports" -OutputReport "D:\reports\benchmark.html"

# Debug mode — verbose tracing for troubleshooting
.\run_f1_test.ps1 -Debug

# Performance / Load Testing: run with 4 concurrent threads
.\run_f1_test.ps1 -ThreadCount 4

# Sustained load test: repeat the full benchmark 10 times with 8 threads
.\run_f1_test.ps1 -ThreadCount 8 -LoadTestIterations 10

# Enable process monitoring to capture performance data & detect crashes
# Set `"MonitorEnabled": true` in config.json, then run as normal
.\run_f1_test.ps1

# Run the monitor standalone (for long-running observation)
.\monitor-mediaserver.ps1 -ProcessName "mediaserver" -SampleIntervalSec 5 -HealthCheck
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-MediaServerUrl` | `string` | from `config.json` | Base URL of the MediaServer (scheme + host + port). CLI overrides config. |
| `-ConfigName` | `string` | from `config.json` | Name of the MediaServer configuration to invoke. CLI overrides config. |
| `-TPFolder` | `string` | from `config.json` | Path to True Positive images (contain passports). CLI overrides config. |
| `-FPFolder` | `string` | from `config.json` | Path to False Positive images (no passports). CLI overrides config. |
| `-OutputReport` | `string` | from `config.json` | Path for the generated HTML report. CLI overrides config. |
| `-TimeoutSec` | `int` | `120` | Timeout in seconds for each MediaServer API call |
| `-ThreadCount` | `int` | from `config.json` | Number of concurrent threads for parallel API calls. Set >1 for concurrency. |
| `-LoadTestIterations` | `int` | from `config.json` | Repeat the full benchmark N times for sustained load. Metrics aggregated across iterations. |
| `-UseHttps` | `switch` | from `config.json` | Replace `http://` with `https://` in the MediaServer URL. CLI overrides config. |
| `-Debug` | `switch` | `$false` | Enable verbose tracing: URI, HTTP details, token, XML paths, per-face/object confidence |

## How It Works

1. **Health Check** — Verifies the MediaServer is reachable via `action=getstatus`.
2. **Process TP Set** — Sends each passport image through the pipeline, recording face detection and object recognition results.
3. **Process FP Set** — Sends each non-passport image through the same pipeline.
4. **F1 Calculation** — Builds a confusion matrix from passport detection outcomes:
   - **TP**: Passport image → passport detected ✓
   - **FN**: Passport image → passport NOT detected ✗
   - **FP**: Non-passport image → passport falsely detected ⚠
   - **TN**: Non-passport image → passport correctly NOT detected ✓
5. **HTML Report** — Generates a styled report with confusion matrix, per-file details, face statistics, and optimization recommendations.

## Pipeline Flow

```
Source (image file) → FaceDetect → faceFilter.lua → ObjectRecognition → Result
```

- **FaceDetect**: Locates faces in the image and returns position/confidence/angle metadata.
- **faceFilter.lua**: Filters face results (e.g., requires sufficient frontal angle, minimum size) before allowing object recognition.
- **ObjectRecognition**: Identifies objects (passports) in the face regions. Confidence threshold filtering (≥ 55%) is applied in the PowerShell benchmark script.

## Debugging

Run with the `-Debug` switch for verbose magenta-colored tracing output:

```powershell
.\run_f1_test.ps1 -Debug
```

Debug output includes:
- Full API URI sent to MediaServer
- HTTP status code, response time, and content length
- Session token extraction (or raw XML preview if token missing)
- Output file path check with directory listing on failure
- Raw XML preview of the output file (first 1000 chars)
- All track names found in the XML
- XPath result counts for `FaceDetect.Result` and `ObjectRecognize.Result`
- Per-face details: confidence, angles, size in image
- Per-object details: identity name, database, confidence, and threshold pass/fail

## Performance Testing & Load Testing

The script supports multi-threaded concurrent API calls and sustained load testing for benchmarking MediaServer throughput.

### Concurrency (`-ThreadCount`)

When `ThreadCount` > 1, files are processed in parallel using multiple runspaces:

- **PowerShell 7+**: Uses `ForEach-Object -Parallel` with `-ThrottleLimit` for native parallel processing.
- **PowerShell 5.1**: Falls back to `RunspacePool` for cross-version compatibility.

```powershell
# 4 concurrent API calls
.\run_f1_test.ps1 -ThreadCount 4
```

Each result entry is tagged with its thread ID so you can verify parallel execution in the console output.

### Load Testing (`-LoadTestIterations`)

When `LoadTestIterations` > 1, the entire TP+FP benchmark repeats multiple times. This measures sustained performance and reveals degradation under load.

```powershell
# 10 iterations with 8 threads = heavy sustained load
.\run_f1_test.ps1 -ThreadCount 8 -LoadTestIterations 10
```

### Performance Metrics Reported

The script reports these metrics for every run:

| Metric | Description |
|---|---|
| **Throughput** | Files processed per second |
| **Avg Response Time** | Mean API response time across all calls |
| **Min / Max** | Fastest and slowest individual API call |
| **P50 (Median)** | 50th percentile latency |
| **P95** | 95th percentile latency (tail latency) |
| **P99** | 99th percentile latency (worst-case tail) |
| **Total Duration** | Wall-clock time for the entire run |
| **Total API Calls** | Number of `action=process` calls made |
| **Errors** | Count of failed API calls |

All metrics are displayed in the console and rendered in the HTML report. When load testing, a per-iteration breakdown table is also included in the report.

## Process Monitoring (`MonitorEnabled`)

When `MonitorEnabled` is set to `true` in `config.json`, `run_f1_test.ps1` automatically launches `monitor-mediaserver.ps1` as a background job that samples the MediaServer process during the entire benchmark run.

### What Gets Captured

| Category | Metrics |
|---|---|
| **CPU** | Process CPU %, total CPU time (sec), system-wide CPU % |
| **Memory** | Working Set (MB), Private Memory (MB), Virtual Memory (MB), Peak Working Set (MB), Paged Memory (MB) |
| **Handles & Threads** | Handle count, thread count (leak detection) |
| **GDI / USER Objects** | GDI object count, USER object count (resource leak detection) |
| **I/O** | Read/write operation counts and transfer bytes |
| **System** | Available physical memory (MB), total physical memory (MB) |
| **Health Check** | HTTP `action=getstatus` response code and latency at each sample |
| **Crash Detection** | Process exit time & exit code, crash dump (.dmp) file detection |

### Output Files

All monitoring output is written to the directory configured in `MonitorProcess.OutputDir` (default: `./monitor_logs/`):

| File | Format | Description |
|---|---|---|
| `mediaserver_monitor_YYYYMMDD_HHmmss.csv` | CSV | Time-series data: one row per sample interval |
| `mediaserver_monitor_YYYYMMDD_HHmmss.summary.json` | JSON | Aggregated summary: max/avg/min for all metrics, exit details |
| `mediaserver_monitor_YYYYMMDD_HHmmss.dumps.log` | Text | Crash dump file discoveries (if `CrashDumpDir` is set) |

### Configuration

```json
{
  "MonitorEnabled": true,
  "MonitorProcess": {
    "ProcessName": "mediaserver",
    "SampleIntervalSec": 2,
    "OutputDir": "C:\\IDOL\\code\\monitor_logs",
    "CrashDumpDir": "C:\\IDOL\\MediaServer_26.2.0_WINDOWS_X86_64",
    "MediaServerUrl": "http://localhost:14000",
    "HealthCheck": true
  }
}
```

| Key | Type | Description |
|---|---|---|
| `ProcessName` | `string` | Process name to monitor (without `.exe`). Default: `mediaserver`. |
| `SampleIntervalSec` | `int` | Seconds between samples. Lower = finer granularity but more data. |
| `OutputDir` | `string` | Directory for CSV, JSON summary, and dump log files. |
| `CrashDumpDir` | `string` | Directory to watch for `.dmp` crash dump files. Set to MediaServer install dir. |
| `MediaServerUrl` | `string` | URL for optional health checks (same as main config). |
| `HealthCheck` | `boolean` | Whether to call `action=getstatus` at each sample interval. |

### Crash Diagnosis Workflow

1. Enable monitoring in `config.json`: `"MonitorEnabled": true`
2. Run the benchmark as usual: `pwsh .\run_f1_test.ps1 -ThreadCount 20`
3. If the MediaServer crashes during the run, the monitor detects the process exit and logs:
   - Exact exit time and exit code
   - Max resource usage before crash (working set, handles, threads)
   - Any crash dump files created
4. Review the CSV in Excel or Power BI to see the resource usage trend leading up to the crash
5. Check the `.summary.json` for a quick overview of peak values

### Standalone Usage

The monitor can also run independently for long-running observation:

```powershell
# Monitor with 5-second sampling and health checks
.\monitor-mediaserver.ps1 -ProcessName "mediaserver" -SampleIntervalSec 5 -HealthCheck -MediaServerUrl "http://localhost:14000"

# Load settings from config.json
.\monitor-mediaserver.ps1 -ConfigPath ".\config.json"

# Stop gracefully: create a stop file
ni .\monitor_logs\monitor_stop.txt
```

## License

See [LICENSE](LICENSE).
