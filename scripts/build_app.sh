#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
APP_NAME="OrbitStat"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Building ${APP_NAME} (release)..."
cd "${PROJECT_ROOT}"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "Error: release binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cat > "${CONTENTS_DIR}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>OrbitStat</string>
    <key>CFBundleExecutable</key>
    <string>OrbitStat</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.orbitstat.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>OrbitStat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Generating AppIcon.icns..."
TMP_ICON_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_ICON_DIR}"' EXIT
ICONSET_DIR="${TMP_ICON_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"

swift - "${ICONSET_DIR}" <<'SWIFT'
import AppKit
import Foundation

let iconsetDir = CommandLine.arguments[1]

func renderIcon(pixels: Int, to url: URL) throws {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGen", code: 1)
    }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "IconGen", code: 2)
    }
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let inset = size * 0.08
    let cardRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = cardRect.width * 0.225
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Sleek macOS Tahoe blue-indigo Liquid Glass squircle gradient
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.22, green: 0.68, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.06, green: 0.45, blue: 0.96, alpha: 1.0),
        CGColor(red: 0.23, green: 0.26, blue: 0.78, alpha: 1.0),
        CGColor(red: 0.14, green: 0.16, blue: 0.48, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.38, 0.78, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: size * 0.2, y: size),
            end: CGPoint(x: size * 0.85, y: 0),
            options: []
        )
    }

    // Soft glass specular radial bloom at upper-left
    let glowColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.36),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let radial = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            radial,
            startCenter: CGPoint(x: size * 0.32, y: size * 0.78),
            startRadius: 0,
            endCenter: CGPoint(x: size * 0.32, y: size * 0.78),
            endRadius: size * 0.56,
            options: []
        )
    }
    ctx.restoreGState()

    // Crisp Liquid Glass inner specular rim
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.42))
    ctx.setLineWidth(max(1.0, size * 0.018))
    ctx.strokePath()
    ctx.restoreGState()

    // Native macOS SF Symbol (`gauge.with.dots.needle.33percent`) centered cleanly
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: size * 0.44, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let baseSymbol = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)
        ?? NSImage(systemSymbolName: "cpu", accessibilityDescription: nil),
       let symbol = baseSymbol.withSymbolConfiguration(symbolConfig) {
        let symSize = symbol.size
        let maxDim = cardRect.width * 0.60
        let scale = min(maxDim / max(symSize.width, 1), maxDim / max(symSize.height, 1))
        let drawW = symSize.width * scale
        let drawH = symSize.height * scale
        let drawRect = NSRect(
            x: (size - drawW) * 0.5,
            y: (size - drawH) * 0.5,
            width: drawW,
            height: drawH
        )
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -size * 0.018),
            blur: size * 0.045,
            color: CGColor(red: 0.02, green: 0.06, blue: 0.20, alpha: 0.35)
        )
        symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        ctx.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 3)
    }
    try png.write(to: url)
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    let url = URL(fileURLWithPath: iconsetDir).appendingPathComponent(name)
    try renderIcon(pixels: px, to: url)
}
SWIFT

iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"

echo "==> Ad-hoc codesigning ${APP_BUNDLE}..."
codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "==> Build complete:"
ls -lh "${MACOS_DIR}/${APP_NAME}"
echo "App bundle: ${APP_BUNDLE}"
