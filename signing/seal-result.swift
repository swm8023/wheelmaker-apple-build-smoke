import CryptoKit
import Foundation

let arguments = CommandLine.arguments
let key = SymmetricKey(data: try Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let input = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let sealed = try AES.GCM.seal(input, using: key)
guard let encrypted = sealed.combined else { fatalError("Could not encode encrypted result") }
try encrypted.write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
