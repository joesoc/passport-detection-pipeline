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
    "MediaServerOutputDir": "C:\\IDOL\\MediaServer_26.2.0_WINDOWS_X86_64\\output"
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

## License

See [LICENSE](LICENSE).
