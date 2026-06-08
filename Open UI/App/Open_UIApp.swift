import SwiftUI
import WidgetKit
import BackgroundTasks
import UIKit
import AVFoundation
import Photos

// MLX is always present when either audio framework is linked.
// Import it unconditionally so we can set Memory.cacheLimit at startup
// before the Metal GPU runtime inflates its buffer pool.
#if canImport(MLX)
import MLX
#endif

// MARK: - App Delegate + Scene Delegate (handles home screen Quick Actions)
//
// In a scene-based SwiftUI app (UIApplicationSceneManifest_Generation = YES),
// UIApplicationDelegate.performActionFor is NEVER called for shortcut items.
// iOS routes them to the UIWindowSceneDelegate instead:
//   • Cold launch  → scene(_:willConnectTo:options:)  (connectionOptions.shortcutItem)
//   • Warm launch  → windowScene(_:performActionFor:completionHandler:)

final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Pending shortcut action type string, set by the scene delegate.
    /// Consumed by the `scenePhase == .active` handler in `Open_UIApp`.
    static var pendingShortcutAction: String?

    /// Return a scene configuration that uses our custom SceneDelegate.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = ShortcutSceneDelegate.self
        return config
    }
}

/// Scene delegate that intercepts shortcut items on both cold and warm launch.
final class ShortcutSceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// **Cold launch**: shortcut item arrives in connectionOptions.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcutItem = connectionOptions.shortcutItem {
            AppDelegate.pendingShortcutAction = shortcutItem.type
        }
    }

    /// **Warm launch**: app already running / suspended when user taps a quick action.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        AppDelegate.pendingShortcutAction = shortcutItem.type
        completionHandler(true)
    }
}

@main
struct Open_UIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var dependencies = AppDependencyContainer()
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Limit the MLX Metal GPU buffer-recycling cache to 20 MB.
        //
        // By default, MLX sizes its cache to `recommendedMaxWorkingSetSize`, which
        // scales with device RAM (e.g. ~2 GB on an iPhone with 8 GB RAM). The cache
        // stays inflated even when no model is loaded, causing ~500 MB of "dirty"
        // memory at startup that iOS counts against our memory footprint. Setting a
        // small limit here means the cache is immediately trimmed on the next
        // deallocation event rather than staying large until the app backgrounds.
        //
        // 20 MB is the value from Apple's own MLX iOS guide. It's enough for smooth
        // TTS/ASR inference without the startup memory spike.
        #if canImport(MLX)
        Memory.cacheLimit = 20 * 1024 * 1024  // 20 MB
        #endif

        // Establish the global AVAudioSession baseline at launch.
        // .playAndRecord ignores the hardware silent switch (unlike .ambient/.soloAmbient).
        // .defaultToSpeaker routes to the main loud speaker rather than the earpiece.
        // .mixWithOthers prevents interrupting music/podcasts from other apps.
        // .allowBluetoothHFP/.allowBluetoothA2DP keep BT headsets and CarPlay connected.
        //
        // Setting this BEFORE any WKWebView is created ensures the WebContent process
        // inherits the "ignore silent switch" behavior. Individual services (TTS, voice call)
        // can adjust category/mode on the same shared session as needed, then the JS
        // audioSessionHandler re-asserts .playback when HTML audio starts.
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]
        )
        try? audioSession.setActive(true)

        // Remove the default circular/pill-shaped backgrounds from navigation
        // bar toolbar buttons that iOS adds in dark mode (iOS 15+).
        let plainButtonAppearance = UIBarButtonItemAppearance(style: .plain)
        plainButtonAppearance.normal.titleTextAttributes = [:]
        plainButtonAppearance.highlighted.titleTextAttributes = [:]

        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.buttonAppearance = plainButtonAppearance
        navBarAppearance.doneButtonAppearance = plainButtonAppearance

        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(dependencies)
                .task {
                    // Wire the router into the dependency container so AuthViewModel
                    // can reset navigation on server switch (must be done after both
                    // objects are injected into the environment).
                    dependencies.router = router
                }
                .preferredColorScheme(dependencies.appearanceManager.resolvedColorScheme)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        // Notify connection monitor that the app is in the foreground.
                        // This triggers an immediate health check + socket reconnect,
                        // cancelling any pending backoff timer so recovery is instant.
                        dependencies.connectionMonitor.markAppForeground()
                        dependencies.socketService?.resetBackoffAndReconnect()

                        // Re-check for app + server updates whenever the app returns
                        // to the foreground (handles the case where an update ships
                        // while the app is backgrounded). Fails silently on any error.
                        Task {
                            async let appCheck: () = dependencies.updateChecker.checkForUpdates()
                            async let serverCheck: () = dependencies.serverUpdateChecker.checkForUpdates(using: dependencies.apiClient)
                            _ = await (appCheck, serverCheck)
                        }

                        // Process pending actions after a short delay so that
                        // MainChatView / iPadMainChatView have time to mount
                        // their .onReceive handlers before we post notifications.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            // 1. Quick Action from home screen long-press
                            if let action = AppDelegate.pendingShortcutAction {
                                AppDelegate.pendingShortcutAction = nil
                                handleShortcutAction(action)
                            }

                            // 2. Control Center widget action (cross-process via UserDefaults)
                            let defaults = UserDefaults(suiteName: SharedDataService.appGroupId)
                            if let ccAction = defaults?.string(forKey: "pendingControlCenterAction") {
                                defaults?.removeObject(forKey: "pendingControlCenterAction")
                                handleControlCenterAction(ccAction)
                            }

                            // 3. Pending shared content from Share Extension
                            if defaults?.data(forKey: "pending_shared_content") != nil {
                                handleSharedContent()
                            }
                        }
                    }
                    if newPhase == .inactive || newPhase == .background {
                        // Notify connection monitor + socket that we're backgrounding.
                        // Suppresses false "server down" overlays caused by the OS
                        // suspending network activity and cancels reconnect timers
                        // that would waste battery in the background.
                        dependencies.connectionMonitor.markAppBackground()
                        dependencies.socketService?.markAppBackground()
                        // Stop on-device TTS (Kokoro/Qwen3) before backgrounding to prevent
                        // Metal GPU crash (kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted).
                        // .inactive fires before .background, giving us time to release GPU resources.
                        //
                        // Server TTS (AVQueuePlayer) is intentionally NOT stopped — it uses no GPU
                        // and continues playing in the background when UIBackgroundModes includes "audio".
                        let tts = dependencies.textToSpeechService
                        let session = AVAudioSession.sharedInstance()
                        print("🌙[APP] scenePhase=\(newPhase) — tts.activeEngine=\(tts.activeEngine) tts.state=\(tts.state)")
                        print("🌙[APP] AudioSession before BG — category=\(session.category.rawValue) mode=\(session.mode.rawValue) isActive=\(session.isOtherAudioPlaying)")
                        if tts.activeEngine == .kokoro || tts.activeEngine == .qwen3 {
                            print("🌙[APP] Stopping on-device TTS (Kokoro/Qwen3) before background")
                            tts.stop()
                        }
                        // Guard stopAndUnload() — it calls audioPlayer.stop() which calls
                        // AVAudioSession.setActive(false) on the shared session, killing
                        // AVQueuePlayer (server TTS) mid-playback. Skip it when server TTS
                        // is actively playing so background audio continues uninterrupted.
                        if tts.activeEngine != .server {
                            print("🌙[APP] Calling kokoroService.stopAndUnload() — engine is \(tts.activeEngine), not server")
                            tts.kokoroService.stopAndUnload()
                        } else {
                            print("🌙[APP] ✅ Skipping stopAndUnload() — server TTS is active, keeping audio session alive")
                        }
                        print("🌙[APP] AudioSession after BG handling — category=\(session.category.rawValue) mode=\(session.mode.rawValue)")

                        // ASR background safety: pause on-device transcription on iOS < 26.
                        //
                        // iOS < 26: Metal GPU access is forbidden in the background. Calling
                        // pauseForBackground() cancels the in-flight MLX task and unloads the
                        // model BEFORE iOS revokes GPU access, preventing the uncatchable
                        // std::runtime_error crash. ChatViewModel catches .backgroundInterrupted
                        // and auto-restarts transcription when the app returns to foreground.
                        //
                        // iOS 26+: BGContinuedProcessingTask + Background GPU Access entitlement
                        // keeps the GPU alive in the background, so pauseForBackground() is a
                        // no-op and transcription continues uninterrupted for minutes.
                        dependencies.asrService.pauseForBackground()

                        // STORAGE FIX: Run routine cleanup when entering background.
                        // Cleans orphaned temp files, prunes upload cache, evicts
                        // oversized image cache. Zero user intervention needed.
                        StorageManager.shared.performRoutineCleanup()
                    }
                }
                .task {
                    // STORAGE FIX: Run cleanup on app launch to handle accumulated
                    // data from previous sessions (orphaned files, stale caches, etc.)
                    StorageManager.shared.performRoutineCleanup()

                    // Initialize notification service: registers categories and
                    // requests permission if not yet determined. Also acts as a
                    // fallback safety net in notifyGenerationComplete() in case
                    // the user hasn't been prompted yet.
                    await NotificationService.shared.setup()

                    // Wire notification tap to router
                    NotificationService.shared.onOpenChat = { conversationId in
                        router.navigate(to: .chatDetail(conversationId: conversationId))
                    }

                    // Request Photos "add-only" permission at startup so that
                    // "Save to Photos" works the first time a user taps it.
                    // Uses .addOnly (not .readWrite) — we only ever write to Photos,
                    // never read the library. If already granted/denied, this is a no-op.
                    let photosStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                    if photosStatus == .notDetermined {
                        _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    }
                }
                .onOpenURL { url in
                    if url.isFileURL {
                        handleIncomingFileURL(url)
                    } else {
                        handleDeepLink(url)
                    }
                }
        }
    }

    /// Handles a file URL received via "Open In" / document import from another app.
    /// Reads the file data, creates a ChatAttachment, and navigates to a new chat
    /// with the file pre-attached in the input field.
    private func handleIncomingFileURL(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return }

        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let imageExts = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp"]
        let isImage = imageExts.contains(ext)

        let thumbnail: Image? = isImage ? UIImage(data: data).map { Image(uiImage: $0) } : nil
        let attachment = ChatAttachment(
            type: isImage ? .image : .file,
            name: fileName,
            thumbnail: thumbnail,
            data: data
        )

        dependencies.pendingIncomingFile = attachment
        dependencies.pendingIncomingFileVersion += 1
        dependencies.activeChatStore.remove(nil)
        router.navigate(to: .newChat)
    }

    /// Handles deep links from widgets and external sources.
    private func handleDeepLink(_ url: URL) {
        guard let host = url.host() else { return }

        switch host {
        case "new-chat":
            // Widget "Ask Open Relay" bar → new chat with keyboard auto-focus.
            // Posts a notification that MainChatView/iPadMainChatView handle directly
            // (they own the activeConversationId state, not the router).
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            ShortcutDonationService.donateNewChat()

        case "voice-call":
            // Widget mic button → voice call. Posts a notification that
            // MainChatView/iPadMainChatView handle by creating a VoiceCallViewModel
            // and presenting it via router.presentVoiceCall(viewModel:).
            NotificationCenter.default.post(name: .openUIWidgetVoiceCall, object: nil)
            ShortcutDonationService.donateVoiceCall()

        case "new-note":
            router.navigate(to: .notesList)

        case "continue":
            if let conversationId = SharedDataService.shared.lastActiveConversationId {
                router.navigate(to: .chatDetail(conversationId: conversationId))
            }

        case "camera-chat":
            // Widget camera button → new chat + open camera immediately.
            // Posts newChatWithFocus first (MainChatView/iPadMainChatView handle
            // creating the new chat via local state), then after a delay posts
            // the camera notification which ChatDetailView handles.
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUICameraChat, object: nil)
            }

        case "photos-chat":
            // Widget photos button → new chat + open photo picker immediately.
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUIPhotosChat, object: nil)
            }

        case "file-chat":
            // Widget files button → new chat + open file picker immediately.
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUIFileChat, object: nil)
            }

        case "new-channel":
            // Signal the main view to open the create-channel sheet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .openUINewChannel, object: nil)
            }

        case "chat":
            // openui://chat/{conversationId}
            // FIX: Validate conversation ID format before navigating to prevent
            // malicious deep links from causing confusing UX.
            let conversationId = url.pathComponents.last ?? ""
            if !conversationId.isEmpty && conversationId != "/"
                && conversationId.count >= 8 && conversationId.count <= 128
                && conversationId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                router.navigate(to: .chatDetail(conversationId: conversationId))
            }

        case "note":
            // openui://note/{noteId}
            // FIX: Validate note ID format before navigating.
            let noteId = url.pathComponents.last ?? ""
            if !noteId.isEmpty && noteId != "/"
                && noteId.count >= 8 && noteId.count <= 128
                && noteId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                router.navigate(to: .noteEditor(noteId: noteId))
            }

        case "shared-content":
            // openui://shared-content
            // Posted by the Share Extension after writing SharedContent to App Group UserDefaults.
            // Delay slightly so the main app has time to finish launching / foregrounding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                handleSharedContent()
            }

        default:
            break
        }
    }

    /// Reads SharedContent written by the Share Extension, converts it to
    /// chat attachments / input text, and opens a new chat.
    private func handleSharedContent() {
        guard let content = dependencies.processPendingSharedContent() else { return }

        var attachments: [ChatAttachment] = []
        var inputText: String = ""

        // --- Files / images ---
        for sharedFile in content.fileAttachments {
            let ext = URL(fileURLWithPath: sharedFile.name).pathExtension.lowercased()
            let imageExts = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp"]
            let isImage = imageExts.contains(ext)
                || sharedFile.mimeType?.hasPrefix("image/") == true
            let thumbnail: Image? = isImage
                ? UIImage(data: sharedFile.data).map { Image(uiImage: $0) }
                : nil
            attachments.append(ChatAttachment(
                type: isImage ? .image : .file,
                name: sharedFile.name,
                thumbnail: thumbnail,
                data: sharedFile.data
            ))
        }

        // --- Legacy image data (older extension builds) ---
        for imageData in content.imageData {
            let thumbnail = UIImage(data: imageData).map { Image(uiImage: $0) }
            attachments.append(ChatAttachment(
                type: .image,
                name: "image.jpg",
                thumbnail: thumbnail,
                data: imageData
            ))
        }

        // --- URLs → web-scraping pipeline (scrape + upload, not plain text) ---
        // processWebURL() is called in ChatDetailView via applyShareExtensionHandlers
        // once the new chat is open and the view model is ready.
        let urlStrings = content.urls
        if !urlStrings.isEmpty {
            dependencies.pendingIncomingWebURLs = urlStrings
            dependencies.pendingIncomingWebURLsVersion += 1
        }

        // --- Plain text ---
        if let text = content.text, !text.isEmpty {
            inputText = text
        }

        // If we have attachments, inject the first one as pendingIncomingFile and
        // store the rest in pendingIncomingExtraAttachments. Then open a new chat.
        if let first = attachments.first {
            dependencies.pendingIncomingFile = first
            // Store any additional attachments (multi-file share)
            if attachments.count > 1 {
                dependencies.pendingIncomingExtraAttachments = Array(attachments.dropFirst())
            }
            dependencies.pendingIncomingFileVersion += 1
        }

        if !inputText.isEmpty {
            dependencies.pendingIncomingText = inputText
            dependencies.pendingIncomingTextVersion += 1
        }

        dependencies.activeChatStore.remove(nil)
        router.navigate(to: .newChat)
    }

    // MARK: - Overlay Dismissal

    /// Dismisses all presented overlays (camera, file picker, voice call, sheets, etc.)
    /// before starting a new quick action so they don't stack on top of each other.
    /// Posts a broadcast notification that ChatDetailView, MainChatView, and
    /// iPadMainChatView each listen for to reset their local overlay booleans.
    private func dismissAllOverlays() {
        NotificationCenter.default.post(name: .openUIDismissOverlays, object: nil)
        router.dismissVoiceCall()
        router.dismissSheet()
    }

    // MARK: - Quick Action Handlers

    /// Maps a `UIApplicationShortcutItemType` string (from Info.plist) to the
    /// corresponding NotificationCenter post so MainChatView / iPadMainChatView
    /// can react. Called from the `scenePhase == .active` handler after a delay.
    private func handleShortcutAction(_ type: String) {
        // Dismiss any existing overlays first so new action doesn't stack
        dismissAllOverlays()

        // Short delay to let SwiftUI animate the dismissal before presenting new overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch type {
            case "com.openui.openui.new-chat":
                NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
                ShortcutDonationService.donateNewChat()

            case "com.openui.openui.voice-call":
                NotificationCenter.default.post(name: .openUIWidgetVoiceCall, object: nil)
                ShortcutDonationService.donateVoiceCall()

            case "com.openui.openui.camera-chat":
                NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(name: .openUICameraChat, object: nil)
                }

            case "com.openui.openui.new-channel":
                NotificationCenter.default.post(name: .openUINewChannel, object: nil)

            default:
                break
            }
        }
    }

    /// Handles a pending action written to shared UserDefaults by the
    /// Control Center widget extension (runs in a separate process).
    private func handleControlCenterAction(_ action: String) {
        // Dismiss any existing overlays first so new action doesn't stack
        dismissAllOverlays()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch action {
            case "new-chat":
                NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
                ShortcutDonationService.donateNewChat()
            default:
                break
            }
        }
    }
}

// MARK: - App Launch Screen

/// A single floating ambient orb used in the launch screen background.
private struct LaunchOrb: View {
    let color: Color
    let size: CGFloat
    @State private var offset: CGSize = .zero
    @State private var opacity: Double = 0

    var body: some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: size, height: size)
            .blur(radius: size * 0.4)
            .offset(offset)
            .onAppear {
                let randomX = CGFloat.random(in: -120...120)
                let randomY = CGFloat.random(in: -120...120)
                withAnimation(.easeInOut(duration: Double.random(in: 6...10)).repeatForever(autoreverses: true)) {
                    offset = CGSize(width: randomX, height: randomY)
                }
                withAnimation(.easeInOut(duration: 2)) {
                    opacity = Double.random(in: 0.15...0.35)
                }
            }
    }
}

/// Animated launch screen shown during app startup (session validation / restore).
/// Fades away smoothly to reveal the chat view underneath — no jarring swap.
private struct AppLaunchView: View {
    @Environment(\.theme) private var theme

    // Pulse animation state
    @State private var pulse = false

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            // Ambient floating orbs
            LaunchOrb(color: theme.brandPrimary, size: 200)
                .offset(x: -80, y: -200)
            LaunchOrb(color: theme.brandPrimary.opacity(0.6), size: 160)
                .offset(x: 100, y: -100)
            LaunchOrb(color: theme.brandPrimary.opacity(0.4), size: 120)
                .offset(x: -60, y: 180)
            LaunchOrb(color: theme.info.opacity(0.3), size: 140)
                .offset(x: 80, y: 250)

            // Centered logo with pulsing rings
            VStack(spacing: 28) {
                ZStack {
                    // Outer pulsing ring
                    Circle()
                        .stroke(theme.brandPrimary.opacity(0.15), lineWidth: 1.5)
                        .frame(width: pulse ? 160 : 130, height: pulse ? 160 : 130)
                        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)

                    // Inner pulsing ring
                    Circle()
                        .stroke(theme.brandPrimary.opacity(0.25), lineWidth: 1.5)
                        .frame(width: pulse ? 128 : 110, height: pulse ? 128 : 110)
                        .animation(.easeInOut(duration: 1.6).delay(0.2).repeatForever(autoreverses: true), value: pulse)

                    // Solid background circle
                    Circle()
                        .fill(theme.brandPrimary.opacity(0.08))
                        .frame(width: 100, height: 100)

                    // App icon
                    Image("AppIconImage")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                // App name
                Text("Open Relay")
                    .scaledFont(size: 28, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.textPrimary)
            }
        }
        .onAppear {
            pulse = true
        }
    }
}

/// Launch screen that shows error + retry when session restore fails.
private struct AppLaunchErrorView: View {
    let error: String
    let onRetry: () -> Void
    let onSwitchAccount: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            LaunchOrb(color: theme.brandPrimary, size: 200)
                .offset(x: -80, y: -200)
            LaunchOrb(color: theme.brandPrimary.opacity(0.4), size: 120)
                .offset(x: -60, y: 180)

            VStack(spacing: 20) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.textTertiary)

                Text("Connection Issue")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)

                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.body.weight(.medium))
                        .frame(minWidth: 140)
                        .frame(height: 50)
                        .foregroundStyle(theme.buttonPrimaryText)
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.buttonPrimary)
                )
                .padding(.top, 4)

                Button("Sign in with different account", action: onSwitchAccount)
                    .font(.footnote)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, 2)
            }
        }
    }
}

/// Root view that manages the full authentication flow using a phase-based state machine.
struct RootView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @State private var showOnboarding = false
    @State private var showSettings = false
    @State private var hasAttemptedRestore = false

    // Launch overlay — starts visible for any startup path that needs validation.
    // Set to true only when we begin from an authenticated/restoring phase (i.e. a
    // saved session exists). Fades out smoothly once validation/restore is complete.
    @State private var launchOverlayVisible: Bool
    // Separate opacity so we can animate the fade independently of visibility.
    @State private var launchOverlayOpacity: Double

    init() {
        // We need to decide at init time (before the view mounts) whether to
        // show the launch overlay. If the app is starting into an auth-needing
        // state (serverConnection, authMethodSelection etc.) we skip it.
        // Only optimistic-auth and restoring-session paths need it.
        // We can't access @Environment here, so we peek at the raw UserDefaults/
        // Keychain state. The easiest proxy is to check the ServerConfigStore directly.
        let store = ServerConfigStore()
        let needsOverlay: Bool
        if let active = store.activeServer {
            needsOverlay = KeychainService.shared.hasToken(forServer: active.url)
        } else {
            needsOverlay = false
        }
        _launchOverlayVisible = State(initialValue: needsOverlay)
        _launchOverlayOpacity = State(initialValue: needsOverlay ? 1.0 : 0.0)
    }

    private var viewModel: AuthViewModel {
        dependencies.authViewModel
    }

    var body: some View {
        ZStack {
            // ── Background layer: the full phase-based content ──
            phaseContent
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.phase)

            // ── Foreground layer: launch overlay (fades out on top) ──
            if launchOverlayVisible {
                launchOverlay
                    .opacity(launchOverlayOpacity)
                    .ignoresSafeArea()
                    // Disable interaction once fading so the chat underneath is tappable
                    .allowsHitTesting(launchOverlayOpacity > 0.05)
            }
        }
        .task {
            viewModel.runLegacyMigrationIfNeeded()

            guard !hasAttemptedRestore else { return }
            hasAttemptedRestore = true

            guard dependencies.serverConfigStore.activeServer != nil else {
                dismissLaunchOverlay()
                return
            }

            switch viewModel.phase {
            case .authenticated:
                // Optimistic auth — chat view is already rendered underneath the overlay.
                // Validate token silently, then fade the overlay away.
                await viewModel.validateSessionInBackground()
                dismissLaunchOverlay()
            case .restoringSession:
                // Have token but no cached user — restore first, then fade away.
                await viewModel.restoreSession()
                // Only dismiss if restore succeeded (phase changed to .authenticated).
                // If it failed, errorMessage will be set and overlay shows the error UI.
                if viewModel.phase == .authenticated {
                    dismissLaunchOverlay()
                }
                // Error path: overlay stays visible and switches to the error UI.
            case .authMethodSelection:
                await viewModel.fetchBackendConfigIfNeeded()
                dismissLaunchOverlay()
            default:
                dismissLaunchOverlay()
            }
        }
    }

    /// Fades the launch overlay out smoothly.
    private func dismissLaunchOverlay() {
        withAnimation(.easeInOut(duration: 0.45)) {
            launchOverlayOpacity = 0.0
        }
        // Remove from hierarchy after the fade completes to avoid blocking touches.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            launchOverlayVisible = false
        }
    }

    // MARK: - Launch Overlay Content

    @ViewBuilder
    private var launchOverlay: some View {
        if let error = viewModel.errorMessage, viewModel.phase == .restoringSession {
            // Session restore failed — show error + retry inside the overlay.
            AppLaunchErrorView(
                error: error,
                onRetry: {
                    Task { await viewModel.retrySessionRestore()
                        if viewModel.phase == .authenticated {
                            dismissLaunchOverlay()
                        }
                    }
                },
                onSwitchAccount: {
                    viewModel.errorMessage = nil
                    viewModel.phase = .authMethodSelection
                    dismissLaunchOverlay()
                }
            )
            .transition(.opacity)
        } else {
            AppLaunchView()
                .transition(.opacity)
        }
    }

    // MARK: - Phase Content

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .serverConnection:
            ServerConnectionView(viewModel: viewModel)

        case .restoringSession:
            // Render authenticated content behind the overlay so it's ready when overlay fades.
            // If there's an error (after retries exhausted), the overlay shows the error UI.
            authenticatedContent

        case .authMethodSelection:
            NavigationStack {
                AuthMethodSelectionView(viewModel: viewModel)
            }

        case .credentialLogin:
            NavigationStack {
                LoginView(viewModel: viewModel)
            }

        case .signUp:
            NavigationStack {
                SignUpView(viewModel: viewModel)
            }

        case .pendingApproval:
            PendingApprovalView(viewModel: viewModel)

        case .ldapLogin:
            NavigationStack {
                LDAPLoginView(viewModel: viewModel)
            }

        case .ssoLogin:
            NavigationStack {
                SSOAuthView(viewModel: viewModel)
            }

        case .authenticated:
            authenticatedContent

        case .serverSwitcher:
            NavigationStack {
                ScrollView {
                    SavedServersView(viewModel: viewModel, showAddServerButton: true)
                }
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("Switch Server")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var authenticatedContent: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadMainChatView()
            } else {
                MainChatView()
            }
        }
        .overlay {
            // Connection lost overlay — blocks interaction when server/internet is down
            ConnectionOverlayView(monitor: dependencies.connectionMonitor)
        }
        .task {
            // Start the connection monitor once the user is authenticated.
            // This begins NWPathMonitor + /health polling.
            dependencies.startServerConnectionMonitor()
        }
        .task {
            // Check for app updates (App Store) and server updates in parallel.
            // Runs once after authentication on every app launch.
            async let appCheck: () = dependencies.updateChecker.checkForUpdates()
            async let serverCheck: () = dependencies.serverUpdateChecker.checkForUpdates(using: dependencies.apiClient)
            _ = await (appCheck, serverCheck)
        }
        .sheet(isPresented: Binding(
            get: {
                dependencies.updateChecker.availableUpdate != nil ||
                dependencies.serverUpdateChecker.availableUpdate != nil
            },
            set: { isPresented in
                if !isPresented {
                    dependencies.updateChecker.dismissUpdate()
                    dependencies.serverUpdateChecker.dismissUpdate()
                }
            }
        )) {
            CombinedUpdateSheet(
                appUpdate: dependencies.updateChecker.availableUpdate,
                serverUpdate: dependencies.serverUpdateChecker.availableUpdate,
                onDismiss: {
                    dependencies.updateChecker.dismissUpdate()
                    dependencies.serverUpdateChecker.dismissUpdate()
                }
            )
            .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
        }
        .overlay(alignment: .topTrailing) {
            // Floating pill shown when voice call is minimized.
            // Compact 56×56 square anchored top-right — no Spacer/drag so
            // the overlay only intercepts touches directly on the pill itself.
            if router.isVoiceCallMinimized, let vm = router.voiceCallViewModel {
                VoiceCallPillView(
                    viewModel: vm,
                    onExpand: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            router.expandVoiceCall()
                        }
                    },
                    onEndCall: {
                        Task {
                            await vm.endCall()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                router.dismissVoiceCall()
                            }
                        }
                    }
                )
                .padding(.top, 56)
                .padding(.trailing, 12)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: router.isVoiceCallMinimized)
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(
                    userName: viewModel.currentUser?.displayName ?? "there"
                ) {
                    viewModel.markOnboardingSeen()
                }
            }
            .onAppear {
                // Show onboarding for first-time users
                if !viewModel.hasShownOnboarding {
                    showOnboarding = true
                }

                // Update widget data
                WidgetCenter.shared.reloadAllTimelines()

                // Update shared auth state
                SharedDataService.shared.saveAuthState(
                    isAuthenticated: true,
                    userName: viewModel.currentUser?.displayName,
                    serverURL: dependencies.serverConfigStore.activeServer?.url
                )

                // Prefetch the current user's avatar once so every UserAvatar
                // view renders instantly without a shimmer flash.
                // Only fires if a user + baseURL are known at this point;
                // if restoreSession hasn't completed yet, the avatar is prefetched
                // once currentUser becomes available via the .task block below.
                if let userId = viewModel.currentUser?.id,
                   let baseURL = dependencies.apiClient?.baseURL,
                   !userId.isEmpty, !baseURL.isEmpty,
                   let avatarURL = URL(string: "\(baseURL)/api/v1/users/\(userId)/profile/image?v=\(viewModel.profileImageVersion)") {
                    Task {
                        await ImageCacheService.shared.prefetchUserAvatar(
                            url: avatarURL,
                            authToken: dependencies.apiClient?.network.authToken
                        )
                    }
                }
            }
    }
}
