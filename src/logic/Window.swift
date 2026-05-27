import Cocoa

class Window {
    private static let notifications = [
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowResizedNotification,
        kAXWindowMovedNotification,
    ]
    private static var globalCreationCounter = Int.zero

    var id: String
    var cgWindowId: CGWindowID?
    var lastFocusOrder = Int.zero
    var creationOrder = Int.zero
    var title: String!
    var thumbnail: CALayerContents?
    var icon: CGImage? { get { application.icon } }
    var shouldShowTheUser = true
    var isTabbed: Bool = false
    var tabbedSiblingWids: [CGWindowID]?
    var isHidden: Bool { get { application.isHidden } }
    var dockLabel: String? { get { application.dockLabel } }
    var isFullscreen = false
    var isMinimized = false
    var isOnAllSpaces = false
    var isWindowlessApp: Bool { get { cgWindowId == nil } }
    var position: CGPoint?
    var size: CGSize?
    var spaceIds = [CGSSpaceID.max]
    var spaceIndexes = [SpaceIndex.max]
    // QL fork: Quick Look windows report being on ALL user spaces via CGSCopySpacesForWindows.
    // To keep them where they were opened (instead of following the user across spaces), we pin
    // their spaceIds at creation time and stop updating them in updateSpaces().
    var isQuickLookWindow = false
    private var hasPinnedQuickLookSpace = false
    // F14 v2 (PLAN-019): Spaces.refreshGeneration value at the last successful CGS
    // read for this window. The preserve branch in updateSpaces() only fires when
    // this matches the current refreshGeneration — closes Gap A by letting
    // visibleSpaces-fallback heal stale spaceIds across refresh boundaries.
    private var lastCGSSuccessGeneration: Int = -1
    var screenId: ScreenUuid?
    var axUiElement: AXUIElement?
    var application: Application
    var axObserver: AXObserver?
    var rowIndex: Int?
    var debugId: String!
    var lastSearchQuery: String?
    var swAppResults: [SWResult] = []
    var swTitleResults: [SWResult] = []
    var swBestSimilarity = 0.0

    init(_ axUiElement: AXUIElement, _ application: Application, _ wid: CGWindowID, _ title: String?, _ isFullscreen: Bool?, _ isMinimized: Bool?, _ position: CGPoint?, _ size: CGSize?) {
        id = "wid-\(wid)"
        self.axUiElement = axUiElement
        self.application = application
        cgWindowId = wid
        self.updateSpacesAndScreen()
        updateFromAxAttributes(title, size, position, isFullscreen, isMinimized)
        debugId = "\(self.application.debugId) (wid:\(cgWindowId) title:\(self.title))"
        Window.globalCreationCounter += 1
        creationOrder = Window.globalCreationCounter
        application.removeWindowlessAppWindow()
        // the app may have timed out trying to subscribe to app notifications
        // It may be responsive now since it has a window; we attempt again
        application.observeEventsIfEligible()
        // fetch app icon only if we display that app in the switcher
        application.fetchAppIcon()
        checkIfFocused()
        Logger.info { self.debugId }
        observeEvents()
    }

    init(_ application: Application) {
        id = "pid-\(application.pid)"
        self.application = application
        title = bestEffortTitle(nil)
        Window.globalCreationCounter += 1
        creationOrder = Window.globalCreationCounter
        debugId = "\(application.debugId) (title:\(title))"
        // fetch app icon only if we display that app in the switcher
        application.fetchAppIcon()
        Logger.debug { self.debugId }
    }

    deinit {
        Logger.info { self.debugId }
    }

    func updateFromAxAttributes(_ title: String?, _ size: CGSize?, _ position: CGPoint?, _ isFullscreen: Bool?, _ isMinimized: Bool?) {
        self.title = bestEffortTitle(title)
        self.size = size
        self.position = position
        self.isFullscreen = isFullscreen ?? false
        self.isMinimized = isMinimized ?? false
        lastSearchQuery = nil
    }

    func isEqualRobust(_ otherWindowAxUiElement: AXUIElement, _ otherWindowWid: CGWindowID?) -> Bool {
        // the window can be deallocated by the OS, in which case its `CGWindowID` will be `-1`
        // we check for equality both on the AXUIElement, and the CGWindowID, in order to catch all scenarios
        return otherWindowAxUiElement == axUiElement || (cgWindowId != nil && cgWindowId != CGWindowID(bitPattern: -1) && otherWindowWid == cgWindowId)
    }

    private func observeEvents() {
        AXObserverCreate(application.pid, AccessibilityEvents.axObserverCallback, &axObserver)
        guard let axObserver else { return }
        AXCallScheduler.shared.schedule(key: "sub-win-\(cgWindowId)", context: debugId, pid: application.pid) { [weak self] in
            guard let self else { return }
            if try self.axUiElement!.subscribeToNotification(axObserver, Window.notifications.first!) {
                Logger.debug { "Subscribed to window: \(self.debugId)" }
                for notification in Window.notifications.dropFirst() {
                    AXCallScheduler.shared.schedule(key: "sub-win-\(cgWindowId)-\(notification)", context: self.debugId, pid: self.application.pid) { [weak self] in
                        try self?.axUiElement!.subscribeToNotification(axObserver, notification)
                    }
                }
            }
        }
        CFRunLoopAddSource(BackgroundWork.accessibilityEventsThread.runLoop, AXObserverGetRunLoopSource(axObserver), .commonModes)
    }

    func refreshThumbnail(_ screenshot: CALayerContents) {
        thumbnail = screenshot
        if !App.appIsBeingUsed || !shouldShowTheUser { return }
        if let position, let size,
           let view = (TilesView.recycledViews.first { $0.window_?.cgWindowId == cgWindowId }) {
            if !view.thumbnail.isHidden {
                let thumbnailSize = TileView.thumbnailSize(size, false)
                let newSize = thumbnailSize.width != view.thumbnail.frame.width || thumbnailSize.height != view.thumbnail.frame.height
                view.thumbnail.updateContents(screenshot, thumbnailSize)
                // if the thumbnail size has changed, we need to refresh the open UI
                if newSize {
                    App.refreshOpenUiAfterExternalEvent([])
                }
            }
            PreviewPanel.updateIfShowing(cgWindowId, screenshot, position, size)
        }
    }

    func canBeClosed() -> Bool {
        return !isWindowlessApp
    }

    func close() {
        if !canBeClosed() {
            NSSound.beep()
            return
        }
        if let altTabWindow = altTabWindow() {
            altTabWindow.close()
            return
        }
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard let self else { return }
            if self.isFullscreen {
                try? self.axUiElement!.setAttribute(kAXFullscreenAttribute, false)
                // minimizing is ignored if sent immediatly; we wait for the de-fullscreen animation to be over
                BackgroundWork.accessibilityCommandsQueue.addOperationAfter(deadline: .now() + .seconds(1)) { [weak self] in
                    guard let self else { return }
                    if let closeButton_ = try? self.axUiElement!.attributes([kAXCloseButtonAttribute]).closeButton {
                        try? closeButton_.performAction(kAXPressAction)
                    }
                }
            } else {
                if let closeButton_ = try? self.axUiElement!.attributes([kAXCloseButtonAttribute]).closeButton  {
                    try? closeButton_.performAction(kAXPressAction)
                }
            }
        }
    }

    func canBeMinDeminOrFullscreened() -> Bool {
        return !isWindowlessApp && !isTabbed
    }

    func minDemin() {
        if !canBeMinDeminOrFullscreened() {
            NSSound.beep()
            return
        }
        if let altTabWindow = altTabWindow() {
            isMinimized ? altTabWindow.deminiaturize(nil) : altTabWindow.miniaturize(nil)
            return
        }
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard let self else { return }
            if self.isFullscreen {
                try? self.axUiElement!.setAttribute(kAXFullscreenAttribute, false)
                // minimizing is ignored if sent immediatly; we wait for the de-fullscreen animation to be over
                BackgroundWork.accessibilityCommandsQueue.addOperationAfter(deadline: .now() + .seconds(1)) { [weak self] in
                    guard let self else { return }
                    try? self.axUiElement!.setAttribute(kAXMinimizedAttribute, true)
                }
            } else {
                try? self.axUiElement!.setAttribute(kAXMinimizedAttribute, !self.isMinimized)
            }
        }
    }

    func toggleFullscreen() {
        if !canBeMinDeminOrFullscreened() {
            NSSound.beep()
            return
        }
        if let altTabWindow = altTabWindow() {
            altTabWindow.toggleFullScreen(nil)
            return
        }
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard let self else { return }
            try? self.axUiElement!.setAttribute(kAXFullscreenAttribute, !self.isFullscreen)
        }
    }

    func focus() {
        if let altTabWindow = altTabWindow() {
            App.shared.activate(ignoringOtherApps: true)
            altTabWindow.makeKeyAndOrderFront(nil)
            Windows.previewSelectedWindowIfNeeded()
        } else if isWindowlessApp || cgWindowId == nil || Preferences.onlyShowApplications() {
            if let bundleUrl = application.bundleURL, isWindowlessApp {
                if (try? NSWorkspace.shared.launchApplication(at: bundleUrl, configuration: [:])) == nil {
                    application.runningApplication.activate(options: .activateAllWindows)
                }
            } else {
                application.runningApplication.activate(options: .activateAllWindows)
            }
            Windows.previewSelectedWindowIfNeeded()
        } else {
            // macOS bug: when switching to a System Preferences window in another space, it switches to that space,
            // but quickly switches back to another window in that space
            // You can reproduce this buggy behaviour by clicking on the dock icon, proving it's an OS bug
            BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
                guard let self else { return }
                var psn = ProcessSerialNumber()
                GetProcessForPID(self.application.pid, &psn)
                _SLPSSetFrontProcessWithOptions(&psn, self.cgWindowId!, SLPSMode.userGenerated.rawValue)
                self.makeKeyWindow(&psn)
                try? self.axUiElement!.focusWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                    Windows.previewSelectedWindowIfNeeded()
                }
            }
        }
    }

    /// The following function was ported from https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
    private func makeKeyWindow(_ psn: inout ProcessSerialNumber) -> Void {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        memcpy(&bytes[0x3c], &cgWindowId, MemoryLayout<UInt32>.size)
        memset(&bytes[0x20], 0xff, 0x10)
        bytes[0x08] = 0x01
        SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        SLPSPostEventRecordTo(&psn, &bytes)
    }

    // for some windows (e.g. Slack), the AX API doesn't return a title; we try CG API; finally we resort to the app name
    func bestEffortTitle(_ axTitle: String?) -> String {
        if let axTitle, !axTitle.isEmpty {
            return axTitle
        }
        if let cgWindowId, let cgTitle = cgWindowId.title(), !cgTitle.isEmpty {
            return cgTitle
        }
        return application.localizedName ?? ""
    }

    func updateSpacesAndScreen() {
        // macOS bug: if you tab a window, then move the tab group to another space, other tabs from the tab group will stay on the current space
        // you can use the Dock to focus one of the other tabs and it will teleport that tab in the current space, proving that it's a macOS bug
        // note: for some reason, it behaves differently if you minimize the tab group after moving it to another space
        updateSpaces()
        updateScreenId()
    }

    private func updateSpaces() {
        guard let cgWindowId else { return }
        var spaceIds = cgWindowId.spaces()
        let cgsReturnedNonEmpty = !spaceIds.isEmpty
        var usedSyntheticValue = false
        // inactive tabs return no space from CGSCopySpacesForWindows; use the active tab sibling's space
        if spaceIds.isEmpty, let activeTab = TabGroup.activeTabSibling(of: self) {
            spaceIds = activeTab.spaceIds
        }
        // F14 v2 Gap B (PLAN-019): CGS can return a STALE non-empty value during a space
        // transition (upstream #689/#1254/#3792 — acknowledged macOS WindowServer behavior,
        // ~300-600ms window). If CGS returned non-empty but its spaceIds don't intersect
        // visibleSpaces AND a space change just happened AND CG considers the window
        // on-screen, CGS is lying — trust on-screen-ness and fall back to currentSpaceId.
        // Must run BEFORE the empty-handler so the synthesized value isn't treated as empty.
        if !spaceIds.isEmpty
            && !Spaces.visibleSpaces.contains(where: { vs in spaceIds.contains(vs) })
            && Window.recentSpaceChangeWithinMs(500)
            && Window.windowIsOnScreenViaCG(cgWindowId) {
            spaceIds = [Spaces.currentSpaceId]
            usedSyntheticValue = true
        }
        // Fallback for apps without AXTabGroup (e.g. Safari uses HTML tabs, not native AXTabGroup)
        // when CGSCopySpacesForWindows transiently returns empty. Without this, the window's
        // spaceIds remains [] and Windows.refreshIfWindowShouldBeShownToTheUser drops it at the
        // visible-spaces filter, causing intermittent missing-from-switcher symptom.
        if spaceIds.isEmpty {
            // F14 v2 Gap A (PLAN-019): preserve self.spaceIds only if it was recorded in
            // the current Spaces.refreshGeneration. Across refresh boundaries (e.g. the
            // user moved the window between spaces via Mission Control with no AX event),
            // open the preserve gate so visibleSpaces-fallback can heal stale state.
            if lastCGSSuccessGeneration == Spaces.refreshGeneration
                && !self.spaceIds.isEmpty
                && self.spaceIds != [CGSSpaceID.max] {
                return
            }
            // First-ever update (sentinel) or new generation: clamp to currentSpaceId so the window
            // isn't dropped. [currentSpaceId] (not visibleSpaces) avoids a false isOnAllSpaces on
            // multi-display, where visibleSpaces has >1 id and would mis-flag a single-space window.
            spaceIds = [Spaces.currentSpaceId]
            usedSyntheticValue = true
        }
        // QL fork: Quick Look windows are reported on all user spaces by CGS. Pin them to the
        // space they were opened on at first observation; after that, never overwrite.
        if isQuickLookWindow {
            if hasPinnedQuickLookSpace {
                // Already pinned: keep existing spaceIds untouched on subsequent updates.
                return
            }
            spaceIds = [Spaces.currentSpaceId]
            hasPinnedQuickLookSpace = true
            usedSyntheticValue = true
        }
        // Tag this write with the refresh generation only for a real CGS read — lets Gap A tell
        // "still valid in same generation" from "stale, generation advanced." Synthetic writes
        // (tiebreaker / fallback / QL pin) set usedSyntheticValue and must not update the tag.
        if cgsReturnedNonEmpty && !usedSyntheticValue {
            lastCGSSuccessGeneration = Spaces.refreshGeneration
        }
        self.spaceIds = spaceIds
        self.spaceIndexes = spaceIds.compactMap { spaceId in Spaces.idsAndIndexes.first { $0.0 == spaceId }?.1 }
        self.isOnAllSpaces = spaceIds.count > 1
    }

    // F14 v2 (PLAN-019): true if an activeSpaceDidChange notification fired within the
    // last `ms` milliseconds. Used to gate the Gap B tiebreaker so the more-expensive
    // CGWindowListCopyWindowInfo IPC only fires during a known transition window.
    private static func recentSpaceChangeWithinMs(_ ms: Int) -> Bool {
        guard let t = SpacesEvents.lastChangeAt else { return false }
        return Date().timeIntervalSince(t) * 1000 < Double(ms)
    }

    // F14 v2 (PLAN-019): Gap B tiebreaker — true if WindowServer reports the wid on-screen (CGS then
    // lying about a non-visible space). updateSpaces() runs on the main thread once per window per pass,
    // so a per-wid IPC fanned out to N synchronous round-trips during a transition. Snapshot all
    // on-screen wids in ONE IPC, memoized per (refreshGeneration, lastChangeAt): a summon pass shares
    // one round-trip and a new space change re-snapshots.
    private static var onScreenWidsCache = Set<CGWindowID>()
    private static var onScreenWidsCacheGeneration = -1
    private static var onScreenWidsCacheChangeAt: Date?
    private static func windowIsOnScreenViaCG(_ wid: CGWindowID) -> Bool {
        if onScreenWidsCacheGeneration != Spaces.refreshGeneration || onScreenWidsCacheChangeAt != SpacesEvents.lastChangeAt {
            onScreenWidsCache = Set(CGWindow.windows(.optionOnScreenOnly).compactMap { $0.id() })
            onScreenWidsCacheGeneration = Spaces.refreshGeneration
            onScreenWidsCacheChangeAt = SpacesEvents.lastChangeAt
        }
        return onScreenWidsCache.contains(wid)
    }

    private func updateScreenId() {
        screenId = NSScreen.screens.first { isOnScreen($0) }?.cachedUuid()
    }

    /// window may not be visible on that screen (e.g. the window is not on the current Space)
    func isOnScreen(_ screen: NSScreen) -> Bool {
        if NSScreen.screensHaveSeparateSpaces {
            if let screenUuid = screen.cachedUuid(), let screenSpaces = Spaces.screenSpacesMap[screenUuid] {
                return screenSpaces.contains { screenSpace in spaceIds.contains { $0 == screenSpace } }
            }
        } else {
            let referenceWindow = referenceWindowForTabbedWindow()
            if let topLeftCorner = referenceWindow?.position, let size = referenceWindow?.size {
                var screenFrameInQuartzCoordinates = screen.frame
                screenFrameInQuartzCoordinates.origin.y = NSMaxY(NSScreen.screens[0].frame) - NSMaxY(screen.frame)
                let windowRect = CGRect(origin: topLeftCorner, size: size)
                return windowRect.intersects(screenFrameInQuartzCoordinates)
            }
        }
        return true
    }

    func referenceWindowForTabbedWindow() -> Window? {
        // if the window is tabbed, we can't know its position/size before it's focused, so we use the currently
        // visible window-tab. Its data will match the tabbed window's
        // fallback to the focusedWindow
        isTabbed ? (TabGroup.activeTabSibling(of: self) ?? application.focusedWindow) : self
    }

    // Determines if this window is the main application window
    func isAppMainWindow() -> Bool {
        // AX calls done on main thread. They can block thus freeze the UI
        // TODO: find a better approach
        guard let appAxUiElement = application.axUiElement,
              let mainWindow = try? appAxUiElement.attributes([kAXMainWindowAttribute]).mainWindow else { return false }
        return (try? mainWindow.cgWindowId()) == cgWindowId
    }

    private func altTabWindow() -> NSWindow? {
        if application.bundleURL == App.bundleURL, let cgWindowId {
            return App.shared.window(withWindowNumber: Int(cgWindowId))
        }
        return nil
    }

    /// Scenarios addressed by this:
    /// * Some apps will not trigger AXApplicationActivated, where we usually update application.focusedWindow
    /// * Sometimes, we subscribe to an app after it has emitted the focusedWindow / applicationActivated events, so we never receive these
    private func checkIfFocused() {
        let app = application
        guard let appAxUiElement = app.axUiElement else { return }
        AXCallScheduler.shared.schedule(key: "wid-\(cgWindowId)-focus", context: debugId, pid: app.pid) { [weak app] in
            guard let app, let focusedWindow = try appAxUiElement.attributes([kAXFocusedWindowAttribute]).focusedWindow else { return }
            let focusedWid = try focusedWindow.cgWindowId()
            DispatchQueue.main.async {
                guard let window = (Windows.list.first { $0.isEqualRobust(focusedWindow, focusedWid) }) else { return }
                app.focusedWindow = window
                if let windows = Windows.updateLastFocusOrder(window) {
                    App.refreshOpenUiAfterExternalEvent(windows)
                }
            }
        }
    }
}
