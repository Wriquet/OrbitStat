import AppKit
import Combine
import SwiftUI

@main
public struct OrbitStatApp {
    public static func main() {
        let options = LaunchOptions.parse(arguments: CommandLine.arguments)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        if let snapshotDir = options.snapshotDirectory {
            let runner = SnapshotRunner(
                outputDirectory: snapshotDir,
                sampleCount: options.sampleCount
            )
            app.delegate = runner
            app.run()
            return
        }

        let delegate = OrbitStatAppDelegate()
        app.delegate = delegate
        app.run()
    }
}

// MARK: - CLI Launch Options

struct LaunchOptions {
    let snapshotDirectory: String?
    let sampleCount: Int

    static func parse(arguments: [String]) -> LaunchOptions {
        var snapshotDir: String?
        var sampleCount = 12

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--snapshot-dir":
                if i + 1 < arguments.count {
                    snapshotDir = arguments[i + 1]
                    i += 1
                }
            case "--samples":
                if i + 1 < arguments.count, let parsed = Int(arguments[i + 1]), parsed > 0 {
                    sampleCount = min(60, parsed)
                    i += 1
                }
            default:
                break
            }
            i += 1
        }

        return LaunchOptions(
            snapshotDirectory: snapshotDir,
            sampleCount: sampleCount
        )
    }
}

// MARK: - Shell-less Floating Non-Activating Liquid Glass Panel

/// Transparent root container around the floating Control Center column so individual
/// `.glassEffect` tiles float directly over the desktop with zero outer container box
/// while their native glass shadows bloom smoothly into transparent padding.
final class FloatingGlassRootView: NSView {
    var interactiveColumnRect: NSRect

    init(frame: NSRect, interactiveColumnRect: NSRect) {
        self.interactiveColumnRect = interactiveColumnRect
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveColumnRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

final class FloatingGlassPanel: NSPanel {
    /// Generous transparent halo around the official `.regular` Liquid Glass shell so the
    /// dual-layer floating drop shadow (`radius: 22, y: 10`) fades smoothly to 0% alpha well
    /// before the window boundary — zero clipped shadow edges and zero square corner artifacts.
    static let shadowPadding: CGFloat = 44

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Allow the transparent `shadowPadding` halo to extend smoothly into screen margins
    /// (such as behind the menu bar) so AppKit does not push the anchored floating islands downward.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Screen-space frame of the visible floating island column (excluding transparent shadow padding).
    var visibleCardFrame: NSRect {
        frame.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)
    }

    init(cardScreenFrame: NSRect) {
        let paddedFrame = cardScreenFrame.insetBy(dx: -Self.shadowPadding, dy: -Self.shadowPadding)
        super.init(
            contentRect: paddedFrame,
            // Omit `.nonactivatingPanel` so macOS 26/27 always renders SwiftUI `.glassEffect(.clear)`
            // in active, optical-lensing state (never degrading to an inactive opaque `#2E3033` slab).
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // Disable NSPanel's rectangular WindowServer shadow; every independent SwiftUI
        // `.glassEffect` shell, tile & capsule casts its own authentic rounded floating shadow.
        hasShadow = false
        becomesKeyOnlyIfNeeded = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
}

// MARK: - Menu Bar Application Delegate

@MainActor
final class OrbitStatAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: FloatingGlassPanel?
    private var hostingView: NSView?
    private var store: MonitorStore?
    private var cancellables: Set<AnyCancellable> = []
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var isPanelVisible = false
    private var panelOpenedAt: Date?
    private var hasActivatedSinceOpen = false
    private var animationToken: UInt64 = 0

    /// Activates our LSUIElement accessory app immediately even when another app is frontmost.
    /// Verified empirically on macOS 27.3: cooperative `NSApp.activate()` is ignored while another
    /// app is frontmost, leaving `.glassEffect(.clear)` in an inactive opaque gray slab until clicked,
    /// whereas `NSRunningApplication.current.activate(options:)` with `activateAllWindows | bit 1`
    /// immediately achieves `isActive = true`, `isKeyWindow = true`, `isMainWindow = true` on frame 1.
    static func activateForPanel() {
        let options = NSApplication.ActivationOptions(
            rawValue: NSApplication.ActivationOptions.activateAllWindows.rawValue | (1 << 1)
        )
        NSRunningApplication.current.activate(options: options)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = MonitorStore()
        self.store = store

        setupStatusItem()
        // Panel and NSHostingView are created lazily in showPanel() and released in
        // tearDownPanel() so idle memory/GPU footprint stays ~14–16 MB and 0% CPU.
        bindMenuBarUpdates(to: store)

        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEventMonitors()
        tearDownPanel()
        store?.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard isPanelVisible, let panel else { return }
        hasActivatedSinceOpen = true
        panel.makeKeyAndOrderFront(nil)
        panel.makeMain()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Dismiss immediately when switching to another app (Cmd+Tab or clicking outside)
        // so the glass panel never lingers on screen in an inactive gray degraded state,
        // while guarding the initial 0.25s activation handoff window on open.
        guard isPanelVisible else { return }
        let elapsed = Date().timeIntervalSince(panelOpenedAt ?? .distantPast)
        guard hasActivatedSinceOpen || elapsed > 0.25 else { return }
        hidePanel()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = MenuBarIconFactory.makeNativeStatusBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "OrbitStat"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item
    }

    private func setupFloatingPanel(with store: MonitorStore, cardScreenFrame: NSRect) {
        let cardSize = cardScreenFrame.size
        let panel = FloatingGlassPanel(cardScreenFrame: cardScreenFrame)
        let (rootView, host) = Self.makeTransparentPanelContent(
            store: store,
            cardSize: cardSize,
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
        self.hostingView = host
        panel.contentView = rootView
        self.panel = panel
    }

    /// Hosts `RootPopoverView` directly inside a transparent `FloatingGlassRootView`
    /// so `RootPopoverView`'s official SwiftUI `.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 24))`
    /// outer frame refracts the live desktop crystal-clearly (zero muddy gray backdrop)
    /// while all inner `.glassEffect(.regular, ...)` tiles & capsules remain razor-sharp.
    static func makeTransparentPanelContent(
        store: MonitorStore,
        cardSize: NSSize,
        appearance: NSAppearance? = nil,
        colorSchemeOverride: ColorScheme? = nil,
        scrollToBottomForSnapshot: Bool = false,
        onQuit: @escaping () -> Void
    ) -> (NSView, NSView) {
        let pad = FloatingGlassPanel.shadowPadding
        let totalSize = NSSize(width: cardSize.width + pad * 2, height: cardSize.height + pad * 2)
        let interactiveRect = NSRect(x: pad, y: pad, width: cardSize.width, height: cardSize.height)

        let root = FloatingGlassRootView(
            frame: NSRect(origin: .zero, size: totalSize),
            interactiveColumnRect: interactiveRect
        )
        root.autoresizingMask = [.width, .height]

        let paddedRoot = RootPopoverView(
            store: store,
            panelHeight: cardSize.height,
            scrollToBottomForSnapshot: scrollToBottomForSnapshot,
            onQuit: onQuit
        )
        .padding(pad)
        .frame(width: totalSize.width, height: totalSize.height)
        .background(Color.clear)

        let host: NSView
        if let colorSchemeOverride {
            host = NSHostingView(rootView: paddedRoot.environment(\.colorScheme, colorSchemeOverride))
        } else {
            host = NSHostingView(rootView: paddedRoot)
        }
        host.appearance = appearance
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(host)

        return (root, host)
    }

    private func bindMenuBarUpdates(to store: MonitorStore) {
        Publishers.CombineLatest3(
            store.$systemSnapshot,
            store.$powerSnapshot,
            store.$settings
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak store] _, _, _ in
            guard let self, let store else { return }
            self.updateStatusItemDisplay(text: store.menuBarText)
        }
        .store(in: &cancellables)
    }

    private func updateStatusItemDisplay(text: String?) {
        guard let button = statusItem?.button else { return }
        if let text, !text.isEmpty {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .baselineOffset: 0.5
            ]
            button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // MARK: - Interaction

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePanel()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if isPanelVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let store else { return }

        animationToken &+= 1
        let token = animationToken
        isPanelVisible = true
        panelOpenedAt = Date()
        hasActivatedSinceOpen = NSApp.isActive

        // Panel geometry is fixed once on open (364 × 600 clamped to visible screen height)
        // and never resized dynamically during tab switches or settings toggles.
        let cardFrame = computeFixedAnchoredCardFrame()
        if panel == nil {
            setupFloatingPanel(with: store, cardScreenFrame: cardFrame)
        }
        guard let panel else { return }

        let targetFrame = cardFrame.insetBy(
            dx: -FloatingGlassPanel.shadowPadding,
            dy: -FloatingGlassPanel.shadowPadding
        )
        let startFrame = NSRect(
            x: targetFrame.origin.x,
            y: targetFrame.origin.y + 6,
            width: targetFrame.width,
            height: targetFrame.height
        )

        // Keep window alphaValue at 1.0 before makeKeyAndOrderFront so AppKit immediately grants
        // key + main status on frame 1 (animating layer opacity instead of window alphaValue).
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 1.0
        Self.activateForPanel()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeMain()
        startEventMonitors()

        if let contentLayer = panel.contentView?.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = Float(0.0)
            fade.toValue = Float(1.0)
            fade.duration = 0.14
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentLayer.opacity = 1.0
            contentLayer.add(fade, forKey: "orbitstat.panelFadeIn")
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }

        // Re-assert key + main status on the next runloop tick in case NSStatusBarWindow's
        // mouseUp completion momentarily reclaimed focus after the menu bar click.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPanelVisible, self.animationToken == token, let panel = self.panel else { return }
            Self.activateForPanel()
            panel.makeKeyAndOrderFront(nil)
            panel.makeMain()
            if NSApp.isActive {
                self.hasActivatedSinceOpen = true
            }
        }

        Task { await store.refreshNow() }
    }

    private func hidePanel(animated: Bool = true) {
        guard let panel, isPanelVisible else { return }

        isPanelVisible = false
        stopEventMonitors()
        animationToken &+= 1
        let token = animationToken

        guard animated else {
            tearDownPanel()
            return
        }

        let endFrame = NSRect(
            x: panel.frame.origin.x,
            y: panel.frame.origin.y + 4,
            width: panel.frame.width,
            height: panel.frame.height
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
            panel.animator().setFrame(endFrame, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.animationToken == token, !self.isPanelVisible else { return }
                self.tearDownPanel()
            }
        })
    }

    private func tearDownPanel() {
        if let panel {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        hostingView = nil
        panel = nil
        panelOpenedAt = nil
        hasActivatedSinceOpen = false
        store?.isShowingSettings = false
    }

    private func computeFixedAnchoredCardFrame() -> NSRect {
        let width = RootPopoverView.popoverWidth
        let buttonScreenRect = statusItemButtonScreenRect()
        let screen = screenFor(rect: buttonScreenRect) ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let fixedHeight = min(
            RootPopoverView.fixedPanelHeight,
            max(360, floor(visibleFrame.height - 24))
        )

        let horizontalMargin: CGFloat = 8
        let idealX: CGFloat
        let topY: CGFloat
        if let buttonScreenRect {
            idealX = buttonScreenRect.midX - (width / 2.0)
            topY = min(buttonScreenRect.minY, visibleFrame.maxY) - 6
        } else {
            idealX = visibleFrame.maxX - width - horizontalMargin
            topY = visibleFrame.maxY - 6
        }

        let minX = visibleFrame.minX + horizontalMargin
        let maxX = max(minX, visibleFrame.maxX - width - horizontalMargin)
        let clampedX = min(maxX, max(minX, round(idealX)))
        let clampedY = max(visibleFrame.minY + 8, round(topY - fixedHeight))

        return NSRect(x: clampedX, y: clampedY, width: width, height: fixedHeight)
    }

    private func statusItemButtonScreenRect() -> NSRect? {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return nil }
        let rectInWindow = button.convert(button.bounds, to: nil)
        return buttonWindow.convertToScreen(rectInWindow)
    }

    private func screenFor(rect: NSRect?) -> NSScreen? {
        guard let rect else { return nil }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) })
    }

    private func showContextMenu() {
        hidePanel(animated: false)
        let menu = NSMenu()
        menu.addItem(withTitle: "打开 OrbitStat", action: #selector(openPanelFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 OrbitStat", action: #selector(quitFromMenu), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openPanelFromMenu() {
        showPanel()
    }

    @objc private func openSettingsFromMenu() {
        if !isPanelVisible {
            showPanel()
        }
        store?.isShowingSettings = true
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Outside-Click & Escape Dismissal

    private func startEventMonitors() {
        stopEventMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let mouseLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleOutsideMouseDown(at: mouseLocation)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event } // Escape
            if self.store?.isShowingSettings == true {
                self.store?.isShowingSettings = false
                return nil
            }
            self.hidePanel()
            return nil
        }
    }

    private func handleOutsideMouseDown(at screenPoint: NSPoint) {
        if let buttonRect = statusItemButtonScreenRect(), buttonRect.contains(screenPoint) {
            return
        }
        if let panel, panel.visibleCardFrame.contains(screenPoint) {
            return
        }
        for window in NSApp.windows where window.isVisible && window !== panel {
            if window.frame.contains(screenPoint) {
                return
            }
        }
        hidePanel()
    }

    private func stopEventMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
}

// MARK: - Native macOS SF Symbol Menu Bar Template Icon

enum MenuBarIconFactory {
    static func makeNativeStatusBarIcon() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let base = NSImage(
            systemSymbolName: "gauge.with.dots.needle.33percent",
            accessibilityDescription: "OrbitStat"
        ) ?? NSImage(
            systemSymbolName: "gauge.medium",
            accessibilityDescription: "OrbitStat"
        )
        let configured = base?.withSymbolConfiguration(config) ?? base
        configured?.isTemplate = true
        return configured
    }
}

// MARK: - Snapshot Backdrops (Tahoe Light/Dark + Real Dark/Light Desktop App Windows)

private enum SnapshotBackdropStyle {
    case tahoeLight
    case tahoeDark
    case darkCodeWindow
    case lightAppWindow

    var isDark: Bool {
        self == .tahoeDark || self == .darkCodeWindow
    }
}

private struct SnapshotBackdropView: View {
    let style: SnapshotBackdropStyle

    var body: some View {
        switch style {
        case .tahoeLight:
            tahoeLightBackdrop
        case .tahoeDark:
            tahoeDarkBackdrop
        case .darkCodeWindow:
            darkCodeWindowBackdrop
        case .lightAppWindow:
            lightAppWindowBackdrop
        }
    }

    private var tahoeLightBackdrop: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.49, green: 0.76, blue: 0.98), location: 0.0),
                    .init(color: Color(red: 0.61, green: 0.84, blue: 0.95), location: 0.34),
                    .init(color: Color(red: 0.75, green: 0.78, blue: 0.97), location: 0.70),
                    .init(color: Color(red: 0.88, green: 0.78, blue: 0.92), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.14, green: 0.56, blue: 0.96).opacity(0.70),
                            Color(red: 0.18, green: 0.78, blue: 0.88).opacity(0.36),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 12,
                        endRadius: 230
                    )
                )
                .frame(width: 440, height: 330)
                .offset(x: -95, y: -180)
                .blur(radius: 26)

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.18, green: 0.84, blue: 0.74).opacity(0.65),
                            Color(red: 0.34, green: 0.70, blue: 0.96).opacity(0.30),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 12,
                        endRadius: 230
                    )
                )
                .frame(width: 430, height: 350)
                .offset(x: 115, y: 0)
                .blur(radius: 28)

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.64, green: 0.50, blue: 0.96).opacity(0.62),
                            Color(red: 0.96, green: 0.62, blue: 0.78).opacity(0.32),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 12,
                        endRadius: 230
                    )
                )
                .frame(width: 440, height: 340)
                .offset(x: -85, y: 190)
                .blur(radius: 30)
        }
    }

    private var tahoeDarkBackdrop: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.04, green: 0.07, blue: 0.17), location: 0.0),
                    .init(color: Color(red: 0.07, green: 0.13, blue: 0.28), location: 0.42),
                    .init(color: Color(red: 0.12, green: 0.10, blue: 0.27), location: 0.78),
                    .init(color: Color(red: 0.05, green: 0.09, blue: 0.18), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.06, green: 0.72, blue: 0.86).opacity(0.68),
                            Color(red: 0.11, green: 0.36, blue: 0.85).opacity(0.32),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 230
                    )
                )
                .frame(width: 440, height: 340)
                .offset(x: -90, y: -180)
                .blur(radius: 30)

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.62, green: 0.26, blue: 0.92).opacity(0.62),
                            Color(red: 0.90, green: 0.28, blue: 0.62).opacity(0.28),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 240
                    )
                )
                .frame(width: 440, height: 360)
                .offset(x: 110, y: 20)
                .blur(radius: 34)

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.08, green: 0.76, blue: 0.56).opacity(0.55),
                            Color(red: 0.06, green: 0.45, blue: 0.66).opacity(0.25),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 210
                    )
                )
                .frame(width: 400, height: 300)
                .offset(x: -75, y: 200)
                .blur(radius: 32)
        }
    }

    /// Simulates a dark macOS IDE/editor window behind the floating glass islands so transparent
    /// inter-tile gaps and real behind-window refraction are unmistakably visible.
    private var darkCodeWindowBackdrop: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.075, green: 0.082, blue: 0.098)

            VStack(alignment: .leading, spacing: 11) {
                ForEach(0..<28, id: \.self) { line in
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", line + 1))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.25))

                        Text(codeSnippet(for: line))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(codeColor(for: line))
                            .lineLimit(1)
                    }
                }
            }
            .padding(14)
        }
    }

    private var lightAppWindowBackdrop: some View {
        ZStack(alignment: .topLeading) {
            // Warm cream desktop window surface (matching modern light workspace windows)
            Color(red: 0.962, green: 0.950, blue: 0.922)

            VStack(alignment: .leading, spacing: 11) {
                ForEach(0..<30, id: \.self) { line in
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", line + 1))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.24))

                        Text(codeSnippet(for: line))
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(lightCodeColor(for: line))
                            .lineLimit(1)
                    }
                }
            }
            .padding(16)
        }
    }

    private func codeSnippet(for line: Int) -> String {
        let lines = [
            "import AppKit // OrbitStat macOS Tahoe Liquid Glass",
            "final class FloatingGlassPanel: NSPanel {",
            "    isOpaque = false; backgroundColor = .clear",
            "    // 系统监控 · CPU / 温度 / 内存 / 电池 / 系统功耗",
            "    let snapshot = await systemMonitor.sample()",
            "    GlassTile(cornerRadius: 20) { PowerTabView() }",
            "    NativeGlassCapsulePill(text: \"已运行\", height: 28)"
        ]
        return lines[line % lines.count]
    }

    private func codeColor(for line: Int) -> Color {
        switch line % 4 {
        case 0: return Color(red: 0.40, green: 0.78, blue: 1.0).opacity(0.85)
        case 1: return Color(red: 0.98, green: 0.65, blue: 0.35).opacity(0.85)
        case 2: return Color(red: 0.45, green: 0.90, blue: 0.62).opacity(0.82)
        default: return Color.white.opacity(0.75)
        }
    }

    private func lightCodeColor(for line: Int) -> Color {
        switch line % 4 {
        case 0: return Color(red: 0.05, green: 0.42, blue: 0.88).opacity(0.78)
        case 1: return Color(red: 0.78, green: 0.38, blue: 0.08).opacity(0.78)
        case 2: return Color(red: 0.08, green: 0.56, blue: 0.32).opacity(0.78)
        default: return Color.black.opacity(0.65)
        }
    }
}

// MARK: - Live Liquid Glass Snapshot Renderer (--snapshot-dir)

@MainActor
final class SnapshotRunner: NSObject, NSApplicationDelegate {
    private let outputDirectory: String
    private let sampleCount: Int
    private var activeWindow: NSWindow?

    init(outputDirectory: String, sampleCount: Int) {
        self.outputDirectory = outputDirectory
        self.sampleCount = sampleCount
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await runSnapshots()
            NSApplication.shared.terminate(nil)
        }
    }

    private func runSnapshots() async {
        let outURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        } catch {
            fputs("OrbitStat snapshot error: failed to create output dir: \(error)\n", stderr)
            exit(1)
        }

        let store = MonitorStore()
        await store.warmUpAndSample(count: sampleCount, delaySeconds: 0.2)

        let systemPNG = outURL.appendingPathComponent("system.png")
        let systemCollapsedPNG = outURL.appendingPathComponent("system_collapsed.png")
        let powerPNG = outURL.appendingPathComponent("power.png")
        let settingsPNG = outURL.appendingPathComponent("settings.png")
        let systemDarkPNG = outURL.appendingPathComponent("system_dark.png")
        let powerDarkPNG = outURL.appendingPathComponent("power_dark.png")
        let liveDarkPNG = outURL.appendingPathComponent("live_dark.png")
        let liveDarkScrolledPNG = outURL.appendingPathComponent("live_dark_scrolled.png")
        let liveLightPNG = outURL.appendingPathComponent("live_light.png")

        // 1. Light Tahoe window: exercise real live state transitions
        //    System -> Power -> Settings -> System (expanded) -> System (Memory collapsed)
        let (lightWin, lightHost, lightSize) = makeBackdropSnapshotWindow(store: store, style: .tahoeLight)

        store.isShowingSettings = false
        store.isMemoryExpanded = true
        store.selectedTab = .system
        await settleWindow(lightWin, hostingView: lightHost)

        store.selectedTab = .power
        await settleWindow(lightWin, hostingView: lightHost)
        let powerOK = captureWindow(lightWin, hostingView: lightHost, size: lightSize, to: powerPNG)

        store.isShowingSettings = true
        await settleWindow(lightWin, hostingView: lightHost)
        let settingsOK = captureWindow(lightWin, hostingView: lightHost, size: lightSize, to: settingsPNG)

        store.isShowingSettings = false
        store.selectedTab = .system
        store.isMemoryExpanded = true
        await settleWindow(lightWin, hostingView: lightHost)
        let systemOK = captureWindow(lightWin, hostingView: lightHost, size: lightSize, to: systemPNG)

        store.isMemoryExpanded = false
        await settleWindow(lightWin, hostingView: lightHost)
        let systemCollapsedOK = captureWindow(lightWin, hostingView: lightHost, size: lightSize, to: systemCollapsedPNG)

        closeSnapshotWindow(lightWin)

        // 2. Dark Tahoe Aurora window: System -> Power inside SAME fixed 600pt live host
        store.isMemoryExpanded = true
        let (darkWin, darkHost, darkSize) = makeBackdropSnapshotWindow(store: store, style: .tahoeDark)

        store.isShowingSettings = false
        store.selectedTab = .system
        await settleWindow(darkWin, hostingView: darkHost)
        let systemDarkOK = captureWindow(darkWin, hostingView: darkHost, size: darkSize, to: systemDarkPNG)

        store.selectedTab = .power
        await settleWindow(darkWin, hostingView: darkHost)
        let powerDarkOK = captureWindow(darkWin, hostingView: darkHost, size: darkSize, to: powerDarkPNG)

        closeSnapshotWindow(darkWin)

        // 3. REAL live transparent FloatingGlassPanel over dark code window (unscrolled + scrolled)
        //    and light window — verifies crystal-clear official `.clear` outer glass border,
        //    zero muddy gray fill, smooth scroll fade mask, zero square corners, & 28pt capsules!
        store.isShowingSettings = false
        store.isMemoryExpanded = true
        store.selectedTab = .system
        let liveDarkOK = await captureLiveFloatingPanel(
            store: store,
            style: .darkCodeWindow,
            scrollToBottom: false,
            to: liveDarkPNG
        )
        let liveDarkScrolledOK = await captureLiveFloatingPanel(
            store: store,
            style: .darkCodeWindow,
            scrollToBottom: true,
            to: liveDarkScrolledPNG
        )
        let liveLightOK = await captureLiveFloatingPanel(
            store: store,
            style: .lightAppWindow,
            scrollToBottom: false,
            to: liveLightPNG
        )

        if let sys = store.systemSnapshot {
            let tempStr = MetricsFormatter.formatTemperature(sys.cpuTemperatureCelsius)
            let cpuStr = MetricsFormatter.formatPercent(sys.cpuTotalUsage)
            let memStr = "\(MetricsFormatter.formatBytes(sys.memoryUsedBytes)) / \(MetricsFormatter.formatTotalMemory(sys.memoryTotalBytes))"
            print("SYSTEM: temp=\(tempStr) cpu=\(cpuStr) mem=\(memStr) pressure=\(sys.memoryPressure.rawValue) apps=\(sys.topMemoryApps.count) uptime=\(MetricsFormatter.formatUptime(sys.uptimeSeconds))")
        }
        if let pwr = store.powerSnapshot {
            let battStr = MetricsFormatter.formatPercent(pwr.batteryPercent)
            let tempStr = MetricsFormatter.formatTemperature(pwr.batteryTemperatureCelsius)
            let sysW = MetricsFormatter.formatWatts(pwr.systemPowerWatts)
            let adMax = MetricsFormatter.formatWholeWatts(pwr.adapterMaxWatts)
            let adIn = MetricsFormatter.formatWatts(pwr.adapterInputWatts)
            let health = MetricsFormatter.formatPercent(pwr.batteryHealthPercent)
            let cycles = pwr.cycleCount.map(String.init) ?? "--"
            print("POWER: battery=\(battStr) temp=\(tempStr) sysPower=\(sysW) adapter=\(adIn)/\(adMax) health=\(health) cycles=\(cycles)")
        }
        print(
            "SNAPSHOTS: system=\(systemOK ? systemPNG.path : "FAILED") " +
            "system_collapsed=\(systemCollapsedOK ? systemCollapsedPNG.path : "FAILED") " +
            "power=\(powerOK ? powerPNG.path : "FAILED") " +
            "system_dark=\(systemDarkOK ? systemDarkPNG.path : "FAILED") " +
            "power_dark=\(powerDarkOK ? powerDarkPNG.path : "FAILED") " +
            "settings=\(settingsOK ? settingsPNG.path : "FAILED") " +
            "live_dark=\(liveDarkOK ? liveDarkPNG.path : "FAILED") " +
            "live_dark_scrolled=\(liveDarkScrolledOK ? liveDarkScrolledPNG.path : "FAILED") " +
            "live_light=\(liveLightOK ? liveLightPNG.path : "FAILED")"
        )

        if !(systemOK && systemCollapsedOK && powerOK && systemDarkOK && powerDarkOK && settingsOK && liveDarkOK && liveDarkScrolledOK && liveLightOK) {
            exit(1)
        }
    }

    private func makeBackdropSnapshotWindow(
        store: MonitorStore,
        style: SnapshotBackdropStyle
    ) -> (NSWindow, NSView, NSSize) {
        let appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
        let backdropMargin: CGFloat = 44
        let panelHeight = RootPopoverView.fixedPanelHeight
        let totalSize = NSSize(
            width: RootPopoverView.popoverWidth + backdropMargin * 2,
            height: panelHeight + backdropMargin * 2
        )

        let composed = ZStack {
            SnapshotBackdropView(style: style)

            RootPopoverView(
                store: store,
                panelHeight: panelHeight,
                onQuit: {}
            )
        }
        .frame(width: totalSize.width, height: totalSize.height)
        .clipped()
        .environment(\.colorScheme, style.isDark ? .dark : .light)

        let hostingView = NSHostingView(rootView: composed)
        hostingView.appearance = appearance
        hostingView.frame = NSRect(origin: .zero, size: totalSize)

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: totalSize.width, height: totalSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .clear
        window.hasShadow = false
        window.appearance = appearance
        window.contentView = hostingView
        window.orderBack(nil)
        self.activeWindow = window
        return (window, hostingView, totalSize)
    }

    private func captureLiveFloatingPanel(
        store: MonitorStore,
        style: SnapshotBackdropStyle,
        scrollToBottom: Bool,
        to fileURL: URL
    ) async -> Bool {
        let appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
        let colorScheme: ColorScheme = style.isDark ? .dark : .light
        let screen = NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 48
        let panelW = RootPopoverView.popoverWidth
        let panelH = RootPopoverView.fixedPanelHeight
        let totalW = panelW + margin * 2
        let totalH = panelH + margin * 2

        let originX = round(screenFrame.minX + 60)
        let originY = round(screenFrame.minY + max(40, (screenFrame.height - totalH) * 0.5))
        let bgRect = NSRect(x: originX, y: originY, width: totalW, height: totalH)
        let cardRect = NSRect(x: originX + margin, y: originY + margin, width: panelW, height: panelH)

        let bgWin = NSWindow(
            contentRect: bgRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        bgWin.appearance = appearance
        let bgHost = NSHostingView(
            rootView: SnapshotBackdropView(style: style)
                .frame(width: totalW, height: totalH)
                .environment(\.colorScheme, colorScheme)
        )
        bgHost.appearance = appearance
        bgHost.frame = NSRect(origin: .zero, size: bgRect.size)
        bgWin.contentView = bgHost
        bgWin.isOpaque = true
        bgWin.hasShadow = false
        bgWin.level = .statusBar
        bgWin.orderFrontRegardless()

        let panel = FloatingGlassPanel(cardScreenFrame: cardRect)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.appearance = appearance
        let (rootView, _) = OrbitStatAppDelegate.makeTransparentPanelContent(
            store: store,
            cardSize: cardRect.size,
            appearance: appearance,
            colorSchemeOverride: colorScheme,
            scrollToBottomForSnapshot: scrollToBottom,
            onQuit: {}
        )
        panel.contentView = rootView

        panel.alphaValue = 1.0
        OrbitStatAppDelegate.activateForPanel()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeMain()

        try? await Task.sleep(for: .milliseconds(50))
        OrbitStatAppDelegate.activateForPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeMain()

        try? await Task.sleep(for: .milliseconds(400))
        print("LIVE_PANEL_STATE: style=\(style) scrollToBottom=\(scrollToBottom) isActive=\(NSApp.isActive) isKey=\(panel.isKeyWindow) isMain=\(panel.isMainWindow)")

        let captureTop = Int(round(screenFrame.maxY - bgRect.maxY))
        let captureLeft = Int(round(bgRect.minX))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = [
            "-x",
            "-R", "\(captureLeft),\(captureTop),\(Int(totalW)),\(Int(totalH))",
            fileURL.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        var ok = false
        do {
            try process.run()
            process.waitUntilExit()
            ok = (process.terminationStatus == 0 && FileManager.default.fileExists(atPath: fileURL.path))
        } catch {
            ok = false
        }

        panel.orderOut(nil)
        panel.contentView = nil
        bgWin.orderOut(nil)
        bgWin.contentView = nil
        return ok
    }

    private func settleWindow(_ window: NSWindow, hostingView: NSView) async {
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(220))
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func closeSnapshotWindow(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        if activeWindow === window {
            activeWindow = nil
        }
    }

    private func captureWindow(
        _ window: NSWindow,
        hostingView: NSView,
        size: NSSize,
        to fileURL: URL
    ) -> Bool {
        if captureWindowWithScreencapture(windowID: CGWindowID(window.windowNumber), to: fileURL) {
            return true
        }
        return renderFallbackBitmap(hostingView: hostingView, size: size, to: fileURL)
    }

    private func captureWindowWithScreencapture(windowID: CGWindowID, to fileURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(windowID)", fileURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: fileURL.path)
        } catch {
            return false
        }
    }

    private func renderFallbackBitmap(hostingView: NSView, size: NSSize, to fileURL: URL) -> Bool {
        let scale: CGFloat = 2.0
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return false
        }
        rep.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try pngData.write(to: fileURL)
            return true
        } catch {
            return false
        }
    }
}
