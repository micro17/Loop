//
//  PumpDataManager.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/30/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import Foundation
import CarbKit
import GlucoseKit
import HealthKit
import InsulinKit
import LoopKit
import MinimedKit
import RileyLinkKit
import WatchConnectivity
import xDripG5

enum State<T> {
    case NeedsConfiguration
    case Ready(T)
}

enum Error: ErrorType {
    case MissingDataError
    case StaleDataError
}


class PumpDataManager: NSObject, CarbStoreDelegate, TransmitterDelegate, WCSessionDelegate {
    static let GlucoseUpdatedNotification = "com.loudnate.Naterade.notification.GlucoseUpdated"
    static let PumpStatusUpdatedNotification = "com.loudnate.Naterade.notification.PumpStatusUpdated"

    // MARK: - Observed state

    lazy var logger = DiagnosticLogger()

    var rileyLinkManager: RileyLinkManager? {
        switch rileyLinkState {
        case .Ready(let manager):
            return manager
        case .NeedsConfiguration:
            return nil
        }
    }

    var transmitter: Transmitter? {
        switch transmitterState {
        case .Ready(let transmitter):
            return transmitter
        case .NeedsConfiguration:
            return nil
        }
    }

    // MARK: - RileyLink

    var rileyLinkManagerObserver: AnyObject? {
        willSet {
            if let observer = rileyLinkManagerObserver {
                NSNotificationCenter.defaultCenter().removeObserver(observer)
            }
        }
    }

    var rileyLinkDeviceObserver: AnyObject? {
        willSet {
            if let observer = rileyLinkDeviceObserver {
                NSNotificationCenter.defaultCenter().removeObserver(observer)
            }
        }
    }

    func receivedRileyLinkManagerNotification(note: NSNotification) {
        NSNotificationCenter.defaultCenter().postNotificationName(note.name, object: self, userInfo: note.userInfo)
    }

    func receivedRileyLinkPacketNotification(note: NSNotification) {
        if let
            device = note.object as? RileyLinkDevice,
            packet = note.userInfo?[RileyLinkDevicePacketKey] as? MinimedPacket where packet.valid == true,
            let data = packet.data,
            message = PumpMessage(rxData: data)
        {
            switch message.packetType {
            case .MySentry:
                switch message.messageBody {
                case let body as MySentryPumpStatusMessageBody:
                    updatePumpStatus(body, fromDevice: device)
                case is MySentryAlertMessageBody:
                    break
                    // TODO: de-dupe
//                    logger?.addMessage(body.dictionaryRepresentation, toCollection: "sentryAlert")
                case is MySentryAlertClearedMessageBody:
                    break
                    // TODO: de-dupe
//                    logger?.addMessage(body.dictionaryRepresentation, toCollection: "sentryAlert")
                case let body as UnknownMessageBody:
                    logger?.addMessage(body.dictionaryRepresentation, toCollection: "sentryOther")
                default:
                    break
                }
            default:
                break
            }
        }
    }

    func connectToRileyLink(device: RileyLinkDevice) {
        connectedPeripheralIDs.insert(device.peripheral.identifier.UUIDString)

        rileyLinkManager?.connectDevice(device)
    }

    func disconnectFromRileyLink(device: RileyLinkDevice) {
        connectedPeripheralIDs.remove(device.peripheral.identifier.UUIDString)

        rileyLinkManager?.disconnectDevice(device)
    }

    private func updatePumpStatus(status: MySentryPumpStatusMessageBody, fromDevice device: RileyLinkDevice) {
        if status != latestPumpStatus {
            latestPumpStatus = status

//            logger?.addMessage(status.dictionaryRepresentation, toCollection: "sentryMessage")

            doseStore.addReservoirValue(status.reservoirRemainingUnits, atDate: status.pumpDate) { (_, error) -> Void in
                if let error = error {
                    self.logger?.addError(error, fromSource: "DoseStore")
                } else {
                    NSNotificationCenter.defaultCenter().postNotificationName(self.dynamicType.PumpStatusUpdatedNotification, object: self)
                }
            }
        }
    }

    func getPredictedGlucose(resultsHandler: (values: [GlucoseValue], error: ErrorType?) -> Void) {
        guard let
            glucose = latestGlucose ?? glucoseStore?.latestGlucose,
            pumpStatus = latestPumpStatus
            else
        {
            resultsHandler(values: [], error: Error.MissingDataError)
            return
        }

        let startDate = NSDate()
        let recencyInterval = NSTimeInterval(minutes: 15)

        guard   startDate.timeIntervalSinceDate(glucose.startDate) <= recencyInterval &&
                startDate.timeIntervalSinceDate(pumpStatus.pumpDate) <= recencyInterval
            else
        {
            resultsHandler(values: [], error: Error.StaleDataError)
            return
        }

        let dataGroup = dispatch_group_create()
        var momentum: [GlucoseEffect] = []
        var carbEffect: [GlucoseEffect] = []
        var insulinEffect: [GlucoseEffect] = []
        var lastError: ErrorType?

        dispatch_group_enter(dataGroup)
        glucoseStore?.getRecentMomentumEffect { (effects, error) -> Void in
            if let error = error {
                self.logger?.addError(error, fromSource: "GlucoseStore")
                lastError = error
            }

            momentum = effects
            dispatch_group_leave(dataGroup)
        }

        if let carbStore = carbStore {
            dispatch_group_enter(dataGroup)
            carbStore.getGlucoseEffects(startDate: glucose.startDate) { (effects, error) -> Void in
                if let error = error {
                    self.logger?.addError(error, fromSource: "CarbStore")
                    lastError = error
                }

                carbEffect = effects
                dispatch_group_leave(dataGroup)
            }
        }

        dispatch_group_enter(dataGroup)
        doseStore.getGlucoseEffects(startDate: glucose.startDate) { (effects, error) -> Void in
            if let error = error {
                self.logger?.addError(error, fromSource: "DoseStore")
                lastError = error
            }

            insulinEffect = effects
            dispatch_group_leave(dataGroup)
        }

        dispatch_group_notify(dataGroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)) { () -> Void in
            let prediction = LoopMath.predictGlucose(glucose, momentum: momentum, effects: carbEffect, insulinEffect)

            self.logger?.addLoopStatus(
                startDate: startDate,
                endDate: NSDate(),
                glucose: glucose,
                effects: [
                    "momentum": momentum,
                    "carbs": carbEffect,
                    "insulin": insulinEffect
                ],
                error: lastError,
                prediction: prediction
            )

            resultsHandler(values: prediction, error: lastError)
        }
    }

    // MARK: - Transmitter

    // MARK: TransmitterDelegate

    func transmitter(transmitter: Transmitter, didError error: ErrorType) {
        logger?.addMessage([
            "error": "\(error)",
            "collectedAt": NSDateFormatter.ISO8601StrictDateFormatter().stringFromDate(NSDate())
            ], toCollection: "g5"
        )
    }

    func transmitter(transmitter: Transmitter, didReadGlucose glucose: GlucoseRxMessage) {
        transmitterStartTime = transmitter.startTimeInterval

        if glucose != latestGlucoseMessage {
            latestGlucoseMessage = glucose

            if glucose.glucose >= 20, let transmitterStartTime = transmitterStartTime, glucoseStore = glucoseStore {
                let quantity = HKQuantity(unit: HKUnit.milligramsPerDeciliterUnit(), doubleValue: Double(glucose.glucose))

                let startDate = NSDate(timeIntervalSince1970: transmitterStartTime).dateByAddingTimeInterval(NSTimeInterval(glucose.timestamp))

                let device = HKDevice(name: "xDripG5", manufacturer: "Dexcom", model: "G5 Mobile", hardwareVersion: nil, firmwareVersion: nil, softwareVersion: String(xDripG5VersionNumber), localIdentifier: nil, UDIDeviceIdentifier: "00386270000002")

                glucoseStore.addGlucose(quantity, date: startDate, displayOnly: glucose.glucoseIsDisplayOnly, device: device, resultHandler: { (_, value, error) -> Void in
                    if let error = error {
                        self.logger?.addError(error, fromSource: "GlucoseStore")
                    } else if let value = value {
                        self.latestGlucose = value
                    }

                    NSNotificationCenter.defaultCenter().postNotificationName(self.dynamicType.GlucoseUpdatedNotification, object: self)
                })

                updateWatch()
            } else {
                NSNotificationCenter.defaultCenter().postNotificationName(self.dynamicType.GlucoseUpdatedNotification, object: self)
            }
        }
    }

    // MARK: - Managed state

    var transmitterStartTime: NSTimeInterval? = NSUserDefaults.standardUserDefaults().transmitterStartTime {
        didSet {
            if oldValue != transmitterStartTime {
                NSUserDefaults.standardUserDefaults().transmitterStartTime = transmitterStartTime
            }
        }
    }

    var latestGlucoseMessage: GlucoseRxMessage?

    var latestGlucose: GlucoseValue?

    var latestPumpStatus: MySentryPumpStatusMessageBody?

    var transmitterState: State<Transmitter> = .NeedsConfiguration {
        didSet {
            switch transmitterState {
            case .Ready(let transmitter):
                transmitter.delegate = self
            case .NeedsConfiguration:
                break
            }
        }
    }

    var rileyLinkState: State<RileyLinkManager> = .NeedsConfiguration {
        willSet {
            switch newValue {
            case .Ready(let manager):
                rileyLinkManagerObserver = NSNotificationCenter.defaultCenter().addObserverForName(nil, object: manager, queue: nil) { [weak self = self] (note) -> Void in
                    self?.receivedRileyLinkManagerNotification(note)
                }

                rileyLinkDeviceObserver = NSNotificationCenter.defaultCenter().addObserverForName(RileyLinkDeviceDidReceivePacketNotification, object: nil, queue: nil, usingBlock: { [weak self = self] (note) -> Void in
                    self?.receivedRileyLinkPacketNotification(note)
                })

            case .NeedsConfiguration:
                rileyLinkManagerObserver = nil
                rileyLinkDeviceObserver = nil
            }
        }
    }

    var connectedPeripheralIDs: Set<String> {
        didSet {
            NSUserDefaults.standardUserDefaults().connectedPeripheralIDs = Array(connectedPeripheralIDs)
        }
    }

    var pumpID: String? {
        didSet {
            if pumpID?.characters.count != 6 {
                pumpID = nil
            }

            switch (rileyLinkState, pumpID) {
            case (_, let pumpID?):
                rileyLinkState = .Ready(RileyLinkManager(pumpID: pumpID, autoconnectIDs: connectedPeripheralIDs))
            case (.NeedsConfiguration, .None):
                break
            case (.Ready, .None):
                rileyLinkState = .NeedsConfiguration
            }

            doseStore.pumpID = pumpID

            NSUserDefaults.standardUserDefaults().pumpID = pumpID
        }
    }

    var transmitterID: String? {
        didSet {
            if transmitterID?.characters.count != 6 {
                transmitterID = nil
            }

            switch (transmitterState, transmitterID) {
            case (.NeedsConfiguration, let transmitterID?):
                transmitterState = .Ready(Transmitter(
                    ID: transmitterID,
                    startTimeInterval: NSUserDefaults.standardUserDefaults().transmitterStartTime,
                    passiveModeEnabled: true
                ))
            case (.Ready, .None):
                transmitterState = .NeedsConfiguration
            case (.Ready(let transmitter), let transmitterID?):
                transmitter.ID = transmitterID
                transmitter.startTimeInterval = nil
            case (.NeedsConfiguration, .None):
                break
            }

            NSUserDefaults.standardUserDefaults().transmitterID = transmitterID
        }
    }

    var basalRateSchedule: BasalRateSchedule? {
        didSet {
            doseStore.basalProfile = basalRateSchedule

            NSUserDefaults.standardUserDefaults().basalRateSchedule = basalRateSchedule
        }
    }

    var carbRatioSchedule: CarbRatioSchedule? {
        didSet {
            carbStore?.carbRatioSchedule = carbRatioSchedule

            NSUserDefaults.standardUserDefaults().carbRatioSchedule = carbRatioSchedule
        }
    }

    var insulinActionDuration: NSTimeInterval? {
        didSet {
            doseStore.insulinActionDuration = insulinActionDuration

            NSUserDefaults.standardUserDefaults().insulinActionDuration = insulinActionDuration
        }
    }

    var insulinSensitivitySchedule: InsulinSensitivitySchedule? {
        didSet {
            carbStore?.insulinSensitivitySchedule = insulinSensitivitySchedule
            doseStore.insulinSensitivitySchedule = insulinSensitivitySchedule

            NSUserDefaults.standardUserDefaults().insulinSensitivitySchedule = insulinSensitivitySchedule
        }
    }

    var glucoseTargetRangeSchedule: GlucoseRangeSchedule? {
        didSet {
            NSUserDefaults.standardUserDefaults().glucoseTargetRangeSchedule = glucoseTargetRangeSchedule
        }
    }

    var maximumBasalRatePerHour: Double? {
        didSet {
            NSUserDefaults.standardUserDefaults().maximumBasalRatePerHour = maximumBasalRatePerHour
        }
    }

    var maximumBolus: Double? {
        didSet {
            NSUserDefaults.standardUserDefaults().maximumBolus = maximumBolus
        }
    }

    // MARK: - CarbKit

    let carbStore: CarbStore?

    private func addCarbEntryFromWatchMessage(message: [String: AnyObject]) {
        if let carbStore = carbStore, carbEntry = CarbEntryUserInfo(rawValue: message) {
            let newEntry = NewCarbEntry(
                quantity: HKQuantity(unit: carbStore.preferredUnit, doubleValue: carbEntry.value),
                startDate: carbEntry.startDate,
                foodType: nil,
                absorptionTime: carbEntry.absorptionTimeType.absorptionTimeFromDefaults(carbStore.defaultAbsorptionTimes)
            )

            carbStore.addCarbEntry(newEntry, resultHandler: { (_, _, error) -> Void in
                if let error = error {
                    self.logger?.addError(error, fromSource: "CarbStore")
                }
            })
        }
    }

    // MARK: CarbStoreDelegate

    func carbStore(_: CarbStore, didError error: CarbStore.Error) {
        logger?.addError(error, fromSource: "CarbStore")
    }

    // MARK: - GlucoseKit

    let glucoseStore: GlucoseStore? = GlucoseStore()

    // MARK: - InsulinKit

    let doseStore: DoseStore

    // MARK: - WatchKit

    private var watchSession: WCSession? = {
        if WCSession.isSupported() {
            return WCSession.defaultSession()
        } else {
            return nil
        }
    }()

    private func updateWatch() {
        // TODO: Check session.activationState as of iOS 9.3
        if let _ = watchSession {
//            switch session.activationState {
//            case .NotActivated, .Inactive:
//                session.activateSession()
//            case .Activated:
                sendWatchContext()
//            }
        }
    }

    private var latestComplicationGlucose: GlucoseRxMessage?

    private func sendWatchContext() {
        if let session = watchSession where session.paired && session.watchAppInstalled {
            let userInfo = WatchContext(pumpStatus: latestPumpStatus, glucose: latestGlucoseMessage, transmitterStartTime: transmitterStartTime).rawValue

            let complicationShouldUpdate: Bool

            if let complicationGlucose = latestComplicationGlucose, glucose = latestGlucoseMessage {
                complicationShouldUpdate = Int(glucose.timestamp) - Int(complicationGlucose.timestamp) >= 30 * 60 || abs(Int(glucose.glucose) - Int(complicationGlucose.glucose)) >= 20
            } else {
                complicationShouldUpdate = true
            }

            if session.complicationEnabled && complicationShouldUpdate, let glucose = latestGlucoseMessage {
                session.transferCurrentComplicationUserInfo(userInfo)
                latestComplicationGlucose = glucose
            } else {
                do {
                    try session.updateApplicationContext(userInfo)
                } catch let error {
                    self.logger?.addError(error, fromSource: "WCSession")
                }
            }
        }
    }

    // MARK: WCSessionDelegate

    func session(session: WCSession, didReceiveMessage message: [String : AnyObject]) {
        addCarbEntryFromWatchMessage(message)
    }

    func session(session: WCSession, didReceiveUserInfo userInfo: [String : AnyObject]) {
        addCarbEntryFromWatchMessage(userInfo)
    }

    // TODO: iOS 9.3
    //    func session(session: WCSession, activationDidCompleteWithState activationState: WCSessionActivationState, error: NSError?) { }

    func sessionDidBecomeInactive(session: WCSession) {
        // Nothing to do here
    }

    func sessionDidDeactivate(session: WCSession) {
        watchSession = WCSession.defaultSession()
        watchSession?.delegate = self
        watchSession?.activateSession()
    }

    // MARK: - Initialization

    static let sharedManager = PumpDataManager()

    override init() {
        basalRateSchedule = NSUserDefaults.standardUserDefaults().basalRateSchedule
        carbRatioSchedule = NSUserDefaults.standardUserDefaults().carbRatioSchedule
        connectedPeripheralIDs = Set(NSUserDefaults.standardUserDefaults().connectedPeripheralIDs)
        insulinActionDuration = NSUserDefaults.standardUserDefaults().insulinActionDuration
        insulinSensitivitySchedule = NSUserDefaults.standardUserDefaults().insulinSensitivitySchedule
        glucoseTargetRangeSchedule = NSUserDefaults.standardUserDefaults().glucoseTargetRangeSchedule
        maximumBasalRatePerHour = NSUserDefaults.standardUserDefaults().maximumBasalRatePerHour
        maximumBolus = NSUserDefaults.standardUserDefaults().maximumBolus
        pumpID = NSUserDefaults.standardUserDefaults().pumpID

        doseStore = DoseStore(pumpID: pumpID, insulinActionDuration: insulinActionDuration, basalProfile: basalRateSchedule, insulinSensitivitySchedule: insulinSensitivitySchedule)

        carbStore = CarbStore(carbRatioSchedule: carbRatioSchedule, insulinSensitivitySchedule: insulinSensitivitySchedule)

        super.init()

        watchSession?.delegate = self
        watchSession?.activateSession()

        carbStore?.delegate = self

        defer {
            if let pumpID = pumpID {
                rileyLinkState = .Ready(RileyLinkManager(pumpID: pumpID, autoconnectIDs: connectedPeripheralIDs))
            }

            transmitterID = NSUserDefaults.standardUserDefaults().transmitterID
        }
    }

    deinit {
        rileyLinkManagerObserver = nil
        rileyLinkDeviceObserver = nil
    }
}


extension WatchContext {
    convenience init(pumpStatus: MySentryPumpStatusMessageBody?, glucose: GlucoseRxMessage?, transmitterStartTime: NSTimeInterval?) {
        self.init()

        if let glucose = glucose, transmitterStartTime = transmitterStartTime where glucose.state > 5 {
            glucoseValue = Int(glucose.glucose)
            glucoseTrend = Int(glucose.trend)
            glucoseDate = NSDate(timeIntervalSince1970: transmitterStartTime).dateByAddingTimeInterval(NSTimeInterval(glucose.timestamp))
        }

        if let status = pumpStatus {
            IOB = status.iob
            reservoir = status.reservoirRemainingUnits
            pumpDate = status.pumpDate
        }
    }
}

