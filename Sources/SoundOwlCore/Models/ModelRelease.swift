import Foundation

/// A model package SoundOwl knows how to get: where it lives, what it must hash to, and the
/// credits shown in Settings › Model. Pinned in the app, so a release always downloads exactly the
/// package it was tested with.
public struct ModelRelease: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let packageVersion: Int
    public let url: URL
    public let sha256: String
    public let bytes: Int64
    public let summary: String
    public let credits: [Credit]
    public let links: [Link]

    public struct Credit: Sendable, Hashable {
        public let part: String
        public let authors: String
        public let license: String
    }

    public struct Link: Sendable, Hashable {
        public let title: String
        public let url: URL
    }

    /// Developers can point the download elsewhere (a local server, a mirror). The checksum still
    /// has to match, so this can only ever deliver the same package.
    public static let urlOverrideKey = "ModelDownloadURL"

    public var downloadURL: URL {
        SharedDefaults.defaults.string(forKey: Self.urlOverrideKey).flatMap(URL.init(string:)) ?? url
    }
}

public extension ModelRelease {
    static let lavaSRv2 = ModelRelease(
        id: "lavasr-v2",
        name: "LavaSR v2",
        packageVersion: 1,
        url: URL(string: "https://github.com/fanckush/SoundOwl/releases/download/model-lavasr-v2-1/lavasr-v2-1.zip")!,
        sha256: "22d4fd9065d3a2d1486767647d8a7c04d7bfb04aca75e361df4c011d85d7b857",
        bytes: 52_616_460,
        summary: String(
            localized: "Restores clarity to voice recordings by rebuilding the frequencies that compression and cheap microphones took away. The optional denoiser removes steady background noise."
        ),
        credits: [
            Credit(part: String(localized: "Speech restoration"), authors: "Yatharth Sharma", license: "Apache-2.0"),
            Credit(part: String(localized: "Noise reduction (UL-UNAS)"), authors: "Xiaobin Rong et al.", license: "MIT")
        ],
        links: [
            Link(title: String(localized: "Paper"), url: URL(string: "https://arxiv.org/abs/2603.07285")!),
            Link(title: String(localized: "Source code"), url: URL(string: "https://github.com/ysharma3501/LavaSR")!),
            Link(title: String(localized: "Original weights"), url: URL(string: "https://huggingface.co/YatharthS/LavaSR")!)
        ]
    )
}
