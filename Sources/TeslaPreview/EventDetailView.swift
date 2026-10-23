import AVFoundation
import Charts
import MapKit
import SwiftUI
import TeslaCamCore

struct EventDetailView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppModel.self) private var app
    let event: LibraryEvent

    @State private var player = MultiCamPlayer()
    @State private var telemetry: [TelemetrySample] = []
    @State private var mainCamera: Camera = .front
    @State private var exportState: ExportState = .idle
    /// Vybraný výřez; ukládá se k události (s malým zpožděním kvůli tažení).
    @State private var range: TrimRange?
    @State private var saveRangeTask: Task<Void, Never>?
    @State private var keyMonitor: Any?

    enum ExportState: Equatable {
        case idle, running(String), done(URL), failed(String)
    }

    var index: EventIndex? { library.indexes[event.id] }

    var body: some View {
        Group {
            if let index {
                content(index)
                    .task {
                        mainCamera = event.primaryCamera
                        range = library.annotation(event.id).range
                        installKeyMonitor()
                        telemetry = await Task.detached { [cache = library.cache, event] in cache.loadTelemetry(event) }.value
                        await player.load(event, index: index)
                        #if DEBUG
                        DebugSnapshot.activePlayer = player
                        #endif
                    }
                    .onDisappear {
                        player.tear()
                        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                        keyMonitor = nil
                    }
                    .onChange(of: range) { persistRange() }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Připravuji událost (délky, telemetrie, náhled)…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func content(_ index: EventIndex) -> some View {
        VStack(spacing: 0) {
            CameraGrid(player: player, cameras: event.cameras, main: $mainCamera,
                       sample: currentSample, clock: clockTime(index))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            transport(index)
            trimBar(index)
            TimelineChart(player: player, samples: telemetry, duration: index.totalDuration,
                          saved: EventIndexer.savedOffset(event, index: index), range: $range)
                .frame(height: 96)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            Divider()
            HStack(alignment: .top, spacing: 16) {
                AnnotationPanel(eventID: event.id)
                    .frame(minWidth: 210, maxWidth: 290)
                infoPanel(index)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RouteMap(samples: telemetry, current: currentSample, fallback: event.metadata?.coordinate)
                    .frame(minWidth: 160, idealWidth: 260, maxWidth: 280, minHeight: 196, maxHeight: 196)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(12)
            .frame(height: 220)
        }
        .overlay(alignment: .top) {
            if let error = player.loadError {
                Label(error, systemImage: "exclamationmark.triangle").padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
            }
        }
    }

    // MARK: Ovládání

    private func transport(_ index: EventIndex) -> some View {
        HStack(spacing: 14) {
            Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .help("Zpět o 10 s (⌘←)")
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
            }
            .disabled(!player.isReady)
            .help("Přehrát / pozastavit (mezerník)")
            Button { player.skip(10) } label: { Image(systemName: "goforward.10") }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .help("Vpřed o 10 s (⌘→)")
            Picker("Rychlost", selection: $player.rate) {
                ForEach([Float(0.25), 0.5, 1, 2, 4, 8], id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            .labelsHidden()
            .frame(width: 70)

            Text("\(Format.clock(player.currentTime)) / \(Format.clock(index.totalDuration))")
                .monospacedDigit()
            if let clock = clockTime(index) {
                Text(Format.timeOfDay(clock)).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            if let saved = EventIndexer.savedOffset(event, index: index) {
                Button { player.seek(to: max(0, saved - 10)) } label: { Label("Na okamžik uložení", systemImage: "flag.fill") }
                    .help("Skočit 10 s před okamžik, kdy se událost uložila")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Výřez

    private func trimBar(_ index: EventIndex) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors").foregroundStyle(.secondary)
            Button { setIn(index) } label: { Label("Začátek (I)", systemImage: "chevron.left.to.line") }
                .help("Začátek výřezu na aktuální pozici (klávesa I)")
            Button { setOut(index) } label: { Label("Konec (O)", systemImage: "chevron.right.to.line") }
                .help("Konec výřezu na aktuální pozici (klávesa O)")
            if let range {
                Text("\(Format.clock(range.start)) – \(Format.clock(range.end)) (\(Format.clock(range.duration)))")
                    .monospacedDigit()
                    .foregroundStyle(.yellow)
                Button { player.play(range: range) } label: { Label("Přehrát výřez", systemImage: "play.rectangle") }
                Button { self.range = nil } label: { Label("Zrušit", systemImage: "xmark.circle") }
            } else {
                Text("Označ část, kterou chceš uložit. Úchyty jdou táhnout i na časové ose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func setIn(_ index: EventIndex) {
        let t = player.currentTime
        let end = range.map(\.end).flatMap { $0 > t + 0.5 ? $0 : nil } ?? index.totalDuration
        range = TrimRange(start: t, end: end)
    }

    private func setOut(_ index: EventIndex) {
        let t = player.currentTime
        let start = range.map(\.start).flatMap { $0 < t - 0.5 ? $0 : nil } ?? 0
        range = TrimRange(start: start, end: t)
    }

    private func persistRange() {
        saveRangeTask?.cancel()
        let id = event.id, value = range
        saveRangeTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            library.update(id) { $0.range = value }
        }
    }

    /// Mezerník, I a O ovládají přehrávač, pokud se zrovna nepíše do textového pole.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [player] event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText),
                  let index = library.indexes[self.event.id]
            else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": player.togglePlay()
            case "i": setIn(index)
            case "o": setOut(index)
            default: return event
            }
            return nil
        }
    }

    /// Skutečný čas na hodinách pro aktuální pozici.
    private func clockTime(_ index: EventIndex) -> Date? {
        let offsets = index.offsets
        guard let i = offsets.lastIndex(where: { $0 <= player.currentTime }), i < event.minutes.count else { return nil }
        return event.minutes[i].start.addingTimeInterval(player.currentTime - offsets[i])
    }

    private var currentSample: TelemetrySample? {
        guard !telemetry.isEmpty else { return nil }
        let t = player.currentTime
        var lo = 0, hi = telemetry.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if telemetry[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        let sample = telemetry[lo]
        return abs(sample.t - t) < 2 ? sample : nil
    }

    // MARK: Informace a export

    private func infoPanel(_ index: EventIndex) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Format.dateTime(event.savedAt)).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            CategoryBadge(category: event.category).fixedSize()
            if let reason = event.metadata?.reasonText { Label(reason, systemImage: "info.circle") }
            if let place = event.metadata?.place { Label(place, systemImage: "mappin.and.ellipse") }
            Label("\(event.minutes.count) min. úseků · \(event.cameras.count) kamer · \(Format.clock(index.totalDuration))",
                  systemImage: "film.stack")
            if index.telemetryCount > 0 {
                TelemetryChips(summary: index.summary)
                if index.summary.brakeEvents > 0 {
                    Text("Brždění: \(index.summary.brakeEvents)×").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Bez telemetrie (auto stálo, nebo starší firmware).").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            exportControls(index)
        }
        .font(.callout)
    }

    @ViewBuilder private func exportControls(_ index: EventIndex) -> some View {
        HStack {
            Menu {
                if let range {
                    Section("Výřez \(Format.clock(range.start))–\(Format.clock(range.end))") {
                        Button("Uložit výřez do knihovny jako novou událost") { saveCut(index, range) }
                        Button("Všechny kamery do složky…") { export(index, .cameras, range: range) }
                        Button("Jen přední kamera…") { export(index, .front, range: range) }
                        Button("Mozaika všech kamer…") { export(index, .mosaic, range: range) }
                    }
                    Section("Celá událost") {
                        Button("Všechny kamery do složky…") { export(index, .cameras) }
                        Button("Jen přední kamera…") { export(index, .front) }
                        Button("Mozaika všech kamer…") { export(index, .mosaic) }
                    }
                } else {
                    Button("Všechny kamery do složky…") { export(index, .cameras) }
                    Button("Jen přední kamera…") { export(index, .front) }
                    Button("Mozaika všech kamer…") { export(index, .mosaic) }
                    Text("Tip: klávesami I a O označíš jen část.")
                }
            } label: {
                Label(range == nil ? "Exportovat…" : "Exportovat výřez…", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .disabled(app.ffmpeg == nil || { if case .running = exportState { return true } else { return false } }())

            switch exportState {
            case .idle: EmptyView()
            case .running(let what):
                ProgressView().controlSize(.small)
                Text(what).font(.caption).foregroundStyle(.secondary)
            case .done(let url):
                Button("Zobrazit ve Finderu") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        if app.ffmpeg == nil { Text(FFmpeg.installHint).font(.caption).foregroundStyle(.orange) }
    }

    private func export(_ index: EventIndex, _ kind: Exporter.Kind, range: TrimRange? = nil) {
        guard let ffmpeg = app.ffmpeg else { return }
        let prefix = Exporter.clipPrefix(event, index: index, range: range) + (range == nil ? "" : "-vyrez")
        let url: URL
        if kind == .cameras {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Exportovat sem"
            panel.message = "Vyber, kam uložit složku „\(prefix)“ se soubory všech kamer"
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            url = dir.appendingPathComponent(prefix)
            if FileManager.default.fileExists(atPath: url.path) {
                exportState = .failed("Složka \(prefix) už tam existuje.")
                return
            }
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = "\(prefix)-\(kind == .front ? "predni" : "mozaika").mp4"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        exportState = .running(kind == .mosaic ? "Exportuji mozaiku, může to chvíli trvat…" : "Exportuji…")
        Task {
            do {
                try await Exporter.export(event, index: index, kind: kind, range: range, to: url, ffmpeg: ffmpeg)
                exportState = .done(url)
            } catch {
                let detail = (error as? FFmpeg.Failure)?.detail ?? error.localizedDescription
                exportState = .failed("Export selhal: \(detail)")
            }
        }
    }

    private func saveCut(_ index: EventIndex, _ range: TrimRange) {
        guard let ffmpeg = app.ffmpeg else { return }
        exportState = .running("Ukládám výřez do knihovny…")
        Task {
            do {
                let id = try await Exporter.saveToLibrary(event, index: index, range: range, root: library.root, ffmpeg: ffmpeg)
                exportState = .idle
                library.reload(select: id)
            } catch {
                let detail = (error as? FFmpeg.Failure)?.detail ?? error.localizedDescription
                exportState = .failed("Uložení výřezu selhalo: \(detail)")
            }
        }
    }
}

// MARK: - Kamery

struct CameraGrid: View {
    let player: MultiCamPlayer
    let cameras: [Camera]
    @Binding var main: Camera
    let sample: TelemetrySample?
    let clock: Date?

    var body: some View {
        GeometryReader { geo in
            let others = cameras.filter { $0 != main }
            let stripHeight = others.isEmpty ? 0 : min(geo.size.height * 0.24, geo.size.width / CGFloat(max(others.count, 1)) / 1.54)
            VStack(spacing: 2) {
                tile(main)
                    .overlay(alignment: .bottom) {
                        if let sample { TelemetryHUD(sample: sample).padding(10) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let clock {
                            Text(Format.dateTime(clock)).font(.caption.monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white).padding(8)
                        }
                    }
                if !others.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(order(others)) { camera in
                            tile(camera)
                                .contentShape(Rectangle())
                                .onTapGesture { main = camera }
                                .help("Zvětšit kameru \(camera.title)")
                        }
                    }
                    .frame(height: stripHeight)
                }
            }
        }
    }

    /// Pořadí jako v autě zleva doprava.
    private func order(_ list: [Camera]) -> [Camera] {
        let preferred: [Camera] = [.leftRepeater, .leftPillar, .front, .back, .rightPillar, .rightRepeater]
        return preferred.filter(list.contains)
    }

    private func tile(_ camera: Camera) -> some View {
        ZStack(alignment: .topLeading) {
            if let p = player.players[camera] {
                PlayerLayerView(player: p)
            } else {
                Color.black
            }
            Text(camera.title).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.white).padding(4)
        }
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}

// MARK: - Telemetrie nad videem

struct TelemetryHUD: View {
    let sample: TelemetrySample

    var body: some View {
        HStack(spacing: 16) {
            blinker(left: true)
            VStack(spacing: 0) {
                Text("\(Int(sample.speedKmh.rounded()))").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .fixedSize()
                Text("km/h").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minWidth: 72)
            HStack(spacing: 3) {
                ForEach([Gear.park, .reverse, .neutral, .drive], id: \.self) { gear in
                    Text(gear.letter).font(.callout.bold())
                        .foregroundStyle(gear == sample.gear ? .primary : .tertiary)
                }
            }
            if sample.autopilot != .none {
                Text(sample.autopilot.title).font(.callout.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(AutopilotColors.color(sample.autopilot), in: Capsule())
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                pedal("Plyn", value: Double(sample.accelerator) / 100, color: .green)
                HStack(spacing: 4) {
                    Circle().fill(sample.brake ? Color.red : Color.gray.opacity(0.3)).frame(width: 9, height: 9)
                    Text("Brzda").font(.caption2).foregroundStyle(sample.brake ? .red : .secondary).fixedSize()
                }
            }
            Image(systemName: "steeringwheel")
                .font(.title2)
                .rotationEffect(.degrees(Double(sample.steering)))
                .help("Volant \(Int(sample.steering))°")
            Text("\(Int(sample.steering))°").font(.caption.monospacedDigit()).frame(width: 36, alignment: .leading)
            blinker(left: false)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
    }

    private func blinker(left: Bool) -> some View {
        let on = left ? sample.blinkLeft : sample.blinkRight
        return Image(systemName: left ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
            .foregroundStyle(on ? Color.green : Color.gray.opacity(0.3))
    }

    private func pedal(_ title: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(.gray.opacity(0.3))
                Capsule().fill(color).frame(width: 40 * min(max(value, 0), 1))
            }
            .frame(width: 40, height: 6)
            Text(title).font(.caption2).foregroundStyle(.secondary).fixedSize()
        }
    }
}

// MARK: - Časová osa s grafem rychlosti

struct TimelineChart: View {
    let player: MultiCamPlayer
    let samples: [TelemetrySample]
    let duration: Double
    let saved: Double?
    @Binding var range: TrimRange?

    @State private var plot: CGRect = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpeedChart(samples: samples, duration: duration, saved: saved)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        let frame = proxy.plotFrame.map { geo[$0] } ?? .zero
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { scrub(at: $0.location.x, frame: frame, exact: false) }
                                .onEnded { scrub(at: $0.location.x, frame: frame, exact: true) })
                            .onAppear { plot = frame }
                            .onChange(of: frame) { plot = frame }
                    }
                }
            if let range, duration > 0, plot.width > 0 {
                let x0 = x(range.start), x1 = x(range.end)
                Rectangle().fill(Color.yellow.opacity(0.18))
                    .overlay(alignment: .top) { Rectangle().fill(Color.yellow).frame(height: 2) }
                    .frame(width: max(1, x1 - x0), height: plot.height)
                    .offset(x: x0, y: plot.minY)
                    .allowsHitTesting(false)
                handle(at: x0) { t in self.range = TrimRange(start: min(t, range.end - 0.5), end: range.end) }
                handle(at: x1) { t in self.range = TrimRange(start: range.start, end: max(t, range.start + 0.5)) }
            }
            // Ukazatel přehrávání odděleně, aby se graf nepřekresloval 20× za sekundu.
            if duration > 0, plot.width > 0 {
                Rectangle().fill(Color.primary)
                    .frame(width: 2, height: plot.height)
                    .offset(x: plot.minX + plot.width * CGFloat(min(player.currentTime / duration, 1)) - 1, y: plot.minY)
                    .allowsHitTesting(false)
            }
            if samples.isEmpty {
                Text("Bez telemetrie: táhni pro posun v čase").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "timeline")
    }

    private func x(_ t: Double) -> CGFloat { plot.minX + plot.width * CGFloat(min(max(t / duration, 0), 1)) }

    private func time(at x: CGFloat) -> Double {
        Double(min(max((x - plot.minX) / plot.width, 0), 1)) * duration
    }

    /// Úchyt výřezu, který jde táhnout; zároveň posouvá přehrávač, ať je vidět záběr.
    private func handle(at position: CGFloat, update: @escaping (Double) -> Void) -> some View {
        Capsule().fill(Color.yellow)
            .frame(width: 8, height: plot.height * 0.6)
            .overlay(Capsule().stroke(.black.opacity(0.4)))
            .offset(x: position - 4, y: plot.minY + plot.height * 0.2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { value in
                    let t = time(at: value.location.x)
                    update(t)
                    player.seek(to: t, exact: false)
                }
                .onEnded { value in player.seek(to: time(at: value.location.x)) })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }

    private func scrub(at x: CGFloat, frame: CGRect, exact: Bool) {
        guard frame.width > 0 else { return }
        let fraction = min(max((x - frame.minX) / frame.width, 0), 1)
        player.seek(to: Double(fraction) * duration, exact: exact)
    }
}

struct SpeedChart: View, Equatable {
    let samples: [TelemetrySample]
    let duration: Double
    let saved: Double?

    static func == (a: SpeedChart, b: SpeedChart) -> Bool {
        a.samples.count == b.samples.count && a.duration == b.duration && a.saved == b.saved
    }

    struct Span: Identifiable {
        var id: Double { start }
        var start: Double
        var end: Double
        var state: AutopilotState
    }

    var points: [TelemetrySample] {
        let step = max(1, samples.count / 1200)
        return stride(from: 0, to: samples.count, by: step).map { samples[$0] }
    }

    /// Souvislé úseky se stejným stavem asistence (bez ručního řízení).
    var spans: [Span] {
        var result: [Span] = []
        for s in samples {
            if var last = result.last, last.state == s.autopilot, s.t - last.end < 1.5 {
                last.end = s.t
                result[result.count - 1] = last
            } else {
                result.append(Span(start: s.t, end: s.t, state: s.autopilot))
            }
        }
        return result.filter { $0.state != .none }
    }

    var brakes: [Span] {
        var result: [Span] = []
        for s in samples where s.brake {
            if var last = result.last, s.t - last.end < 0.5 {
                last.end = s.t
                result[result.count - 1] = last
            } else {
                result.append(Span(start: s.t, end: s.t + 0.1, state: .none))
            }
        }
        return result
    }

    var body: some View {
        let maxSpeed = max(30, (samples.map(\.speedKmh).max() ?? 0) * 1.1)
        Chart {
            ForEach(spans) { span in
                RectangleMark(xStart: .value("Od", span.start), xEnd: .value("Do", span.end))
                    .foregroundStyle(AutopilotColors.color(span.state).opacity(0.25))
            }
            ForEach(brakes) { span in
                RectangleMark(xStart: .value("Od", span.start), xEnd: .value("Do", max(span.end, span.start + 0.2)),
                              yStart: .value("", 0), yEnd: .value("", maxSpeed * 0.08))
                    .foregroundStyle(.red)
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, s in
                LineMark(x: .value("Čas", s.t), y: .value("km/h", s.speedKmh))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.blue)
            }
            if let saved {
                RuleMark(x: .value("Uloženo", saved))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.orange)
                    }
            }
        }
        .chartXScale(domain: 0...max(duration, 1))
        .chartYScale(domain: 0...maxSpeed)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { value in
                AxisGridLine()
                AxisValueLabel { if let t = value.as(Double.self) { Text(Format.clock(t)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))") } }
            }
        }
        .chartLegend(.hidden)
    }
}

// MARK: - Mapa

struct RouteMap: View {
    let samples: [TelemetrySample]
    let current: TelemetrySample?
    let fallback: (lat: Double, lon: Double)?

    struct Segment: Identifiable {
        let id: Int
        let state: AutopilotState
        let coordinates: [CLLocationCoordinate2D]
    }

    var segments: [Segment] {
        var result: [Segment] = []
        var coords: [CLLocationCoordinate2D] = []
        var state: AutopilotState?
        let step = max(1, samples.count / 800)
        for s in stride(from: 0, to: samples.count, by: step).map({ samples[$0] }) where s.hasPosition {
            let c = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
            if let state, state != s.autopilot {
                coords.append(c)
                result.append(Segment(id: result.count, state: state, coordinates: coords))
                coords = []
            }
            state = s.autopilot
            coords.append(c)
        }
        if let state, coords.count > 1 { result.append(Segment(id: result.count, state: state, coordinates: coords)) }
        return result
    }

    var body: some View {
        let segments = segments
        if segments.isEmpty, fallback == nil {
            ZStack {
                Rectangle().fill(.quaternary)
                Label("Bez polohy", systemImage: "map").foregroundStyle(.secondary)
            }
        } else {
            Map(initialPosition: .automatic) {
                ForEach(segments) { segment in
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(segment.state == .none ? Color.orange : AutopilotColors.color(segment.state), lineWidth: 4)
                }
                if let current, current.hasPosition {
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: current.lat, longitude: current.lon)) {
                        Image(systemName: "location.north.fill")
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.blue, in: Circle())
                            .rotationEffect(.degrees(current.heading))
                    }
                } else if let fallback {
                    Marker("Událost", coordinate: CLLocationCoordinate2D(latitude: fallback.lat, longitude: fallback.lon))
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
        }
    }
}

// MARK: - Třídění

struct AnnotationPanel: View {
    @Environment(LibraryModel.self) private var library
    let eventID: String
    @State private var note = ""
    @State private var newTag = ""

    var body: some View {
        let annotation = library.annotation(eventID)
        VStack(alignment: .leading, spacing: 8) {
            Picker("Rozhodnutí", selection: Binding(
                get: { annotation.decision },
                set: { value in library.update(eventID) { $0.decision = value } }
            )) {
                Label("Ponechat", systemImage: "checkmark.circle").tag(Decision.keep)
                Text("Nerozhodnuto").tag(Decision.undecided)
                Label("Smazat", systemImage: "trash").tag(Decision.delete)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 4) {
                ForEach(annotation.tags, id: \.self) { tag in
                    HStack(spacing: 2) {
                        Text("#\(tag)")
                        Button { library.update(eventID) { $0.tags.removeAll { $0 == tag } } } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                }
            }
            HStack {
                TextField("Přidat štítek", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                let suggestions = library.annotations.allTags.filter { !annotation.tags.contains($0) }
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { tag in
                            Button(tag) { library.update(eventID) { $0.tags.append(tag) } }
                        }
                    } label: { Image(systemName: "tag") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            TextField("Poznámka", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
                .onSubmit(saveNote)
                .onChange(of: note) { saveNote() }
        }
        .onAppear { note = library.annotation(eventID).note }
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard !tag.isEmpty else { return }
        library.update(eventID) { if !$0.tags.contains(tag) { $0.tags.append(tag) } }
        newTag = ""
    }

    private func saveNote() {
        guard note != library.annotation(eventID).note else { return }
        library.update(eventID) { $0.note = note }
    }
}
