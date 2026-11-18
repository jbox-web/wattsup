// Checks the Rust bindings end to end: polls one UPS and prints what came back.
// Usage: Smoke <host> <port> <nut ups name>
import Foundation
import WattsUpCore

let arguments = CommandLine.arguments
guard arguments.count == 4, let port = UInt16(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: Smoke <host> <port> <nut ups name>\n".utf8))
    exit(2)
}
let entry = UpsEntry(
    name: "smoke", host: arguments[1], port: port, ups: arguments[3],
    publish: false, notifyUnreachable: true, username: nil)
let snapshot = poll(entry: entry, password: nil)
print("state: \(snapshot.state)")
print("charge: \(snapshot.chargePercent.map(String.init) ?? "-")")
print("variables: \(snapshot.vars.count)")
if let error = snapshot.error { print("error: \(error)") }
exit(snapshot.vars.isEmpty ? 1 : 0)
