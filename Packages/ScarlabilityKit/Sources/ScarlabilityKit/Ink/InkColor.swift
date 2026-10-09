import CoreGraphics

/// An sRGB color stored as 8-bit channels, so it encodes compactly in ink files.
public struct InkColor: Hashable, Sendable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Creates a color from a `0xRRGGBB` value.
    public init(hex: UInt32, alpha: UInt8 = 255) {
        self.init(
            red: UInt8((hex >> 16) & 0xFF),
            green: UInt8((hex >> 8) & 0xFF),
            blue: UInt8(hex & 0xFF),
            alpha: alpha
        )
    }

    /// Creates a color from 0–1 components, clamping anything out of range.
    public init(srgbRed red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func channel(_ value: Double) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        self.init(red: channel(red), green: channel(green), blue: channel(blue), alpha: channel(alpha))
    }

    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }
}

extension InkColor {
    public static let black = InkColor(hex: 0x1C1C1E)
    public static let blue = InkColor(hex: 0x1D5BD8)
    public static let red = InkColor(hex: 0xD62D2D)
    public static let white = InkColor(hex: 0xFFFFFF)
}
