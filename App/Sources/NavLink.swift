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
        let message: [String: Any] = [
            "v": 1,
            "active": true,
            "turn": maneuver?.type.rawValue ?? "straight",
            "instruction": navigator.arrived ? "Arrived" : String((maneuver?.instruction ?? "Continue").prefix(72)),
            "road": String((maneuver?.road ?? "").prefix(40)),
            "distance_m": max(0, Int(distance.rounded())),
            "remaining_m": max(0, Int((navigator.progress?.remainingMeters ?? navigator.route.distanceMeters).rounded())),
            "eta_s": max(0, Int(left.rounded())),
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
