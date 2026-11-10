// Renders the app icon from OwlMark, so the icon and the in-app owl never drift apart.
//
//   scripts/render-icon.sh
//
// Writes AppIcon.appiconset PNGs and the 1024 px master used by the website.
import AppKit
import SwiftUI

struct AppIcon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: an 824 pt rounded square inside the 1024 pt canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.70),
                                              Color(red: 0.12, green: 0.14, blue: 0.30)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 3)
                )
                .overlay(alignment: .topTrailing) {
                    // A moon behind the owl's shoulder.
                    Circle().fill(Color(red: 1.0, green: 0.86, blue: 0.55).opacity(0.9))
                        .frame(width: 130, height: 130)
                        .offset(x: -80, y: 80)
                }
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 14)
            OwlMark(size: 600)
                .offset(y: 50)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
        }
        .frame(width: 1024, height: 1024)
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let image = MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: AppIcon())
    renderer.scale = 1
    return renderer.cgImage
}
guard let image else { fatalError("render failed") }
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try png.write(to: out.appending(path: "icon-1024.png"))
print("wrote \(out.path)/icon-1024.png")
