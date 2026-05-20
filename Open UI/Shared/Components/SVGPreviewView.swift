import SwiftUI

// MARK: - SVG Preview View

/// Renders SVG code via WKWebView (StreamingWebPreview).
///
/// ## Architecture
/// - During streaming: `StreamingWebPreview(isStreaming: true)` calls `reconcileContent`
///   incrementally so the SVG updates token-by-token with a live preview.
/// - After streaming: `StreamingWebPreview(isStreaming: false)` calls `finalizeContent`
///   exactly once, letting WebKit render the complete SVG — including SMIL animations —
///   without further DOM replacement.
///
/// SwiftDraw is no longer used. WKWebView renders SVG natively and correctly handles
/// animated SVGs (SMIL `<animateTransform>` etc.) which SwiftDraw would only rasterize
/// to a static frame-0 image.
struct SVGPreviewView: View {
    let code: String
    var isStreaming: Bool = false

    @State private var showSource = false
    @State private var codeCopied = false
    @State private var svgHeight: CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if showSource {
                sourceView
                    .transition(.opacity)
            } else {
                webView
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSource)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        )
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "skew")
                    .scaledFont(size: 10, weight: .semibold)
                Text("svg")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.secondary)

            Spacer()

            if isStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.secondary)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSource.toggle()
                    }
                    Haptics.play(.light)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showSource ? "skew" : "chevron.left.forwardslash.chevron.right")
                            .scaledFont(size: 11, weight: .medium)
                        Text(showSource ? "Image" : "Source")
                            .scaledFont(size: 12, weight: .medium)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                UIPasteboard.general.string = code
                Haptics.notify(.success)
                withAnimation(.spring()) { codeCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    withAnimation(.spring()) { codeCopied = false }
                }
            } label: {
                Group {
                    if codeCopied {
                        Label("Copied", systemImage: "checkmark")
                            .transition(.opacity.combined(with: .scale))
                    } else {
                        Label("Copy", systemImage: "square.on.square")
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.3))
    }

    // MARK: - Web View

    /// Always-on WKWebView path.
    /// `isStreaming: true`  → reconcileContent called on each content change (live preview).
    /// `isStreaming: false` → finalizeContent called once (settled, animations run freely).
    private var webView: some View {
        LazyStreamingWebPreview(
            content: code,
            mode: .svg,
            isStreaming: isStreaming,
            isDark: colorScheme == .dark,
            height: $svgHeight
        )
        .frame(height: min(max(svgHeight, 80), 600))
    }

    // MARK: - Source View

    private var sourceView: some View {
        HighlightedSourceView(code: code, language: "xml")
    }
}
