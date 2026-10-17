// SPDX-License-Identifier: GPL-3.0-or-later
// network-path.swift -- report what kind of network path this Mac is on, for
// network-path.sh. Prints exactly one word and exits 0:
//
//   ok            usable path, neither expensive nor constrained
//   expensive     cellular or a personal hotspot (NWPath.isExpensive)
//   constrained   Low Data Mode is on for the network (NWPath.isConstrained)
//   no-network    no usable path
//
// Checked in that order: no-network, then constrained, then expensive.
// Anything else (no path update within 5 s, a crash) is an error: nothing on
// stdout and a non-zero exit.
//
// The monitor runs on its own queue, and the first path update prints and
// exits from there. The one public example of this check, a Homebrew gist,
// is reported to crash when Low Data Mode is on.
//
// network-path.sh runs this file with `swift`, which compiles it on every
// run. To compile it once instead, build it and point NETWORK_PATH_SWIFT at
// the binary:
//   swiftc -O network-path.swift -o network-path

import Foundation
import Network

let queue = DispatchQueue(label: "network-path")
let monitor = NWPathMonitor()

monitor.pathUpdateHandler = { path in
    let word: String
    if path.status != .satisfied {
        word = "no-network"
    } else if path.isConstrained {
        word = "constrained"
    } else if path.isExpensive {
        word = "expensive"
    } else {
        word = "ok"
    }
    print(word)
    fflush(stdout)
    exit(0)
}
monitor.start(queue: queue)

queue.asyncAfter(deadline: .now() + 5) {
    FileHandle.standardError.write("network-path: no path update within 5 s\n".data(using: .utf8)!)
    exit(1)
}

dispatchMain()
