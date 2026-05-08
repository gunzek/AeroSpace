import AppKit
import Common

/// Personal-fork command that exposes reapplyRoutingAndSlotsToAllWindows as
/// a bindable shortcut. Compared to launch-homepage:
///   - launch-homepage = open every routed app + spawn extra windows + snap
///   - apply-routing = just snap currently-open windows (no opens, no spawns)
/// Use apply-routing as a "fix my layout" panic button.
struct ApplyRoutingCommand: Command {
    let args: ApplyRoutingCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        await reapplyRoutingAndSlotsToAllWindows()
        return .succ
    }
}
