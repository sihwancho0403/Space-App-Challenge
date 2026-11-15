// ASTRAWatchApp.swift — ASTRA Watch companion (Part B). Add this ONLY to the watchOS app target, not the iPhone target.
//
// Setup in Xcode:
//   File ▸ New ▸ Target ▸ watchOS ▸ App ▸ "Watch App for Existing iOS App" ▸ name "ASTRA Watch", companion: MyApp
//   Replace the generated Watch App files' content with this file (delete the generated ContentView and App files of the watch target).
//   Watch target ▸ Signing & Capabilities: same Personal Team, + HealthKit, + Background Modes ▸ ☑ Workout processing
//   Watch target ▸ Info: Privacy - Health Share Usage Description, Privacy - Health Update Usage Description
//
// What it does: runs a workout session so the Watch measures heart rate every few seconds, checks thresholds on the
// Watch itself (haptic + on-screen alert, works with the iPhone out of range), and forwards samples to the iPhone app,
// where WatchLinkReceiver feeds them into the same ASTRA pipeline (charts, RiskEngine, reasoning, export).

import SwiftUI
import HealthKit
import WatchConnectivity
import WatchKit

@main
struct ASTRAWatchApp: App {
    @State private var monitor = WatchMonitor()

    var body: some Scene {
        WindowGroup {
            WatchMonitorView()
                .environment(monitor)
        }
    }
}

@MainActor
@Observable
final class WatchMonitor: NSObject {
    var heartRate: Double?
    var lastUpdate: Date?
    var running = false
    var alert: String?
    var message: String?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var pending: [[String: Any]] = []
    private var lastSend = Date.distantPast
    private var lastHaptic = Date.distantPast

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    var linkText: String {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return "iPhone link inactive" }
        return WCSession.default.isReachable ? "iPhone connected" : "iPhone not reachable — data queued"
    }

    func start() async {
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate), HKQuantityType(.oxygenSaturation)]
        do {
            try await store.requestAuthorization(toShare: [HKQuantityType.workoutType()], read: read)
            let config = HKWorkoutConfiguration()
            config.activityType = .other
            config.locationType = .indoor
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            b.delegate = self
            session = s
            builder = b
            s.startActivity(with: Date())
            try await b.beginCollection(at: Date())
            running = true
            message = nil
        } catch {
            message = "Could not start monitoring: \(error.localizedDescription)"
        }
    }

    func stop() async {
        session?.end()
        try? await builder?.endCollection(at: Date())
        _ = try? await builder?.finishWorkout()
        flush()
        running = false
    }

    fileprivate func received(heartRate bpm: Double, at date: Date) {
        heartRate = bpm
        lastUpdate = date
        // Same default thresholds as the iPhone RiskEngine (Urgent: ≥150 or <40 bpm; Caution: ≥120 or <45 bpm).
        if bpm >= 150 || bpm < 40 {
            alert = "URGENT — heart rate \(Int(bpm)) bpm"
        } else if bpm >= 120 || bpm < 45 {
            alert = "CAUTION — heart rate \(Int(bpm)) bpm"
        } else {
            alert = nil
        }
        if alert != nil, Date().timeIntervalSince(lastHaptic) > 30 {
            WKInterfaceDevice.current().play(.notification)
            lastHaptic = Date()
        }
        pending.append(["metric": "heartRate", "value": bpm, "time": date.timeIntervalSince1970, "id": UUID().uuidString])
        if Date().timeIntervalSince(lastSend) >= 5 { flush() }
    }

    private func flush() {
        guard !pending.isEmpty, WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let payload: [String: Any] = ["samples": pending]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            WCSession.default.transferUserInfo(payload)   // delivered later, in order
        }
        pending.removeAll()
        lastSend = Date()
    }
}

extension WatchMonitor: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType),
              let quantity = workoutBuilder.statistics(for: hrType)?.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        Task { @MainActor in self.received(heartRate: bpm, at: Date()) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

extension WatchMonitor: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
}

struct WatchMonitorView: View {
    @Environment(WatchMonitor.self) private var monitor

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("ASTRA").font(.headline).tracking(2)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Image(systemName: "heart.fill").foregroundStyle(.red)
                    Text(monitor.heartRate.map { "\(Int($0))" } ?? "--").font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("bpm").font(.caption2)
                }
                if let a = monitor.alert {
                    Text(a).font(.caption.weight(.bold)).foregroundStyle(a.hasPrefix("URGENT") ? .red : .yellow)
                        .multilineTextAlignment(.center)
                }
                if let t = monitor.lastUpdate {
                    Text(t.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                }
                Button(monitor.running ? "Stop monitoring" : "Start monitoring") {
                    Task { monitor.running ? await monitor.stop() : await monitor.start() }
                }
                .tint(monitor.running ? .red : .green)
                Text(monitor.linkText).font(.caption2).foregroundStyle(.secondary)
                if let m = monitor.message { Text(m).font(.caption2).foregroundStyle(.orange) }
            }
        }
    }
}
