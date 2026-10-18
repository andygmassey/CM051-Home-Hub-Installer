#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to de by l10n/ostler_l10n.py.
# Generated: edit the en-GB source, never this file. '# NEEDS REVIEW' marks a key
# awaiting a native speaker; a key with no current translation carries English.
# CM051 install.sh -- en-GB strings catalogue
# Generated 2026-05-19 as part of Rule 0.9
# (customer strings extractable from day one).
#
# Sourced by install.sh near the top, before any
# info/warn/step/ok/err/fail call. To add a new
# language: copy this file to install.sh.strings.<lang>.sh,
# translate the right-hand side of each MSG_* assignment,
# and invoke the installer with OSTLER_LANG=<lang>.
#
# Format-string entries use printf %s placeholders;
# install.sh wraps them in $(printf "$KEY" "$arg1" "$arg2").
# Translators: keep the same number of %s placeholders,
# in the same order, as the English source.
#
# TODO (Wave 2.1 / W7, #596/#573): the completion/"walk away" and
# install-time-estimate copy below was reworded in en-GB only, to stop
# users walking away mid-install and to make the ETAs honest. If other
# locale catalogues (de/fr/es/it) are added later, re-translate the
# updated values for these keys (do not machine-translate):
#   MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK
#   MSG_STEP_SETUP_COMPLETE_WRAP_UP (new key)
#   MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE
#   MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES
#   MSG_OK_POWER_SOURCE_AC_GOOD_10_15
#   MSG_WARN_PHASE_3_TAKES_10_15_MINUTES
# The same softening applies to gui/OstlerInstaller/Resources/HintCopy.json
# (setup_questions, setup_complete_wrap_up).

# ── Step (top-level phase) banners ──

MSG_STEP_CHECKING_PREREQUISITES="Voraussetzungen werden geprüft"
MSG_STEP_RUNNING_HEALTH_CHECK="Integritätsprüfung läuft"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="iPhone und Watch verbinden"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="Einrichtung (ein paar kurze Fragen, danach läuft alles von selbst weiter)"
# 2026-08-20: this key used to end "...and needs nothing further from you, so
# you can leave it running and check back later." Measured against Andy's
# install log, that was false three times over. The message printed at
# 12:41:43; then 12:42:13-12:45:14 asked him seven times to click Install on a
# macOS developer-tools dialog, 13:01:20 said "This part needs you for about
# two minutes" for Full Disk Access, and 13:04:20 waited up to three minutes
# for a Tailscale sign-in. A customer who does what this sentence says comes
# back to a stalled install. It now names what is still wanted.
# F2 (console walk of DMG #16): the Tailscale sign-in and the assistant's
# Reminders prompt both moved to the END of the install (after the health
# check), so the copy says "at the very end", not "near the end".
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_SETUP_COMPLETE_WRAP_UP="Fragen beantwortet. Ostler wird jetzt im Hintergrund installiert – das dauert etwa 45 Minuten bis einige Stunden. Dreimal wirst du noch gebraucht: Wenn macOS fragt, ob Entwicklerwerkzeuge installiert werden sollen, klicke auf „Installieren“. Gegen Ende folgt eine Minute Einrichtung (Festplattenvollzugriff aktivieren). Ganz am Ende, nach der Integritätsprüfung, meldest du dich bei Tailscale an und erlaubst dem Assistenten, Erinnerungen zu verwenden. Dazwischen kannst du die Installation einfach laufen lassen."
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="Fragen beantwortet. Ostler wird jetzt im Hintergrund installiert – das dauert etwa 45 Minuten bis einige Stunden. Dreimal wirst du noch gebraucht: Wenn macOS fragt, ob Entwicklerwerkzeuge installiert werden sollen, klicke auf „Installieren“. Gegen Ende folgt eine Minute Einrichtung (Festplattenvollzugriff aktivieren). Ganz am Ende erlaubst du dem Assistenten, Erinnerungen zu verwenden. Dazwischen kannst du die Installation einfach laufen lassen."

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="und führe erneut aus: ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="Der Assistent wird neu gestartet, damit er mit Festplattenvollzugriff deinen Nachrichtenverlauf lesen kann. Erst ein Neustart macht eine soeben erteilte Berechtigung wirksam. Falls du sie noch nicht erteilt hast, leitet dich das Doctor-Dashboard weiterhin an."
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="Dein Assistent läuft und hat Festplattenvollzugriff, sodass er die benötigten Dateien lesen kann."
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="Dein Assistent läuft, hat aber noch keinen Festplattenvollzugriff. Solange du ihn nicht aktivierst, kann Ostler Nachrichten, Mail, Kalender, Erinnerungen, Notizen, Fotos, Safari, Kontakte und WhatsApp nicht aktuell halten und deinen Dokumente-Ordner nicht lesen. Was bereits gelesen wurde, bleibt erhalten. Das Doctor-Dashboard führt dich durch die Aktivierung."
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="Dein Assistent läuft. Wir konnten nicht prüfen, ob er auf diesem Mac Festplattenvollzugriff hat. Das Ergebnis ist also offen. Das Doctor-Dashboard meldet sich, sobald die Prüfung möglich ist."
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="Sichtbare Apple Mail-Accounts: %s (zur Information)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mail enthält offenbar noch keine lokalen Nachrichten. Doctor meldet sich mit einem Hinweis, falls innerhalb von 24 Stunden keine E-Mails eintreffen."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mail hat Nachrichten im Cache. Ostler übernimmt sie beim nächsten stündlichen Durchlauf."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="Apple Mail ist ausgewählt, aber auf diesem Mac gibt es noch keine lokalen Nachrichten zu lesen. Öffne Apple Mail und füge einen Account hinzu (Systemeinstellungen > Internetaccounts, dann Mail aktivieren) und lass die erste Synchronisierung abschließen."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="Sobald E-Mails eingetroffen sind, führe erneut aus: ostler-fda. Ostler übernimmt sie automatisch, mehr ist nicht nötig."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="Die Apple-Notarisierung wird beim ersten Start von Gatekeeper überprüft."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="verfügbar ist, überspringt das Installationsprogramm diesen Schritt automatisch."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="Betatester mit Zugriff können PWG_PIPELINE_REPO=<url> setzen und erneut ausführen."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="Betatester mit Zugriff können PWG_KNOWLEDGE_REPO=<url> setzen und erneut ausführen."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="Browser-Erweiterungen übersprungen (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  Geklont nach %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture läuft nur auf Apple Silicon. Die Installation wird auf diesem Mac übersprungen."
MSG_INFO_CM042_LOGS_AT="RemoteCapture-Protokolle: %s/ostler-remotecapture.log (und .err)"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="Bei einer früheren Installation wurde Ostler RemoteCapture beim Anmelden gestartet. Es wurde gestoppt und startet nicht mehr."
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="Ostler RemoteCapture wurde nicht installiert: Du hast die Transkription gesprochener Sprache ausgeschaltet. Schalte sie in den Einstellungen ein und führe das Installationsprogramm erneut aus, falls du es dir anders überlegst."
MSG_INFO_CM042_TCC_PRE_PROMPT="Beim ersten Start fragt Ostler RemoteCapture bei macOS die Berechtigungen für Bildschirmaufnahme und Mikrofon an. Erteile beide, damit Anrufe und Meetings lokal transkribiert werden können. In deiner Menüleiste erscheint kein violetter Aufnahmeindikator – die Audioerfassung läuft bewusst lautlos."
# Shown during setup to pre-explain the macOS Documents (Files and Folders)
# consent prompt. macOS gates that prompt per RESPONSIBLE PROCESS, so the
# customer may meet it more than once and not always during setup: the
# installer's own first write under ~/Documents/Ostler can prompt now, and the
# bundled python3.11 that organises the wiki writes here later from its own
# launchd jobs, prompting separately and possibly the next day. The copy is
# therefore honest about timing rather than promising an immediate prompt, and
# it carries the System Settings remediation for a decline. Paired with the
# live Documents-access tile in the dashboard
# (vendor/doctor/agent/documents_access_posture.py), which surfaces a denial
# whenever it happens.
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="Ostler speichert dein persönliches Wiki und deine Gesprächsprotokolle unter Dokumente/Ostler auf diesem Mac. Sie gehören dir und bleiben auf diesem Gerät. Zum Schreiben braucht Ostler Zugriff auf deinen Dokumente-Ordner. Deshalb fragt macOS eventuell bei der Einrichtung danach und später am Tag noch einmal, wenn Ostler dein Wiki erstmals ordnet. Die Anfrage kann so aussehen, als käme sie von python3.11, dem mitgelieferten Hilfsprogramm, mit dem Ostler deine Dateien schreibt. Klicke bitte jedes Mal auf „Erlauben“. Falls du sie verpasst oder ablehnst, kannst du den Zugriff jederzeit in den Systemeinstellungen unter Datenschutz & Sicherheit > Dateien und Ordner aktivieren. Ab dann werden dein Wiki und deine Gesprächsprotokolle geschrieben."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  Gedächtnis-Engine für Gespräche in der venv installiert."
MSG_INFO_HUB_APP_VERIFYING="Ostler.app wird überprüft unter %s"
MSG_INFO_HUB_APP_STAGING="Ostler.app wird aus %s nach /Applications bereitgestellt"
MSG_INFO_HUB_APP_DRAG_HINT="Öffne das Installer-DMG, ziehe Ostler.app und OstlerInstaller.app auf die Programme-Verknüpfung und führe das Installationsprogramm dann erneut aus."
MSG_OK_HUB_APP_PRESENT="Ostler.app ist bereits unter %s vorhanden. Signatur überprüft."
MSG_OK_HUB_APP_STAGED="Ostler.app installiert unter %s"
MSG_WARN_HUB_APP_NOT_FOUND="Ostler.app wurde in /Applications nicht gefunden und es ist keine mitgelieferte Kopie verfügbar."
MSG_WARN_HUB_APP_VERIFY_FAILED="Die Überprüfung von Signatur oder Notarisierung von Ostler.app ist fehlgeschlagen. Das Paket bleibt an Ort und Stelle, damit der Support es untersuchen kann."
MSG_OK_UNINSTALLER_APP_STAGED="Ostler Uninstaller.app installiert unter %s"
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="Ostler Uninstaller.app konnte nicht in /Applications abgelegt werden. Du kannst Ostler trotzdem deinstallieren, indem du Folgendes ausführst: ~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="Doctor-Agent wird geklont..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="E-Mail-Import-Skripte werden geklont..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Hub-Power-Skripte werden geklont..."
MSG_INFO_CLONING_IMPORT_PIPELINE="Import-Pipeline wird geklont..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="Wiki-Recompile-Skripte werden geklont..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima ist installiert, läuft aber nicht. Es wird gestartet."
MSG_INFO_COLIMA_START_ATTEMPT="Colima wird gestartet (Versuch %s von %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="Kontakte konnten nicht exportiert werden. Du kannst sie später manuell importieren."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="Die Kontaktkarte konnte nicht gelesen werden. Kein Problem – wir fragen stattdessen nach."
MSG_INFO_CONTACT_CARD_WILL_ASK="Gleich fragen wir dich nach deinem Namen und deinem Land. Deine Kontakte werden später mit dem Festplattenvollzugriff gelesen, den du erteilst, und nichts verlässt diesen Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  Python-venv wird in %s erstellt..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="Ordnerstruktur für deine Inhalte wird in %s/ erstellt"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="Täglicher Takt. Manueller Start: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="Desktop-Hub (ohne Akku) erkannt: Ruhezustand wird systemweit deaktiviert"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker ist nicht installiert. Colima, die Docker-CLI und das docker-compose-Plugin werden installiert (schlank, Docker Desktop ist nicht nötig)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="Die Doctor-Agent-Dateien sind nicht im Installer enthalten."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="Die E-Mail-Import-Skripte sind nicht im Installer enthalten."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="Die E-Mail-Import-Skripte fehlen im Installer-Paket. Lade die .app erneut von ostler.ai/install herunter und versuche es noch einmal."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Die E-Mail-Import-Skripte sind nicht enthalten und --allow-plaintext wurde übergeben. Die LaunchAgent-Installation wird übersprungen. Künftige E-Mails werden nicht abgeholt."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  Vorhandener Checkout unter %s; wird aktualisiert..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Gmail-mbox wird aus dem Takeout-ZIP extrahiert (bei großen Archiven kann das eine Minute dauern)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="Das FDA-Extraktionsmodul ist nicht enthalten. Die sofortige Datenextraktion wird übersprungen."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Deine ersten 30 Tage Ostler Pro werden aktiviert..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Ostler Pro kostet nach der Testphase 9,99 USD pro Monat. Schließe das Abo in der Ostler App auf deinem iPhone ab."
MSG_INFO_FOUND_GMAIL_MBOX_MB="Gmail-mbox gefunden unter %s (%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Google-Takeout-ZIP gefunden unter %s (%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="Festplattenvollzugriff erkannt – vollständige Extraktion verfügbar."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="DSGVO-Exporte erkannt, aber die Import-Pipeline ist noch nicht verfügbar."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="Der Import von DSGVO-Exporten ist verfügbar, sobald die Pipeline bereitsteht."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="Gleich werden Downloads, Schreibtisch und Dokumente nach KI-Exporten durchsucht (Google Takeout, Meta-Downloads, LinkedIn usw.), die du vielleicht gespeichert hast. macOS zeigt drei Abfragen zum Ordnerzugriff an – bitte erlaube jede davon. Das dauert insgesamt etwa 5–10 Sekunden. Während der Suche wird nichts verschoben oder kopiert; wir prüfen nur, was vorhanden ist."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS fragt möglicherweise um Erlaubnis, deinen Kalender zu lesen. Erlaube es, damit Ostler den Teil deines Wissensgraphen mit Terminen und Ereignissen aufbauen kann. (Kalenderdaten bleiben auf diesem Gerät.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS fragt um Erlaubnis für Downloads. Klicke auf „OK“."
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS fragt um Erlaubnis für den Schreibtisch. Klicke auf „OK“."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS fragt um Erlaubnis für Dokumente. Klicke auf „OK“."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="Festplattenvollzugriff erteilt. Die nächste macOS-Abfrage (Automation für Nachrichten) wird vorbereitet..."
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="Die Abfrage zur Nachrichten-Berechtigung wurde nicht beantwortet, deshalb haben wir weitergemacht. Deine Nachrichten werden erst gelesen, wenn sie erlaubt ist. Ostler fragt später erneut, oder du erteilst sie in Systemeinstellungen > Datenschutz & Sicherheit > Automation."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="Die Xcode Command Line Tools werden benötigt. macOS fragt nach der Erlaubnis zur Installation – achte auf ein kleines graues Dialogfenster (falls du es nicht siehst, drücke Cmd+Tab oder sieh im Dock nach). Klicke auf „Installieren“. Die Tools werden im Hintergrund geladen, während du die folgenden Fragen beantwortest."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  Die Command Line Tools werden noch eingerichtet (%ss). Falls ein kleines graues macOS-Dialogfenster fragt, ob Entwicklerwerkzeuge installiert werden sollen, klicke darin auf „Installieren“ – dieser Schritt wartet darauf. (Cmd+Tab oder ein Blick ins Dock, falls du es nicht siehst.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="Warten, bis die Command Line Tools installiert sind (fast geschafft)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="Stündlicher Takt. Beim ersten Durchlauf werden die E-Mails der letzten 5 Jahre abgerufen."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="Veralteter iMessage-Bridge-LaunchAgent wird deaktiviert (Einzelrechner v1.0)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Hub nur mit Netzbetrieb (kein Akku erkannt), der hub-power-LaunchAgent wird übersprungen."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Die Hub-Power-Skripte sind nicht im Installer enthalten."
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="Laptop-Hub. Er arbeitet weiter, solange der Deckel offen ist und er am Stromnetz hängt."
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="Wenn du den Deckel schließt oder den Mac im Akkubetrieb ungenutzt lässt, versetzt macOS ihn in den Ruhezustand."
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="Solange er schläft, empfängt der Assistent nichts."
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="Nachrichten, die in dieser Zeit eintreffen, werden beim Aufwachen nicht abgeholt."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="Im Betrieb bei geschlossenem Display kann der Deckel zubleiben."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="Dafür braucht es Netzstrom sowie ein externes Display, eine Tastatur und eine Maus."
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="Docker und Ollama pausieren im Akkubetrieb und laufen am Netz weiter."
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="Nach einem Neustart hält FileVault diesen Mac im Anmeldefenster an."
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="Ostler startet, sobald du dich anmeldest."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="Assistenten-API ist im Installer enthalten; die mitgelieferte Quelle wird verwendet."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="Quelle der Assistenten-API ist nicht enthalten; die Ostler app auf deinem iPhone hat eingeschränkten Zugriff."
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="Laufzeitabhängigkeiten der Assistenten-API werden installiert (phonenumbers, httpx)..."
MSG_WARN_ICAL_SERVER_DEPS_FAILED="Die Laufzeitabhängigkeiten der Assistenten-API (phonenumbers/httpx) konnten nicht installiert werden; Personen und Zeitleiste bleiben möglicherweise bis zur nächsten Installation leer."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Sobald das Tailscale-Fenster erscheint, melde dich mit Apple / Google / Microsoft an."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="Tailscale wird geöffnet, damit du dich anmelden kannst..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="Verstanden – ab hier installiert sich Ostler größtenteils von selbst. Gegen Ende braucht es dich noch für etwa zwei Minuten: Du schaltest den Festplattenvollzugriff ein und meldest dich dann bei Tailscale an, damit dein iPhone und deine Watch diesen Mac von überall erreichen können. Für die Anmeldung öffnen wir deinen Browser."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale übersprungen – die Ostler app auf deinem iPhone funktioniert nur in deinem WLAN zu Hause. Du kannst das später in den Einstellungen einrichten."
MSG_INFO_TAILSCALE_STILL_WAITING="Warte noch auf die Tailscale-Anmeldung (%ss vergangen) – bitte schließe die Anmeldung im Tailscale-Fenster ab."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="Festplattenvollzugriff erteilt; der Assistent wird neu gestartet, um die neue Berechtigung zu übernehmen."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="Systemeinstellungen und Finder werden geöffnet, um dich beim Erteilen des Festplattenvollzugriffs für den Assistenten anzuleiten..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="Der Ostler-Assistent wird bei macOS registriert, damit er im Festplattenvollzugriff als Schalter erscheint..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="Der Festplattenvollzugriff steht noch aus. Das Doctor-Dashboard zeigt die Karte so lange an, bis der Zugriff erteilt ist."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant hat bereits Festplattenvollzugriff; keine weitere Aktion nötig."
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="Dieser Teil braucht dich für etwa zwei Minuten: Schalte jetzt den Festplattenvollzugriff für den Assistenten ein und melde dich im nächsten Schritt bei Tailscale an. Danach kannst du Ostler den Rest allein erledigen lassen."
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="Dieser Teil braucht dich für etwa eine Minute: Schalte den Festplattenvollzugriff für den Assistenten ein. Danach kannst du Ostler den Rest allein erledigen lassen."
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="„%s“ ist bereits im Festplattenvollzugriff aufgeführt, du musst es also nur einschalten. Aus dem Finder musst du nichts hineinziehen."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Es wird geprüft, ob der Ostler-Assistent Festplattenvollzugriff hat..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="Der Assistent kann den Nachrichtenverlauf in Nachrichten lesen; der iMessage-Kanal funktioniert."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="Der Ostler-Assistent hat noch keinen Festplattenvollzugriff. Er braucht ihn, um die eigenen Apps deines Macs aktuell zu halten, ob mit oder ohne Nachrichten. Wenn du das jetzt überspringst, führt dich das Doctor-Dashboard durch die Systemeinstellungen."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="Der Assistent-LaunchAgent wurde nicht geladen; die Prüfung des Festplattenvollzugriffs für iMessage wird übersprungen."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="Die Evernote-Import-Oberfläche im Doctor zeigt „Dienst nicht verfügbar“ an"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Die Import-Pipeline ist nicht im Installer enthalten."
MSG_INFO_INSTALLING_CM042="Ostler RemoteCapture v%s wird installiert (Anruf- und Meeting-Transkription)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="Gesprächsgedächtnis-Engine wird von %s installiert..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  Gesprächsgedächtnis-Engine wird in die venv installiert..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="Colima + Docker CLI werden installiert..."
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="GNU coreutils werden installiert (für Timeout-Limits bei langen Schritten)..."
MSG_INFO_INSTALLING_HOMEBREW="Homebrew wird installiert..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="Knowledge-Dienst wird von %s installiert..."
MSG_INFO_INSTALLING_OLLAMA="Ollama wird installiert..."
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  Abhängigkeiten des Datenextraktionsmoduls werden installiert..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Apple-Mail-Reader wird in eine eigene venv installiert..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  ostler-knowledge wird in die venv installiert..."
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  Abhängigkeit für verschlüsselten Speicher wird in die Gesprächsgedächtnis-venv installiert..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Safari-Erweiterung wird in /Applications installiert"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="Python-Abhängigkeiten für die Sicherheit werden installiert..."
MSG_INFO_INSTALLING_SQLCIPHER="SQLCipher wird installiert..."
MSG_INFO_INSTALLING_TAILSCALE="Tailscale wird installiert..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="Intel-Unterstützung steht nicht auf der Roadmap; stelle bei Bedarf eine Anfrage."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Knowledge-Dienst ist im Installer enthalten; mitgelieferter Quellcode wird verwendet."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Knowledge-Dienst nicht installiert: PWG_KNOWLEDGE_REPO ist leer."
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="Dieser Mac ist ein Laptop. Als dein Hub arbeitet er weiter, solange der Deckel geöffnet und der Mac an das Stromnetz angeschlossen ist."
MSG_INFO_LAPTOP_HUB_SLEEP_COST="Wenn du den Deckel schließt oder den Mac im Akkubetrieb ruhen lässt, versetzt macOS ihn in den Ruhezustand. Der Assistent empfängt dann nichts, und Nachrichten, die in dieser Zeit eintreffen, werden nach dem Aufwachen nicht abgeholt."
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="Der Deckel kann im Betrieb mit geschlossenem Display geschlossen bleiben. Dafür sind Netzstrom sowie ein externes Display, eine Tastatur und eine Maus nötig."
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="Ein Hub auf einem Mac mini oder Mac Studio bleibt von selbst wach, falls du lieber auf einem dieser Geräte installieren möchtest."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="später in Systemeinstellungen > Datenschutz & Sicherheit > Festplattenvollzugriff"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  Start, um Cron-Zustellung und iMessage-TCC-Status zu prüfen)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="Lizenz: %s steht unter Apache 2.0. Volltext: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Lizenz: %s – prüfe vor kommerzieller Nutzung die Bedingungen des Upstream-Projekts."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="lokaler Speicher – Google erfährt nie, dass es Ostler gibt."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="Protokolle: %s/email-ingest.log (und .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="Protokolle: %s/ostler-assistant.log (und .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="Protokolle: %s/wiki-recompile.log (und .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="MacBook-Hubs: PWG_HUB_POWER_REPO=<url> setzen und erneut ausführen."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="MacBook-Hub erkannt: Ruhezustand wird nur am Netzstrom verhindert (hub-power regelt den Akkubetrieb)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Mac mini / Mac Studio sind nicht betroffen (immer am Netzstrom)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Daten vom Mac (iMessage, Safari usw.) wurden oben extrahiert."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="Manueller Neustart: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="Manuell ausführen: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="Die Installation von com.ostler.meeting-brief-sender wird übersprungen (Funktion von v1.0.1; Endpunkte noch nicht veröffentlicht)."
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="Der Memory-Hygiene-Durchlauf wird übersprungen (nicht in diesem Installer enthalten); bis dahin wird nichts automatisch abgewertet."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="Meldung, wenn das Feature-Flag später aktiviert wird."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="Brauchst du Hilfe? Schreib an support@ostler.ai. Wir antworten in der Regel innerhalb von 2 Werktagen."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="Keine Kanäle konfiguriert. Später ausführen: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="Eine veraltete config.toml im Stammverzeichnis des Arbeitsbereichs wurde entfernt; die aktive Konfiguration des Assistenten liegt unter assistant-config/."
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="Derzeit sind keine FDA-Quellen verfügbar. Du kannst den Festplattenvollzugriff erteilen"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="Keine DSGVO-Exporte in Downloads, Schreibtisch oder Dokumente gefunden."
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="%s konnte nicht gelesen werden, um nach Datenexporten zu suchen. macOS blockiert den Zugriff auf diesen Ordner."
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="Erteile den Zugriff in Systemeinstellungen > Datenschutz & Sicherheit > Dateien und Ordner (oder Festplattenvollzugriff) und starte erneut, oder wähle unten manuell deinen Exportordner für Ostler aus."
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="Ein oder mehrere Ordner konnten nicht nach Datenexporten durchsucht werden, weil macOS den Zugriff blockiert hat. Erteile den Zugriff und starte erneut, oder wähle deinen Exportordner manuell aus."
MSG_INFO_OPENING_CHROME_WEB_STORE="Chrome Web Store wird geöffnet: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="ostler-assistant-Binärdatei nicht installiert; Doctor-Prüfung wird übersprungen"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: zurückgestellt (der Daemon läuft möglicherweise noch nicht"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="Die in diesem DMG enthaltene ostler-assistant-Binärdatei wird verwendet (Installationsweg auch offline möglich)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge in der venv installiert."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler zeigt vor der Installation einen zusätzlichen Einwilligungsbildschirm an"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  Das Quell-Repository der Konversations-Gedächtnis-Engine lässt sich über die in ./install.sh --help beschriebene Umgebungsvariable überschreiben."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  Das Quell-Repository überschreiben mit PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  Das Quell-Repository überschreiben mit PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  Das Quell-Repository überschreiben mit PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  Das Quell-Repository überschreiben mit PWG_PIPELINE_REPO=<url> ./install.sh"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Einwilligungsnachweise und Region werden gespeichert..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="Phase-3-Akkuüberwachung aktiv (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="Dein Adressbuch wird gelesen (bei großen Adressbüchern kann es ein paar Minuten dauern – bitte schließe den Installer nicht)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="Richtlinie überschreiben: ~/.ostler/power.conf bearbeiten (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="Berechtigung für iMessage-Automation wird geprüft (nur Lesezugriff)..."
MSG_INFO_PULLING_GRAPH_DB_IMAGES="Die Wissensgraph-Datenbanken werden geladen (nur beim ersten Mal). Bei einer Neuinstallation kann das eine Minute dauern..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="nomic-embed-text wird geladen (274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="%s wird geladen (%s)... das kann ein paar Minuten dauern."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="Quarantäne-xattr entfernt. Sobald der Developer-ID-Build"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Safari, iMessage, Notizen, Kalender, Fotos, Erinnerungen und Mail werden gelesen..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="Deine Kontaktkarte wird gelesen, um deine Angaben vorauszufüllen..."
MSG_INFO_REGION_EU_EEA_SOURCE="Region: EU/EWR (%s, Quelle: %s)"
MSG_INFO_REGION_SOURCE="Region: %s (Quelle: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="Region: Vereinigtes Königreich (Quelle: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="Region: USA (Quelle: %s)"
MSG_INFO_REPO_URL="Repo-URL: %s"
MSG_INFO_REPO_URL_2="Repo-URL: %s"
MSG_INFO_REPO_URL_3="Repo-URL: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="Wähle jetzt die Passphrase, mit der dein Hub entsperrt wird. Du gibst sie jedes Mal ein, wenn du die Hub-Oberfläche startest."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="Wiederherstellungs-Passphrase übersprungen. (Veraltet: v1.0 erfordert immer eine Passphrase.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="Vorhandene Doctor-Agent-Installation wird wiederverwendet: %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="Vorhandene E-Mail-Import-Installation wird wiederverwendet: %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="Vorhandene hub-power-Installation wird wiederverwendet: %s"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="Vorhandener Browsererweiterungs-Schlüssel wird wiederverwendet: %s"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="Die Ostler-Erweiterung für Chrome ist nicht Teil dieser Version."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="E-Mail-Unterhaltungen: nicht eingerichtet, weil du nicht zugestimmt hast, dass Ostler die Nachrichten anderer Personen liest."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="E-Mail-Unterhaltungen: nicht eingerichtet, weil Apple Mail auf diesem Mac nicht eingerichtet ist."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="Nachrichten-Unterhaltungen: nicht eingerichtet, weil du nicht zugestimmt hast, dass Ostler die Nachrichten anderer Personen liest."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="Nachrichten-Unterhaltungen: nicht eingerichtet, weil auf diesem Mac kein Nachrichtenverlauf vorhanden ist."
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  Transkribiere ein Gespräch mit Ostler, dann schaltet sich dies von selbst ein."
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="Gesprochene Unterhaltungen: noch nicht eingerichtet, weil es keine Transkripte zum Lesen gibt."
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="Gesprochene Unterhaltungen: ausgeschaltet, weil der Ordner „Transcripts“ seit der Installation von Ostler entfernt wurde."
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  Erstelle %s neu, um es wieder einzuschalten. Ostler erstellt es nicht für dich neu."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="WhatsApp-Unterhaltungen: nicht eingerichtet, weil du nicht zugestimmt hast, dass Ostler die Nachrichten anderer Personen liest."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="WhatsApp-Unterhaltungen: nicht eingerichtet, weil WhatsApp ausgeschaltet ist."
MSG_INFO_CHROME_HISTORY_STILL_READ="  Ostler liest weiterhin deinen Chrome-Verlauf, daher werden besuchte Seiten gemerkt. Die Live-Erfassung beim Surfen gibt es vorerst nur in Safari."
MSG_INFO_REUSING_EXISTING_JWT_SECRET="Vorhandenes JWT_SECRET in %s wird wiederverwendet"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="Vorhandenes PWG-Dienst-Token wird wiederverwendet: %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="Vorhandene wiki-recompile-Installation wird wiederverwendet: %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="Safari-Erweiterungspaket ist in diesem Installer-Build nicht enthalten (wird übersprungen)"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="Ein manueller Schritt bleibt: Öffne Safari, wähle Safari > Einstellungen > Erweiterungen und setze ein Häkchen bei Ostler, um die Erweiterung zu aktivieren."
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="Suche nach DSGVO-Datenexporten..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="Setze PWG_DOCTOR_REPO=<url> und führe den Vorgang erneut aus, um die Installation durchzuführen."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="Setze PWG_HUB_POWER_REPO=<HR015 url> und führe den Vorgang erneut aus, um die Installation durchzuführen."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="Konversationsmodell übersprungen. Später laden: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Colima wird gestartet (schlanke Docker-Laufzeitumgebung)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Docker Desktop wird gestartet..."
MSG_INFO_STARTING_OLLAMA="Ollama wird gestartet..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="Veraltetes Colima-Startobjekt einer älteren Version wird entfernt..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="Veraltete Ollama-Formula (ohne llama-server) wird entfernt, Wechsel zur Ollama-App..."
MSG_INFO_VERIFYING_EMBEDDINGS="Es wird geprüft, ob die Embedding-Engine Vektoren zurückgibt..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="Ollama konnte nicht automatisch gestartet werden. Lade es mit: launchctl bootstrap gui/\$(id -u) %s – und führe dann den Installer erneut aus."
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="Ollama wurde nicht über den Hintergrunddienst gestartet; es wird für diesen Durchlauf direkt gestartet..."
# NEEDS REVIEW: Mid-sentence fragment split across lines. The proposed 'danach zuerst' distorts the meaning. A human must check the German against the neighbouring lines.
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  startet; führe nach dem ersten Start \`ostler-assistant doctor\` aus"
MSG_INFO_SYMLINKING="  Symlink wird erstellt: %s -> %s"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(Systemeinstellungen > Internetaccounts). Ostler liest aus den Mail-"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(Der Rest von Ostler läuft auch ohne das Doctor-Dashboard.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="Das ist vorerst so vorgesehen. Der DSGVO-Import wird in einem zukünftigen Update verfügbar sein."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="Das dauert in der Regel 15 bis 45 Minuten und kann länger dauern, wenn du viel Verlauf hast oder dein Mac langsamer ist. Das ist normal – es arbeitet und hängt nicht, also lass es ruhig weiterlaufen..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="Dabei werden macOS-Datenbanken direkt gelesen – ein Export ist nicht nötig."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="Tipp: Um dein Gmail einzubeziehen, füge es zuerst in Mail auf dem Mac hinzu"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="So installierst du es später, sobald du Zugriff hast:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="iCloud-Synchronisierung für %s wird ausgelöst (im Hintergrund, nur beim ersten Start)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (UK GDPR Artikel 9 - erforderlich für besondere Kategorien personenbezogener Daten)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="Bestehende Pipeline wird aktualisiert..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="Benutzerseitige Struktur bereits angekündigt (Sentinel vorhanden); wird übersprungen"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="Die lokale Websuchmaschine wird geladen (etwa 3,5 GB). Bei einer Erstinstallation ist das der längste Schritt und kann bis zu einer Stunde dauern. Dafür gibt es keine Fortschrittsanzeige, daher ist eine lange Pause ohne Ausgabe hier normal und bedeutet nicht, dass die Installation hängt."
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane antwortet nicht (optional; siehe Warnungen zu Phase 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="Jederzeit anzeigen mit: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="Die Spracherkennung bleibt ausgeschaltet. Du kannst sie später in den Einstellungen aktivieren."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="Warte darauf, dass du dich bei Tailscale anmeldest (bis zu 3 Minuten)..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="Der Tailscale-Fernzugriff wurde nicht eingerichtet. Die Ostler app auf deinem iPhone funktioniert in deinem WLAN zu Hause; den Fernzugriff kannst du später in den Einstellungen einrichten."
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="Dieser Mac ist bereits mit deinem Tailscale-Netzwerk verbunden, also gibt es nichts einzurichten. Deine bestehende Verbindung bleibt erhalten."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="Fernzugriff: Deine Antwort vom letzten Mal (überspringen) wird beibehalten. Deine iOS-App funktioniert in deinem WLAN zu Hause, und den Fernzugriff kannst du später in den Einstellungen einrichten."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="Fernzugriff: Deine Antwort vom letzten Mal (einrichten) wird beibehalten."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="WhatsApp-Connector bleibt ausgeschaltet. Du kannst ihn später in den Einstellungen aktivieren."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="WhatsApp-Keepalive geplant für 08:50 + 17:50 (Label com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="Wiki-Nachhollauf am ersten Tag wird übersprungen: Der Wiki-Recompile-Tick ist nicht installiert. Der tägliche Wiki-Neuaufbau läuft, falls installiert, weiterhin."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Wiki-Recompile-Skripte sind nicht im Installer enthalten."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="Das Wiki wird nicht automatisch aktualisiert; du kannst die erste Kompilierung manuell erneut ausführen:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="Posture-Markierung geschrieben: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="Deine Exporte sind sicher. Importiere sie später mit: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="Deine Mac-Daten (iMessage, Safari usw.) wurden oben bereits extrahiert."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="Du kannst es später hinzufügen, für eine sofortige Einrichtung aus Safari, iMessage usw."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="KI-Modell: %s (%s) – ausgewählt für deine %s GB RAM"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="Passt"
MSG_MODELFIT_PILL_SLOW="Evtl. langsam"
MSG_MODELFIT_PILL_NOFIT="Passt nicht"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="Das Assistenten-Modell wird auf deinen Mac abgestimmt (%s, %s GB RAM, Assistenten-Kontext %s Tokens):"
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- Empfohlen"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="KI-Modell: %s (%s) – passt am besten zu deinen %s GB RAM beim erforderlichen Kontextfenster des Assistenten"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="Alle Quellen ausgewählt (Gesichtserkennung bleibt aus)"
MSG_OK_ALREADY_AVAILABLE="%s ist bereits verfügbar"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon erkannt"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="Apps gestartet, um die iCloud-Synchronisierung auszulösen"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="App-Datenbanken sind bereits vorhanden (Vorabstart wird übersprungen)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="Assistenten-Konfiguration gespeichert unter %s (Modus 0600)"
MSG_OK_BACKED_UP_CONTACTS="%s Kontakte gesichert unter %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s installiert unter %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="Ostler RemoteCapture LaunchAgent geladen (Label %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima und Docker CLI installiert"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="Container-Runtime-Überwachung installiert (prüft alle 5 Minuten und startet die Runtime neu, falls sie stoppt)"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="Die Container-Runtime-Überwachung konnte nicht eingeplant werden. Ostler wird trotzdem installiert, aber wenn die Runtime später stoppt, startet sie nichts von selbst wieder. Dein Wiki bliebe offline, bis du das Installationsprogramm erneut ausführst."
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="Die Dateien der Container-Runtime-Überwachung fehlen in diesem Installationsprogramm, daher wurde sie nicht eingeplant. Ostler wird trotzdem installiert, aber die automatische Wiederherstellung der Runtime ist nicht aktiv."
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
# NEEDS REVIEW: Section names People/Timeline/Governor must match the app's German UI labels; verify against the app catalogue.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="Das Ostler-Doctor-Dashboard konnte nicht gestartet werden, daher antwortet http://localhost:8089 nicht. Die Seiten der App, die daraus lesen (Personen, Zeitleiste, Governor, Kanalstatus), werden als nicht verfügbar angezeigt, bis es läuft. Führe das Installationsprogramm erneut aus, um es noch einmal zu versuchen."
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="Der Helfer, der den Mac wach hält, konnte nicht eingeplant werden. Ostler funktioniert weiterhin, aber dieser Mac kann bei langen Hintergrundaufgaben in den Ruhezustand wechseln. Sie werden dann beim Aufwachen fortgesetzt, statt über Nacht fertig zu werden."
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="Der Helfer für das Nachladen im Hintergrund konnte nicht eingeplant werden, daher werden neue Nachrichten, E-Mails und Kalendereinträge nicht von selbst abgeholt. Führe das Installationsprogramm erneut aus, um ihn wiederherzustellen."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="%s nicht eingerichtet: Ostler hat keine gespeicherte Antwort von dir auf die zugehörige Frage und hat deshalb keine angenommen."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  Führe Ostler erneut aus und beantworte die Fragen noch einmal, um es zu aktivieren. (Einwilligungsnachweis: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="Die tägliche Übersicht konnte nicht eingeplant werden, daher erhältst du die Zusammenfassung am Morgen nicht. Alles andere funktioniert; führe das Installationsprogramm erneut aus, um sie wiederherzustellen."
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="Die Gedächtnispflege konnte nicht eingeplant werden, daher werden veraltete oder ersetzte Fakten nicht automatisch heruntergewichtet. Alles andere funktioniert; führe das Installationsprogramm erneut aus, um sie wiederherzustellen."
MSG_WARN_EXPORT_SCAN_NOT_LOADED="Die Überwachung des Ordners „Downloads“ konnte nicht gestartet werden, daher werden Dateien, die du dort ablegst, nicht automatisch übernommen. Bereits Importiertes ist nicht betroffen, und du kannst Dateien weiterhin in der App hinzufügen. Führe das Installationsprogramm erneut aus, um sie wiederherzustellen."
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="Der Wiederholungshelfer für die Geräteregistrierung konnte nicht eingeplant werden. Wenn sich dein iPhone bei der Einrichtung registriert hat, ändert das nichts. Falls nicht, musst du es in der App erneut koppeln, statt dass es von selbst abgeschlossen wird."
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="Container-Runtime antwortet"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="Veraltetes Colima-Startobjekt einer älteren Version entfernt"
MSG_OK_CONFIG_SAVED_ENV="Konfiguration gespeichert unter %s/.env"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Einwilligungsnachweise und Region gespeichert unter ~/.ostler/posture/"
MSG_OK_AT_REST_EXCLUDED="Von Spotlight und Time Machine ausgenommen (geprüft): %s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s ist NICHT von Time Machine oder Spotlight ausgenommen: %s. Der Inhalt, einschließlich der Geheimnisse von Ostler, wird möglicherweise auf deine Backup-Festplatte kopiert. Der Doctor zeigt dies so lange an, bis es behoben ist."
MSG_INFO_AT_REST_FOLDER_ABSENT="%s existiert noch nicht, daher gibt es nichts, was von Backups ausgenommen werden müsste."
MSG_WARN_DB_KEY_NOT_EXCLUDED="Die Datenbankschlüsseldatei %s ist NICHT von Time Machine ausgenommen und wird möglicherweise auf deine Backup-Festplatte kopiert."
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="Deine Auswahl zur Anreicherung im Hintergrund konnte nicht unter ~/.ostler/posture/ gespeichert werden. Sie wird für diese Installation trotzdem angewendet, erscheint aber nicht in einem Support-Bericht."
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="Datenbanken verschlüsselt. Die Hub-Dienste lesen den Schlüssel aus einer geschützten Datei in deinem Benutzerordner und starten daher ohne Nachfrage."
MSG_OK_DB_KEY_DELIVERED="Datenbankschlüssel an die Hub-Dienste übergeben (%s, nur für dich lesbar)."
MSG_WARN_DB_KEY_NOT_DELIVERED="Der Datenbankschlüssel konnte nicht an die Hub-Dienste übergeben werden. Sie öffnen Datenbanken unverschlüsselt, bis dies behoben ist."
MSG_INFO_DB_KEY_RECOVER_HINT="Führe dies aus, um ihn wiederherzustellen und zu übergeben: %s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="Datenbanken aus einer früheren Installation werden verschlüsselt"
MSG_WARN_DB_MIGRATION_FAILED="Einige vorhandene Datenbanken konnten nicht verschlüsselt werden. Sie bleiben auf dem Datenträger lesbar."
MSG_WARN_DB_KEY_MISSING_ON_RERUN="Diese Installation hat keine Datenbankschlüsseldatei, daher öffnen die Hub-Dienste Datenbanken unverschlüsselt."
MSG_WARN_DB_PLAINTEXT_COUNT="%s Datenbank(en) auf diesem Mac sind derzeit auf dem Datenträger lesbar."
MSG_INFO_DB_MIGRATE_HINT="Verschlüssele dann, was bereits vorhanden ist: %s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="Verzögerter Wiederholungsversuch für die Geräteregistrierung installiert (läuft stündlich, bis die Warteschlange leer ist)"
MSG_OK_DOCKER_RUNNING="Docker läuft"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker läuft (nach %ss)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Doctor-Agent von %s geklont"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Doctor-Agent-Dateien im Installer gebündelt"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Doctor-Abhängigkeiten installiert"
MSG_OK_EMAIL_CHANNEL_FOLDER="E-Mail-Kanal: %s (Ordner: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="E-Mail-Ingest-LaunchAgent geladen (Label com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="E-Mail-Ingest-Skripte im Installer gebündelt"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="E-Mail-Ingest-Skripte von %s geklont"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="WhatsApp-Gesprächsgedächtnis wird eingerichtet"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  WhatsApp-Gesprächsleser installiert."
MSG_WARN_WHATSAPP_SOURCE_FAILED="Installation des WhatsApp-Gesprächslesers fehlgeschlagen; der WhatsApp-Gesprächsfeed wird nicht ausgeführt. Siehe Ausgabe oben."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="Quelle des WhatsApp-Gesprächslesers nicht gefunden; der WhatsApp-Gesprächsfeed wird übersprungen."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="WhatsApp-Gesprächsfeed-Paket in diesem Installer nicht gefunden; wird übersprungen. Der WhatsApp-Nachrichtenverlauf (mit wem du wann geschrieben hast) ist davon nicht betroffen."
MSG_OK_WHATSAPP_BUNDLE_LOADED="WhatsApp-Gesprächsfeed-LaunchAgent geladen (Label com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  Der erste Durchlauf liest aktuelle WhatsApp-Gespräche, die dein Mac synchronisiert hat (etwa das letzte Jahr); sie bleiben auf deinem Mac."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  Protokolle: %s/whatsapp-bundle.log und whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="Installation des WhatsApp-Gesprächsfeed-LaunchAgents fehlgeschlagen. Siehe Ausgabe oben; der Rest der Installation ist nicht betroffen."
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  Noch nicht gestartet: Das Assistentenprogramm, das dieser Agent ausführt, ist nicht auf der Festplatte. Gesucht wurde unter: %s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="E-Mail-Gesprächsgedächtnis wird eingerichtet"
MSG_OK_EMAIL_SOURCE_INSTALLED="  E-Mail-Gesprächsleser installiert."
MSG_WARN_EMAIL_SOURCE_FAILED="Installation des E-Mail-Gesprächslesers fehlgeschlagen; der E-Mail-Gesprächsfeed wird nicht ausgeführt. Siehe Ausgabe oben."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="Quelle des E-Mail-Gesprächslesers nicht gefunden; der E-Mail-Gesprächsfeed wird übersprungen."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="E-Mail-Gesprächsfeed-Paket in diesem Installer nicht gefunden; wird übersprungen. Der stündliche E-Mail-Ingest ist davon nicht betroffen."
MSG_OK_EMAIL_BUNDLE_LOADED="E-Mail-Gesprächsfeed-LaunchAgent geladen (Label com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Liest deine aktuellen E-Mail-Threads aus dem lokalen Speicher von Apple Mail; alles bleibt auf deinem Mac."
MSG_INFO_EMAIL_BUNDLE_LOGS="  Protokolle: %s/email-bundle.log und email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="Installation des E-Mail-Gesprächsfeed-LaunchAgents fehlgeschlagen. Siehe Ausgabe oben; der Rest der Installation ist nicht betroffen."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="Gesprächsgedächtnis für Meetings und Sprachnotizen wird eingerichtet"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  Leser für Meeting- und Sprachgespräche installiert."
MSG_WARN_SPOKEN_SOURCE_FAILED="Installation des Lesers für Meeting- und Sprachgespräche fehlgeschlagen; der Feed wird nicht ausgeführt. Siehe Ausgabe oben."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="Quelle des Lesers für Meeting- und Sprachgespräche nicht gefunden; der Feed wird übersprungen."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="Paket für den Meeting- und Sprachgesprächsfeed in diesem Installer nicht gefunden; wird übersprungen."
MSG_OK_SPOKEN_BUNDLE_LOADED="LaunchAgent für den Meeting- und Sprachgesprächsfeed geladen (Label com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  Transkribiert deine eigenen Meetings und Sprachnotizen zu durchsuchbaren Gesprächen; alles bleibt auf deinem Mac."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  Protokolle: %s/spoken-bundle.log und spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="Installation des LaunchAgents für den Meeting- und Sprachgesprächsfeed fehlgeschlagen. Siehe Ausgabe oben; der Rest der Installation ist nicht betroffen."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="iMessage-Gesprächsgedächtnis wird eingerichtet"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  iMessage-Gesprächsleser installiert."
MSG_WARN_IMESSAGE_SOURCE_FAILED="Installation des iMessage-Gesprächslesers fehlgeschlagen; der iMessage-Gesprächsfeed wird nicht ausgeführt. Siehe Ausgabe oben."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="Quelle für den iMessage-Unterhaltungsleser nicht gefunden; der iMessage-Unterhaltungsfeed wird übersprungen."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="Paket für den iMessage-Unterhaltungsfeed in diesem Installer nicht gefunden; wird übersprungen."
MSG_OK_IMESSAGE_BUNDLE_LOADED="LaunchAgent für den iMessage-Unterhaltungsfeed geladen (Label com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  Liest deine letzten iMessage-Unterhaltungen aus dem Nachrichten-Speicher dieses Macs; alles bleibt auf deinem Mac."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  Protokolle: %s/imessage-bundle.log und imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="Installation des LaunchAgents für den iMessage-Unterhaltungsfeed fehlgeschlagen. Siehe die Ausgabe oben; der Rest der Installation ist davon nicht betroffen."
MSG_OK_EMBEDDING_MODEL_READY="Embedding-Modell bereit"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="%s Kontakte exportiert (werden automatisch importiert)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="Export-Watcher installiert (durchsucht alle 4 Stunden den Ordner „Downloads“)"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  Export-Watcher noch nicht gestartet: Das Assistenten-Programm, das er ausführt, ist nicht auf dem Datenträger. Gesucht wurde: %s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="Versand der Briefings vor Terminen installiert (prüft tagsüber alle 10 Minuten)"
MSG_OK_MEMORY_HYGIENE_INSTALLED="Gedächtnispflege geplant (läuft täglich, damit veraltete Fakten aktuelle nicht verdrängen)"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="Dein Mac bleibt am Stromnetz wach, damit Ostler weiterarbeitet (im Akkubetrieb schläft er weiterhin ein)"
MSG_OK_EXTRACTED="Extrahiert nach %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="Aus %s Quelle(n) extrahiert. Daten gespeichert unter %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="FDA-Wiederholung alle %s Minuten geplant (erfasst langsame iCloud-Synchronisierungen und schließt das Nachladen des Kalenders ab)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro ist 30 Tage lang aktiv. Abonniere in der Ostler app auf deinem iPhone, um nach der Testphase zu verlängern."
MSG_OK_FOUND="Gefunden: %s"
MSG_OK_FOUND_EXPORTS="Exporte gefunden unter %s"
MSG_OK_FOUND_GDPR_EXPORT_S="%s DSGVO-Export(e) gefunden:"
MSG_OK_GB_FREE_DISK_SPACE="%s GB freier Speicherplatz"
MSG_OK_GB_RAM_DETECTED="%s GB RAM erkannt"
MSG_OK_GDPR_IMPORT_COMPLETE="DSGVO-Import abgeschlossen"
MSG_OK_GIT_AVAILABLE="Git verfügbar"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="Installation der Command Line Tools gestartet (Download im Hintergrund, während du die Fragen unten beantwortest)."
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils installiert (lange Schritte haben jetzt ein Zeitlimit)"
MSG_OK_HOMEBREW_INSTALLED="Homebrew installiert"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent für Hub-Energie geladen (Label com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Skripte für Hub-Energie im Installer enthalten"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Skripte für Hub-Energie von %s geklont"
MSG_OK_ICAL_SERVER_INSTALLED="Assistenten-API installiert (Loopback 127.0.0.1:8090, über Doctor weitergeleitet)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="LaunchAgent für die iMessage-Bridge geladen (Label com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="Skripte für die iMessage-Bridge im Installer enthalten"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="Skripte für die iMessage-Bridge von %s geklont"
MSG_OK_IMESSAGE_CHANNEL="iMessage-Kanal: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="Import-Pipeline im Installer enthalten"
MSG_OK_IMPORT_PIPELINE_READY="Import-Pipeline bereit"
MSG_OK_CM048_PIPELINE_READY="Gedächtnis-Engine für Unterhaltungen bereit."
MSG_INFO_CM048_SETTINGS_WRITTEN="  Unterhaltungsmodelle auf %s eingestellt (passend zu deinen %s GB Arbeitsspeicher)"
MSG_INFO_CM048_SETTINGS_KEPT="  Deine bestehenden Unterhaltungseinstellungen (%s) bleiben erhalten"
MSG_OK_KNOWLEDGE_SERVICE_READY="Wissensdienst bereit: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="Lizenztexte installiert unter %s/ (Quelle: %s)"
MSG_OK_MACOS_DETECTED="macOS %s erkannt"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="Systemeinstellungen > Internetaccounts wird geöffnet, damit du ein E-Mail-Konto hinzufügen kannst. Kehre zu diesem Fenster zurück, sobald du dich bei deinem ersten Konto angemeldet hast."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="Der Schritt „Internetaccounts“ wird übersprungen. Du kannst später in den Systemeinstellungen ein E-Mail-Konto hinzufügen. Doctor weist dich darauf hin, falls innerhalb von 24 Stunden keine E-Mails eintreffen."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Dein gesamter Apple Mail-Verlauf wird jetzt abgerufen. Bei einem großen Postfach kann das etwas länger dauern."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="Das übliche E-Mail-Zeitfenster von fünf Jahren bleibt bestehen. Mehr kannst du später über Doctor abrufen."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text bereits verfügbar"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="Ollama installiert"
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama installiert (nur CLI – nach einem Neustart eventuell manueller Start nötig)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama installiert (Desktop-App)"
MSG_OK_OLLAMA_RUNNING="Ollama läuft"
MSG_OK_EMBEDDINGS_VERIFIED="Embedding-Engine geprüft (768-dimensionale Vektoren)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: 0 Fehler bei den eigenen Startprüfungen"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="Ostler-Assistent-LaunchAgent geladen (Label com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s bereitgestellt unter %s (signiert)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s bereitgestellt unter %s (nicht signiert)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor läuft unter http://localhost:8089/doctor"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  Das Modul zur Datenextraktion wird korrekt geladen."
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Apple Mail-Reader installiert."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  E-Mail-Import-Engine installiert."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="Befehle ostler-import, ostler-fda und ostler-uninstall installiert"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="Passphrase notiert. Sie verschlüsselt deine Datenbanken in Phase 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="Wiederherstellungs-Passphrase eingerichtet."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="Hinweis zur Passphrase bestätigt."
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="Passwort für den Disney+-Export notiert. Es wird beim Import verwendet."
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="Der Disney+-Export wird übersprungen: Es wurde kein Passwort angegeben. Alles andere bleibt unberührt."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="Stromquelle: Netzstrom (Desktop-Mac, kein Akku)"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="Stromquelle: Netzstrom (gut – die Installation kann 45 Minuten bis einige Stunden dauern, daher läuft sie mit Netzstrom stabiler)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="Frühere Installation erkannt. Konfiguration wird geladen..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="Mitgeliefertes Python %s wird verwendet (keine Systeminstallation nötig)"
MSG_OK_PYTHON_INSTALLED="Python %s installiert"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="Kopplungsdienst funktioniert einwandfrei"
MSG_WARN_GATEWAY_NOT_RESPONDING="Kopplungsdienst antwortet nicht (127.0.0.1:8000) - Kopplung mit iPhone/Browser und der Chat-Assistent funktionieren eventuell noch nicht"
MSG_OK_DOCTOR_HEALTHY="Doctor funktioniert einwandfrei"
MSG_WARN_DOCTOR_NOT_RESPONDING="Doctor antwortet nicht (127.0.0.1:8089) – die App und der Browser erreichen Ostler darüber, daher sind Daten und Kopplung möglicherweise nicht verfügbar"
MSG_OK_WIKI_HEALTHY="Dein Wiki ist in Ordnung"
MSG_OK_ICAL_SERVER_HEALTHY="Assistenten-API ist in Ordnung"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="Assistenten-API antwortet nicht (127.0.0.1:8090) – Personen, Meetings und Zeitleiste sind möglicherweise leer, bis sie startet"
MSG_OK_READY="%s ist bereit"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="Empfohlene Quellen ausgewählt"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="Wiederherstellungsschlüssel im Schlüsselbund gesichert (suche in der App „Passwörter“ nach „Ostler“)"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Safari-Erweiterung installiert unter %s"
MSG_OK_SAFARI_EXTENSION_PAIRED="Safari-Erweiterung mit diesem Hub gekoppelt"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="Die Sicherheit wurde bereits bei einem früheren Durchlauf eingerichtet."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="Sicherheitsmodul in venv installiert"
MSG_OK_SEEDED_FRESH_JWT_SECRET="Neues JWT_SECRET in %s angelegt"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="PWG-Dienst-Token in %s angelegt"
MSG_OK_SEEDED_EXTENSION_TOKEN="Schlüssel für die Browsererweiterung in %s angelegt"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="Dienste gestartet (Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  Suchsammlung vorbereitet: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="Die Suchsammlung %s konnte noch nicht vorbereitet werden. Der Datenimport unten versucht es erneut und stoppt, statt deine Daten zu verwerfen, falls es weiterhin nicht klappt."
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="Der Suchindex war noch nicht rechtzeitig bereit. Der Datenimport unten wartet darauf, bereitet die Sammlungen vor und stoppt, statt deine Daten zu verwerfen, falls der Speicher weiterhin nicht bereit ist."
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="Deine Daten wurden nicht importiert. Der Suchspeicher konnte nicht darauf vorbereitet werden, sie aufzunehmen (fehlt: %s), und ein trotzdem durchgeführter Import hätte sie stillschweigend verworfen. Es ging nichts verloren. Führe das Installationsprogramm erneut aus, sobald der Mac nicht ausgelastet ist, oder setze OSTLER_QDRANT_READY_WAIT_S, um länger zu warten."
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="Der Datenimport hat %s Einträge verarbeitet, aber keinen davon gespeichert: Der Suchspeicher hat jeden einzelnen abgelehnt, sodass am Ende ein leerer Wissensgraph als vollständig dargestellt würde. Der Vorgang wird gestoppt, statt dir das anzuzeigen. Führe das Installationsprogramm erneut aus, sobald der Mac nicht ausgelastet ist."
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="Das eigene Protokoll des Imports konnte nicht gelesen werden, daher konnte nicht geprüft werden, ob deine Daten tatsächlich angekommen sind. Das heißt weder, dass der Import fehlgeschlagen ist, noch, dass er erfolgreich war."
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="Ruhezustand am Netzteil deaktiviert, Ruhezustand im Akkubetrieb beibehalten, Aufwecken über das Netzwerk aktiviert"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="Ruhezustand deaktiviert, Aufwecken über das Netzwerk aktiviert"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale ist bereits installiert"
MSG_OK_TAILSCALE_INSTALLED="Tailscale installiert"
MSG_OK_TAILSCALE_ENV_PERSISTED="Tailscale-IP in .env gesichert – die Ostler app auf deinem iPhone verwendet sie beim ersten Start."
MSG_OK_TAILSCALE_IP="Tailscale-IP: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Tailscale-Hintergrunddienst gestartet (Userspace-Modus, keine Systemerweiterung)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="Der Tailscale-Hintergrunddienst konnte nicht gestartet werden. Du kannst die Einrichtung später in den Einstellungen erneut ausführen."
MSG_INFO_TAILSCALE_SIGN_IN_URL="Dein Browser wird geöffnet, um dich bei Tailscale anzumelden: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Hub-Port %s in deinem Tailnet freigegeben"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="Hub-Port %s konnte nicht in deinem Tailnet freigegeben werden; der Zugriff von außerhalb des lokalen Netzwerks ist möglicherweise eingeschränkt"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="Dein Wiki ist jetzt von deinen eigenen Geräten aus unter %s lesbar – angemeldet als du und nur du."
MSG_INFO_WIKI_TAILNET_OWNER="Der Wiki-Zugriff ist auf dein Tailscale-Konto (%s) beschränkt. Andere Personen in deinem Tailnet erhalten einen 403-Fehler."
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="Dein Wiki bleibt nur auf diesem Mac. Öffne Ostler und wähle in der Seitenleiste „Wiki“, um es zu lesen."
MSG_INFO_WIKI_TAILNET_BANNER="%s  (von deinen eigenen Geräten aus, über Tailscale. Das ist der einzige Weg, der die oben genannte Anmeldung verlangt.)"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="in der Ostler app. Öffne Ostler und wähle in der Seitenleiste „Wiki“; deine Seiten sind dort, bereits angemeldet."
MSG_INFO_WIKI_INTERNAL_ADDRESS="Ostler ruft diese Seiten auf diesem Mac unter http://localhost:8044 ab. Diese Adresse ist intern, dort gibt es nichts, wofür du dich anmelden müsstest."
MSG_INFO_WIKI_SIGN_IN="Deine Wiki-Anmeldung ist %s mit dem Passwort %s. Ostler übernimmt sie für dich, du musst also auf diesem Mac nichts eintippen; du brauchst sie nur, wenn du das Wiki von einem anderen deiner Geräte über Tailscale öffnest."
MSG_INFO_WIKI_SIGN_IN_WITHHELD="Deine Wiki-Anmeldung lautet %s. Das Passwort wird nicht in dieses Protokoll geschrieben; es liegt in deiner Zwischenablage und in der unten genannten Datei. Ostler gibt es für dich ein, du musst auf diesem Mac also nichts eintippen."
MSG_INFO_WIKI_PORT_LAST_STATUS="Letzter HTTP-Status vom Wiki-Port: %s (000 bedeutet, dass nichts geantwortet hat; 403 bedeutet, dass eine Antwort kam, die Zugangsdaten aber abgelehnt wurden)."
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="Dein Passwort wird außerdem unter %s aufbewahrt, die Zwischenablage ist also nicht die einzige Kopie."
MSG_INFO_WIKI_STILL_BUILDING="Wird noch erstellt. %s Seiten liegen bereits auf dem Datenträger, und die letzte Antwort von der Wiki-Adresse war HTTP %s. Das Wiki erscheint von selbst in der Ostler app. Du musst nichts tun."
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="Der erste Build hat noch keine Seiten erzeugt (siehe die Warnungen oben). Dein Wiki öffnet sich trotzdem in der Ostler app, sobald es erstellt ist, und die Anmeldung oben bleibt dir erhalten."
MSG_INFO_WIKI_READINESS_NOT_MEASURED="Bei diesem Durchlauf wurde nicht gemessen, ob das Wiki bereits erreichbar ist, daher wird dazu nichts behauptet. Dein Wiki öffnet sich trotzdem in der Ostler app, und die Anmeldung oben bleibt dir erhalten."
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="Es konnte nicht bestätigt werden, welchem Tailscale-Account dieser Mac gehört, deshalb wurde das Wiki NICHT in deinem Tailnet freigegeben. Es ist weiterhin auf diesem Mac verfügbar, in der Ostler app unter Wiki."
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="Das Wiki konnte nicht in deinem Tailnet veröffentlicht werden; es ist weiterhin auf diesem Mac verfügbar, in der Ostler app unter Wiki."
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="Die Zugangskontrolle des Wikis konnte nicht neu geladen werden, deshalb wurde das Wiki NICHT in deinem Tailnet freigegeben."
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="Tailscale Funnel ist für %s eingeschaltet. Funnel veröffentlicht Inhalte im offenen Internet. Ostler schaltet Funnel nie ein und dein Wiki weist Funnel-Datenverkehr ab, daher ist nichts von Ostler öffentlich – aber wenn du Funnel nicht aktivieren wolltest, schalte es in der Tailscale-Admin-Konsole für diesen Rechner aus."
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="Drittanbieter-Hinweise installiert (Quelle: %s)"
MSG_OK_USER_FACING_TREE_READY="Benutzerordnerstruktur bereit"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="Stattdessen wird der Ordner bzw. die Bezeichnung „Ostler“ verwendet."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane funktioniert einwandfrei (lokale Websuche)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane läuft unter http://localhost:3000 (nutzt dein lokales Ollama)"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="Der WhatsApp-Connector wird aktiviert (Einwilligung festgehalten)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="LaunchAgent für den Wiki-Abgleich am ersten Tag geladen (erstellt dein Wiki in den ersten Stunden alle 30 Minuten neu und hört dann auf)"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="Doppelte Kontakte werden noch zusammengeführt – große Adressbücher können mehrere Minuten dauern (%ss vergangen)"
MSG_INFO_DEDUPE_MERGED="Doppelte Kontakte zusammengeführt"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="Das Zusammenführen doppelter Kontakte dauert bei einem Adressbuch dieser Größe etwas. Es läuft nach der Installation im Hintergrund weiter – dein Wiki aktualisiert sich automatisch, sobald es fertig ist."
MSG_WARN_DEDUPE_INCOMPLETE="Der Durchlauf zum Entfernen von Duplikaten im gesamten Graphen wurde nicht sauber abgeschlossen (siehe %s); es geht weiter"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="Doppelte Kontakte während der Installation vollständig zusammengeführt; kein Abgleich im Hintergrund nötig"
MSG_OK_DEDUPE_CATCHUP_LOADED="LaunchAgent für die Kontakt-Deduplizierung im Hintergrund geladen (führt Duplikate nach der Installation fertig zusammen und hört dann auf)"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="Der LaunchAgent für die Kontakt-Deduplizierung im Hintergrund konnte nicht geladen werden. Duplikate werden trotzdem im täglichen Wartungslauf zusammengeführt; es dauert nur länger, bis alles bereinigt ist."
MSG_OK_ENRICH_AGENT_LOADED="LaunchAgent für die Anreicherung im Hintergrund geladen (ergänzt Details zu deinen Filmen, Orten, Büchern und Links; läuft im Verlauf des nächsten Tages in Etappen)"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="Der LaunchAgent für die Anreicherung im Hintergrund konnte nicht geladen werden. Deine Präferenzen sind gespeichert und durchsuchbar; es fehlen vorerst nur die zusätzlichen Referenzdetails (Regie, Besetzung, Drehorte), bis er läuft."
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent für die Wiki-Neukompilierung geladen (Label com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Skripte zur Wiki-Neukompilierung im Installer enthalten"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Skripte zur Wiki-Neukompilierung von %s geklont"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="Deine Titelseite wird eingerichtet (stündliche Aktualisierung)"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="Titelseiten-Generator im Installer enthalten"
MSG_OK_EDITOR_FRONTPAGE_LOADED="LaunchAgent für die Titelseite geladen (Label com.creativemachines.ostler.editor-frontpage)"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  Die erste Aktualisierung läuft jetzt; die Titelseite in deinem Dashboard füllt sich nach und nach, während Ostler deine Präferenzen einliest."
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  Protokolle: %s/editor-frontpage.log und editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="Titelseiten-Generator wurde in diesem Installer nicht gefunden; die Titelseite im Dashboard wird nicht aktualisiert."
MSG_WARN_EDITOR_FRONTPAGE_FAILED="Installation des LaunchAgents für die Titelseite fehlgeschlagen. Siehe die Ausgabe oben; der Rest der Installation ist nicht betroffen."
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="Der Titelseiten-Abgleich wird eingerichtet"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="LaunchAgent für den Titelseiten-Abgleich geladen (prüft alle 5 Minuten, bis deine Interessen eingelesen wurden, und hört dann auf)"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="Der LaunchAgent für den Titelseiten-Abgleich konnte nicht geladen werden. Deine Titelseite und das, was Ostler über deine Interessen weiß, füllen sich stattdessen bei der nächsten stündlichen Aktualisierung."
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="Der Titelseiten-Abgleich wird übersprungen: Die Aktualisierung der Titelseite ist nicht installiert, es gibt also nichts, was erneut ausgeführt werden könnte."
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki läuft unter http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="Dein Wiki kann jetzt durchstöbert werden. Ostler schreibt die Seitenzusammenfassungen im Hintergrund und füllt sie in der nächsten Zeit nach. Du kannst dein Wiki sofort nutzen."
MSG_OK_YOUR_ASSISTANT_CALLED="Dein Assistent heißt %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="Skripte für die persönliche Kontext-Zusammenfassung sind im Installer enthalten"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="LaunchAgent für die persönliche Kontext-Zusammenfassung geladen (Label com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  Protokolle: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="Vorhandene context-refresh-Installation unter %s wird weiterverwendet"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="Skripte für die persönliche Kontext-Zusammenfassung sind nicht enthalten; der Assistent verlässt sich nur auf Live-Abfragen (keine ständig aktuelle Kontext-Zusammenfassung)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="LaunchAgent für die persönliche Kontext-Zusammenfassung wurde nicht geladen; siehe context-refresh.err. Der Assistent antwortet weiterhin über Live-Abfragen"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="Im geklonten Quellcode des Knowledge-Dienstes fehlt die Paketkonfiguration, daher wurde seine Umgebung nicht eingerichtet."
MSG_WARN_BUNDLE="  Bundle: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s läuft nur auf Apple Silicon (erkannt: %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="Ostler RemoteCapture v%s konnte nicht von %s geladen werden"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="Häufige Ursachen: Release-Tag noch nicht veröffentlicht, Netzwerk offline oder Notarisierung noch nicht abgeschlossen. Führe den Installer erneut aus, sobald das Release verfügbar ist."
MSG_WARN_CM042_EXTRACT_FAILED="Das Ostler-RemoteCapture-Tarball konnte nicht entpackt werden; LaunchAgent wird übersprungen."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Der Ostler-RemoteCapture-LaunchAgent konnte nicht geladen werden. Siehe die Ausgabe oben und ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  Die Anreicherung von Gesprächen ist nicht verfügbar. Der Rest von Ostler wird normal installiert; führe die Installation ohne --allow-plaintext erneut aus, um die Gesprächsgedächtnis-Engine einzubinden."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="Installation der Gesprächsgedächtnis-Engine fehlgeschlagen (Klonen)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  Gesucht wurde: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  Das bedeutet meist, dass die Installer-.app ohne"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  das mitgelieferte cm048_pipeline-Paket erstellt wurde, das in"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/ enthalten sein sollte. Lade den Installer erneut herunter oder"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  führe ihn für eine Dev/CI-Installation mit --allow-plaintext erneut aus."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="Gesprächsgedächtnis-Engine nicht gefunden. Ohne sie kann die Anreicherung von Gesprächen nicht laufen."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="Einrichtung der Gesprächsgedächtnis-Engine übersprungen (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="Quelle der Gesprächsgedächtnis-Engine gefunden, aber pyproject.toml fehlt; Einrichtung der venv übersprungen."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Colima konnte nicht gestartet werden. Docker Desktop wird als Ersatz versucht ..."
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="GNU coreutils konnten nicht installiert werden; lange Schritte laufen ohne Zeitlimit (eine Fortschrittszeile zeigt weiterhin, dass sie arbeiten)."
MSG_WARN_COLIMA_START_RETRY="Colima ist nicht sauber gestartet (der Docker-Socket war nicht bereit). Neuer Versuch in %ss ..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="Häufige Ursachen: Tag v%s noch nicht veröffentlicht, Netzwerk offline,"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  consent_cli-stderr (erste 400 Zeichen):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  Konsolenskript nicht erstellt unter %s; in pyproject.toml fehlt möglicherweise der Eintrag [project.scripts]."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="Es geht weiter, weil --allow-plaintext angegeben wurde."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="Die Installation wird fortgesetzt. Führe \`ostler-fda\` erneut aus, nachdem du den obigen Fehler untersucht hast."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="Es geht ohne automatisches Ausfüllen der Kontaktkarte weiter – Ostler fragt dich stattdessen."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  Gespräche, die an iMessage gesendet werden, schlagen stillschweigend fehl, bis"
# NEEDS REVIEW: Removed added 'Batterie bzw.' (not in source); exact German macOS label of the sleep option varies by version/model and needs verification.
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="Die Ruhezustand-Einstellungen konnten nicht geändert werden. Aktiviere in Systemeinstellungen > Energie die Option „Automatischen Ruhezustand bei Netzbetrieb verhindern“."
# NEEDS REVIEW: The source names only 'Energy'; 'Batterie bzw.' was added. 'Energiespar-Einstellungen' misread 'sleep settings'. Verify the exact German macOS label for the opt
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="Die Einstellungen für den Ruhezustand konnten nicht geändert werden. Aktiviere unter Systemeinstellungen > Energie die Option „Automatischen Ruhezustand verhindern“."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="ostler-assistant v%s konnte nicht von %s heruntergeladen werden"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="Die Gmail-mbox konnte nicht aus dem Takeout-ZIP extrahiert werden – wird übersprungen."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="Der ostler-assistant-Tarball konnte nicht extrahiert werden; LaunchAgent wird übersprungen."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="Die Tailscale-CLI wurde nicht gefunden. Du kannst sie später manuell konfigurieren."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Das Paket legal/ mit den Einwilligungstexten konnte nicht installiert werden; wird fortgesetzt"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="Das Verzeichnis LICENSES/ konnte nicht installiert werden (nicht kritisch)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="ostler_security konnte nicht in die Hub-venv installiert werden."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="THIRD_PARTY_NOTICES.md konnte nicht installiert werden (nicht kritisch)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="Der Doctor-Agent konnte nicht bereitgestellt werden (gebündelt und geklont fehlgeschlagen)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="Ostler-Doctor-Dateien nicht gefunden. Sie werden für das iOS-Pairing benötigt (Ostler.app bettet :8089/pair-ios per iframe ein)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  Gesucht in: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  Das bedeutet meist, dass die Installer-.app ohne"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  den mitgelieferten Quellcode doctor/agent/ in"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/ erstellt wurde. Lade den Installer erneut herunter oder"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  führe ihn für eine Dev-/CI-Installation erneut mit --allow-plaintext aus."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Doctor-Installation abgebrochen: Doctor wird für das iOS-Pairing benötigt. Lade den Installer erneut herunter oder verwende --allow-plaintext für eine Dev-/CI-Installation."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="Die E-Mail-Import-Skripte konnten nicht bereitgestellt werden (gebündelt und geklont fehlgeschlagen)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="Die hub-power-Skripte konnten nicht bereitgestellt werden (gebündelt und geklont fehlgeschlagen)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="Die wiki-recompile-Skripte konnten nicht bereitgestellt werden (gebündelt und geklont fehlgeschlagen)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="Die URL des Chrome Web Store konnte nicht automatisch geöffnet werden: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="region.json konnte nicht gespeichert werden (wird fortgesetzt, Doctor weist darauf hin)"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="Es konnte nicht vermerkt werden, dass der Wiederherstellungsschlüssel übergeben wurde. Die Zusammenfassung dieses Durchlaufs ist weiterhin korrekt, aber ein späterer Durchlauf kann das eventuell nicht erkennen und erneut warnen – in diesem Fehlerfall ist das die sichere Variante."
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="Im Schlüsselbund konnte nicht gespeichert werden. Bitte schreibe ihn auf."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="Ollama konnte nicht automatisch gestartet werden."
MSG_FAIL_OLLAMA_PORT_IN_USE="Ein anderes Programm verwendet bereits Port 11434, den Ostler für seine lokale KI braucht. Ostler konnte seine eigene Kopie nicht starten, daher wurde die Installation hier angehalten, statt nur halb abgeschlossen zu werden.

  Was den Port belegt: %s
  Der genaue Fehler steht in: %s

Meist ist das eine bereits vorhandene Kopie von Ollama oder eine, die von einer früheren Ostler-Installation weiterläuft. Beende sie (oder starte diesen Mac neu) und führe den Installer erneut aus."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="Die Pipeline konnte nicht aktualisiert werden (offline?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="pipeline_signals.json konnte nicht geschrieben werden. Die Doctor-Diagnose für leere Mail-Postfächer verwendet sichere Standardwerte bis zur nächsten Installation oder zum nächsten Durchlauf."
MSG_WARN_CURL_SAID="Curl meldete:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="Verzeichnis nicht gefunden: %s – Import wird übersprungen."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker wurde nicht innerhalb von %s Sekunden gestartet."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker ist installiert, läuft aber nicht. Es muss gestartet werden."
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="Der Docker-Befehl ist auf diesem Mac vorhanden, aber dahinter läuft nichts. Unter macOS ist der Docker-Befehl nur ein Client – zum tatsächlichen Ausführen braucht er eine Engine wie Colima oder Docker Desktop. Der Installer richtet eine ein."
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="Diagnose der Container-Laufzeit – Docker-Client: %s | colima: %s | Docker Desktop: %s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="Der Wiki-Container wurde gestartet, aber innerhalb von 60 Sekunden antwortete nichts unter http://localhost:8044. Gehe davon aus, dass das Wiki NICHT läuft – der Exit-Code des Startbefehls beweist nicht, dass die Seite lädt."
MSG_WARN_WIKI_NOT_RESPONDING="Dein Wiki antwortet nicht (127.0.0.1:8044). Es läuft in einem Container, daher bedeutet das meist, dass die Container-Laufzeit gestoppt wurde. Öffne Ostler Doctor unter http://localhost:8089/doctor, um den Grund zu sehen."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama mitten in der Installation und lassen die Bereitschaftsprüfungen hängen."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  frühe Marker (Kanäle verbinden sich noch + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="Die Installation des LaunchAgents für den E-Mail-Import ist fehlgeschlagen. Siehe Ausgabe oben."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="Die Installation des iMessage-Bridge-LaunchAgents ist fehlgeschlagen. iMessage-Antworten des Assistenten funktionieren erst, wenn du den Installer erneut ausführst oder INSTALL_SNIPPET.sh manuell startest."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Die iMessage-Bridge-Skripte sind nicht enthalten und --allow-plaintext wurde übergeben. Die Installation des LaunchAgents wird übersprungen. iMessage-Antworten des Assistenten funktionieren nicht."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="Die Verschlüsselung funktioniert nicht."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="Die Verschlüsselung funktioniert nicht, und"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="Stelle sicher, dass das festgelegte Tag von PWG_KNOWLEDGE_REPO ihn enthält."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  Automation-Berechtigung für die App „Nachrichten“)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="Der FDA-Extraktor wurde mit einem Wert ungleich null beendet (%s). Letzte 20 Zeilen der Ausgabe:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="Das FDA-Extraktionsmodul ist nicht in diesem Installer enthalten."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="Erwartet unter: Contents/Resources/ostler_fda/ (innerhalb der .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="Wahrscheinlichste Ursache: Ein Build-Fehler hat die mitgelieferte Kopie ausgelassen. Lade die .app erneut von ostler.ai/install herunter."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="Das FDA-Extraktionsmodul ist nicht enthalten. Es geht weiter, weil --allow-plaintext übergeben wurde – die sofortige Datenextraktion wird übersprungen."
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="Das Datenextraktionsmodul liegt auf dem Datenträger, aber seine Abhängigkeiten wurden nicht installiert, daher kann es nicht geladen werden:"
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="Es geht weiter, weil --allow-plaintext übergeben wurde – die geplante Datenaktualisierung schlägt bei jedem Durchlauf fehl."
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault ist NICHT aktiviert."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="Der erste kostenlose Monat konnte gerade nicht aktiviert werden. Die Installation wird fortgesetzt. Öffne nach dem Koppeln die Ostler app auf deinem iPhone, um das zu beheben."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="Dem Terminal wurde kein Festplattenvollzugriff gewährt."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="%s GB RAM erkannt. Du erhältst den kompakten Assistenten (gemma4:e2b) – zuverlässig, genau, bei kurzen Fragen in unter einer Sekunde, mit Tool-Aufrufen und einem ehrlichen „Ich weiß es nicht“, wenn er etwas nicht weiß. Für ausführlichere Antworten auf längere Fragen schaltet ein Mac mit 24 GB oder mehr den Standard-Assistenten (qwen3.5:9b) frei. Du kannst später den Mac wechseln, indem du neu installierst."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="Beim DSGVO-Import sind Fehler aufgetreten. Du kannst ihn erneut ausführen mit:"
MSG_WARN_GRAPH_DB_PULL_RETRY="Der Download der Datenbank wurde nicht abgeschlossen (Versuch %s von %s). Neuer Versuch in %ss..."
MSG_WARN_GRAPH_DB_UP_RETRY="Die Wissensgraph-Datenbanken sind nicht gestartet (Versuch %s von %s). Neuer Versuch..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="Der DSGVO-Import ist Teil der Standardinstallation. Ohne ihn kann dein soziales Netzwerk (LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google Calendar) nicht importiert werden."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="Der DSGVO-Import ist auf dieser Instanz nicht verfügbar, bis die Import-Pipeline neu installiert wird."
MSG_WARN_GIT_SAID="Git meldete:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  Integritätsprüfung fehlgeschlagen: ostler-knowledge --version hat keine Ausgabe erzeugt."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  Integritätsprüfung fehlgeschlagen: Die Gesprächsgedächtnis-Engine konnte nicht geladen werden (pwg-convo oder sein Pipeline-Import wurde nicht sauber beendet)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="Der Homebrew-Installer wurde mit %s beendet. Die letzten 30 Zeilen von %s folgen:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Homebrew-Installationsprotokoll (Ende) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="Die pip-Installation von Doctor wurde mit %s beendet. Die letzten 30 Zeilen von %s folgen:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Doctor-pip-Installationsprotokoll (Ende) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="Die pip-Installation der Pipeline wurde mit %s beendet. Die letzten 30 Zeilen von %s folgen:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- Pipeline-pip-Installationsprotokoll (Ende) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Die Installation des Hub-Power-LaunchAgents ist fehlgeschlagen. Siehe Ausgabe oben."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="Die Hub-Power-Skripte wurden unter dem erwarteten Bundle-Pfad nicht gefunden."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  In der Installer-.app fehlt anscheinend vendor/hub_power/"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  in Contents/Resources/hub-power/. Die akkuabhängige Drosselung wird nicht installiert; der Rest der Installation wird fortgesetzt."
MSG_WARN_ICAL_SERVER_FAILED="Die Assistant API konnte nicht gestartet werden. Die Ostler app auf deinem iPhone hat bis zum nächsten Installationslauf eingeschränkten Zugriff."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - Abrufen des Images fehlgeschlagen (Netzwerk, Speicherplatz oder Registry-Zeitüberschreitung)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="Das iMessage-FDA-Signal konnte nicht in pipeline_signals.json geschrieben werden. Möglicherweise zeigt das Doctor-Dashboard die Karte für den Festplattenvollzugriff nicht automatisch an."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="Der IMAP-Host ist leer – versuche es erneut."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="iMessage-Automationsberechtigung: nicht erteilt (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="iMessage-Automationsberechtigung: Prüfung ohne eindeutiges Ergebnis."
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="Der iMessage-Verlauf (chat.db) ist nicht lesbar: Dem Ostler-Daemon wurde noch kein Festplattenvollzugriff erteilt. Das Lesen des iMessage-Verlaufs bleibt deaktiviert, bis du ihn in Systemeinstellungen > Datenschutz & Sicherheit > Festplattenvollzugriff erteilst."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="Systemeinstellungen > Datenschutz & Sicherheit > Automation wird geöffnet. Aktiviere die Zeile „Nachrichten“ für OstlerInstaller (oder Terminal), um die iMessage-Zustellung einzurichten."
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="Keine vollständige E-Mail-Adresse, daher ignoriert: %s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="Bitte gib mindestens eine vollständige E-Mail-Adresse ein (zum Beispiel you@example.com)."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage benötigt mindestens einen erlaubten Kontakt. Versuche es erneut oder"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="Import-Pipeline nicht verfügbar (privates Repository – nur für Betatester)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="Import-Pipeline ist nicht im Installer enthalten. Harter Abbruch umgangen."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Import-Pipeline ist nicht im Installer enthalten. Dies ist der produktive Installationspfad; das Python-Paket contact_syncer sollte im .app-Bundle enthalten sein."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX bedeutet, dass der Assistent jede E-Mail liest, die du erhältst."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Nicht genug Speicherplatz für das Wiki-Ausgabevolume"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Intel-Mac erkannt – die Leistung ist eingeschränkt. Apple Silicon wird empfohlen."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s ist ein Host eines Cloud-Anbieters."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="JWT_SECRET in %s steht auf der Sperrliste; wird neu erzeugt, damit die Wissensgraph-Dienste importierbar bleiben"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="JWT_SECRET in %s ist zu kurz (%s < %s Zeichen); wird neu erzeugt"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="Wissens-Repository geklont, aber pyproject.toml fehlt; venv-Einrichtung übersprungen."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="Installation des Wissensdienstes fehlgeschlagen (Klonen)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="Lizenz: %s wird unter den Gemma-Nutzungsbedingungen von Google ausgeliefert, nicht unter Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="MacBook-Installationen benötigen dies für die Akku- und Ruhezustandsverwaltung."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="Der Zugriff auf Kontakte unter macOS wurde abgelehnt oder noch nicht erteilt."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS fragt per Skript NICHT danach – du musst die Berechtigung manuell erteilen."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Mac-mini-Installationen sind nicht betroffen; MacBook-Nutzer sollten es erneut versuchen."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="Mail-Daten können weiterhin manuell eingelesen werden:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  Manuell erneut versuchen: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  Manuell erneut versuchen, sobald die Ursache behoben ist:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Weder Apple Mail noch benutzerdefiniertes IMAP ausgewählt – Apple Mail wird als Standard verwendet."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="Kein Passkey festgelegt; Datenbanken werden nicht verschlüsselt."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="Eine frühere Installation hat deinen Wiederherstellungsschlüssel erzeugt, wurde aber nicht abgeschlossen, daher wurde er dir nie angezeigt. Er kann nicht abgerufen werden – er wird nirgendwo gespeichert, auch nicht hier."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="Deine Passphrase funktioniert weiterhin und aktuell ist nichts gesperrt. Aber falls du sie jemals vergisst, gibt es derzeit keinen Weg zurück."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="Wende dich an den Support, um die Sicherheit neu einrichten zu lassen. Dabei wird dir ein neuer Wiederherstellungsschlüssel zum Aufbewahren angezeigt."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="Die Passphrasen stimmen nicht überein. Versuche es erneut."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="Einrichtung der Passphrase fehlgeschlagen. Ausgabe:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="Leere Eingabe. Passphrase übersprungen."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="Die Passphrase muss mindestens 12 Zeichen lang sein. Versuche es erneut."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="Zum Verschlüsseln deiner Daten ist eine Passphrase erforderlich."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="Das ist keine internationale Nummer. Beginne mit einem +, gefolgt von der Landesvorwahl und der restlichen Nummer, z. B. +447700900123. Versuche es erneut."
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama antwortet nicht"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s fehlgeschlagen (Versuch %s/3). Neuer Versuch in %s s …"
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="Nur %s GB frei. Wir empfehlen mindestens 35 GB (Docker-Images + KI-Modell + Daten)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="Im Batteriebetrieb wird der LaunchAgent für die Hub-Energieverwaltung (Schritt 3.14) möglicherweise pausiert"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="oder führe das Installationsprogramm erneut aus und wähle einen anderen Kanal."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="oder läuft der Release-Pipeline von Phase B voraus. Führe das Installationsprogramm erneut aus, sobald die"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor hat %s Fehler gemeldet."

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="Ostler ist fertig, aber während der Installation sind %s Fehler aufgetreten."
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  Alle Details stehen in ~/.ostler/logs/install.log. Ostler startet trotzdem; öffne den Doctor, um zu sehen, was Aufmerksamkeit braucht."
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="Ostler ist fertig, aber %s Installationsschritt(e) wurden nicht sauber abgeschlossen: %s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="Ostler ist fertig, ohne dass bei der Installation Fehler aufgetreten sind."

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant wurde entpackt, aber die Prüfung mit --version ist fehlgeschlagen."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Die Installation des Ostler-Assistenten-LaunchAgents ist nach 3 Versuchen fehlgeschlagen. Diagnoseausgabe oben und unten."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Installationsversuch %s des Ostler-Assistenten-LaunchAgents ist fehlgeschlagen; neuer Versuch."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="Vollständige Daemon-Fehlerausgabe (stderr) unter: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="Letzter Auszug der Fehlerausgabe (stderr):"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s läuft nur auf Apple Silicon (erkannt: %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  Die Abhängigkeit für verschlüsselten Speicher konnte nicht in die venv des Gesprächsspeichers installiert werden; die Anreicherung von Gesprächen wird nicht ausgeführt."
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  Quelle der Abhängigkeit für verschlüsselten Speicher wurde unter SCRIPT_DIR nicht gefunden; die Engine für den Gesprächsspeicher kann nicht geladen werden und die Anreicherung von Gesprächen wird nicht ausgeführt."
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - Das Image ostler-wiki-compiler kann noch nicht geladen werden (Registry nicht angebunden)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph antwortet nicht"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph ist in dieser Phase noch nicht funktionsfähig (siehe Protokoll oben)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="Die Passwörter stimmen nicht überein (oder waren leer). Versuche es noch einmal."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="Die Hauptinstallation dauert normalerweise 45 Minuten bis einige Stunden (Docker- und Ollama-Downloads + Ersteinrichtung), bei langsamerer Verbindung oder einem Mac mit jahrelangem Verlauf auch länger. Lange ruhige Phasen sind normal – im Hintergrund wird heruntergeladen und eingerichtet, nichts hängt fest."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  pip-Installation fehlgeschlagen; die Engine für den Gesprächsspeicher ist nicht verfügbar."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  pip-Installation fehlgeschlagen; email-ingest greift auf das System-Python zurück (kann zur Laufzeit ebenfalls fehlschlagen)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  pip-Installation fehlgeschlagen; ostler-knowledge ist nicht verfügbar."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  pip-Installation fehlgeschlagen; die Engine für den E-Mail-Import ist nicht verfügbar. Der stündliche LaunchAgent erzeugt weiterhin mbox-Dateien, kann sie aber erst nach einer Reparatur in den Graphen importieren."
MSG_WARN_CM021_SOURCE_NOT_FOUND="Die Quelle der Engine für den E-Mail-Import wurde im App-Bundle nicht gefunden; der stündliche Hintergrundjob speichert E-Mail-Dateien, ohne sie zu importieren."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="Die Quelle ostler_fda wurde im App-Bundle nicht gefunden; der email-ingest-LaunchAgent greift zur Laufzeit auf das System-Python zurück."
MSG_WARN_PIP_SAID="pip meldete:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="Schließe den Mac für die vollständige Installation ans Stromnetz an."
MSG_WARN_PORT_1_ALREADY_USE_PID="Port %s wird bereits von %s verwendet (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - Port 3000 wird bereits von einem anderen Dienst verwendet"
MSG_WARN_POWER_SOURCE="Stromquelle: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="Installation von sqlcipher3 fehlgeschlagen."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="Installation von sqlcipher3 fehlgeschlagen. Datenbanken werden nicht verschlüsselt."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="Python 3 nicht gefunden. Python 3.12 wird installiert …"
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s ist zu alt (benötigt wird 3.10+). Python 3.12 wird installiert..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant antwortet nicht"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         Lies https://ai.google.dev/gemma/terms, bevor du es kommerziell nutzt."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="Die öffentliche Version findest du unter https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis antwortet nicht"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="Release erscheint, oder lege die Binärdatei manuell bereit:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="Erneuter Versuch – gib einen selbst gehosteten Host ein oder drücke Ctrl-C, starte neu und wähle Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="Führe das Installationsprogramm erneut aus und deaktiviere iMessage, um es zu überspringen."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="AUSFÜHRUNG MIT --allow-plaintext: Verschlüsselung deaktiviert. NICHT FÜR DEN PRODUKTIVEINSATZ."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  Führe nach dem ersten Start \`%s doctor\` aus"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="Führe 'tailscale ip --4' aus, sobald du angemeldet bist, und füge die Adresse dann in der iOS-App hinzu."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Safari-Erweiterung konnte nicht kopiert werden; du kannst sie später manuell installieren"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="Safari-Erweiterung installiert, aber es war kein Erweiterungs-Token zum Koppeln verfügbar; die Erfassung des Surfverlaufs bleibt aus, bis du das Installationsprogramm erneut ausführst"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="Die Safari-Erweiterung konnte nicht mit diesem Hub gekoppelt werden; die Erfassung des Surfverlaufs bleibt aus, bis du das Installationsprogramm erneut ausführst"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="Sicherheitsmodul nicht gefunden. Die Passkey-Einrichtung wird übersprungen."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  Gesucht wurde: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  Das bedeutet meist, dass die Installer-.app ohne das"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  mitgelieferte Paket ostler_security erstellt wurde, das in"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/ enthalten sein sollte. Lade das Installationsprogramm erneut herunter oder"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  führe es für eine Dev/CI-Installation mit --allow-plaintext erneut aus."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="Sicherheitseinrichtung fehlgeschlagen. Es geht ohne Datenbankverschlüsselung weiter."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="Sicherheitseinrichtung fehlgeschlagen. Ausgabe:"
MSG_WARN_SEE_STDERR_FRAGMENT="  Das stderr-Fragment findest du in %s."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="Die Installation der Binärdatei wird übersprungen. Die vom Assistenten geschriebene config.toml bleibt erhalten."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Die Installation des Doctor-LaunchAgents wird übersprungen."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="Die Installation des E-Mail-Import-LaunchAgents wird übersprungen."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="Die Installation des LaunchAgents wird übersprungen. Mac-mini-Installationen sind nicht betroffen."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="Die Installation des LaunchAgents wird übersprungen. Versuche: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="Die Installation des Wiki-Neukompilierungs-LaunchAgents wird übersprungen."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="Einige Ports sind belegt. Docker-Container starten möglicherweise nicht."
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="Port %s wird bereits von %s (PID %s) verwendet, einem Programm dieses Accounts. Beende es und führe das Installationsprogramm erneut aus."
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="Port %s wird bereits von einem Programm eines ANDEREN Benutzer-Accounts auf diesem Mac verwendet. Ostler kann ihn nicht mitnutzen, und ein Start trotz des Konflikts könnte die Daten der beiden Accounts vermischen. Melde den anderen Account ab oder installiere Ostler auf einem Mac, auf dem nur ein Account diesen Port verwendet."
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="Ostler kann seine Datenbanken nicht starten, weil benötigte Ports bereits belegt sind."
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="Beende, was die oben aufgeführten Ports verwendet, und führe das Installationsprogramm dann erneut aus."
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="Es konnte nicht geprüft werden, ob Port %s frei ist. Das heißt nicht, dass der Port frei ist."
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="Eine oder mehrere Port-Prüfungen konnten nicht ausgeführt werden, daher lässt sich ein Konflikt mit einem anderen Programm nicht ausschließen."
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="Die zuverlässigste Port-Prüfung konnte auf diesem Mac nicht ausgeführt werden, daher sind die folgenden Prüfungen weniger gründlich als sonst."
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="Ostler konnte nicht bestätigen, dass diese Ports frei sind, und startet seine Datenbanken nicht auf einem ungeprüften Port. Bitte wende dich mit deinem Installationsprotokoll an den Support."
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="Ein veraltetes Colima-Startobjekt konnte nicht entfernt werden. Dein Wiki lädt nach einem Neustart eventuell nicht; wende dich an den Support."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="Beende die in Konflikt stehenden Dienste oder ändere die Ports in docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Die Anmeldung bei Tailscale wurde nicht innerhalb von 3 Minuten abgeschlossen. Du kannst das später in den Einstellungen nachholen."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="Die Tailscale-IP wurde in .env geschrieben, konnte aber beim anschließenden Lesen nicht gefunden werden. Die Ostler app auf deinem iPhone übernimmt sie möglicherweise nicht – führe in diesem Fall install.sh --repair erneut aus."
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="Deine Antwort zum Fernzugriff konnte nicht gespeichert werden, deshalb wirst du bei der nächsten Neuinstallation erneut gefragt. Alles andere bleibt unberührt."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="Die Installation von Tailscale ist fehlgeschlagen – du kannst sie später über tailscale.com nachholen"
MSG_WARN_TAILSCALE_STATE_UNREADABLE="Auf diesem Mac gibt es bestehende Tailscale-Einstellungen, die nicht gelesen werden konnten. Deshalb lässt sich nicht feststellen, ob er noch mit deinem Netzwerk verbunden ist. Bitte wähle unten aus – wenn er bereits verbunden ist, schadet eine erneute Einrichtung nicht."
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="die installierten Dienste starten ohne sie nicht."
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  dies behoben ist. Hinweise zur Behebung findest du im Banner mit den nächsten Schritten."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  zur Prüfung. cron-delivery / imessage-tcc sind häufige"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  Versuche: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  Versuche: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="Unbekannte Auswahl '%s'; es wird iMessage + E-Mail verwendet."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="Unbekannte Auswahl. Es wird „Empfohlen“ verwendet."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  Aktualisierung fehlgeschlagen; es wird mit dem vorhandenen Checkout fortgefahren."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="Verwende dafür Apple Mail (oben empfohlen) – Ostler speichert niemals Cloud-Passwörter."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="INBOX wird verwendet. Der Assistent liest jede eingehende E-Mail."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="Der Vane-Container wurde gestartet, aber http://localhost:3000 hat nicht innerhalb von 60 s geantwortet."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane (lokale Websuche) konnte nicht gestartet werden. Häufige Ursachen:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  Die Websuche ist optional; der Rest von Ostler funktioniert auch ohne sie."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="Wir empfehlen dringend, stattdessen ein eigenes Label bzw. einen eigenen Ordner zu verwenden."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp benötigt eine Telefonnummer für die Zustellung der Zusammenfassung. Versuche es noch einmal,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="Das Wiki wurde kompiliert, aber der wiki-site-Container konnte nicht gestartet werden."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="Die erste Kompilierung des Wikis ist fehlgeschlagen. Häufige Ursachen:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="Der LaunchAgent für den Wiki-Abgleich am ersten Tag konnte nicht geladen werden. Der tägliche Wiki-Neuaufbau läuft weiterhin; dein Wiki wird einfach am nächsten Tag statt innerhalb einer Stunde aktualisiert."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Die Installation des LaunchAgents für die Wiki-Neukompilierung ist fehlgeschlagen. Siehe Ausgabe oben."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="Das Wiki wird nicht automatisch aktualisiert; ein manueller Neuaufbau bleibt möglich:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="Die Wizard-Konfiguration bleibt erhalten; die Binärdatei bleibt bereitgestellt. Manuell erneut versuchen:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="Dein Assistent braucht einen Namen. Wähle einen der Vorschläge oben oder gib einen eigenen ein."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="Du kannst den Zugriff in den Systemeinstellungen > Datenschutz & Sicherheit > Kontakte erneut erlauben."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="Du kannst die Sicherheitseinrichtung später ausführen: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="Möglicherweise musst du manuell installieren: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  tatsächlich: %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="Das Ostler-RemoteCapture-Bundle war nach dem Entpacken nicht unter %s vorhanden. Der Release-Tarball ist möglicherweise fehlerhaft."
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="%s konnte nicht erstellt oder erreicht werden, daher gibt es keinen Ort, an dem Ostler RemoteCapture installiert werden kann. Das ist ein Problem mit Ordnerberechtigungen, nicht mit dem Download."
MSG_ERR_CM042_RENAME_FAILED="Ostler RemoteCapture wurde korrekt heruntergeladen und entpackt, konnte aber nicht nach %s verschoben werden. Die entpackte App wurde in /Applications belassen. Das ist kein Signierungsproblem."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify meldete:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  Ein Bundle, das nicht zur veröffentlichten Prüfsumme passt, wird nicht bereitgestellt."
MSG_ERR_CM042_SHA_256_MISMATCH="SHA-256-Abweichung beim Ostler-RemoteCapture-Tarball."
MSG_ERR_CM042_PIN_FAILED="Ostler konnte nicht bestätigen, dass dieser Download von RemoteCapture echt ist, und hat ihn deshalb nicht installiert."
MSG_ERR_CM042_VERSION_UNKNOWN="Diese RemoteCapture-Version ist Ostler nicht bekannt und wurde deshalb nicht installiert."
MSG_ERR_CM042_SIDECAR_DISAGREES="Die mit diesem RemoteCapture-Download veröffentlichte Prüfsumme passt nicht zur Datei, daher wurde er nicht installiert."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess meldete:"
MSG_ERR_CM042_VERIFY_FAILED="Die Prüfung der Signatur bzw. Notarisierung von Ostler RemoteCapture ist fehlgeschlagen."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv meldete:"
MSG_ERR_EXPECTED="  erwartet: %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief meldete: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="Die ostler-assistant-Binärdatei unter %s ist keine ausführbare Mach-O-Datei."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="Die SHA-256-Prüfsumme des ostler-assistant-Tarballs stimmt nicht überein."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  Eine Binärdatei, die nicht zur veröffentlichten Prüfsumme passt, wird nicht bereitgestellt."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="Die Quarantäne wird nicht entfernt und der LaunchAgent nicht geladen."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="Führe das Installationsprogramm erneut aus, sobald der Upstream-Tarball korrigiert ist."
MSG_ERR_URL="  URL:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Intel-Macs werden nicht unterstützt. Ostler benötigt Apple Silicon (M1, M2, M3 oder M4)."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="Mindestens 16 GB RAM erforderlich. Dein Mac hat %s GB. Empfohlen sind 24 GB."
MSG_FAIL_CM042_SIGNATURE_FAILED="Die Installation von Ostler RemoteCapture wurde abgebrochen: Die Prüfung der Signatur oder Notarisierung ist fehlgeschlagen. Das Bundle wurde für den Support in /Applications belassen. Schreib an support@ostler.ai und führe das Installationsprogramm erneut aus."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="%s konnte nach 3 Versuchen nicht geladen werden. Prüfe dein Netzwerk und führe das Installationsprogramm erneut aus."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="nomic-embed-text konnte nach 3 Versuchen nicht geladen werden. Prüfe dein Netzwerk und führe das Installationsprogramm erneut aus."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker ist nicht verfügbar. Führe das Installationsprogramm erneut aus, um Colima zu installieren."
MSG_FAIL_CONTAINER_CLIENT_MISSING="Der Befehl docker ist auf diesem Mac nicht vorhanden, daher kann Ostler die benötigten Dienste nicht starten. Führe das Installationsprogramm erneut aus. Wenn es wieder fehlschlägt, schick uns das Protokoll unter %s."
MSG_FAIL_CONTAINER_ENGINE_ABSENT="Ostler benötigt eine Container-Laufzeitumgebung, und auf diesem Mac antwortet keine. Dein Wiki, dein Wissensgraph und dein Suchindex laufen alle in Containern. Deshalb wurde die Installation hier angehalten, statt sie abzuschließen und diese Teile fehlen zu lassen. So behebst du das: Öffne das Terminal und führe 'colima start' aus, dann starte dieses Installationsprogramm erneut. Wenn du stattdessen Docker Desktop verwendest, öffne es, warte, bis das Wal-Symbol ruhig steht, und führe das Installationsprogramm dann erneut aus. Das vollständige Protokoll liegt unter %s."
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="Docker war nicht rechtzeitig bereit, um die Wissensgraph-Datenbanken zu starten. Stelle sicher, dass Colima oder Docker läuft, und führe das Installationsprogramm dann erneut aus."
MSG_FAIL_GRAPH_DB_PULL_FAILED="Die Images der Wissensgraph-Datenbanken konnten auch nach mehreren Versuchen nicht heruntergeladen werden. Meist liegt das an der Netzwerkverbindung. Prüfe deine Internetverbindung und führe das Installationsprogramm erneut aus."
MSG_FAIL_GRAPH_DB_UP_FAILED="Die Wissensgraph-Datenbanken wurden heruntergeladen, konnten aber nicht gestartet werden. Führe das Installationsprogramm erneut aus. Tritt der Fehler weiterhin auf, öffne das Terminal und führe aus: cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="Ostler konnte keine authentifizierte Anfrage an die Wissensgraph-Datenbank abschließen. Es wurde zweimal im Abstand von zwei Sekunden versucht, und beide Versuche wurden abgelehnt. Den Grund kennen wir noch nicht: Möglicherweise startete die Datenbank noch, oder die Zugangsdaten, die Ostler hat, sind nicht die erwarteten. Deine Daten wurden nicht angetastet. Oft klappt es, wenn du das Installationsprogramm erneut ausführst. Selbst dann würden wir gern davon erfahren – schick uns das Installationsprotokoll, denn wir versuchen gerade aktiv, diesen Fehler zu reproduzieren."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="Das FDA-Extraktionsmodul fehlt im Bundle des Installationsprogramms. Lade die .app erneut von ostler.ai/install herunter oder führe das Installationsprogramm für Entwicklung/CI mit --allow-plaintext erneut aus."
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="Das Datenextraktionsmodul wurde installiert, kann aber nicht geladen werden, sodass die Aktualisierung im Hintergrund jedes Mal fehlschlagen würde. Die vollständige Ausgabe wurde unter %s gespeichert – führe das Installationsprogramm erneut aus und hänge diese Datei an, wenn du den Support kontaktierst (Referenz: ERR-10-FDA-DEPS-IMPORT)."
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="Interner Fehler: Das Datenextraktionsmodul wurde innerhalb des Anwendungs-Bundles bereitgestellt, was dessen Signatur ungültig machen würde. Das ist ein Build-Fehler und kein Problem deines Macs. Lade die .app erneut von ostler.ai/install herunter (Referenz: ERR-10-FDA-DEPS-UNSAFE-PATH)."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Die Installation der Doctor-Abhängigkeiten ist fehlgeschlagen. Die vollständige Ausgabe wurde unter %s gespeichert – hänge sie an, wenn du an support@ostler.ai schreibst (Referenz: ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="Die Installation der Abhängigkeiten der Import-Pipeline ist fehlgeschlagen. Die vollständige Ausgabe wurde unter %s gespeichert – hänge sie an, wenn du an support@ostler.ai schreibst (Referenz: ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Die Installation von Homebrew ist fehlgeschlagen. Die vollständige Ausgabe wurde unter %s gespeichert – hänge sie an, wenn du an support@ostler.ai schreibst."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="Die Installation der Import-Pipeline ist fehlgeschlagen. Das contact_syncer-Bundle ist für die Produktinstallation erforderlich. Führe das Installationsprogramm für Entwicklung/CI mit --allow-plaintext erneut aus oder lade es erneut herunter und versuche es noch einmal."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="Für das Deaktivieren des Ruhezustands und die Installation von Homebrew ist sudo-Zugriff nötig. Führe das Installationsprogramm erneut aus, wenn du bereit bist."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Weder Colima noch Docker Desktop ließ sich starten. Installiere Docker Desktop und führe das Installationsprogramm erneut aus."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="Nicht genug Speicherplatz (%s GB). Gib Speicherplatz frei und versuche es erneut."
MSG_FAIL_MACOS_BELOW_FLOOR="macOS %s ist älter, als Ostler unterstützt. Ostler benötigt macOS %s oder neuer: Die Installer-App ist dafür gebaut und lässt sich auf älteren Versionen nicht öffnen. Aktualisiere macOS und führe das Installationsprogramm dann erneut aus."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="Es ist kein Passkey festgelegt und keine Sicherheitskonfiguration vorhanden. Führe das Installationsprogramm für Entwicklung/CI mit --allow-plaintext erneut aus oder starte es neu und bestätige den Touch ID-Hinweis."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="Die Engine für das Gesprächsgedächtnis ist erforderlich. Führe das Installationsprogramm für Entwicklung/CI mit --allow-plaintext erneut aus oder behebe das oben genannte fehlende Bundle und versuche es noch einmal."
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="Der mitgelieferte Ostler-Daemon (v%s unter %s) unterstützt den Befehl 'run-source' nicht, den dieses Installationsprogramm benötigt, um den Import über den Festplattenvollzugriff zu leiten. Das ist eine Versionsabweichung innerhalb des Installer-Bundles: Würde es installiert, wäre jede Importquelle unbemerkt defekt, und das Produkt würde ohne sichtbaren Fehler veralten. Lade die .app erneut von ostler.ai/install herunter und versuche es noch einmal (Referenz: ERR-11-DAEMON-RUN-SOURCE-SKEW)."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="Die Installation von ostler_security ist fehlgeschlagen. Führe das Installationsprogramm für Entwicklung/CI mit --allow-plaintext erneut aus oder behebe den oben genannten pip-Fehler und versuche es noch einmal."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="Die Passkey-Einrichtung ist fehlgeschlagen. Führe das Installationsprogramm für Entwicklung/CI mit --allow-plaintext erneut aus oder behebe den oben genannten Fehler und versuche es noch einmal."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="sqlcipher3 ist für verschlüsselte Datenbanken erforderlich. Führe das Installationsprogramm für Entwicklung/CI mit --allow-plaintext erneut aus oder behebe den oben genannten pip-Fehler und versuche es noch einmal."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Dieses Installationsprogramm ist nur für macOS."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="Die Installation der Xcode Command Line Tools wurde nicht innerhalb von 15 Minuten abgeschlossen. Öffne das Terminal und führe 'xcode-select --install' aus, klicke im macOS-Dialog auf „Installieren“ und warte, bis der Vorgang abgeschlossen ist. Starte dann dieses Installationsprogramm erneut."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="Die Installation von Homebrew wurde als erfolgreich gemeldet, aber /opt/homebrew/bin/brew fehlt. Das vollständige Protokoll findest du in %s. Behebung: Öffne das Terminal, führe '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' aus und starte dann das Installationsprogramm erneut."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew ist unter /opt/homebrew/bin/brew installiert, aber der Befehl 'brew' ist nach der shellenv-Auswertung nicht im PATH. Öffne ein neues Terminal und starte das Installationsprogramm erneut."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' wurde als erfolgreich gemeldet, aber colima ist nicht im PATH. Prüfe %s auf Homebrew-Fehler. Behebung: Öffne das Terminal, führe 'brew install colima docker docker-compose' manuell aus und starte dann das Installationsprogramm erneut."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' wurde als erfolgreich gemeldet, aber die Docker-CLI ist nicht im PATH. Prüfe %s. Behebung: Führe 'brew install docker' manuell aus und starte dann das Installationsprogramm erneut."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="Die Installation der Ollama-App wurde als erfolgreich gemeldet, aber das Programm fehlt unter /Applications/Ollama.app. Prüfe %s. Behebung: Führe 'brew install --cask ollama-app' manuell aus und starte dann das Installationsprogramm erneut."
MSG_FAIL_EMBED_HEALTHCHECK="Ollama läuft, aber das Embedding-Modell hat keinen Vektor zurückgegeben (HTTP nicht 200 oder ein leeres Ergebnis). Die Personenkarte, die Suche und das Durchsuchen wären alle leer. Prüfe %s. Behebung: Stelle sicher, dass die Ollama-App (nicht die Homebrew-Formel) installiert ist und läuft, und starte dann das Installationsprogramm erneut."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' wurde als erfolgreich gemeldet, aber sqlcipher ist nicht im PATH. Prüfe %s. Behebung: Führe 'brew install sqlcipher' manuell aus und starte dann das Installationsprogramm erneut."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' hat /Applications/Tailscale.app nicht erzeugt. Prüfe %s. Behebung: Lade Tailscale von https://tailscale.com/download/macos herunter, ziehe es in /Applications und starte dann das Installationsprogramm erneut."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' wurde als erfolgreich gemeldet, aber die Datei python3.11 fehlt unter /opt/homebrew/opt/python@3.11/bin/python3.11. Prüfe %s. Behebung: Führe 'brew reinstall python@3.11' aus und starte dann das Installationsprogramm erneut."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="Wir haben deine früheren Antworten gefunden"
MSG_PROMPT_REUSE_SETTINGS_HELP="Wir haben einen früheren Installationsversuch auf diesem Mac erkannt. Die Fragen, die du bereits beantwortet hast (Name, Name des Assistenten, Zeitzone, Ländervorwahl, Kanäle usw.), werden wiederverwendet, sodass du sie nicht erneut eingeben musst. Wähle „Ja“, um dort weiterzumachen, wo du aufgehört hast, oder „Nein“, um die Fragen noch einmal von vorn durchzugehen."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Gefundene frühere Antworten: Name = %s, Assistent = %s, Zeitzone = %s."

MSG_PROMPT_PERMS_OK_TITLE="Bereit, fortzufahren?"
MSG_PROMPT_PERMS_OK_HELP="macOS fragt nach dem Zugriff auf Kontakte sowie auf Dateien und Ordner. Der optionale Festplattenvollzugriff kann später erteilt werden."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Vollständiger Name (wie in deinen Kontakten)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Vollständiger Name (z. B. Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="Wie soll dein Assistent dich nennen?"
MSG_PROMPT_USER_ID_HELP="Ein kurzer Name, mit dem dein Assistent dich anspricht (z. B. 'Andy', 'Andrew', 'Frau Schmidt'). Er erscheint in deinen Morgenübersichten und in Chat-Antworten. Er unterscheidet sich von deinem vollständigen Namen oben."

# ── End-of-install confirmation (calendars + identity) ──
#
# One-time propose-and-confirm at the end of setup that seeds the
# disambiguation the daily brief relies on. Calendar prompts confirm whose
# diary each calendar is (so a partner's flight is not read as yours);
# identity prompts confirm which look-alike profiles are you (collapse) and
# which are a different person who happens to share your name (split). All
# skippable -- hitting enter accepts the pre-filled guess. Calendars are ONE
# screen confirmed once; the per-calendar OWNER/TYPE/INCLUDE prompts appear
# only if the customer says the list is not right. %s placeholders carry
# runtime values (calendar name, event count/samples, the evidence that
# links or separates a profile). EVENTS_ONE / EVENTS_MANY are the singular
# and plural of the event count ("1 event", "2 events").
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="Hier sind deine Kalender. Stimmt das so?"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="Wir haben geschätzt, wem welcher gehört, damit deine Übersicht Reisen nie der falschen Person zuordnet."
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="Automatisch beiseitegelegt, nicht für deine Übersicht verwendet:"
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="deiner"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="%s Termin"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="%s Termine"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="gesetzliche Feiertage"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="Geburtstage"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="Siri-Vorschläge"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="ein Kalender, den du abonniert hast"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="Erinnerungen"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="„%s“ für deine Übersicht verwenden?"
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="Wir haben diesen beiseitegelegt, weil er wie %s aussieht. Sag Ja, wenn es wirklich jemandes Terminkalender ist."
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="Wem gehört der Kalender „%s“?"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="Was für ein Kalender ist „%s“?"
# NEEDS REVIEW: The option words may be typed answers compared by the installer in English (personal/work/family/shared/other); a developer should confirm whether they must sta
MSG_CONFIRM_CALENDAR_TYPE_HELP="Eines von: privat, beruflich, Familie, geteilt, andere. Das legt fest, wie sensibel seine Termine behandelt werden."
MSG_CONFIRM_CALENDARS_SAVED="Kalenderbesitzer gespeichert"
MSG_CONFIRM_CALENDARS_FAILED="Kalenderbesitzer konnten nicht gespeichert werden (nicht kritisch; du kannst sie später festlegen)"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="Wir glauben, dass all diese Profile zu dir gehören (%s). Zu einem zusammenführen?"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="Diese Profile haben ein eindeutiges Identitätsmerkmal mit dir gemeinsam (eine E-Mail-Domain, ein LinkedIn-Profil oder einen Arbeitgeber). Wenn du sie zusammenführst, behandelt dein Assistent deine eigene Geschichte nicht als mehrere verschiedene Personen. Du kannst das später rückgängig machen."
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="Jemand teilt deinen Namen, sieht aber nach einer anderen Person aus (%s). Bist du das oder jemand anderes?"
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="Wähle „Andere Person“, um sie als eigene Person zu behalten (dein Assistent führt sie nie mit dir zusammen). Wähle „Ich“ nur, wenn du es wirklich bist."
MSG_CONFIRM_IDENTITY_SAVED="Deine Identität gespeichert"
MSG_CONFIRM_IDENTITY_FAILED="Identitätsauswahl konnte nicht gespeichert werden (nicht kritisch, du kannst sie später bestätigen)"

# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="Installation läuft im Hintergrund (etwa 45 Minuten bis einige Stunden)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="+%s verwenden?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Ländervorwahl eingeben (z. B. 44 für UK, 1 für USA)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Standard-Ländervorwahl"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Wird verwendet, um Telefonnummern beim Kontaktimport zu vereinheitlichen und deine Region (UK / EU / USA / andere) für rechtliche Standardvorgaben festzulegen."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="Wir haben +%s erkannt. Diese Vorwahl für deinen Hub verwenden?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Aus deiner Telefonnummer oben erkannt. Wähle „Ja“, um diese Vorwahl zu verwenden, oder „Nein“, um eine andere Ländervorwahl einzugeben."

MSG_PROMPT_TZ_CONFIRM_TITLE="Diese Zeitzone verwenden?"
MSG_PROMPT_TZ_CONFIRM_HELP="Erkannte Zeitzone: %s"
MSG_PROMPT_USER_TZ_TITLE="Zeitzone eingeben (z. B. Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="Wie möchtest du deinen Assistenten nennen?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="Der Name im Feld ist ein zufälliger Vorschlag – überschreibe ihn einfach mit einem Namen deiner Wahl. Marvin, Samantha, Joshua, Friday, Athena, Sage und Rosie sind beliebte Namen." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Gib einen beliebigen Namen ein – der Vorschlag ist nur ein Anfang."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="Wie soll dein Assistent dich erreichen?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Wähle die Nachrichtenkanäle, die dein Assistent verwenden soll. Du kannst das später im Bereich „Doctor“ der App ändern."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_WHATSAPP_CONSENT_TITLE="WhatsApp-Nachrichten für deinen Assistenten aktivieren?"
# NEEDS REVIEW: Consent/legal wording; lawyer should confirm.
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web ist ein Dienst eines Drittanbieters. Mit der Aktivierung akzeptierst du, dass deine Nachrichten über die eigene Infrastruktur von WhatsApp laufen, bevor sie deine lokale Ostler-Instanz erreichen, und dass WhatsApp (Meta Platforms Ireland Ltd) dein WhatsApp-Konto wegen automatisierter Nutzung sperren, einschränken oder beenden kann. Du kannst das später in den Einstellungen deaktivieren."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="Deine WhatsApp-Telefonnummer"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Internationale Nummer mit Ländervorwahl, z. B. +447700900123. Nur Ziffern und ein führendes + – keine Leerzeichen, Klammern oder Bindestriche."
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="Gespeichert als %s. WhatsApp benötigt die Nummer ohne Leerzeichen oder Klammern."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Festplattenvollzugriff für den Ostler-Assistenten aktivieren"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="Die Systemeinstellungen sind bei „Festplattenvollzugriff“ geöffnet."
# Both branches rewrote these three lines and they made DIFFERENT claims
# about what happens after Done. Resolved against the CODE, not by
# preferring a side: after the modal is dismissed install.sh polls
# _imessage_daemon_fda_granted 20 x 2s (~40s), breaking the instant the
# switch is on. Both branches ship that poll. So "click Done any time to
# continue" understates what the installer actually does, and the
# order-does-not-matter wording is the accurate one -- it is the only
# version that tells the customer their click order is safe, which is the
# whole reason the poll exists.
# Locator wording taken from the other side: "Find ... in the list" tells
# them WHERE to look before naming WHICH switch to flip.
# WALK-874(b), measured on the v1.0.44 walk 2026-08-24 step 26/37: these
# two lines named the row "Ostler". The row macOS shows is the assistant
# bundle's file name -- OstlerAssistant. A customer scanning for "Ostler"
# concludes it is absent and goes to Finder, which LINE3 tells them not
# to do. %s is now DERIVED from the bundle at run time
# (install.sh: _ostler_fda_entry_name), so a bundle rename moves the copy
# with it. Do NOT reintroduce a literal product name here -- it is
# mutation-tested by tests/test_fda_dialog_tells_the_truth.sh case-4.
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Suche „%s“ in der Liste und aktiviere den Schalter für den Festplattenvollzugriff."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="Nicht aufgeführt? Ziehe „%s“ aus dem Finder-Fenster in die Liste und aktiviere dann den Schalter. Die Reihenfolge spielt keine Rolle – klicke vorher oder nachher auf „Fertig“; das Installationsprogramm wartet, bis der Schalter tatsächlich aktiviert ist."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="Nicht aufgeführt? Ostler konnte kein Finder-Fenster für dich öffnen. Drücke im Finder ⌘⇧G, gib den Pfad unten ein, ziehe dann „%s“ in die Liste und aktiviere den Schalter. Die Reihenfolge spielt keine Rolle – klicke vorher oder nachher auf „Fertig“; das Installationsprogramm wartet, bis der Schalter tatsächlich aktiviert ist."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="Die App befindet sich hier: %s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="Die App befindet sich hier: %s – dieser Pfad liegt in deiner Zwischenablage. Drücke im Finder ⌘⇧G, dann ⌘V und dann den Zeilenschalter."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Fertig"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="Du kannst vor oder nach dem Umlegen des Schalters auf „Fertig“ klicken – das Installationsprogramm wartet, bis er tatsächlich aktiviert ist."

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Ostler das Lesen deiner Mac-Daten erlauben"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="Die Systemeinstellungen sind bei „Festplattenvollzugriff“ geöffnet."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Suche „OstlerInstaller“ in der Liste und aktiviere den Schalter."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Klicke auf „Fertig“, wenn du fertig bist. Ostler liest dann deinen Safari-Verlauf, Notizen, iMessages und Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Fertig"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="Als Nächstes: Festplattenvollzugriff für das Installationsprogramm"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="Als Nächstes bittet macOS dich, OstlerInstaller den Festplattenvollzugriff zu erteilen."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Nachdem du den Schalter aktiviert hast, zeigt macOS ein Dialogfenster an, in dem du „Beenden und erneut öffnen“ oder „Später“ auswählen kannst."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Klicke auf „Beenden und erneut öffnen“. Der Installer startet sich selbst neu und macht automatisch an dieser Stelle weiter."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="OK"
MSG_INFO_INSTALLER_FDA_PREWARN="Ich erkläre dir kurz, wie du den Festplattenvollzugriff erteilst..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="Die Systemeinstellungen werden geöffnet, damit du dem Installer den Festplattenvollzugriff erteilen kannst..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="Festplattenvollzugriff für den Installer erteilt. Als Nächstes werden Safari, Notizen, iMessages und Mail gelesen."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="Festplattenvollzugriff wurde noch nicht erteilt. Es geht ohne ihn weiter; du kannst den Installer später erneut ausführen, um Safari, Notizen und iMessages auszulesen."
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="Der Festplattenvollzugriff für den Installer ist erledigt. Jetzt beginnt der lange Teil, der größtenteils von allein läuft. Achte aber auf ein macOS-Dialogfenster, das fragt, ob Entwicklerwerkzeuge installiert werden sollen, und komm gegen Ende für ein paar Minuten Einrichtung zurück."
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="Eine weitere Berechtigung (Nachrichtenverlauf für deinen Assistenten) folgt gegen Ende, sobald dein Assistent installiert ist. Wir zeigen dir dann, wo du sie erteilst."
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="Festplattenvollzugriff noch erforderlich"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostler ist kurz davor, die Daten auf deinem Mac zu lesen, aber der Festplattenvollzugriff für OstlerInstaller ist noch ausgeschaltet. Suche „OstlerInstaller“ in der Liste und schalte ihn ein."
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="Oder klicke einfach auf „Fortfahren“, um die Installation mit weniger Daten abzuschließen. Du kannst den Zugriff später erteilen und den Extraktor erneut ausführen."
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="Fortfahren"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="Erlaubte Kontakte"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="Vertrauenswürdige Personen: Telefonnummern und Apple-ID-E-Mail-Adressen (durch Kommas getrennt). %s antwortet nur Personen auf dieser Liste; Nachrichten von allen anderen werden ignoriert. Mindestens ein Eintrag ist erforderlich.

Zum Beispiel:
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="E-Mails über Apple Mail lesen?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Liest jedes E-Mail-Konto, das du in Apple Mail hinzugefügt hast (iCloud, Gmail, Outlook usw.), mithilfe des Festplattenvollzugriffs. Es werden keine Passwörter gespeichert. Für fast alle empfohlen."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="Ein E-Mail-Konto zu Apple Mail hinzufügen?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="In Apple Mail ist auf diesem Mac noch kein Konto verbunden, daher hat Ostler keine E-Mails zum Lesen. Wähle „Ja“, um jetzt Systemeinstellungen > Internetaccounts zu öffnen (dort kannst du iCloud, Gmail oder Outlook hinzufügen). Wähle „Nein“, um zu überspringen. Du kannst später ein Konto hinzufügen, und Doctor weist dich darauf hin, wenn innerhalb von 24 Stunden keine E-Mails ankommen."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="Gesamten Apple-Mail-Verlauf übernehmen?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Standardmäßig liest Ostler die letzten fünf Jahre deiner Apple-Mail-Daten. Wenn du auf diesem Mac mehr aufbewahrst und alles in deinem Wissensgraphen haben möchtest, wähle „Ja“, um jetzt den gesamten lokalen Verlauf zu übernehmen (bei einem großen Postfach kann das etwas länger dauern). Wähle „Nein“, um beim Zeitraum von fünf Jahren zu bleiben. Du kannst ihn später jederzeit in Doctor erweitern."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="Auch einen eigenen IMAP- und SMTP-Server konfigurieren?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="Nur für selbst gehostete Postfächer. Lass es auf „Nein“, wenn deine Konten bei Gmail, iCloud oder Outlook sind. Diese funktionieren über Apple Mail (oben) besser."

MSG_PROMPT_IMAP_HOST_TITLE="IMAP-Host"
MSG_PROMPT_IMAP_HOST_HELP="Nur für selbst gehostete oder benutzerdefinierte IMAP-Server. Verwende Apple Mail (oben) für Gmail, iCloud und Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="IMAP-Port"

MSG_PROMPT_SMTP_HOST_TITLE="SMTP-Host"
MSG_PROMPT_SMTP_PORT_TITLE="SMTP-Port"

MSG_PROMPT_EMAIL_USERNAME_TITLE="E-Mail-Adresse (auch als IMAP-/SMTP-Benutzername verwendet)"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="Wer darf deinem Assistenten E-Mails schreiben?"
MSG_PROMPT_EMAIL_ALLOWED_HELP="Deine eigenen E-Mail-Adressen, durch Kommas getrennt. %s beantwortet nur E-Mails von Adressen auf dieser Liste; Nachrichten von allen anderen werden ignoriert. Mindestens eine Adresse ist erforderlich. Deine eigene Adresse ist bereits eingetragen: Du kannst sie ändern oder eine weitere hinzufügen."

MSG_PROMPT_EMAIL_PASSWORD_TITLE="Passwort (verborgen)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Passwort für deinen selbst gehosteten IMAP-/SMTP-Server. Es wird lokal unter ~/.ostler/ gespeichert und nie an Creative Machines gesendet. Es wird im Klartext gespeichert: Geschützt ist es nur durch die Dateiberechtigungen, die ausschließlich deinem macOS-Account Zugriff erlauben. Es wird auch später nicht verschlüsselt. Verwende ein App-spezifisches Passwort statt des Passworts deines Hauptaccounts."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Passwort bestätigen"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="Welchen Ordner soll der Assistent überwachen?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="Empfohlen: ein eigenes Label oder ein eigener Ordner (z. B. Ostler). Wir lesen nur die Nachrichten dort und lassen deinen Posteingang unberührt."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="Gib zur Bestätigung erneut INBOX ein oder klicke auf „Fortfahren“, um „Ostler“ zu verwenden"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX bedeutet, dass der Assistent jede E-Mail liest, die du erhältst. Wir empfehlen dringend stattdessen ein eigenes Label oder einen eigenen Ordner."

MSG_PROMPT_EXPORTS_ACK_TITLE="Hast du deine Datenexporte angefordert?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler importiert von etwa 20 Plattformen. Die vollständige Liste mit direkten Links zur Anfrageseite jedes Anbieters findest du unter docs.ostler.ai/data-exports.

Die meisten Archive treffen nach 1 bis 3 Tagen per E-Mail ein. Sobald die ZIP-Dateien da sind, lege sie in deinen Ordner „Downloads“, und Ostler findet sie automatisch.

Überspringe alles, was du nicht nutzt. Du kannst später jederzeit weitere importieren."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="Mit UNVERSCHLÜSSELTER Festplatte fortfahren?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="FileVault ist auf diesem Mac AUSGESCHALTET, daher ist deine Festplatte nicht verschlüsselt.

Was das bedeutet, wenn du fortfährst: Alles, was Ostler speichert -- dein gesamter persönlicher Graph (Wiki, Unterhaltungen, Wissensnotizen) unter ~/Documents/Ostler sowie Dienstgeheimnisse und Datenbanken unter ~/.ostler -- wird UNVERSCHLÜSSELT auf die Festplatte geschrieben. Jeder, der von diesem Laufwerk starten, es ausbauen oder auf eine entsperrte Sitzung zugreifen kann, kann alles lesen. Ostler verschlüsselt seine sensibelsten Datenbanken ohnehin mit einer Passphrase, aber der Rest deiner Daten ist nur so gut geschützt wie die Festplatte selbst.

FileVault wird dringend empfohlen. Du kannst es jederzeit in Systemeinstellungen > Datenschutz & Sicherheit > FileVault einschalten -- die Verschlüsselung läuft im Hintergrund, ohne dass du neu installieren musst.

Wähle Ja, um jetzt mit unverschlüsselter Festplatte fortzufahren (das ist eine bewusste, informierte Entscheidung -- sie wird protokolliert).
Wähle Nein, um hier anzuhalten, damit du zuerst FileVault einschalten und dann das Installationsprogramm erneut ausführen kannst. In beiden Fällen ist nichts schiefgelaufen."

MSG_PROMPT_PASSKEY_ACK_TITLE="Bereit, die Festplattenverschlüsselung einzurichten"
MSG_PROMPT_PASSKEY_ACK_HELP="Die sensiblen Datenbanken von Ostler werden mit SQLCipher und einer Passphrase verschlüsselt, die du auf dem nächsten Bildschirm wählst. Du gibst diese Passphrase bei jedem Start der Hub-Oberfläche ein. Zusätzlich wird ein separater Wiederherstellungsschlüssel erzeugt und am Ende der Installation einmalig angezeigt. Für vollständigen Schutz aller Daten auf deinem Mac lässt du macOS FileVault eingeschaltet. Klicke auf Fortfahren, wenn du bereit bist."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="Auch eine Wiederherstellungs-Passphrase festlegen? (empfohlen)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="Passphrase wählen"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="Diese Passphrase verschlüsselt deinen Wissensgraphen und entsperrt bei jedem Start die Hub-Oberfläche. Mindestens 12 Zeichen. Wir können sie nicht für dich wiederherstellen. Wir empfehlen, sie in einem Passwortmanager zu speichern."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="Passphrase bestätigen"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="Gib dieselbe Passphrase zur Bestätigung erneut ein."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="Diese bei der Installation importieren?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="Gefundene DSGVO-Exporte werden bei der Installation in deinen Wissensgraphen importiert."

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="Disney+-Exportpasswort"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="Disney+ liefert seinen DSGVO-Export als passwortgeschützte Tabelle aus. Das ist normal und kein Problem mit deinem Download. Gib das Passwort ein, um deinen Disney+-Wiedergabeverlauf jetzt zu importieren, oder lass das Feld leer, um ihn zu überspringen. Alles andere wird trotzdem importiert."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="Hast du Datenexporte bereit?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler kann Archive von sozialen Medien und Plattformen importieren – deine gesamte Geschichte mit Freunden, Familie, Orten, Meinungen – gleich von Anfang an. Je mehr Ostler am ersten Tag weiß, desto nützlicher ist es am ersten Tag. Du kannst das auch später hinzufügen, ganz ohne Eile.

Fordere deinen Datenexport bei jeder Plattform an (Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp usw.), lade die ZIP-Dateien herunter und lege sie in deinen Ordner „Downloads“.

Ostler sucht standardmäßig in ~/Downloads. Du möchtest einen anderen Ordner? Wähle unten einen aus. Andernfalls überspringe den Schritt und importiere später."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="Gmail-Nachrichten aus diesem Takeout importieren?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Liest Gmail-Inhalte direkt aus der Takeout-Datei. Google bekommt Ostler nie zu sehen."

MSG_PROMPT_FDA_PRESET_TITLE="Aus welchen Mac-Quellen soll Ostler lernen?"
MSG_PROMPT_FDA_PRESET_HELP="Drei Voreinstellungen, oder wähle jede Quelle selbst. Sensible Quellen (Gesichtserkennung) sind in jeder Voreinstellung standardmäßig ausgeschaltet – wähle sie nur bewusst aus."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="Empfohlen. Enthält Apple Mail, Kontakte, Kalender, Notizen, Nachrichten, Erinnerungen, Safari-Verlauf, Safari-Lesezeichen und Fotos-Ereignisse (Datumsangaben und Orte, keine Gesichtserkennung). WhatsApp-Desktop-Verlauf und Chrome-Verlauf werden automatisch hinzugefügt, wenn die App installiert ist. Ausgenommen sind Gesichtserkennungsdaten aus Fotos und alle Exportarchive von Drittanbietern."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="Alles. Jede Quelle, die Ostler auf diesem Mac lesen kann. Die Gesichtserkennung in Fotos bleibt ausgeschaltet, bis du sie bewusst auswählst."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="Anpassen. Wähle jede Quelle auf dem nächsten Bildschirm aus. Sensible Quellen bleiben ausgeschaltet, bis du sie auswählst."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="Diese Datenquelle ein- oder ausschalten."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_ARTICLE_9_TITLE="Deine Entscheidung (Y / N)"
# NEEDS REVIEW: Legal consent wording; lawyer should check.
MSG_PROMPT_CONSENT_ARTICLE_9_HELP="Einwilligung nach Artikel 9 (besondere Datenkategorien, UK GDPR). Erforderlich für die Rechtsgrundlage der Verarbeitung."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_VOICE_EU_TITLE="Stimmen in den Anrufen erkennen, die du erfasst?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_VOICE_EU_HELP="Die Sprechererkennung bleibt auf diesem Mac. Creative Machines erhält die Stimmabdrücke nie."

# Enrichment opt-in (Q_ENRICH). Andy, 2026-08-18: "users must EXPLICITLY
# decide whether public-data enrichment runs. Not a default-on setting."
# v1.0.36 shipped the agent gated off and this is the question that was owed
# in the next cut, enforced by tests/test_enrichment_optin_is_owed_after_v1_0_36.sh.
#
# TITLE IS DELIBERATELY SHORT. Task #167: the spoken-consent sheet pushed its
# own title and toggle off-screen because the title ran long.
#
# The HELP text states what LEAVES the Mac and what CANNOT be hidden, because
# the second one is true and easy to omit: measured 2026-08-18, enrichment
# requests carry no IP obfuscation and identify themselves as Ostler. A
# consent question that describes only the flattering half is not consent.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_ENRICHMENT_TITLE="Öffentliche Fakten zu gespeicherten Dingen nachschlagen?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_ENRICHMENT_HELP="Ostler kann zu Dingen, die es findet, öffentliche Referenzangaben ergänzen – ein Buch, ein Film, ein Album, ein Ort. Dazu sendet es den NAMEN dieser einen Sache an öffentliche Referenzdienste wie Wikidata, MusicBrainz und OpenLibrary und speichert die Antwort auf diesem Mac.

Was deinen Mac verlässt: der Name der nachgeschlagenen Sache. Sonst nichts. Nicht deine Nachrichten, nicht deine Kontakte, nicht deine Dateien und nicht, wer sie erwähnt hat.

Was der Dienst auf der anderen Seite sehen kann: deine IP-Adresse und dass die Anfrage von Ostler kam. Die Abfrage geht direkt von deinem Mac zu ihnen - nichts läuft über unsere Server - daher lässt sich nicht anfragen, ohne dass sie erfahren, dass jemand angefragt hat.

Wenn du Nein sagst: Es werden keine Abfragen gemacht, und der Anreicherungsjob im Hintergrund wird gar nicht installiert. Alles andere funktioniert genau gleich. Deine Bibliothek enthält dann nur das, was du ihr gegeben hast, und nicht das, was ein öffentlicher Katalog ergänzt.

Du kannst jetzt Nein sagen und es dir später anders überlegen, indem du das Installationsprogramm erneut ausführst."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE="Eine letzte Sache: Wie Daten von Drittanbietern behandelt werden"
# NEEDS REVIEW: Legal text; smoothed 'verstehst du und stimmst zu'; lawyer should check.
MSG_PROMPT_CONSENT_THIRD_PARTY_HELP="Alle Daten, die du von Drittanbietern importierst (Google Takeout, Meta-Downloads, LinkedIn-Exporte usw.), bleiben auf diesem Mac. Ostler speichert sie in deinem lokalen Wissensgraphen; nichts verlässt dein Gerät.

Indem du fortfährst, bestätigst du, dass du allein für die Verarbeitung und Aufbewahrung dieser Daten auf deinem Rechner verantwortlich bist, genau wie für die E-Mails, die bereits auf deiner Festplatte liegen, und stimmst dem zu.

Rechtlicher Hinweis: Für Datensätze, die du auf diesen Mac importierst, bist du nach britischem und EU-Recht der Verantwortliche und der Auftragsverarbeiter (UK GDPR Artikel 4(7) und 4(8)). Creative Machines erhält diese Daten nie und ist nicht der Verantwortliche. Deine Verarbeitung für persönliche und familiäre Zwecke fällt unter Artikel 2(2)(c) der UK/EU-DSGVO.

Mehr dazu unter docs.ostler.ai/privacy/third-party-data."

# Spoken-capture recording-consent acknowledgement (every region). Shown
# in the Phase-2 consent batch. The HELP string is the substantive text
# GUI installer users read on the decision sheet, so it is self-contained.
# ── Personal-use-only terms (vendor/legal/consent_strings.py PERSONAL_USE_ONLY) ──
# A LICENCE TERM, not an optional consent, which is why it acknowledges rather
# than offering a decline that leaves a half-licensed install. Wording verbatim
# from the versioned ConsentString so the Doctor can flag drift.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TERMS_PERSONAL_USE_HEADING="Wofür Ostler gedacht ist"
MSG_TERMS_PERSONAL_USE_INTRO="Ostler ist für eine einzelne Person gebaut, auf ihrem eigenen Mac, um ihr eigenes Leben zu verstehen. Das ist das gesamte Konzept, und deshalb verlassen deine Daten diesen Rechner nie."
# NEEDS REVIEW: Licence term; lawyer should check.
MSG_TERMS_PERSONAL_USE_BUSINESS="Es ist nicht für den geschäftlichen Einsatz gebaut. Bitte setze Ostler nicht bei Mitarbeitenden ein und nutze es nicht im Rahmen deiner Arbeit, um Kolleginnen, Kollegen, Kunden, Patienten oder Klienten zu erfassen. Wenn eine Organisation das tut, wird sie für alle verantwortlich, deren Informationen sie erhebt, und Ostler ist nicht dafür ausgelegt, das zu tragen."
# NEEDS REVIEW: Replaced the clumsy gendered opening. Legal responsibility wording needs lawyer review.
MSG_TERMS_PERSONAL_USE_RECORDER="Die Aufzeichnung machst du, Ostler ist nur das Werkzeug. Wo dein örtliches Recht eine Einwilligung verlangt, bevor ein Gespräch aufgezeichnet wird, musst du sie selbst einholen, und wir können von hier aus nicht wissen, ob eine bestimmte Aufzeichnung dort, wo du bist, rechtmäßig ist."
MSG_TERMS_PERSONAL_USE_ASK_HEADING="Wir bitten dich, drei Dinge zu unterlassen:"
MSG_TERMS_PERSONAL_USE_ASK_1="Zeichne keine Kinder auf, ohne dass ein Elternteil oder Erziehungsberechtigter zustimmt. Ein Kind kann diese Zustimmung nicht selbst geben, und deine eigene Zusicherung ersetzt sie nicht."
MSG_TERMS_PERSONAL_USE_ASK_2="Zeichne nicht an Orten auf, an denen Menschen echte Privatsphäre erwarten: bei einem Arzttermin, einem Anwaltsgespräch, einer Therapiesitzung, einer religiösen Beichte, in einem Badezimmer oder einer Umkleide."
MSG_TERMS_PERSONAL_USE_ASK_3="Verwende Ostler nicht, um jemanden heimlich aufzuzeichnen, wo das bei dir geltende Recht dies nicht erlaubt."
# NEEDS REVIEW: Licence and GDPR-role wording needs lawyer review.
MSG_TERMS_PERSONAL_USE_LEGAL="Ostler ist für die persönliche, nicht kommerzielle Nutzung durch eine natürliche Person lizenziert. Creative Machines ist weder Verantwortlicher noch Auftragsverarbeiter der Informationen, die du auf deinem Mac aufbewahrst, erhält nichts davon und übernimmt keine Gewähr dafür, dass eine bestimmte Aufzeichnung oder Erfassung in deinem Rechtsgebiet rechtmäßig ist."
MSG_PROMPT_TERMS_PERSONAL_USE_TITLE="Ostler ist für den persönlichen Gebrauch bestimmt"
# NEEDS REVIEW: Licence acceptance terms need lawyer review. Verify the button label really is "Fortfahren".
MSG_PROMPT_TERMS_PERSONAL_USE_HELP="Ostler ist für deine eigene persönliche Nutzung auf deinem eigenen Mac lizenziert. Bitte setze es nicht für Mitarbeitende ein und nutze es nicht bei der Arbeit, um Kolleginnen, Kollegen, Kundschaft oder Patienten zu erfassen. Zeichne keine Kinder ohne Zustimmung eines Elternteils auf und zeichne nicht an Orten auf, an denen Menschen echte Privatsphäre erwarten, etwa bei einem Arzt-, Anwalts- oder Therapietermin. Klicke auf Fortfahren, um diese Bedingungen zu akzeptieren."
MSG_INFO_TERMS_PERSONAL_USE_DECLINED="Kein Problem. Es wurde nichts installiert."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_HEADING="Gesprochene Unterhaltungen in Text umwandeln"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_INTRO="Kurz gesagt: Wenn du gesprochenes Audio erfasst, um es zu transkribieren, liegt es in deiner Verantwortung, nicht in unserer, jede gesetzlich erforderliche Einwilligung einzuholen. Tippen und Nachrichtenschreiben sind nicht betroffen."
# NEEDS REVIEW: Statement about national recording law needs lawyer review.
MSG_CONSENT_SPOKEN_CAPTURE_LAW="Ostler kann gesprochene Unterhaltungen, die du erfasst – Anrufe und Besprechungen – in durchsuchbaren Text umwandeln; das betrifft nur Audio, das du transkribieren lässt. Die Regeln zur Aufzeichnung gesprochener Worte unterscheiden sich von Land zu Land – an manchen Orten (zum Beispiel in Deutschland und Frankreich) müssen zuvor alle Beteiligten zustimmen."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_LOCAL="Dass das erfasste Audio auf deinem eigenen Mac bleibt, hebt diese Pflicht nicht auf – Ostler sendet es nirgendwohin, aber du brauchst trotzdem eine Einwilligung, wo dein örtliches Recht sie verlangt."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_HEADING="Worum wir dich bitten:"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_1="Hole jede Einwilligung ein, die dein örtliches Recht verlangt, bevor du ein Gespräch erfasst."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_2="Mach den Menschen, mit denen du zusammen bist, deutlich, dass Audio erfasst wird – sag es zum Beispiel gleich zu Beginn oder lass eine sichtbare Anzeige eingeschaltet."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_3="Lass die Transkription gesprochener Worte im Zweifel ausgeschaltet. Deine Textunterhaltungen funktionieren in jedem Fall."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_LABEL="Deine Entscheidung:"
# NEEDS REVIEW: Consent affirmation the customer accepts; needs lawyer review.
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_Y="[Y] Ich verstehe das und werde jede Einwilligung einholen, die mein örtliches Recht verlangt."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_N="[N] Jetzt nicht – Transkription gesprochener Worte ausgeschaltet lassen. (Du kannst sie später in den Einstellungen aktivieren.)"
# NEEDS REVIEW: Legal note citing statutes; needs lawyer review.
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL="Rechtlicher Hinweis: Die Aufzeichnung des gesprochenen Wortes kann unabhängig vom Datenschutzrecht durch nationales Recht geregelt sein – zum Beispiel durch § 201 des deutschen Strafgesetzbuchs (Verletzung der Vertraulichkeit des Wortes) oder Artikel 226-1 des französischen Strafgesetzbuchs (Code pénal). Als Person, die auf diesem Mac aufzeichnet, bist du für die Einhaltung verantwortlich. Creative Machines erhält deine Aufzeichnungen nie und ist an ihnen nicht beteiligt."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_TITLE="Gesprochene Unterhaltungen in Text umwandeln?"
# NEEDS REVIEW: Aligned wording with the fixed standalone strings. Legal consent text needs lawyer review.
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_HELP="Kurz gesagt: Wenn du gesprochenes Audio erfasst, um es zu transkribieren, liegt es in deiner Verantwortung, jede gesetzlich erforderliche Einwilligung einzuholen. Tippen und Nachrichtenschreiben sind nicht betroffen.

Ostler kann gesprochene Unterhaltungen, die du erfasst – Anrufe und Besprechungen – in durchsuchbaren Text umwandeln. Das betrifft nur Audio, das du transkribieren lässt.

Worum wir dich bitten:
• Hole jede Einwilligung ein, die dein örtliches Recht verlangt, bevor du Audio erfasst.
• Mach deutlich, dass Audio erfasst wird – sag es oder lass eine sichtbare Anzeige eingeschaltet.
• Lass dies im Zweifel ausgeschaltet. Deine Textunterhaltungen funktionieren in jedem Fall, und du kannst es später in den Einstellungen aktivieren.

Rechtlicher Hinweis: Die Aufzeichnung des gesprochenen Wortes kann unabhängig vom Datenschutzrecht durch nationales Recht geregelt sein – zum Beispiel durch § 201 des deutschen Strafgesetzbuchs oder Artikel 226-1 des französischen Strafgesetzbuchs. Als Person, die aufzeichnet, bist du für die Einhaltung verantwortlich. Creative Machines erhält deine Aufzeichnungen nie."
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="Die Transkription gesprochener Worte bleibt ausgeschaltet. Du kannst sie später in den Einstellungen aktivieren."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_TITLE="Bereit zur Installation?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_HELP="Gib INSTALL ein, um zu bestätigen, dass du die Bedingungen akzeptierst."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="INSTALL eingeben"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Ostler installieren"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Abbrechen"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Gib INSTALL genau so ein (Groß- und Kleinschreibung spielt keine Rolle), um zu bestätigen, oder klicke auf Abbrechen, um zurückzugehen."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="iPhone und Watch verbinden"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale gibt diesem Mac eine stabile private Adresse, die dein iPhone und deine Watch von überall erreichen können – verschlüsselt und ohne öffentliche Erreichbarkeit."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="Wiederherstellungsschlüssel im Schlüsselbund sichern?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="Speichert deinen Wiederherstellungsschlüssel für die Verschlüsselung zur sicheren Aufbewahrung im macOS-Schlüsselbund."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="Dein Graph wird befüllt"
MSG_HYDRATE_CONTACTS_STARTED="Deine Kontakte werden in den Graphen importiert"
MSG_HYDRATE_CONTACTS_DONE="%s Kontakte importiert"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="Die Kontakte haben länger als %s s gedauert, daher haben wir nicht länger gewartet und sind weitergegangen. Bisher sind %s Kontakte importiert, den Rest erledigt Ostler im Hintergrund."
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="Dein Kalenderverlauf wird geladen (fünf Jahre zurück, ein Jahr voraus)"
MSG_HYDRATE_CALENDAR_DONE="%s Termine importiert"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  Dein Kalender wird noch geladen (bisher %ss). Ein Mac mit jahrelangen Terminen braucht einen Moment."
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="Deine Orte werden aus den Standorten deiner Termine erstellt"
MSG_HYDRATE_PLACES_DONE="Dein Bereich „Orte“ wurde erstellt"
MSG_HYDRATE_PLACES_SKIPPED="Noch keine Standortsignale gefunden; „Orte“ füllt sich, sobald sich dein Kalender füllt"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="Beim Erstellen der Orte ist ein Problem aufgetreten: Es gibt Standortsignale, aber es wurden keine Orte erzeugt. Deine Seite „Orte“ bleibt möglicherweise leer. Siehe %s"
MSG_HYDRATE_PLACES_ERROR_WARN="Das Erstellen der Orte wurde nicht abgeschlossen (unerwarteter Fehler). Deine Seite „Orte“ ist möglicherweise unvollständig. Siehe %s"
MSG_HYDRATE_WIKI_RECOMPILE="Dein Wiki wird erstellt. Ostler schreibt eine kurze Zusammenfassung zu jeder deiner wichtigen Personen, Organisationen und Themen. Bei einem großen Adressbuch kann das einige Minuten bis etwa eine Stunde dauern. Das passiert nur einmal, läuft komplett auf deinem Mac und du kannst es ruhig laufen lassen."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="Dein Suchindex wird geprüft (%s Sammlungen erkannt)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="Dein Browserverlauf wird in den Suchindex geladen"
MSG_INITIAL_HYDRATE_QDRANT_READY="Suchindex bereit (%s Sammlungen)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="Der Suchindex wird nach Abschluss der Installation im Hintergrund gefüllt"
# #616 / #615. MSG_INITIAL_HYDRATE_QDRANT_READY above is printed with a COUNT,
# and a count cannot see a missing member. On the v1.0.60 walk box the store
# holds three collections, two of the four the installer promised are absent,
# and the count-based test called that "ready". These three strings exist so
# the install can say WHICH, and so that "could not look" is a third outcome
# rather than being folded into either of the other two.
#
# NOTE ON TIME WORDS: the _AWAITING string deliberately inherits the wording of
# the DEFERRED string above and names no deadline. Background loading has no
# completion time we can honestly quote (see background-copy-honesty.yml, where
# an "hour" was measured wrong by two orders of magnitude); it may say work
# CONTINUES, never when it will be DONE.
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="Der Suchspeicher läuft jetzt; fehlende Sammlungen werden noch erstellt: %s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="Der Suchindex ist unvollständig: %s konnte nicht erstellt werden, obwohl der Suchspeicher läuft und antwortet. Ostler funktioniert weiter und der Doctor zeigt diese Lücke an, aber dieser Teil der Suche bleibt leer, bis das behoben ist."
MSG_WARN_QDRANT_COLLECTIONS_MISSING="Der Suchindex ist unvollständig: %s konnte nicht erstellt werden. Ostler funktioniert weiter und der Doctor zeigt diese Lücke an."
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="Es konnte nicht geprüft werden, welche Suchsammlungen vorhanden sind (%s). Das heißt nicht, dass sie fehlen."
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="Der Suchindex wird nach Abschluss der Installation im Hintergrund gefüllt (Warten auf: %s)"
MSG_HYDRATE_DONE="Dein Graph ist bereit: %s Personen, %s Ereignisse"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud synchronisiert deine Kontakte möglicherweise noch – sie werden jetzt erneut exportiert, um alles Neue zu erfassen."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="Keine Kontakte in deiner App „Kontakte“ gefunden (lokal oder iCloud). Füge dort welche hinzu und starte den Vorgang erneut in den Einstellungen."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="Keine iCloud-Kontakte zum Importieren. Du kannst das später in den Einstellungen nachholen."
MSG_HYDRATE_SKIPPED_NO_EVENTS="Keine Kalendertermine in den letzten 5 Jahren. Du kannst sie später in den Einstellungen nachladen."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="Die E-Mails der letzten 90 Tage werden gelesen – deine E-Mails bleiben auf diesem Mac (ältere Mails werden im Hintergrund nachgeladen)"
MSG_HYDRATE_EMAIL_DONE="%s Personen in deinen letzten E-Mails gefunden"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="Keine aktuellen E-Mails zum Lesen. Du kannst in Apple Mail ein Mail-Konto hinzufügen und es später erneut starten."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="Der E-Mail-Reader ist noch nicht bereit. Du kannst in Apple Mail ein Mail-Konto hinzufügen und es später erneut starten."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="E-Mails werden noch im Hintergrund geladen. Dein Wiki füllt sich nach und nach und zeigt dir, wie weit der Vorgang ist."
MSG_HYDRATE_EMAIL_HEARTBEAT="  Deine E-Mails werden noch gelesen (bisher %ss). Bei einem Mac mit jahrelangem Verlauf kann das eine Weile dauern."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="Apple Mail öffnen, damit die Synchronisierung beginnt?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="Du hast %s Mail-Konto/Konten eingerichtet, aber Apple Mail hat noch keine Nachrichten abgerufen. Wir können Mail.app jetzt öffnen und warten, bis die Synchronisierung läuft."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="Kalender öffnen, damit die Synchronisierung beginnt?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="Du hast %s Kalenderkonto/-konten eingerichtet, aber in Calendar.app sind noch keine Termine gespeichert. Wir können Kalender jetzt öffnen und warten, bis die Synchronisierung mit iCloud läuft."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="Kontakte öffnen, damit die Synchronisierung beginnt?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="Du hast %s Konto/Konten für Kontakte eingerichtet, aber in Contacts.app sind noch keine Einträge gespeichert. Wir können Kontakte jetzt öffnen und warten, bis die Synchronisierung mit iCloud läuft."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="Warten, bis die Synchronisierung von %s beginnt (bis zu %s Sekunden)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="Es wird noch auf die Synchronisierung von %s gewartet (%ss vergangen, %ss verbleibend). Die erste iCloud-Synchronisierung kann nach einer neuen Anmeldung einige Minuten dauern."
MSG_OK_APP_HAS_POPULATED="%s hat den lokalen Speicher gefüllt. Es geht weiter."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="Innerhalb der Wartezeit wurde keine Synchronisierung von %s erkannt. Es geht weiter; du kannst den Import später in den Einstellungen erneut starten."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="Sichtbare Apple-Mail-Konten: %s. Öffne Mail.app einmal, damit der Abruf der Nachrichten beginnt."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="Sichtbare Kalenderkonten: %s. Öffne Calendar.app einmal, damit deine Termine synchronisiert werden."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="Sichtbare Kontakte-Konten: %s. Öffne Contacts.app einmal, damit dein Adressbuch synchronisiert wird."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="Deine Kontakte konnten nicht gelesen werden. Ostler liest sie über den Festplattenvollzugriff. Erteile ihn unter Systemeinstellungen > Datenschutz & Sicherheit > Festplattenvollzugriff und starte dann die Hydration in den Einstellungen erneut. Wir versuchen es im Hintergrund weiter."
MSG_HYDRATE_CONTACTS_PENDING="Deine Kontakte-App wurde noch nicht synchronisiert. Öffne Kontakte einmal, warte, bis die Synchronisierung abgeschlossen ist, und starte dann die Hydration in den Einstellungen erneut."
MSG_HYDRATE_CONTACTS_READ_FAILED="Deine Kontakte befinden sich auf diesem Mac, aber Ostler hat 0 davon importiert, was unerwartet ist. Der Import wird im Hintergrund automatisch wiederholt. Wenn das Problem bestehen bleibt, starte die Hydration in den Einstellungen erneut oder sieh im Installationsprotokoll nach."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler prüft weiter im Hintergrund und importiert deine Kontakte automatisch, sobald iCloud die Synchronisierung abgeschlossen hat."
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="%s Kontakte mit Telefonnummern, aber fast ohne E-Mail-Adressen importiert (%s Telefon, %s E-Mail). Das bedeutet meist, dass der Kontakt-Reader E-Mail-Adressen übersprungen hat. Deine Kontakte sind weiterhin nutzbar. Siehe %s und starte die Hydration in den Einstellungen erneut, sobald das behoben ist."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="Neue Kontakte importiert. Dein Wiki wird im Hintergrund neu aufgebaut."
MSG_HYDRATE_CALENDAR_PENDING="Deine Kalender-App hat noch keine Termine synchronisiert. Öffne Kalender einmal, warte, bis die Synchronisierung abgeschlossen ist, und starte dann die Hydration in den Einstellungen erneut."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="Dein Kalender konnte diesmal nicht gelesen werden (der Extraktor meldete einen Fehler, nicht einen leeren Kalender). Deine übrigen Daten sind nicht betroffen. Siehe %s und starte dann die Hydration in den Einstellungen erneut."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="Dein WhatsApp-Verlauf wird gelesen – deine Nachrichten bleiben auf diesem Mac"
MSG_HYDRATE_WHATSAPP_DONE="%s Personen in deinen WhatsApp-Chats gefunden"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="WhatsApp-Chats wurden gelesen, aber nicht in deinen Personengraphen geschrieben (Exit %s). Ostler versucht es erneut. Details: %s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="Keine WhatsApp-Chats zum Lesen vorhanden. Du kannst es später in den Einstellungen erneut starten."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktop ist nicht installiert. Installiere es aus dem Mac App Store und starte den Vorgang in den Einstellungen erneut."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="Der WhatsApp-Reader ist noch nicht bereit. Du kannst es später in den Einstellungen erneut starten."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp wird noch im Hintergrund geladen. Dein Wiki füllt sich nach und nach und zeigt dir, wie weit es ist."

# ── A SKIP THAT WAS NEVER EARNED HAD A SENTENCE OF ITS OWN (#2314) ──
#
# #2313 gave the browsing leg these three lines. Seven more legs skipped on the
# same evidence and printed the same class of false sentence when they did:
# "No WhatsApp chats to read", "No iMessage history to read", "No people to
# index yet", "No email-preferences file configured", "No AI chat history to
# read" -- each emitted by a branch that had NOT looked at whether the data was
# still there, and two of them ("already in your knowledge base") asserting a
# state of the store from a file that cannot see the store.
#
# ALREADY_IMPORTED is the skip that was corroborated, and it carries the count
# the destination actually reported, so the sentence is checkable by the
# customer rather than merely reassuring. The two REIMPORT_ lines separate "the
# rows are gone" from "I could not look", which is the distinction the whole
# change turns on.
#
# Privacy unchanged: counts only. No names, handles, addresses, titles or
# message content in any of these.
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="Deine WhatsApp-Kontakte befinden sich bereits in deinem Personengraphen (%s Kennungen). Nichts erneut zu lesen."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="Deine WhatsApp-Kontakte wurden schon einmal gelesen, aber dein Personengraph enthält sie nicht mehr. Sie werden erneut gelesen."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="Es konnte nicht geprüft werden, ob deine WhatsApp-Kontakte noch in deinem Personengraphen sind. Sie werden erneut gelesen, statt anzunehmen, dass sie vorhanden sind."

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="Dein KI-Chatverlauf wird gelesen – deine Unterhaltungen bleiben auf diesem Mac"
MSG_HYDRATE_AICONV_DONE="%s KI-Unterhaltungen in deinem Wiki gespeichert"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="Der Reader für KI-Unterhaltungen ist noch nicht bereit. Du kannst es später in den Einstellungen erneut starten."
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="Kein KI-Chatverlauf zum Lesen vorhanden. Du kannst es später in den Einstellungen erneut starten."
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="KI-Chats werden noch im Hintergrund geladen. Dein Wiki füllt sich nach und nach und zeigt dir, wie weit es ist."
MSG_HYDRATE_AICONV_HEARTBEAT="  Dein KI-Chatverlauf wird noch gelesen (bisher %ss). Ein großer Verlauf kann mehrere Minuten dauern."


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="Dein Browserverlauf wird importiert – deine Besuche bleiben auf diesem Mac"
MSG_HYDRATE_BROWSING_DONE="%s Seiten Browserverlauf importiert"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="%s als sensibel markierte Seiten übersprungen (Banking, Medizin usw.)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="Kein Browserverlauf zum Importieren vorhanden. Du kannst es später in den Einstellungen erneut starten."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="Der Reader für den Browserverlauf ist noch nicht bereit. Du kannst es später in den Einstellungen erneut starten."

# ── ONE SENTENCE FOR FOUR DIFFERENT FACTS (#2313) ───────────────────
#
# MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA above was emitted by FOUR branches of
# the hydrate_browsing block: the already-done skip, a run that sent nothing,
# a run that printed nothing, and a missing export file. Measured on
# macmini16-walk 2026-09-23, install.log line 1246, that sentence was printed
# over 8,831 visits the reader had already found and logged at line 497. The
# customer was told they have no browsing history. They have eight thousand
# pages of it.
#
# A message emitted by several branches cannot tell you which one fired, which
# is why the skip, the empty run and the absent export now each own a line.
# NO_DATA above is reserved for its literal meaning: the run happened and the
# customer's history is genuinely empty.
#
# Privacy unchanged: counts only, no URLs, titles or domains.
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="Dein Browserverlauf ist bereits importiert (%s Seiten). Nichts erneut zu importieren."
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="Kein exportierter Browserverlauf zum Importieren gefunden. Du kannst es später in den Einstellungen erneut starten."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="Dein Browserverlauf wurde schon einmal importiert, aber dein Suchindex enthält ihn nicht mehr. Er wird erneut importiert."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="Es konnte nicht geprüft werden, ob dein Browserverlauf noch in deinem Suchindex ist. Er wird erneut importiert, statt anzunehmen, dass er vorhanden ist."
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="Dein Browserverlauf hat deinen Suchindex nicht erreicht, deshalb bleibt deine Seite „Browsing“ leer. Starte den Vorgang in den Einstellungen erneut oder öffne Doctor."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="Der Browserverlauf wird noch im Hintergrund geladen. Dein Wiki füllt sich nach und nach und zeigt dir, wie weit es ist."

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="Deine E-Mail-Präferenzen werden geladen. Die Daten bleiben auf diesem Mac, und das kann einige Minuten dauern."
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="%s Präferenzen aus deinem E-Mail-Verlauf geladen"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="Keine Datei mit E-Mail-Präferenzen konfiguriert. Nichts zu laden."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="Keine Datei mit E-Mail-Präferenzen unter %s gefunden. Nichts zu laden."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="Die Präferenz-Pipeline ist noch nicht bereit. Du kannst es später in den Einstellungen erneut starten."
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="Deine E-Mail-Präferenzen werden noch im Hintergrund geladen. Dein Wiki füllt sich nach und nach und zeigt dir, wie weit es ist."
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  Deine E-Mail-Präferenzen werden noch geladen (bisher %ss). Ein großer Verlauf kann einige Minuten dauern."

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="Deine E-Mail-Präferenzen sind bereits geladen (%s Einträge). Es gibt nichts neu zu laden."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="Deine E-Mail-Präferenzen wurden zuvor geladen, aber dein Suchindex enthält sie nicht mehr. Sie werden erneut geladen."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="Es konnte nicht geprüft werden, ob deine E-Mail-Präferenzen noch in deinem Suchindex sind. Sie werden erneut geladen, statt anzunehmen, dass sie vorhanden sind."

# Preferences import counts-only confirmation, shown by phase 3.12b after
# the shared ostler-import fan-out runs. The other hydrate_preferences
# strings were removed when the standalone block was collapsed into the
# shared importer; only this done-count line is still referenced.
# Privacy: enrich's lookup clients call PUBLIC item-metadata APIs only
# (about the item, never the user); this string is a count.
# This said "Imported and enriched %s preferences" and the number it
# printed was the INGEST count. On the 2026-08-17 install it read 2,963
# while enrichment's own successful count for the same run was 1. Two
# separate facts, one of them borrowed the other's number. Now each is
# counted at its own source and stated separately.
MSG_HYDRATE_PREFERENCES_DONE="%s Präferenzen importiert"
MSG_HYDRATE_PREFERENCES_ENRICHED="%s davon mit öffentlichen Referenzdaten angereichert"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="%s Präferenzen importiert, aber keine wurde Essen, Musik oder Beruf zugeordnet. Deine Wiki-Seiten für Essen und Musik bleiben leer."
MSG_WARN_PREFS_HEADLINE_HINT="Das bedeutet meist, dass kein Musik- oder Essensexport (Spotify, Apple Music, Uber Eats, Google Takeout) vorhanden war oder die Daten nicht kategorisiert wurden. Füge diese Exporte hinzu, führe den Vorgang in den Einstellungen erneut aus und erstelle das Wiki dann neu."
MSG_WARN_PREFS_UNCATEGORISED="%s von %s Präferenzen (%s%%) haben keine Kategorie und erscheinen auf keiner Themenseite. Prüfe das Format des Quellexports."

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="Präferenzanreicherung wird eingerichtet"
MSG_CM019_SETUP_DONE="Präferenzanreicherung ist bereit"
MSG_CM019_SETUP_FAILED="Die Einrichtung der Präferenzanreicherung wurde nicht abgeschlossen. Deine Präferenzseiten füllen sich, sobald das behoben ist. Der Rest von Ostler ist nicht betroffen."
MSG_CM019_SETUP_SKIPPED="Die Pipeline zur Präferenzanreicherung ist nicht enthalten und wird vorerst übersprungen."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="Dein iMessage-Verlauf wird gelesen – deine Nachrichten bleiben auf diesem Mac"
MSG_HYDRATE_IMESSAGE_DONE="%s Personen in deinem iMessage-Verlauf gefunden"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="Kein iMessage-Verlauf zum Lesen vorhanden. Du kannst den Vorgang später in den Einstellungen erneut ausführen."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="Der iMessage-Reader ist noch nicht bereit. Du kannst den Vorgang später in den Einstellungen erneut ausführen."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage wird noch im Hintergrund geladen. Dein Wiki füllt sich nach und nach und zeigt dir, wie weit es ist."
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  Dein iMessage-Verlauf wird noch gelesen (bisher %ss). Ein großer Nachrichtenverlauf kann mehrere Minuten dauern."

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="Deine iMessage-Kontakte sind bereits in deinem Personengraphen (%s Kennungen). Es gibt nichts neu zu lesen."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="Deine iMessage-Kontakte wurden zuvor gelesen, aber dein Personengraph enthält sie nicht mehr. Sie werden erneut gelesen."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="Es konnte nicht geprüft werden, ob deine iMessage-Kontakte noch in deinem Personengraphen sind. Sie werden erneut gelesen, statt anzunehmen, dass sie vorhanden sind."

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="Deine Apple Notizen werden gelesen - sie bleiben auf diesem Mac"
MSG_HYDRATE_APPLE_NOTES_DONE="%s Notizen zu deiner Wissensdatenbank hinzugefügt"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="Keine Apple Notizen zum Lesen vorhanden. Du kannst den Vorgang später in den Einstellungen erneut ausführen."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="Deine Apple Notizen sind bereits in deiner Wissensdatenbank. Wird übersprungen."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="Apple Notizen sind für die Wissenssuche ausgeschaltet. Du kannst sie in den Einstellungen einschalten."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="Der Wissensimporter ist noch nicht bereit. Du kannst den Vorgang später in den Einstellungen erneut ausführen."
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="Apple Notizen werden noch im Hintergrund geladen. Deine Wissensdatenbank füllt sich nach und nach und zeigt dir, wie weit sie ist."
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  Deine Apple Notizen werden noch gelesen (bisher %ss). Eine große Notizsammlung kann einige Minuten dauern."

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="Deine Apple Notizen sind bereits in deiner Wissensdatenbank (%s Einträge). Es gibt nichts neu zu lesen."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="Deine Apple Notizen wurden zuvor hinzugefügt, aber deine Wissensdatenbank enthält sie nicht mehr. Sie werden erneut hinzugefügt."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="Es konnte nicht geprüft werden, ob deine Apple Notizen noch in deiner Wissensdatenbank sind. Sie werden erneut hinzugefügt, statt anzunehmen, dass sie vorhanden sind."

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="Deine Erinnerungen werden gelesen - sie bleiben auf diesem Mac"
MSG_HYDRATE_REMINDERS_DONE="%s Erinnerungen zu deiner Wissensdatenbank hinzugefügt"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="Keine Erinnerungen zum Lesen vorhanden. Du kannst den Vorgang später in den Einstellungen erneut ausführen."
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="Deine Erinnerungen sind bereits in deiner Wissensdatenbank. Wird übersprungen."
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="Erinnerungen sind für die Wissenssuche ausgeschaltet. Du kannst sie in den Einstellungen einschalten."
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="Der Wissensimporter ist noch nicht bereit. Du kannst den Vorgang später in den Einstellungen erneut ausführen."
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="Erinnerungen werden noch im Hintergrund geladen. Deine Wissensbasis füllt sich nach und nach und zeigt dir, wie weit sie ist."
MSG_HYDRATE_REMINDERS_HEARTBEAT="  Deine Erinnerungen werden noch gelesen (bisher %s s). Eine große Erinnerungsliste kann einige Minuten dauern."

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="Deine Erinnerungen sind bereits in deiner Wissensbasis (%s Einträge). Es muss nichts erneut gelesen werden."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="Deine Erinnerungen wurden schon einmal hinzugefügt, aber deine Wissensbasis enthält sie nicht mehr. Sie werden erneut hinzugefügt."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="Es konnte nicht geprüft werden, ob deine Erinnerungen noch in deiner Wissensbasis sind. Sie werden erneut hinzugefügt, statt anzunehmen, dass sie vorhanden sind."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="Personen werden für die Suche indexiert"
MSG_HYDRATE_PEOPLE_DONE="%s Personen für die Suche indexiert"
MSG_HYDRATE_PEOPLE_PARTIAL="Bisher %s von %s Personen für die Suche indexiert. Die übrigen waren noch nicht durchsuchbar; Ostler versucht es automatisch erneut."
MSG_HYDRATE_PEOPLE_FAILED="Deine Personen konnten diesmal nicht für die Suche indexiert werden (der Graph-Speicher hat nicht geantwortet). Ostler versucht es automatisch erneut. Details: %s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="Noch keine Personen zu indexieren. Du kannst es später in den Einstellungen erneut starten."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="Der Personen-Indexer ist noch nicht bereit. Du kannst es später in den Einstellungen erneut starten."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="Deine Personen werden noch im Hintergrund indexiert. Die Suche füllt sich nach und nach, und das Wiki zeigt dir, wie weit sie ist."

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="Deine Personen sind bereits für die Suche indexiert (%s Personen). Es muss nichts erneut indexiert werden."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="Deine Personen wurden schon einmal indexiert, aber dein Suchindex enthält sie nicht mehr. Sie werden erneut indexiert."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="Es konnte nicht geprüft werden, ob deine Personen noch in deinem Suchindex sind. Sie werden erneut indexiert, statt anzunehmen, dass sie vorhanden sind."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="Drei Anfragen zum Ordnerzugriff folgen"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="Der Dialog der Command Line Tools ist vor diesem Fenster erschienen. Klicke darin auf „Installieren“ und komm dann hierher zurück (oder warte ein paar Sekunden, wir holen dieses Fenster wieder nach vorn). Die Tools werden im Hintergrund geladen, während du die Fragen unten weiter beantwortest; nichts hier ist blockiert."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="Berechtigung erforderlich: Automation für iMessage"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostler bittet jetzt macOS um die Erlaubnis, mit Messages.app zu kommunizieren. macOS zeigt ein Fenster mit dem Hinweis, dass „OstlerInstaller“ die Steuerung von „Nachrichten“ möchte. Klicke auf „Erlauben“, damit der Assistent in deinem Namen iMessages senden und empfangen kann. Ohne diese Berechtigung verlassen iMessage-Nachrichten den Mac stillschweigend nie. Das ist eine einmalige Freigabe; du kannst sie später unter Systemeinstellungen > Datenschutz & Sicherheit > Automation ändern."

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="Dein Wiederherstellungsschlüssel"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="Schreib ihn jetzt auf oder drucke ihn aus. Er ist dein einziger Weg zurück, wenn du dein Passwort verlierst UND dein Schlüsselbund nicht mehr zugänglich ist. Ostler kann ihn nicht für dich wiederherstellen – der Schlüssel verlässt diesen Mac nie und wird auf keinem Server gespeichert."
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="Ich habe ihn sicher aufbewahrt"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="In die Zwischenablage kopieren"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="Als PDF sichern..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="Drucken..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="Fortfahren"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Ostler-Wiederherstellungsschlüssel.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Ostler-Wiederherstellungsschlüssel"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="Wiederherstellungsschlüssel in die Zwischenablage kopiert"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="Wiederherstellungsschlüssel gesichert unter %s"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="iPhone koppeln"
MSG_INFO_PAIR_IPHONE_HELP="Öffne die Ostler-App auf deinem iPhone und scanne diesen QR-Code, um es mit diesem Hub zu verbinden. Du kannst auch später über das Einstellungsmenü des Hubs koppeln."
MSG_INFO_PAIR_IPHONE_FETCHING="Kopplungscode wird erstellt..."
MSG_INFO_PAIR_REFRESH="Code aktualisieren"
MSG_ERR_PAIR_FETCH_FAILED="Das Ostler-Gateway ist noch nicht erreichbar. Möglicherweise startet es noch – klicke auf „Aktualisieren“, um es erneut zu versuchen."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agent ist nicht im Installer enthalten. Der LaunchAgent für tägliche Briefings und WhatsApp-Keepalive wird nicht geladen."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Wiki-Recompile-Skripte sind nicht im Installer enthalten. Das Wiki wird nicht automatisch aktualisiert."

# F3 - legal package missing
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="Das Paket „legal“ ist nicht im Installer enthalten. Die Einwilligungsprüfungen für Artikel 9, WhatsApp und Sprache lösen einen ModuleNotFoundError aus, bis neu installiert wird."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s installiert unter %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s ist bereits installiert und bleibt unverändert"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Nicht unterstützte CPU-Architektur für die Google Workspace CLI; Funktionen für Gmail / Google Calendar sind eingeschränkt."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl ist nicht verfügbar; die Installation der Google Workspace CLI wurde übersprungen. Funktionen für Gmail / Google Calendar sind eingeschränkt."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="Die Google Workspace CLI konnte nicht von %s heruntergeladen werden"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="SHA256-Abweichung bei der Google Workspace CLI (erwartet: %s, erhalten: %s). Die Installation dieser Binärdatei wird abgebrochen."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="Das Archiv der Google Workspace CLI konnte nicht entpackt werden."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Die Google Workspace CLI wurde unter %s installiert, aber die Prüfung mit --version ist fehlgeschlagen."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="Kalenderbrücke für iCloud / CalDAV installiert unter %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="Die Kalenderbrücke für iCloud / CalDAV unter %s ist nicht ausführbar. Der Kalender liefert keine Termine."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh ist nicht im Installer enthalten. Der erneute Versuch der Geräteregistrierung beim nächsten Netzwerkzugang ist deaktiviert."

MSG_WARN_EMBED_DIMS_UNREADABLE="Die Einbettungsbreite konnte aus der Statusprüfung nicht gelesen werden. Das Gedächtnis ist auf 768 Dimensionen konfiguriert; wenn sich der Abruf seltsam verhält, prüfe das Einbettungsmodell."
MSG_FAIL_EMBED_DIMS="Das Einbettungsmodell hat Vektoren mit %s Dimensionen geliefert, Ostler ist aber auf %s konfiguriert. Das Gedächtnis würde Vektoren speichern, die nie zugeordnet werden können. Prüfe das Einbettungsmodell und führe die Installation erneut aus."

# ── Reboot self-heal: automatic login on boot (v1.0.11) ─────────────
# LOCALE PARITY (future de/fr/es/it catalogues): these keys are en-GB only.
# Re-translate the values below when a new locale catalogue is added; do NOT
# machine-translate the consent / FileVault copy -- it is legal-adjacent and
# must read naturally in the operator's language.
#
# WHAT THIS COPY MUST NOT DO. Automatic sign-in works by storing the
# customer's login password on their Mac at /etc/kcpassword, scrambled with a
# fixed, publicly documented byte pattern (the cipher literal is in install.sh,
# in _ostler_configure_reboot_autologin). That is obfuscation, not encryption,
# and it is reversible by anyone with an administrator account or with the disk
# in their hands. The step also runs ONLY when FileVault is off, so it writes a
# recoverable login password exclusively onto Macs with no disk encryption.
#
# Every string below is therefore held to one rule: no word that implies the
# password is protected. Banned: "keystore", "keychain", "vault", "encrypted",
# "secure", "safe". Say what happens instead.
#
# The only reassurance any of these strings is allowed to carry is the one that
# was verified end to end in the installer, and it is stated at exactly that
# scope: the password is not echoed as it is typed, and it does not reach
# ~/.ostler/logs/install.log. Nothing here claims anything about what macOS
# itself does with /etc/kcpassword afterwards, because that was not measured.
MSG_PROGRESS_REBOOT_SELFHEAL="Selbstheilung nach Neustart wird konfiguriert"
# NEEDS REVIEW: Verify Apple's exact German label for the Automatic login option in current macOS; security disclosure wording should be checked.
MSG_INFO_AUTOLOGIN_EXPLAIN="Ostler ist ein Hub, der immer eingeschaltet bleibt. Nach einem Stromausfall oder Neustart muss er also zurückkommen, ohne dass jemand am Rechner sitzt. Das funktioniert nur, wenn sich dieser Mac selbst anmeldet, und macOS kann sich nur selbst anmelden, wenn das Anmeldepasswort von %s auf diesem Mac gespeichert ist.

Das Speichern schwächt die Sicherheit dieses Mac. Das Passwort wird verschleiert, nicht verschlüsselt. Wer hier ein Administratorkonto nutzen kann oder die Festplatte ausbaut und woanders liest, kann daraus wieder dein Passwort machen. Du siehst genau, wo es gespeichert wird, bevor du etwas eingibst.

Wenn du Nein wählst, wird nichts gespeichert und nichts weiter geändert. Nach einem Stromausfall meldest du dich wie gewohnt an, und die Dienste von Ostler starten mit deiner Sitzung. Du kannst das später in Systemeinstellungen > Benutzer:innen & Gruppen > Automatische Anmeldung ändern."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_AUTOLOGIN_CONSENT="Anmeldepasswort auf diesem Mac speichern, damit er sich nach einem Neustart selbst anmelden kann? [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="Ostler schreibt dieses Passwort in eine Datei auf diesem Mac unter /etc/kcpassword. Dort wird es mit einem festen Muster verschleiert, das auf jedem Mac gleich und öffentlich dokumentiert ist. Das ist also keine Verschlüsselung und lässt sich rückgängig machen. Wer auf diesem Mac ein Administratorkonto nutzen kann oder die Festplatte ausbaut und woanders liest, kann diese Datei wieder in das Anmeldepasswort von %s umwandeln.

FileVault würde das verhindern, weil die Festplatte ohne das Startpasswort gar nicht gelesen werden kann. Aus demselben Grund verhindert FileVault auch die automatische Anmeldung. Deshalb bietet Ostler dies nur an, wenn FileVault ausgeschaltet ist.

Was der Installer selbst kontrolliert: Er zeigt das Passwort beim Tippen nicht an und schreibt es nicht in das Installationsprotokoll. Die verschleierte Datei ist die einzige Kopie, die der Installer erstellt.

Lass das Feld leer, um die automatische Anmeldung zu überspringen."
MSG_PROMPT_AUTOLOGIN_PASSWORD="Anmeldepasswort für %s"
MSG_OK_AUTOLOGIN_CONFIGURED="Die automatische Anmeldung ist für %s aktiviert, und dieses Anmeldepasswort liegt jetzt in verschleierter Form unter /etc/kcpassword auf diesem Mac. Nach einem Neustart meldet sich dieser Mac selbst an, und die Dienste von Ostler starten mit dieser Sitzung. Zum Rückgängigmachen schaltest du in Systemeinstellungen > Benutzer:innen & Gruppen die automatische Anmeldung aus."
MSG_INFO_AUTOLOGIN_ALREADY="Die automatische Anmeldung ist für %s bereits eingerichtet, daher ist dieses Anmeldepasswort schon unter /etc/kcpassword auf diesem Mac gespeichert. Beides bleibt unverändert. Zum Rückgängigmachen schaltest du in Systemeinstellungen > Benutzer:innen & Gruppen die automatische Anmeldung aus."
MSG_INFO_AUTOLOGIN_DECLINED="Die automatische Anmeldung wurde nicht aktiviert, und es wurde kein Passwort gespeichert. Nach einem Neustart oder Stromausfall meldest du dich wie gewohnt an, und die Dienste von Ostler starten mit deiner Sitzung."
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="Die Einrichtung der automatischen Anmeldung wird übersprungen: Hier gibt es keine Möglichkeit, nach einem Anmeldepasswort zu fragen, und es wurde nichts gespeichert. Du kannst die automatische Anmeldung später in Systemeinstellungen > Benutzer:innen & Gruppen einschalten, wenn dieser Mac nach einem Neustart unbeaufsichtigt wieder betriebsbereit sein soll. Dabei wird dein Anmeldepasswort verschleiert und umkehrbar auf dem Mac gespeichert. Informiere dich daher vorher darüber."
MSG_WARN_AUTOLOGIN_NO_PASSWORD="Es wurde kein Passwort eingegeben, daher wurde die automatische Anmeldung nicht aktiviert und nichts gespeichert. Wenn du sie später möchtest, schalte in Systemeinstellungen > Benutzer:innen & Gruppen die automatische Anmeldung ein."
MSG_WARN_AUTOLOGIN_FAILED="Die automatische Anmeldung konnte nicht aktiviert werden (%s). Es gibt keinen weiteren Versuch. Falls /etc/kcpassword auf diesem Mac existiert, enthält die Datei das Anmeldepasswort in verschleierter Form, obwohl die Funktion aus ist. Du kannst sie im Terminal entfernen mit: sudo rm /etc/kcpassword. Um es erneut zu versuchen, schalte in Systemeinstellungen > Benutzer:innen & Gruppen die automatische Anmeldung ein."
MSG_WARN_AUTOLOGIN_FILEVAULT="FileVault ist eingeschaltet, daher fragt dieser Mac beim Start nach einem Passwort, um die Festplatte zu entsperren, bevor sich jemand anmelden kann. Die automatische Anmeldung kann das nicht beantworten. Nach einem Stromausfall wartet dieser Mac deshalb auf dem FileVault-Entsperrbildschirm, bis jemand das Passwort eingibt. Die automatische Anmeldung wurde nicht aktiviert und es wurde kein Passwort gespeichert. Das ist die sicherere der beiden Varianten: Ein unbeaufsichtigter Neustart ist bei eingeschaltetem FileVault nicht möglich, dafür bleibt die Festplatte für alle unlesbar, die das Passwort nicht kennen."

# ── WALK-874 (2026-08-24, v1.0.44 upgrade walk, step 26/37) ──────────
# The Full Disk Access modal opened with "System Settings is open at
# Full Disk Access." It was NOT open -- Andy opened it himself. The pane
# open was fire-and-forget (`open ... 2>/dev/null || true`) and the
# sentence was printed regardless: the same shape as #876's
# `launchctl ... || true` followed by an unconditional success line.
#
# This is the line the modal shows when the pane could NOT be brought
# up. It ESTABLISHES the state instead of asserting it, and it does not
# pretend the installer did something it did not do.
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="Ostler konnte die Systemeinstellungen nicht für dich öffnen. Öffne die Systemeinstellungen bitte selbst und gehe zu Datenschutz & Sicherheit > Festplattenvollzugriff."
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="Ostler betreibt dein Wiki und die Suche in Containern und installiert und verwaltet deshalb eine Container-Engine (Colima) auf diesem Mac. Wenn diese Engine entfernt oder neu konfiguriert wird, funktionieren dein Wiki und die Suche nicht mehr – Ostler sagt dir Bescheid und versucht, sie neu zu starten."
MSG_INFO_ENGINE_ALREADY_PRESENT="Auf diesem Mac ist bereits eine Container-Engine installiert. Ostler verwendet sie, anstatt eine eigene zu installieren, und verwaltet oder ändert sie nicht."

