// NewtHelper — a privileged launchd daemon. Installed and started by the Newt
// app via SMAppService; runs as root so it can toggle `pmset disablesleep`.

import Foundation

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

// launchd keeps us alive; spin the run loop to service XPC connections.
RunLoop.main.run()
