//
//  LoopCompletionHUDView.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 5/1/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit
import LoopKitUI
import LoopCore

public final class LoopCompletionHUDView: BaseHUDView {

    @IBOutlet private weak var loopStateView: LoopStateView!
    
    override public var orderPriority: HUDViewOrderPriority {
        return 2
    }

    private(set) var freshness = LoopCompletionFreshness.stale {
        didSet {
            updateTintColor()
        }
    }

    override public func awakeFromNib() {
        super.awakeFromNib()

        updateDisplay(nil)
    }

    public var loopIconClosed = false {
        didSet {
            loopStateView.open = !loopIconClosed
        }
    }

    public var lastLoopCompleted: Date? {
        didSet {
            if lastLoopCompleted != oldValue {
                loopInProgress = false
            }
        }
    }

    public var loopInProgress = false {
        didSet {
            loopStateView.animated = loopInProgress

            if !loopInProgress {
                updateTimer = nil
                assertTimer()
            }
        }
    }

    public var closedLoopDisallowedLocalizedDescription: String?

    public func assertTimer(_ active: Bool = true) {
        if active && window != nil, let date = lastLoopCompleted {
            initTimer(date)
        } else {
            updateTimer = nil
        }
    }

    override public func stateColorsDidUpdate() {
        super.stateColorsDidUpdate()
        updateTintColor()
    }

    private func updateTintColor() {
        let tintColor: UIColor?

        switch freshness {
        case .fresh:
            tintColor = stateColors?.normal
        case .aging:
            tintColor = stateColors?.warning
        case .stale:
            tintColor = stateColors?.error
        }

        self.tintColor = tintColor
    }

    private func initTimer(_ startDate: Date) {
        let updateInterval = TimeInterval(minutes: 1)

        let timer = Timer(
            fireAt: startDate.addingTimeInterval(2),
            interval: updateInterval,
            target: self,
            selector: #selector(updateDisplay(_:)),
            userInfo: nil,
            repeats: true
        )
        updateTimer = timer

        RunLoop.main.add(timer, forMode: .default)
    }

    private var updateTimer: Timer? {
        willSet {
            if let timer = updateTimer {
                timer.invalidate()
            }
        }
    }

    private lazy var formatterFull: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()

        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .full

        return formatter
    }()

    private var lastLoopMessage: String = ""

    private lazy var formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()

        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .short

        return formatter
    }()

    @objc private func updateDisplay(_: Timer?) {
        lastLoopMessage = ""
        if let date = lastLoopCompleted {
            let ago = abs(min(0, date.timeIntervalSinceNow))

            freshness = LoopCompletionFreshness(age: ago)

            if let timeString = formatter.string(from: ago) {
                switch traitCollection.preferredContentSizeCategory {
                case UIContentSizeCategory.extraSmall,
                     UIContentSizeCategory.small,
                     UIContentSizeCategory.medium,
                     UIContentSizeCategory.large:
                    // Use a longer form only for smaller text sizes
                    caption?.text = String(format: LocalizedString("%@ ago", comment: "Format string describing the time interval since the last completion date. (1: The localized date components"), timeString)
                default:
                    caption?.text = timeString
                }

                accessibilityLabel = String(format: LocalizedString("Loop ran %@ ago", comment: "Accessbility format label describing the time interval since the last completion date. (1: The localized date components)"), timeString)

                if let fullTimeStr = formatterFull.string(from: ago) {
                    lastLoopMessage = String(format: LocalizedString("%1$@ last successfully completed a loop %2$@ ago.", comment: "Last loop time completed message (1: app name) (2: last loop time string)"), Bundle.main.bundleDisplayName, fullTimeStr)
                }
            } else {
                caption?.text = "–"
                accessibilityLabel = nil
            }
        } else {
            caption?.text = "–"
            accessibilityLabel = LocalizedString("Waiting for first run", comment: "Accessibility label describing completion HUD waiting for first run")
        }

        if loopIconClosed {
            accessibilityHint = LocalizedString("Closed loop", comment: "Accessibility hint describing completion HUD for a closed loop")
        } else {
            accessibilityHint = LocalizedString("Open loop", comment: "Accessbility hint describing completion HUD for an open loop")
        }
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()

        assertTimer()
    }
}

extension LoopCompletionHUDView {
    public var loopCompletionMessage: (title: String, message: String) {
        switch freshness {
        case .fresh:
            if loopStateView.open {
                let reason = closedLoopDisallowedLocalizedDescription ?? NSLocalizedString("Tap Settings to toggle Closed Loop ON if you wish for the app to automate your insulin.", comment: "Instructions for user to close loop if it is allowed.")
                return (title: LocalizedString("Closed Loop OFF", comment: "Title of green open loop OFF message"),
                        message: String(format: NSLocalizedString("\n%1$@ is operating with Closed Loop in the OFF position. Your pump and CGM will continue operating, but the app will not adjust dosing automatically.\n\n%2$@", comment: "Green closed loop OFF message (1: app name)(2: reason for open loop)"), Bundle.main.bundleDisplayName, reason))
            } else {
                return (title: LocalizedString("Closed Loop ON", comment: "Title of green closed loop ON message"),
                        message: String(format: LocalizedString("\n%1$@ is operating with Closed Loop in the ON position. %2$@", comment: "Green closed loop ON message (1: app name) (2: last loop string)"), Bundle.main.bundleDisplayName, lastLoopMessage))
            }
        case .aging:
            return (title: LocalizedString("Loop Warning", comment: "Title of yellow loop message"),
                    message: String(format: LocalizedString("\n%1$@\n\nTap your CGM and insulin pump status icons for more information. %2$@ will continue trying to complete a loop, but watch for potential communication issues with your pump and CGM.", comment: "Yellow loop message (1: last loop string) (2: app name)"), lastLoopMessage, Bundle.main.bundleDisplayName))
        case .stale:
            return (title: LocalizedString("Loop Failure", comment: "Title of red loop message"),
                    message: String(format: LocalizedString("\n%1$@\n\nTap your CGM and insulin pump status icons for more information. %2$@ will continue trying to complete a loop, but check for potential communication issues with your pump and CGM.", comment: "Red loop message (1: last loop  string) (2: app name)"), lastLoopMessage, Bundle.main.bundleDisplayName))
        }
    }
}
