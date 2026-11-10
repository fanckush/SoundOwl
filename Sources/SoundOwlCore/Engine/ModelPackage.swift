import Foundation

/// A model package on disk: the folder produced by `tools/model-export/export.py`.
public struct ModelPackage: Sendable {
    public let directory: URL
    public let manifest: Manifest

    public init(directory: URL) throws {
        self.directory = directory
        let url = directory.appending(path: "model.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EngineError.invalidModel("model.json is missing in \(directory.path)")
        }
        manifest = try JSONDecoder().decode(Manifest.self, from: data)
        for name in manifest.files.keys where !FileManager.default.fileExists(atPath: directory.appending(path: name).path) {
            throw EngineError.invalidModel("\(name) is missing")
        }
    }

    public struct Manifest: Codable, Sendable {
        public let id: String
        public let name: String
        public let packageVersion: Int
        public let pipeline: Pipeline
        public let files: [String: File]

        public struct Pipeline: Codable, Sendable {
            public let modelSampleRate: Int
            public let outputSampleRate: Int
            public let bwe: Stage
            public let denoiser: Stage
            public let merge: Merge
        }

        public struct Stage: Codable, Sendable {
            public let file: String
            public let nFFT: Int
            public let hop: Int
        }

        public struct Merge: Codable, Sendable {
            public let cutoffHz: Double
            public let transitionBins: Int
        }

        public struct File: Codable, Sendable {
            public let sha256: String
            public let bytes: Int
        }
    }
}
