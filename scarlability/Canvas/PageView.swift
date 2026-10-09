#if os(iOS)
import ScarlabilityKit
import UIKit

/// One page on the canvas. The paper and finished ink are drawn by a tiled layer.
final class PageView: UIView {
    override class var layerClass: AnyClass { PageTileLayer.self }

    var tileLayer: PageTileLayer { layer as! PageTileLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
#endif
