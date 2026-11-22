import CoreBluetooth
import Foundation
import VelaCore

/** Sends the current navigation cue to a nearby MiniNav display over BLE. */
final class NavLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = NavLink()

    // Keep these UUIDs in sync with the ESP32 GATT service in MiniNav.
    static let serviceUUID = CBUUID(string: "0000A001-0000-1000-8000-00805F9B34FB")
    private static let cueUUID = CBUUID(string: "0000A002-0000-1000-8000-00805F9B34FB")

    private var central: CBCentralManager!
    private var display: CBPeripheral?
    private var cue: CBCharacteristic?
    private var pending: Data?
    private var lastSent: Data?
    private var navigationActive = false

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "app.kite.navlink"])
    }

    @MainActor
    func update(_ navigator: Navigator?) {
        guard let navigator else {
            navigationActive = false
            send(["v": 1, "active": false])
            central.stopScan()
            return
        }
        navigationActive = true

        let maneuver = navigator.nextManeuver
        let distance = navigator.progress?.distanceToNext ?? 0
        let left = navigator.progress?.remainingSeconds ?? navigator.route.durationSeconds
        let remaining = navigator.progress?.remainingMeters ?? navigator.route.distanceMeters
        let total = max(1, navigator.route.distanceMeters)
        let progressPct = min(100, max(0, Int(((total - remaining) / total * 100).rounded())))
        let laneGuide = maneuver.flatMap { LaneGuide.lanes(for: $0, leftTraffic: Geo.drivesOnLeft($0.location)) }
        let laneItems = Array((laneGuide?.lanes ?? []).prefix(10))
        let laneCodes = laneItems.map { lane -> String in
            var bits = 0
            for indication in lane.indications {
                let word = indication.lowercased()
                if word.contains("uturn") || word.contains("reverse") { bits |= 8 }
                if word.contains("left") { bits |= 1 }
                if word.contains("straight") || word.contains("through") { bits |= 2 }
                if word.contains("right") { bits |= 4 }
            }
            return String(bits, radix: 16, uppercase: true)
        }.joined()
        var laneMask = 0
        for (index, lane) in laneItems.enumerated() where lane.valid { laneMask |= 1 << index }
        let splitSide: String
        switch maneuver?.type {
        case .keepLeft, .forkLeft, .rampLeft: splitSide = "left"
        case .keepRight, .forkRight, .rampRight: splitSide = "right"
        default: splitSide = ""
        }
        let routeLine: String
        let geometry = navigator.route.polyline
        if geometry.count > 1, let progress = navigator.progress {
            let cumulative = Geo.cumulative(geometry)
            let bearing = progress.routeBearing * .pi / 180
            let cosine = cos(bearing), sine = sin(bearing)
            let latitudeScale = cos(progress.snapped.lat * .pi / 180) * 111_320.0
            routeLine = (0..<8).map { index in
                let point = Geo.point(along: geometry,
                                      meters: min(cumulative.last ?? 0, progress.alongMeters + Double(index) * 40),
                                      cumulative: cumulative)
                let east = (point.lng - progress.snapped.lng) * latitudeScale
                let north = (point.lat - progress.snapped.lat) * 110_540.0
                let right = east * cosine - north * sine
                let ahead = east * sine + north * cosine
                let x = min(15, max(0, Int(((right + 80) / 160 * 15).rounded())))
                let y = min(15, max(0, Int((ahead / 280 * 15).rounded())))
                return String(format: "%1X%1X", x, y)
            }.joined()
        } else {
            routeLine = ""
        }
        let message: [String: Any] = [
            "v": 1,
            "active": true,
             "turn": maneuver?.type.rawValue ?? "straight",
            "road": String((maneuver?.road ?? "").prefix(16)),
            "distance_m": max(0, Int(distance.rounded())),
            "remaining_m": max(0, Int(remaining.rounded())),
            "eta_s": max(0, Int(left.rounded())),
            "pr": progressPct,
            "sp": max(0, Int((navigator.speedLimitKmh ?? 0).rounded())),
            "ex": max(0, maneuver?.exit ?? 0),
            "lc": laneCodes,
            "lm": String(laneMask, radix: 16, uppercase: true),
            "lh": String((laneGuide?.words ?? "").prefix(12)),
            "rp": routeLine,
            "sd": splitSide == "left" ? "L" : (splitSide == "right" ? "R" : ""),
            "arrived": navigator.arrived
        ]
        send(message)
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        pending = data
        guard central.state == .poweredOn else { return }
        if let display, let cue {
            guard data != lastSent else { return }
            display.writeValue(data, for: cue, type: .withResponse)
            lastSent = data
        } else if central.state == .poweredOn, display == nil {
            central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn, navigationActive else { return }
        if navigationActive { central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first, navigationActive {
            display = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard display == nil else { return }
        display = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        display = nil
        cue = nil
        if navigationActive { central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        display = nil
        cue = nil
        lastSent = nil
        if central.state == .poweredOn, navigationActive { central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.cueUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        cue = service.characteristics?.first(where: { $0.uuid == Self.cueUUID })
        if let pending, let cue { peripheral.writeValue(pending, for: cue, type: .withResponse); lastSent = pending }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil { lastSent = nil }
    }
}
