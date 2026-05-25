import Foundation
import UIKit
import SwiftTerm
import os.log

/// Manages state for the terminal file browser panel.
///
/// Shell sessions use a **WebSocket** connection that mirrors exactly what the web
/// UI does. No HTTP polling — characters appear instantly.
///
/// Protocol (matches web UI's inspector traffic):
///   1. POST  /api/v1/terminals/{serverId}/api/terminals            → `{"id": "xxxx"}`
///   2. WS    wss(s)://{server}/api/v1/terminals/{serverId}/api/terminals/{id}
///   3. Send  text  `{"type":"auth","token":"<jwt>"}`
///   4. Send  text  `{"type":"resize","cols":N,"rows":M}`
///   5. Recv  binary frames  → feed to SwiftTerm
///   6. Send  binary frames  ← from SwiftTerm keystrokes
///   7. Send  text  `{"type":"ping"}`  every 25 s (keepalive)
///
/// Auto-reconnect: on disconnect the VM waits 1 s, 2 s, 4 s before giving up.
/// Calling `reconnectIfNeeded()` (e.g. when the panel becomes visible) triggers
/// an immediate reconnect attempt regardless of retry state.
@MainActor @Observable
final class TerminalBrowserViewModel {
    // MARK: - File Browser State

    var currentPath: String = "/home/user"
    var items: [TerminalFileItem] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var pathHistory: [String] = []

    // MARK: - Shell Session State

    var isShellStarting: Bool = false
    var isShellReady: Bool = false
    var isTerminalExpanded: Bool = false

    // MARK: - Action State

    var showNewFolderAlert: Bool = false
    var newFolderName: String = ""
    var renamingFile: TerminalFileItem?
    var renameText: String = ""

    // MARK: - SwiftTerm Bridge

    weak var terminalView: TerminalView?

    // MARK: - Private

    private var apiClient: APIClient?
    private var serverId: String = ""
    private let logger = Logger(subsystem: "com.openui", category: "TerminalBrowser")

    // WebSocket state
    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var wsReceiveTask: Task<Void, Never>?
    private var wsPingTask: Task<Void, Never>?
    private var terminalSessionId: String?

    // Auto-reconnect
    private var autoReconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private static let maxReconnectAttempts = 5
    private static let reconnectDelays: [UInt64] = [
        1_000_000_000,   // 1 s
        2_000_000_000,   // 2 s
        4_000_000_000,   // 4 s
        8_000_000_000,   // 8 s
        15_000_000_000,  // 15 s
    ]

    // Terminal dimensions (updated by TerminalHostView on layout)
    var terminalCols: Int = 120
    var terminalRows: Int = 24

    // MARK: - Computed

    var pathSegments: [(name: String, path: String)] {
        let components = currentPath.split(separator: "/").map(String.init)
        var segments: [(name: String, path: String)] = [("/", "/")]
        var accumulated = ""
        for component in components {
            accumulated += "/\(component)"
            segments.append((component, accumulated))
        }
        return segments
    }

    var sortedItems: [TerminalFileItem] {
        let dirs = items.filter(\.isDirectory).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let files = items.filter { !$0.isDirectory }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return dirs + files
    }

    // MARK: - Setup

    func configure(apiClient: APIClient, serverId: String) {
        if self.serverId == serverId, isShellReady { return }
        self.apiClient = apiClient
        self.serverId = serverId
    }

    func reset() {
        cancelAutoReconnect()
        disconnectWebSocket()
        currentPath = "/home/user"
        items = []
        isLoading = false
        errorMessage = nil
        pathHistory = []
        isShellStarting = false
        isShellReady = false
        isTerminalExpanded = false
        showNewFolderAlert = false
        newFolderName = ""
        renamingFile = nil
        renameText = ""
        terminalView = nil
        reconnectAttempt = 0
    }

    // MARK: - Navigation

    func loadDirectory() async {
        guard let apiClient, !serverId.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            items = try await apiClient.terminalListFiles(serverId: serverId, path: currentPath)
        } catch {
            logger.error("Failed to list files at \(self.currentPath): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            items = []
        }
        isLoading = false
    }

    func navigateToDirectory(_ path: String) {
        pathHistory.append(currentPath)
        currentPath = path
        Task { await loadDirectory() }
    }

    func navigateToPath(_ path: String) {
        guard path != currentPath else { return }
        pathHistory.append(currentPath)
        currentPath = path
        Task { await loadDirectory() }
    }

    func navigateBack() {
        guard let previous = pathHistory.popLast() else { return }
        currentPath = previous
        Task { await loadDirectory() }
    }

    func refresh() {
        Task { await loadDirectory() }
    }

    // MARK: - File Operations

    func createFolder(name: String) async {
        guard let apiClient, !serverId.isEmpty else { return }
        let folderPath = currentPath.hasSuffix("/") ? "\(currentPath)\(name)" : "\(currentPath)/\(name)"
        do {
            try await apiClient.terminalMkdir(serverId: serverId, path: folderPath)
            await loadDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteItem(_ item: TerminalFileItem) async {
        guard let apiClient, !serverId.isEmpty else { return }
        do {
            try await apiClient.terminalDeleteFile(serverId: serverId, path: item.path)
            items.removeAll { $0.path == item.path }
        } catch {
            errorMessage = error.localizedDescription
            await loadDirectory()
        }
    }

    func downloadFile(_ item: TerminalFileItem) async -> URL? {
        guard let apiClient, !serverId.isEmpty else { return nil }
        do {
            let (data, _) = try await apiClient.terminalDownloadFile(serverId: serverId, path: item.path)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("terminal_downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent(item.name)
            try data.write(to: fileURL)
            return fileURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func uploadFile(data: Data, fileName: String) async {
        guard let apiClient, !serverId.isEmpty else { return }
        do {
            try await apiClient.terminalUploadFile(
                serverId: serverId, fileData: data, fileName: fileName, destinationPath: currentPath
            )
            await loadDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - WebSocket Shell Session

    /// Start a fresh shell session. Guards against double-start.
    func startShell() async {
        guard let apiClient, !serverId.isEmpty else { return }
        guard !isShellReady, !isShellStarting else { return }

        isShellStarting = true
        do {
            // Step 1: Create terminal session on the server
            let sessionId = try await apiClient.terminalCreateSession(serverId: serverId)
            terminalSessionId = sessionId
            logger.info("Terminal session created: \(sessionId)")

            // Step 2: Build WebSocket URL
            let wsURL = try buildWebSocketURL(sessionId: sessionId)
            logger.info("Connecting WS to: \(wsURL)")

            // Step 3: Connect WebSocket
            connectWebSocket(url: wsURL, token: apiClient.network.authToken ?? "")

            // Reset reconnect counter on successful connect
            reconnectAttempt = 0

        } catch {
            isShellStarting = false
            isShellReady = false
            let errMsg = "\r\n\u{001B}[31m[Failed to start terminal: \(error.localizedDescription)]\u{001B}[0m\r\n"
            feedToTerminal(errMsg)
            logger.error("Failed to start shell: \(error.localizedDescription)")
            // Schedule a retry if we haven't exhausted attempts
            scheduleAutoReconnect()
        }
    }

    /// Call this whenever the terminal panel becomes visible (panel opens,
    /// terminal section expands, fullscreen toggled). If the shell is not
    /// running it will start/reconnect immediately without needing a button tap.
    func reconnectIfNeeded() {
        guard !isShellReady, !isShellStarting else { return }
        guard apiClient != nil, !serverId.isEmpty else { return }
        // Cancel any pending backoff reconnect — we want to reconnect NOW
        cancelAutoReconnect()
        reconnectAttempt = 0
        Task { await startShell() }
    }

    private func buildWebSocketURL(sessionId: String) throws -> URL {
        guard let apiClient else { throw URLError(.badURL) }
        var serverURL = apiClient.baseURL
        // Trim trailing slash
        if serverURL.hasSuffix("/") { serverURL = String(serverURL.dropLast()) }

        // Convert http(s) → ws(s)
        var wsURLString = serverURL
        if wsURLString.hasPrefix("https://") {
            wsURLString = "wss://" + wsURLString.dropFirst("https://".count)
        } else if wsURLString.hasPrefix("http://") {
            wsURLString = "ws://" + wsURLString.dropFirst("http://".count)
        }

        let path = "/api/v1/terminals/\(serverId)/api/terminals/\(sessionId)"
        guard let url = URL(string: wsURLString + path) else {
            throw URLError(.badURL)
        }
        return url
    }

    private func connectWebSocket(url: URL, token: String) {
        // Tear down any existing connection first
        tearDownWebSocket()

        // Create a new URLSession with no timeouts for the WS
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = true
        config.httpCookieStorage = HTTPCookieStorage.shared

        let session = URLSession(configuration: config)
        wsSession = session

        var request = URLRequest(url: url)
        request.timeoutInterval = .infinity
        let task = session.webSocketTask(with: request)
        wsTask = task
        task.resume()

        // Auth handshake — use a small delay so the TCP handshake completes
        // before we send frames. URLSessionWebSocketTask buffers sends, so
        // this is safe even if the connection isn't open yet.
        sendTextFrame(["type": "auth", "token": token])

        // Resize to current terminal dimensions
        sendTextFrame(["type": "resize", "cols": terminalCols, "rows": terminalRows])

        // Start receive loop and ping timer
        wsReceiveTask = Task { await receiveLoop() }
        wsPingTask = Task { await pingLoop() }

        isShellReady = true
        isShellStarting = false
        logger.info("WebSocket connected and authenticated")
    }

    /// Tears down the WS tasks without touching isShellReady/isShellStarting.
    private func tearDownWebSocket() {
        wsReceiveTask?.cancel()
        wsReceiveTask = nil
        wsPingTask?.cancel()
        wsPingTask = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
    }

    private func sendTextFrame(_ dict: [String: Any]) {
        guard let wsTask else { return }
        // URLSessionWebSocketTask buffers messages until the connection is open,
        // so we don't gate on `.running` here — the task may be in `.suspended`
        // briefly right after creation.
        guard wsTask.state != .canceling, wsTask.state != .completed else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        wsTask.send(.string(str)) { [weak self] error in
            if let error {
                self?.logger.error("WS send text error: \(error.localizedDescription)")
            }
        }
    }

    /// Called by `TerminalViewDelegate.send()` — user typed something in SwiftTerm.
    /// Sends the raw bytes as a binary WebSocket frame — exactly what the web UI does.
    func sendRawToServer(_ data: ArraySlice<UInt8>) {
        guard let wsTask, wsTask.state == .running else { return }
        let bytes = Data(data)
        wsTask.send(.data(bytes)) { [weak self] error in
            if let error {
                self?.logger.error("WS send binary error: \(error.localizedDescription)")
            }
        }
    }

    /// Sends a raw control sequence to the shell (Tab, arrows, Ctrl+C, etc.)
    func sendControlSequence(_ bytes: String) {
        guard let data = bytes.data(using: .utf8) else { return }
        guard let wsTask, wsTask.state == .running else { return }
        wsTask.send(.data(data)) { [weak self] error in
            if let error {
                self?.logger.error("WS send ctrl error: \(error.localizedDescription)")
            }
        }
    }

    /// Notifies the server of a terminal resize event.
    func sendResize(cols: Int, rows: Int) {
        terminalCols = cols
        terminalRows = rows
        guard isShellReady else { return }
        sendTextFrame(["type": "resize", "cols": cols, "rows": rows])
    }

    /// Clears the SwiftTerm screen and scrollback.
    func clearTerminal() {
        terminalView?.getTerminal().resetToInitialState()
        sendControlSequence("\u{0C}") // Ctrl+L
    }

    // MARK: - WebSocket Receive Loop

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let wsTask else { break }

            do {
                let message = try await wsTask.receive()
                switch message {
                case .data(let data):
                    // Raw PTY output — feed directly to SwiftTerm
                    let slice = ArraySlice(data)
                    feedBytesToTerminal(slice)

                case .string(let str):
                    // Control messages from server (rare)
                    logger.debug("WS text frame: \(str)")

                @unknown default:
                    break
                }
            } catch {
                if Task.isCancelled { break }
                logger.error("WS receive error: \(error.localizedDescription)")
                await handleDisconnect()
                break
            }
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000_000) // 25 seconds
            if Task.isCancelled { break }
            guard isShellReady else { break }
            guard let wsTask, wsTask.state == .running else {
                // Task is no longer running — handleDisconnect will be called
                // by the receive loop error, so just exit ping loop
                break
            }
            sendTextFrame(["type": "ping"])
        }
    }

    @MainActor
    private func handleDisconnect() async {
        guard isShellReady else { return }
        isShellReady = false
        tearDownWebSocket()
        terminalSessionId = nil
        logger.info("Terminal WebSocket disconnected")

        // Auto-reconnect — only if the terminal panel is still open/expanded
        if isTerminalExpanded {
            scheduleAutoReconnect()
        }
    }

    // MARK: - Auto-reconnect

    private func scheduleAutoReconnect() {
        guard reconnectAttempt < Self.maxReconnectAttempts else {
            // Exhausted retries — show a message so the user knows
            feedToTerminal("\r\n\u{001B}[31m[Connection lost. Tap ↺ to reconnect.]\u{001B}[0m\r\n")
            reconnectAttempt = 0
            return
        }

        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        let attempt = reconnectAttempt
        reconnectAttempt += 1

        logger.info("Auto-reconnect in \(delay / 1_000_000_000)s (attempt \(attempt + 1)/\(Self.maxReconnectAttempts))")

        cancelAutoReconnect()
        autoReconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.startShell()
        }
    }

    private func cancelAutoReconnect() {
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
    }

    // MARK: - Cleanup

    func disconnectWebSocket() {
        cancelAutoReconnect()
        tearDownWebSocket()
        terminalSessionId = nil
        isShellReady = false
        isShellStarting = false
        reconnectAttempt = 0
    }

    // MARK: - Terminal Output Helpers

    /// Feeds raw bytes directly into SwiftTerm (no UTF-8 conversion needed).
    private func feedBytesToTerminal(_ bytes: ArraySlice<UInt8>) {
        terminalView?.feed(byteArray: bytes)
    }

    /// Feeds a string as raw bytes into SwiftTerm (for status messages).
    func feedToTerminal(_ text: String) {
        guard let filteredBytes = text.data(using: .utf8) else { return }
        let slice = ArraySlice(filteredBytes)
        terminalView?.feed(byteArray: slice)
    }
}
