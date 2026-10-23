import SwiftUI
import TeslaCamCore

struct CleanupView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryModel.self) private var library

    // Označené události
    @State private var eventItems: [Cleanup.EventItem] = []
    @State private var confirmEvents = false
    @State private var eventResult: Cleanup.Result?

    // Zdroj
    @State private var includePlain = false
    @State private var method = Cleanup.Method.trash
    @State private var isPlanning = false
    @State private var sourcePlan: Cleanup.SourcePlan?
    @State private var showSourceConfirm = false
    @State private var isDeleting = false
    @State private var deleteProgress = 0
    @State private var sourceResult: Cleanup.Result?

    var body: some View {
        Form {
            eventsSection
            sourceSection
        }
        .formStyle(.grouped)
        .navigationTitle("Úklid")
        .task(id: library.annotations.events.count) { refreshEvents() }
        .task(id: library.events.count) { refreshEvents() }
        .onAppear {
            library.loadIfNeeded()
            #if DEBUG
            if ProcessInfo.processInfo.environment["TP_AUTOPLAN"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { planSource() }
            }
            #endif
        }
        .sheet(isPresented: $showSourceConfirm) {
            if let sourcePlan { SourceConfirmSheet(plan: sourcePlan, method: method) { deleteSource(sourcePlan) } }
        }
    }

    // MARK: Označené události

    private var eventsSection: some View {
        Section {
            if eventItems.isEmpty {
                Text("Žádná událost není označená ke smazání. V Knihovně ji označ tlačítkem Smazat.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(eventItems) { item in
                    HStack {
                        Text(Format.dateTime(item.event.savedAt)).monospacedDigit()
                        CategoryBadge(category: item.event.category)
                        if let place = item.event.metadata?.place { Text(place).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Text(Format.files(item.files.count)).foregroundStyle(.secondary)
                        Text(Format.bytes(item.bytes)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                    }
                }
                HStack {
                    Text("Celkem \(Format.events(eventItems.count)), \(Format.bytes(eventItems.reduce(0) { $0 + $1.bytes }))").bold()
                    Spacer()
                    Button("Přesunout do Koše…", role: .destructive) { confirmEvents = true }
                }
            }
            if let eventResult { resultLabel(eventResult, noun: Format.events) }
        } header: {
            Text("Odemčená videa označená ke smazání")
        } footer: {
            Text("Přesouvají se do Koše, odkud je jde vrátit. Aplikace si zapamatuje, že jsi je smazal, a při dalším odemykání je znovu neodemkne.")
        }
        .confirmationDialog(
            "Přesunout \(Format.events(eventItems.count)) do Koše?",
            isPresented: $confirmEvents, titleVisibility: .visible
        ) {
            Button("Přesunout do Koše (\(Format.bytes(eventItems.reduce(0) { $0 + $1.bytes })))", role: .destructive, action: trashEvents)
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text(eventItems.map { Format.dateTime($0.event.savedAt) }.joined(separator: "\n"))
        }
    }

    private func refreshEvents() {
        eventItems = Cleanup.planEventTrash(library.events, annotations: library.annotations)
    }

    private func trashEvents() {
        let items = eventItems, root = library.root
        Task {
            eventResult = await Task.detached { Cleanup.trashEvents(items, root: root) }.value
            library.reload()
            sourcePlan = nil
        }
    }

    // MARK: Zdroj

    private var sourceSection: some View {
        Section {
            HStack {
                if let url = app.sourceURL {
                    Label(url.path, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Zdroj není vybraný").foregroundStyle(.secondary)
                }
                Spacer()
                if app.flashDriveAvailable && app.sourceURL != AppModel.flashDrive {
                    Button("Flashka TESLADRIVE") { app.setSource(AppModel.flashDrive); sourcePlan = nil }
                }
                Button("Vybrat…") { app.chooseSource(); sourcePlan = nil }
            }
            .disabled(isDeleting)

            Toggle("Zahrnout i zkopírované nešifrované klipy", isOn: $includePlain)
                .onChange(of: includePlain) { sourcePlan = nil }

            HStack {
                Button("Zkontrolovat, co lze smazat") { planSource() }
                    .disabled(app.sourceURL == nil || isPlanning || isDeleting || app.overlapProblem != nil)
                if isPlanning {
                    ProgressView().controlSize(.small)
                    Text("Ověřuji odemčená videa…").foregroundStyle(.secondary)
                }
            }
            if let problem = app.overlapProblem { Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red) }

            if let plan = sourcePlan { planSummary(plan) }
            if isDeleting, let plan = sourcePlan {
                ProgressView(value: Double(deleteProgress), total: Double(max(1, plan.items.count))) {
                    Text("Mažu \(deleteProgress) / \(Format.files(plan.items.count))")
                }
            }
            if let sourceResult { resultLabel(sourceResult, noun: Format.files) }
        } header: {
            Text("Uklidit zdroj (šifrované originály)")
        } footer: {
            Text("Smaže se jen originál, jehož odemčené video existuje a je celé a platné, nebo který jsi v knihovně sám smazal. Shoda se pozná podle unikátního klíče v hlavičce, takže jde uklidit i flashka, i když se odemykalo z kopie na disku. Nedopsané, neodemčené a chybné soubory zůstávají.")
        }
    }

    @ViewBuilder private func planSummary(_ plan: Cleanup.SourcePlan) -> some View {
        let byReason = Dictionary(grouping: plan.items, by: \.reason.title).mapValues(\.count)
        VStack(alignment: .leading, spacing: 4) {
            Text("Lze smazat \(Format.files(plan.items.count)) (\(Format.bytes(plan.bytes)))").font(.headline)
            ForEach(byReason.keys.sorted(), id: \.self) { title in
                Text("· \(title): \(byReason[title]!)").foregroundStyle(.secondary)
            }
        }
        if !plan.kept.isEmpty {
            let byWhy = Dictionary(grouping: plan.kept, by: \.why)
            DisclosureGroup("Zůstane \(Format.files(plan.kept.count)) (\(Format.bytes(plan.kept.reduce(0) { $0 + $1.file.size })))") {
                ForEach(byWhy.keys.sorted(), id: \.self) { why in
                    DisclosureGroup("\(why) (\(byWhy[why]!.count))") {
                        ForEach(byWhy[why]!) { item in
                            Text(item.file.relativePath).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        if !plan.items.isEmpty {
            Picker("Způsob", selection: $method) {
                Text("Do Koše").tag(Cleanup.Method.trash)
                Text("Smazat natrvalo").tag(Cleanup.Method.permanent)
            }
            .pickerStyle(.segmented)
            Text(method == .trash
                 ? "Na flashce Koš místo neuvolní, dokud ho nevysypeš (a Tesla pak vidí složku .Trashes). Pro flashku je lepší smazat natrvalo."
                 : "Soubory se smažou hned a nepůjdou vrátit. Odemčená videa zůstávají.")
                .font(.caption).foregroundStyle(method == .trash ? Color.secondary : Color.orange)
            HStack {
                Spacer()
                Button("Smazat \(Format.files(plan.items.count)) (\(Format.bytes(plan.bytes)))…", role: .destructive) {
                    showSourceConfirm = true
                }
                .disabled(isDeleting)
            }
        }
    }

    private func planSource() {
        guard let root = app.sourceURL else { return }
        let destination = app.destination, includePlain = includePlain
        isPlanning = true
        sourcePlan = nil
        sourceResult = nil
        Task {
            sourcePlan = await Task.detached(priority: .userInitiated) { () -> Cleanup.SourcePlan? in
                guard let scan = try? SourceScanner.scan(root: root) else { return nil }
                return Cleanup.planSource(scan: scan, destination: destination, includePlain: includePlain)
            }.value
            isPlanning = false
        }
    }

    private func deleteSource(_ plan: Cleanup.SourcePlan) {
        let method = method
        isDeleting = true
        deleteProgress = 0
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Cleanup.executeSource(plan, method: method) { done in
                    Task { @MainActor in deleteProgress = done }
                }
            }.value
            sourceResult = result
            isDeleting = false
            sourcePlan = nil
            app.rescan()
        }
    }

    @ViewBuilder private func resultLabel(_ result: Cleanup.Result, noun: (Int) -> String) -> some View {
        Label("Hotovo: \(noun(result.removed)), uvolněno \(Format.bytes(result.bytes)).", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        if !result.failures.isEmpty {
            DisclosureGroup("Nepodařilo se: \(result.failures.count)") {
                ForEach(result.failures) { failure in
                    VStack(alignment: .leading) {
                        Text(failure.path).font(.caption.monospaced())
                        Text(failure.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .foregroundStyle(.red)
        }
    }
}

/// Potvrzení se seznamem všech souborů, které se smažou.
struct SourceConfirmSheet: View {
    let plan: Cleanup.SourcePlan
    let method: Cleanup.Method
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(method == .trash ? "Přesunout do Koše \(Format.files(plan.items.count))?" : "Natrvalo smazat \(Format.files(plan.items.count))?")
                .font(.title2.bold())
            Text("Celkem \(Format.bytes(plan.bytes)) ze složky \(plan.root.path).")
                .foregroundStyle(.secondary)
            List(plan.items) { item in
                HStack {
                    Text(item.file.relativePath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(item.reason.title).font(.caption).foregroundStyle(.secondary)
                    Text(Format.bytes(item.file.size)).font(.caption.monospacedDigit()).frame(minWidth: 64, alignment: .trailing)
                }
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Zrušit", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(method == .trash ? "Přesunout do Koše" : "Smazat natrvalo", role: .destructive) {
                    dismiss()
                    onConfirm()
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }
}
