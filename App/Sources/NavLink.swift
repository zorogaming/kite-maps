import CoreBluetooth
import CallKit
import Foundation
import UIKit
import VelaCore

private struct RoutePoint2D {
    let x: Double
    let y: Double
}

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
    private var writeFrames: [Data] = []
    private var writeFrameIndex = 0
    private var writeInProgress = false
    private var currentWriteData: Data?
    private var queuedWrite: Data?
    private var writeSequence: UInt8 = 0

    private var cueRouteID: UUID?
    private var routeDistances: [Double] = []
    private var routeProjectionCos = 1.0
    private var routeMinX = 0.0
    private var routeMaxX = 0.0
    private var routeMinY = 0.0
    private var routeMaxY = 0.0
    private var routeCoordinates: [(Int, Int)] = []
    private var routePath = ""

    private func simplified(_ points: [RoutePoint2D], tolerance: Double) -> [RoutePoint2D] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var ranges: [(Int, Int)] = [(0, points.count - 1)]
        let toleranceSquared = tolerance * tolerance
        while let (start, end) = ranges.popLast() {
            guard end > start + 1 else { continue }
            let a = points[start], b = points[end]
            let dx = b.x - a.x, dy = b.y - a.y
            var largest = toleranceSquared
            var best: Int?
            for index in (start + 1)..<end {
                let p = points[index]
                let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) /
                                  max(1e-12, dx * dx + dy * dy)))
                let ex = p.x - (a.x + t * dx), ey = p.y - (a.y + t * dy)
                let error = ex * ex + ey * ey
                if error > largest { largest = error; best = index }
            }
            if let best {
                keep[best] = true
                ranges.append((start, best))
                ranges.append((best, end))
            }
        }
        return points.indices.compactMap { keep[$0] ? points[$0] : nil }
    }

    // Cache the whole route once. Coordinates are a compact 32x16 overview; the cursor moves on it.
    private func cacheRoute(_ route: Route) {
        cueRouteID = route.id
        routeDistances = Geo.cumulative(route.polyline)
        routeCoordinates = []
        routePath = ""
        guard route.polyline.count > 1 else { return }
        let referenceLatitude = route.polyline.map(\.lat).reduce(0, +) / Double(route.polyline.count)
        routeProjectionCos = max(0.01, cos(referenceLatitude * .pi / 180))
        let projected = route.polyline.map {
            RoutePoint2D(x: $0.lng * routeProjectionCos, y: $0.lat)
        }
        var tolerance = 0.00002
        var reduced = simplified(projected, tolerance: tolerance)
        while reduced.count > 24 {
            tolerance *= 1.7
            reduced = simplified(projected, tolerance: tolerance)
        }
        routeMinX = reduced.map(\.x).min() ?? 0
        routeMaxX = reduced.map(\.x).max() ?? 0
        routeMinY = reduced.map(\.y).min() ?? 0
        routeMaxY = reduced.map(\.y).max() ?? 0
        routeCoordinates = reduced.map(encodeRoutePoint)
        routePath = routeCoordinates.map { String(format: "%02X%1X", $0.0, $0.1) }.joined()
    }

    private func encodeRoutePoint(_ point: RoutePoint2D) -> (Int, Int) {
        let width = routeMaxX - routeMinX
        let height = routeMaxY - routeMinY
        let nx = width > 1e-10 ? (point.x - routeMinX) / width : 0.5
        let ny = height > 1e-10 ? (routeMaxY - point.y) / height : 0.5
        let x = min(30, max(1, Int((1 + nx * 29).rounded())))
        let y = min(14, max(1, Int((1 + ny * 13).rounded())))
        return (x, y)
    }

    private func routeCue(route: Route, along measured: Double) -> (path: String, cursor: String) {
        if cueRouteID != route.id { cacheRoute(route) }
        guard let total = routeDistances.last, total > 0, measured.isFinite,
              route.polyline.count > 1 else { return (routePath, "") }
        let point = Geo.point(along: route.polyline,
                              meters: min(total, max(0, measured)),
                              cumulative: routeDistances)
        let coordinate = encodeRoutePoint(RoutePoint2D(x: point.lng * routeProjectionCos, y: point.lat))
        return (routePath, String(format: "%02X%1X", coordinate.0, coordinate.1))
    }

    private func roundaboutCue(_ maneuver: Maneuver?) -> [String: Any]? {
        guard let maneuver, maneuver.type == .roundabout else { return nil }
        let shape = maneuver.roundabout
        let clockwise = shape?.clockwise ?? Geo.drivesOnLeft(maneuver.location)
        let exit = max(1, maneuver.exit ?? 1)
        var exits = shape?.exits ?? []
        if exits.isEmpty {
            let count = min(12, exit)
            let step = min(90.0, 300.0 / Double(count + 1))
            let sign = clockwise ? 1.0 : -1.0
            exits = (1...count).map { index in
                (180 + sign * Double(index) * step + 360)
                    .truncatingRemainder(dividingBy: 360)
            }
        }
        let normalized: (Double) -> Int = { angle in
            let degrees = (angle.truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360)
            return Int(degrees.rounded()) % 360
        }
        let exitList = Array(exits.prefix(12)).map(normalized)
        let entryList = Array((shape?.entriesOnly ?? []).prefix(12)).map(normalized)
        return [
            "e": exitList,
            "i": entryList,
            "t": min(max(0, shape?.taken ?? exit - 1), max(0, exitList.count - 1)),
            "c": clockwise,
            "m": shape?.mini ?? false
        ]
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
            cueRouteID = nil
            routeDistances = []
            routeCoordinates = []
            routePath = ""
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
        let routeCue: (path: String, cursor: String)
        let geometry = navigator.route.polyline
        if geometry.count > 1 {
            routeCue = self.routeCue(route: navigator.route, along: navigator.progress?.alongMeters ?? 0)
        } else {
            routeCue = ("", "")
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
            "rb": roundaboutCue(maneuver).map { $0 as Any } ?? NSNull(),
            "lc": laneCodes,
            "lm": String(laneMask, radix: 16, uppercase: true),
            "lh": String((laneGuide?.words ?? "").prefix(12)),
            "rp": routeCue.path,
            "rc": routeCue.cursor,
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
            if writeInProgress {
                queuedWrite = data
            } else {
                transmit(data, to: display, characteristic: cue)
            }
        } else if central.state == .poweredOn, display == nil {
            central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        }
    }

    private func transmit(_ data: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let maxLength = peripheral.maximumWriteValueLength(for: .withResponse)
        let headerLength = 8
        guard maxLength > headerLength else { return }
        let chunkLength = maxLength - headerLength
        let chunkCount = max(1, (data.count + chunkLength - 1) / chunkLength)
        guard chunkCount <= 255 else { return }
        writeSequence &+= 1
        writeFrames = (0..<chunkCount).map { index in
            let start = index * chunkLength
            let end = min(data.count, start + chunkLength)
            let header = Data(String(format: "~%02X%02X%02X:", writeSequence, index, chunkCount).utf8)
            var frame = header
            frame.append(data.subdata(in: start..<end))
            return frame
        }
        writeFrameIndex = 0
        writeInProgress = true
        currentWriteData = data
        peripheral.writeValue(writeFrames[0], for: characteristic, type: .withResponse)
    }

    private func writeNextFrame(on peripheral: CBPeripheral) {
        guard let cue else { return }
        writeFrameIndex += 1
        if writeFrameIndex < writeFrames.count {
            peripheral.writeValue(writeFrames[writeFrameIndex], for: cue, type: .withResponse)
            return
        }
        writeInProgress = false
        writeFrames = []
        lastSent = currentWriteData
        currentWriteData = nil
        if let queued = queuedWrite {
            queuedWrite = nil
            pending = queued
            if queued != lastSent { transmit(queued, to: peripheral, characteristic: cue) }
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
        writeFrames = []
        writeInProgress = false
        currentWriteData = nil
        if navigationActive { central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        display = nil
        cue = nil
        lastSent = nil
        writeFrames = []
        writeInProgress = false
        currentWriteData = nil
        queuedWrite = nil
        if central.state == .poweredOn, navigationActive { central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.cueUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        cue = service.characteristics?.first(where: { $0.uuid == Self.cueUUID })
        if let pending, let cue { transmit(pending, to: peripheral, characteristic: cue) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.cueUUID else { return }
        if error != nil {
            lastSent = nil
            writeFrames = []
            writeInProgress = false
            currentWriteData = nil
            if let queued = queuedWrite {
                queuedWrite = nil
                pending = queued
                if let cue { transmit(queued, to: peripheral, characteristic: cue) }
            }
            return
        }
        writeNextFrame(on: peripheral)
    }
}
