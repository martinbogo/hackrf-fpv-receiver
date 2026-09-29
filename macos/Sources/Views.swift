import SwiftUI

struct ContentView: View {
    @EnvironmentObject var rx: Receiver

    var body: some View {
        VideoPane()
            .frame(minWidth: 520, minHeight: 390)
            .inspector(isPresented: $rx.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 270, ideal: 300, max: 400)
            }
            .navigationTitle("FPV Receiver")
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .sheet(isPresented: scanSheetShown) { ScanSheet() }
    }

    private var subtitle: String {
        switch rx.source {
        case .file(let name): return "Replaying \(name)"
        case .noDevice: return "No HackRF"
        default: return "\(rx.current.name) · \(rx.current.band.title) · \(rx.current.mhz) MHz"
        }
    }

    private var scanSheetShown: Binding<Bool> {
        Binding(get: { rx.scan != .idle }, set: { if !$0 { rx.scan = .idle } })
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { rx.step(-1) } label: { Label("Previous Channel", systemImage: "chevron.left") }
                .help("Previous channel (⌘[)")
            ChannelMenu()
            Button { rx.step(1) } label: { Label("Next Channel", systemImage: "chevron.right") }
                .help("Next channel (⌘])")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { rx.findVTX() } label: { Label("Find VTX", systemImage: "antenna.radiowaves.left.and.right") }
                .help("Search all 48 channels for the video transmitter")
                .disabled(rx.source != .live)
            Button { rx.snapshot() } label: { Label("Snapshot", systemImage: "camera") }
                .help("Save the current frame to Pictures (⇧⌘S)")
                .disabled(rx.image == nil)
            Button { rx.toggleRecording() } label: {
                if rx.recording != nil {
                    Label("Stop Recording", systemImage: "stop.circle.fill").foregroundStyle(.red)
                } else {
                    Label("Record", systemImage: "record.circle")
                }
            }
            .help(rx.recording != nil ? "Stop recording (⌘R)" : "Record video to Movies/FPV Receiver (⌘R)")
            Button { rx.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

struct ChannelMenu: View {
    @EnvironmentObject var rx: Receiver

    var body: some View {
        Menu {
            ForEach(Channels.bands, id: \.letter) { band in
                Section("\(band.letter) · \(band.title)") {
                    ForEach(Channels.all.filter { $0.band == band }) { ch in
                        Button {
                            rx.channel = ch.number
                        } label: {
                            if ch.number == rx.channel {
                                Label(ch.label, systemImage: "checkmark")
                            } else {
                                Text(ch.label)
                            }
                        }
                    }
                }
            }
        } label: {
            Text(rx.current.name).monospacedDigit()
        }
        .help("Choose a channel")
    }
}

struct VideoPane: View {
    @EnvironmentObject var rx: Receiver

    var body: some View {
        ZStack {
            Color.black
            if let img = rx.image, rx.hasSignal || isFile {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
            }
            statusOverlay
            VStack {
                HStack {
                    if let started = rx.recordingStarted { RecordingBadge(started: started) }
                    Spacer()
                }
                Spacer()
                if let notice = rx.notice {
                    Text(notice)
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                }
            }
            .padding(14)
            .animation(.easeInOut(duration: 0.2), value: rx.notice)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { rx.step(-1); return .handled }
        .onKeyPress(.rightArrow) { rx.step(1); return .handled }
    }

    private var isFile: Bool { if case .file = rx.source { return true } else { return false } }

    @ViewBuilder private var statusOverlay: some View {
        switch rx.source {
        case .noDevice(let msg):
            VStack(spacing: 10) {
                Image(systemName: "cable.connector.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                Text(msg).font(.title3)
                Text("Connect the HackRF with the PortaPack in HackRF mode. It is picked up automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Retry") { rx.connect() }
                    Button("Open IQ Recording…") { rx.openFile() }
                }
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .foregroundStyle(.white)
        case .live where !rx.hasSignal:
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 36))
                Text("No video on \(rx.current.name) (\(rx.current.mhz) MHz)")
                    .font(.title3)
                Button("Find VTX") { rx.findVTX() }
            }
            .foregroundStyle(.white.opacity(0.85))
        case .starting:
            ProgressView().controlSize(.large)
        default:
            EmptyView()
        }
    }
}

struct RecordingBadge: View {
    let started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { ctx in
            let s = Int(ctx.date.timeIntervalSince(started))
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(String(format: "REC %d:%02d", s / 60, s % 60)).monospacedDigit()
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject var rx: Receiver

    var body: some View {
        Form {
            Section("Channel") {
                Picker("Band", selection: bandBinding) {
                    ForEach(Channels.bands, id: \.letter) { Text($0.letter).tag($0.letter).help($0.title) }
                }
                .pickerStyle(.segmented)
                Picker("Slot", selection: slotBinding) {
                    ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Channel", value: "\(rx.current.name)  (\(rx.current.band.title))")
                LabeledContent("Frequency", value: "\(rx.current.mhz) MHz")
                LabeledContent("Measured carrier", value: carrierText)
            }

            Section {
                Toggle("RF amplifier", isOn: $rx.ampOn)
                Toggle("Automatic gain", isOn: $rx.autoGain)
                gainRow("LNA", value: $rx.lna, range: 0...40, step: 8)
                gainRow("VGA", value: $rx.vga, range: 0...62, step: 2)
            } header: {
                Text("Receiver")
            } footer: {
                Text("Keep the RF amplifier off when the drone is close. It switches itself off if the level passes -6 dBFS.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Picture") {
                Toggle("Color", isOn: $rx.color)
                LabeledContent("Saturation") {
                    Slider(value: $rx.saturation, in: 0...2.5)
                        .disabled(!rx.color)
                }
                Picker("Deinterlace", selection: $rx.weave) {
                    Text("Bob (smooth motion)").tag(false)
                    Text("Weave (full detail)").tag(true)
                }
                Toggle("Repair interference bands", isOn: $rx.repairBands)
            }

            Section("Signal") {
                stat("Sync lock", rx.hasSignal ? String(format: "%.0f%%", rx.stats.decode.lock * 100) : "–",
                     tint: !rx.hasSignal ? .secondary : rx.stats.decode.lock > 0.95 ? .green : .orange)
                stat("Level", String(format: "%.1f dBFS", rx.stats.decode.dbfs),
                     tint: rx.stats.decode.dbfs > -6 ? .red : rx.stats.decode.dbfs > -12 ? .orange : .primary)
                stat("Line period", rx.hasSignal ? String(format: "%.3f µs", rx.stats.decode.lineMicroseconds) : "–")
                stat("Field lines", rx.stats.decode.fieldLines.map(String.init) ?? "–")
                stat("Click noise", String(format: "%.1f%%", rx.stats.decode.clickPercent))
                stat("Lines repaired", "\(rx.stats.decode.patchedLines)")
                stat("Fields held", "\(rx.stats.heldFields)")
                stat("USB rate", String(format: "%.1f MB/s", rx.stats.usbMBps),
                     tint: rx.source == .live && rx.stats.usbMBps < 39 ? .orange : .primary)
                stat("Display", String(format: "%.0f fps · %.0f ms/frame", rx.stats.fps, rx.stats.decodeMs))
            }
        }
        .formStyle(.grouped)
    }

    private var carrierText: String {
        guard rx.hasSignal, rx.source == .live else { return "–" }
        let mhz = (Double(rx.tunedHz) + rx.stats.decode.carrierOffsetHz) / 1e6
        return String(format: "%.2f MHz (%+.2f)", mhz, mhz - Double(rx.current.mhz))
    }

    private var bandBinding: Binding<String> {
        Binding(get: { rx.current.band.letter }, set: { letter in
            let b = Channels.bands.firstIndex { $0.letter == letter } ?? 0
            rx.channel = b * 8 + rx.current.index
        })
    }

    private var slotBinding: Binding<Int> {
        Binding(get: { rx.current.index }, set: { idx in
            let b = Channels.bands.firstIndex { $0 == rx.current.band } ?? 0
            rx.channel = b * 8 + idx
        })
    }

    private func gainRow(_ title: String, value: Binding<Int>, range: ClosedRange<Double>, step: Double) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                       in: range, step: step)
                Text("\(value.wrappedValue) dB").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
        .disabled(rx.autoGain)
    }

    private func stat(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        LabeledContent(title) { Text(value).monospacedDigit().foregroundStyle(tint) }
    }
}

struct ScanSheet: View {
    @EnvironmentObject var rx: Receiver
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find VTX").font(.headline)
            switch rx.scan {
            case .scanning(let p):
                Text("Listening for PAL video on each channel frequency…")
                ProgressView(value: p)
                HStack { Spacer(); Button("Cancel") { dismiss() }.disabled(true) }
            case let .found(n, carrier):
                let ch = Channels.channel(n)
                Text(String(format: "Video found at %.2f MHz.", carrier))
                Text("Nearest channel: \(ch.name) (\(ch.band.title), \(ch.mhz) MHz)")
                    .font(.title3.weight(.semibold))
                HStack {
                    Spacer()
                    Button("Close") { rx.scan = .idle }
                    Button("Tune to \(ch.name)") { rx.channel = n; rx.scan = .idle }
                        .keyboardShortcut(.defaultAction)
                }
            default:
                Text("No PAL video found on any of the \(Channels.count) channels.")
                Text("Check that the drone is powered and the VTX is not in pit mode, or try enabling the RF amplifier.")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("OK") { rx.scan = .idle }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
