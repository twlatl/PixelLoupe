// Checks a Sparkle update signature the way Sparkle does before installing an update: the file's Ed25519 (EdDSA)
// signature against the public key in the app's Info.plist (SUPublicEDKey). Scripts/release.sh runs it on each
// release's disk image, so a signature the app would reject never reaches the update feed.
//
//   xcrun swift Scripts/verify-update-signature.swift <file> <signature, base64> <public key, base64>
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: verify-update-signature.swift <file> <signature> <public key>\n".utf8))
    exit(64)
}
guard let file = FileManager.default.contents(atPath: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let keyData = Data(base64Encoded: arguments[3]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write(Data("Couldn't read the file, the signature or the public key.\n".utf8))
    exit(1)
}
guard publicKey.isValidSignature(signature, for: file) else {
    FileHandle.standardError.write(Data("\(arguments[1]): the signature doesn't verify with SUPublicEDKey.\n".utf8))
    exit(1)
}
print("\((arguments[1] as NSString).lastPathComponent): the update signature verifies with SUPublicEDKey.")
