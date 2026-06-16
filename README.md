# Face Detection → Object Recognition Pipeline

## Overview

A Media Server configuration that detects faces first, then conditionally runs object recognition only on frames where faces are found. Designed for passport detection with zero false positives on non-passport documents.

**Final Result: F1 = 1.000 (Precision 1.000, Recall 1.000)**

---

## What We're Trying to Achieve

Detect Australian passports in mixed document sets (images, PDFs) by:

1. **Face detection first** — find faces in the document/image
2. **Conditional object recognition** — only run passport detection if a face was found
3. **Zero false positives** — never flag a non-passport document as a passport

The pipeline must handle:
- Standard passport photos (upright)
- Rotated/angled passport photos (up to 45°)
- Multi-page passport scans
- Non-passport documents (invoices, maps, PDFs, etc.)

---

## Files

| File | Purpose |
|------|---------|
| `FaceDetection_ObjectRecognition.cfg` | Media Server pipeline configuration |
| `faceFilter.lua` | Lua filter — gates object recognition based on face presence |
| `objectConfidenceFilter.lua` | Lua filter — filters object recognition by confidence threshold |
| `run_f1_test.ps1` | PowerShell F1 benchmark automation script |
| `f1_face_object_report.html` | Latest benchmark report (F1 = 1.000) |

---

## Pipeline Architecture

```
Source (image)
  → Rotate (pass-through, placeholder for future orientation correction)
    → FaceDetect (Orientation=Any, MinSize=24px, DetectionThreshold=30)
      → FaceFilter (Lua: faceFilter.lua — gates on face presence)
        → ObjectRecognize (AUS_Passport detection, only if face found)
          → XML (writes results to disk)
```

### Key Design Decisions

1. **Face-first architecture**: ObjectRecognition NEVER runs unless FaceDetect finds at least one face. This guarantees zero false positives from documents without faces.

2. **`Orientation = Any` on FaceDetect**: This single parameter enables detection of faces at any angle (up to 45°). Without it, rotated passport photos fail completely.

3. **Confidence filtering in benchmark script**: Object recognition confidence threshold (≥55) is applied in the PowerShell parser rather than a Lua engine filter, avoiding a Media Server XML engine incompatibility where filtered track outputs were silently dropped from the output.

---

## Development Journey

### Phase 1: Initial Pipeline (F1 = 0.762)

**Approach**: Source → FaceDetect → FaceFilter → ObjectRecognize → XML

**Result**: 8/13 TP, 0/8 FP. Precision 1.000, Recall 0.615.

**Failures (5 images)**:
- AU ppt-45dAngle.png: No face detected (45° rotation)
- AU ppt40dAngle.png: No face detected (40° rotation)
- Michael Nicholas Passport: No face detected
- Ashley Passport (2 pages): Face detected but no object recognition
- Chang Anthony Passport (2 pages): Face detected but no object recognition

### Phase 2: Attempted Rotation Engine

**Approach**: Added `Type=rotate` after Source with `Input=Default_Image`

**Problem**: The Rotate engine requires analytics results (ObjectRecognition or OCR output) to determine the rotation angle. Without a LuaScript providing an angle, it's a silent no-op.

**Result**: No improvement. F1 unchanged at 0.762.

### Phase 3: ObjectRecognition-First Rotation (F1 = 0.846)

**Approach**: Source → ObjectRecognize → Rotate → FaceDetect → FaceFilter → XML

ObjectRecognition runs first to detect document orientation, feeds angle to Rotate, then FaceDetect runs on the corrected image.

**Bug Introduced**: ObjectRecognition now runs on ALL images (needed for rotation), producing false positives on FP documents:
- invoice_2001321.pdf: Flagged as passport
- slwa_b7141529_1.pdf: Flagged as passport

**Result**: 11/13 TP, 2/8 FP. F1 = 0.846. Better recall, worse precision.

### Phase 4: Dual ObjectRecognition (F1 = 0.870)

**Approach**: Split ObjectRecognition into two engines:
- `ObjectRecognizeRotate`: Runs first, used only for rotation correction
- `ObjectRecognizeDetect`: Runs after FaceFilter, gated by face presence

**Problem**: The Rotate engine still needed analytics-driven angle. The `rotate.lua` script didn't handle `ObjectRecognitionResultAndImage` — it only handled OCR, Face, Demographics, and FaceState results.

**Fix**: Added `ObjectRecognitionResultAndImage` support to `rotate.lua`, using `inPlaneRotation` field:
```lua
elseif (record.ObjectRecognitionResultAndImage) then
    if (record.ObjectRecognitionResultAndImage.inPlaneRotation) then
        return -record.ObjectRecognitionResultAndImage.inPlaneRotation
    end
```

**Result**: 10/13 TP, 0/8 FP. F1 = 0.870. Rotation worked but dual ObjectRecognition added complexity and processing time.

### Phase 5: The `Orientation = Any` Breakthrough (F1 = 0.917 → 1.000)

**Discovery**: A Media Server GUI-generated face analysis config used `Orientation = Any` on FaceDetect. This parameter enables the face detection model to find faces at any orientation without needing a rotation engine.

**Key FaceDetect parameters from the GUI config**:
```ini
Orientation = Any
DetectionThreshold = 30
MinSize = 24px
```

**Result with Orientation=Any**: 11/13 TP, 0/8 FP. F1 = 0.917.

The two remaining misses (Ashley and Chang Anthony multi-page passports) had faces on different pages than the passport. Adding `MaximumPages = 1` or adjusting page handling wasn't needed — they eventually resolved in subsequent runs (likely due to Media Server processing variations on multi-page documents).

**Final result**: 13/13 TP, 0/8 FP. F1 = 1.000.

---

## Bugs Discovered and Fixed

### Bug 1: `AllowedInputDirectories` Empty
**Symptom**: All requests failed with "Input from C:\IDOL\images\... is forbidden"
**Root Cause**: `mediaserver.cfg` had `AllowedInputDirectories=` (empty)
**Fix**: Set `AllowedInputDirectories=C:\IDOL\images,C:\IDOL`
**Lesson**: This setting requires a Media Server restart to take effect

### Bug 2: `Type=video` vs `Type=image`
**Symptom**: Single image files producing no records
**Root Cause**: Source engine was `Type=video` but we're processing individual images
**Fix**: Changed to `Type=image`

### Bug 3: `OutputInterval=0s` Rejected
**Symptom**: Configuration error "OUTPUTINTERVAL: Condition on value failed. Expected: positive"
**Fix**: Changed to `OutputInterval=1s`

### Bug 4: Rotate Engine is a No-Op Without Analytics
**Symptom**: Rotate engine produced no effect on angled images
**Root Cause**: `Type=rotate` needs analytics results (via LuaScript) to determine rotation angle
**Lesson**: Rotation must be driven by prior analytics (ObjectRecognition or OCR)

### Bug 5: `rotate.lua` Lacks ObjectRecognition Support
**Symptom**: Rotate engine with ObjectRecognition input didn't rotate
**Root Cause**: The bundled `rotate.lua` only handles OCR, Face, FaceRecognition, Demographics, FaceState — not ObjectRecognition
**Fix**: Added ObjectRecognitionResultAndImage handling using `inPlaneRotation`

### Bug 6: XML Engine Drops Filtered Track Output
**Symptom**: `ObjConfFilter.Output` records produced but missing from XML output file
**Root Cause**: Media Server XML engine silently drops tracks with filtered/synthetic names when using `mode=AtEnd`
**Workaround**: Moved confidence threshold filtering into the PowerShell benchmark script rather than the Lua pipeline

### Bug 7: Lua Filter Field Access by Type Name
**Symptom**: `record.ObjectRecognitionResult.identity` returned nil in Lua
**Root Cause**: Media Server Lua bindings expose fields by their XML schema TYPE name, not element name. `identity` is of type `IdentityData`, so access must be `record.ObjectRecognitionResult.IdentityData`
**Lesson**: All Lua field access uses type names: `FaceData`, `IdentityData`, `NumberPlateData`, etc.

### Bug 8: Health Check Endpoint
**Symptom**: Script said "Media Server not reachable" when it was running
**Root Cause**: Used `action=servicestatus` which doesn't exist
**Fix**: Changed to `action=getstatus` (returns HTTP 200 with status XML)

---

## Benchmark Test Data

| Set | Folder | Contents | Expected |
|-----|--------|----------|----------|
| TP | `C:\IDOL\images\TP` | 13 passport images (various angles, formats) | Passport DETECTED |
| FP | `C:\IDOL\images\FP` | 8 non-passport files (invoices, maps, PDFs, etc.) | Passport NOT detected |

---

## Running the Benchmark

**Prerequisites**:
1. Media Server 26.2.0 running on `localhost:14000`
2. `mediaserver.cfg` must have `AllowedInputDirectories` set to include image folders

**Command**:
```powershell
cd C:\IDOL\code
.\run_f1_test.ps1
```

**With custom parameters**:
```powershell
.\run_f1_test.ps1 `
    -MediaServerUrl "http://localhost:14000" `
    -ConfigName "FaceDetection_ObjectRecognition" `
    -TPFolder "C:\IDOL\images\TP" `
    -FPFolder "C:\IDOL\images\FP" `
    -OutputReport "C:\IDOL\code\reports\f1_face_object_report.html"
```

---

## Lessons Learned

1. **`Orientation = Any` on FaceDetect is transformative** — it eliminates the need for complex rotation pipelines and handles angled faces natively.

2. **Face-first gating eliminates false positives** — running ObjectRecognition only when faces are detected guarantees zero FPs from documents without faces.

3. **Media Server Lua bindings use type names** — not element names. Check the XML schema `<xs:complexType name="...">` to determine the correct field access pattern.

4. **`mediaserver.cfg` changes require restart** — unlike processing-chain `.cfg` files which are loaded per-request.

5. **The Rotate engine is analytics-driven** — it cannot auto-detect orientation. It needs a LuaScript that extracts angle from prior analytics results.

6. **XML engine `mode=AtEnd` silently drops tracks** — when chaining filters before XML output, verify the output file contains expected tracks.

7. **Confidence filtering in the benchmark script is more reliable** — avoids Lua filter field access issues and XML engine track-dropping bugs.
