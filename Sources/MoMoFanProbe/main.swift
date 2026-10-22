import Foundation
import FanCore

do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(SMCClient().snapshot()), as: UTF8.self))
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
