import AppKit
import Combine

@MainActor
final class SwitcherAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.live()
    let updater = AppUpdater()
    let tiboForecast = TiboForecastModel()

    private var modelObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        modelObservation = model.objectWillChange.sink { [weak self] in
            guard let self else { return }
            updater.accountOperationInProgress = model.isMutating || model.isAddingAccount
        }
        updater.start()
        tiboForecast.start()
        Task { await model.startBackgroundUsageRefresh() }
    }
}
