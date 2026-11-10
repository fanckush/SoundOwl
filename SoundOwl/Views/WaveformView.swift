import SwiftUI

/// The recording's loudness as bars, accent coloured up to the playhead. Colour means one thing
/// only: what you've played. Restoring happens out of sight, ahead of you. Click or drag to seek.
struct WaveformView: View {
    var peaks: [Float]
    var position: Double
    var duration: Double
    var seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, geometry.size.width > 0 else { return }
                        seek(min(max(0, value.location.x / geometry.size.width), 1) * duration)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue("\(Format.duration(position)) of \(Format.duration(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(min(duration, position + 10))
            case .decrement: seek(max(0, position - 10))
            @unknown default: break
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let barWidth: CGFloat = 2.5, gap: CGFloat = 1.5
        let bars = max(1, Int(size.width / (barWidth + gap)))
        let loudest = max(peaks.max() ?? 0, 0.01)
        let mid = size.height / 2
        let played = duration > 0 ? position / duration : 0

        func level(_ values: [Float], bar: Int) -> CGFloat {
            guard !values.isEmpty else { return 0 }
            let from = bar * values.count / bars, to = max(from + 1, (bar + 1) * values.count / bars)
            let peak = values[from..<min(to, values.count)].max() ?? 0
            // A gentle curve so quiet passages still show.
            return CGFloat(pow(Double(peak / loudest), 0.8))
        }

        for bar in 0..<bars {
            let x = CGFloat(bar) * (barWidth + gap)
            let height = max(2, level(peaks, bar: bar) * (size.height - 4))
            let rect = CGRect(x: x, y: mid - height / 2, width: barWidth, height: height)
            let isPlayed = Double(bar) / Double(bars) < played
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                         with: .color(isPlayed ? .accentColor : .secondary.opacity(0.45)))
        }

        if duration > 0 {
            let x = CGFloat(played) * size.width
            context.fill(Path(roundedRect: CGRect(x: x - 1, y: 0, width: 2, height: size.height), cornerRadius: 1),
                         with: .color(.accentColor))
        }
    }
}
