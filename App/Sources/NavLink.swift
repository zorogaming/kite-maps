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
    private var writeFrames: [Data] = []
    private var writeFrameIndex = 0
    private var writeInProgress = false
    private var currentWriteData: Data?
    private var queuedWrite: Data?
    private var writeSequence: UInt8 = 0

    private var cueRouteID: UUID?
    private var routeDistances: [Double] = []
    private var cueEnd = 0.0
    private var lastAlong = 0.0
    private var cueAnchors: [Double] = []
    private var cueCoordinates: [(Int, Int)] = []
    private var cuePath = ""

    private func routeCue(route: Route, along measured: Double, nextTurn: Double?) -> (path: String, cursor: String, segment: Int) {
        if cueRouteID != route.id {
            cueRouteID = route.id
            routeDistances = Geo.cumulative(route.polyline)
            cueAnchors = []
        }
        guard let total = routeDistances.last, total > 0, measured.isFinite,
              route.polyline.count > 1 else { return ("", "", 0) }
        let reset = cueAnchors.isEmpty || measured < lastAlong - 25
        let along = min(total, max(0, reset ? measured : max(lastAlong, measured)))
        lastAlong = along
        func point(_ meters: Double) -> LatLng {
            Geo.point(along: route.polyline, meters: meters, cumulative: routeDistances)
        }
        // Freeze this short section's geometry and orientation until the rider
        // reaches its end. Only its cursor changes between GPS updates.
        if reset || (along >= cueEnd && cueEnd < total) {
            let target = nextTurn.flatMap { $0 > along ? max(along + 40, $0 + 25) : nil } ?? total
            cueEnd = min(total, min(along + 240, target))
            var anchors = [along, cueEnd]
            let vertices = routeDistances.filter { $0 > along && $0 < cueEnd }
            let origin = point(along)
            let longitudeScale = max(0.01, cos(origin.lat * .pi / 180)) * 111_320.0
            let heading = Geo.bearing(origin, point(min(total, along + 12))) * .pi / 180
            let cosine = cos(heading), sine = sin(heading)
            func projected(_ meters: Double) -> (Double, Double) {
                let p = point(meters)
                let east = (p.lng - origin.lng) * longitudeScale
                let north = (p.lat - origin.lat) * 110_540.0
                return (east * cosine - north * sine, east * sine + north * cosine)
            }
            // Spend the eight-point budget on actual bends rather than eight
            // equally spaced samples that can cut off a junction's corner.
            while anchors.count < 8 {
                var largest = 4.0
                var best: Double?
                for (start, end) in zip(anchors, anchors.dropFirst()) {
                    let a = projected(start), b = projected(end)
                    let dx = b.0 - a.0, dy = b.1 - a.1
                    for m in vertices where m > start && m < end {
                        let v = projected(m)
                        let t = min(1, max(0, ((v.0 - a.0) * dx + (v.1 - a.1) * dy) / max(1e-9, dx * dx + dy * dy)))
                        let error = pow(v.0 - a.0 - t * dx, 2) + pow(v.1 - a.1 - t * dy, 2)
                        if error > largest { largest = error; best = m }
                    }
                }
                guard let best else { break }
                anchors.append(best)
                anchors.sort()
            }
            let points = anchors.map(projected)
            let minX = points.map { $0.0 }.min() ?? 0
            let maxX = points.map { $0.0 }.max() ?? 0
            let minY = points.map { $0.1 }.min() ?? 0
            let maxY = points.map { $0.1 }.max() ?? 0
            let scale = min(165 / max(1, maxX - minX), 75 / max(1, maxY - minY))
            let padX = (165 - (maxX - minX) * scale) / 2
            let padY = (75 - (maxY - minY) * scale) / 2
            cueCoordinates = points.map { p in
                let x = min(15, max(0, Int(((p.0 - minX) * scale + padX) / 11.0 + 0.5)))
                let y = min(15, max(0, Int(((p.1 - minY) * scale + padY) / 5.0 + 0.5)))
                return (x, y)
            }
            cueAnchors = anchors
            cuePath = cueCoordinates.map { String(format: "%1X%1X", $0.0, $0.1) }.joined()
        }
        guard cueCoordinates.count >= 2 else { return ("", "", 0) }
        var i = 0
        while i + 2 < cueAnchors.count && along > cueAnchors[i + 1] { i += 1 }
        let f = min(1, max(0, (along - cueAnchors[i]) / max(0.001, cueAnchors[i + 1] - cueAnchors[i])))
        let a = cueCoordinates[i], b = cueCoordinates[i + 1]
        let x = Int(((Double(a.0) + Double(b.0 - a.0) * f) * 16).rounded())
        let y = Int(((Double(a.1) + Double(b.1 - a.1) * f) * 16).rounded())
        // A four-character cursor adds fractional precision to the same 16-char
        // path. It is interpolated on the transmitted line, never beside it.
        return (cuePath, String(format: "%02X%02X", x, y), i)
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
            cueAnchors = []
            cueCoordinates = []
            cuePath = ""
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
        let routeCue: (path: String, cursor: String, segment: Int)
        let geometry = navigator.route.polyline
        if geometry.count > 1 {
            routeCue = self.routeCue(route: navigator.route, along: navigator.progress?.alongMeters ?? 0,
                                     nextTurn: maneuver?.alongMeters)
        } else {
            routeCue = ("", "", 0)
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
        let along = navigator.progress?.alongMeters ?? 0
        func nearby(_ sorted: [Double], within meters: Double) -> Bool {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid] < along { lo = mid + 1 } else { hi = mid }
            }
            return lo < sorted.count && sorted[lo] - along <= meters
        }
        let instruction = maneuver?.instruction ?? ""
        var signs = 0
        if nearby(navigator.signalMeters, within: 150) { signs |= 1 }
        if navigator.cameraAhead?.kind == .speed { signs |= 2 }
        if nearby(navigator.stopMeters, within: 100) ||
            (distance <= 100 && instruction.localizedCaseInsensitiveContains("at the stop sign")) { signs |= 4 }
        if let report = navigator.wazeAhead, [.hazard, .accident, .roadworks, .weather, .closure].contains(report.alert.kind) { signs |= 8 }
        let roadRef = RoadRefs.find(instruction + " " + (maneuver?.road ?? "")).first ?? ""
        let destination: String
        if maneuver?.type == .arrive || navigator.arrived {
            destination = navigator.destination.name
        } else if let range = instruction.range(of: " towards ", options: [.backwards, .caseInsensitive])
                        ?? instruction.range(of: " toward ", options: [.backwards, .caseInsensitive]) {
            destination = String(instruction[range.upperBound...])
        } else {
            destination = ""
        }
        let message: [String: Any] = [
            "sg": signs,
            "ref": String(roadRef.prefix(8)),
            "dst": String(destination.prefix(16)),
            "bat": level >= 0 ? Int((level * 100).rounded()) + 1 : 0,
            "chg": phone.batteryState == .charging || phone.batteryState == .full,
            "gps": gpsBars,
            "v": 1,
            "active": true,
            "rerouting": navigator.rerouting,
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
            "rpf": 2,
            "rc": routeCue.cursor,
            "ri": routeCue.segment,
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
        let maxLength = min(120, min(peripheral.maximumWriteValueLength(for: .withResponse),
                                     peripheral.maximumWriteValueLength(for: .withoutResponse)))
        let headerLength = 8
        guard maxLength > headerLength else { return }
        // The withResponse limit can permit long writes. Also cap to the
        // withoutResponse limit (ATT MTU minus 3) and 120 bytes per frame.
        let chunkLength = min(maxLength - headerLength, 112)
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
