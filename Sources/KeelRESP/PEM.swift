import Foundation

/// One `-----BEGIN <label>-----` block of a PEM file, base64-decoded.
public struct PEMBlock: Sendable, Equatable {
    public var label: String
    /// RFC 1421 headers such as `Proc-Type: 4,ENCRYPTED` (legacy OpenSSL key encryption).
    public var headers: [String: String]
    public var der: Data
}

public enum PEM {
    /// Every well-formed block in `data`, in file order. Text outside blocks (comments, `openssl x509 -text`
    /// output) is ignored; a block whose body isn't base64 is skipped rather than guessed at.
    public static func blocks(in data: Data) -> [PEMBlock] {
        let text = String(decoding: data, as: UTF8.self)
        var blocks: [PEMBlock] = []
        var label: String?
        var headers: [String: String] = [:]
        var body = ""
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = marker(line, "BEGIN") {
                label = open; headers = [:]; body = ""
            } else if let close = marker(line, "END") {
                if close == label, let der = Data(base64Encoded: body) { blocks.append(PEMBlock(label: close, headers: headers, der: der)) }
                label = nil
            } else if label != nil {
                if let colon = line.firstIndex(of: ":") {
                    headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                } else {
                    body += line
                }
            }
        }
        return blocks
    }

    private static func marker(_ line: String, _ kind: String) -> String? {
        let prefix = "-----\(kind) ", suffix = "-----"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count else { return nil }
        return String(line.dropFirst(prefix.count).dropLast(suffix.count))
    }
}
