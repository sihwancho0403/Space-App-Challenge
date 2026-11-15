# ASTRA — Build, Architecture, and Test Report

## Files
| File | Purpose |
|---|---|
| `ContentView.swift` | The entire iOS app (≈4,900 lines, 25 sections). Replaces your current ContentView.swift. |
| `ASTRA_Sheets.gs` | Google Apps Script web app for the spreadsheet link (English, adds a `provenance` column). |
| `ASTRA_knowledge_template.json` | Format for importing your ~20 medical sources and the onboard supply list. |

## Setup (Mac + Xcode)
1. Open the project → replace **all** of `ContentView.swift` with the new file. Delete any older extra Swift files from the earlier versions (BiometricPipeline, SheetsSync, AIAdvisorView) so types aren't duplicated. Keep your existing `…App.swift` (`@main` with `ContentView()`).
2. TARGETS ▸ General ▸ **Minimum Deployments: iOS 26.0**.
3. Signing & Capabilities: Personal Team, a unique Bundle ID, **+ Capability ▸ HealthKit**.
4. TARGETS ▸ Info, add two keys:
   - `Privacy - Health Share Usage Description`: "ASTRA reads health data to assess astronaut status."
   - `Privacy - Motion Usage Description`: "ASTRA reads the barometer to monitor ambient pressure." (without this key the app crashes when you turn on the barometer)
5. Destination: your iPhone (not "My Mac"). Run. Allow Health access for every type.
6. Google Sheets: paste the new `ASTRA_Sheets.gs`, change `TOKEN`, then **deploy a new version**. Your old sheet's columns differ (a new `provenance` column was added), so use a new sheet or delete the old `records` tab.
7. Knowledge: put your sources in the JSON template → AirDrop or Files to the iPhone → Data tab ▸ *Import sources (JSON)*. If an import uses the same `id` as a built-in placeholder (e.g. `builtin-hemorrhage`), the import replaces it.

## Architecture
```
Apple Watch ─► HealthKit ─► HealthKitManager (anchored streams)
                                 │
Suit simulator / manual entry ───┼─► BiometricDataManager: validate (plausible range, timestamps)
Google Sheets edits ─────────────┘        → BiometricStore (on-device, completeFileProtection)
                                          → TrendAnalyzer (14-day baseline, z-score, 1 h Δ, 6 h slope)
iPhone barometer / presets / crew entry ─► EnvironmentalDataManager ─► PhysicalModelCalculator
                                                       │                  (Antoine boiling point, Armstrong limit,
                                                       │                   alveolar gas eq., Severinghaus SpO₂,
                                                       │                   hydrostatic ρgh)
                                                       ▼
                      RiskEngine (rule-based tiers: Normal/Observe/Caution/Urgent/Emergency)
                                                       │
Case description ─► MedicalReasoningEngine:  1. ProtocolEngine (offline, always runs)
                                             2. MedicalKnowledgeBase retrieval (your sources, cited)
                                             3. AIIntegrationManager (on-device model, if available)
                                             4. SafetyValidator (no doses, kit-only items, authority escalation,
                                                unknown citations removed, AI claims labeled)
                                                       │
            Dashboard · Assistant · Vitals charts · Environment · Emergency screen · CSV/JSON/PDF · Sheets
```
Rules the code enforces: AI can raise urgency but never lower it. Every value carries a provenance tag (SENSOR / MANUAL / CALC / ESTIMATE / ASSUMED / SIM), and simulated values are never shown as sensor data. Gravity is applied only to the hydrostatic model. Medications appear without doses ("per onboard protocol"). Invasive actions are marked **AUTH REQUIRED**.

## Guidance Engine → where it is in the code
| Spec | Implementation |
|---|---|
| A Assessment | `assessFirst`, `confirmed`, `missingInformation` in `ProtocolEngine.assess` |
| B Decision support | differentials with evidence for and against, `escalation`, `contraindications` |
| C Sequential guidance | `GuidanceStep`: action, purpose, equipment, precautions, expected observations, reassess-if, if-unsuccessful, authority, basis, sources |
| D Reassessment | `reassessInMinutes` (2/5/15/60/240), case updates, intervention log (Improved / No change / Worse), auto re-run when new vitals arrive, trend vs previous report |
| E Mission-aware | gravity (microgravity CPR/restraint/fluid notes), pressure/O₂ physics, comms delay/blackout, responder training, onboard kit |
| F Uncertainty | Confirmed / Supported by sources / Uncertain / Needs qualified assistance |
| Unfamiliar cases | Offline: SAMPLE + full vitals structured assessment. With AI: additional steps and differentials, validated and labeled |

## Testing report (honest)
**What I verified:** static review only. Brackets, braces, and parentheses balance (1265/1265, 2467/2467, 521/521). There are no duplicate type names, no Korean text is left, and every type the code references is defined in the file or in Apple's frameworks. The knowledge template parses as valid JSON. I checked by hand that calls match their initializers' argument order.

**What I could not do:** compile or run. This environment has no Swift compiler or iOS SDK, so expect to fix a few compile errors in Xcode. If you get any, paste the error text and line number and I'll fix them quickly. The parts most likely to need a tweak are the FoundationModels `@Generable`/`@Guide` macros and Swift 6 concurrency warnings.

**Edge cases handled in code (not yet run):**
| Case | Handling |
|---|---|
| Missing / no data | "No data" tiles, missing-data chart placeholder, missing-info list in reports |
| Invalid values | Rejected outside plausible range (count and last rejection shown); sheet edits also validated |
| Delayed / future / inconsistent timestamps | Future > 5 min or end < start rejected; stale flag when older than expected interval |
| Gaps | Chart lines break at gaps |
| No Health permission / unsupported device | Error message; simulation available |
| No barometer | Message; presets / manual entry remain |
| AI unavailable (your iPhone) | Full offline protocol + knowledge retrieval; status explains why |
| AI context overflow | Retries with fewer sources |
| Network down | Sheets errors shown; everything else is offline |
| Large datasets | 30-day retention, chart downsampling to ≤400 points, 500-row upload chunks |
| Multiple symptoms | All findings processed; urgency = highest; differentials combined |

**Test on device (suggested order):** Demo cases menu (Assistant) → suit simulation + deterioration (Data) → depressurization demo (Environment) → emergency screen and 30 s crew alert → export PDF/CSV → Sheets upload, edit a value, download edits → import your JSON.

---

# Psychological Monitoring (Mind tab) — sections 26–32

## Data architecture
```
Astronaut text ──► Conversation (chat | journal | private journal) ──► ChatMessage (original text, never overwritten)
                                     │
                                     ├─► PsychSafetyScreen (deterministic, always first) ──► safety banner + steps
                                     ├─► OfflineConversationManager (LanguageModelSession, on-device) ──► AI reply   [chat only]
                                     └─► EmotionAnalysisEngine (@Generable AIPsychAnalysis, on-device)
                                             └─ unavailable → message saved as "pending"; optional labeled keyword screen
                                                         │
                                                         ▼
                                     EmotionAnalysis (linked by messageID; method, status, evidence, uncertainty,
                                                      astronaut correction overrides the inference)
MoodCheckIn (49 states, stress/energy/workload, mission event, note) ─┐
                                                                      ├─► DailyPsychRecord → weekly / monthly summary,
EmotionAnalysis ──────────────────────────────────────────────────────┘   personal baseline, themes, stressors
BiometricStore (sleep, HR, HRV) ──► Pearson correlation with mood/stress (association only)
All of it → astra_psych.json (iOS Data Protection: completeFileProtection) + optional Face ID / passcode lock
Export → psych CSV (wrote / selected / inferred / uncertain columns), JSON (full), PDF report. Private journals are excluded unless enabled.
```

## Offline AI
- Replies and analysis both use `LanguageModelSession` from Apple's FoundationModels, which runs on the device and needs no network.
- Before every call the app checks `SystemLanguageModel.default.availability` and the device language, and handles these errors: device not eligible, Apple Intelligence off, model not ready, unsupported language, guardrail refusal, context overflow (starts a new session with the recent history).
- If the model is unavailable, no reply is faked. A system notice explains why, the entry stays pending, and *Analyze now* processes pending entries later.
- An optional keyword screen fills the gap. It is always labeled "KEYWORD (not AI)" and set to low confidence.
- Alternative local model for unsupported iPhones: investigated, not implemented. MLX Swift or llama.cpp with a small quantized model (about 1–2 GB) could run offline on older devices. It needs a Swift package plus a model file bundled in advance, and its output would need the same safety validation.

## Setup additions
- Info key `Privacy - Face ID Usage Description` ("Unlock your private psychological records"). This is needed only if the Mind lock is turned on.
- AI conversation needs an Apple Intelligence-capable device: iPhone 15 Pro or later, or an M-series iPad/Mac, running iOS 26 with Apple Intelligence on and the device language set to English. On other devices everything else works and entries are saved for later analysis.
- Offline test: turn on Airplane Mode (Wi-Fi and cellular off) → Mind → Chat → send messages. Replies and analysis should still appear on a supported device.
- There are now 6 tabs, so on iPhone the last tabs appear under **More**.

## Testing report (Mind)
**Not compiled or run here** (no Swift toolchain). Offline operation and model availability are **not verified**. They must be tested on a supported device with Airplane Mode on. Static checks passed: brackets balanced, no duplicate type names, all types defined.

Test sentences to use on device (expected behavior, not yet observed):
| Type | Sentence | Expected |
|---|---|---|
| Positive | "Today's EVA went perfectly and the view of Earth was incredible." | excitement/awe, high confidence |
| Negative | "I miss being able to talk to my family whenever I want." | homesickness + loneliness, factor: separation |
| Mixed | "I'm excited about the mission, but I'm worried something might go wrong." | excitement + anxiety both listed |
| Neutral | "Completed the filter replacement and logged the readings." | insufficient information |
| Ambiguous | "Long day." | insufficient information / low confidence |
| Sarcasm | "Great, another 14-hour shift. Just what I needed." | frustration, uncertainty notes sarcasm |
| Context | "I'm tired, but it's the good kind after the workout." | physical fatigue, not distress |
| Indirect | "Nothing bad happened, I just feel far away from everyone." | detachment/loneliness, moderate confidence |
| Safety | a sentence containing "I can't go on" | safety banner first, crew/CMO steps, no claim of contact |

Expected limitation: the keyword screen cannot detect sarcasm or indirect feelings. It is labeled accordingly and is meant to be replaced by AI analysis when available.

---

# Monitoring while the app is closed

## Part A — HealthKit background delivery (implemented, section 33)
- Apple Watch samples reach HealthKit on the iPhone whether or not ASTRA is open.
- `BackgroundHealthMonitor` registers `HKObserverQuery` + `enableBackgroundDelivery(.immediate)` for heart rate, SpO₂, respiratory rate, body temperature, and HRV.
- iOS wakes ASTRA when new samples arrive. ASTRA reads them with an anchored query, evaluates them with the **same RiskEngine and saved environment**, and posts a time-sensitive local notification for Urgent/Emergency. Notifications are rate-limited to one per metric every 10 minutes.
- No data is lost: the foreground app reloads everything from HealthKit when opened.
- Limitation: iOS controls wake frequency. Heart rate may arrive minutes to about an hour late, so this is not second-by-second monitoring.
- Setup:
  1. Signing & Capabilities ▸ HealthKit ▸ ☑ **Background Delivery**
  2. Replace the @main App file with `MyAppApp.swift` (adds `ASTRAAppDelegate`)
  3. Allow notifications on first launch

## Part B — ASTRA Watch companion app (code provided: `ASTRAWatchApp.swift`; iPhone receiver implemented)
- A workout session on the Watch measures heart rate **every few seconds**. The Watch checks thresholds itself (haptic and on-screen alert, works even if the iPhone is out of range) and streams samples to the iPhone over WatchConnectivity (live message, or queued transfer when out of range).
- On the iPhone, `WatchLinkReceiver` feeds them into the same pipeline: charts, RiskEngine, medical reasoning, and export.
- Setup: File ▸ New ▸ Target ▸ watchOS App ("Watch App for Existing iOS App"). Then add HealthKit + Background Modes ▸ Workout processing, and the Health Share/Update usage descriptions.
- Status: code written but **not built or tested on a Watch**.
- Next steps: SpO₂ on demand, fall/impact detection, and on-Watch medical guidance when the iPhone is unavailable.

# How environment values are obtained in space
| Value | Source on a spacecraft |
|---|---|
| Cabin pressure | Module pressure transducers |
| O₂, CO₂, N₂ partial pressures | Atmosphere analyzers (on the ISS, the mass-spectrometer-based Major Constituent Analyzer) and portable CO₂ monitors |
| Temperature, humidity | Temperature-and-humidity control system sensors |
| Toxic gases / combustion products | Portable combustion-product analyzers |
| Acceleration / gravity | Microgravity accelerometers in orbit; known surface gravity on the Moon (1.62 m/s²) or Mars (3.71 m/s²) |
| Radiation | Area and personal dosimeters |

Flow: vehicle life-support sensors → onboard data system → onboard local network (not the internet) → ASTRA labels them **MEASURED**. Without that link, ASTRA uses presets (**ASSUMED**), crew entry (**MANUAL**), the iPhone barometer (**MEASURED**), or the depressurization demo (**SIMULATED**). Derived values (boiling point, Armstrong limit, alveolar O₂, expected SpO₂, hydrostatic load) are **CALCULATED/ESTIMATED** from established physical models.

---

# Simulation Mode (sections 34–39)

## Architecture
```
Manual controls ─┐
Scenario engine ─┤                                  ┌─ Live mode: shows only real records
CSV import ──────┼─► BiometricRecord (sourceKind =  │
Google Sheets ───┘   simulatedManual / Scenario /   ├─ Simulation mode: shows only simulated records
                     Import, provenance SIM)        │
Apple Watch / HealthKit ─► BiometricRecord (live) ──┘   (both stored; HealthKit is never written to)
        ▼ same path for every source
BiometricDataManager.receive  → validation: number, unit, plausible range, timestamp, duplicate, out-of-order
                                (rejected/flagged values logged with the reason; never silently corrected)
BiometricStore → TrendAnalyzer → RiskEngine (+ single-reading vs sustained-change notes)
→ Dashboard / Vitals charts → MedicalReasoningEngine (offline protocols + on-device AI)
→ ClinicalReport with dataSource ("Simulation — scenario …") + exact input snapshot
```
- An assessment runs automatically every 20 s while a simulation is active. The AI prompt starts with "DATA SOURCE: SIMULATION … never call it an actual emergency".
- Reports are prefixed **[SIMULATION]**. Alerts are prefixed **[SIM]**. The emergency screen reads **SIMULATED EMERGENCY**.
- A pink banner on every screen shows the mode, with Open and Exit buttons.

## Simulation clock
- Speeds: 1×, 5×, 10×, 60×. At 60×, one simulated hour plays in one real minute.
- Timestamps keep simulated spacing, so trends and slopes stay correct. They are anchored so they never run ahead of real time and never go backwards. Changing speed re-anchors the clock.
- Controls: play, pause, resume, step forward (one sample), rewind 5 min (removes generated records after that point), restart, reset (removes all simulated records and returns to Live).

## Datasets
- **CSV (offline)**: wide format (Timestamp + Heart Rate, Blood Pressure "118/78", Systolic, Diastolic, SpO2, Temperature °C, Respiratory Rate, HRV, Glucose, Cabin Pressure kPa) or ASTRA's own long-format export.
  - Units are checked, not converted. °F, mmol/L, psi and SpO₂ given as a fraction are rejected with a reason.
  - Empty cells stay missing. Imported datasets play exactly their rows (no interpolation).
  - A validation report lists every problem with its row number.
  - `ASTRA_sample_scenario.csv` includes a missing value and a Fahrenheit value to demonstrate this.
- **Google Sheets**: uses the existing Apps Script web app. No API keys or OAuth credentials are in the app.
  1. Paste the updated `ASTRA_Sheets.gs` and run `setupScenarioSheet()` once to create the example 'scenario' tab.
  2. Deploy a **new version**.
  3. In the app: Simulation ▸ Datasets ▸ Sync now (or Auto-sync every 10–300 s).
  - Sync rules: the sheet is the source of truth for the "Google Sheets scenario". Changes are detected by content signature. The playback position is kept and only unplayed samples use edited values. On failure, the last good copy is used offline.
- Export: the current scenario as CSV (re-importable), or all simulated records as CSV.

## Built-in configurable templates (test data, not diagnoses)
Spreadsheet example · Gradual heart-rate increase · Blood-pressure rise · Oxygen saturation decline · Body-temperature rise · Multiple simultaneous abnormalities · Intermittent sensor dropout · Sudden sensor disconnection · Cabin pressure drop. Templates are copied before editing. The scenario editor sets name, description, context sent to the assistant, expected behavior, duration, sample interval, interpolation, environment preset, and keyframes (any parameter can be left missing, and sensor dropout can be marked).

## Testing status
Not compiled or run here (no Swift toolchain). Static checks passed: brackets balanced and no duplicate type names. Suggested device tests:
1. Manual: set HR 120, then Send. Overview shows SIM 120 bpm and Observe/Caution, and the Live view is unchanged.
2. Template "Multiple simultaneous abnormalities" at 60×. Expected: Urgent, then Emergency; the [SIMULATION] assessment includes bleeding guidance.
3. "Intermittent sensor dropout". Expected: a chart gap and missing-data notes.
4. Import `ASTRA_sample_scenario.csv`. Expected: 2 issues reported (°F rejected, missing HR kept missing).
5. Google Sheets: edit a value during playback, then Sync. Expected: later samples use the new value.
