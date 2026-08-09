//
//  BLEAdapter.swift
//  arvos
//
//  Bluetooth Low Energy adapter for streaming sensor data
//

import Foundation
import CoreBluetooth

final class BLEAdapter: NSObject, StreamingProtocol {
    weak var delegate: StreamingProtocolDelegate?
    
    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if oldValue != state {
                delegate?.streamingProtocol(self, didChangeState: state)
            }
        }
    }
    
    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var targetDeviceName: String?
    
    private let serviceUUID = CBUUID(string: "5B6A38A0-2A0E-4A5F-8C96-5ED26F1935B8")
    private let characteristicUUID = CBUUID(string: "3E2E3101-0BC0-4B53-9CF0-9E9981F357F1")
    
    private var bytesSent: Int64 = 0
    private var messagesSent: Int64 = 0
    private var queuedMessages: Int = 0
    private var reconnectAttempts: Int = 0
    
    var protocolName: String { "Bluetooth LE" }
    
    override init() {
        super.init()
    }
    
    func connect(config: ConnectionConfig) async throws {
        state = .connecting
        targetDeviceName = config.deviceName
        
        centralManager = CBCentralManager(delegate: self, queue: nil)
        
        // Wait for Bluetooth to be ready
        while centralManager?.state == .unknown {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        if centralManager?.state != .poweredOn {
            state = .error
            throw StreamingProtocolError.connectionFailed("Bluetooth not available")
        }
        
        // Start scanning - if deviceName is specified, scan for all peripherals and filter by name
        // Otherwise, scan for peripherals with the specific service UUID
        if targetDeviceName != nil {
            centralManager?.scanForPeripherals(withServices: nil, options: nil)
        } else {
            centralManager?.scanForPeripherals(withServices: [serviceUUID], options: nil)
        }
    }
    
    func disconnect() {
        if let peripheral = peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        centralManager?.stopScan()
        peripheral = nil
        targetDeviceName = nil
        state = .disconnected
    }
    
    func send<T: Encodable>(json object: T) throws {
        guard state == .connected, peripheral != nil else {
            throw StreamingProtocolError.notConnected
        }

        let data = try JSONEncoder().encode(object)
        try send(data: data)
    }
    
    func send(data: Data) throws {
        guard state == .connected, let peripheral = peripheral else {
            throw StreamingProtocolError.notConnected
        }
        
        // BLE has MTU limits, so we need to chunk the data
        // For now, we'll just send if it fits
        if let characteristic = findCharacteristic(for: peripheral) {
            let chunkSize = 20 // BLE default MTU - 3 bytes overhead
            var offset = 0
            
            while offset < data.count {
                let endIndex = min(offset + chunkSize, data.count)
                let chunk = data.subdata(in: offset..<endIndex)
                peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
                offset = endIndex
            }
            
            bytesSent += Int64(data.count)
            messagesSent += 1
        }
    }
    
    func getStatistics() -> StreamingProtocolStatistics {
        return StreamingProtocolStatistics(
            state: state,
            bytesSent: bytesSent,
            messagesSent: messagesSent,
            queuedMessages: queuedMessages,
            reconnectAttempts: reconnectAttempts,
            protocolName: protocolName
        )
    }
    
    func resetStatistics() {
        bytesSent = 0
        messagesSent = 0
        queuedMessages = 0
        reconnectAttempts = 0
    }
    
    static func isAvailable() -> Bool {
        return true
    }
    
    private func findCharacteristic(for peripheral: CBPeripheral) -> CBCharacteristic? {
        return peripheral.services?.first?.characteristics?.first(where: { $0.uuid == characteristicUUID })
    }
}

extension BLEAdapter: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            state = .error
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // If deviceName is specified, filter by name
        if let targetName = targetDeviceName {
            let peripheralName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            if peripheralName?.lowercased() != targetName.lowercased() {
                // Not the target device, continue scanning
                return
            }
        }
        
        // Found matching peripheral
        self.peripheral = peripheral
        central.stopScan()
        central.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .error
        if let error = error {
            delegate?.streamingProtocol(self, didEncounterError: error)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .disconnected
        if let error = error {
            delegate?.streamingProtocol(self, didEncounterError: error)
        }
    }
}

extension BLEAdapter: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) {
            peripheral.setNotifyValue(true, for: characteristic)
            state = .connected
        }
    }
}

