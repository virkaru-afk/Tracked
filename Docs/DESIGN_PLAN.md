# Triple Jump Analysis iOS App — Design Plan & Project Status

**Last Updated:** August 4, 2026 (revision 2)
**Status:** Every layer is written and now targets real iPhone hardware modes rather than a frame rate no camera offers. A threading bug, an upsampling bug, and a shared-camera-session bug were found and fixed this pass — see §0. No Xcode is available in this environment, so nothing has been compiled; §0.5 explains exactly what that does and doesn't mean.

---

## 0. This revision: real hardware modes, and three bugs that came with fixing it

The previous revision targeted a flat 150 fps everywhere. **No iPhone camera has ever offered 150 fps.** Slow-motion capture on iOS is quantised to fixed modes, not a continuously requestable rate — the real options are 1080p@240, 720p@240, and 1080p@120. The app now targets exactly those three, ranked in that order, with the ranked list evaluated once per device at configure time so calibration and recording always resolve to the same mode. A settings-level override lets a coach deliberately choose 1080p120 for better low-light sensitivity, trading it for coarser contact timing.

Chasing that change down surfaced three real bugs, none of them cosmetic:

1. **A latent upsampling bug in the analysis grid.** The old canonical rate was a fixed 150 Hz, chosen — per its own doc comment — to sit between 120 and 240 fps. But `ConsistencyGuard` accepts recordings down to 120 fps, and 120 < 150: an accepted 120 fps recording was being upsampled by 25% onto the 150 Hz grid, inventing one sample in five, directly contradicting the "never upsample" rule the same file states. `ProcessingTimebase.analysisRate` is now set per analysis run from that recording's own measured rate, clamped to never exceed what was captured and never fall below 120. A 240 fps recording now gets a 240 Hz grid — real extra precision — instead of being thrown away down to 150.

2. **A consequence of making that rate mutable: a stale-global bug in event correction.** `SessionAnalysis.analysisFrameIndex(forTime:)` converts a video timestamp into the stored analysis-grid index when a user places or moves an event. It read `ProcessingTimebase.analysisRate` directly — but that value is now reconfigured at the start of every analysis run, so a correction screen opened for one session, after some *other* session had been analysed more recently, would compute the index using the wrong session's rate. Fixed by deriving the rate independently from that session's own stored `measuredFrameRate`, through the same pure clamp function `configure()` uses, rather than reading live global state.

3. **A pre-existing bug the mode override made concrete: two disconnected camera sessions.** `TripodCalibrationContainer` correctly shares the app's one `CaptureController`. The lens calibration screen did not — `IntrinsicCalibrationViewModel` built its own, entirely separate instance. With only one possible mode this never showed up; with a settings override now in play, the lens calibration screen would have silently calibrated in the auto-selected mode while ignoring a user's explicit choice, producing a fingerprint mismatch neither screen would report until analysis refused to run. Fixed by injecting the shared controller, matching the pattern the tripod screen already used correctly.

Also fixed, found while re-reading `CaptureController` fresh: the sample-buffer delegate runs on a background queue at up to 240 Hz and was mutating `@Observable` properties and unsynchronised writer state directly — a data race, and off-main SwiftUI invalidation. Recording-session state now lives behind a lock in a plain, non-observable class; the observable surface is written from the main actor only.

### 0.5 It compiles — as of Xcode 26.6, and what that took

**Superseded.** This section previously said nothing had ever been compiled, because the sandbox had Swift command-line tools but no Xcode and no iOS SDK. That is no longer the case. The project now builds against the iOS 26.5 simulator SDK and the full test suite runs: **41 tests, 0 failures.**

The reported symptom was `no such module 'UIKit'`. That was not a code defect: opening a folder containing `Package.swift` makes Xcode treat it as a Swift package and default the run destination to **My Mac**, where UIKit does not exist. `.build/arm64-apple-macosx` was the giveaway. Building for an iOS destination was the entire fix for the reported error.

What the first real compile then found, none of which inspection had caught:

1. **`FixtureJumpRecorder` could not conform to `JumpRecording`.** It is an `actor`, so its `previewSession` was actor-isolated, while the protocol requires it synchronously. Marked `nonisolated` — safe here specifically because it returns a constant `nil` and reads no actor state.
2. **`CaptureRequirements.HardwareMode` was only `Equatable`.** SwiftUI's `Picker` requires `Hashable` of anything used as a `.tag`, and the settings screen tags every supported mode. Now `Hashable`; all stored properties already were, so it synthesises.
3. **Three `foregroundStyle` ternaries mixed `HierarchicalShapeStyle` with `Color`** (`.primary : .red` and friends). Legal-looking, and does not type-check. Found all five instances of the pattern in one sweep rather than one build at a time.
4. **`HardwareCheckView` blew the type-checker's time limit outright** on a chain of `+`-concatenated string literals inside a `Section`/`footer` builder. Hoisted to an explicitly-typed `String` constant.
5. **Both test files imported a module `TJCore` that does not exist** — the target is `TJApp`. The test suite had evidently not been run since the module was renamed.

Two genuine defects surfaced only once tests could actually execute; they are in §0.8.

Both gaps named here in the previous revision — no app target, no MediaPipe — have since been closed. `TripleJump.xcodeproj` exists and the app launches; MediaPipe is vendored and linked without CocoaPods. See §5.1 and §5.2. The single remaining blocker is code signing, which needs an Apple ID (§5.3).

### 0.6 Landscape, and a correction to how I described it last time

Orientation is now locked to landscape (`UIInterfaceOrientationLandscapeRight` specifically — one fixed orientation, not both, to avoid tracking live device rotation against the capture connection). Last revision called portrait-only capture a **blocking** correctness bug. Having now traced it through properly: it isn't one. `CameraModel` and `WorldFrame` work in whatever pixel coordinates the buffer has, regardless of how the phone is physically held — the geometry was never broken. The real cost of portrait is a wasted sensor: a runway is wide, and a phone held upright points the sensor's long axis at the sky and the ground instead of along the runway, giving fewer effective pixels across the athlete than a landscape mount would. It's a real fix, but it belongs in the ergonomics/data-quality category, not "the numbers were wrong" — I overstated the severity before and want that on the record rather than left standing.

The event correction screen's layout depended on this being fixed regardless: its video pane was a fixed 300 pt tall, which on a landscape iPhone screen (roughly 340 pt of usable height total) would have consumed nearly the entire screen. It's now a side-by-side layout — video pane filling the available height on one side, the scrolling event list and controls in a fixed 340 pt column beside it — which is also, not coincidentally, the layout every video review tool converges on for the same reason.

### 0.7 Zoom and pan in event correction

Also fixed this pass, the other item flagged blocking last time: the video pane now supports pinch-to-zoom (up to 6×) and pan, with the skeleton overlay scaling and panning as one unit with the video so it never drifts out of registration. Double-tap zooms to 3.5× centred on whichever foot the selected event concerns, and zooms back out on a second double-tap. Selecting a different event resets the zoom, so a magnified view of one event's foot doesn't linger, misleadingly, over the next.

The lens calibration loupe — still coordinates and a crosshair rather than magnified pixels, since `AVCaptureVideoPreviewLayer` contents aren't addressable from SwiftUI without a second capture path — remains unfixed. That is still open; see §5.

### 0.8 Two defects the tests found once they could run

Both were invisible to inspection. Both needed an executing test suite.

**A never-observed foot was read as a foot resting on the ground.** `EventDetector.buildSignal` writes `NaN` for a frame where a side has no heel, toe, or ankle landmark, and `fillGaps` converts an all-`NaN` signal to **all zeros**. Zero height at zero speed passes every contact gate there is — the height gate (0.06 m), the vertical speed gate, and the horizontal speed gate — so a side that was never seen anywhere in the clip registered as one motionless contact spanning the entire recording. It was emitted with confidence 0.0, but confidence is computed and never used to reject, so it reached `PhaseSegmenter` as a genuine phase boundary.

This is why `testDetectsThreeContacts` returned four: three real left-foot contacts plus one phantom right-foot contact covering the whole clip. It also defeated `testShortSpikeIsNotACOntact` entirely, for the same reason.

Fixed at the source: `ContactSignal` now carries `wasObserved`, and `detectContacts` skips a side with no observations rather than trusting a zero-filled signal. The distinction the code was missing is between *"the foot was on the ground"* and *"we never saw the foot"* — the height signal alone cannot express it.

On real footage MediaPipe emits all 33 landmarks nearly always, so this needed an athlete fully occluded or out of frame on one side for a whole clip to bite. Rare, but silent and severe when it did: a fabricated ground contact across the entire recording.

**A half-pixel convention error, in the test rather than the detector.** `testDetectsFrontalBoard` reported mean corner error of exactly 0.70710671 px against a 0.6 px bar. That number is `sqrt(0.5² + 0.5²)`, which is a constant half-pixel offset in both axes, not noise — noise does not land on an exact algebraic constant. Measuring the signed offset gave `dx = dy = -0.49999998`.

The renderer colours pixel index `x` by evaluating the pattern at exactly `x`, so a square boundary falls midway *between* two pixel centres — half a pixel below the boundary coordinate. `expectedCorners` omitted that. The detector was right; its actual sub-pixel localisation error on this synthetic board is around 1e-8 px. Corrected in the test, with the convention written down so it does not get "fixed" back.

Worth stating plainly: a constant offset like this is the kind of thing that gets absorbed by loosening the threshold. Had the bar been set at 0.8 px instead of 0.6, the test would have passed and the detector's real accuracy — eight orders of magnitude better than the bar — would have been hidden behind an expectation that was simply wrong.

---

## 1. What changed in this build

The previous version of this document listed 17 types that were referenced across the codebase but not defined anywhere. All of them now exist. The full pipeline is connected end to end.

**Written this session:**

| File | Lines | What it provides |
|---|---|---|
| `CameraGeometry.swift` | 381 | `CameraIntrinsics`, `CameraPose`, `CameraModel`, `WorldFrame`, `ReferencePipe` |
| `PoseModel.swift` | 334 | `PoseLandmark` (33), `Keypoint2D/3D`, `PoseFrame`, `ReconstructedFrame`, `JointAngles` |
| `CaptureController.swift` | 529 | `CaptureConfiguration`, full AVFoundation capture stack |
| `IntrinsicsStore.swift` | 438 | `IntrinsicQuality`, `IntrinsicsStore`, `CoverageGrid`, `IntrinsicCalibrationViewModel` |
| `Reconstruction.swift` | 280 | `Reconstructor` — 2D pose → 3D world, with measured athlete plane |
| `MetricsEngine.swift` | 334 | The 13 metrics, from segmentation |
| `AnalysisRunner.swift` | 280 | Full pipeline + `EventReanalysing` conformance + pose archive |
| `PoseEstimator.swift` | ~200 | MediaPipe wrapper, `#if canImport` guarded |
| `AppState.swift` | 249 | App-wide state, all store ownership |
| `CalibrationUISupport.swift` | 258 | `CameraPreview`, `CheckerboardOverlay`, `CoverageGridView`, `SkeletonOverlay`, `AspectFitMapping` |
| `TripodCalibrationView.swift` | 574 | Six-point tapping UI with loupe and nudge |
| `CaptureView.swift` | 285 | Recording screen |
| `SettingsView.swift` | ~290 | Storage, retention, calibration inventory, accuracy explainer |

**Rewritten:** `RootView.swift` — now wires history, settings, capture, and per-session results.

**Total: 29 Swift files, ~12,800 lines.**

---

## 2. Two bugs found and fixed while wiring

These are worth recording because both would have produced plausible wrong numbers rather than obvious failures.

### 2.1 Name collision: `CalibrationView`

`IntrinsicCalibrator.swift` already defined `public struct CalibrationView` as the data type for one captured checkerboard view. `RootView.swift` was calling `CalibrationView(intrinsics:imageSize:session:onComplete:)` as though it were a SwiftUI view. Two different things with one name in one module.

Resolved by naming the SwiftUI screen `TripodCalibrationView`. The data type kept the name — it came first and is referenced throughout the calibrator.

### 2.2 Two frame numberings, silently conflated

This one is subtle and would have corrupted every manually confirmed event.

`EventSnapshot.frameIndex` comes from `GroundEvent.frameIndex`, which `EventDetector` populates from `ReconstructedFrame.frameIndex` — an index into the **canonical 150 Hz analysis grid**. The video player in the correction screen counts **source video frames**, which arrive at whatever rate the camera actually managed (149.7 fps, with drops).

The original correction screen seeked the player to `event.frameIndex` and wrote `frameIndex = draftFrame` back. Both are wrong whenever the delivered rate isn't exactly 150 — which is always.

Fixed by making timestamps the common currency:
- `SessionAnalysis.analysisStartTime` records the grid origin
- The UI seeks and displays **video** frames derived from `event.timestamp`
- Commits write `timestamp` from the video frame, then recompute `frameIndex` on the analysis grid via `analysisFrameIndex(forTime:)`
- The timeline positions phases and markers by time, not by index

`PhaseSegmenter` matches events to frames by `frameIndex`, so getting this wrong would have made confirmed events segment against the wrong frames.

---

## 3. The pipeline, end to end

```
CaptureView
  └─ CaptureController          pinned 150 fps, stabilisation off, optics locked
     └─ CapturedClip            measured rate, not requested rate
        └─ AnalysisRunner.analyse
           ├─ PoseEstimator     MediaPipe → [PoseFrame]  (2D, pixels)
           ├─ ConsistencyGuard  fingerprint + rate + tracking-quality gate
           ├─ Reconstructor     measured athlete plane → [ReconstructedFrame] (3D, metres)
           ├─ EventDetector     → [GroundEvent]
           ├─ PhaseSegmenter    → PhaseSegmentation
           └─ MetricsEngine     → 13 metrics, SI units
              └─ SessionStore   session JSON + pose archive + video
                 └─ EventCorrectionView   human confirms events
                    └─ AnalysisRunner.reanalyse   re-segments FROM confirmed events
                       └─ ResultsView / SessionHistoryView / ComparisonSheet
```

The re-analysis path is the important one. It reads the archived 2D pose, reconstructs, and then **uses the events it was given rather than detecting fresh ones**. Without that, a pipeline upgrade would silently move a contact a human had already confirmed.

---

## 4. Design decisions worth knowing

### 4.1 Athlete plane is measured, not assumed

Single-camera 3D needs a depth assumption. The obvious one — the athlete runs down the runway centreline — costs real accuracy: 15 cm off-centre at 4 m camera distance is a ~4% scale error, or 20 cm on a 5 m hop.

`Reconstructor.measureAthletePlane` recovers it from the footage. Every foot pixel's ray is intersected with the ground plane. When the foot is genuinely down, that intersection *is* the foot; when it's airborne, the ray overshoots and lands further from the camera — always a larger Y. So the true plane sits near the bottom of the distribution, and the 10th percentile finds it.

This avoids a circularity: contact detection needs 3D, 3D needs the plane, so anything requiring contacts first would deadlock.

### 4.2 Three storage tiers, three lifetimes

| What | Size | Lifetime |
|---|---|---|
| Session record + analysis | ~5 KB | Permanent |
| 2D pose archive | ~400 KB | Permanent |
| Video | ~300 MB | 3 days, unless pinned |

The pose archive is the piece that makes the retention policy work. Re-analysis after the footage is dropped reads it, so confirming events on day 2 and re-analysing on day 10 both work.

### 4.3 There is no jump distance

The jump phase lands in the pit: the foot is occluded by the athlete's own body and the sand, and the landing is a slide rather than a plant, so there is no stationary core to take a median over. `MetricsEngine` measures hop and step, and the share metrics are named `...of measured phases` for exactly this reason.

Earlier versions of `METRICS_REFERENCE.md` listed a jump distance. That was wrong and has been corrected.

### 4.4 Imperial at the view layer only

Everything is stored, compared, and thresholded in SI. `TrendAnalyser.meaningfulChangeThresholds` is in metres; converting storage would let rounding drift past the noise floor. `Imperial.feetInches` runs at display time and nowhere else. Inches carry one decimal (2.5 mm) — just under the measured 2.5–2.9 mm run-to-run SD, so two decimals would imply resolution that isn't there.

---

## 5. What is genuinely still missing

### 5.1 MediaPipe — resolved, and not with CocoaPods

**Done.** `Frameworks/` holds `MediaPipeTasksVision.xcframework` and `MediaPipeTasksCommon.xcframework` 0.10.14, with device and simulator slices, plus the two `graph_libraries/*.a`. `Resources/pose_landmarker_heavy.task` is bundled into the app target. The `Podfile` has been deleted.

CocoaPods was never actually needed. The podspec turned out to be a plain HTTP tarball wrapping a vendored xcframework, so it is linked directly — no Ruby, no `pod install`, no `.xcworkspace`. That matters practically here: the machine has system Ruby 2.6, which current CocoaPods does not support, so the pod route would have meant installing a newer Ruby via Homebrew with `sudo` before anything could be built at all.

What CocoaPods would have injected is now explicit on the app target: `FRAMEWORK_SEARCH_PATHS`, `-lc++`, the seven system frameworks MediaPipe needs, and — the part that is easy to miss — a per-SDK `-force_load` of the matching graph archive. Without that `-force_load` the project builds cleanly and then crashes the first time a MediaPipe graph is constructed, because the graph nodes are registered by static initialisers the linker otherwise strips.

Verified, rather than assumed: the built binary contains `_$s5TJApp13PoseEstimatorV9modelPath…SSvg`, the getter for a stored property that exists **only** inside the `#if canImport(MediaPipeTasksVision)` branch. The stub has no stored properties, so its presence proves the real implementation compiled. The app's own hardware check confirms the same thing at runtime: *"MediaPipeTasksVision is linked"*, *"pose_landmarker_heavy.task found"*.

### 5.2 Xcode project — built

`TripleJump.xcodeproj` exists, with a `TripleJump` app target and a `TripleJumpTests` unit-test target. It builds for the simulator, builds for arm64 device hardware, launches, and runs all 41 tests.

`project.pbxproj` is **generated** by `Tools/generate_xcodeproj.py` and is deterministic — same inputs, byte-identical output. Anything configured through Xcode's UI is lost on the next regeneration, so settings that must persist belong in `APP_COMMON` in that script.

Three decisions in it are load-bearing:

- **Sources compile into the app target, not as a package dependency.** Required, not stylistic — see §5.1. A SwiftPM target cannot see vendored app-target frameworks, so `canImport(MediaPipeTasksVision)` would be false inside a package and pose extraction would silently be the stub.
- **`PRODUCT_MODULE_NAME = TJApp`,** while the product stays `TripleJump.app`. This lets `@testable import TJApp` resolve identically whether the tests are run through the Xcode project or through `Package.swift`, so one test suite serves both.
- **`Package.swift`'s package is named `TripleJumpCore`.** Two schemes named `TripleJump` — one from the package, one from the project — are ambiguous, and `xcodebuild -scheme TripleJump` fails with "not currently configured for the build action" rather than choosing.

No shared `.xcscheme` is committed. A hand-written one was rejected by Xcode in exactly that way; autocreation produces a working scheme and folds the test target into the app scheme's test action.

Both concerns flagged here previously are now settled by the compiler rather than by argument: `CaptureController` being simultaneously `@Observable` and an `NSObject` subclass builds without complaint, and `SessionAnalysis.analysisStartTime` being non-optional is a non-issue since no data has shipped.

### 5.3 Code signing — the remaining manual step

`security find-identity -v -p codesigning` reports **0 valid identities**, so `DEVELOPMENT_TEAM` is empty and the app builds for device but cannot be installed on one. This needs an Apple ID, which is not something that can be set up on someone's behalf. Steps are in `SETUP.md` §3.

This is now the only thing standing between the code and a real measurement.

### 5.4 No device testing

Nothing here has run on hardware. Every accuracy figure in `SETUP.md` comes from synthetic trials. They establish the algorithms are internally consistent; they do not establish real-world accuracy.

### 5.5 The lens calibration loupe is still not a real magnifier

Tripod calibration asks for 2 px tap precision on a live preview, where a fingertip covers roughly 40 px, and offers nudge arrows plus a coordinate readout rather than magnified pixels — because `AVCaptureVideoPreviewLayer` contents aren't directly addressable from SwiftUI. The fix is to capture one still frame via `CaptureController.captureFrame`, render it as a plain `Image`, and tap on that instead of the live preview; the magnifier then becomes a trivial scaled crop. Event correction got its zoom fix this pass (§0.7); this one, the other screen with the same underlying limitation, did not.

---

## 6. Critical setup the user must get right

These are in `IMPLEMENTATION_CHECKLIST.md` in full. The ones that silently corrupt data rather than failing loudly:

1. **Video stabilisation must be off.** It warps image geometry per-frame, breaking the fixed camera-to-world mapping. `CaptureController.disableStabilisation` sets it and then *verifies* it, because some devices accept the setter and ignore it.

2. **Calibrate in the mode you record in.** High-frame-rate modes crop the sensor. A 1080p120 calibration applied to 1080p240 footage is a multi-percent scale error with nothing on screen to say so. The fingerprint mechanism catches this — don't route around it. The app now targets three real modes (1080p240, 720p240, 1080p120, in that preference order) rather than a flat rate no iPhone camera has ever offered; see §0.

3. **Enter the real pipe height.** A 1.48 m pipe entered as 1.50 puts 1.3% into every distance.

4. **Tape the tripod feet.** Profile reuse measured 4× better session-to-session repeatability than re-solving, and that only works if the rig is rebuilt identically.

5. **Confirm the events.** Takes timing from ~±15 ms to ±7 ms. Largest single improvement available.

---

## 7. Build order from here

Steps 1–3 are **done**. Everything from step 4 needs a physical phone and cannot be done from a desk.

1. ~~MediaPipe + model + first compile.~~ Done — §0.5, §5.1.
2. ~~Xcode app target.~~ Done — §5.2. Builds for simulator and arm64 device, 41 tests passing.
3. ~~Launch and exercise the UI without a camera.~~ Done — the app runs on the simulator, and the in-app hardware check confirms MediaPipe linked, model bundled, no rear camera.
4. **Sign it.** Apple ID → `DEVELOPMENT_TEAM` → install on a real iPhone (`SETUP.md` §3). The only blocker left.
5. **Run `HardwareCheckView` on that phone first.** It enumerates which of the three modes the camera actually offers, which one will be selected, and — the number that matters — the frame rate the sensor *delivers* under load rather than the one requested. Do this before recording anything, because everything downstream is scaled by it.
6. Lens calibration → tripod calibration → record → confirm → results.
7. Validate against a tape measure. Expect ±0.8″ on distances.
8. Validate repeatability: same jump twice, tripod untouched. Expect ±10–30 mm, ±7 ms — tighter on a device that supports 1080p240, since the analysis grid now uses the full delivered rate instead of the old fictional 150 Hz.

Steps 7 and 8 are the first moments this project produces a number that means anything. Until then every figure in this document is synthetic, and `DeviceIntegrationStatus.hasRunOnHardware` should stay `false`.

---

## 8. Scalability notes

- **`athleteName` is a free-text string** with no backing identity. Fine for one coach and a handful of athletes; painful the first time someone renames a typo across a season. A proper `Athlete` record is the natural next refactor.
- **`AnalysisPipeline.version`** already exists and is checked by `TrendAnalyser`. Bump it whenever a threshold or filter window changes, and old sessions will correctly refuse to compare rather than silently misleading.
- **`MetricCatalog`** separates what a metric *is* from how it's shown, so CSV/PDF export is additive.
- **Multi-camera** would require `CameraModel`/`WorldFrame` to become multi-view aware. Nothing else assumes one camera.

---

**Document version: 5.0**
**Supersedes: 4.0 (2026-08-06), 3.0 (2026-08-04), 2.0 (2026-08-04), 1.0 (2026-08-03)**

Version 5.0 covers the first build that produced a running application: the Xcode app target, MediaPipe vendored without CocoaPods, and the two defects the test suite found once it could execute. Nothing in this revision has run on a camera.
