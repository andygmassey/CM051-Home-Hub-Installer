#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to nl by l10n/ostler_l10n.py.
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

MSG_STEP_CHECKING_PREREQUISITES="Vereisten controleren"
MSG_STEP_RUNNING_HEALTH_CHECK="Statuscontrole uitvoeren"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="Verbind je iPhone en Watch"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="Configuratie (een paar korte vragen, daarna gaat het zelf verder)"
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
MSG_STEP_SETUP_COMPLETE_WRAP_UP="Vragen klaar. Ostler wordt nu op de achtergrond geïnstalleerd, in ongeveer 45 minuten tot een paar uur. Drie dingen hebben nog jou nodig: als macOS vraagt om ontwikkelaarstools te installeren, klik je op Installeer; tegen het einde is er een minuut configuratie (Volledige schijftoegang inschakelen); en helemaal aan het einde, na de statuscontrole, log je in bij Tailscale en geef je de assistent toestemming om Herinneringen te gebruiken. Tussendoor kun je het laten draaien."
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="Vragen klaar. Ostler wordt nu op de achtergrond geïnstalleerd, in ongeveer 45 minuten tot een paar uur. Drie dingen hebben nog jou nodig: als macOS vraagt om ontwikkelaarstools te installeren, klik je op Installeer; tegen het einde is er een minuut configuratie (Volledige schijftoegang inschakelen); en helemaal aan het einde geef je de assistent toestemming om Herinneringen te gebruiken. Tussendoor kun je het laten draaien."

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="en voer opnieuw uit: ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="De assistent wordt opnieuw gestart zodat hij Volledige schijftoegang kan gebruiken om je berichtengeschiedenis in Berichten te lezen. Een herstart zorgt ervoor dat een net verleende toestemming ingaat; als je die nog niet hebt verleend, blijft het Doctor-dashboard je begeleiden."
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="Je assistent draait en heeft Volledige schijftoegang, dus hij kan de bestanden lezen die hij nodig heeft."
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="Je assistent draait, maar heeft nog geen Volledige schijftoegang. Zolang je die niet inschakelt, kan Ostler Berichten, Mail, Agenda, Herinneringen, Notities, Foto's, Safari, Contacten of WhatsApp niet actueel houden en je map Documenten niet lezen. Wat al is gelezen, blijft bewaard. Het Doctor-dashboard begeleidt je bij het inschakelen."
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="Je assistent draait. We konden niet controleren of hij Volledige schijftoegang heeft op deze Mac, dus dit is geen bevestiging in welke richting dan ook. Het Doctor-dashboard laat het je weten zodra het kan kijken."
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="Zichtbare Apple Mail-accounts: %s (ter informatie)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mail lijkt nog geen lokale berichten te bevatten. Doctor meldt een vervolgactie als er binnen 24 uur geen e-mail binnenkomt."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mail heeft berichten in de cache. Ostler leest ze bij de volgende uurlijkse ronde in."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="Apple Mail is geselecteerd, maar er zijn nog geen lokale berichten om te lezen op deze Mac. Open Apple Mail en voeg een account toe (Systeeminstellingen > Internetaccounts, vink daarna Mail aan) en laat een eerste synchronisatie voltooien."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="Zodra er e-mail is binnengekomen, voer je opnieuw uit: ostler-fda. Ostler pakt het automatisch op; verder is niets nodig."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="Apple-notarisatie wordt bij de eerste start door Gatekeeper gecontroleerd."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="beschikbaar is, slaat het installatieprogramma deze stap automatisch over."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="Betatesters met toegang kunnen PWG_PIPELINE_REPO=<url> instellen en opnieuw uitvoeren."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="Betatesters met toegang kunnen PWG_KNOWLEDGE_REPO=<url> instellen en opnieuw uitvoeren."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="Browserextensies overgeslagen (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  Gekloond naar %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture werkt alleen op Apple Silicon. Installatie op deze machine wordt overgeslagen."
MSG_INFO_CM042_LOGS_AT="RemoteCapture-logbestanden: %s/ostler-remotecapture.log (en .err)"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="Een eerdere installatie liet Ostler RemoteCapture bij het inloggen starten. Dit is gestopt en start niet meer."
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="Ostler RemoteCapture is niet geïnstalleerd: je hebt ervoor gekozen gesproken transcriptie uit te laten. Zet het aan in Instellingen en voer het installatieprogramma opnieuw uit als je van gedachten verandert."
MSG_INFO_CM042_TCC_PRE_PROMPT="Bij de eerste start vraagt Ostler RemoteCapture macOS om toestemming voor Schermopname en Microfoon. Geef beide, zodat gesprekken en vergaderingen lokaal getranscribeerd kunnen worden. Er verschijnt geen paarse opname-indicator in je menubalk, want audio wordt bewust ongemerkt opgevangen."
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
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="Ostler bewaart je persoonlijke wiki en je gespreksgegevens onder Documenten/Ostler, op deze Mac. Ze zijn van jou en blijven op deze machine. Om ze te schrijven heeft Ostler toegang nodig tot je map Documenten, dus macOS kan hierom vragen tijdens de configuratie en later vandaag opnieuw, wanneer Ostler je wiki voor het eerst ordent. Het verzoek kan van python3.11 lijken te komen, het meegeleverde hulpprogramma waarmee Ostler je bestanden schrijft. Klik op Sta toe wanneer het verschijnt. Als je het mist of weigert, kun je het op elk moment inschakelen in Systeeminstellingen, onder Privacy en beveiliging, dan Bestanden en mappen. Vanaf dan worden je wiki en gespreksgegevens geschreven."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  Geheugenengine voor gesprekken geïnstalleerd in venv."
MSG_INFO_HUB_APP_VERIFYING="Ostler.app controleren op %s"
MSG_INFO_HUB_APP_STAGING="Ostler.app vanuit %s in /Applications plaatsen"
MSG_INFO_HUB_APP_DRAG_HINT="Open de installatie-DMG en sleep zowel Ostler.app als OstlerInstaller.app naar de snelkoppeling Programma's, en voer het installatieprogramma daarna opnieuw uit."
MSG_OK_HUB_APP_PRESENT="Ostler.app is al aanwezig op %s; handtekening geverifieerd."
MSG_OK_HUB_APP_STAGED="Ostler.app geïnstalleerd op %s"
MSG_WARN_HUB_APP_NOT_FOUND="Ostler.app is niet gevonden in /Applications en er is geen meegeleverde kopie beschikbaar."
MSG_WARN_HUB_APP_VERIFY_FAILED="Verificatie van handtekening of notarisatie van Ostler.app is mislukt. De bundel blijft staan zodat support hem kan onderzoeken."
MSG_OK_UNINSTALLER_APP_STAGED="Ostler Uninstaller.app geïnstalleerd op %s"
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="Kan Ostler Uninstaller.app niet in /Applications plaatsen. Je kunt Ostler nog steeds verwijderen met: ~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="Doctor-agent klonen..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="E-mailingest-scripts klonen..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Hub-power-scripts klonen..."
MSG_INFO_CLONING_IMPORT_PIPELINE="Importpipeline klonen..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="Wiki-recompile-scripts klonen..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima is geïnstalleerd maar draait niet. Het wordt gestart."
MSG_INFO_COLIMA_START_ATTEMPT="Colima starten (poging %s van %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="Kan contacten niet exporteren. Je kunt ze later handmatig importeren."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="Kan contactkaart niet lezen. Geen probleem – we vragen het je gewoon."
MSG_INFO_CONTACT_CARD_WILL_ASK="We vragen je zo meteen naar je naam en land. Je contacten worden later gelezen via de volledige schijftoegang die je verleent, en er verlaat niets deze Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  Python-venv maken in %s..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="Inhoudsstructuur voor gebruikers maken in %s/"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="Dagelijkse tick. Handmatig uitvoeren: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="Desktop-Hub (zonder batterij) gedetecteerd: slaapstand wordt systeembreed uitgeschakeld"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker is niet geïnstalleerd. Colima, Docker CLI en de docker-compose-plug-in worden geïnstalleerd (lichtgewicht, Docker Desktop is niet nodig)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="Doctor-agentbestanden zijn niet meegeleverd met het installatieprogramma."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="E-mailingest-scripts zijn niet meegeleverd met het installatieprogramma."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="De e-mailingest-scripts ontbreken in het installatiepakket. Download de .app opnieuw van ostler.ai/install en probeer het opnieuw."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="E-mailingest-scripts zijn niet meegeleverd en --allow-plaintext is opgegeven; de installatie van de LaunchAgent wordt overgeslagen. Toekomstige e-mails worden niet verwerkt."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  Bestaande checkout op %s; bijwerken..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Gmail-mbox uitpakken uit het Takeout-zipbestand (dit kan bij grote archieven een minuut duren)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="FDA-extractiemodule is niet meegeleverd. Directe data-extractie wordt overgeslagen."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Je eerste 30 dagen Ostler Pro activeren..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Ostler Pro kost na de proefperiode \$9.99 USD per maand. Abonneer je in de Ostler app op je iPhone."
MSG_INFO_FOUND_GMAIL_MBOX_MB="Gmail-mbox gevonden op %s (%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Google Takeout-zipbestand gevonden op %s (%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="Volledige schijftoegang gedetecteerd – volledige extractie beschikbaar."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="GDPR-exports gedetecteerd, maar de importpipeline is nog niet beschikbaar."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="Import van GDPR-exports wordt beschikbaar zodra de pipeline uitkomt."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="Downloads, Bureaublad en Documenten worden doorzocht op AI-exports (Google Takeout, Meta-downloads, LinkedIn enzovoort) die je mogelijk hebt bewaard. macOS toont drie meldingen voor maptoegang – sta ze alle drie toe. Het duurt in totaal ongeveer 5-10 seconden. Tijdens de scan wordt niets verplaatst of gekopieerd; we kijken alleen wat er staat."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS vraagt mogelijk toestemming om je Agenda te lezen. Sta dit toe zodat Ostler het deel van je kennisgraaf met afspraken en evenementen kan opbouwen. (Agendagegevens blijven op deze Mac.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS vraagt toestemming voor Downloads. Klik op OK."
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS vraagt toestemming voor Bureaublad. Klik op OK."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS vraagt toestemming voor Documenten. Klik op OK."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="Volledige schijftoegang verleend. De volgende macOS-melding (Berichten-automatisering) wordt voorbereid..."
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="Geen antwoord op de toestemmingsvraag voor Berichten, dus we gingen verder. Je berichten worden pas gelezen als dit is toegestaan. Ostler vraagt het later opnieuw, of je kunt het verlenen in Systeeminstellingen > Privacy en beveiliging > Automatisering."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="Xcode Command Line Tools zijn nodig. macOS vraagt om toestemming om ze te installeren – zoek naar een klein grijs venster (zie je het niet, druk dan op Cmd+Tab of kijk in je Dock). Klik op Installeer. De tools worden op de achtergrond gedownload terwijl je de vragen hieronder beantwoordt."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  De Command Line Tools worden nog ingesteld (%ss). Als een klein grijs macOS-venster vraagt om ontwikkelaarstools te installeren, klik dan daarin op Installeer – deze stap wacht daarop. (Druk op Cmd+Tab of kijk in het Dock als je het niet ziet.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="Wachten tot de Command Line Tools zijn geïnstalleerd (bijna klaar)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="Elk uur een controle. De eerste keer worden de e-mails van de afgelopen 5 jaar opgehaald."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="Oude iMessage-bridge-LaunchAgent wordt uitgeschakeld (enkele machine, v1.0)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Hub op netstroom (geen accu gevonden), hub-power-LaunchAgent wordt overgeslagen."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Hub-powerscripts zijn niet meegeleverd met het installatieprogramma."
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="Laptop-Hub. Werkt door zolang het scherm openstaat en de laptop op netstroom zit."
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="Klap je het scherm dicht of laat je hem ongebruikt op de accu staan, dan zet macOS hem in de sluimerstand."
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="Zolang de Hub slaapt, ontvangt de assistent niets."
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="Berichten die in die tijd binnenkomen, worden bij het ontwaken niet opgehaald."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="Het scherm mag dicht blijven in de modus voor gesloten scherm."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="Daarvoor heb je netstroom plus een extern scherm, toetsenbord en muis nodig."
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="Docker en Ollama pauzeren op de accu en gaan verder op netstroom."
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="Na een herstart blijft deze Mac door FileVault op het inlogscherm staan."
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="Ostler start zodra je inlogt."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="Assistant-API meegeleverd met het installatieprogramma; de meegeleverde broncode wordt gebruikt."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="Broncode van de Assistant-API niet meegeleverd; de Ostler app op je iPhone krijgt beperkte toegang."
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="Runtime-afhankelijkheden van de Assistant-API worden geïnstalleerd (phonenumbers, httpx)..."
MSG_WARN_ICAL_SERVER_DEPS_FAILED="Kon de runtime-afhankelijkheden van de Assistant-API (phonenumbers/httpx) niet installeren; Personen en Tijdlijn blijven mogelijk leeg tot de volgende installatie."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Als het Tailscale-venster verschijnt, log je in met Apple / Google / Microsoft."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="Tailscale wordt geopend zodat je kunt inloggen..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="Begrepen – Ostler installeert vanaf hier grotendeels zelf. Tegen het einde heeft het je ongeveer twee minuten nodig: Volledige schijftoegang inschakelen en daarna inloggen bij Tailscale, zodat je iPhone en Watch deze Mac overal kunnen bereiken. We openen je browser voor het inloggen."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale overgeslagen – de Ostler app op je iPhone werkt alleen op je wifi-netwerk thuis. Je kunt dit later instellen via Instellingen."
MSG_INFO_TAILSCALE_STILL_WAITING="Wacht nog op het inloggen bij Tailscale (%ss verstreken) – rond het inloggen af in het Tailscale-venster."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="Volledige schijftoegang verleend; de assistent wordt opnieuw gestart om de nieuwe toestemming op te pakken."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="Systeeminstellingen + Finder worden geopend om je te helpen Volledige schijftoegang aan de assistent te geven..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="De Ostler-assistent wordt bij macOS geregistreerd zodat hij als schakelaar verschijnt in Volledige schijftoegang..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="Volledige schijftoegang is nog niet verleend. Het Doctor-dashboard blijft de kaart tonen tot de toegang is verleend."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant heeft al Volledige schijftoegang; verdere actie is niet nodig."
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="Hier heb je ongeveer twee minuten nodig: schakel nu Volledige schijftoegang in voor de assistent en log in de volgende stap in bij Tailscale. Daarna kun je Ostler zelf laten afronden."
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="Hier heb je ongeveer een minuut nodig: schakel Volledige schijftoegang in voor de assistent. Daarna kun je Ostler zelf laten afronden."
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="\"%s\" staat al in Volledige schijftoegang, dus je hoeft het alleen in te schakelen. Je hoeft niets uit Finder te slepen."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Controleren of de Ostler-assistent Volledige schijftoegang heeft..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="De assistent kan de geschiedenis van Berichten lezen; het iMessage-kanaal werkt."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="De Ostler-assistent heeft nog geen Volledige schijftoegang. Die is nodig om de eigen apps van je Mac actueel te houden, met of zonder Berichten. Als je dit nu overslaat, begeleidt het Doctor-dashboard je door de Systeeminstellingen."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="De LaunchAgent van de assistent is niet geladen; de iMessage-controle op Volledige schijftoegang wordt overgeslagen."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="De Evernote-importfunctie in Doctor toont een melding 'service niet beschikbaar'"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Importpipeline niet meegeleverd met het installatieprogramma."
MSG_INFO_INSTALLING_CM042="Ostler RemoteCapture v%s installeren (transcriptie van gesprekken en vergaderingen)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="Engine voor gespreksgeheugen installeren vanuit %s..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  Engine voor gespreksgeheugen installeren in venv..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="Colima + Docker CLI installeren..."
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="GNU coreutils installeren (voor tijdslimieten bij lange stappen)..."
MSG_INFO_INSTALLING_HOMEBREW="Homebrew installeren..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="Knowledge-service installeren vanuit %s..."
MSG_INFO_INSTALLING_OLLAMA="Ollama installeren..."
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  Afhankelijkheden van de gegevensextractiemodule installeren..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Apple Mail-lezer installeren in een eigen venv..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  ostler-knowledge installeren in venv..."
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  Afhankelijkheid voor versleutelde opslag installeren in de gespreksgeheugen-venv..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Safari-extensie installeren in /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="Python-afhankelijkheden voor beveiliging installeren..."
MSG_INFO_INSTALLING_SQLCIPHER="SQLCipher installeren..."
MSG_INFO_INSTALLING_TAILSCALE="Tailscale installeren..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="Ondersteuning voor Intel staat niet op de roadmap; dien een verzoek in als je dit nodig hebt."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Knowledge-service is meegeleverd met het installatieprogramma; de meegeleverde broncode wordt gebruikt."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Knowledge-service niet geïnstalleerd: PWG_KNOWLEDGE_REPO is leeg."
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="Deze Mac is een laptop. Als jouw Hub blijft hij werken zolang het scherm openstaat en de Mac op netstroom is aangesloten."
MSG_INFO_LAPTOP_HUB_SLEEP_COST="Als je het scherm sluit, of de Mac op batterij laat rusten, zet macOS hem in de sluimerstand. De assistent ontvangt dan niets, en berichten die in die tijd binnenkomen, worden bij het ontwaken niet opgehaald."
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="Het scherm kan dicht blijven in de modus met gesloten scherm, waarvoor netstroom plus een extern scherm, toetsenbord en muis nodig zijn."
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="Een Hub op een Mac mini of Mac Studio blijft uit zichzelf wakker, als je liever op een van die Macs installeert."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="later in Systeeminstellingen > Privacy en beveiliging > Volledige schijftoegang"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  start om de status van cron-delivery + imessage-tcc te controleren)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="Licentie: %s valt onder Apache 2.0. Volledige tekst: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licentie: %s – controleer de upstream-voorwaarden vóór commercieel gebruik."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="lokale opslag – Google merkt nooit dat Ostler bestaat."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="Logs: %s/email-ingest.log (en .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="Logs: %s/ostler-assistant.log (en .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="Logs: %s/wiki-recompile.log (en .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="MacBook-Hubs: stel PWG_HUB_POWER_REPO=<url> in en voer het opnieuw uit."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="MacBook-Hub gedetecteerd: nooit-sluimeren wordt alleen op netstroom ingesteld (hub-power regelt de overgangen naar batterij)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Opstellingen met Mac mini of Mac Studio worden hierdoor niet beïnvloed (altijd op netstroom)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Gegevens van de Mac zelf (iMessage, Safari enzovoort) zijn hierboven uitgelezen."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="Handmatig herstarten: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="Handmatig uitvoeren: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="Installatie van com.ostler.meeting-brief-sender wordt overgeslagen (functie van v1.0.1; endpoints nog niet beschikbaar)."
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="De geheugenopschoning wordt overgeslagen (niet meegeleverd met dit installatieprogramma); tot die er is, wordt niets automatisch lager gewogen."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="bericht wanneer de feature flag later wordt ingeschakeld."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="Hulp nodig? Mail naar support@ostler.ai. We streven ernaar binnen 2 werkdagen te antwoorden."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="Geen kanalen ingesteld. Voer later uit: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="Een verouderde config.toml in de hoofdmap van de werkruimte is verwijderd; de actieve assistentconfiguratie staat in assistant-config/."
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="Er zijn nu geen FDA-bronnen beschikbaar. Je kunt Volledige schijftoegang verlenen"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="Geen GDPR-exports gevonden in Downloads, Bureaublad of Documenten."
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="Kan %s niet lezen om naar data-exports te zoeken. macOS blokkeert de toegang tot die map."
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="Verleen toegang in Systeeminstellingen > Privacy en beveiliging > Bestanden en mappen (of Volledige schijftoegang) en voer opnieuw uit, of wijs Ostler hieronder handmatig naar je exportmap."
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="Kan een of meer mappen niet scannen op data-exports omdat macOS de toegang blokkeerde. Verleen toegang en voer opnieuw uit, of wijs me handmatig naar je exportmap."
MSG_INFO_OPENING_CHROME_WEB_STORE="Chrome Web Store wordt geopend: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="ostler-assistant-binary niet geïnstalleerd; doctor-controle wordt overgeslagen"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: uitgesteld (daemon is mogelijk nog"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="De ostler-assistant-binary uit deze DMG wordt gebruikt (installatiepad zonder internet)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge geïnstalleerd in venv."
# NEEDS REVIEW: Source is a line fragment ('before installing' likely continues with an object on the next line); Dutch rendering may not join correctly with the continuation.
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler toont een extra toestemmingsscherm voordat de installatie begint"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  Overschrijf de bronrepository voor de gespreksgeheugen-engine via de omgevingsvariabele die staat beschreven in ./install.sh --help."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  Overschrijf de bronrepository met PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  Overschrijf de bronrepository met PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  Overschrijf de bronrepository met PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  Overschrijf de bronrepository met PWG_PIPELINE_REPO=<url> ./install.sh"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Toestemmingsregistraties en regio worden opgeslagen..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="Fase 3: accubewaker actief (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="Je adresboek wordt gelezen (grote bibliotheken kunnen een paar minuten duren – sluit het installatieprogramma niet)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="Beleid overschrijven: bewerk ~/.ostler/power.conf (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="Toestemming voor iMessage-automatisering wordt gecontroleerd (alleen lezen)..."
MSG_INFO_PULLING_GRAPH_DB_IMAGES="De kennisgrafiek-databases worden gedownload (alleen bij de eerste keer). Dit kan bij een verse installatie een minuut duren..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="nomic-embed-text wordt opgehaald (274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="%s (%s) wordt opgehaald... dit kan een paar minuten duren."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="Quarantaine-xattr gewist. Zodra de Developer-ID-build"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Safari, iMessage, Notities, Agenda, Foto's, Herinneringen en Mail worden gelezen..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="Je contactkaart wordt gelezen om je gegevens vooraf in te vullen..."
MSG_INFO_REGION_EU_EEA_SOURCE="Regio: EU/EER (%s, bron: %s)"
MSG_INFO_REGION_SOURCE="Regio: %s (bron: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="Regio: Verenigd Koninkrijk (bron: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="Regio: Verenigde Staten (bron: %s)"
MSG_INFO_REPO_URL="Repo-URL: %s"
MSG_INFO_REPO_URL_2="Repo-URL: %s"
MSG_INFO_REPO_URL_3="Repo-URL: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="Kies nu de wachtzin waarmee je je Hub ontgrendelt. Die typ je elke keer als je de Hub-interface start."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="Herstelwachtzin overgeslagen. (Verouderd: v1.0 vereist altijd een wachtzin.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="Bestaande installatie van de Doctor-agent wordt hergebruikt op %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="Bestaande email-ingest-installatie wordt hergebruikt op %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="Bestaande hub-power-installatie wordt hergebruikt op %s"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="Bestaande sleutel voor de browserextensie wordt hergebruikt op %s"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="De Ostler-extensie voor Chrome maakt geen deel uit van deze versie."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="E-mailgesprekken: niet ingesteld, omdat je geen toestemming hebt gegeven dat Ostler berichten van andere mensen leest."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="E-mailgesprekken: niet ingesteld, omdat Apple Mail niet is ingesteld op deze Mac."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="Berichtengesprekken: niet ingesteld, omdat je geen toestemming hebt gegeven dat Ostler berichten van andere mensen leest."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="Berichtengesprekken: niet ingesteld, omdat er geen Berichten-geschiedenis op deze Mac is."
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  Laat Ostler een gesprek transcriberen en dit wordt vanzelf ingeschakeld."
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="Gesproken gesprekken: nog niet ingesteld, omdat er geen transcripties zijn om te lezen."
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="Gesproken gesprekken: uitgeschakeld, omdat de map Transcripts is verwijderd sinds Ostler is geïnstalleerd."
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  Maak %s opnieuw aan om het weer in te schakelen. Ostler maakt het niet voor je aan."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="WhatsApp-gesprekken: niet ingesteld, omdat je geen toestemming hebt gegeven dat Ostler berichten van andere mensen leest."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="WhatsApp-gesprekken: niet ingesteld, omdat WhatsApp is uitgeschakeld."
MSG_INFO_CHROME_HISTORY_STILL_READ="  Ostler leest nog steeds je Chrome-geschiedenis, dus pagina's die je hebt bezocht worden onthouden. Live vastleggen tijdens het browsen werkt voorlopig alleen in Safari."
MSG_INFO_REUSING_EXISTING_JWT_SECRET="Bestaande JWT_SECRET wordt hergebruikt in %s"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="Bestaand PWG-servicetoken wordt hergebruikt op %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="Bestaande wiki-recompile-installatie wordt hergebruikt op %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="Safari-extensiebundel niet aanwezig in deze installerversie (wordt overgeslagen)"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="Nog één handmatige stap: open Safari, kies Safari > Instellingen > Extensies en vink Ostler aan om het in te schakelen."
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="Zoeken naar AVG-gegevensexports..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="Stel PWG_DOCTOR_REPO=<url> in en voer opnieuw uit om te installeren."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="Stel PWG_HUB_POWER_REPO=<HR015 url> in en voer opnieuw uit om te installeren."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="Gespreksmodel overgeslagen. Haal het later op: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Colima wordt gestart (lichtgewicht Docker-runtime)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Docker Desktop wordt gestart..."
MSG_INFO_STARTING_OLLAMA="Ollama wordt gestart..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="Een verouderd Colima-opstartonderdeel van een oudere versie wordt verwijderd..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="De oude Ollama-formula (zonder llama-server) wordt verwijderd; overstappen naar de Ollama-app..."
MSG_INFO_VERIFYING_EMBEDDINGS="Controleren of de embedding-engine vectoren teruggeeft..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="Kon Ollama niet automatisch starten. Laad het met: launchctl bootstrap gui/\$(id -u) %s – voer daarna het installatieprogramma opnieuw uit."
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="Ollama is niet gestart via de achtergrondservice; het wordt voor deze run direct gestart..."
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  starten; voer na de eerste keer \`ostler-assistant doctor\` uit"
MSG_INFO_SYMLINKING="  Symlink maken voor %s -> %s"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(Systeeminstellingen > Internetaccounts). Ostler leest uit de"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(De rest van Ostler werkt ook zonder het Doctor-dashboard.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="Dit is voorlopig normaal. GDPR-import komt beschikbaar in een toekomstige update."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="Dit duurt meestal 15 tot 45 minuten en kan langer duren als je veel geschiedenis hebt of een tragere Mac. Dat is normaal – het werkt gewoon en zit niet vast, dus je kunt het gerust laten draaien..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="Dit leest macOS-databases rechtstreeks uit – geen export nodig."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="Tip: voeg je Gmail eerst toe aan Mail op je Mac als je die wilt gebruiken"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="Om later te installeren zodra je toegang hebt:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="iCloud-synchronisatie starten voor %s (op de achtergrond, alleen bij de eerste keer)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (UK GDPR artikel 9 - vereist voor gegevens in bijzondere categorieën)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="Bestaande pipeline bijwerken..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="Gebruikersmap is al aangekondigd (markering aanwezig); overgeslagen"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="De lokale webzoekmachine wordt gedownload (ongeveer 3,5 GB). Bij een eerste installatie is dit de langste stap en kan het tot een uur duren. Er is geen voortgangsbalk, dus een lange stilte is normaal en betekent niet dat de installatie vastzit."
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane reageert niet (optioneel; zie waarschuwingen bij fase 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="Bekijk op elk moment met: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="Spraakherkenning blijft uit. Je kunt dit later inschakelen in Instellingen."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="Wachten tot je bent ingelogd bij Tailscale (maximaal 3 minuten)..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="Toegang op afstand via Tailscale is niet ingesteld. De Ostler-app op je iPhone werkt op je wifi-netwerk thuis; je kunt toegang op afstand later instellen via Instellingen."
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="Deze Mac is al verbonden met je Tailscale-netwerk, dus er hoeft niets te worden ingesteld. Je bestaande verbinding blijft behouden."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="Toegang op afstand: je antwoord van de vorige keer blijft behouden, namelijk overslaan. Je iOS-app werkt op je wifi-netwerk thuis en je kunt toegang op afstand later instellen via Instellingen."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="Toegang op afstand: je antwoord van de vorige keer blijft behouden, namelijk instellen."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="WhatsApp-connector blijft uit. Je kunt hem later inschakelen via Instellingen."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="WhatsApp-keepalive gepland om 08:50 + 17:50 (label com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="Wiki-inhaalslag van de eerste dag overgeslagen: de wiki-recompile-tick is niet geïnstalleerd. De dagelijkse wiki-herbouw draait nog wel, als die is geïnstalleerd."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Wiki-recompile-scripts zijn niet meegeleverd met het installatieprogramma."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="De wiki wordt niet automatisch bijgewerkt; je kunt de eerste compilatie handmatig opnieuw uitvoeren:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="Posture-markering geschreven: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="Je exports zijn veilig. Importeer ze later met: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="Je Mac-gegevens (iMessage, Safari, enz.) zijn hierboven al uitgelezen."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="Je kunt dit later toevoegen voor directe onboarding vanuit Safari, iMessage, enz."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="AI-model: %s (%s) – gekozen voor je %s GB RAM"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="Past"
MSG_MODELFIT_PILL_SLOW="Kan traag zijn"
MSG_MODELFIT_PILL_NOFIT="Past niet"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="Het assistentmodel afstemmen op je Mac (%s, %s GB RAM, assistentcontext %s tokens):"
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- Aanbevolen"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="AI-model: %s (%s) – beste keuze voor je %s GB RAM bij het contextvenster dat de assistent nodig heeft"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="Alle bronnen geselecteerd (gezichtsherkenning staat nog uit)"
MSG_OK_ALREADY_AVAILABLE="%s al beschikbaar"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon gedetecteerd"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="Apps geopend om iCloud-synchronisatie te starten"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="App-databases zijn al aanwezig (vooraf openen overgeslagen)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="Assistent-configuratie opgeslagen in %s (modus 0600)"
MSG_OK_BACKED_UP_CONTACTS="%s contacten geback-upt naar %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s geïnstalleerd in %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="Ostler RemoteCapture LaunchAgent geladen (label %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima en Docker CLI geïnstalleerd"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="Supervisor voor de containerruntime geïnstalleerd (controleert elke 5 minuten en start de runtime opnieuw als die stopt)"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="De supervisor voor de containerruntime kon niet worden ingepland. Ostler wordt nog steeds geïnstalleerd, maar als de runtime later stopt, brengt niets hem uit zichzelf terug. Je wiki blijft dan uit tot je het installatieprogramma opnieuw uitvoert."
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="De bestanden voor de supervisor van de containerruntime ontbreken in dit installatieprogramma, dus hij is niet ingepland. Ostler wordt nog steeds geïnstalleerd, maar automatisch herstel van de runtime is niet actief."
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
# NEEDS REVIEW: Section names (Mensen, Tijdlijn, Governor) must match the app's localised navigation labels; needs a human check.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="Het Doctor-dashboard van Ostler kon niet worden gestart, dus http://localhost:8089 reageert niet. De eigen pagina's van de app die hieruit lezen (Mensen, Tijdlijn, Governor, kanaalstatus) worden als niet beschikbaar getoond totdat het draait. Voer het installatieprogramma opnieuw uit om het nog eens te proberen."
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="De helper die de Mac wakker houdt kon niet worden ingepland. Ostler werkt nog steeds, maar deze Mac kan tijdens lange achtergrondtaken in slaap vallen. Ze gaan verder zodra hij wakker wordt, in plaats van 's nachts af te ronden."
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="De helper voor aanvulling op de achtergrond kon niet worden ingepland, dus nieuwe berichten, e-mails en agenda-items worden niet vanzelf opgehaald. Voer het installatieprogramma opnieuw uit om hem te herstellen."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="%s niet ingesteld: Ostler heeft geen vastgelegd antwoord van jou op de vraag die hierover gaat, dus er is niets aangenomen."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  Voer Ostler opnieuw uit en kies ervoor de vragen opnieuw te beantwoorden om het in te schakelen. (toestemmingsregistratie: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="Het dagelijkse overzicht kon niet worden ingepland, dus je ontvangt de ochtendsamenvatting niet. Al het andere werkt; voer het installatieprogramma opnieuw uit om het te herstellen."
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="De geheugenopschoning kon niet worden ingepland, dus verouderde of vervangen feiten krijgen niet automatisch een lager gewicht. Al het andere werkt; voer het installatieprogramma opnieuw uit om het te herstellen."
MSG_WARN_EXPORT_SCAN_NOT_LOADED="De Downloads-watcher kon niet worden gestart, dus bestanden die je in Downloads zet worden niet automatisch opgepikt. Alles wat al is geïmporteerd blijft ongewijzigd, en je kunt nog steeds bestanden toevoegen vanuit de app. Voer het installatieprogramma opnieuw uit om het te herstellen."
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="De helper voor het opnieuw proberen van apparaatregistratie kon niet worden ingepland. Als je iPhone tijdens de installatie is geregistreerd, verandert dit niets; zo niet, dan moet je opnieuw koppelen vanuit de app in plaats van dat het vanzelf wordt voltooid."
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="Containerruntime reageert"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="Een verouderd Colima-opstartitem van een oudere versie is verwijderd"
MSG_OK_CONFIG_SAVED_ENV="Configuratie opgeslagen in %s/.env"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Toestemmingsregistraties en regio opgeslagen in ~/.ostler/posture/"
MSG_OK_AT_REST_EXCLUDED="Uitgesloten van Spotlight en Time Machine (gecontroleerd): %s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s is NIET uitgesloten van Time Machine of Spotlight: %s. De inhoud, inclusief de geheimen van Ostler, kan naar je back-upschijf worden gekopieerd. De Doctor blijft dit tonen totdat het is opgelost."
MSG_INFO_AT_REST_FOLDER_ABSENT="%s bestaat nog niet, dus er valt niets uit te sluiten van back-ups."
MSG_WARN_DB_KEY_NOT_EXCLUDED="Het databasesleutelbestand %s is NIET uitgesloten van Time Machine, dus het kan naar je back-upschijf worden gekopieerd."
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="Je keuze voor verrijking op de achtergrond kon niet worden opgeslagen in ~/.ostler/posture/. Je keuze wordt wel toegepast op deze installatie; ze verschijnt alleen niet in een supportrapport."
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="Databases versleuteld. De Hub-services lezen de sleutel uit een beveiligd bestand in je thuismap, zodat ze starten zonder iets te vragen."
MSG_OK_DB_KEY_DELIVERED="Databasesleutel aan de Hub-services geleverd (%s, alleen door jou leesbaar)."
MSG_WARN_DB_KEY_NOT_DELIVERED="Kon de databasesleutel niet aan de Hub-services doorgeven. Ze openen databases onversleuteld totdat dit is opgelost."
MSG_INFO_DB_KEY_RECOVER_HINT="Voer dit uit om hem te herstellen en door te geven: %s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="Databases van een eerdere installatie worden versleuteld"
MSG_WARN_DB_MIGRATION_FAILED="Sommige bestaande databases konden niet worden versleuteld. Ze blijven leesbaar op schijf."
MSG_WARN_DB_KEY_MISSING_ON_RERUN="Deze installatie heeft geen databasesleutelbestand, dus de Hub-services openen databases onversleuteld."
MSG_WARN_DB_PLAINTEXT_COUNT="%s database(s) op deze Mac zijn nu leesbaar op schijf."
MSG_INFO_DB_MIGRATE_HINT="Versleutel daarna wat er al staat: %s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="Uitgestelde herhaalpoging voor apparaatregistratie geïnstalleerd (draait elk uur totdat de wachtrij leeg is)"
MSG_OK_DOCKER_RUNNING="Docker actief"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker actief (duurde %ss)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Doctor-agent gekloond van %s"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Bestanden van de Doctor-agent gebundeld met het installatieprogramma"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Afhankelijkheden van Doctor geïnstalleerd"
MSG_OK_EMAIL_CHANNEL_FOLDER="E-mailkanaal: %s (map: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="E-mail-ingest-LaunchAgent geladen (label com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="E-mail-ingest-scripts gebundeld met het installatieprogramma"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="E-mail-ingest-scripts gekloond van %s"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="WhatsApp-gespreksgeheugen instellen"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  WhatsApp-gesprekslezer geïnstalleerd."
MSG_WARN_WHATSAPP_SOURCE_FAILED="Installatie van de WhatsApp-gesprekslezer is mislukt; de WhatsApp-gespreksfeed werkt niet. Zie de uitvoer hierboven."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="Bron van de WhatsApp-gesprekslezer niet gevonden; de WhatsApp-gespreksfeed wordt overgeslagen."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="Pakket van de WhatsApp-gespreksfeed niet gevonden in dit installatieprogramma; overgeslagen. De WhatsApp-berichtgeschiedenis (met wie je berichten uitwisselde en wanneer) blijft ongewijzigd."
MSG_OK_WHATSAPP_BUNDLE_LOADED="WhatsApp-gespreksfeed-LaunchAgent geladen (label com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  De eerste ronde leest recente WhatsApp-gesprekken die je Mac heeft gesynchroniseerd (ongeveer het afgelopen jaar); alles blijft op je Mac."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  Logbestanden: %s/whatsapp-bundle.log en whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="Installatie van de WhatsApp-gespreksfeed-LaunchAgent is mislukt. Zie de uitvoer hierboven; de rest van de installatie wordt niet beïnvloed."
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  Nog niet gestart: het assistentprogramma dat deze agent uitvoert staat niet op de schijf. Gezocht naar: %s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="E-mailgespreksgeheugen instellen"
MSG_OK_EMAIL_SOURCE_INSTALLED="  E-mailgesprekslezer geïnstalleerd."
MSG_WARN_EMAIL_SOURCE_FAILED="Installatie van de e-mailgesprekslezer is mislukt; de e-mailgespreksfeed werkt niet. Zie de uitvoer hierboven."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="Bron van de e-mailgesprekslezer niet gevonden; de e-mailgespreksfeed wordt overgeslagen."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="Pakket van de e-mailgespreksfeed niet gevonden in dit installatieprogramma; overgeslagen. De e-mail-ingest die elk uur draait, wordt niet beïnvloed."
MSG_OK_EMAIL_BUNDLE_LOADED="E-mailgespreksfeed-LaunchAgent geladen (label com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Leest je recente e-mailgesprekken uit de lokale opslag van Apple Mail; alles blijft op je Mac."
MSG_INFO_EMAIL_BUNDLE_LOGS="  Logbestanden: %s/email-bundle.log en email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="Installatie van de e-mailgespreksfeed-LaunchAgent is mislukt. Zie de uitvoer hierboven; de rest van de installatie wordt niet beïnvloed."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="Geheugen voor vergaderingen en spraakgesprekken instellen"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  Lezer voor vergaderingen en spraakgesprekken geïnstalleerd."
MSG_WARN_SPOKEN_SOURCE_FAILED="Installatie van de lezer voor vergaderingen en spraakgesprekken is mislukt; de feed werkt niet. Zie de uitvoer hierboven."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="Bron van de lezer voor vergaderingen en spraakgesprekken niet gevonden; de feed wordt overgeslagen."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="Pakket van de feed voor vergaderingen en spraakgesprekken niet gevonden in dit installatieprogramma; overgeslagen."
MSG_OK_SPOKEN_BUNDLE_LOADED="LaunchAgent van de feed voor vergaderingen en spraakgesprekken geladen (label com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  Transcribeert je eigen vergaderingen en spraaknotities naar doorzoekbare gesprekken; alles blijft op je Mac."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  Logbestanden: %s/spoken-bundle.log en spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="Installatie van de LaunchAgent voor de feed voor vergaderingen en spraakgesprekken is mislukt. Zie de uitvoer hierboven; de rest van de installatie wordt niet beïnvloed."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="iMessage-gespreksgeheugen instellen"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  iMessage-gesprekslezer geïnstalleerd."
MSG_WARN_IMESSAGE_SOURCE_FAILED="Installatie van de iMessage-gesprekslezer is mislukt; de iMessage-gespreksfeed werkt niet. Zie de uitvoer hierboven."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="Bron van de iMessage-gesprekslezer niet gevonden; de iMessage-gespreksfeed wordt overgeslagen."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="Pakket voor de iMessage-gespreksfeed niet gevonden in dit installatieprogramma; wordt overgeslagen."
MSG_OK_IMESSAGE_BUNDLE_LOADED="LaunchAgent voor de iMessage-gespreksfeed geladen (label com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  Leest je recente iMessage-gesprekken uit de Berichten-opslag van deze Mac; alles blijft op je Mac."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  Logbestanden: %s/imessage-bundle.log en imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="Installatie van de LaunchAgent voor de iMessage-gespreksfeed mislukt. Zie de uitvoer hierboven; de rest van de installatie wordt niet beïnvloed."
MSG_OK_EMBEDDING_MODEL_READY="Embeddingmodel gereed"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="%s contacten geëxporteerd (worden automatisch geïmporteerd)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="Exportwatcher geïnstalleerd (scant Downloads elke 4 uur)"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  Exportwatcher nog niet gestart: het assistentprogramma dat hij uitvoert staat niet op schijf. Gezocht naar: %s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="Verzender van briefings vóór vergaderingen geïnstalleerd (controleert overdag elke 10 minuten)"
MSG_OK_MEMORY_HYGIENE_INSTALLED="Geheugenopschoning ingepland (draait dagelijks, zodat verouderde feiten actuele niet verdringen)"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="Je Mac blijft wakker op netstroom zodat Ostler blijft werken (op de batterij gaat hij nog wel slapen)"
MSG_OK_EXTRACTED="Uitgepakt naar %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="Uitgepakt uit %s bron(nen). Gegevens opgeslagen in %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="FDA wordt elke %s minuten opnieuw uitgevoerd (vangt trage iCloud-synchronisaties op en maakt het aanvullen van de agenda af)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro is 30 dagen actief. Abonneer je in de Ostler app op je iPhone om na de proefperiode door te gaan."
MSG_OK_FOUND="Gevonden: %s"
MSG_OK_FOUND_EXPORTS="Exports gevonden in %s"
MSG_OK_FOUND_GDPR_EXPORT_S="%s AVG-export(s) gevonden:"
MSG_OK_GB_FREE_DISK_SPACE="%s GB vrije schijfruimte"
MSG_OK_GB_RAM_DETECTED="%s GB RAM gedetecteerd"
MSG_OK_GDPR_IMPORT_COMPLETE="AVG-import voltooid"
MSG_OK_GIT_AVAILABLE="Git beschikbaar"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="Installatie van Command Line Tools gestart (wordt op de achtergrond gedownload terwijl je de vragen hieronder beantwoordt)."
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils geïnstalleerd (lange stappen hebben nu een tijdslimiet)"
MSG_OK_HOMEBREW_INSTALLED="Homebrew geïnstalleerd"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent voor Hub-energiebeheer geladen (label com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts voor Hub-energiebeheer meegeleverd met het installatieprogramma"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Scripts voor Hub-energiebeheer gekloond van %s"
MSG_OK_ICAL_SERVER_INSTALLED="Assistent-API geïnstalleerd (loopback 127.0.0.1:8090, via proxy van Doctor)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="LaunchAgent voor de iMessage-brug geladen (label com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts voor de iMessage-brug meegeleverd met het installatieprogramma"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="Scripts voor de iMessage-brug gekloond van %s"
MSG_OK_IMESSAGE_CHANNEL="iMessage-kanaal: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="Importpipeline meegeleverd met het installatieprogramma"
MSG_OK_IMPORT_PIPELINE_READY="Importpipeline gereed"
MSG_OK_CM048_PIPELINE_READY="Gespreksgeheugen-engine gereed."
MSG_INFO_CM048_SETTINGS_WRITTEN="  Gespreksmodellen ingesteld op %s (afgestemd op je %s GB geheugen)"
MSG_INFO_CM048_SETTINGS_KEPT="  Je bestaande gespreksinstellingen blijven behouden (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="Kennisservice gereed: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="Licentieteksten geïnstalleerd op %s/ (bron: %s)"
MSG_OK_MACOS_DETECTED="macOS %s gedetecteerd"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="Systeeminstellingen > Internetaccounts wordt geopend, zodat je een e-mailaccount kunt toevoegen. Kom terug naar dit venster zodra je bent ingelogd bij je eerste account."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="De stap Internetaccounts wordt overgeslagen. Je kunt later een e-mailaccount toevoegen via Systeeminstellingen. Doctor meldt een vervolgstap als er binnen 24 uur geen e-mail binnenkomt."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Je volledige Apple Mail-geschiedenis wordt nu opgehaald. Bij een grote mailbox kan dit wat langer duren."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="De standaardperiode van vijf jaar voor e-mail blijft behouden. Je kunt later via Doctor meer ophalen."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text is al beschikbaar"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="Ollama geïnstalleerd"
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama geïnstalleerd (alleen CLI – moet na een herstart mogelijk handmatig worden gestart)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama geïnstalleerd (desktopapp)"
MSG_OK_OLLAMA_RUNNING="Ollama actief"
MSG_OK_EMBEDDINGS_VERIFIED="Embedding-engine gecontroleerd (vectoren met 768 dimensies)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: 0 fouten in de eigen opstartcontroles"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent van Ostler-assistent geladen (label com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s klaargezet op %s (ondertekend)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s klaargezet op %s (niet ondertekend)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor actief op http://localhost:8089/doctor"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  Module voor gegevensextractie wordt correct geladen."
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Apple Mail-lezer geïnstalleerd."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  Engine voor het inlezen van e-mail geïnstalleerd."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="De opdrachten ostler-import, ostler-fda en ostler-uninstall zijn geïnstalleerd"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="Wachtzin genoteerd. Hiermee worden je databases versleuteld tijdens fase 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="Herstelwachtzin ingesteld."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="Uitleg over de wachtzin bevestigd."
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="Wachtwoord voor de Disney+-export genoteerd. Het wordt gebruikt tijdens het importeren."
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="Disney+-export wordt overgeslagen: er is geen wachtwoord opgegeven. Verder blijft alles ongewijzigd."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="Voedingsbron: netstroom (desktop-Mac, geen accu)"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="Voedingsbron: netstroom (goed – de installatie kan 45 minuten tot een paar uur duren, dus netstroom houdt alles stabiel)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="Eerdere installatie gedetecteerd. Configuratie wordt geladen..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="Meegeleverde Python %s wordt gebruikt (geen systeeminstallatie nodig)"
MSG_OK_PYTHON_INSTALLED="Python %s geïnstalleerd"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="Koppelservice werkt naar behoren"
MSG_WARN_GATEWAY_NOT_RESPONDING="Koppelservice reageert niet (127.0.0.1:8000) - koppelen met telefoon/browser en de chatassistent werken mogelijk nog niet"
MSG_OK_DOCTOR_HEALTHY="Doctor werkt naar behoren"
MSG_WARN_DOCTOR_NOT_RESPONDING="Doctor reageert niet (127.0.0.1:8089) - de app en de browser bereiken Ostler via Doctor, dus gegevens en koppeling zijn mogelijk niet beschikbaar"
MSG_OK_WIKI_HEALTHY="Je wiki werkt goed"
MSG_OK_ICAL_SERVER_HEALTHY="Assistent-API werkt goed"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="Assistent-API reageert niet (127.0.0.1:8090) - Mensen, Vergaderingen en Tijdlijn kunnen leeg blijven totdat de API start"
MSG_OK_READY="%s gereed"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="Aanbevolen bronnen geselecteerd"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="Herstelsleutel bewaard in Sleutelhanger (zoek 'Ostler' in de app Wachtwoorden)"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Safari-extensie geïnstalleerd in %s"
MSG_OK_SAFARI_EXTENSION_PAIRED="Safari-extensie gekoppeld aan deze Hub"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="Beveiliging is al bij een eerdere run ingesteld."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="Beveiligingsmodule geïnstalleerd in venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="Nieuwe JWT_SECRET aangemaakt in %s"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="PWG-servicetoken aangemaakt in %s"
MSG_OK_SEEDED_EXTENSION_TOKEN="Sleutel voor de browserextensie aangemaakt in %s"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="Services gestart (Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  Zoekcollectie voorbereid: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="De zoekcollectie %s kon nog niet worden voorbereid. De gegevensimport hieronder probeert het opnieuw en stopt als het nog steeds niet lukt, zodat je gegevens niet verloren gaan."
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="De zoekindex was nog niet op tijd gereed. De gegevensimport hieronder wacht erop, bereidt de collecties voor en stopt als de opslag nog steeds niet gereed is, zodat je gegevens niet verloren gaan."
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="Je gegevens zijn niet geïmporteerd. De zoekopslag kon niet worden voorbereid om ze te bewaren (ontbreekt: %s), en doorgaan met importeren zou ze stilzwijgend hebben weggegooid. Er is niets verloren gegaan. Voer het installatieprogramma opnieuw uit zodra de Mac niet bezig is, of stel OSTLER_QDRANT_READY_WAIT_S in om langer te wachten."
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="Je gegevensimport heeft %s records verwerkt, maar geen ervan opgeslagen: de zoekopslag heeft ze allemaal geweigerd. Het resultaat zou een lege kennisgraaf zijn die als compleet wordt getoond. Daarom stoppen we hier. Voer het installatieprogramma opnieuw uit zodra de Mac niet bezig is."
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="Het eigen logboek van de import kon niet worden gelezen, dus de controle of je gegevens echt zijn aangekomen kon niet worden uitgevoerd. Dit betekent niet dat de import is mislukt, en ook niet dat hij is geslaagd."
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="Slaapstand uitgeschakeld op netstroom, accuslaapstand behouden, wekken via het netwerk ingeschakeld"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="Slaapstand uitgeschakeld, wekken via het netwerk ingeschakeld"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale is al geïnstalleerd"
MSG_OK_TAILSCALE_INSTALLED="Tailscale geïnstalleerd"
MSG_OK_TAILSCALE_ENV_PERSISTED="Tailscale-IP opgeslagen in .env – de Ostler app op je iPhone gebruikt dit bij de eerste keer openen."
MSG_OK_TAILSCALE_IP="Tailscale-IP: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Tailscale-achtergrondservice gestart (userspace-modus, geen systeemextensie)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="De Tailscale-achtergrondservice kon niet worden gestart. Je kunt de installatie later opnieuw uitvoeren via Instellingen."
MSG_INFO_TAILSCALE_SIGN_IN_URL="Je browser wordt geopend om je bij Tailscale aan te melden: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Hub-poort %s beschikbaar gemaakt op je tailnet"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="Hub-poort %s kon niet beschikbaar worden gemaakt op je tailnet; toegang buiten je lokale netwerk kan beperkt zijn"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="Je wiki is nu leesbaar vanaf je eigen apparaten op %s – aangemeld als jij, en alleen jij."
MSG_INFO_WIKI_TAILNET_OWNER="Toegang tot de wiki is beperkt tot je Tailscale-account (%s). Andere mensen op je tailnet krijgen een 403."
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="Je wiki blijft alleen op deze Mac. Open Ostler en kies Wiki in de navigatiekolom om hem te lezen."
MSG_INFO_WIKI_TAILNET_BANNER="%s  (vanaf je eigen apparaten, via Tailscale. Dit is de enige route waarbij om de bovenstaande aanmelding wordt gevraagd.)"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="in de Ostler app. Open Ostler en kies Wiki in de navigatiekolom; je pagina's staan daar, al aangemeld."
MSG_INFO_WIKI_INTERNAL_ADDRESS="Ostler haalt die pagina's op via http://localhost:8044 op deze Mac. Dat adres is intern en er is niets waarvoor je je daar hoeft aan te melden."
MSG_INFO_WIKI_SIGN_IN="Je aanmelding voor de wiki is %s met het wachtwoord %s. Ostler vult dit voor je in, dus je hoeft op deze Mac niets te typen; je hebt het alleen nodig als je de wiki via Tailscale vanaf een van je andere apparaten opent."
MSG_INFO_WIKI_SIGN_IN_WITHHELD="Je wiki-inlog is %s. Het wachtwoord staat niet in dit logboek; het staat op je klembord en in het hieronder genoemde bestand. Ostler vult het voor je in, dus je hoeft niets te typen op deze Mac."
MSG_INFO_WIKI_PORT_LAST_STATUS="Laatste HTTP-status van de wikipoort: %s (000 betekent dat er niets antwoordde; 403 betekent dat er wel antwoord kwam, maar dat de inloggegevens zijn geweigerd)."
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="Je wachtwoord staat ook in %s, dus het klembord is niet de enige kopie."
MSG_INFO_WIKI_STILL_BUILDING="Nog bezig met bouwen. Er staan al %s pagina's op schijf en het laatste antwoord van het wikiadres was HTTP %s. De wiki verschijnt vanzelf in de Ostler app. Je hoeft niets te doen."
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="De eerste build heeft nog geen pagina's opgeleverd (zie de waarschuwingen hierboven). Je wiki opent in de Ostler app zodra hij is gebouwd, en de inlog hierboven blijft van jou."
MSG_INFO_WIKI_READINESS_NOT_MEASURED="Tijdens deze run is niet gemeten of de wiki al bereikbaar is, dus we beweren daar niets over. Je wiki opent hoe dan ook in de Ostler app, en de inlog hierboven blijft van jou."
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="Kon niet bevestigen welk Tailscale-account eigenaar is van deze Mac, dus de wiki is NIET beschikbaar gesteld op je tailnet. Hij is nog wel beschikbaar op deze Mac, in de Ostler app onder Wiki."
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="Kon de wiki niet publiceren op je tailnet; hij is nog wel beschikbaar op deze Mac, in de Ostler app onder Wiki."
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="Kon de toegangspoort van de wiki niet opnieuw laden, dus de wiki is NIET beschikbaar gesteld op je tailnet."
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="Tailscale Funnel staat aan voor %s. Funnel publiceert naar het open internet. Ostler zet Funnel nooit aan en je wiki weigert Funnel-verkeer, dus niets van Ostler is openbaar – maar als je dit niet wilde, zet het dan uit in de Tailscale-beheerconsole voor deze machine."
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="Naamsvermeldingen van derden geïnstalleerd (bron: %s)"
MSG_OK_USER_FACING_TREE_READY="Gebruikersmap gereed"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="In plaats daarvan wordt de map/het label 'Ostler' gebruikt."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane werkt goed (lokaal zoeken op het web)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane draait op http://localhost:3000 (praat met je lokale Ollama)"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="WhatsApp-connector wordt ingeschakeld (toestemming vastgelegd)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="LaunchAgent voor het bijwerken van de wiki op de eerste dag geladen (bouwt je wiki de eerste paar uur elke 30 minuten opnieuw op en stopt dan)"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="Dubbele contacten worden nog samengevoegd – grote adresboeken kunnen enkele minuten duren (%ss verstreken)"
MSG_INFO_DEDUPE_MERGED="Dubbele contacten samengevoegd"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="Het samenvoegen van dubbele contacten duurt even bij een adresboek van deze grootte. Het gaat na de installatie op de achtergrond door – je wiki wordt automatisch bijgewerkt zodra het klaar is."
MSG_WARN_DEDUPE_INCOMPLETE="De ontdubbelronde over de hele graaf is niet netjes voltooid (zie %s); we gaan door"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="Dubbele contacten volledig samengevoegd tijdens de installatie; achtergrondwerk is niet nodig"
MSG_OK_DEDUPE_CATCHUP_LOADED="LaunchAgent voor ontdubbelen van contacten op de achtergrond geladen (voegt na de installatie de resterende duplicaten samen en stopt dan)"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="De LaunchAgent voor ontdubbelen van contacten op de achtergrond kon niet worden geladen. Duplicaten worden nog steeds samengevoegd door het dagelijkse onderhoud; het duurt alleen langer voordat alles op orde is."
MSG_OK_ENRICH_AGENT_LOADED="LaunchAgent voor verrijking op de achtergrond geladen (vult details aan over je films, plaatsen, boeken en links; draait in delen gedurende ongeveer een dag)"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="De LaunchAgent voor verrijking op de achtergrond kon niet worden geladen. Je voorkeuren zijn opgeslagen en doorzoekbaar; alleen de extra referentiegegevens (regisseurs, cast, locaties) ontbreken tot hij draait."
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent voor het hercompileren van de wiki geladen (label com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Wiki-hercompileerscripts meegeleverd met het installatieprogramma"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Wiki-hercompileerscripts gekloond van %s"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="Je Voorpagina wordt ingesteld (elk uur vernieuwd)"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="Voorpagina-producer meegeleverd met het installatieprogramma"
MSG_OK_EDITOR_FRONTPAGE_LOADED="Voorpagina-LaunchAgent geladen (label com.creativemachines.ostler.editor-frontpage)"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  De eerste vernieuwing draait nu; je Voorpagina op het dashboard vult zich naarmate Ostler je voorkeuren inleest."
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  Logbestanden: %s/editor-frontpage.log en editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="Voorpagina-producer niet gevonden in dit installatieprogramma; de Voorpagina op het dashboard wordt niet vernieuwd."
MSG_WARN_EDITOR_FRONTPAGE_FAILED="Installatie van de Voorpagina-LaunchAgent is mislukt. Zie de uitvoer hierboven; de rest van de installatie wordt hierdoor niet beïnvloed."
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="Inhaalslag voor je Voorpagina wordt ingesteld"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="Inhaal-LaunchAgent voor de Voorpagina geladen (controleert elke 5 minuten tot je interesses zijn ingelezen en stopt dan)"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="De inhaal-LaunchAgent voor de Voorpagina kon niet worden geladen. Je Voorpagina en wat Ostler over je interesses weet, worden in plaats daarvan bij de volgende uurlijkse vernieuwing aangevuld."
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="De inhaalslag voor de Voorpagina wordt overgeslagen: de vernieuwing van de Voorpagina is niet geïnstalleerd, dus er is niets om opnieuw uit te voeren."
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki actief op http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="Je wiki staat klaar om te bekijken. Ostler schrijft nu op de achtergrond de samenvattingen van de pagina's, dus die worden de komende tijd aangevuld. Je kunt je wiki meteen gebruiken."
MSG_OK_YOUR_ASSISTANT_CALLED="Je assistent heet %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="Scripts voor het persoonlijke contextoverzicht zijn met het installatieprogramma meegeleverd"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="LaunchAgent voor het persoonlijke contextoverzicht geladen (label com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  Logbestanden: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="Bestaande installatie van context-refresh wordt hergebruikt op %s"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="Scripts voor het persoonlijke contextoverzicht zijn niet meegeleverd; de assistent gebruikt alleen live opzoekingen (geen altijd actieve contextsamenvatting)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="LaunchAgent voor het persoonlijke contextoverzicht is niet geladen; zie context-refresh.err. De assistent antwoordt nog steeds via live opzoekingen"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="In de gekloonde broncode van de Knowledge-service ontbreekt de pakketconfiguratie, dus de omgeving is niet ingesteld."
MSG_WARN_BUNDLE="  Bundel: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s werkt alleen op Apple Silicon (gedetecteerd: %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="Kan Ostler RemoteCapture v%s niet downloaden van %s"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="Veelvoorkomende oorzaken: de release-tag is nog niet gepubliceerd, je bent offline, of de notarisatie is nog bezig. Voer het installatieprogramma opnieuw uit zodra de release beschikbaar is."
MSG_WARN_CM042_EXTRACT_FAILED="Kan het tarball van Ostler RemoteCapture niet uitpakken; LaunchAgent wordt overgeslagen."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Laden van de Ostler RemoteCapture LaunchAgent mislukt. Zie de uitvoer hierboven en ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  Gespreksverrijking is niet beschikbaar. De rest van Ostler wordt normaal geïnstalleerd; voer de installatie opnieuw uit zonder --allow-plaintext om de geheugenengine voor gesprekken te koppelen."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="Installatie van de geheugenengine voor gesprekken mislukt (klonen)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  Gezocht naar: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  Dit betekent meestal dat de installer-.app is gebouwd zonder"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  het meegeleverde cm048_pipeline-pakket in"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Download het installatieprogramma opnieuw of"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  voer opnieuw uit met --allow-plaintext voor een dev/CI-installatie."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="Geheugenengine voor gesprekken niet gevonden. Gespreksverrijking kan zonder deze engine niet werken."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="Installatie van de geheugenengine voor gesprekken overgeslagen (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="Bron van de geheugenengine voor gesprekken gevonden, maar pyproject.toml ontbreekt; venv-installatie overgeslagen."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Colima kon niet starten. Docker Desktop wordt als alternatief geprobeerd..."
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="GNU coreutils kon niet worden geïnstalleerd; lange stappen worden zonder tijdslimiet uitgevoerd (een voortgangsregel laat nog steeds zien dat ze bezig zijn)."
MSG_WARN_COLIMA_START_RETRY="Colima is niet goed gestart (de Docker-socket was niet gereed). Opnieuw proberen over %ss..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="Veelvoorkomende oorzaken: tag v%s is nog niet gepubliceerd, je bent offline,"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  consent_cli stderr (eerste 400 tekens):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  Consolescript niet aangemaakt op %s; mogelijk ontbreekt de [project.scripts]-vermelding in pyproject.toml."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="Doorgaan omdat --allow-plaintext is meegegeven."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="Installatie wordt voortgezet. Voer \`ostler-fda\` opnieuw uit nadat je de bovenstaande fout hebt onderzocht."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="Doorgaan zonder automatisch invullen via contactkaarten – Ostler vraagt het je in plaats daarvan."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  Gesprekken die naar iMessage worden gestuurd, mislukken stilzwijgend totdat"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="Kan de sluimerstandinstellingen niet wijzigen. Schakel 'Voorkom automatische sluimerstand bij gebruik van lichtnetadapter' in bij Systeeminstellingen > Energie."
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="Kan de sluimerinstellingen niet wijzigen. Schakel 'Voorkom automatische sluimerstand' in via Systeeminstellingen > Energie."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="Kan ostler-assistant v%s niet downloaden van %s"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="Kan de Gmail-mbox niet uitpakken uit de Takeout-zip – wordt overgeslagen."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="Kan de ostler-assistant-tarball niet uitpakken; LaunchAgent wordt overgeslagen."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="Kan de Tailscale CLI niet vinden. Je kunt dit later handmatig instellen."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Kan het pakket met toestemmingsteksten (legal/) niet installeren; gaat door"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="Kan de map LICENSES/ niet installeren (niet fataal)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="Kan ostler_security niet installeren in de venv van de Hub."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="Kan THIRD_PARTY_NOTICES.md niet installeren (niet fataal)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="Kan de Doctor-agent niet ophalen (zowel meegeleverd als gekloond mislukt)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="Ostler Doctor-bestanden niet gevonden. Vereist voor het koppelen met iOS (Ostler.app iframes :8089/pair-ios)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  Gezocht in: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  Dit betekent meestal dat de installer-.app is gebouwd zonder"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  de meegeleverde doctor/agent/-bron in"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Download het installatieprogramma opnieuw of"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  voer opnieuw uit met --allow-plaintext voor een dev/CI-installatie."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Doctor-installatie afgebroken: vereist voor het koppelen met iOS. Download het installatieprogramma opnieuw of gebruik --allow-plaintext voor een dev/CI-installatie."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="Kan de e-mail-ingest-scripts niet ophalen (zowel meegeleverd als gekloond mislukt)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="Kan de hub-power-scripts niet ophalen (zowel meegeleverd als gekloond mislukt)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="Kan de wiki-recompile-scripts niet ophalen (zowel meegeleverd als gekloond mislukt)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="Kan de Chrome Web Store-URL niet automatisch openen: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="Kan region.json niet bewaren (gaat door - Doctor meldt dit)"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="Kan niet vastleggen dat de herstelsleutel is afgeleverd. De samenvatting van deze run klopt nog steeds, maar een latere run kan dit mogelijk niet zien en opnieuw waarschuwen – dat is de veilige kant om op te falen."
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="Kan niet bewaren in Sleutelhanger. Schrijf het alsjeblieft op."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="Kan Ollama niet automatisch starten."
MSG_FAIL_OLLAMA_PORT_IN_USE="Een ander programma gebruikt al poort 11434, die Ostler nodig heeft voor de lokale AI. Ostler kon zijn eigen kopie niet starten, dus de installatie is hier gestopt in plaats van half afgerond.

  Dit houdt de poort bezet: %s
  De exacte fout staat in: %s

Meestal is dit een kopie van Ollama die je al had, of een die is blijven draaien na een eerdere Ostler-installatie. Stop die (of start deze Mac opnieuw op) en voer het installatieprogramma opnieuw uit."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="Kan de pipeline niet bijwerken (offline?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="Kan pipeline_signals.json niet schrijven. De Doctor-diagnose voor lege Mail valt terug op veilige standaardwaarden tot de volgende installatie of tick."
MSG_WARN_CURL_SAID="Curl meldde:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="Map niet gevonden: %s – import wordt overgeslagen."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker is niet gestart binnen %s seconden."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker is geïnstalleerd maar draait niet. Het moet nog worden gestart."
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="De Docker-opdracht staat op deze Mac, maar er draait niets achter. Op macOS is de Docker-opdracht alleen een client – er is een engine nodig, zoals Colima of Docker Desktop, om iets echt uit te voeren. Het installatieprogramma stelt er een in."
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="Diagnose containerruntime - docker-client: %s | colima: %s | Docker Desktop: %s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="De wiki-container is gestart, maar er reageerde niets op http://localhost:8044 binnen 60 seconden. Beschouw de wiki als NIET actief - de exitcode van de startopdracht bewijst niet dat de pagina laadt."
MSG_WARN_WIKI_NOT_RESPONDING="Je wiki reageert niet (127.0.0.1:8044). Hij draait in een container, dus meestal betekent dit dat de containerruntime is gestopt. Open Ostler Doctor op http://localhost:8089/doctor om te zien waarom."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama halverwege de installatie en laten de gereedheidscontroles vastlopen."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  vroege signalen (kanalen nog aan het verbinden + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="Installatie van de LaunchAgent voor e-mailimport is mislukt. Zie de uitvoer hierboven."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="Installatie van de iMessage-bridge LaunchAgent is mislukt. iMessage-antwoorden van de assistentgebruiker werken pas als je het installatieprogramma opnieuw uitvoert of INSTALL_SNIPPET.sh handmatig uitvoert."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="De iMessage-bridgescripts zijn niet meegeleverd en --allow-plaintext is meegegeven; de installatie van de LaunchAgent wordt overgeslagen. iMessage-antwoorden van de assistentgebruiker werken niet."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="Versleuteling werkt niet."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="Versleuteling werkt niet, en"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="controleer of de vastgezette PWG_KNOWLEDGE_REPO-tag dit bevat."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  Events-toestemming voor Messages.app)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="FDA-extractor is met een niet-nulcode afgesloten (%s). Laatste 20 regels uitvoer:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="De FDA-extractiemodule is niet in dit installatieprogramma opgenomen."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="Verwacht op: Contents/Resources/ostler_fda/ (in de .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="Meest waarschijnlijke oorzaak: een buildregressie heeft de vendor-kopie weggelaten. Download de .app opnieuw via ostler.ai/install."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="FDA-extractiemodule niet meegeleverd. Doorgaan omdat --allow-plaintext is meegegeven – directe gegevensextractie wordt overgeslagen."
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="De gegevensextractiemodule staat op schijf, maar de bijbehorende afhankelijkheden zijn niet geïnstalleerd, dus de module kan niet worden geladen:"
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="Doorgaan omdat --allow-plaintext is meegegeven – de geplande gegevensvernieuwing mislukt bij elke uitvoering."
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault is NIET ingeschakeld."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="De eerste gratis maand kon nu niet worden geactiveerd; de installatie gaat door. Open de Ostler app op je iPhone zodra die is gekoppeld om dit op te lossen."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="Volledige schijftoegang is niet verleend aan Terminal."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="%s GB RAM gedetecteerd. Je krijgt de compacte assistent (gemma4:e2b) – betrouwbaar, nauwkeurig, binnen een seconde klaar bij korte vragen, met toolaanroepen en een eerlijk 'Ik weet het niet' als hij het niet weet. Voor rijkere antwoorden op langere vragen ontgrendelt 24 GB of meer de standaardassistent (qwen3.5:9b). Je kunt later van Mac wisselen door opnieuw te installeren."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="De AVG-import had fouten. Je kunt het opnieuw uitvoeren met:"
MSG_WARN_GRAPH_DB_PULL_RETRY="Het downloaden van de database is niet voltooid (poging %s van %s). Opnieuw proberen over %ss..."
MSG_WARN_GRAPH_DB_UP_RETRY="De kennisgraafdatabases zijn niet gestart (poging %s van %s). Opnieuw proberen..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="De AVG-import maakt deel uit van de standaardinstallatie. Zonder deze import kan je sociale graaf (LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google Calendar) niet worden geïmporteerd."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="De AVG-import is op deze instantie niet beschikbaar totdat de importpipeline opnieuw is geïnstalleerd."
MSG_WARN_GIT_SAID="Git meldde:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  Gezondheidscontrole mislukt: ostler-knowledge --version gaf geen uitvoer."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  Gezondheidscontrole mislukt: de gespreksgeheugenengine kon niet worden geladen (pwg-convo of de pipeline-import keerde niet netjes terug)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="Het Homebrew-installatieprogramma is afgesloten met %s. Hieronder volgen de laatste 30 regels van %s:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Homebrew-installatielog (einde) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="Doctor pip-installatie is afgesloten met %s. Hieronder volgen de laatste 30 regels van %s:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Doctor pip-installatielog (einde) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="Pipeline pip-installatie is afgesloten met %s. Hieronder volgen de laatste 30 regels van %s:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- Pipeline pip-installatielog (einde) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Installatie van de LaunchAgent voor Hub-energiebeheer is mislukt. Zie de uitvoer hierboven."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="Hub-energiescripts niet gevonden op het verwachte bundelpad."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  Er lijkt vendor/hub_power/ te ontbreken in de installatie-.app"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  in Contents/Resources/hub-power/. Accuvriendelijke beperking wordt niet geïnstalleerd; de rest van de installatie gaat door."
MSG_WARN_ICAL_SERVER_FAILED="Kon de Assistant API niet starten; de Ostler app op je iPhone heeft beperkte toegang tot de volgende installatie."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - Ophalen van image mislukt (netwerk, schijfruimte of time-out van het register)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="Kon het iMessage-FDA-signaal niet naar pipeline_signals.json schrijven. Het Doctor-dashboard toont de kaart voor Volledige schijftoegang mogelijk niet automatisch."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="De IMAP-host is leeg – probeer het opnieuw."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="iMessage-automatiseringsrechten: niet verleend (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="iMessage-automatiseringsrechten: test niet doorslaggevend."
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="iMessage-geschiedenis (chat.db) is niet leesbaar: de Ostler-daemon heeft nog geen Volledige schijftoegang. Het lezen van de iMessage-geschiedenis blijft uit totdat je dit toestaat in Systeeminstellingen > Privacy en beveiliging > Volledige schijftoegang."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="Systeeminstellingen > Privacy en beveiliging > Automatisering wordt geopend. Zet een vinkje bij de rij Berichten voor OstlerInstaller (of Terminal) om iMessage-bezorging in te stellen."
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="Geen volledig e-mailadres, dus genegeerd: %s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="Voer ten minste één volledig e-mailadres in (bijvoorbeeld you@example.com)."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage heeft ten minste één toegestaan contact nodig. Probeer het opnieuw of"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="Importpijplijn niet beschikbaar (privérepository, alleen voor bètatesters)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="Importpijplijn niet meegeleverd met het installatieprogramma. Harde fout omzeild."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Importpijplijn niet meegeleverd met het installatieprogramma. Dit is het standaard installatiepad; het Python-pakket contact_syncer hoort in de .app-bundel te zitten."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX betekent dat de assistent elke e-mail leest die je ontvangt."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Onvoldoende schijfruimte voor het wiki-uitvoervolume"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Intel-Mac gedetecteerd – de prestaties zijn beperkt. Apple Silicon wordt aanbevolen."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s is een host van een cloudprovider."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="JWT_SECRET in %s staat op de blokkeerlijst; er wordt een nieuwe gegenereerd zodat de kennisgrafiekservices importeerbaar blijven"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="JWT_SECRET in %s is te kort (%s < %s tekens); er wordt een nieuwe gegenereerd"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="Kennisrepository gekloond, maar pyproject.toml ontbreekt; venv-installatie overgeslagen."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="Installatie van de kennisservice mislukt (klonen)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="Licentie: %s wordt geleverd onder de Gemma Terms of Use van Google, niet onder Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="MacBook-installaties hebben dit nodig voor accu- en slaapstandbeheer."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="Toegang tot Contacten in macOS is geweigerd of nog niet verleend."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS vraagt hier NIET zelf om vanuit een script – je moet dit handmatig toestaan."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Mac mini-installaties worden hier niet door beïnvloed; MacBook-gebruikers moeten het opnieuw proberen."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="Mailgegevens kunnen nog steeds handmatig worden ingelezen:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  Handmatig opnieuw proberen: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  Handmatig opnieuw proberen zodra de oorzaak is verholpen:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Noch Apple Mail noch aangepaste IMAP geselecteerd – Apple Mail wordt standaard gebruikt."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="Geen toegangscode ingesteld; databases worden niet versleuteld."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="Een eerdere installatie heeft je herstelsleutel aangemaakt maar is niet voltooid, dus de sleutel is je nooit getoond. Hij kan niet worden opgehaald – hij wordt nergens bewaard, ook hier niet."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="Je wachtwoordzin werkt nog steeds en er is op dit moment niets vergrendeld. Maar als je hem ooit vergeet, is er nu geen manier om weer binnen te komen."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="Neem contact op met support om de beveiliging opnieuw in te laten stellen. Je krijgt dan een nieuwe herstelsleutel om te bewaren."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="De wachtwoordzinnen komen niet overeen. Probeer het opnieuw."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="Instellen van de wachtwoordzin mislukt. Uitvoer:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="Lege invoer. Wachtwoordzin overgeslagen."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="De wachtwoordzin moet uit minstens 12 tekens bestaan. Probeer het opnieuw."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="Een wachtwoordzin is nodig om je gegevens te versleutelen."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="Dat is geen internationaal nummer. Begin met een + gevolgd door de landcode en de rest van het nummer, bijvoorbeeld +447700900123. Probeer het opnieuw."
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama reageert niet"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s mislukt (poging %s/3). Opnieuw proberen over %ss..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="Slechts %s GB vrij. We raden minimaal 35 GB aan (Docker-images + AI-model + gegevens)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="Op batterijstroom kan de LaunchAgent voor het energiebeheer van de Hub (stap 3.14) pauzeren"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="of voer het installatieprogramma opnieuw uit en kies een ander kanaal."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="of loopt voor op de releasepipeline van fase B. Voer het installatieprogramma opnieuw uit zodra de"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor meldde %s fout(en)."

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="Ostler is klaar, maar er zijn %s fout(en) opgetreden tijdens de installatie."
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  Alle details staan in ~/.ostler/logs/install.log. Ostler start wel gewoon op; open de Doctor om te zien wat aandacht nodig heeft."
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="Ostler is klaar, maar %s installatiestap(pen) zijn niet netjes voltooid: %s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="Ostler is klaar, zonder fouten tijdens de installatie."

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant is uitgepakt, maar de --version-controle is mislukt."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Installatie van de Ostler-assistent-LaunchAgent is na 3 pogingen mislukt. Diagnose-uitvoer hierboven en hieronder."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Installatiepoging %s van de Ostler-assistent-LaunchAgent is mislukt; opnieuw proberen."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="Volledige stderr van de daemon op: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="Laatste stderr-fragment:"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s werkt alleen op Apple Silicon (gedetecteerd: %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  Kon de afhankelijkheid voor versleutelde opslag niet installeren in de venv van het gespreksgeheugen; verrijking van gesprekken wordt niet uitgevoerd."
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  Bron van de afhankelijkheid voor versleutelde opslag niet gevonden in SCRIPT_DIR; de engine voor gespreksgeheugen kan niet laden en verrijking van gesprekken wordt niet uitgevoerd."
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - ostler-wiki-compiler-image kan nog niet worden opgehaald (registry niet gekoppeld)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph reageert niet"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph is in deze fase nog niet gezond (zie de logs hierboven)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="De wachtwoorden kwamen niet overeen (of waren leeg). Probeer het opnieuw."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="De hoofdinstallatie duurt meestal 45 minuten tot een paar uur (downloads van Docker en Ollama + eerste installatie), langer bij een tragere verbinding of een Mac met jarenlange geschiedenis. Lange stille periodes zijn normaal – het downloadt en richt alles op de achtergrond in, het zit niet vast."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  pip-installatie mislukt; de engine voor gespreksgeheugen is niet beschikbaar."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  pip-installatie mislukt; email-ingest valt terug op de systeem-Python (kan tijdens het uitvoeren ook mislukken)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  pip-installatie mislukt; ostler-knowledge is niet beschikbaar."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  pip-installatie mislukt; de engine voor het inlezen van e-mail is niet beschikbaar. De LaunchAgent die elk uur draait maakt nog wel mbox-bestanden, maar kan ze pas in de graaf inlezen als dit is hersteld."
MSG_WARN_CM021_SOURCE_NOT_FOUND="Bron van de engine voor het inlezen van e-mail niet gevonden in de app-bundel; de achtergrondtaak die elk uur draait slaat e-mailbestanden op zonder ze in te lezen."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="Bron van ostler_fda niet gevonden in de app-bundel; de email-ingest-LaunchAgent valt tijdens het uitvoeren terug op de systeem-Python."
MSG_WARN_PIP_SAID="pip meldde:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="Sluit de lader aan voor de volledige installatie."
MSG_WARN_PORT_1_ALREADY_USE_PID="Poort %s is al in gebruik door %s (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - Poort 3000 is al in gebruik door een andere service"
MSG_WARN_POWER_SOURCE="Stroombron: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="Installatie van sqlcipher3 mislukt."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="Installatie van sqlcipher3 mislukt. Databases worden niet versleuteld."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="Python 3 niet gevonden. Python 3.12 wordt geïnstalleerd..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s is te oud (3.10+ vereist). Python 3.12 wordt geïnstalleerd..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant reageert niet"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         Lees https://ai.google.dev/gemma/terms vóór commercieel gebruik."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="Lees de openbare versie op https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis reageert niet"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="release beschikbaar komt, of plaats het binaire bestand handmatig:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="Opnieuw uitvoeren – typ een zelfgehoste host, of druk op Ctrl-C, start opnieuw en kies Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="voer het installatieprogramma opnieuw uit met iMessage uitgevinkt om het over te slaan."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="UITGEVOERD MET --allow-plaintext: versleuteling staat uit. NIET VOOR PRODUCTIE."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  Voer \`%s doctor\` uit na de eerste start"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="Voer 'tailscale ip --4' uit zodra je bent aangemeld en voeg het adres daarna toe aan de iOS-app."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Kopiëren van de Safari-extensie mislukt; je kunt hem later handmatig installeren"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="Safari-extensie geïnstalleerd, maar er was geen extensietoken beschikbaar om hem te koppelen; het vastleggen van browsegedrag blijft uit totdat je het installatieprogramma opnieuw uitvoert"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="Kon de Safari-extensie niet koppelen met deze Hub; het vastleggen van browsegedrag blijft uit totdat je het installatieprogramma opnieuw uitvoert"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="Beveiligingsmodule niet gevonden. De instelling van de toegangssleutel wordt overgeslagen."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  Gezocht naar: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  Dit betekent meestal dat de installer-.app is gebouwd zonder"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  het meegeleverde ostler_security-pakket in"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Download het installatieprogramma opnieuw of"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  voer opnieuw uit met --allow-plaintext voor een dev/CI-installatie."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="Beveiligingsinstelling mislukt. Doorgaan zonder databaseversleuteling."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="Beveiligingsinstelling mislukt. Uitvoer:"
MSG_WARN_SEE_STDERR_FRAGMENT="  Zie %s voor het stderr-fragment."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="Installatie van het binaire bestand wordt overgeslagen. De door de installatie-assistent geschreven config.toml blijft ongewijzigd."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Installatie van de Doctor-LaunchAgent wordt overgeslagen."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="Installatie van de e-mailimport-LaunchAgent wordt overgeslagen."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="Installatie van de LaunchAgent wordt overgeslagen. Mac mini-installaties worden hier niet door beïnvloed."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="Installatie van de LaunchAgent wordt overgeslagen. Probeer: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="Installatie van de wiki-hercompilatie-LaunchAgent wordt overgeslagen."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="Sommige poorten zijn in gebruik. Docker-containers kunnen mogelijk niet starten."
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="Poort %s wordt al gebruikt door %s (PID %s), dat bij dit account hoort. Sluit het af en voer het installatieprogramma opnieuw uit."
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="Poort %s wordt al gebruikt door een programma van een ANDER gebruikersaccount op deze Mac. Ostler kan de poort niet delen, en toch starten kan de gegevens van de twee accounts door elkaar halen. Log het andere account uit, of installeer Ostler op een Mac waarop alleen dit account de poort gebruikt."
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="Ostler kan zijn databases niet starten omdat benodigde poorten al bezet zijn."
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="Stop wat de hierboven genoemde poorten gebruikt en voer het installatieprogramma daarna opnieuw uit."
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="Kon niet controleren of poort %s vrij is. Dat is niet hetzelfde als dat de poort vrij is."
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="Een of meer poortcontroles konden niet worden uitgevoerd, dus een conflict met een ander programma kan niet worden uitgesloten."
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="Kon de meest betrouwbare poortcontrole niet uitvoeren op deze Mac, dus de onderstaande controles zijn minder grondig dan normaal."
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="Ostler kon niet bevestigen dat die poorten vrij zijn en start zijn databases niet op een poort die niet is gecontroleerd. Neem contact op met support en stuur je installatielog mee."
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="Kon een verouderd Colima-opstartitem niet verwijderen. Je wiki laadt na een herstart mogelijk niet; neem contact op met support."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="Stop de conflicterende services of wijzig de poorten in docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscale is niet binnen 3 minuten ingelogd. Je kunt hier later op terugkomen via Instellingen."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="Het Tailscale-IP-adres is naar .env geschreven, maar bij een controle erna was het niet zichtbaar. Mogelijk pakt de Ostler app op je iPhone het niet op – voer in dat geval install.sh --repair opnieuw uit."
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="Je antwoord over toegang op afstand kon niet worden opgeslagen, dus bij de volgende herinstallatie wordt het je opnieuw gevraagd. Al het andere blijft ongewijzigd."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="Installatie van Tailscale mislukt – je kunt het later installeren via tailscale.com"
MSG_WARN_TAILSCALE_STATE_UNREADABLE="Deze Mac heeft bestaande Tailscale-instellingen die niet gelezen konden worden, dus we weten niet of hij nog met je netwerk verbonden is. Kies hieronder een optie – als hij al verbonden is, kan het geen kwaad om het opnieuw in te stellen."
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="de geïnstalleerde services weigeren te starten zonder deze."
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  dit is opgelost. Zie de banner met volgende stappen voor herstel."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  om te bekijken. cron-delivery / imessage-tcc komen vaak voor"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  Probeer: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  Probeer: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="Onbekende keuze '%s'; iMessage + e-mail wordt standaard gebruikt."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="Onbekende keuze. De aanbevolen optie wordt gebruikt."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  Bijwerken mislukt; er wordt doorgegaan met de bestaande checkout."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="Gebruik voor dat account Apple Mail (hierboven aanbevolen) – Ostler slaat nooit cloudwachtwoorden op."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="INBOX wordt gebruikt. De assistent leest elke binnenkomende e-mail."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="De Vane-container is gestart, maar http://localhost:3000 reageerde niet binnen 60 s."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane (lokaal zoeken op het web) kon niet starten. Veelvoorkomende oorzaken:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  Zoeken op het web is optioneel; de rest van Ostler werkt ook zonder."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="We raden sterk aan in plaats daarvan een apart label of een aparte map te gebruiken."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp heeft een telefoonnummer nodig om de briefing te bezorgen. Probeer het opnieuw,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="De wiki is samengesteld, maar de wiki-site-container kon niet starten."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="De eerste samenstelling van de wiki is mislukt. Veelvoorkomende oorzaken:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="De LaunchAgent voor de inhaalronde van de wiki op de eerste dag kon niet worden geladen. De dagelijkse wiki-herbouw draait nog steeds; je wiki wordt gewoon de volgende dag ververst in plaats van binnen het uur."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Installatie van de LaunchAgent voor het opnieuw samenstellen van de wiki is mislukt. Zie de uitvoer hierboven."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="De wiki wordt niet automatisch bijgewerkt; handmatig opnieuw opbouwen blijft mogelijk:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="De wizardconfiguratie blijft behouden; het binaire bestand blijft klaarstaan. Handmatig opnieuw proberen:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="Je assistent heeft een naam nodig. Kies uit de suggesties hierboven of typ zelf een naam."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="Je kunt dit opnieuw toestaan via Systeeminstellingen > Privacy en beveiliging > Contacten."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="Je kunt de beveiligingsinstelling later uitvoeren: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="Mogelijk moet je het handmatig installeren: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  werkelijk: %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="De Ostler RemoteCapture-bundel was na het uitpakken niet aanwezig in %s. De release-tarball is mogelijk beschadigd."
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="%s kon niet worden aangemaakt of bereikt, dus Ostler RemoteCapture kan nergens worden geïnstalleerd. Dit is een probleem met maprechten, niet met de download."
MSG_ERR_CM042_RENAME_FAILED="Ostler RemoteCapture is correct gedownload en uitgepakt, maar kon niet naar %s worden verplaatst. De uitgepakte app staat nog in /Applications. Dit is geen ondertekeningsprobleem."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify meldde:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  Een bundel die niet overeenkomt met de gepubliceerde checksum wordt niet klaargezet."
MSG_ERR_CM042_SHA_256_MISMATCH="SHA-256 van de Ostler RemoteCapture-tarball komt niet overeen."
MSG_ERR_CM042_PIN_FAILED="Ostler kon niet bevestigen dat deze download van RemoteCapture echt is, dus hij is niet geïnstalleerd."
MSG_ERR_CM042_VERSION_UNKNOWN="Deze RemoteCapture-versie wordt door Ostler niet herkend, dus hij is niet geïnstalleerd."
MSG_ERR_CM042_SIDECAR_DISAGREES="De checksum die bij deze RemoteCapture-download is gepubliceerd, komt niet overeen met het bestand, dus het is niet geïnstalleerd."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess meldde:"
MSG_ERR_CM042_VERIFY_FAILED="Verificatie van de handtekening of notarisatie van Ostler RemoteCapture is mislukt."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv meldde:"
MSG_ERR_EXPECTED="  verwacht: %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief meldde: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="Het binaire bestand ostler-assistant op %s is geen uitvoerbaar Mach-O-bestand."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="SHA-256-waarde van de ostler-assistant-tarball komt niet overeen."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  Een binair bestand dat niet overeenkomt met de gepubliceerde checksum wordt niet klaargezet."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="Quarantaine wordt niet verwijderd en de LaunchAgent wordt niet geladen."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="Voer het installatieprogramma opnieuw uit zodra de upstream-tarball is hersteld."
MSG_ERR_URL="  url:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Intel-Macs worden niet ondersteund. Ostler heeft Apple Silicon nodig (M1, M2, M3 of M4)."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="Minimaal 16 GB RAM vereist. Je hebt %s GB. 24 GB wordt aanbevolen."
MSG_FAIL_CM042_SIGNATURE_FAILED="Installatie van Ostler RemoteCapture afgebroken: de controle van de handtekening of notarisatie is mislukt. De bundel is voor support in /Applications achtergelaten. Mail naar support@ostler.ai en voer het installatieprogramma opnieuw uit."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="Kon %s na 3 pogingen niet ophalen. Controleer je netwerk en voer het installatieprogramma opnieuw uit."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="Kon nomic-embed-text na 3 pogingen niet ophalen. Controleer je netwerk en voer het installatieprogramma opnieuw uit."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker is niet beschikbaar. Voer het installatieprogramma opnieuw uit om Colima te installeren."
MSG_FAIL_CONTAINER_CLIENT_MISSING="Het docker-commando staat niet op deze Mac, dus Ostler kan de benodigde services niet starten. Voer het installatieprogramma opnieuw uit. Als het weer mislukt, stuur ons dan het logbestand op %s."
MSG_FAIL_CONTAINER_ENGINE_ABSENT="Ostler heeft een containerruntime nodig en er reageert er geen op deze Mac. Je wiki, je kennisgraaf en je zoekindex draaien allemaal in containers, dus de installatie is hier gestopt in plaats van af te ronden terwijl ze ontbreken. Zo los je het op: open Terminal en voer 'colima start' uit, en start dit installatieprogramma daarna opnieuw. Gebruik je liever Docker Desktop, open het dan, wacht tot het walvispictogram stilstaat en probeer het opnieuw. Het volledige logbestand staat op %s."
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="Docker was niet op tijd gereed om de databases van de kennisgraaf te starten. Zorg dat Colima of Docker draait en voer het installatieprogramma opnieuw uit."
MSG_FAIL_GRAPH_DB_PULL_FAILED="Kon de images van de kennisgraaf-databases na meerdere pogingen niet downloaden. Meestal ligt dit aan het netwerk. Controleer je internetverbinding en voer het installatieprogramma opnieuw uit."
MSG_FAIL_GRAPH_DB_UP_FAILED="De databases van de kennisgraaf zijn gedownload maar konden niet worden gestart. Voer het installatieprogramma opnieuw uit. Blijft het gebeuren, open dan Terminal en voer uit: cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="Ostler kon geen geauthenticeerd verzoek naar de database van de kennisgraaf voltooien. Het probeerde het twee keer, met twee seconden ertussen, en beide pogingen werden geweigerd. We weten nog niet waarom: de database was mogelijk nog aan het opstarten, of de inloggegevens die Ostler bewaart zijn niet de verwachte. Je gegevens zijn niet aangeraakt. Het installatieprogramma opnieuw uitvoeren helpt vaak, en als dat lukt, horen we het toch graag – stuur ons het installatielogboek, want we proberen deze fout actief te reproduceren."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="De FDA-extractiemodule ontbreekt in de installatiebundel. Download de .app opnieuw van ostler.ai/install, of voer opnieuw uit met --allow-plaintext voor dev/CI."
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="De module voor gegevensextractie is geïnstalleerd maar kan niet worden geladen, dus de vernieuwing op de achtergrond zou elke keer mislukken. De volledige uitvoer is opgeslagen in %s – voer het installatieprogramma opnieuw uit en voeg dat bestand toe als je contact opneemt met support (Referentie: ERR-10-FDA-DEPS-IMPORT)."
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="Interne fout: de module voor gegevensextractie is in de app-bundel geplaatst, wat de handtekening zou breken. Dit is een buildfout, geen probleem met je Mac. Download de .app opnieuw van ostler.ai/install (Referentie: ERR-10-FDA-DEPS-UNSAFE-PATH)."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Installatie van de Doctor-afhankelijkheden is mislukt. De volledige uitvoer is opgeslagen in %s – voeg die toe als je mailt naar support@ostler.ai (Referentie: ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="Installatie van de afhankelijkheden van de importpijplijn is mislukt. De volledige uitvoer is opgeslagen in %s – voeg die toe als je mailt naar support@ostler.ai (Referentie: ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Installatie van Homebrew is mislukt. De volledige uitvoer is opgeslagen in %s – voeg die toe als je mailt naar support@ostler.ai."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="Installatie van de importpijplijn is mislukt. De contact_syncer-bundel is vereist voor de standaardinstallatie. Voer opnieuw uit met --allow-plaintext voor dev/CI, of download het installatieprogramma opnieuw en probeer het nogmaals."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="Sudo-toegang is nodig om slaapstand uit te schakelen en Homebrew te installeren. Voer opnieuw uit als je er klaar voor bent."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Noch Colima noch Docker Desktop kon starten. Installeer Docker Desktop en voer opnieuw uit."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="Onvoldoende schijfruimte (%s GB). Maak ruimte vrij en probeer het opnieuw."
MSG_FAIL_MACOS_BELOW_FLOOR="macOS %s is ouder dan Ostler ondersteunt. Ostler heeft macOS %s of nieuwer nodig: de installatie-app is daarvoor gebouwd en opent niet op oudere versies. Werk macOS bij en voer het installatieprogramma daarna opnieuw uit."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="Geen toegangssleutel ingesteld en geen bestaande beveiligingsconfiguratie. Voer opnieuw uit met --allow-plaintext voor dev/CI, of voer het installatieprogramma opnieuw uit en bevestig de Touch ID-uitleg."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="De geheugenengine voor gesprekken is vereist. Voer opnieuw uit met --allow-plaintext voor dev/CI, of herstel de ontbrekende bundel hierboven en probeer het opnieuw."
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="De meegeleverde Ostler-daemon (v%s op %s) ondersteunt het commando 'run-source' niet, dat dit installatieprogramma nodig heeft om de import via Volledige schijftoegang te laten lopen. Dit is een versieverschil binnen de installatiebundel: als dit zou worden geïnstalleerd, werkt elke importbron stilzwijgend niet meer en veroudert het product zonder zichtbare fout. Download de .app opnieuw van ostler.ai/install en probeer het nogmaals (Referentie: ERR-11-DAEMON-RUN-SOURCE-SKEW)."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="Installatie van ostler_security is mislukt. Voer opnieuw uit met --allow-plaintext voor dev/CI, of los de pip-fout hierboven op en probeer het opnieuw."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="Instellen van de toegangssleutel is mislukt. Voer opnieuw uit met --allow-plaintext voor dev/CI, of los de fout hierboven op en probeer het opnieuw."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="sqlcipher3 is vereist voor versleutelde databases. Voer opnieuw uit met --allow-plaintext voor dev/CI, of los de pip-fout hierboven op en probeer het opnieuw."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Dit installatieprogramma is alleen voor macOS."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="De installatie van de Xcode Command Line Tools is niet binnen 15 minuten voltooid. Open Terminal en voer 'xcode-select --install' uit, klik in het macOS-venster op Installeer, wacht tot het klaar is en start dit installatieprogramma daarna opnieuw."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="De installatie van Homebrew meldde succes, maar /opt/homebrew/bin/brew ontbreekt. Bekijk %s voor het volledige logboek. Herstel: open Terminal en voer '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' uit en start het installatieprogramma daarna opnieuw."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew is geïnstalleerd in /opt/homebrew/bin/brew, maar het commando 'brew' staat na shellenv eval niet in PATH. Open een nieuw Terminal-venster en start het installatieprogramma opnieuw."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' meldde succes, maar colima staat niet in PATH. Controleer %s op fouten van Homebrew. Herstel: open Terminal, voer 'brew install colima docker docker-compose' handmatig uit en start het installatieprogramma daarna opnieuw."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' meldde succes, maar de docker CLI staat niet in PATH. Controleer %s. Herstel: voer 'brew install docker' handmatig uit en start het installatieprogramma daarna opnieuw."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="De installatie van de Ollama-app meldde succes, maar het programma ontbreekt in /Applications/Ollama.app. Controleer %s. Herstel: voer 'brew install --cask ollama-app' handmatig uit en start het installatieprogramma daarna opnieuw."
MSG_FAIL_EMBED_HEALTHCHECK="Ollama draait, maar het embeddingmodel gaf geen vector terug (HTTP niet 200, of een leeg resultaat). De Mensenkaart, zoeken en bladeren zouden leeg zijn. Controleer %s. Herstel: zorg dat de Ollama-app (niet de Homebrew-formule) is geïnstalleerd en actief is en start het installatieprogramma daarna opnieuw."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' meldde succes, maar sqlcipher staat niet in PATH. Controleer %s. Herstel: voer 'brew install sqlcipher' handmatig uit en start het installatieprogramma daarna opnieuw."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' heeft /Applications/Tailscale.app niet aangemaakt. Controleer %s. Herstel: download Tailscale van https://tailscale.com/download/macos, sleep het naar /Applications en start het installatieprogramma daarna opnieuw."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' meldde succes, maar het programma python3.11 ontbreekt in /opt/homebrew/opt/python@3.11/bin/python3.11. Controleer %s. Herstel: voer 'brew reinstall python@3.11' uit en start het installatieprogramma daarna opnieuw."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="We hebben je eerdere antwoorden gevonden"
MSG_PROMPT_REUSE_SETTINGS_HELP="We hebben een eerdere installatiepoging op deze Mac gevonden. De vragen die je al hebt beantwoord (naam, naam van je assistent, tijdzone, landcode, kanalen enzovoort) worden hergebruikt, zodat je ze niet opnieuw hoeft in te voeren. Kies Ja om verder te gaan waar je gebleven was, of Nee om de vragen opnieuw van het begin te doorlopen."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Eerdere antwoorden die we vonden: naam = %s, assistent = %s, tijdzone = %s."

MSG_PROMPT_PERMS_OK_TITLE="Klaar om door te gaan?"
MSG_PROMPT_PERMS_OK_HELP="macOS vraagt om toegang tot Contacten en Bestanden en mappen. Volledige schijftoegang is optioneel en kan later worden verleend."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Volledige naam (zoals in je contacten)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Volledige naam (bijv. Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="Hoe moet je assistent je noemen?"
MSG_PROMPT_USER_ID_HELP="Een korte naam waarmee je assistent je aanspreekt (bijv. 'Andy', 'Andrew', 'mevrouw Smit'). Die zie je in je ochtendoverzichten en chatantwoorden. Dit verschilt van je volledige naam hierboven."

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
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="Hier zijn je agenda's. Klopt dit?"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="We hebben geraden van wie elke agenda is, zodat je overzicht nooit de reizen van verschillende mensen door elkaar haalt."
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="Automatisch apart gezet, niet gebruikt voor je overzicht:"
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="van jou"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="%s afspraak"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="%s afspraken"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="feestdagen"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="verjaardagen"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="Siri-suggesties"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="een agenda waarop je bent geabonneerd"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="herinneringen"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="\"%s\" gebruiken voor je overzicht?"
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="We hebben deze apart gezet omdat het lijkt op %s. Kies ja als het echt iemands agenda is."
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="Van wie is de agenda \"%s\"?"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="Wat voor soort agenda is \"%s\"?"
MSG_CONFIRM_CALENDAR_TYPE_HELP="Kies uit: persoonlijk, werk, familie, gedeeld, overig. Dit bepaalt hoe gevoelig de afspraken worden behandeld."
MSG_CONFIRM_CALENDARS_SAVED="Agenda-eigenaren opgeslagen"
MSG_CONFIRM_CALENDARS_FAILED="Kon agenda-eigenaren niet opslaan (niet erg; je kunt dit later instellen)"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="We denken dat deze profielen allemaal van jou zijn (%s). Samenvoegen tot één?"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="Deze profielen delen een sterk identiteitskenmerk met jou (een e-maildomein, LinkedIn-profiel of werkgever). Door ze samen te voegen ziet je assistent je eigen geschiedenis niet als meerdere verschillende mensen. Je kunt dit later ongedaan maken."
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="Iemand heeft dezelfde naam als jij, maar lijkt een ander persoon (%s). Ben jij dit, of is het iemand anders?"
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="Kies 'anders' om deze persoon als aparte persoon te bewaren (je assistent voegt hem of haar nooit samen met jou). Kies 'ik' alleen als jij dit echt zelf bent."
MSG_CONFIRM_IDENTITY_SAVED="Vastgelegd wie jij bent"
MSG_CONFIRM_IDENTITY_FAILED="Kon de identiteitskeuzes niet opslaan (niet fataal; je kunt ze later bevestigen)"

# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="Installeren op de achtergrond (ongeveer 45 minuten tot een paar uur)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="+%s gebruiken?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Voer de landcode in (bijv. 44 voor het VK, 1 voor de VS)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Standaardlandcode"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Wordt gebruikt om telefoonnummers te normaliseren bij het importeren van contacten en om je regio (VK / EU / VS / overig) in te stellen voor standaardinstellingen rond wettelijke naleving."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="We hebben +%s gedetecteerd. Wil je dit voor je Hub gebruiken?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Gedetecteerd op basis van je telefoonnummer hierboven. Kies Ja om het te gebruiken, of Nee om een andere landcode in te voeren."

MSG_PROMPT_TZ_CONFIRM_TITLE="Deze tijdzone gebruiken?"
MSG_PROMPT_TZ_CONFIRM_HELP="Gedetecteerde tijdzone: %s"
MSG_PROMPT_USER_TZ_TITLE="Voer de tijdzone in (bijv. Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="Hoe wil je je assistent noemen?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="De naam in het veld is een willekeurige suggestie – typ er gerust iets anders overheen. Marvin, Samantha, Joshua, Friday, Athena, Sage en Rosie zijn allemaal populaire keuzes." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Typ elke naam die je wilt – de suggestie is slechts een startpunt."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="Hoe bereikt je assistent jou?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Kies de berichtenkanalen die je assistent mag gebruiken. Je kunt dit later wijzigen in het Doctor-gedeelte van de app."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_WHATSAPP_CONSENT_TITLE="WhatsApp-berichten inschakelen voor je assistent?"
# NEEDS REVIEW: Legal acceptance wording; lawyer should confirm legal force in Dutch.
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web is een dienst van een derde partij. Door dit in te schakelen accepteer je dat je berichten via de eigen infrastructuur van WhatsApp lopen voordat ze je lokale Ostler-installatie bereiken, en dat WhatsApp (Meta Platforms Ireland Ltd) je WhatsApp-account kan opschorten, beperken of beëindigen vanwege geautomatiseerd gebruik. Je kunt dit later uitschakelen in Instellingen."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="Je WhatsApp-telefoonnummer"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Internationaal nummer met landcode, bijv. +447700900123. Alleen cijfers en een + vooraan – geen spaties, haakjes of streepjes."
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="Opgeslagen als %s. WhatsApp heeft het nummer nodig zonder spaties of haakjes."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Zet Volledige schijftoegang aan voor de Ostler-assistent"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="Systeeminstellingen is geopend bij Volledige schijftoegang."
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
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Zoek \"%s\" in de lijst en zet de schakelaar voor Volledige schijftoegang aan."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="Niet in de lijst? Sleep \"%s\" vanuit het Finder-venster naar de lijst en zet de schakelaar aan. De volgorde maakt niet uit – klik op Gereed voor of na het aanzetten; het installatieprogramma wacht tot de schakelaar echt aan staat."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="Niet in de lijst? Ostler kon geen Finder-venster voor je openen. Druk in Finder op ⌘⇧G, voer het pad hieronder in, sleep dan \"%s\" naar de lijst en zet de schakelaar aan. De volgorde maakt niet uit – klik op Gereed voor of na het aanzetten; het installatieprogramma wacht tot de schakelaar echt aan staat."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="De app staat hier: %s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="De app staat hier: %s – dit pad staat op je klembord, dus druk in Finder op ⌘⇧G, dan ⌘V en daarna op Return."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Gereed"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="Je kunt op Gereed klikken voor of na het omzetten van de schakelaar – het installatieprogramma wacht tot die echt aan staat."

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Sta Ostler toe je Mac-gegevens te lezen"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="Systeeminstellingen is geopend bij Volledige schijftoegang."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Zoek \"OstlerInstaller\" in de lijst en zet de schakelaar aan."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Klik op Gereed als je klaar bent, dan leest Ostler je Safari-geschiedenis, Notities, iMessages en Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Gereed"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="Hierna: Volledige schijftoegang voor het installatieprogramma"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="Hierna vraagt macOS je om OstlerInstaller Volledige schijftoegang te geven."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Nadat je de schakelaar hebt aangezet, toont macOS een venster waarin je kunt kiezen tussen 'Stop en open opnieuw' of 'Later'."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Klik op 'Stop en open opnieuw'. Het installatieprogramma start zichzelf opnieuw op en gaat automatisch verder vanaf deze stap."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="OK"
MSG_INFO_INSTALLER_FDA_PREWARN="Uitleg over het verlenen van Volledige schijftoegang..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="Systeeminstellingen worden geopend zodat je het installatieprogramma Volledige schijftoegang kunt geven..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="Volledige schijftoegang is verleend aan het installatieprogramma. Hierna worden Safari, Notities, iMessages en Mail gelezen."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="Volledige schijftoegang is nog steeds niet verleend. We gaan zonder verder; je kunt het installatieprogramma later opnieuw uitvoeren om Safari / Notities / iMessages uit te lezen."
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="Volledige schijftoegang voor het installatieprogramma is geregeld. Het lange deel begint nu en loopt grotendeels vanzelf, maar let op een macOS-venster dat vraagt om ontwikkelaarstools te installeren, en kom tegen het einde een paar minuten terug voor de laatste configuratie."
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="Nog één toestemming (berichtengeschiedenis voor je assistent) volgt tegen het einde, zodra je assistent is geïnstalleerd. We wijzen je dan de weg."
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="Volledige schijftoegang nog nodig"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostler staat op het punt je Mac-gegevens te lezen, maar Volledige schijftoegang voor OstlerInstaller staat nog uit. Zoek \"OstlerInstaller\" in de lijst en zet de schakelaar aan."
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="Of klik op Ga door om de installatie met minder gegevens af te ronden. Je kunt de toegang later alsnog verlenen en de extractie opnieuw uitvoeren."
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="Ga door"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="Toegestane contacten"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="Vertrouwde personen: telefoonnummers en Apple ID-e-mailadressen (gescheiden door komma's). %s antwoordt alleen aan mensen op deze lijst; berichten van anderen worden genegeerd. Minstens één vermelding is vereist.

Bijvoorbeeld:
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="E-mail lezen via Apple Mail?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Leest elk e-mailaccount dat je aan Apple Mail hebt toegevoegd (iCloud, Gmail, Outlook enzovoort) met Volledige schijftoegang. Er worden geen wachtwoorden opgeslagen. Aanbevolen voor bijna iedereen."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="Een e-mailaccount aan Apple Mail toevoegen?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="Er zijn nog geen accounts gekoppeld aan Apple Mail op deze Mac, dus Ostler heeft geen e-mail om te lezen. Kies Ja om Systeeminstellingen > Internetaccounts nu te openen (daar kun je iCloud, Gmail of Outlook toevoegen). Kies Nee om over te slaan; je kunt later een account toevoegen en Doctor meldt het als er binnen 24 uur geen e-mail binnenkomt."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="Je volledige Apple Mail-geschiedenis ophalen?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Standaard leest Ostler de laatste vijf jaar van je Apple Mail. Bewaar je meer dan dat op deze Mac en wil je alles in je kennisgrafiek hebben, kies dan Ja om nu de volledige lokale geschiedenis op te halen (bij een grote mailbox kan dit wat langer duren). Kies Nee om bij de periode van vijf jaar te blijven; je kunt die later altijd verlengen via Doctor."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="Ook een eigen IMAP+SMTP-server instellen?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="Alleen voor zelfgehoste mailboxen. Laat dit op NEE staan als je accounts bij Gmail, iCloud of Outlook zitten: die werken beter via Apple Mail hierboven."

MSG_PROMPT_IMAP_HOST_TITLE="IMAP-host"
MSG_PROMPT_IMAP_HOST_HELP="Alleen voor zelfgehoste of eigen IMAP-servers. Gebruik Apple Mail (hierboven) voor Gmail / iCloud / Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="IMAP-poort"

MSG_PROMPT_SMTP_HOST_TITLE="SMTP-host"
MSG_PROMPT_SMTP_PORT_TITLE="SMTP-poort"

MSG_PROMPT_EMAIL_USERNAME_TITLE="E-mailadres (ook gebruikt als IMAP/SMTP-gebruikersnaam)"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="Wie mag je assistent e-mailen?"
MSG_PROMPT_EMAIL_ALLOWED_HELP="Je eigen e-mailadressen, gescheiden door komma's. %s beantwoordt alleen e-mail van adressen op deze lijst; e-mail van anderen wordt genegeerd. Minstens één adres is vereist. Je eigen adres is al voor je ingevuld: pas het aan of voeg er een toe."

MSG_PROMPT_EMAIL_PASSWORD_TITLE="Wachtwoord (verborgen)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Wachtwoord voor je zelfgehoste IMAP/SMTP-server. Lokaal opgeslagen onder ~/.ostler/ en nooit naar Creative Machines gestuurd. Het wordt als platte tekst bewaard: het enige wat het beschermt zijn de bestandsrechten, die alleen jouw macOS-account toegang geven. Het wordt ook later niet versleuteld. Gebruik een app-wachtwoord in plaats van het wachtwoord van je hoofdaccount."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Bevestig wachtwoord"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="Welke map moet de assistent in de gaten houden?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="Aanbevolen: een eigen label of map (bijv. Ostler). We lezen alleen berichten daarin en laten je hoofdinbox ongemoeid."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="Typ INBOX nogmaals om te bevestigen, of klik op Ga door om 'Ostler' te gebruiken"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX betekent dat de assistent alle e-mail leest die je ontvangt. We raden sterk aan in plaats daarvan een eigen label of map te gebruiken."

MSG_PROMPT_EXPORTS_ACK_TITLE="Heb je je gegevensexports aangevraagd?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler importeert van ongeveer 20 platforms. De volledige lijst, met directe links naar de aanvraagpagina van elke aanbieder, staat op docs.ostler.ai/data-exports.

De meeste archieven komen binnen 1 tot 3 dagen per e-mail binnen. Zodra de ZIP-bestanden er zijn, zet je ze in je map Downloads en Ostler vindt ze automatisch.

Sla over wat je niet gebruikt; je kunt later altijd meer importeren."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="Doorgaan terwijl je schijf in rust ONVERSLEUTELD is?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="FileVault staat UIT op deze Mac, dus je schijf is niet versleuteld in rust.

Wat dit betekent als je doorgaat: alles wat Ostler opslaat -- je hele persoonlijke graaf (wiki, gesprekken, kennisnotities) onder ~/Documents/Ostler, plus geheimen en databases van services onder ~/.ostler -- wordt ONVERSLEUTELD naar de schijf geschreven. Iedereen die vanaf deze schijf kan opstarten, de schijf kan uitbouwen of toegang heeft tot een ontgrendelde sessie, kan alles lezen. Ostler versleutelt de meest gevoelige databases hoe dan ook met een wachtzin, maar de rest van je gegevens is slechts zo goed beveiligd als de schijf zelf.

FileVault wordt sterk aanbevolen. Je kunt het op elk moment aanzetten via Systeeminstellingen > Privacy en beveiliging > FileVault -- het versleutelt op de achtergrond, zonder opnieuw te installeren.

Kies Ja om nu door te gaan met de schijf onversleuteld in rust (dit is een bewuste, geïnformeerde keuze -- die wordt vastgelegd).
Kies Nee om hier te stoppen, zodat je eerst FileVault kunt aanzetten en daarna het installatieprogramma opnieuw kunt starten. Er is in beide gevallen niets misgegaan."

MSG_PROMPT_PASSKEY_ACK_TITLE="Klaar om schijfversleuteling in te stellen"
MSG_PROMPT_PASSKEY_ACK_HELP="De gevoelige databases van Ostler worden versleuteld met SQLCipher, met een wachtzin die je op het volgende scherm kiest. Je typt deze wachtzin elke keer dat je de Hub-interface start. Er wordt ook een aparte herstelsleutel gemaakt, die aan het eind van de installatie één keer wordt getoond. Laat macOS FileVault ingeschakeld voor volledige beveiliging in rust van alles op je Mac. Klik op Ga door wanneer je klaar bent."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="Ook een herstelwachtzin instellen? (aanbevolen)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="Kies je wachtzin"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="Deze wachtzin versleutelt je kennisgraaf en ontgrendelt de Hub-interface bij elke start. Minimaal 12 tekens. Wij kunnen hem niet voor je herstellen. We raden aan hem in een wachtwoordmanager te bewaren."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="Bevestig je wachtzin"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="Voer dezelfde wachtzin nogmaals in ter bevestiging."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="Deze tijdens de installatie importeren?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="Gevonden AVG-exports worden tijdens de installatie in je kennisgraaf geïmporteerd."

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="Exportwachtwoord voor Disney+"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="Disney+ levert zijn AVG-export als een met een wachtwoord beveiligd spreadsheet. Dat is normaal en geen probleem met je download. Voer het wachtwoord in om je kijkgeschiedenis van Disney+ nu te importeren, of laat dit leeg om over te slaan; al het andere wordt nog steeds geïmporteerd."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="Heb je data-exports klaarstaan?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler kan archieven van social media en platforms importeren – je volledige geschiedenis met vrienden, familie, plaatsen en meningen – meteen vanaf het begin. Hoe meer Ostler op dag één weet, hoe nuttiger het op dag één is. Je kunt dit ook later toevoegen; geen haast.

Vraag je data-export aan bij elk platform (Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp enz.), download de ZIP-bestanden en zet ze in je map Downloads.

Ostler zoekt standaard in ~/Downloads. Wil je een andere map? Kies er hieronder een. Anders sla je dit over en importeer je later."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="Gmail-berichten uit deze Takeout importeren?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Leest Gmail-inhoud rechtstreeks uit het Takeout-bestand. Google ziet Ostler nooit."

MSG_PROMPT_FDA_PRESET_TITLE="Van welke Mac-bronnen moet Ostler leren?"
MSG_PROMPT_FDA_PRESET_HELP="Drie voorinstellingen, of kies zelf elke bron. Gevoelige bronnen (gezichtsherkenning) staan in elke voorinstelling standaard uit – kies er bewust voor als je ze wilt."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="Aanbevolen. Omvat Apple Mail, Contacten, Agenda, Notities, Berichten, Herinneringen, Safari-geschiedenis, Safari-bladwijzers en gebeurtenissen uit Foto's (datums en plaatsen, geen gezichtsherkenning). Geschiedenis van WhatsApp Desktop en Chrome wordt automatisch toegevoegd als de app is geïnstalleerd. Sluit gezichtsherkenningsgegevens van Foto's en exportarchieven van derden uit."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="Alles. Elke bron die Ostler op deze Mac kan lezen. Gezichtsherkenning in Foto's blijft uit totdat je die bewust aanvinkt."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="Aanpassen. Kies elke bron op het volgende scherm. Gevoelige bronnen blijven uit totdat je ze aanvinkt."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="Zet deze gegevensbron aan of uit."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_ARTICLE_9_TITLE="Jouw beslissing (Y / N)"
# NEEDS REVIEW: Legal consent wording; a lawyer should check it.
MSG_PROMPT_CONSENT_ARTICLE_9_HELP="Toestemming voor bijzondere categorieën volgens artikel 9 (UK GDPR). Vereist voor de rechtsgrond van de verwerking."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_VOICE_EU_TITLE="Stemmen herkennen in de gesprekken die je transcribeert?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_VOICE_EU_HELP="Sprekerherkenning blijft op deze Mac. Creative Machines ontvangt de stemafdrukken nooit."

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
MSG_PROMPT_CONSENT_ENRICHMENT_TITLE="Openbare feiten opzoeken over dingen die je bewaart?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_ENRICHMENT_HELP="Ostler kan openbare referentiegegevens toevoegen aan dingen die het vindt – een boek, een film, een album, een plaats. Daarvoor stuurt het de NAAM van dat ene ding naar openbare referentiediensten zoals Wikidata, MusicBrainz en OpenLibrary en slaat het antwoord op deze Mac op.

Wat je Mac verlaat: de naam van het ding dat wordt opgezocht. Verder niets. Niet je berichten, niet je contacten, niet je bestanden en niet wie het heeft genoemd.

Wat de dienst aan de andere kant kan zien: je IP-adres, en dat het verzoek van Ostler kwam. Het opzoeken gaat rechtstreeks van je Mac naar hen - er loopt niets via onze servers - dus je kunt het niet vragen zonder dat zij weten dat iemand het vroeg.

Als je Nee zegt: er worden geen opzoekingen gedaan en de achtergrondtaak voor verrijking wordt helemaal niet geïnstalleerd. Al het andere werkt precies hetzelfde. Je bibliotheek bevat dan alleen wat jij eraan hebt gegeven, niet wat een openbare catalogus toevoegt.

Je kunt nu Nee zeggen en later van gedachten veranderen door het installatieprogramma opnieuw te starten."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE="Nog één ding: hoe gegevens van derden werken"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_THIRD_PARTY_HELP="Alle gegevens die je van derden importeert (Google Takeout, Meta-downloads, LinkedIn-exports enz.) blijven op deze Mac. Ostler slaat ze op in je lokale kennisgraaf; er verlaat niets je apparaat.

Door door te gaan begrijp en accepteer je dat je zelf volledig verantwoordelijk bent voor het verwerken en bewaren van deze gegevens op je computer, net als voor de e-mailberichten die al op je harde schijf staan.

Juridische opmerking: Voor gegevens die je naar deze Mac importeert, ben jij de verwerkingsverantwoordelijke en verwerker volgens Brits en EU-recht (UK GDPR artikel 4(7) en 4(8)). Creative Machines ontvangt deze gegevens nooit en is niet de verwerkingsverantwoordelijke. Je verwerking voor persoonlijke en huishoudelijke doeleinden valt onder artikel 2(2)(c) van de UK/EU-AVG.

Lees meer op docs.ostler.ai/privacy/third-party-data."

# Spoken-capture recording-consent acknowledgement (every region). Shown
# in the Phase-2 consent batch. The HELP string is the substantive text
# GUI installer users read on the decision sheet, so it is self-contained.
# ── Personal-use-only terms (vendor/legal/consent_strings.py PERSONAL_USE_ONLY) ──
# A LICENCE TERM, not an optional consent, which is why it acknowledges rather
# than offering a decline that leaves a half-licensed install. Wording verbatim
# from the versioned ConsentString so the Doctor can flag drift.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TERMS_PERSONAL_USE_HEADING="Waar Ostler voor bedoeld is"
MSG_TERMS_PERSONAL_USE_INTRO="Ostler is gemaakt voor één persoon, op de eigen Mac, om het eigen leven te begrijpen. Dat is het hele ontwerp, en daarom verlaten je gegevens deze computer nooit."
# NEEDS REVIEW: Licence term with legal force; a lawyer should check it.
MSG_TERMS_PERSONAL_USE_BUSINESS="Het is niet gemaakt voor zakelijk gebruik. Zet Ostler niet in voor medewerkers en gebruik het niet in je werk om collega's, klanten, cliënten of patiënten vast te leggen. Als een organisatie dat doet, wordt de organisatie verantwoordelijk voor iedereen van wie zij gegevens verzamelt, en Ostler is er niet op ontworpen dat te dragen."
# NEEDS REVIEW: Legal responsibility wording; lawyer should check.
MSG_TERMS_PERSONAL_USE_RECORDER="Jij bent degene die opneemt. Ostler is het hulpmiddel. Als de wet bij jou vereist dat er toestemming is voordat een gesprek wordt opgenomen, moet je die zelf regelen, en wij kunnen van hieruit niet weten of een bepaalde opname rechtmatig is waar jij bent."
MSG_TERMS_PERSONAL_USE_ASK_HEADING="Drie dingen die we je vragen niet te doen:"
# NEEDS REVIEW: 'verzekering' reads as insurance; changed to 'toezegging'. Consent wording, lawyer should check.
MSG_TERMS_PERSONAL_USE_ASK_1="Neem geen kinderen op zonder dat een ouder of voogd daarmee instemt. Een kind kan die instemming zelf niet geven, en jouw eigen toezegging komt niet in de plaats van die van hen."
MSG_TERMS_PERSONAL_USE_ASK_2="Maak geen opnamen op plekken waar mensen echte privacy verwachten: een afspraak bij een arts, een gesprek met een advocaat, een therapiesessie, een biecht, een toilet of een kleedkamer."
MSG_TERMS_PERSONAL_USE_ASK_3="Gebruik Ostler niet om iemand heimelijk op te nemen waar de wet bij jou dat niet toestaat."
# NEEDS REVIEW: Licence and liability text; lawyer should check.
MSG_TERMS_PERSONAL_USE_LEGAL="Ostler is in licentie gegeven voor persoonlijk, niet-commercieel gebruik door een natuurlijke persoon. Creative Machines is geen verwerkingsverantwoordelijke of verwerker van de informatie die je op je Mac bewaart, ontvangt daar niets van, en geeft geen garantie dat een bepaalde opname of vastlegging rechtmatig is in jouw rechtsgebied."
MSG_PROMPT_TERMS_PERSONAL_USE_TITLE="Ostler is voor persoonlijk gebruik"
# NEEDS REVIEW: Fixed awkward 'neem niet op op'. Acceptance of terms, so a lawyer should check.
MSG_PROMPT_TERMS_PERSONAL_USE_HELP="Ostler is in licentie gegeven voor je eigen persoonlijke gebruik op je eigen Mac. Zet het niet in voor medewerkers en gebruik het niet op het werk om collega's, klanten of patiënten vast te leggen. Neem geen kinderen op zonder instemming van een ouder, en maak geen opnamen op plekken waar mensen echte privacy verwachten, zoals een afspraak bij een arts, advocaat of therapeut. Klik op Ga door om deze voorwaarden te accepteren."
MSG_INFO_TERMS_PERSONAL_USE_DECLINED="Geen probleem. Er is niets geïnstalleerd."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_HEADING="Gesproken gesprekken omzetten in tekst"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_INTRO="Kort gezegd: als je gesproken audio vastlegt om die te transcriberen, ben jij verantwoordelijk voor de toestemming die de wet vereist, niet wij. Dit geldt niet voor typen en berichten."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_LAW="Ostler kan gesproken gesprekken die je vastlegt – telefoongesprekken en vergaderingen – omzetten in doorzoekbare tekst. Dit gaat alleen over audio die je zelf wilt transcriberen. De regels over het opnemen van sprekende mensen verschillen per land – op sommige plekken (bijvoorbeeld in Duitsland en Frankrijk) moet iedereen die meedoet eerst instemmen."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_LOCAL="Het op je eigen Mac houden van de vastgelegde audio neemt deze plicht niet weg. Ostler stuurt die nergens naartoe, maar je hebt nog steeds toestemming nodig als de wet bij jou dat vereist."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_HEADING="Wat we van je vragen:"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_1="Zorg voor de toestemming die de wet bij jou vereist voordat je een gesproken gesprek vastlegt."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_2="Maak duidelijk aan de mensen bij wie je bent dat er audio wordt vastgelegd. Zeg het bijvoorbeeld aan het begin, of laat een zichtbare indicator aan."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_3="Twijfel je? Laat gesproken transcriptie dan uit. Je tekstgesprekken werken in beide gevallen."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_LABEL="Jouw keuze:"
# NEEDS REVIEW: Consent declaration; lawyer should check.
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_Y="[Y] Ik begrijp het en zal zorgen voor de toestemming die de wet bij mij vereist."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_N="[N] Nu niet – laat gesproken transcriptie uit. (Je kunt dit later aanzetten in Instellingen.)"
# NEEDS REVIEW: Lowercase after the colon (Dutch style). Legal text, lawyer should check.
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL="Juridische opmerking: het opnemen van het gesproken woord kan door nationale wetgeving worden geregeld, bijvoorbeeld paragraaf 201 van het Duitse Wetboek van Strafrecht (Verletzung der Vertraulichkeit des Wortes) of artikel 226-1 van het Franse Wetboek van Strafrecht, los van de gegevensbeschermingswetgeving. Als degene die op deze Mac opneemt, ben jij verantwoordelijk voor naleving. Creative Machines ontvangt je opnamen nooit en is er geen partij bij."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_TITLE="Gesproken gesprekken omzetten in tekst?"
# NEEDS REVIEW: Fixed 'niet afhankelijk' and 'calls'. Legal text, lawyer should check.
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_HELP="Kort gezegd: als je gesproken audio vastlegt om die te transcriberen, ben jij verantwoordelijk voor de toestemming die de wet vereist. Dit geldt niet voor typen en berichten.

Ostler kan gesproken gesprekken die je vastlegt – telefoongesprekken en vergaderingen – omzetten in doorzoekbare tekst. Dit gaat alleen over audio die je zelf wilt transcriberen.

Wat we van je vragen:
• Zorg voor de toestemming die de wet bij jou vereist voordat je audio vastlegt.
• Maak duidelijk dat er audio wordt vastgelegd: zeg het, of laat een zichtbare indicator aan.
• Twijfel je? Laat dit dan uit. Je tekstgesprekken werken in beide gevallen, en je kunt het later aanzetten in Instellingen.

Juridische opmerking: het opnemen van het gesproken woord kan los van de gegevensbeschermingswetgeving door nationale wetgeving worden geregeld – bijvoorbeeld paragraaf 201 van het Duitse Wetboek van Strafrecht of artikel 226-1 van het Franse Wetboek van Strafrecht. Als degene die opneemt, ben jij verantwoordelijk voor naleving. Creative Machines ontvangt je opnamen nooit."
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="Gesproken transcriptie blijft uit. Je kunt dit later aanzetten in Instellingen."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_TITLE="Klaar om te installeren?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_HELP="Typ INSTALL om te bevestigen dat je de voorwaarden accepteert."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Typ INSTALL"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Installeer Ostler"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Annuleer"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Typ precies INSTALL (hoofdletters maken niet uit) om te bevestigen, of klik op Annuleer om terug te gaan."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="Verbind je iPhone en Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale geeft deze Mac een vast privéadres dat je iPhone en Watch overal kunnen bereiken – versleuteld en niet openbaar zichtbaar."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="Herstelsleutel bewaren in Sleutelhanger?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="Bewaart je herstelsleutel voor versleuteling veilig in de macOS-sleutelhanger."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="Je kennisgraaf vullen"
MSG_HYDRATE_CONTACTS_STARTED="Je contacten importeren in de kennisgraaf"
MSG_HYDRATE_CONTACTS_DONE="%s contacten geïmporteerd"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="Het importeren van contacten duurde langer dan %s s, dus zijn we gestopt met wachten en verdergegaan. Tot nu toe zijn %s contacten binnen, en Ostler maakt de rest op de achtergrond af."
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="Je agendageschiedenis laden (vijf jaar terug, een jaar vooruit)"
MSG_HYDRATE_CALENDAR_DONE="%s afspraken geïmporteerd"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  Je agenda wordt nog geladen (%ss tot nu toe). Een Mac met jaren aan afspraken heeft even nodig."
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="Je Plaatsen samenstellen op basis van de locaties waar je afspreekt"
MSG_HYDRATE_PLACES_DONE="Je onderdeel Plaatsen is opgebouwd"
MSG_HYDRATE_PLACES_SKIPPED="Nog geen locatiesignalen gevonden; Plaatsen wordt aangevuld naarmate je agenda zich vult"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="Het opbouwen van Plaatsen is misgegaan: er zijn locatiesignalen, maar er zijn geen Plaatsen aangemaakt. Je pagina Plaatsen blijft mogelijk leeg. Zie %s"
MSG_HYDRATE_PLACES_ERROR_WARN="Het opbouwen van Plaatsen is niet voltooid (onverwachte fout). Je pagina Plaatsen is mogelijk onvolledig. Zie %s"
MSG_HYDRATE_WIKI_RECOMPILE="Je wiki wordt opgebouwd. Ostler schrijft een korte samenvatting voor al je belangrijke personen, organisaties en onderwerpen. Bij een groot adresboek kan dit enkele minuten tot ongeveer een uur duren. Het gebeurt maar één keer, draait volledig op je Mac en je kunt het gerust laten lopen."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="Je zoekindex controleren (%s collecties gevonden)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="Je browsegeschiedenis laden in de zoekindex"
MSG_INITIAL_HYDRATE_QDRANT_READY="Zoekindex gereed (%s collecties)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="De zoekindex wordt na afloop van de installatie op de achtergrond gevuld"
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
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="De zoekopslag is nu actief; de collecties die nog ontbreken worden aangemaakt: %s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="De zoekindex is onvolledig: %s kon niet worden aangemaakt, hoewel de zoekopslag draait en reageert. Ostler blijft werken en de Doctor toont deze lacune, maar dit deel van de zoekfunctie blijft leeg totdat het is opgelost."
MSG_WARN_QDRANT_COLLECTIONS_MISSING="De zoekindex is onvolledig: %s kon niet worden aangemaakt. Ostler blijft werken en de Doctor toont deze lacune."
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="Kon niet controleren welke zoekcollecties bestaan (%s). Dit betekent niet dat ze ontbreken."
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="De zoekindex wordt na afloop van de installatie op de achtergrond gevuld (wachten op: %s)"
MSG_HYDRATE_DONE="Je graaf is klaar: %s personen, %s gebeurtenissen"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud is mogelijk nog bezig je contacten te synchroniseren – opnieuw exporteren om alles op te halen wat er net bij is gekomen."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="Geen contacten gevonden in je Contacten-app (lokaal of iCloud). Voeg er enkele toe in Contacten en voer het opnieuw uit via Instellingen."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="Geen iCloud-contacten om te importeren. Je kunt dit later toevoegen via Instellingen."
MSG_HYDRATE_SKIPPED_NO_EVENTS="Geen agenda-afspraken in de afgelopen 5 jaar. Je kunt dit later aanvullen via Instellingen."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="De e-mail van de afgelopen 90 dagen lezen – je e-mails blijven op deze Mac (oudere geschiedenis wordt op de achtergrond aangevuld)"
MSG_HYDRATE_EMAIL_DONE="%s personen gevonden in je recente e-mail"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="Geen recente e-mail om te lezen. Je kunt een e-mailaccount toevoegen in Apple Mail en het later opnieuw uitvoeren."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="De e-maillezer is nog niet gereed. Je kunt een e-mailaccount toevoegen in Apple Mail en het later opnieuw uitvoeren."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="E-mail wordt nog op de achtergrond geladen. Je wiki vult zich gaandeweg en laat zien hoe ver het is."
MSG_HYDRATE_EMAIL_HEARTBEAT="  Je e-mail wordt nog gelezen (%ss tot nu toe). Op een Mac met jaren aan geschiedenis kan dit even duren."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="Apple Mail openen zodat het kan beginnen met synchroniseren?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="Je hebt %s e-mailaccount(s) ingesteld, maar Apple Mail heeft nog geen berichten opgehaald. We kunnen Mail.app nu openen en wachten terwijl het synchroniseert."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="Agenda openen zodat het kan beginnen met synchroniseren?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="Je hebt %s agenda-account(s) ingesteld, maar Calendar.app bevat nog geen afspraken. We kunnen Agenda nu openen en wachten terwijl het vanuit iCloud synchroniseert."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="Contacten openen zodat het kan beginnen met synchroniseren?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="Je hebt %s contactenaccount(s) ingesteld, maar Contacts.app bevat nog geen items. We kunnen Contacten nu openen en wachten terwijl het vanuit iCloud synchroniseert."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="Wachten tot %s begint met synchroniseren (maximaal %s seconden)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="Nog wachten op synchronisatie van %s (%ss verstreken, nog %ss te gaan). De eerste iCloud-synchronisatie kan na een nieuwe aanmelding enkele minuten duren."
MSG_OK_APP_HAS_POPULATED="%s heeft de lokale opslag gevuld. We gaan verder."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="We hebben binnen de wachttijd geen synchronisatie van %s gezien. We gaan verder; je kunt het laden later opnieuw uitvoeren via Instellingen."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="Zichtbare Apple Mail-accounts: %s. Open Mail.app één keer zodat het berichten kan gaan ophalen."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="Zichtbare agenda-accounts: %s. Open Calendar.app één keer zodat het je afspraken kan synchroniseren."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="Zichtbare contactenaccounts: %s. Open Contacts.app één keer zodat het je adresboek kan synchroniseren."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="Je contacten konden niet worden gelezen. Ostler leest ze via Volledige schijftoegang. Geef die toegang in Systeeminstellingen > Privacy en beveiliging > Volledige schijftoegang en voer daarna het laden opnieuw uit via Instellingen. We blijven het op de achtergrond opnieuw proberen."
MSG_HYDRATE_CONTACTS_PENDING="Je Contacten-app is nog niet gesynchroniseerd. Open Contacten één keer, wacht tot de synchronisatie klaar is en voer het laden daarna opnieuw uit via Instellingen."
MSG_HYDRATE_CONTACTS_READ_FAILED="Je contacten staan op deze Mac, maar Ostler heeft er 0 geïmporteerd, wat onverwacht is. De import wordt automatisch op de achtergrond opnieuw geprobeerd. Als het blijft gebeuren, voer je het laden opnieuw uit via Instellingen of bekijk je het installatielogboek."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler blijft op de achtergrond controleren en importeert je contacten automatisch zodra iCloud klaar is met synchroniseren."
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="%s contacten met telefoonnummers geïmporteerd, maar bijna geen e-mailadressen (%s telefoon tegenover %s e-mail). Dit betekent meestal dat de contactlezer e-mailadressen heeft overgeslagen. Je contacten blijven bruikbaar; zie %s en voer het laden opnieuw uit via Instellingen zodra het is opgelost."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="Nieuwe contacten geïmporteerd; je wiki wordt op de achtergrond opnieuw opgebouwd."
MSG_HYDRATE_CALENDAR_PENDING="Je Agenda-app heeft nog geen afspraken gesynchroniseerd. Open Agenda één keer, wacht tot de synchronisatie klaar is en voer het laden daarna opnieuw uit via Instellingen."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="Je agenda kon deze keer niet worden gelezen (de extractor meldde een fout, geen lege agenda). Je andere gegevens zijn niet beïnvloed; zie %s en voer het laden daarna opnieuw uit via Instellingen."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="Je WhatsApp-geschiedenis wordt gelezen – je berichten blijven op deze Mac"
MSG_HYDRATE_WHATSAPP_DONE="%s personen gevonden in je WhatsApp-chats"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="WhatsApp-chats zijn gelezen, maar niet naar je personengraaf geschreven (exit %s). Ostler probeert het opnieuw. Details: %s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="Geen WhatsApp-chats om te lezen. Je kunt het later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktop is niet geïnstalleerd. Installeer het via de Mac App Store en voer het opnieuw uit via Instellingen."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="De WhatsApp-lezer is nog niet gereed. Je kunt het later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp wordt nog op de achtergrond geladen. Je wiki wordt gaandeweg aangevuld en laat zien hoe ver het is."

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
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="Je WhatsApp-contacten staan al in je personengraaf (%s ID's). Er hoeft niets opnieuw gelezen te worden."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="Je WhatsApp-contacten zijn eerder gelezen, maar je personengraaf bevat ze niet meer. Ze worden opnieuw gelezen."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="Kon niet controleren of je WhatsApp-contacten nog in je personengraaf staan. Ze worden opnieuw gelezen in plaats van aan te nemen dat ze er zijn."

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="Je AI-chatgeschiedenis wordt gelezen – je gesprekken blijven op deze Mac"
MSG_HYDRATE_AICONV_DONE="%s AI-gesprekken opgeslagen in je wiki"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="De lezer voor AI-gesprekken is nog niet gereed. Je kunt het later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="Geen AI-chatgeschiedenis om te lezen. Je kunt het later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="AI-chats worden nog op de achtergrond geladen. Je wiki wordt gaandeweg aangevuld en laat zien hoe ver het is."
MSG_HYDRATE_AICONV_HEARTBEAT="  Je AI-chatgeschiedenis wordt nog gelezen (%ss tot nu toe). Een grote geschiedenis kan enkele minuten duren."


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="Je browsegeschiedenis wordt geïmporteerd – je bezoeken blijven op deze Mac"
MSG_HYDRATE_BROWSING_DONE="%s pagina's browsegeschiedenis geïmporteerd"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="%s pagina's overgeslagen die als gevoelig zijn gemarkeerd (bankzaken, medisch, enzovoort)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="Geen browsegeschiedenis om te importeren. Je kunt het later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="De lezer voor browsegeschiedenis is nog niet gereed. Je kunt het later opnieuw uitvoeren via Instellingen."

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
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="Je browsegeschiedenis is al geïmporteerd (%s pagina's). Er hoeft niets opnieuw geïmporteerd te worden."
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="Geen geëxporteerde browsegeschiedenis gevonden om te importeren. Je kunt het later opnieuw uitvoeren via Instellingen."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="Je browsegeschiedenis is eerder geïmporteerd, maar je zoekindex bevat die niet meer. Ze wordt opnieuw geïmporteerd."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="Kon niet controleren of je browsegeschiedenis nog in je zoekindex staat. Ze wordt opnieuw geïmporteerd in plaats van aan te nemen dat ze er is."
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="Je browsegeschiedenis heeft je zoekindex niet bereikt, dus je Browsen-pagina blijft leeg. Voer het opnieuw uit via Instellingen of open Doctor."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="De browsegeschiedenis wordt nog op de achtergrond geladen. Je wiki wordt gaandeweg aangevuld en laat zien hoe ver het is."

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="Je e-mailvoorkeuren worden geladen. Dit blijft op deze Mac en kan een paar minuten duren."
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="%s voorkeuren geladen uit je e-mailgeschiedenis"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="Geen bestand met e-mailvoorkeuren ingesteld. Er is niets om te laden."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="Geen bestand met e-mailvoorkeuren gevonden op %s. Er is niets om te laden."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="De voorkeurenpijplijn is nog niet gereed. Je kunt het later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="E-mailvoorkeuren worden nog op de achtergrond geladen. Je wiki vult zich gaandeweg en laat zien hoe ver het is."
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  E-mailvoorkeuren worden nog geladen (%ss tot nu toe). Een grote geschiedenis kan een paar minuten duren."

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="Je e-mailvoorkeuren zijn al geladen (%s items). Opnieuw laden is niet nodig."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="Je e-mailvoorkeuren zijn eerder geladen, maar je zoekindex bevat ze niet meer. Ze worden opnieuw geladen."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="Kon niet controleren of je e-mailvoorkeuren nog in je zoekindex staan. Ze worden opnieuw geladen in plaats van aan te nemen dat ze er zijn."

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
MSG_HYDRATE_PREFERENCES_DONE="%s voorkeuren geïmporteerd"
MSG_HYDRATE_PREFERENCES_ENRICHED="%s daarvan verrijkt met openbare referentiegegevens"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="%s voorkeuren geïmporteerd, maar geen enkele viel onder Eten, Muziek of Professioneel. Je wikipagina's voor Eten en Muziek blijven leeg."
MSG_WARN_PREFS_HEADLINE_HINT="Dit betekent meestal dat er geen export van muziek of eten (Spotify, Apple Music, Uber Eats, Google Takeout) aanwezig was, of dat de gegevens niet zijn ingedeeld. Voeg die exports toe, voer het opnieuw uit via Instellingen en bouw daarna de wiki opnieuw op."
MSG_WARN_PREFS_UNCATEGORISED="%s van %s voorkeuren (%s%%) hebben geen categorie en verschijnen op geen enkele onderwerppagina. Controleer het formaat van de bronexport."

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="Voorkeursverrijking wordt ingesteld"
MSG_CM019_SETUP_DONE="Voorkeursverrijking is klaar"
MSG_CM019_SETUP_FAILED="Het instellen van voorkeursverrijking is niet voltooid. Je voorkeurenpagina's worden gevuld zodra dit is opgelost; de rest van Ostler wordt er niet door beïnvloed."
MSG_CM019_SETUP_SKIPPED="Pipeline voor voorkeursverrijking is niet meegeleverd; wordt voorlopig overgeslagen."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="Je iMessage-geschiedenis wordt gelezen – je berichten blijven op deze Mac"
MSG_HYDRATE_IMESSAGE_DONE="%s personen gevonden in je iMessage-geschiedenis"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="Geen iMessage-geschiedenis om te lezen. Je kunt dit later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="De iMessage-lezer is nog niet gereed. Je kunt dit later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage wordt nog op de achtergrond geladen. Je wiki vult zich gaandeweg en laat zien hoe ver het is."
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  Je iMessage-geschiedenis wordt nog gelezen (%ss tot nu toe). Een grote berichtgeschiedenis kan enkele minuten duren."

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="Je iMessage-contacten staan al in je personengraaf (%s identificatoren). Opnieuw lezen is niet nodig."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="Je iMessage-contacten zijn eerder gelezen, maar je personengraaf bevat ze niet meer. Ze worden opnieuw gelezen."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="Kon niet controleren of je iMessage-contacten nog in je personengraaf staan. Ze worden opnieuw gelezen in plaats van aan te nemen dat ze er zijn."

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="Je Apple Notes worden gelezen - ze blijven op deze Mac"
MSG_HYDRATE_APPLE_NOTES_DONE="%s notities toegevoegd aan je kennisbank"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="Geen Apple Notes om te lezen. Je kunt dit later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="Je Apple Notes staan al in je kennisbank. Overgeslagen."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="Apple Notes zijn uitgeschakeld voor zoeken in je kennisbank. Je kunt ze inschakelen in Instellingen."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="De kennisimporter is nog niet gereed. Je kunt dit later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="Apple Notes worden nog op de achtergrond geladen. Je kennisbank vult zich gaandeweg en laat zien hoe ver het is."
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  Je Apple Notes worden nog gelezen (%ss tot nu toe). Een grote notitiebibliotheek kan een paar minuten duren."

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="Je Apple Notes staan al in je kennisbank (%s items). Opnieuw lezen is niet nodig."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="Je Apple Notes zijn eerder toegevoegd, maar je kennisbank bevat ze niet meer. Ze worden opnieuw toegevoegd."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="Kon niet controleren of je Apple Notes nog in je kennisbank staan. Ze worden opnieuw toegevoegd in plaats van aan te nemen dat ze er zijn."

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="Je Herinneringen worden gelezen - ze blijven op deze Mac"
MSG_HYDRATE_REMINDERS_DONE="%s herinneringen toegevoegd aan je kennisbank"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="Geen Herinneringen om te lezen. Je kunt dit later opnieuw uitvoeren via Instellingen."
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="Je Herinneringen staan al in je kennisbank. Overgeslagen."
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="Herinneringen zijn uitgeschakeld voor zoeken in je kennisbank. Je kunt ze inschakelen in Instellingen."
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="De kennisimporter is nog niet gereed. Je kunt dit later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="Herinneringen worden nog op de achtergrond geladen. Je kennisbank wordt gaandeweg aangevuld en laat zien hoe ver het is."
MSG_HYDRATE_REMINDERS_HEARTBEAT="  Je Herinneringen worden nog gelezen (%ss tot nu toe). Een grote lijst met herinneringen kan een paar minuten duren."

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="Je Herinneringen staan al in je kennisbank (%s items). Er hoeft niets opnieuw gelezen te worden."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="Je Herinneringen zijn eerder toegevoegd, maar je kennisbank bevat ze niet meer. Ze worden opnieuw toegevoegd."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="Kan niet controleren of je Herinneringen nog in je kennisbank staan. Ze worden opnieuw toegevoegd in plaats van aan te nemen dat ze er zijn."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="Je mensen indexeren voor zoeken"
MSG_HYDRATE_PEOPLE_DONE="%s mensen geïndexeerd voor zoeken"
MSG_HYDRATE_PEOPLE_PARTIAL="Tot nu toe %s van %s mensen geïndexeerd voor zoeken. De rest was nog niet doorzoekbaar; Ostler probeert het automatisch opnieuw."
MSG_HYDRATE_PEOPLE_FAILED="Je mensen konden deze keer niet worden geïndexeerd voor zoeken (de graafdatabase reageerde niet). Ostler probeert het automatisch opnieuw. Details: %s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="Nog geen mensen om te indexeren. Je kunt dit later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="De personenindexeerder is nog niet gereed. Je kunt dit later opnieuw uitvoeren via Instellingen."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="Je mensen worden nog op de achtergrond geïndexeerd. Zoeken wordt gaandeweg aangevuld en de wiki laat zien hoe ver het is."

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="Je mensen zijn al geïndexeerd voor zoeken (%s mensen). Er hoeft niets opnieuw geïndexeerd te worden."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="Je mensen zijn eerder geïndexeerd, maar je zoekindex bevat ze niet meer. Ze worden opnieuw geïndexeerd."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="Kan niet controleren of je mensen nog in je zoekindex staan. Ze worden opnieuw geïndexeerd in plaats van aan te nemen dat ze er zijn."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="Er komen drie verzoeken om maptoegang aan"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="Het dialoogvenster van de Command Line Tools staat voor dit venster – klik erin op Installeer en kom dan hier terug (of wacht een paar seconden, we halen dit venster weer naar voren). De tools worden op de achtergrond gedownload terwijl je de vragen hieronder beantwoordt; niets hier wordt geblokkeerd."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="Toestemming nodig: iMessage-automatisering"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostler vraagt nu aan macOS toestemming om met Messages.app te communiceren. macOS toont een melding met \"OstlerInstaller wil toegang om Berichten te bedienen\" – klik op Sta toe, zodat de assistent namens jou iMessages kan versturen en ontvangen. Zonder deze toestemming worden iMessage-berichten nooit verstuurd, zonder dat je een melding krijgt. Je geeft dit één keer; je kunt het later wijzigen via Systeeminstellingen > Privacy en beveiliging > Automatisering."

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="Je herstelsleutel"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="Schrijf dit op of druk het nu af. Het is de enige weg terug als je je wachtzin kwijtraakt EN je Sleutelhanger ontoegankelijk wordt. Ostler kan hem niet voor je herstellen – de sleutel verlaat deze Mac nooit en wordt op geen enkele server bewaard."
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="Ik heb dit op een veilige plek bewaard"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="Kopieer naar klembord"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="Bewaar als pdf..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="Druk af..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="Ga door"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Ostler-herstelsleutel.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Ostler-herstelsleutel"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="Herstelsleutel gekopieerd naar klembord"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="Herstelsleutel bewaard in %s"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="Koppel je iPhone"
MSG_INFO_PAIR_IPHONE_HELP="Open de Ostler app op je iPhone en scan deze QR-code om hem aan deze Hub te koppelen. Je kunt ook later koppelen via het instellingenmenu van de Hub."
MSG_INFO_PAIR_IPHONE_FETCHING="Koppelcode genereren..."
MSG_INFO_PAIR_REFRESH="Vernieuw code"
MSG_ERR_PAIR_FETCH_FAILED="De Ostler-gateway is nog niet bereikbaar. Mogelijk is hij nog aan het opstarten – klik op Vernieuw om het opnieuw te proberen."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agent is niet meegeleverd met het installatieprogramma. Dagelijkse overzichten en de WhatsApp-keepalive-LaunchAgent worden niet geladen."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Wiki-hercompilatiescripts zijn niet meegeleverd met het installatieprogramma. De wiki wordt niet automatisch bijgewerkt."

# F3 - legal package missing
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="Het legal-pakket is niet meegeleverd met het installatieprogramma. De toestemmingspoorten voor Artikel 9, WhatsApp en spraak geven een ModuleNotFoundError totdat je opnieuw installeert."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s geïnstalleerd in %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s is al geïnstalleerd, blijft ongewijzigd"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Niet-ondersteunde cpu-architectuur voor de Google Workspace CLI; functies voor Gmail / Google Agenda werken beperkt."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl is niet beschikbaar; installatie van de Google Workspace CLI is overgeslagen. Functies voor Gmail / Google Agenda werken beperkt."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="Kon de Google Workspace CLI niet downloaden van %s"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="SHA256 van de Google Workspace CLI komt niet overeen (verwacht %s, ontvangen %s). Installatie van dit programma wordt afgebroken."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="Het archief van de Google Workspace CLI kon niet worden uitgepakt."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI is geïnstalleerd op %s, maar de controle met --version is mislukt."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="iCloud- / CalDAV-agendabrug geïnstalleerd op %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="De iCloud- / CalDAV-agendabrug op %s is niet uitvoerbaar. Agenda levert geen afspraken op."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh zit niet in het installatiepakket. Opnieuw proberen om het apparaat te registreren zodra er netwerk is, staat uit."

MSG_WARN_EMBED_DIMS_UNREADABLE="Kon de embeddingbreedte niet uitlezen via de statuscontrole. Geheugen is ingesteld op 768 dimensies; controleer het embeddingmodel als het terugvinden vreemd werkt."
MSG_FAIL_EMBED_DIMS="Het embeddingmodel gaf vectoren met %s dimensies terug, maar Ostler is ingesteld op %s. Het geheugen zou vectoren opslaan die nooit kunnen overeenkomen. Controleer het embeddingmodel en voer het opnieuw uit."

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
MSG_PROGRESS_REBOOT_SELFHEAL="Zelfherstel na herstart configureren"
MSG_INFO_AUTOLOGIN_EXPLAIN="Ostler is een Hub die altijd aan staat, dus na een stroomstoring of herstart moet hij terugkomen zonder dat iemand achter het toetsenbord zit. Dat werkt alleen als deze Mac zichzelf aanmeldt, en dat kan macOS alleen als het inlogwachtwoord van %s op deze Mac is opgeslagen.

Het opslaan hiervan maakt deze Mac minder veilig. Het wachtwoord wordt door elkaar gehusseld, niet versleuteld. Wie hier een beheerdersaccount kan gebruiken, of de schijf eruit kan halen en elders kan uitlezen, kan er je wachtwoord weer van maken. Je ziet precies waar het wordt opgeslagen voordat je iets typt.

Als je nee zegt, wordt er niets opgeslagen en verandert er niets. Na een stroomstoring meld je je gewoon aan en starten de diensten van Ostler met je sessie. Je kunt dit later wijzigen in Systeeminstellingen > Gebruikers en groepen > Automatisch inloggen."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_AUTOLOGIN_CONSENT="Je inlogwachtwoord op deze Mac opslaan zodat hij zichzelf na een herstart kan aanmelden? [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="Ostler schrijft dit wachtwoord naar een bestand op deze Mac op /etc/kcpassword. Het wordt daar gehusseld met een vast patroon dat op elke Mac hetzelfde en openbaar gedocumenteerd is, dus het is geen versleuteling en het kan worden teruggedraaid. Wie een beheerdersaccount op deze Mac kan gebruiken, of de schijf eruit kan halen en elders kan uitlezen, kan dat bestand weer omzetten in het inlogwachtwoord van %s.

FileVault zou dat voorkomen, want zonder het opstartwachtwoord is de schijf helemaal niet te lezen. Om dezelfde reden blokkeert FileVault automatisch aanmelden, en daarom biedt Ostler dit alleen aan als FileVault uit staat.

Wat het installatieprogramma wél in de hand heeft: het toont het wachtwoord niet terwijl je typt en schrijft het niet naar het installatielogboek. Het gehusselde bestand is het enige exemplaar dat het installatieprogramma maakt.

Laat dit leeg om automatisch aanmelden over te slaan."
MSG_PROMPT_AUTOLOGIN_PASSWORD="Inlogwachtwoord voor %s"
MSG_OK_AUTOLOGIN_CONFIGURED="Automatisch aanmelden staat aan voor %s en dat inlogwachtwoord staat nu in gehusselde vorm op deze Mac in /etc/kcpassword. Na een herstart meldt deze Mac zichzelf aan en starten de diensten van Ostler met die sessie. Zet Automatisch inloggen uit in Systeeminstellingen > Gebruikers en groepen om dit ongedaan te maken."
MSG_INFO_AUTOLOGIN_ALREADY="Automatisch aanmelden is al ingesteld voor %s, dus dat inlogwachtwoord staat al op deze Mac in /etc/kcpassword. Beide blijven zoals ze zijn. Zet Automatisch inloggen uit in Systeeminstellingen > Gebruikers en groepen om dit ongedaan te maken."
MSG_INFO_AUTOLOGIN_DECLINED="Automatisch aanmelden is niet ingeschakeld en er is geen wachtwoord opgeslagen. Meld je na een herstart of stroomstoring gewoon aan, dan starten de diensten van Ostler met je sessie."
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="Instelling van automatisch aanmelden overgeslagen: hier is geen manier om om een inlogwachtwoord te vragen en er is niets opgeslagen. Je kunt Automatisch inloggen later aanzetten in Systeeminstellingen > Gebruikers en groepen als je wilt dat deze Mac zonder toezicht herstelt na een herstart. Het slaat je inlogwachtwoord op de Mac op in gehusselde, omkeerbare vorm, dus lees je er eerst goed over in."
MSG_WARN_AUTOLOGIN_NO_PASSWORD="Er is geen wachtwoord ingevoerd, dus automatisch aanmelden is niet ingeschakeld en er is niets opgeslagen. Wil je het later alsnog, zet dan Automatisch inloggen aan in Systeeminstellingen > Gebruikers en groepen."
MSG_WARN_AUTOLOGIN_FAILED="Kon automatisch aanmelden niet inschakelen (%s). Dit wordt niet opnieuw geprobeerd. Als /etc/kcpassword op deze Mac bestaat, bevat het dat inlogwachtwoord in gehusselde vorm, ook al staat de functie uit. Je kunt het verwijderen via Terminal met: sudo rm /etc/kcpassword. Zet Automatisch inloggen aan in Systeeminstellingen > Gebruikers en groepen om het opnieuw te proberen."
MSG_WARN_AUTOLOGIN_FILEVAULT="FileVault staat aan, dus deze Mac vraagt op het opstartscherm om een wachtwoord om de schijf te ontgrendelen voordat iemand zich kan aanmelden. Automatisch aanmelden kan daar geen antwoord op geven, dus na een stroomstoring wacht deze Mac op het FileVault-ontgrendelscherm tot iemand het wachtwoord invoert. Automatisch aanmelden is niet ingeschakeld en er is geen wachtwoord opgeslagen. Dat is de sterkste van de twee opties: herstel zonder toezicht na een herstart is niet mogelijk zolang FileVault aan staat, en in ruil daarvoor blijft de schijf onleesbaar voor wie dat wachtwoord niet heeft."

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
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="Ostler kon Systeeminstellingen niet voor je openen. Open Systeeminstellingen zelf en ga naar Privacy en beveiliging > Volledige schijftoegang."
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="Ostler draait je wiki en zoekfunctie in containers, dus installeert en beheert het een containerengine (Colima) op deze Mac. Als die engine wordt verwijderd of anders wordt ingesteld, werken je wiki en zoekfunctie niet meer – Ostler laat het je weten en probeert de engine opnieuw te starten."
MSG_INFO_ENGINE_ALREADY_PRESENT="Er is al een containerengine op deze Mac geïnstalleerd. Ostler gebruikt die in plaats van er zelf een te installeren en beheert of wijzigt hem niet."
