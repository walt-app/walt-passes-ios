import Foundation

/// Indirection over a "kill the renderer" action so ``RenderWatchdog`` is
/// testable without taking down the test process. Mirrors Android's
/// `ProcessKiller` seam.
///
/// On Android the production implementation calls
/// `Process.killProcess(Process.myPid())`, taking down the isolated renderer
/// service. On iOS there is no isolated process to kill: the PDF renderer
/// runs in-process, and calling `exit()` would terminate the host app — the
/// opposite of the trust claim. The production iOS implementation therefore
/// records the kill request without exiting; the surface above (the importer)
/// folds the watchdog timeout into ``PassesPDFCore/DocumentRejectedKind/rendererFailed``
/// via the watchdog's failure path. Test fakes substitute a recording killer
/// so the timeout behaviour can be pinned without taking down the test
/// process. The protocol is `internal` because the abstraction has no
/// consumer outside this module.
package protocol ProcessKiller: Sendable {
    func killSelf()
}

/// Production no-op. Documented above: iOS cannot safely terminate the
/// renderer in the same process as the consumer's UI, so the watchdog
/// surfaces timeouts through the rejection enum rather than via process death.
package struct RealProcessKiller: ProcessKiller {
    package init() {}
    package func killSelf() {}
}
