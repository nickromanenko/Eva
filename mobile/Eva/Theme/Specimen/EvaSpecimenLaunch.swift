#if DEBUG
import Foundation

/// The `EVA_SPECIMEN` launch hook.
///
/// Set `EVA_SPECIMEN=1` in the launch environment and the app shows
/// `EvaSpecimenView` instead of its normal root, so the token and component system can
/// be reviewed and screenshotted from the command line without building a throwaway
/// harness:
///
/// ```sh
/// SIMCTL_CHILD_EVA_SPECIMEN=1 xcrun simctl launch --terminate-running-process <udid> com.evaapp.ios
///
/// `simctl launch` has no `--setenv`: anything after the bundle id is argv, so the app
/// would launch normally and the flag would be silently swallowed. The environment goes
/// in the calling environment with a `SIMCTL_CHILD_` prefix. See mobile/CLAUDE.md.
/// ```
///
/// Same family as `EVA_ONBOARDING_STEP` (`OnboardingModel.init`) and `EVA_UITEST_RESET`
/// (`AppSession.bootstrap`): read once from `ProcessInfo`, DEBUG only. The whole file is
/// inside `#if DEBUG`, so in a Release build this type does not exist and neither does
/// the branch in `EvaApp` that reads it.
enum EvaSpecimenLaunch {

    /// The environment variable that turns the specimen on.
    static let environmentKey = "EVA_SPECIMEN"

    /// Whether this process was launched with `EVA_SPECIMEN=1`.
    ///
    /// Read once at first use rather than on every `body` evaluation — the launch
    /// environment cannot change while the process is alive.
    static let isEnabled = ProcessInfo.processInfo.environment[environmentKey] == "1"
}
#endif
