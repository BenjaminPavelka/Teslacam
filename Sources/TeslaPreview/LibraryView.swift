import SwiftUI
import TeslaCamCore

struct LibraryView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        HSplitView {
            eventList
                .frame(minWidth: 330, idealWidth: 390, maxWidth: 540)
            Group {
                if let event = library.selectedEvent {
                    EventDetailView(event: event).id(event.id)
                } else {
                    ContentUnavailableView("Vyber událost", systemImage: "film",
                                           description: Text("Vlevo vyber událost, kterou chceš přehrát."))
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Knihovna")
        .toolbar { toolbar }
        .task { library.loadIfNeeded() }
    }

    // MARK: Seznam

    @ViewBuilder private var eventList: some View {
        @Bindable var library = library
        VStack(spacing: 0) {
            filters
            if let progress = library.indexing {
                HStack {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))).frame(width: 120)
                    Text("Připravuji náhledy a telemetrii \(progress.done)/\(progress.total)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            if let error = library.saveError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(6)
            }
            Divider()
            if library.events.isEmpty && !library.isLoading {
                ContentUnavailableView(
                    "Zatím žádné události", systemImage: "tray",
                    description: Text("Ve složce \(library.root.path) nejsou odemčené klipy. Nejdřív je odemkni, nebo změň cílovou složku v části Odemčení.")
                )
            } else {
                List(selection: $library.selection) {
                    ForEach(library.groupedByDay, id: \.day) { group in
                        Section(Format.day(group.day)) {
                            ForEach(group.events) { event in
                                EventRow(event: event).tag(event.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if library.filteredEvents.isEmpty && !library.events.isEmpty {
                        ContentUnavailableView.search
                    }
                }
            }
        }
    }

    @ViewBuilder private var filters: some View {
        @Bindable var library = library
        VStack(spacing: 6) {
            TextField("Hledat místo, poznámku, štítek…", text: $library.searchText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Typ", selection: $library.categoryFilter) {
                    Text("Všechny typy").tag(ClipCategory?.none)
                    ForEach(ClipCategory.allCases, id: \.self) { Text($0.title).tag(ClipCategory?.some($0)) }
                }
                Picker("Stav", selection: $library.decisionFilter) {
                    Text("Vše").tag(Decision?.none)
                    ForEach(Decision.allCases, id: \.self) { Text($0.title).tag(Decision?.some($0)) }
                }
            }
            .labelsHidden()
            HStack {
                Picker("Štítek", selection: $library.tagFilter) {
                    Text("Všechny štítky").tag(String?.none)
                    ForEach(library.annotations.allTags, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden()
                Toggle("Jen s FSD/Autopilotem", isOn: $library.onlyAssisted)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            let c = library.counts
            Text("\(Format.events(library.events.count)) · ponechat \(c.keep) · smazat \(c.delete) · nerozhodnuto \(c.undecided)")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button { library.reload() } label: { Label("Načíst znovu", systemImage: "arrow.clockwise") }
                .help("Znovu projít složku odemčených videí")
        }
        ToolbarItem {
            Button { NSWorkspace.shared.open(library.root) } label: { Label("Otevřít ve Finderu", systemImage: "folder") }
        }
    }
}

struct EventRow: View {
    @Environment(LibraryModel.self) private var library
    let event: LibraryEvent
    @State private var image: NSImage?

    var body: some View {
        let index = library.indexes[event.id]
        let note = library.annotation(event.id)
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .bottomTrailing) {
                if let index {
                    Text(Format.clock(index.totalDuration))
                        .font(.caption2.monospacedDigit()).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white).padding(3)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Format.timeOfDay(event.savedAt)).font(.headline.monospacedDigit())
                    CategoryBadge(category: event.category)
                    Spacer(minLength: 0)
                    DecisionIcon(decision: note.decision)
                }
                if let line = event.metadata?.reasonText ?? event.metadata?.place {
                    Text(line).font(.caption).lineLimit(1)
                }
                if let place = event.metadata?.place, event.metadata?.reasonText != nil {
                    Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let summary = index?.summary, index?.telemetryCount ?? 0 > 0 {
                    TelemetryChips(summary: summary)
                }
                if !note.tags.isEmpty {
                    Text(note.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.tint).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .task(id: index?.signature) {
            image = index == nil ? nil : await LibraryModel.loadThumbnail(library.cache.thumbnailURL(event))
        }
    }
}

struct CategoryBadge: View {
    let category: ClipCategory
    var body: some View {
        Text(category.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    var color: Color {
        switch category {
        case .saved: .blue
        case .sentry: .red
        case .recent: .gray
        }
    }
}

struct DecisionIcon: View {
    let decision: Decision
    var body: some View {
        switch decision {
        case .keep: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Ponechat")
        case .delete: Image(systemName: "trash.circle.fill").foregroundStyle(.red).help("Smazat")
        case .undecided: EmptyView()
        }
    }
}

struct TelemetryChips: View {
    let summary: TelemetrySummary
    var body: some View {
        HStack(spacing: 4) {
            ForEach([AutopilotState.selfDriving, .autosteer, .tacc], id: \.self) { state in
                let seconds = summary.seconds(state)
                if seconds >= 1 {
                    chip("\(state.title) \(Format.minutes(seconds))", AutopilotColors.color(state))
                }
            }
            if summary.maxSpeedKmh >= 1 { chip("max \(Int(summary.maxSpeedKmh)) km/h", .secondary) }
            if summary.distanceKm >= 0.1 { chip(String(format: "%.1f km", summary.distanceKm), .secondary) }
        }
    }

    func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(color)
    }
}

enum AutopilotColors {
    static func color(_ state: AutopilotState) -> Color {
        switch state {
        case .selfDriving: .blue
        case .autosteer: .teal
        case .tacc: .purple
        case .none: .gray
        }
    }
}
