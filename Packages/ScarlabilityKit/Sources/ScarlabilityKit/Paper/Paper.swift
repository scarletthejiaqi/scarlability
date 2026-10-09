import CoreGraphics

public enum PaperTemplate: String, Codable, Sendable, CaseIterable {
    case blank
    case lined
    // Not offered in the app (only blank and lined are), but kept so files using them still open.
    case grid
    case dotted
}

public enum LineSpacing: String, Codable, Sendable, CaseIterable {
    case narrow
    case medium
    case wide

    /// Distance between lines, in page points.
    public var points: CGFloat {
        switch self {
        case .narrow: 6.5 * PaperRenderer.millimeter
        case .medium: 8 * PaperRenderer.millimeter
        case .wide: 10 * PaperRenderer.millimeter
        }
    }
}

public struct PaperStyle: Codable, Hashable, Sendable {
    public var template: PaperTemplate
    public var color: InkColor
    /// Used by lined paper.
    public var lineSpacing: LineSpacing

    public init(template: PaperTemplate, color: InkColor, lineSpacing: LineSpacing = .medium) {
        self.template = template
        self.color = color
        self.lineSpacing = lineSpacing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        template = try container.decode(PaperTemplate.self, forKey: .template)
        color = try container.decode(InkColor.self, forKey: .color)
        // Notes from before line spacing existed have medium lines.
        lineSpacing = try container.decodeIfPresent(LineSpacing.self, forKey: .lineSpacing) ?? .medium
    }

    public static let whiteLined = PaperStyle(template: .lined, color: .white)

    /// Dark paper shows black ink as white, so it stays readable.
    public var isDark: Bool { color.luminance < 0.4 }
}

extension InkColor {
    /// The paper colors offered in the app.
    public static let paperColors: [InkColor] = [.white, .paperCream, .paperGray, .paperDark]
    public static let paperCream = InkColor(hex: 0xFCF5DC)
    public static let paperGray = InkColor(hex: 0xECECEE)
    public static let paperDark = InkColor(hex: 0x1F2023)

    /// Relative brightness from 0 (black) to 1 (white).
    public var luminance: Double {
        (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255
    }

    /// The color to draw pen ink in on the given paper: black becomes white on dark paper.
    public func displayed(on paper: PaperStyle) -> InkColor {
        paper.isDark && luminance < 0.2 ? InkColor(hex: 0xF2F2F2, alpha: alpha) : self
    }
}

public enum PageSize {
    /// 210 × 297 mm in points.
    public static let a4 = CGSize(width: 595.28, height: 841.89)
}

public enum PaperRenderer {
    public static let millimeter: CGFloat = 72 / 25.4
    static let lineTopMargin = 20 * millimeter
    static let lineBottomMargin = 10 * millimeter
    static let gridSpacing = 5 * millimeter

    /// Draws the paper background. The context must use page coordinates with the origin at the
    /// top-left; only the part inside `clip` is drawn.
    public static func draw(_ style: PaperStyle, pageSize: CGSize, in context: CGContext, clip: CGRect) {
        let page = CGRect(origin: .zero, size: pageSize)
        let area = page.intersection(clip)
        guard !area.isNull else { return }

        context.setFillColor(style.color.cgColor)
        context.fill(area)
        let lineColor = (style.isDark ? InkColor(hex: 0x3E4858) : InkColor(hex: 0xBFD0E4)).cgColor

        switch style.template {
        case .blank:
            break
        case .lined:
            context.setStrokeColor(lineColor)
            context.setLineWidth(0.6)
            var y = lineTopMargin
            while y <= pageSize.height - lineBottomMargin {
                if y >= area.minY - 1, y <= area.maxY + 1 {
                    context.move(to: CGPoint(x: area.minX, y: y))
                    context.addLine(to: CGPoint(x: area.maxX, y: y))
                }
                y += style.lineSpacing.points
            }
            context.strokePath()
        case .grid:
            context.setStrokeColor(lineColor)
            context.setLineWidth(0.5)
            for x in stride(from: gridSpacing, to: pageSize.width, by: gridSpacing) where x >= area.minX - 1 && x <= area.maxX + 1 {
                context.move(to: CGPoint(x: x, y: area.minY))
                context.addLine(to: CGPoint(x: x, y: area.maxY))
            }
            for y in stride(from: gridSpacing, to: pageSize.height, by: gridSpacing) where y >= area.minY - 1 && y <= area.maxY + 1 {
                context.move(to: CGPoint(x: area.minX, y: y))
                context.addLine(to: CGPoint(x: area.maxX, y: y))
            }
            context.strokePath()
        case .dotted:
            context.setFillColor(lineColor)
            let r: CGFloat = 0.7
            for x in stride(from: gridSpacing, to: pageSize.width, by: gridSpacing) where x >= area.minX - r && x <= area.maxX + r {
                for y in stride(from: gridSpacing, to: pageSize.height, by: gridSpacing) where y >= area.minY - r && y <= area.maxY + r {
                    context.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                }
            }
            context.fillPath()
        }
    }
}
