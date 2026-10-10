#if os(iOS)
import UIKit

/// The bar of actions shown above a selection (Delete, Copy, Paste, Cut…). Everything is in one
/// row you can scroll left and right, centered when it all fits.
final class SelectionActionBar: UIView {
    struct Action {
        var title: String
        var systemImage: String
        var isDestructive = false
        /// Runs on tap. Ignored if `menu` is set.
        var handler: () -> Void = {}
        /// Shown on tap instead (e.g. colors).
        var menu: UIMenu?
    }

    private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let scrollView = UIScrollView()
    private var buttons: [UIButton] = []

    private static let height: CGFloat = 58
    private static let gap: CGFloat = 10

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        background.clipsToBounds = true
        background.layer.cornerRadius = 16
        background.layer.cornerCurve = .continuous
        addSubview(background)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        background.contentView.addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the actions centered above `target` (canvas coordinates), or below it if there's no
    /// room, kept inside `bounds`.
    func show(_ actions: [Action], over target: CGRect, within bounds: CGRect) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.map(button(for:))
        var x: CGFloat = 0
        for button in buttons {
            let size = button.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: Self.height))
            button.frame = CGRect(x: x, y: 0, width: ceil(max(size.width, 52)), height: Self.height)
            x = button.frame.maxX
            scrollView.addSubview(button)
        }
        scrollView.contentSize = CGSize(width: x, height: Self.height)
        reposition(over: target, within: bounds)
        scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: 0)
        isHidden = false
    }

    func reposition(over target: CGRect, within bounds: CGRect) {
        let content = scrollView.contentSize
        let width = min(content.width + 16, bounds.width - 2 * Self.gap)
        var y = target.minY - Self.gap - Self.height
        if y < bounds.minY + Self.gap {
            y = min(target.maxY + Self.gap, bounds.maxY - Self.height - Self.gap)
        }
        let x = min(max(target.midX - width / 2, bounds.minX + Self.gap), bounds.maxX - width - Self.gap)
        frame = CGRect(x: x, y: y, width: width, height: Self.height)
        background.frame = self.bounds
        scrollView.frame = background.contentView.bounds
        // Centered when everything fits; scrollable when it doesn't.
        let spare = max(0, scrollView.bounds.width - content.width)
        scrollView.contentInset = UIEdgeInsets(top: 0, left: spare / 2, bottom: 0, right: spare / 2)
        layer.shadowPath = UIBezierPath(roundedRect: self.bounds, cornerRadius: 16).cgPath
    }

    func hide() {
        isHidden = true
    }

    private func button(for action: Action) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = action.title
        configuration.image = UIImage(systemName: action.systemImage)
        configuration.imagePlacement = .top
        configuration.imagePadding = 3
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 12, weight: .medium)
            return attributes
        }
        configuration.baseForegroundColor = action.isDestructive ? .systemRed : .label
        let button = UIButton(configuration: configuration)
        if let menu = action.menu {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
        } else {
            button.addAction(UIAction { _ in action.handler() }, for: .touchUpInside)
        }
        button.accessibilityLabel = action.title
        return button
    }
}
#endif
