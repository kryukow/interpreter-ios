import SwiftUI
import UIKit

// UIKit tracking delivers release and cancellation even when a ScrollView wins
// the gesture. A delayed long-press gesture can otherwise miss a quick release.
struct HoldToTalkButton: UIViewRepresentable {
    var title: String
    var subtitle: String
    var active: Bool
    var onBegin: () -> Void
    var onEnd: () -> Void
    var onCancel: () -> Void
    func makeUIView(context: Context) -> HoldControl {
        let view = HoldControl(type: .custom)
        view.isExclusiveTouch = true
        view.layer.cornerRadius = 28
        view.layer.borderWidth = 1
        view.clipsToBounds = true
        return view
    }
    func updateUIView(_ view: HoldControl, context: Context) {
        view.onBegin = onBegin; view.onEnd = onEnd; view.onCancel = onCancel
        var config = UIButton.Configuration.plain()
        config.title = title; config.subtitle = subtitle
        config.image = UIImage(systemName: active ? "waveform" : "mic.fill")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        config.imagePlacement = .top; config.imagePadding = 16; config.titleAlignment = .center
        config.baseForegroundColor = active ? .white : .black
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes; result.font = .systemFont(ofSize: 20, weight: .semibold); return result
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes; result.font = .systemFont(ofSize: 12, weight: .regular); return result
        }
        view.configuration = config
        view.backgroundColor = active ? UIColor(white: 0.16, alpha: 1) : .white
        view.layer.borderColor = UIColor.white.withAlphaComponent(active ? 0.55 : 1).cgColor
        view.accessibilityLabel = title
        view.accessibilityHint = "Удерживай и говори после вибросигнала. Отпусти для перевода. В VoiceOver двойное нажатие начинает или завершает запись."
    }
}

final class HoldControl: UIButton {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?
    private var holding = false
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard !holding else { return false }
        holding = true; onBegin?(); return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard bounds.insetBy(dx: -20, dy: -20).contains(touch.location(in: self)) else {
            abort(); return false
        }
        return holding
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard holding else { return }
        holding = false; onEnd?()
    }
    override func cancelTracking(with event: UIEvent?) { abort() }
    private func abort() {
        guard holding else { return }
        holding = false; onCancel?()
    }
    override func accessibilityActivate() -> Bool {
        if holding { holding = false; onEnd?() }
        else { holding = true; onBegin?() }
        return true
    }
}
