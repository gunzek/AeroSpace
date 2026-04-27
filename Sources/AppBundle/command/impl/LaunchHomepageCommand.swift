import AppKit
import Common

/// Personal-fork command. Lets the user bind `launch-homepage` in
/// `[mode.main.binding]` (e.g. `alt-h = 'launch-homepage'`) — the same
/// flow the Settings UI button triggers. Doesn't take any arguments;
/// reads the live UISettingsStore state.
struct LaunchHomepageCommand: Command {
    let args: LaunchHomepageCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        let state = UISettingsStore.shared.state
        if state.appRouting.isEmpty {
            return .fail(io.err("App Routing list is empty — nothing to launch."))
        }
        await launchHomepage(state)
        return .succ
    }
}
