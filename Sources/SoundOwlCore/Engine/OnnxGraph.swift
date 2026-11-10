import Foundation
import OnnxRuntimeBindings

/// One ONNX graph with float tensors in and out, run on the CPU.
final class OnnxGraph {
    /// ORT documents the environment as thread-safe; one per process is the intended use.
    private nonisolated(unsafe) static let environment = Result { try ORTEnv(loggingLevel: .warning) }

    private let session: ORTSession
    private let runOptions: ORTRunOptions

    /// `intraOpThreads` caps the threads one run may use; nil leaves it to ORT (all cores).
    init(url: URL, intraOpThreads: Int? = nil) throws {
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        if let intraOpThreads { try options.setIntraOpNumThreads(Int32(intraOpThreads)) }
        session = try ORTSession(env: Self.environment.get(), modelPath: url.path, sessionOptions: options)
        // The CPU arena otherwise keeps its high-water mark (hundreds of MB for a 30 s chunk) for
        // as long as the app runs. Shrinking after each run costs nothing measurable.
        runOptions = try ORTRunOptions()
        try runOptions.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
    }

    struct Tensor {
        var values: [Float]
        var shape: [Int]
    }

    func run(_ inputs: [String: Tensor], outputs: [String]) throws -> [String: [Float]] {
        // ORT's Objective-C API hands back autoreleased tensors. Without a pool per run they pile
        // up until the thread's pool drains, which for a long restore is never.
        try autoreleasepool { try runUnpooled(inputs, outputs: outputs) }
    }

    private func runUnpooled(_ inputs: [String: Tensor], outputs: [String]) throws -> [String: [Float]] {
        var feeds = [String: ORTValue]()
        for (name, tensor) in inputs {
            precondition(tensor.values.count == tensor.shape.reduce(1, *), "\(name): shape does not match data")
            let data = tensor.values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
            feeds[name] = try ORTValue(tensorData: data, elementType: .float,
                                       shape: tensor.shape.map { NSNumber(value: $0) })
        }
        let results = try session.run(withInputs: feeds, outputNames: Set(outputs), runOptions: runOptions)
        var out = [String: [Float]]()
        for name in outputs {
            guard let value = results[name] else { throw EngineError.missingOutput(name) }
            let data = try value.tensorData() as Data
            out[name] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return out
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case missingOutput(String)
    case invalidModel(String)

    public var description: String {
        switch self {
        case .missingOutput(let name): "The model did not produce \(name)."
        case .invalidModel(let reason): "The model package is not usable: \(reason)"
        }
    }
}
