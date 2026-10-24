// Verifies a Sparkle EdDSA signature against a public key, the way an installed Keel checks an update (INT-11):
//   swift scripts/verify-update-signature.swift <base64 public key> <file> <base64 signature>
// Exits 0 when the signature is valid for the file's exact bytes, 1 when it isn't, 2 on bad arguments.
import CryptoKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, let keyData = Data(base64Encoded: arguments[0]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
    let signature = Data(base64Encoded: arguments[2]), let file = FileManager.default.contents(atPath: arguments[1])
else {
    FileHandle.standardError.write(Data("usage: verify-update-signature.swift <public key> <file> <signature>\n".utf8)); exit(2)
}
exit(key.isValidSignature(signature, for: file) ? 0 : 1)
