// ContentView.swift — ASTRA (Autonomous Space Triage & Response Assistant)
//
// Single-file build. Replace the contents of ContentView.swift with this file.
// Remove any older BiometricPipeline.swift / SheetsSync.swift / AIAdvisorView.swift from the target.
//
// Required target settings (TARGETS ▸ your app):
//   • General ▸ Minimum Deployments: iOS 26.0
//   • Signing & Capabilities ▸ + Capability ▸ HealthKit
//   • Info ▸ Privacy - Health Share Usage Description  (NSHealthShareUsageDescription)
//   • Info ▸ Privacy - Motion Usage Description         (NSMotionUsageDescription) — iPhone barometer
//   • Info ▸ Privacy - Face ID Usage Description        (NSFaceIDUsageDescription) — optional Mind lock
//   • Signing & Capabilities ▸ HealthKit ▸ ☑ Background Delivery — alerts while the app is closed
//   • In the @main App file add: @UIApplicationDelegateAdaptor(ASTRAAppDelegate.self) private var appDelegate
//
// Module map (Ctrl+6 in Xcode jumps between sections):
//   1  Utilities                      14  MedicalReasoningEngine
//   2  Environment model              15  Vital-sign snapshot + RiskEngine
//   3  PhysicalModelCalculator        16  DataExportManager (CSV / JSON / PDF)
//   4  EnvironmentalDataManager       17  AppModel (integration hub)
//   5  Biometric data model           18  Theme, logo, shared components
//   6  Trend analysis                 19  Root view (ContentView)
//   7  Storage + Google Sheets sync   20  DashboardView
//   8  HealthKitManager +             21  MedicalAssistantView
//      BiometricDataManager           22  BiometricChartsView
//   9  MedicalKnowledgeBase           23  EnvironmentalMonitoringView
//  10  Clinical case model            24  DataView
//  11  Safety validator               25  EmergencyView
//  12  Offline protocol engine
//  13  AIIntegrationManager (FoundationModels)
//  26–32  Psychological monitoring: data model, safety + keyword screen, on-device
//         emotion analysis + conversation, longitudinal analysis, manager, export, GUI
//  33     Background monitoring (app closed) + Apple Watch live link receiver
//  34–39  Simulation Mode: Live/Simulation separation, scenarios, CSV + Google Sheets datasets,
//         playback engine with speed control, simulation dashboard and scenario editor
//
// Data flow:
//   Apple Watch → HealthKit → validation/normalization → BiometricStore (encrypted at rest)
//   → trend analysis → risk engine + reasoning engine (with environment + physics + knowledge)
//   → charts / assistant / alerts → CSV · JSON · PDF export and Google Sheets sync.
//
// Clinical safety: alert tiers are rule-based; AI output is validated (onboard-kit-only supplies,
// no generated doses, invasive actions require higher authority, unsupported claims labeled).
// Thresholds and the example knowledge/kit content are prototype values — replace them with the
// team's verified sources via the JSON import on the Data tab.

import SwiftUI
import HealthKit
import Charts
import FoundationModels
import UIKit
import CoreMotion
import UniformTypeIdentifiers
import Combine
import LocalAuthentication
import UserNotifications
import WatchConnectivity

// MARK: - 1. Utilities

nonisolated func fmt(_ v: Double?, _ digits: Int = 0) -> String {
    guard let v, v.isFinite else { return "—" }
    return String(format: "%.\(digits)f", v)
}

nonisolated func signed(_ v: Double, _ digits: Int = 0) -> String {
    (v >= 0 ? "+" : "") + fmt(v, digits)
}

nonisolated enum JSONCoding {
    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                    : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Local persistence. Files are written with iOS Data Protection (encrypted while the device is locked).
nonisolated enum FileStore {
    static func url(_ name: String) -> URL { URL.documentsDirectory.appending(path: name) }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONCoding.encoder().encode(value) else { return }
        try? data.write(to: url(name), options: [.atomic, .completeFileProtection])
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONCoding.decoder().decode(type, from: data)
    }
}

/// Where a value came from. Simulated or assumed values are never presented as sensor measurements.
nonisolated enum Provenance: String, Codable, CaseIterable {
    case measured, manualEntry, calculated, estimated, assumed, simulated

    var label: String {
        switch self {
        case .measured: return "Measured (sensor)"
        case .manualEntry: return "Measured (manual entry)"
        case .calculated: return "Calculated"
        case .estimated: return "Model estimate"
        case .assumed: return "Assumed default"
        case .simulated: return "Simulated"
        }
    }

    var shortLabel: String {
        switch self {
        case .measured: return "SENSOR"
        case .manualEntry: return "MANUAL"
        case .calculated: return "CALC"
        case .estimated: return "ESTIMATE"
        case .assumed: return "ASSUMED"
        case .simulated: return "SIM"
        }
    }
}

// MARK: - 2. Environment model

nonisolated enum EnvironmentKind: String, Codable, CaseIterable, Identifiable {
    case gravity, adaptedGravity, cabinPressure, oxygenFraction, cabinTemperature, relativeHumidity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gravity: return "Gravity acceleration"
        case .adaptedGravity: return "Crew-adapted gravity"
        case .cabinPressure: return "Ambient pressure"
        case .oxygenFraction: return "Oxygen concentration"
        case .cabinTemperature: return "Cabin temperature"
        case .relativeHumidity: return "Relative humidity"
        }
    }

    var unit: String {
        switch self {
        case .gravity, .adaptedGravity: return "m/s²"
        case .cabinPressure: return "kPa"
        case .oxygenFraction, .relativeHumidity: return "%"
        case .cabinTemperature: return "°C"
        }
    }

    var validRange: ClosedRange<Double> {
        switch self {
        case .gravity, .adaptedGravity: return 0...30
        case .cabinPressure: return 0...150
        case .oxygenFraction: return 0...100
        case .cabinTemperature: return -20...60
        case .relativeHumidity: return 0...100
        }
    }

    var digits: Int {
        switch self {
        case .gravity, .adaptedGravity: return 2
        case .cabinPressure, .cabinTemperature: return 1
        case .oxygenFraction, .relativeHumidity: return 1
        }
    }

    /// Typical instrument uncertainty used when the source does not report one.
    var defaultUncertainty: Double {
        switch self {
        case .gravity, .adaptedGravity: return 0.05
        case .cabinPressure: return 0.5
        case .oxygenFraction: return 0.5
        case .cabinTemperature: return 0.5
        case .relativeHumidity: return 3
        }
    }
}

nonisolated struct EnvironmentalParameter: Codable, Identifiable, Hashable {
    var id: String { kind.rawValue }
    let kind: EnvironmentKind
    var value: Double
    var provenance: Provenance
    var source: String
    var timestamp: Date
    var uncertainty: Double?

    var isValid: Bool { value.isFinite && kind.validRange.contains(value) }
}

/// Starting assumptions for a mission environment. Every preset value is labeled "Assumed default".
nonisolated enum MissionPreset: String, Codable, CaseIterable, Identifiable {
    case earth, iss, explorationVehicle, lunarSurface, marsSurface

    var id: String { rawValue }

    var label: String {
        switch self {
        case .earth: return "Earth (sea level)"
        case .iss: return "ISS (low Earth orbit)"
        case .explorationVehicle: return "Exploration vehicle (reduced-pressure atmosphere)"
        case .lunarSurface: return "Lunar surface habitat"
        case .marsSurface: return "Mars surface habitat"
        }
    }

    var gravity: Double {
        switch self {
        case .earth: return 9.80665
        case .iss, .explorationVehicle: return 0
        case .lunarSurface: return 1.62
        case .marsSurface: return 3.71
        }
    }

    /// Gravity the crew is assumed to be adapted to (e.g. microgravity before a planetary landing).
    var adaptedGravity: Double {
        switch self {
        case .earth: return 9.80665
        default: return 0
        }
    }

    var pressureKPa: Double {
        switch self {
        case .earth, .iss: return 101.3
        default: return 56.5   // 8.2 psia candidate exploration atmosphere — verify against mission data
        }
    }

    var oxygenPercent: Double {
        switch self {
        case .earth, .iss: return 20.9
        default: return 34.0
        }
    }

    var temperature: Double { 22 }
    var humidity: Double { 45 }
}

// MARK: - 3. PhysicalModelCalculator

nonisolated struct BoilingPointResult: Codable {
    let celsius: Double?
    let uncertainty: Double?
    let modelNote: String
    let inValidityRange: Bool
}

nonisolated struct PhysicsSnapshot: Codable {
    var pressureKPa: Double?
    var pressureProvenance: Provenance?
    var boiling: BoilingPointResult?
    var armstrongLimitKPa: Double
    var armstrongMarginKPa: Double?
    var inspiredO2mmHg: Double?
    var alveolarO2mmHg: Double?
    var expectedSpO2: Double?
    var hydrostaticCurrentMmHg: Double?
    var hydrostaticAdaptedMmHg: Double?
    var orthostaticLoadChangeMmHg: Double?
    var assumptions: [String]

    var lines: [String] {
        var out: [String] = []
        if let p = pressureKPa { out.append("Ambient pressure \(fmt(p, 1)) kPa (\(pressureProvenance?.label ?? "unknown source"))") }
        if let b = boiling {
            if let c = b.celsius { out.append("Water boiling point \(fmt(c, 1)) °C ± \(fmt(b.uncertainty, 1)) (\(b.modelNote))") }
            else { out.append("Water boiling point: \(b.modelNote)") }
        }
        out.append("Armstrong limit \(fmt(armstrongLimitKPa, 2)) kPa (water boils at 37 °C)")
        if let m = armstrongMarginKPa { out.append("Margin above Armstrong limit \(fmt(m, 1)) kPa") }
        if let a = alveolarO2mmHg { out.append("Estimated alveolar PO₂ \(fmt(a)) mmHg") }
        if let s = expectedSpO2 { out.append("Expected SpO₂ for this atmosphere ≈ \(fmt(s))% (model estimate)") }
        if let h = hydrostaticCurrentMmHg { out.append("Heart-to-brain hydrostatic gradient \(fmt(h, 1)) mmHg at current gravity") }
        if let d = orthostaticLoadChangeMmHg, d > 0.5 { out.append("Orthostatic load increased by \(fmt(d, 1)) mmHg relative to adapted gravity") }
        return out
    }
}

/// Established physical models only. Gravity is applied solely to the hydrostatic pressure model.
nonisolated enum PhysicalModelCalculator {
    static let mmHgPerKPa = 7.50062
    static let bloodDensity = 1060.0            // kg/m³
    static let defaultHeartToBrainM = 0.30      // m, adult seated/standing — assumption
    static let alveolarCO2mmHg = 40.0           // assumption: normocapnia
    static let respiratoryQuotient = 0.8        // assumption
    static let aaGradientmmHg = 10.0            // assumption: healthy alveolar-arterial gradient

    // Antoine coefficients for water (P in mmHg, T in °C)
    private static let low = (a: 8.07131, b: 1730.63, c: 233.426)    // valid 1–100 °C
    private static let high = (a: 8.14019, b: 1810.94, c: 244.485)   // valid 99–374 °C

    static func vaporPressureKPa(celsius t: Double) -> Double {
        let k = t <= 100 ? low : high
        let mmHg = pow(10, k.a - k.b / (k.c + t))
        return mmHg / mmHgPerKPa
    }

    private static func boilingCelsius(mmHg p: Double) -> Double? {
        let pLow = pow(10, low.a - low.b / (low.c + 1))       // ≈ 4.9 mmHg (1 °C)
        let pHigh = pow(10, high.a - high.b / (high.c + 374)) // critical region
        guard p >= pLow, p <= pHigh else { return nil }
        let k = p <= 760 ? low : high
        return k.b / (k.a - log10(p)) - k.c
    }

    static func boilingPoint(pressureKPa: Double, uncertaintyKPa: Double?) -> BoilingPointResult {
        let p = pressureKPa * mmHgPerKPa
        guard let t = boilingCelsius(mmHg: p) else {
            let note = p < 4.9 ? "below Antoine validity range (< 0.65 kPa) — water boils below 1 °C"
                               : "above Antoine validity range"
            return BoilingPointResult(celsius: nil, uncertainty: nil, modelNote: note, inValidityRange: false)
        }
        var u: Double?
        if let du = uncertaintyKPa, du > 0 {
            let up = boilingCelsius(mmHg: (pressureKPa + du) * mmHgPerKPa)
            let dn = boilingCelsius(mmHg: max(pressureKPa - du, 0.66) * mmHgPerKPa)
            if let up, let dn { u = abs(up - dn) / 2 }
        }
        let note = p <= 760 ? "Antoine equation, 1–100 °C range" : "Antoine equation, 99–374 °C range"
        return BoilingPointResult(celsius: t, uncertainty: u, modelNote: note, inValidityRange: true)
    }

    /// Pressure at which water boils at body temperature (≈ 6.3 kPa).
    static var armstrongLimitKPa: Double { vaporPressureKPa(celsius: 37) }

    /// Alveolar gas equation: PAO₂ = FiO₂ × (Pb − PH₂O) − PaCO₂ / R
    static func alveolarO2(pressureKPa: Double, oxygenPercent: Double) -> (inspired: Double, alveolar: Double) {
        let pb = pressureKPa * mmHgPerKPa
        let ph2o = vaporPressureKPa(celsius: 37) * mmHgPerKPa
        let fio2 = oxygenPercent / 100
        let inspired = max(fio2 * (pb - ph2o), 0)
        let alveolar = max(inspired - alveolarCO2mmHg / respiratoryQuotient, 0)
        return (inspired, alveolar)
    }

    /// Severinghaus (1979) oxygen–hemoglobin dissociation approximation.
    static func saturation(po2 p: Double) -> Double {
        guard p > 0 else { return 0 }
        return 100 / (23400 / (p * p * p + 150 * p) + 1)
    }

    /// Hydrostatic pressure difference ρ·g·h, converted to mmHg.
    static func hydrostaticMmHg(gravity: Double, heightM: Double = defaultHeartToBrainM) -> Double {
        bloodDensity * gravity * heightM / 133.322
    }

    static func evaluate(pressure: EnvironmentalParameter?, oxygen: EnvironmentalParameter?,
                         gravity: EnvironmentalParameter?, adapted: EnvironmentalParameter?) -> PhysicsSnapshot {
        var s = PhysicsSnapshot(armstrongLimitKPa: armstrongLimitKPa, assumptions: [
            "PaCO₂ \(fmt(alveolarCO2mmHg)) mmHg, respiratory quotient \(respiratoryQuotient), A–a gradient \(fmt(aaGradientmmHg)) mmHg",
            "Heart-to-brain height \(fmt(defaultHeartToBrainM, 2)) m, blood density \(fmt(bloodDensity)) kg/m³"
        ])
        if let pressure, pressure.isValid {
            s.pressureKPa = pressure.value
            s.pressureProvenance = pressure.provenance
            s.boiling = boilingPoint(pressureKPa: pressure.value,
                                     uncertaintyKPa: pressure.uncertainty ?? pressure.kind.defaultUncertainty)
            s.armstrongMarginKPa = pressure.value - armstrongLimitKPa
            if let oxygen, oxygen.isValid {
                let o = alveolarO2(pressureKPa: pressure.value, oxygenPercent: oxygen.value)
                s.inspiredO2mmHg = o.inspired
                s.alveolarO2mmHg = o.alveolar
                s.expectedSpO2 = saturation(po2: max(o.alveolar - aaGradientmmHg, 0))
            }
        }
        if let gravity, gravity.isValid {
            let current = hydrostaticMmHg(gravity: gravity.value)
            s.hydrostaticCurrentMmHg = current
            if let adapted, adapted.isValid {
                let base = hydrostaticMmHg(gravity: adapted.value)
                s.hydrostaticAdaptedMmHg = base
                s.orthostaticLoadChangeMmHg = current - base
            }
        }
        return s
    }
}

// MARK: - 4. EnvironmentalDataManager

@MainActor
@Observable
final class EnvironmentalDataManager {
    var preset: MissionPreset = .iss
    var parameters: [EnvironmentKind: EnvironmentalParameter] = [:]
    var log: [EnvironmentalParameter] = []
    var barometerActive = false
    var barometerMessage: String?
    var depressurizing = false

    /// Called after every parameter change so risk evaluation and reasoning see the new environment.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private var depressurizationTask: Task<Void, Never>?

    init() {
        if let saved = FileStore.load([EnvironmentalParameter].self, from: "astra_environment.json"), !saved.isEmpty {
            for p in saved { parameters[p.kind] = p }
            if let raw = UserDefaults.standard.string(forKey: "env.preset"), let p = MissionPreset(rawValue: raw) { preset = p }
        } else {
            applyPreset(.iss)
        }
        log = FileStore.load([EnvironmentalParameter].self, from: "astra_environment_log.json") ?? []
    }

    func value(_ kind: EnvironmentKind) -> EnvironmentalParameter? { parameters[kind] }

    var physics: PhysicsSnapshot {
        PhysicalModelCalculator.evaluate(pressure: parameters[.cabinPressure], oxygen: parameters[.oxygenFraction],
                                         gravity: parameters[.gravity], adapted: parameters[.adaptedGravity])
    }

    /// Pressure change over the last 60 s (kPa), from logged values.
    var pressureRateKPaPerMinute: Double? {
        let recent = log.filter { $0.kind == .cabinPressure && $0.timestamp > Date().addingTimeInterval(-60) }
        guard let first = recent.first, let last = recent.last, last.timestamp > first.timestamp else { return nil }
        return (last.value - first.value) / last.timestamp.timeIntervalSince(first.timestamp) * 60
    }

    func applyPreset(_ p: MissionPreset) {
        preset = p
        UserDefaults.standard.set(p.rawValue, forKey: "env.preset")
        let source = "Preset: \(p.label)"
        set(.gravity, p.gravity, .assumed, source)
        set(.adaptedGravity, p.adaptedGravity, .assumed, source)
        if !(barometerActive) { set(.cabinPressure, p.pressureKPa, .assumed, source) }
        set(.oxygenFraction, p.oxygenPercent, .assumed, source)
        set(.cabinTemperature, p.temperature, .assumed, source)
        set(.relativeHumidity, p.humidity, .assumed, source)
    }

    func setManual(_ kind: EnvironmentKind, _ value: Double) {
        set(kind, value, .manualEntry, "Crew entry")
    }

    func set(_ kind: EnvironmentKind, _ value: Double, _ provenance: Provenance, _ source: String, uncertainty: Double? = nil) {
        let p = EnvironmentalParameter(kind: kind, value: value, provenance: provenance, source: source,
                                       timestamp: Date(), uncertainty: uncertainty ?? kind.defaultUncertainty)
        parameters[kind] = p
        log.append(p)
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
        persist()
        onChange?()
    }

    private func persist() {
        FileStore.save(Array(parameters.values), to: "astra_environment.json")
        FileStore.save(log, to: "astra_environment_log.json")
    }

    // iPhone barometer (real sensor). Requires NSMotionUsageDescription.
    func startBarometer() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            barometerMessage = "This device has no barometer."
            return
        }
        stopDepressurizationDemo()
        barometerActive = true
        barometerMessage = "Reading iPhone barometer…"
        altimeter.startRelativeAltitudeUpdates(to: OperationQueue.main) { [weak self] data, error in
            let kPa = data?.pressure.doubleValue
            let message = error?.localizedDescription
            Task { @MainActor in self?.receiveBarometer(kPa: kPa, error: message) }
        }
    }

    func stopBarometer() {
        altimeter.stopRelativeAltitudeUpdates()
        barometerActive = false
        barometerMessage = nil
    }

    private func receiveBarometer(kPa: Double?, error: String?) {
        if let error {
            barometerMessage = "Barometer error: \(error)"
            barometerActive = false
            return
        }
        guard let kPa else { return }
        barometerMessage = nil
        // Log at most every 5 s to keep the history compact.
        if let last = parameters[.cabinPressure], last.provenance == .measured,
           Date().timeIntervalSince(last.timestamp) < 5 { return }
        set(.cabinPressure, kPa, .measured, "iPhone barometer", uncertainty: 0.1)
    }

    /// Demonstration only: values are labeled "Simulated" everywhere.
    func startDepressurizationDemo() {
        stopBarometer()
        depressurizationTask?.cancel()
        depressurizing = true
        depressurizationTask = Task {
            var p = parameters[.cabinPressure]?.value ?? 101.3
            while !Task.isCancelled && p > 3 {
                p = max(p * 0.82, 3)
                set(.cabinPressure, p, .simulated, "Depressurization simulation")
                try? await Task.sleep(for: .seconds(2))
            }
            depressurizing = false
        }
    }

    func stopDepressurizationDemo() {
        depressurizationTask?.cancel()
        depressurizationTask = nil
        depressurizing = false
    }
}

// MARK: - 5. Biometric data model

nonisolated enum MetricKind: String, Codable, CaseIterable, Identifiable {
    case heartRate, restingHeartRate, hrv, spo2, respiratoryRate
    case bodyTemperature, wristTemperature, systolicBP, diastolicBP, bloodGlucose, sleep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .restingHeartRate: return "Resting heart rate"
        case .hrv: return "Heart rate variability (SDNN)"
        case .spo2: return "Blood oxygen saturation (SpO₂)"
        case .respiratoryRate: return "Respiratory rate"
        case .bodyTemperature: return "Body temperature"
        case .wristTemperature: return "Wrist temperature (sleep)"
        case .systolicBP: return "Systolic blood pressure"
        case .diastolicBP: return "Diastolic blood pressure"
        case .bloodGlucose: return "Blood glucose"
        case .sleep: return "Sleep"
        }
    }

    var shortLabel: String {
        switch self {
        case .heartRate: return "HR"
        case .restingHeartRate: return "Resting HR"
        case .hrv: return "HRV"
        case .spo2: return "SpO₂"
        case .respiratoryRate: return "Resp. rate"
        case .bodyTemperature: return "Body temp"
        case .wristTemperature: return "Wrist temp"
        case .systolicBP: return "Systolic BP"
        case .diastolicBP: return "Diastolic BP"
        case .bloodGlucose: return "Glucose"
        case .sleep: return "Sleep"
        }
    }

    var unit: String {
        switch self {
        case .heartRate, .restingHeartRate: return "bpm"
        case .hrv: return "ms"
        case .spo2: return "%"
        case .respiratoryRate: return "breaths/min"
        case .bodyTemperature, .wristTemperature: return "°C"
        case .systolicBP, .diastolicBP: return "mmHg"
        case .bloodGlucose: return "mg/dL"
        case .sleep: return "h"
        }
    }

    var digits: Int {
        switch self {
        case .bodyTemperature, .wristTemperature, .sleep: return 1
        default: return 0
        }
    }

    var systemImage: String {
        switch self {
        case .heartRate, .restingHeartRate: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .spo2: return "lungs.fill"
        case .respiratoryRate: return "wind"
        case .bodyTemperature, .wristTemperature: return "thermometer.medium"
        case .systolicBP, .diastolicBP: return "gauge.with.dots.needle.50percent"
        case .bloodGlucose: return "drop.fill"
        case .sleep: return "bed.double.fill"
        }
    }

    /// Physiologically plausible range. Values outside it are rejected as sensor or entry errors.
    var plausibleRange: ClosedRange<Double> {
        switch self {
        case .heartRate: return 20...250
        case .restingHeartRate: return 25...200
        case .hrv: return 1...300
        case .spo2: return 50...100
        case .respiratoryRate: return 3...70
        case .bodyTemperature: return 28...44
        case .wristTemperature: return 20...42
        case .systolicBP: return 40...280
        case .diastolicBP: return 20...180
        case .bloodGlucose: return 15...800
        case .sleep: return 0...16
        }
    }

    /// Expected maximum interval between samples, used to mark data gaps on charts.
    var expectedInterval: TimeInterval {
        switch self {
        case .heartRate: return 30 * 60
        case .spo2, .respiratoryRate, .hrv: return 6 * 3600
        default: return 36 * 3600
        }
    }

    var hkIdentifier: HKQuantityTypeIdentifier? {
        switch self {
        case .heartRate: return .heartRate
        case .restingHeartRate: return .restingHeartRate
        case .hrv: return .heartRateVariabilitySDNN
        case .spo2: return .oxygenSaturation
        case .respiratoryRate: return .respiratoryRate
        case .bodyTemperature: return .bodyTemperature
        case .wristTemperature: return .appleSleepingWristTemperature
        case .systolicBP: return .bloodPressureSystolic
        case .diastolicBP: return .bloodPressureDiastolic
        case .bloodGlucose: return .bloodGlucose
        case .sleep: return nil
        }
    }

    var hkUnit: HKUnit {
        switch self {
        case .heartRate, .restingHeartRate, .respiratoryRate: return HKUnit.count().unitDivided(by: .minute())
        case .hrv: return .secondUnit(with: .milli)
        case .spo2: return .percent()
        case .bodyTemperature, .wristTemperature: return .degreeCelsius()
        case .systolicBP, .diastolicBP: return .millimeterOfMercury()
        case .bloodGlucose: return HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        case .sleep: return .hour()
        }
    }

    /// HealthKit stores SpO₂ as a fraction (0.97); the app uses percent.
    var scale: Double { self == .spo2 ? 100 : 1 }
}

nonisolated enum DataSourceKind: String, Codable {
    case appleWatch, iPhone, manual, otherDevice, simulatedSuit, simulatedManual, simulatedScenario, simulatedImport

    /// Simulated sources are never treated as real astronaut measurements.
    var isSimulated: Bool { [.simulatedSuit, .simulatedManual, .simulatedScenario, .simulatedImport].contains(self) }

    var label: String {
        switch self {
        case .appleWatch: return "Apple Watch"
        case .iPhone: return "iPhone"
        case .manual: return "Manual entry"
        case .otherDevice: return "Other device"
        case .simulatedSuit: return "Suit simulation"
        case .simulatedManual: return "Simulation — manual control"
        case .simulatedScenario: return "Simulation — scenario playback"
        case .simulatedImport: return "Simulation — CSV / Google Sheets"
        }
    }

    var provenance: Provenance {
        switch self {
        case .appleWatch, .iPhone, .otherDevice: return .measured
        case .manual: return .manualEntry
        case .simulatedSuit, .simulatedManual, .simulatedScenario, .simulatedImport: return .simulated
        }
    }
}

nonisolated enum Reliability: String, Codable {
    case high, medium, low

    var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

/// One measurement = one row in every table, chart, export, and AI payload.
nonisolated struct BiometricRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let metric: MetricKind
    let value: Double
    let unit: String
    let start: Date
    let end: Date
    let sourceName: String
    let sourceKind: DataSourceKind
    let deviceModel: String?
    let context: String?
    let reliability: Reliability
    let note: String?
}

nonisolated extension BiometricRecord {
    init(sample: HKQuantitySample, metric: MetricKind) {
        let productType = sample.sourceRevision.productType ?? ""
        let model = sample.device?.model
        let userEntered = (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) ?? false

        var context: String?
        if let n = sample.metadata?[HKMetadataKeyHeartRateMotionContext] as? NSNumber,
           let c = HKHeartRateMotionContext(rawValue: n.intValue) {
            switch c {
            case .sedentary: context = "Sedentary"
            case .active: context = "Active"
            default: context = nil
            }
        }

        let kind: DataSourceKind
        if userEntered { kind = .manual }
        else if productType.hasPrefix("Watch") || model == "Watch" { kind = .appleWatch }
        else if productType.hasPrefix("iPhone") { kind = .iPhone }
        else { kind = .otherDevice }

        let reliability: Reliability
        if context == "Active" { reliability = .medium }
        else if kind == .appleWatch { reliability = .high }
        else { reliability = .medium }

        self.init(id: sample.uuid, metric: metric,
                  value: sample.quantity.doubleValue(for: metric.hkUnit) * metric.scale,
                  unit: metric.unit, start: sample.startDate, end: sample.endDate,
                  sourceName: sample.sourceRevision.source.name, sourceKind: kind,
                  deviceModel: model ?? (productType.isEmpty ? nil : productType),
                  context: context, reliability: reliability, note: nil)
    }

    init(sleepSample sample: HKCategorySample) {
        let productType = sample.sourceRevision.productType ?? ""
        let isWatch = productType.hasPrefix("Watch") || sample.device?.model == "Watch"
        self.init(id: sample.uuid, metric: .sleep,
                  value: sample.endDate.timeIntervalSince(sample.startDate) / 3600,
                  unit: MetricKind.sleep.unit, start: sample.startDate, end: sample.endDate,
                  sourceName: sample.sourceRevision.source.name,
                  sourceKind: isWatch ? .appleWatch : .otherDevice,
                  deviceModel: sample.device?.model, context: nil,
                  reliability: isWatch ? .high : .medium, note: nil)
    }
}

nonisolated struct ChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
    var segment: Int = 0
    var isAbnormal: Bool = false
}

// MARK: - 6. Trend analysis

nonisolated struct MetricSummary: Identifiable {
    var id: String { metric.rawValue }
    let metric: MetricKind
    let latestValue: Double?
    let latestAt: Date?
    let latestSource: String?
    let latestReliability: Reliability?
    let latestProvenance: Provenance?
    let baselineMean: Double?
    let baselineSD: Double?
    let baselineCount: Int
    let zScore: Double?
    let change1h: Double?
    let slopePerHour6h: Double?
    let recentCount: Int
    let anomalies: [String]

    var isStale: Bool {
        guard let latestAt else { return true }
        return Date().timeIntervalSince(latestAt) > metric.expectedInterval * 2
    }
}

nonisolated enum TrendAnalyzer {
    static func summaries(from records: [BiometricRecord], now: Date = Date()) -> [MetricSummary] {
        let grouped = Dictionary(grouping: records, by: \.metric)
        return MetricKind.allCases.map { m in
            let rs = grouped[m] ?? []
            return m == .sleep ? sleepSummary(rs, now: now) : summary(m, rs, now: now)
        }
    }

    static func summary(_ m: MetricKind, _ rs: [BiometricRecord], now: Date) -> MetricSummary {
        let latest = rs.last
        let startToday = Calendar.current.startOfDay(for: now)
        let baseStart = startToday.addingTimeInterval(-14 * 86400)
        let baseValues = rs.filter { $0.end >= baseStart && $0.end < startToday }.map(\.value)
        let (mean, sd) = stats(baseValues)

        var z: Double?
        if let v = latest?.value, let mean, let sd, sd > 0, baseValues.count >= 5 { z = (v - mean) / sd }

        var d1h: Double?
        if let latest {
            let target = latest.end.addingTimeInterval(-3600)
            let past = rs.min { a, b in
                abs(a.end.timeIntervalSince(target)) < abs(b.end.timeIntervalSince(target))
            }
            if let past, abs(past.end.timeIntervalSince(target)) <= 20 * 60 {
                d1h = latest.value - past.value
            }
        }

        let recent = rs.filter { $0.end >= now.addingTimeInterval(-6 * 3600) }
        let slope = recent.count >= 4 ? slopePerHour(recent) : nil

        var anomalies: [String] = []
        if let z {
            if abs(z) >= 3 { anomalies.append("Marked deviation from personal baseline (z = \(fmt(z, 1)))") }
            else if abs(z) >= 2 { anomalies.append("Deviation from personal baseline (z = \(fmt(z, 1)))") }
        }
        if let slope, let sd, sd > 0, abs(slope * 6) > 2 * sd {
            anomalies.append("Sustained 6-hour \(slope > 0 ? "rise" : "decline") (\(signed(slope, 1)) \(m.unit)/h)")
        }

        return MetricSummary(metric: m, latestValue: latest?.value, latestAt: latest?.end,
                             latestSource: latest?.sourceName, latestReliability: latest?.reliability,
                             latestProvenance: latest?.sourceKind.provenance,
                             baselineMean: mean, baselineSD: sd, baselineCount: baseValues.count,
                             zScore: z, change1h: d1h, slopePerHour6h: slope,
                             recentCount: recent.count, anomalies: anomalies)
    }

    static func sleepSummary(_ rs: [BiometricRecord], now: Date) -> MetricSummary {
        let preferred = rs.contains { $0.sourceKind == .appleWatch } ? rs.filter { $0.sourceKind == .appleWatch } : rs
        let last24 = preferred.filter { $0.end > now.addingTimeInterval(-86400) }
        let total: Double? = last24.isEmpty ? nil : last24.reduce(0) { sum, r in sum + r.value }

        let startToday = Calendar.current.startOfDay(for: now)
        let past = preferred.filter { $0.end >= startToday.addingTimeInterval(-14 * 86400) && $0.end < startToday }
        let byDay = Dictionary(grouping: past) { r in Calendar.current.startOfDay(for: r.end) }
            .mapValues { day in day.reduce(0) { sum, r in sum + r.value } }
        let (mean, sd) = stats(Array(byDay.values))

        var z: Double?
        if let total, let mean, let sd, sd > 0, byDay.count >= 5 { z = (total - mean) / sd }
        var anomalies: [String] = []
        if let z, z <= -2 { anomalies.append("Sleep markedly below personal baseline (z = \(fmt(z, 1)))") }

        return MetricSummary(metric: .sleep, latestValue: total, latestAt: last24.last?.end,
                             latestSource: last24.last?.sourceName, latestReliability: last24.last?.reliability,
                             latestProvenance: last24.last?.sourceKind.provenance,
                             baselineMean: mean, baselineSD: sd, baselineCount: byDay.count,
                             zScore: z, change1h: nil, slopePerHour6h: nil,
                             recentCount: last24.count, anomalies: anomalies)
    }

    static func stats(_ values: [Double]) -> (Double?, Double?) {
        guard !values.isEmpty else { return (nil, nil) }
        let mean = values.reduce(0, +) / Double(values.count)
        guard values.count >= 2 else { return (mean, nil) }
        let variance = values.reduce(0) { acc, v in acc + (v - mean) * (v - mean) } / Double(values.count - 1)
        return (mean, variance.squareRoot())
    }

    static func slopePerHour(_ rs: [BiometricRecord]) -> Double? {
        guard let t0 = rs.first?.end else { return nil }
        let xs = rs.map { $0.end.timeIntervalSince(t0) / 3600 }
        let ys = rs.map(\.value)
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        return den > 0 ? num / den : nil
    }
}

// MARK: - 7. Storage + Google Sheets sync

@MainActor
@Observable
final class BiometricStore {
    private(set) var records: [BiometricRecord] = []
    private(set) var lastUpdate: Date?

    /// Live mode shows only real measurements; Simulation mode shows only simulated ones. Both are kept in storage.
    var mode: DataMode = DataMode(rawValue: UserDefaults.standard.string(forKey: "data.mode") ?? "") ?? .live

    @ObservationIgnored private var ids = Set<UUID>()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    func matchesMode(_ r: BiometricRecord) -> Bool {
        mode == .live ? !r.sourceKind.isSimulated : r.sourceKind.isSimulated
    }

    var visibleRecords: [BiometricRecord] { records.filter(matchesMode) }

    func contains(metric: MetricKind, at date: Date, sourceKind: DataSourceKind) -> Bool {
        records.contains { $0.metric == metric && $0.sourceKind == sourceKind && abs($0.end.timeIntervalSince(date)) < 0.5 }
    }

    func latestTime(metric: MetricKind, sourceKind: DataSourceKind) -> Date? {
        records.last { $0.metric == metric && $0.sourceKind == sourceKind }?.end
    }

    init() {
        records = (FileStore.load([BiometricRecord].self, from: "astra_biometrics.json") ?? []).sorted { $0.end < $1.end }
        ids = Set(records.map(\.id))
    }

    func ingest(_ new: [BiometricRecord], deleted: Set<UUID> = []) {
        var changed = false
        if !deleted.isEmpty {
            let before = records.count
            records.removeAll { deleted.contains($0.id) }
            ids.subtract(deleted)
            changed = records.count != before
        }
        let fresh = new.filter { !ids.contains($0.id) }
        if !fresh.isEmpty {
            records.append(contentsOf: fresh)
            ids.formUnion(fresh.map(\.id))
            records.sort { $0.end < $1.end }
            changed = true
        }
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        if let first = records.first, first.end < cutoff {
            records.removeAll { $0.end < cutoff }
            ids = Set(records.map(\.id))
        }
        if changed {
            lastUpdate = Date()
            scheduleSave()
        }
    }

    func remove(where shouldRemove: (BiometricRecord) -> Bool) {
        records.removeAll(where: shouldRemove)
        ids = Set(records.map(\.id))
        lastUpdate = Date()
        scheduleSave()
    }

    @discardableResult
    func applyEdits(_ edits: [UUID: (value: Double?, note: String?, reliability: Reliability?)]) -> Int {
        var count = 0
        records = records.map { r in
            guard let e = edits[r.id] else { return r }
            count += 1
            return BiometricRecord(id: r.id, metric: r.metric, value: e.value ?? r.value, unit: r.unit,
                                   start: r.start, end: r.end, sourceName: r.sourceName, sourceKind: r.sourceKind,
                                   deviceModel: r.deviceModel, context: r.context,
                                   reliability: e.reliability ?? r.reliability,
                                   note: e.note ?? r.note ?? "Edited in Google Sheets")
        }
        if count > 0 {
            lastUpdate = Date()
            scheduleSave()
        }
        return count
    }

    func history(for metric: MetricKind, since: Date? = nil) -> [BiometricRecord] {
        records.filter { r in
            guard r.metric == metric, matchesMode(r) else { return false }
            if let since { return r.end >= since }
            return true
        }
    }

    func latest(_ metric: MetricKind, within seconds: TimeInterval) -> BiometricRecord? {
        let cutoff = Date().addingTimeInterval(-seconds)
        return records.last { $0.metric == metric && $0.end >= cutoff && matchesMode($0) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            FileStore.save(records, to: "astra_biometrics.json")
        }
    }
}

nonisolated struct SheetRow: Codable {
    let id: String
    let end: String
    let start: String
    let metric: String
    let metricLabel: String
    let value: Double
    let unit: String
    let sourceName: String
    let sourceKind: String
    let deviceModel: String?
    let context: String?
    let reliability: String
    let note: String?
}

nonisolated extension SheetRow {
    init(_ r: BiometricRecord) {
        self.init(id: r.id.uuidString, end: r.end.ISO8601Format(), start: r.start.ISO8601Format(),
                  metric: r.metric.rawValue, metricLabel: r.metric.label, value: r.value, unit: r.unit,
                  sourceName: r.sourceName, sourceKind: r.sourceKind.rawValue, deviceModel: r.deviceModel,
                  context: r.context, reliability: r.reliability.rawValue, note: r.note)
    }
}

nonisolated struct UploadBody: Encodable {
    let token: String
    let records: [SheetRow]
}

nonisolated struct UploadResponse: Decodable {
    let ok: Bool
    let added: Int?
    let error: String?
}

nonisolated struct PullResponse: Decodable {
    let ok: Bool
    let rows: [PulledRow]?
    let error: String?
}

/// A row returned from the sheet. Human-edited cells may arrive as numbers or text.
nonisolated struct PulledRow: Decodable {
    let id: String
    let value: Double?
    let note: String?
    let reliability: String?

    enum CodingKeys: String, CodingKey { case id, value, note, reliability }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        if let d = try? c.decode(Double.self, forKey: .value) {
            value = d
        } else if let s = try? c.decode(String.self, forKey: .value) {
            value = Double(s.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
        if let s = try? c.decode(String.self, forKey: .note) {
            note = s.isEmpty ? nil : s
        } else if let d = try? c.decode(Double.self, forKey: .note) {
            note = String(d)
        } else {
            note = nil
        }
        reliability = try? c.decode(String.self, forKey: .reliability)
    }
}

nonisolated enum SyncError: LocalizedError {
    case server(String)
    case notJSON

    var errorDescription: String? {
        switch self {
        case .server(let message): return "Sheet error: \(message)"
        case .notJSON: return "The response was not JSON. Check that the web app access is set to 'Anyone' and that the URL ends with /exec."
        }
    }
}

@MainActor
@Observable
final class SheetsSync {
    var webAppURL: String
    var token: String
    var autoUpload: Bool

    var status: String?
    var lastSync: Date?
    var isBusy = false

    @ObservationIgnored private var uploaded = Set<UUID>()
    @ObservationIgnored private var autoTask: Task<Void, Never>?

    init() {
        webAppURL = UserDefaults.standard.string(forKey: "sheets.url") ?? ""
        token = UserDefaults.standard.string(forKey: "sheets.token") ?? ""
        autoUpload = UserDefaults.standard.bool(forKey: "sheets.auto")
        uploaded = Set(FileStore.load([UUID].self, from: "astra_sheets_uploaded.json") ?? [])
    }

    func saveSettings() {
        UserDefaults.standard.set(webAppURL, forKey: "sheets.url")
        UserDefaults.standard.set(token, forKey: "sheets.token")
        UserDefaults.standard.set(autoUpload, forKey: "sheets.auto")
    }

    var isConfigured: Bool {
        guard let url = URL(string: webAppURL.trimmingCharacters(in: .whitespaces)) else { return false }
        return url.scheme == "https" && !token.isEmpty
    }

    func pendingCount(_ records: [BiometricRecord]) -> Int {
        records.reduce(0) { count, r in count + (uploaded.contains(r.id) ? 0 : 1) }
    }

    func upload(_ records: [BiometricRecord]) async {
        guard isConfigured, let url = URL(string: webAppURL.trimmingCharacters(in: .whitespaces)) else {
            status = "Enter the web app URL (https://…/exec) and token first."
            return
        }
        guard !isBusy else { return }
        let pending = records.filter { !uploaded.contains($0.id) }
        guard !pending.isEmpty else {
            status = "No new records to upload."
            return
        }
        isBusy = true
        defer { isBusy = false }

        var added = 0
        do {
            for start in stride(from: 0, to: pending.count, by: 500) {
                let chunk = Array(pending[start..<min(start + 500, pending.count)])
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 60
                request.httpBody = try JSONCoding.encoder().encode(UploadBody(token: token, records: chunk.map { SheetRow($0) }))

                let (data, _) = try await URLSession.shared.data(for: request)
                guard let response = try? JSONCoding.decoder().decode(UploadResponse.self, from: data) else { throw SyncError.notJSON }
                guard response.ok else { throw SyncError.server(response.error ?? "Unknown error") }
                added += response.added ?? 0
                uploaded.formUnion(chunk.map(\.id))
                FileStore.save(Array(uploaded), to: "astra_sheets_uploaded.json")
            }
            lastSync = Date()
            status = "Upload complete: \(added) new rows added to the sheet."
        } catch {
            status = "Upload failed: \(error.localizedDescription)"
        }
    }

    func pullEdits() async -> [PulledRow]? {
        guard isConfigured, var components = URLComponents(string: webAppURL.trimmingCharacters(in: .whitespaces)) else {
            status = "Enter the web app URL (https://…/exec) and token first."
            return nil
        }
        components.queryItems = [URLQueryItem(name: "token", value: token),
                                 URLQueryItem(name: "editedOnly", value: "1")]
        guard let url = components.url else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let response = try? JSONCoding.decoder().decode(PullResponse.self, from: data) else { throw SyncError.notJSON }
            guard response.ok else { throw SyncError.server(response.error ?? "Unknown error") }
            lastSync = Date()
            return response.rows ?? []
        } catch {
            status = "Download failed: \(error.localizedDescription)"
            return nil
        }
    }

    func scheduleAutoUpload(_ currentRecords: @escaping @MainActor () -> [BiometricRecord]) {
        guard autoUpload, isConfigured, autoTask == nil else { return }
        autoTask = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled {
                await upload(currentRecords())
            }
            autoTask = nil
        }
    }

    func resetUploadHistory() {
        uploaded.removeAll()
        FileStore.save(Array(uploaded), to: "astra_sheets_uploaded.json")
        status = "Upload history cleared. All records will be sent on the next upload."
    }
}

// MARK: - 8. HealthKitManager + BiometricDataManager

@MainActor
@Observable
final class HealthKitManager {
    var isStreaming = false
    var errorMessage: String?

    /// Receives every batch of new or deleted samples.
    @ObservationIgnored var onBatch: (@MainActor ([BiometricRecord], Set<UUID>) -> Void)?

    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for m in MetricKind.allCases {
            if let id = m.hkIdentifier { types.insert(HKQuantityType(id)) }
        }
        types.insert(HKCategoryType(.sleepAnalysis))
        return types
    }

    func start() async {
        guard !isStreaming else { return }
        guard isAvailable else {
            errorMessage = "Health data is not available on this device. Use the suit simulation on the Data tab."
            return
        }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: Self.readTypes)
        } catch {
            errorMessage = "Health data authorization failed: \(error.localizedDescription)"
            return
        }
        // HealthKit does not reveal denied read access; denied types simply return no samples.
        BackgroundHealthMonitor.shared.start()
        isStreaming = true
        errorMessage = nil
        let since = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-15 * 86400)
        for metric in MetricKind.allCases {
            if metric == .sleep {
                tasks.append(Task { await self.streamSleep(since: since) })
            } else {
                tasks.append(Task { await self.streamQuantity(metric, since: since) })
            }
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        isStreaming = false
    }

    func restart() async {
        stop()
        await start()
    }

    /// Long-running anchored query: delivers the last 15 days, then every new sample as it syncs from the Watch.
    private func streamQuantity(_ metric: MetricKind, since: Date) async {
        guard let id = metric.hkIdentifier else { return }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
            anchor: nil
        )
        do {
            for try await update in descriptor.results(for: healthStore) {
                let added = update.addedSamples.map { BiometricRecord(sample: $0, metric: metric) }
                let deleted = Set(update.deletedObjects.map(\.uuid))
                onBatch?(added, deleted)
            }
        } catch {
            if !Task.isCancelled { errorMessage = "\(metric.label) query error: \(error.localizedDescription)" }
        }
    }

    private func streamSleep(since: Date) async {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            anchor: nil
        )
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        do {
            for try await update in descriptor.results(for: healthStore) {
                let added = update.addedSamples
                    .filter { asleep.contains($0.value) }
                    .map { BiometricRecord(sleepSample: $0) }
                let deleted = Set(update.deletedObjects.map(\.uuid))
                onBatch?(added, deleted)
            }
        } catch {
            if !Task.isCancelled { errorMessage = "Sleep query error: \(error.localizedDescription)" }
        }
    }
}

/// Validation, normalization, storage, trend analysis, simulation, manual entry, and sheet sync.
@MainActor
@Observable
final class BiometricDataManager {
    let health = HealthKitManager()
    let store = BiometricStore()
    let sheets = SheetsSync()

    var summaries: [MetricSummary] = []
    var simulating = false
    var deteriorating = false
    var rejectedCount = 0
    var lastRejection: String?
    /// Every rejected or flagged measurement, with the reason. Nothing is silently corrected.
    var issues: [DataIssue] = []

    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?
    @ObservationIgnored private var simTask: Task<Void, Never>?
    @ObservationIgnored private var simTick = 0
    @ObservationIgnored private var worsenTicks = 0

    init() {
        summaries = TrendAnalyzer.summaries(from: store.visibleRecords)
        health.onBatch = { [weak self] added, deleted in self?.receive(added, deleted: deleted) }
    }

    func summary(_ m: MetricKind) -> MetricSummary? { summaries.first { $0.metric == m } }

    /// Single entry point for every data source.
    func receive(_ added: [BiometricRecord], deleted: Set<UUID> = []) {
        let latestAllowed = Date().addingTimeInterval(300)
        var valid: [BiometricRecord] = []
        func reject(_ r: BiometricRecord, _ reason: String) {
            rejectedCount += 1
            lastRejection = "\(r.metric.label) \(fmt(r.value, 1)) \(r.unit) — \(reason)"
            logIssue(r, reason, rejected: true)
        }
        for r in added {
            if !r.value.isFinite {
                reject(r, "not a valid number")
            } else if r.unit != r.metric.unit {
                reject(r, "unit '\(r.unit)' does not match expected '\(r.metric.unit)'; not converted")
            } else if !r.metric.plausibleRange.contains(r.value) {
                reject(r, "outside plausible range \(fmt(r.metric.plausibleRange.lowerBound))–\(fmt(r.metric.plausibleRange.upperBound))")
            } else if r.end > latestAllowed || r.end < r.start {
                reject(r, "inconsistent timestamp")
            } else if r.sourceKind.isSimulated && (store.contains(metric: r.metric, at: r.end, sourceKind: r.sourceKind)
                                                   || valid.contains { $0.metric == r.metric && $0.sourceKind == r.sourceKind && $0.end == r.end }) {
                reject(r, "duplicate timestamp for this source")
            } else {
                if r.sourceKind.isSimulated, let last = store.latestTime(metric: r.metric, sourceKind: r.sourceKind), r.end < last {
                    logIssue(r, "out-of-order timestamp (earlier than the previous reading) — accepted and flagged", rejected: false)
                }
                valid.append(r)
            }
        }
        guard !valid.isEmpty || !deleted.isEmpty else { return }
        store.ingest(valid, deleted: deleted)
        summaries = TrendAnalyzer.summaries(from: store.visibleRecords)
        onUpdate?()
        sheets.scheduleAutoUpload { [weak self] in self?.store.records ?? [] }
    }

    private func logIssue(_ r: BiometricRecord, _ reason: String, rejected: Bool) {
        issues.insert(DataIssue(metric: r.metric.label, value: r.value, unit: r.unit, source: r.sourceName,
                                timestamp: r.end, reason: reason, rejected: rejected), at: 0)
        if issues.count > 300 { issues.removeLast(issues.count - 300) }
    }

    func setMode(_ m: DataMode) {
        guard store.mode != m else { return }
        store.mode = m
        UserDefaults.standard.set(m.rawValue, forKey: "data.mode")
        summaries = TrendAnalyzer.summaries(from: store.visibleRecords)
        onUpdate?()
    }

    func applySheetEdits(_ rows: [PulledRow]) -> Int {
        var edits: [UUID: (value: Double?, note: String?, reliability: Reliability?)] = [:]
        for row in rows {
            guard let id = UUID(uuidString: row.id) else { continue }
            if let v = row.value, let existing = store.records.first(where: { $0.id == id }),
               !existing.metric.plausibleRange.contains(v) {
                rejectedCount += 1
                lastRejection = "Sheet edit \(existing.metric.label) \(fmt(v, 1)) outside plausible range — rejected"
                continue
            }
            edits[id] = (row.value, row.note, row.reliability.flatMap { Reliability(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces)) })
        }
        let applied = store.applyEdits(edits)
        if applied > 0 {
            summaries = TrendAnalyzer.summaries(from: store.visibleRecords)
            onUpdate?()
        }
        return applied
    }

    func snapshot() -> VitalsSnapshot {
        var s = VitalsSnapshot()
        let hrRecord = store.latest(.heartRate, within: 86400)
        s.heartRate = hrRecord?.value
        s.heartRateAt = hrRecord?.end
        s.isSimulated = store.mode == .simulation
        s.restingHR = store.latest(.restingHeartRate, within: 7 * 86400)?.value
        s.restingBaseline = summary(.restingHeartRate)?.baselineMean
        s.hrv = store.latest(.hrv, within: 7 * 86400)?.value
        s.hrvBaseline = summary(.hrv)?.baselineMean
        s.spo2 = store.latest(.spo2, within: 7 * 86400)?.value
        s.respiratoryRate = store.latest(.respiratoryRate, within: 7 * 86400)?.value
        s.bodyTemperature = store.latest(.bodyTemperature, within: 86400)?.value
        s.systolic = store.latest(.systolicBP, within: 6 * 3600)?.value
        s.diastolic = store.latest(.diastolicBP, within: 6 * 3600)?.value
        s.glucose = store.latest(.bloodGlucose, within: 6 * 3600)?.value
        s.sleepHours = summary(.sleep)?.latestValue
        s.hrSeries = store.history(for: .heartRate, since: Date().addingTimeInterval(-86400))
            .map { ChartPoint(date: $0.end, value: $0.value) }
        s.updated = store.lastUpdate ?? Date()
        return s
    }

    @discardableResult
    func logManual(_ values: [MetricKind: Double]) -> Int {
        let now = Date()
        let new = values.map { m, v in
            BiometricRecord(id: UUID(), metric: m, value: v, unit: m.unit, start: now, end: now,
                            sourceName: "Manual entry", sourceKind: .manual, deviceModel: nil,
                            context: nil, reliability: .medium, note: nil)
        }
        let before = rejectedCount
        receive(new)
        return new.count - (rejectedCount - before)
    }

    // Suit simulation — demonstrates that a different wearable feeds the same pipeline.

    func startSimulation() {
        stopSimulation()
        setMode(.simulation)
        simulating = true
        seedSimulatedHistoryIfNeeded()
        simTask = Task {
            while !Task.isCancelled {
                simulateTick()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopSimulation() {
        simTask?.cancel()
        simTask = nil
        simulating = false
    }

    func clearSimulated() {
        stopSimulation()
        deteriorating = false
        store.remove { $0.sourceKind.isSimulated }
        summaries = TrendAnalyzer.summaries(from: store.visibleRecords)
        onUpdate?()
    }

    private func simRecord(_ m: MetricKind, _ value: Double, at date: Date, note: String? = nil) -> BiometricRecord {
        BiometricRecord(id: UUID(), metric: m, value: value, unit: m.unit, start: date, end: date,
                        sourceName: "ASTRA Suit Simulator", sourceKind: .simulatedSuit, deviceModel: "Simulated suit",
                        context: nil, reliability: .medium, note: note)
    }

    private func seedSimulatedHistoryIfNeeded() {
        let startToday = Calendar.current.startOfDay(for: Date())
        guard !store.records.contains(where: { $0.sourceKind == .simulatedSuit && $0.end < startToday }) else { return }
        var seed: [BiometricRecord] = []
        for day in 1...14 {
            let dayStart = startToday.addingTimeInterval(Double(-day) * 86400)
            for hour in stride(from: 0, to: 24, by: 2) {
                let t = dayStart.addingTimeInterval(Double(hour) * 3600)
                let k = Double(day * 24 + hour)
                seed.append(simRecord(.heartRate, 66 + 4 * sin(k * 0.7), at: t, note: "Simulated baseline"))
                seed.append(simRecord(.hrv, 45 + 5 * sin(k * 1.1), at: t, note: "Simulated baseline"))
                seed.append(simRecord(.spo2, 97.5 + 0.7 * sin(k * 0.9), at: t, note: "Simulated baseline"))
                seed.append(simRecord(.respiratoryRate, 14 + sin(k * 1.3), at: t, note: "Simulated baseline"))
                seed.append(simRecord(.bodyTemperature, 36.6 + 0.15 * sin(k * 0.5), at: t, note: "Simulated baseline"))
            }
            seed.append(simRecord(.restingHeartRate, 57 + 2 * sin(Double(day)),
                                  at: dayStart.addingTimeInterval(8 * 3600), note: "Simulated baseline"))
            let wake = dayStart.addingTimeInterval(7 * 3600)
            let hours = 7.2 + 0.5 * sin(Double(day) * 0.8)
            seed.append(BiometricRecord(id: UUID(), metric: .sleep, value: hours, unit: MetricKind.sleep.unit,
                                        start: wake.addingTimeInterval(-hours * 3600), end: wake,
                                        sourceName: "ASTRA Suit Simulator", sourceKind: .simulatedSuit,
                                        deviceModel: "Simulated suit", context: nil, reliability: .medium,
                                        note: "Simulated baseline"))
        }
        receive(seed)
    }

    /// Every 3 s. With deterioration on, the pattern resembles hemorrhage/shock (HR↑ HRV↓ SpO₂↓ RR↑).
    private func simulateTick() {
        let now = Date()
        let t = Double(simTick)
        if deteriorating { worsenTicks += 1 } else { worsenTicks = 0 }
        let w = Double(min(worsenTicks, 60))

        var batch = [
            simRecord(.heartRate, 68 + 3 * sin(t * 0.4) + w * 1.5, at: now),
            simRecord(.spo2, 98 + 0.4 * sin(t * 0.7) - w * 0.15, at: now),
            simRecord(.respiratoryRate, 14 + sin(t * 0.5) + w * 0.25, at: now)
        ]
        if simTick % 5 == 0 { batch.append(simRecord(.hrv, max(46 + 3 * sin(t) - w * 0.6, 5), at: now)) }
        if simTick % 10 == 0 { batch.append(simRecord(.bodyTemperature, 36.7 + 0.05 * sin(t), at: now)) }
        if simTick % 5 == 0 {
            batch.append(simRecord(.systolicBP, 118 - w * 0.8, at: now))
            batch.append(simRecord(.diastolicBP, 76 - w * 0.4, at: now))
        }
        simTick += 1
        receive(batch)
    }
}

// MARK: - 9. MedicalKnowledgeBase

nonisolated enum EvidenceLevel: String, Codable, CaseIterable {
    case A, B, C, D

    var label: String {
        switch self {
        case .A: return "A — Guideline / systematic review"
        case .B: return "B — Peer-reviewed study"
        case .C: return "C — Expert consensus / agency protocol summary"
        case .D: return "D — Built-in placeholder / unverified"
        }
    }

    var short: String { "Evidence \(rawValue)" }
}

nonisolated enum KnowledgeCategory: String, Codable, CaseIterable {
    case physiology, emergencyProtocol, firstAid, spaceMedicine, pharmacology, environment, other

    var label: String {
        switch self {
        case .physiology: return "Physiology / normal ranges"
        case .emergencyProtocol: return "Emergency protocol"
        case .firstAid: return "First aid"
        case .spaceMedicine: return "Space medicine"
        case .pharmacology: return "Medication reference"
        case .environment: return "Environment"
        case .other: return "Other"
        }
    }
}

/// Who may carry out an action.
nonisolated enum AuthorityLevel: Int, Codable, CaseIterable, Comparable {
    case crew = 0, crewMedicalOfficer = 1, flightSurgeon = 2

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .crew: return "Any crew member"
        case .crewMedicalOfficer: return "Crew Medical Officer"
        case .flightSurgeon: return "Requires flight surgeon / CMO authorization"
        }
    }

    var short: String {
        switch self {
        case .crew: return "CREW"
        case .crewMedicalOfficer: return "CMO"
        case .flightSurgeon: return "AUTH REQUIRED"
        }
    }
}

/// One source document. Teams import their own sources as JSON; missing fields fall back to safe defaults.
nonisolated struct KnowledgeDocument: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var category: KnowledgeCategory
    var evidence: EvidenceLevel
    var citation: String
    var url: String?
    var keywords: [String]
    var summary: String
    var guidance: [String]
    var contraindications: [String]
    var escalation: [String]
    var isBuiltIn: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, category, evidence, citation, url, keywords, summary, guidance, contraindications, escalation, isBuiltIn
    }

    init(id: String, title: String, category: KnowledgeCategory, evidence: EvidenceLevel, citation: String,
         url: String? = nil, keywords: [String], summary: String, guidance: [String] = [],
         contraindications: [String] = [], escalation: [String] = [], isBuiltIn: Bool = false) {
        self.id = id; self.title = title; self.category = category; self.evidence = evidence
        self.citation = citation; self.url = url; self.keywords = keywords; self.summary = summary
        self.guidance = guidance; self.contraindications = contraindications; self.escalation = escalation
        self.isBuiltIn = isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled source"
        id = (try? c.decode(String.self, forKey: .id)) ?? title.lowercased().replacingOccurrences(of: " ", with: "-")
        category = (try? c.decode(KnowledgeCategory.self, forKey: .category)) ?? .other
        evidence = (try? c.decode(EvidenceLevel.self, forKey: .evidence)) ?? .D
        citation = (try? c.decode(String.self, forKey: .citation)) ?? "Citation not provided"
        url = try? c.decode(String.self, forKey: .url)
        keywords = ((try? c.decode([String].self, forKey: .keywords)) ?? []).map { $0.lowercased() }
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        guidance = (try? c.decode([String].self, forKey: .guidance)) ?? []
        contraindications = (try? c.decode([String].self, forKey: .contraindications)) ?? []
        escalation = (try? c.decode([String].self, forKey: .escalation)) ?? []
        isBuiltIn = (try? c.decode(Bool.self, forKey: .isBuiltIn)) ?? false
    }
}

nonisolated struct MedicalSupply: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var category: String
    var location: String?
    var quantity: Int?
    var notes: String?
    var authority: AuthorityLevel

    enum CodingKeys: String, CodingKey { case id, name, category, location, quantity, notes, authority }

    init(id: String, name: String, category: String, location: String? = nil, quantity: Int? = nil,
         notes: String? = nil, authority: AuthorityLevel = .crew) {
        self.id = id; self.name = name; self.category = category; self.location = location
        self.quantity = quantity; self.notes = notes; self.authority = authority
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Unnamed item"
        id = (try? c.decode(String.self, forKey: .id)) ?? name.lowercased()
        category = (try? c.decode(String.self, forKey: .category)) ?? "General"
        location = try? c.decode(String.self, forKey: .location)
        quantity = try? c.decode(Int.self, forKey: .quantity)
        notes = try? c.decode(String.self, forKey: .notes)
        if let a = try? c.decode(AuthorityLevel.self, forKey: .authority) {
            authority = a
        } else if let s = try? c.decode(String.self, forKey: .authority) {
            authority = s.lowercased().contains("surgeon") || s.lowercased().contains("auth") ? .flightSurgeon
                : s.lowercased().contains("cmo") || s.lowercased().contains("medical") ? .crewMedicalOfficer : .crew
        } else {
            authority = .crew
        }
    }
}

nonisolated struct KnowledgeBundle: Codable {
    var documents: [KnowledgeDocument]?
    var supplies: [MedicalSupply]?
}

nonisolated struct SourceRef: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let citation: String
    let evidence: EvidenceLevel
    let url: String?
    let isBuiltIn: Bool
}

nonisolated extension KnowledgeDocument {
    var ref: SourceRef { SourceRef(id: id, title: title, citation: citation, evidence: evidence, url: url, isBuiltIn: isBuiltIn) }
}

@MainActor
@Observable
final class MedicalKnowledgeBase {
    private(set) var documents: [KnowledgeDocument] = []
    private(set) var supplies: [MedicalSupply] = []
    var message: String?

    init() {
        let saved = FileStore.load(KnowledgeBundle.self, from: "astra_knowledge.json")
        let imported = saved?.documents ?? []
        documents = Self.builtInDocuments.filter { b in !imported.contains { $0.id == b.id } } + imported
        if let s = saved?.supplies, !s.isEmpty { supplies = s } else { supplies = Self.exampleKit }
    }

    var importedCount: Int { documents.filter { !$0.isBuiltIn }.count }
    var usingExampleKit: Bool { supplies.first?.id == Self.exampleKit.first?.id && supplies.count == Self.exampleKit.count }

    func document(_ id: String) -> KnowledgeDocument? { documents.first { $0.id == id } }

    /// Imports {"documents":[…], "supplies":[…]}, or a bare array of documents.
    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            var bundle: KnowledgeBundle
            if let b = try? JSONCoding.decoder().decode(KnowledgeBundle.self, from: data), b.documents != nil || b.supplies != nil {
                bundle = b
            } else {
                bundle = KnowledgeBundle(documents: try JSONCoding.decoder().decode([KnowledgeDocument].self, from: data), supplies: nil)
            }
            let newDocs = (bundle.documents ?? []).map { d -> KnowledgeDocument in
                var d = d
                d.isBuiltIn = false
                return d
            }
            var existing = documents.filter { !$0.isBuiltIn }
            for d in newDocs {
                existing.removeAll { $0.id == d.id }
                existing.append(d)
            }
            if let s = bundle.supplies, !s.isEmpty { supplies = s }
            documents = Self.builtInDocuments.filter { b in !existing.contains { $0.id == b.id } } + existing
            bundle.documents = existing
            bundle.supplies = supplies
            FileStore.save(bundle, to: "astra_knowledge.json")
            message = "Imported \(newDocs.count) documents\(bundle.supplies.map { ", \($0.count) supply items" } ?? "")."
        } catch {
            message = "Import failed: \(error.localizedDescription). Check the JSON format (see template)."
        }
    }

    func resetImported() {
        documents = Self.builtInDocuments
        supplies = Self.exampleKit
        FileStore.save(KnowledgeBundle(documents: [], supplies: []), to: "astra_knowledge.json")
        message = "Imported sources removed; built-in placeholders and example kit restored."
    }

    /// Keyword retrieval. Score = keyword hits ×3 + title word hits ×2 + summary hits ×1, weighted by evidence.
    func retrieve(_ terms: [String], limit: Int = 5) -> [KnowledgeDocument] {
        let query = Set(terms.map { $0.lowercased() }.filter { $0.count >= 3 })
        guard !query.isEmpty else { return [] }
        let scored: [(KnowledgeDocument, Double)] = documents.map { d in
            var score = 0.0
            let title = d.title.lowercased()
            let summary = d.summary.lowercased()
            for q in query {
                if d.keywords.contains(where: { $0 == q || $0.contains(q) || q.contains($0) }) { score += 3 }
                if title.contains(q) { score += 2 }
                if summary.contains(q) { score += 1 }
            }
            let weight: Double
            switch d.evidence {
            case .A: weight = 1.3
            case .B: weight = 1.2
            case .C: weight = 1.1
            case .D: weight = 1.0
            }
            return (d, score * weight * (d.isBuiltIn ? 0.9 : 1.0))
        }
        return scored.filter { $0.1 >= 3 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Fuzzy match of an item name against the onboard inventory.
    func supply(matching name: String) -> MedicalSupply? {
        let n = name.lowercased()
        return supplies.first { s in
            let sn = s.name.lowercased()
            return sn == n || sn.contains(n) || n.contains(sn)
                || sn.split(separator: " ").contains { $0.count > 4 && n.contains($0) }
        }
    }

    static let templateJSON = """
    {
      "documents": [
        {
          "id": "nasa-hemorrhage-protocol",
          "title": "Hemorrhage control protocol",
          "category": "emergencyProtocol",
          "evidence": "C",
          "citation": "Full citation exactly as it appears in your source",
          "url": "https://…",
          "keywords": ["bleeding", "hemorrhage", "tourniquet", "pressure"],
          "summary": "Two to four sentences summarizing what the source says.",
          "guidance": ["Step the source recommends", "Next step"],
          "contraindications": ["When the source says not to do this"],
          "escalation": ["When the source says to escalate"]
        }
      ],
      "supplies": [
        { "id": "tq-1", "name": "Tourniquet", "category": "Hemorrhage control", "location": "Medical kit A", "quantity": 2, "authority": "crew" },
        { "id": "epi-1", "name": "Epinephrine auto-injector", "category": "Medication", "location": "Medical kit B", "quantity": 2, "authority": "crewMedicalOfficer", "notes": "Dose per onboard protocol" }
      ]
    }
    """

    /// Built-in placeholders: general first-aid principles so the app works before team sources are imported.
    /// They carry no external citation and are marked Evidence D. Replace them by importing documents with the same id.
    static let builtInDocuments: [KnowledgeDocument] = [
        KnowledgeDocument(id: "builtin-hemorrhage", title: "External hemorrhage control (general principles)", category: .firstAid, evidence: .D,
                          citation: "ASTRA built-in summary — no external citation. Replace with team-provided protocol.",
                          keywords: ["bleeding", "hemorrhage", "blood", "wound", "laceration", "amputation", "tourniquet", "pressure", "shock"],
                          summary: "Control life-threatening external bleeding first: firm direct pressure, wound packing with hemostatic or plain gauze for junctional or deep wounds, and a tourniquet proximal to a limb wound when pressure fails or the limb is amputated.",
                          guidance: ["Apply firm direct pressure", "Pack deep wounds", "Tourniquet above limb wound if pressure fails", "Record tourniquet time"],
                          contraindications: ["Do not remove a tourniquet once applied without medical direction"],
                          escalation: ["Bleeding not controlled", "Signs of shock"], isBuiltIn: true),
        KnowledgeDocument(id: "builtin-bls", title: "Unresponsive casualty / basic life support (general principles)", category: .emergencyProtocol, evidence: .D,
                          citation: "ASTRA built-in summary — no external citation. Replace with team-provided protocol.",
                          keywords: ["unresponsive", "cardiac arrest", "cpr", "aed", "not breathing", "collapse", "pulse"],
                          summary: "If the casualty is unresponsive and not breathing normally, call for help, start chest compressions, and attach a defibrillator as soon as available. In microgravity the casualty and rescuer must be restrained against a rigid surface.",
                          guidance: ["Check response and breathing", "Start compressions", "Attach defibrillator", "Restrain casualty and rescuer in microgravity"],
                          escalation: ["Any unresponsive casualty"], isBuiltIn: true),
        KnowledgeDocument(id: "builtin-hypoxia", title: "Hypoxia and breathing difficulty (general principles)", category: .physiology, evidence: .D,
                          citation: "ASTRA built-in summary — no external citation. Replace with team-provided protocol.",
                          keywords: ["hypoxia", "oxygen", "spo2", "breathing", "shortness of breath", "dyspnea", "cyanosis", "depressurization"],
                          summary: "Low oxygen saturation with breathing difficulty requires checking the atmosphere first, then supplemental oxygen and a position that eases breathing. Persistent low saturation despite oxygen is an emergency.",
                          guidance: ["Verify cabin atmosphere", "Supplemental oxygen", "Sitting-up posture where gravity exists"],
                          escalation: ["SpO₂ remains low on oxygen", "Exhaustion or confusion"], isBuiltIn: true),
        KnowledgeDocument(id: "builtin-stroke", title: "Sudden neurological deficit (general principles)", category: .emergencyProtocol, evidence: .D,
                          citation: "ASTRA built-in summary — no external citation. Replace with team-provided protocol.",
                          keywords: ["stroke", "weakness", "face droop", "speech", "confusion", "seizure", "head injury", "neurological"],
                          summary: "Sudden one-sided weakness, facial droop, or speech difficulty may indicate stroke or intracranial bleeding. Record the time symptoms began, check glucose, and escalate immediately.",
                          guidance: ["Record symptom onset time", "FAST check", "Check glucose", "Nothing by mouth"],
                          escalation: ["Any new focal deficit"], isBuiltIn: true),
        KnowledgeDocument(id: "builtin-chest-pain", title: "Chest pain (general principles)", category: .emergencyProtocol, evidence: .D,
                          citation: "ASTRA built-in summary — no external citation. Replace with team-provided protocol.",
                          keywords: ["chest pain", "chest pressure", "palpitations", "cardiac", "pneumothorax"],
                          summary: "New chest pain may be cardiac, pulmonary, or musculoskeletal. Rest, monitor rhythm and oxygen, obtain an ECG if available, and escalate. Medication decisions follow onboard protocol and flight surgeon direction.",
                          guidance: ["Stop activity", "Monitor HR/SpO₂", "ECG if available"],
                          escalation: ["Pain persists", "Abnormal rhythm", "Low blood pressure"], isBuiltIn: true),
        KnowledgeDocument(id: "builtin-fracture", title: "Suspected fracture or joint injury (general principles)", category: .firstAid, evidence: .D,
                          citation: "ASTRA built-in summary — no external citation. Replace with team-provided protocol.",
                          keywords: ["fracture", "broken", "deformity", "sprain", "dislocation", "splint", "swelling"],
                          summary: "Immobilize the injured part in the position found using a splint, check circulation and sensation beyond the injury before and after splinting, and control pain per onboard protocol.",
                          guidance: ["Immobilize", "Check distal pulse and sensation", "Cold pack if available"],
                          escalation: ["Loss of distal pulse", "Open fracture"], isBuiltIn: true),
        KnowledgeDocument(id: "builtin-burn", title: "Thermal or chemical burn (general principles)", category: .firstAid, evidence: .D,
                          citation: "ASTRA built-in summary — no external citation. Replace with team-provided protocol.",
                          keywords: ["burn", "scald", "chemical", "fire", "smoke", "blister"],
                          summary: "Stop the burning process, cool thermal burns with clean water, irrigate chemical burns, then cover loosely with a clean non-adherent dressing. Water handling in microgravity requires containment.",
                          guidance: ["Remove from source", "Cool or irrigate", "Cover loosely"],
                          escalation: ["Burns to face, airway, hands, or large area", "Smoke inhalation"], isBuiltIn: true),
        KnowledgeDocument(id: "builtin-eye", title: "Eye foreign body or chemical exposure (general principles)", category: .firstAid, evidence: .D,
                          citation: "ASTRA built-in summary — no external citation. Replace with team-provided protocol.",
                          keywords: ["eye", "vision", "foreign body", "debris", "irrigation", "chemical"],
                          summary: "Floating debris is a common eye hazard in microgravity. Do not rub; irrigate with the eyewash kit and escalate if vision changes or pain persists.",
                          guidance: ["Do not rub", "Irrigate"],
                          escalation: ["Vision change", "Persistent pain"], isBuiltIn: true),
        KnowledgeDocument(id: "builtin-allergy", title: "Severe allergic reaction (general principles)", category: .emergencyProtocol, evidence: .D,
                          citation: "ASTRA built-in summary — no external citation. Replace with team-provided protocol.",
                          keywords: ["allergy", "allergic", "anaphylaxis", "hives", "swelling", "wheeze", "throat"],
                          summary: "Swelling of the face or throat, wheeze, or collapse after an exposure suggests anaphylaxis. Epinephrine is the first-line medication; dose and route follow the onboard protocol.",
                          guidance: ["Remove trigger", "Epinephrine per onboard protocol", "Oxygen", "Monitor airway"],
                          escalation: ["Any airway or breathing involvement"], isBuiltIn: true),
        KnowledgeDocument(id: "builtin-dcs", title: "Decompression sickness / barotrauma (general principles)", category: .spaceMedicine, evidence: .D,
                          citation: "ASTRA built-in summary — no external citation. Replace with team-provided protocol.",
                          keywords: ["decompression", "eva", "spacewalk", "joint pain", "bends", "pressure", "ear", "sinus", "barotrauma"],
                          summary: "Joint pain, skin changes, or neurological symptoms after an EVA or pressure change may be decompression sickness. Treatment centers on oxygen and repressurization per protocol.",
                          guidance: ["Oxygen", "Report EVA/pressure history", "Repressurization per protocol"],
                          escalation: ["Neurological symptoms", "Breathing symptoms"], isBuiltIn: true),
        KnowledgeDocument(id: "builtin-orthostatic", title: "Orthostatic intolerance after gravity transition (general principles)", category: .spaceMedicine, evidence: .D,
                          citation: "ASTRA built-in summary — no external citation. Replace with team-provided protocol.",
                          keywords: ["dizziness", "lightheaded", "fainting", "syncope", "landing", "gravity", "orthostatic"],
                          summary: "After adaptation to microgravity, standing in gravity can cause lightheadedness or fainting from reduced blood return. Lie the person down with legs raised, give fluids per protocol, and stand up gradually.",
                          guidance: ["Lie down, legs raised", "Fluids per protocol", "Gradual standing"],
                          escalation: ["Fainting with injury", "Persistent low blood pressure"], isBuiltIn: true),
        KnowledgeDocument(id: "convertino-2020-crm", title: "Compensatory reserve monitoring with wearable sensors", category: .physiology, evidence: .B,
                          citation: "Convertino VA, et al. Wearable sensors incorporating compensatory reserve measurement for advancing physiological monitoring in critically injured trauma patients. Sensors. 2020;20(22):6413.",
                          url: "https://doi.org/10.3390/s20226413",
                          keywords: ["hemorrhage", "shock", "compensatory reserve", "heart rate", "wearable", "blood loss"],
                          summary: "Heart rate and blood pressure can remain near normal during early blood loss because of compensation; waveform-based compensatory reserve measurement detected decline earlier than standard vital signs.",
                          isBuiltIn: true)
    ]

    /// Example kit so the guidance engine can reference real items. Replace by importing your mission's inventory.
    static let exampleKit: [MedicalSupply] = [
        MedicalSupply(id: "kit-gloves", name: "Exam gloves", category: "Protection", location: "Example kit"),
        MedicalSupply(id: "kit-gauze", name: "Gauze pads", category: "Hemorrhage control", location: "Example kit"),
        MedicalSupply(id: "kit-hemostatic", name: "Hemostatic gauze", category: "Hemorrhage control", location: "Example kit"),
        MedicalSupply(id: "kit-pressure", name: "Pressure bandage", category: "Hemorrhage control", location: "Example kit"),
        MedicalSupply(id: "kit-tq", name: "Tourniquet", category: "Hemorrhage control", location: "Example kit"),
        MedicalSupply(id: "kit-o2", name: "Oxygen mask and supply", category: "Respiratory", location: "Example kit"),
        MedicalSupply(id: "kit-bvm", name: "Bag-valve mask", category: "Respiratory", location: "Example kit", authority: .crewMedicalOfficer),
        MedicalSupply(id: "kit-aed", name: "Defibrillator (AED)", category: "Cardiac", location: "Example kit"),
        MedicalSupply(id: "kit-restraint", name: "Crew restraint system", category: "Microgravity", location: "Example kit"),
        MedicalSupply(id: "kit-splint", name: "Moldable splint", category: "Orthopedic", location: "Example kit"),
        MedicalSupply(id: "kit-collar", name: "Cervical collar", category: "Orthopedic", location: "Example kit"),
        MedicalSupply(id: "kit-burn", name: "Non-adherent burn dressing", category: "Burns", location: "Example kit"),
        MedicalSupply(id: "kit-eyewash", name: "Eye irrigation kit", category: "Eye", location: "Example kit"),
        MedicalSupply(id: "kit-thermo", name: "Thermometer", category: "Diagnostics", location: "Example kit"),
        MedicalSupply(id: "kit-bp", name: "Blood pressure cuff", category: "Diagnostics", location: "Example kit"),
        MedicalSupply(id: "kit-glucose", name: "Glucometer", category: "Diagnostics", location: "Example kit"),
        MedicalSupply(id: "kit-ecg", name: "ECG monitor", category: "Diagnostics", location: "Example kit", authority: .crewMedicalOfficer),
        MedicalSupply(id: "kit-ultrasound", name: "Ultrasound", category: "Diagnostics", location: "Example kit", authority: .crewMedicalOfficer),
        MedicalSupply(id: "kit-cold", name: "Cold pack", category: "General", location: "Example kit"),
        MedicalSupply(id: "kit-epi", name: "Epinephrine auto-injector", category: "Medication", location: "Example kit",
                      notes: "Dose per onboard protocol", authority: .crewMedicalOfficer),
        MedicalSupply(id: "kit-oral-glucose", name: "Oral glucose", category: "Medication", location: "Example kit"),
        MedicalSupply(id: "kit-analgesic", name: "Analgesics (per onboard protocol)", category: "Medication", location: "Example kit",
                      notes: "Selection and dose per flight surgeon", authority: .crewMedicalOfficer),
        MedicalSupply(id: "kit-fluids", name: "Oral rehydration fluids", category: "Fluids", location: "Example kit"),
        MedicalSupply(id: "kit-iv", name: "IV fluid kit", category: "Fluids", location: "Example kit",
                      notes: "Invasive — requires authorization", authority: .flightSurgeon)
    ]
}

// MARK: - 10. Clinical case model

nonisolated enum Urgency: Int, Codable, CaseIterable, Comparable {
    case normal = 0, observe, caution, urgent, emergency

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .observe: return "Observe"
        case .caution: return "Caution"
        case .urgent: return "Urgent"
        case .emergency: return "Emergency"
        }
    }

    var action: String {
        switch self {
        case .normal: return "Continue routine monitoring."
        case .observe: return "Re-check within the hour and note symptoms."
        case .caution: return "Reduce workload, reassess within 15 minutes, inform the Crew Medical Officer."
        case .urgent: return "Begin guided care now and contact the flight surgeon as soon as communications allow."
        case .emergency: return "Life-threatening: start immediate actions and alert all crew."
        }
    }

    var color: Color {
        switch self {
        case .normal: return .green
        case .observe: return .teal
        case .caution: return .yellow
        case .urgent: return .orange
        case .emergency: return .red
        }
    }
}

nonisolated enum BodyRegion: String, Codable, CaseIterable, Identifiable {
    case head, eyes, neck, chest, abdomen, back, pelvis, leftArm, rightArm, leftLeg, rightLeg, skin, wholeBody
    var id: String { rawValue }
    var label: String {
        switch self {
        case .head: return "Head"
        case .eyes: return "Eyes"
        case .neck: return "Neck"
        case .chest: return "Chest"
        case .abdomen: return "Abdomen"
        case .back: return "Back / spine"
        case .pelvis: return "Pelvis"
        case .leftArm: return "Left arm"
        case .rightArm: return "Right arm"
        case .leftLeg: return "Left leg"
        case .rightLeg: return "Right leg"
        case .skin: return "Skin"
        case .wholeBody: return "Whole body"
        }
    }
    var isLimb: Bool { [.leftArm, .rightArm, .leftLeg, .rightLeg].contains(self) }
    var isJunctionalOrTorso: Bool { [.neck, .chest, .abdomen, .pelvis, .back].contains(self) }
}

nonisolated enum BleedingStatus: String, Codable, CaseIterable, Identifiable {
    case none, minor, controlled, uncontrolled, severe
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .minor: return "Minor / oozing"
        case .controlled: return "Controlled"
        case .uncontrolled: return "Not controlled"
        case .severe: return "Severe / spurting / amputation"
        }
    }
}

/// AVPU scale.
nonisolated enum Consciousness: String, Codable, CaseIterable, Identifiable {
    case alert, voice, pain, unresponsive
    var id: String { rawValue }
    var label: String {
        switch self {
        case .alert: return "Alert"
        case .voice: return "Responds to voice"
        case .pain: return "Responds to pain only"
        case .unresponsive: return "Unresponsive"
        }
    }
}

nonisolated enum ClinicalFinding: String, Codable, CaseIterable, Identifiable {
    case notBreathingNormally, breathingDifficulty, chestPain, palpitations
    case oneSidedWeakness, speechDifficulty, confusion, seizure, severeHeadache, visionChange
    case dizziness, fainted, nauseaVomiting, abdominalPain
    case suspectedFracture, headOrNeckInjury, burn, eyeExposure, chemicalExposure, smokeExposure
    case allergicReaction, jointPainAfterPressureChange, earSinusPain, feverChills, numbnessTingling, extremeFatigue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notBreathingNormally: return "Not breathing normally"
        case .breathingDifficulty: return "Breathing difficulty"
        case .chestPain: return "Chest pain / pressure"
        case .palpitations: return "Palpitations"
        case .oneSidedWeakness: return "One-sided weakness / face droop"
        case .speechDifficulty: return "Speech difficulty"
        case .confusion: return "Confusion"
        case .seizure: return "Seizure"
        case .severeHeadache: return "Severe headache"
        case .visionChange: return "Vision change"
        case .dizziness: return "Dizziness / lightheaded"
        case .fainted: return "Fainted"
        case .nauseaVomiting: return "Nausea / vomiting"
        case .abdominalPain: return "Abdominal pain"
        case .suspectedFracture: return "Suspected fracture / deformity"
        case .headOrNeckInjury: return "Head or neck impact"
        case .burn: return "Burn"
        case .eyeExposure: return "Eye debris / exposure"
        case .chemicalExposure: return "Chemical / toxic exposure"
        case .smokeExposure: return "Smoke / fire exposure"
        case .allergicReaction: return "Allergic reaction (hives, swelling)"
        case .jointPainAfterPressureChange: return "Joint pain after EVA / pressure change"
        case .earSinusPain: return "Ear or sinus pain"
        case .feverChills: return "Fever / chills"
        case .numbnessTingling: return "Numbness / tingling"
        case .extremeFatigue: return "Extreme fatigue"
        }
    }

    var keywords: [String] {
        label.lowercased().components(separatedBy: CharacterSet(charactersIn: " /(),")).filter { $0.count >= 3 }
    }
}

nonisolated struct CaseInput: Codable, Hashable {
    var description: String = ""
    var regions: Set<BodyRegion> = []
    var findings: Set<ClinicalFinding> = []
    var bleeding: BleedingStatus = .none
    var consciousness: Consciousness = .alert
    var painScore: Int?
    var mechanism: String = ""
    var onsetMinutesAgo: Int?
    var createdAt = Date()

    var isEmpty: Bool {
        description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && regions.isEmpty && findings.isEmpty
            && bleeding == .none && consciousness == .alert && painScore == nil && mechanism.isEmpty
    }

    var bleedingMajor: Bool { bleeding == .uncontrolled || bleeding == .severe }

    var text: String {
        var parts: [String] = []
        if !description.isEmpty { parts.append("Description: \(description)") }
        if !mechanism.isEmpty { parts.append("Mechanism: \(mechanism)") }
        if !regions.isEmpty { parts.append("Regions: \(regions.map(\.label).sorted().joined(separator: ", "))") }
        if !findings.isEmpty { parts.append("Findings: \(findings.map(\.label).sorted().joined(separator: ", "))") }
        if bleeding != .none { parts.append("Bleeding: \(bleeding.label)") }
        parts.append("Consciousness: \(consciousness.label)")
        if let painScore { parts.append("Pain \(painScore)/10") }
        if let onsetMinutesAgo { parts.append("Onset \(onsetMinutesAgo) min ago") }
        return parts.joined(separator: ". ")
    }
}

nonisolated enum EvidenceBasis: String, Codable {
    case measurement, protocolRule, knowledgeBase, aiInference

    var label: String {
        switch self {
        case .measurement: return "Measured data"
        case .protocolRule: return "Built-in safety protocol"
        case .knowledgeBase: return "Knowledge-base source"
        case .aiInference: return "AI inference — verify"
        }
    }
}

nonisolated enum Likelihood: String, Codable {
    case higher, possible, lower, unclear
    var label: String {
        switch self {
        case .higher: return "More consistent"
        case .possible: return "Possible"
        case .lower: return "Less consistent"
        case .unclear: return "Unclear"
        }
    }
}

nonisolated struct GuidanceStep: Codable, Identifiable, Hashable {
    var id = UUID()
    var phase: String
    var action: String
    var purpose: String
    var equipment: [String] = []
    var precautions: [String] = []
    var expectedObservations: [String] = []
    var reassessIf: [String] = []
    var ifUnsuccessful: String?
    var authority: AuthorityLevel = .crew
    var basis: EvidenceBasis = .protocolRule
    var sourceIDs: [String] = []
    var timeCritical = false
}

nonisolated struct Differential: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var likelihood: Likelihood
    var supporting: [String]
    var against: [String]
    var basis: EvidenceBasis
    var sourceIDs: [String] = []
}

nonisolated struct InterventionRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var time = Date()
    var action: String
    var result: String
}

nonisolated struct CaseUpdate: Codable, Identifiable, Hashable {
    var id = UUID()
    var time = Date()
    var note: String
}

nonisolated enum CommsStatus: String, Codable, CaseIterable, Identifiable {
    case available, delayed, unavailable
    var id: String { rawValue }
    var label: String {
        switch self {
        case .available: return "Ground available"
        case .delayed: return "Delayed communication"
        case .unavailable: return "No ground contact"
        }
    }
}

nonisolated enum MedicalTraining: String, Codable, CaseIterable, Identifiable {
    case none, firstAid, crewMedicalOfficer, physician
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "No medical training"
        case .firstAid: return "First aid"
        case .crewMedicalOfficer: return "Crew Medical Officer"
        case .physician: return "Physician"
        }
    }
    var authority: AuthorityLevel {
        switch self {
        case .none, .firstAid: return .crew
        case .crewMedicalOfficer, .physician: return .crewMedicalOfficer
        }
    }
}

nonisolated struct AstronautProfile: Codable, Hashable {
    var name = "Crew member"
    var role = "Mission specialist"
    var age: Int?
    var allergies = ""
    var conditions = ""
    var medications = ""
    var responderTraining: MedicalTraining = .firstAid
    var notes = ""

    var text: String {
        var p = ["\(name), \(role)"]
        if let age { p.append("age \(age)") }
        if !allergies.isEmpty { p.append("allergies: \(allergies)") }
        if !conditions.isEmpty { p.append("conditions: \(conditions)") }
        if !medications.isEmpty { p.append("medications: \(medications)") }
        p.append("responder training: \(responderTraining.label)")
        return p.joined(separator: "; ")
    }
}

/// Complete guidance output. Sections A–F of the Guidance Engine map onto these fields.
nonisolated struct ClinicalReport: Codable, Identifiable, Hashable {
    var id = UUID()
    var createdAt = Date()
    var input: CaseInput
    var urgency: Urgency
    var urgencyRationale: [String]
    var summary: String
    // F. Uncertainty management
    var confirmed: [String]
    var differentials: [Differential]
    var evidenceSupported: [String]
    var uncertain: [String]
    var needsQualifiedHelp: [String]
    // A. Assessment
    var missingInformation: [String]
    var assessFirst: [String]
    // C. Sequential guidance
    var steps: [GuidanceStep]
    // D. Reassessment
    var monitoring: [String]
    var improvingSigns: [String]
    var deterioratingSigns: [String]
    var reassessInMinutes: Int
    // B. Decision support
    var escalation: [String]
    var contraindications: [String]
    var supplies: [String]
    // E. Mission awareness
    var missionNotes: [String]
    var sources: [SourceRef]
    var trend: String?
    var aiUsed: Bool
    var aiNote: String
    var safetyNotes: [String]
    var vitalsHR: Double?
    var vitalsSpO2: Double?
    /// Where the input data came from (live sensors or a named simulation source) and the exact vitals used.
    var dataSource: String?
    var inputSnapshot: String?
}

// MARK: - 11. Safety validator

nonisolated enum SafetyValidator {
    static let dosePlaceholder = "[dose per onboard protocol / flight surgeon]"

    private static let doseRegex = try? NSRegularExpression(
        pattern: #"\b\d+([.,]\d+)?\s?(mg|mcg|µg|ug|g|grams?|ml|mL|cc|units?|IU|mEq|mg/kg|mcg/kg|tablets?|pills?|puffs?|drops?)\b"#,
        options: [.caseInsensitive])

    private static let authorizationTerms = ["cricothyro", "needle decompression", "thoracostomy", "chest tube", "surgery", "surgical",
                                             "incision", "intubat", "intraosseous", "central line", "amputat", "reduce the dislocation",
                                             "reduce dislocation", "suture"]
    private static let cmoTerms = ["intravenous", " iv ", "iv line", "inject", "catheter", "administer", "medication", "drug",
                                   "epinephrine", "aspirin", "analgesic", "opioid", "antibiotic", "nitroglycerin", "sedat",
                                   "bag-valve", "airway adjunct", "ultrasound", "ecg"]

    static func stripDoses(_ s: String) -> (String, Bool) {
        guard let doseRegex else { return (s, false) }
        let range = NSRange(s.startIndex..., in: s)
        guard doseRegex.firstMatch(in: s, range: range) != nil else { return (s, false) }
        return (doseRegex.stringByReplacingMatches(in: s, range: range, withTemplate: dosePlaceholder), true)
    }

    static func requiredAuthority(for text: String) -> AuthorityLevel {
        let t = " " + text.lowercased() + " "
        if authorizationTerms.contains(where: { t.contains($0) }) { return .flightSurgeon }
        if cmoTerms.contains(where: { t.contains($0) }) { return .crewMedicalOfficer }
        return .crew
    }

    /// Applies every rule to one step. Returns the corrected step and notes describing any changes.
    @MainActor
    static func validate(_ step: GuidanceStep, kb: MedicalKnowledgeBase, knownSources: Set<String>) -> (GuidanceStep, [String]) {
        var s = step
        var notes: [String] = []

        var dosed = false
        (s.action, dosed) = stripDoses(s.action)
        if dosed { notes.append("A specific dose was removed from \"\(s.action.prefix(40))…\" — doses come only from onboard protocol.") }
        s.precautions = s.precautions.map { stripDoses($0).0 }
        s.purpose = stripDoses(s.purpose).0

        let needed = max(requiredAuthority(for: s.action + " " + s.purpose), s.equipment.compactMap { kb.supply(matching: $0)?.authority }.max() ?? .crew)
        if needed > s.authority {
            s.authority = needed
            notes.append("Authority for \"\(s.action.prefix(40))…\" raised to \(needed.label).")
        }

        var kitItems: [String] = []
        for item in s.equipment {
            if let match = kb.supply(matching: item) {
                kitItems.append(match.name + (match.location.map { " (\($0))" } ?? ""))
            } else {
                kitItems.append("\(item) — not in onboard inventory, verify or improvise")
            }
        }
        s.equipment = kitItems

        let valid = s.sourceIDs.filter { knownSources.contains($0) }
        if valid.count < s.sourceIDs.count { notes.append("Unrecognized source references were removed.") }
        s.sourceIDs = valid
        if s.basis == .knowledgeBase && valid.isEmpty { s.basis = .aiInference }

        if s.authority == .flightSurgeon && !s.precautions.contains(where: { $0.contains("authorization") }) {
            s.precautions.insert("Do not perform without flight surgeon / CMO authorization and appropriate training.", at: 0)
        }
        return (s, notes)
    }
}

// MARK: - 12. Offline protocol engine (always available, no AI required)

nonisolated struct ReasoningContext {
    var vitals: VitalsSnapshot
    var evaluation: Evaluation
    var physics: PhysicsSnapshot
    var pressureRateKPaPerMinute: Double?
    var environmentLines: [String]
    var missionLabel: String
    var gravity: Double
    var adaptedGravity: Double
    var comms: CommsStatus
    var commsDelayMinutes: Int
    var profile: AstronautProfile
    var previous: ClinicalReport?
    var interventions: [InterventionRecord]
    var updates: [CaseUpdate]
    var dataSource: String = "Live sensor data"
    var isSimulation: Bool = false

    var microgravity: Bool { gravity < 0.5 }
    var gravityTransition: Bool { gravity - adaptedGravity > 1.0 }
}

nonisolated func unique(_ items: [String]) -> [String] {
    var seen = Set<String>()
    return items.filter { seen.insert($0).inserted }
}

nonisolated enum ProtocolEngine {
    static func reassessMinutes(_ u: Urgency) -> Int {
        switch u {
        case .emergency: return 2
        case .urgent: return 5
        case .caution: return 15
        case .observe: return 60
        case .normal: return 240
        }
    }

    static func searchTerms(_ input: CaseInput, _ ctx: ReasoningContext) -> [String] {
        var terms = input.description.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }
        terms += input.mechanism.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 }
        for f in input.findings { terms += f.keywords }
        for r in input.regions { terms.append(r.label.lowercased()) }
        if input.bleeding != .none { terms += ["bleeding", "hemorrhage", "wound"] }
        if input.bleedingMajor { terms += ["tourniquet", "shock"] }
        if input.consciousness == .unresponsive { terms += ["unresponsive", "cpr"] }
        if let s = ctx.vitals.spo2, s < 92 { terms += ["hypoxia", "oxygen"] }
        if ctx.gravityTransition { terms += ["orthostatic", "gravity"] }
        if let m = ctx.physics.armstrongMarginKPa, m < 20 { terms += ["depressurization", "pressure"] }
        return Array(Set(terms))
    }

    @MainActor
    static func assess(_ input: CaseInput, _ ctx: ReasoningContext, kb: MedicalKnowledgeBase, docs: [KnowledgeDocument]) -> ClinicalReport {
        var steps: [GuidanceStep] = []
        var urgency = ctx.evaluation.tier
        var rationale = ctx.evaluation.reasons.filter { $0.tier >= .caution }.map { "\($0.title): \($0.detail)" }
        var differentials: [Differential] = []
        var confirmed: [String] = []
        var uncertain: [String] = []
        var needsQualified: [String] = []
        var escalation: [String] = []
        var contraindications: [String] = []
        var monitoring: [String] = ["Heart rate and SpO₂ (Apple Watch / suit) continuously", "Level of consciousness (AVPU)"]
        var improving: [String] = []
        var deteriorating: [String] = []
        var missing: [String] = []
        var assessFirst: [String] = []
        var missionNotes: [String] = []

        let v = ctx.vitals
        let micro = ctx.microgravity
        let f = input.findings
        let docIDs = Set(docs.map(\.id))
        func src(_ ids: String...) -> [String] { ids.filter { docIDs.contains($0) || kb.document($0) != nil } }
        func raise(_ u: Urgency, _ why: String) {
            if u > urgency { urgency = u }
            rationale.append(why)
        }

        // Confirmed observations
        if let hr = v.heartRate { confirmed.append("Heart rate \(fmt(hr)) bpm (\(v.provenanceNote))") }
        if let s = v.spo2 { confirmed.append("SpO₂ \(fmt(s))% (\(v.provenanceNote))") }
        if let rr = v.respiratoryRate { confirmed.append("Respiratory rate \(fmt(rr)) /min") }
        if let sys = v.systolic, let dia = v.diastolic { confirmed.append("Blood pressure \(fmt(sys))/\(fmt(dia)) mmHg") }
        if let t = v.bodyTemperature { confirmed.append("Body temperature \(fmt(t, 1)) °C") }
        if !input.findings.isEmpty { confirmed.append("Crew-reported: " + input.findings.map(\.label).sorted().joined(separator: ", ")) }
        if input.bleeding != .none { confirmed.append("Bleeding reported: \(input.bleeding.label)") }
        confirmed.append("Consciousness: \(input.consciousness.label)")

        // 0. Environment and scene safety
        if let margin = ctx.physics.armstrongMarginKPa, margin <= 0 {
            raise(.emergency, "Ambient pressure at or below the Armstrong limit — body fluids boil at body temperature.")
            steps.append(GuidanceStep(phase: "Scene safety", action: "Restore pressure first: move the casualty into a pressurized volume or pressure suit, or close the hatch and repressurize per emergency procedure.",
                                      purpose: "No medical treatment is effective while ambient pressure is below the Armstrong limit.",
                                      equipment: ["Pressure suit", "Oxygen mask and supply"],
                                      precautions: ["Rescuers protect themselves first (suit or oxygen) before entering"],
                                      expectedObservations: ["Pressure above 6.3 kPa and rising"], reassessIf: ["Pressure does not rise"],
                                      ifUnsuccessful: "Evacuate to the safe-haven module and notify all crew.", authority: .crew,
                                      basis: .measurement, timeCritical: true))
        } else if let rate = ctx.pressureRateKPaPerMinute, rate < -1 {
            raise(.emergency, "Cabin pressure falling \(fmt(-rate, 1)) kPa/min.")
            steps.append(GuidanceStep(phase: "Scene safety", action: "Treat as a depressurization event: don oxygen masks, isolate the leak per procedure, account for all crew.",
                                      purpose: "Prevent hypoxia and loss of consciousness in all crew members.",
                                      equipment: ["Oxygen mask and supply"], expectedObservations: ["Pressure rate stabilizes"],
                                      reassessIf: ["Any crew member confused or unresponsive"], authority: .crew, basis: .measurement, timeCritical: true))
        }
        if let alv = ctx.physics.alveolarO2mmHg, alv < 60 {
            raise(.urgent, "Estimated alveolar PO₂ \(fmt(alv)) mmHg in the current atmosphere (model estimate).")
            steps.append(GuidanceStep(phase: "Scene safety", action: "Verify cabin oxygen and pressure readings; provide supplemental oxygen to everyone affected.",
                                      purpose: "The atmosphere itself may be causing hypoxia.", equipment: ["Oxygen mask and supply"],
                                      expectedObservations: ["SpO₂ rises within minutes"], reassessIf: ["SpO₂ stays low on oxygen"],
                                      authority: .crew, basis: .measurement, sourceIDs: src("builtin-hypoxia"), timeCritical: true))
        }
        if f.contains(.smokeExposure) || f.contains(.chemicalExposure) {
            raise(.urgent, "Possible toxic atmosphere.")
            steps.append(GuidanceStep(phase: "Scene safety", action: "Don protective breathing equipment, isolate the source, and move the casualty to clean air before treatment.",
                                      purpose: "Prevent further exposure to casualty and rescuers.", equipment: ["Oxygen mask and supply", "Exam gloves"],
                                      precautions: ["Do not enter a contaminated area without protection"],
                                      expectedObservations: ["Breathing eases away from the source"], reassessIf: ["Cough, wheeze, or voice change (airway burn)"],
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-burn"), timeCritical: true))
        }
        steps.append(GuidanceStep(phase: "Scene safety", action: micro
                                  ? "Put on gloves and eye protection. Secure the casualty and yourself with restraints or foot loops before working."
                                  : "Put on gloves and eye protection. Make the area safe and position the casualty on a firm surface.",
                                  purpose: micro ? "In microgravity, both bodies drift with every push; fluids form floating droplets."
                                  : "Protects the rescuer and gives a stable working position.",
                                  equipment: micro ? ["Exam gloves", "Crew restraint system"] : ["Exam gloves"],
                                  authority: .crew, basis: .protocolRule))

        // 1. Unresponsive / not breathing
        if input.consciousness == .unresponsive || f.contains(.notBreathingNormally) {
            raise(.emergency, "Unresponsive or not breathing normally.")
            assessFirst.append("Responsiveness and normal breathing (no more than 10 seconds)")
            steps.append(GuidanceStep(phase: "Life support", action: "Call all crew to the casualty. If not breathing normally, start chest compressions immediately and continue without long pauses.",
                                      purpose: "Maintains blood flow to the brain and heart.",
                                      equipment: micro ? ["Crew restraint system"] : [],
                                      precautions: micro ? ["Restrain the casualty to a rigid surface; the rescuer braces (e.g., feet against the opposite wall or handstand position) to generate force"] : ["Firm, flat surface"],
                                      expectedObservations: ["Chest rises and falls with each compression"],
                                      reassessIf: ["Signs of life return: movement, coughing, normal breathing"],
                                      ifUnsuccessful: "Swap compressors every 2 minutes and continue until the AED or medical direction says otherwise.",
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-bls"), timeCritical: true))
            steps.append(GuidanceStep(phase: "Life support", action: "Attach the defibrillator as soon as it arrives and follow its voice prompts.",
                                      purpose: "Treats shockable heart rhythms.", equipment: ["Defibrillator (AED)"],
                                      precautions: ["Nobody touches the casualty during analysis or shock", "Dry the chest; keep floating water away"],
                                      expectedObservations: ["AED analyzes rhythm and advises"], reassessIf: ["Return of breathing or movement"],
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-bls"), timeCritical: true))
            escalation.append("Any unresponsive casualty — notify the flight surgeon immediately.")
        }

        // 2. Catastrophic bleeding
        if input.bleedingMajor {
            raise(input.bleeding == .severe ? .emergency : .urgent, "External bleeding \(input.bleeding.label.lowercased()).")
            assessFirst.append("Locate the source of bleeding; expose the wound")
            let limb = input.regions.contains { $0.isLimb }
            let torso = input.regions.contains { $0.isJunctionalOrTorso }
            steps.append(GuidanceStep(phase: "Bleeding control", action: "Apply firm, direct pressure on the wound with gauze and hold it continuously.",
                                      purpose: "Direct pressure stops most external bleeding.", equipment: ["Exam gloves", "Gauze pads", "Pressure bandage"],
                                      precautions: micro ? ["Blood will not drip — it clings and forms droplets. Contain with absorbent material and protect eyes."] : [],
                                      expectedObservations: ["Bleeding slows and stops; dressing does not soak through"],
                                      reassessIf: ["Dressing soaks through", "Bleeding restarts when pressure is released"],
                                      ifUnsuccessful: limb ? "Apply a tourniquet (next step)." : "Pack the wound (next step).",
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-hemorrhage"), timeCritical: true))
            if limb || input.bleeding == .severe {
                steps.append(GuidanceStep(phase: "Bleeding control", action: "If limb bleeding is not controlled by pressure, or the limb is amputated: apply a tourniquet high and tight above the wound (not over a joint) and tighten until bleeding stops. Write down the time.",
                                          purpose: "Stops arterial bleeding from a limb that pressure cannot control.", equipment: ["Tourniquet"],
                                          precautions: ["Do not loosen or remove once applied without medical direction", "It will be painful — that is expected"],
                                          expectedObservations: ["Bleeding stops", "No pulse below the tourniquet"],
                                          reassessIf: ["Bleeding continues — apply a second tourniquet above the first"],
                                          ifUnsuccessful: "Apply a second tourniquet directly above the first and keep direct pressure.",
                                          authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-hemorrhage"), timeCritical: true))
                contraindications.append("Do not loosen a tourniquet to \"check\" the wound.")
            }
            if torso || !limb {
                steps.append(GuidanceStep(phase: "Bleeding control", action: "For a deep wound in the neck, groin, armpit, or torso where a tourniquet cannot be used: pack the wound firmly with hemostatic gauze, then hold pressure as directed on the product.",
                                          purpose: "Packing applies pressure directly to the bleeding vessel.", equipment: ["Hemostatic gauze", "Gauze pads"],
                                          precautions: ["Do not pack open chest or abdominal cavities — cover and seek medical direction", "Do not remove impaled objects"],
                                          expectedObservations: ["Bleeding controlled with packing in place"], reassessIf: ["Packing soaks through"],
                                          ifUnsuccessful: "Add more packing on top and continue pressure; escalate immediately.",
                                          authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-hemorrhage"), timeCritical: true))
            }
            needsQualified.append("Fluid resuscitation or IV access requires CMO / flight surgeon authorization.")
            escalation.append("Bleeding not controlled after pressure and tourniquet or packing.")
            deteriorating += ["Heart rate rising, SpO₂ falling, pale/cold skin, confusion — possible shock"]
            improving += ["Bleeding stopped", "Heart rate stabilizing or falling"]
            monitoring.append("Wound dressing for soak-through every few minutes")
            var bleedSupport = ["Major external bleeding reported"]
            if let hr = v.heartRate, hr > 100 { bleedSupport.append("Tachycardia \(fmt(hr)) bpm") }
            var bleedAgainst: [String] = []
            if let hr = v.heartRate, hr < 90 { bleedAgainst.append("Heart rate not elevated yet (early compensation can hide blood loss)") }
            let shockLikely = (v.heartRate ?? 0) > 110 || (v.systolic ?? 120) < 90
            differentials.append(Differential(name: "Hemorrhagic shock (developing)",
                                              likelihood: shockLikely ? .higher : .possible,
                                              supporting: bleedSupport,
                                              against: bleedAgainst,
                                              basis: .protocolRule, sourceIDs: src("builtin-hemorrhage", "convertino-2020-crm")))
        } else if input.bleeding == .minor || input.bleeding == .controlled {
            steps.append(GuidanceStep(phase: "Wound care", action: "Clean around the wound and cover it with a sterile dressing; keep pressure if oozing continues.",
                                      purpose: "Prevents infection and further blood loss.", equipment: ["Gauze pads", "Exam gloves"],
                                      expectedObservations: ["No further bleeding"], reassessIf: ["Bleeding restarts or spreading redness"],
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-hemorrhage")))
            raise(.observe, "Minor or controlled bleeding.")
        }

        // 3. Airway and spine
        if input.consciousness == .voice || input.consciousness == .pain {
            raise(.urgent, "Reduced level of consciousness (\(input.consciousness.label)).")
            assessFirst.append("Airway open and clear; breathing adequate")
            steps.append(GuidanceStep(phase: "Airway", action: micro ? "Keep the airway open (head tilt–chin lift, or jaw thrust if neck injury suspected). Have vomit bags and suction ready — fluids do not drain away in microgravity."
                                      : "Keep the airway open; if breathing and no spinal injury suspected, place in the recovery position.",
                                      purpose: "A drowsy casualty can lose their airway.",
                                      expectedObservations: ["Quiet, regular breathing"], reassessIf: ["Snoring, gurgling, or pauses in breathing"],
                                      ifUnsuccessful: "Airway adjuncts and ventilation require the CMO.",
                                      authority: .crew, basis: .protocolRule, timeCritical: true))
            contraindications.append("Nothing by mouth while consciousness is reduced.")
        }
        if f.contains(.headOrNeckInjury) {
            raise(.caution, "Head or neck impact.")
            steps.append(GuidanceStep(phase: "Airway", action: "Hold the head and neck still in line with the body; apply a cervical collar if neck pain, numbness, or reduced consciousness.",
                                      purpose: "Protects a possible spinal injury.", equipment: ["Cervical collar"],
                                      expectedObservations: ["Casualty can move fingers and toes; sensation intact"],
                                      reassessIf: ["New numbness, weakness, or worsening headache"], authority: .crew, basis: .protocolRule))
            deteriorating += ["Worsening headache, repeated vomiting, drowsiness, unequal pupils"]
        }

        // 4. Breathing
        let expected = ctx.physics.expectedSpO2 ?? 97
        let lowSpO2 = v.spo2.map { $0 < min(92, expected - 4) } ?? false
        if f.contains(.breathingDifficulty) || lowSpO2 {
            raise(lowSpO2 && (v.spo2 ?? 100) < 88 ? .emergency : .urgent, "Breathing difficulty or low SpO₂.")
            assessFirst.append("Breathing rate, effort, and SpO₂")
            steps.append(GuidanceStep(phase: "Breathing", action: ctx.gravity > 0.5 ? "Give supplemental oxygen and help the casualty sit upright."
                                      : "Give supplemental oxygen; let the casualty adopt the position that eases breathing.",
                                      purpose: "Raises blood oxygen while the cause is identified.", equipment: ["Oxygen mask and supply"],
                                      precautions: ["Oxygen raises fire risk — no ignition sources"],
                                      expectedObservations: ["SpO₂ rising, breathing rate slowing"], reassessIf: ["SpO₂ not improving in 5 minutes"],
                                      ifUnsuccessful: "Escalate: CMO may assist ventilation with a bag-valve mask.",
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-hypoxia"), timeCritical: true))
            if input.regions.contains(.chest) || f.contains(.chestPain) {
                differentials.append(Differential(name: "Pneumothorax", likelihood: input.mechanism.isEmpty ? .possible : .higher,
                                                  supporting: ["Breathing difficulty with chest involvement"], against: [], basis: .protocolRule))
                needsQualified.append("Suspected tension pneumothorax (worsening breathing, falling SpO₂, low BP): any decompression procedure requires flight surgeon authorization.")
            }
            differentials.append(Differential(name: "Hypoxia from atmosphere", likelihood: (ctx.physics.alveolarO2mmHg ?? 100) < 70 ? .higher : .lower,
                                              supporting: ctx.physics.expectedSpO2.map { ["Model-expected SpO₂ ≈ \(fmt($0))%"] } ?? [],
                                              against: (ctx.physics.alveolarO2mmHg ?? 100) >= 70 ? ["Cabin atmosphere within normal range"] : [],
                                              basis: .measurement))
            uncertain.append("Wrist SpO₂ can read falsely low with motion, cold hands, or poor perfusion — confirm with a finger sensor if available.")
            escalation.append("SpO₂ stays below 90% on oxygen, or breathing becomes exhausted.")
        }

        // 5. Circulation and cardiac
        if f.contains(.chestPain) || f.contains(.palpitations) {
            raise(.urgent, "Chest pain or palpitations.")
            assessFirst.append("Pain character, onset, radiation; heart rhythm")
            steps.append(GuidanceStep(phase: "Circulation", action: "Stop all activity, keep the casualty at rest and restrained, and record the time the pain began.",
                                      purpose: "Reduces heart workload.", equipment: micro ? ["Crew restraint system"] : [],
                                      expectedObservations: ["Pain eases with rest"], reassessIf: ["Pain worsens, sweating, breathlessness, fainting"],
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-chest-pain")))
            steps.append(GuidanceStep(phase: "Circulation", action: "Record a 12-lead or monitor ECG and blood pressure; transmit to the flight surgeon.",
                                      purpose: "Distinguishes cardiac from non-cardiac causes.", equipment: ["ECG monitor", "Blood pressure cuff"],
                                      expectedObservations: ["Rhythm and ST segments documented"], reassessIf: ["Irregular or very fast/slow rhythm"],
                                      authority: .crewMedicalOfficer, basis: .protocolRule, sourceIDs: src("builtin-chest-pain")))
            needsQualified.append("Any cardiac medication (e.g., antiplatelet or nitrate) only per onboard protocol and flight surgeon direction.")
            differentials.append(Differential(name: "Cardiac ischemia", likelihood: .possible, supporting: ["Chest pain reported"],
                                              against: [], basis: .protocolRule, sourceIDs: src("builtin-chest-pain")))
            differentials.append(Differential(name: "Musculoskeletal chest pain", likelihood: .possible,
                                              supporting: input.mechanism.isEmpty ? [] : ["Injury mechanism reported"],
                                              against: ["Cannot be assumed until cardiac causes are excluded"], basis: .protocolRule))
            escalation.append("Chest pain lasting more than a few minutes, or with abnormal rhythm or low blood pressure.")
        }
        if f.contains(.dizziness) || f.contains(.fainted) {
            raise(f.contains(.fainted) ? .urgent : .caution, "Dizziness or fainting.")
            steps.append(GuidanceStep(phase: "Circulation", action: ctx.gravity > 0.5 ? "Lie the casualty flat and raise the legs; check glucose and blood pressure."
                                      : "Restrain the casualty at rest; check glucose and blood pressure.",
                                      purpose: "Restores blood flow to the brain and checks reversible causes.",
                                      equipment: ["Glucometer", "Blood pressure cuff"],
                                      expectedObservations: ["Symptoms resolve within minutes"], reassessIf: ["Repeated fainting, chest pain, or injury from the fall"],
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-orthostatic")))
            if ctx.gravityTransition {
                var orthoSupport = ["Gravity \(fmt(ctx.gravity, 2)) m/s² vs adapted \(fmt(ctx.adaptedGravity, 2)) m/s²"]
                if let load = ctx.physics.orthostaticLoadChangeMmHg { orthoSupport.append("Hydrostatic load +\(fmt(load, 1)) mmHg (model)") }
                differentials.append(Differential(name: "Orthostatic intolerance after gravity transition", likelihood: .higher,
                                                  supporting: orthoSupport,
                                                  against: [], basis: .measurement, sourceIDs: src("builtin-orthostatic")))
            }
        }
        if let hr = v.heartRate, let sys = v.systolic, sys > 0, hr / sys >= 1.0 {
            raise(.urgent, "Shock index ≥ 1.0 (HR \(fmt(hr)) / SBP \(fmt(sys))).")
        }

        // 6. Disability (neurological)
        let neuro: Set<ClinicalFinding> = [.oneSidedWeakness, .speechDifficulty, .confusion, .seizure, .severeHeadache]
        if !f.isDisjoint(with: neuro) {
            raise(.urgent, "New neurological symptoms.")
            assessFirst.append("FAST check (Face, Arms, Speech, Time) and glucose")
            steps.append(GuidanceStep(phase: "Neurological", action: "Perform a FAST check, record the exact time symptoms started, and measure glucose.",
                                      purpose: "Onset time and glucose are essential for medical decisions about stroke.",
                                      equipment: ["Glucometer"], expectedObservations: ["Deficits documented"],
                                      reassessIf: ["Any worsening of speech, strength, or alertness"],
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-stroke"), timeCritical: true))
            if f.contains(.seizure) {
                steps.append(GuidanceStep(phase: "Neurological", action: "During a seizure: protect from injury, loosely restrain away from hard surfaces, do not put anything in the mouth, and time the seizure.",
                                          purpose: "Prevents injury; duration guides medical decisions.", equipment: micro ? ["Crew restraint system"] : [],
                                          expectedObservations: ["Seizure stops; casualty gradually wakes"], reassessIf: ["Seizure lasts more than 5 minutes or repeats"],
                                          ifUnsuccessful: "Prolonged seizure: anti-seizure medication only per protocol and CMO.",
                                          authority: .crew, basis: .protocolRule, timeCritical: true))
            }
            contraindications.append("Nothing by mouth until swallowing is confirmed safe.")
            differentials.append(Differential(name: "Stroke or intracranial bleeding", likelihood: f.contains(.oneSidedWeakness) || f.contains(.speechDifficulty) ? .higher : .possible,
                                              supporting: f.intersection(neuro).map(\.label), against: [], basis: .protocolRule, sourceIDs: src("builtin-stroke")))
            differentials.append(Differential(name: "Low blood glucose", likelihood: v.glucose.map { g -> Likelihood in g < 70 ? Likelihood.higher : Likelihood.lower } ?? Likelihood.unclear,
                                              supporting: v.glucose.map { ["Glucose \(fmt($0)) mg/dL"] } ?? [],
                                              against: [], basis: v.glucose == nil ? .protocolRule : .measurement))
            if v.glucose == nil { missing.append("Glucose — essential with neurological symptoms") }
            escalation.append("Any new focal neurological deficit — immediate flight surgeon contact.")
        }
        if let g = v.glucose, g < 70 {
            raise(.urgent, "Low glucose \(fmt(g)) mg/dL.")
            steps.append(GuidanceStep(phase: "Neurological", action: input.consciousness == .alert ? "Give oral glucose if the casualty is alert and can swallow, then recheck glucose."
                                      : "Do not give anything by mouth; escalate for alternative glucose administration.",
                                      purpose: "Corrects hypoglycemia.", equipment: ["Oral glucose", "Glucometer"],
                                      expectedObservations: ["Glucose rising, alertness improving"], reassessIf: ["No improvement on recheck"],
                                      authority: input.consciousness == .alert ? .crew : .crewMedicalOfficer, basis: .measurement))
        }
        if f.contains(.visionChange) && f.contains(.severeHeadache) && micro {
            differentials.append(Differential(name: "Raised intracranial pressure / spaceflight-associated neuro-ocular changes", likelihood: .possible,
                                              supporting: ["Headache with vision change in microgravity"], against: [], basis: .protocolRule))
        }

        // 7. Exposure: injuries and other conditions
        if f.contains(.suspectedFracture) {
            raise(.caution, "Suspected fracture.")
            steps.append(GuidanceStep(phase: "Injuries", action: "Check pulse, color, and sensation beyond the injury; splint in the position found; recheck after splinting.",
                                      purpose: "Immobilization reduces pain and further damage.", equipment: ["Moldable splint", "Cold pack"],
                                      precautions: ["Do not try to straighten a deformed limb unless circulation is lost and medical direction is given"],
                                      expectedObservations: ["Pain reduced; circulation intact below the splint"],
                                      reassessIf: ["Limb becomes cold, pale, numb, or pulseless"], authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-fracture")))
            needsQualified.append("Pain medication selection and dose: per onboard protocol / CMO.")
        }
        if f.contains(.burn) {
            raise(.caution, "Burn injury.")
            steps.append(GuidanceStep(phase: "Injuries", action: micro ? "Cool the burn with clean water applied by a wet cloth or contained irrigation, then cover loosely with a non-adherent dressing."
                                      : "Cool the burn under clean running water, then cover loosely with a non-adherent dressing.",
                                      purpose: "Stops tissue damage and reduces pain.", equipment: ["Non-adherent burn dressing"],
                                      precautions: ["No ice, creams, or popping blisters", "Avoid hypothermia when cooling large areas"],
                                      expectedObservations: ["Pain decreases"], reassessIf: ["Burns to face/airway, hoarse voice, or large area"],
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-burn")))
        }
        if f.contains(.eyeExposure) {
            raise(.caution, "Eye exposure.")
            steps.append(GuidanceStep(phase: "Injuries", action: "Do not rub. Irrigate the eye with the eye irrigation kit, holding the lids open.",
                                      purpose: "Removes debris or chemicals.", equipment: ["Eye irrigation kit"],
                                      expectedObservations: ["Discomfort decreases, vision clear"], reassessIf: ["Vision change or pain persists"],
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-eye")))
        }
        if f.contains(.allergicReaction) {
            let severe = f.contains(.breathingDifficulty) || input.consciousness != .alert || (v.systolic ?? 120) < 90
            raise(severe ? .emergency : .caution, severe ? "Allergic reaction with airway, breathing, or circulation involvement." : "Allergic reaction.")
            steps.append(GuidanceStep(phase: "Allergy", action: severe ? "Suspected anaphylaxis: give epinephrine by auto-injector per the onboard protocol now, then oxygen."
                                      : "Remove the trigger and monitor closely for spreading swelling or breathing changes.",
                                      purpose: "Epinephrine is the first-line treatment for anaphylaxis.",
                                      equipment: severe ? ["Epinephrine auto-injector", "Oxygen mask and supply"] : [],
                                      expectedObservations: ["Breathing and swelling improve within minutes"],
                                      reassessIf: ["No improvement — protocol may allow a repeat"], authority: severe ? .crewMedicalOfficer : .crew,
                                      basis: .protocolRule, sourceIDs: src("builtin-allergy"), timeCritical: severe))
            if !ctx.profile.allergies.isEmpty { confirmed.append("Known allergies: \(ctx.profile.allergies)") }
        }
        if f.contains(.jointPainAfterPressureChange) || (f.contains(.numbnessTingling) && (ctx.physics.pressureKPa ?? 101) < 80) {
            raise(.urgent, "Possible decompression sickness.")
            steps.append(GuidanceStep(phase: "Pressure-related", action: "Give oxygen, keep the casualty at rest, and report EVA or pressure-change history for repressurization planning.",
                                      purpose: "Oxygen helps eliminate nitrogen bubbles; repressurization is the definitive treatment.",
                                      equipment: ["Oxygen mask and supply"], expectedObservations: ["Pain decreases"],
                                      reassessIf: ["Neurological or breathing symptoms appear"],
                                      ifUnsuccessful: "Repressurization treatment per protocol — flight surgeon authorization.",
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-dcs")))
            differentials.append(Differential(name: "Decompression sickness", likelihood: f.contains(.jointPainAfterPressureChange) ? .higher : .possible,
                                              supporting: ["Symptoms after pressure change"], against: [], basis: .protocolRule, sourceIDs: src("builtin-dcs")))
        }
        if f.contains(.earSinusPain) {
            raise(.observe, "Ear or sinus pain.")
            steps.append(GuidanceStep(phase: "Pressure-related", action: "Pause any pressure change and attempt gentle equalization (swallowing, jaw movement).",
                                      purpose: "Relieves barotrauma.", expectedObservations: ["Pain eases"], reassessIf: ["Hearing loss, vertigo, or discharge"],
                                      authority: .crew, basis: .protocolRule, sourceIDs: src("builtin-dcs")))
        }
        if f.contains(.feverChills) || (v.bodyTemperature ?? 37) >= 38.0 {
            raise((v.bodyTemperature ?? 37) >= 39.5 ? .urgent : .caution, "Fever.")
            steps.append(GuidanceStep(phase: "Other", action: "Measure temperature, encourage fluids, rest, and isolate if infection is possible.",
                                      purpose: "Supports recovery and protects the crew.", equipment: ["Thermometer", "Oral rehydration fluids"],
                                      expectedObservations: ["Temperature stable or falling"], reassessIf: ["Temperature rising, confusion, rash, stiff neck"],
                                      authority: .crew, basis: .protocolRule))
            needsQualified.append("Antipyretic or antibiotic use per onboard protocol / flight surgeon.")
        }
        if f.contains(.nauseaVomiting) {
            raise(.observe, "Nausea or vomiting.")
            if micro { differentials.append(Differential(name: "Space motion sickness", likelihood: .possible, supporting: ["Microgravity environment"], against: f.contains(.headOrNeckInjury) ? ["Head impact reported — rule out head injury first"] : [], basis: .protocolRule)) }
            monitoring.append("Fluid intake and output; vomit containment")
        }
        if f.contains(.abdominalPain) {
            raise(.caution, "Abdominal pain.")
            assessFirst.append("Pain location, onset, and whether the abdomen is rigid")
            escalation.append("Rigid abdomen, fever, vomiting blood, or pain with low blood pressure.")
        }

        // 8. Measured-only alerts without a reported case
        for r in ctx.evaluation.reasons where r.tier >= .urgent && input.isEmpty {
            steps.append(GuidanceStep(phase: "Vitals alert", action: "Check on the crew member now: ask how they feel and confirm the reading (\(r.title)).",
                                      purpose: "A sensor alert needs human confirmation.", expectedObservations: ["Reading confirmed or explained (motion, loose band)"],
                                      reassessIf: ["Crew member is unwell"], authority: .crew, basis: .measurement, timeCritical: r.tier == .emergency))
        }

        // 9. Knowledge-base guidance from team-provided sources
        for d in docs where !d.isBuiltIn {
            for g in d.guidance.prefix(3) {
                steps.append(GuidanceStep(phase: "From source: \(d.title)", action: g, purpose: d.summary.isEmpty ? "Recommended by the source." : String(d.summary.prefix(160)),
                                          precautions: d.contraindications, reassessIf: d.escalation,
                                          authority: .crew, basis: .knowledgeBase, sourceIDs: [d.id]))
            }
            contraindications += d.contraindications
            escalation += d.escalation
        }

        // 10. Unfamiliar presentation fallback
        let clinicalSteps = steps.filter { $0.phase != "Scene safety" }
        if clinicalSteps.isEmpty && !input.isEmpty {
            raise(.observe, "Presentation not matched by built-in protocols.")
            uncertain.append("This presentation does not match a built-in protocol; guidance below is a structured general assessment.")
            steps.append(GuidanceStep(phase: "Structured assessment", action: "Ask about symptoms using SAMPLE: Signs/symptoms, Allergies, Medications, Past history, Last intake, Events leading up.",
                                      purpose: "Collects the information a physician needs to reason about an unfamiliar problem.",
                                      expectedObservations: ["Clear timeline of events"], reassessIf: ["Any new symptom"], authority: .crew, basis: .protocolRule))
            steps.append(GuidanceStep(phase: "Structured assessment", action: "Measure a full set of vitals (HR, SpO₂, BP, respiratory rate, temperature, glucose) and compare with the personal baseline.",
                                      purpose: "Objective data narrow the possibilities.", equipment: ["Blood pressure cuff", "Thermometer", "Glucometer"],
                                      expectedObservations: ["Vitals near baseline"], reassessIf: ["Any vital in caution range"], authority: .crew, basis: .protocolRule))
            needsQualified.append("Unfamiliar presentation — share the structured findings with the CMO / flight surgeon.")
        }
        if input.isEmpty && ctx.evaluation.tier <= .observe {
            steps.append(GuidanceStep(phase: "Routine", action: "No problem reported and vitals within expected ranges. Continue routine monitoring.",
                                      purpose: "Baseline tracking.", authority: .crew, basis: .measurement))
        }

        // Missing information
        if v.spo2 == nil { missing.append("Recent SpO₂ — take an on-demand Blood Oxygen reading on the Watch") }
        if v.systolic == nil && urgency >= .caution { missing.append("Blood pressure — measure with the cuff") }
        if v.respiratoryRate == nil && urgency >= .caution { missing.append("Respiratory rate — count breaths for 30 seconds") }
        if v.bodyTemperature == nil && (f.contains(.feverChills) || urgency >= .urgent) { missing.append("Body temperature") }
        if input.onsetMinutesAgo == nil && !input.isEmpty { missing.append("Time of onset") }
        if input.painScore == nil && !input.isEmpty { missing.append("Pain score (0–10)") }
        if input.mechanism.isEmpty && (input.bleeding != .none || f.contains(.suspectedFracture) || f.contains(.headOrNeckInjury)) { missing.append("Mechanism of injury") }
        if ctx.profile.allergies.isEmpty && steps.contains(where: { $0.authority >= .crewMedicalOfficer }) { missing.append("Allergies (before any medication)") }
        if v.heartRate != nil, let age = v.heartRateAgeSeconds, age > 600 { uncertain.append("Latest heart rate is \(Int(age / 60)) minutes old.") }
        if ctx.isSimulation {
            uncertain.insert("SIMULATION — inputs are test data (\(ctx.dataSource)), not a real astronaut. This is not an actual emergency.", at: 0)
        }
        uncertain += ctx.evaluation.dataNotes.filter { $0.contains("single reading") || $0.contains("sustained") }

        // Monitoring and mission context
        if urgency >= .urgent { monitoring.append("Full vitals every \(reassessMinutes(urgency)) minutes") }
        improving += ["Vitals returning toward personal baseline", "Casualty more alert and comfortable"]
        deteriorating += ["Falling SpO₂ or rising heart rate", "New confusion or drowsiness"]

        missionNotes.append("Mission profile: \(ctx.missionLabel); gravity \(fmt(ctx.gravity, 2)) m/s².")
        if micro { missionNotes.append("Microgravity: restrain casualty and rescuer; contain all fluids; CPR requires bracing technique.") }
        switch ctx.comms {
        case .available: escalation.append("Contact the flight surgeon with a concise status report.")
        case .delayed: missionNotes.append("Communication delay ≈ \(ctx.commsDelayMinutes) min each way — do not wait for a reply before time-critical actions; send a status report now.")
        case .unavailable: missionNotes.append("No ground contact — the CMO leads care. Document every action and time for later handover.")
        }
        missionNotes.append("Responder training: \(ctx.profile.responderTraining.label). Steps above \(ctx.profile.responderTraining.authority.label) authority are listed for awareness only.")
        if kb.usingExampleKit { missionNotes.append("Supply list is the example kit — import the mission inventory for exact items and locations.") }

        // Trend relative to the previous report
        var trend: String?
        if let prev = ctx.previous {
            var t: [String] = []
            if prev.urgency != urgency { t.append("Urgency \(prev.urgency.label) → \(urgency.label)") }
            if let a = prev.vitalsHR, let b = v.heartRate { t.append("HR \(fmt(a)) → \(fmt(b)) bpm") }
            if let a = prev.vitalsSpO2, let b = v.spo2 { t.append("SpO₂ \(fmt(a)) → \(fmt(b))%") }
            trend = t.isEmpty ? "No significant change since \(prev.createdAt.formatted(date: .omitted, time: .shortened))." : t.joined(separator: " · ")
            if !ctx.interventions.isEmpty {
                trend! += " · Interventions: " + ctx.interventions.suffix(3).map { "\($0.action) (\($0.result))" }.joined(separator: "; ")
            }
        }

        let supplies = Array(Set(steps.flatMap(\.equipment))).sorted()
        let evidenceSupported = docs.map { "\($0.title) [\($0.evidence.short)]" }
        var summary: String
        if input.isEmpty {
            summary = "Vitals-only assessment: \(ctx.evaluation.tier.label). \(ctx.evaluation.reasons.first?.title ?? "No abnormal findings.")"
        } else {
            summary = "\(urgency.label): \(rationale.first ?? "Reported problem assessed with built-in protocols.")"
        }
        if ctx.isSimulation { summary = "[SIMULATION] " + summary }

        return ClinicalReport(input: input, urgency: urgency, urgencyRationale: unique(rationale),
                              summary: summary, confirmed: confirmed, differentials: differentials,
                              evidenceSupported: evidenceSupported, uncertain: uncertain, needsQualifiedHelp: needsQualified,
                              missingInformation: missing, assessFirst: assessFirst.isEmpty ? ["Scene safety, then responsiveness and breathing"] : assessFirst,
                              steps: steps, monitoring: monitoring, improvingSigns: improving, deterioratingSigns: deteriorating,
                              reassessInMinutes: reassessMinutes(urgency), escalation: Array(Set(escalation)).sorted(),
                              contraindications: Array(Set(contraindications)).sorted(), supplies: supplies,
                              missionNotes: missionNotes, sources: docs.map(\.ref), trend: trend,
                              aiUsed: false, aiNote: "", safetyNotes: [],
                              vitalsHR: v.heartRate, vitalsSpO2: v.spo2)
    }
}

// MARK: - 13. AIIntegrationManager (Apple Foundation Models, on-device)

@Generable
nonisolated enum AIUrgency {
    case normal, observe, caution, urgent, emergency
}

@Generable
nonisolated enum AIAuthority {
    case anyCrew, crewMedicalOfficer, flightSurgeonAuthorization
}

@Generable
nonisolated enum AILikelihood {
    case moreConsistent, possible, lessConsistent, unclear
}

@Generable
nonisolated struct AIDifferential {
    @Guide(description: "Name of a possible explanation. Not a diagnosis.")
    var name: String
    var likelihood: AILikelihood
    @Guide(description: "Findings from the case that support it", .maximumCount(3))
    var supporting: [String]
    @Guide(description: "Findings that argue against it, or missing data", .maximumCount(2))
    var against: [String]
    @Guide(description: "IDs of provided sources that support this; empty if none", .maximumCount(2))
    var sourceIDs: [String]
}

@Generable
nonisolated struct AIStep {
    @Guide(description: "One concrete action the crew performs, in plain words. Never include a medication dose.")
    var action: String
    @Guide(description: "Why this action matters")
    var purpose: String
    @Guide(description: "Items from the onboard supply list only", .maximumCount(3))
    var equipment: [String]
    @Guide(description: "Precautions or contraindications", .maximumCount(2))
    var precautions: [String]
    @Guide(description: "What the crew should observe if it works", .maximumCount(2))
    var expectedObservations: [String]
    @Guide(description: "Signs that require reassessment or escalation", .maximumCount(2))
    var reassessIf: [String]
    @Guide(description: "What to do if the step does not work")
    var ifUnsuccessful: String
    var authority: AIAuthority
    @Guide(description: "IDs of provided sources that support this step; empty if none", .maximumCount(2))
    var sourceIDs: [String]
}

@Generable
nonisolated struct AIClinicalAssessment {
    @Guide(description: "Two sentences describing the situation and the main concern")
    var summary: String
    var urgency: AIUrgency
    @Guide(description: "Why this urgency level", .maximumCount(3))
    var urgencyRationale: [String]
    @Guide(description: "Possible explanations, all considered", .maximumCount(4))
    var differentials: [AIDifferential]
    @Guide(description: "Information that would change the assessment", .maximumCount(4))
    var missingInformation: [String]
    @Guide(description: "Additional actions not already covered by the protocol steps", .maximumCount(4))
    var additionalSteps: [AIStep]
    @Guide(description: "When to escalate to the flight surgeon", .maximumCount(3))
    var escalation: [String]
    @Guide(description: "What remains uncertain", .maximumCount(3))
    var uncertainties: [String]
}

@MainActor
@Observable
final class AIIntegrationManager {
    var lastError: String?

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var statusText: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "On-device AI available (Apple Foundation Models). Runs offline."
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device does not support Apple Intelligence. ASTRA uses the offline protocol engine and knowledge base only."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off. Enable it in Settings to add AI reasoning; offline protocols remain active."
            case .modelNotReady:
                return "The on-device model is still downloading. Offline protocols remain active."
            @unknown default:
                return "On-device AI unavailable. Offline protocols remain active."
            }
        }
    }

    static let instructions = """
    You are ASTRA, a medical decision-support assistant for astronauts far from Earth, guiding a crew member like a \
    physician directing a first responder. Reason from the case, vital signs, history, environment, and the provided \
    sources. Consider all reasonable explanations as possibilities; never give a definitive diagnosis. \
    Give concrete, practical actions using only the listed onboard supplies. Never state medication doses — write \
    "per onboard protocol". Mark invasive procedures and all medications as requiring CMO or flight surgeon authority. \
    Cite only source IDs from the provided list; if no source supports a statement, leave sourceIDs empty. \
    Do not repeat the protocol steps already listed. Be concise.
    """

    func analyze(input: CaseInput, offline: ClinicalReport, context: ReasoningContext,
                 docs: [KnowledgeDocument], supplies: [MedicalSupply]) async throws -> AIClinicalAssessment {
        do {
            return try await run(prompt(input, offline, context, docs.prefix(4), supplies))
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            return try await run(prompt(input, offline, context, docs.prefix(1), supplies.prefix(10)))
        }
    }

    private func run(_ prompt: String) async throws -> AIClinicalAssessment {
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(to: prompt, generating: AIClinicalAssessment.self,
                                                 options: GenerationOptions(temperature: 0.2))
        return response.content
    }

    private func prompt<D: Collection, S: Collection>(_ input: CaseInput, _ offline: ClinicalReport, _ ctx: ReasoningContext,
                                                      _ docs: D, _ supplies: S) -> String
    where D.Element == KnowledgeDocument, S.Element == MedicalSupply {
        var p = ctx.isSimulation
            ? "DATA SOURCE: SIMULATION (\(ctx.dataSource)). Test data for system evaluation — not a real astronaut; never call it an actual emergency.\n"
            : "DATA SOURCE: \(ctx.dataSource)\n"
        p += "CASE: \(input.isEmpty ? "No symptoms reported; vitals alert only." : input.text)\n"
        p += "VITALS: \(ctx.vitals.compactText)\n"
        if !ctx.evaluation.dataNotes.isEmpty { p += "DATA QUALITY: " + ctx.evaluation.dataNotes.prefix(4).joined(separator: "; ") + "\n" }
        if !ctx.evaluation.reasons.isEmpty {
            p += "VITAL ALERTS: " + ctx.evaluation.reasons.prefix(4).map { "\($0.tier.label): \($0.title)" }.joined(separator: "; ") + "\n"
        }
        p += "ENVIRONMENT: \(ctx.missionLabel); " + ctx.physics.lines.prefix(4).joined(separator: "; ") + "\n"
        p += "COMMS: \(ctx.comms.label). CREW: \(ctx.profile.text)\n"
        if !ctx.updates.isEmpty { p += "UPDATES: " + ctx.updates.suffix(3).map(\.note).joined(separator: "; ") + "\n" }
        if !ctx.interventions.isEmpty {
            p += "DONE SO FAR: " + ctx.interventions.suffix(4).map { "\($0.action) → \($0.result)" }.joined(separator: "; ") + "\n"
        }
        p += "PROTOCOL STEPS ALREADY GIVEN: " + offline.steps.prefix(6).map { String($0.action.prefix(60)) }.joined(separator: " | ") + "\n"
        p += "SUPPLIES: " + supplies.prefix(24).map(\.name).joined(separator: ", ") + "\n"
        p += "SOURCES:\n"
        for d in docs { p += "[\(d.id)] \(d.title) (\(d.evidence.short)): \(d.summary.prefix(280))\n" }
        return p
    }
}

nonisolated extension AIUrgency {
    var urgency: Urgency {
        switch self {
        case .normal: return .normal
        case .observe: return .observe
        case .caution: return .caution
        case .urgent: return .urgent
        case .emergency: return .emergency
        }
    }
}

nonisolated extension AIAuthority {
    var authority: AuthorityLevel {
        switch self {
        case .anyCrew: return .crew
        case .crewMedicalOfficer: return .crewMedicalOfficer
        case .flightSurgeonAuthorization: return .flightSurgeon
        }
    }
}

nonisolated extension AILikelihood {
    var likelihood: Likelihood {
        switch self {
        case .moreConsistent: return .higher
        case .possible: return .possible
        case .lessConsistent: return .lower
        case .unclear: return .unclear
        }
    }
}

// MARK: - 14. MedicalReasoningEngine (offline protocols → knowledge → AI → safety validation)

@MainActor
@Observable
final class MedicalReasoningEngine {
    var current: ClinicalReport?
    var history: [ClinicalReport] = []
    var activeCase: CaseInput?
    var interventions: [InterventionRecord] = []
    var updates: [CaseUpdate] = []
    var isAnalyzing = false
    var aiStatusNote: String?

    let ai = AIIntegrationManager()
    @ObservationIgnored private var lastAutoReassess = Date.distantPast

    init() {
        history = FileStore.load([ClinicalReport].self, from: "astra_reports.json") ?? []
        current = history.last
    }

    func startCase(_ input: CaseInput) {
        activeCase = input
        interventions = []
        updates = []
    }

    func closeCase() {
        activeCase = nil
        interventions = []
        updates = []
    }

    func logIntervention(_ action: String, result: String) {
        interventions.append(InterventionRecord(action: action, result: result))
    }

    func addUpdate(_ note: String) {
        updates.append(CaseUpdate(note: note))
        if var c = activeCase {
            c.description += (c.description.isEmpty ? "" : " ") + "Update: \(note)."
            activeCase = c
        }
    }

    /// Layer 1 (offline protocol) is published immediately; Layer 3 (AI) refines it if available.
    func assess(_ input: CaseInput, context: ReasoningContext, kb: MedicalKnowledgeBase, useAI: Bool = true) async {
        var ctx = context
        ctx.previous = current
        ctx.interventions = interventions
        ctx.updates = updates
        let docs = kb.retrieve(ProtocolEngine.searchTerms(input, ctx), limit: 5)
        var report = ProtocolEngine.assess(input, ctx, kb: kb, docs: docs)
        report.aiNote = ai.isAvailable ? "AI analysis running…" : ai.statusText
        report.dataSource = ctx.dataSource
        report.inputSnapshot = ctx.vitals.compactText
        publish(report)

        guard useAI, ai.isAvailable else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let result = try await ai.analyze(input: input, offline: report, context: ctx, docs: docs, supplies: kb.supplies)
            report = merge(report, result, kb: kb, docs: docs)
            if ctx.isSimulation && !report.summary.hasPrefix("[SIMULATION]") { report.summary = "[SIMULATION] " + report.summary }
        } catch {
            report.aiNote = "AI analysis failed (\(error.localizedDescription)). Offline protocol guidance shown."
        }
        publish(report, replacingID: report.id)
    }

    /// Called whenever new vitals arrive; re-runs the active case at the report's reassessment interval (min 60 s).
    func autoReassessIfNeeded(context: ReasoningContext, kb: MedicalKnowledgeBase) {
        guard let input = activeCase, !isAnalyzing, let current else { return }
        let interval = max(60, Double(current.reassessInMinutes) * 60 / 2)
        guard Date().timeIntervalSince(lastAutoReassess) > interval else { return }
        lastAutoReassess = Date()
        Task { await assess(input, context: context, kb: kb, useAI: false) }
    }

    private func merge(_ base: ClinicalReport, _ ai: AIClinicalAssessment, kb: MedicalKnowledgeBase, docs: [KnowledgeDocument]) -> ClinicalReport {
        var r = base
        let known = Set(kb.documents.map(\.id))
        var notes: [String] = []

        let aiUrgency = ai.urgency.urgency
        if aiUrgency > r.urgency {
            r.urgency = aiUrgency
            r.reassessInMinutes = ProtocolEngine.reassessMinutes(aiUrgency)
            r.urgencyRationale += ai.urgencyRationale.map { "AI: \($0)" }
        } else if aiUrgency < r.urgency {
            notes.append("AI suggested \(aiUrgency.label); the protocol level \(r.urgency.label) was kept (AI may raise, never lower, urgency).")
        }

        let existing = Set(r.steps.map { $0.action.lowercased().prefix(30) })
        for s in ai.additionalSteps {
            let action = s.action.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.isEmpty, !existing.contains(action.lowercased().prefix(30)) else { continue }
            let validIDs = s.sourceIDs.filter { known.contains($0) }
            let step = GuidanceStep(phase: "AI-suggested", action: action, purpose: s.purpose, equipment: s.equipment,
                                    precautions: s.precautions, expectedObservations: s.expectedObservations, reassessIf: s.reassessIf,
                                    ifUnsuccessful: s.ifUnsuccessful.isEmpty ? nil : s.ifUnsuccessful,
                                    authority: s.authority.authority, basis: validIDs.isEmpty ? .aiInference : .knowledgeBase,
                                    sourceIDs: s.sourceIDs)
            let (validated, stepNotes) = SafetyValidator.validate(step, kb: kb, knownSources: known)
            r.steps.append(validated)
            notes += stepNotes
            if validated.authority == .flightSurgeon { r.needsQualifiedHelp.append(validated.action) }
        }

        for d in ai.differentials {
            guard !r.differentials.contains(where: { $0.name.lowercased() == d.name.lowercased() }) else { continue }
            let ids = d.sourceIDs.filter { known.contains($0) }
            r.differentials.append(Differential(name: SafetyValidator.stripDoses(d.name).0, likelihood: d.likelihood.likelihood,
                                                supporting: d.supporting, against: d.against,
                                                basis: ids.isEmpty ? .aiInference : .knowledgeBase, sourceIDs: ids))
        }

        let currentMissing = r.missingInformation
        let newMissing = ai.missingInformation.filter { !currentMissing.contains($0) }
        r.missingInformation.append(contentsOf: newMissing)
        let currentEscalation = r.escalation
        let newEscalation = ai.escalation.map { SafetyValidator.stripDoses($0).0 }.filter { !currentEscalation.contains($0) }
        r.escalation.append(contentsOf: newEscalation)
        r.uncertain += ai.uncertainties.map { "AI: \($0)" }
        r.summary = SafetyValidator.stripDoses(ai.summary).0
        r.supplies = Array(Set(r.steps.flatMap(\.equipment))).sorted()
        r.aiUsed = true
        r.aiNote = "On-device AI added reasoning. AI content is labeled and passed through the safety validator."
        r.safetyNotes = notes
        return r
    }

    private func publish(_ report: ClinicalReport, replacingID: UUID? = nil) {
        if let replacingID, let i = history.lastIndex(where: { $0.id == replacingID }) {
            history[i] = report
        } else {
            history.append(report)
            if history.count > 200 { history.removeFirst(history.count - 200) }
        }
        current = report
        FileStore.save(history, to: "astra_reports.json")
    }
}

// MARK: - 15. Vital-sign snapshot + RiskEngine (deterministic alert tiers)

nonisolated struct VitalsSnapshot {
    var heartRate: Double?
    var heartRateAt: Date?
    var restingHR: Double?
    var restingBaseline: Double?
    var hrv: Double?
    var hrvBaseline: Double?
    var spo2: Double?
    var respiratoryRate: Double?
    var bodyTemperature: Double?
    var systolic: Double?
    var diastolic: Double?
    var glucose: Double?
    var sleepHours: Double?
    var hrSeries: [ChartPoint] = []
    var updated = Date()
    var isSimulated = false

    var heartRateAgeSeconds: Double? { heartRateAt.map { Date().timeIntervalSince($0) } }
    var provenanceNote: String { isSimulated ? "simulated" : "sensor" }
    var hasAnyData: Bool { heartRate != nil || spo2 != nil || respiratoryRate != nil || bodyTemperature != nil }

    var compactText: String {
        var p: [String] = []
        if let v = heartRate { p.append("HR \(fmt(v))") }
        if let v = restingHR { p.append("restHR \(fmt(v))" + (restingBaseline.map { " (base \(fmt($0)))" } ?? "")) }
        if let v = hrv { p.append("HRV \(fmt(v))ms" + (hrvBaseline.map { " (base \(fmt($0)))" } ?? "")) }
        if let v = spo2 { p.append("SpO2 \(fmt(v))%") }
        if let v = respiratoryRate { p.append("RR \(fmt(v))") }
        if let v = bodyTemperature { p.append("T \(fmt(v, 1))C") }
        if let s = systolic, let d = diastolic { p.append("BP \(fmt(s))/\(fmt(d))") }
        if let v = glucose { p.append("Glu \(fmt(v))") }
        if let v = sleepHours { p.append("Sleep \(fmt(v, 1))h") }
        if isSimulated { p.append("(simulated)") }
        return p.isEmpty ? "No vital signs available" : p.joined(separator: ", ")
    }
}

nonisolated struct Reason: Identifiable, Hashable {
    var id: String { title + detail }
    let title: String
    let detail: String
    let tier: Urgency
    let metric: MetricKind?
}

nonisolated struct Evaluation {
    var tier: Urgency = .normal
    var reasons: [Reason] = []
    var dataNotes: [String] = []
}

/// Default thresholds are general adult reference values. Teams should verify them against their own sources.
nonisolated enum RiskEngine {
    static func evaluate(_ v: VitalsSnapshot, physics: PhysicsSnapshot, pressureRate: Double?, gravityTransition: Bool) -> Evaluation {
        var reasons: [Reason] = []
        func add(_ tier: Urgency, _ title: String, _ detail: String, _ metric: MetricKind? = nil) {
            reasons.append(Reason(title: title, detail: detail, tier: tier, metric: metric))
        }

        // Environment first: it can make every other reading irrelevant.
        if let m = physics.armstrongMarginKPa, m <= 0 {
            add(.emergency, "Pressure below Armstrong limit", "Ambient \(fmt(physics.pressureKPa, 1)) kPa ≤ \(fmt(physics.armstrongLimitKPa, 1)) kPa")
        }
        if let r = pressureRate, r < -1 {
            add(.emergency, "Rapid depressurization", "\(fmt(r, 1)) kPa/min")
        } else if let r = pressureRate, r < -0.2 {
            add(.caution, "Cabin pressure falling", "\(fmt(r, 2)) kPa/min")
        }
        if let a = physics.alveolarO2mmHg {
            if a < 45 { add(.emergency, "Hypoxic atmosphere", "Estimated alveolar PO₂ \(fmt(a)) mmHg (model)") }
            else if a < 60 { add(.urgent, "Low-oxygen atmosphere", "Estimated alveolar PO₂ \(fmt(a)) mmHg (model)") }
        }

        if let hr = v.heartRate {
            if hr >= 150 || hr < 40 { add(.urgent, "Heart rate critical", "\(fmt(hr)) bpm", .heartRate) }
            else if hr >= 120 || hr < 45 { add(.caution, "Heart rate abnormal", "\(fmt(hr)) bpm", .heartRate) }
            else if hr > 100 { add(.observe, "Heart rate elevated", "\(fmt(hr)) bpm", .heartRate) }
        }
        if let r = v.restingHR, let b = v.restingBaseline, r - b >= 10 {
            add(.caution, "Resting HR above baseline", "\(fmt(r)) vs \(fmt(b)) bpm", .restingHeartRate)
        }
        if let h = v.hrv, let b = v.hrvBaseline, b > 0, h < b * 0.6 {
            add(.observe, "HRV well below baseline", "\(fmt(h)) vs \(fmt(b)) ms — stress, fatigue, or illness", .hrv)
        }
        if let s = v.spo2 {
            let expected = physics.expectedSpO2 ?? 97
            if s < 85 { add(.emergency, "Oxygen saturation critical", "\(fmt(s))%", .spo2) }
            else if s < 90 { add(.urgent, "Oxygen saturation low", "\(fmt(s))%", .spo2) }
            else if s < 94 || expected - s > 4 { add(.caution, "Oxygen saturation below expected", "\(fmt(s))% (expected ≈ \(fmt(expected))% for this atmosphere)", .spo2) }
        }
        if let rr = v.respiratoryRate {
            if rr > 30 || rr < 8 { add(.urgent, "Respiratory rate critical", "\(fmt(rr)) /min", .respiratoryRate) }
            else if rr > 24 { add(.caution, "Respiratory rate high", "\(fmt(rr)) /min", .respiratoryRate) }
            else if rr > 20 { add(.observe, "Respiratory rate elevated", "\(fmt(rr)) /min", .respiratoryRate) }
        }
        if let t = v.bodyTemperature {
            if t >= 40 || t < 35 { add(.urgent, "Body temperature critical", "\(fmt(t, 1)) °C", .bodyTemperature) }
            else if t >= 38.5 { add(.caution, "Fever", "\(fmt(t, 1)) °C", .bodyTemperature) }
            else if t >= 37.8 { add(.observe, "Temperature elevated", "\(fmt(t, 1)) °C", .bodyTemperature) }
        }
        if let s = v.systolic {
            if s < 80 { add(.emergency, "Blood pressure critically low", "\(fmt(s)) mmHg systolic", .systolicBP) }
            else if s < 90 { add(.urgent, "Blood pressure low", "\(fmt(s)) mmHg systolic", .systolicBP) }
            else if s >= 180 { add(.urgent, "Blood pressure very high", "\(fmt(s)) mmHg systolic", .systolicBP) }
            else if s >= 160 { add(.caution, "Blood pressure high", "\(fmt(s)) mmHg systolic", .systolicBP) }
            if let hr = v.heartRate, hr / s >= 1.0 { add(.urgent, "Shock index ≥ 1.0", "HR \(fmt(hr)) / SBP \(fmt(s))", .systolicBP) }
        }
        if let g = v.glucose {
            if g < 54 { add(.urgent, "Glucose very low", "\(fmt(g)) mg/dL", .bloodGlucose) }
            else if g < 70 { add(.caution, "Glucose low", "\(fmt(g)) mg/dL", .bloodGlucose) }
            else if g > 300 { add(.caution, "Glucose high", "\(fmt(g)) mg/dL", .bloodGlucose) }
        }
        if let sl = v.sleepHours, sl < 5 { add(.observe, "Short sleep", "\(fmt(sl, 1)) h in the last 24 h", .sleep) }
        if gravityTransition, let hr = v.heartRate, let b = v.restingBaseline, hr - b > 25 {
            add(.caution, "Possible orthostatic stress", "HR \(fmt(hr)) after gravity transition", .heartRate)
        }

        var notes: [String] = []
        if !v.hasAnyData { notes.append("No vital signs yet — check Apple Watch pairing and Health permissions, or start the suit simulation.") }
        if let age = v.heartRateAgeSeconds, age > 3600 { notes.append("Latest heart rate is \(Int(age / 60)) min old.") }
        if v.isSimulated { notes.append("Includes simulated suit data.") }

        reasons.sort { $0.tier > $1.tier }
        return Evaluation(tier: reasons.first?.tier ?? .normal, reasons: reasons, dataNotes: notes)
    }
}

// MARK: - 16. DataExportManager

nonisolated enum ExportRange: String, CaseIterable, Identifiable {
    case hour, day, week, month, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hour: return "Last hour"
        case .day: return "Last 24 h"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .all: return "All data"
        }
    }
    var start: Date? {
        switch self {
        case .hour: return Date().addingTimeInterval(-3600)
        case .day: return Date().addingTimeInterval(-86400)
        case .week: return Date().addingTimeInterval(-7 * 86400)
        case .month: return Date().addingTimeInterval(-30 * 86400)
        case .all: return nil
        }
    }
}

nonisolated enum ExportFormat: String, CaseIterable, Identifiable {
    case biometricsCSV, environmentCSV, reportsCSV, json, pdf, psychCSV, psychJSON, psychPDF
    var id: String { rawValue }
    var label: String {
        switch self {
        case .biometricsCSV: return "Biometrics (CSV, spreadsheet)"
        case .environmentCSV: return "Environment log (CSV)"
        case .reportsCSV: return "Medical assessments (CSV)"
        case .json: return "Complete bundle (JSON)"
        case .pdf: return "Summary report (PDF)"
        case .psychCSV: return "Psychological records (CSV)"
        case .psychJSON: return "Psychological records (JSON)"
        case .psychPDF: return "Psychological report (PDF)"
        }
    }
}

nonisolated struct ExportMetadata: Codable {
    let app: String
    let version: String
    let generatedAt: Date
    let rangeStart: Date?
    let rangeEnd: Date
    let crewMember: String
    let deidentified: Bool
    let metrics: [String]
    let recordCount: Int
    let note: String
}

nonisolated struct ExportBundle: Codable {
    let metadata: ExportMetadata
    let profile: AstronautProfile?
    let biometrics: [BiometricRecord]
    let environment: [EnvironmentalParameter]
    let assessments: [ClinicalReport]
}

@MainActor
@Observable
final class DataExportManager {
    var range: ExportRange = .day
    var formats: Set<ExportFormat> = [.biometricsCSV, .pdf]
    var metrics: Set<MetricKind> = Set(MetricKind.allCases)
    var deidentify = false
    var files: [URL] = []
    var message: String?

    func export(records: [BiometricRecord], environment: [EnvironmentalParameter], reports: [ClinicalReport],
                profile: AstronautProfile, evaluation: Evaluation, physics: PhysicsSnapshot,
                psych: PsychologicalMonitoringManager? = nil) {
        let start = range.start
        let end = Date()
        let recs = records.filter { r in metrics.contains(r.metric) && (start.map { r.end >= $0 } ?? true) }
        let env = environment.filter { p in start.map { p.timestamp >= $0 } ?? true }
        let reps = reports.filter { r in start.map { r.createdAt >= $0 } ?? true }
        let name = deidentify ? "Crew member (de-identified)" : profile.name
        let meta = ExportMetadata(app: "ASTRA", version: "2026.11", generatedAt: end, rangeStart: start, rangeEnd: end,
                                  crewMember: name, deidentified: deidentify, metrics: metrics.map(\.rawValue).sorted(),
                                  recordCount: recs.count,
                                  note: "Decision support only — not a diagnosis. Provenance column distinguishes measured, manual, calculated, estimated, assumed, and simulated values.")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ASTRA-Export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = stampFormatter.string(from: end)

        var out: [URL] = []
        func write(_ data: Data, _ filename: String) {
            let url = dir.appendingPathComponent(filename)
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                out.append(url)
            } catch {
                message = "Could not write \(filename): \(error.localizedDescription)"
            }
        }

        if formats.contains(.biometricsCSV) { write(Data(biometricsCSV(recs).utf8), "ASTRA_biometrics_\(stamp).csv") }
        if formats.contains(.environmentCSV) { write(Data(environmentCSV(env).utf8), "ASTRA_environment_\(stamp).csv") }
        if formats.contains(.reportsCSV) { write(Data(reportsCSV(reps).utf8), "ASTRA_assessments_\(stamp).csv") }
        if formats.contains(.json) {
            let bundle = ExportBundle(metadata: meta, profile: deidentify ? nil : profile, biometrics: recs, environment: env, assessments: reps)
            if let data = try? JSONCoding.encoder(pretty: true).encode(bundle) { write(data, "ASTRA_bundle_\(stamp).json") }
        }
        if formats.contains(.pdf) {
            write(pdf(meta: meta, records: recs, reports: reps, evaluation: evaluation, physics: physics, profile: profile), "ASTRA_report_\(stamp).pdf")
        }
        if let psych {
            if formats.contains(.psychCSV) { write(Data(psychCSV(psych, since: start).utf8), "ASTRA_psych_\(stamp).csv") }
            if formats.contains(.psychJSON), let data = psychJSON(psych, since: start) { write(data, "ASTRA_psych_\(stamp).json") }
            if formats.contains(.psychPDF) { write(psychPDF(psych, since: start), "ASTRA_psych_report_\(stamp).pdf") }
        }
        files = out
        if !out.isEmpty {
            message = "Prepared \(out.count) file(s): \(recs.count) biometric records, \(env.count) environment entries, \(reps.count) assessments. Files are stored with iOS Data Protection until shared."
        } else if message == nil {
            message = "Select at least one format."
        }
    }

    nonisolated static func csvField(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        if s.contains(",") || s.contains("\"") || s.contains("\n") { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return s
    }

    /// UTF-8 BOM so Excel opens units such as °C and SpO₂ correctly.
    private let bom = "\u{FEFF}"

    func biometricsCSV(_ rs: [BiometricRecord]) -> String {
        var s = bom + "timestamp_utc,start_utc,metric,metric_label,value,unit,provenance,source,source_kind,device,context,reliability,note,id\n"
        for r in rs {
            let fields: [String?] = [r.end.ISO8601Format(), r.start.ISO8601Format(), r.metric.rawValue, r.metric.label,
                  String(format: "%.\(r.metric.digits + 1)f", r.value), r.unit, r.sourceKind.provenance.label,
                  r.sourceName, r.sourceKind.label, r.deviceModel, r.context, r.reliability.label, r.note, r.id.uuidString]
            s += fields.map { Self.csvField($0) }.joined(separator: ",") + "\n"
        }
        return s
    }

    func environmentCSV(_ ps: [EnvironmentalParameter]) -> String {
        var s = bom + "timestamp_utc,parameter,value,unit,provenance,source,uncertainty,within_validation_range\n"
        for p in ps {
            let fields: [String?] = [p.timestamp.ISO8601Format(), p.kind.label, String(format: "%.3f", p.value), p.kind.unit, p.provenance.label,
                  p.source, p.uncertainty.map { String(format: "%.3f", $0) }, p.isValid ? "yes" : "no"]
            s += fields.map { Self.csvField($0) }.joined(separator: ",") + "\n"
        }
        return s
    }

    func reportsCSV(_ rs: [ClinicalReport]) -> String {
        var s = bom + "timestamp_utc,urgency,summary,case,differentials,steps,escalation,ai_used,sources\n"
        for r in rs {
            let fields: [String?] = [r.createdAt.ISO8601Format(), r.urgency.label, r.summary, r.input.text,
                  r.differentials.map { "\($0.name) [\($0.likelihood.label)]" }.joined(separator: "; "),
                  r.steps.map { "[\($0.authority.short)] \($0.action)" }.joined(separator: " | "),
                  r.escalation.joined(separator: "; "), r.aiUsed ? "yes" : "no",
                  r.sources.map(\.citation).joined(separator: " || ")]
            s += fields.map { Self.csvField($0) }.joined(separator: ",") + "\n"
        }
        return s
    }

    func pdf(meta: ExportMetadata, records: [BiometricRecord], reports: [ClinicalReport], evaluation: Evaluation,
             physics: PhysicsSnapshot, profile: AstronautProfile) -> Data {
        var blocks: [(String, UIFont, UIColor)] = []
        let h1 = UIFont.boldSystemFont(ofSize: 20), h2 = UIFont.boldSystemFont(ofSize: 14), body = UIFont.systemFont(ofSize: 10.5)
        let gray = UIColor.darkGray

        blocks.append(("ASTRA — Crew Health Report", h1, .black))
        blocks.append(("Generated \(meta.generatedAt.formatted(date: .abbreviated, time: .standard)) · Range: \(meta.rangeStart?.formatted(date: .abbreviated, time: .shortened) ?? "all data") – \(meta.rangeEnd.formatted(date: .abbreviated, time: .shortened))\nCrew member: \(meta.crewMember)\n\(meta.note)", body, gray))

        blocks.append(("Current status: \(evaluation.tier.label)", h2, .black))
        blocks.append((evaluation.reasons.isEmpty ? "No abnormal findings." : evaluation.reasons.map { "• [\($0.tier.label)] \($0.title) — \($0.detail)" }.joined(separator: "\n"), body, .black))
        if !evaluation.dataNotes.isEmpty { blocks.append((evaluation.dataNotes.joined(separator: "\n"), body, gray)) }

        blocks.append(("Biometric summary (\(records.count) records)", h2, .black))
        var lines: [String] = []
        for m in MetricKind.allCases {
            let vals = records.filter { $0.metric == m }.map(\.value)
            guard !vals.isEmpty else { continue }
            let mean = vals.reduce(0, +) / Double(vals.count)
            lines.append("\(m.label): n=\(vals.count), min \(fmt(vals.min(), m.digits)), mean \(fmt(mean, m.digits)), max \(fmt(vals.max(), m.digits)) \(m.unit)")
        }
        blocks.append((lines.isEmpty ? "No biometric data in range." : lines.joined(separator: "\n"), body, .black))

        blocks.append(("Environment and physical models", h2, .black))
        blocks.append((physics.lines.joined(separator: "\n") + "\nAssumptions: " + physics.assumptions.joined(separator: "; "), body, .black))

        if let r = reports.last {
            blocks.append(("Latest medical assessment — \(r.urgency.label) (\(r.createdAt.formatted(date: .abbreviated, time: .shortened)))", h2, .black))
            var t = "Case: \(r.input.text)\nSummary: \(r.summary)\n\nPossible explanations:\n"
            t += r.differentials.map { "• \($0.name) — \($0.likelihood.label) (\($0.basis.label))" }.joined(separator: "\n")
            t += "\n\nGuidance steps:\n"
            t += r.steps.enumerated().map { i, s in "\(i + 1). [\(s.authority.short)] \(s.action)" }.joined(separator: "\n")
            t += "\n\nEscalate if:\n" + r.escalation.map { "• \($0)" }.joined(separator: "\n")
            if !r.contraindications.isEmpty { t += "\n\nDo not:\n" + r.contraindications.map { "• \($0)" }.joined(separator: "\n") }
            t += "\n\nSources:\n" + (r.sources.isEmpty ? "None matched." : r.sources.map { "• \($0.citation) [\($0.evidence.short)]" }.joined(separator: "\n"))
            t += "\n\n\(r.aiNote)"
            blocks.append((t, body, .black))
        }
        if !meta.deidentified {
            blocks.append(("Crew profile", h2, .black))
            blocks.append((profile.text, body, .black))
        }
        blocks.append(("ASTRA provides decision support only. All actions requiring authorization must be confirmed by the Crew Medical Officer or flight surgeon.", body, gray))

        return renderPDF(blocks)
    }

    /// Paginated text renderer shared by the health and psychological reports.
    func renderPDF(_ blocks: [(String, UIFont, UIColor)]) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 48
        let width = page.width - margin * 2
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            var y = margin
            for (text, font, color) in blocks {
                let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                var remaining = attributed
                while remaining.length > 0 {
                    let needed = remaining.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
                    let available = page.height - margin - y
                    if needed <= available {
                        remaining.draw(with: CGRect(x: margin, y: y, width: width, height: needed),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                        y += ceil(needed) + 8
                        break
                    }
                    // Split by lines so long sections continue on the next page.
                    let parts = remaining.string.components(separatedBy: "\n")
                    var fit = 0
                    for i in stride(from: parts.count - 1, through: 1, by: -1) {
                        let candidate = NSAttributedString(string: parts[0..<i].joined(separator: "\n"), attributes: [.font: font, .foregroundColor: color])
                        let hgt = candidate.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
                        if hgt <= available { fit = i; break }
                    }
                    if fit > 0 {
                        let head = NSAttributedString(string: parts[0..<fit].joined(separator: "\n"), attributes: [.font: font, .foregroundColor: color])
                        head.draw(with: CGRect(x: margin, y: y, width: width, height: available),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                        remaining = NSAttributedString(string: parts[fit...].joined(separator: "\n"), attributes: [.font: font, .foregroundColor: color])
                    } else if y <= margin + 1 {
                        // A single line block taller than a page: draw clipped to avoid an infinite loop.
                        remaining.draw(with: CGRect(x: margin, y: y, width: width, height: available),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                        break
                    }
                    ctx.beginPage()
                    y = margin
                }
            }
        }
    }
}

// MARK: - 17. AppModel (integration hub)

nonisolated struct AlertEvent: Identifiable, Codable, Hashable {
    var id = UUID()
    var time = Date()
    var tierRaw: Int
    var title: String
    var detail: String
    var tier: Urgency { Urgency(rawValue: tierRaw) ?? .normal }
}

nonisolated enum DemoCase: String, CaseIterable, Identifiable {
    case legLaceration, depressurizationHypoxia, strokeSigns, chestPain, landingDizziness, unfamiliar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .legLaceration: return "Severe leg laceration"
        case .depressurizationHypoxia: return "Breathing difficulty after pressure drop"
        case .strokeSigns: return "Sudden one-sided weakness"
        case .chestPain: return "Chest pain during exercise"
        case .landingDizziness: return "Dizziness after landing"
        case .unfamiliar: return "Unfamiliar presentation"
        }
    }
    var input: CaseInput {
        var c = CaseInput()
        switch self {
        case .legLaceration:
            c.description = "Deep cut on the right thigh from a sharp panel edge during maintenance; blood soaking through the cloth."
            c.regions = [.rightLeg]; c.bleeding = .severe; c.mechanism = "Sharp metal edge"; c.painScore = 7; c.onsetMinutesAgo = 2
        case .depressurizationHypoxia:
            c.description = "Short of breath and lightheaded after the cabin pressure alarm."
            c.findings = [.breathingDifficulty, .dizziness]; c.onsetMinutesAgo = 3
        case .strokeSigns:
            c.description = "Right arm feels weak and speech is slurred; started suddenly."
            c.findings = [.oneSidedWeakness, .speechDifficulty]; c.regions = [.head, .rightArm]; c.onsetMinutesAgo = 10
        case .chestPain:
            c.description = "Pressure-like chest pain during treadmill session, radiating to the left arm, with sweating."
            c.findings = [.chestPain]; c.regions = [.chest]; c.painScore = 6; c.onsetMinutesAgo = 5
        case .landingDizziness:
            c.description = "Feels faint when standing up after landing on the surface."
            c.findings = [.dizziness]; c.onsetMinutesAgo = 15
        case .unfamiliar:
            c.description = "Intermittent itching rash on both forearms with mild metallic taste for two days, no known exposure."
            c.regions = [.leftArm, .rightArm, .skin]; c.onsetMinutesAgo = 2880
        }
        return c
    }
}

@MainActor
@Observable
final class AppModel {
    let env = EnvironmentalDataManager()
    let bio = BiometricDataManager()
    let kb = MedicalKnowledgeBase()
    let engine = MedicalReasoningEngine()
    let exporter = DataExportManager()
    let psych = PsychologicalMonitoringManager()
    let sim = SimulationEngine()

    var vitals = VitalsSnapshot()
    var evaluation = Evaluation()
    var alerts: [AlertEvent] = []
    var profile = AstronautProfile()
    var comms: CommsStatus = .delayed
    var commsDelayMinutes = 8

    var selectedTab: AppTab = .overview
    var showSimulation = false
    var simEmergencyNotice = false
    @ObservationIgnored private var lastSimAssess = Date.distantPast
    var emergencyVisible = false
    var emergencyStart: Date?
    var crewAlerted = false
    @ObservationIgnored private var dismissedEmergencyAt: Date?
    @ObservationIgnored private var lastTier: Urgency = .normal
    @ObservationIgnored private var started = false

    init() {
        profile = FileStore.load(AstronautProfile.self, from: "astra_profile.json") ?? AstronautProfile()
        alerts = FileStore.load([AlertEvent].self, from: "astra_alerts.json") ?? []
        if let raw = UserDefaults.standard.string(forKey: "comms.status"), let c = CommsStatus(rawValue: raw) { comms = c }
        let delay = UserDefaults.standard.integer(forKey: "comms.delay")
        if delay > 0 { commsDelayMinutes = delay }
        bio.onUpdate = { [weak self] in self?.refresh() }
        env.onChange = { [weak self] in self?.refresh() }
        WatchLinkReceiver.shared.onRecords = { [weak self] records in self?.bio.receive(records) }
        WatchLinkReceiver.shared.activate()
        sim.attach(bio: bio, env: env)
        sim.onScenarioStarted = { [weak self] scenario in self?.scenarioStarted(scenario) }
        refresh()
    }

    var isSimulation: Bool { bio.store.mode == .simulation }

    var dataSourceLabel: String {
        guard isSimulation else { return "Live sensor data (Apple Watch / HealthKit / manual entry)" }
        if let s = sim.active, sim.isPlaying || sim.simMinute > 0 { return "Simulation — scenario '\(s.name)' (\(s.source)) at T+\(sim.clockText)" }
        if bio.simulating { return "Simulation — suit simulator" }
        return "Simulation — manual controls"
    }

    func scenarioStarted(_ s: SimScenario) {
        if !s.context.isEmpty {
            var input = CaseInput()
            input.description = s.context
            engine.startCase(input)
        }
        lastSimAssess = .distantPast
    }

    /// Distinguishes a single abnormal reading from a sustained change across consecutive readings.
    private func persistenceNotes() -> [String] {
        var notes: [String] = []
        for m in [MetricKind.heartRate, .spo2, .respiratoryRate, .systolicBP, .bodyTemperature] {
            guard let band = normalBand(m) else { continue }
            let recent = bio.store.history(for: m, since: Date().addingTimeInterval(-3 * 3600)).suffix(4)
            guard let last = recent.last, !band.contains(last.value) else { continue }
            let abnormalRun = recent.reversed().prefix { !band.contains($0.value) }.count
            if abnormalRun >= 3 {
                notes.append("\(m.shortLabel): sustained — last \(abnormalRun) consecutive readings outside \(fmt(band.lowerBound))–\(fmt(band.upperBound)) \(m.unit)")
            } else if recent.count >= 2 {
                notes.append("\(m.shortLabel): single reading outside the normal band — confirm with a repeat measurement before acting on the trend")
            }
        }
        return notes
    }

    func start() async {
        guard !started else { return }
        started = true
        await bio.health.start()
    }

    func saveProfile() { FileStore.save(profile, to: "astra_profile.json") }

    func saveComms() {
        UserDefaults.standard.set(comms.rawValue, forKey: "comms.status")
        UserDefaults.standard.set(commsDelayMinutes, forKey: "comms.delay")
    }

    var gravity: Double { env.value(.gravity)?.value ?? 0 }
    var adaptedGravity: Double { env.value(.adaptedGravity)?.value ?? 0 }

    func refresh() {
        vitals = bio.snapshot()
        evaluation = RiskEngine.evaluate(vitals, physics: env.physics, pressureRate: env.pressureRateKPaPerMinute,
                                         gravityTransition: gravity - adaptedGravity > 1.0)
        evaluation.dataNotes += persistenceNotes()
        let tier = evaluation.tier
        if tier > lastTier, tier >= .caution, let top = evaluation.reasons.first {
            alerts.insert(AlertEvent(tierRaw: tier.rawValue, title: (isSimulation ? "[SIM] " : "") + top.title, detail: top.detail), at: 0)
            if alerts.count > 300 { alerts.removeLast(alerts.count - 300) }
            FileStore.save(alerts, to: "astra_alerts.json")
            UINotificationFeedbackGenerator().notificationOccurred(tier == .emergency ? .error : .warning)
        }
        lastTier = tier
        if tier == .emergency { triggerEmergency() }
        if isSimulation && (sim.isPlaying || sim.manualStreaming || bio.simulating) {
            // Simulated data take the same path as live data: validation → store → charts → reasoning (with AI when available).
            if !engine.isAnalyzing, Date().timeIntervalSince(lastSimAssess) > 20 {
                lastSimAssess = Date()
                let input = engine.activeCase ?? CaseInput()
                let ctx = context()
                Task { await engine.assess(input, context: ctx, kb: kb) }
            }
        } else {
            engine.autoReassessIfNeeded(context: context(), kb: kb)
        }
    }

    func context() -> ReasoningContext {
        ReasoningContext(vitals: vitals, evaluation: evaluation, physics: env.physics,
                         pressureRateKPaPerMinute: env.pressureRateKPaPerMinute,
                         environmentLines: env.physics.lines, missionLabel: env.preset.label,
                         gravity: gravity, adaptedGravity: adaptedGravity, comms: comms, commsDelayMinutes: commsDelayMinutes,
                         profile: profile, previous: nil, interventions: [], updates: [],
                         dataSource: dataSourceLabel, isSimulation: isSimulation)
    }

    func assess(_ input: CaseInput) async {
        engine.startCase(input)
        await engine.assess(input, context: context(), kb: kb)
        if let r = engine.current, r.urgency == .emergency { triggerEmergency() }
    }

    func reassess() async {
        guard let input = engine.activeCase else { return }
        await engine.assess(input, context: context(), kb: kb)
    }

    func triggerEmergency() {
        if let d = dismissedEmergencyAt, Date().timeIntervalSince(d) < 120 { return }
        guard !emergencyVisible else { return }
        if showSimulation {
            simEmergencyNotice = true
            return
        }
        emergencyStart = Date()
        crewAlerted = false
        emergencyVisible = true
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    func acknowledgeEmergency() {
        emergencyVisible = false
        dismissedEmergencyAt = Date()
    }

    func alertCrew() {
        crewAlerted = true
        alerts.insert(AlertEvent(tierRaw: Urgency.emergency.rawValue, title: "Crew alert sent (simulated)",
                                 detail: "Casualty did not respond within 30 s"), at: 0)
        FileStore.save(alerts, to: "astra_alerts.json")
    }

    func clearAlerts() {
        alerts.removeAll()
        FileStore.save(alerts, to: "astra_alerts.json")
    }

    func runExport() {
        exporter.export(records: bio.store.records, environment: env.log, reports: engine.history,
                        profile: profile, evaluation: evaluation, physics: env.physics, psych: psych)
    }
}

// MARK: - 18. Theme, logo, shared components

enum AppTab: Hashable { case overview, assistant, mind, vitals, environment, data }

enum Theme {
    static let background = Color(red: 0.04, green: 0.06, blue: 0.10)
    static let panel = Color(red: 0.09, green: 0.12, blue: 0.18)
    static let panelBorder = Color.white.opacity(0.08)
    static let accent = Color(red: 0.35, green: 0.78, blue: 1.0)
    static let secondaryText = Color.white.opacity(0.6)
}

extension Provenance {
    var color: Color {
        switch self {
        case .measured: return .green
        case .manualEntry: return .blue
        case .calculated: return .purple
        case .estimated: return .orange
        case .assumed: return .gray
        case .simulated: return .pink
        }
    }
}

struct ASTRALogo: View {
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.12, blue: 0.28), Color(red: 0.02, green: 0.04, blue: 0.10)],
                                     startPoint: .top, endPoint: .bottom))
            Ellipse()
                .stroke(Theme.accent.opacity(0.85), lineWidth: size * 0.035)
                .frame(width: size * 0.86, height: size * 0.34)
                .rotationEffect(.degrees(-22))
            Image(systemName: "cross.fill")
                .resizable().scaledToFit()
                .frame(width: size * 0.36)
                .foregroundStyle(.white)
            Image(systemName: "waveform.path.ecg")
                .resizable().scaledToFit()
                .frame(width: size * 0.30)
                .foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.35))
            Circle()
                .fill(Theme.accent)
                .frame(width: size * 0.09)
                .offset(x: size * 0.40, y: -size * 0.16)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.accent.opacity(0.4), lineWidth: max(1, size * 0.02)))
    }
}

struct Panel<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label(title, systemImage: systemImage ?? "square.grid.2x2")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.secondaryText)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.panelBorder))
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}

struct ProvenanceBadge: View {
    let provenance: Provenance
    var body: some View { Badge(text: provenance.shortLabel, color: provenance.color) }
}

struct UrgencyBadge: View {
    let urgency: Urgency
    var body: some View { Badge(text: urgency.label.uppercased(), color: urgency.color) }
}

struct BulletList: View {
    let items: [String]
    var symbol = "circle.fill"
    var color: Color = Theme.secondaryText

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 6)).foregroundStyle(color)
                    Text(item).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Normal display band for chart highlighting. General adult reference values — verify with team sources.
func normalBand(_ m: MetricKind) -> ClosedRange<Double>? {
    switch m {
    case .heartRate: return 50...100
    case .restingHeartRate: return 40...90
    case .spo2: return 94...100
    case .respiratoryRate: return 10...20
    case .bodyTemperature: return 36.0...37.8
    case .systolicBP: return 90...140
    case .diastolicBP: return 60...90
    case .bloodGlucose: return 70...180
    case .sleep: return 6...10
    case .hrv, .wristTemperature: return nil
    }
}

/// Downsamples large histories, breaks lines at data gaps, and flags abnormal points.
func chartPoints(_ records: [BiometricRecord], metric: MetricKind, maxPoints: Int = 400) -> [ChartPoint] {
    var points: [ChartPoint]
    if records.count > maxPoints {
        let chunk = Int(ceil(Double(records.count) / Double(maxPoints)))
        points = stride(from: 0, to: records.count, by: chunk).map { i in
            let slice = records[i..<min(i + chunk, records.count)]
            let mean = slice.reduce(0) { $0 + $1.value } / Double(slice.count)
            return ChartPoint(date: slice[slice.endIndex - 1].end, value: mean)
        }
    } else {
        points = records.map { ChartPoint(date: $0.end, value: $0.value) }
    }
    var segment = 0
    let band = normalBand(metric)
    for i in points.indices {
        if i > 0, points[i].date.timeIntervalSince(points[i - 1].date) > metric.expectedInterval { segment += 1 }
        points[i].segment = segment
        if let band { points[i].isAbnormal = !band.contains(points[i].value) }
    }
    return points
}

// MARK: - 19. Root view

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Overview", systemImage: "gauge.with.dots.needle.67percent", value: AppTab.overview) { DashboardView() }
            Tab("Assistant", systemImage: "cross.case.fill", value: AppTab.assistant) { MedicalAssistantView() }
            Tab("Mind", systemImage: "brain.head.profile", value: AppTab.mind) { PsychologicalDashboardView() }
            Tab("Vitals", systemImage: "chart.xyaxis.line", value: AppTab.vitals) { BiometricChartsView() }
            Tab("Environment", systemImage: "aqi.medium", value: AppTab.environment) { EnvironmentalMonitoringView() }
            Tab("Data", systemImage: "externaldrive.fill", value: AppTab.data) { DataView() }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isSimulation { SimulationModeBanner() }
        }
        .environment(model)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .fullScreenCover(isPresented: $model.emergencyVisible) {
            EmergencyView().environment(model)
        }
        .sheet(isPresented: $model.showSimulation) {
            SimulationDashboardView().environment(model)
        }
        .task { await model.start() }
    }
}

// MARK: - 20. DashboardView

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    statusStrip
                    TierCard(evaluation: model.evaluation)
                    WellbeingCard()
                    vitalsGrid
                    liveHeartRate
                    environmentSummary
                    recentAlerts
                }
                .padding()
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ASTRALogo(size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("ASTRA").font(.title2.weight(.heavy)).tracking(3)
                Text("Autonomous Space Triage & Response Assistant").font(.caption2).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.profile.name).font(.caption.weight(.semibold))
                Text(model.env.preset.label).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
        }
    }

    private var statusStrip: some View {
        let health = model.bio.health
        let collecting = health.isStreaming || model.bio.simulating
        return Panel(title: "System status", systemImage: "antenna.radiowaves.left.and.right") {
            HStack(alignment: .top, spacing: 12) {
                statusItem("Data", collecting ? (model.bio.simulating ? "Simulation" : "Apple Watch live") : "Not collecting",
                           collecting ? .green : .orange)
                statusItem("AI", model.engine.ai.isAvailable ? "On-device" : "Offline protocols", model.engine.ai.isAvailable ? .green : .yellow)
                statusItem("Comms", model.comms.label, model.comms == .available ? .green : .orange)
            }
            if let last = model.bio.store.lastUpdate {
                Text("Last data \(last.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(Theme.secondaryText)
            }
            if let err = health.errorMessage { Text(err).font(.caption2).foregroundStyle(.orange) }
            ForEach(model.evaluation.dataNotes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.yellow) }
        }
    }

    private func statusItem(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(value).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var vitalsGrid: some View {
        let metrics: [MetricKind] = [.heartRate, .spo2, .hrv, .respiratoryRate, .bodyTemperature, .systolicBP, .restingHeartRate, .sleep]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(metrics) { m in
                VitalTile(metric: m, summary: model.bio.summary(m),
                          flagged: model.evaluation.reasons.first { $0.metric == m }?.tier)
                    .onTapGesture { model.selectedTab = .vitals }
            }
        }
    }

    private var liveHeartRate: some View {
        let since = Date().addingTimeInterval(-3600)
        let pts = chartPoints(model.bio.store.history(for: .heartRate, since: since), metric: .heartRate)
        return Panel(title: "Heart rate — last hour", systemImage: "heart.fill") {
            if pts.isEmpty {
                MissingDataView(text: "No heart-rate samples in the last hour.")
            } else {
                Chart(pts) { p in
                    LineMark(x: .value("Time", p.date), y: .value("bpm", p.value), series: .value("Segment", p.segment))
                        .foregroundStyle(Color.red)
                        .interpolationMethod(.monotone)
                    if p.isAbnormal {
                        PointMark(x: .value("Time", p.date), y: .value("bpm", p.value)).foregroundStyle(.orange).symbolSize(20)
                    }
                }
                .chartXScale(domain: since...Date())
                .frame(height: 140)
            }
        }
    }

    private var environmentSummary: some View {
        let physics = model.env.physics
        return Panel(title: "Environment", systemImage: "aqi.medium") {
            ForEach([EnvironmentKind.cabinPressure, .oxygenFraction, .gravity]) { k in
                if let p = model.env.value(k) {
                    HStack {
                        Text(k.label).font(.callout)
                        Spacer()
                        Text("\(fmt(p.value, k.digits)) \(k.unit)").font(.callout.monospacedDigit())
                        ProvenanceBadge(provenance: p.provenance)
                    }
                }
            }
            if let b = physics.boiling?.celsius {
                HStack {
                    Text("Water boiling point").font(.callout)
                    Spacer()
                    Text("\(fmt(b, 1)) °C").font(.callout.monospacedDigit())
                    ProvenanceBadge(provenance: .calculated)
                }
            }
            if let m = physics.armstrongMarginKPa {
                HStack {
                    Text("Armstrong margin").font(.callout)
                    Spacer()
                    Text("\(fmt(m, 1)) kPa").font(.callout.monospacedDigit()).foregroundStyle(m <= 0 ? .red : m < 20 ? .orange : .primary)
                    ProvenanceBadge(provenance: .calculated)
                }
            }
        }
        .onTapGesture { model.selectedTab = .environment }
    }

    private var recentAlerts: some View {
        Panel(title: "Recent alerts", systemImage: "bell.badge.fill") {
            if model.alerts.isEmpty {
                Text("No alerts recorded.").font(.callout).foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(model.alerts.prefix(5)) { a in
                    HStack(alignment: .top) {
                        UrgencyBadge(urgency: a.tier)
                        VStack(alignment: .leading) {
                            Text(a.title).font(.callout.weight(.semibold))
                            Text(a.detail).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Text(a.time.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
    }
}

struct TierCard: View {
    let evaluation: Evaluation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: evaluation.tier >= .urgent ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                Text(evaluation.tier.label.uppercased()).font(.title3.weight(.heavy)).tracking(2)
                Spacer()
                Text(Date().formatted(date: .omitted, time: .shortened)).font(.caption).opacity(0.8)
            }
            Text(evaluation.tier.action).font(.callout)
            ForEach(evaluation.reasons.prefix(3)) { r in
                Text("• \(r.title): \(r.detail)").font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(evaluation.tier.color.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(evaluation.tier.color.opacity(0.7), lineWidth: 1.5))
    }
}

struct VitalTile: View {
    let metric: MetricKind
    let summary: MetricSummary?
    let flagged: Urgency?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: metric.systemImage).foregroundStyle(flagged?.color ?? Theme.accent)
                Text(metric.shortLabel).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                Spacer()
                if let p = summary?.latestProvenance { ProvenanceBadge(provenance: p) }
            }
            if let v = summary?.latestValue {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(fmt(v, metric.digits)).font(.title2.weight(.bold).monospacedDigit())
                    Text(metric.unit).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                HStack(spacing: 4) {
                    if let at = summary?.latestAt { Text(at.formatted(.relative(presentation: .numeric))) }
                    if summary?.isStale == true { Text("· stale").foregroundStyle(.yellow) }
                    if let z = summary?.zScore { Text("· z \(fmt(z, 1))").foregroundStyle(abs(z) >= 2 ? .orange : Theme.secondaryText) }
                }
                .font(.caption2).foregroundStyle(Theme.secondaryText)
            } else {
                Text("—").font(.title2.weight(.bold))
                Text("No data").font(.caption2).foregroundStyle(.yellow)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(flagged.map { $0.color.opacity(0.7) } ?? Theme.panelBorder))
    }
}

struct MissingDataView: View {
    let text: String
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.yellow)
            Text(text).font(.callout).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
    }
}

// MARK: - 21. MedicalAssistantView

struct MedicalAssistantView: View {
    @Environment(AppModel.self) private var model
    @State private var input = CaseInput()
    @State private var updateText = ""
    @State private var hasPain = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    aiStatus
                    caseForm
                    if let r = model.engine.current {
                        ReportView(report: r)
                        followUp
                    }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Medical Assistant")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(DemoCase.allCases) { d in
                            Button(d.label) {
                                input = d.input
                                hasPain = d.input.painScore != nil
                                switch d {
                                case .legLaceration:
                                    if !model.bio.simulating { model.bio.startSimulation() }
                                    model.bio.deteriorating = true
                                case .depressurizationHypoxia:
                                    if !model.bio.simulating { model.bio.startSimulation() }
                                    model.bio.deteriorating = true
                                    model.env.startDepressurizationDemo()
                                default:
                                    break
                                }
                            }
                        }
                    } label: { Label("Demo cases", systemImage: "theatermasks") }
                }
            }
        }
    }

    private var aiStatus: some View {
        HStack(alignment: .top) {
            Image(systemName: model.engine.ai.isAvailable ? "cpu.fill" : "cpu")
                .foregroundStyle(model.engine.ai.isAvailable ? .green : .yellow)
            Text(model.engine.ai.statusText).font(.caption).foregroundStyle(Theme.secondaryText)
            Spacer()
        }
    }

    private var caseForm: some View {
        Panel(title: "Describe the situation", systemImage: "square.and.pencil") {
            TextField("What happened? What does the crew member feel or what do you see?", text: $input.description, axis: .vertical)
                .lineLimit(3...8)
                .padding(10)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))

            TextField("Mechanism (e.g., struck by hatch, sharp edge)", text: $input.mechanism)
                .padding(10)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Picker("Bleeding", selection: $input.bleeding) {
                    ForEach(BleedingStatus.allCases) { Text($0.label).tag($0) }
                }
                Picker("Consciousness", selection: $input.consciousness) {
                    ForEach(Consciousness.allCases) { Text($0.label).tag($0) }
                }
            }
            .pickerStyle(.menu)

            Toggle("Pain score", isOn: $hasPain)
                .onChange(of: hasPain) { _, on in input.painScore = on ? (input.painScore ?? 5) : nil }
            if hasPain {
                Stepper("Pain \(input.painScore ?? 5)/10", value: Binding(get: { input.painScore ?? 5 }, set: { input.painScore = $0 }), in: 0...10)
            }
            Stepper("Onset: \(input.onsetMinutesAgo.map { "\($0) min ago" } ?? "unknown")",
                    value: Binding(get: { input.onsetMinutesAgo ?? 0 }, set: { input.onsetMinutesAgo = $0 }), in: 0...10080, step: 5)

            Text("Body regions").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            ChipGrid(items: BodyRegion.allCases, label: \.label, selection: $input.regions)
            Text("Findings").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            ChipGrid(items: ClinicalFinding.allCases, label: \.label, selection: $input.findings)

            HStack {
                Button {
                    input.createdAt = Date()
                    Task { await model.assess(input) }
                } label: {
                    Label(model.engine.isAnalyzing ? "Analyzing…" : "Assess", systemImage: "stethoscope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.engine.isAnalyzing)

                Button("Clear") {
                    input = CaseInput()
                    hasPain = false
                    model.engine.closeCase()
                }
                .buttonStyle(.bordered)
            }
            Text("Leave everything empty and tap Assess for a vitals-only assessment.").font(.caption2).foregroundStyle(Theme.secondaryText)
        }
    }

    private var followUp: some View {
        Panel(title: "Case updates & interventions", systemImage: "arrow.triangle.2.circlepath") {
            HStack {
                TextField("New observation (e.g., bleeding stopped, now pale)", text: $updateText)
                    .textFieldStyle(.roundedBorder)
                Button("Update") {
                    let note = updateText.trimmingCharacters(in: .whitespaces)
                    guard !note.isEmpty else { return }
                    model.engine.addUpdate(note)
                    updateText = ""
                    Task { await model.reassess() }
                }
                .buttonStyle(.bordered)
                .disabled(model.engine.activeCase == nil)
            }
            if model.engine.activeCase == nil {
                Text("Start a case with Assess to log updates.").font(.caption).foregroundStyle(Theme.secondaryText)
            }
            ForEach(model.engine.updates.reversed()) { u in
                Text("\(u.time.formatted(date: .omitted, time: .shortened)) — \(u.note)").font(.caption)
            }
            ForEach(model.engine.interventions.reversed()) { i in
                Text("\(i.time.formatted(date: .omitted, time: .shortened)) — \(i.action) → \(i.result)").font(.caption).foregroundStyle(.green)
            }
            Button {
                Task { await model.reassess() }
            } label: { Label("Reassess now", systemImage: "arrow.clockwise") }
                .disabled(model.engine.activeCase == nil || model.engine.isAnalyzing)
        }
    }
}

struct ChipGrid<Item: Hashable & Identifiable>: View {
    let items: [Item]
    let label: KeyPath<Item, String>
    @Binding var selection: Set<Item>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                let on = selection.contains(item)
                Button {
                    if on { selection.remove(item) } else { selection.insert(item) }
                } label: {
                    Text(item[keyPath: label])
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(on ? Theme.accent.opacity(0.3) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.accent : .clear))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ReportView: View {
    @Environment(AppModel.self) private var model
    let report: ClinicalReport

    var body: some View {
        VStack(spacing: 12) {
            banner
            if !report.assessFirst.isEmpty {
                Panel(title: "A · Assess first", systemImage: "eye.fill") { BulletList(items: report.assessFirst, symbol: "1.circle.fill", color: Theme.accent) }
            }
            Panel(title: "C · Step-by-step guidance", systemImage: "list.number") {
                ForEach(Array(report.steps.enumerated()), id: \.element.id) { i, s in
                    StepCard(index: i + 1, step: s, report: report)
                }
            }
            Panel(title: "B · Possible explanations (not diagnoses)", systemImage: "questionmark.diamond.fill") {
                if report.differentials.isEmpty {
                    Text("No specific pattern identified. Use the structured assessment and missing information below.").font(.callout)
                }
                ForEach(report.differentials) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(d.name).font(.callout.weight(.semibold))
                            Spacer()
                            Badge(text: d.likelihood.label, color: d.likelihood == .higher ? .orange : .gray)
                            Badge(text: d.basis.label, color: d.basis == .aiInference ? .pink : .blue)
                        }
                        if !d.supporting.isEmpty { Text("For: " + d.supporting.joined(separator: "; ")).font(.caption) }
                        if !d.against.isEmpty { Text("Against / unknown: " + d.against.joined(separator: "; ")).font(.caption).foregroundStyle(Theme.secondaryText) }
                        if !d.sourceIDs.isEmpty { Text("Sources: " + d.sourceIDs.joined(separator: ", ")).font(.caption2).foregroundStyle(Theme.accent) }
                    }
                    Divider()
                }
            }
            Panel(title: "F · What is known and what is not", systemImage: "scalemass.fill") {
                section("Confirmed observations", report.confirmed, .green)
                section("Supported by sources", report.evidenceSupported, .blue)
                section("Uncertain", report.uncertain, .yellow)
                section("Needs qualified medical assistance", report.needsQualifiedHelp, .red)
                section("Missing information", report.missingInformation, .orange)
            }
            Panel(title: "D · Reassessment", systemImage: "arrow.triangle.2.circlepath") {
                Text("Reassess in \(report.reassessInMinutes) min").font(.callout.weight(.semibold))
                section("Monitor", report.monitoring, Theme.accent)
                section("Signs of improvement", report.improvingSigns, .green)
                section("Signs of deterioration", report.deterioratingSigns, .red)
            }
            Panel(title: "Escalation & contraindications", systemImage: "exclamationmark.octagon.fill") {
                section("Escalate when", report.escalation, .orange)
                section("Do not", report.contraindications, .red)
            }
            if !report.supplies.isEmpty {
                Panel(title: "Supplies to prepare", systemImage: "shippingbox.fill") { BulletList(items: report.supplies) }
            }
            Panel(title: "E · Mission context", systemImage: "globe.americas.fill") { BulletList(items: report.missionNotes) }
            Panel(title: "Sources", systemImage: "books.vertical.fill") {
                if report.sources.isEmpty {
                    Text("No knowledge-base sources matched. Guidance is from built-in safety protocols.").font(.callout)
                }
                ForEach(report.sources) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("[\(s.id)] \(s.title)").font(.caption.weight(.semibold))
                            Spacer()
                            Badge(text: s.evidence.short, color: s.evidence == .D ? .gray : .green)
                        }
                        Text(s.citation).font(.caption2).foregroundStyle(Theme.secondaryText)
                        if let u = s.url, let url = URL(string: u) { Link(u, destination: url).font(.caption2) }
                    }
                }
            }
            if !report.safetyNotes.isEmpty {
                Panel(title: "Safety validator changes", systemImage: "shield.lefthalf.filled") { BulletList(items: report.safetyNotes, color: .yellow) }
            }
            Text("ASTRA is decision support, not a diagnosis. Actions marked CMO or AUTH REQUIRED need the Crew Medical Officer or flight-surgeon authorization.")
                .font(.caption2).foregroundStyle(Theme.secondaryText)
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                UrgencyBadge(urgency: report.urgency)
                Spacer()
                Text(report.createdAt.formatted(date: .omitted, time: .standard)).font(.caption2)
            }
            Text(report.summary).font(.headline)
            if let src = report.dataSource {
                Label(src, systemImage: src.hasPrefix("Simulation") ? "testtube.2" : "sensor.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(src.hasPrefix("Simulation") ? .pink : Theme.secondaryText)
            }
            Text(report.urgency.action).font(.callout)
            ForEach(report.urgencyRationale.prefix(4), id: \.self) { Text("• \($0)").font(.caption) }
            if let t = report.trend { Text("Trend: \(t)").font(.caption).foregroundStyle(Theme.accent) }
            HStack {
                Image(systemName: report.aiUsed ? "sparkles" : "cpu")
                Text(report.aiNote).font(.caption2)
            }
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(report.urgency.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(report.urgency.color.opacity(0.7), lineWidth: 1.5))
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [String], _ color: Color) -> some View {
        if !items.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            BulletList(items: items, color: color)
        }
    }
}

struct StepCard: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let step: GuidanceStep
    let report: ClinicalReport
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
                    .background(step.timeCritical ? Color.red : Theme.accent.opacity(0.6), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.phase.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondaryText)
                    Text(step.action).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Badge(text: step.authority.short, color: step.authority == .crew ? .green : step.authority == .crewMedicalOfficer ? .orange : .red)
                        Badge(text: step.basis.label, color: step.basis == .aiInference ? .pink : .blue)
                        if step.timeCritical { Badge(text: "TIME-CRITICAL", color: .red) }
                    }
                }
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    detail("Why", [step.purpose])
                    detail("Equipment", step.equipment)
                    detail("Precautions", step.precautions)
                    detail("Expect to see", step.expectedObservations)
                    detail("Reassess if", step.reassessIf)
                    if let u = step.ifUnsuccessful { detail("If unsuccessful", [u]) }
                    if !step.sourceIDs.isEmpty { detail("Sources", step.sourceIDs) }
                    if model.engine.activeCase != nil {
                        HStack {
                            ForEach(["Improved", "No change", "Worse"], id: \.self) { result in
                                Button(result) { model.engine.logIntervention(step.action, result: result) }
                                    .buttonStyle(.bordered).font(.caption)
                            }
                        }
                    }
                }
            } label: {
                Text("Details").font(.caption)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func detail(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty && !(items.count == 1 && items[0].isEmpty) {
            Text(title).font(.caption2.weight(.bold)).foregroundStyle(Theme.secondaryText)
            BulletList(items: items)
        }
    }
}

// MARK: - 22. BiometricChartsView

nonisolated enum ChartRange: String, CaseIterable, Identifiable {
    case hour = "1 h", sixHours = "6 h", day = "24 h", week = "7 d", month = "30 d"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        }
    }
}

struct BiometricChartsView: View {
    @Environment(AppModel.self) private var model
    @State private var range: ChartRange = .day

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Picker("Range", selection: $range) {
                        ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 10) {
                        legend(.red, "Value")
                        legend(.orange, "Outside normal band")
                        legend(.gray, "Baseline (14 d)")
                        legend(.yellow, "Gap = missing data")
                    }
                    .font(.caption2)
                    ForEach(MetricKind.allCases) { m in
                        MetricChartCard(metric: m, range: range)
                    }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Vitals")
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).foregroundStyle(Theme.secondaryText)
        }
    }
}

struct MetricChartCard: View {
    @Environment(AppModel.self) private var model
    let metric: MetricKind
    let range: ChartRange

    var body: some View {
        let start = Date().addingTimeInterval(-range.seconds)
        let records = model.bio.store.history(for: metric, since: start)
        let pts = chartPoints(records, metric: metric)
        let summary = model.bio.summary(metric)
        return Panel(title: metric.label, systemImage: metric.systemImage) {
            HStack(alignment: .firstTextBaseline) {
                if let v = summary?.latestValue {
                    Text("\(fmt(v, metric.digits)) \(metric.unit)").font(.title3.weight(.bold).monospacedDigit())
                    if let p = summary?.latestProvenance { ProvenanceBadge(provenance: p) }
                } else {
                    Text("No data").font(.title3.weight(.bold)).foregroundStyle(.yellow)
                }
                Spacer()
                if let at = summary?.latestAt {
                    Text(at.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Theme.secondaryText)
                }
            }
            HStack(spacing: 10) {
                if let b = summary?.baselineMean { Text("Baseline \(fmt(b, metric.digits))") }
                if let z = summary?.zScore { Text("z \(fmt(z, 1))").foregroundStyle(abs(z) >= 2 ? .orange : Theme.secondaryText) }
                if let s = summary?.slopePerHour6h { Text("6 h trend \(signed(s, 1))/h") }
                Text("n = \(records.count)")
            }
            .font(.caption).foregroundStyle(Theme.secondaryText)
            ForEach(summary?.anomalies ?? [], id: \.self) { Text("⚠︎ \($0)").font(.caption).foregroundStyle(.orange) }

            if pts.isEmpty {
                MissingDataView(text: summary?.latestValue == nil ? "No samples recorded for this metric." : "No samples in the selected range.")
            } else {
                Chart {
                    if let band = normalBand(metric) {
                        RectangleMark(xStart: .value("Start", start), xEnd: .value("End", Date()),
                                      yStart: .value("Low", band.lowerBound), yEnd: .value("High", band.upperBound))
                            .foregroundStyle(Color.green.opacity(0.08))
                    }
                    if let b = summary?.baselineMean {
                        RuleMark(y: .value("Baseline", b)).foregroundStyle(.gray).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    ForEach(pts) { p in
                        LineMark(x: .value("Time", p.date), y: .value(metric.unit, p.value), series: .value("Segment", p.segment))
                            .foregroundStyle(Color.red)
                    }
                    ForEach(pts.filter(\.isAbnormal)) { p in
                        PointMark(x: .value("Time", p.date), y: .value(metric.unit, p.value)).foregroundStyle(.orange).symbolSize(18)
                    }
                    if pts.count == 1, let p = pts.first {
                        PointMark(x: .value("Time", p.date), y: .value(metric.unit, p.value)).foregroundStyle(.red)
                    }
                }
                .chartXScale(domain: start...Date())
                .frame(height: 150)
                if summary?.isStale == true {
                    Text("Data are older than the expected update interval.").font(.caption2).foregroundStyle(.yellow)
                }
            }
        }
    }
}

// MARK: - 23. EnvironmentalMonitoringView

struct EnvironmentalMonitoringView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EnvironmentKind?
    @State private var editValue: Double?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Panel(title: "Mission profile", systemImage: "globe.europe.africa.fill") {
                        Picker("Preset", selection: Binding(get: { model.env.preset }, set: { model.env.applyPreset($0) })) {
                            ForEach(MissionPreset.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        Text("Preset values are labeled ASSUMED. Replace them with measured or crew-entered values whenever available.")
                            .font(.caption2).foregroundStyle(Theme.secondaryText)
                        Picker("Communications", selection: $model.comms) {
                            ForEach(CommsStatus.allCases) { Text($0.label).tag($0) }
                        }
                        .onChange(of: model.comms) { _, _ in model.saveComms() }
                        if model.comms == .delayed {
                            Stepper("One-way delay: \(model.commsDelayMinutes) min", value: $model.commsDelayMinutes, in: 1...45)
                                .onChange(of: model.commsDelayMinutes) { _, _ in model.saveComms() }
                        }
                    }

                    Panel(title: "Parameters", systemImage: "slider.horizontal.3") {
                        ForEach(EnvironmentKind.allCases) { k in
                            parameterRow(k)
                            Divider()
                        }
                    }

                    Panel(title: "Sensors & simulation", systemImage: "sensor.fill") {
                        Toggle("iPhone barometer (measured)", isOn: Binding(get: { model.env.barometerActive },
                                                                           set: { $0 ? model.env.startBarometer() : model.env.stopBarometer() }))
                        if let m = model.env.barometerMessage { Text(m).font(.caption).foregroundStyle(.yellow) }
                        Toggle("Depressurization demo (simulated)", isOn: Binding(get: { model.env.depressurizing },
                                                                                 set: { $0 ? model.env.startDepressurizationDemo() : model.env.stopDepressurizationDemo() }))
                        Text("Simulated values are never treated as sensor data; they are labeled SIM everywhere and in exports.")
                            .font(.caption2).foregroundStyle(Theme.secondaryText)
                    }

                    pressureChart
                    physicsPanel
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Environment")
            .sheet(item: $editing) { k in
                NavigationStack {
                    Form {
                        Section(k.label) {
                            TextField("Value (\(k.unit))", value: $editValue, format: .number)
                                .keyboardType(.decimalPad)
                            Text("Valid range \(fmt(k.validRange.lowerBound)) – \(fmt(k.validRange.upperBound)) \(k.unit)")
                                .font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .navigationTitle("Crew entry")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                if let v = editValue, v.isFinite, k.validRange.contains(v) { model.env.setManual(k, v) }
                                editing = nil
                            }
                            .disabled(editValue.map { !k.validRange.contains($0) } ?? true)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func parameterRow(_ k: EnvironmentKind) -> some View {
        let p = model.env.value(k)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(k.label).font(.callout.weight(.semibold))
                if let p {
                    Text("\(p.source) · \(p.timestamp.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                    if !p.isValid { Text("Outside validation range").font(.caption2).foregroundStyle(.red) }
                } else {
                    Text("Not available").font(.caption2).foregroundStyle(.yellow)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let p {
                    Text("\(fmt(p.value, k.digits)) \(k.unit)").font(.callout.monospacedDigit())
                    if let u = p.uncertainty { Text("± \(fmt(u, k.digits)) \(k.unit)").font(.caption2).foregroundStyle(Theme.secondaryText) }
                    ProvenanceBadge(provenance: p.provenance)
                }
            }
            Button {
                editValue = p?.value
                editing = k
            } label: { Image(systemName: "pencil.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
        }
    }

    private var pressureChart: some View {
        let since = Date().addingTimeInterval(-15 * 60)
        let log = model.env.log.filter { $0.kind == .cabinPressure && $0.timestamp >= since }
        return Panel(title: "Ambient pressure — last 15 min", systemImage: "gauge.with.needle") {
            if log.count < 2 {
                MissingDataView(text: "Not enough pressure history. Enable the barometer or the demo.")
            } else {
                Chart {
                    RuleMark(y: .value("Armstrong", PhysicalModelCalculator.armstrongLimitKPa))
                        .foregroundStyle(.red)
                        .annotation(position: .top, alignment: .leading) { Text("Armstrong limit").font(.caption2).foregroundStyle(.red) }
                    ForEach(log, id: \.timestamp) { p in
                        LineMark(x: .value("Time", p.timestamp), y: .value("kPa", p.value))
                            .foregroundStyle(p.provenance.color)
                        PointMark(x: .value("Time", p.timestamp), y: .value("kPa", p.value))
                            .foregroundStyle(p.provenance.color).symbolSize(10)
                    }
                }
                .frame(height: 150)
                if let r = model.env.pressureRateKPaPerMinute {
                    Text("Rate: \(signed(r, 2)) kPa/min").font(.caption).foregroundStyle(r < -1 ? .red : Theme.secondaryText)
                }
            }
        }
    }

    private var physicsPanel: some View {
        let ph = model.env.physics
        return Panel(title: "Physical models (calculated)", systemImage: "function") {
            if let b = ph.boiling {
                row("Water boiling point (Antoine)", b.celsius.map { "\(fmt($0, 1)) °C ± \(fmt(b.uncertainty, 1))" } ?? "—", .calculated)
                Text(b.modelNote).font(.caption2).foregroundStyle(b.inValidityRange ? Theme.secondaryText : .yellow)
            }
            row("Armstrong limit", "\(fmt(ph.armstrongLimitKPa, 2)) kPa", .calculated)
            if let m = ph.armstrongMarginKPa { row("Margin above limit", "\(fmt(m, 1)) kPa", .calculated) }
            if let i = ph.inspiredO2mmHg { row("Inspired PO₂", "\(fmt(i)) mmHg", .calculated) }
            if let a = ph.alveolarO2mmHg { row("Alveolar PO₂ (alveolar gas eq.)", "\(fmt(a)) mmHg", .estimated) }
            if let s = ph.expectedSpO2 { row("Expected SpO₂ (Severinghaus)", "\(fmt(s))%", .estimated) }
            if let h = ph.hydrostaticCurrentMmHg { row("Heart-to-brain hydrostatic gradient", "\(fmt(h, 1)) mmHg", .calculated) }
            if let d = ph.orthostaticLoadChangeMmHg { row("Change vs adapted gravity", "\(signed(d, 1)) mmHg", .calculated) }
            Text("Assumptions").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            BulletList(items: ph.assumptions)
            Text("Gravity is applied only to established models (hydrostatic pressure). It is not applied to physiology without a validated model.")
                .font(.caption2).foregroundStyle(Theme.secondaryText)
        }
    }

    private func row(_ title: String, _ value: String, _ prov: Provenance) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Text(value).font(.callout.monospacedDigit())
            ProvenanceBadge(provenance: prov)
        }
    }
}

// MARK: - 24. DataView (collection, manual entry, export, Sheets, knowledge, profile)

struct DataView: View {
    @Environment(AppModel.self) private var model
    @State private var manual: [MetricKind: Double] = [:]
    @State private var manualMessage: String?
    @State private var importing = false
    @State private var iconURL: URL?
    @State private var templateURL: URL?
    @State private var bgRefresh = 0

    private let manualMetrics: [MetricKind] = [.heartRate, .spo2, .respiratoryRate, .bodyTemperature, .systolicBP, .diastolicBP, .bloodGlucose]

    var body: some View {
        @Bindable var model = model
        @Bindable var exporter = model.exporter
        @Bindable var sheets = model.bio.sheets
        @Bindable var bio = model.bio
        NavigationStack {
            Form {
                Section("Data collection") {
                    LabeledContent("Apple Watch / HealthKit", value: model.bio.health.isStreaming ? "Streaming" : "Stopped")
                    if let e = model.bio.health.errorMessage { Text(e).font(.caption).foregroundStyle(.orange) }
                    Button("Restart HealthKit stream") { Task { await model.bio.health.restart() } }
                    LabeledContent("Stored records", value: "\(model.bio.store.records.count)")
                    LabeledContent("Rejected (invalid)", value: "\(model.bio.rejectedCount)")
                    if let r = model.bio.lastRejection { Text(r).font(.caption).foregroundStyle(Theme.secondaryText) }
                    Text("Watch heart rate syncs to the iPhone periodically; open the Heart Rate app on the Watch or start a workout for denser data. Denied Health permissions appear as missing data.")
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                }

                Section("Background alerts & Apple Watch link") {
                    let _ = bgRefresh
                    Text(BackgroundHealthMonitor.status).font(.callout)
                    if let t = BackgroundHealthMonitor.lastCheck {
                        Text("Last background check: \(t.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    }
                    Text(WatchLinkReceiver.shared.statusText).font(.callout)
                    ForEach(BackgroundHealthMonitor.log.prefix(5), id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    Button("Refresh status") { bgRefresh += 1 }
                    Text("When ASTRA is closed, iOS wakes it as new Health data arrives (iOS controls the timing) and Urgent/Emergency readings trigger a notification. For second-by-second monitoring, run a session in the ASTRA Watch app.")
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                }

                Section("Simulation Mode (testing)") {
                    LabeledContent("Current mode", value: model.isSimulation ? "SIMULATION" : "LIVE")
                    Button {
                        model.showSimulation = true
                    } label: { Label("Open Simulation Mode", systemImage: "slider.horizontal.below.rectangle") }
                    Text("Manual controls, scenario playback, CSV and Google Sheets datasets. Simulated data are kept separate from real measurements.")
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                }

                Section("Suit simulation (labeled SIM)") {
                    Toggle("Run suit simulation", isOn: Binding(get: { model.bio.simulating },
                                                                set: { $0 ? model.bio.startSimulation() : model.bio.stopSimulation() }))
                    Toggle("Deterioration pattern (blood-loss-like)", isOn: $bio.deteriorating)
                    Button("Delete simulated data", role: .destructive) { model.bio.clearSimulated() }
                }

                Section("Manual measurement") {
                    ForEach(manualMetrics) { m in
                        HStack {
                            Text(m.shortLabel)
                            Spacer()
                            TextField(m.unit, value: Binding(get: { manual[m] }, set: { manual[m] = $0 }), format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 110)
                        }
                    }
                    Button("Save measurements") {
                        let values = manual
                        let saved = model.bio.logManual(values)
                        manualMessage = "Saved \(saved) of \(values.count). Values outside plausible ranges are rejected."
                        manual = [:]
                    }
                    .disabled(manual.isEmpty)
                    if let m = manualMessage { Text(m).font(.caption) }
                }

                Section("Export") {
                    Picker("Range", selection: $exporter.range) {
                        ForEach(ExportRange.allCases) { Text($0.label).tag($0) }
                    }
                    ForEach(ExportFormat.allCases) { f in
                        Toggle(f.label, isOn: Binding(get: { exporter.formats.contains(f) },
                                                      set: { on in if on { exporter.formats.insert(f) } else { exporter.formats.remove(f) } }))
                    }
                    DisclosureGroup("Metrics (\(exporter.metrics.count))") {
                        ForEach(MetricKind.allCases) { m in
                            Toggle(m.label, isOn: Binding(get: { exporter.metrics.contains(m) },
                                                          set: { on in if on { exporter.metrics.insert(m) } else { exporter.metrics.remove(m) } }))
                        }
                    }
                    Toggle("De-identify (remove name and profile)", isOn: $exporter.deidentify)
                    Button("Prepare export") { model.runExport() }
                    if !exporter.files.isEmpty {
                        ShareLink(items: exporter.files) { Label("Share \(exporter.files.count) file(s)", systemImage: "square.and.arrow.up") }
                    }
                    if let m = exporter.message { Text(m).font(.caption) }
                }

                Section("Google Sheets (team editing)") {
                    TextField("Web app URL (https://…/exec)", text: $sheets.webAppURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: sheets.webAppURL) { _, _ in sheets.saveSettings() }
                    SecureField("Token", text: $sheets.token)
                        .onChange(of: sheets.token) { _, _ in sheets.saveSettings() }
                    Toggle("Auto-upload new records", isOn: $sheets.autoUpload)
                        .onChange(of: sheets.autoUpload) { _, _ in sheets.saveSettings() }
                    LabeledContent("Pending upload", value: "\(sheets.pendingCount(model.bio.store.records))")
                    Button("Upload now") { Task { await sheets.upload(model.bio.store.records) } }
                        .disabled(sheets.isBusy)
                    Button("Download sheet edits") {
                        Task {
                            if let rows = await sheets.pullEdits() {
                                let n = model.bio.applySheetEdits(rows)
                                sheets.status = "Applied \(n) edited rows from the sheet."
                            }
                        }
                    }
                    .disabled(sheets.isBusy)
                    Button("Reset upload history") { sheets.resetUploadHistory() }
                    if let s = sheets.status { Text(s).font(.caption) }
                    if sheets.isBusy { ProgressView() }
                }

                Section("Medical knowledge base") {
                    LabeledContent("Documents", value: "\(model.kb.documents.count) (\(model.kb.importedCount) imported)")
                    LabeledContent("Supply items", value: "\(model.kb.supplies.count)\(model.kb.usingExampleKit ? " (example kit)" : "")")
                    Button("Import sources (JSON)") { importing = true }
                    Button("Create JSON template") {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ASTRA_knowledge_template.json")
                        try? Data(MedicalKnowledgeBase.templateJSON.utf8).write(to: url)
                        templateURL = url
                    }
                    if let templateURL { ShareLink(item: templateURL) { Label("Share template", systemImage: "doc.badge.plus") } }
                    NavigationLink("Browse documents") { KnowledgeListView() }
                    Button("Remove imported sources", role: .destructive) { model.kb.resetImported() }
                    if let m = model.kb.message { Text(m).font(.caption) }
                }

                Section("Crew profile") {
                    TextField("Name", text: $model.profile.name)
                    TextField("Role", text: $model.profile.role)
                    TextField("Age", value: $model.profile.age, format: .number).keyboardType(.numberPad)
                    TextField("Allergies", text: $model.profile.allergies)
                    TextField("Medical conditions", text: $model.profile.conditions)
                    TextField("Current medications", text: $model.profile.medications)
                    Picker("Responder training", selection: $model.profile.responderTraining) {
                        ForEach(MedicalTraining.allCases) { Text($0.label).tag($0) }
                    }
                    Button("Save profile") { model.saveProfile() }
                }

                Section("On-device AI") {
                    Text(model.engine.ai.statusText).font(.callout)
                    Text("Without Apple Intelligence, ASTRA still runs the full offline protocol engine and knowledge-base retrieval.")
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                }

                Section("App icon") {
                    HStack {
                        ASTRALogo(size: 64)
                        Spacer()
                        Button("Render 1024 px PNG") {
                            let renderer = ImageRenderer(content: ASTRALogo(size: 1024))
                            renderer.scale = 1
                            if let data = renderer.uiImage?.pngData() {
                                let url = FileManager.default.temporaryDirectory.appendingPathComponent("ASTRA_AppIcon_1024.png")
                                try? data.write(to: url)
                                iconURL = url
                            }
                        }
                    }
                    if let iconURL { ShareLink(item: iconURL) { Label("Share icon PNG", systemImage: "photo") } }
                }

                Section {
                    Button("Clear alert history", role: .destructive) { model.clearAlerts() }
                } footer: {
                    Text("ASTRA provides decision support for crew self-care and does not replace a physician. All data are stored on this device with iOS Data Protection.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Data")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { model.kb.importFile(url) }
            }
        }
    }
}

struct KnowledgeListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Documents") {
                ForEach(model.kb.documents) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(d.title).font(.callout.weight(.semibold))
                            Spacer()
                            Badge(text: d.evidence.short, color: d.evidence == .D ? .gray : .green)
                        }
                        Text("\(d.category.label) · \(d.isBuiltIn ? "Built-in" : "Imported") · id: \(d.id)").font(.caption2).foregroundStyle(Theme.secondaryText)
                        Text(d.citation).font(.caption2)
                    }
                }
            }
            Section("Onboard supplies") {
                ForEach(model.kb.supplies) { s in
                    HStack {
                        Text(s.name)
                        Spacer()
                        Badge(text: s.authority.short, color: s.authority == .crew ? .green : .orange)
                    }
                }
            }
        }
        .navigationTitle("Knowledge base")
    }
}

// MARK: - 25. EmergencyView

struct EmergencyView: View {
    @Environment(AppModel.self) private var model
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let elapsed = model.emergencyStart.map { now.timeIntervalSince($0) } ?? 0
        let remaining = max(0, 30 - Int(elapsed))
        let steps = (model.engine.current?.urgency == .emergency ? model.engine.current?.steps.filter(\.timeCritical) : nil) ?? []
        ZStack {
            Color(red: 0.45, green: 0.0, blue: 0.02).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64))
                    Text(model.isSimulation ? "SIMULATED EMERGENCY" : "EMERGENCY").font(.largeTitle.weight(.black)).tracking(4)
                        .multilineTextAlignment(.center)
                    if model.isSimulation {
                        Text("Test data — not a real astronaut emergency").font(.headline)
                    }
                    if let r = model.evaluation.reasons.first(where: { $0.tier == .emergency }) {
                        Text("\(r.title) — \(r.detail)").font(.headline).multilineTextAlignment(.center)
                    } else if let s = model.engine.current?.summary {
                        Text(s).font(.headline).multilineTextAlignment(.center)
                    }
                    if model.crewAlerted {
                        Label("Crew alert sent (simulated)", systemImage: "person.3.fill").font(.headline)
                    } else {
                        Text("Are you able to respond? Crew will be alerted in \(remaining) s").font(.title3.weight(.semibold))
                    }
                    Button {
                        model.acknowledgeEmergency()
                    } label: {
                        Text("I'm responsive — dismiss").font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding()
                    }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.red)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("IMMEDIATE ACTIONS").font(.caption.weight(.heavy))
                        if steps.isEmpty {
                            BulletList(items: ["Check the crew member now: response and breathing",
                                               "Check the cabin pressure and oxygen",
                                               "Open the Medical Assistant and describe the situation"], color: .white)
                        } else {
                            ForEach(Array(steps.prefix(4).enumerated()), id: \.offset) { i, s in
                                Text("\(i + 1). \(s.action)").font(.callout.weight(.semibold))
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))

                    Button {
                        model.acknowledgeEmergency()
                        model.selectedTab = .assistant
                    } label: {
                        Label("Open guided care", systemImage: "cross.case.fill").frame(maxWidth: .infinity).padding()
                    }
                    .buttonStyle(.bordered).tint(.white)
                }
                .padding()
                .foregroundStyle(.white)
            }
        }
        .onReceive(timer) { t in
            now = t
            if remaining == 0 && !model.crewAlerted { model.alertCrew() }
        }
    }
}

#Preview {
    ContentView()
}

// MARK: - 26. Psychological data model

nonisolated enum EmotionGroup: String, Codable, CaseIterable, Identifiable {
    case positive, negative, complex
    var id: String { rawValue }
    var label: String {
        switch self {
        case .positive: return "Positive"
        case .negative: return "Difficult"
        case .complex: return "Neutral / complex"
        }
    }
    var color: Color {
        switch self {
        case .positive: return .green
        case .negative: return .orange
        case .complex: return .purple
        }
    }
    var symbol: String {
        switch self {
        case .positive: return "sun.max.fill"
        case .negative: return "cloud.rain.fill"
        case .complex: return "circle.lefthalf.filled"
        }
    }
    var valence: Double {
        switch self {
        case .positive: return 1
        case .negative: return -1
        case .complex: return 0
        }
    }
}

/// 49 selectable states. Used for check-ins, for mapping AI output, and for the keyword screen.
nonisolated enum Emotion: String, Codable, CaseIterable, Identifiable {
    case happy, joyful, excited, content, calm, relaxed, hopeful, optimistic, motivated, confident
    case grateful, satisfied, inspired, connected, appreciated, proud, curious, focused, energized
    case sad, lonely, anxious, worried, stressed, frustrated, irritated, angry, disappointed, overwhelmed
    case fearful, hopeless, homesick, guilty, insecure, ashamed, tense
    case indifferent, numb, confused, uncertain, nostalgic, bored, restless, mentallyExhausted
    case emotionallyDrained, ambivalent, detached, physicallyTired, pensive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .numb: return "Emotionally numb"
        case .mentallyExhausted: return "Mentally exhausted"
        case .emotionallyDrained: return "Emotionally drained"
        case .physicallyTired: return "Physically tired"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    var group: EmotionGroup {
        switch self {
        case .happy, .joyful, .excited, .content, .calm, .relaxed, .hopeful, .optimistic, .motivated, .confident,
             .grateful, .satisfied, .inspired, .connected, .appreciated, .proud, .curious, .focused, .energized:
            return .positive
        case .sad, .lonely, .anxious, .worried, .stressed, .frustrated, .irritated, .angry, .disappointed, .overwhelmed,
             .fearful, .hopeless, .homesick, .guilty, .insecure, .ashamed, .tense:
            return .negative
        default:
            return .complex
        }
    }

    /// Phrases for the non-AI keyword screen and for mapping free-text AI labels.
    var phrases: [String] {
        switch self {
        case .happy: return ["happy", "glad", "good day", "great day"]
        case .joyful: return ["joy", "joyful", "delighted"]
        case .excited: return ["excited", "exciting", "thrilled", "can't wait"]
        case .content: return ["content", "at peace"]
        case .calm: return ["calm", "peaceful"]
        case .relaxed: return ["relaxed", "rested"]
        case .hopeful: return ["hopeful", "hope"]
        case .optimistic: return ["optimistic", "positive about"]
        case .motivated: return ["motivated", "driven", "motivation"]
        case .confident: return ["confident", "sure of myself"]
        case .grateful: return ["grateful", "thankful", "gratitude"]
        case .satisfied: return ["satisfied", "accomplished", "satisfaction"]
        case .inspired: return ["inspired", "amazed", "awe", "inspiring"]
        case .connected: return ["connected", "close to", "bonded", "connection"]
        case .appreciated: return ["appreciated", "valued"]
        case .proud: return ["proud", "pride"]
        case .curious: return ["curious", "fascinated", "curiosity"]
        case .focused: return ["focused", "in the zone"]
        case .energized: return ["energized", "energetic", "full of energy"]
        case .sad: return ["sad", "unhappy", "crying", "cried", "feel down", "feeling down", "sadness"]
        case .lonely: return ["lonely", "loneliness", "alone", "isolated", "isolation"]
        case .anxious: return ["anxious", "anxiety", "nervous", "on edge", "panic"]
        case .worried: return ["worried", "worry", "worrying", "concerned"]
        case .stressed: return ["stressed", "stress", "under pressure", "stressful"]
        case .frustrated: return ["frustrated", "frustrating", "frustration"]
        case .irritated: return ["irritated", "annoyed", "irritable"]
        case .angry: return ["angry", "furious", "mad at", "anger"]
        case .disappointed: return ["disappointed", "let down", "disappointing"]
        case .overwhelmed: return ["overwhelmed", "too much to handle", "overwhelming"]
        case .fearful: return ["scared", "afraid", "fear", "terrified", "frightened"]
        case .hopeless: return ["hopeless", "pointless", "no point"]
        case .homesick: return ["homesick", "miss my family", "miss home", "miss earth", "miss being", "miss my"]
        case .guilty: return ["guilty", "my fault", "guilt"]
        case .insecure: return ["insecure", "not good enough", "doubt myself"]
        case .ashamed: return ["ashamed", "embarrassed", "shame"]
        case .tense: return ["tense", "tension"]
        case .indifferent: return ["indifferent", "don't care", "whatever"]
        case .numb: return ["numb", "feel nothing", "emotionally flat", "emotional numbness"]
        case .confused: return ["confused", "confusing", "don't understand"]
        case .uncertain: return ["uncertain", "not sure", "unsure", "uncertainty"]
        case .nostalgic: return ["nostalgic", "nostalgia", "remember when"]
        case .bored: return ["bored", "boring", "monotonous", "boredom"]
        case .restless: return ["restless", "can't sit still"]
        case .mentallyExhausted: return ["mentally exhausted", "can't concentrate", "difficulty concentrating", "hard to focus", "brain fog", "trouble focusing"]
        case .emotionallyDrained: return ["drained", "emotionally exhausted", "emotionally drained", "emotional exhaustion"]
        case .ambivalent: return ["mixed feelings", "ambivalent", "torn between"]
        case .detached: return ["detached", "disconnected", "distant from", "disconnection"]
        case .physicallyTired: return ["tired", "exhausted", "sore", "fatigued", "fatigue"]
        case .pensive: return ["pensive", "reflective", "thinking a lot"]
        }
    }

    /// Maps a free-text label (e.g. from the AI) to the closest predefined state, if any.
    static func match(_ text: String) -> Emotion? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = allCases.first(where: { $0.rawValue.lowercased() == t || $0.label.lowercased() == t }) { return exact }
        let aliases: [String: Emotion] = ["homesickness": .homesick, "loneliness": .lonely, "anxiety": .anxious, "worry": .worried,
                                          "stress": .stressed, "excitement": .excited, "sadness": .sad, "fear": .fearful,
                                          "frustration": .frustrated, "anger": .angry, "joy": .joyful, "happiness": .happy,
                                          "gratitude": .grateful, "boredom": .bored, "nervousness": .anxious, "hope": .hopeful,
                                          "disappointment": .disappointed, "guilt": .guilty, "pride": .proud, "calmness": .calm,
                                          "fatigue": .physicallyTired, "tiredness": .physicallyTired, "mental exhaustion": .mentallyExhausted,
                                          "emotional exhaustion": .emotionallyDrained, "detachment": .detached, "nostalgia": .nostalgic,
                                          "uncertainty": .uncertain, "confusion": .confused, "motivation": .motivated, "contentment": .content]
        if let a = aliases[t] { return a }
        return allCases.first { e in e.phrases.contains { $0 == t } }
    }
}

nonisolated enum ChatRole: String, Codable { case astronaut, assistant, system }

nonisolated struct ChatMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    var role: ChatRole
    var text: String            // Original text — never overwritten.
    var time = Date()
    var analysisID: UUID?
    var pendingAnalysis = false
}

nonisolated enum ConversationKind: String, Codable, CaseIterable, Identifiable {
    case chat, journal, privateJournal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chat: return "Conversation"
        case .journal: return "Journal (analyzed)"
        case .privateJournal: return "Private journal (never analyzed)"
        }
    }
    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .journal: return "book.fill"
        case .privateJournal: return "lock.fill"
        }
    }
    var analyzes: Bool { self != .privateJournal }
    var replies: Bool { self == .chat }
}

nonisolated struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: ConversationKind
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [ChatMessage] = []
    var isSample = false
}

nonisolated enum AnalysisMethod: String, Codable {
    case onDeviceAI, keywordScreen
    var label: String { self == .onDeviceAI ? "On-device AI inference" : "Keyword screen (not AI)" }
}

nonisolated enum AnalysisStatus: String, Codable {
    case complete, insufficientInformation, failed
    var label: String {
        switch self {
        case .complete: return "Analyzed"
        case .insufficientInformation: return "Insufficient information"
        case .failed: return "Analysis failed"
        }
    }
}

nonisolated enum FatigueKind: String, Codable {
    case notMentioned, physical, mental, emotional, ordinaryExpression, unclear
    var label: String {
        switch self {
        case .notMentioned: return "Not mentioned"
        case .physical: return "Physical fatigue"
        case .mental: return "Mental exhaustion"
        case .emotional: return "Emotional exhaustion"
        case .ordinaryExpression: return "Ordinary expression of tiredness"
        case .unclear: return "Tiredness — type unclear"
        }
    }
}

nonisolated enum IntensityLevel: String, Codable {
    case low, moderate, high, unclear
    var label: String { rawValue.capitalized }
    var score: Double? {
        switch self {
        case .low: return 1
        case .moderate: return 2
        case .high: return 3
        case .unclear: return nil
        }
    }
}

nonisolated enum ConfidenceLevel: String, Codable {
    case low, moderate, high
    var label: String { rawValue.capitalized }
}

nonisolated enum SafetyLevel: Int, Codable, Comparable {
    case none = 0, possibleConcern = 1, immediateConcern = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

nonisolated struct EmotionObservation: Codable, Hashable {
    var label: String
    var emotion: Emotion?
    var evidence: String
}

nonisolated enum CorrectionVerdict: String, Codable, CaseIterable, Identifiable {
    case accurate, partlyAccurate, inaccurate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .accurate: return "Accurate"
        case .partlyAccurate: return "Partly accurate"
        case .inaccurate: return "Not accurate"
        }
    }
}

nonisolated struct UserCorrection: Codable, Hashable {
    var date = Date()
    var verdict: CorrectionVerdict
    var emotions: [Emotion]
    var comment: String
}

nonisolated struct EmotionAnalysis: Codable, Identifiable, Hashable {
    var id = UUID()
    var createdAt = Date()
    var conversationID: UUID
    var messageID: UUID
    var excerpt: String
    var method: AnalysisMethod
    var status: AnalysisStatus
    var primary: [EmotionObservation] = []
    var secondary: [EmotionObservation] = []
    var contributingFactors: [String] = []
    var fatigue: FatigueKind = .notMentioned
    var intensity: IntensityLevel = .unclear
    var confidence: ConfidenceLevel = .low
    var uncertainties: [String] = []
    var changeFromPrevious: String?
    var followUpQuestions: [String] = []
    var safety: SafetyLevel = .none
    var correction: UserCorrection?
    var isSample = false

    /// The astronaut's correction always overrides the inference.
    var effectiveEmotions: [Emotion] {
        if let c = correction, c.verdict != .accurate { return c.emotions }
        return (primary + secondary).compactMap(\.emotion)
    }
}

nonisolated struct MoodCheckIn: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var emotions: [Emotion] = []
    var stress: Int?
    var energy: Int?
    var workload: Int?
    var missionEvent = ""
    var note = ""
    var editedAt: Date?
    var isSample = false
}

nonisolated struct PsychArchive: Codable {
    var conversations: [Conversation] = []
    var checkIns: [MoodCheckIn] = []
    var analyses: [EmotionAnalysis] = []
}

// MARK: - 27. Safety screen + keyword screen (deterministic, no AI)

nonisolated enum PsychSafetyScreen {
    /// Phrases indicating a possible immediate safety concern. Checked before any AI call.
    private static let immediate = ["kill myself", "suicide", "suicidal", "end my life", "want to die", "hurt myself",
                                    "harm myself", "self-harm", "no reason to live", "better off without me",
                                    "can't go on", "cannot go on", "don't want to be alive", "end it all"]
    private static let concern = ["can't cope", "cannot cope", "falling apart", "breaking down", "can't take it",
                                  "nobody cares", "no one cares", "worthless", "hopeless", "trapped", "can't sleep at all"]

    static func check(_ text: String) -> SafetyLevel {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        if immediate.contains(where: { t.contains($0) }) { return .immediateConcern }
        if concern.contains(where: { t.contains($0) }) { return .possibleConcern }
        return .none
    }

    static let immediateSteps = [
        "If you might act on thoughts of harming yourself, tell a crewmate right now and stay with them.",
        "Contact the Crew Medical Officer now.",
        "Request a private medical or behavioral-health conference with the flight surgeon at the next communication opportunity, following your mission's behavioral health protocol.",
        "ASTRA has not contacted anyone. It cannot send messages on your behalf."
    ]
    static let concernSteps = [
        "Consider talking with a crewmate or the Crew Medical Officer today.",
        "Your mission's private psychological support conferences are available at the next communication window.",
        "Rest, a predictable routine, and contact with people you trust can help; tell someone if this feeling grows."
    ]
}

nonisolated enum KeywordEmotionScreen {
    private static let negations = ["not", "no", "never", "n't", "dont", "don't", "didn't", "isn't", "wasn't", "aren't", "hardly", "without"]

    static func analyze(_ text: String, conversationID: UUID, messageID: UUID) -> EmotionAnalysis {
        let lower = " " + text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        var found: [EmotionObservation] = []
        for e in Emotion.allCases {
            for p in e.phrases {
                guard let r = lower.range(of: " " + p) ?? lower.range(of: p + " ") else { continue }
                let before = lower[lower.startIndex..<r.lowerBound].split(separator: " ").suffix(3).map(String.init)
                if before.contains(where: { w in negations.contains(where: { w.hasSuffix($0) }) }) { continue }
                found.append(EmotionObservation(label: e.label, emotion: e, evidence: snippet(text, around: p)))
                break
            }
        }
        // "Tired" alone is not an emotion: classify the fatigue type instead.
        var fatigue: FatigueKind = .notMentioned
        if found.contains(where: { $0.emotion == .physicallyTired || $0.emotion == .mentallyExhausted || $0.emotion == .emotionallyDrained }) {
            if lower.contains("emotionally") || lower.contains("drained") { fatigue = .emotional }
            else if lower.contains("mentally") || lower.contains("concentrat") || lower.contains("focus") { fatigue = .mental }
            else if ["slept", "sleep", "body", "muscle", "workout", "exercise", "physically", "sore"].contains(where: { lower.contains($0) }) { fatigue = .physical }
            else { fatigue = .unclear }
        }
        var factors: [String] = []
        if ["family", "home", "earth", "kids", "children", "wife", "husband", "partner", "parents"].contains(where: { lower.contains(" " + $0) }) { factors.append("Family / Earth mentioned") }
        if ["mission", "task", "schedule", "workload", "deadline", "eva"].contains(where: { lower.contains($0) }) { factors.append("Mission workload mentioned") }
        if ["crew", "crewmate", "colleague", "commander"].contains(where: { lower.contains($0) }) { factors.append("Crew relationships mentioned") }
        if lower.contains("sleep") || lower.contains("slept") { factors.append("Sleep mentioned") }

        var a = EmotionAnalysis(conversationID: conversationID, messageID: messageID, excerpt: String(text.prefix(160)),
                                method: .keywordScreen, status: found.isEmpty ? .insufficientInformation : .complete)
        a.primary = Array(found.prefix(2))
        a.secondary = Array(found.dropFirst(2).prefix(3))
        a.contributingFactors = factors
        a.fatigue = fatigue
        a.confidence = .low
        a.uncertainties = ["Keyword screen only — it cannot understand context, sarcasm, or indirect expressions. Re-analyze with on-device AI when available."]
        if found.isEmpty { a.uncertainties.append("No explicit emotional words were found.") }
        a.safety = PsychSafetyScreen.check(text)
        return a
    }

    private static func snippet(_ text: String, around phrase: String) -> String {
        guard let r = text.range(of: phrase, options: .caseInsensitive) else { return phrase }
        let start = text.index(r.lowerBound, offsetBy: -min(30, text.distance(from: text.startIndex, to: r.lowerBound)))
        let end = text.index(r.upperBound, offsetBy: min(30, text.distance(from: r.upperBound, to: text.endIndex)))
        return "…" + String(text[start..<end]) + "…"
    }
}

// MARK: - 28. EmotionAnalysisEngine + OfflineConversationManager (FoundationModels, on-device)

@Generable
nonisolated enum AIFatigueType { case notMentioned, physical, mental, emotional, ordinaryExpression, unclear }

@Generable
nonisolated enum AIIntensityLevel { case low, moderate, high, unclear }

@Generable
nonisolated enum AIConfidenceLevel { case low, moderate, high }

@Generable
nonisolated enum AISafetyLevel { case none, possibleConcern, immediateConcern }

@Generable
nonisolated struct AIEmotionFinding {
    @Guide(description: "Emotion in one or two words, such as homesickness, loneliness, excitement, anxiety")
    var emotion: String
    @Guide(description: "A short exact phrase from the astronaut's text that supports this emotion")
    var evidence: String
}

@Generable
nonisolated struct AIPsychAnalysis {
    @Guide(description: "False when the text does not contain enough information to infer any emotional state")
    var hasEnoughInformation: Bool
    @Guide(description: "Main emotions clearly supported by the text; several may coexist", .maximumCount(3))
    var primaryEmotions: [AIEmotionFinding]
    @Guide(description: "Weaker or secondary emotions supported by the text", .maximumCount(3))
    var secondaryEmotions: [AIEmotionFinding]
    @Guide(description: "Possible contributing factors the astronaut mentioned, such as separation from family or workload", .maximumCount(4))
    var contributingFactors: [String]
    @Guide(description: "Type of tiredness if tiredness is mentioned")
    var fatigue: AIFatigueType
    var intensity: AIIntensityLevel
    var confidence: AIConfidenceLevel
    @Guide(description: "What is uncertain about this interpretation, including possible sarcasm or ambiguity", .maximumCount(3))
    var uncertainties: [String]
    @Guide(description: "How this compares with the previous observations provided; empty if none were provided")
    var changeComparedWithPrevious: String
    @Guide(description: "Gentle follow-up questions that would improve understanding; empty if none are needed", .maximumCount(2))
    var followUpQuestions: [String]
    var safety: AISafetyLevel
}

nonisolated enum PsychAIStatus {
    static var isAvailable: Bool {
        guard case .available = SystemLanguageModel.default.availability else { return false }
        return languageSupported
    }

    static var languageSupported: Bool {
        SystemLanguageModel.default.supportedLanguages.contains(Locale.current.language)
    }

    static var text: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return languageSupported
                ? "On-device AI ready — conversations and analysis run locally without internet."
                : "On-device AI is available, but the device language is not supported. Set the iPhone language to English."
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device cannot run Apple's on-device model. Entries are saved and can be analyzed later on a supported device; a clearly labeled keyword screen is used meanwhile."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off. Turn it on in Settings to enable offline AI conversation."
            case .modelNotReady:
                return "The on-device model is still downloading. Entries are saved and will be analyzed when it is ready."
            @unknown default:
                return "On-device AI unavailable. Entries are saved for later analysis."
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation: return "The on-device model declined to process this text. Your entry is saved."
            case .exceededContextWindowSize: return "The conversation became too long for the on-device model; a new session was started."
            case .unsupportedLanguageOrLocale: return "This language is not supported by the on-device model."
            default: return "On-device generation failed: \(e.localizedDescription)"
            }
        }
        return "On-device generation failed: \(error.localizedDescription)"
    }
}

@MainActor
final class EmotionAnalysisEngine {
    static let instructions = """
    You analyze short journal entries and chat messages written by an astronaut, to support psychological self-monitoring. \
    Interpret meaning, tone, context, and relationships between statements, not just keywords. Several emotions can coexist. \
    Distinguish physical fatigue, mental exhaustion, emotional exhaustion, and ordinary tiredness. \
    Only report emotions supported by the text and quote the supporting phrase. Never name a psychological disorder. \
    If the text lacks emotional information, set hasEnoughInformation to false and leave the emotion lists empty. \
    Mark safety as immediateConcern only if the text suggests risk of self-harm or danger.
    """

    func analyze(text: String, recentContext: String, previous: String, conversationID: UUID, messageID: UUID) async throws -> EmotionAnalysis {
        let session = LanguageModelSession(instructions: Self.instructions)
        var prompt = "TEXT TO ANALYZE:\n\(text)\n"
        if !recentContext.isEmpty { prompt += "\nEARLIER IN THE SAME CONVERSATION (context only):\n\(recentContext)\n" }
        if !previous.isEmpty { prompt += "\nPREVIOUS OBSERVATIONS:\n\(previous)\n" }
        let r = try await session.respond(to: prompt, generating: AIPsychAnalysis.self, options: GenerationOptions(temperature: 0.2)).content

        func map(_ f: AIEmotionFinding) -> EmotionObservation {
            EmotionObservation(label: f.emotion.capitalized, emotion: Emotion.match(f.emotion), evidence: f.evidence)
        }
        var a = EmotionAnalysis(conversationID: conversationID, messageID: messageID, excerpt: String(text.prefix(160)),
                                method: .onDeviceAI, status: r.hasEnoughInformation && !r.primaryEmotions.isEmpty ? .complete : .insufficientInformation)
        if a.status == .complete {
            a.primary = r.primaryEmotions.map(map)
            a.secondary = r.secondaryEmotions.map(map)
        }
        a.contributingFactors = r.contributingFactors
        switch r.fatigue {
        case .notMentioned: a.fatigue = .notMentioned
        case .physical: a.fatigue = .physical
        case .mental: a.fatigue = .mental
        case .emotional: a.fatigue = .emotional
        case .ordinaryExpression: a.fatigue = .ordinaryExpression
        case .unclear: a.fatigue = .unclear
        }
        switch r.intensity {
        case .low: a.intensity = .low
        case .moderate: a.intensity = .moderate
        case .high: a.intensity = .high
        case .unclear: a.intensity = .unclear
        }
        switch r.confidence {
        case .low: a.confidence = .low
        case .moderate: a.confidence = .moderate
        case .high: a.confidence = .high
        }
        a.uncertainties = r.uncertainties
        a.changeFromPrevious = r.changeComparedWithPrevious.isEmpty ? nil : r.changeComparedWithPrevious
        a.followUpQuestions = r.followUpQuestions
        let aiSafety: SafetyLevel
        switch r.safety {
        case .none: aiSafety = .none
        case .possibleConcern: aiSafety = .possibleConcern
        case .immediateConcern: aiSafety = .immediateConcern
        }
        // The deterministic screen can raise, never lower, the AI's safety level.
        a.safety = max(aiSafety, PsychSafetyScreen.check(text))
        // Evidence quotes that do not appear in the original text are flagged.
        let lower = text.lowercased()
        for o in a.primary + a.secondary where !o.evidence.isEmpty && !lower.contains(o.evidence.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            a.uncertainties.append("Evidence for \"\(o.label)\" is paraphrased, not quoted exactly.")
        }
        return a
    }
}

@MainActor
final class OfflineConversationManager {
    static let instructions = """
    You are ASTRA Companion, a supportive conversation partner for an astronaut on a long-duration mission. You run \
    entirely on the device without internet. Talk naturally and warmly, like a thoughtful crewmate. Reflect what the \
    astronaut says in your own words and connect it to what they said earlier. Ask at most one relevant follow-up \
    question, only when it would help; do not ask a question in every reply and vary your style. Do not diagnose, do not \
    name mental disorders, and do not present yourself as a psychologist. Never minimize or judge. Respect that the \
    astronaut may not want to discuss something. If they mention harming themselves or being in danger, encourage them \
    to tell a crewmate and the Crew Medical Officer now. Never claim you have contacted anyone. Keep replies under 120 words.
    """

    private var sessions: [UUID: LanguageModelSession] = [:]

    func reset(_ id: UUID) { sessions[id] = nil }

    func reply(to text: String, in conversation: Conversation, context: String) async throws -> String {
        if let session = sessions[conversation.id] {
            do {
                return try await session.respond(to: text).content
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                sessions[conversation.id] = nil
            }
        }
        // New or restored session: give it the recent history so the conversation continues naturally.
        let session = LanguageModelSession(instructions: Self.instructions)
        sessions[conversation.id] = session
        let history = conversation.messages.filter { $0.role != .system }.dropLast().suffix(8)
            .map { "\($0.role == .astronaut ? "Astronaut" : "You"): \($0.text.prefix(300))" }.joined(separator: "\n")
        var prompt = ""
        if !context.isEmpty { prompt += "Background (do not repeat back): \(context)\n\n" }
        if !history.isEmpty { prompt += "Conversation so far:\n\(history)\n\n" }
        prompt += "Astronaut: \(text)"
        return try await session.respond(to: prompt).content
    }

    func summarize(_ material: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
        Summarize an astronaut's self-reported psychological records for the astronaut. Describe patterns and changes \
        cautiously, separate self-reports from AI inferences, avoid diagnoses, and note uncertainty. Under 150 words.
        """)
        return try await session.respond(to: material).content
    }
}

// MARK: - 29. Longitudinal analysis

nonisolated struct DailyPsychRecord: Identifiable {
    var id: Date { day }
    let day: Date
    var selfReported: [Emotion] = []
    var inferred: [Emotion] = []
    var stress: Double?
    var energy: Double?
    var workload: Double?
    var entries = 0
    var text = ""
    var factors: [String] = []
    var isSample = false

    static func valence(_ es: [Emotion]) -> Double? {
        guard !es.isEmpty else { return nil }
        return es.reduce(0) { $0 + $1.group.valence } / Double(es.count)
    }
    var selfValence: Double? { Self.valence(selfReported) }
    var inferredValence: Double? { Self.valence(inferred) }
    var anyValence: Double? { selfValence ?? inferredValence }
}

nonisolated enum PsychTheme: String, CaseIterable, Identifiable {
    case loneliness, motivation, socialConnection, familyEarth, concentration, fatigue, stress
    var id: String { rawValue }
    var label: String {
        switch self {
        case .loneliness: return "Loneliness"
        case .motivation: return "Low motivation"
        case .socialConnection: return "Feeling connected"
        case .familyEarth: return "Family / Earth concerns"
        case .concentration: return "Concentration difficulty"
        case .fatigue: return "Fatigue"
        case .stress: return "Stress"
        }
    }

    func present(in r: DailyPsychRecord) -> Bool {
        let es = Set(r.selfReported + r.inferred)
        let t = r.text.lowercased()
        switch self {
        case .loneliness: return !es.isDisjoint(with: [.lonely, .homesick, .detached]) || t.contains("lonely") || t.contains("alone")
        case .motivation: return !es.isDisjoint(with: [.bored, .hopeless, .indifferent]) || t.contains("unmotivated") || t.contains("no motivation")
        case .socialConnection: return !es.isDisjoint(with: [.connected, .appreciated])
        case .familyEarth: return es.contains(.homesick) || r.factors.contains { $0.lowercased().contains("family") || $0.lowercased().contains("earth") } || t.contains("family")
        case .concentration: return es.contains(.mentallyExhausted) || t.contains("concentrat") || t.contains("focus")
        case .fatigue: return !es.isDisjoint(with: [.physicallyTired, .mentallyExhausted, .emotionallyDrained]) || (r.energy ?? 10) <= 3
        case .stress: return !es.isDisjoint(with: [.stressed, .overwhelmed, .tense]) || (r.stress ?? 0) >= 7
        }
    }
}

nonisolated struct PeriodSummary {
    let days: Int
    var daysWithData = 0
    var topSelfReported: [(Emotion, Int)] = []
    var topInferred: [(Emotion, Int)] = []
    var avgStress: Double?
    var previousAvgStress: Double?
    var themes: [(PsychTheme, Int, Int)] = []   // theme, days this period, days previous period
    var stressors: [(String, Int)] = []

    var lines: [String] {
        var out: [String] = []
        if daysWithData == 0 { return ["No records in the last \(days) days."] }
        out.append("Records on \(daysWithData) of the last \(days) days.")
        if !topSelfReported.isEmpty { out.append("Most selected (self-reported): " + topSelfReported.prefix(4).map { "\($0.0.label) ×\($0.1)" }.joined(separator: ", ")) }
        if !topInferred.isEmpty { out.append("Most inferred from writing (AI/keyword): " + topInferred.prefix(4).map { "\($0.0.label) ×\($0.1)" }.joined(separator: ", ")) }
        if let s = avgStress {
            var l = "Average self-reported stress \(fmt(s, 1))/10"
            if let p = previousAvgStress { l += " (previous period \(fmt(p, 1)))" }
            out.append(l)
        }
        for (t, now, before) in themes where now > 0 || before > 0 {
            let change = now > before ? "↑" : now < before ? "↓" : "="
            out.append("\(t.label): \(now) day(s) vs \(before) before \(change)")
        }
        if !stressors.isEmpty { out.append("Recurring stressors: " + stressors.prefix(4).map { "\($0.0) (\($0.1))" }.joined(separator: ", ")) }
        return out
    }
}

nonisolated struct EmotionCount: Identifiable {
    var id: String { source + emotion.rawValue }
    let emotion: Emotion
    let count: Int
    let source: String
}

nonisolated struct CorrelationResult: Identifiable {
    var id: String { label }
    let label: String
    let r: Double
    let n: Int
    var text: String {
        let strength = abs(r) >= 0.5 ? "moderate–strong" : abs(r) >= 0.3 ? "weak–moderate" : "little or no"
        return "\(label): r = \(fmt(r, 2)), n = \(n) days — \(strength) association. Correlation does not show cause."
    }
}

nonisolated func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
    guard xs.count == ys.count, xs.count >= 3 else { return nil }
    let n = Double(xs.count)
    let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
    var num = 0.0, dx = 0.0, dy = 0.0
    for (x, y) in zip(xs, ys) {
        num += (x - mx) * (y - my)
        dx += (x - mx) * (x - mx)
        dy += (y - my) * (y - my)
    }
    guard dx > 0, dy > 0 else { return nil }
    return num / (dx * dy).squareRoot()
}

// MARK: - 30. PsychologicalMonitoringManager (storage, chat, analysis, trends, privacy)

@MainActor
@Observable
final class PsychologicalMonitoringManager {
    private(set) var conversations: [Conversation] = []
    private(set) var checkIns: [MoodCheckIn] = []
    private(set) var analyses: [EmotionAnalysis] = []

    var respondingConversation: UUID?
    var analyzingCount = 0
    var lastAnalysisAt: Date?
    var statusMessage: String?
    var safetyAlert: SafetyLevel = .none
    var aiSummary: String?
    var lockEnabled: Bool
    var unlocked = false
    var keywordFallback: Bool
    var exportIncludesPrivate = false

    @ObservationIgnored private let chat = OfflineConversationManager()
    @ObservationIgnored private let analyzer = EmotionAnalysisEngine()
    @ObservationIgnored private static let file = "astra_psych.json"

    init() {
        let a = FileStore.load(PsychArchive.self, from: Self.file) ?? PsychArchive()
        conversations = a.conversations
        checkIns = a.checkIns
        analyses = a.analyses
        lockEnabled = UserDefaults.standard.bool(forKey: "psych.lock")
        keywordFallback = UserDefaults.standard.object(forKey: "psych.keyword") as? Bool ?? true
        lastAnalysisAt = a.analyses.filter { $0.method == .onDeviceAI }.map(\.createdAt).max()
    }

    var aiAvailable: Bool { PsychAIStatus.isAvailable }
    var aiStatusText: String { PsychAIStatus.text }
    var pendingCount: Int { conversations.flatMap(\.messages).filter(\.pendingAnalysis).count }

    private func save() {
        FileStore.save(PsychArchive(conversations: conversations, checkIns: checkIns, analyses: analyses), to: Self.file)
    }

    func saveSettings() {
        UserDefaults.standard.set(lockEnabled, forKey: "psych.lock")
        UserDefaults.standard.set(keywordFallback, forKey: "psych.keyword")
    }

    // Access control: Face ID / passcode (requires NSFaceIDUsageDescription).
    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            unlocked = true
            statusMessage = "No passcode is set on this device; the lock cannot be enforced."
            return
        }
        do {
            unlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your private psychological records")
        } catch {
            unlocked = false
        }
    }

    // Conversations

    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }
    func analysis(_ id: UUID?) -> EmotionAnalysis? { id.flatMap { i in analyses.first { $0.id == i } } }

    @discardableResult
    func newConversation(_ kind: ConversationKind) -> UUID {
        let title = "\(kind == .chat ? "Conversation" : "Journal") — \(Date().formatted(date: .abbreviated, time: .shortened))"
        let c = Conversation(kind: kind, title: title)
        conversations.insert(c, at: 0)
        save()
        return c.id
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        analyses.removeAll { $0.conversationID == id }
        chat.reset(id)
        save()
    }

    private func update(_ id: UUID, _ change: (inout Conversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[i])
        conversations[i].updatedAt = Date()
    }

    func send(_ raw: String, to id: UUID, bio: BiometricDataManager) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let convo = conversation(id) else { return }
        let message = ChatMessage(role: .astronaut, text: text, pendingAnalysis: convo.kind.analyzes)
        update(id) { $0.messages.append(message) }
        save()

        // 1. Deterministic safety screen first — it does not depend on the AI.
        let safety = PsychSafetyScreen.check(text)
        if safety > .none {
            safetyAlert = safety
            update(id) { $0.messages.append(ChatMessage(role: .system, text: safety == .immediateConcern
                ? "Your safety comes first. " + PsychSafetyScreen.immediateSteps.joined(separator: " ")
                : PsychSafetyScreen.concernSteps.joined(separator: " "))) }
            save()
        }

        // 2. Conversational reply (chat only).
        if convo.kind.replies {
            if aiAvailable {
                respondingConversation = id
                do {
                    let reply = try await chat.reply(to: text, in: conversation(id) ?? convo, context: contextSummary(bio: bio))
                    update(id) { $0.messages.append(ChatMessage(role: .assistant, text: reply)) }
                } catch {
                    update(id) { $0.messages.append(ChatMessage(role: .system, text: PsychAIStatus.describe(error))) }
                }
                respondingConversation = nil
            } else {
                update(id) { $0.messages.append(ChatMessage(role: .system, text: "On-device AI is not available, so no reply was generated. Your message is saved locally and will be analyzed when a supported model is available.")) }
            }
            save()
        }

        // 3. Emotion analysis (not for private journals).
        if convo.kind.analyzes { await analyze(messageID: message.id, in: id) }
    }

    func analyze(messageID: UUID, in conversationID: UUID, force: Bool = false) async {
        guard let convo = conversation(conversationID), let msg = convo.messages.first(where: { $0.id == messageID }) else { return }
        let earlier = convo.messages.prefix { $0.id != messageID }.filter { $0.role == .astronaut }.suffix(3)
            .map { String($0.text.prefix(200)) }.joined(separator: "\n")
        var result: EmotionAnalysis?
        if aiAvailable {
            analyzingCount += 1
            do {
                result = try await analyzer.analyze(text: msg.text, recentContext: earlier, previous: previousSummary(),
                                                    conversationID: conversationID, messageID: messageID)
                lastAnalysisAt = Date()
            } catch {
                statusMessage = PsychAIStatus.describe(error)
            }
            analyzingCount -= 1
        }
        if result == nil && (keywordFallback || force) {
            result = KeywordEmotionScreen.analyze(msg.text, conversationID: conversationID, messageID: messageID)
        }
        guard let result else { return }
        if let old = msg.analysisID { analyses.removeAll { $0.id == old && $0.correction == nil } }
        analyses.append(result)
        update(conversationID) { c in
            if let i = c.messages.firstIndex(where: { $0.id == messageID }) {
                c.messages[i].analysisID = result.id
                c.messages[i].pendingAnalysis = result.method != .onDeviceAI
            }
        }
        if result.safety > safetyAlert { safetyAlert = result.safety }
        save()
    }

    /// Re-runs entries that were saved while the model was unavailable or only keyword-screened.
    func analyzePending() async {
        guard aiAvailable else {
            statusMessage = "On-device AI is still unavailable. Entries remain saved."
            return
        }
        for c in conversations where c.kind.analyzes {
            for m in c.messages where m.pendingAnalysis { await analyze(messageID: m.id, in: c.id) }
        }
        statusMessage = "Pending entries analyzed."
    }

    func correct(_ analysisID: UUID, _ correction: UserCorrection) {
        guard let i = analyses.firstIndex(where: { $0.id == analysisID }) else { return }
        analyses[i].correction = correction
        save()
    }

    // Mood check-ins

    var todaysCheckIn: MoodCheckIn? { checkIns.last { Calendar.current.isDateInToday($0.date) && !$0.isSample } }

    func saveCheckIn(_ c: MoodCheckIn) {
        if let i = checkIns.firstIndex(where: { $0.id == c.id }) {
            var edited = c
            edited.editedAt = Date()
            checkIns[i] = edited
        } else {
            checkIns.append(c)
        }
        checkIns.sort { $0.date < $1.date }
        save()
    }

    func deleteCheckIn(_ id: UUID) {
        checkIns.removeAll { $0.id == id }
        save()
    }

    // Longitudinal analysis

    func dailyRecords(days: Int, endingAt end: Date = Date()) -> [DailyPsychRecord] {
        let cal = Calendar.current
        let lastDay = cal.startOfDay(for: end)
        var map: [Date: DailyPsychRecord] = [:]
        for k in 0..<days {
            if let d = cal.date(byAdding: .day, value: -k, to: lastDay) { map[d] = DailyPsychRecord(day: d) }
        }
        for c in checkIns {
            let d = cal.startOfDay(for: c.date)
            guard var r = map[d] else { continue }
            r.selfReported += c.emotions
            if let s = c.stress { r.stress = ((r.stress ?? Double(s)) + Double(s)) / 2 }
            if let e = c.energy { r.energy = Double(e) }
            if let w = c.workload { r.workload = Double(w) }
            if !c.missionEvent.isEmpty { r.factors.append(c.missionEvent) }
            r.text += " " + c.note
            r.entries += 1
            r.isSample = r.isSample || c.isSample
            map[d] = r
        }
        for a in analyses where a.status == .complete {
            let d = cal.startOfDay(for: a.createdAt)
            guard var r = map[d] else { continue }
            r.inferred += a.effectiveEmotions
            r.factors += a.contributingFactors
            r.entries += 1
            r.isSample = r.isSample || a.isSample
            map[d] = r
        }
        for c in conversations where c.kind.analyzes {
            for m in c.messages where m.role == .astronaut {
                let d = cal.startOfDay(for: m.time)
                if var r = map[d] { r.text += " " + m.text; map[d] = r }
            }
        }
        return map.values.sorted { $0.day < $1.day }
    }

    func summary(days: Int) -> PeriodSummary {
        let all = dailyRecords(days: days * 2)
        let current = Array(all.suffix(days)), previous = Array(all.prefix(days))
        var s = PeriodSummary(days: days)
        s.daysWithData = current.filter { $0.entries > 0 }.count
        func top(_ es: [Emotion]) -> [(Emotion, Int)] {
            Dictionary(grouping: es, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        }
        s.topSelfReported = top(current.flatMap(\.selfReported))
        s.topInferred = top(current.flatMap(\.inferred))
        let cs = current.compactMap(\.stress), ps = previous.compactMap(\.stress)
        s.avgStress = cs.isEmpty ? nil : cs.reduce(0, +) / Double(cs.count)
        s.previousAvgStress = ps.isEmpty ? nil : ps.reduce(0, +) / Double(ps.count)
        s.themes = PsychTheme.allCases.map { t in (t, current.filter { t.present(in: $0) }.count, previous.filter { t.present(in: $0) }.count) }
        let factors = current.flatMap(\.factors).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        s.stressors = Dictionary(grouping: factors, by: { $0.lowercased() }).map { ($0.value[0], $0.value.count) }.sorted { $0.1 > $1.1 }
        return s
    }

    /// Personal baseline: compares the last 3–7 days with the astronaut's own earlier records. Not a diagnosis.
    func baselineNotes() -> [String] {
        let records = dailyRecords(days: 60).filter { $0.entries > 0 }
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let base = records.filter { $0.day < cutoff }, recent = records.filter { $0.day >= cutoff }
        guard base.count >= 7 else {
            return ["A personal baseline needs at least 7 days of records before the last week (currently \(base.count))."]
        }
        var notes: [String] = []
        let bv = base.compactMap(\.anyValence)
        let (mean, sd) = TrendAnalyzer.stats(bv)
        let last3 = recent.suffix(3).compactMap(\.anyValence)
        if let mean, let sd, last3.count == 3, last3.allSatisfy({ $0 < mean - max(sd, 0.15) }) {
            notes.append("The last 3 days were more negative than your usual pattern (baseline mood balance \(signed(mean, 2)), recent \(signed(last3.reduce(0, +) / 3, 2))). This is a change from your own baseline, not a diagnosis.")
        }
        for e in Emotion.allCases where e.group == .negative {
            let recentDays = recent.filter { ($0.selfReported + $0.inferred).contains(e) }.count
            let baseRate = Double(base.filter { ($0.selfReported + $0.inferred).contains(e) }.count) / Double(base.count)
            if recentDays >= 3 && Double(recentDays) / Double(max(recent.count, 1)) > baseRate + 0.3 {
                notes.append("\(e.label) noted on \(recentDays) of the last \(recent.count) recorded days, compared with \(Int(baseRate * 100))% of days in your baseline.")
            }
        }
        if let s = recent.compactMap(\.stress).last, let bs = TrendAnalyzer.stats(base.compactMap(\.stress)).0, s - bs >= 3 {
            notes.append("Self-reported stress \(Int(s))/10 vs baseline average \(fmt(bs, 1)).")
        }
        return notes.isEmpty ? ["Recent records are within your usual pattern."] : notes
    }

    /// Correlations between daily mood/stress and biometrics. Association only.
    func correlations(bio: BiometricDataManager) -> [CorrelationResult] {
        let days = dailyRecords(days: 30)
        let cal = Calendar.current
        func daily(_ m: MetricKind, sum: Bool) -> [Date: Double] {
            let grouped = Dictionary(grouping: bio.store.visibleRecords.filter { $0.metric == m }) { cal.startOfDay(for: $0.end) }
            return grouped.mapValues { rs in sum ? rs.reduce(0) { $0 + $1.value } : rs.reduce(0) { $0 + $1.value } / Double(rs.count) }
        }
        let sleep = daily(.sleep, sum: true), hr = daily(.heartRate, sum: false), hrv = daily(.hrv, sum: false)
        var out: [CorrelationResult] = []
        func add(_ label: String, _ x: (DailyPsychRecord) -> Double?, _ ys: [Date: Double]) {
            let pairs = days.compactMap { d -> (Double, Double)? in
                guard let a = x(d), let b = ys[d.day] else { return nil }
                return (a, b)
            }
            if pairs.count >= 7, let r = pearson(pairs.map(\.0), pairs.map(\.1)) { out.append(CorrelationResult(label: label, r: r, n: pairs.count)) }
        }
        add("Stress vs sleep duration", { $0.stress }, sleep)
        add("Mood balance vs sleep duration", { $0.anyValence }, sleep)
        add("Stress vs mean heart rate", { $0.stress }, hr)
        add("Stress vs HRV", { $0.stress }, hrv)
        add("Mood balance vs HRV", { $0.anyValence }, hrv)
        var workloadPairs: [(Double, Double)] = []
        for d in days { if let w = d.workload, let s = d.stress { workloadPairs.append((w, s)) } }
        if workloadPairs.count >= 7, let r = pearson(workloadPairs.map(\.0), workloadPairs.map(\.1)) {
            out.append(CorrelationResult(label: "Workload vs stress", r: r, n: workloadPairs.count))
        }
        return out
    }

    func contextSummary(bio: BiometricDataManager) -> String {
        var p: [String] = []
        if let c = todaysCheckIn, !c.emotions.isEmpty { p.append("Today's check-in: " + c.emotions.map(\.label).joined(separator: ", ")) }
        if let s = bio.summary(.sleep)?.latestValue { p.append("Sleep last 24 h \(fmt(s, 1)) h (sensor)") }
        let recent = analyses.suffix(3).flatMap(\.effectiveEmotions).map(\.label)
        if !recent.isEmpty { p.append("Recently noted: " + Array(Set(recent)).joined(separator: ", ")) }
        return p.joined(separator: ". ")
    }

    private func previousSummary() -> String {
        analyses.filter { $0.status == .complete }.suffix(5).map { a in
            "\(a.createdAt.formatted(date: .abbreviated, time: .omitted)): " + a.effectiveEmotions.map(\.label).joined(separator: ", ")
        }.joined(separator: "\n")
    }

    func generateAISummary(days: Int) async {
        guard aiAvailable else {
            aiSummary = nil
            statusMessage = "AI summary needs the on-device model. The rule-based summary is shown instead."
            return
        }
        let material = "Period: last \(days) days.\n" + summary(days: days).lines.joined(separator: "\n") + "\nBaseline: " + baselineNotes().joined(separator: " ")
        do {
            aiSummary = try await chat.summarize(material)
        } catch {
            statusMessage = PsychAIStatus.describe(error)
        }
    }

    // Sample history for demonstrations — labeled SAMPLE everywhere and removable.

    func loadSampleHistory() {
        clearSampleHistory()
        let cal = Calendar.current
        let pattern: [[Emotion]] = [[.calm, .motivated], [.content, .focused], [.excited, .curious], [.calm, .grateful],
                                    [.motivated, .connected], [.content], [.calm, .inspired]]
        for day in stride(from: 21, through: 1, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -day, to: Date()) else { continue }
            var c = MoodCheckIn(date: d, isSample: true)
            if day <= 4 {
                c.emotions = [.lonely, .homesick, .physicallyTired]
                c.stress = 6 + (4 - day) / 2
                c.energy = 3
                c.workload = 8
                c.missionEvent = "Extended EVA preparation"
                c.note = "Sample: missing family after long shifts."
            } else {
                c.emotions = pattern[day % pattern.count]
                c.stress = 2 + day % 3
                c.energy = 7
                c.workload = 4 + day % 3
            }
            checkIns.append(c)
        }
        checkIns.sort { $0.date < $1.date }
        save()
        statusMessage = "Loaded 21 days of SAMPLE check-ins for demonstration."
    }

    func clearSampleHistory() {
        checkIns.removeAll(where: \.isSample)
        analyses.removeAll(where: \.isSample)
        conversations.removeAll(where: \.isSample)
        save()
    }

    func deleteAll() {
        conversations = []
        checkIns = []
        analyses = []
        safetyAlert = .none
        save()
    }
}

// MARK: - 31. Psychological export (CSV / JSON / PDF) — integrated with DataExportManager

nonisolated struct PsychExportBundle: Codable {
    let generatedAt: Date
    let note: String
    let conversations: [Conversation]
    let checkIns: [MoodCheckIn]
    let analyses: [EmotionAnalysis]
}

extension DataExportManager {
    func psychRecords(_ p: PsychologicalMonitoringManager, since start: Date?) -> (conversations: [Conversation], checkIns: [MoodCheckIn], analyses: [EmotionAnalysis]) {
        let inRange: (Date) -> Bool = { d in start.map { d >= $0 } ?? true }
        let convos = p.conversations
            .filter { p.exportIncludesPrivate || $0.kind != .privateJournal }
            .map { c -> Conversation in
                var c = c
                c.messages = c.messages.filter { inRange($0.time) }
                return c
            }
            .filter { !$0.messages.isEmpty }
        return (convos, p.checkIns.filter { inRange($0.date) }, p.analyses.filter { inRange($0.createdAt) })
    }

    /// One row per record. Columns keep what the astronaut wrote, selected, what the AI inferred, and what it was uncertain about separate.
    func psychCSV(_ p: PsychologicalMonitoringManager, since start: Date?) -> String {
        let (convos, checks, analyses) = psychRecords(p, since: start)
        var s = "\u{FEFF}record_type,timestamp_utc,conversation,entry_kind,astronaut_wrote,astronaut_selected,stress_0_10,energy_0_10,workload_0_10,ai_or_keyword_inferred_primary,inferred_secondary,evidence,contributing_factors,fatigue_type,intensity,confidence,uncertain,method,status,astronaut_correction,id\n"
        func row(_ f: [String?]) { s += f.map { Self.csvField($0) }.joined(separator: ",") + "\n" }
        for c in checks {
            row(["mood_check_in", c.date.ISO8601Format(), nil, c.isSample ? "SAMPLE" : "check-in", c.note,
                 c.emotions.map(\.label).joined(separator: "; "), c.stress.map { String($0) }, c.energy.map { String($0) },
                 c.workload.map { String($0) }, nil, nil, nil, c.missionEvent, nil, nil, nil, nil, "self-report", nil, nil, c.id.uuidString])
        }
        for c in convos {
            for m in c.messages {
                row(["message", m.time.ISO8601Format(), c.title, c.kind.label, m.role == .astronaut ? m.text : nil, nil, nil, nil, nil,
                     m.role == .astronaut ? nil : "[\(m.role.rawValue)] \(m.text)", nil, nil, nil, nil, nil, nil, nil,
                     m.role.rawValue, m.pendingAnalysis ? "pending AI analysis" : nil, nil, m.id.uuidString])
            }
        }
        for a in analyses {
            row(["emotion_analysis", a.createdAt.ISO8601Format(), nil, a.isSample ? "SAMPLE" : nil, a.excerpt, nil, nil, nil, nil,
                 a.primary.map(\.label).joined(separator: "; "), a.secondary.map(\.label).joined(separator: "; "),
                 (a.primary + a.secondary).map(\.evidence).joined(separator: " | "), a.contributingFactors.joined(separator: "; "),
                 a.fatigue.label, a.intensity.label, a.confidence.label, a.uncertainties.joined(separator: "; "),
                 a.method.label, a.status.label,
                 a.correction.map { "\($0.verdict.label): \($0.emotions.map(\.label).joined(separator: ", ")) \($0.comment)" },
                 a.id.uuidString])
        }
        return s
    }

    func psychJSON(_ p: PsychologicalMonitoringManager, since start: Date?) -> Data? {
        let (convos, checks, analyses) = psychRecords(p, since: start)
        let bundle = PsychExportBundle(generatedAt: Date(),
                                       note: "Messages with role 'astronaut' are original text. Analyses are inferences (method onDeviceAI or keywordScreen) and never replace the original. Corrections are the astronaut's own.",
                                       conversations: convos, checkIns: checks, analyses: analyses)
        return try? JSONCoding.encoder(pretty: true).encode(bundle)
    }

    func psychPDF(_ p: PsychologicalMonitoringManager, since start: Date?) -> Data {
        let (convos, checks, analyses) = psychRecords(p, since: start)
        let h1 = UIFont.boldSystemFont(ofSize: 20), h2 = UIFont.boldSystemFont(ofSize: 14), body = UIFont.systemFont(ofSize: 10.5)
        var blocks: [(String, UIFont, UIColor)] = []
        blocks.append(("ASTRA — Psychological Self-Monitoring Report", h1, .black))
        blocks.append(("Generated \(Date().formatted(date: .abbreviated, time: .shortened)). Self-reports, AI inferences, and keyword screens are labeled separately. This is self-monitoring support, not a clinical assessment.", body, .darkGray))
        for days in [7, 30] {
            blocks.append(("Last \(days) days", h2, .black))
            blocks.append((p.summary(days: days).lines.joined(separator: "\n"), body, .black))
        }
        blocks.append(("Compared with personal baseline", h2, .black))
        blocks.append((p.baselineNotes().joined(separator: "\n"), body, .black))
        blocks.append(("Mood check-ins (self-reported) — \(checks.count)", h2, .black))
        var checkLines: [String] = []
        for c in checks.suffix(30) {
            var l = "\(c.date.formatted(date: .abbreviated, time: .shortened))\(c.isSample ? " [SAMPLE]" : ""): "
            l += c.emotions.isEmpty ? "no states selected" : c.emotions.map(\.label).joined(separator: ", ")
            if let st = c.stress { l += " · stress \(st)/10" }
            if !c.note.isEmpty { l += " — \"\(c.note)\"" }
            checkLines.append(l)
        }
        blocks.append((checkLines.joined(separator: "\n"), body, .black))
        blocks.append(("Inferred observations — \(analyses.count)", h2, .black))
        blocks.append((analyses.suffix(30).map { a in
            var l = "\(a.createdAt.formatted(date: .abbreviated, time: .shortened)) [\(a.method.label), confidence \(a.confidence.label)]: "
            l += a.status == .complete ? (a.primary + a.secondary).map(\.label).joined(separator: ", ") : a.status.label
            if let c = a.correction { l += "\n   Astronaut correction (\(c.verdict.label)): \(c.emotions.map(\.label).joined(separator: ", ")) \(c.comment)" }
            if !a.uncertainties.isEmpty { l += "\n   Uncertain: " + a.uncertainties.joined(separator: "; ") }
            return l
        }.joined(separator: "\n"), body, .black))
        blocks.append(("Written entries (original text)", h2, .black))
        blocks.append((convos.flatMap { c in c.messages.filter { $0.role == .astronaut }.map { "\($0.time.formatted(date: .abbreviated, time: .shortened)) [\(c.kind.label)]: \($0.text)" } }
            .suffix(40).joined(separator: "\n\n"), body, .black))
        if !p.exportIncludesPrivate { blocks.append(("Private journal entries were excluded from this export.", body, .darkGray)) }
        return renderPDF(blocks)
    }
}

// MARK: - 32. Psychological GUI

enum MindSection: String, CaseIterable, Identifiable {
    case overview = "Overview", chat = "Chat", checkIn = "Check-in", trends = "Trends", history = "History"
    var id: String { rawValue }
}

struct PsychologicalDashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var section: MindSection = .overview

    var body: some View {
        let psych = model.psych
        NavigationStack {
            Group {
                if psych.lockEnabled && !psych.unlocked {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
                        Text("Private psychological records").font(.headline)
                        Button("Unlock") { Task { await psych.unlock() } }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        Picker("Section", selection: $section) {
                            ForEach(MindSection.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding([.horizontal, .top])
                        switch section {
                        case .overview: PsychOverview(section: $section)
                        case .chat: ConversationListView()
                        case .checkIn: MoodCheckInView()
                        case .trends: EmotionalTrendChartView()
                        case .history: PsychHistoryView()
                        }
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Mind")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct SafetyBanner: View {
    let level: SafetyLevel
    var dismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(level == .immediateConcern ? "Your safety comes first" : "Support is available", systemImage: "heart.circle.fill")
                .font(.headline)
            BulletList(items: level == .immediateConcern ? PsychSafetyScreen.immediateSteps : PsychSafetyScreen.concernSteps, color: .white)
            if let dismiss { Button("Close", action: dismiss).buttonStyle(.bordered).tint(.white) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((level == .immediateConcern ? Color.red : Color.orange).opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
    }
}

struct PsychOverview: View {
    @Environment(AppModel.self) private var model
    @Binding var section: MindSection

    var body: some View {
        let psych = model.psych
        let week = psych.summary(days: 7)
        ScrollView {
            VStack(spacing: 12) {
                if psych.safetyAlert > .none {
                    SafetyBanner(level: psych.safetyAlert) { psych.safetyAlert = .none }
                }
                Panel(title: "On-device AI", systemImage: psych.aiAvailable ? "cpu.fill" : "cpu") {
                    Text(psych.aiStatusText).font(.callout)
                    if let t = psych.lastAnalysisAt {
                        Text("Last successful local AI analysis: \(t.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    if psych.pendingCount > 0 {
                        HStack {
                            Text("\(psych.pendingCount) entries awaiting AI analysis").font(.caption).foregroundStyle(.yellow)
                            Spacer()
                            Button("Analyze now") { Task { await psych.analyzePending() } }.disabled(!psych.aiAvailable)
                        }
                    }
                    if let m = psych.statusMessage { Text(m).font(.caption).foregroundStyle(Theme.secondaryText) }
                }
                Panel(title: "Today", systemImage: "calendar") {
                    if let c = psych.todaysCheckIn {
                        EmotionChips(emotions: c.emotions)
                        if let s = c.stress { Text("Stress \(s)/10").font(.caption) }
                    } else {
                        Text("No check-in yet today.").font(.callout).foregroundStyle(Theme.secondaryText)
                    }
                    HStack {
                        Button { section = .checkIn } label: { Label("Check in", systemImage: "face.smiling") }.buttonStyle(.bordered)
                        Button {
                            section = .chat
                        } label: { Label("Talk", systemImage: "bubble.left.fill") }.buttonStyle(.borderedProminent)
                    }
                }
                Panel(title: "Recent observations from your writing", systemImage: "text.magnifyingglass") {
                    let recent = psych.analyses.suffix(3).reversed()
                    if recent.isEmpty { Text("No analyzed entries yet.").font(.callout).foregroundStyle(Theme.secondaryText) }
                    ForEach(Array(recent)) { a in AnalysisSummaryRow(analysis: a) }
                }
                Panel(title: "Last 7 days", systemImage: "chart.bar.fill") { BulletList(items: week.lines) }
                Panel(title: "Compared with your own baseline", systemImage: "person.crop.circle.badge.checkmark") {
                    BulletList(items: psych.baselineNotes())
                    Text("Changes from your own pattern are observations, not diagnoses.").font(.caption2).foregroundStyle(Theme.secondaryText)
                }
            }
            .padding()
        }
    }
}

struct EmotionChips: View {
    let emotions: [Emotion]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(emotions) { e in
                Label(e.label, systemImage: e.group.symbol)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(e.group.color.opacity(0.2), in: Capsule())
                    .foregroundStyle(e.group.color)
            }
        }
    }
}

struct AnalysisSummaryRow: View {
    let analysis: EmotionAnalysis
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Badge(text: analysis.method == .onDeviceAI ? "AI-INFERRED" : "KEYWORD", color: analysis.method == .onDeviceAI ? .pink : .gray)
                Badge(text: "Confidence \(analysis.confidence.label)", color: .blue)
                if analysis.isSample { Badge(text: "SAMPLE", color: .gray) }
                if analysis.correction != nil { Badge(text: "CORRECTED", color: .green) }
                Spacer()
                Text(analysis.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Theme.secondaryText)
            }
            if analysis.status == .complete {
                EmotionChips(emotions: analysis.effectiveEmotions)
            } else {
                Text(analysis.status.label).font(.callout).foregroundStyle(.yellow)
            }
            Text("\"\(analysis.excerpt)\"").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
        }
    }
}

struct ConversationListView: View {
    @Environment(AppModel.self) private var model
    @State private var openID: UUID?

    var body: some View {
        let psych = model.psych
        List {
            Section {
                ForEach(ConversationKind.allCases) { kind in
                    Button {
                        openID = psych.newConversation(kind)
                    } label: {
                        Label("New \(kind.label.lowercased())", systemImage: kind.symbol)
                    }
                }
            }
            Section("Previous") {
                if psych.conversations.isEmpty { Text("No conversations yet.").foregroundStyle(Theme.secondaryText) }
                ForEach(psych.conversations) { c in
                    NavigationLink {
                        PsychologicalChatView(conversationID: c.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(c.title, systemImage: c.kind.symbol).font(.callout)
                            Text(c.messages.last?.text ?? "Empty").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        }
                    }
                }
                .onDelete { idx in
                    let ids = idx.map { psych.conversations[$0].id }
                    for id in ids { psych.deleteConversation(id) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationDestination(item: $openID) { id in PsychologicalChatView(conversationID: id) }
    }
}

struct PsychologicalChatView: View {
    @Environment(AppModel.self) private var model
    let conversationID: UUID
    @State private var draft = ""
    @State private var selectedAnalysis: EmotionAnalysis?

    var body: some View {
        let psych = model.psych
        let convo = psych.conversation(conversationID)
        VStack(spacing: 0) {
            if let convo, convo.kind == .privateJournal {
                Label("Private — never analyzed by AI", systemImage: "lock.fill").font(.caption).padding(6)
            } else if !psych.aiAvailable {
                Text(psych.aiStatusText).font(.caption2).foregroundStyle(.yellow).padding(6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(convo?.messages ?? []) { m in
                            MessageBubble(message: m, analysis: psych.analysis(m.analysisID)) { a in selectedAnalysis = a }
                                .id(m.id)
                        }
                        if psych.respondingConversation == conversationID {
                            HStack {
                                ProgressView()
                                Text("ASTRA is thinking on-device…").font(.caption).foregroundStyle(Theme.secondaryText)
                                Spacer()
                            }
                            .id("typing")
                        }
                        if psych.analyzingCount > 0 {
                            Text("Analyzing emotions locally…").font(.caption2).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding()
                }
                .onChange(of: convo?.messages.count ?? 0) { _, _ in
                    if let last = convo?.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(alignment: .bottom) {
                TextField(convo?.kind == .chat ? "Write anything…" : "Write your journal entry…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(10)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
                Button {
                    let text = draft
                    draft = ""
                    Task { await psych.send(text, to: conversationID, bio: model.bio) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || psych.respondingConversation == conversationID)
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle(convo?.kind.label ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedAnalysis) { a in AnalysisDetailView(analysisID: a.id) }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let analysis: EmotionAnalysis?
    let onAnalysis: (EmotionAnalysis) -> Void

    var body: some View {
        let mine = message.role == .astronaut
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(10)
                    .background(mine ? Theme.accent.opacity(0.35) : message.role == .system ? Color.orange.opacity(0.25) : Theme.panel,
                                in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 6) {
                    Text(message.time.formatted(date: .omitted, time: .shortened))
                    if message.role == .system { Text("System notice") }
                    if mine && message.pendingAnalysis { Text("Awaiting AI analysis").foregroundStyle(.yellow) }
                }
                .font(.caption2).foregroundStyle(Theme.secondaryText)
                if let analysis {
                    Button { onAnalysis(analysis) } label: {
                        Label(analysis.status == .complete ? analysis.effectiveEmotions.prefix(3).map(\.label).joined(separator: ", ") : analysis.status.label,
                              systemImage: analysis.method == .onDeviceAI ? "sparkles" : "textformat")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if !mine { Spacer(minLength: 40) }
        }
    }
}

struct AnalysisDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let analysisID: UUID
    @State private var verdict: CorrectionVerdict = .accurate
    @State private var corrected: Set<Emotion> = []
    @State private var comment = ""

    var body: some View {
        let psych = model.psych
        NavigationStack {
            Form {
                if let a = psych.analysis(analysisID) {
                    Section("What you wrote") { Text(a.excerpt) }
                    Section("Inferred (\(a.method.label))") {
                        LabeledContent("Status", value: a.status.label)
                        LabeledContent("Confidence", value: a.confidence.label)
                        LabeledContent("Intensity (inferred, not measured)", value: a.intensity.label)
                        if a.fatigue != .notMentioned { LabeledContent("Tiredness", value: a.fatigue.label) }
                        ForEach(a.primary, id: \.self) { o in observation(o, "Primary") }
                        ForEach(a.secondary, id: \.self) { o in observation(o, "Secondary") }
                        if !a.contributingFactors.isEmpty { Text("Possible factors: " + a.contributingFactors.joined(separator: "; ")).font(.callout) }
                        if let c = a.changeFromPrevious { Text("Compared with before: \(c)").font(.callout) }
                    }
                    if !a.uncertainties.isEmpty { Section("Uncertain") { BulletList(items: a.uncertainties, color: .yellow) } }
                    if !a.followUpQuestions.isEmpty { Section("Questions to consider") { BulletList(items: a.followUpQuestions) } }
                    Section("Does this match how you feel?") {
                        Picker("Verdict", selection: $verdict) {
                            ForEach(CorrectionVerdict.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if verdict != .accurate {
                            ChipGrid(items: Emotion.allCases, label: \.label, selection: $corrected)
                        }
                        TextField("Comment (optional)", text: $comment, axis: .vertical)
                        Button("Save my correction") {
                            psych.correct(analysisID, UserCorrection(verdict: verdict, emotions: Array(corrected), comment: comment))
                            dismiss()
                        }
                        if let c = a.correction {
                            Text("Saved: \(c.verdict.label) — \(c.emotions.map(\.label).joined(separator: ", ")) \(c.comment)").font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Interpretation")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                if let a = psych.analysis(analysisID) {
                    corrected = Set(a.correction?.emotions ?? a.effectiveEmotions)
                    verdict = a.correction?.verdict ?? .accurate
                    comment = a.correction?.comment ?? ""
                }
            }
        }
    }

    private func observation(_ o: EmotionObservation, _ rank: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(rank): \(o.label)").font(.callout.weight(.semibold))
            if !o.evidence.isEmpty { Text("Evidence: \"\(o.evidence)\"").font(.caption).foregroundStyle(Theme.secondaryText) }
        }
    }
}

struct MoodCheckInView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = MoodCheckIn()
    @State private var selection: Set<Emotion> = []
    @State private var hasStress = false
    @State private var saved = false

    var body: some View {
        let psych = model.psych
        ScrollView {
            VStack(spacing: 12) {
                Panel(title: "How are you today? (optional — choose any, or none)", systemImage: "face.smiling") {
                    ForEach(EmotionGroup.allCases) { g in
                        Label(g.label, systemImage: g.symbol).font(.caption.weight(.semibold)).foregroundStyle(g.color)
                        ChipGrid(items: Emotion.allCases.filter { $0.group == g }, label: \.label, selection: $selection)
                    }
                }
                Panel(title: "Details (optional)", systemImage: "slider.horizontal.3") {
                    Toggle("Rate stress", isOn: $hasStress)
                    if hasStress {
                        Stepper("Stress \(draft.stress ?? 5)/10", value: Binding(get: { draft.stress ?? 5 }, set: { draft.stress = $0 }), in: 0...10)
                        Stepper("Energy \(draft.energy ?? 5)/10", value: Binding(get: { draft.energy ?? 5 }, set: { draft.energy = $0 }), in: 0...10)
                        Stepper("Workload \(draft.workload ?? 5)/10", value: Binding(get: { draft.workload ?? 5 }, set: { draft.workload = $0 }), in: 0...10)
                    }
                    TextField("Mission event today (e.g., EVA, docking)", text: $draft.missionEvent)
                        .textFieldStyle(.roundedBorder)
                    TextField("Anything you want to add", text: $draft.note, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    draft.emotions = Emotion.allCases.filter { selection.contains($0) }
                    if !hasStress { draft.stress = nil; draft.energy = nil; draft.workload = nil }
                    psych.saveCheckIn(draft)
                    saved = true
                } label: {
                    Label(psych.todaysCheckIn?.id == draft.id ? "Update today's check-in" : "Save check-in", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if saved { Text("Saved \(Date().formatted(date: .omitted, time: .shortened)). You can change it any time today.").font(.caption) }
                Text("Check-ins are supplementary. You can always describe how you feel in your own words in Chat.")
                    .font(.caption2).foregroundStyle(Theme.secondaryText)
            }
            .padding()
        }
        .onAppear {
            if let today = psych.todaysCheckIn {
                draft = today
                selection = Set(today.emotions)
                hasStress = today.stress != nil
            }
        }
    }
}

struct EmotionalTrendChartView: View {
    @Environment(AppModel.self) private var model
    @State private var days = 7

    var body: some View {
        let psych = model.psych
        let records = psych.dailyRecords(days: days)
        let summary = psych.summary(days: days)
        let baseline = TrendAnalyzer.stats(psych.dailyRecords(days: 60).filter { $0.day < Calendar.current.date(byAdding: .day, value: -7, to: Date())! }.compactMap(\.anyValence)).0
        ScrollView {
            VStack(spacing: 12) {
                Picker("Period", selection: $days) {
                    Text("Week").tag(7)
                    Text("Month").tag(30)
                }
                .pickerStyle(.segmented)

                Panel(title: "Mood balance by day", systemImage: "chart.xyaxis.line") {
                    Chart {
                        if let baseline {
                            RuleMark(y: .value("Baseline", baseline))
                                .foregroundStyle(.gray)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .annotation(position: .top, alignment: .leading) { Text("Your baseline").font(.caption2).foregroundStyle(.gray) }
                        }
                        ForEach(records) { r in
                            if let v = r.selfValence {
                                LineMark(x: .value("Day", r.day, unit: .day), y: .value("Balance", v), series: .value("Source", "Self-reported"))
                                    .foregroundStyle(by: .value("Source", "Self-reported"))
                                PointMark(x: .value("Day", r.day, unit: .day), y: .value("Balance", v))
                                    .foregroundStyle(by: .value("Source", "Self-reported"))
                            }
                            if let v = r.inferredValence {
                                LineMark(x: .value("Day", r.day, unit: .day), y: .value("Balance", v), series: .value("Source", "Inferred from writing"))
                                    .foregroundStyle(by: .value("Source", "Inferred from writing"))
                                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                            }
                        }
                    }
                    .chartYScale(domain: -1...1)
                    .chartForegroundStyleScale(["Self-reported": Color.green, "Inferred from writing": Color.pink])
                    .frame(height: 180)
                    Text("+1 = only positive states, −1 = only difficult states. Inferred values come from AI or keyword analysis of your writing and are not measurements.")
                        .font(.caption2).foregroundStyle(Theme.secondaryText)
                    if records.allSatisfy({ $0.entries == 0 }) { MissingDataView(text: "No records in this period.") }
                }

                Panel(title: "Self-reported stress", systemImage: "gauge.with.needle") {
                    let stressDays = records.filter { $0.stress != nil }
                    if stressDays.isEmpty {
                        MissingDataView(text: "No stress ratings in this period.")
                    } else {
                        Chart(stressDays) { r in
                            BarMark(x: .value("Day", r.day, unit: .day), y: .value("Stress", r.stress ?? 0))
                                .foregroundStyle((r.stress ?? 0) >= 7 ? Color.orange : Theme.accent)
                        }
                        .chartYScale(domain: 0...10)
                        .frame(height: 140)
                    }
                }

                Panel(title: "Most frequent states", systemImage: "chart.bar.xaxis") {
                    let selfTop = Array(summary.topSelfReported.prefix(6))
                    let inferredTop = Array(summary.topInferred.prefix(6))
                    if selfTop.isEmpty && inferredTop.isEmpty {
                        MissingDataView(text: "No states recorded yet.")
                    } else {
                        Chart(selfTop.map { EmotionCount(emotion: $0.0, count: $0.1, source: "Self-reported") }
                              + inferredTop.map { EmotionCount(emotion: $0.0, count: $0.1, source: "Inferred from writing") }) { item in
                            BarMark(x: .value("Count", item.count), y: .value("State", item.emotion.label))
                                .foregroundStyle(by: .value("Source", item.source))
                                .position(by: .value("Source", item.source))
                        }
                        .chartForegroundStyleScale(["Self-reported": Color.green, "Inferred from writing": Color.pink])
                        .frame(height: CGFloat(max(selfTop.count + inferredTop.count, 3)) * 26)
                    }
                }

                Panel(title: "Patterns", systemImage: "list.bullet.rectangle") {
                    BulletList(items: summary.lines)
                    if let s = psych.aiSummary { Text(s).font(.callout).padding(.top, 4) }
                    Button("Write an AI summary (on-device)") { Task { await psych.generateAISummary(days: days) } }
                        .disabled(!psych.aiAvailable)
                }

                Panel(title: "Links with body data (correlation, not cause)", systemImage: "point.3.connected.trianglepath.dotted") {
                    let corr = psych.correlations(bio: model.bio)
                    if corr.isEmpty {
                        Text("Needs at least 7 days with both mood/stress records and sleep, heart-rate, or HRV data.").font(.callout).foregroundStyle(Theme.secondaryText)
                    }
                    ForEach(corr) { Text($0.text).font(.callout) }
                    Text("A heart-rate or HRV change alone cannot show how someone feels.").font(.caption2).foregroundStyle(Theme.secondaryText)
                }
            }
            .padding()
        }
    }
}

struct PsychHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: EmotionAnalysis?
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var psych = model.psych
        List {
            Section("Check-ins") {
                if psych.checkIns.isEmpty { Text("None yet").foregroundStyle(Theme.secondaryText) }
                ForEach(psych.checkIns.reversed()) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(c.date.formatted(date: .abbreviated, time: .shortened)).font(.caption.weight(.semibold))
                            if c.isSample { Badge(text: "SAMPLE", color: .gray) }
                            if c.editedAt != nil { Badge(text: "EDITED", color: .blue) }
                        }
                        Text(c.emotions.isEmpty ? "No states selected" : c.emotions.map(\.label).joined(separator: ", ")).font(.callout)
                        if !c.note.isEmpty { Text(c.note).font(.caption).foregroundStyle(Theme.secondaryText) }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { psych.deleteCheckIn(c.id) } }
                }
            }
            Section("Interpretations of your writing") {
                if psych.analyses.isEmpty { Text("None yet").foregroundStyle(Theme.secondaryText) }
                ForEach(psych.analyses.reversed()) { a in
                    Button { selected = a } label: { AnalysisSummaryRow(analysis: a) }.buttonStyle(.plain)
                }
            }
            Section("Privacy & demo") {
                Toggle("Require Face ID / passcode for Mind", isOn: $psych.lockEnabled)
                    .onChange(of: psych.lockEnabled) { _, _ in psych.saveSettings() }
                Toggle("Keyword screen when AI is unavailable (labeled)", isOn: $psych.keywordFallback)
                    .onChange(of: psych.keywordFallback) { _, _ in psych.saveSettings() }
                Toggle("Include private journals in exports", isOn: $psych.exportIncludesPrivate)
                Button("Load 21 days of SAMPLE check-ins") { psych.loadSampleHistory() }
                Button("Remove SAMPLE data") { psych.clearSampleHistory() }
                Button("Delete all psychological records", role: .destructive) { confirmDelete = true }
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $selected) { a in AnalysisDetailView(analysisID: a.id) }
        .confirmationDialog("Delete all conversations, check-ins, and analyses?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { psych.deleteAll() }
        }
    }
}

struct WellbeingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let psych = model.psych
        Panel(title: "Wellbeing", systemImage: "brain.head.profile") {
            if psych.lockEnabled && !psych.unlocked {
                Text("Locked").font(.callout).foregroundStyle(Theme.secondaryText)
            } else {
                if let c = psych.todaysCheckIn, !c.emotions.isEmpty {
                    EmotionChips(emotions: Array(c.emotions.prefix(4)))
                } else {
                    Text("No mood check-in today.").font(.callout).foregroundStyle(Theme.secondaryText)
                }
                if let a = psych.analyses.last {
                    Text("Latest from writing (\(a.method == .onDeviceAI ? "AI-inferred" : "keyword")): " +
                         (a.status == .complete ? a.effectiveEmotions.prefix(3).map(\.label).joined(separator: ", ") : a.status.label))
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
                if psych.safetyAlert > .none { Text("Support information available — open Mind").font(.caption).foregroundStyle(.orange) }
            }
        }
        .onTapGesture { model.selectedTab = .mind }
    }
}

// MARK: - 33. Background monitoring (app closed) + Apple Watch live link
//
// Part A — HealthKit background delivery (implemented here):
//   iOS wakes ASTRA when new Watch samples reach HealthKit, even if the app is closed.
//   ASTRA evaluates them with the same RiskEngine and posts a local notification for Urgent/Emergency.
//   iOS decides how often it wakes the app; heart rate is typically delivered with delays of minutes up to about an hour.
//   Requires: HealthKit capability ▸ "Background Delivery" checkbox, and ASTRAAppDelegate in the @main App file.
//
// Part B — watchOS companion app (receiver implemented here, Watch app in ASTRAWatchApp.swift):
//   A workout session on the Watch streams heart rate every few seconds; the Watch checks thresholds itself
//   (haptic alert) and forwards samples to the iPhone over WatchConnectivity. WatchLinkReceiver feeds them into
//   the same BiometricDataManager pipeline.

/// Lets a non-Sendable completion handler cross into HealthKit's callback safely.
nonisolated final class CompletionBox: @unchecked Sendable {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

nonisolated final class BackgroundHealthMonitor: @unchecked Sendable {
    static let shared = BackgroundHealthMonitor()
    static let monitored: [MetricKind] = [.heartRate, .spo2, .respiratoryRate, .bodyTemperature, .hrv]

    private let healthStore = HKHealthStore()
    private let lock = NSLock()
    private var started = false

    static var status: String { UserDefaults.standard.string(forKey: "bg.status") ?? "Not started" }
    static var log: [String] { UserDefaults.standard.stringArray(forKey: "bg.log") ?? [] }
    static var lastCheck: Date? {
        let t = UserDefaults.standard.double(forKey: "bg.lastCheck")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private static func setStatus(_ s: String) { UserDefaults.standard.set(s, forKey: "bg.status") }

    private static func appendLog(_ s: String) {
        var l = log
        l.insert("\(Date().formatted(date: .abbreviated, time: .shortened)) — \(s)", at: 0)
        UserDefaults.standard.set(Array(l.prefix(30)), forKey: "bg.log")
    }

    /// Safe to call many times; registers observers once per launch. Must run at every launch (see ASTRAAppDelegate).
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started, HKHealthStore.isHealthDataAvailable() else { return }
        started = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if !granted { Self.appendLog("Notifications not allowed — background alerts cannot be shown.") }
        }

        for metric in Self.monitored {
            guard let id = metric.hkIdentifier else { continue }
            let type = HKQuantityType(id)
            healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { ok, error in
                if !ok {
                    Self.appendLog("Background delivery unavailable for \(metric.shortLabel): \(error?.localizedDescription ?? "unknown error"). Check the HealthKit Background Delivery capability.")
                }
            }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                let box = CompletionBox(completion)
                guard let self, error == nil else { box.run(); return }
                self.check(metric, type: type, completion: box)
            }
            healthStore.execute(query)
        }
        Self.setStatus("Background monitoring registered \(Date().formatted(date: .abbreviated, time: .shortened))")
    }

    private func check(_ metric: MetricKind, type: HKQuantityType, completion: CompletionBox) {
        let key = "bg.anchor.\(metric.rawValue)"
        var anchor: HKQueryAnchor?
        if let data = UserDefaults.standard.data(forKey: key) {
            anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }
        // Only the last hour matters for alerts; older data is loaded by the foreground app.
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-3600), end: nil)
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, newAnchor, _ in
            if let newAnchor, let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: key)
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "bg.lastCheck")
            if let latest = (samples as? [HKQuantitySample])?.max(by: { $0.endDate < $1.endDate }) {
                self?.evaluate(metric, BiometricRecord(sample: latest, metric: metric))
            }
            completion.run()
        }
        healthStore.execute(query)
    }

    /// Same RiskEngine and environment as the foreground app, so background and foreground alerts agree.
    func evaluate(_ metric: MetricKind, _ r: BiometricRecord) {
        guard r.value.isFinite, metric.plausibleRange.contains(r.value), Date().timeIntervalSince(r.end) < 3600 else { return }
        var v = VitalsSnapshot()
        switch metric {
        case .heartRate: v.heartRate = r.value; v.heartRateAt = r.end
        case .spo2: v.spo2 = r.value
        case .respiratoryRate: v.respiratoryRate = r.value
        case .bodyTemperature: v.bodyTemperature = r.value
        case .hrv: v.hrv = r.value
        default: return
        }
        let env = FileStore.load([EnvironmentalParameter].self, from: "astra_environment.json") ?? []
        func param(_ k: EnvironmentKind) -> EnvironmentalParameter? { env.first { $0.kind == k } }
        let physics = PhysicalModelCalculator.evaluate(pressure: param(.cabinPressure), oxygen: param(.oxygenFraction),
                                                       gravity: param(.gravity), adapted: param(.adaptedGravity))
        let evaluation = RiskEngine.evaluate(v, physics: physics, pressureRate: nil, gravityTransition: false)
        guard evaluation.tier >= .urgent, let reason = evaluation.reasons.first else { return }

        // At most one notification per metric every 10 minutes.
        let key = "bg.notified.\(metric.rawValue)"
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: key) > 600 else { return }
        UserDefaults.standard.set(now, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = "ASTRA \(evaluation.tier.label): \(reason.title)"
        content.body = "\(reason.detail) at \(r.end.formatted(date: .omitted, time: .shortened)) (\(r.sourceName)). Open ASTRA for guided care."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        Self.appendLog("\(evaluation.tier.label): \(reason.title) — \(reason.detail)")
    }
}

/// Add to the @main App file:  @UIApplicationDelegateAdaptor(ASTRAAppDelegate.self) private var appDelegate
final class ASTRAAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BackgroundHealthMonitor.shared.start()
        WatchLinkReceiver.shared.activate()
        return true
    }

    /// Show ASTRA alerts as banners even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

/// iPhone side of Part B. Receives live samples from the ASTRA Watch app.
nonisolated final class WatchLinkReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLinkReceiver()

    @MainActor var onRecords: (@MainActor ([BiometricRecord]) -> Void)?
    private let lock = NSLock()
    private var activated = false

    func activate() {
        lock.lock()
        defer { lock.unlock() }
        guard !activated, WCSession.isSupported() else { return }
        activated = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var statusText: String {
        guard WCSession.isSupported() else { return "WatchConnectivity not supported on this device." }
        let s = WCSession.default
        guard s.activationState == .activated else { return "Watch link not active." }
        if !s.isPaired { return "No Apple Watch paired." }
        if !s.isWatchAppInstalled { return "ASTRA Watch app not installed — HealthKit sync is used instead." }
        return s.isReachable ? "Live link connected — streaming from ASTRA Watch." : "ASTRA Watch app installed; not currently reachable (data queued)."
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { handle(message) }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { handle(userInfo) }

    private func handle(_ payload: [String: Any]) {
        guard let samples = payload["samples"] as? [[String: Any]] else { return }
        let records: [BiometricRecord] = samples.compactMap { s in
            guard let raw = s["metric"] as? String, let metric = MetricKind(rawValue: raw),
                  let value = s["value"] as? Double, let t = s["time"] as? Double else { return nil }
            let date = Date(timeIntervalSince1970: t)
            let id = (s["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            return BiometricRecord(id: id, metric: metric, value: value, unit: metric.unit, start: date, end: date,
                                   sourceName: "ASTRA Watch (live)", sourceKind: .appleWatch, deviceModel: "Watch",
                                   context: "Live workout stream", reliability: .high, note: nil)
        }
        guard !records.isEmpty else { return }
        for r in records { BackgroundHealthMonitor.shared.evaluate(r.metric, r) }
        Task { @MainActor in self.onRecords?(records) }
    }
}

// MARK: - 34. Simulation data model (Live vs Simulation separation, validation log)
//
// Data flow for simulation (identical to live after the first step):
//   SimulationEngine / manual controls / CSV / Google Sheets → BiometricRecord (sourceKind = simulated…)
//   → BiometricDataManager.receive (validation, duplicate/out-of-order checks, issue log) → BiometricStore
//   → TrendAnalyzer → RiskEngine → charts/dashboard → MedicalReasoningEngine (offline protocols + on-device AI)
//   → ClinicalReport (records data source + exact input snapshot).
// Live mode shows only real measurements; Simulation mode shows only simulated ones. HealthKit is never written to.

nonisolated enum DataMode: String, Codable {
    case live, simulation
    var label: String { self == .live ? "Live" : "Simulation" }
}

nonisolated struct DataIssue: Identifiable, Codable, Hashable {
    var id = UUID()
    var loggedAt = Date()
    let metric: String
    let value: Double
    let unit: String
    let source: String
    let timestamp: Date
    let reason: String
    let rejected: Bool
}

/// Keys a scenario can drive: every MetricKind raw value plus environment keys.
nonisolated enum SimKey {
    static let cabinPressure = "cabinPressure"
    static let oxygenFraction = "oxygenFraction"
    static let metrics: [MetricKind] = [.heartRate, .systolicBP, .diastolicBP, .spo2, .bodyTemperature, .respiratoryRate, .hrv, .bloodGlucose]
    static let all: [String] = metrics.map(\.rawValue) + [cabinPressure, oxygenFraction]

    static func label(_ key: String) -> String {
        if let m = MetricKind(rawValue: key) { return "\(m.shortLabel) (\(m.unit))" }
        if key == cabinPressure { return "Cabin pressure (kPa)" }
        if key == oxygenFraction { return "Cabin O₂ (%)" }
        return key
    }
}

nonisolated struct ScenarioKeyframe: Codable, Identifiable, Hashable {
    var id = UUID()
    var minute: Double
    var values: [String: Double] = [:]
    /// Sensors disconnected from this point until the next keyframe: no data are generated (recorded as missing).
    var dropout = false
    var note = ""
}

nonisolated struct SimScenario: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var summary: String
    var context = ""
    var expectedBehavior = ""
    var durationMinutes: Double
    var sampleSeconds: Double = 60
    /// Built-in templates interpolate between keyframes; imported datasets play exactly their rows (no invented values).
    var interpolate = true
    var environmentPreset: String?
    var keyframes: [ScenarioKeyframe]
    var source = "Custom"
    var isBuiltIn = false

    var sortedFrames: [ScenarioKeyframe] { keyframes.sorted { $0.minute < $1.minute } }

    func value(_ key: String, at minute: Double) -> Double? {
        let frames = sortedFrames.filter { $0.values[key] != nil }
        guard let first = frames.first, let last = frames.last else { return nil }
        if !interpolate {
            return sortedFrames.last { $0.minute <= minute + 1e-6 }.flatMap { abs($0.minute - minute) < 1e-6 ? $0.values[key] : nil }
        }
        if minute <= first.minute { return first.values[key] }
        if minute >= last.minute { return last.values[key] }
        guard let i = frames.lastIndex(where: { $0.minute <= minute }), i + 1 < frames.count,
              let a = frames[i].values[key], let b = frames[i + 1].values[key] else { return nil }
        let t = (minute - frames[i].minute) / max(frames[i + 1].minute - frames[i].minute, 1e-6)
        return a + (b - a) * t
    }

    func isDropout(at minute: Double) -> Bool {
        sortedFrames.last { $0.minute <= minute + 1e-6 }?.dropout ?? false
    }

    var keysUsed: [String] { SimKey.all.filter { k in keyframes.contains { $0.values[k] != nil } } }

    /// Sample times in simulated minutes.
    var sampleMinutes: [Double] {
        if !interpolate { return sortedFrames.map(\.minute) }
        let step = max(sampleSeconds, 1) / 60
        return Array(stride(from: 0, through: durationMinutes + 1e-9, by: step))
    }
}

nonisolated struct GeneratedSample: Codable, Hashable {
    let minute: Double
    let key: String
    let value: Double
    let timestamp: Date
    let recordID: UUID?
}

// MARK: - 35. Built-in configurable test scenarios (test data, not diagnoses)

nonisolated enum ScenarioLibrary {
    private static func kf(_ minute: Double, _ v: [String: Double], dropout: Bool = false, note: String = "") -> ScenarioKeyframe {
        ScenarioKeyframe(minute: minute, values: v, dropout: dropout, note: note)
    }
    private static let baseline: [String: Double] = ["heartRate": 72, "systolicBP": 118, "diastolicBP": 78, "spo2": 98,
                                                      "bodyTemperature": 36.7, "respiratoryRate": 14, "hrv": 48]

    static let templates: [SimScenario] = [
        SimScenario(name: "Spreadsheet example (illustrative)", summary: "HR, BP, SpO₂ and temperature change over 15 minutes, matching the example table.",
                    expectedBehavior: "Observe → Caution as HR exceeds 100 and BP rises; sustained-change notes after 3 readings.",
                    durationMinutes: 15, sampleSeconds: 60,
                    keyframes: [kf(0, ["heartRate": 72, "systolicBP": 118, "diastolicBP": 78, "spo2": 98, "bodyTemperature": 36.7]),
                                kf(5, ["heartRate": 85, "systolicBP": 125, "diastolicBP": 82, "spo2": 97, "bodyTemperature": 36.8]),
                                kf(10, ["heartRate": 105, "systolicBP": 145, "diastolicBP": 95, "spo2": 95, "bodyTemperature": 37.0]),
                                kf(15, ["heartRate": 120, "systolicBP": 160, "diastolicBP": 100, "spo2": 93, "bodyTemperature": 37.2])],
                    source: "Built-in template", isBuiltIn: true),
        SimScenario(name: "Gradual heart-rate increase", summary: "Heart rate rises from 72 to 125 bpm over 30 minutes; other values steady.",
                    expectedBehavior: "Observe at >100 bpm, Caution at ≥120 bpm. Single vs sustained readings distinguished.",
                    durationMinutes: 30, keyframes: [kf(0, baseline), kf(30, baseline.merging(["heartRate": 125]) { $1 })],
                    source: "Built-in template", isBuiltIn: true),
        SimScenario(name: "Blood-pressure rise", summary: "Systolic 118→185, diastolic 78→110 mmHg over 30 minutes.",
                    expectedBehavior: "Caution at ≥160 systolic, Urgent at ≥180.",
                    durationMinutes: 30, keyframes: [kf(0, baseline), kf(30, baseline.merging(["systolicBP": 185, "diastolicBP": 110, "heartRate": 88]) { $1 })],
                    source: "Built-in template", isBuiltIn: true),
        SimScenario(name: "Oxygen saturation decline", summary: "SpO₂ 98→86% with rising respiratory and heart rate over 20 minutes.",
                    context: "Crew member reports shortness of breath.",
                    expectedBehavior: "Caution <94%, Urgent <90%, Emergency <85%; breathing guidance with oxygen.",
                    durationMinutes: 20, keyframes: [kf(0, baseline), kf(20, baseline.merging(["spo2": 86, "respiratoryRate": 27, "heartRate": 108]) { $1 })],
                    source: "Built-in template", isBuiltIn: true),
        SimScenario(name: "Body-temperature rise", summary: "Temperature 36.7→39.8 °C over 60 minutes with rising heart rate.",
                    expectedBehavior: "Observe ≥37.8, Caution ≥38.5 °C; fever guidance.",
                    durationMinutes: 60, sampleSeconds: 120,
                    keyframes: [kf(0, baseline), kf(60, baseline.merging(["bodyTemperature": 39.8, "heartRate": 104, "respiratoryRate": 19]) { $1 })],
                    source: "Built-in template", isBuiltIn: true),
        SimScenario(name: "Multiple simultaneous abnormalities", summary: "HR↑, BP↓, SpO₂↓, RR↑ together over 30 minutes (blood-loss-like pattern).",
                    context: "Deep laceration on the right thigh from a sharp panel edge.",
                    expectedBehavior: "Shock index ≥1 → Urgent; systolic <80 → Emergency; bleeding-control guidance.",
                    durationMinutes: 30,
                    keyframes: [kf(0, baseline), kf(15, ["heartRate": 108, "systolicBP": 104, "diastolicBP": 68, "spo2": 96, "respiratoryRate": 20, "hrv": 30, "bodyTemperature": 36.6]),
                                kf(30, ["heartRate": 138, "systolicBP": 78, "diastolicBP": 50, "spo2": 91, "respiratoryRate": 29, "hrv": 15, "bodyTemperature": 36.3])],
                    source: "Built-in template", isBuiltIn: true),
        SimScenario(name: "Intermittent sensor dropout", summary: "Normal values, but sensors stop reporting between minutes 5 and 12.",
                    expectedBehavior: "Gap shown on charts; stale-data notes; no values invented during the gap.",
                    durationMinutes: 20,
                    keyframes: [kf(0, baseline), kf(5, baseline, dropout: true, note: "Sensor disconnected"), kf(12, baseline, note: "Sensor reconnected"), kf(20, baseline)],
                    source: "Built-in template", isBuiltIn: true),
        SimScenario(name: "Sudden sensor disconnection", summary: "Heart rate climbing, then all sensors disconnect at minute 8.",
                    expectedBehavior: "Last values shown with age; data marked stale; missing data listed.",
                    durationMinutes: 15,
                    keyframes: [kf(0, baseline), kf(8, baseline.merging(["heartRate": 112]) { $1 }, dropout: true, note: "Disconnected"), kf(15, baseline, dropout: true)],
                    source: "Built-in template", isBuiltIn: true),
        SimScenario(name: "Cabin pressure drop", summary: "Cabin pressure 101 → 4 kPa over 10 minutes with falling SpO₂.",
                    context: "Cabin pressure alarm sounding.",
                    expectedBehavior: "Rapid depressurization → Emergency; Armstrong limit crossed; restore-pressure guidance first.",
                    durationMinutes: 10, sampleSeconds: 30, environmentPreset: MissionPreset.iss.rawValue,
                    keyframes: [kf(0, baseline.merging([SimKey.cabinPressure: 101.3]) { $1 }),
                                kf(6, ["cabinPressure": 40, "spo2": 90, "heartRate": 112, "respiratoryRate": 24]),
                                kf(10, ["cabinPressure": 4, "spo2": 72, "heartRate": 135, "respiratoryRate": 30])],
                    source: "Built-in template", isBuiltIn: true)
    ]
}

// MARK: - 36. CSV import / export (offline) — also used for Google Sheets rows

nonisolated enum CSVImportExportManager {
    struct ImportResult {
        var scenario: SimScenario?
        var rowsRead = 0
        var valuesAccepted = 0
        var issues: [String] = []
    }

    /// RFC 4180-style parser: quoted fields, escaped quotes, commas or semicolons.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false
        let delimiter: Character = text.split(separator: "\n").first.map { $0.filter { $0 == ";" }.count > $0.filter { $0 == "," }.count } == true ? ";" : ","
        var chars = Array(text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n"))
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" {
                row.append(field); field = ""
                if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows
    }

    private static func normalize(_ h: String) -> String {
        h.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Maps a header to a scenario key. "bp"/"bloodpressure" columns hold "120/80".
    private static func key(for header: String) -> String? {
        let h = normalize(header)
        let map: [(String, [String])] = [
            ("time", ["timestamp", "time", "date", "datetime", "timestamputc", "minute", "minutes", "t"]),
            ("bp", ["bloodpressure", "bp", "bloodpressuremmhg", "bpmmhg"]),
            ("systolicBP", ["systolic", "sbp", "systolicbp", "systolicmmhg", "systolicbloodpressure"]),
            ("diastolicBP", ["diastolic", "dbp", "diastolicbp", "diastolicmmhg", "diastolicbloodpressure"]),
            ("heartRate", ["heartrate", "hr", "pulse", "heartratebpm", "hrbpm"]),
            ("spo2", ["spo2", "oxygensaturation", "o2sat", "spo2percent", "saturation"]),
            ("bodyTemperature", ["temperature", "temp", "bodytemperature", "temperaturec", "tempc", "bodytemp"]),
            ("respiratoryRate", ["respiratoryrate", "rr", "resp", "respirationrate", "breathingrate"]),
            ("hrv", ["hrv", "hrvms", "heartratevariability", "sdnn"]),
            ("bloodGlucose", ["glucose", "bloodglucose", "glucosemgdl"]),
            ("cabinPressure", ["cabinpressure", "pressure", "pressurekpa", "ambientpressure"]),
            ("oxygenFraction", ["cabino2", "oxygenfraction", "o2percent", "cabinoxygen"])
        ]
        return map.first { $0.1.contains(h) }?.0
    }

    private static func number(_ s: String) -> Double? {
        guard let r = s.range(of: #"-?\d+([.,]\d+)?"#, options: .regularExpression) else { return nil }
        return Double(s[r].replacingOccurrences(of: ",", with: "."))
    }

    private static func date(_ s: String, row: Int) -> (Date?, Double?) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let m = Double(t) { return (nil, m) }                         // already in minutes
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return (d, nil) }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return (d, nil) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm"] {
            f.dateFormat = format
            if let d = f.date(from: t) { return (d, nil) }
        }
        for format in ["HH:mm:ss", "HH:mm", "H:mm"] {
            f.dateFormat = format
            if let d = f.date(from: t) {
                let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
                return (Calendar.current.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0, of: Date()), nil)
            }
        }
        return (nil, nil)
    }

    /// Validates a unit written next to a value; returns a reason when it is not the expected unit (never converted silently).
    private static func unitProblem(_ key: String, _ raw: String, _ value: Double) -> String? {
        let r = raw.lowercased()
        switch key {
        case "bodyTemperature":
            if r.contains("°f") || r.hasSuffix("f") || value > 45 { return "temperature looks like Fahrenheit (\(raw)); ASTRA expects °C and does not convert automatically" }
        case "spo2":
            if value <= 1 { return "SpO₂ \(raw) looks like a fraction; ASTRA expects percent" }
        case "bloodGlucose":
            if r.contains("mmol") { return "glucose in mmol/L (\(raw)); ASTRA expects mg/dL and does not convert automatically" }
        case "cabinPressure":
            if r.contains("psi") || r.contains("mmhg") || r.contains("hpa") || r.contains("atm") { return "pressure unit in '\(raw)' is not kPa; not converted" }
        default:
            break
        }
        return nil
    }

    private static func plausible(_ key: String, _ v: Double) -> Bool {
        if let m = MetricKind(rawValue: key) { return m.plausibleRange.contains(v) }
        if key == SimKey.cabinPressure { return EnvironmentKind.cabinPressure.validRange.contains(v) }
        if key == SimKey.oxygenFraction { return EnvironmentKind.oxygenFraction.validRange.contains(v) }
        return false
    }

    /// Converts rows (first row = header) into a scenario. Wide format (one column per parameter) or long format (metric,value,timestamp).
    static func scenario(fromRows input: [[String]], name: String, source: String) -> ImportResult {
        var result = ImportResult()
        guard let header = input.first, input.count > 1 else {
            result.issues.append("No data rows found. The first row must be a header such as: Timestamp, Heart Rate, Blood Pressure, SpO2, Temperature")
            return result
        }
        var rows = Array(input.dropFirst())
        result.rowsRead = rows.count
        let normalized = header.map(normalize)

        // Long format (e.g. ASTRA's own biometrics export): convert to wide.
        if let mi = normalized.firstIndex(of: "metric"), let vi = normalized.firstIndex(of: "value"),
           let ti = normalized.firstIndex(where: { ["timestamputc", "timestamp", "time"].contains($0) }) {
            var grouped: [String: [String: String]] = [:]
            var order: [String] = []
            for r in rows where r.count > max(mi, vi, ti) {
                if grouped[r[ti]] == nil { order.append(r[ti]) }
                grouped[r[ti], default: [:]][r[mi]] = r[vi]
            }
            let keys = SimKey.all
            rows = order.map { t in [t] + keys.map { grouped[t]?[$0] ?? "" } }
            return scenario(fromRows: [["timestamp"] + keys] + rows, name: name, source: source)
        }

        let keys = header.map(key(for:))
        guard let timeIndex = keys.firstIndex(of: "time") else {
            result.issues.append("Missing a Timestamp (or Time / Minute) column.")
            return result
        }
        let recognized = keys.compactMap { $0 }.filter { $0 != "time" }
        if recognized.isEmpty { result.issues.append("No recognized measurement columns. Recognized: heart rate, blood pressure, systolic, diastolic, SpO2, temperature, respiratory rate, HRV, glucose, cabin pressure.") }
        for (i, h) in header.enumerated() where keys[i] == nil && !h.trimmingCharacters(in: .whitespaces).isEmpty {
            result.issues.append("Column '\(h)' is not recognized and was ignored.")
        }

        var parsed: [(minute: Double?, date: Date?, values: [String: Double], row: Int)] = []
        for (n, r) in rows.enumerated() {
            let rowNumber = n + 2
            guard timeIndex < r.count else { result.issues.append("Row \(rowNumber): missing timestamp — row skipped."); continue }
            let (d, m) = date(r[timeIndex], row: rowNumber)
            if d == nil && m == nil { result.issues.append("Row \(rowNumber): unreadable timestamp '\(r[timeIndex])' — row skipped."); continue }
            var values: [String: Double] = [:]
            for (i, k) in keys.enumerated() {
                guard let k, k != "time" else { continue }
                let raw = i < r.count ? r[i].trimmingCharacters(in: .whitespaces) : ""
                if raw.isEmpty || raw == "-" || raw.lowercased() == "na" || raw.lowercased() == "missing" {
                    continue    // missing stays missing
                }
                if k == "bp" {
                    let parts = raw.split(separator: "/").map { number(String($0)) }
                    guard parts.count == 2, let s = parts[0], let dia = parts[1] else {
                        result.issues.append("Row \(rowNumber): blood pressure '\(raw)' is not in 'systolic/diastolic' form — not used."); continue
                    }
                    for (key, v) in [("systolicBP", s), ("diastolicBP", dia)] {
                        if plausible(key, v) { values[key] = v; result.valuesAccepted += 1 }
                        else { result.issues.append("Row \(rowNumber): \(SimKey.label(key)) \(fmt(v)) is outside the plausible range — not used.") }
                    }
                    if s <= dia { result.issues.append("Row \(rowNumber): systolic \(fmt(s)) ≤ diastolic \(fmt(dia)) — check the entry (kept as entered).") }
                    continue
                }
                guard let v = number(raw) else {
                    result.issues.append("Row \(rowNumber): '\(raw)' in \(SimKey.label(k)) is not a number — not used."); continue
                }
                if let problem = unitProblem(k, raw, v) { result.issues.append("Row \(rowNumber): \(problem) — not used."); continue }
                guard plausible(k, v) else {
                    result.issues.append("Row \(rowNumber): \(SimKey.label(k)) \(fmt(v, 1)) is outside the plausible range — not used."); continue
                }
                values[k] = v
                result.valuesAccepted += 1
            }
            parsed.append((m, d, values, rowNumber))
        }
        guard !parsed.isEmpty else { result.issues.append("No usable rows."); return result }

        // Convert to simulated minutes relative to the first row.
        let firstDate = parsed.compactMap { $0.date }.min()
        var frames: [ScenarioKeyframe] = []
        var seen = Set<Double>()
        var previous = -Double.infinity
        var outOfOrder = false
        for p in parsed {
            let minute: Double
            if let m = p.minute { minute = m } else if let d = p.date, let f = firstDate { minute = d.timeIntervalSince(f) / 60 } else { continue }
            if minute < previous { outOfOrder = true }
            previous = max(previous, minute)
            if seen.contains(minute) {
                result.issues.append("Row \(p.row): duplicate timestamp — row ignored (the first row with this time is used)."); continue
            }
            seen.insert(minute)
            frames.append(ScenarioKeyframe(minute: minute, values: p.values, note: "CSV row \(p.row)"))
        }
        if outOfOrder { result.issues.append("Rows were not in time order; playback follows the timestamps.") }
        frames.sort { $0.minute < $1.minute }
        let duration = max(frames.last?.minute ?? 1, 1)
        result.scenario = SimScenario(name: name, summary: "\(frames.count) time points imported from \(source).",
                                      expectedBehavior: "", durationMinutes: duration, sampleSeconds: 60, interpolate: false,
                                      keyframes: frames, source: source)
        return result
    }

    /// Exports a scenario as a wide, spreadsheet-friendly CSV (re-importable).
    static func csv(for s: SimScenario) -> String {
        let keys = s.keysUsed
        var out = "\u{FEFF}minute," + keys.map { SimKey.label($0).replacingOccurrences(of: ",", with: "") }.joined(separator: ",") + ",sensor_dropout,note\n"
        for f in s.sortedFrames {
            let cells: [String] = [fmt(f.minute, 2)] + keys.map { k in f.values[k].map { fmt($0, 1) } ?? "" } + [f.dropout ? "yes" : "", DataExportManager.csvField(f.note)]
            out += cells.joined(separator: ",") + "\n"
        }
        return out
    }
}

// MARK: - 37. Google Sheets scenario source (via the team Apps Script web app — no API keys in the app)

nonisolated struct ScenarioSheetResponse: Decodable {
    let ok: Bool
    let values: [[String]]?
    let error: String?
}

extension SheetsSync {
    /// Reads the 'scenario' tab as display strings (e.g. "118/78", "36.7°C"). Requires the updated ASTRA_Sheets.gs.
    func fetchScenarioRows() async -> [[String]]? {
        guard isConfigured, var components = URLComponents(string: webAppURL.trimmingCharacters(in: .whitespaces)) else {
            status = "Enter the Google Sheets web app URL and token on the Data tab first."
            return nil
        }
        components.queryItems = [URLQueryItem(name: "token", value: token), URLQueryItem(name: "sheet", value: "scenario")]
        guard let url = components.url else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let r = try? JSONDecoder().decode(ScenarioSheetResponse.self, from: data) else { throw SyncError.notJSON }
            guard r.ok, let values = r.values else { throw SyncError.server(r.error ?? "No 'scenario' tab") }
            return values
        } catch {
            status = "Scenario sheet unavailable: \(error.localizedDescription). Using the last saved copy."
            return nil
        }
    }
}

// MARK: - 38. SimulationEngine (playback, manual controls, speed, sync)

@MainActor
@Observable
final class SimulationEngine {
    private(set) var scenarios: [SimScenario] = []
    var active: SimScenario?
    var simMinute: Double = 0
    var isPlaying = false
    private(set) var speed: Double = 1

    /// Changing speed re-anchors the simulated clock so timestamps stay monotonic and never run ahead of real time.
    func setSpeed(_ s: Double) {
        speed = s
        if isPlaying { reanchor() }
        note("Speed set to \(fmt(s))×.")
    }
    private(set) var generated: [GeneratedSample] = []
    var log: [String] = []
    var lastImport: CSVImportExportManager.ImportResult?

    // Manual controls
    var manualValues: [MetricKind: Double] = [.heartRate: 72, .systolicBP: 118, .diastolicBP: 78, .spo2: 98,
                                              .bodyTemperature: 36.7, .respiratoryRate: 14, .hrv: 48, .bloodGlucose: 95]
    var manualEnabled: Set<MetricKind> = [.heartRate, .systolicBP, .diastolicBP, .spo2, .bodyTemperature, .respiratoryRate]
    var manualStreaming = false

    // Google Sheets synchronization
    var sheetAutoSync = false
    var sheetSyncSeconds: Double = 30
    var sheetStatus: String?
    var lastSheetSync: Date?

    @ObservationIgnored var onScenarioStarted: (@MainActor (SimScenario) -> Void)?
    @ObservationIgnored private weak var bio: BiometricDataManager?
    @ObservationIgnored private weak var env: EnvironmentalDataManager?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var manualTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var sampleIndex = 0
    @ObservationIgnored private var anchor = Date()
    @ObservationIgnored private var lastTimestamp = Date.distantPast
    @ObservationIgnored private var lastSheetSignature = ""
    @ObservationIgnored private var inDropout = false

    init() {
        let custom = FileStore.load([SimScenario].self, from: "astra_scenarios.json") ?? []
        scenarios = ScenarioLibrary.templates + custom
    }

    func attach(bio: BiometricDataManager, env: EnvironmentalDataManager) {
        self.bio = bio
        self.env = env
    }

    var clockText: String {
        let s = Int(simMinute * 60)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var progress: Double {
        guard let a = active, a.durationMinutes > 0 else { return 0 }
        return min(simMinute / a.durationMinutes, 1)
    }

    private func note(_ s: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .standard)) — \(s)", at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }

    // Scenario library

    func save(_ s: SimScenario) {
        var s = s
        s.isBuiltIn = false
        if let i = scenarios.firstIndex(where: { $0.id == s.id }) { scenarios[i] = s } else { scenarios.append(s) }
        persist()
        if active?.id == s.id { active = s }
        note("Scenario '\(s.name)' saved.")
    }

    func delete(_ s: SimScenario) {
        guard !s.isBuiltIn else { return }
        scenarios.removeAll { $0.id == s.id }
        persist()
    }

    private func persist() {
        FileStore.save(scenarios.filter { !$0.isBuiltIn }, to: "astra_scenarios.json")
    }

    // Playback

    func start(_ s: SimScenario) {
        stop(keepData: false)
        bio?.setMode(.simulation)
        if let raw = s.environmentPreset, let preset = MissionPreset(rawValue: raw) { env?.applyPreset(preset) }
        active = s
        simMinute = 0
        sampleIndex = 0
        generated = []
        lastTimestamp = .distantPast
        inDropout = false
        note("Started '\(s.name)' (\(s.source)) at \(fmt(speed))×.")
        onScenarioStarted?(s)
        play()
    }

    func play() {
        guard let a = active, !isPlaying else { return }
        if simMinute >= a.durationMinutes { restart(); return }
        bio?.setMode(.simulation)
        isPlaying = true
        reanchor()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isPlaying else { return }
                self.tick(realSeconds: 0.5)
            }
        }
    }

    func pause() {
        isPlaying = false
        task?.cancel()
        task = nil
    }

    func stop(keepData: Bool) {
        pause()
        if !keepData { simMinute = 0 }
    }

    /// Advance to the next sample immediately (works while paused).
    func stepForward() {
        guard let a = active else { return }
        let minutes = a.sampleMinutes
        guard sampleIndex < minutes.count else { note("End of scenario."); return }
        simMinute = minutes[sampleIndex]
        reanchor()
        emitDueSamples()
    }

    /// Removes samples generated after the target time and continues from there.
    func rewind(minutes back: Double = 5) {
        guard active != nil else { return }
        let target = max(0, simMinute - back)
        let removed = generated.filter { $0.minute > target + 1e-9 }
        let ids = Set(removed.compactMap(\.recordID))
        if !ids.isEmpty { bio?.store.remove { ids.contains($0.id) } }
        generated.removeAll { $0.minute > target + 1e-9 }
        simMinute = target
        sampleIndex = active?.sampleMinutes.firstIndex { $0 > target + 1e-9 } ?? 0
        lastTimestamp = generated.last?.timestamp ?? .distantPast
        reanchor()
        bio?.setMode(.simulation)
        bio?.onUpdate?()
        note("Rewound to T+\(clockText); \(ids.count) generated records removed.")
    }

    func restart() {
        guard let a = active else { return }
        let ids = Set(generated.compactMap(\.recordID))
        if !ids.isEmpty { bio?.store.remove { ids.contains($0.id) } }
        start(a)
    }

    /// Clears all simulated data and returns to Live mode. Real HealthKit records are untouched.
    func reset() {
        pause()
        stopManualStream()
        stopSheetSync()
        active = nil
        simMinute = 0
        generated = []
        bio?.clearSimulated()
        env?.stopDepressurizationDemo()
        bio?.setMode(.live)
        note("Simulation reset — all simulated records removed; Live mode restored.")
    }

    /// Simulated clock → timestamps. Spacing follows simulated time; timestamps never exceed real time and never go backwards.
    private func reanchor() {
        guard let a = active else { return }
        let remaining = max(a.durationMinutes - simMinute, 0)
        let compression = 1 - 1 / max(speed, 1)
        anchor = Date().addingTimeInterval(-simMinute * 60 - remaining * 60 * compression)
    }

    private func tick(realSeconds: Double) {
        guard let a = active else { return }
        simMinute += speed * realSeconds / 60
        emitDueSamples()
        if simMinute >= a.durationMinutes {
            simMinute = a.durationMinutes
            emitDueSamples()
            pause()
            note("Scenario '\(a.name)' finished.")
        }
    }

    private func emitDueSamples() {
        guard let a = active else { return }
        let minutes = a.sampleMinutes
        var batch: [BiometricRecord] = []
        while sampleIndex < minutes.count, minutes[sampleIndex] <= simMinute + 1e-9 {
            batch += samples(a, at: minutes[sampleIndex])
            sampleIndex += 1
        }
        if !batch.isEmpty { bio?.receive(batch) }
    }

    private func timestamp(for minute: Double) -> Date {
        var t = min(anchor.addingTimeInterval(minute * 60), Date())
        if t <= lastTimestamp { t = lastTimestamp.addingTimeInterval(1) }
        lastTimestamp = t
        return t
    }

    private func samples(_ a: SimScenario, at minute: Double) -> [BiometricRecord] {
        if a.isDropout(at: minute) {
            if !inDropout { note("T+\(fmtMinute(minute)): sensor dropout — no data generated (shown as missing).") }
            inDropout = true
            return []
        }
        if inDropout { note("T+\(fmtMinute(minute)): sensors reconnected.") }
        inDropout = false
        let t = timestamp(for: minute)
        var out: [BiometricRecord] = []
        for key in a.keysUsed {
            guard let v = a.value(key, at: minute) else { continue }
            if let m = MetricKind(rawValue: key) {
                let r = BiometricRecord(id: UUID(), metric: m, value: (v * 10).rounded() / 10, unit: m.unit, start: t, end: t,
                                        sourceName: "Scenario: \(a.name)", sourceKind: a.source == "Built-in template" || a.source == "Custom" ? .simulatedScenario : .simulatedImport,
                                        deviceModel: "ASTRA Simulation Engine", context: "T+\(fmtMinute(minute)) · \(a.source)",
                                        reliability: .medium, note: "Simulated test data")
                out.append(r)
                generated.append(GeneratedSample(minute: minute, key: key, value: r.value, timestamp: t, recordID: r.id))
            } else if key == SimKey.cabinPressure {
                env?.set(.cabinPressure, v, .simulated, "Scenario: \(a.name)")
                generated.append(GeneratedSample(minute: minute, key: key, value: v, timestamp: t, recordID: nil))
            } else if key == SimKey.oxygenFraction {
                env?.set(.oxygenFraction, v, .simulated, "Scenario: \(a.name)")
                generated.append(GeneratedSample(minute: minute, key: key, value: v, timestamp: t, recordID: nil))
            }
        }
        return out
    }

    private func fmtMinute(_ m: Double) -> String {
        let s = Int((m * 60).rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // Manual controls

    func sendManual() {
        bio?.setMode(.simulation)
        let now = Date()
        let records = manualEnabled.sorted { $0.rawValue < $1.rawValue }.compactMap { m -> BiometricRecord? in
            guard let v = manualValues[m] else { return nil }
            return BiometricRecord(id: UUID(), metric: m, value: v, unit: m.unit, start: now, end: now,
                                   sourceName: "Manual simulation control", sourceKind: .simulatedManual,
                                   deviceModel: "ASTRA Simulation Engine", context: "Manual control",
                                   reliability: .medium, note: "Simulated test data")
        }
        bio?.receive(records)
        note("Manual values sent: " + records.map { "\($0.metric.shortLabel) \(fmt($0.value, $0.metric.digits))" }.joined(separator: ", "))
    }

    func startManualStream() {
        stopManualStream()
        manualStreaming = true
        manualTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.manualStreaming else { return }
                self.sendManual()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopManualStream() {
        manualStreaming = false
        manualTask?.cancel()
        manualTask = nil
    }

    // CSV

    func importCSV(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lastImport = CSVImportExportManager.ImportResult(issues: ["Could not read the file as UTF-8 text."])
            return
        }
        var result = CSVImportExportManager.scenario(fromRows: CSVImportExportManager.parse(text),
                                                     name: url.deletingPathExtension().lastPathComponent, source: "CSV file")
        if var s = result.scenario {
            s.summary += " \(result.issues.count) issue(s) flagged."
            result.scenario = s
            save(s)
        }
        lastImport = result
        note("CSV import: \(result.rowsRead) rows, \(result.valuesAccepted) values accepted, \(result.issues.count) issue(s).")
    }

    func exportScenarioCSV(_ s: SimScenario) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ASTRA_scenario_\(s.name.replacingOccurrences(of: "/", with: "-")).csv")
        do {
            try Data(CSVImportExportManager.csv(for: s).utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            note("Export failed: \(error.localizedDescription)")
            return nil
        }
    }

    func exportSimulatedRecords(using exporter: DataExportManager) -> URL? {
        guard let bio else { return nil }
        let rows = bio.store.records.filter { $0.sourceKind.isSimulated }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ASTRA_simulated_records.csv")
        do {
            try Data(exporter.biometricsCSV(rows).utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            note("Export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // Google Sheets synchronization: sheet is the source of truth for the "Google Sheets" scenario.

    func syncSheet(_ sheets: SheetsSync) async {
        guard let rows = await sheets.fetchScenarioRows() else {
            sheetStatus = sheets.status ?? "Sync failed."
            if let cached = FileStore.load([[String]].self, from: "astra_sheet_scenario.json"), lastSheetSignature.isEmpty {
                applySheetRows(cached, cached: true)
            }
            return
        }
        let signature = rows.map { $0.joined(separator: "|") }.joined(separator: "\n")
        lastSheetSync = Date()
        guard signature != lastSheetSignature else {
            sheetStatus = "No changes in the sheet (checked \(Date().formatted(date: .omitted, time: .standard)))."
            return
        }
        lastSheetSignature = signature
        FileStore.save(rows, to: "astra_sheet_scenario.json")
        applySheetRows(rows, cached: false)
    }

    private func applySheetRows(_ rows: [[String]], cached: Bool) {
        let result = CSVImportExportManager.scenario(fromRows: rows, name: "Google Sheets scenario", source: "Google Sheets")
        lastImport = result
        guard var s = result.scenario else {
            sheetStatus = "Sheet could not be used: " + (result.issues.first ?? "unknown problem")
            return
        }
        if let existing = scenarios.first(where: { $0.source == "Google Sheets" }) { s.id = existing.id }
        save(s)
        if active?.id == s.id {
            // Keep the playback position; samples not yet played will use the edited values.
            active = s
            sampleIndex = s.sampleMinutes.firstIndex { $0 > simMinute + 1e-9 } ?? s.sampleMinutes.count
        }
        sheetStatus = (cached ? "Offline — using last saved sheet copy. " : "Synced \(Date().formatted(date: .omitted, time: .standard)). ")
            + "\(result.rowsRead) rows, \(result.valuesAccepted) values, \(result.issues.count) issue(s)."
        note(sheetStatus ?? "")
    }

    func startSheetSync(_ sheets: SheetsSync) {
        stopSheetSync()
        sheetAutoSync = true
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.sheetAutoSync else { return }
                await self.syncSheet(sheets)
                try? await Task.sleep(for: .seconds(max(self.sheetSyncSeconds, 10)))
            }
        }
    }

    func stopSheetSync() {
        sheetAutoSync = false
        syncTask?.cancel()
        syncTask = nil
    }
}

// MARK: - 39. Simulation GUI

struct SimulationModeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "testtube.2")
            VStack(alignment: .leading, spacing: 0) {
                Text("SIMULATION MODE — test data, not real measurements").font(.caption.weight(.heavy))
                if let a = model.sim.active {
                    Text("\(a.name) · T+\(model.sim.clockText) · \(fmt(model.sim.speed))×\(model.sim.isPlaying ? "" : " · paused")").font(.caption2)
                }
            }
            Spacer()
            Button("Open") { model.showSimulation = true }.font(.caption.weight(.bold))
            Button("Exit") { model.bio.setMode(.live) }.font(.caption.weight(.bold))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.pink.opacity(0.85))
        .foregroundStyle(.white)
    }
}

enum SimSection: String, CaseIterable, Identifiable {
    case control = "Control", manual = "Manual", data = "Datasets", analysis = "Analysis"
    var id: String { rawValue }
}

struct SimulationDashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var section: SimSection = .control

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modeHeader
                Picker("Section", selection: $section) {
                    ForEach(SimSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()
                ScrollView {
                    VStack(spacing: 12) {
                        if model.simEmergencyNotice {
                            HStack {
                                Label("SIMULATED EMERGENCY threshold reached", systemImage: "exclamationmark.triangle.fill").font(.callout.weight(.bold))
                                Spacer()
                                Button("OK") { model.simEmergencyNotice = false }
                            }
                            .padding()
                            .background(Color.red.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        }
                        switch section {
                        case .control: SimControlPanel()
                        case .manual: SimManualPanel()
                        case .data: SimDatasetPanel()
                        case .analysis: SimAnalysisPanel()
                        }
                    }
                    .padding([.horizontal, .bottom])
                }
            }
            .background(Theme.background)
            .navigationTitle("Simulation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var modeHeader: some View {
        HStack {
            Label(model.isSimulation ? "SIMULATION MODE" : "LIVE MODE", systemImage: model.isSimulation ? "testtube.2" : "sensor.fill")
                .font(.headline)
            Spacer()
            Picker("Mode", selection: Binding(get: { model.bio.store.mode }, set: { model.bio.setMode($0) })) {
                Text("Live").tag(DataMode.live)
                Text("Simulation").tag(DataMode.simulation)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
        .padding()
        .background(model.isSimulation ? Color.pink.opacity(0.3) : Color.green.opacity(0.2))
    }
}

struct SimControlPanel: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SimScenario?

    var body: some View {
        let sim = model.sim
        VStack(spacing: 12) {
            Panel(title: "Playback", systemImage: "play.rectangle.fill") {
                if let a = sim.active {
                    Text(a.name).font(.headline)
                    Text(a.summary).font(.caption).foregroundStyle(Theme.secondaryText)
                    ProgressView(value: sim.progress)
                    HStack {
                        Text("T+\(sim.clockText) / \(fmt(a.durationMinutes, 0)) min").font(.callout.monospacedDigit())
                        Spacer()
                        Text(sim.isPlaying ? "Playing" : "Paused").font(.caption.weight(.bold)).foregroundStyle(sim.isPlaying ? .green : .yellow)
                    }
                    if !a.expectedBehavior.isEmpty { Text("Expected: \(a.expectedBehavior)").font(.caption).foregroundStyle(Theme.accent) }
                } else {
                    Text("No scenario loaded. Choose one below.").font(.callout).foregroundStyle(Theme.secondaryText)
                }
                HStack(spacing: 8) {
                    Button { sim.rewind() } label: { Image(systemName: "gobackward.5") }
                    Button { sim.isPlaying ? sim.pause() : sim.play() } label: {
                        Image(systemName: sim.isPlaying ? "pause.fill" : "play.fill").frame(width: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { sim.stepForward() } label: { Image(systemName: "forward.frame.fill") }
                    Button { sim.restart() } label: { Image(systemName: "arrow.counterclockwise") }
                    Spacer()
                    Button("Reset", role: .destructive) { sim.reset() }
                }
                .buttonStyle(.bordered)
                .disabled(sim.active == nil && !model.isSimulation)
                Picker("Speed", selection: Binding(get: { sim.speed }, set: { sim.setSpeed($0) })) {
                    ForEach([1.0, 5, 10, 60], id: \.self) { Text("\(Int($0))×").tag($0) }
                }
                .pickerStyle(.segmented)
                Text("At 60×, one simulated hour passes in one real minute. Measurement timestamps keep simulated spacing and never run ahead of real time.")
                    .font(.caption2).foregroundStyle(Theme.secondaryText)
            }

            Panel(title: "Scenarios", systemImage: "list.bullet.rectangle.portrait") {
                ForEach(sim.scenarios) { s in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(s.name).font(.callout.weight(.semibold))
                                Badge(text: s.isBuiltIn ? "TEMPLATE" : s.source.uppercased(), color: s.isBuiltIn ? .gray : .blue)
                            }
                            Text("\(fmt(s.durationMinutes)) min · \(s.keysUsed.count) parameters · \(s.interpolate ? "interpolated" : "exact rows")")
                                .font(.caption2).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Button { editing = s } label: { Image(systemName: "pencil") }.buttonStyle(.bordered)
                        Button { sim.start(s) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderedProminent)
                    }
                    Divider()
                }
                Button {
                    editing = SimScenario(name: "New scenario", summary: "", durationMinutes: 30,
                                          keyframes: [ScenarioKeyframe(minute: 0, values: ["heartRate": 72, "spo2": 98]),
                                                      ScenarioKeyframe(minute: 30, values: ["heartRate": 110, "spo2": 94])])
                } label: { Label("Create custom scenario", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { s in ScenarioEditorView(scenario: s).environment(model) }
    }
}

struct SimManualPanel: View {
    @Environment(AppModel.self) private var model

    private let ranges: [MetricKind: ClosedRange<Double>] = [.heartRate: 30...200, .systolicBP: 60...220, .diastolicBP: 30...140,
                                                             .spo2: 70...100, .bodyTemperature: 33...42, .respiratoryRate: 4...45,
                                                             .hrv: 5...150, .bloodGlucose: 30...400]

    var body: some View {
        let sim = model.sim
        Panel(title: "Manual biometric controls", systemImage: "slider.horizontal.3") {
            ForEach(SimKey.metrics) { m in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Toggle(isOn: Binding(get: { sim.manualEnabled.contains(m) },
                                             set: { on in if on { sim.manualEnabled.insert(m) } else { sim.manualEnabled.remove(m) } })) {
                            Text(m.label).font(.callout)
                        }
                    }
                    if sim.manualEnabled.contains(m) {
                        HStack {
                            Slider(value: Binding(get: { sim.manualValues[m] ?? ranges[m]!.lowerBound }, set: { sim.manualValues[m] = (($0 * 10).rounded()) / 10 }),
                                   in: ranges[m] ?? 0...100)
                            TextField(m.unit, value: Binding(get: { sim.manualValues[m] }, set: { sim.manualValues[m] = $0 }), format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Text(m.unit).font(.caption2).frame(width: 60, alignment: .leading)
                        }
                    }
                }
                Divider()
            }
            HStack {
                Button { sim.sendManual() } label: { Label("Send reading now", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                Toggle("Stream every 5 s", isOn: Binding(get: { sim.manualStreaming },
                                                          set: { $0 ? sim.startManualStream() : sim.stopManualStream() }))
            }
            Text("Values go through the same validation, storage, charts, alerts, and reasoning as live data, labeled SIM. Systolic and diastolic are stored separately. Disabled parameters are reported as missing.")
                .font(.caption2).foregroundStyle(Theme.secondaryText)
            if let s = model.bio.summary(.systolicBP)?.latestValue, let d = model.bio.summary(.diastolicBP)?.latestValue {
                Text("Current simulated BP \(fmt(s))/\(fmt(d)) mmHg").font(.caption)
            }
        }
    }
}

struct SimDatasetPanel: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var shareURL: URL?

    var body: some View {
        let sim = model.sim
        let sheets = model.bio.sheets
        VStack(spacing: 12) {
            Panel(title: "CSV (offline)", systemImage: "tablecells") {
                Text("Import a CSV with a Timestamp column and any of: Heart Rate, Blood Pressure (118/78), Systolic, Diastolic, SpO2, Temperature (°C), Respiratory Rate, HRV, Glucose, Cabin Pressure (kPa). ASTRA's own biometrics export is also accepted.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                HStack {
                    Button { importing = true } label: { Label("Import CSV", systemImage: "square.and.arrow.down") }
                    Button {
                        shareURL = sim.exportSimulatedRecords(using: model.exporter)
                    } label: { Label("Export simulated records", systemImage: "square.and.arrow.up") }
                }
                .buttonStyle(.bordered)
                if let a = sim.active {
                    Button {
                        shareURL = sim.exportScenarioCSV(a)
                    } label: { Label("Export current scenario as CSV", systemImage: "doc.text") }
                    .buttonStyle(.bordered)
                }
                if let shareURL { ShareLink(item: shareURL) { Label("Share \(shareURL.lastPathComponent)", systemImage: "paperplane") } }
            }

            Panel(title: "Google Sheets (optional, needs network)", systemImage: "cloud") {
                Text("Uses the same Apps Script web app as the Data tab. Add a tab named 'scenario' with a header row (Timestamp, Heart Rate, Blood Pressure, SpO2, Temperature…). Edits in the sheet are picked up on the next sync; the last good copy is kept for offline use.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                HStack {
                    Button { Task { await sim.syncSheet(sheets) } } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.bordered)
                    Toggle("Auto-sync", isOn: Binding(get: { sim.sheetAutoSync }, set: { $0 ? sim.startSheetSync(sheets) : sim.stopSheetSync() }))
                }
                Stepper("Every \(Int(sim.sheetSyncSeconds)) s", value: Binding(get: { sim.sheetSyncSeconds }, set: { sim.sheetSyncSeconds = $0 }), in: 10...300, step: 10)
                if let s = sim.sheetStatus { Text(s).font(.caption) }
                if !sheets.isConfigured { Text("Not configured — set the URL and token on the Data tab.").font(.caption).foregroundStyle(.yellow) }
                if let gs = sim.scenarios.first(where: { $0.source == "Google Sheets" }) {
                    Button { sim.start(gs) } label: { Label("Play Google Sheets scenario", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                }
            }

            if let r = sim.lastImport {
                Panel(title: "Last import — validation report", systemImage: "checklist") {
                    Text("\(r.rowsRead) rows read · \(r.valuesAccepted) values accepted · \(r.issues.count) issue(s)").font(.callout)
                    if r.issues.isEmpty { Text("No problems found.").font(.caption).foregroundStyle(.green) }
                    BulletList(items: Array(r.issues.prefix(30)), color: .yellow)
                    if r.issues.count > 30 { Text("…and \(r.issues.count - 30) more").font(.caption2) }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            if case .success(let url) = result { sim.importCSV(url) }
        }
    }
}

struct SimAnalysisPanel: View {
    @Environment(AppModel.self) private var model
    @State private var compareKey = "heartRate"

    var body: some View {
        let sim = model.sim
        let generated = sim.generated
        VStack(spacing: 12) {
            Panel(title: "Current simulated values", systemImage: "waveform.path.ecg") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(SimKey.metrics) { m in
                        HStack {
                            Text(m.shortLabel).font(.caption).foregroundStyle(Theme.secondaryText)
                            Spacer()
                            if let v = model.bio.summary(m)?.latestValue {
                                Text("\(fmt(v, m.digits)) \(m.unit)").font(.callout.monospacedDigit())
                            } else {
                                Text("missing").font(.caption).foregroundStyle(.yellow)
                            }
                        }
                    }
                }
                HStack {
                    Text("Status: \(model.evaluation.tier.label)").font(.callout.weight(.bold)).foregroundStyle(model.evaluation.tier.color)
                    Spacer()
                    Text("Source: \(model.dataSourceLabel)").font(.caption2).foregroundStyle(.pink).lineLimit(2)
                }
            }

            Panel(title: "All variables — one timeline (simulated minutes)", systemImage: "chart.xyaxis.line") {
                if generated.isEmpty {
                    MissingDataView(text: "Start a scenario to see its output.")
                } else {
                    ForEach(groupedKeys(), id: \.self) { group in
                        Chart {
                            ForEach(generated.filter { group.contains($0.key) }, id: \.self) { g in
                                LineMark(x: .value("Minute", g.minute), y: .value("Value", g.value), series: .value("Parameter", SimKey.label(g.key)))
                                    .foregroundStyle(by: .value("Parameter", SimKey.label(g.key)))
                            }
                            RuleMark(x: .value("Now", sim.simMinute)).foregroundStyle(.gray.opacity(0.5))
                        }
                        .chartXScale(domain: 0...max(sim.active?.durationMinutes ?? 1, 1))
                        .frame(height: 120)
                    }
                    Text("Gaps mark simulated sensor dropouts (no values invented).").font(.caption2).foregroundStyle(Theme.secondaryText)
                }
            }

            Panel(title: "Expected (scenario) vs actual (engine output)", systemImage: "square.split.2x1") {
                Picker("Parameter", selection: $compareKey) {
                    ForEach(sim.active?.keysUsed ?? SimKey.all, id: \.self) { Text(SimKey.label($0)).tag($0) }
                }
                if let a = sim.active {
                    let expected = stride(from: 0.0, through: a.durationMinutes, by: max(a.durationMinutes / 120, 0.05)).compactMap { m in
                        a.value(compareKey, at: m).map { (m, $0) }
                    }
                    let actual = generated.filter { $0.key == compareKey }
                    Chart {
                        ForEach(Array(expected.enumerated()), id: \.offset) { _, e in
                            LineMark(x: .value("Minute", e.0), y: .value("Value", e.1), series: .value("Series", "Expected"))
                                .foregroundStyle(.gray)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                        ForEach(actual, id: \.self) { g in
                            PointMark(x: .value("Minute", g.minute), y: .value("Value", g.value)).foregroundStyle(.pink).symbolSize(20)
                        }
                    }
                    .frame(height: 150)
                    Text("Dashed = scenario definition; dots = measurements the engine delivered into the pipeline.").font(.caption2).foregroundStyle(Theme.secondaryText)
                }
            }

            Panel(title: "Detected changes", systemImage: "bell.badge") {
                if model.evaluation.reasons.isEmpty && model.evaluation.dataNotes.isEmpty {
                    Text("No abnormal findings.").font(.callout).foregroundStyle(Theme.secondaryText)
                }
                ForEach(model.evaluation.reasons) { r in Text("[\(r.tier.label)] \(r.title): \(r.detail)").font(.caption) }
                BulletList(items: model.evaluation.dataNotes, color: .yellow)
            }

            Panel(title: "AI / reasoning assessment history (simulation)", systemImage: "cross.case") {
                let reports = model.engine.history.filter { $0.dataSource?.hasPrefix("Simulation") == true }.suffix(8).reversed()
                if reports.isEmpty { Text("Assessments run automatically every 20 s while a simulation is active.").font(.callout).foregroundStyle(Theme.secondaryText) }
                ForEach(Array(reports)) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            UrgencyBadge(urgency: r.urgency)
                            Badge(text: r.aiUsed ? "AI + PROTOCOL" : "PROTOCOL", color: r.aiUsed ? .pink : .blue)
                            Spacer()
                            Text(r.createdAt.formatted(date: .omitted, time: .standard)).font(.caption2)
                        }
                        Text(r.summary).font(.caption)
                        if let input = r.inputSnapshot { Text("Input: \(input)").font(.caption2).foregroundStyle(Theme.secondaryText) }
                    }
                    Divider()
                }
            }

            Panel(title: "Missing / invalid measurements", systemImage: "exclamationmark.triangle") {
                let issues = model.bio.issues.prefix(20)
                if issues.isEmpty { Text("No rejected or flagged values.").font(.callout).foregroundStyle(Theme.secondaryText) }
                ForEach(Array(issues)) { i in
                    Text("\(i.rejected ? "Rejected" : "Flagged"): \(i.metric) \(fmt(i.value, 1)) \(i.unit) (\(i.source)) — \(i.reason)")
                        .font(.caption).foregroundStyle(i.rejected ? .red : .yellow)
                }
                BulletList(items: Array(sim.log.filter { $0.contains("dropout") || $0.contains("reconnected") }.prefix(6)), color: .yellow)
            }

            Panel(title: "Simulation log", systemImage: "text.alignleft") {
                BulletList(items: Array(sim.log.prefix(15)))
            }
        }
    }

    private func groupedKeys() -> [[String]] {
        let used = Set(model.sim.generated.map(\.key))
        let groups: [[String]] = [["heartRate", "respiratoryRate", "hrv"], ["systolicBP", "diastolicBP"], ["spo2", "oxygenFraction"],
                                  ["bodyTemperature"], ["bloodGlucose"], ["cabinPressure"]]
        return groups.map { $0.filter(used.contains) }.filter { !$0.isEmpty }
    }
}

struct ScenarioEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SimScenario

    init(scenario: SimScenario) {
        var s = scenario
        if s.isBuiltIn {
            s.id = UUID()
            s.name += " (copy)"
            s.isBuiltIn = false
            s.source = "Custom"
        }
        _draft = State(initialValue: s)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Scenario") {
                    TextField("Name", text: $draft.name)
                    TextField("Description", text: $draft.summary, axis: .vertical)
                    TextField("Context sent to the assistant (optional)", text: $draft.context, axis: .vertical)
                    TextField("Expected system behavior", text: $draft.expectedBehavior, axis: .vertical)
                    Stepper("Duration \(Int(draft.durationMinutes)) min", value: $draft.durationMinutes, in: 1...720, step: 1)
                    Picker("Sample every", selection: $draft.sampleSeconds) {
                        ForEach([10.0, 30, 60, 120, 300], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    Toggle("Interpolate between keyframes", isOn: $draft.interpolate)
                    Picker("Environment preset", selection: Binding(get: { draft.environmentPreset ?? "" }, set: { draft.environmentPreset = $0.isEmpty ? nil : $0 })) {
                        Text("Keep current").tag("")
                        ForEach(MissionPreset.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
                Section("Timeline (keyframes)") {
                    ForEach($draft.keyframes) { $kf in
                        DisclosureGroup("T+\(fmt(kf.minute, 1)) min\(kf.dropout ? " · sensor dropout" : "")") {
                            Stepper("Minute \(fmt(kf.minute, 1))", value: $kf.minute, in: 0...draft.durationMinutes, step: 0.5)
                            Toggle("Sensors disconnected from here", isOn: $kf.dropout)
                            ForEach(SimKey.all, id: \.self) { key in
                                HStack {
                                    Text(SimKey.label(key)).font(.caption)
                                    Spacer()
                                    TextField("missing", value: Binding(get: { kf.values[key] }, set: { kf.values[key] = $0 }), format: .number)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 90)
                                }
                            }
                            TextField("Note", text: $kf.note)
                        }
                    }
                    .onDelete { draft.keyframes.remove(atOffsets: $0) }
                    Button("Add keyframe") {
                        let last = draft.sortedFrames.last
                        draft.keyframes.append(ScenarioKeyframe(minute: min((last?.minute ?? 0) + 5, draft.durationMinutes), values: last?.values ?? [:]))
                    }
                }
                Section {
                    Button("Save scenario") {
                        draft.keyframes.sort { $0.minute < $1.minute }
                        model.sim.save(draft)
                        dismiss()
                    }
                    Button("Save and play") {
                        draft.keyframes.sort { $0.minute < $1.minute }
                        model.sim.save(draft)
                        model.sim.start(draft)
                        dismiss()
                    }
                    if !draft.isBuiltIn, model.sim.scenarios.contains(where: { $0.id == draft.id }) {
                        Button("Delete scenario", role: .destructive) {
                            model.sim.delete(draft)
                            dismiss()
                        }
                    }
                } footer: {
                    Text("Empty fields are missing values (nothing is generated for them). Templates are copied before editing.")
                }
            }
            .navigationTitle("Scenario editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
