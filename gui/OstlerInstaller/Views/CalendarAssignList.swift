// CalendarAssignList.swift
//
// 118 Q32b. The end-of-install calendar check used to be a plain text list
// with one yes/no switch: a wrong guess could only be fixed by declining and
// answering two questions per calendar. This renders the same list with one
// menu per calendar (Yours / Family / Shared / Holidays / Ignore), pre-set to
// install.sh's guess, so a wrong guess is corrected where it is shown.
//
// Wire contract with install.sh (prompt id `calendar_assign`, kind `text`):
//   default  one row per line, "category|count|name" (name last, so a "|"
//            inside a calendar name survives)
//   answer   one category per row, comma-separated, in row order
// lib/ostler-confirm-calendars.py maps the answer to calendars.json and
// keeps the pre-fill if the answer is malformed.

import SwiftUI

struct CalendarAssignRow: Identifiable, Equatable {
    let id: Int
    let name: String
    let count: Int
    /// The guess install.sh sent. Decides which group the row is listed in,
    /// so changing a menu never makes rows jump.
    let initial: String
    var category: String
}

enum CalendarAssign {
    static let promptId = "calendar_assign"
    static let categories = ["yours", "family", "shared", "holidays", "ignore"]
    static let setAside: Set<String> = ["holidays", "ignore"]

    /// Parse the prompt's default. Malformed lines are dropped, and an
    /// unknown category reads as "yours" (the helper's own safe default).
    static func parse(_ wire: String) -> [CalendarAssignRow] {
        var rows: [CalendarAssignRow] = []
        for line in wire.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[2].isEmpty else { continue }
            let cat = String(parts[0])
            let known = categories.contains(cat) ? cat : "yours"
            rows.append(CalendarAssignRow(id: rows.count, name: String(parts[2]),
                                          count: Int(parts[1]) ?? 0,
                                          initial: known, category: known))
        }
        return rows
    }

    /// Rows for a back-review: the default's rows with the customer's answer.
    static func rows(wire: String, answer: String?) -> [CalendarAssignRow] {
        var rows = parse(wire)
        let picks = (answer ?? "").split(separator: ",").map(String.init)
        if picks.count == rows.count {
            for i in rows.indices where categories.contains(picks[i]) { rows[i].category = picks[i] }
        }
        return rows
    }

    static func answer(_ rows: [CalendarAssignRow]) -> String {
        rows.map(\.category).joined(separator: ",")
    }
}

struct CalendarAssignList: View {
    @Binding var rows: [CalendarAssignRow]
    var disabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace2) {
            ForEach(rows.indices, id: \.self) { i in
                if i > 0 && CalendarAssign.setAside.contains(rows[i].initial)
                    && !CalendarAssign.setAside.contains(rows[i - 1].initial) {
                    Text(ViewCopy.shared.string(for: "onboarding_question.calendar_assign.set_aside_heading"))
                        .font(.ostlerCaption)
                        .foregroundStyle(Color.ostlerInkMuted)
                        .padding(.top, .ostlerSpace2)
                }
                row($rows[i])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ r: Binding<CalendarAssignRow>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: .ostlerSpace3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.wrappedValue.name)
                    .font(.ostlerBody)
                    .foregroundStyle(Color.ostlerInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(eventsLabel(r.wrappedValue.count))
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerInkMuted)
            }
            Spacer(minLength: .ostlerSpace2)
            Picker("", selection: r.category) {
                ForEach(CalendarAssign.categories, id: \.self) { c in
                    Text(ViewCopy.shared.string(for: "onboarding_question.calendar_assign.category.\(c)"))
                        .tag(c)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(disabled)
            .accessibilityLabel(Text(r.wrappedValue.name))
        }
    }

    private func eventsLabel(_ n: Int) -> String {
        ViewCopy.shared.string(
            for: n == 1 ? "onboarding_question.calendar_assign.events_one"
                        : "onboarding_question.calendar_assign.events_many",
            fills: ["count": String(n)]
        )
    }
}
