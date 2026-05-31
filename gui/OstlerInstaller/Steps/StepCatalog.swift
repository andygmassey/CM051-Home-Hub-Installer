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

    /// The canonical order of step ids. The first id
    /// (`license_entry`) is a GUI-only step that runs before
    /// install.sh launches -- it is the licence-file drag/paste
    /// gate. Every id after it matches a `progress` callsite in
    /// install.sh. Used to render the sidebar before the first
    /// marker arrives + to derive the overall progress fraction.
    /// Out-of-band ids will appear in the sidebar dynamically.
    static let canonicalOrder: [String] = [
        "license_entry",
        "prereq_check",
        "setup_questions",
        "setup_complete_wrap_up",
        "homebrew_install",
        "docker_install",
        "ollama_install",
        "config_save",
        "encrypt_db",
        "fda_extract",
        "graph_db_start",
        "vane_install",
        "ai_models",
        "import_pipeline",
        "cm048_setup",
        "gws_install",
        "import_data",
        "doctor_setup",
        "ical_server_setup",
        "knowledge_setup",
        "hub_power",
        "email_ingest",
        "imessage_bridge",
        "wiki_recompile_agent",
        "ostler_assistant",
        "ostler_hub_app",
        "ostler_remotecapture",
        // CX-81 Tailscale step (2026-05-26): dedicated "Connect your
        // iPhone and Watch" full-screen view + STEP_BEGIN so the
        // sidebar shows the row from launch. install.sh §3.15 emits
        // the matching `progress "Connect your iPhone and Watch"
        // "tailscale_connect"` before the gui_read PROMPT. Lives
        // between ostler_remotecapture and hydrate_graph to match
        // install.sh §3.15 position (between §3.14g and §3.16).
        "tailscale_connect",
        "hydrate_graph",
        // CX-86 Gap A + Gap C: hydrate_browsing fires as a separate
        // progress emission BETWEEN hydrate_graph (B1/B2/CX-85's
        // contacts + calendar + email + whatsapp drainer) and
        // wiki_compile. Streams Safari + Chrome history through the
        // gateway with needs_reprocessing=true.
        "hydrate_browsing",
        // CX-84: hydrate_imessage fires after hydrate_browsing and
        // before wiki_compile. Reads imessage_conversations.json
        // (written by fda_extract) and walks it through
        // ingest_imessage to emit Person + lastContactIMessage
        // triples. Counts-only stdout, no participant identifiers.
        "hydrate_imessage",
        // Preferences wire (2026-05-31): hydrate_preferences fires after
        // hydrate_imessage and before wiki_compile. Runs the vendored CM019
        // ingest + enrich pipeline over any GDPR exports the user dropped in
        // ~/Documents/Ostler/imports/preferences/, populating the Food /
        // Music / Media / Reading / Apps / Places / Topics wiki sections.
        // Counts-only stdout; no item content leaves the local process.
        "hydrate_preferences",
        // CX-106 (2026-05-29): initial_hydrate is a synchronous first-load
        // sweep emitted between hydrate_preferences and wiki_compile that
        // guarantees Qdrant has at least one collection before the wiki
        // compiles. It shipped as a `progress` callsite without a
        // canonicalOrder entry, so the install.sh<->GUI step-parity contract
        // test has been red on main since CX-106. Registering it here closes
        // that drift (the contract test prescribes exactly this fix).
        "initial_hydrate",
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
