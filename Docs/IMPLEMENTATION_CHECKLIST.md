# Implementation Checklist & Critical Notes

**This document is your build map.** Every checkbox must be addressed. Every caveat must be understood before writing code. Things checked off are ready to integrate; things unchecked will break silently.

---

## Phase 1: Core Video & Analysis Loop

### Capture & Recording
- [ ] **`AppState` initialization**
  - Create `@StateObject var sessionStore: SessionStore`
  - Create `@StateObject var recordingSession: JumpRecording` — decide between `DeviceJumpRecorder` (real hardware) or `FixtureJumpRecorder` (simulator testing)
  - Expose `recordingSession` to capture screen

- [ ] **`DeviceJumpRecorder` implementation** (CameraHardware.swift:128–200)
  - Permission: `AVCaptureDevice.requestAccess(for: .video)` before session config, not alongside it
  - Format selection: Match the fingerprint used in lens calibration — if calibration was 1080p@150fps, capture must be exactly that format
  - **CRITICAL: Pin frame duration** — set BOTH `activeVideoMinFrameDuration` and `activeVideoMaxFrameDuration` to exactly `CMTime(value: 1, timescale: 150)`. Setting only min leaves iOS free to slow down in dim light
  - **CRITICAL: Stabilisation OFF** — `AVCaptureConnection.preferredVideoStabilizationMode = .off`. On some devices this setter is accepted and ignored; verify it took effect by checking the property again
  - Exposure cap: `maxExposureDuration = 1.0 / 500` (stay well under frame budget to avoid motion blur at contact)
  - Lock focus, exposure, white balance once athlete is in frame
  - Measure delivered frame rate from sample buffer timestamps, not from the requested format
  - Reject clip if delivered rate < 120 fps (ConsistencyGuard will catch it anyway, but fail fast)
  - Check thermal state and free disk before arming record

- [ ] **`FixtureJumpRecorder` for simulator**
  - Bundle a 150 fps test clip in the app (a 2–3 second jump is 300–450 MB; keep one fixture, not one per test)
  - Verify it passes ConsistencyGuard (correct frame rate, correct fingerprint if applicable)
  - Use this while DeviceJumpRecorder is being built

### Pose & Metrics
- [ ] **MediaPipe integration**
  - Add to Podfile: `pod 'MediaPipeTasksVision', '~> 0.10.14'`
  - Download `pose_landmarker_heavy.task` from the model garden and add to app target (not library) with Target Membership checked
  - Create `PoseEstimator` if it doesn't exist — extract 33 landmarks from every frame of a recorded clip
  - Output: `[ReconstructedFrame]` with keypoints already extracted

- [ ] **`AnalysisRunner` conformance to `EventReanalysing`**
  - Implement: take `[EventSnapshot]`, run `PhaseSegmenter` on the ground events they represent, calculate metrics, return `ReanalysisOutcome`
  - This is what the "Re-analyse" button in event correction calls
  - Without it, the correction screen reports re-analysis unavailable

### Session Persistence
- [ ] **`SessionStore` integration into `AppState`**
  - `sessionStore = try SessionStore()` in `AppState.init()`
  - On recording finish, call `sessionStore.save(_:)` with the new `StoredSession`
  - Video retention starts as `.temporary(expiresAt: RetentionPolicy.expiryDate())`

---

## Phase 2: Event Correction & Results

### Event Correction Screen
- [ ] **Wiring into `AppState`**
  - Results screen discovers video URL: `let videoURL = await sessionStore.videoURL(for: session)`
  - Pass to `EventCorrectionView(session:store:videoURL:reanalyser:onFinished:)`

- [ ] **Video playback via `DeviceJumpRecorder.stop()` result**
  - The clip is already on disk at the URL `CapturedClip.url`
  - `EventCorrectionView.setUpPlayer()` creates `AVPlayer(url:)` and attaches it to `EventCorrectionModel`
  - Player must have `automaticallyWaitsToMinimizeStalling = false` or frame seeking is approximate

- [ ] **Frame picker range safety**
  - If `EventSnapshot.detectedFrameIndex` is outside `[0, frameCount-1]`, clamp it before calculating range (EventCorrectionView.swift:617 shows the pattern)
  - A corrupted session file could land an index outside the clip; catching it here prevents a trap at runtime

### Results Screen
- [ ] **Metrics display**
  - Distance metric unit conversions use `Imperial.feetInches(_:)` (returns e.g. `"17′ 5.4″"`)
  - Distances and small distances use `Imperial.feetInches()` and `Imperial.inches()` respectively — one decimal place (2.5 mm)
  - Other units use the formatters in `Format.*` (milliseconds, velocity, degrees, percent)
  - **Never display a metric without a reliability tier** — `MetricCatalog.Tier.label` shows the accuracy (±0.8″, ±7 ms, Indicative)

- [ ] **Comparison thresholds**
  - `TrendAnalyser.meaningfulChangeThresholds` defines the noise floor
  - `ChangeChip` prints a number only when `comparison.isMeaningful == true`
  - Below threshold, print "no change" rather than a small greyed-out number

- [ ] **Video retention warning**
  - Check `session.retention` every time results load
  - If `.temporary(let expiry)` and `RetentionPolicy.daysRemaining(until: expiry) <= RetentionPolicy.warnWithinDays`, show banner with Keep button
  - If footage is gone, disable the "Confirm events" action (can't confirm something you can't see)

### Session History
- [ ] **Retention pruning**
  - Call `sessionStore.pruneExpiredVideos()` when history screen loads
  - Return value tells you what was dropped; display a notice so the user knows why a clip is no longer on the device
  - Do this once per app launch, not on every history view load

- [ ] **Comparison view**
  - Max 2 sessions selected for comparison (three-way diff is unreadable on mobile)
  - Call `TrendAnalyser().compare(current:previous:)` which throws if the two are not comparable (different profile, frame rate, or pipeline version)
  - Catch the error and display the reason

---

## Phase 3: Integration & Wiring

### RootView
- [ ] **Navigation to history**
  - Add NavigationLink to `SessionHistoryView(store: state.sessionStore, reanalyser: state.reanalyser)`
  - Place it in the results section or as a tab

- [ ] **Recording flow**
  - Button label is "Record a jump"
  - Opens capture screen, which calls `recordingSession.start(writingTo:)` and `recordingSession.stop()`
  - On success, construct `StoredSession` with `SessionAnalysis` from pose extraction, save to store
  - On failure, show error with recovery options (retry, change format, check permissions)

### AppState
- [ ] **Properties to expose**
  ```swift
  @StateObject var sessionStore: SessionStore
  @StateObject var recordingSession: JumpRecording
  var reanalyser: EventReanalysing?
  ```
  - `reanalyser` can be nil during early testing; the correction screen handles it gracefully

---

## Phase 4: Compilation & Testing

### Dependency resolution
- [ ] **SwiftUI imports** — every view is SwiftUI (no UIKit except `VideoSurface` which needs `UIViewRepresentable`)
- [ ] **AVFoundation imports** — everywhere media is touched
- [ ] **Combine** — for `@ObservedObject` in models
- [ ] **simd** — used in `EventDetector` and elsewhere for 3D math

### Test targets
- [ ] **Existing tests still compile**
  - `ProcessingTests.swift` and `IntrinsicsTests.swift` have no dependencies on new files
  - Run these first to verify the numerical core is untouched

- [ ] **No simulator-only code in library**
  - `FixtureJumpRecorder` is in the library (wrapped in the main package) but only used in simulator targets
  - `DeviceJumpRecorder` throws on simulator; that is fine and expected

---

## Critical Gotchas (Read These)

### Video Stabilisation
**The single most damaging default on iOS for this project.**

Stabilisation warps the image geometry per-frame. Every distance measurement depends on a fixed camera-to-world mapping. One frame of warping and that map is broken.

```swift
// In DeviceJumpRecorder.prepare():
guard let connection = captureOutput.connection(with: .video) else { throw ... }
connection.preferredVideoStabilizationMode = .off

// Verify it took. On some devices this is accepted and ignored.
guard connection.activeVideoStabilizationMode == .off else {
    throw CaptureFailure.notImplemented("Stabilisation could not be disabled")
}
```

### Frame Rate is a Target, Not a Contract
iOS treats frame rate as aspirational. In dim light, the sensor lengthens exposure time to maintain brightness and drops frames to afford it. A session that silently ran at 90 fps is not comparable to one at 150, and nothing in the file says so.

**Solution:** `ConsistencyGuard` checks the delivered rate from the file metadata and rejects anything under 120 fps. Do not trust the format you requested — measure what was delivered.

### Focal Length Scales Everything
The lens calibration produces a focal length in pixels. Every 3D reconstruction is scaled by it. A 1% error in focal length = 27 mm error in recovered distance.

**Critical:** The calibration fingerprint encodes device + resolution + frame rate. If you calibrate at 1080p@150fps and later record at 1080p@120fps, they are different formats and `ConsistencyGuard` will reject the 120 fps session. This is correct.

### Session Records are Untyped Dictionaries
`SessionRecord.metricValues: [String: Double]` is deliberately untyped so the pipeline can add a metric without a storage migration. The consequence: a value with no unit and no reliability tier cannot be read correctly.

`MetricCatalog.definition(for:)` returns nil if the metric is unknown. `PresentedMetric.from(record:)` drops any metric the catalogue does not describe. A number with no unit does not appear on screen.

### Comparison Refuses to Compare
`TrendAnalyser.compare()` throws rather than showing a crossed-out number. Two calibration profiles are two different rulers — same metric, different scale.

```swift
// In results screen:
do {
    comparisons = try TrendAnalyser().compare(current: session.record,
                                              previous: other.record)
} catch {
    // Display error as a banner, not a silent failure
    comparisonError = error.localizedDescription
}
```

---

## Device Testing Prerequisites

Before you take this to hardware:

1. **Verify `pose_landmarker_heavy.task` is in the app target**, not the library. MediaPipe models are huge; bundling one that is never used breaks simulator builds.

2. **Test on a real device at exactly the calibration format.** If you calibrated at 1080p@150fps, record at 1080p@150fps. A different format will be rejected.

3. **Measure a known reference.** Jump on a board you have measured with a tape. Compare app distance to tape distance. Expect ±20 mm (about 0.8″). If it is off by centimetres:
   - Check the reference pipe height (1% error = 1.3% scale error)
   - Check the tripod was actually perpendicular (the solver handles yaw/pitch, but only to a point)
   - Check the board corners were tapped precisely (zoom in, use the nudge arrows)
   - Check for motion blur (exposure capped? frame rate sustained?)
   - Check stabilisation is actually off (verify the property, do not trust the setter)

4. **Validate repeatability.** Record the same jump twice, seconds apart, without moving the tripod. Differences should be ±10–30 mm in distances and ±7 ms in timing (if events are confirmed).

---

## File Ownership

| File | What | Status |
|------|------|--------|
| `Units.swift` | Imperial formatting, all unit conversions live here | Ready |
| `MetricCatalog.swift` | Metric definitions, display order, reliability tiers | Ready, needs 2 removed (jump distance, asymmetries not in pipeline) |
| `SessionStore.swift` | Persistence, video retention logic | Ready |
| `EventCorrectionView.swift` | Event review screen, numeric picker, timeline | Ready |
| `ResultsView.swift` | Metric display, comparison, video retention banner | Ready |
| `SessionHistoryView.swift` | Trial list by day, sparklines, comparison sheet | Ready |
| `CameraHardware.swift` | Device seam, implementation checklist | Ready (methods throw `notImplemented`) |
| `DeviceJumpRecorder` | **YOUR WORK** — 8-step implementation in comments | Not started |
| `AnalysisRunner` | **YOUR WORK** — must conform to `EventReanalysing` | Not started |
| `AppState` | **YOUR WORK** — wire up SessionStore, recordingSession, history nav | Not started |

---

## UX Principles (For Future Work)

1. **Numbers on the same row, not behind navigation.** Comparing two trials in a session happens in seconds on the history screen, not by opening both and switching between them.

2. **Thresholds are honest.** A change below the noise floor says "no change" in words. A greyed-out `+0.3″` still reads as movement.

3. **Warnings are specific.** "Frame rate dropped" beats "Session may not be comparable." Name the problem so the user knows what to fix.

4. **Retention is visible.** A countdown to when footage is dropped appears before it disappears, not after. Users discover retention when they still have time to press Keep.

5. **Nothing is silent.** Dropped footage, pruned videos, refused comparisons — all surfaced in text the user can read.

6. **State is encoded visually.** A green checkmark means "confirmed." A question mark means "needs review." Orange means "warning." Do not rely on greying out.

---

## Quick Reference: Metrics in the Pipeline

**Distances (±10–20 mm):**
- Hop distance, Step distance, Hop share %, Step share %
- Board accuracy, Touchdown distance ahead of hips

**Timing (±7 ms):**
- Contact time, Flight time

**Technique (±100 mm absolute, tighter relative):**
- Approach velocity, Velocity loss
- Hip rise in flight
- Knee angle at touchdown, Trunk lean at touchdown

**NOT in pipeline:**
- Jump distance (lands in pit, occluded, unmeasurable)
- Individual hip heights (included in my earlier docs, remove them)
- Left/right asymmetries (not in `meaningfulChangeThresholds`)

---

## When You're Stuck

1. **Build fails?** Check `#if canImport(MediaPipeTasksVision)` guards — the pod is optional until you add it to Podfile
2. **Comparison refuses?** Catch the error and display it; it is information, not a bug
3. **Frame rate rejected?** Run the clip through `MediaInfo` or similar; iOS may have delivered something different than what you requested
4. **Numbers don't match tape?** Tap the corners again. Tap precision dominates calibration error — 10 mm of distance uncertainty per 2 px of tap noise

---

**This checklist is your contract.** Every item is necessary. Every caveat is load-bearing. Mark items off as you complete them, and refer back when integrating.
