import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    Label(model.bluetooth.state.title, systemImage: statusIcon)
                    HStack {
                        Button("Scan for BS444") {
                            model.bluetooth.startScanning()
                        }
                        .buttonStyle(.borderedProminent)
                        if model.bluetooth.state == .scanning {
                            ProgressView()
                        }
                    }
                    if let selected = model.bluetooth.selectedDevice {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Selected scale")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(selected.name)
                            Text(selected.identifier)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button("Disconnect", role: .destructive) {
                            model.bluetooth.disconnect()
                        }
                    }
                }

                if !model.bluetooth.discoveredDevices.isEmpty {
                    Section("Scales") {
                        ForEach(model.bluetooth.discoveredDevices) { device in
                            Button {
                                model.bluetooth.connect(to: device)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(device.identifier)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Latest measurement") {
                    if let measurement = model.bluetooth.latestMeasurement {
                        MeasurementView(measurement: measurement)
                    } else {
                        Text("Step on the scale after connecting.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Apple Health") {
                    Label(model.healthKit.authorizationState.title, systemImage: "heart.text.square")
                    if model.healthKit.authorizationState != .authorized {
                        Button("Allow Health access") {
                            model.requestHealthKitAuthorization()
                        }
                    }
                    if let message = model.healthKitMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Raw BLE log") {
                    if model.bluetooth.logs.isEmpty {
                        Text("No BLE events yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.bluetooth.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Scale2Health")
        }
        .task {
            model.start()
        }
    }

    private var statusIcon: String {
        switch model.bluetooth.state {
        case .ready, .receiving: return "dot.radiowaves.left.and.right"
        case .failed: return "exclamationmark.triangle"
        case .scanning, .connecting, .discovering: return "antenna.radiowaves.left.and.right"
        case .idle, .unavailable: return "bolt.horizontal"
        }
    }
}

private struct MeasurementView: View {
    let measurement: BodyMeasurement

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            value("Weight", measurement.weightKg, suffix: "kg")
            if let bodyFatPercent = measurement.bodyFatPercent {
                value("Body fat", bodyFatPercent, suffix: "%")
            }
            if let bodyWaterPercent = measurement.bodyWaterPercent {
                value("Body water", bodyWaterPercent, suffix: "%")
            }
            if let musclePercent = measurement.musclePercent {
                value("Muscle", musclePercent, suffix: "%")
            }
            if let boneMassKg = measurement.boneMassKg {
                value("Bone mass", boneMassKg, suffix: "kg")
            }
            Text(measurement.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func value(_ label: String, _ value: Double, suffix: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(String(format: "%.1f %@", value, suffix))
                .monospacedDigit()
        }
    }
}
