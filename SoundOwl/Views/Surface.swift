import SwiftUI

extension View {
    /// The one surface style for SoundOwl's own panels: Liquid Glass where the system has it,
    /// a material everywhere else.
    @ViewBuilder
    func soundOwlSurface(cornerRadius: CGFloat = 18) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator.opacity(0.5)))
        }
    }
}
