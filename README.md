IDOL MediaServer pipeline that detects faces in images, filters candidates via a Lua script, then performs object recognition to identify passports (e.g., Australian passports). The suite benchmarks the pipeline against True Positive (passport) and False Positive (non-passport) image sets and generates an F1 score HTML report.

## Files

| File | Purpose |
|---|---|
| `FaceDetection_ObjectRecognition.cfg` | MediaServer pipeline configuration (FaceDetect → Lua Filter → ObjectRecognition) |
| `faceFilter.lua` | Lua script that gates which detected faces proceed to object recognition |
| `run_f1_test.ps1` | PowerShell benchmark script — sends images through the pipeline and computes F1 metrics |
| `f1_face_object_report.html` | Sample/generated HTML report with confusion matrix and per-file details |

## Prerequisites

- **IDOL MediaServer** (tested on 24.3.1, 25.3.0, 26.1.0, 26.2.0)
- **PowerShell 5.1+** (Windows) or **PowerShell 7+** (cross-platform)
- Image sets organized into `TP/` (passport images) and `FP/` (non-passport images)

## Quick Start

```powershell
# Default: HTTP to localhost:14000
.\run_f1_test.ps1

# HTTPS (MediaServer configured with SSL)
.\run_f1_test.ps1 -UseHttps

# Custom server with HTTPS
.\run_f1_test.ps1 -MediaServerUrl "http://mediaserver.example.com:14000" -UseHttps

# Custom image folders and report output
.\run_f1_test.ps1 `
    -MediaServerUrl "http://localhost:14000" `
    -TPFolder "D:\testdata\passports" `
    -FPFolder "D:\testdata\negatives" `
    -OutputReport "D:\reports\benchmark.html" `
    -TimeoutSec 180

# Debug mode — verbose tracing for troubleshooting
.\run_f1_test.ps1 -Debug
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-MediaServerUrl` | `string` | `http://localhost:14000` | Base URL of the MediaServer (scheme + host + port) |
| `-ConfigName` | `string` | `FaceDetection_ObjectRecognition` | Name of the MediaServer configuration to invoke |
| `-TPFolder` | `string` | `C:\IDOL\images\TP` | Path to True Positive images (contain passports) |
| `-FPFolder` | `string` | `C:\IDOL\images\FP` | Path to False Positive images (no passports) |
| `-OutputReport` | `string` | `C:\IDOL\code\reports\f1_face_object_report.html` | Path for the generated HTML report |
| `-TimeoutSec` | `int` | `120` | Timeout in seconds for each MediaServer API call |
| `-UseHttps` | `switch` | `$false` | Replace `http://` with `https://` in the MediaServer URL |
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
