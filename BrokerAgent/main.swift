// main.swift

import Darwin

// Broker launch agent.
//
// This process exists for one reason: a plain double-clicked app cannot publish
// a named mach service. `NSXPCListener(machServiceName:)` only works when
// launchd owns the name, and launchd only learns a name from a launchd plist.
// So the name is declared in the launch agent plist named by
// `ServiceNames.agentPlistName` (under `Support/`), launchd reserves it, and
// starts this process on demand when anything connects. Every identifier
// involved lives in `ServiceNames.swift` -- nothing here spells one out.
//
// This issue (#0045) only delivers the target itself -- built, embedded at
// Contents/MacOS/BrokerAgent, and registered with launchd via the embedded
// plist. The broker's actual behaviour (exporting an XPC service, holding the
// app's endpoint) is #0046.

exit(0)
