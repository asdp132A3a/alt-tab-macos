import Cocoa

class SpacesEvents {
    private static let throttler = Throttler(delayInMs: 200)
    // F14 v2 (PLAN-019): timestamp of the most recent activeSpaceDidChange notification.
    // Window.updateSpaces() reads this via Window.recentSpaceChangeWithinMs() to gate
    // the Gap B on-screen tiebreaker — the tiebreaker should only fire during the
    // ~300-600ms transition window where CGS can return stale-non-empty space ids.
    static var lastChangeAt: Date?

    static func observe() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleEvent), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private static func handleEvent(_ notification: Notification) {
        lastChangeAt = Date()
        throttler.throttleOrProceed {
            Logger.debug { notification.name.rawValue }
            // Workaround for Safari full-screen videos
            // when full-screening a video, Safari spawns a second full-screen window called "Safari"
            // this window doesn't emit resize/move events. It doesn't pass isActualWindow on creation. It's added on focusedWindowChanged
            // for such cases, we refresh isFullscreen on Space change
            Windows.updateIsFullscreenOnCurrentSpace()
            if let frontmostPid = Applications.frontmostPid,
               let frontmostApp = Applications.findOrCreate(frontmostPid, false),
               let focusedWindow = frontmostApp.focusedWindow {
                App.checkIfShortcutsShouldBeDisabled(focusedWindow, nil)
            }
            // if UI was kept open during Space transition, the Spaces may be obsolete; we refresh them
            App.refreshOpenUiAfterExternalEvent(Windows.list)
            Logger.info { "screens:\(NSScreen.screens.map { ($0.cachedUuid() ?? "nil" as CFString, $0.frame) })" }
            Logger.info { "currentSpace:\(Spaces.currentSpaceIndex) (id:\(Spaces.currentSpaceId)) spaces:\(Spaces.screenSpacesMap)" }
        }
    }
}

// QL fork (PLAN-020 B1(b), FND-029): observe app-activation to drive an event-driven discovery resweep.
// The Epubor window-missing bug class is "a window never delivered via kAXWindowCreatedNotification";
// upstream c72fedbb (FND-028) removed the only event-driven re-discovery, so nothing re-adds such a
// window between summons. The user activates an app to USE it — often without summoning AltTab first —
// so resweeping on activation recovers the missing-since-launch window earlier than the on-summon
// resweep (PLAN-020 B1(a)), and maps directly onto the "missing since launch, restart fixes it" shape.
// We call Applications.refreshWindowsForDiscovery() (additive-only; skips removeZombieWindows) so this
// does NOT re-introduce the Safari-fullscreen case that the deleted manuallyUpdateAllAppsWindows() had
// (that case only returns if discovery is wired into the space-change handler, which we do not do here).
// Lives in SpacesEvents.swift (already in the build) rather than a new file, modeling the same observe()
// pattern. The throttle inside refreshWindowsForDiscovery() collapses an app-switch burst to one sweep.
class ApplicationActivationEvents {
    static func observe() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleEvent), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private static func handleEvent(_ notification: Notification) {
        guard let ra = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let app = (Applications.list.first { $0.pid == ra.processIdentifier }) else { return }
        Applications.refreshWindowsForDiscovery(app)
    }
}
