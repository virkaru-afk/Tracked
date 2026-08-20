# Setup

## 1. Xcode project

The Swift package builds as-is except for the MediaPipe dependency. MediaPipe
Tasks Vision ships as a CocoaPod, not a SwiftPM package, so it needs to be
added to an Xcode app project that consumes `TJCore`.

`Podfile`:

```ruby
platform :ios, '17.0'
target 'TripleJump' do
  use_frameworks!
  pod 'MediaPipeTasksVision', '~> 0.10.14'
end
```

Then `pod install` and open the `.xcworkspace`.

`PoseEstimator.swift` is wrapped in `#if canImport(MediaPipeTasksVision)`, so
everything else compiles and the whole test suite runs before the pod is
integrated. This is deliberate: the numerical core is the part worth testing,
and it should not be blocked on a dependency.

### Model file

Download `pose_landmarker_heavy.task` from the MediaPipe model garden and add
it to the app target with **Target Membership** ticked.

Heavy rather than Lite or Full: analysis runs offline after capture, so
inference speed barely matters, while landmark accuracy during fast motion
directly limits every downstream measurement.

### Info.plist

```xml
<key>NSCameraUsageDescription</key>
<string>Records jumps for technique analysis.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Saves recorded jumps to your photo library.</string>
```

---

## 2. Lens calibration — do this once per phone

**This step is not optional.** Every measurement is scaled by the lens
focal length. A 1% error there produces a 27 mm error in the recovered camera
distance and a proportional error in every distance the app reports.

It only has to be done once per phone, but it must be done **in the exact
capture mode the app will record in**. High-frame-rate modes usually crop the
sensor, so a 30 fps calibration applied to 150 fps footage is a silent scale
error. `CaptureConfiguration.fingerprint` encodes device, resolution and frame
rate, and `ConsistencyGuard` refuses to analyse a session whose fingerprint
does not match its calibration profile.

Procedure:

1. Print a 9×6 checkerboard with 30 mm squares. Mount it on something rigid —
   a clipboard or foam board. A curled sheet of paper will quietly corrupt the
   result.
2. Record 40–50 seconds at 150 fps, moving the board so it appears at all
   corners of the frame and at several angles and distances. Corner coverage
   matters most: distortion is largest at the frame edges, which is exactly
   where the athlete is during approach and landing.
3. Run OpenCV `calibrateCamera` on the extracted frames.
4. Accept only if RMS reprojection error is below 0.5 px. Above that, re-shoot
   with better lighting and more angle variety.

The checkerboard module is not yet written — see Status below.

---

## 3. Physical setup

### Tripod

- Place it perpendicular to the runway, level with the middle of the board.
- Any distance from about 2 m to 8 m works. Closer is better conditioned:
  the near and far board edges separate by 494 px at 2 m but only 28 px at
  8 m, and beyond roughly 8 m the reference pipe carries the solve almost
  alone. Beyond 12 m the app refuses to calibrate.
- Measure the height from the ground to the lens with a tape and enter it.
  ±20 mm is fine — it is used as a soft prior, not as fact.
- Perfect squaring is **not** required. The solver estimates yaw and pitch,
  which removes the roughly 94 mm per degree bias that assuming a square
  tripod would introduce. Getting within a few degrees by eye is enough.

**Mark the tripod feet on the ground with tape.** This is the single most
valuable thing you can do for data quality. Rebuilding the same setup lets you
reuse the stored calibration profile, and profile reuse measured 4× better
session-to-session repeatability than re-solving each time.

### Reference pipe

- A 1.5 m length of rigid PVC with a brightly coloured ball or marker on top.
- Plant it where it does not obstruct the athlete or the landing area. The
  default assumed position is 0.60 m upstream of the scratch line and 0.30 m
  outside the near board edge; change `ReferencePipe.basePosition` if you put
  it elsewhere.
- Measure ground-to-marker-centre and enter the real number. If your pipe is
  1.48 m, enter 1.48. Entering 1.50 puts a 1.3% scale error into everything.
- Check it is vertical. A leaning pipe biases the height solve.
- Tape its base position to the ground too.

### Lighting

Frame rate is the first thing iOS sacrifices in poor light, and a session that
silently drops to 90 fps is not comparable to one at 150. The app pins the
frame duration and caps exposure to prevent this, and measures the delivered
rate from the file afterward rather than trusting the request. Outdoor daylight
or bright floodlights are strongly preferred.

---

## 4. Calibration in the app

Tap, in order:

1. Near scratch corner — closest to camera, pit-side edge
2. Far scratch corner
3. Far back corner
4. Near back corner
5. Where the pipe meets the ground
6. Centre of the marker on top

Order matters and must match every time; the world-frame corner list assumes
it.

Zoom in and use the nudge arrows. Tap precision dominates calibration error at
roughly 10 mm of distance uncertainty per 2 px of tap noise, so this is the
one place where taking an extra thirty seconds measurably improves the data.

Acceptance: fit error below 1.5 px is excellent, below 4.0 px is fine, and
above that the app will name the specific point that looks mistapped.

Then **write the setup notes**. Where the tripod legs are, where the pipe is,
which runway. Future sessions depend on rebuilding this.

---

## 5. Recording

- Start recording before the athlete begins the approach run.
- Keep the athlete in frame from at least the last few strides through the
  landing.
- Do not let anyone walk between the camera and the runway.
- Do not touch the tripod between trials.

---

## 6. Reading the results

Metrics are grouped by how much they can be trusted, and the grouping is
honest rather than flattering:

| Group | Accuracy | What it covers |
|---|---|---|
| Distances and foot placement | ±10–20 mm | Phase distances, board accuracy, touchdown distance ahead of hips |
| Timing | ±7 ms | Contact times, flight times |
| Heights, angles, velocities | ±100 mm absolute | Hip rise, joint angles, velocity loss |

The third group is less precise in absolute terms but considerably tighter
session to session, because most of its error is a fixed offset that cancels
when comparing two sessions on the same profile.

**Confirm the detected contacts when prompted.** It takes about a minute and
is the largest single improvement available to the repeatability of your own
data — a confirmed event is identical every time, where an automatic one can
land a frame or two differently between sessions.

The comparison view hides changes smaller than the measurement noise rather
than showing them as progress. If a number does not appear, it did not move
enough to be distinguishable from noise.

---

## Validated performance

Measured on synthetic trials with the calibration profile reused, 2 px tap
noise and 1.8 px pose noise:

| Quantity | Repeatability (SD) | Bias |
|---|---|---|
| Hop distance | 2.5 mm | −0.2 mm |
| Step distance | 2.9 mm | +0.2 mm |
| Contact time | 5.0 ms | −1.8 ms |

Calibration recovers distance exactly in the noiseless case across 2–8 m, and
recovers yaw correctly at 0.5°–5° of tripod misalignment.

These are synthetic numbers. They establish that the algorithms are sound and
internally consistent; they do not establish real-world accuracy, which needs
device testing against a known reference.

---

## Status

Complete and validated:

- World geometry, camera model, calibration solver
- Profile persistence, reuse and drift verification
- Capture controller with pinned frame rate
- Signal processing on a fixed 150 Hz timebase
- 3D reconstruction with measured athlete lateral plane
- Event detection, phase segmentation, metrics
- Consistency guard and trend comparison
- Calibration and results UI
- Test suites including regression tests for both bugs found in validation

Written, but not yet compiled or run:

- **Event correction UI** (`EventCorrectionView.swift`). Scrub-and-confirm
  over the recorded clip, with placement by numeric frame picker rather than
  by dragging. The picker states the offset from the detected frame in both
  frames and milliseconds, because one frame at 150 fps is 6.7 ms against a
  15 ms meaningful-change threshold on contact time.
- **Session storage with video retention** (`SessionStore.swift`). Analysis is
  kept permanently; footage is kept three days and then dropped unless the
  user pins it. A 150 fps clip runs to several hundred megabytes and the
  analysis it produces is a few kilobytes, so only one of the two can be kept
  indefinitely.
- **Results UI** (`ResultsView.swift`) and **history and comparison**
  (`SessionHistoryView.swift`). Distances display as feet and inches;
  everything is stored, compared and thresholded in SI.
- **Imperial formatting and the metric catalogue** (`Units.swift`,
  `MetricCatalog.swift`).

Not yet built:

1. **Checkerboard intrinsic calibration module.** Design is settled, code is
   not written. Until it exists, intrinsics must be produced externally with
   OpenCV and entered manually.
2. **Skeleton overlay player.** The correction screen plays the clip and steps
   it frame-accurately, but draws no landmarks over it.
3. **Camera and device layer.** `CameraHardware.swift` defines the seam and
   lists every outstanding piece; `DeviceJumpRecorder` throws `notImplemented`
   on every call. `FixtureJumpRecorder` plays a bundled clip so the
   record → analyse → confirm → results flow can be exercised in the simulator.
4. **`AnalysisRunner` conformance to `EventReanalysing`.** The correction
   screen calls re-analysis through that protocol; nothing implements it yet,
   so the button reports that re-analysis is unavailable.
5. **Wiring into `RootView`.** `AppState` is not in this directory, so the
   history and results entry points are not attached to the home screen.
6. **Device testing.** Nothing here has been compiled or run on hardware. All
   validation was done by porting the algorithms to Python and testing them
   numerically.

## Known limitation

Out-of-plane motion — lateral arm swing, trunk drift — cannot be resolved by a
single camera. This affects joint angles by roughly 10% and is not fixable
within this setup. It is surfaced through the `moderate` and `indicative`
reliability tiers rather than hidden.
