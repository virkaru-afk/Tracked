# Triple Jump Metrics — Complete Reference

Based on event detection and phase segmentation, here are all measurable metrics organized by category, accuracy tier, and display priority.

---

## 1. PRIMARY METRICS (Highest Accuracy ±10–20 mm)

These are the core performance indicators. Display these first, prominently.

### 1.1 Phase Distances (Horizontal)

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Hop Distance** | Horizontal travel during hop flight phase | Distance from takeoff to hop landing foot plant (core position) | ±10–20 mm |
| **Step Distance** | Horizontal travel during step flight phase | Distance from hop landing to step landing foot plant | ±10–20 mm |
| **Jump Distance** | Horizontal travel during jump flight phase | Distance from step landing to final landing foot plant | ±10–20 mm |
| **Total Distance** | Sum of all three phases | Hop + Step + Jump | ±15–20 mm (cumulative) |

### 1.2 Board Accuracy

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Board Hit Accuracy** | How close takeoff is to the board scratch line | Horizontal distance of takeoff foot from scratch line (negative = foul, positive = past board) | ±5–10 mm |
| **Foul Flag** | Whether takeoff was over the line (foot past scratch) | If board contact X position > scratch line X, then foul | Binary |

### 1.3 Approach & Takeoff Placement

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Approach Distance** | How far athlete ran before takeoff | Distance from start of clip to takeoff position | ±20 mm |
| **Approach Velocity** | Speed heading into jump | Horizontal velocity at takeoff | ±0.1 m/s |

---

## 2. TIMING METRICS (±7 ms)

Critical for technique analysis and training load.

### 2.1 Contact Times

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Hop Contact Time** | How long foot is on ground during hop | Toe-off timestamp - touchdown timestamp (hop) | ±7 ms |
| **Step Contact Time** | How long foot is on ground during step | Toe-off timestamp - touchdown timestamp (step) | ±7 ms |
| **Jump Contact Time** | How long foot is on ground during jump | Toe-off timestamp - touchdown timestamp (jump) | ±7 ms |
| **Mean Contact Time** | Average of three phases | (Hop + Step + Jump) / 3 | ±7 ms |

### 2.2 Flight Times

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Hop Flight Time** | Time in air after hop takeoff | Hop landing - Hop takeoff | ±7 ms |
| **Step Flight Time** | Time in air after step takeoff | Step landing - Step takeoff | ±7 ms |
| **Jump Flight Time** | Time in air after jump takeoff | Landing - Jump takeoff | ±7 ms |
| **Mean Flight Time** | Average of three flight phases | (Hop + Step + Jump flight) / 3 | ±7 ms |

### 2.3 Total & Approach Times

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Approach Time** | Time running toward board (start to takeoff) | Takeoff timestamp - video start | ±20 ms |
| **Total Jump Time** | Entire performance from start to final landing | Final landing - video start | ±20 ms |

---

## 3. HEIGHT & ANGLE METRICS (±100 mm absolute, but ±10–30 mm relative session-to-session)

Less accurate in absolute terms, but good for trends. Mark these as "Indicative" or "Relative" in reliability tier.

### 3.1 Hip Height (Vertical Rise)

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Hip Height at Takeoff** | Vertical position of hip joint at moment of takeoff | Y-coordinate of hip landmark at takeoff | ±100 mm |
| **Hip Height at Hop Landing** | Hip height when foot contacts during hop | Y-coordinate of hip at hop landing | ±100 mm |
| **Hip Height at Step Landing** | Hip height when foot contacts during step | Y-coordinate of hip at step landing | ±100 mm |
| **Hip Height at Final Landing** | Hip height at final contact | Y-coordinate of hip at landing | ±100 mm |
| **Max Hip Height (Overall)** | Highest point hips reach during entire jump | Maximum Y-coordinate across all frames | ±100 mm |

### 3.2 Hip Rise During Phases

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Hip Rise During Hop Flight** | Vertical displacement during hop flight | Hip height at apex - Hip height at hop landing | ±50 mm relative |
| **Hip Rise During Step Flight** | Vertical displacement during step flight | Hip height at apex - Hip height at step landing | ±50 mm relative |
| **Hip Rise During Jump Flight** | Vertical displacement during jump flight | Hip height at apex - Hip height at step landing | ±50 mm relative |
| **Max Hip Rise** | Tallest flight apex relative to most recent contact | Maximum rise across all three phases | ±50 mm relative |

### 3.3 Joint Angles (at Takeoff & Landing)

**⚠️ Reliability:** Moderate. Out-of-plane motion (lateral arm swing, trunk drift) cannot be resolved with single camera. Affects angles ~10%.

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Knee Angle at Takeoff** | Angle between hip, knee, ankle (takeoff leg) | Joint angle from 3D landmarks | ±10–15° |
| **Hip Angle at Takeoff** | Angle between shoulder, hip, knee (takeoff leg) | Joint angle from 3D landmarks | ±10–15° |
| **Ankle Angle at Takeoff** | Angle at ankle joint | Joint angle from 3D landmarks | ±10–15° |
| **Knee Angle at Landing** | Angle at landing | Joint angle from 3D landmarks | ±10–15° |
| **Hip Angle at Landing** | Angle at landing | Joint angle from 3D landmarks | ±10–15° |
| **Torso Angle at Takeoff** | Angle of trunk relative to vertical | Calculated from shoulder and hip landmarks | ±10° |

### 3.4 Velocities

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Horizontal Velocity at Takeoff** | Speed in forward direction at takeoff | Derivative of X position around takeoff | ±0.1 m/s |
| **Vertical Velocity at Takeoff** | Upward speed at takeoff | Derivative of Y position around takeoff | ±0.1 m/s |
| **Total Takeoff Velocity** | Combined magnitude | √(Vx² + Vy²) | ±0.15 m/s |
| **Horizontal Velocity at Hop Landing** | Forward speed when foot contacts during hop | Derivative of X position | ±0.1 m/s |
| **Horizontal Velocity at Step Landing** | Forward speed during step contact | Derivative of X position | ±0.1 m/s |
| **Velocity Loss (Hop → Step)** | Reduction in forward speed | Takeoff velocity - Step landing velocity | ±0.15 m/s |
| **Velocity Loss (Step → Jump)** | Reduction from step to jump | Step landing velocity - Jump takeoff velocity | ±0.15 m/s |

---

## 4. SECONDARY/CONTEXTUAL METRICS

Lower priority for initial display, but useful for trends and detailed analysis.

### 4.1 Asymmetries

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Left vs. Right Contact Time** | Imbalance between feet | Contact time (left) - Contact time (right) | ±10 ms |
| **Left vs. Right Flight Time** | Imbalance between feet | Flight time (left) - Flight time (right) | ±10 ms |
| **Step-to-Hop Distance Ratio** | How much step distance vs. hop distance | Step distance / Hop distance | ±5% |
| **Jump-to-Hop Distance Ratio** | How much jump distance vs. hop distance | Jump distance / Hop distance | ±5% |

### 4.2 Efficiency & Power Indicators

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Distance per Contact Time (Hop)** | Efficiency metric: distance covered per unit time on ground | Hop distance / Hop contact time | Derived |
| **Distance per Contact Time (Step)** | Efficiency during step | Step distance / Step contact time | Derived |
| **Distance per Contact Time (Jump)** | Efficiency during jump | Jump distance / Jump contact time | Derived |
| **Contact Time Ratio (Hop:Step:Jump)** | Relative time spent in each phase | e.g., 0.11 : 0.08 : 0.12 seconds | Relative |

### 4.3 Landing Characteristics

| Metric | What It Measures | Calculation | Confidence |
|--------|------------------|-------------|-----------|
| **Landing Distance Ahead of Hips** | Foot position at final landing relative to hip center | Distance between hip and heel at landing contact | ±10–20 mm |
| **Landing Angle** | Body angle at final ground contact | Angle of leg relative to vertical | ±5° |
| **Landing Deceleration** | How hard the landing impact (derived from velocity change) | Vertical velocity change from jump flight to landing | Derived |

---

## 5. DATA QUALITY & METADATA METRICS

Always display these to provide context.

### 5.1 Confidence & Validation

| Metric | What It Measures | Display As |
|--------|------------------|-----------|
| **Overall Segmentation Confidence** | How confident the system is in the detected phases | Percentage 0–100% or badge (Low/Good/High) |
| **Per-Phase Confidence** | Individual scores for each phase | Badges or small bars (hop, step, jump) |
| **Event Confirmation Status** | Whether events were manually confirmed | "Automatic" vs. "Confirmed" badges |
| **Warnings** | Any structural issues (unusual durations, misassigned sides, etc.) | List of warning messages in orange |

### 5.2 Session Metadata

| Metric | What It Measures | Display As |
|--------|------------------|-----------|
| **Athlete Name** | Who performed the jump | Text |
| **Date & Time** | When the recording was made | Timestamp |
| **Calibration Profile Used** | Which setup was used | Profile name + distance (e.g., "North runway, 4m mark") |
| **Video Frame Rate** | Actual delivered frame rate (not requested) | e.g., "150.2 fps" |
| **Video Resolution** | Capture resolution | e.g., "1080×720" |
| **Frame Count** | Total frames in video | e.g., "2,847 frames" |

---

## 6. RECOMMENDED DISPLAY HIERARCHY

### Results View — Priority 1 (Main Screen)

Show these metrics prominently, large numbers, clear labels:

1. **Total Distance** (hop + step + jump)
   - With breakdown: Hop: X m | Step: X m | Jump: X m
2. **Board Accuracy** (±X mm from scratch line, with foul warning if applicable)
3. **Approach Velocity** (e.g., 9.2 m/s)
4. **Contact Times** (Hop: X ms | Step: X ms | Jump: X ms)
5. **Flight Times** (Hop: X ms | Step: X ms | Jump: X ms)
6. **Max Hip Height** (e.g., 1.45 m above ground)

**Confidence badges:**
- Overall segmentation confidence badge (top right)
- Event confirmation status (e.g., "✓ Events Confirmed")
- Any warnings (red/orange banner if present)

### Results View — Priority 2 (Expandable Details)

Collapse these under "Advanced Metrics" or "Full Analysis":

- Hip heights at each contact
- Joint angles (knee, hip, ankle) at takeoff & landing
- Velocity loss across phases
- All individual flight times
- Asymmetry metrics
- Efficiency ratios
- Landing characteristics

### Comparison View (This Session vs. Prior Session)

Show only metrics where change exceeds measurement noise (not shown = no meaningful change):

- Δ Total Distance (±20 mm threshold for display)
- Δ Each phase distance
- Δ Approach velocity (±0.15 m/s threshold)
- Δ Contact times (±10 ms threshold)
- Δ Flight times (±10 ms threshold)
- Δ Board accuracy
- % change indicator (↑ improved, ↓ regressed, → no change)

### Trend Chart (Series Over Time)

Plot these as time series:

- Total distance (line chart with points)
- Hop distance (line)
- Step distance (line)
- Jump distance (line)
- Approach velocity (line with ±0.5 m/s confidence band)
- Average contact time (bar chart by phase)
- Average flight time (bar chart by phase)

---

## 7. MEASUREMENT CONFIDENCE TIERS

### Tier 1: Distances & Foot Placement (±10–20 mm)
**Display as:** Large, primary numbers
**Confidence:** High — directly from reconstructed foot positions during stationary core

- Phase distances (hop, step, jump)
- Board accuracy
- Approach/landing foot positions

### Tier 2: Timing (±7 ms)
**Display as:** Medium-sized numbers, clearly labeled
**Confidence:** High — directly from event timestamps, sub-frame refined

- Contact times (all phases)
- Flight times (all phases)
- Approach time

### Tier 3: Heights, Angles, Velocities (±100 mm absolute)
**Display as:** Secondary numbers, mark as "Indicative" or with reliability badge
**Confidence:** Moderate — affected by out-of-plane motion (±10% on angles)

- Hip heights
- Joint angles
- Velocities
- Efficiency ratios

### Out-of-Plane Motion Caveat
Mark these with a note: "Single-camera setup cannot resolve lateral motion. Values are in-plane estimates; actual joint angles may differ ~10%."

---

## 8. CORRECTION — METRICS NOT ACTUALLY IN THE PIPELINE

**This section supersedes parts of Sections 1–4 above.** When `MetricCatalog.swift` was built against the real `TrendAnalyser.meaningfulChangeThresholds` table, several metrics speculated about in this document turned out not to exist in the validated pipeline. Do not build UI for:

- **Jump distance.** The jump phase lands in the pit, where the foot is occluded by the athlete's body and the sand, and the landing is a slide rather than a plant. There is no stationary core to take a median position over, so it cannot be measured the way hop and step are. This is why the real metric is named `Hop share of measured phases` — "measured phases" means hop + step, not all three.
- **Individual hip heights at each contact.** Not in the validated threshold table.
- **Max hip height (overall).** Same.
- **Landing angle, landing deceleration.** Not validated.
- **Left/right asymmetry metrics.** Not in the validated table — contact/flight time are tracked per-phase, not per-side comparison.
- **Efficiency ratios (distance per contact time).** Derived, not validated, not in the pipeline.

**The 13 metrics that are actually real** (from `MetricCatalog.all`, grouped as implemented):

| Group | Metric | Unit | Tier |
|---|---|---|---|
| Distances | Hop distance | ft/in | ±0.8″ |
| Distances | Step distance | ft/in | ±0.8″ |
| Distances | Hop share of measured phases | % | ±0.8″ |
| Distances | Step share of measured phases | % | ±0.8″ |
| Placement | Toe distance behind scratch line (board accuracy) | inches | ±0.8″ |
| Placement | Touchdown distance ahead of hips | inches | ±0.8″ |
| Timing | Contact time | ms | ±7 ms |
| Timing | Flight time | ms | ±7 ms |
| Technique | Approach velocity | m/s | Indicative |
| Technique | Velocity loss | m/s | Indicative |
| Technique | Hip rise in flight | inches | Indicative |
| Technique | Knee angle at touchdown | degrees | Indicative |
| Technique | Trunk lean at touchdown | degrees | Indicative |

Anything the pipeline emits that isn't in this table is silently dropped by `PresentedMetric.from(record:)` — by design, so a number with no unit and no reliability tier never reaches the screen.

---

## 9. WHAT TO HIDE BY DEFAULT

These are less useful for end users and clutter the display:

- Individual frame indices (unless debugging)
- Raw pixel-space coordinates
- Intermediate pose confidence scores (combine into phase confidence instead)
- Per-frame velocity vectors (average per phase instead)
- Model input parameters (focal length, distortion coefficients — include in "Calibration Info" collapsible)

---

## 10. EXPORT OPTIONS

For CSV or PDF export, include all metrics above, organized by category.

**Default export fields (recommended for most users):**
- Phase distances
- Board accuracy
- Contact times
- Flight times
- Approach velocity
- Max hip height
- Event confirmation status
- Warnings

**Full export (for coaches/analysts):**
- Everything above
- Joint angles at each event
- Velocity profiles
- Confidence scores
- Raw event timestamps
- Session metadata

---

## Summary Table: Which Metrics to Display Where

| Location | Metrics | Format | Priority |
|----------|---------|--------|----------|
| **Results Card (Home)** | Total distance, board accuracy, confidence | Large numbers + badge | P0 |
| **Results Main View** | Distances, times, velocity, heights | Prominent cards | P1 |
| **Results Details Panel** | Angles, efficiency, asymmetries, metadata | Expandable sections | P2 |
| **Comparison View** | Δ distances, Δ times (only if significant) | % change + arrow | P1 |
| **Trend Chart** | Distance, velocity, times over 5–10 sessions | Line/bar charts | P2 |
| **Export (CSV)** | All metrics, organized by category | Rows & columns | P3 |

---

**Note:** This list is data-complete. Not all metrics need to be displayed immediately—prioritize the P0 and P1 items for MVP, add P2 as refinement.
