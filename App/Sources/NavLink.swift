import CoreBluetooth
import CallKit
import Foundation
import UIKit
import VelaCore

/** Sends the current navigation cue to a nearby MiniNav display over BLE. */
final class NavLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, CXCallObserverDelegate {
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
    private let callObserver = CXCallObserver()
    private var callStatus = "none"
    private var latestCue: [String: Any] = ["v": 1, "active": false, "call": "none"]

    private var cueRouteID: UUID?
    private var routeDistances: [Double] = []
    private var cueEnd = 0.0
    private var lastAlong = 0.0
    private var cueVertices: [Double] = []

    // Keep the bends of one road section until the rider reaches its end.
    private func roadCue(route: Route, along measured: Double, nextTurn: Double?) -> String {
        let road = route.polyline
        if cueRouteID != route.id {
            cueRouteID = route.id
            routeDistances = Geo.cumulative(road)
            cueVertices = []
        }
        guard let total = routeDistances.last, total > 0, measured.isFinite else { return "" }
        let reset = cueVertices.isEmpty || measured < lastAlong - 25
        let along = min(total, max(0, reset ? measured : max(lastAlong, measured)))
        lastAlong = along
        func point(_ m: Double) -> LatLng {
            Geo.point(along: road, meters: m, cumulative: routeDistances)
        }
        if reset || along >= cueEnd {
            let target = nextTurn.flatMap { $0 > along ? $0 + 25 : nil } ?? total
            cueEnd = min(total, min(along + 240, target))
            // Preserve actual corner vertices. Spend each available BLE point on
            // the largest remaining deviation from a straight segment.
            var anchors = [along, cueEnd]
            let vertices = routeDistances.filter { $0 > along && $0 < cueEnd }
            let longitudeScale = cos(point(along).lat * .pi / 180)
            while anchors.count < 8 {
                var largest = 0.000012
                var best: Double?
                for (start, end) in zip(anchors, anchors.dropFirst()) {
                    let a = point(start), b = point(end)
                    let dx = (b.lng - a.lng) * longitudeScale, dy = b.lat - a.lat
                    for m in vertices where m > start && m < end {
                        let v = point(m)
                        let x = (v.lng - a.lng) * longitudeScale, y = v.lat - a.lat
                        let t = min(1, max(0, (x * dx + y * dy) / max(1e-18, dx * dx + dy * dy)))
                        let error = hypot(x - t * dx, y - t * dy)
                        if error > largest { largest = error; best = m }
                    }
                }
                guard let best else { break }
                anchors.append(best)
                anchors.sort()
            }
            cueVertices = anchors
        }
        let origin = point(along)
        let heading = Geo.bearing(point(max(0, along - 5)), point(min(total, along + 12))) * .pi / 180
        var encoded = "80"
        var lastX = 8.0, lastY = 0.0
        for m in cueVertices where m > along {
            let v = point(m)
            let east = (v.lng - origin.lng) * cos(origin.lat * .pi / 180) * 111320
            let north = (v.lat - origin.lat) * 110540
            let x = 8 + (east * cos(heading) - north * sin(heading)) / 20
            let y = (east * sin(heading) + north * cos(heading)) / 10
            // End the visible road at the first viewport crossing, so an
            // off-screen bend cannot turn into a false line along the edge.
            var t = 1.0
            if x < 0 { t = min(t, -lastX / (x - lastX)) }
            if x > 15 { t = min(t, (15 - lastX) / (x - lastX)) }
            if y < 0 { t = min(t, -lastY / (y - lastY)) }
            if y > 15 { t = min(t, (15 - lastY) / (y - lastY)) }
            encoded += String(format: "%1X%1X", Int((lastX + t * (x - lastX)).rounded()),
                              Int((lastY + t * (y - lastY)).rounded()))
            if t < 1 { break }
            lastX = x; lastY = y
        }
        return encoded.count == 2 ? encoded + "80" : encoded
    }

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "app.kite.navlink"])
        callObserver.setDelegate(self, queue: .main)
    }

    private func currentCallStatus() -> String {
        let activeCalls = callObserver.calls.filter { !$0.hasEnded }
        if activeCalls.contains(where: { !$0.isOutgoing && !$0.hasConnected }) { return "incoming" }
        if activeCalls.contains(where: { $0.hasConnected }) { return "active" }
        return "none"
    }

    private func refreshCallStatus() {
        let next = currentCallStatus()
        guard next != callStatus else { return }
        callStatus = next
        guard navigationActive else { return }
        latestCue["call"] = next
        send(latestCue)
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        refreshCallStatus()
    }

    @MainActor
    func update(_ navigator: Navigator?) {
        guard let navigator else {
            cueVertices = []
            navigationActive = false
            latestCue = ["v": 1, "active": false, "call": callStatus]
            send(latestCue)
            central.stopScan()
            return
        }
        navigationActive = true
        callStatus = currentCallStatus()

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
            routeLine = roadCue(route: navigator.route, along: progress.alongMeters,
                                nextTurn: maneuver?.alongMeters)
        } else {
            routeLine = ""
        }
        let phone = UIDevice.current
        phone.isBatteryMonitoringEnabled = true
        let level = phone.batteryLevel
        var gpsBars = 0
        if let fix = navigator.lastFix, abs(fix.timestamp.timeIntervalSinceNow) < 15,
           fix.horizontalAccuracy >= 0 {
            switch fix.horizontalAccuracy {
            case ...8: gpsBars = 4
            case ...20: gpsBars = 3
            case ...50: gpsBars = 2
            default: gpsBars = 1
            }
        }
        let message: [String: Any] = [
            "bat": level >= 0 ? Int((level * 100).rounded()) + 1 : 0,
            "chg": phone.batteryState == .charging || phone.batteryState == .full,
            "gps": gpsBars,
            "v": 1,
            "active": true,
            "call": callStatus,
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
        latestCue = message
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
