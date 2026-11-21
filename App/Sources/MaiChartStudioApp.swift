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
    var initialScreen: String?

    var body: some View {
        ZStack {
            HomeView(initialScreen: initialScreen)
            if let job = library.job { JobOverlay(job: job) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
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
