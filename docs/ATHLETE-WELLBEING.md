# Athlete and wellbeing v1

The iPhone Today screen uses the existing on-device journal and WOD database. Check-in fields are optional integer observations from 1 to 5, stored under stable noop.checkin.v1 keys. They are not a validated questionnaire and do not modify Charge. Saves are atomic and retain unrelated journal answers.

WOD migration v25 adds nullable actual duration, benchmark version and scaling; movement JSON adds optional sets. Older rows remain readable. Total reps done × actual kg describes recorded external volume, not muscular fatigue. Missing fields are not zero. Comparable benchmarks require matching version, type, format, score kind, cap, RX status, scaling and movement prescription. Rounds/reps are ordered lexicographically and not plotted using an arbitrary conversion.

## Calculation versions

- load-interval-v2: sorted positive HR readings, duplicate timestamps collapsed deterministically to the lower HR. Each accepted interval contributes its actual elapsed time. Gaps over 60 s contribute no load. The final sample receives the median accepted cadence, matching legacy regular-stream semantics; coverage explicitly includes that estimate. The 60 s threshold is an engineering heuristic. Require at least 20 unique samples and 600 accepted seconds. Edwards-style HRR zones remain an adaptation, not original Edwards HRmax zones. Imported historical scores are not silently rewritten.
- readiness-calendar-v2: baseline uses the prior 30 civil days. Load ratios require all 28 and 7 calendar-day values; missing is unknown, explicit zero is recorded rest/low load. Future rows are excluded. Civil-day arithmetic uses Gregorian UTC day labels, not elapsed local seconds. Readiness categories are descriptive heuristics, not diagnoses, injury predictions or training prescriptions.
- Charge remains the existing approximate weighted model. Its weights do not confer clinical validation. Provider-imported scores are not described as computed by this model. Source, selected day and local HR coverage are displayed; absent per-score calculation timestamps and overnight coverage are explicitly unavailable.

## Verification

Automated regression coverage: irregular HR, duplicate/order invariance, disconnected samples, long gaps, historical evaluation, missing vs zero days, DST/leap-day labels, actual session duration, journal editing/clearing, invalid check-in values, WOD roundtrip, legacy movement decoding and benchmark incompatibility.

GitHub Actions builds macOS and iOS without signing and runs Swift package tests on ChatGPT_V2. These checks do not establish clinical validity. Device-only acceptance still requires VoiceOver, largest Dynamic Type, relaunch persistence and a real strap synchronization. No clinical predictions or CGM changes are introduced.
