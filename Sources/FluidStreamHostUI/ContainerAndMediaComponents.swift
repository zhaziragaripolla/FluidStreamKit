public import SwiftUI
import AVKit
import Foundation

// MARK: - Tabs

struct A2UITabsView: View {
    let context: A2UIComponentContext
    @State private var selected = 0

    var body: some View {
        let tabs = context.value("tabs")?.arrayValue ?? []
        let titles = tabs.enumerated().map { index, tab in
            context.resolve(tab["title"])?.displayString ?? "Tab \(index + 1)"
        }
        VStack(alignment: .leading, spacing: 10) {
            Picker(selection: $selected) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    Text(title).tag(index)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if tabs.indices.contains(selected) {
                context.render(childId: tabs[selected]["child"]?.stringValue)
            }
        }
    }
}

// MARK: - Modal

/// Shows `trigger` inline; tapping it presents `content` in a sheet.
struct A2UIModalView: View {
    let context: A2UIComponentContext
    @State private var isPresented = false

    var body: some View {
        let trigger = context.component["trigger"]?.stringValue
        let content = context.component["content"]?.stringValue
        Button { isPresented = true } label: {
            context.render(childId: trigger)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                ScrollView {
                    context.render(childId: content).padding()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { isPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Video

struct A2UIVideoView: View {
    let context: A2UIComponentContext
    @State private var player: AVPlayer?

    var body: some View {
        let url = context.url("url")
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                AsyncImage(url: context.url("posterUrl")) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                Button {
                    if let url { player = AVPlayer(url: url); player?.play() }
                } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 52)).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .disabled(url == nil)
                .accessibilityLabel("Play video")
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onDisappear { player?.pause() }
    }
}

// MARK: - AudioPlayer

struct A2UIAudioPlayerView: View {
    let context: A2UIComponentContext
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        let url = context.url("url")
        HStack(spacing: 12) {
            Button {
                if player == nil, let url { player = AVPlayer(url: url) }
                if isPlaying { player?.pause() } else { player?.play() }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 36))
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Text(context.string("description") ?? "Audio").font(.subheadline).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .onDisappear { player?.pause(); isPlaying = false }
    }
}
