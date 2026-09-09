import AppKit
import Sparkle

// Executed only inside the temporary test app created by test_sparkle_release.py.
// Starting the real framework catches missing helper services and bundle configuration errors.
_ = NSApplication.shared
let controller = SPUStandardUpdaterController(startingUpdater: false,
                                             updaterDelegate: nil, userDriverDelegate: nil)
try controller.updater.start()
precondition(controller.updater.updateCheckInterval == 3600)
precondition(!controller.updater.automaticallyChecksForUpdates)
precondition(!controller.updater.automaticallyDownloadsUpdates)
print("Sparkle startup and hourly schedule verified")
