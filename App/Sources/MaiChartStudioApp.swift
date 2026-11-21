import SwiftUI
import MaiCore

@main
struct MaiChartStudioApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var library: Library

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _library = StateObject(wrappedValue: Library(settings: s))
    }

    /// `-screen <name>` opens a specific screen (used for automated screenshots).
    static var launchScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-screen"), i + 1 < args.count { return args[i + 1] }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            RootView(initialScreen: Self.launchScreen)
                .environmentObject(settings)
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(MaiColor.pink)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: Library
    @Environment(\.scenePhase) private var scenePhase
    var initialScreen: String?

    var body: some View {
        HomeView(initialScreen: initialScreen)
            .jobHost()
            .onOpenURL { url in Task { await library.openIncoming(url) } }
            .onChange(of: scenePhase) { phase in
                // like AstroDX: anything dropped into the Import folder is added when the app comes to the front
                let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                if phase == .active && initialScreen == nil && !testing { Task { await library.scanInbox() } }
            }
    }
}

/// Shows import progress, errors and notices in the app's own panels. Applied to the root and to sheets,
/// so they are visible whatever is presented (system alerts can't appear behind a sheet).
struct JobHost: ViewModifier {
    @EnvironmentObject var library: Library

    func body(content: Content) -> some View {
        ZStack {
            content
            if let job = library.job {
                JobOverlay(job: job)
            } else if let message = library.errorMessage {
                MessagePanel(title: "Something went wrong", text: message, icon: "exclamationmark.triangle.fill", color: MaiColor.orange) {
                    library.errorMessage = nil
                }
            } else if let n = library.notice {
                MessagePanel(title: n.title, text: n.text, icon: "checkmark.seal.fill", color: MaiColor.mint) {
                    library.notice = nil
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: library.job == nil)
    }
}

extension View {
    func jobHost() -> some View { modifier(JobHost()) }
}

struct MessagePanel: View {
    let title: String
    let text: String
    let icon: String
    let color: Color
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 34, weight: .bold)).foregroundColor(color)
                Text(title).font(MaiFont.heavy(17)).foregroundColor(.white)
                Text(text).font(MaiFont.body(13)).foregroundColor(.white.opacity(0.9)).multilineTextAlignment(.leading)
                    .lineLimit(16).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("OK", action: onClose)
                    .buttonStyle(MaiButtonStyle(kind: .primary, compact: true))
                    .accessibilityIdentifier("message-ok")
            }
            .padding(22)
            .frame(maxWidth: 340)
            .maiPanel(accent: color)
            .padding(.horizontal, 20)
        }
        .transition(.opacity)
    }
}

struct JobOverlay: View {
    let job: JobState
    @State private var spin = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 10).frame(width: 110, height: 110)
                    Circle().trim(from: 0, to: max(0.03, job.progress))
                        .stroke(AngularGradient(colors: [MaiColor.pink, MaiColor.yellow, MaiColor.cyan, MaiColor.pink], center: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 110, height: 110)
                        .animation(.easeOut(duration: 0.3), value: job.progress)
                    Text("\(Int(job.progress * 100))%").font(MaiFont.title(26)).foregroundColor(.white)
                }
                Text(job.title).font(MaiFont.heavy(16)).foregroundColor(.white).multilineTextAlignment(.center)
                Text(job.stage).font(MaiFont.body(13)).foregroundColor(MaiColor.cyan).multilineTextAlignment(.center)
            }
            .padding(26)
            .frame(maxWidth: 320)
            .maiPanel()
        }
        .transition(.opacity)
    }
}
