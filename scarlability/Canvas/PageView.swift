#if os(iOS)
import ScarlabilityKit
import UIKit

/// One page on the canvas: a soft shadow, with the paper and finished ink drawn by a tiled layer.
final class PageView: UIView {
    private let tileView = TileView()

    var tileLayer: PageTileLayer { tileView.layer as! PageTileLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
        tileView.isUserInteractionEnabled = false
        addSubview(tileView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tileView.frame = bounds
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }

    private final class TileView: UIView {
        override class var layerClass: AnyClass { PageTileLayer.self }
    }
}
#endif
