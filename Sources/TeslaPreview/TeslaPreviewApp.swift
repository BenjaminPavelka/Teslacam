import SwiftUI

@main
struct TeslaPreviewApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Tesla Preview") {
            RootView()
                .environment(model)
                .environment(model.library)
                .onAppear {
                    #if DEBUG
                    DebugSnapshot.model = model
                    #endif
                }
                .frame(minWidth: 860, minHeight: 640)
        }
        .commands { CommandGroup(replacing: .newItem) {} }
        Window("Přihlášení k Tesle", id: LoginWindow.id) {
            LoginWindow().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Spuštěno přímo jako binárka (bez .app) by jinak nemělo okno v popředí.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Screen: String, CaseIterable, Identifiable {
    case unlock, library, cleanup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlock: "Odemčení"
        case .library: "Knihovna"
        case .cleanup: "Úklid"
        }
    }

    var icon: String {
        switch self {
        case .unlock: "lock.open"
        case .library: "film.stack"
        case .cleanup: "trash"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Screen.allCases, selection: $model.screen) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch model.screen ?? .unlock {
            case .unlock: UnlockView()
            case .library: LibraryView()
            case .cleanup: CleanupView()
            }
        }
    }
}
