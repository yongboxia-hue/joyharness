import Foundation
import Sparkle

/// In-app updates, via Sparkle.
///
/// Sparkle rather than something hand-written because replacing a running
/// application on someone's machine has a lot of ways to go wrong -- verifying
/// the signature on the download, swapping the bundle atomically, asking for
/// authorisation when /Applications is not writable, relaunching. Sparkle has
/// solved those; a homemade updater would be discovering them one user at a
/// time.
///
/// Checking is on by default. An update the user never installs is the same as
/// no update, and this app's whole point is that it sits in the background --
/// nobody is going to come looking for a download page. They can switch it off
/// in 关于 → 系统, and nothing is ever installed without them agreeing to it.
///
/// The feed and the public key come from Info.plist, which Sparkle reads
/// itself; the only reason this class exists is to expose the automatic-check
/// setting to the UI and to give the menu a "check now" action.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    /// Whether Sparkle checks on its own schedule (daily, per Info.plist).
    @Published var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    /// When the last check happened, for the About page to show.
    @Published private(set) var lastCheckDate: Date?

    private let controller: SPUStandardUpdaterController

    override init() {
        // startingUpdater: true lets Sparkle run its scheduled check without
        // anything else having to remember to start it.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        lastCheckDate = controller.updater.lastUpdateCheckDate
        super.init()
    }

    /// A check the user asked for. Unlike the scheduled one, this always
    /// reports back -- including "you are up to date", which is the answer
    /// someone who just clicked the button is waiting for.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
        lastCheckDate = controller.updater.lastUpdateCheckDate
    }

    /// Whether a check can run right now (it cannot while one is in progress).
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
