/// Personal-fork command — opens every app in the App Routing list and
/// (for rules with multi-slot definitions) sends ⌘N until each app has
/// the configured number of windows. Used as the target for keybindings
/// like `alt-h = 'launch-homepage'` so the user can trigger their full
/// workspace from the keyboard, not only the menubar Settings UI.
public struct LaunchHomepageCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .launchHomepage,
        allowInConfig: true,
        help: "Launch every app in the App Routing list and ensure each has the configured number of windows.",
        flags: [:],
        posArgs: [],
    )
}
