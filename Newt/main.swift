import AppKit

// `brew uninstall` runs this while the bundle is still on disk, to unwind the
// one thing that outlives it: the entries Newt wrote into other tools' own
// configuration, which would otherwise keep firing at an app that is gone.
// Handled before NSApplication starts, so no icon or window ever appears.
//
// Deliberately not a CLI — nothing is symlinked onto PATH and there is nothing
// here a user is meant to run. Scope is exactly what the flag name says: the
// login item is left to macOS, which invalidates it when the bundle goes, and
// sleep is left to the helper, which restores `disablesleep 0` by itself when
// the running app's XPC connection drops.
if CommandLine.arguments.contains("--uninstall-integrations") {
    for agent in IntegrationInstaller.all {
        do {
            switch try IntegrationInstaller.uninstall(agent) {
            case .removed: print("removed Newt's \(agent.name) integration")
            default: break
            }
        } catch {
            // Uninstall must not fail because one agent's config is unreadable.
            print("could not remove Newt's \(agent.name) integration: \(error)")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
