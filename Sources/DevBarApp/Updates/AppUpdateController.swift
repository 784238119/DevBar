import Foundation
import Observation
import Sparkle

@MainActor
protocol AppUpdateBackend: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
}

@MainActor
final class SparkleUpdateBackend: AppUpdateBackend {
    private let controller: SPUStandardUpdaterController

    init(startingUpdater: Bool = true) {
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
@Observable
final class AppUpdateController {
    static let releasesURL = URL(string: "https://github.com/784238119/DevBar/releases")!

    private let backend: any AppUpdateBackend
    private var isSynchronizing = false

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard !isSynchronizing else { return }
            backend.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    init(backend: any AppUpdateBackend) {
        self.backend = backend
        automaticallyChecksForUpdates = backend.automaticallyChecksForUpdates
    }

    convenience init() {
        self.init(backend: SparkleUpdateBackend())
    }

    func checkForUpdates() {
        backend.checkForUpdates()
    }

    func synchronize() {
        isSynchronizing = true
        automaticallyChecksForUpdates = backend.automaticallyChecksForUpdates
        isSynchronizing = false
    }
}

@MainActor
final class DisabledUpdateBackend: AppUpdateBackend {
    var automaticallyChecksForUpdates = false

    func checkForUpdates() {}
}
