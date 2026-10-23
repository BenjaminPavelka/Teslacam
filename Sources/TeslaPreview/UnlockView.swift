import SwiftUI
import TeslaCamCore

struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            sourceSection
            if model.scan != nil { overviewSection }
            destinationSection
            tokenSection
            runSection
            if case .finished = model.phase { summarySection }
        }
        .formStyle(.grouped)
        .navigationTitle("Odemčení")
    }

    // MARK: Zdroj

    private var sourceSection: some View {
        Section {
            HStack {
                if let url = model.sourceURL {
                    Label(Format.path(url), systemImage: "folder").lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Zatím nevybráno").foregroundStyle(.secondary)
                }
                Spacer()
                if model.flashDriveAvailable && model.sourceURL != AppModel.flashDrive {
                    Button("Použít flashku TESLADRIVE") { model.setSource(AppModel.flashDrive) }
                }
                Button("Vybrat složku…") { model.chooseSource() }
            }
            .disabled(model.phase == .running)
            if model.isScanning {
                HStack { ProgressView().controlSize(.small); Text("Procházím klipy…") }
            }
            if let error = model.scanError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text("Zdroj")
        } footer: {
            Text("Složka se zkopírovanými klipy z flashky. Může to být TeslaCam, EncryptedClips, nebo jen SavedClips či jedna událost.")
        }
    }

    // MARK: Přehled

    private var overviewSection: some View {
        Section("Přehled") {
            let files = model.scan?.files ?? []
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Událostí").bold()
                    Text("Šifrovaná videa").bold()
                    Text("Nešifrované").bold()
                    Text("Nedopsané").bold()
                    Text("Velikost").bold()
                }
                Divider()
                ForEach(ClipCategory.allCases, id: \.self) { category in
                    let stats = CategoryStats(files.filter { $0.category == category })
                    GridRow {
                        Toggle(category.title, isOn: Binding(
                            get: { model.categories.contains(category) },
                            set: { on in
                                if on { model.categories.insert(category) } else { model.categories.remove(category) }
                            }
                        ))
                        .disabled(model.phase == .running)
                        Text(category == .recent ? "–" : "\(stats.events)")
                        Text("\(stats.encrypted)")
                        Text("\(stats.plain)")
                        Text("\(stats.incomplete)").foregroundStyle(stats.incomplete > 0 ? .orange : .primary)
                        Text(Format.bytes(stats.bytes))
                    }
                }
            }
            .monospacedDigit()

            if let plan = model.plan {
                HStack(spacing: 16) {
                    Label("K odemčení \(plan.toUnlock.count)", systemImage: "lock.open")
                    Label("Ke zkopírování \(plan.toCopy.count)", systemImage: "doc.on.doc")
                    Label("Už hotovo \(plan.alreadyDone.count)", systemImage: "checkmark.circle")
                    if !plan.deletedByUser.isEmpty {
                        Label("Smazané v knihovně \(plan.deletedByUser.count)", systemImage: "trash")
                            .help("Tyhle soubory jsi smazal v knihovně, znovu se neodemykají.")
                    }
                    if !plan.locked.isEmpty {
                        Label("Zamčené doplňky \(plan.locked.count)", systemImage: "lock")
                            .help(Messages.locked)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Cíl

    private var destinationSection: some View {
        Section("Cíl") {
            HStack {
                Label(Format.path(model.destination), systemImage: "externaldrive").lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Otevřít") { NSWorkspace.shared.open(model.destination) }
                    .disabled(!FileManager.default.fileExists(atPath: model.destination.path))
                Button("Změnit…") { model.chooseDestination() }
            }
            .disabled(model.phase == .running)

            if let plan = model.plan {
                LabeledContent("Potřeba místa") { Text(Format.bytes(plan.requiredBytes)) }
            }
            if let free = model.availableBytes {
                LabeledContent("Volno na cílovém disku") { Text(Format.bytes(free)) }
            }
            if let problem = model.overlapProblem ?? model.spaceProblem {
                Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red)
            }

            Toggle(isOn: Binding(get: { model.remux && model.ffmpeg != nil }, set: { model.remux = $0 })) {
                Text("Upravit videa pro přehrávače (remux)")
                Text("Bezztrátově, telemetrie (rychlost, FSD…) zůstává.").font(.caption).foregroundStyle(.secondary)
            }
            .disabled(model.ffmpeg == nil || model.phase == .running)
            if model.ffmpeg == nil {
                Label(FFmpeg.installHint, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Stepper("Souběžně zpracovávat: \(model.workers)", value: Bindable(model).workers, in: 1...8)
                .disabled(model.phase == .running)
        }
    }

    // MARK: Token

    private var tokenSection: some View {
        Section {
            HStack {
                tokenStatus
                Spacer()
                Button("Přihlásit se v okně…") { openWindow(id: LoginWindow.id) }
                Button("Vložit token ze schránky") { model.pasteToken() }
                if model.token != nil {
                    Button("Zapomenout", role: .destructive) { model.forgetToken() }
                }
            }
            if let message = model.tokenMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text("Přihlášení k Tesle")
        } footer: {
            Text("Token se drží jen v paměti, dokud aplikace běží. Nikam se neukládá a posílá se výhradně na dashcam.tesla.com. Video se odemyká lokálně, Tesle se posílají jen identifikátory souborů.")
        }
    }

    @ViewBuilder private var tokenStatus: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if let token = model.token {
                if token.isExpired() {
                    Label("Token vypršel, vlož nový", systemImage: "key.slash").foregroundStyle(.red)
                } else if let expiry = token.expiresAt {
                    Label("Token platí do \(Format.time(expiry))", systemImage: "key.fill").foregroundStyle(.green)
                } else {
                    Label("Token vložen", systemImage: "key.fill").foregroundStyle(.green)
                }
            } else {
                Label(model.needsToken ? "Token chybí" : "Token zatím není potřeba", systemImage: "key")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Běh

    private var runSection: some View {
        Section("Odemknout") {
            if model.phase == .running {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(model.runDoneBytes), total: Double(max(1, model.runTotalBytes)))
                        HStack {
                            Text("\(model.runDoneFiles) / \(Format.files(model.runTotalFiles))")
                            Text("·")
                            Text("\(Format.bytes(model.runDoneBytes)) / \(Format.bytes(model.runTotalBytes))")
                            if let speed = model.throughput {
                                Text("·")
                                Text("\(Format.bytes(UInt64(speed)))/s")
                            }
                            if let eta = model.eta {
                                Text("·")
                                Text("zbývá asi \(Format.duration(eta))")
                            }
                        }
                        .monospacedDigit()
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                Button("Pozastavit") { model.stop() }
                    .help("Rozpracované soubory se zahodí. Příště se naváže tam, kde to skončilo.")
            } else {
                HStack {
                    Button {
                        model.start()
                    } label: {
                        Label(startTitle, systemImage: "lock.open.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.startBlocker != nil)
                    if let blocker = model.startBlocker {
                        Text(blocker).foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
        }
    }

    private var startTitle: String {
        guard let plan = model.plan else { return "Odemknout" }
        if case .finished(.tokenExpired) = model.phase { return "Pokračovat (\(Format.files(plan.workCount)))" }
        return "Odemknout \(Format.files(plan.workCount))"
    }

    // MARK: Souhrn

    private var summarySection: some View {
        Section("Výsledek") {
            if case .finished(let end) = model.phase { endBanner(end) }
            let s = model.summary
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                row("Odemčeno", s.unlocked, "checkmark.circle.fill", .green)
                row("Zkopírováno (nešifrované)", s.copied, "doc.on.doc.fill", .green)
                row("Už bylo hotové", s.alreadyDone, "checkmark.circle", .secondary)
                row("Nedopsané (poškozené)", s.incomplete, "exclamationmark.triangle.fill", .orange)
                row("Selhalo", s.failed, "xmark.octagon.fill", .red)
                row("Čeká na nový token", s.waiting, "key.slash", .red)
                row("Zamčené doplňky (event.json, thumb.png)", s.locked, "lock", .secondary)
                if s.remuxFallback > 0 { row("Uloženo bez remuxu", s.remuxFallback, "film", .orange) }
            }
            .monospacedDigit()

            HStack {
                if !model.retryablePaths.isEmpty {
                    Button("Zkusit znovu jen chybné (\(model.retryablePaths.count))") { model.retryFailed() }
                        .disabled(model.startBlocker(forRetry: true) != nil)
                }
                Button("Otevřít cílovou složku") { NSWorkspace.shared.open(model.destination) }
            }

            let problems = model.problems
            if !problems.isEmpty {
                DisclosureGroup("Podrobnosti (\(problems.count))") {
                    ForEach(problems, id: \.path) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.path).font(.caption.monospaced()).textSelection(.enabled)
                            Text(item.message).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder private func endBanner(_ end: RunEnd) -> some View {
        switch end {
        case .finished:
            Label("Hotovo.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .cancelled:
            Label("Pozastaveno. Kliknutím na Odemknout se naváže.", systemImage: "pause.circle.fill")
        case .tokenExpired:
            Label("Token vypršel. Vlož nový a klikni na Pokračovat, hotové soubory se přeskočí.", systemImage: "key.slash")
                .foregroundStyle(.red)
        case .gaveUp(let error):
            Label("Zastaveno: \(Messages.text(for: error))", systemImage: "wifi.exclamationmark").foregroundStyle(.red)
        }
    }

    private func row(_ title: String, _ count: Int, _ icon: String, _ color: Color) -> some View {
        GridRow {
            Label(title, systemImage: icon).foregroundStyle(count > 0 ? color : .secondary)
            Text("\(count)")
        }
    }
}

extension AppModel {
    func startBlocker(forRetry: Bool) -> String? {
        if needsToken || !retryablePaths.isEmpty {
            guard let token else { return "Chybí token." }
            if token.isExpired() { return "Token vypršel." }
        }
        return phase == .running ? "Běží." : nil
    }
}

struct CategoryStats {
    var events = 0, encrypted = 0, plain = 0, incomplete = 0
    var bytes: UInt64 = 0

    init(_ files: [SourceFile]) {
        var folders = Set<String>()
        for file in files {
            bytes += file.size
            let parts = file.relativePath.split(separator: "/")
            if parts.count >= 3 { folders.insert(String(parts[1])) }
            guard file.isVideo else { continue }
            switch file.kind {
            case .encryptedVideo: encrypted += 1
            case .plain: plain += 1
            case .incompleteVideo, .damaged: incomplete += 1
            case .lockedSidecar: break
            }
        }
        events = folders.count
    }
}
