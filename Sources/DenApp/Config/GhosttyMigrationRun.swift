/// Progress of a Ghostty migration as the palette shows it.
struct GhosttyMigrationRun: Equatable {
    enum StepID: CaseIterable {
        case source, option, keybinds, theme

        var title: String {
            switch self {
            case .source: "Ghostty config"
            case .option: "Option key"
            case .keybinds: "Key bindings"
            case .theme: "Theme"
            }
        }
    }

    enum Status: Equatable {
        case pending, running
        case done(String)
        case skipped(String)
        case failed(String)
    }

    enum Phase: Equatable {
        case running, finished
        case failed(String)
    }

    struct Step: Equatable, Identifiable {
        let id: StepID
        var status: Status
    }

    var steps = StepID.allCases.map { Step(id: $0, status: .pending) }
    var phase = Phase.running

    mutating func set(_ id: StepID, _ status: Status) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].status = status
    }
}
