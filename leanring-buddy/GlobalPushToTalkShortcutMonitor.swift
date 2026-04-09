//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures the global push-to-talk shortcut for the full app lifetime.
//  Uses a dedicated event-tap thread so the shortcut remains active even when
//  the menu bar panel is closed or Clicky is not the active app.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

enum GlobalPushToTalkMonitorState: Equatable {
    case stopped
    case listening
    case failed(String)
}

class GlobalPushToTalkShortcutMonitor: ObservableObject {
    private final class StartupResultBox {
        var didStart = false
        var failureReason: String?
    }

    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var monitorRunLoop: CFRunLoop?
    private var monitorThread: Thread?
    private var eventTapShortcutPressed = false

    @Published private(set) var hasActiveEventTap = false
    @Published private(set) var isShortcutCurrentlyPressed = false
    @Published private(set) var monitorState: GlobalPushToTalkMonitorState = .stopped

    /// Clicky's app flow only needs proof that the system is allowing the
    /// global shortcut monitor to operate. That is a practical proxy for the
    /// permission gate even when AXIsProcessTrusted() lags or returns a false
    /// negative for the current dev build.
    var grantsAccessibilityForAppFlow: Bool {
        hasActiveEventTap || monitorState == .listening
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        if monitorThread != nil {
            return hasActiveEventTap
        }

        let startupResultBox = StartupResultBox()
        let startupSemaphore = DispatchSemaphore(value: 0)

        let monitorThread = Thread { [weak self] in
            self?.runMonitorLoop(
                startupResultBox: startupResultBox,
                startupSemaphore: startupSemaphore
            )
        }
        monitorThread.name = "com.clicky.global-push-to-talk"
        monitorThread.start()
        self.monitorThread = monitorThread

        _ = startupSemaphore.wait(timeout: .now() + 3)

        if !startupResultBox.didStart {
            self.monitorThread = nil
            let failureReason = startupResultBox.failureReason ?? "Clicky couldn't install the global hotkey monitor."
            DispatchQueue.main.async {
                self.hasActiveEventTap = false
                self.monitorState = .failed(failureReason)
            }
            print("⚠️ Global push-to-talk: \(failureReason)")
        }

        return startupResultBox.didStart
    }

    func stop() {
        DispatchQueue.main.async {
            self.hasActiveEventTap = false
            self.isShortcutCurrentlyPressed = false
            self.monitorState = .stopped
        }

        guard let monitorRunLoop else {
            monitorThread = nil
            return
        }

        CFRunLoopPerformBlock(monitorRunLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            self.teardownEventTap()
            self.eventTapShortcutPressed = false
            self.monitorRunLoop = nil
            CFRunLoopStop(monitorRunLoop)
        }
        CFRunLoopWakeUp(monitorRunLoop)
        monitorThread = nil
    }

    private func runMonitorLoop(
        startupResultBox: StartupResultBox,
        startupSemaphore: DispatchSemaphore
    ) {
        autoreleasepool {
            monitorRunLoop = CFRunLoopGetCurrent()

            let didStart = installEventTap()
            startupResultBox.didStart = didStart
            if !didStart {
                startupResultBox.failureReason = "Clicky couldn't create a global keyboard event tap."
            }
            startupSemaphore.signal()

            guard didStart else {
                monitorRunLoop = nil
                return
            }

            CFRunLoopRun()
            teardownEventTap()
        }
    }

    private func installEventTap() -> Bool {
        guard globalEventTap == nil else {
            DispatchQueue.main.async {
                self.hasActiveEventTap = true
                self.monitorState = .listening
            }
            return true
        }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        let candidateTapLocations: [CGEventTapLocation] = [.cghidEventTap, .cgSessionEventTap]

        for candidateTapLocation in candidateTapLocations {
            guard let createdEventTap = CGEvent.tapCreate(
                tap: candidateTapLocation,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: eventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                continue
            }

            guard let createdRunLoopSource = CFMachPortCreateRunLoopSource(
                kCFAllocatorDefault,
                createdEventTap,
                0
            ) else {
                CFMachPortInvalidate(createdEventTap)
                continue
            }

            globalEventTap = createdEventTap
            globalEventTapRunLoopSource = createdRunLoopSource
            CFRunLoopAddSource(CFRunLoopGetCurrent(), createdRunLoopSource, .commonModes)
            CGEvent.tapEnable(tap: createdEventTap, enable: true)

            DispatchQueue.main.async {
                self.hasActiveEventTap = true
                self.monitorState = .listening
            }

            print("🎙️ Global push-to-talk: event tap installed via \(candidateTapLocation)")
            return true
        }

        return false
    }

    private func teardownEventTap() {
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                print("🎙️ Global push-to-talk: re-enabling disabled event tap")
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: eventTapShortcutPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            eventTapShortcutPressed = true
            DispatchQueue.main.async {
                self.isShortcutCurrentlyPressed = true
                self.shortcutTransitionPublisher.send(.pressed)
            }
        case .released:
            eventTapShortcutPressed = false
            DispatchQueue.main.async {
                self.isShortcutCurrentlyPressed = false
                self.shortcutTransitionPublisher.send(.released)
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
