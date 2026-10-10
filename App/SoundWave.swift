import SwiftUI

struct SoundWave: View {
    let levels: [CGFloat]
    let waiting: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !waiting)) { context in
            HStack(spacing: 4) {
                ForEach(0..<40, id: \.self) { index in
                    let pulse = waiting ? 0.12 + 0.10 * CGFloat(sin(context.date.timeIntervalSinceReferenceDate * 3 - Double(index) * 0.3) + 1) : levels[index]
                    Capsule().fill(.white.opacity(waiting ? 0.5 : 0.9))
                        .frame(width: 3, height: max(3, min(1, pulse) * 64))
                }
            }.frame(maxWidth: .infinity).frame(height: 70)
        }.accessibilityHidden(true)
    }
}
