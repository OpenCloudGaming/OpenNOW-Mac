import Foundation
import Foundation
import Testing
@testable import OpenNOW

@Test func nativeMetadataPreservesArrayShapeUTF8EmptyStringsAndDuplicates() throws {
    let json = """
    {
      "metaData": [
        {"key":" spaced key ","value":"  spaced value  "},
        {"key":"unicode","value":"Grüße 世界"},
        {"key":"","value":""},
        {"key":"duplicate","value":"first"},
        {"key":"duplicate","value":"last"}
      ]
    }
    """

    let inspected = try inspectMetadata(json)

    #expect(inspected.pairs == [
        MetadataPair(key: " spaced key ", value: "  spaced value  "),
        MetadataPair(key: "unicode", value: "Grüße 世界"),
        MetadataPair(key: "", value: ""),
        MetadataPair(key: "duplicate", value: "first"),
        MetadataPair(key: "duplicate", value: "last"),
    ])
    #expect(inspected.pointersStable)
    #expect(Dictionary(inspected.pairs.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })["duplicate"] == "last")
}

@Test func nativeMetadataRejectsMalformedEntriesWithoutFiltering() {
    let malformed = [
        "{\"metaData\":{\"key\":\"a\",\"value\":\"b\"}}",
        "{\"metaData\":[{\"key\":\"valid\",\"value\":\"entry\"},7]}",
        "{\"metaData\":[{\"key\":\"missing-value\"}]}",
        "{\"metaData\":[{\"key\":7,\"value\":\"not-coerced\"}]}",
        "{\"metaData\":[{\"key\":\"not-coerced\",\"value\":true}]}",
        "{\"metaData\":[{\"key\":\"nul\",\"value\":\"a\\u0000b\"}]}",
    ]

    for json in malformed {
        #expect(throws: MetadataInspectionError.self) {
            _ = try inspectMetadata(json)
        }
    }
}

@Test func nativeMetadataAccepts64EntriesAndRejectsOverflowBeforeIteration() throws {
    let accepted = try metadataJSON(count: 64)
    let overflow = try metadataJSON(count: 65, malformedLastEntry: true)

    let inspected = try inspectMetadata(accepted)

    #expect(inspected.pairs.count == 64)
    #expect(inspected.pairs.last == MetadataPair(key: "key-63", value: "value-63"))
    #expect(inspected.pointersStable)
    #expect(throws: MetadataInspectionError(result: -2, message: "Native Geronimo metadata exceeds the maximum of 64 entries.")) {
        _ = try inspectMetadata(overflow)
    }
}

private struct MetadataPair: Equatable {
    let key: String
    let value: String
}

private struct MetadataInspection {
    let pairs: [MetadataPair]
    let pointersStable: Bool
}

private struct MetadataInspectionError: Error, Equatable {
    let result: Int32
    let message: String
}

private func inspectMetadata(_ json: String) throws -> MetadataInspection {
    var count: UInt32 = 0
    var pointersStable: Int32 = 0
    var error = [CChar](repeating: 0, count: 256)
    let countResult = json.withCString { jsonPointer in
        error.withUnsafeMutableBufferPointer { errorBuffer in
            OpenNOWNativeNVSTGeronimoInspectMetadata(jsonPointer, UInt32.max, nil, 0, nil, 0, &count, &pointersStable, errorBuffer.baseAddress, errorBuffer.count)
        }
    }
    guard countResult == 0 else {
        throw MetadataInspectionError(result: countResult, message: decodedCString(error))
    }

    var pairs: [MetadataPair] = []
    for index in 0..<count {
        var key = [CChar](repeating: 0, count: 1024)
        var value = [CChar](repeating: 0, count: 1024)
        let result = json.withCString { jsonPointer in
            key.withUnsafeMutableBufferPointer { keyBuffer in
                value.withUnsafeMutableBufferPointer { valueBuffer in
                    error.withUnsafeMutableBufferPointer { errorBuffer in
                        OpenNOWNativeNVSTGeronimoInspectMetadata(jsonPointer, index, keyBuffer.baseAddress, keyBuffer.count, valueBuffer.baseAddress, valueBuffer.count, &count, &pointersStable, errorBuffer.baseAddress, errorBuffer.count)
                    }
                }
            }
        }
        guard result == 0 else {
            throw MetadataInspectionError(result: result, message: decodedCString(error))
        }
        pairs.append(MetadataPair(key: decodedCString(key), value: decodedCString(value)))
    }
    return MetadataInspection(pairs: pairs, pointersStable: pointersStable != 0)
}

private func decodedCString(_ buffer: [CChar]) -> String {
    buffer.withUnsafeBufferPointer { pointer in
        guard let baseAddress = pointer.baseAddress else { return "" }
        return String(cString: baseAddress)
    }
}

private func metadataJSON(count: Int, malformedLastEntry: Bool = false) throws -> String {
    var entries: [[String: Any]] = (0..<count).map { ["key": "key-\($0)", "value": "value-\($0)"] }
    if malformedLastEntry, !entries.isEmpty { entries[entries.count - 1]["value"] = true }
    let data = try JSONSerialization.data(withJSONObject: ["metaData": entries], options: [.sortedKeys])
    return try #require(String(data: data, encoding: .utf8))
}

@_silgen_name("OpenNOWNativeNVSTGeronimoInspectMetadata")
private func OpenNOWNativeNVSTGeronimoInspectMetadata(_ geronimoJSON: UnsafePointer<CChar>?, _ index: UInt32, _ keyBuffer: UnsafeMutablePointer<CChar>?, _ keyBufferLength: Int, _ valueBuffer: UnsafeMutablePointer<CChar>?, _ valueBufferLength: Int, _ count: UnsafeMutablePointer<UInt32>?, _ pointersStable: UnsafeMutablePointer<Int32>?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32
