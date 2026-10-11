import SwiftUI

/// A purely local, lightweight microphone visualization. Never requests extra
/// transcription, FFT, network or audio capture; uses levels already measured
/// by NativeRecorder's input tap.
struct MicrophoneWaveform: View {
    let levels: [Double]
    let recording: Bool

    var body: some View {
        Canvas { context, size in
            let center = size.height * 0.5
            let count = levels.count
            guard count > 0 else { return }
            let step = size.width / CGFloat(count)

            if !recording {
                for i in 0..<count {
                    let x = (CGFloat(i) + 0.5) * step
                    let dot = CGRect(x: x - 1.35, y: center - 1.35,
                                     width: 2.7, height: 2.7)
                    context.fill(Path(ellipseIn: dot),
                                 with: .color(.white.opacity(0.78)))
                }
                return
            }

            // Keep the reference's dotted axis beneath the animated waveform.
            for i in 0..<count {
                let x = (CGFloat(i) + 0.5) * step
                let dot = CGRect(x: x - 0.85, y: center - 0.85,
                                 width: 1.7, height: 1.7)
                context.fill(Path(ellipseIn: dot),
                             with: .color(.white.opacity(0.22)))
            }

            // Recent microphone peaks become a symmetric, smooth audio ribbon.
            // The square-root response makes ordinary conversational speech
            // visible without artificially changing the recorded audio.
            var upper: [CGPoint] = []
            var lower: [CGPoint] = []
            for (index, raw) in levels.enumerated() {
                let normalized = min(1, max(0, raw))
                let response = min(1, pow(normalized, 0.48) * 1.65)
                let leadIn = min(1, Double(index + 1) / 7)
                let amplitude = CGFloat(response * leadIn) * size.height * 0.45
                let x = (CGFloat(index) + 0.5) * step
                upper.append(CGPoint(x: x, y: center - amplitude))
                lower.append(CGPoint(x: x, y: center + amplitude))
            }

            var ribbon = Path()
            if let first = upper.first {
                ribbon.move(to: CGPoint(x: 0, y: center))
                ribbon.addLine(to: first)
                for point in upper.dropFirst() { ribbon.addLine(to: point) }
                for point in lower.reversed() { ribbon.addLine(to: point) }
                ribbon.addLine(to: CGPoint(x: 0, y: center))
                ribbon.closeSubpath()
                context.fill(ribbon, with: .color(.white.opacity(0.94)))
            }
        }
        .frame(height: 52)
        .accessibilityHidden(true)
    }
}
