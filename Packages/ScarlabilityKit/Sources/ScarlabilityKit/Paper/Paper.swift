import CoreGraphics

public enum PaperTemplate: String, Codable, Sendable, CaseIterable {
    case blank
    case lined
    case grid
    case dotted
}

public struct PaperStyle: Codable, Hashable, Sendable {
    public var template: PaperTemplate
    public var color: InkColor

    public init(template: PaperTemplate, color: InkColor) {
        self.template = template
        self.color = color
    }

    public static let whiteLined = PaperStyle(template: .lined, color: .white)
}

public enum PageSize {
    /// 210 × 297 mm in points.
    public static let a4 = CGSize(width: 595.28, height: 841.89)
}

public enum PaperRenderer {
    static let millimeter: CGFloat = 72 / 25.4
    static let lineSpacing = 8 * millimeter
    static let lineTopMargin = 20 * millimeter
    static let lineBottomMargin = 10 * millimeter
    static let gridSpacing = 5 * millimeter
    static let lineColor = InkColor(hex: 0xBFD0E4).cgColor
    static let gridColor = InkColor(hex: 0xD6E1EE).cgColor
    static let dotColor = InkColor(hex: 0xA9BCD3).cgColor

    /// Draws the paper background. The context must use page coordinates with the origin at the
    /// top-left; only the part inside `clip` is drawn.
    public static func draw(_ style: PaperStyle, pageSize: CGSize, in context: CGContext, clip: CGRect) {
        let page = CGRect(origin: .zero, size: pageSize)
        let area = page.intersection(clip)
        guard !area.isNull else { return }

        context.setFillColor(style.color.cgColor)
        context.fill(area)

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
                y += lineSpacing
            }
            context.strokePath()
        case .grid:
            context.setStrokeColor(gridColor)
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
            context.setFillColor(dotColor)
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
