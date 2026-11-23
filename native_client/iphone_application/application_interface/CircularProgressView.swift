import UIKit

/// The share of an upload sent: a ring that fills clockwise from the top.
final class CircularProgressView: UIView {
	private let track = CAShapeLayer()
	private let stroke = CAShapeLayer()
	private var fraction = 0.0

	override init(frame: CGRect) {
		super.init(frame: frame)
		for ring in [track, stroke] {
			ring.fillColor = nil
			ring.lineWidth = 2.5
			ring.lineCap = .round
			layer.addSublayer(ring)
		}
		stroke.strokeEnd = 0
		isAccessibilityElement = false
		registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
			view.applyColors()
		}
		applyColors()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("The interface is built in code")
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		let inset = track.lineWidth / 2
		let path = UIBezierPath(
			arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
			radius: max(min(bounds.width, bounds.height) / 2 - inset, 0),
			startAngle: -.pi / 2,
			endAngle: .pi * 3 / 2,
			clockwise: true
		).cgPath
		for ring in [track, stroke] {
			ring.frame = bounds
			ring.path = path
		}
	}

	override func tintColorDidChange() {
		super.tintColorDidChange()
		applyColors()
	}

	func show(fraction next: Double, animated: Bool) {
		let clamped = min(max(next, 0), 1)
		guard clamped != fraction || !animated else {
			return
		}
		let start = stroke.presentation()?.strokeEnd ?? CGFloat(fraction)
		fraction = clamped
		stroke.strokeEnd = CGFloat(clamped)
		guard animated else {
			stroke.removeAnimation(forKey: "fill")
			return
		}
		let filling = CABasicAnimation(keyPath: "strokeEnd")
		filling.fromValue = start
		filling.toValue = CGFloat(clamped)
		filling.duration = 0.2
		filling.timingFunction = CAMediaTimingFunction(name: .easeOut)
		stroke.add(filling, forKey: "fill")
	}

	private func applyColors() {
		track.strokeColor = UIColor.tertiarySystemFill.resolvedColor(with: traitCollection).cgColor
		stroke.strokeColor = InterfacePalette.archive.resolvedColor(with: traitCollection).cgColor
	}
}
