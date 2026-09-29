import Foundation
import HerdrKit

// Placeholder: the full CLI arrives with the control server (milestone 6).
let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "version", "--version":
    print("ghr 0.1.0")
default:
    FileHandle.standardError.write(Data("usage: ghr <command>\n".utf8))
    exit(64)
}
