// InstallCompleteView.swift
//
// CX-49 (DMG #30, 2026-05-24): affirmative completion panel shown
// in the main content area when coordinator.finished == .ok. Replaces
// the generic "Quick sanity pass" Health Check placeholder so the
// customer sees a clear "you're done, everything is up" state
// instead of the same body copy they were reading mid-install.
//
// CX-56 (DMG ship, 2026-05-24): pairing-QR section added between
// the service tick list + the CTA buttons. The Hub gateway exposes
// a §3.3 envelope at POST http://localhost:8000/admin/paircode
// which we render as a 256x256 QR with an oxblood border. CM031's
// iOS pairing flow scans the QR + verifies the envelope on the iOS
// side. Fetch fires on .task with a Refresh button for retries
// (e.g. gateway not yet up immediately after start-services).
//
// The per-service tick list reads from coordinator.completedSteps +
// peeks for the health probes' "X healthy" / "X granted" log lines
// so the page reflects the actual health-check outcomes. No data
// flows OFF the Mac to render this view.

import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct InstallCompleteView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    // CX-56 pairing-QR state. Stays inside InstallCompleteView so
    // the lifecycle (fetch on appear, refresh on tap) is colocated
    // with the view that owns it; the GatewayClient itself is
    // stateless.
    @State private var pairEnvelope: String? = nil
    @State private var pairFetchInFlight: Bool = false
    @State private var pairFetchError: String? = nil

    // #944. THE BUTTON BELOW USED TO BE UNCONDITIONAL, and this screen is the
    // last thing a customer sees. install.sh already knows the answer: its
    // "Next steps" banner prints the wiki URL only when WIKI_FIRST_COMPILE_OK
    // is true, and prints "not yet available" otherwise. The GUI printed
    // neither guard. So on a box where the first compile did not finish, the
    // terminal path went quiet and the GUI actively sent the customer to a
    // page that would not load, with a sign-in hint for a server that was not
    // listening. The richer surface was the more misleading one.
    //
    // THREE STATES, THREE BRANCHES. "Not checked yet" is not "not serving",
    // and "not serving" is not "broken for ever". A two-state flag here would
    // read the first render as a failure and flash a false warning on every
    // healthy install.
    private enum WikiReachability { case checking, serving, notServing }
    @State private var wikiReachability: WikiReachability = .checking

    /// Starts at `.checking`, NOT at `.notResponding`.
    ///
    /// The initial value is the answer shown for the fraction of a second
    /// before the probe returns, so it has to be the honest one: we have not
    /// asked yet. Defaulting to `.notResponding` would put "Hub not
    /// responding" on the screen of every healthy install on first paint.
    @State private var hubReachability: HubReachability = .checking

    private let gatewayClient = GatewayClient()

    // The health probes install.sh runs at the tail of Phase 4. We
    // detect them by scanning logLines for the canonical "X healthy"
    // / "X granted" patterns emitted by install.sh's `ok` calls. If
    // a service didn't tick green during the probe (offline, port
    // collision, optional skip), it's rendered as a warn row so the
    // customer is informed without panicking the success page.
    private struct ServiceCheck: Identifiable {
        let id: String
        let label: String
        let status: StepStatus
    }

    // ── WHAT THIS PANEL CAN AND CANNOT HONESTLY SAY (#1589) ───────────────
    //
    // Every row below is derived by GREPPING THE INSTALLER'S OWN TRANSCRIPT.
    // That is what the installer BELIEVES it did, not what is running. The
    // issue asks for the panel to be built from surfaces the box can evidence,
    // and that is right.
    //
    // WHY IT IS NOT SIMPLY REPOINTED AT A HEALTH ENDPOINT, measured rather
    // than assumed: the gateway DOES expose a real per-service check at
    // `/health?detailed`, which genuinely connects to Qdrant, Oxigraph and
    // Ollama. But `ical-server.py:7198` requires the service token for the
    // detailed form and returns 401 without it. The installer would have to
    // read that token off disk first. That is the right fix and it is more
    // than a repoint.
    //
    // AND THE STORE PORTS MUST NOT BE PROBED DIRECTLY. Ports plus auth is the
    // shipped design, and a separate blocking probe exists precisely to assert
    // those ports are NOT reachable without a credential. A panel that
    // connected to 6333 to prove health would be asserting the opposite of the
    // security property.
    //
    // WHAT CHANGES HERE, and it is the half that can be done honestly today:
    //
    // 1. TWO STATES, AND THEY CANNOT BE THREE FROM HERE. This block used to
    //    claim three states and that "a service that is fine but logged
    //    differently, and a service that is genuinely down" were "now
    //    separable". They were not, and they cannot be: every row below is
    //    `ok(...) ? .ok : .warn`, a two-state ternary over the transcript, and
    //    StepStatus having five cases available does not make the transcript
    //    carry a third answer. From a log line alone "did not tick green" is
    //    genuinely one state. Separating them needs a live check, which is
    //    item 2, and item 2 covers the Hub and not the six services.
    //
    //    So the claim is withdrawn rather than reworded. What replaces it is
    //    item 3, which is now actually rendered.
    // 2. ONE REAL CHECK. The gateway's UNAUTHENTICATED `/health` needs no
    //    token and answers whether the Hub is actually serving. That is one
    //    genuine observation of the box rather than of the transcript.
    // 3. THE LOG-DERIVED ROWS SAY SO. They are labelled as the installer's own
    //    report. A customer reading "as reported during install" knows what
    //    they are being told; a green tick implies a check that did not happen.
    private var serviceChecks: [ServiceCheck] {
        let lines = coordinator.logLines.map { $0.text }
        func ok(_ probe: String) -> Bool {
            lines.contains { $0.localizedCaseInsensitiveContains(probe) }
        }
        return [
            ServiceCheck(id: "qdrant",   label: "Knowledge graph (Qdrant)",
                         status: ok("Qdrant healthy") ? .ok : .warn),
            ServiceCheck(id: "oxigraph", label: "Triple store (Oxigraph)",
                         status: ok("Oxigraph healthy") ? .ok : .warn),
            ServiceCheck(id: "redis",    label: "Cache + message bus (Redis)",
                         status: ok("Redis healthy") ? .ok : .warn),
            ServiceCheck(id: "ollama",   label: "Local AI (Ollama)",
                         status: ok("Ollama healthy") ? .ok : .warn),
            ServiceCheck(id: "vane",     label: "Local web search (Vane)",
                         status: ok("Vane healthy") ? .ok : .warn),
            ServiceCheck(id: "imessage", label: "iMessage automation",
                         status: ok("iMessage Automation permission: granted") ? .ok : .warn),
            // THE ONLY ROW HERE THAT ASKED THE BOX. Everything above it is the
            // installer quoting itself; this one connected.
            ServiceCheck(id: "hub", label: "Hub responding",
                         status: hubReachability.asStatus),
        ]
    }

    /// Did the Hub answer, could it not, or have we not asked yet?
    ///
    /// Three states because two cannot carry the difference. "Not asked yet"
    /// rendering as a warning would put a red mark on every healthy install
    /// for the first second of the screen, and "could not ask" rendering as
    /// "not running" tells a customer their Hub is broken when what actually
    /// happened is that we did not find out.
    enum HubReachability {
        case checking, responding, notResponding

        /// Mapped onto the vocabulary the panel already has, rather than a
        /// new one. `StepStatus` carries `timeout`, whose own definition says
        /// it means "we gave up waiting, NOT it failed" and that the record
        /// must no longer claim the step succeeded. That is exactly what an
        /// unanswered health check is, so it is used rather than `fail`:
        /// telling a customer their Hub FAILED when what happened is that we
        /// stopped waiting is the same overstatement this row is about.
        var asStatus: StepStatus {
            switch self {
            case .responding:    return .ok
            case .checking:      return .warn
            case .notResponding: return .timeout
            }
        }
    }

    /// Ask the gateway's UNAUTHENTICATED health route.
    ///
    /// `/health` without `detailed` needs no service token (the detailed form
    /// does, and returns 401 without it). It answers one question honestly:
    /// is the Hub serving. Any HTTP answer counts, including an error status,
    /// because something replying is the thing being asked about.
    private func probeHubReachability() async {
        guard let url = URL(string: "http://localhost:8089/health") else {
            hubReachability = .notResponding
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for attempt in 1...20 {
            if Task.isCancelled { return }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if response is HTTPURLResponse {
                    hubReachability = .responding
                    return
                }
            } catch {
                if attempt == 20 {
                    NSLog("install_complete: the Hub did not answer :8089/health in 20 attempts: %@",
                          error.localizedDescription)
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        hubReachability = .notResponding
    }

    var body: some View {
        // CX-64 (DMG #36, 2026-05-24): wrap the body in a ScrollView so
        // the hero never gets clipped above the viewport when the
        // installer window is shorter than the assembled content.
        // Studio retest #28 had the "You're all set" hero scrolled out
        // of sight: total content runs ~600pt (hero + tick list +
        // pairing QR + CTAs) and the VStack's trailing Spacer was
        // taking the overflow off the TOP, not the bottom. ScrollView
        // gives the content the room it actually needs, with the hero
        // pinned at the top so it's always the first thing the
        // customer sees on a successful install.
        //
        // CX-DMG44 (DMG #44, 2026-05-25): hero is now visible but the
        // primary CTA buttons (Open Ostler / Open your Wiki) sit at
        // the bottom of the scroll content and disappear below the
        // viewport fold on short installer windows. Refactor the
        // layout: ScrollView on top holding hero + tick list + QR;
        // a sticky footer outside the ScrollView holding the CTA
        // buttons. Buttons are now always above the fold regardless
        // of window size. Studio retest #43 found customers didn't
        // realise they could scroll to find the buttons.
        VStack(spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: .ostlerSpace4) {
            // Hero: large oxblood check + bold heading. Mirrors the
            // sidebar's terminal "Done" footer but at full size so
            // the main content area carries the announcement.
            HStack(alignment: .center, spacing: .ostlerSpace3) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.ostlerForest)
                VStack(alignment: .leading, spacing: .ostlerSpace1) {
                    Text("INSTALL COMPLETE")
                        .font(.ostlerStrap)
                        .tracking(1.6)
                        .foregroundStyle(Color.ostlerInkMuted)
                    Text(ViewCopy.shared.string(for: "install_complete.heading"))
                        .font(.ostlerH1)
                        .tracking(-0.4)
                        .foregroundStyle(Color.ostlerInk)
                    Text(ViewCopy.shared.string(for: "install_complete.subheading"))
                        .font(.ostlerBodyLg)
                        .foregroundStyle(Color.ostlerInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, .ostlerSpace2)

            Divider()

            // #599: "What's happening now" replaces the per-service
            // tick list as the focus, so a still-hydrating wiki does
            // not read as "everything is finished".
            whatsHappeningSection

            Divider()

            // #599: primary iPhone call to action -- download the app.
            getIosAppSection

            // #599: the pairing QR, demoted below the download CTA and
            // relabelled "already installed the app? scan to pair".
            pairingSection

            Divider()

            // #599: the per-service tick list, moved into a collapsed
            // "Hub status" disclosure -- still reachable, not the
            // headline.
            hubStatusSection

            // v1.0.42 walk, finding 1b: the offer-to-trash, DEFAULTED TO
            // KEEP. Pre-fix the Done button trashed the installer silently
            // and unconditionally; the customer was never asked and never
            // told. Re-running the installer is the repair route.
            keepInstallerSection

            // v1.0.42 walk, finding 1d: if the memory ceiling was breached
            // during this install, say so HERE rather than only in the log
            // drawer. The customer's next experience of it is macOS telling
            // them the system is out of application memory.
            if coordinator.memoryCeilingBreached {
                memoryCeilingSection
            }

            Spacer(minLength: .ostlerSpace2)
        }
        .padding(CGFloat.ostlerSpace4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }  // end ScrollView

        // CX-DMG44 sticky footer: Primary CTA + secondary live in a
        // non-scrolling bar pinned to the bottom of the viewport.
        // Always above the fold regardless of installer window size.
        // Reveal-in-Finder lives in the bottom toolbar already so we
        // don't repeat it here.
        Divider()
        VStack(alignment: .leading, spacing: .ostlerSpace1) {
        HStack(spacing: .ostlerSpace2) {
            Button(action: openOstlerHub) {
                HStack(spacing: .ostlerSpace1) {
                    Image(systemName: "app.dashed")
                    Text(ViewCopy.shared.string(for: "install_complete.open_ostler_button"))
                }
                .padding(.horizontal, .ostlerSpace3)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.ostlerOxblood)

            Button(action: openWiki) {
                HStack(spacing: .ostlerSpace1) {
                    Image(systemName: "book.closed")
                    Text(ViewCopy.shared.string(for: "install_complete.open_wiki_button"))
                }
                .padding(.horizontal, .ostlerSpace3)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            // #944: off while checking and while not serving. A button that
            // opens a dead page is worse than a button that is plainly not
            // ready yet, because the customer blames the product for the
            // blank tab and has no way to tell the two apart.
            .disabled(wikiReachability != .serving)

            Spacer()
        }

        // #1725. "Open your Wiki" opens http://localhost:8044, which has sat
        // behind auth_basic since #1609 (34201cb4). Before that it opened the
        // wiki; now it opens a browser password box, and this screen is the
        // LAST thing a customer sees.
        //
        // The credential is not secret from the person installing -- it is
        // theirs, written 0600 on their own disk -- but it was only ever
        // announced on the terminal path. install.sh prints the username, the
        // password and a clipboard copy in its "Next steps" banner, and that
        // banner has no gui_active guard so it still runs under OSTLER_GUI=1;
        // it just lands in the scrolling log, hours of install before the
        // button that needs it.
        //
        // Deliberately says WHERE the password is rather than "we copied it to
        // your clipboard". The installer only claims the clipboard when pbcopy
        // actually succeeded, and this view cannot observe that. A promise the
        // GUI cannot verify is the failure mode install.sh's own comment warns
        // about: claiming a clipboard we could not write is worse than silence.
        // #944: the sign-in hint is a promise about a server that is
        // answering. It only belongs under a wiki that is actually serving;
        // under one that is not, it reads as "here is the password for the
        // blank page", which is how a customer decides the install failed.
        switch wikiReachability {
        case .serving:
            Text(ViewCopy.shared.string(for: "install_complete.wiki_signin_hint"))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInkSubdued)
                .fixedSize(horizontal: false, vertical: true)
        case .checking:
            Text(ViewCopy.shared.string(for: "install_complete.wiki_checking"))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInkSubdued)
                .fixedSize(horizontal: false, vertical: true)
        case .notServing:
            VStack(alignment: .leading, spacing: 2) {
                Text(ViewCopy.shared.string(for: "install_complete.wiki_not_serving_label"))
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerInk)
                Text(ViewCopy.shared.string(for: "install_complete.wiki_not_serving_body"))
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerInkSubdued)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        }
        .padding(.horizontal, CGFloat.ostlerSpace4)
        .padding(.vertical, CGFloat.ostlerSpace2)
        .background(Color.ostlerChassis)
        }  // end outer VStack
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ostlerChassis)
        .task {
            // Fire the initial pair-code fetch when the success
            // screen first appears. .task is async, cancels on
            // disappear, and guards against double-fires if the
            // view rebuilds for an unrelated reason.
            //
            // BW-FIND-27 (2026-06-23): this is the AUTO-SHOW. It
            // retries because the success screen can render the
            // instant install.sh's start-services step fires, before
            // the gateway has bound :8000 / minted a first code -- a
            // single-shot fetch then fell through to the empty
            // placeholder and the QR stopped auto-appearing (the
            // customer-facing Refresh button still worked because by
            // then the gateway was up). autoShowPairCode retries with
            // a short backoff so the QR appears on its own.
            await autoShowPairCode()
            await probeWikiReachability()
        }
        // A SECOND .task, deliberately, rather than a line inside the one
        // above. autoShowPairCode retries the gateway with a backoff and can
        // run for many seconds; sequencing the health probe behind it would
        // leave the "Hub responding" row sitting on `.checking` for that whole
        // time and report a warning about the Hub that is really a statement
        // about the pair-code fetch. Separate .task modifiers run
        // concurrently and are each cancelled on disappear.
        .task {
            await probeHubReachability()
        }
    }

    // ── #599 "What's happening now" ───────────────────────────────
    // Calm, minimal hydration explainer (no glowing callout). Sets the
    // expectation that the wiki + assistant keep filling in for a while
    // after install. Qualitative timing only -- no hard hours number.
    @ViewBuilder
    private var whatsHappeningSection: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace1) {
            Text(ViewCopy.shared.string(for: "install_complete.hydration_label"))
                .font(.ostlerStrap)
                .tracking(1.2)
                .foregroundStyle(Color.ostlerInkMuted)
            Text(ViewCopy.shared.string(for: "install_complete.hydration_body"))
                .font(.ostlerBody)
                .foregroundStyle(Color.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ── #599 "Get Ostler on your iPhone" ──────────────────────────
    // Primary iPhone CTA: a static QR + link to a stable redirect Andy
    // repoints to the App Store listing once it is live, so the DMG
    // never needs recutting for the store URL.
    private static let iosAppURL = "https://ostler.ai/ios"

    @ViewBuilder
    private var getIosAppSection: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace2) {
            Text(ViewCopy.shared.string(for: "get_ios_app.title"))
                .font(.ostlerStrap)
                .tracking(1.2)
                .foregroundStyle(Color.ostlerInkMuted)
            HStack(alignment: .center, spacing: .ostlerSpace3) {
                staticQRPanel(payload: Self.iosAppURL)
                    .frame(width: 144, height: 144)
                VStack(alignment: .leading, spacing: .ostlerSpace1) {
                    Text(ViewCopy.shared.string(for: "get_ios_app.body"))
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ViewCopy.shared.string(for: "get_ios_app.url_caption"))
                        .font(.ostlerCaption)
                        .foregroundStyle(Color.ostlerInkSubdued)
                }
            }
        }
    }

    /// Static (non-fetched) QR panel for a fixed payload such as the
    /// iOS download URL. Same oxblood-bordered frame as the pairing QR.
    @ViewBuilder
    private func staticQRPanel(payload: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.ostlerOxblood.opacity(0.5), lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                )
            if let qrImage = Self.makeQRImage(payload: payload, size: 128) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.ostlerInkSubdued)
            }
        }
    }

    // ── #599 "Hub status" (demoted) ───────────────────────────────
    // The per-service tick list, moved out of the headline into a
    // collapsed disclosure. Still reads from logLines so it reflects
    // the actual probes.
    @ViewBuilder
    private var hubStatusSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                // 🔴 THE ROWS BELOW ARE THE TRANSCRIPT, AND THE CUSTOMER IS NOW
                // TOLD SO ON THE SCREEN. The comment block above serviceChecks
                // claimed this had been done -- "THE LOG-DERIVED ROWS SAY SO.
                // They are labelled as the installer's own report" -- and it
                // had not: the phrase existed only in that comment. Measured,
                // with a positive control of 18 install_complete.* keys proving
                // the search reaches the copy catalogue, zero rendered strings
                // said anything of the kind.
                //
                // A green tick implies a check that did not happen. This is the
                // half of board row 1589 that can be done honestly without the
                // service token, and it is the half that was claimed rather
                // than made.
                Text(ViewCopy.shared.string(for: "install_complete.hub_status_caveat"))
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, .ostlerSpace1)
                ForEach(serviceChecks) { check in
                    HStack(spacing: .ostlerSpace2) {
                        Image(systemName: check.status == .ok
                              ? "checkmark.circle.fill"
                              : "exclamationmark.triangle.fill")
                            .foregroundStyle(check.status == .ok
                                             ? Color.ostlerForest
                                             : Color.ostlerOxbloodWarm)
                            .frame(width: 18)
                        Text(check.label)
                            .font(.ostlerBody)
                            .foregroundStyle(Color.ostlerInk)
                        Spacer()
                        Text(check.status == .ok
                             ? ViewCopy.shared.string(for: "install_complete.status_ok")
                             : ViewCopy.shared.string(for: "install_complete.status_see_log"))
                            .font(.ostlerCaption)
                            .foregroundStyle(Color.ostlerInkSubdued)
                    }
                }
            }
            .padding(.top, .ostlerSpace1)
        } label: {
            Text(ViewCopy.shared.string(for: "install_complete.hub_status_label"))
                .font(.ostlerStrap)
                .tracking(1.2)
                .foregroundStyle(Color.ostlerInkMuted)
        }
        .tint(Color.ostlerInkMuted)
    }

    // ── v1.0.42 walk: keep-or-trash, defaulted to KEEP ────────────

    @ViewBuilder
    private var keepInstallerSection: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace1) {
            // Toggle is bound to the INVERSE of the coordinator flag, so the
            // customer-facing default reads "Keep this installer" = on. The
            // stored flag stays `trashInstallerOnQuit == false` by default,
            // which is what finishAndQuit() honours.
            Toggle(isOn: Binding(
                get: { !coordinator.trashInstallerOnQuit },
                set: { coordinator.trashInstallerOnQuit = !$0 }
            )) {
                Text(ViewCopy.shared.string(for: "install_complete.keep_installer_label"))
                    .font(.ostlerBody)
                    .foregroundStyle(Color.ostlerInk)
            }
            .toggleStyle(.checkbox)

            Text(ViewCopy.shared.string(for: "install_complete.keep_installer_help"))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInkSubdued)
                .fixedSize(horizontal: false, vertical: true)

            Text(ViewCopy.shared.string(for: "install_complete.auto_quit_note"))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInkSubdued)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var memoryCeilingSection: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace1) {
            Text(ViewCopy.shared.string(for: "install_complete.memory_ceiling_label"))
                .font(.ostlerStrap)
                .tracking(1.2)
                .foregroundStyle(Color.ostlerInkMuted)
            Text(ViewCopy.shared.string(for: "install_complete.memory_ceiling_body"))
                .font(.ostlerBody)
                .foregroundStyle(Color.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ── CX-56 pairing QR ──────────────────────────────────────────

    @ViewBuilder
    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace2) {
            Text(ViewCopy.shared.string(for: "pair_iphone.title"))
                .font(.ostlerStrap)
                .tracking(1.2)
                .foregroundStyle(Color.ostlerInkMuted)

            HStack(alignment: .center, spacing: .ostlerSpace3) {
                // QR panel. Always reserves a 144x144 box so the
                // layout doesn't jump between loading + loaded.
                pairingQRPanel
                    .frame(width: 144, height: 144)

                VStack(alignment: .leading, spacing: .ostlerSpace1) {
                    Text(ViewCopy.shared.string(for: "pair_iphone.help"))
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInk)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = pairFetchError {
                        Text(err)
                            .font(.ostlerCaption)
                            .foregroundStyle(Color.ostlerOxbloodWarm)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: .ostlerSpace2) {
                        Button(action: { Task { await fetchPairCode() } }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text(ViewCopy.shared.string(for: "pair_iphone.refresh_button"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(pairFetchInFlight)
                        Spacer()
                    }
                }
            }
        }
        .padding(.vertical, .ostlerSpace1)
    }

    @ViewBuilder
    private var pairingQRPanel: some View {
        ZStack {
            // Oxblood-tinted border that matches the brand.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.ostlerOxblood.opacity(0.5), lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                )

            if let envelope = pairEnvelope, !envelope.isEmpty,
               let qrImage = Self.makeQRImage(payload: envelope, size: 128) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else if pairFetchInFlight {
                VStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.ostlerOxblood)
                    Text(ViewCopy.shared.string(for: "pair_iphone.fetching"))
                        .font(.ostlerCaption)
                        .foregroundStyle(Color.ostlerInkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
            } else {
                // Error or empty state: show a muted QR-glyph
                // placeholder so the layout doesn't read as blank.
                Image(systemName: "qrcode")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.ostlerInkSubdued)
            }
        }
    }

    // BW-FIND-27 (2026-06-23): auto-show retry budget. The success
    // screen can appear before the gateway has bound :8000 and minted
    // a first pair code; without retries the one fetch fails and the
    // QR never auto-appears. Six attempts at ~1.5s spacing covers a
    // normal post-start-services gateway boot (1-3s) with headroom,
    // and bails politely (placeholder + Refresh button still live) if
    // the gateway never comes up.
    private static let autoShowMaxAttempts = 6
    private static let autoShowRetryDelay: Duration = .milliseconds(1500)

    /// AUTO-SHOW entry point fired from `.task` on first appear.
    /// MINTS a fresh pair code (so a just-installed Hub with no
    /// current code still produces a QR) and retries on transport /
    /// not-ready failures so the QR appears on its own without the
    /// customer having to tap Refresh.
    @MainActor
    private func autoShowPairCode() async {
        for attempt in 1...Self.autoShowMaxAttempts {
            let ok = await loadPairCode(mint: true)
            if ok { return }
            // Don't sleep after the final attempt. Honour task
            // cancellation (view disappeared) by bailing quietly.
            if attempt < Self.autoShowMaxAttempts {
                do {
                    try await Task.sleep(for: Self.autoShowRetryDelay)
                } catch {
                    return  // cancelled
                }
            }
        }
    }

    /// Manual Refresh handler. Re-reads the CURRENT pair code (GET
    /// semantics) -- one shot, the customer-driven retry.
    @MainActor
    private func fetchPairCode() async {
        _ = await loadPairCode(mint: false)
    }

    /// Single fetch attempt. `mint == true` POSTs /admin/paircode/new
    /// (auto-show); `mint == false` GETs /admin/paircode (Refresh).
    /// Returns true when an envelope was rendered, false on any
    /// failure (caller decides whether to retry).
    @MainActor
    @discardableResult
    private func loadPairCode(mint: Bool) async -> Bool {
        guard !pairFetchInFlight else { return false }
        pairFetchInFlight = true
        pairFetchError = nil
        defer { pairFetchInFlight = false }

        do {
            let envelope = mint
                ? try await gatewayClient.mintPairCodeEnvelope()
                : try await gatewayClient.fetchPairCodeEnvelope()
            if envelope.isEmpty {
                pairFetchError = ViewCopy.shared.string(for: "pair_iphone.fetch_failed")
                pairEnvelope = nil
                return false
            }
            pairEnvelope = envelope
            pairFetchError = nil
            return true
        } catch {
            pairFetchError = ViewCopy.shared.string(for: "pair_iphone.fetch_failed")
            pairEnvelope = nil
            return false
        }
    }

    /// Render a CoreImage QR code for the given payload at the
    /// requested integer pixel size. Uses
    /// CIFilter.qrCodeGenerator() with a high error-correction
    /// level (Q = 25%) so the printed QR survives shutter blur on
    /// the iPhone camera + scuffs on a printed sheet. Returns nil
    /// when CoreImage fails to render (extremely rare; defensive
    /// guard so the panel falls through to the placeholder rather
    /// than crashing).
    static func makeQRImage(payload: String, size: CGFloat) -> NSImage? {
        let data = Data(payload.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        // Q = 25% error correction. The §3.3 envelope is typically
        // 200-400 bytes so the QR ends up at version 8-12; Q keeps
        // it scannable in the wild.
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage else { return nil }

        // Scale up to the target size with nearest-neighbour so the
        // pixels stay crisp on Retina + non-Retina displays. The
        // generator emits a tiny image (~33x33 for a v4 code); we
        // need to upscale by an integer factor.
        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = size / extent.width
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    private func openOstlerHub() {
        if let url = URL(string: "file:///Applications/Ostler.app") {
            NSWorkspace.shared.open(url)
        }
    }

    // 🔴 THIS USED TO OPEN http://localhost:8044 IN THE BROWSER, AND THAT IS
    // THE BUTTON ANDY PRESSED. His words on his own console walk: "The wiki
    // via a browser is requesting authentication details I don't have."
    //
    // :8044 is nginx, and until this change it answered an uncredentialled
    // request with `401 + WWW-Authenticate: Basic`. That header is what makes
    // a browser pop a password box. The password was the customer's own and
    // sat 0600 on their disk, but this screen is the LAST thing they see and
    // the box cannot be filled from it.
    //
    // install.sh no longer challenges a browser on that port, so this button
    // would now open a tab saying "your wiki is in the Ostler app". Opening a
    // browser to be told to close it is not a fix. The wiki is a tab INSIDE
    // Ostler.app -- the Hub fetches it through the daemon's own proxy, which
    // presents the credential on the customer's behalf (ostler-assistant
    // crates/zeroclaw-gateway/src/wiki_proxy.rs, reached from
    // web/src/pages/Wiki.tsx at WIKI_PROXY_PATH) -- so this button opens the
    // place the wiki actually is.
    //
    // No deep link: the Hub registers no URL scheme (measured, zero
    // CFBundleURLSchemes in the hub app tree), so this opens the app and the
    // customer picks Wiki in the sidebar. The hint copy beside the button
    // says exactly that.
    private func openWiki() {
        if let url = URL(string: "file:///Applications/Ostler.app") {
            NSWorkspace.shared.open(url)
        }
    }

    // #944. THE INSTRUMENT AND THE DEFECT MUST SHARE A SURFACE. The claim this
    // button makes is "your wiki is at this URL", so the evidence has to be
    // that URL, not a line in the installer's own transcript saying it started
    // a container. A log line is what the installer BELIEVES it did.
    //
    // 401 COUNTS AS SERVING, AND THIS IS THE TRAP. The wiki has sat behind
    // auth_basic since #1609, so a correctly protected wiki answers an
    // unauthenticated request with 401. install.sh learned this the hard way
    // at its own poll loop: #1594 used `curl -sf`, whose -f fails on any 4xx,
    // and a properly secured wiki then read as a dead one. That inversion
    // would have SUPPRESSED the banner carrying the customer's password, so
    // the fix would have hidden its own credential. Any HTTP answer at all
    // means something is listening and serving; only a transport failure
    // means it is not.
    //
    // The budget is deliberately longer than install.sh's own 60 seconds. The
    // success screen can render the instant start-services fires, and a wiki
    // that is still compiling on a cold box is the ordinary case this row was
    // filed about, not an error.
    private func probeWikiReachability() async {
        guard let url = URL(string: "http://localhost:8044/") else {
            wikiReachability = .notServing
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        for attempt in 1...45 {
            if Task.isCancelled { return }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if response is HTTPURLResponse {
                    wikiReachability = .serving
                    return
                }
            } catch {
                // A transport failure is the only evidence of "not serving".
                // Swallowing it silently is what this row is about, so it is
                // recorded once, on the last attempt, rather than never.
                if attempt == 45 {
                    NSLog("install_complete: wiki at :8044 did not answer in 45 attempts: %@",
                          error.localizedDescription)
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        wikiReachability = .notServing
    }
}
