import AppKit
import SwiftUI

public struct RootPopoverView: View {
    @ObservedObject public var store: MonitorStore
    public var panelHeight: CGFloat
    public var scrollToBottomForSnapshot: Bool
    public var onQuit: () -> Void

    @ViewState private var isShowingFilterPopover = false

    public static let popoverWidth: CGFloat = 364
    public static let fixedPanelHeight: CGFloat = 600
    public static let shellCornerRadius: CGFloat = 24

    public init(
        store: MonitorStore,
        panelHeight: CGFloat = RootPopoverView.fixedPanelHeight,
        scrollToBottomForSnapshot: Bool = false,
        onQuit: @escaping () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.store = store
        self.panelHeight = panelHeight
        self.scrollToBottomForSnapshot = scrollToBottomForSnapshot
        self.onQuit = onQuit
    }

    public var body: some View {
        ZStack(alignment: .top) {
            if store.isShowingSettings {
                SettingsView(store: store) {
                    store.isShowingSettings = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: Self.popoverWidth, height: panelHeight, alignment: .top)
        .modifier(OfficialRegularGlassShellModifier(cornerRadius: Self.shellCornerRadius))
    }

    // MARK: - Main Control Center Layout Inside Official .clear Glass Frame

    private var mainContent: some View {
        VStack(spacing: 2) {
            // Top Official Liquid Glass Capsule Tab Bar + Circular Filter Button (locked at top)
            topControlBar
                .padding(.horizontal, 14)
                .padding(.top, 14)

            // Single smooth outer ScrollView with gentle 8pt top/bottom edge fade mask
            // so scrolling tiles glide softly inside the outer 24pt .clear glass frame.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        activeTabView
                            .frame(maxWidth: .infinity, alignment: .top)
                        Color.clear
                            .frame(height: 1)
                            .id("orbitstat.scrollBottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .id(store.selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .mask(scrollEdgeFadeMask)
                .onAppear {
                    if scrollToBottomForSnapshot {
                        proxy.scrollTo("orbitstat.scrollBottom", anchor: .bottom)
                    }
                }
            }

            // Bottom Official Liquid Glass Capsule Bar — all 3 capsules unified at exact 28pt height
            bottomCapsuleBar
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var scrollEdgeFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 8)

            Rectangle().fill(.black)

            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 8)
        }
    }

    // MARK: - Top Control Bar

    private var topControlBar: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                NativeTabCapsuleBar(selection: $store.selectedTab) { _ in
                    isShowingFilterPopover = false
                }

                NativeCircleIconButton(
                    systemImage: "slider.horizontal.3",
                    size: 36,
                    iconSize: 13.5,
                    help: "自定义显示项",
                    isActive: isShowingFilterPopover
                ) {
                    isShowingFilterPopover.toggle()
                }
                .popover(isPresented: $isShowingFilterPopover, arrowEdge: .bottom) {
                    SectionFilterPopover(tab: store.selectedTab, settings: $store.settings)
                }
            }
        }
    }

    // MARK: - Modular Content Area

    @ViewBuilder
    private var activeTabView: some View {
        switch store.selectedTab {
        case .system:
            SystemTabView(store: store)
        case .power:
            PowerTabView(store: store)
        }
    }

    // MARK: - Bottom Native Capsule Bar (Unified 28pt Official Liquid Glass)

    private var bottomCapsuleBar: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                NativeGlassCapsulePill(
                    text: "已运行 \(uptimeText)",
                    systemImage: "clock",
                    height: 28
                )

                Spacer(minLength: 4)

                NativeCapsuleButton(
                    title: "设置",
                    systemImage: "gearshape",
                    compact: true
                ) {
                    store.isShowingSettings = true
                }

                NativeCapsuleButton(
                    title: "退出",
                    systemImage: "power",
                    compact: true
                ) {
                    onQuit()
                }
            }
        }
    }

    private var uptimeText: String {
        guard let uptime = store.systemSnapshot?.uptimeSeconds else { return "--" }
        return MetricsFormatter.formatUptime(uptime)
    }
}

// MARK: - Official Frosted Regular Outer Liquid Glass Window Shell + Floating Shadow

/// Applies Apple's official macOS 26+ `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))`
/// outer window frame paired with a lush dual-layer macOS floating drop shadow (matching native
/// macOS Tahoe Notification Center / Control Center panels: softly diffusing text behind it while
/// lifting the entire glass surface cleanly off light cream and dark desktop windows).
private struct OfficialRegularGlassShellModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let ambientOpacity = colorScheme == .dark ? 0.45 : 0.16
        let contactOpacity = colorScheme == .dark ? 0.22 : 0.06

        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: Color.black.opacity(ambientOpacity), radius: 22, x: 0, y: 10)
                .shadow(color: Color.black.opacity(contactOpacity), radius: 5, x: 0, y: 2)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.10),
                        lineWidth: 0.75
                    )
                )
                .clipShape(shape)
                .shadow(color: Color.black.opacity(ambientOpacity), radius: 22, x: 0, y: 10)
                .shadow(color: Color.black.opacity(contactOpacity), radius: 5, x: 0, y: 2)
        }
    }
}
