import Foundation
import Darwin
import NotchCore

// No activation policy, Accessibility, networking, or prompts. The app starts
// this independent child before changing any preference and waits for READY.
let arguments = CommandLine.arguments
#if DEBUG
if arguments.count > 1, arguments[1].hasPrefix("--fixture-") {
    runSystemDockRecoveryFixture(arguments)
}
#endif
guard arguments.count == 4, arguments[1] == "--watch",
      let token = UUID(uuidString: arguments[3]), getuid() == geteuid(), getuid() != 0 else { exit(64) }
let directory = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
guard directory == SystemDockJournalStore.defaultDirectory.standardizedFileURL,
      let helper = SystemDockProcessIdentity.live(getpid()) else { exit(65) }
let engine = SystemDockRecoveryEngine(store: .init(directory: directory), backend: SystemDockNativePreferences())
do {
    guard let journal = try engine.journal(), journal.token == token,
          journal.owner.pid == getppid(), engine.ownerIsAlive(journal) else { exit(66) }
    try engine.registerHelper(token: token, helper: helper)
    try FileHandle.standardOutput.write(contentsOf: Data("READY \(token.uuidString)\n".utf8))
    // A PID is never sufficient: compare UID and kernel process-start time on
    // every check, so PID reuse cannot leave Dock hidden after the parent exits.
    while engine.ownerIsAlive(journal) { Thread.sleep(forTimeInterval: 0.5) }
    var retry = SystemDockRecoveryRetryPolicy()
    while true {
        do {
            _ = try engine.restore(token: token, onlyIfOwnerExited: true)
            exit(0)
        } catch SystemDockRecoveryError.anotherOwner { exit(0) }
        catch {
            // restore() rechecks the token and the parent's complete identity
            // under the file lock on every attempt. Never give up with Dock
            // hidden after a fixed number of transient recovery failures.
            Thread.sleep(forTimeInterval: retry.nextDelay())
        }
    }
} catch { exit(1) }
