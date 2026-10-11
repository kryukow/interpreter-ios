import SwiftUI
import UIKit

// Native touch down/up events. These controls are outside the scrolling transcript.
struct PressButton: UIViewRepresentable {
    let title: String
    let subtitle: String
    let pressed: Bool
    let enabled: Bool
    let begin: () -> Void
    let end: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.isExclusiveTouch = true
        button.layer.cornerRadius = 26
        button.clipsToBounds = true
        button.addTarget(context.coordinator, action: #selector(Coordinator.down), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.up), for: [.touchUpInside, .touchUpOutside])
        button.addTarget(context.coordinator, action: #selector(Coordinator.abort), for: .touchCancel)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled
        var config = UIButton.Configuration.plain()
        config.title = title; config.subtitle = subtitle
        config.image = UIImage(systemName: pressed ? "waveform" : "mic.fill")
        config.preferredSymbolConfigurationForImage = .init(pointSize: 30, weight: .medium)
        config.imagePlacement = .top; config.imagePadding = 13
        config.titleAlignment = .center
        config.baseForegroundColor = pressed ? .white : .black
        config.titleTextAttributesTransformer = .init { incoming in
            var attributes = incoming
            attributes.font = .systemFont(ofSize: 21, weight: .semibold)
            return attributes
        }
        button.configuration = config
        button.backgroundColor = pressed ? UIColor(white: 0.18, alpha: 1) : .white
        button.alpha = enabled ? 1 : 0.45
        button.accessibilityLabel = title + ". " + subtitle
        button.accessibilityHint = "Удерживай, дождись вибросигнала, говори. Отпусти для перевода."
    }
    final class Coordinator: NSObject {
        var parent: PressButton
        private var downNow = false
        init(_ parent: PressButton) { self.parent = parent }
        @objc func down() {
            guard !downNow else { return }
            downNow = true; parent.begin()
        }
        @objc func up() {
            guard downNow else { return }
            downNow = false; parent.end()
        }
        @objc func abort() {
            guard downNow else { return }
            downNow = false; parent.cancel()
        }
    }
}
