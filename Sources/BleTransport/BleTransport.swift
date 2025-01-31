//
//  BleTransport.swift
//  BleTransport
//
//  Created by Dante Puglisi on 5/11/22.
//

import Foundation
import CoreBluetooth


extension BleTransport: BleModuleDelegate {
    func disconnected(from peripheral: PeripheralIdentifier) {
        clearConnection()
    }
    
    func bluetoothAvailable(_ available: Bool) {
        bluetoothAvailabilityCompletion?(available)
        if !available {
            clearConnection()
        }
    }
    
    func bluetoothState(_ state: CBManagerState) {
        bluetoothStateCompletion?(state)
    }
}

@objc public class BleTransport: NSObject, BleTransportProtocol {
    
    typealias ConnectFunction = (PeripheralIdentifier) -> ()
    
    public static var shared: BleTransportProtocol = BleTransport(configuration: nil, debugMode: false)
    
    private let bleModule: BleModule
    
    private let debugMode: Bool
    
    private let configuration: BleTransportConfiguration
    private var disconnectedCallback: EmptyResponse? /// Once `disconnectCallback` is set it never becomes `nil` again so we can reuse it in methods where we reconnect to the peripheral blindly like `openApp/closeApp`
    private var connectFailure: ((BleTransportError)->())?
    
    private var scanDuration: TimeInterval = 5.0 /// `scanDuration` will be overriden every time a value gets passed to `scan/create`
    
    private var peripheralsServicesTuple = [PeripheralInfo]()
    private var connectedPeripheral: PeripheralIdentifier?
    private var bluetoothAvailabilityCompletion: ((Bool)->())?
    private var bluetoothStateCompletion: ((CBManagerState)->())?
    private var notifyDisconnectedCompletion: EmptyResponse?
    
    /// Exchange handling
    private var exchangeCallback: ((Result<String, BleTransportError>) -> Void)?
    private var isExchanging = false {
        didSet {
            if !isExchanging, let waitingToDisconnectCompletion = waitingToDisconnectCompletion {
                disconnect(completion: waitingToDisconnectCompletion)
            }
        }
    }
    private var currentResponse = ""
    private var currentResponseRemainingLength = 0
    private var waitingToDisconnectCompletion: OptionalBleErrorResponse?
    
    /// Infer MTU
    private var mtuWaitingForCallback: PeripheralResponse?
    
    @objc
    public var isBluetoothAvailable: Bool {
        bleModule.isBluetoothAvailable
    }
    
    @objc
    public var isConnected: Bool {
        connectedPeripheral != nil
    }
    
    // MARK: - Initialization
    
    public init(configuration: BleTransportConfiguration?, debugMode: Bool) {
        self.bleModule = BleModule()
        self.configuration = configuration ?? BleTransportConfiguration.defaultConfig()
        self.debugMode = debugMode
        
        super.init()
    }

	public func start() {
		bleModule.start(delegate: self)
	}

    // MARK: - Public Methods
    
    public func scan(duration: TimeInterval, callback: @escaping PeripheralsWithServicesResponse, stopped: @escaping OptionalBleErrorResponse) {
        DispatchQueue.main.async {
            self.peripheralsServicesTuple = [] /// We clean `peripheralsServicesTuple` at the start of each scan so the changes can be properly propagated and not before because it has info needed for connecting and writing to peripherals
            
            self.bleModule.scan(duration: duration, serviceIdentifiers: self.configuration.services.map({ $0.service }), discovery: { [weak self] discovery, discoveries in
                guard let self = self else { return .continue }
                if self.updatePeripheralsServicesTuple(discoveries: discoveries) {
                    callback(self.peripheralsServicesTuple)
                }
                return .continue
            }, expired: { [weak self] discovery, discoveries in
                guard let self = self else { return .continue }
                if self.updatePeripheralsServicesTuple(discoveries: discoveries) {
                    callback(self.peripheralsServicesTuple)
                }
                return .continue
            }, stopped: { [weak self] discoveries, error, timedOut in
                guard let self = self else { return }
                self.updatePeripheralsServicesTuple(discoveries: discoveries)
                if let error = error {
                    print("Stopped scanning with error: \(error)")
                    stopped(.scanError(description: error.localizedDescription))
                } else if timedOut {
                    stopped(.scanningTimedOut)
                } else {
                    stopped(nil)
                }
            })
        }
    }
    
    @objc
    public func stopScanning() {
        DispatchQueue.main.async {
            self.bleModule.stopScanning()
        }
    }
    
    public func create(scanDuration: TimeInterval, disconnectedCallback: EmptyResponse?, success: @escaping PeripheralResponse, failure: @escaping BleErrorResponse) {
        
        guard isBluetoothAvailable else { failure(.bluetoothNotAvailable); return }
        
        self.scanDuration = scanDuration
        
        var connecting = false
        
        func attemptConnecting(peripheralInfo: PeripheralInfo) {
            connect(toPeripheralID: peripheralInfo.peripheral, disconnectedCallback: disconnectedCallback, success: { connectedPeripheral in
                success(connectedPeripheral)
            }, failure: failure)
        }
        
        self.scan(duration: scanDuration) { discoveries in
            guard let firstDiscovery = discoveries.first else { return }
            if !connecting {
                connecting = true
                attemptConnecting(peripheralInfo: firstDiscovery)
            }
        } stopped: { error in
            if let error = error {
                failure(error)
            }
        }
    }
    
    public func exchange(apdu apduToSend: APDU, callback: @escaping (Result<String, BleTransportError>) -> Void) {
        DispatchQueue.main.async {
            guard !self.isExchanging else {
                callback(.failure(.pendingActionOnDevice))
                return
            }
            
            print("Sending", "->", apduToSend.data.hexEncodedString())
            self.exchangeCallback = callback
            self.isExchanging = true
            self.writeAPDU(apduToSend)
        }
    }
    
    public func send(apdu: APDU, success: @escaping EmptyResponse, failure: @escaping BleErrorResponse) {
        DispatchQueue.main.async {
            self.send(value: apdu, success: success, failure: failure)
        }
    }
    
    /// The inner implementation of `send`
    /// - Parameters:
    ///   - value: APDU to send
    ///   - retryWithResponse: Used internally in the function if `writeWithoutResponse` fails the first time
    ///   - success: The success callback
    ///   - failure: The failue callback
    fileprivate func send<S: Sendable>(value: S, retryWithResponse: Bool = false, success: @escaping EmptyResponse, failure: @escaping BleErrorResponse) {
        let connectedPeripheral: PeripheralIdentifier
        let connectedPeripheralTuple: PeripheralInfo
        let peripheralService: BleService
        let currentConnectedTuple = currentConnectedTuple()
        switch currentConnectedTuple {
        case .success(let tuple):
            (connectedPeripheral, connectedPeripheralTuple, peripheralService) = tuple
        case .failure(let error):
            failure(error)
            return
        }
        let writeCharacteristic: CharacteristicIdentifier
        let type: CBCharacteristicWriteType
        if let canWriteWithoutCharacteristic = connectedPeripheralTuple.canWriteWithoutResponse {
            writeCharacteristic = peripheralService.writeCharacteristic(canWriteWithoutResponse: canWriteWithoutCharacteristic)
            type = canWriteWithoutCharacteristic ? .withoutResponse : .withResponse
        } else {
            writeCharacteristic = retryWithResponse ? peripheralService.writeWithResponse : peripheralService.writeWithoutResponse
            type = retryWithResponse ? .withResponse : .withoutResponse
        }
        self.bleModule.write(to: writeCharacteristic, value: value, type: type) { [weak self] result in
            guard let self = self else { failure(.writeError(description: "Self got deallocated")); return }
            switch result {
            case .success:
                if connectedPeripheralTuple.canWriteWithoutResponse == nil {
                    if let tupleIndex = self.peripheralsServicesTuple.firstIndex(where: { $0.peripheral.uuid == connectedPeripheral.uuid }) {
                        self.peripheralsServicesTuple[tupleIndex].canWriteWithoutResponse = type == .withoutResponse
                    }
                }
                success()
            case .failure(let error):
                if connectedPeripheralTuple.canWriteWithoutResponse == nil {
                    self.send(value: value, retryWithResponse: true, success: success, failure: failure)
                } else {
                    print(error.localizedDescription)
                    failure(.writeError(description: error.localizedDescription))
                }
            }
        }
    }
    
    public func disconnect(completion: OptionalBleErrorResponse?) {
        guard isConnected else { completion?(nil); return }
        guard !isExchanging else { self.waitingToDisconnectCompletion = completion; return }
        self.bleModule.disconnect { [weak self] result in
            switch result {
            case .disconnected(_):
                self?.connectedPeripheral = nil
                completion?(nil)
                self?.waitingToDisconnectCompletion = nil
            case .failure(let error):
                completion?(.lowerLevelError(description: error.localizedDescription))
                self?.waitingToDisconnectCompletion = nil
            }
        }
    }
    
    public func connect(toPeripheralID peripheral: PeripheralIdentifier, disconnectedCallback: EmptyResponse?, success: @escaping PeripheralResponse, failure: @escaping BleErrorResponse) {
        
        guard !isConnected else { failure(.connectError(description: "Already connected to a peripheral")); return }
        guard isBluetoothAvailable else { failure(.bluetoothNotAvailable); return }
        
        self.stopScanning()
        
        self.disconnectedCallback = disconnectedCallback
        
        let connect = createConnectFunction(success: success, failure: failure)
        
        if let p = peripheralsServicesTuple.first(where: { $0.peripheral == peripheral }) {
            connect(p.peripheral)
        } else {
            scanAndDiscoverBeforeConnecting(lookingFor: peripheral, connectFunction: connect, failure: failure)
        }
    }
    
    public func connect(toPeripheralNamed name: String, disconnectedCallback: EmptyResponse?, success: @escaping PeripheralResponse, failure: @escaping BleErrorResponse) {
        
        guard !isConnected else { failure(.connectError(description: "Already connected to a peripheral")); return }
        guard isBluetoothAvailable else { failure(.bluetoothNotAvailable); return }
        
        self.stopScanning()
        
        self.disconnectedCallback = disconnectedCallback
        
        let connect = createConnectFunction(success: success, failure: failure)
        
        if let p = peripheralsServicesTuple.first(where: { $0.peripheral.name == name }) {
            connect(p.peripheral)
        } else {
            scanAndDiscoverBeforeConnecting(lookingFor: name, connectFunction: connect, failure: failure)
        }
    }
        
    public func bluetoothAvailabilityCallback(completion: @escaping ((Bool)->())) {
        completion(isBluetoothAvailable)
        bluetoothAvailabilityCompletion = completion
    }
    
    public func bluetoothStateCallback(completion: @escaping ((CBManagerState)->())) {
        completion(self.bleModule.bluetoothState)
        bluetoothStateCompletion = completion
    }
    
    public func notifyDisconnected(completion: @escaping EmptyResponse) {
        if !isConnected {
            completion()
        } else {
            notifyDisconnectedCompletion = completion
        }
    }
    
    public func getAppAndVersion(success: @escaping ((AppInfo)->()), failure: @escaping ErrorResponse) {
        let apdu = APDU(data: [0xb0, 0x01, 0x00, 0x00])
        exchange(apdu: apdu) { result in
            switch result {
            case .success(let string):
                let data = string.UInt8Array()
                var i = 0
                let format = data[i]
                if format != 1 {
                    failure(BleTransportError.lowerLevelError(description: "Format is not supported"))
                    return
                }
                i += 1
                let nameLength = Int(data[i])
                i += 1
                let nameData = data[i..<i+Int(nameLength)]
                i += nameLength
                let versionLength = Int(data[i])
                i += 1
                let versionData = data[i..<i+Int(versionLength)]
                i += versionLength
                guard let name = String(data: Data(nameData), encoding: .ascii) else { failure(BleTransportError.lowerLevelError(description: "Could not parse response data")); return }
                guard let version = String(data: Data(versionData), encoding: .ascii) else { failure(BleTransportError.lowerLevelError(description: "Could not parse response data")); return }
                success(AppInfo(name: name, version: version))
            case .failure(let error):
                failure(error)
            }
        }
    }
    
    public func openAppIfNeeded(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        Task() {
            do {
                let currentAppInfo = try await getAppAndVersion()
                if currentAppInfo.name != name {
                    if currentAppInfo.name == "BOLOS" {
                        try await openApp(name)
                        completion(.success(()))
                    } else {
                        try await closeApp()
                        try await openApp(name)
                        completion(.success(()))
                    }
                } else {
                    completion(.success(()))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    
    // MARK: - Private methods
    
    /// Updates the current list of peripherals matching them with their service.
    ///
    /// - Parameter discoveries: All the current peripherals.
    /// - Returns: A boolean indicating whether the last changed since the last update.
    @discardableResult
    fileprivate func updatePeripheralsServicesTuple(discoveries: [ScanDiscovery]) -> Bool {
        var auxPeripherals = [PeripheralInfo]()
        for discovery in discoveries {
            if let services = discovery.advertisementPacket["kCBAdvDataServiceUUIDs"] as? [CBUUID], let firstService = services.first {
                auxPeripherals.append(PeripheralInfo(peripheral: discovery.peripheralIdentifier, rssi: discovery.rssi, serviceUUID: firstService, canWriteWithoutResponse: nil))
            }
        }
        
        let somethingChanged = auxPeripherals.map({ $0.peripheral }) != peripheralsServicesTuple.map({ $0.peripheral })
        
        peripheralsServicesTuple = auxPeripherals
        
        return somethingChanged
    }
    
    fileprivate func scanAndDiscoverBeforeConnecting(lookingFor identifier: PeripheralIdentifier, connectFunction: @escaping ConnectFunction, failure: @escaping BleErrorResponse) {
        scan(validationBlock: { $0.peripheral == identifier }, connectFunction: connectFunction, failure: failure)
    }
    
    fileprivate func scanAndDiscoverBeforeConnecting(lookingFor name: String, connectFunction: @escaping ConnectFunction, failure: @escaping BleErrorResponse) {
        scan(validationBlock: { $0.peripheral.name == name }, connectFunction: connectFunction, failure: failure)
    }
    
    fileprivate func scan(validationBlock predicate: @escaping (PeripheralInfo) -> Bool, connectFunction: @escaping ConnectFunction, failure: @escaping BleErrorResponse) {
        DispatchQueue.main.async {
            let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                self.stopScanning()
                failure(.connectError(description: "Couldn't find peripheral when scanning, timed out"))
            }
            
            self.scan(duration: self.scanDuration) { [weak self] discoveries in
                if let p = discoveries.first(where: { predicate($0) }) {
                    timer.invalidate()
                    connectFunction(p.peripheral)
                    self?.stopScanning()
                }
            } stopped: { error in
                if let error = error {
                    failure(.connectError(description: "Couldn't find peripheral when scanning because of error: \(error.localizedDescription)"))
                }
            }
        }
    }
    
    fileprivate func currentConnectedTuple() -> Result<(PeripheralIdentifier, PeripheralInfo, BleService), BleTransportError> {
        guard let connectedPeripheral = connectedPeripheral else { return .failure(.currentConnectedError(description: "Not connected")) }
        guard let connectedPeripheralTuple = peripheralsServicesTuple.first(where: { $0.peripheral.uuid == connectedPeripheral.uuid }) else { return .failure(.currentConnectedError(description: "peripheralsServiceTuple doesn't contain connected peripheral UUID")) }
        guard let peripheralService = configuration.serviceMatching(serviceUUID: connectedPeripheralTuple.serviceUUID) else { return .failure(.currentConnectedError(description: "No matching peripheralService")) }
        
        return .success((connectedPeripheral, connectedPeripheralTuple, peripheralService))
    }
    
    /**
     * Write the next ble frame to the peripheral, only triggered from the exchange/send methods.
     **/
    fileprivate func writeAPDU(_ apdu: APDU, withResponse: Bool = false) {
        guard !apdu.isEmpty else {
            self.exchangeCallback?(.failure(.writeError(description: "APDU is empty")))
            self.exchangeCallback = nil
            return
        }
        
        send(apdu: apdu) {
            apdu.next()
            if !apdu.isEmpty {
                self.writeAPDU(apdu)
            }
        } failure: { error in
            self.isExchanging = false
            self.exchangeCallback?(.failure(.writeError(description: error.localizedDescription)))
            self.exchangeCallback = nil
        }
        
    }
    
    fileprivate func startListening(setupFinished: EmptyResponse?) {
        self.listen { [weak self] apduReceived in
            guard let self = self else { return }
            if self.mtuWaitingForCallback != nil {
                self.parseMTUresponse(apduReceived: apduReceived)
                self.mtuWaitingForCallback = nil
                return
            }
            /// This might be a partial response
            var offset = 6
            let hex = apduReceived.data.hexEncodedString()
            
            if self.currentResponse == "" {
                offset = 10
                
                let a = hex.index(hex.startIndex, offsetBy: 6)
                let b = hex.index(hex.startIndex, offsetBy: 10)
                let expectedLength = (Int(hex[a..<b], radix: 16) ?? 1) * 2
                self.currentResponseRemainingLength = expectedLength
                print("Expected length is: \(expectedLength)")
            }
            
            let cleanAPDU = hex.suffix(hex.count - offset)
            
            self.currentResponse += cleanAPDU
            self.currentResponseRemainingLength -= cleanAPDU.count
            
            print("Received: \(cleanAPDU)")
            
            if self.currentResponseRemainingLength <= 0 {
                /// We got the full response in `currentResponse`
                self.isExchanging = false
                self.exchangeCallback?(.success(self.currentResponse))
                self.exchangeCallback = nil
                self.currentResponse = ""
                self.currentResponseRemainingLength = 0
            } else {
                print("WAITING_FOR_NEXT_MESSAGE!!")
            }
        } setupFinished: {
            setupFinished?()
        } failure: { [weak self] error in
            if case .pairingError = error {
                self?.connectFailure?(error)
                self?.disconnect(completion: nil)
            } else {
                self?.exchangeCallback?(.failure(error))
                self?.exchangeCallback = nil
            }
            self?.isExchanging = false
        }
    }
    
    fileprivate func listen(apduReceived: @escaping APDUResponse, setupFinished: EmptyResponse?, failure: @escaping BleErrorResponse) {
        let peripheralService: BleService
        let currentConnectedTuple = currentConnectedTuple()
        switch currentConnectedTuple {
        case .success(let tuple):
            (_, _, peripheralService) = tuple
        case .failure(let error):
            failure(error)
            return
        }
        self.bleModule.listen(to: peripheralService.notify) { (result: ReadResult<APDU>) in
            switch result {
            case .success(let apdu):
                apduReceived(apdu)
            case .failure(let error):
                if (error as NSError).code == CBATTError.insufficientEncryption.rawValue {
                    failure(.pairingError(description: error.localizedDescription))
                } else {
                    failure(.listenError(description: error.localizedDescription))
                }
            }
        } setupFinished: {
            setupFinished?()
        }
    }
    
    fileprivate func inferMTU() {
        send(value: APDU.inferMTU) {
            
        } failure: { error in
            print("Error inferring MTU: \(error.localizedDescription)")
        }
    }
    
    fileprivate func parseMTUresponse(apduReceived: APDU) {
        if apduReceived.data.first == 0x08 {
            if let fifthByte = apduReceived.data.advanced(by: 5).first {
                APDU.mtuSize = Int(fifthByte)
            }
        }
        if let connectedPeripheral = connectedPeripheral {
            mtuWaitingForCallback?(connectedPeripheral)
        }
    }
    
    fileprivate func clearConnection() {
        connectedPeripheral = nil
        isExchanging = false
        notifyDisconnectedCompletion?()
        notifyDisconnectedCompletion = nil /// We call `notifyDisconnectedCompletion` only once since it's used to be notified about the next disconnection not all of them
        disconnectedCallback?()
    }
    
    fileprivate func openApp(_ name: String, success: @escaping EmptyResponse, failure: @escaping ErrorResponse) {
        let errorCodes: [BleStatusError: [String]] = [.userRejected(status: ""): ["6985", "5501"], .appNotAvailableInDevice(status: ""): ["6984", "6807"]]
        let nameData = Data(name.utf8)
        var data: [UInt8] = [0xe0, 0xd8, 0x00, 0x00]
        data.append(UInt8(nameData.count))
        data.append(contentsOf: nameData)
        let apdu = APDU(data: data)

        let connectedPeripheral: PeripheralIdentifier
        switch currentConnectedTuple() {
        case .success(let tuple):
            (connectedPeripheral, _, _) = tuple
        case .failure(let error):
            failure(error)
            return
        }
        
        exchange(apdu: apdu) { [weak self] result in
            guard let self = self else { failure(BleTransportError.lowerLevelError(description: "closeApp -> self is nil")); return }
            guard let disconnectedCallback = self.disconnectedCallback else { failure(BleTransportError.lowerLevelError(description: "closeApp -> disconnectedCallback is nil")); return }
            
            switch result {
            case .success(let response):
                if let error = self.parseStatus(response: response, errorCodes: errorCodes) {
                    failure(error)
                } else {
                    self.notifyDisconnected {
                        self.connect(toPeripheralID: connectedPeripheral, disconnectedCallback: disconnectedCallback) { _ in
                            success()
                        } failure: { error in
                            failure(error)
                        }
                    }
                }
            case .failure(let error):
                failure(error)
            }
        }
    }
    
    /// Never call this method directly since some apps (like Bitcoin) will hang the execution if `getAppAndVersion` is not called right before
    fileprivate func closeApp(success: @escaping EmptyResponse, failure: @escaping ErrorResponse) {
        let apdu = APDU(data: [0xb0, 0xa7, 0x00, 0x00])
        
        let connectedPeripheral: PeripheralIdentifier
        switch currentConnectedTuple() {
        case .success(let tuple):
            (connectedPeripheral, _, _) = tuple
        case .failure(let error):
            failure(error)
            return
        }
        
        exchange(apdu: apdu) { [weak self] result in
            guard let self = self else { failure(BleTransportError.lowerLevelError(description: "closeApp -> self is nil")); return }
            guard let disconnectedCallback = self.disconnectedCallback else { failure(BleTransportError.lowerLevelError(description: "closeApp -> disconnectedCallback is nil")); return }
            
            switch result {
            case .success(_):
                self.notifyDisconnected {
                    self.connect(toPeripheralID: connectedPeripheral, disconnectedCallback: disconnectedCallback) { _ in
                        success()
                    } failure: { error in
                        failure(error)
                    }
                }
            case .failure(let error):
                failure(error)
            }
        }
    }
    
    fileprivate func parseStatus(response: String, errorCodes: [BleStatusError: [String]]) -> BleStatusError? {
        let status = String(response.suffix(4))
        if status.count == 4 {
            if status == "9000" {
                return nil
            } else {
                if let error = errorCodes.first(where: { $0.value.contains(status) })?.key {
                    /// `error` here is a BleStatusError which we used to group the status codes that match the associated value `status` it has is empty because we didn't know the appropriate status then so we re-generate it here
                    switch error {
                    case .userRejected(_):
                        return .userRejected(status: status)
                    case .appNotAvailableInDevice(_):
                        return .appNotAvailableInDevice(status: status)
                    case .formatNotSupported(_):
                        return .formatNotSupported(status: status)
                    case .couldNotParseResponseData(_):
                        return .couldNotParseResponseData(status: status)
                    case .unknown(_):
                        return .unknown(status: status)
                    case .noStatus:
                        return .noStatus
                    }
                } else {
                    return .unknown(status: status)
                }
            }
        } else {
            return .noStatus
        }
    }
    
    private func createConnectFunction(success: @escaping PeripheralResponse, failure: @escaping BleErrorResponse) -> ConnectFunction {
        return { (peripheral: PeripheralIdentifier) in
            self.bleModule.connect(peripheralIdentifier: peripheral, timeout: .seconds(5)) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let peripheral):
                    self.connectedPeripheral = PeripheralIdentifier(uuid: peripheral.identifier, name: peripheral.name)
                    self.connectFailure = failure
                    self.startListening {
                        self.mtuWaitingForCallback = success
                        self.inferMTU()
                    }
                case .failure(let error):
                    failure(.connectError(description: error.localizedDescription))
                }
            }
        }
    }
}

/// Async implementations
extension BleTransport {
    public func bluetoothStateCallback() async -> CBManagerState {
        return await withCheckedContinuation { continuation in
            bluetoothStateCallback { state in
                continuation.resume(returning: state)
            }
        }
    }
    
    public func scan(duration: TimeInterval) -> AsyncThrowingStream<[PeripheralInfo], Error> {
        return AsyncThrowingStream { continuation in
            scan(duration: duration) { devices in
                continuation.yield(devices)
            } stopped: { error in
                if let error = error {
                    continuation.finish(throwing: error)
                    return
                }
                continuation.finish()
            }
        }
    }
    
    @discardableResult
    public func create(scanDuration: TimeInterval, disconnectedCallback: EmptyResponse?) async throws -> PeripheralIdentifier {
        let lock = NSLock()
        return try await withCheckedThrowingContinuation { continuation in
            
            // https://forums.swift.org/t/how-to-prevent-swift-task-continuation-misuse/57581
            var nillableContinuation: CheckedContinuation<PeripheralIdentifier, Error>? = continuation
            
            create(scanDuration: scanDuration, disconnectedCallback: disconnectedCallback) { response in
                lock.lock()
                defer { lock.unlock() }
                nillableContinuation?.resume(returning: response)
                nillableContinuation = nil
            } failure: { error in
                lock.lock()
                defer { lock.unlock() }
                
                nillableContinuation?.resume(throwing: error)
                nillableContinuation = nil
            }

        }
    }
    @discardableResult
    public func connect(toPeripheralID: PeripheralIdentifier, disconnectedCallback: EmptyResponse?) async throws -> PeripheralIdentifier {
        let lock = NSLock()
        return try await withCheckedThrowingContinuation { continuation in
            
            // https://forums.swift.org/t/how-to-prevent-swift-task-continuation-misuse/57581
            var nillableContinuation: CheckedContinuation<PeripheralIdentifier, Error>? = continuation
            
            connect(toPeripheralID: toPeripheralID, disconnectedCallback: disconnectedCallback) { response in
                lock.lock()
                defer { lock.unlock() }
                nillableContinuation?.resume(returning: response)
                nillableContinuation = nil
            } failure: { error in
                lock.lock()
                defer { lock.unlock() }
                nillableContinuation?.resume(throwing: error)
                nillableContinuation = nil
            }
            
        }
    }
    
    public func connect(toPeripheralNamed name: String, disconnectedCallback: EmptyResponse?) async throws -> PeripheralIdentifier {
        let lock = NSLock()
        return try await withCheckedThrowingContinuation { continuation in
            
            var nillableContinuation: CheckedContinuation<PeripheralIdentifier, Error>? = continuation
            
            connect(toPeripheralNamed: name, disconnectedCallback: disconnectedCallback) { response in
                lock.lock()
                defer { lock.unlock() }
                nillableContinuation?.resume(returning: response)
                nillableContinuation = nil
            } failure: { error in
                lock.lock()
                defer { lock.unlock() }
                nillableContinuation?.resume(throwing: error)
                nillableContinuation = nil
            }
            
        }
    }
    
    public func exchange(apdu apduToSend: APDU) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            exchange(apdu: apduToSend) { result in
                switch result {
                case .success(let response):
                    continuation.resume(returning: response)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    public func send(apdu: APDU) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            send(apdu: apdu) {
                continuation.resume()
            } failure: { error in
                continuation.resume(throwing: error)
            }
            
        }
    }
    public func disconnect() async throws {
        let lock = NSLock()
        return try await withCheckedThrowingContinuation { continuation in
            
            // https://forums.swift.org/t/how-to-prevent-swift-task-continuation-misuse/57581
            var nillableContinuation: CheckedContinuation<Void, Error>? = continuation
            
            disconnect() { error in
                if let error = error {
                    lock.lock()
                    defer { lock.unlock() }
                    nillableContinuation?.resume(throwing: error)
                    nillableContinuation = nil
                } else {
                    lock.lock()
                    defer { lock.unlock() }
                    nillableContinuation?.resume()
                    nillableContinuation = nil
                }
            }
        }
    }
    public func getAppAndVersion() async throws -> AppInfo {
        return try await withCheckedThrowingContinuation { continuation in
            self.getAppAndVersion { response in
                continuation.resume(returning: response)
            } failure: { error in
                continuation.resume(throwing: error)
            }
        }
    }
    public func openAppIfNeeded(_ name: String) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            openAppIfNeeded(name) { result in
                switch result {
                case .success(_):
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    fileprivate func openApp(_ name: String) async throws {
        let lock = NSLock()
        return try await withCheckedThrowingContinuation { continuation in
            var nillableContinuation: CheckedContinuation<Void, Error>? = continuation
            
            openApp(name) {
                lock.lock()
                defer { lock.unlock() }
                nillableContinuation?.resume()
                nillableContinuation = nil
            } failure: { error in
                lock.lock()
                defer { lock.unlock() }
                nillableContinuation?.resume(throwing: error)
                nillableContinuation = nil            }
        }
    }
    fileprivate func closeApp() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            closeApp() {
                continuation.resume()
            } failure: { error in
                continuation.resume(throwing: error)
            }
        }
    }
}

func print(_ object: Any) {
    #if DEBUG
    Swift.print("BleTransport", object)
    #endif
}
