#!/usr/bin/env bash
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

# ── Step (top-level phase) banners ──

MSG_STEP_CHECKING_PREREQUISITES="Voraussetzungen werden geprüft"
MSG_STEP_RUNNING_HEALTH_CHECK="Funktionsprüfung läuft"
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="Setup (a few quick questions, then it keeps going on its own)"

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="und erneut ausführen: ostler-fda"
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="Sichtbare Apple Mail-Konten: %s (zur Information)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mail scheint noch keine lokalen Nachrichten zu enthalten. Doctor zeigt einen Hinweis an, falls innerhalb von 24 Stunden keine E-Mails eintreffen."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mail hat zwischengespeicherte Nachrichten. Die Erfassung übernimmt sie beim nächsten stündlichen Durchlauf."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="Apple Mail ist ausgewählt, aber auf diesem Mac sind noch keine lokalen Nachrichten zum Lesen vorhanden. Öffnen Sie Apple Mail und fügen Sie ein Konto hinzu (Systemeinstellungen > Internetaccounts, dann Mail aktivieren) und lassen Sie eine erste Synchronisierung abschließen."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="Sobald E-Mails eingetroffen sind, führen Sie erneut aus: ostler-fda. Ostler übernimmt sie automatisch; es ist nichts weiter nötig."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="Die Apple-Notarisierung wird beim ersten Start von Gatekeeper überprüft."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="verfügbar ist, überspringt der Installer diesen Schritt automatisch."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="Betatester mit Zugang können PWG_PIPELINE_REPO=<url> setzen und erneut ausführen."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="Betatester mit Zugang können PWG_KNOWLEDGE_REPO=<url> setzen und erneut ausführen."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="Browser-Erweiterungen übersprungen (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  Geklont nach %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture läuft nur auf Apple Silicon. Installation auf diesem Rechner wird übersprungen."
MSG_INFO_CM042_LOGS_AT="RemoteCapture-Protokolle: %s/ostler-remotecapture.log (und .err)"
MSG_INFO_CM042_TCC_PRE_PROMPT="Beim ersten Start fragt Ostler RemoteCapture macOS nach der Berechtigung für Bildschirmaufnahme und Mikrofon. Erteilen Sie beide, damit Anrufe und Besprechungen lokal transkribiert werden können. In Ihrer Menüleiste erscheint kein violetter Aufnahmehinweis – die Audioaufnahme erfolgt absichtlich unauffällig."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  Gesprächsgedächtnis-Engine im venv installiert."
MSG_INFO_HUB_APP_VERIFYING="Ostler.app wird unter %s überprüft"
MSG_INFO_HUB_APP_STAGING="Ostler.app wird aus %s nach /Applications kopiert"
MSG_INFO_HUB_APP_DRAG_HINT="Öffnen Sie das Installer-DMG und ziehen Sie sowohl Ostler.app als auch OstlerInstaller.app auf das Applications-Symbol, und führen Sie den Installer dann erneut aus."
MSG_OK_HUB_APP_PRESENT="Ostler.app ist bereits unter %s vorhanden; Signatur überprüft."
MSG_OK_HUB_APP_STAGED="Ostler.app installiert unter %s"
MSG_WARN_HUB_APP_NOT_FOUND="Ostler.app wurde nicht in /Applications gefunden und es ist keine mitgelieferte Kopie verfügbar."
MSG_WARN_HUB_APP_VERIFY_FAILED="Die Signatur- oder Notarisierungsprüfung von Ostler.app ist fehlgeschlagen. Das Bundle bleibt an Ort und Stelle, damit der Support es untersuchen kann."
MSG_INFO_CLONING_DOCTOR_AGENT="Doctor-Agent wird geklont..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="E-Mail-Erfassungsskripte werden geklont..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Hub-Power-Skripte werden geklont..."
MSG_INFO_CLONING_IMPORT_PIPELINE="Import-Pipeline wird geklont..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="Wiki-Neukompilierungsskripte werden geklont..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima ist installiert, läuft aber nicht. Es wird gestartet."
MSG_INFO_COLIMA_START_ATTEMPT="Colima wird gestartet (Versuch %s von %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="Kontakte konnten nicht exportiert werden. Sie können sie später manuell importieren."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="Kontaktkarte konnte nicht gelesen werden. Kein Problem – wir fragen stattdessen nach."
MSG_INFO_CONTACT_CARD_WILL_ASK="Wir fragen Sie gleich nach Ihrem Namen und Land. Ihre Kontakte werden später über den von Ihnen erteilten Vollzugriff auf die Festplatte gelesen, und nichts verlässt diesen Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  Python-venv wird unter %s erstellt..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="Nutzersichtbarer Inhaltsbaum wird unter %s/ erstellt"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="Täglicher Durchlauf. Manuell ausführen: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="Desktop-Hub (kein Akku) erkannt: Ruhezustand wird systemweit deaktiviert"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker ist nicht installiert. Colima + Docker CLI + docker-compose-Plugin werden installiert (leichtgewichtig, kein Docker Desktop erforderlich)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="Doctor-Agent-Dateien sind nicht im Installer enthalten."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="E-Mail-Erfassungsskripte sind nicht im Installer enthalten."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="Die E-Mail-Erfassungsskripte fehlen im Installer-Bundle. Laden Sie die .app erneut von ostler.ai/install herunter und versuchen Sie es noch einmal."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="E-Mail-Erfassungsskripte sind nicht enthalten und --allow-plaintext wurde übergeben; die Installation des LaunchAgent wird übersprungen. Künftige E-Mails werden nicht abgerufen."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  Vorhandener Checkout unter %s; wird aktualisiert..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Gmail-mbox wird aus dem Takeout-Zip extrahiert (bei großen Archiven kann das eine Minute dauern)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="FDA-Extraktionsmodul nicht enthalten. Sofortige Datenextraktion wird übersprungen."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Ihre ersten 30 Tage Ostler Pro werden aktiviert..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Ostler Pro kostet nach der Testphase \$9.99 USD pro Monat. Abonnieren Sie über die iOS-Companion-App."
MSG_INFO_FOUND_GMAIL_MBOX_MB="Gmail-mbox gefunden unter %s (%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Google-Takeout-Zip gefunden unter %s (%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="Vollzugriff auf die Festplatte erkannt – vollständige Extraktion verfügbar."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="DSGVO-Exporte erkannt, aber die Import-Pipeline ist noch nicht verfügbar."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="Der DSGVO-Export-Import wird verfügbar, sobald die Pipeline ausgeliefert wird."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="Es werden gleich Downloads, Schreibtisch und Dokumente nach KI-Exporten (Google Takeout, Meta-Downloads, LinkedIn usw.) durchsucht, die Sie möglicherweise gespeichert haben. macOS zeigt drei Ordnerzugriffs-Abfragen an – bitte erlauben Sie jede einzelne. Insgesamt dauert es etwa 5-10 Sekunden. Während des Scans wird nichts verschoben oder kopiert; wir prüfen nur, was vorhanden ist."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS fragt möglicherweise nach der Berechtigung, Ihren Kalender zu lesen. Erlauben Sie es, damit Ostler den Besprechungs- und Termin-Teil Ihres Wissensgraphen aufbauen kann. (Kalenderdaten bleiben auf diesem Rechner.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS fragt nach der Berechtigung für Downloads. Klicken Sie auf OK."
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS fragt nach der Berechtigung für den Schreibtisch. Klicken Sie auf OK."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS fragt nach der Berechtigung für Dokumente. Klicken Sie auf OK."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="Vollzugriff auf die Festplatte erteilt. Die nächste macOS-Abfrage wird vorbereitet (Messages-Automatisierung)..."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="Die Xcode Command Line Tools werden benötigt. macOS fragt nach der Berechtigung zur Installation – achten Sie auf einen kleinen grauen Dialog (falls Sie ihn nicht sehen, drücken Sie Cmd+Tab oder schauen Sie im Dock nach). Klicken Sie auf Installieren. Die Tools werden im Hintergrund heruntergeladen, während Sie die folgenden Fragen beantworten."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  Command Line Tools werden noch eingerichtet (%ss). Falls ein kleiner grauer macOS-Dialog fragt, ob Entwicklertools installiert werden sollen, klicken Sie dort auf Installieren – dieser Schritt wartet darauf. (Cmd+Tab oder ein Blick ins Dock, falls Sie ihn nicht sehen.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="Es wird gewartet, bis die Command Line Tools fertig installiert sind (fast geschafft)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="Stündlicher Durchlauf. Der erste Durchlauf holt die E-Mails der letzten 5 Jahre."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="Veralteter iMessage-Bridge-LaunchAgent wird deaktiviert (Einzelmaschinen-v1.0)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Reiner Netzbetrieb-Hub (kein Akku erkannt), Hub-Power-LaunchAgent wird übersprungen."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Hub-Power-Skripte sind nicht im Installer enthalten."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="Assistant-API im Installer enthalten; mitgelieferte Quelle wird verwendet."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="Assistant-API-Quelle nicht enthalten; die iOS-Companion-Endpunkte sind eingeschränkt."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Wenn das Tailscale-Fenster erscheint, melden Sie sich mit Apple / Google / Microsoft an."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="Tailscale wird geöffnet, damit Sie sich anmelden können..."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale übersprungen – der iOS-Companion funktioniert nur in Ihrem Heim-WLAN. Sie können dies später in den Einstellungen einrichten."
MSG_INFO_TAILSCALE_STILL_WAITING="Es wird weiterhin auf die Tailscale-Anmeldung gewartet (%ss vergangen) – bitte schließen Sie die Anmeldung im Tailscale-Fenster ab."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="Vollzugriff auf die Festplatte erteilt; der Assistent wird neu gestartet, um die neue Berechtigung zu übernehmen."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="Systemeinstellungen + Finder werden geöffnet, um Sie durch die Erteilung des Vollzugriffs auf die Festplatte für den Assistenten zu führen..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="Der Vollzugriff auf die Festplatte steht noch aus. Das Doctor-Dashboard zeigt die Karte weiterhin an, bis der Zugriff erteilt ist."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant hat bereits Vollzugriff auf die Festplatte; es ist nichts weiter nötig."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Es wird geprüft, ob der Ostler-Assistent Ihren Messages-Verlauf lesen kann..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="Der Assistent kann den Messages-Verlauf lesen; der iMessage-Kanal funktioniert."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="Der Assistent kann den Messages-Verlauf noch nicht lesen. Das Doctor-Dashboard zeigt eine Karte an, die Sie durch die Systemeinstellungen führt."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="Der Assistent-LaunchAgent wurde nicht geladen; die iMessage-Prüfung des Vollzugriffs auf die Festplatte wird übersprungen."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="Die Evernote-Import-Oberfläche in Doctor zeigt 'Dienst nicht verfügbar' an"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Import-Pipeline ist nicht im Installer enthalten."
MSG_INFO_INSTALLING_CM042="Ostler RemoteCapture v%s wird installiert (Anruf- + Besprechungstranskription)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="Gesprächsgedächtnis-Engine wird aus %s installiert..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  Gesprächsgedächtnis-Engine wird ins venv installiert..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="Colima + Docker CLI werden installiert..."
MSG_INFO_INSTALLING_HOMEBREW="Homebrew wird installiert..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="Knowledge-Dienst wird aus %s installiert..."
MSG_INFO_INSTALLING_OLLAMA="Ollama wird installiert..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Der Apple Mail-Leser wird in ein eigenes venv installiert..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  ostler-knowledge wird ins venv installiert..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Safari-Erweiterung wird in /Applications installiert"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="Python-Abhängigkeiten für die Sicherheit werden installiert..."
MSG_INFO_INSTALLING_SQLCIPHER="SQLCipher wird installiert..."
MSG_INFO_INSTALLING_TAILSCALE="Tailscale wird installiert..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="Intel-Unterstützung ist nicht auf der Roadmap; reichen Sie bei Bedarf eine Anfrage ein."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Knowledge-Dienst im Installer enthalten; mitgelieferte Quelle wird verwendet."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Knowledge-Dienst nicht installiert: PWG_KNOWLEDGE_REPO ist leer."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="später unter Systemeinstellungen > Datenschutz & Sicherheit > Vollzugriff auf die Festplatte"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  starten, um die Cron-Zustellung + iMessage-TCC-Status zu überprüfen)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="Lizenz: %s steht unter Apache 2.0. Vollständiger Text: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Lizenz: %s – prüfen Sie vor kommerzieller Nutzung die Upstream-Bedingungen."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="lokaler Speicher – Google erfährt nie, dass Ostler existiert."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="Protokolle: %s/email-ingest.log (und .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="Protokolle: %s/ostler-assistant.log (und .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="Protokolle: %s/wiki-recompile.log (und .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="MacBook-Hubs: PWG_HUB_POWER_REPO=<url> setzen und erneut ausführen."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="MacBook-Hub erkannt: Kein-Ruhezustand nur im Netzbetrieb wird gesetzt (Hub-Power übernimmt die Akku-Übergänge)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Mac Mini / Studio-Installationen sind nicht betroffen (immer im Netzbetrieb)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Mac-seitige Daten (iMessage, Safari usw.) wurden oben extrahiert."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="Manueller Neustart: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="Manuell ausführen: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="Installation von com.ostler.meeting-brief-sender wird übersprungen (v1.0.1-Funktion; Endpunkte noch nicht ausgeliefert)."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="Nachricht, wenn das Feature-Flag später aktiviert wird."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="Brauchen Sie Hilfe? Schreiben Sie an support@ostler.ai. Wir antworten in der Regel innerhalb von 2 Werktagen."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="Keine Kanäle konfiguriert. Später ausführen: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="Derzeit sind keine FDA-Quellen verfügbar. Sie können den Vollzugriff auf die Festplatte erteilen"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="Keine DSGVO-Exporte in Downloads, Schreibtisch oder Dokumenten gefunden."
MSG_INFO_OPENING_CHROME_WEB_STORE="Chrome Web Store wird geöffnet: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="ostler-assistant-Binärdatei nicht installiert; Doctor-Prüfung wird übersprungen"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: aufgeschoben (Daemon startet möglicherweise noch"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="Es wird die in diesem DMG enthaltene ostler-assistant-Binärdatei verwendet (offline-fähiger Installationspfad)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge im venv installiert."
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler zeigt vor der Installation einen zusätzlichen Einwilligungsbildschirm an"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  Überschreiben Sie das Quell-Repo für die Gesprächsgedächtnis-Engine über die in ./install.sh --help dokumentierte Umgebungsvariable."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  Überschreiben Sie das Quell-Repo mit PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  Überschreiben Sie das Quell-Repo mit PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  Überschreiben Sie das Quell-Repo mit PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  Überschreiben Sie das Quell-Repo mit PWG_PIPELINE_REPO=<url> ./install.sh"
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Einwilligungsnachweise und Region werden gespeichert..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="Phase-3-Akkuüberwachung aktiviert (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="Ihr Adressbuch wird gelesen (bei großen Beständen kann das ein paar Minuten dauern – bitte schließen Sie den Installer nicht)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="Richtlinien-Überschreibung: ~/.ostler/power.conf bearbeiten (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="iMessage-Automatisierungsberechtigung wird geprüft (schreibgeschützt)..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="nomic-embed-text wird geladen (274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="%s wird geladen (%s)... dies kann einige Minuten dauern."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="Quarantäne-xattr entfernt. Sobald der Developer-ID-Build"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Safari, iMessage, Notizen, Kalender, Fotos, Erinnerungen, Mail werden gelesen..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="Ihre Kontaktkarte wird gelesen, um Ihre Angaben vorauszufüllen..."
MSG_INFO_REGION_EU_EEA_SOURCE="Region: EU/EWR (%s, Quelle: %s)"
MSG_INFO_REGION_SOURCE="Region: %s (Quelle: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="Region: Vereinigtes Königreich (Quelle: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="Region: Vereinigte Staaten (Quelle: %s)"
MSG_INFO_REPO_URL="Repo-URL: %s"
MSG_INFO_REPO_URL_2="Repo-URL: %s"
MSG_INFO_REPO_URL_3="Repo-URL: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="Wählen Sie nun die Passphrase, mit der Ihr Hub entsperrt wird. Sie geben sie bei jedem Start der Hub-Oberfläche ein."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="Wiederherstellungs-Passphrase übersprungen. (Veraltet: v1.0 erfordert immer eine Passphrase.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="Vorhandene Doctor-Agent-Installation unter %s wird wiederverwendet"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="Vorhandene E-Mail-Erfassungs-Installation unter %s wird wiederverwendet"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="Vorhandene Hub-Power-Installation unter %s wird wiederverwendet"
MSG_INFO_REUSING_EXISTING_JWT_SECRET="Vorhandenes JWT_SECRET in %s wird wiederverwendet"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="Vorhandenes PWG-Dienst-Token unter %s wird wiederverwendet"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="Vorhandene Wiki-Neukompilierungs-Installation unter %s wird wiederverwendet"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="Safari-Erweiterungs-Bundle in diesem Installer-Build nicht vorhanden (wird übersprungen)"
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="Es wird nach DSGVO-Datenexporten gesucht..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="Setzen Sie PWG_DOCTOR_REPO=<url> und führen Sie zur Installation erneut aus."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="Setzen Sie PWG_HUB_POWER_REPO=<HR015-url> und führen Sie zur Installation erneut aus."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="Gesprächsmodell übersprungen. Später laden: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Colima wird gestartet (leichtgewichtige Docker-Laufzeit)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Docker Desktop wird gestartet..."
MSG_INFO_STARTING_OLLAMA="Ollama wird gestartet..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="Die veraltete Ollama-Formel (ohne llama-server) wird entfernt; es wird zur Ollama-App gewechselt..."
MSG_INFO_VERIFYING_EMBEDDINGS="Es wird geprüft, ob die Embedding-Engine Vektoren zurückgibt..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="Ollama konnte nicht automatisch gestartet werden. Laden Sie es mit: launchctl bootstrap gui/\$(id -u) %s -- und führen Sie den Installer dann erneut aus."
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  startet; führen Sie \`ostler-assistant doctor\` nach dem ersten"
MSG_INFO_SYMLINKING="  Symlink wird erstellt %s -> %s"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(Systemeinstellungen > Internetaccounts). Ostler liest aus Mails"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(Der Rest von Ostler läuft ohne das Doctor-Dashboard.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="Das ist derzeit zu erwarten. Der DSGVO-Import wird in einem künftigen Update verfügbar sein."
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="This usually takes 15 to 45 minutes, and can run longer if you have a lot of history or a slower Mac. That is normal – it is working, not stuck, so feel free to leave it running..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="Dies liest die macOS-Datenbanken direkt – kein Export erforderlich."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="Tipp: Um Ihr Gmail einzubeziehen, fügen Sie es zuerst zu Mac Mail hinzu"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="So installieren Sie es später, sobald Sie Zugang haben:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="iCloud-Synchronisierung für %s wird ausgelöst (unauffällig, nur beim ersten Durchlauf)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (UK GDPR Artikel 9 - erforderlich für besondere Kategorien von Daten)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="Vorhandene Pipeline wird aktualisiert..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="Nutzersichtbarer Baum wurde bereits angekündigt (Sentinel vorhanden); wird übersprungen"
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane antwortet nicht (optional; siehe Warnungen in Phase 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="Jederzeit ansehen mit: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="Die Stimmerkennung bleibt aus. Sie können sie später in den Einstellungen aktivieren."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="Es wird auf Ihre Anmeldung bei Tailscale gewartet (bis zu 3 Minuten)..."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="WhatsApp-Connector bleibt aus. Sie können ihn später über die Einstellungen aktivieren."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="WhatsApp-Keepalive geplant um 08:50 + 17:50 (Label com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="Wiki-Aufholung am ersten Tag wird übersprungen: Der Wiki-Neukompilierungs-Durchlauf ist nicht installiert. Der tägliche Wiki-Neuaufbau läuft, falls installiert, dennoch."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Wiki-Neukompilierungsskripte sind nicht im Installer enthalten."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="Das Wiki wird nicht automatisch aktualisiert; Sie können die Erstkompilierung manuell erneut ausführen:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="Status-Marker geschrieben: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="Ihre Exporte sind sicher. Importieren Sie sie später mit: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="Ihre Mac-Daten (iMessage, Safari usw.) wurden bereits oben extrahiert."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="Sie können es später für ein sofortiges Onboarding aus Safari, iMessage usw. hinzufügen."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="KI-Modell: %s (%s) – ausgewählt für Ihre %s GB RAM"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="Alle Quellen ausgewählt (Gesichtserkennung weiterhin aus)"
MSG_OK_ALREADY_AVAILABLE="%s bereits verfügbar"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon erkannt"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="Apps gestartet, um die iCloud-Synchronisierung auszulösen"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="App-Datenbanken bereits vorhanden (Vorstart wird übersprungen)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="Assistent-Konfiguration gespeichert unter %s (Modus 0600)"
MSG_OK_BACKED_UP_CONTACTS="%s Kontakte gesichert nach %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s installiert unter %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="Ostler RemoteCapture-LaunchAgent geladen (Label %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima und Docker CLI installiert"
MSG_OK_COLIMA_WILL_START_AUTOMATICALLY_BOOT="Colima startet beim Hochfahren automatisch"
MSG_OK_CONFIG_SAVED_ENV="Konfiguration gespeichert unter %s/.env"
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Einwilligungsnachweise und Region gespeichert unter ~/.ostler/posture/"
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="Datenbanken verschlüsselt. Bei jedem Start ist die Passphrase erforderlich."
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="Aufgeschobener Geräteregistrierungs-Wiederholungsversuch installiert (läuft stündlich, bis die Warteschlange leer ist)"
MSG_OK_DOCKER_RUNNING="Docker läuft"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker läuft (dauerte %ss)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Doctor-Agent geklont von %s"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Doctor-Agent-Dateien im Installer enthalten"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Doctor-Abhängigkeiten installiert"
MSG_OK_EMAIL_CHANNEL_FOLDER="E-Mail-Kanal: %s (Ordner: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="E-Mail-Erfassungs-LaunchAgent geladen (Label com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="E-Mail-Erfassungsskripte im Installer enthalten"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="E-Mail-Erfassungsskripte geklont von %s"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="WhatsApp-Gesprächsgedächtnis wird eingerichtet"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  WhatsApp-Gesprächsleser installiert."
MSG_WARN_WHATSAPP_SOURCE_FAILED="Installation des WhatsApp-Gesprächslesers fehlgeschlagen; der WhatsApp-Gesprächsfeed läuft nicht. Siehe Ausgabe oben."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="Quelle des WhatsApp-Gesprächslesers nicht gefunden; der WhatsApp-Gesprächsfeed wird übersprungen."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="WhatsApp-Gesprächsfeed-Paket in diesem Installer nicht gefunden; wird übersprungen. Der WhatsApp-Nachrichtenverlauf (wem Sie wann geschrieben haben) ist nicht betroffen."
MSG_OK_WHATSAPP_BUNDLE_LOADED="WhatsApp-Gesprächsfeed-LaunchAgent geladen (Label com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  Der erste Durchlauf liest die jüngsten WhatsApp-Gespräche, die Ihr Mac synchronisiert hat (etwa das letzte Jahr); sie bleiben auf Ihrem Mac."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  Protokolle: %s/whatsapp-bundle.log und whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="Installation des WhatsApp-Gesprächsfeed-LaunchAgent fehlgeschlagen. Siehe Ausgabe oben; der Rest der Installation ist nicht betroffen."
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="E-Mail-Gesprächsgedächtnis wird eingerichtet"
MSG_OK_EMAIL_SOURCE_INSTALLED="  E-Mail-Gesprächsleser installiert."
MSG_WARN_EMAIL_SOURCE_FAILED="Installation des E-Mail-Gesprächslesers fehlgeschlagen; der E-Mail-Gesprächsfeed läuft nicht. Siehe Ausgabe oben."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="Quelle des E-Mail-Gesprächslesers nicht gefunden; der E-Mail-Gesprächsfeed wird übersprungen."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="E-Mail-Gesprächsfeed-Paket in diesem Installer nicht gefunden; wird übersprungen. Die stündliche E-Mail-Erfassung ist nicht betroffen."
MSG_OK_EMAIL_BUNDLE_LOADED="E-Mail-Gesprächsfeed-LaunchAgent geladen (Label com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Liest Ihre jüngsten E-Mail-Threads aus dem lokalen Speicher von Apple Mail; alles bleibt auf Ihrem Mac."
MSG_INFO_EMAIL_BUNDLE_LOGS="  Protokolle: %s/email-bundle.log und email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="Installation des E-Mail-Gesprächsfeed-LaunchAgent fehlgeschlagen. Siehe Ausgabe oben; der Rest der Installation ist nicht betroffen."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="Besprechungs- und Sprach-Gesprächsgedächtnis wird eingerichtet"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  Besprechungs- und Sprach-Gesprächsleser installiert."
MSG_WARN_SPOKEN_SOURCE_FAILED="Installation des Besprechungs- und Sprach-Gesprächslesers fehlgeschlagen; der Feed läuft nicht. Siehe Ausgabe oben."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="Quelle des Besprechungs- und Sprach-Gesprächslesers nicht gefunden; der Feed wird übersprungen."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="Besprechungs- und Sprach-Gesprächsfeed-Paket in diesem Installer nicht gefunden; wird übersprungen."
MSG_OK_SPOKEN_BUNDLE_LOADED="Besprechungs- und Sprach-Gesprächsfeed-LaunchAgent geladen (Label com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  Macht aus Ihren eigenen aufgezeichneten Besprechungen und Sprachnotizen durchsuchbare Gespräche; alles bleibt auf Ihrem Mac."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  Protokolle: %s/spoken-bundle.log und spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="Installation des Besprechungs- und Sprach-Gesprächsfeed-LaunchAgent fehlgeschlagen. Siehe Ausgabe oben; der Rest der Installation ist nicht betroffen."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="iMessage-Gesprächsgedächtnis wird eingerichtet"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  iMessage-Gesprächsleser installiert."
MSG_WARN_IMESSAGE_SOURCE_FAILED="Installation des iMessage-Gesprächslesers fehlgeschlagen; der iMessage-Gesprächsfeed läuft nicht. Siehe Ausgabe oben."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="Quelle des iMessage-Gesprächslesers nicht gefunden; der iMessage-Gesprächsfeed wird übersprungen."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="iMessage-Gesprächsfeed-Paket in diesem Installer nicht gefunden; wird übersprungen."
MSG_OK_IMESSAGE_BUNDLE_LOADED="iMessage-Gesprächsfeed-LaunchAgent geladen (Label com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  Liest Ihre jüngsten iMessage-Gespräche aus dem Messages-Speicher dieses Macs; alles bleibt auf Ihrem Mac."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  Protokolle: %s/imessage-bundle.log und imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="Installation des iMessage-Gesprächsfeed-LaunchAgent fehlgeschlagen. Siehe Ausgabe oben; der Rest der Installation ist nicht betroffen."
MSG_OK_EMBEDDING_MODEL_READY="Embedding-Modell bereit"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="%s Kontakte exportiert (werden automatisch importiert)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="Export-Überwachung installiert (durchsucht Downloads alle 4 Stunden)"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="Versand von Besprechungs-Briefings installiert (prüft alle 10 Minuten während der Wachzeiten)"
MSG_OK_EXTRACTED="Extrahiert nach %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="Aus %s Quelle(n) extrahiert. Daten gespeichert unter %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_12_HOURS="FDA-Wiederholung in ca. 12 Stunden geplant (erfasst langsame iCloud-Synchronisierungen)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro für 30 Tage aktiv. Abonnieren Sie über die iOS-Companion-App, um es nach der Testphase zu verlängern."
MSG_OK_FOUND="Gefunden: %s"
MSG_OK_FOUND_EXPORTS="Exporte gefunden unter %s"
MSG_OK_FOUND_GDPR_EXPORT_S="%s DSGVO-Export(e) gefunden:"
MSG_OK_GB_FREE_DISK_SPACE="%s GB freier Speicherplatz"
MSG_OK_GB_RAM_DETECTED="%s GB RAM erkannt"
MSG_OK_GDPR_IMPORT_COMPLETE="DSGVO-Import abgeschlossen"
MSG_OK_GIT_AVAILABLE="Git verfügbar"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="Installation der Command Line Tools ausgelöst (wird im Hintergrund heruntergeladen, während Sie die folgenden Fragen beantworten)."
MSG_OK_HOMEBREW_INSTALLED="Homebrew installiert"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="Hub-Power-LaunchAgent geladen (Label com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Hub-Power-Skripte im Installer enthalten"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Hub-Power-Skripte geklont von %s"
MSG_OK_ICAL_SERVER_INSTALLED="Assistant-API installiert (Loopback 127.0.0.1:8090, über Doctor weitergeleitet)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage-Automatisierungsberechtigung: erteilt"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="iMessage-Bridge-LaunchAgent geladen (Label com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="iMessage-Bridge-Skripte im Installer enthalten"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="iMessage-Bridge-Skripte geklont von %s"
MSG_OK_IMESSAGE_CHANNEL="iMessage-Kanal: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="Import-Pipeline im Installer enthalten"
MSG_OK_IMPORT_PIPELINE_READY="Import-Pipeline bereit"
MSG_OK_CM048_PIPELINE_READY="Gesprächsgedächtnis-Engine bereit."
MSG_INFO_CM048_SETTINGS_WRITTEN="  Gesprächsmodelle auf %s gesetzt (passend zu Ihren %s GB Arbeitsspeicher)"
MSG_INFO_CM048_SETTINGS_KEPT="  Ihre vorhandenen Gesprächseinstellungen werden beibehalten (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="Knowledge-Dienst bereit: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="Lizenztexte installiert unter %s/ (Quelle: %s)"
MSG_OK_MACOS_DETECTED="macOS %s erkannt"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="Systemeinstellungen > Internetaccounts werden geöffnet, damit Sie ein Mail-Konto hinzufügen können. Kehren Sie zu diesem Fenster zurück, sobald Sie sich bei Ihrem ersten Konto angemeldet haben."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="Der Schritt Internetaccounts wird übersprungen. Sie können später in den Systemeinstellungen ein Mail-Konto hinzufügen; Doctor zeigt einen Hinweis an, falls innerhalb von 24 Stunden keine E-Mails eintreffen."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Ihr vollständiger Apple Mail-Verlauf wird jetzt geholt. Bei einem großen Postfach kann das etwas länger dauern."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="Das Standard-Fenster von fünf Jahren E-Mail wird beibehalten. Sie können später mehr über Doctor holen."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text bereits verfügbar"
MSG_OK_OLLAMA_HEALTHY="Ollama funktionsfähig"
MSG_OK_OLLAMA_INSTALLED="Ollama installiert"
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama installiert (nur CLI – nach einem Neustart eventuell manueller Start nötig)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama installiert (Desktop-App)"
MSG_OK_OLLAMA_RUNNING="Ollama läuft"
MSG_OK_EMBEDDINGS_VERIFIED="Embedding-Engine überprüft (768-dimensionale Vektoren)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: keine Fehler erkannt"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="Ostler-Assistent-LaunchAgent geladen (Label com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s bereitgestellt unter %s (signiert)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s bereitgestellt unter %s (unsigniert)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor läuft unter http://localhost:8089/doctor"
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Apple Mail-Leser installiert."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  E-Mail-Erfassungs-Engine installiert."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="Befehle ostler-import, ostler-fda und ostler-uninstall installiert"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph funktionsfähig"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="Passphrase notiert. Sie verschlüsselt Ihre Datenbanken in Phase 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="Wiederherstellungs-Passphrase konfiguriert."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="Passphrase-Hinweis bestätigt."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="Stromquelle: Netzbetrieb (Desktop-Mac, kein Akku)"
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="Power source: AC (good – the install can run 30 to 60 minutes or more, so mains power keeps it steady)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="Frühere Installation erkannt. Konfiguration wird geladen..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="Es wird das mitgelieferte Python %s verwendet (keine Systeminstallation nötig)"
MSG_OK_PYTHON_INSTALLED="Python %s installiert"
MSG_OK_QDRANT_HEALTHY="Qdrant funktionsfähig"
MSG_OK_READY="%s bereit"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="Empfohlene Quellen ausgewählt"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="Wiederherstellungsschlüssel im Schlüsselbund gespeichert (in der Passwörter-App nach 'Ostler' suchen)"
MSG_OK_REDIS_HEALTHY="Redis funktionsfähig"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Safari-Erweiterung installiert unter %s"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="Sicherheit wurde bereits bei einem früheren Durchlauf konfiguriert."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="Sicherheitsmodul ins venv installiert"
MSG_OK_SEEDED_FRESH_JWT_SECRET="Neues JWT_SECRET in %s erzeugt"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="PWG-Dienst-Token unter %s erzeugt"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="Dienste gestartet (Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant optional-collection pre-create (#606) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  Suchsammlung vorbereitet: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="Die Suchsammlung %s konnte nicht vorbereitet werden; das Wiki wird dennoch aufgebaut (der Leser behandelt sie als leer)"
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="Der Suchindex war nicht rechtzeitig bereit; die Vorbereitung optionaler Sammlungen wurde übersprungen (das Wiki wird dennoch aufgebaut)"
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="Ruhezustand im Netzbetrieb deaktiviert, Akku-Ruhezustand beibehalten, Aufwachen bei Netzwerkaktivität aktiviert"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="Ruhezustand deaktiviert, Aufwachen bei Netzwerkaktivität aktiviert"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale bereits installiert"
MSG_OK_TAILSCALE_INSTALLED="Tailscale installiert"
MSG_OK_TAILSCALE_ENV_PERSISTED="Tailscale-IP in .env gespeichert – der iOS-Companion verwendet sie beim ersten Start."
MSG_OK_TAILSCALE_IP="Tailscale-IP: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Tailscale-Hintergrunddienst gestartet (Userspace-Modus, keine Systemerweiterung)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="Der Tailscale-Hintergrunddienst konnte nicht gestartet werden. Sie können die Einrichtung später über die Einstellungen erneut ausführen."
MSG_INFO_TAILSCALE_SIGN_IN_URL="Ihr Browser wird geöffnet, um sich bei Tailscale anzumelden: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Hub-Port %s in Ihrem Tailnet freigegeben"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="Hub-Port %s konnte nicht in Ihrem Tailnet freigegeben werden; die Erreichbarkeit außerhalb des LANs ist möglicherweise eingeschränkt"
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="Drittanbieter-Hinweise installiert (Quelle: %s)"
MSG_OK_USER_FACING_TREE_READY="Nutzersichtbarer Baum bereit"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="Es wird stattdessen der Ordner / das Label 'Ostler' verwendet."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane funktionsfähig (lokale Websuche)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane läuft unter http://localhost:3000 (kommuniziert mit Ihrem lokalen Ollama)"
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="WhatsApp-Connector wird aktiviert (Einwilligung erfasst)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="Wiki-Aufhol-LaunchAgent für den ersten Tag geladen (baut Ihr Wiki in den ersten Stunden alle 30 Minuten neu auf, dann nicht mehr)"
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="Wiki-Neukompilierungs-LaunchAgent geladen (Label com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Wiki-Neukompilierungsskripte im Installer enthalten"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Wiki-Neukompilierungsskripte geklont von %s"
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki läuft unter http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="Ihr Wiki kann durchsucht werden. Ostler schreibt nun im Hintergrund die Seitenzusammenfassungen, sodass sie sich nach und nach füllen. Sie können Ihr Wiki sofort nutzen."
MSG_OK_YOUR_ASSISTANT_CALLED="Ihr Assistent heißt %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="Skripte für den Kontext-Digest im Installer enthalten"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="Kontext-Digest-LaunchAgent geladen (Label com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  Protokolle: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="Vorhandene context-refresh-Installation unter %s wird wiederverwendet"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="Skripte für den Kontext-Digest sind nicht enthalten; der Assistent verlässt sich nur auf Live-Abfragen (keine durchgehende Kontextzusammenfassung)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="Kontext-Digest-LaunchAgent wurde nicht geladen; siehe context-refresh.err. Der Assistent antwortet weiterhin über Live-Abfragen"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="Der geklonten Quelle des Knowledge-Dienstes fehlt die Paketierungskonfiguration, daher wurde seine Umgebung nicht eingerichtet."
MSG_WARN_BUNDLE="  Bundle: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s läuft nur auf Apple Silicon (erkannt: %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="Ostler RemoteCapture v%s konnte nicht von %s heruntergeladen werden"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="Häufige Ursachen: Release-Tag noch nicht veröffentlicht, keine Netzwerkverbindung oder Upstream-Notarisierung noch in Bearbeitung. Führen Sie den Installer erneut aus, sobald das Release verfügbar ist."
MSG_WARN_CM042_EXTRACT_FAILED="Ostler RemoteCapture-Tarball konnte nicht extrahiert werden; LaunchAgent wird übersprungen."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Laden des Ostler RemoteCapture-LaunchAgent fehlgeschlagen. Siehe Ausgabe oben und ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  Die Gesprächsanreicherung wird nicht verfügbar sein. Der Rest von Ostler wird normal installiert; führen Sie ohne --allow-plaintext erneut aus, um die Gesprächsgedächtnis-Engine einzubinden."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="Installation der Gesprächsgedächtnis-Engine fehlgeschlagen (Klonen)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  Gesucht nach: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  Das bedeutet in der Regel, dass die Installer-.app ohne das"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  mitgelieferte cm048_pipeline-Paket gebaut wurde, das in"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/ enthalten sein sollte. Laden Sie den Installer erneut herunter oder"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  führen Sie ihn mit --allow-plaintext für eine Dev/CI-Installation erneut aus."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="Gesprächsgedächtnis-Engine nicht gefunden. Ohne sie kann die Gesprächsanreicherung nicht laufen."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="Einrichtung der Gesprächsgedächtnis-Engine übersprungen (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="Quelle der Gesprächsgedächtnis-Engine aufgelöst, aber pyproject.toml fehlt; venv-Einrichtung übersprungen."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Colima konnte nicht gestartet werden. Docker Desktop wird als Ausweichlösung versucht..."
MSG_WARN_COLIMA_START_RETRY="Colima ist nicht sauber hochgefahren (der Docker-Socket war nicht bereit). Erneuter Versuch in %ss..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="Häufige Ursachen: Tag v%s noch nicht veröffentlicht, keine Netzwerkverbindung,"
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  consent_cli stderr (erste 400 Zeichen):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  Konsolenskript wurde nicht unter %s erstellt; in pyproject.toml fehlt möglicherweise der Eintrag [project.scripts]."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="Wird fortgesetzt, weil --allow-plaintext übergeben wurde."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="Installation wird fortgesetzt. Führen Sie \`ostler-fda\` erneut aus, nachdem Sie den obigen Fehler diagnostiziert haben."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="Wird ohne automatisches Ausfüllen aus der Kontaktkarte fortgesetzt – Ostler fragt Sie stattdessen."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  An iMessage gesendete Gespräche schlagen unbemerkt fehl, bis"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="Die Ruhezustand-Einstellungen konnten nicht geändert werden. Aktivieren Sie 'Automatischen Ruhezustand bei Netzbetrieb verhindern' unter Systemeinstellungen > Energie."
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="Die Ruhezustand-Einstellungen konnten nicht geändert werden. Aktivieren Sie 'Automatischen Ruhezustand verhindern' unter Systemeinstellungen > Energie."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="ostler-assistant v%s konnte nicht von %s heruntergeladen werden"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="Gmail-mbox konnte nicht aus dem Takeout-Zip extrahiert werden – wird übersprungen."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="ostler-assistant-Tarball konnte nicht extrahiert werden; LaunchAgent wird übersprungen."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="Die Tailscale-CLI konnte nicht gefunden werden. Sie können sie später manuell konfigurieren."
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Das Paket mit Rechts- / Einwilligungstexten konnte nicht installiert werden; wird fortgesetzt"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="Das Verzeichnis LICENSES/ konnte nicht installiert werden (nicht kritisch)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="ostler_security konnte nicht in das Hub-venv installiert werden."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="THIRD_PARTY_NOTICES.md konnte nicht installiert werden (nicht kritisch)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="Doctor-Agent konnte nicht bezogen werden (mitgeliefert / geklont, beides fehlgeschlagen)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="Ostler Doctor-Dateien nicht gefunden. Erforderlich für den iOS-Kopplungsablauf (Ostler.app bindet :8089/pair-ios per iframe ein)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  Gesucht nach: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  Das bedeutet in der Regel, dass die Installer-.app ohne die"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  mitgelieferte Quelle doctor/agent/ gebaut wurde, die in"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/ enthalten sein sollte. Laden Sie den Installer erneut herunter oder"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  führen Sie ihn mit --allow-plaintext für eine Dev/CI-Installation erneut aus."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Doctor-Installation abgebrochen: erforderlich für den iOS-Kopplungsablauf. Laden Sie den Installer erneut herunter oder übergeben Sie --allow-plaintext für eine Dev/CI-Installation."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="E-Mail-Erfassungsskripte konnten nicht bezogen werden (mitgeliefert / geklont, beides fehlgeschlagen)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="Hub-Power-Skripte konnten nicht bezogen werden (mitgeliefert / geklont, beides fehlgeschlagen)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="Wiki-Neukompilierungsskripte konnten nicht bezogen werden (mitgeliefert / geklont, beides fehlgeschlagen)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="Die Chrome Web Store-URL konnte nicht automatisch geöffnet werden: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="region.json konnte nicht gespeichert werden (wird fortgesetzt - Doctor zeigt es an)"
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="Speichern im Schlüsselbund nicht möglich. Bitte notieren Sie ihn."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="Ollama konnte nicht automatisch gestartet werden."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="Pipeline konnte nicht aktualisiert werden (offline?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="pipeline_signals.json konnte nicht geschrieben werden. Die Doctor-Diagnose für leere Mail greift bis zur nächsten Installation oder zum nächsten Durchlauf auf sichere Standardwerte zurück."
MSG_WARN_CURL_SAID="Curl meldete:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="Verzeichnis nicht gefunden: %s – Import wird übersprungen."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker ist nicht innerhalb von %s Sekunden gestartet."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker ist installiert, läuft aber nicht. Es muss gestartet werden."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama mitten in der Installation und blockieren die Bereitschaftsprüfungen."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  frühe Marker (Kanäle verbinden sich noch + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="Installation des E-Mail-Erfassungs-LaunchAgent fehlgeschlagen. Siehe Ausgabe oben."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="Installation des iMessage-Bridge-LaunchAgent fehlgeschlagen. iMessage-Antworten des Assistent-Nutzers funktionieren erst, wenn Sie den Installer erneut ausführen oder INSTALL_SNIPPET.sh manuell ausführen."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="iMessage-Bridge-Skripte sind nicht enthalten und --allow-plaintext wurde übergeben; die Installation des LaunchAgent wird übersprungen. iMessage-Antworten des Assistent-Nutzers funktionieren nicht."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="Die Verschlüsselung funktioniert nicht."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="Die Verschlüsselung funktioniert nicht, und"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="stellen Sie sicher, dass der angepinnte PWG_KNOWLEDGE_REPO-Tag es enthält."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  Ereignis-Berechtigung für Messages.app)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="FDA-Extraktor mit Nicht-null beendet (%s). Letzte 20 Zeilen der Ausgabe:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="FDA-Extraktionsmodul ist nicht in diesem Installer enthalten."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="Erwartet unter: Contents/Resources/ostler_fda/ (innerhalb der .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="Wahrscheinlichste Ursache: Eine Build-Regression hat die mitgelieferte Kopie weggelassen. Laden Sie die .app erneut von ostler.ai/install herunter."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="FDA-Extraktionsmodul nicht enthalten. Wird fortgesetzt, weil --allow-plaintext übergeben wurde – die sofortige Datenextraktion wird übersprungen."
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault ist NICHT aktiviert."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="Der erste kostenlose Monat konnte derzeit nicht aktiviert werden; die Installation wird fortgesetzt. Öffnen Sie nach der Kopplung die iOS-Companion-App, um das Problem zu beheben."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="Terminal wurde kein Vollzugriff auf die Festplatte erteilt."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="%s GB RAM erkannt. Sie erhalten den kompakten Assistenten (gemma4:e2b) – zuverlässig, präzise, bei kurzen Fragen unter einer Sekunde, mit Tool-Aufrufen und einem ehrlichen 'Das weiß ich nicht', wenn er es nicht weiß. Für ausführlichere Antworten auf längere Fragen schalten 24 GB oder mehr den Standard-Assistenten (qwen3.5:9b) frei. Sie können später durch Neuinstallation den Mac wechseln."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="Beim DSGVO-Import gab es Fehler. Sie können ihn erneut ausführen mit:"
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="Der DSGVO-Import ist Teil der produktiven Installation. Ohne ihn kann Ihr sozialer Graph (LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google Kalender) nicht importiert werden."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="Der DSGVO-Import ist auf dieser Instanz nicht verfügbar, bis die Import-Pipeline neu installiert wird."
MSG_WARN_GIT_SAID="Git meldete:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  Funktionsprüfung fehlgeschlagen: ostler-knowledge --version hat keine Ausgabe erzeugt."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  Funktionsprüfung fehlgeschlagen: Das Konversationsspeicher-Modul konnte nicht laden (pwg-convo oder sein Pipeline-Import kehrte nicht sauber zurück)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="Homebrew-Installer mit %s beendet. Es folgen die letzten 30 Zeilen von /tmp/ostler-brew-install.log:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Homebrew-Installationsprotokoll (Ende) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="Doctor-pip-Installation mit %s beendet. Es folgen die letzten 30 Zeilen von /tmp/ostler-doctor-pip.log:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Doctor-pip-Installationsprotokoll (Ende) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="Pipeline-pip-Installation mit %s beendet. Es folgen die letzten 30 Zeilen von /tmp/ostler-pipeline-pip.log:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- Pipeline-pip-Installationsprotokoll (Ende) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Installation des Hub-Power-LaunchAgent fehlgeschlagen. Siehe Ausgabe oben."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="Hub-Power-Skripte wurden nicht am erwarteten Bundle-Pfad gefunden."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  In der Installer-.app scheint vendor/hub_power/ zu fehlen"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  in Contents/Resources/hub-power/. Die akkubewusste Drosselung wird nicht installiert; der Rest der Installation wird fortgesetzt."
MSG_WARN_ICAL_SERVER_FAILED="Assistant-API konnte nicht gestartet werden; die iOS-Companion-Endpunkte sind bis zum nächsten Installationslauf eingeschränkt."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - Image-Download fehlgeschlagen (Netzwerk, Speicherplatz oder Registry-Zeitüberschreitung)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="Das iMessage-FDA-Signal konnte nicht in pipeline_signals.json geschrieben werden. Das Doctor-Dashboard zeigt die Karte für den Vollzugriff auf die Festplatte möglicherweise nicht automatisch an."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="IMAP-Host ist leer – versuchen Sie es erneut."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="iMessage-Automatisierungsberechtigung: nicht erteilt (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="iMessage-Automatisierungsberechtigung: Prüfung nicht eindeutig."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="Systemeinstellungen > Datenschutz & Sicherheit > Automatisierung werden geöffnet. Aktivieren Sie die Messages-Zeile für OstlerInstaller (oder Terminal), um die iMessage-Zustellung einzurichten."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage benötigt mindestens einen erlaubten Kontakt. Versuchen Sie es erneut oder"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="Import-Pipeline nicht verfügbar (privates Repo - nur Betatester)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="Import-Pipeline nicht im Installer enthalten. Harter Abbruch umgangen."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Import-Pipeline nicht im Installer enthalten. Dies ist der produktive Installationspfad; das contact_syncer-Python-Paket sollte im .app-Bundle enthalten sein."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX bedeutet, dass der Assistent jede E-Mail liest, die Sie erhalten."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Nicht genügend Speicherplatz für das Wiki-Ausgabe-Volume"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Intel-Mac erkannt – die Leistung wird eingeschränkt sein. Apple Silicon wird empfohlen."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s ist ein Cloud-Provider-Host."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="JWT_SECRET in %s steht auf der Sperrliste; es wird neu erzeugt, damit die Wissensgraph-Dienste importierbar bleiben"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="JWT_SECRET in %s ist zu kurz (%s < %s Zeichen); wird neu erzeugt"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="Knowledge-Repo geklont, aber pyproject.toml fehlt; venv-Einrichtung übersprungen."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="Installation des Knowledge-Dienstes fehlgeschlagen (Klonen)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="Lizenz: %s wird unter Googles Gemma-Nutzungsbedingungen ausgeliefert, nicht unter Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="MacBook-Installationen benötigen dies für die Akku- / Ruhezustand-Behandlung."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="Die macOS-Kontaktberechtigung wurde verweigert oder noch nicht erteilt."
MSG_WARN_MACOS_OUTDATED_WE_RECOMMEND_MACOS_13="macOS %s ist veraltet. Wir empfehlen macOS 13 (Ventura) oder neuer."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS fragt NICHT aus einem Skript danach – Sie müssen es manuell erteilen."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Mac Mini-Installationen sind nicht betroffen; MacBook-Nutzer sollten es erneut versuchen."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="Mail-Daten lassen sich weiterhin manuell erfassen:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  Manueller erneuter Versuch: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  Manueller erneuter Versuch, sobald die Ursache behoben ist:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Weder Apple Mail noch benutzerdefiniertes IMAP ausgewählt – es wird Apple Mail als Standard verwendet."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="Kein Passkey gesetzt; die Datenbanken werden nicht verschlüsselt."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="Die Passphrasen stimmen nicht überein. Versuchen Sie es erneut."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="Einrichtung der Passphrase fehlgeschlagen. Ausgabe:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="Leere Eingabe. Passphrase übersprungen."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="Die Passphrase muss mindestens 12 Zeichen lang sein. Versuchen Sie es erneut."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="Zur Verschlüsselung Ihrer Daten ist eine Passphrase erforderlich."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="Die Nummer muss mit + beginnen. Versuchen Sie es erneut."
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama antwortet nicht"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s fehlgeschlagen (Versuch %s/3). Erneuter Versuch in %ss..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="Nur %s GB frei. Wir empfehlen mindestens 35 GB (Docker-Images + KI-Modell + Daten)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="Im Akkubetrieb kann der Hub-Power-LaunchAgent (Schritt 3.14) pausieren"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="oder führen Sie den Installer erneut aus und treffen Sie eine andere Kanalauswahl."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="oder der Release-Pipeline von Phase B voraus. Führen Sie den Installer erneut aus, sobald die"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor meldete %s Fehler."
MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant extrahiert, aber die --version-Prüfung ist fehlgeschlagen."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Installation des Ostler-Assistent-LaunchAgent nach 3 Versuchen fehlgeschlagen. Diagnoseausgabe oben + unten."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Installationsversuch %s des Ostler-Assistent-LaunchAgent fehlgeschlagen; wird wiederholt."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="Vollständiges Daemon-stderr unter: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="Letztes Snippet-stderr:"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s läuft nur auf Apple Silicon (erkannt: %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - ostler-wiki-compiler-Image noch nicht abrufbar (Registry nicht eingerichtet)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph antwortet nicht"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph in dieser Phase noch nicht funktionsfähig (siehe Protokolle oben)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="Die Passwörter stimmten nicht überein (oder waren leer). Versuchen Sie es erneut."
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="The main install typically takes 30 to 60 minutes (Docker + Ollama downloads + first-time setup) and can run longer on a slower connection. Long quiet stretches are normal – it is downloading and setting up in the background, not stuck."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  pip-Installation fehlgeschlagen; die Gesprächsgedächtnis-Engine wird nicht verfügbar sein."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  pip-Installation fehlgeschlagen; die E-Mail-Erfassung greift auf das System-Python zurück (kann zur Laufzeit ebenfalls fehlschlagen)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  pip-Installation fehlgeschlagen; ostler-knowledge wird nicht verfügbar sein."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  pip-Installation fehlgeschlagen; die E-Mail-Erfassungs-Engine ist nicht verfügbar. Der stündliche LaunchAgent erzeugt weiterhin mbox-Dateien, kann sie aber erst in den Graphen erfassen, wenn dies behoben ist."
MSG_WARN_CM021_SOURCE_NOT_FOUND="Quelle der E-Mail-Erfassungs-Engine im App-Bundle nicht gefunden; der stündliche Hintergrundjob speichert Mail-Dateien, ohne sie zu erfassen."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="ostler_fda-Quelle im App-Bundle nicht gefunden; der E-Mail-Erfassungs-LaunchAgent greift zur Laufzeit auf das System-Python zurück."
MSG_WARN_PIP_SAID="pip meldete:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="Schließen Sie für die vollständige Installation das Netzteil an."
MSG_WARN_PORT_1_ALREADY_USE_PID="Port %s wird bereits von %s verwendet (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - Port 3000 wird bereits von einem anderen Dienst verwendet"
MSG_WARN_POWER_SOURCE="Stromquelle: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="sqlcipher3-Installation fehlgeschlagen."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="sqlcipher3-Installation fehlgeschlagen. Die Datenbanken werden nicht verschlüsselt."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="Python 3 nicht gefunden. Python 3.12 wird installiert..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s ist zu alt (benötigt wird 3.10+). Python 3.12 wird installiert..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant antwortet nicht"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         Lesen Sie https://ai.google.dev/gemma/terms vor kommerzieller Nutzung."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="Lesen Sie die öffentliche Version unter https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis antwortet nicht"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="Release erscheint, oder stellen Sie die Binärdatei manuell bereit:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="Wird erneut ausgeführt – geben Sie einen selbst gehosteten Host ein, oder drücken Sie Strg-C und starten Sie erneut mit Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="führen Sie den Installer mit deaktiviertem iMessage erneut aus, um es zu überspringen."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="AUSFÜHRUNG MIT --allow-plaintext: Verschlüsselung deaktiviert. NICHT FÜR DEN PRODUKTIVEINSATZ."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  Führen Sie \`%s doctor\` nach dem ersten Start aus"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="Führen Sie nach der Anmeldung 'tailscale ip --4' aus und fügen Sie die Adresse dann der iOS-App hinzu."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Kopieren der Safari-Erweiterung fehlgeschlagen; Sie können sie später manuell installieren"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="Sicherheitsmodul nicht gefunden. Die Passkey-Einrichtung wird übersprungen."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  Gesucht nach: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  Das bedeutet in der Regel, dass die Installer-.app ohne das"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  mitgelieferte ostler_security-Paket gebaut wurde, das in"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/ enthalten sein sollte. Laden Sie den Installer erneut herunter oder"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  führen Sie ihn mit --allow-plaintext für eine Dev/CI-Installation erneut aus."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="Sicherheitseinrichtung fehlgeschlagen. Wird ohne Datenbankverschlüsselung fortgesetzt."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="Sicherheitseinrichtung fehlgeschlagen. Ausgabe:"
MSG_WARN_SEE_STDERR_FRAGMENT="  Siehe %s für das stderr-Fragment."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="Binärinstallation wird übersprungen. Die vom Assistenten geschriebene config.toml bleibt an Ort und Stelle."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Installation des Doctor-LaunchAgent wird übersprungen."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="Installation des E-Mail-Erfassungs-LaunchAgent wird übersprungen."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="Installation des LaunchAgent wird übersprungen. Mac Mini-Installationen sind nicht betroffen."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="Installation des LaunchAgent wird übersprungen. Versuchen Sie: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="Installation des Wiki-Neukompilierungs-LaunchAgent wird übersprungen."
MSG_WARN_SOME_FEATURES_MAY_NOT_WORK_CORRECTLY="Einige Funktionen arbeiten auf älteren Versionen möglicherweise nicht korrekt."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="Einige Ports sind belegt. Docker-Container starten möglicherweise nicht."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="Beenden Sie die in Konflikt stehenden Dienste oder ändern Sie die Ports in docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscale hat sich nicht innerhalb von 3 Minuten angemeldet. Sie können später über die Einstellungen darauf zurückkommen."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="Die Tailscale-IP wurde in .env geschrieben, aber ein anschließender Lesevorgang konnte sie nicht sehen. Der iOS-Companion übernimmt sie möglicherweise nicht – führen Sie in diesem Fall install.sh --repair erneut aus."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="Tailscale-Installation fehlgeschlagen – Sie können es später von tailscale.com installieren"
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="die bereitgestellten Dienste starten ohne sie nicht."
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  dies behoben ist. Siehe das Banner mit den nächsten Schritten zur Behebung."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  zur Prüfung. cron-delivery / imessage-tcc sind häufig"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  Versuchen Sie: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  Versuchen Sie: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="Unbekannte Auswahl '%s'; es wird auf iMessage + E-Mail zurückgegriffen."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="Unbekannte Auswahl. Es wird Empfohlen verwendet."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  Aktualisierung fehlgeschlagen; wird mit dem vorhandenen Checkout fortgesetzt."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="Verwenden Sie für dieses Konto Apple Mail (oben empfohlen) – Ostler speichert niemals Cloud-Passwörter."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="INBOX wird verwendet. Der Assistent liest jede eingehende E-Mail."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="Vane-Container gestartet, aber http://localhost:3000 hat nicht innerhalb von 60s geantwortet."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane (lokale Websuche) konnte nicht gestartet werden. Häufige Ursachen:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  Die Websuche ist optional; der Rest von Ostler funktioniert auch ohne sie."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="Wir empfehlen dringend stattdessen ein eigenes Label / einen eigenen Ordner."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp benötigt eine Telefonnummer für die Briefing-Zustellung. Versuchen Sie es erneut,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="Wiki kompiliert, aber der wiki-site-Container konnte nicht gestartet werden."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="Erstkompilierung des Wikis fehlgeschlagen. Häufige Ursachen:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="Der Wiki-Aufhol-LaunchAgent für den ersten Tag konnte nicht geladen werden. Der tägliche Wiki-Neuaufbau läuft weiterhin; Ihr Wiki aktualisiert sich einfach am nächsten Tag statt innerhalb der Stunde."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Installation des Wiki-Neukompilierungs-LaunchAgent fehlgeschlagen. Siehe Ausgabe oben."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="Das Wiki wird nicht automatisch aktualisiert; der manuelle Neuaufbau bleibt verfügbar:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="Die Assistenten-Konfiguration bleibt an Ort und Stelle; die Binärdatei bleibt bereitgestellt. Manueller erneuter Versuch:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="Ihr Assistent braucht einen Namen. Wählen Sie aus den obigen Vorschlägen oder geben Sie einen eigenen ein."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="Sie können es unter Systemeinstellungen > Datenschutz & Sicherheit > Kontakte erneut erteilen."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="Sie können die Sicherheitseinrichtung später ausführen: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="Sie müssen es möglicherweise manuell installieren: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  tatsächlich:   %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="Das Ostler RemoteCapture-Bundle war nach dem Extrahieren nicht unter %s vorhanden. Der Release-Tarball ist möglicherweise fehlerhaft."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify meldete:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  Es wird abgelehnt, ein Bundle bereitzustellen, das nicht zur veröffentlichten Prüfsumme passt."
MSG_ERR_CM042_SHA_256_MISMATCH="SHA-256-Abweichung beim Ostler RemoteCapture-Tarball."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess meldete:"
MSG_ERR_CM042_VERIFY_FAILED="Ostler RemoteCapture-Signatur- / Notarisierungsprüfung fehlgeschlagen."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv meldete:"
MSG_ERR_EXPECTED="  erwartet: %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief meldete: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="Die ostler-assistant-Binärdatei unter %s ist keine ausführbare Mach-O-Datei."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="SHA-256-Abweichung beim ostler-assistant-Tarball."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  Es wird abgelehnt, eine Binärdatei bereitzustellen, die nicht zur veröffentlichten Prüfsumme passt."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="Es wird abgelehnt, die Quarantäne zu entfernen oder den LaunchAgent zu laden."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="Führen Sie den Installer erneut aus, sobald der Upstream-Tarball korrigiert ist."
MSG_ERR_URL="  url:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Intel-Macs werden in v1.0 nicht unterstützt. Apple Silicon (M1, M2, M3 oder M4) ist erforderlich. Intel-Unterstützung folgt in v1.0.1."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="Mindestens 16 GB RAM erforderlich. Sie haben %s GB. 24 GB empfohlen."
MSG_FAIL_CM042_SIGNATURE_FAILED="Ostler RemoteCapture-Installation abgebrochen: Signatur- oder Notarisierungsprüfung fehlgeschlagen. Das Bundle wurde für den Support in /Applications belassen. Schreiben Sie an support@ostler.ai und führen Sie den Installer erneut aus."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="%s konnte nach 3 Versuchen nicht geladen werden. Prüfen Sie Ihre Netzwerkverbindung und führen Sie den Installer erneut aus."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="nomic-embed-text konnte nach 3 Versuchen nicht geladen werden. Prüfen Sie Ihre Netzwerkverbindung und führen Sie den Installer erneut aus."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker nicht verfügbar. Führen Sie den Installer erneut aus, um Colima zu installieren."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="Das FDA-Extraktionsmodul fehlt im Installer-Bundle. Laden Sie die .app erneut von ostler.ai/install herunter, oder führen Sie sie mit --allow-plaintext für Dev/CI erneut aus."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Installation der Doctor-Abhängigkeiten fehlgeschlagen. Die vollständige Ausgabe wurde unter /tmp/ostler-doctor-pip.log gespeichert – hängen Sie sie an, wenn Sie an support@ostler.ai schreiben (Referenz: ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="Installation der Import-Pipeline-Abhängigkeiten fehlgeschlagen. Die vollständige Ausgabe wurde unter /tmp/ostler-pipeline-pip.log gespeichert – hängen Sie sie an, wenn Sie an support@ostler.ai schreiben (Referenz: ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Homebrew-Installation fehlgeschlagen. Die vollständige Ausgabe wurde unter /tmp/ostler-brew-install.log gespeichert – hängen Sie sie an, wenn Sie an support@ostler.ai schreiben."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="Installation der Import-Pipeline fehlgeschlagen. Das contact_syncer-Bundle ist für die produktive Installation erforderlich. Führen Sie sie mit --allow-plaintext für Dev/CI erneut aus, oder laden Sie den Installer erneut herunter und versuchen Sie es noch einmal."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="Für das Deaktivieren des Ruhezustands + die Installation von Homebrew ist sudo-Zugriff erforderlich. Führen Sie es erneut aus, wenn Sie bereit sind."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Weder Colima noch Docker Desktop konnten gestartet werden. Installieren Sie Docker Desktop und führen Sie es erneut aus."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="Nicht genügend Speicherplatz (%s GB). Geben Sie Speicherplatz frei und versuchen Sie es erneut."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="Kein Passkey gesetzt und keine vorhandene Sicherheitskonfiguration. Führen Sie es mit --allow-plaintext für Dev/CI erneut aus, oder führen Sie den Installer erneut aus und bestätigen Sie den Touch ID-Hinweis."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="Die Gesprächsgedächtnis-Engine ist erforderlich. Führen Sie es mit --allow-plaintext für Dev/CI erneut aus, oder beheben Sie das oben fehlende Bundle und versuchen Sie es noch einmal."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="ostler_security-Installation fehlgeschlagen. Führen Sie es mit --allow-plaintext für Dev/CI erneut aus, oder beheben Sie den obigen pip-Fehler und versuchen Sie es noch einmal."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="Passkey-Einrichtung fehlgeschlagen. Führen Sie es mit --allow-plaintext für Dev/CI erneut aus, oder beheben Sie den obigen Fehler und versuchen Sie es noch einmal."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="sqlcipher3 ist für verschlüsselte Datenbanken erforderlich. Führen Sie es mit --allow-plaintext für Dev/CI erneut aus, oder beheben Sie den obigen pip-Fehler und versuchen Sie es noch einmal."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Dieser Installer ist nur für macOS. Linux-Unterstützung folgt in Kürze."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="Die Installation der Xcode Command Line Tools wurde nicht innerhalb von 15 Minuten abgeschlossen. Öffnen Sie Terminal, führen Sie 'xcode-select --install' aus, klicken Sie im macOS-Dialog auf Installieren, warten Sie das Ende ab und führen Sie diesen Installer dann erneut aus."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="Die Homebrew-Installation meldete Erfolg, aber /opt/homebrew/bin/brew fehlt. Prüfen Sie %s für das vollständige Protokoll. Behebung: Öffnen Sie Terminal und führen Sie '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' aus und führen Sie den Installer dann erneut aus."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew ist unter /opt/homebrew/bin/brew installiert, aber der Befehl 'brew' ist nach der shellenv-Auswertung nicht im PATH. Öffnen Sie ein neues Terminal und führen Sie den Installer erneut aus."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' meldete Erfolg, aber colima ist nicht im PATH. Prüfen Sie %s auf Homebrew-Fehler. Behebung: Öffnen Sie Terminal und führen Sie 'brew install colima docker docker-compose' manuell aus, und führen Sie den Installer dann erneut aus."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' meldete Erfolg, aber die docker-CLI ist nicht im PATH. Prüfen Sie %s. Behebung: 'brew install docker' manuell ausführen und den Installer dann erneut ausführen."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="Die Installation der Ollama-App meldete Erfolg, aber ihre Binärdatei fehlt unter /Applications/Ollama.app. Prüfen Sie %s. Behebung: 'brew install --cask ollama-app' manuell ausführen und den Installer dann erneut ausführen."
MSG_FAIL_EMBED_HEALTHCHECK="Ollama läuft, aber das Embedding-Modell hat keinen Vektor zurückgegeben (HTTP ungleich 200 oder ein leeres Ergebnis). Die Personen-Karte, die Suche und das Browsing wären alle leer. Prüfen Sie %s. Behebung: Stellen Sie sicher, dass die Ollama-App (nicht die Homebrew-Formel) installiert ist und bedient, und führen Sie den Installer dann erneut aus."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' meldete Erfolg, aber sqlcipher ist nicht im PATH. Prüfen Sie %s. Behebung: 'brew install sqlcipher' manuell ausführen und den Installer dann erneut ausführen."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' hat /Applications/Tailscale.app nicht erzeugt. Prüfen Sie %s. Behebung: Laden Sie Tailscale von https://tailscale.com/download/macos herunter und ziehen Sie es nach /Applications, und führen Sie den Installer dann erneut aus."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' meldete Erfolg, aber die python3.11-Binärdatei fehlt unter /opt/homebrew/opt/python@3.11/bin/python3.11. Prüfen Sie %s. Behebung: 'brew reinstall python@3.11' und den Installer dann erneut ausführen."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="Wir haben Ihre früheren Antworten gefunden"
MSG_PROMPT_REUSE_SETTINGS_HELP="Wir haben einen früheren Installationsversuch auf diesem Mac erkannt. Die bereits beantworteten Fragen (Name, Assistentenname, Zeitzone, Ländervorwahl, Kanäle usw.) werden wiederverwendet, damit Sie sie nicht erneut eingeben müssen. Wählen Sie Ja, um dort weiterzumachen, wo Sie aufgehört haben, oder Nein, um die Fragen von Anfang an erneut durchzugehen."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Gefundene frühere Antworten: Name = %s, Assistent = %s, Zeitzone = %s."

MSG_PROMPT_PERMS_OK_TITLE="Bereit, fortzufahren?"
MSG_PROMPT_PERMS_OK_HELP="macOS fragt nach dem Zugriff auf Kontakte sowie Dateien & Ordner. Der optionale Vollzugriff auf die Festplatte kann später erteilt werden."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Vollständiger Name (wie er in Ihren Kontakten erscheint)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Vollständiger Name (z. B. Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="Wie soll Ihr Assistent Sie nennen?"
MSG_PROMPT_USER_ID_HELP="Ein kurzer Name, mit dem Ihr Assistent Sie anspricht (z. B. 'Andy', 'Andrew', 'Frau Smith'). Das erscheint in Ihren Morgen-Briefings und Chat-Antworten. Unterscheidet sich von Ihrem vollständigen Namen oben."

# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="Installing in the background (about 15 to 60 minutes)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="+%s verwenden?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Ländervorwahl eingeben (z. B. 44 für GB, 1 für USA)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Standard-Ländervorwahl"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Wird verwendet, um Telefonnummern beim Kontaktimport zu normalisieren und Ihre Region (GB / EU / USA / andere) für rechtliche Compliance-Standardwerte festzulegen."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="Wir haben +%s erkannt. Für Ihren Hub verwenden?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Aus Ihrer Telefonnummer oben erkannt. Wählen Sie Ja, um sie zu verwenden, oder Nein, um eine andere Ländervorwahl einzugeben."

MSG_PROMPT_TZ_CONFIRM_TITLE="Diese Zeitzone verwenden?"
MSG_PROMPT_TZ_CONFIRM_HELP="Erkannte Zeitzone: %s"
MSG_PROMPT_USER_TZ_TITLE="Zeitzone eingeben (z. B. Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="Wie möchten Sie Ihren Assistenten nennen?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="Der Name im Feld ist ein Zufallsvorschlag – überschreiben Sie ihn mit einem beliebigen Namen. Marvin, Samantha, Joshua, Friday, Athena, Sage und Rosie sind allesamt beliebte Optionen." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Geben Sie einen beliebigen Namen ein – der Vorschlag ist nur ein Ausgangspunkt."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="Wie soll Ihr Assistent Sie erreichen?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Wählen Sie die Nachrichtenkanäle aus, die Ihr Assistent verwenden soll. Sie können dies später im Doctor-Bereich der App ändern."

MSG_PROMPT_WHATSAPP_CONSENT_TITLE="WhatsApp-Nachrichten für Ihren Assistenten aktivieren?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web ist ein Drittanbieterdienst. Mit der Aktivierung akzeptieren Sie, dass Ihre Nachrichten über die eigene Infrastruktur von WhatsApp laufen, bevor sie Ihre lokale Ostler-Instanz erreichen, und dass WhatsApp (Meta Platforms Ireland Ltd) Ihr WhatsApp-Konto wegen automatisierter Nutzung sperren, einschränken oder kündigen kann. Sie können dies später in den Einstellungen deaktivieren."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="Ihre WhatsApp-Telefonnummer"
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Internationale Nummer mit Ländervorwahl, z. B. +44 7700 900123. Nur Ziffern und ein führendes + – keine Leerzeichen, Klammern oder Bindestriche."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Ostler erlauben, Ihre Messages zu lesen"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="Die Systemeinstellungen sind beim Vollzugriff auf die Festplatte geöffnet."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Suchen Sie \"Ostler\" und aktivieren Sie es."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="Klicken Sie auf Fertig, wenn Sie fertig sind."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Fertig"

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Ostler erlauben, Ihre Mac-Daten zu lesen"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="Die Systemeinstellungen sind beim Vollzugriff auf die Festplatte geöffnet."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Suchen Sie \"OstlerInstaller\" in der Liste und aktivieren Sie es."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Klicken Sie auf Fertig, wenn Sie fertig sind, und Ostler liest Ihren Safari-Verlauf, Ihre Notizen, iMessages und Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Fertig"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="Als Nächstes: Vollzugriff auf die Festplatte für den Installer"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="Als Nächstes fragt macOS Sie, dem OstlerInstaller Vollzugriff auf die Festplatte zu erteilen."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Nachdem Sie den Schalter aktiviert haben, zeigt macOS einen Dialog an, in dem Sie 'Beenden & erneut öffnen' oder 'Später' wählen sollen."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Klicken Sie auf Beenden & erneut öffnen. Der Installer startet sich selbst neu und fährt automatisch ab diesem Schritt fort."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="OK"
MSG_INFO_INSTALLER_FDA_PREWARN="Sie werden über den Ablauf zur Erteilung des Vollzugriffs auf die Festplatte informiert..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="Die Systemeinstellungen werden geöffnet, damit Sie dem Installer Vollzugriff auf die Festplatte erteilen können..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="Vollzugriff auf die Festplatte für den Installer erteilt. Als Nächstes werden Safari, Notizen, iMessages und Mail gelesen."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="Vollzugriff auf die Festplatte weiterhin nicht erteilt. Wird ohne ihn fortgesetzt; Sie können den Installer später erneut ausführen, um Safari / Notizen / iMessages zu extrahieren."

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="Erlaubte Kontakte"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="Vertrauenswürdige Personen: Telefonnummern und Apple-ID-E-Mails (durch Komma getrennt). %s antwortet nur Personen auf dieser Liste; Nachrichten von allen anderen werden ignoriert. Mindestens ein Eintrag erforderlich.

Zum Beispiel:
+447700900000, sie@beispiel.de"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="Mail über Apple Mail lesen?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Liest mit Vollzugriff auf die Festplatte jedes E-Mail-Konto, das Sie zu Apple Mail hinzugefügt haben (iCloud, Gmail, Outlook usw.). Es werden keine Passwörter gespeichert. Für fast alle empfohlen."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="Ein Mail-Konto zu Apple Mail hinzufügen?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="Apple Mail hat auf diesem Mac noch keine Konten verbunden, daher hat Ostler keine E-Mails zum Lesen. Wählen Sie Ja, um jetzt die Systemeinstellungen > Internetaccounts zu öffnen (dort können Sie iCloud, Gmail oder Outlook hinzufügen). Wählen Sie Nein, um es zu überspringen; Sie können später ein Konto hinzufügen, und Doctor zeigt einen Hinweis an, falls innerhalb von 24 Stunden keine E-Mails eintreffen."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="Ihren vollständigen Apple Mail-Verlauf holen?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Standardmäßig liest Ostler die letzten fünf Jahre Ihrer Apple Mail. Wenn Sie mehr davon auf diesem Mac aufbewahren und alles in Ihrem Wissensgraphen haben möchten, wählen Sie Ja, um jetzt den vollständigen lokalen Verlauf zu holen (das kann bei einem großen Postfach etwas länger dauern). Wählen Sie Nein, um das Fünf-Jahres-Fenster beizubehalten; Sie können es später jederzeit über Doctor erweitern."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="Auch einen benutzerdefinierten IMAP+SMTP-Server konfigurieren?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="Nur für selbst gehostete Postfächer. Lassen Sie es auf NEIN, wenn Ihre Konten bei Gmail, iCloud oder Outlook liegen – diese funktionieren besser über Apple Mail oben."

MSG_PROMPT_IMAP_HOST_TITLE="IMAP-Host"
MSG_PROMPT_IMAP_HOST_HELP="Nur selbst gehosteter oder benutzerdefinierter IMAP-Server. Verwenden Sie Apple Mail (oben) für Gmail / iCloud / Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="IMAP-Port"

MSG_PROMPT_SMTP_HOST_TITLE="SMTP-Host"
MSG_PROMPT_SMTP_PORT_TITLE="SMTP-Port"

MSG_PROMPT_EMAIL_USERNAME_TITLE="E-Mail-Adresse (wird auch als IMAP/SMTP-Benutzername verwendet)"

MSG_PROMPT_EMAIL_PASSWORD_TITLE="Passwort (verborgen)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Passwort für Ihren selbst gehosteten IMAP/SMTP-Server. Wird lokal unter ~/.ostler/ gespeichert – niemals an Creative Machines gesendet."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Passwort bestätigen"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="Welchen Ordner soll der Assistent beobachten?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="Empfohlen: ein eigenes Label oder einen eigenen Ordner (z. B. Ostler). Wir lesen nur die dortigen Nachrichten und lassen Ihren Haupt-Posteingang unangetastet."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="Geben Sie INBOX erneut ein, um zu bestätigen, oder drücken Sie Weiter, um 'Ostler' zu verwenden"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX bedeutet, dass der Assistent jede E-Mail liest, die Sie erhalten. Wir empfehlen dringend stattdessen ein eigenes Label / einen eigenen Ordner."

MSG_PROMPT_EXPORTS_ACK_TITLE="Haben Sie Ihre Datenexporte angefordert?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler importiert von rund 20 Plattformen. Die vollständige Liste mit direkten Links zur Anforderungsseite jedes Anbieters finden Sie unter docs.ostler.ai/data-exports.

Die meisten Archive treffen innerhalb von 1 bis 3 Tagen per E-Mail ein. Wenn die ZIPs eintreffen, legen Sie sie in Ihren Downloads-Ordner, und Ostler findet sie automatisch.

Überspringen Sie alle, die Sie nicht nutzen; Sie können später jederzeit weitere importieren."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="Ohne FileVault fortfahren?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="FileVault wird dringend empfohlen. Ohne es bedeutet physischer Zugriff auf Ihren Mac auch Zugriff auf Ihre Daten."

MSG_PROMPT_PASSKEY_ACK_TITLE="Bereit, die Festplattenverschlüsselung einzurichten"
MSG_PROMPT_PASSKEY_ACK_HELP="Ihr Wissensgraph wird mit einer Passphrase verschlüsselt, die Sie auf dem nächsten Bildschirm wählen. Sie geben diese Passphrase bei jedem Start der Hub-Oberfläche ein. Außerdem wird ein separater Wiederherstellungsschlüssel erzeugt und am Ende der Installation einmal angezeigt. Drücken Sie auf Weiter, wenn Sie bereit sind."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="Auch eine Wiederherstellungs-Passphrase festlegen? (empfohlen)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="Wählen Sie Ihre Passphrase"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="Diese Passphrase verschlüsselt Ihren Wissensgraphen und entsperrt die Hub-Oberfläche bei jedem Start. Mindestens 12 Zeichen. Wir können sie nicht für Sie wiederherstellen. Es wird empfohlen, sie in einem Passwortmanager zu speichern."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="Bestätigen Sie Ihre Passphrase"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="Geben Sie dieselbe Passphrase erneut ein, um sie zu bestätigen."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="Diese während der Installation importieren?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="Gefundene DSGVO-Exporte werden während der Installation in Ihren Wissensgraphen importiert."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="Haben Sie Datenexporte bereit?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler kann Social-Media- und Plattform-Archive importieren – Ihren vollständigen Verlauf mit Freunden, Familie, Orten, Meinungen – von Anfang an. Je mehr Ostler am ersten Tag weiß, desto nützlicher ist es am ersten Tag. Sie können dies auch später hinzufügen; keine Eile.

Fordern Sie Ihren Datenexport bei jeder Plattform an (Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp usw.), laden Sie die ZIP-Dateien herunter und legen Sie sie in Ihren Downloads-Ordner.

Ostler sucht standardmäßig in ~/Downloads. Möchten Sie einen anderen Ordner? Wählen Sie unten einen aus. Andernfalls überspringen Sie und importieren später."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="Gmail-Nachrichten aus diesem Takeout importieren?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Liest Gmail-Inhalte direkt aus der Takeout-Datei. Google erfährt nie von Ostler."

MSG_PROMPT_FDA_PRESET_TITLE="Aus welchen Mac-Quellen soll Ostler lernen?"
MSG_PROMPT_FDA_PRESET_HELP="Drei Voreinstellungen, oder wählen Sie jede selbst aus. Sensible Quellen (Gesichtserkennung) sind in jeder Voreinstellung standardmäßig aus – wählen Sie sie bewusst, wenn Sie sie möchten."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="Empfohlen. Umfasst Apple Mail, Kontakte, Kalender, Notizen, Messages, Erinnerungen, Safari-Verlauf und Safari-Lesezeichen. WhatsApp Desktop-Verlauf und Chrome-Verlauf werden automatisch hinzugefügt, wenn die App installiert ist. Schließt Fotos-Gesichtserkennungsdaten und alle Drittanbieter-Export-Archive aus."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="Alles. Empfohlen + Fotos-Ereignisse (keine Gesichtserkennung). Die Fotos-Gesichtserkennung bleibt aus, bis Sie sie bewusst aktivieren."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="Anpassen. Wählen Sie jede Quelle auf dem nächsten Bildschirm. Sensible Quellen bleiben aus, bis Sie sie aktivieren."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="Diese Datenquelle ein- oder ausschalten."

MSG_PROMPT_CONSENT_ARTICLE_9_TITLE="Ihre Entscheidung (J / N)"
MSG_PROMPT_CONSENT_ARTICLE_9_HELP="Einwilligung für besondere Kategorien nach Artikel 9 (UK GDPR). Erforderlich für die Rechtsgrundlage der Verarbeitung."

MSG_PROMPT_CONSENT_VOICE_EU_TITLE="Stimmen in Ihren Anrufaufzeichnungen erkennen?"
MSG_PROMPT_CONSENT_VOICE_EU_HELP="Die Sprechererkennung bleibt auf diesem Mac. Creative Machines erhält die Fingerabdrücke niemals."

MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE="Eine letzte Sache: wie Drittanbieterdaten funktionieren"
MSG_PROMPT_CONSENT_THIRD_PARTY_HELP="Alle Daten, die Sie von Dritten importieren (Google Takeout, Meta-Downloads, LinkedIn-Exporte usw.), bleiben auf diesem Mac. Ostler speichert sie in Ihrem lokalen Wissensgraphen; nichts verlässt Ihr Gerät.

Mit dem Fortfahren verstehen Sie und stimmen zu, dass Sie allein für die Verarbeitung und Aufbewahrung dieser Daten auf Ihrem Rechner verantwortlich sind, genau wie für die E-Mail-Nachrichten, die bereits auf Ihrer Festplatte liegen.

Rechtlicher Hinweis: Für Datensätze, die Sie auf diesen Mac importieren, sind Sie nach britischem und EU-Recht der Verantwortliche und der Verarbeiter (UK GDPR Artikel 4(7) und 4(8)). Creative Machines erhält diese Daten niemals und ist nicht der Verantwortliche. Ihre Verarbeitung zu persönlichen und familiären Zwecken fällt unter UK/EU GDPR Artikel 2(2)(c).

Mehr dazu unter docs.ostler.ai/privacy/third-party-data."

MSG_PROMPT_CONSENT_INSTALL_TITLE="Bereit zur Installation?"
MSG_PROMPT_CONSENT_INSTALL_HELP="Bitte geben Sie INSTALL ein, um zu bestätigen, dass Sie die Bedingungen akzeptieren."
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="INSTALL eingeben"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Ostler installieren"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Abbrechen"
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Geben Sie genau INSTALL ein (Groß-/Kleinschreibung egal), um zu bestätigen, oder klicken Sie auf Abbrechen, um zurückzugehen."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="Verbinden Sie Ihr iPhone und Ihre Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale gibt diesem Mac eine stabile private Adresse, die Ihr iPhone und Ihre Watch von überall erreichen können – verschlüsselt, ohne öffentliche Erreichbarkeit."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="Wiederherstellungsschlüssel im Schlüsselbund speichern?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="Speichert Ihren Verschlüsselungs-Wiederherstellungsschlüssel zur sicheren Aufbewahrung im macOS-Schlüsselbund."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="Ihr Graph wird befüllt"
MSG_HYDRATE_CONTACTS_STARTED="Ihre Kontakte werden in den Graphen importiert"
MSG_HYDRATE_CONTACTS_DONE="%s Kontakte importiert"
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="Ihre letzten 90 Tage des Kalenders werden geladen (ein längerer Verlauf wird im Hintergrund nachgeladen)"
MSG_HYDRATE_CALENDAR_DONE="%s Termine importiert"
MSG_HYDRATE_WIKI_RECOMPILE="Ihr Wiki wird aufgebaut. Ostler schreibt eine kurze Zusammenfassung für jede Ihrer wichtigen Personen, Organisationen und Themen, sodass dies bei einem großen Adressbuch von wenigen Minuten bis zu etwa einer Stunde dauern kann. Es geschieht nur einmal, läuft vollständig auf Ihrem Mac und kann unbeaufsichtigt bleiben."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="Ihr Suchindex wird geprüft (%s Sammlungen erkannt)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="Ihr Browserverlauf wird in den Suchindex geladen"
MSG_INITIAL_HYDRATE_QDRANT_READY="Suchindex bereit (%s Sammlungen)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="Der Suchindex wird im Hintergrund befüllt, nachdem die Installation abgeschlossen ist"
MSG_HYDRATE_DONE="Ihr Graph ist bereit: %s Personen, %s Termine"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud synchronisiert Ihre Kontakte möglicherweise noch – sie werden jetzt erneut exportiert, um neu Eingetroffenes zu erfassen."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="Keine Kontakte in Ihrer Kontakte-App gefunden (lokal oder iCloud). Fügen Sie einige zu Kontakte hinzu und führen Sie es über die Einstellungen erneut aus."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="Keine iCloud-Kontakte zum Importieren. Sie können dies später über die Einstellungen hinzufügen."
MSG_HYDRATE_SKIPPED_NO_EVENTS="Keine Kalendertermine in den letzten 5 Jahren. Sie können später über die Einstellungen nachladen."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="Ihre letzten 90 Tage E-Mail werden gelesen – Ihre E-Mails bleiben auf diesem Mac (ein längerer Verlauf wird im Hintergrund nachgeladen)"
MSG_HYDRATE_EMAIL_DONE="%s Personen in Ihren jüngsten E-Mails gefunden"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="Keine jüngsten E-Mails zum Lesen. Sie können in Apple Mail ein Mail-Konto hinzufügen und es später erneut ausführen."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="E-Mail-Leser noch nicht bereit. Sie können in Apple Mail ein Mail-Konto hinzufügen und es später erneut ausführen."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="E-Mails werden weiterhin im Hintergrund geladen – Ihr Wiki füllt sich im Laufe der nächsten Stunde."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="Apple Mail öffnen, damit die Synchronisierung starten kann?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="Sie haben %s Mail-Konto(s) konfiguriert, aber Apple Mail hat noch keine Nachrichten abgerufen. Wir können jetzt Mail.app öffnen und warten, während es synchronisiert."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="Kalender öffnen, damit die Synchronisierung starten kann?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="Sie haben %s Kalender-Konto(s) konfiguriert, aber Calendar.app hat noch keine Termine gespeichert. Wir können jetzt Kalender öffnen und warten, während er aus iCloud synchronisiert."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="Kontakte öffnen, damit die Synchronisierung starten kann?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="Sie haben %s Kontakte-Konto(s) konfiguriert, aber Contacts.app hat noch keine Einträge gespeichert. Wir können jetzt Kontakte öffnen und warten, während sie aus iCloud synchronisieren."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="Es wird gewartet, bis %s mit der Synchronisierung beginnt (bis zu %s Sekunden)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="Es wird weiterhin auf die %s-Synchronisierung gewartet (%ss vergangen, %ss verbleibend). Die erste iCloud-Synchronisierung kann bei einer frischen Anmeldung einige Minuten dauern."
MSG_OK_APP_HAS_POPULATED="%s hat seinen lokalen Speicher befüllt. Es wird fortgesetzt."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="Wir haben innerhalb des Wartefensters keine %s-Synchronisierung erkannt. Es wird fortgesetzt; Sie können die Befüllung später über die Einstellungen erneut ausführen."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="Sichtbare Apple Mail-Konten: %s. Öffnen Sie Mail.app einmal, damit es mit dem Abrufen von Nachrichten beginnen kann."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="Sichtbare Kalender-Konten: %s. Öffnen Sie Calendar.app einmal, damit Ihre Termine synchronisiert werden können."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="Sichtbare Kontakte-Konten: %s. Öffnen Sie Contacts.app einmal, damit Ihr Adressbuch synchronisiert werden kann."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="Ihre Kontakte konnten nicht gelesen werden. Ostler liest sie über den Vollzugriff auf die Festplatte - erteilen Sie ihn unter Systemeinstellungen > Datenschutz & Sicherheit > Vollzugriff auf die Festplatte und führen Sie die Befüllung dann über die Einstellungen erneut aus. Wir versuchen es im Hintergrund weiter."
MSG_HYDRATE_CONTACTS_PENDING="Ihre Kontakte-App hat noch nicht synchronisiert. Öffnen Sie Kontakte einmal, warten Sie auf die Synchronisierung und führen Sie die Befüllung dann über die Einstellungen erneut aus."
MSG_HYDRATE_CONTACTS_READ_FAILED="Ihre Kontakte sind auf diesem Mac, aber Ostler hat 0 davon importiert, was unerwartet ist. Der Import wird im Hintergrund automatisch wiederholt. Falls das Problem bestehen bleibt, führen Sie die Befüllung über die Einstellungen erneut aus oder prüfen Sie das Installationsprotokoll."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler prüft im Hintergrund weiter und importiert Ihre Kontakte automatisch, sobald iCloud die Synchronisierung abgeschlossen hat."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="Neue Kontakte importiert; Ihr Wiki wird im Hintergrund neu aufgebaut."
MSG_HYDRATE_CALENDAR_PENDING="Ihre Kalender-App hat noch keine Termine synchronisiert. Öffnen Sie Kalender einmal, warten Sie auf die Synchronisierung und führen Sie die Befüllung dann über die Einstellungen erneut aus."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="Ihr Kalender konnte diesmal nicht gelesen werden (der Extraktor meldete einen Fehler, keinen leeren Kalender). Ihre anderen Daten waren nicht betroffen; siehe /tmp/ostler-hydrate-calendar.log und führen Sie die Befüllung dann über die Einstellungen erneut aus."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="Ihr WhatsApp-Verlauf wird gelesen – Ihre Nachrichten bleiben auf diesem Mac"
MSG_HYDRATE_WHATSAPP_DONE="%s Personen in Ihren WhatsApp-Chats gefunden"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="Keine WhatsApp-Chats zum Lesen. Sie können es später über die Einstellungen erneut ausführen."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktop ist nicht installiert. Installieren Sie es aus dem Mac App Store und führen Sie es über die Einstellungen erneut aus."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="WhatsApp-Leser noch nicht bereit. Sie können es später über die Einstellungen erneut ausführen."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp wird weiterhin im Hintergrund geladen – Ihr Wiki füllt sich im Laufe der nächsten Stunde."

# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="Ihr Browserverlauf wird importiert – Ihre Besuche bleiben auf diesem Mac"
MSG_HYDRATE_BROWSING_DONE="%s Seiten des Browserverlaufs importiert"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="%s als sensibel markierte Seiten übersprungen (Banking, Medizin usw.)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="Kein Browserverlauf zum Importieren. Sie können es später über die Einstellungen erneut ausführen."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="Browserverlauf-Leser noch nicht bereit. Sie können es später über die Einstellungen erneut ausführen."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="Der Browserverlauf wird weiterhin im Hintergrund geladen – Ihr Wiki füllt sich im Laufe der nächsten Stunde."

# Preferences import counts-only confirmation, shown by phase 3.12b after
# the shared ostler-import fan-out runs. The other hydrate_preferences
# strings were removed when the standalone block was collapsed into the
# shared importer; only this done-count line is still referenced.
# Privacy: enrich's lookup clients call PUBLIC item-metadata APIs only
# (about the item, never the user); this string is a count.
MSG_HYDRATE_PREFERENCES_DONE="%s Präferenzen importiert und angereichert"

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="Präferenzanreicherung wird eingerichtet (einmalig)"
MSG_CM019_SETUP_DONE="Präferenzanreicherung bereit"
MSG_CM019_SETUP_FAILED="Die Einrichtung der Präferenzanreicherung wurde nicht abgeschlossen. Ihre Präferenzseiten füllen sich, sobald es behoben ist; der Rest von Ostler ist nicht betroffen."
MSG_CM019_SETUP_EXISTS="Präferenzanreicherung bereits eingerichtet"
MSG_CM019_SETUP_SKIPPED="Präferenzanreicherungs-Pipeline nicht enthalten; wird vorerst übersprungen."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="Ihr iMessage-Verlauf wird gelesen – Ihre Nachrichten bleiben auf diesem Mac"
MSG_HYDRATE_IMESSAGE_DONE="%s Personen in Ihrem iMessage-Verlauf gefunden"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="Kein iMessage-Verlauf zum Lesen. Sie können es später über die Einstellungen erneut ausführen."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="iMessage-Leser noch nicht bereit. Sie können es später über die Einstellungen erneut ausführen."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage wird weiterhin im Hintergrund geladen – Ihr Wiki füllt sich im Laufe der nächsten Stunde."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="Ihre Personen werden für die Suche indexiert"
MSG_HYDRATE_PEOPLE_DONE="%s Personen für die Suche indexiert"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="Noch keine Personen zum Indexieren. Sie können es später über die Einstellungen erneut ausführen."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="Personen-Indexer noch nicht bereit. Sie können es später über die Einstellungen erneut ausführen."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="Ihre Personen werden weiterhin im Hintergrund indexiert; die Suche füllt sich in Kürze."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="Es kommen gleich drei Ordnerzugriffs-Abfragen"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="Der Dialog der Command Line Tools ist vor diesem Fenster erschienen – klicken Sie darauf auf Installieren und kommen Sie dann hierher zurück (oder warten Sie ein paar Sekunden, wir holen dieses Fenster für Sie wieder nach vorne). Die Tools werden im Hintergrund heruntergeladen, während Sie die folgenden Fragen weiter beantworten; hier wird nichts blockiert."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="Berechtigung erforderlich: iMessage-Automatisierung"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostler fragt macOS nun nach der Berechtigung, mit Messages.app zu kommunizieren. macOS zeigt ein Popup mit \"OstlerInstaller möchte Messages steuern\" – klicken Sie auf Erlauben, damit der Assistent in Ihrem Namen iMessages senden und empfangen kann. Ohne diese Berechtigung verlassen iMessage-Nachrichten den Rechner unbemerkt nie. Dies ist eine einmalige Erteilung; Sie können sie später unter Systemeinstellungen > Datenschutz & Sicherheit > Automatisierung ändern."

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="Ihr Wiederherstellungsschlüssel"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="Notieren oder drucken Sie ihn jetzt. Er ist der einzige Weg zurück, falls Sie Ihre Passphrase verlieren UND Ihr Schlüsselbund unzugänglich wird. Ostler kann ihn nicht für Sie wiederherstellen – der Schlüssel verlässt diesen Mac niemals und wird auf keinem Server gespeichert."
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="Ich habe ihn an einem sicheren Ort gespeichert"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="In die Zwischenablage kopieren"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="Als PDF speichern..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="Drucken..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="Weiter"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Ostler Wiederherstellungsschlüssel.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Ostler Wiederherstellungsschlüssel"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="Wiederherstellungsschlüssel in die Zwischenablage kopiert"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="Wiederherstellungsschlüssel gespeichert unter %s"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="Koppeln Sie Ihr iPhone"
MSG_INFO_PAIR_IPHONE_HELP="Öffnen Sie die Ostler-App auf Ihrem iPhone und scannen Sie diesen QR-Code, um es mit diesem Hub zu verknüpfen. Sie können später auch über das Einstellungen-Menü des Hubs koppeln."
MSG_INFO_PAIR_IPHONE_FETCHING="Kopplungscode wird erzeugt..."
MSG_INFO_PAIR_REFRESH="Code aktualisieren"
MSG_ERR_PAIR_FETCH_FAILED="Das Ostler-Gateway konnte noch nicht erreicht werden. Es startet möglicherweise noch – klicken Sie auf Aktualisieren, um es erneut zu versuchen."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agent nicht im Installer enthalten. Tägliche Briefings + WhatsApp-Keepalive-LaunchAgent werden nicht geladen."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Wiki-Neukompilierungsskripte nicht im Installer enthalten. Das Wiki wird nicht automatisch aktualisiert."

# F3 - legal package missing
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="Rechtspaket nicht im Installer enthalten. Die Einwilligungs-Gates für Artikel 9 / WhatsApp / Stimme lösen einen ModuleNotFoundError aus, bis es neu installiert wird."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s installiert unter %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s bereits installiert, bleibt an Ort und Stelle"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Nicht unterstützte CPU-Architektur für die Google Workspace CLI; Gmail- / Google Kalender-Funktionen eingeschränkt."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl nicht verfügbar; Installation der Google Workspace CLI übersprungen. Gmail- / Google Kalender-Funktionen eingeschränkt."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="Google Workspace CLI konnte nicht von %s heruntergeladen werden"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="SHA256-Abweichung bei der Google Workspace CLI (erwartet %s, erhalten %s). Installation dieser Binärdatei wird abgebrochen."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="Das Google Workspace CLI-Archiv konnte nicht extrahiert werden."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI installiert unter %s, aber die --version-Prüfung ist fehlgeschlagen."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="iCloud- / CalDAV-Kalenderbrücke installiert unter %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="Die iCloud- / CalDAV-Kalenderbrücke unter %s ist nicht ausführbar. Der Kalender gibt keine Termine zurück."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh nicht im Installer enthalten. Der Wiederholungsversuch der Geräteregistrierung beim nächsten Netzwerk ist deaktiviert."

# ── Parity top-up 2026-07-12 (MACHINE DRAFT) ──
# Keys added to en-GB between the 2026-05-19 extraction and 2026-07-12.
# Machine-draft translations; review before shipping a localised installer.

MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="Docker war nicht rechtzeitig bereit, um die Wissensgraph-Datenbanken zu starten. Stellen Sie sicher, dass Colima oder Docker läuft, und führen Sie den Installer dann erneut aus."

MSG_FAIL_GRAPH_DB_PULL_FAILED="Die Images der Wissensgraph-Datenbanken konnten auch nach mehreren Versuchen nicht heruntergeladen werden. Das ist meist ein Netzwerkproblem. Prüfen Sie Ihre Internetverbindung und führen Sie den Installer erneut aus."

MSG_FAIL_GRAPH_DB_UP_FAILED="Die Wissensgraph-Datenbanken wurden heruntergeladen, konnten aber nicht gestartet werden. Führen Sie den Installer erneut aus; falls es weiterhin passiert, öffnen Sie Terminal und führen Sie aus: cd ~/.ostler && docker compose up -d qdrant oxigraph redis"

MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="%s Kontakte mit Telefonnummern importiert, aber fast ohne E-Mail-Adressen (%s Telefon vs. %s E-Mail). Das bedeutet meist, dass der Kontaktleser E-Mail-Adressen verworfen hat. Ihre Kontakte sind trotzdem nutzbar; siehe /tmp/ostler-hydrate-contacts.log und führen Sie den Datenimport nach der Behebung erneut über die Einstellungen aus."

MSG_HYDRATE_EMAIL_HEARTBEAT="  Ihre E-Mails werden noch gelesen (bisher %ss). Auf einem Mac mit jahrelanger Historie kann das eine Weile dauern."

MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="E-Mail-Präferenzen werden noch im Hintergrund geladen. Ihr Wiki füllt sich in Kürze."

MSG_HYDRATE_EMAIL_PREFERENCES_DONE="%s Präferenzen aus Ihrer E-Mail-Historie geladen"

MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  Ihre E-Mail-Präferenzen werden noch geladen (bisher %ss). Eine große Historie kann einige Minuten dauern."

MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="Keine E-Mail-Präferenzdatei konfiguriert. Nichts zu laden."

MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="Keine E-Mail-Präferenzdatei unter %s gefunden. Nichts zu laden."

MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="Die Präferenz-Pipeline ist noch nicht bereit. Sie können sie später über die Einstellungen erneut ausführen."

MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="Ihre E-Mail-Präferenzen werden geladen. Das bleibt auf diesem Mac und kann einige Minuten dauern."

MSG_HYDRATE_IMESSAGE_HEARTBEAT="  Ihre iMessage-Historie wird noch gelesen (bisher %ss). Eine große Nachrichtenhistorie kann mehrere Minuten dauern."

MSG_HYDRATE_PLACES_DONE="Ihr Places-Bereich wurde erstellt"

MSG_HYDRATE_PLACES_ERROR_WARN="Die Erstellung von Places wurde nicht abgeschlossen (unerwarteter Fehler). Ihre Places-Seite ist möglicherweise unvollständig. Siehe /tmp/ostler-places-ingest.log"

MSG_HYDRATE_PLACES_GUARD_WARN="Bei der Erstellung von Places gab es ein Problem: Es gibt Standortsignale, aber es wurden keine Places erzeugt. Ihre Places-Seite bleibt möglicherweise leer. Siehe /tmp/ostler-places-ingest.log"

MSG_HYDRATE_PLACES_SKIPPED="Noch keine Standortsignale gefunden; Places füllt sich, sobald sich Ihr Kalender füllt"

MSG_HYDRATE_PLACES_STARTED="Ihre Places werden aus den Orten erstellt, an denen Sie sich treffen"

MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="Der Assistent wird neu gestartet, damit er den soeben gewährten Festplattenvollzugriff übernimmt (nötig, um Ihre Nachrichten-Historie zu lesen)."

MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="Eine weitere Berechtigung (Nachrichten-Historie für Ihren Assistenten) folgt gegen Ende, sobald Ihr Assistent installiert ist – wir weisen Sie dann darauf hin."

MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="Doppelte Kontakte wurden während der Installation vollständig zusammengeführt; keine Nacharbeit im Hintergrund nötig"

MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="Die meisten doppelten Kontakte wurden zusammengeführt. Der Rest wird nach der Installation im Hintergrund abgeschlossen – Ihr Wiki aktualisiert sich dann automatisch."

MSG_INFO_DEDUPE_MERGED="Doppelte Kontakte zusammengeführt"

MSG_INFO_DEDUPE_STILL_MERGING="Doppelte Kontakte werden noch zusammengeführt – große Adressbücher können mehrere Minuten dauern (%ss vergangen)"

MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="Gewähren Sie den Zugriff unter Systemeinstellungen > Datenschutz & Sicherheit > Dateien und Ordner (oder Festplattenvollzugriff) und führen Sie es erneut aus, oder verweisen Sie Ostler unten manuell auf Ihren Export-Ordner."

MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="Ein oder mehrere Ordner konnten nicht nach Datenexporten durchsucht werden, weil macOS den Zugriff blockiert hat. Gewähren Sie den Zugriff und führen Sie es erneut aus, oder verweisen Sie mich manuell auf Ihren Export-Ordner."

MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="Der Festplattenvollzugriff für den Installer ist erledigt. Ab hier läuft die lange Installation von allein – Sie können sich entfernen."

MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="GNU coreutils wird installiert (für Zeitlimits bei langen Schritten)..."

MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  Die Abhängigkeit für verschlüsselte Speicherung wird in die venv des Konversationsspeichers installiert..."

MSG_INFO_PULLING_GRAPH_DB_IMAGES="Die Wissensgraph-Datenbanken werden heruntergeladen (nur beim ersten Lauf). Bei einer frischen Installation kann das eine Minute dauern..."

MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="Ein manueller Schritt bleibt: Öffnen Sie Safari, wählen Sie Safari > Einstellungen > Erweiterungen und setzen Sie bei Ostler ein Häkchen, um es zu aktivieren."

MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="Alles klar – Sie können sich entfernen, während Ostler installiert. Gegen Ende gibt es einen kurzen optionalen Schritt: die Anmeldung bei Tailscale, damit Ihr iPhone und Ihre Watch diesen Mac von überall erreichen. Wir öffnen dann Ihren Browser dafür."

MSG_MODELFIT_HEADER="Das Assistentenmodell wird auf Ihren Mac abgestimmt (%s, %s GB RAM, Assistenten-Kontext %s Token):"

MSG_MODELFIT_PILL_FITS="Passt"

MSG_MODELFIT_PILL_NOFIT="Passt nicht"

MSG_MODELFIT_PILL_SLOW="Evtl. langsam"

MSG_MODELFIT_RECOMMENDED_TAG="  <- Empfohlen"

MSG_MODELFIT_ROW="  %s  %s (%s, %s)"

MSG_MODELFIT_SELECTED="KI-Modell: %s (%s) – beste Wahl für Ihre %s GB RAM beim erforderlichen Kontextfenster des Assistenten"

MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils installiert (lange Schritte haben jetzt ein Zeitlimit)"

MSG_OK_DEDUPE_CATCHUP_LOADED="LaunchAgent für die Kontakt-Deduplizierung im Hintergrund geladen (führt das Zusammenführen von Duplikaten nach der Installation zu Ende und stoppt dann)"

MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="Fortfahren"

MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostler will gleich Ihre Mac-Daten lesen, aber der Festplattenvollzugriff für OstlerInstaller ist noch aus. Suchen Sie \"OstlerInstaller\" in den Systemeinstellungen (jetzt bei Festplattenvollzugriff geöffnet) und schalten Sie ihn ein."

MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="Oder klicken Sie einfach auf Fortfahren, um die Installation mit weniger Daten abzuschließen – Sie können den Zugriff später gewähren und den Extraktor erneut ausführen."

MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="Festplattenvollzugriff wird noch benötigt"

# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_STEP_SETUP_COMPLETE_WRAP_UP="Questions done. Ostler is now installing in the background – this part takes roughly 15 to 60 minutes and needs nothing further from you, so you can leave it running and check back later."

MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="GNU coreutils konnte nicht installiert werden; lange Schritte laufen ohne Zeitlimit (eine Fortschrittszeile zeigt weiterhin, dass sie arbeiten)."

MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="Der LaunchAgent für die Kontakt-Deduplizierung im Hintergrund konnte nicht geladen werden. Duplikate werden trotzdem vom täglichen Wartungslauf zusammengeführt; es dauert nur länger, bis alles erledigt ist."

MSG_WARN_DEDUPE_INCOMPLETE="Der Deduplizierungslauf über den gesamten Graphen wurde nicht sauber abgeschlossen (siehe %s); es geht weiter"

MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="%s konnte nicht gelesen werden, um nach Datenexporten zu suchen. macOS blockiert den Zugriff auf diesen Ordner."

MSG_WARN_GRAPH_DB_PULL_RETRY="Der Datenbank-Download wurde nicht abgeschlossen (Versuch %s von %s). Neuer Versuch in %ss..."

MSG_WARN_GRAPH_DB_UP_RETRY="Die Wissensgraph-Datenbanken sind nicht gestartet (Versuch %s von %s). Neuer Versuch..."

MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  Die Abhängigkeit für verschlüsselte Speicherung konnte nicht in die venv des Konversationsspeichers installiert werden; die Gesprächsanreicherung wird nicht laufen."

MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  Quelle der Abhängigkeit für verschlüsselte Speicherung unter SCRIPT_DIR nicht gefunden; das Konversationsspeicher-Modul kann nicht laden und die Gesprächsanreicherung wird nicht laufen."

MSG_WARN_PREFS_HEADLINE_HINT="Das bedeutet meist, dass kein Musik-/Essens-Export (Spotify, Apple Music, Uber Eats, Google Takeout) vorhanden war oder die Daten nicht kategorisiert wurden. Fügen Sie diese Exporte hinzu, führen Sie es über die Einstellungen erneut aus und bauen Sie dann das Wiki neu."

MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="%s Präferenzen importiert, aber keine landete unter Food, Music oder Professional. Ihre Food- und Music-Wikiseiten werden leer sein."

MSG_WARN_PREFS_UNCATEGORISED="%s von %s Präferenzen (%s%%) haben keine Kategorie und erscheinen auf keiner Themenseite. Prüfen Sie das Format des Quell-Exports."
