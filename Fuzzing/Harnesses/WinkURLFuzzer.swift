import Foundation

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzWinkURL(_ data: UnsafePointer<UInt8>?, _ size: Int) -> Int32 {
    guard let data else {
        return 0
    }

    let bytes = UnsafeBufferPointer(start: data, count: size)
    let rawValue = String(decoding: bytes, as: UTF8.self)

    #if WINK_FUZZ_SYNTHETIC_FAILURE
    // Opt-in proof for the artifact-minimization workflow. Normal fuzz builds
    // never contain this branch. The minimized input is already covered by
    // WinkURLCommandTests.malformedPercentEscapesHaveABoundedReason.
    if rawValue.contains("wink://focus?bundle=%ZZ") {
        abort()
    }
    #endif

    let first = WinkURLCommand.parseResult(rawValue)
    let second = WinkURLCommand.parseResult(rawValue)

    precondition(first == second, "URL parsing must be deterministic")
    if case .success = first {
        precondition(
            rawValue.utf8.count <= WinkURLCommand.maximumURLByteCount,
            "accepted URL exceeded the parser byte limit"
        )
    }

    return 0
}
