import SwiftUI

@main
struct FPVReceiverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var rx = Receiver.shared

    var body: some Scene {
        Window("FPV Receiver", id: "main") {
            ContentView().environmentObject(rx)
        }
        .defaultSize(width: 1120, height: 700)
        .commands { AppCommands(rx: rx) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { Receiver.shared.shutdown() }
}

struct AppCommands: Commands {
    @ObservedObject var rx: Receiver

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open IQ Recording…") { rx.openFile() }
                .keyboardShortcut("o")
            Button("Use HackRF") { rx.connect() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button(rx.recording == nil ? "Start Recording" : "Stop Recording") { rx.toggleRecording() }
                .keyboardShortcut("r")
            Button("Save Snapshot") { rx.snapshot() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(rx.image == nil)
            Button("Show Recordings in Finder") { rx.revealRecordings() }
        }
        CommandMenu("Channel") {
            Button("Next Channel") { rx.step(1) }.keyboardShortcut("]")
            Button("Previous Channel") { rx.step(-1) }.keyboardShortcut("[")
            Divider()
            ForEach(Channels.bands, id: \.letter) { band in
                Menu("\(band.letter) · \(band.title)") {
                    ForEach(Channels.all.filter { $0.band == band }) { ch in
                        Button(ch.label) { rx.channel = ch.number }
                    }
                }
            }
            Divider()
            Button("Find VTX…") { rx.findVTX() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(rx.source != .live)
        }
        CommandGroup(after: .sidebar) {
            Button(rx.showInspector ? "Hide Inspector" : "Show Inspector") { rx.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
