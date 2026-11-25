import SwiftUI

/// Explicit property-wrapper alias for `SwiftUI.State` so plain `swift build` works cleanly
/// on macOS CommandLineTools SDKs where the `State()` macro plugin (`SwiftUIMacros`) is absent.
public typealias ViewState<Value> = SwiftUI.State<Value>

// MARK: - Design Tokens

public enum OrbitColors {
    public static let cpuBlue = Color(red: 0.0, green: 0.478, blue: 1.0)
    public static let adapterBlue = Color(red: 0.0, green: 0.478, blue: 1.0)

    public static func accentBlue(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.30, green: 0.66, blue: 1.0)
            : Color(red: 0.0, green: 0.478, blue: 1.0)
    }

    public static func thermalTeal(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.22, green: 0.80, blue: 0.78)
            : Color(red: 0.06, green: 0.58, blue: 0.60)
    }

    public static func thermalWarm(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.0, green: 0.64, blue: 0.24)
            : Color(red: 0.90, green: 0.48, blue: 0.08)
    }

    public static func thermalHot(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 1.0, green: 0.38, blue: 0.36)
            : Color(red: 0.86, green: 0.20, blue: 0.18)
    }

    public static func memoryGreen(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.22, green: 0.82, blue: 0.54)
            : Color(red: 0.11, green: 0.56, blue: 0.35)
    }

    public static func batteryGreen(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.22, green: 0.84, blue: 0.46)
            : Color(red: 0.14, green: 0.62, blue: 0.30)
    }

    public static func systemPowerAmber(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.98, green: 0.58, blue: 0.22)
            : Color(red: 0.84, green: 0.42, blue: 0.08)
    }

    public static func healthMagenta(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.98, green: 0.34, blue: 0.58)
            : Color(red: 0.86, green: 0.18, blue: 0.46)
    }

    public static func capPillBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.primary.opacity(0.10)
            : Color.primary.opacity(0.06)
    }
}

// MARK: - Official macOS 26/27 Liquid Glass Containers & Tiles

/// Wraps sibling official `.glassEffect` islands in `GlassEffectContainer` on macOS 26+
/// for cohesive shared refraction and smooth morphing, passing through cleanly on macOS 14–15.
public struct LiquidGlassGroup<Content: View>: View {
    public let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

/// Optional shell helper kept free of custom gray fills (pure official glass or clear).
public struct LiquidGlassShellBackground: View {
    public let cornerRadius: CGFloat
    public let tint: Color?
    public let useNativeGlass: Bool

    public init(
        cornerRadius: CGFloat = 24,
        tint: Color? = nil,
        useNativeGlass: Bool = true
    ) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.useNativeGlass = useNativeGlass
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if useNativeGlass {
            if #available(macOS 26.0, *) {
                let glass: Glass = tint.map { .regular.tint($0) } ?? .regular
                Color.clear
                    .glassEffect(glass, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        } else {
            Color.clear
        }
    }
}

/// Independent macOS Control Center module tile using 100% official `.glassEffect` on macOS 26+
/// with a subtle native floating elevation shadow (zero fake gray fills; `.ultraThinMaterial`
/// fallback on macOS 14–15).
public struct GlassTile<Content: View>: View {
    public let cornerRadius: CGFloat
    public let tint: Color?
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme

    public init(
        cornerRadius: CGFloat = 20,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let shadowOpacity = colorScheme == .dark ? 0.18 : 0.06

        if #available(macOS 26.0, *) {
            let glass: Glass = tint.map { .regular.tint($0) } ?? .regular
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .glassEffect(glass, in: shape)
                .shadow(color: Color.black.opacity(shadowOpacity), radius: 6, x: 0, y: 2)
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(shadowOpacity), radius: 6, x: 0, y: 2)
        }
    }
}

// MARK: - Airy Flat-Tinted Circular SF Symbol Badge

/// Translucent flat-tinted circular SF Symbol badge (zero gradient, zero gloss, zero shadow).
public struct MetricSymbolBadge: View {
    public let systemImage: String
    public let color: Color
    public let size: CGFloat
    public let iconSize: CGFloat
    public let muted: Bool

    @Environment(\.colorScheme) private var colorScheme

    public init(
        systemImage: String,
        color: Color,
        size: CGFloat = 28,
        iconSize: CGFloat = 13,
        muted: Bool = false
    ) {
        self.systemImage = systemImage
        self.color = color
        self.size = size
        self.iconSize = iconSize
        self.muted = muted
    }

    public var body: some View {
        ZStack {
            if muted {
                Circle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                    )
            } else {
                Circle()
                    .fill(color.opacity(colorScheme == .dark ? 0.18 : 0.11))
                    .overlay(
                        Circle()
                            .strokeBorder(color.opacity(colorScheme == .dark ? 0.26 : 0.16), lineWidth: 0.6)
                    )
            }

            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(
                    muted
                        ? Color.primary.opacity(0.45)
                        : color
                )
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Official Native Capsule Controls

/// Subtle tactile press response without overriding official glass appearance.
public struct LiquidGlassPressStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Official macOS Tahoe Liquid Glass **Capsule** segmented bar (`[cpu] 系统` | `[bolt.fill] 电源`).
/// Uses pure official `.glassEffect(.regular, in: Capsule())` for the outer capsule track and
/// official `.glassEffect(.regular.tint(...).interactive(), in: Capsule())` on the selected tab,
/// decoupling binding assignment from parent layout animations so switching tabs never jumps.
public struct NativeTabCapsuleBar: View {
    @Binding public var selection: MetricTab
    public var onChange: ((MetricTab) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var glassNamespace
    @ViewState private var hoveredTab: MetricTab?

    public init(
        selection: Binding<MetricTab>,
        onChange: ((MetricTab) -> Void)? = nil
    ) {
        self._selection = selection
        self.onChange = onChange
    }

    public var body: some View {
        let trackShape = Capsule(style: .continuous)
        let row = HStack(spacing: 3) {
            ForEach(MetricTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(3)
        .animation(.snappy(duration: 0.20), value: selection)

        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 4) {
                row
                    .glassEffect(.regular, in: trackShape)
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.05),
                        radius: 5,
                        x: 0,
                        y: 1.5
                    )
            }
        } else {
            row
                .background(.ultraThinMaterial, in: trackShape)
                .overlay(
                    trackShape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.05),
                    radius: 5,
                    x: 0,
                    y: 1.5
                )
        }
    }

    private func tabButton(for tab: MetricTab) -> some View {
        let isSelected = selection == tab
        let isHovered = hoveredTab == tab
        let pillShape = Capsule(style: .continuous)
        let accent = OrbitColors.accentBlue(for: colorScheme)

        return Button {
            selection = tab
            onChange?(tab)
        } label: {
            tabLabel(
                tab: tab,
                isSelected: isSelected,
                isHovered: isHovered,
                pillShape: pillShape,
                accent: accent
            )
        }
        .buttonStyle(LiquidGlassPressStyle())
        .accessibilityLabel(tab.title)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
            }
        }
    }

    @ViewBuilder
    private func tabLabel(
        tab: MetricTab,
        isSelected: Bool,
        isHovered: Bool,
        pillShape: Capsule,
        accent: Color
    ) -> some View {
        let activeForeground: Color = colorScheme == .dark
            ? Color(red: 0.56, green: 0.84, blue: 1.0)
            : accent

        let content = HStack(spacing: 6) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(tab.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
        }
        .foregroundStyle(isSelected ? activeForeground : Color.primary.opacity(isHovered ? 0.88 : 0.68))
        .frame(maxWidth: .infinity)
        .frame(height: 30)

        if #available(macOS 26.0, *) {
            if isSelected {
                content
                    .glassEffect(
                        .regular.tint(accent.opacity(colorScheme == .dark ? 0.24 : 0.16)).interactive(),
                        in: pillShape
                    )
                    .glassEffectID("orbitstat.nativeTabPill", in: glassNamespace)
                    .contentShape(pillShape)
            } else {
                content
                    .background(
                        pillShape.fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
                    )
                    .contentShape(pillShape)
            }
        } else {
            ZStack {
                if isSelected {
                    pillShape
                        .fill(accent.opacity(colorScheme == .dark ? 0.24 : 0.16))
                        .matchedGeometryEffect(id: "orbitstat.nativeTabPillFallback", in: glassNamespace)
                } else if isHovered {
                    pillShape.fill(Color.primary.opacity(0.06))
                }
                content
            }
            .contentShape(pillShape)
        }
    }
}

/// Official macOS Liquid Glass `Capsule()` button (unified `28pt` compact height matching
/// `NativeGlassCapsulePill`, `32pt` regular height).
public struct NativeCapsuleButton: View {
    public let title: String
    public let systemImage: String?
    public let compact: Bool
    public let expand: Bool
    public let tint: Color?
    public let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var isHovered: Bool = false

    public init(
        title: String,
        systemImage: String? = nil,
        compact: Bool = false,
        expand: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.compact = compact
        self.expand = expand
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        let shape = Capsule(style: .continuous)

        Button(action: action) {
            capsuleLabel(shape: shape)
                .contentShape(shape)
        }
        .buttonStyle(LiquidGlassPressStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private func capsuleLabel(shape: Capsule) -> some View {
        let content = HStack(spacing: compact ? 4.5 : 5.5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            }
            Text(title)
                .font(.system(size: compact ? 12 : 12.5, weight: .medium))
        }
        .foregroundStyle(Color.primary.opacity(isHovered ? 0.98 : 0.88))
        .padding(.horizontal, compact ? 11 : 14)
        .frame(maxWidth: expand ? .infinity : nil)
        .frame(height: compact ? 28 : 32)

        let shadowOpacity = colorScheme == .dark ? 0.16 : 0.05

        if #available(macOS 26.0, *) {
            let glass: Glass = tint.map { .regular.tint($0).interactive() } ?? .regular.interactive()
            content
                .glassEffect(glass, in: shape)
                .shadow(color: Color.black.opacity(shadowOpacity), radius: 5, x: 0, y: 1.5)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(shadowOpacity), radius: 5, x: 0, y: 1.5)
        }
    }
}

/// Official macOS Liquid Glass `Circle()` icon button (for header filter `slider.horizontal.3`, Activity Monitor `arrow.up.right`).
public struct NativeCircleIconButton: View {
    public let systemImage: String
    public let size: CGFloat
    public let iconSize: CGFloat
    public let helpText: String?
    public let isActive: Bool
    public let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var isHovered: Bool = false

    public init(
        systemImage: String,
        size: CGFloat = 36,
        iconSize: CGFloat = 13.5,
        help: String? = nil,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.size = size
        self.iconSize = iconSize
        self.helpText = help
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        let shape = Circle()
        let button = Button(action: action) {
            iconLabel(shape: shape)
                .contentShape(shape)
        }
        .buttonStyle(LiquidGlassPressStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }

        if let helpText {
            button.help(helpText)
        } else {
            button
        }
    }

    @ViewBuilder
    private func iconLabel(shape: Circle) -> some View {
        let accent = OrbitColors.accentBlue(for: colorScheme)
        let content = Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(
                isActive
                    ? accent
                    : Color.primary.opacity(isHovered ? 0.98 : 0.80)
            )
            .frame(width: size, height: size)

        let shadowOpacity = colorScheme == .dark ? 0.16 : 0.05

        if #available(macOS 26.0, *) {
            let glass: Glass = isActive
                ? .regular.tint(accent.opacity(colorScheme == .dark ? 0.26 : 0.16)).interactive()
                : .regular.interactive()
            content
                .glassEffect(glass, in: shape)
                .shadow(color: Color.black.opacity(shadowOpacity), radius: 5, x: 0, y: 1.5)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(shadowOpacity), radius: 5, x: 0, y: 1.5)
        }
    }
}

/// Official macOS Liquid Glass `Capsule()` info pill (default `28pt` height matching compact
/// `NativeCapsuleButton` to the exact pixel — used for bottom `[clock] 已运行 3d 4h`, Settings
/// header/footer pills, etc.).
public struct NativeGlassCapsulePill: View {
    public let text: String
    public let systemImage: String?
    public let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(text: String, systemImage: String? = nil, height: CGFloat = 28) {
        self.text = text
        self.systemImage = systemImage
        self.height = height
    }

    public var body: some View {
        let shape = Capsule(style: .continuous)
        let shadowOpacity = colorScheme == .dark ? 0.16 : 0.05
        let content = HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5, weight: .medium))
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(Color.primary.opacity(0.86))
        .padding(.horizontal, 11)
        .frame(height: height)

        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .shadow(color: Color.black.opacity(shadowOpacity), radius: 5, x: 0, y: 1.5)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(shadowOpacity), radius: 5, x: 0, y: 1.5)
        }
    }
}

/// Compact inline flat sheer-tinted `Capsule()` status tag for inside tiles (`正常`, `温热`, `10`).
public struct StatusCapsulePill: View {
    public let text: String
    public let systemImage: String?
    public let tint: Color?

    @Environment(\.colorScheme) private var colorScheme

    public init(text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        let shape = Capsule(style: .continuous)

        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(
            tint ?? Color.primary.opacity(colorScheme == .dark ? 0.80 : 0.72)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Group {
                if let tint {
                    shape.fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.11))
                } else {
                    shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                }
            }
        )
        .overlay(
            shape.strokeBorder(
                tint?.opacity(colorScheme == .dark ? 0.28 : 0.18)
                    ?? Color.primary.opacity(0.08),
                lineWidth: 0.6
            )
        )
        .clipShape(shape)
    }
}

/// Compact subtle capsule button for actions nested INSIDE an official `.glassEffect` tile
/// (avoids nested glass-on-glass artifacts while preserving clean macOS vibrancy).
public struct TileInlineCapsuleButton: View {
    public let title: String
    public let systemImage: String?
    public let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var isHovered: Bool = false

    public init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        let shape = Capsule(style: .continuous)
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Color.primary.opacity(isHovered ? 0.96 : 0.82))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                shape.fill(
                    Color.primary.opacity(
                        isHovered
                            ? (colorScheme == .dark ? 0.15 : 0.10)
                            : (colorScheme == .dark ? 0.09 : 0.055)
                    )
                )
            )
            .contentShape(shape)
        }
        .buttonStyle(LiquidGlassPressStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

/// Compact subtle circle icon button for actions nested INSIDE an official `.glassEffect` tile.
public struct TileInlineCircleButton: View {
    public let systemImage: String
    public let size: CGFloat
    public let iconSize: CGFloat
    public let helpText: String?
    public let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var isHovered: Bool = false

    public init(
        systemImage: String,
        size: CGFloat = 24,
        iconSize: CGFloat = 11,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.size = size
        self.iconSize = iconSize
        self.helpText = help
        self.action = action
    }

    public var body: some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(isHovered ? 0.96 : 0.78))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(
                        Color.primary.opacity(
                            isHovered
                                ? (colorScheme == .dark ? 0.15 : 0.10)
                                : (colorScheme == .dark ? 0.09 : 0.055)
                        )
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(LiquidGlassPressStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }

        if let helpText {
            button.help(helpText)
        } else {
            button
        }
    }
}

// MARK: - Area Sparkline Chart

public enum SparklineCeiling: Equatable {
    case fixed(maxValue: Double, label: String)
    case dynamicWatts(baseCap: Double = 50, step: Double = 50)

    public func resolved(for values: [Double]) -> (maxValue: Double, label: String) {
        switch self {
        case let .fixed(maxValue, label):
            return (max(1.0, maxValue), label)
        case let .dynamicWatts(baseCap, step):
            let peak = values.filter(\.isFinite).max() ?? 0
            let safeStep = max(1.0, step)
            let cap: Double
            if peak <= baseCap {
                cap = baseCap
            } else {
                cap = ceil(peak / safeStep) * safeStep
            }
            return (max(1.0, cap), "\(Int(cap.rounded())) W")
        }
    }
}

/// Real-time area sparkline with sheer flat `Capsule()` ceiling badge and smooth curve.
public struct AreaSparklineChart: View {
    public let values: [Double]
    public let color: Color
    public let ceiling: SparklineCeiling
    public let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(
        values: [Double],
        color: Color,
        ceiling: SparklineCeiling = .fixed(maxValue: 100, label: "100%"),
        height: CGFloat = 46
    ) {
        self.values = values
        self.color = color
        self.ceiling = ceiling
        self.height = height
    }

    public var body: some View {
        let resolved = ceiling.resolved(for: values)
        let topLineY: CGFloat = 8.5

        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let width = size.width
                let bottomY = size.height - 0.5
                guard width > 1, bottomY > topLineY + 2 else { return }

                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: bottomY))
                baseline.addLine(to: CGPoint(x: width, y: bottomY))
                context.stroke(
                    baseline,
                    with: .color(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10)),
                    style: StrokeStyle(lineWidth: 0.75)
                )

                let sanitized = values.filter(\.isFinite)
                guard !sanitized.isEmpty else { return }

                let plotTop = topLineY + 1.5
                let plotBottom = bottomY - 1.5
                let plotHeight = max(1, plotBottom - plotTop)

                func yPosition(for rawValue: Double) -> CGFloat {
                    let normalized = min(1.0, max(0.0, rawValue / resolved.maxValue))
                    return plotBottom - CGFloat(normalized) * plotHeight
                }

                let points: [CGPoint]
                if sanitized.count == 1 {
                    let y = yPosition(for: sanitized[0])
                    points = [CGPoint(x: 0, y: y), CGPoint(x: width, y: y)]
                } else {
                    let denom = CGFloat(sanitized.count - 1)
                    points = sanitized.enumerated().map { idx, val in
                        CGPoint(
                            x: width * (CGFloat(idx) / denom),
                            y: yPosition(for: val)
                        )
                    }
                }

                var strokePath = Path()
                if let first = points.first {
                    strokePath.move(to: first)
                    for pt in points.dropFirst() {
                        strokePath.addLine(to: pt)
                    }
                }

                var fillPath = strokePath
                if let last = points.last, let first = points.first {
                    fillPath.addLine(to: CGPoint(x: last.x, y: bottomY))
                    fillPath.addLine(to: CGPoint(x: first.x, y: bottomY))
                    fillPath.closeSubpath()
                }

                let peakY = points.map(\.y).min() ?? plotTop
                let gradientStartY = max(plotTop, min(peakY, bottomY - 12))
                let fillGradient = Gradient(stops: [
                    .init(color: color.opacity(colorScheme == .dark ? 0.30 : 0.22), location: 0.0),
                    .init(color: color.opacity(colorScheme == .dark ? 0.10 : 0.06), location: 0.58),
                    .init(color: color.opacity(0.0), location: 1.0)
                ])
                context.fill(
                    fillPath,
                    with: .linearGradient(
                        fillGradient,
                        startPoint: CGPoint(x: 0, y: gradientStartY),
                        endPoint: CGPoint(x: 0, y: bottomY)
                    )
                )

                context.stroke(
                    strokePath,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round)
                )
            }
            .animation(nil, value: values)

            HStack(spacing: 4) {
                Text(resolved.label)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.78 : 0.66))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(OrbitColors.capPillBackground(for: colorScheme))
                    )

                Canvas { ctx, lineSize in
                    let y = lineSize.height / 2.0
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: lineSize.width, y: y))
                    ctx.stroke(
                        path,
                        with: .color(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.14)),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 3])
                    )
                }
                .frame(height: 14)
            }
            .animation(nil, value: resolved.label)
        }
        .frame(height: height)
    }
}

// MARK: - Thin Capsule Bar

/// Pure flat `Capsule()` progress bar with sheer translucent track.
public struct ThinCapsuleBar: View {
    public let progress: Double
    public let color: Color
    public let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(progress: Double, color: Color, height: CGFloat = 6) {
        self.progress = progress
        self.color = color
        self.height = height
    }

    public var body: some View {
        let clamped = progress.isFinite ? min(1.0, max(0.0, progress)) : 0.0

        GeometryReader { proxy in
            let fillWidth = clamped > 0 ? max(height, proxy.size.width * clamped) : 0

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))

                if fillWidth > 0 {
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: min(proxy.size.width, fillWidth))
                        .animation(.easeInOut(duration: 0.22), value: clamped)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Memory Pressure Badge

/// Sheer flat-tinted `Capsule()` badge with crisp dot.
public struct MemoryPressureBadge: View {
    public let level: MemoryPressureLevel

    @Environment(\.colorScheme) private var colorScheme

    public init(level: MemoryPressureLevel) {
        self.level = level
    }

    public var body: some View {
        let style = colors(for: level)

        HStack(spacing: 4.5) {
            Circle()
                .fill(style.dot)
                .frame(width: 6, height: 6)

            Text(level.displayTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.text)
        }
        .padding(.horizontal, 7.5)
        .padding(.vertical, 2.5)
        .background(
            Capsule(style: .continuous)
                .fill(style.background)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(style.border, lineWidth: 0.6)
        )
    }

    private func colors(for level: MemoryPressureLevel) -> (
        background: Color,
        border: Color,
        dot: Color,
        text: Color
    ) {
        switch level {
        case .normal:
            let base = OrbitColors.memoryGreen(for: colorScheme)
            return (
                base.opacity(colorScheme == .dark ? 0.18 : 0.11),
                base.opacity(colorScheme == .dark ? 0.28 : 0.18),
                base,
                base
            )

        case .warning:
            let base = OrbitColors.thermalWarm(for: colorScheme)
            let text = colorScheme == .dark ? base : Color(red: 0.68, green: 0.38, blue: 0.04)
            return (
                base.opacity(colorScheme == .dark ? 0.18 : 0.12),
                base.opacity(colorScheme == .dark ? 0.28 : 0.20),
                base,
                text
            )

        case .critical:
            let base = OrbitColors.thermalHot(for: colorScheme)
            return (
                base.opacity(colorScheme == .dark ? 0.20 : 0.12),
                base.opacity(colorScheme == .dark ? 0.30 : 0.20),
                base,
                base
            )
        }
    }
}

// MARK: - Card Divider

/// Clean subtle native hairline divider.
public struct CardDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.08))
            .frame(height: 0.5)
    }
}

// MARK: - Section Filter Popover

/// Compact native macOS toggle popover triggered by the circular `slider.horizontal.3` button.
public struct SectionFilterPopover: View {
    public let tab: MetricTab
    @Binding public var settings: AppSettings

    @Environment(\.colorScheme) private var colorScheme

    public init(tab: MetricTab, settings: Binding<AppSettings>) {
        self.tab = tab
        self._settings = settings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("显示模块")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if hasHiddenSections {
                    Button("全部显示") {
                        resetTabVisibility()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(OrbitColors.accentBlue(for: colorScheme))
                }
            }

            CardDivider()

            VStack(alignment: .leading, spacing: 8) {
                switch tab {
                case .system:
                    filterToggle("CPU 温度", isOn: $settings.showSystemTempCard)
                    filterToggle("处理器占用", isOn: $settings.showSystemCPUCard)
                    filterToggle("内存", isOn: $settings.showSystemMemoryCard)
                case .power:
                    filterToggle("电池", isOn: $settings.showPowerBatteryCard)
                    filterToggle("电池温度", isOn: $settings.showPowerTempRow)
                    filterToggle("电池健康度", isOn: $settings.showPowerHealthRow)
                    filterToggle("系统功耗", isOn: $settings.showPowerSystemCard)
                    filterToggle("电源适配器", isOn: $settings.showPowerAdapterRow)
                }
            }
        }
        .padding(12)
        .frame(width: 204)
    }

    private func filterToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.primary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private var hasHiddenSections: Bool {
        switch tab {
        case .system:
            return !(settings.showSystemTempCard && settings.showSystemCPUCard && settings.showSystemMemoryCard)
        case .power:
            return !(settings.showPowerBatteryCard &&
                     settings.showPowerTempRow &&
                     settings.showPowerSystemCard &&
                     settings.showPowerAdapterRow &&
                     settings.showPowerHealthRow)
        }
    }

    private func resetTabVisibility() {
        switch tab {
        case .system:
            settings.showSystemTempCard = true
            settings.showSystemCPUCard = true
            settings.showSystemMemoryCard = true
        case .power:
            settings.showPowerBatteryCard = true
            settings.showPowerTempRow = true
            settings.showPowerSystemCard = true
            settings.showPowerAdapterRow = true
            settings.showPowerHealthRow = true
        }
    }
}
