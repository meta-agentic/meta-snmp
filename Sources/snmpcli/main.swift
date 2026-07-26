import Foundation
import MIBKit
import SNMPCore

// Headless driver for exercising the engine against real agents without the
// GUI. Subcommands arrive alongside the protocol operations they drive.

let arguments = CommandLine.arguments.dropFirst()

guard let command = arguments.first else {
    print("""
    snmpcli — headless driver for the SNMP engine

    Usage:
      snmpcli oid <dotted-oid>   Parse and normalise an object identifier
      snmpcli version            Print component versions
    """)
    exit(EXIT_SUCCESS)
}

switch command {
case "version":
    print("MIBKit \(MIBKit.version)")

case "oid":
    guard let raw = arguments.dropFirst().first else {
        FileHandle.standardError.write(Data("error: 'oid' needs a dotted OID\n".utf8))
        exit(EXIT_FAILURE)
    }
    do {
        let oid = try OID(raw)
        print(oid.description)
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }

default:
    FileHandle.standardError.write(Data("error: unknown command '\(command)'\n".utf8))
    exit(EXIT_FAILURE)
}
