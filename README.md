"""
TripleJump

An iOS app that measures triple jump performance from a single phone on a tripod. Record a jump, and it returns phase distances, contact times, and the balance between hop, step and jump.

What it measures — hop/step/jump distances and board placement; ground contact and flight times per phase; phase shares, so a hop-dominant jump is visible at a glance. Distances land within roughly ±0.8 inch and timing ±7 ms once calibrated. Some metrics are indicative only and labelled as such in the app.

How it works — calibrate the lens once against a printed checkerboard (Zhang's method, with focus pinned so recordings match the calibration), calibrate the tripod against a reference object of known height, then record and analyse: MediaPipe pose landmarks, smoothed, turned into takeoff and landing events.

Requirements — Xcode, an iPhone with high frame rate capture, a tripod, a printed calibration target (the app generates it, including multi-sheet versions), and a tape measure.

Getting started — open TripleJump.xcodeproj, not the folder, and see SETUP.md. Two steps are easy to get wrong and quietly corrupt every result: pinning focus at working distance, and mounting the board flat.

Status — builds for simulator and arm64 device hardware, 51 tests passing.

Accuracy — consistent setup gives consistent results, but consistent is not the same as correct. Before trusting the output, measure a few jumps with a tape and compare.
"""
