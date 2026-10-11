import SwiftUI

/// Lightweight, microphone-driven centre-pulsing visualizer.
/// Uses already measured mic peaks and never modifies audio or API traffic.
struct MicrophoneWaveform: View {
    let levels: [Double]
    let recording: Bool

    var body: some View {
        Canvas { context, size in
            let middleY = size.height / 2
            guard !levels.isEmpty, size.width > 0 else { return }

            // Idle state preserves the original fine dotted baseline.
            let points = max(32, Int(size.width / 6))
            let spacing = size.width / CGFloat(points)
            if !recording {
                for i in 0..<points {
                    let x = (CGFloat(i) + 0.5) * spacing
                    let rect = CGRect(x: x - 1.25, y: middleY - 1.25,
                                      width: 2.5, height: 2.5)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(.white.opacity(0.79)))
                }
                return
            }

            // Emphasise actual recent speech, with a nonlinear visual-only gain.
            // No gain is ever applied to the recorded or transmitted audio.
            let tail = levels.suffix(5)
            let recent = tail.reduce(0, +) / Double(max(1, tail.count))
            let voice = min(1, pow(max(0, recent), 0.44) * 1.8)
            let half = Double(max(1, points - 1)) / 2

            for i in 0..<points {
                let x = (CGFloat(i) + 0.5) * spacing
                let distance = abs(Double(i) - half) / half

                // Raised-cosine envelope: strongest at the centre, gradually
                // narrower towards both screen edges, exactly as requested.
                let envelope = pow(max(0, cos(distance * .pi / 2)), 2.1)

                // Symmetrical smaller oscillations sampled from recent real
                // mic levels give a lively, non-repeating silhouette.
                let history = min(levels.count - 1,
                                  Int(distance * Double(min(16, levels.count - 1))))
                let sample = levels[levels.count - 1 - history]
                let texture = 0.58 + 0.42 * min(1, pow(max(0, sample), 0.38) * 2)
                let height = max(2.4, size.height * 0.88 * voice * envelope * texture)
                let width = min(2.8, max(1.75, spacing * 0.42))
                let bar = CGRect(x: x - width / 2,
                                 y: middleY - height / 2,
                                 width: width, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: width / 2),
                             with: .color(.white.opacity(0.95)))
            }
        }
        .frame(height: 58)
        .animation(.linear(duration: 0.085), value: levels)
        .accessibilityHidden(true)
    }
}
