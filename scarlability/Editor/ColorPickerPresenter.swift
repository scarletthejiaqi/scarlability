#if os(iOS)
import ScarlabilityKit
import UIKit

/// Shows the system color picker in a popover. It has a color spectrum, grid and sliders, plus
/// an eyedropper for picking any color on screen.
///
/// It's presented through UIKit (not a SwiftUI popover) so the eyedropper works: the picker has
/// to be the presented view controller to temporarily hide itself while you pick.
final class ColorPickerPresenter: NSObject, UIColorPickerViewControllerDelegate {
    static let shared = ColorPickerPresenter()

    private var onChange: ((InkColor) -> Void)?

    /// - Parameter rect: Where to point the popover, in window coordinates.
    func present(color: InkColor, from rect: CGRect, onChange: @escaping (InkColor) -> Void) {
        guard let window = Self.keyWindow, var presenter = window.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        self.onChange = onChange

        let picker = UIColorPickerViewController()
        picker.selectedColor = UIColor(cgColor: color.cgColor)
        picker.supportsAlpha = false
        picker.delegate = self
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = window
        picker.popoverPresentationController?.sourceRect = rect
        presenter.present(picker, animated: true)
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
        onChange?(InkColor(srgbRed: red, green: green, blue: blue))
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        onChange = nil
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
    }
}
#endif
