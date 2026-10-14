import AncintoshCore
import AppKit
@preconcurrency import ApplicationServices
import Foundation

private struct AXBanner: @unchecked Sendable {
    let element: AXUIElement
    let texts: [String]
}
private struct AXApplication: @unchecked Sendable { let pid: pid_t; let element: AXUIElement }

@MainActor final class MacNotificationSource {
    var changed: ((NotificationMessage) -> Void)?
    var failed: ((ProtocolFailure) -> Void)?
    private var requested = false
    private var active = false
    private var generation = UUID()
    private var observers: [pid_t: AXObserver] = [:]
    private var applications: [pid_t: AXUIElement] = [:]
    private struct Window { let element: AXUIElement; let id: UUID; var texts: [String] }
    private var windows: [pid_t: [Window]] = [:]
    private var primed: Set<pid_t> = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var scanning = false
    private var dirty = false
    private let queue = DispatchQueue(label: "Ancintosh.notifications.capture", qos: .utility)
    var permitted: Bool { AXIsProcessTrusted() }
    func request() -> Bool {
        if permitted { return true }
        guard !requested else { return false }
        requested = true
        return AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func start() {
        guard !active, permitted else { return }
        active = true; generation = UUID(); attach()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attach(); self?.schedule() }
            })
        }
        schedule()
    }
    func stop() {
        active = false; generation = UUID(); scanning = false; dirty = false
        for observer in observers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observers.removeAll(); applications.removeAll(); windows.removeAll(); primed.removeAll()
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }; workspaceTokens.removeAll()
    }
    private func attach() {
        guard active else { return }
        let matches = NSWorkspace.shared.runningApplications.filter {
            ($0.bundleIdentifier?.lowercased().contains("notificationcenter") == true) || ["NotificationCenter", "UserNotificationCenter"].contains($0.localizedName ?? "")
        }
        let live = Set(matches.map(\.processIdentifier))
        for pid in observers.keys.filter({ !live.contains($0) }) {
            if let observer = observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            applications.removeValue(forKey: pid); windows.removeValue(forKey: pid); primed.remove(pid)
        }
        for app in matches where observers[app.processIdentifier] == nil {
            let pid = app.processIdentifier, element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.1)
            var observer: AXObserver?
            let result = AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                MainActor.assumeIsolated { Unmanaged<MacNotificationSource>.fromOpaque(context).takeUnretainedValue().schedule() }
            }, &observer)
            guard result == .success, let observer else { continue }
            var count = 0
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification, kAXLayoutChangedNotification] {
                if AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success { count += 1 }
            }
            guard count > 0 else { failed?(.unsupported); continue }
            applications[pid] = element; observers[pid] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
    private func schedule(retry: Int = 2) {
        guard active else { return }
        if scanning { dirty = true; return }
        scanning = true
        let generation = generation, values = applications.map { AXApplication(pid: $0.key, element: $0.value) }
        queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            let captured = values.map { ($0.pid, Self.capture($0.element)) }
            Task { @MainActor in
                guard let self, self.active, self.generation == generation else { return }
                self.scanning = false
                for (pid, banners) in captured { self.accept(pid: pid, banners: banners) }
                let again = self.dirty; self.dirty = false
                if again { self.schedule() }
                else if retry > 0, captured.contains(where: { $0.1.contains(where: { $0.texts.isEmpty }) }) { self.schedule(retry: retry - 1) }
            }
        }
    }
    private func accept(pid: pid_t, banners: [AXBanner]) {
        let previous = windows[pid] ?? [], baseline = !primed.contains(pid)
        var current: [Window] = []
        for banner in banners {
            let old = previous.first { CFEqual($0.element, banner.element) }
            let id = old?.id ?? UUID()
            current.append(Window(element: banner.element, id: id, texts: banner.texts))
            guard !baseline, banner.texts.count >= 2, banner.texts.count <= 8, old?.texts != banner.texts,
                  banner.texts[0] != "Ancintosh", banner.texts[0] != "Andcintosh" else { continue }
            if let value = try? NotificationMessage.bounded(id: id, application: banner.texts[0], title: banner.texts[1], body: banner.texts.dropFirst(2).joined(separator: "\n")) { changed?(value) }
        }
        windows[pid] = current; primed.insert(pid)
        // A vanished banner is not an authoritative notification withdrawal.
    }
    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    nonisolated private static func capture(_ application: AXUIElement) -> [AXBanner] {
        let candidates = ((attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []) + ((attribute(application, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        var seen: [AXUIElement] = [], result: [AXBanner] = []
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        for window in candidates.prefix(16) where !seen.contains(where: { CFEqual($0, window) }) {
            seen.append(window)
            var texts: [String] = [], pending: [(AXUIElement, Int)] = [(window, 0)], visited = 0
            while let (element, depth) = pending.popLast(), visited < 128, ContinuousClock.now < deadline {
                visited += 1
                if (attribute(element, kAXRoleAttribute) as? String) == kAXStaticTextRole {
                    let value = (attribute(element, kAXValueAttribute) as? String) ?? (attribute(element, kAXTitleAttribute) as? String) ?? (attribute(element, kAXDescriptionAttribute) as? String)
                    if let value { let text = String(value.prefix(8192)).trimmingCharacters(in: .whitespacesAndNewlines); if !text.isEmpty { texts.append(text) } }
                }
                if depth < 8, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                    for child in children.prefix(min(128 - visited, max(0, 128 - pending.count))).reversed() { pending.append((child, depth + 1)) }
                }
            }
            result.append(AXBanner(element: window, texts: texts))
        }
        return result
    }
}
