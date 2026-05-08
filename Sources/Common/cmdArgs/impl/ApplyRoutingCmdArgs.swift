/// Personal-fork command — re-snaps every currently-open window to the
/// workspace + slot defined by its AppRoutingRule. Like the "Apply to open
/// windows" Settings UI button, but bindable as a keyboard shortcut so the
/// user can recover from a layout that drifted (manual moves, crashes, …)
/// without opening Settings. Distinct from `launch-homepage`, which also
/// opens missing apps and spawns extra windows.
public struct ApplyRoutingCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .applyRouting,
        allowInConfig: true,
        help: "Re-snap currently-open windows to the workspace and slot defined by their App Routing rule.",
        flags: [:],
        posArgs: [],
    )
}
