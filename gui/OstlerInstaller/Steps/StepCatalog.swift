// StepCatalog.swift
//
// Static metadata for every step the installer can be in. Loaded
// from Resources/HintCopy.json at startup; the JSON is the source
// of truth so editorial copy can be tweaked without rebuilding the
// app. Falls back to inline placeholder copy if the JSON is missing
// or malformed (rather than crashing) so a partial bundle still
// renders.

import Foundation

struct StepMeta: Decodable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let why: String?
    let durationEstimateSeconds: Int?
    let longRunningThresholdSeconds: Int?
    let longRunningCopy: String?
    let illustration: String?
    let needsFDA: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case why
        case durationEstimateSeconds = "duration_estimate_s"
        case longRunningThresholdSeconds = "long_running_threshold_s"
        case longRunningCopy = "long_running_copy"
        case illustration
        case needsFDA = "needs_fda"
    }
}

final class StepCatalog {
    static let shared = StepCatalog()

    private(set) var byId: [String: StepMeta] = [:]
    private(set) var ordered: [StepMeta] = []

    init() {
        load()
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "HintCopy", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            NSLog("HintCopy.json missing – using minimal fallback")
            self.ordered = StepCatalog.fallback()
            self.byId = Dictionary(uniqueKeysWithValues: self.ordered.map { ($0.id, $0) })
            return
        }
        do {
            // The JSON is an *object* keyed by step id, not an array,
            // so we round-trip via [String: StepMeta] and re-derive
            // the order from a top-level "_order" array if present.
            struct Wrapper: Decodable {
                let order: [String]?
                let steps: [String: StepMeta]
            }
            // Decode as a generic dictionary first.
            if let root = try? JSONDecoder().decode([String: StepMeta].self, from: data) {
                self.byId = root
                self.ordered = StepCatalog.canonicalOrder.compactMap { root[$0] }
                if self.ordered.isEmpty {
                    self.ordered = Array(root.values).sorted { $0.id < $1.id }
                }
            } else {
                // Schema with explicit ordering not yet in use; keep
                // the fallback path live for forward-compat.
                self.ordered = StepCatalog.fallback()
                self.byId = Dictionary(uniqueKeysWithValues: self.ordered.map { ($0.id, $0) })
            }
        }
    }

    func meta(for id: String) -> StepMeta? {
        byId[id]
    }

    /// The canonical order of step ids, matching the `progress`
    /// callsites in install.sh. Used to render the sidebar before
    /// the first marker arrives + to derive the overall progress
    /// fraction. Out-of-band ids (renamed steps, future additions)
    /// will appear in the sidebar dynamically as they emit.
    static let canonicalOrder: [String] = [
        "prereq_check",
        "setup_questions",
        "homebrew_install",
        "docker_install",
        "ollama_install",
        "config_save",
        "encrypt_db",
        "fda_extract",
        "graph_db_start",
        "ai_models",
        "import_pipeline",
        "import_data",
        "doctor_setup",
        "hub_power",
        "email_ingest",
        "wiki_recompile_agent",
        "ostler_assistant",
        "wiki_compile",
        "health_check",
    ]

    /// Minimal in-code fallback if HintCopy.json is missing entirely.
    /// Real copy lives in the JSON resource – this is just shape.
    private static func fallback() -> [StepMeta] {
        canonicalOrder.map { id in
            StepMeta(
                id: id,
                title: id.replacingOccurrences(of: "_", with: " ").capitalized,
                subtitle: nil,
                why: nil,
                durationEstimateSeconds: nil,
                longRunningThresholdSeconds: 30,
                longRunningCopy: nil,
                illustration: nil,
                needsFDA: id == "fda_extract"
            )
        }
    }
}
