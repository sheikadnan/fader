import AppKit
import FaderCore
import SwiftUI

struct MixerView: View {

    let store: MixerStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 360)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Fader").font(.headline)
                Text(store.outputDeviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.rows) { row in
                        MixerRowView(store: store, row: row)
                        Divider().padding(.leading, 40)
                    }
                }
            }
            .frame(maxHeight: 380)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Nothing is playing")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Start audio in any app and it will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 16)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.problems, id: \.self) { problem in
                problemBanner(problem)
            }

            HStack {
                Text("Volume is capped at 100% — Fader never boosts.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func problemBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy & Security settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}

private struct MixerRowView: View {

    let store: MixerStore
    let row: MixerStore.Row

    var body: some View {
        HStack(spacing: 10) {
            icon
            details
            Spacer(minLength: 8)
            muteButton
            slider
            percentage
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            Button(row.isPinned ? "Unpin" : "Pin to top") {
                store.setPinned(!row.isPinned, for: row.id)
            }
            Button("Reset to 100%") { store.reset(row.id) }
                .disabled(row.settings.isPassthrough)
        }
    }

    private var icon: some View {
        Group {
            if let image = row.icon {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "waveform").foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .opacity(row.isPlaying ? 1 : 0.45)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(minWidth: 74, alignment: .leading)
    }

    private var subtitle: String {
        if let problem = row.problem { return problem }
        if !row.isPlaying { return row.processCount > 0 ? "idle" : "not running" }
        return row.processCount > 1 ? "playing · \(row.processCount) processes" : "playing"
    }

    private var muteButton: some View {
        Button {
            store.toggleMute(for: row.id)
        } label: {
            Image(systemName: symbolName)
                .font(.system(size: 11))
                .frame(width: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(row.settings.isMuted ? Color.red : Color.secondary)
        .help(row.settings.isMuted ? "Unmute \(row.name)" : "Mute \(row.name)")
    }

    private var symbolName: String {
        if row.settings.isMuted { return "speaker.slash.fill" }
        if row.settings.volume < 0.34 { return "speaker.fill" }
        if row.settings.volume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var slider: some View {
        Slider(
            value: Binding(
                get: { Double(row.settings.volume) },
                set: { store.setVolume(Float($0), for: row.id) }
            ),
            in: 0...1
        )
        .controlSize(.small)
        .frame(width: 86)
        .disabled(row.settings.isMuted)
    }

    private var percentage: some View {
        Text(row.settings.isMuted ? "—" : "\(Int((row.settings.volume * 100).rounded()))%")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 30, alignment: .trailing)
    }
}
