import Foundation

/// config.json as a JSON object. An edit through it changes the keys that it
/// names and keeps every other key as the file holds it: a key that this
/// version of the app does not know, and a value that the `AdvisorConfig`
/// decode would drop or refuse. A key that an edit writes gets the app's
/// value whole, so a field inside it that this version does not know is lost.
/// The Preferences window, the recording
/// window's context save and the Files tab all edit the file this way, so a
/// copy of the config that a window loaded earlier never writes a setting
/// that the user did not change there (code review 2026-11-10).
enum ConfigFile {
    enum Contents {
        case missing
        /// The file cannot be read, is not a JSON object, or is JSON that the
        /// sidecar reads in another way (`readsAsTheSidecar`).
        case unusable
        /// The file's object, and its bytes for the `AdvisorConfig` decode.
        case object([String: Any], Data)
    }

    static func read(at url: URL) -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary,
            let json = object as? [String: Any],
            // Swift's String equality merges two keys that differ only in
            // normal form (NFC and NFD), which the file and Node keep apart;
            // a write of the merged object would delete one.
            json.count == object.count,
            readsAsTheSidecar(data)
        else { return .unusable }
        return .object(json, data)
    }

    /// Write `json` to `url` in one step; false when the write failed.
    static func write(_ json: [String: Any], to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            // `.atomic`: a partial write would leave a file that does not decode.
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            appLog.write("config.json not saved: \(error)")
            return false
        }
    }

    /// Whether the sidecar's `JSON.parse` reads `data`, which Swift's parser
    /// reads, to the same values. Swift's parser also takes UTF-16 and UTF-32,
    /// a leading byte-order mark and a trailing comma, which the sidecar
    /// refuses (it reads the file as UTF-8), and it keeps the first of two
    /// equal keys where Node keeps the last. The sidecar then uses no folders,
    /// or other folders, than the Files tab would show (code review
    /// 2026-11-10). So such a file counts as one that cannot be used. `data`
    /// must be JSON that Swift's parser reads.
    static func readsAsTheSidecar(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        // UTF-8 only: UTF-16 and UTF-32 text holds NUL bytes or is not UTF-8.
        guard String(data: data, encoding: .utf8) != nil, !bytes.contains(0) else { return false }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return false }
        // A key as its UTF-8 bytes: Node compares keys by code point, and
        // Swift's String equality would match an NFC key with its NFD form.
        enum Container {
            case array
            case object(Set<[UInt8]>)
        }
        var containers: [Container] = []
        var expectKey = false
        var afterComma = false
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D:
                i += 1
                continue
            case UInt8(ascii: "{"):
                containers.append(.object([]))
                expectKey = true
            case UInt8(ascii: "["):
                containers.append(.array)
                expectKey = false
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if afterComma { return false }
                containers.removeLast()
                expectKey = false
            case UInt8(ascii: ","):
                if case .object = containers.last { expectKey = true }
                afterComma = true
                i += 1
                continue
            case UInt8(ascii: "\""):
                var end = i + 1
                while end < bytes.count, bytes[end] != UInt8(ascii: "\"") {
                    end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1
                }
                guard end < bytes.count else { return false }
                if expectKey, case .object(var keys) = containers.last {
                    guard let key = (try? JSONSerialization.jsonObject(
                            with: Data(bytes[i...end]), options: .fragmentsAllowed)) as? String,
                        keys.insert(Array(key.utf8)).inserted
                    else { return false }
                    containers[containers.count - 1] = .object(keys)
                }
                expectKey = false
                i = end
            default:
                expectKey = false
            }
            afterComma = false
            i += 1
        }
        return true
    }
}
