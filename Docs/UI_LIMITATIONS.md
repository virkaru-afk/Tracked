# UI Limitations & Key Features Needed

**As of August 4, 2026.** An honest audit of what the interface cannot currently do, and what has to be built before this is a tool someone would actually use at a track.

The code is complete in the sense that every layer exists and connects. It is not complete in the sense that a coach could take it to a session and get through the day without hitting a wall. This document is about the walls.

---

## Part 1 — UI limitations

Grouped by how badly they hurt. "Blocking" means a real user gives up.

### 1.1 Blocking

#### Portrait-only capture of a horizontal scene

`Info.plist` locks the app to portrait. A runway is a wide, horizontal scene and an athlete travels across it for 10+ metres. In portrait the athlete occupies a narrow vertical strip of a tall frame — the worst possible use of sensor pixels for this subject.

The lock exists for a real reason: the calibration solve assumes a fixed relationship between image axes and the world frame, and a mid-session rotation would silently invalidate every stored profile. But the fix is not "allow rotation" — it is **lock to landscape instead**, and store the orientation in the capture fingerprint so a profile solved in one orientation cannot be used in the other.

This is the single largest UI problem in the project.

#### No zoom or pan in event correction

The whole point of that screen is judging whether a foot is on the ground in a specific frame. At 1080p displayed in a 300 pt tall pane, the foot is roughly 20 pixels. The skeleton overlay helps, but the user cannot magnify to check the overlay is right — which is exactly the judgement being asked for.

Pinch-to-zoom with pan, locked to the selected foot, is not optional for this screen to do its job.

#### Tripod calibration has no real magnifier

`LoupeView` shows the *coordinates* of the pending tap and a crosshair. It does not show magnified pixels, because `AVCaptureVideoPreviewLayer` contents are not addressable from SwiftUI without a second capture path.

The screen asks for 2 px tap precision on a preview where a fingertip covers ~40 px, and gives the user nudge arrows and a number instead of a magnified image. The nudge arrows work, but the user cannot see what they are nudging *towards*.

Needs: capture a still frame, display it as an image, magnify a region around the touch. This also fixes the fact that tapping happens on a live preview that may drift.

#### No export of any kind

Nothing leaves the device. No CSV, no PDF, no share sheet on a session, no backup. A coach who records a season cannot get the data into a spreadsheet, cannot send an athlete their numbers, and loses everything if the phone is lost.

`MetricCatalog` was built to make this easy (`Imperial.Style.ascii` exists specifically for CSV), but no export path was written.

### 1.2 Severe

#### Athlete identity is a free-text string

`SessionRecord.athleteName` is typed into a text field on the capture screen. Consequences:

- "Sam Okafor" and "Sam okafor" are two different athletes to `SessionHistoryModel.athletes` and to every comparison
- A typo fragments history permanently; there is no rename
- No way to see one athlete's season without the filter picker guessing from strings
- A squad of eight means retyping a name for every trial

Needs a real `Athlete` record with a stable id, a picker, and a rename that rewrites existing sessions.

#### Analysis holds the screen hostage

`CaptureView` deliberately blocks navigation during analysis, because tearing down the view mid-extraction leaves a half-written session. But pose extraction over a 150 fps clip is tens of seconds. Between trials in a warm-up that is dead time the coach cannot use, and there is no way to record trial 2 while trial 1 analyses.

Needs a background analysis queue with resumable state, and a UI that shows a queue rather than a modal spinner.

#### Profile verification exists but has no UI

`ProfileVerification.verify()` is implemented and validated. `ConsistencyGuard` emits a note when a profile has not been verified in 30 days. Nothing in the interface lets a user act on that note — there is no "re-tap the reference points to confirm nothing moved" flow.

The note therefore reads as a nag the user cannot resolve.

#### Single-level revert, no undo stack

`revertSelected()` restores an event to its detected position. There is no undo for a delete, no undo for an added event, no undo across a batch confirm. A mis-tapped "Confirm all remaining" is unrecoverable without re-analysing.

### 1.3 Moderate

| Limitation | Effect |
|---|---|
| Comparison capped at 2 sessions | Cannot see a trend across a session's six trials at once |
| Trend chart shows hop distance only | The other 12 metrics have no visualisation |
| Sparkline has no axes or dates | Shape is readable; magnitude and timing are not |
| No session notes editing | `SessionRecord.notes` exists, nothing writes to it after creation |
| No unit preference | Feet/inches is hardcoded at the view layer; a non-US coach cannot switch to metric |
| No scrub gesture on the video itself | Only the timeline strip scrubs; the natural gesture does nothing |
| Frame picker window is ±40 frames | An event misplaced by more than 267 ms must be deleted and re-added |
| No batch event confirmation across trials | Six trials means six passes through the correction screen |
| Results view has no video | Cannot see the jump you are reading numbers about without going back to correction |

### 1.4 Not yet started

- **No onboarding.** First launch drops the user on a checklist with no explanation of why any of it matters. The physical setup — tripod placement, reference pipe, floor tape — is documented only in `SETUP.md`, which is not in the app.
- **No iPad layout.** Everything is phone-width. On iPad the lists stretch and the capture screen is unusable.
- **No accessibility work.** No VoiceOver labels on custom controls (timeline, frame picker, coverage grid), no Dynamic Type testing, no reduced-motion handling.
- **No localisation.** English strings inline throughout.
- **No empty-state guidance** beyond one `ContentUnavailableView`.
- **No error recovery paths.** Errors are alerts with an OK button; none offer the action that would fix the problem.

---

## Part 2 — Key features needed to make this usable

Ordered by what unblocks the most. Each is scoped against what already exists.

### Tier 1 — cannot ship without

**1. Landscape capture**
Change the orientation lock, add orientation to `CaptureConfiguration.fingerprint`, verify `AspectFitMapping` and `CameraPreview` handle the new aspect. Everything downstream is orientation-agnostic because it works in pixels.
*Touches: `Info.plist`, `CaptureConfiguration`, `CaptureView`, `CalibrationUISupport`.*

**2. Zoom and pan in event correction**
`MagnificationGesture` + `DragGesture` over the video pane, with the transform applied to both the video layer and `SkeletonOverlay` so they stay registered.
*Touches: `EventCorrectionView`, `CalibrationUISupport`.*

**3. Still-frame tapping with a real magnifier in tripod calibration**
Grab one frame via `CaptureController.captureFrame`, render it as an `Image`, tap on that. The magnifier becomes a scaled crop, which is trivial once the pixels are in an image rather than a preview layer.
*Touches: `TripodCalibrationView`. `CaptureController` already exposes what is needed.*

**4. Athlete roster**
`Athlete: Identifiable, Codable` with a store, a picker on the capture screen, and a rename that rewrites `SessionRecord.athleteName` across stored sessions.
*New file. Touches: `CaptureView`, `SessionHistoryView`, `AppState`.*

**5. Export**
CSV of all metrics for a session or a date range; a share sheet. `Imperial.Style.ascii` and `MetricCatalog.all` already exist for exactly this.
*New file. `ShareSheet` already exists in `CheckerboardSetupView.swift`.*

### Tier 2 — needed for a real session

**6. Background analysis queue**
Record → enqueue → record again. A queue view showing pending, running, failed. Requires moving analysis out of `CaptureView` into a service owned by `AppState`.
*Touches: `AppState`, `CaptureView`, `AnalysisRunner`.*

**7. Profile verification flow**
Re-tap the six points, run `ProfileVerification.verify()`, show drift and the recommendation. The logic is done; this is a view over it.
*New view. Reuses `TripodCalibrationView`'s tapping.*

**8. Onboarding**
The physical setup guide from `SETUP.md`, in the app, with diagrams: tripod perpendicular and level with the board, 2–8 m out, pipe placement, floor tape. Shown on first launch and reachable from settings.

**9. Undo stack in event correction**
An operation log with `undo()`. The model already mutates through discrete methods, so this is mechanical.

**10. Unit preference**
A toggle in settings, read by `MetricCatalog.format`. The SI-storage design means this is a display-layer change only.

### Tier 3 — quality of life

11. Multi-session comparison (3+ trials side by side)
12. Trend charts for all 13 metrics, with dates and axes
13. Video playback in the results view
14. Session notes editing
15. Pinch-to-scrub on the video itself
16. iPad layout
17. VoiceOver labels on custom controls
18. Cloud backup / multi-device sync

---

## Part 3 — What is genuinely solid

Worth stating so the list above is read in proportion:

- The **data model and storage** need no rework. Three tiers with independent lifetimes, pose archived separately so re-analysis survives video deletion, atomic writes, backup exclusion on video.
- The **measurement honesty** is built in structurally, not bolted on. Metrics without a validated noise floor cannot reach the screen. Changes below threshold say "no change" in words. Incomparable sessions refuse to compare and say why.
- The **unit architecture** is right. SI everywhere, imperial at the view layer only, so adding a metric or a unit preference is additive.
- The **capture layer** does the things that are easy to get wrong: pins frame duration at both ends, verifies stabilisation actually turned off, measures delivered rate rather than trusting the request, gates on thermal and storage.
- **`HardwareCheckView`** exists specifically so device bring-up produces a diagnosis rather than a mystery.

---

## Part 4 — Suggested build order

1. **Compile it.** Add the pod, bundle the model, fix the first-build errors. Nothing below is real until this happens.
2. **Run `HardwareCheckView` on the target device.** It will tell you what the phone can actually sustain.
3. **Landscape** (Tier 1.1) — changes the fingerprint, so do it before any real calibration data exists.
4. **Still-frame tapping** (1.3) and **zoom in correction** (1.2) — these two make the calibration and confirmation steps actually performable.
5. **First real calibration and recording on device.** Validate against a tape measure.
6. **Athlete roster** (1.4) and **export** (1.5) — needed the first time someone else uses it.
7. **Background queue** (2.6) — needed the first time someone records six trials.

Steps 1–5 are what "usable on an iOS device" means. Steps 6–7 are what "usable by a coach at a session" means.
