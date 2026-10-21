#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to it by l10n/ostler_l10n.py.
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

MSG_STEP_CHECKING_PREREQUISITES="Controllo dei prerequisiti"
MSG_STEP_RUNNING_HEALTH_CHECK="Esecuzione del controllo di integrità"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="Collega il tuo iPhone e il tuo Watch"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="Configurazione (poche domande veloci, poi prosegue da sola)"
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
MSG_STEP_SETUP_COMPLETE_WRAP_UP="Domande completate. Ora Ostler si installa in background, da circa 45 minuti a qualche ora. Ci saranno ancora tre momenti in cui serve il tuo intervento: se macOS chiede di installare gli strumenti per sviluppatori, fai clic su Installa; verso la fine c'è un minuto di configurazione (l'attivazione dell'Accesso completo al disco); e alla fine di tutto, dopo il controllo di integrità, accedi a Tailscale e consenti all'assistente di usare Promemoria. Tra questi momenti puoi lasciarlo in esecuzione."
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="Domande completate. Ora Ostler si installa in background, da circa 45 minuti a qualche ora. Ci saranno ancora tre momenti in cui serve il tuo intervento: se macOS chiede di installare gli strumenti per sviluppatori, fai clic su Installa; verso la fine c'è un minuto di configurazione (l'attivazione dell'Accesso completo al disco); e alla fine di tutto consenti all'assistente di usare Promemoria. Tra questi momenti puoi lasciarlo in esecuzione."

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="e riesegui: ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="Riavvio dell'assistente affinché possa usare l'Accesso completo al disco per leggere la cronologia di Messaggi. Il riavvio serve a rendere effettivo un permesso appena concesso; se non l'hai ancora concesso, la dashboard Doctor continuerà a guidarti."
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="Il tuo assistente è in esecuzione e ha l'Accesso completo al disco, quindi può leggere i file di cui ha bisogno."
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="Il tuo assistente è in esecuzione, ma non ha ancora l'Accesso completo al disco. Finché non lo attivi, Ostler non può tenere aggiornati Messaggi, Mail, Calendario, Promemoria, Note, Foto, Safari, Contatti o WhatsApp, e non può leggere la cartella Documenti. Ciò che ha già letto resta disponibile. La dashboard Doctor ti guiderà nell'attivazione."
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="Il tuo assistente è in esecuzione. Non siamo riusciti a verificare se ha l'Accesso completo al disco su questo Mac, quindi non è una conferma in nessuno dei due sensi. La dashboard Doctor te lo dirà appena potrà controllare."
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="Account di Apple Mail visibili: %s (informativo)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mail non sembra ancora contenere messaggi locali. Doctor mostrerà un avviso se non arriva posta entro 24 ore."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mail contiene messaggi in cache. L'acquisizione li rileverà al prossimo ciclo orario."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="Apple Mail è selezionato, ma su questo Mac non ci sono ancora messaggi locali da leggere. Apri Apple Mail e aggiungi un account (Impostazioni di Sistema > Account Internet, poi attiva Mail), quindi lascia che completi una prima sincronizzazione."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="Quando la posta sarà arrivata, riesegui: ostler-fda. Ostler la rileverà automaticamente; non serve altro."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="La notarizzazione Apple verrà verificata da Gatekeeper al primo avvio."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="disponibile, l'installer salterà questo passaggio automaticamente."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="I beta tester con accesso possono impostare PWG_PIPELINE_REPO=<url> e rieseguire."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="I beta tester con accesso possono impostare PWG_KNOWLEDGE_REPO=<url> e rieseguire."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="Estensioni del browser saltate (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  Clonato in %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture funziona solo su Apple Silicon. Installazione saltata su questo computer."
MSG_INFO_CM042_LOGS_AT="Log di RemoteCapture: %s/ostler-remotecapture.log (e .err)"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="Un'installazione precedente avviava Ostler RemoteCapture all'accesso. È stato fermato e non verrà più avviato."
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="Ostler RemoteCapture non è stato installato: hai scelto di tenere disattivata la trascrizione del parlato. Attivala nelle Impostazioni ed esegui di nuovo l'installer se cambi idea."
MSG_INFO_CM042_TCC_PRE_PROMPT="Al primo avvio, Ostler RemoteCapture chiederà a macOS il permesso di Registrazione schermo e Microfono. Concedili entrambi per poter trascrivere localmente chiamate e riunioni. Nella barra dei menu non compare alcun indicatore viola di registrazione: l'acquisizione audio è silenziosa per scelta progettuale."
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
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="Ostler salva il tuo wiki personale e le trascrizioni delle tue conversazioni in Documenti/Ostler, su questo Mac. Sono tuoi e restano su questo computer. Per scriverli, Ostler ha bisogno di accedere alla cartella Documenti, quindi macOS potrebbe chiedertelo durante la configurazione e di nuovo più tardi oggi, quando Ostler organizzerà per la prima volta il tuo wiki. La richiesta può sembrare provenire da python3.11, l'helper incluso che Ostler usa per scrivere i tuoi file. Fai clic su Consenti ogni volta che compare. Se te la perdi o la rifiuti, puoi attivarla in qualsiasi momento in Impostazioni di Sistema, sotto Privacy e sicurezza, poi File e cartelle, e da quel momento il tuo wiki e le trascrizioni delle conversazioni verranno scritti."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  Motore della memoria delle conversazioni installato nel venv."
MSG_INFO_HUB_APP_VERIFYING="Verifica di Ostler.app in %s"
MSG_INFO_HUB_APP_STAGING="Copia di Ostler.app in /Applications da %s"
MSG_INFO_HUB_APP_DRAG_HINT="Apri il DMG dell'installer e trascina sia Ostler.app sia OstlerInstaller.app sulla scorciatoia Applicazioni, poi riesegui l'installer."
MSG_OK_HUB_APP_PRESENT="Ostler.app è già presente in %s; firma verificata."
MSG_OK_HUB_APP_STAGED="Ostler.app installata in %s"
MSG_WARN_HUB_APP_NOT_FOUND="Ostler.app non è stata trovata in /Applications e non è disponibile alcuna copia inclusa."
MSG_WARN_HUB_APP_VERIFY_FAILED="Verifica della firma o della notarizzazione di Ostler.app non riuscita. Il bundle viene lasciato dov'è così che l'assistenza possa esaminarlo."
MSG_OK_UNINSTALLER_APP_STAGED="Ostler Uninstaller.app installata in %s"
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="Impossibile collocare Ostler Uninstaller.app in /Applications. Puoi comunque disinstallare eseguendo: ~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="Clonazione dell'agente Doctor..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="Clonazione degli script email-ingest..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Clonazione degli script hub-power..."
MSG_INFO_CLONING_IMPORT_PIPELINE="Clonazione della pipeline di importazione..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="Clonazione degli script wiki-recompile..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima è installato ma non in esecuzione. Verrà avviato."
MSG_INFO_COLIMA_START_ATTEMPT="Avvio di Colima (tentativo %s di %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="Impossibile esportare i contatti. Potrai importarli manualmente più tardi."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="Impossibile leggere la scheda contatto. Nessun problema: te lo chiederemo."
MSG_INFO_CONTACT_CARD_WILL_ASK="Tra un momento ti chiederemo nome e paese. I tuoi contatti vengono letti più tardi tramite l'Accesso completo al disco che concedi, e nulla lascia questo Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  Creazione dell'ambiente virtuale Python in %s..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="Creazione dell'albero dei contenuti per l'utente in %s/"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="Esecuzione giornaliera. Esecuzione manuale: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="Hub desktop (senza batteria) rilevato: sospensione disattivata per tutto il sistema"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker non è installato. Verranno installati Colima, Docker CLI e il plugin docker-compose (leggero, non richiede Docker Desktop)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="I file dell'agente Doctor non sono inclusi nell'installer."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="Gli script email-ingest non sono inclusi nell'installer."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="Gli script email-ingest mancano dal pacchetto dell'installer. Scarica di nuovo l'app da ostler.ai/install e riprova."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Gli script email-ingest non sono inclusi ed è stato passato --allow-plaintext: l'installazione del LaunchAgent verrà saltata. Le email future non verranno elaborate."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  Copia esistente in %s; aggiornamento..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Estrazione del mbox di Gmail dallo zip di Takeout (può richiedere un minuto per archivi grandi)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="Modulo di estrazione FDA non incluso. Estrazione immediata dei dati saltata."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Attivazione dei tuoi primi 30 giorni di Ostler Pro..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Dopo la prova, Ostler Pro costa 9,99 USD al mese. Abbonati nell'app Ostler sul tuo iPhone."
MSG_INFO_FOUND_GMAIL_MBOX_MB="Trovato mbox di Gmail in %s (%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Trovato zip di Google Takeout in %s (%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="Accesso completo al disco rilevato: estrazione completa disponibile."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="Esportazioni GDPR rilevate, ma la pipeline di importazione non è ancora disponibile."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="L'importazione delle esportazioni GDPR sarà disponibile con il rilascio della pipeline."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="Stiamo per cercare in Download, Scrivania e Documenti eventuali esportazioni AI (Google Takeout, download di Meta, LinkedIn, ecc.) che potresti aver salvato. macOS mostrerà tre richieste di accesso alle cartelle: consentile tutte. Servono circa 5-10 secondi in totale. Durante la scansione nulla viene spostato o copiato; controlliamo solo cosa c'è."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS potrebbe chiederti il permesso di leggere Calendario. Consentilo così Ostler potrà costruire la parte di riunioni ed eventi del tuo grafo della conoscenza. (I dati di Calendario restano su questo Mac.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS chiede il permesso per Download. Fai clic su OK."
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS chiede il permesso per Scrivania. Fai clic su OK."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS chiede il permesso per Documenti. Fai clic su OK."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="Accesso completo al disco concesso. Preparazione della prossima richiesta di macOS (automazione di Messaggi)..."
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="Nessuna risposta alla richiesta di permesso per Messaggi, quindi siamo andati avanti. I tuoi messaggi non verranno letti finché non sarà consentito. Ostler lo chiederà di nuovo, oppure puoi concederlo in Impostazioni di Sistema > Privacy e sicurezza > Automazione."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="Servono gli strumenti da riga di comando di Xcode. macOS chiederà l'autorizzazione per installarli: cerca una piccola finestra grigia (se non la vedi, premi Cmd+Tab o controlla il Dock). Fai clic su Installa. Gli strumenti vengono scaricati in background mentre rispondi alle domande qui sotto."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  Configurazione degli strumenti da riga di comando ancora in corso (%ss). Se una piccola finestra grigia di macOS chiede di installare gli strumenti per sviluppatori, fai clic su Installa: questo passaggio è in attesa di quello. (Premi Cmd+Tab o controlla il Dock se non la vedi.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="In attesa che gli strumenti da riga di comando finiscano di installarsi (quasi fatto)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="Esecuzione oraria. La prima volta scarica gli ultimi 5 anni di posta."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="Disattivazione del vecchio LaunchAgent del bridge iMessage (v1.0 su un solo Mac)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Hub alimentato solo da rete (nessuna batteria rilevata): salto il LaunchAgent hub-power."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Gli script di alimentazione dell'Hub non sono inclusi nell'installer."
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="Hub su portatile. Continua a funzionare con lo schermo aperto e il Mac collegato alla corrente."
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="Se chiudi lo schermo, o lo lasci inattivo a batteria, macOS lo mette in stop."
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="Mentre è in stop, l'assistente non riceve nulla."
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="I messaggi arrivati in quel periodo non vengono recuperati alla riattivazione."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="Lo schermo può restare chiuso in modalità a schermo chiuso."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="Servono la corrente, uno schermo esterno, una tastiera e un mouse."
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="Docker e Ollama si mettono in pausa a batteria e riprendono con la corrente."
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="Dopo un riavvio, FileVault tiene questo Mac alla schermata di login."
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="Ostler si avvia dopo l'accesso."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="API dell'assistente inclusa nell'installer: uso il sorgente incorporato."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="Sorgente dell'API dell'assistente non incluso: l'app Ostler sul tuo iPhone avrà un accesso limitato."
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="Installazione delle dipendenze di runtime dell'API dell'assistente (phonenumbers, httpx)..."
MSG_WARN_ICAL_SERVER_DEPS_FAILED="Impossibile installare le dipendenze di runtime dell'API dell'assistente (phonenumbers/httpx): Persone e Cronologia potrebbero restare vuote fino alla prossima installazione."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Quando compare la finestra di Tailscale, accedi con Apple / Google / Microsoft."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="Apertura di Tailscale per permetterti di accedere..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="Ricevuto: da qui Ostler si installa quasi da solo. Verso la fine ti chiederà di tornare per circa due minuti: attivare l'Accesso completo al disco, poi accedere a Tailscale così che iPhone e Watch possano raggiungere questo Mac da ovunque. Apriremo il browser per l'accesso."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale saltato: l'app Ostler sul tuo iPhone funzionerà solo con il Wi-Fi di casa. Potrai configurarlo più tardi da Impostazioni."
MSG_INFO_TAILSCALE_STILL_WAITING="Ancora in attesa dell'accesso a Tailscale (%ss trascorsi): completa l'accesso nella finestra di Tailscale."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="Accesso completo al disco concesso: riavvio l'assistente per applicare la nuova autorizzazione."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="Apertura di Impostazioni di Sistema e del Finder per guidarti nel concedere l'Accesso completo al disco all'assistente..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="Registrazione dell'assistente Ostler in macOS, in modo che compaia come interruttore in Accesso completo al disco..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="L'Accesso completo al disco è ancora in sospeso. La dashboard Doctor continuerà a mostrare la scheda finché l'accesso non sarà concesso."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant ha già l'Accesso completo al disco: non serve altro."
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="Qui serve il tuo aiuto per circa due minuti: attiva ora l'Accesso completo al disco per l'assistente, poi accedi a Tailscale nel passaggio successivo. Dopodiché puoi lasciare che Ostler finisca da solo."
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="Qui serve il tuo aiuto per circa un minuto: attiva l'Accesso completo al disco per l'assistente. Dopodiché puoi lasciare che Ostler finisca da solo."
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="\"%s\" è già presente in Accesso completo al disco, quindi ti basta attivarlo. Non serve trascinare nulla dal Finder."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Controllo se l'assistente Ostler ha l'Accesso completo al disco..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="L'assistente può leggere la cronologia di Messaggi: il canale iMessage funzionerà."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="L'assistente di Ostler non ha ancora l'Accesso completo al disco. Gli serve per mantenere aggiornate le app del tuo Mac, che tu usi Messaggi o no. Se lo salti ora, la dashboard Doctor ti guiderà in Impostazioni di Sistema."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="LaunchAgent dell'assistente non caricato; salto il controllo dell'Accesso completo al disco per iMessage."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="L'interfaccia di importazione da Evernote in Doctor mostrerà «servizio non disponibile»"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Pipeline di importazione non inclusa nell'installer."
MSG_INFO_INSTALLING_CM042="Installazione di Ostler RemoteCapture v%s (trascrizione di chiamate e riunioni)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="Installazione del motore della memoria delle conversazioni da %s..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  Installazione del motore della memoria delle conversazioni nel venv..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="Installazione di Colima + Docker CLI..."
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="Installazione di GNU coreutils (per i limiti di timeout sui passaggi lunghi)..."
MSG_INFO_INSTALLING_HOMEBREW="Installazione di Homebrew..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="Installazione del servizio Knowledge da %s..."
MSG_INFO_INSTALLING_OLLAMA="Installazione di Ollama..."
MSG_INFO_INSTALLING_OLLAMA_PINNED="Installing Ollama %s (verified release)..."
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  Installazione delle dipendenze del modulo di estrazione dati..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Installazione del lettore di Apple Mail in un venv dedicato..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  Installazione di ostler-knowledge nel venv..."
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  Installazione della dipendenza per l'archiviazione cifrata nel venv della memoria delle conversazioni..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Installazione dell'estensione di Safari in /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="Installazione delle dipendenze Python per la sicurezza..."
MSG_INFO_INSTALLING_SQLCIPHER="Installazione di SQLCipher..."
MSG_INFO_INSTALLING_TAILSCALE="Installazione di Tailscale..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="Il supporto per Intel non è nella roadmap; invia una richiesta se necessario."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Servizio Knowledge incluso nell'installer; uso il sorgente incorporato."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Servizio Knowledge non installato: PWG_KNOWLEDGE_REPO è vuoto."
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="Questo Mac è un portatile. Come Hub continua a funzionare finché il coperchio è aperto e il Mac è collegato all'alimentazione."
MSG_INFO_LAPTOP_HUB_SLEEP_COST="Se chiudi il coperchio, o lo lasci inattivo a batteria, macOS lo mette in stop. L'assistente non riceve nulla mentre è in stop, e i messaggi arrivati in quel periodo non vengono recuperati al risveglio."
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="Il coperchio può restare chiuso in modalità a schermo chiuso, che richiede l'alimentazione, uno schermo esterno, una tastiera e un mouse."
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="Un Hub su Mac mini o Mac Studio resta attivo da solo, se preferisci installare su uno di questi."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="più tardi in Impostazioni di Sistema > Privacy e sicurezza > Accesso completo al disco"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  avvio per verificare la consegna cron e la configurazione imessage-tcc)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="Licenza: %s è Apache 2.0. Testo completo: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licence: %s – check upstream terms before commercial use."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="archivio locale – Google non saprà mai che Ostler esiste."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="Log: %s/email-ingest.log (e .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="Log: %s/ostler-assistant.log (e .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="Log: %s/wiki-recompile.log (e .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="Hub su MacBook: imposta PWG_HUB_POWER_REPO=<url> ed esegui di nuovo."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="Hub su MacBook rilevato: imposto il blocco dello stop solo con alimentazione (hub-power gestisce i passaggi a batteria)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Le installazioni su Mac mini / Studio non sono interessate (sempre alimentati)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="I dati lato Mac (iMessage, Safari, ecc.) sono stati estratti qui sopra."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="Riavvio manuale: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="Esecuzione manuale: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="Installazione di com.ostler.meeting-brief-sender saltata (funzione della v1.0.1; endpoint non ancora rilasciati)."
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="Passaggio di pulizia della memoria saltato (non incluso in questo installer); finché non sarà disponibile, a nulla viene ridotta automaticamente la priorità."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="messaggio quando il flag della funzione verrà attivato in seguito."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="Serve aiuto? Scrivi a support@ostler.ai. Cerchiamo di risponderti entro 2 giorni lavorativi."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="Nessun canale configurato. Esegui più tardi: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="Rimosso un vecchio file config.toml obsoleto nella radice dello spazio di lavoro; la configurazione attiva dell'assistente si trova in assistant-config/."
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="Nessuna fonte FDA disponibile al momento. Puoi concedere l'Accesso completo al disco"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="Nessuna esportazione GDPR trovata in Download, Scrivania o Documenti."
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="Impossibile leggere %s per cercare le esportazioni dei dati. macOS sta bloccando l'accesso a quella cartella."
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="Concedi l'accesso in Impostazioni di Sistema > Privacy e sicurezza > File e cartelle (oppure Accesso completo al disco) ed esegui di nuovo, oppure indica a Ostler la cartella delle esportazioni manualmente qui sotto."
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="Impossibile analizzare una o più cartelle alla ricerca di esportazioni dei dati perché macOS ha bloccato l'accesso. Concedi l'accesso ed esegui di nuovo, oppure indicami manualmente la cartella delle esportazioni."
MSG_INFO_OPENING_CHROME_WEB_STORE="Apertura del Chrome Web Store: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="Il binario ostler-assistant non è installato; verifica Doctor saltata"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: rimandato (il daemon potrebbe essere ancora"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="Uso del binario ostler-assistant incluso in questo DMG (installazione disponibile anche offline)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge installato nel venv."
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler will show an extra consent screen before installing"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  Puoi cambiare il repository sorgente del motore di memoria delle conversazioni tramite la variabile d'ambiente descritta in ./install.sh --help."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  Cambia il repository sorgente con PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  Cambia il repository sorgente con PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  Cambia il repository sorgente con PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  Cambia il repository sorgente con PWG_PIPELINE_REPO=<url> ./install.sh"
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Persisting consent records and region..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="Monitor della batteria della fase 3 attivato (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="Lettura della tua rubrica (le librerie grandi possono richiedere un paio di minuti – non chiudere l'installer)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="Sostituzione della policy: modifica ~/.ostler/power.conf (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="Verifica del permesso di Automazione per iMessage (sola lettura)..."
MSG_INFO_PULLING_GRAPH_DB_IMAGES="Download dei database del grafo della conoscenza (solo al primo avvio). Su un'installazione nuova può richiedere un minuto..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="Download di nomic-embed-text (274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="Download di %s (%s)... potrebbe richiedere qualche minuto."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="Attributo xattr di quarantena rimosso. Quando la build Developer-ID sarà"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Lettura di Safari, iMessage, Note, Calendario, Foto, Promemoria, Mail..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="Lettura della tua scheda contatto per precompilare i tuoi dati..."
MSG_INFO_REGION_EU_EEA_SOURCE="Regione: UE/SEE (%s, fonte: %s)"
MSG_INFO_REGION_SOURCE="Regione: %s (fonte: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="Area geografica: Regno Unito (origine: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="Area geografica: Stati Uniti (origine: %s)"
MSG_INFO_REPO_URL="URL del repository: %s"
MSG_INFO_REPO_URL_2="URL del repository: %s"
MSG_INFO_REPO_URL_3="URL del repository: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="Scegli ora la passphrase che sbloccherà il tuo Hub. La digiterai ogni volta che avvii l'interfaccia dell'Hub."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="Passphrase di recupero saltata. (Obsoleto: la versione 1.0 richiede sempre una passphrase.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="Riutilizzo l'installazione esistente dell'agente Doctor in %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="Riutilizzo l'installazione esistente di email-ingest in %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="Riutilizzo l'installazione esistente di hub-power in %s"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="Riutilizzo la chiave esistente dell'estensione del browser in %s"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="L'estensione di Ostler per Chrome non fa parte di questa versione."
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="Email conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="Conversazioni email: non configurate, perché Apple Mail non è configurato su questo Mac."
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="Messages conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="Conversazioni di Messaggi: non configurate, perché su questo Mac non c'è alcuna cronologia di Messaggi."
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  Trascrivi una chiamata con Ostler e questa funzione si attiverà da sola."
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="Conversazioni parlate: non ancora configurate, perché non ci sono trascrizioni da leggere."
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="Conversazioni parlate: disattivate, perché la cartella Transcripts è stata rimossa dopo l'installazione di Ostler."
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  Ricrea %s per riattivarle. Ostler non la ricreerà al posto tuo."
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="WhatsApp conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="Conversazioni di WhatsApp: non configurate, perché WhatsApp è disattivato."
MSG_INFO_CHROME_HISTORY_STILL_READ="  Ostler legge comunque la cronologia di Chrome, quindi le pagine che hai visitato vengono ricordate. Per ora l'acquisizione in tempo reale durante la navigazione è disponibile solo con Safari."
MSG_INFO_REUSING_EXISTING_JWT_SECRET="Riutilizzo il JWT_SECRET esistente in %s"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="Riutilizzo il token di servizio PWG esistente in %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="Riutilizzo l'installazione esistente di wiki-recompile in %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="Il pacchetto dell'estensione Safari non è presente in questa build dell'installer (saltato)"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="Resta un passaggio manuale: apri Safari, scegli Safari > Impostazioni > Estensioni e seleziona Ostler per attivarla."
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="Ricerca delle esportazioni di dati GDPR..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="Imposta PWG_DOCTOR_REPO=<url> e riesegui per installare."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="Imposta PWG_HUB_POWER_REPO=<HR015 url> e riesegui per installare."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="Modello di conversazione saltato. Scaricalo più tardi: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Avvio di Colima (runtime Docker leggero)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Avvio di Docker Desktop..."
MSG_INFO_STARTING_OLLAMA="Avvio di Ollama..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="Rimozione di un vecchio elemento di avvio di Colima lasciato da una versione precedente..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="Rimozione della vecchia formula di Ollama (senza llama-server); passaggio all'app Ollama..."
MSG_INFO_VERIFYING_EMBEDDINGS="Verifica che il motore di embedding restituisca i vettori..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="Impossibile avviare Ollama automaticamente. Caricalo con: launchctl bootstrap gui/\$(id -u) %s – poi riesegui l'installer."
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="Ollama non si è avviato tramite il servizio in background; lo avvio direttamente per questa esecuzione..."
# NEEDS REVIEW: Proposed text reversed the meaning: 'after first' became 'prima' (before/first). This is a fragment split across lines, so check it against the adjacent lines.
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  avvio; esegui \`ostler-assistant doctor\` dopo il primo"
MSG_INFO_SYMLINKING="  Creo il collegamento simbolico %s -> %s"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(Impostazioni di Sistema > Account Internet). Ostler legge dal database di Mail"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(Il resto di Ostler funziona anche senza la dashboard Doctor.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="Per ora è normale. L'importazione GDPR sarà disponibile in un prossimo aggiornamento."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="Di solito servono da 15 a 45 minuti, e può volerci di più se hai molta cronologia o un Mac più lento. È normale: sta lavorando, non si è bloccato, quindi puoi lasciarlo in esecuzione..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="Legge direttamente i database di macOS: nessuna esportazione necessaria."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="Suggerimento: per includere Gmail, aggiungilo prima a Mail sul Mac"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="Per installarlo più tardi, quando avrai accesso:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="Avvio della sincronizzazione iCloud per %s (silenziosa, solo al primo avvio)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (Articolo 9 del GDPR del Regno Unito - richiesto per i dati di categoria particolare)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="Aggiornamento della pipeline esistente..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="Struttura visibile all'utente già annunciata (sentinella presente); salto"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="Download del motore di ricerca web locale (circa 3,5 GB). Alla prima installazione è il passaggio più lungo e può richiedere fino a un'ora. Non c'è una barra di avanzamento, quindi un lungo silenzio è normale e non significa che l'installazione si sia bloccata."
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane non risponde (facoltativo; vedi gli avvisi della fase 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="Visualizzale in qualsiasi momento con: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="Il riconoscimento vocale resterà disattivato. Puoi attivarlo più tardi in Impostazioni."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="In attesa che tu acceda a Tailscale (fino a 3 minuti)..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="L'accesso remoto con Tailscale non è stato configurato. L'app Ostler sul tuo iPhone funzionerà con il Wi-Fi di casa; puoi configurare l'accesso remoto più tardi da Impostazioni."
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="Questo Mac è già connesso alla tua rete Tailscale, quindi non c'è nulla da configurare. Mantengo la connessione esistente."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="Accesso remoto: mantengo la risposta che hai dato l'ultima volta, cioè di saltarlo. La tua app iOS funzionerà con il Wi-Fi di casa e potrai configurare l'accesso remoto più tardi da Impostazioni."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="Accesso remoto: mantengo la risposta che hai dato l'ultima volta, cioè di configurarlo."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="Connettore WhatsApp lasciato disattivato. Puoi attivarlo più tardi da Impostazioni."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="Keepalive di WhatsApp pianificato alle 08:50 + 17:50 (etichetta com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="Salto l'aggiornamento iniziale del wiki del primo giorno: il tick wiki-recompile non è installato. L'aggiornamento giornaliero del wiki, se installato, viene comunque eseguito."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Script wiki-recompile non inclusi nell'installer."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="Il wiki non si aggiornerà automaticamente; puoi rieseguire manualmente la prima compilazione:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="Marcatore di postura scritto: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="Le tue esportazioni sono al sicuro. Importale più tardi con: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="I dati del tuo Mac (iMessage, Safari, ecc.) sono già stati estratti sopra."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="Puoi aggiungerlo più tardi per un'attivazione immediata da Safari, iMessage, ecc."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="Modello IA: %s (%s) – scelto per i tuoi %s GB di RAM"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="Adatto"
MSG_MODELFIT_PILL_SLOW="Potrebbe essere lento"
MSG_MODELFIT_PILL_NOFIT="Non adatto"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="Abbino il modello dell'assistente al tuo Mac (%s, %s GB di RAM, contesto dell'assistente %s token):"
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- Consigliato"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="Modello IA: %s (%s) – il più adatto ai tuoi %s GB di RAM con la finestra di contesto richiesta dall'assistente"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="Tutte le fonti selezionate (riconoscimento facciale ancora disattivato)"
MSG_OK_ALREADY_AVAILABLE="%s già disponibile"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon rilevato"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="App avviate per attivare la sincronizzazione di iCloud"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="Database delle app già presenti (avvio preliminare saltato)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="Configurazione dell'assistente salvata in %s (modalità 0600)"
MSG_OK_BACKED_UP_CONTACTS="Backup di %s contatti eseguito in %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s installato in %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="LaunchAgent di Ostler RemoteCapture caricato (etichetta %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima e Docker CLI installati"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="Supervisore del runtime dei container installato (controlla ogni 5 minuti e riavvia il runtime se si arresta)"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="Non è stato possibile pianificare il supervisore del runtime dei container. Ostler verrà comunque installato, ma se in seguito il runtime si arresta nulla lo riavvierà da solo: la tua wiki resterebbe inattiva finché non esegui di nuovo l'installer."
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="I file del supervisore del runtime dei container mancano in questo installer, quindi non è stato pianificato. Ostler verrà comunque installato, ma il ripristino automatico del runtime non è attivo."
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
# NEEDS REVIEW: Page names People/Timeline/Governor must match the app's Italian navigation labels; 'la dashboard' is the more usual gender in Italian.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="Non è stato possibile avviare la dashboard Doctor di Ostler, quindi http://localhost:8089 non risponderà. Le pagine dell'app che ne leggono i dati (Persone, Cronologia, Governor, stato dei canali) risulteranno non disponibili finché non sarà in esecuzione. Esegui di nuovo l'installer per riprovare."
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="Non è stato possibile pianificare l'helper che mantiene il Mac attivo. Ostler funziona comunque, ma questo Mac potrebbe entrare in stop durante le attività lunghe in background, che riprenderanno al risveglio invece di terminare durante la notte."
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="Non è stato possibile pianificare l'helper di aggiornamento in background, quindi nuovi messaggi, email ed eventi del calendario non verranno acquisiti automaticamente. Esegui di nuovo l'installer per ripristinarlo."
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="%s not set up: Ostler has no record of your answer to the question that governs it, so it did not assume one."
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  Re-run Ostler and choose to answer the questions again to turn it on. (consent record: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="Non è stato possibile pianificare il riepilogo giornaliero, quindi non riceverai il riassunto del mattino. Tutto il resto funziona; esegui di nuovo l'installer per ripristinarlo."
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="Non è stato possibile pianificare la pulizia della memoria, quindi i dati obsoleti o superati non verranno ridimensionati automaticamente. Tutto il resto funziona; esegui di nuovo l'installer per ripristinarla."
MSG_WARN_EXPORT_SCAN_NOT_LOADED="Non è stato possibile avviare il controllo della cartella Download, quindi i file che sposti in Download non verranno acquisiti automaticamente. Ciò che è già stato importato non cambia e puoi comunque aggiungere file dall'interno dell'app. Esegui di nuovo l'installer per ripristinarlo."
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="Non è stato possibile pianificare l'helper che riprova la registrazione del dispositivo. Se il tuo iPhone si è registrato durante la configurazione, non cambia nulla; altrimenti dovrai eseguire di nuovo l'associazione dall'app, perché non si completerà da sola."
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="Il runtime dei container risponde"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="Rimossa una voce di avvio di Colima obsoleta lasciata da una versione precedente"
MSG_OK_CONFIG_SAVED_ENV="Configurazione salvata in %s/.env"
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Consent records and region persisted to ~/.ostler/posture/"
MSG_OK_AT_REST_EXCLUDED="Esclusione da Spotlight e Time Machine verificata: %s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s NON è escluso da Time Machine o Spotlight: %s. Il suo contenuto, compresi i segreti di Ostler, potrebbe essere copiato sul disco di backup. Doctor continuerà a mostrarlo finché non sarà risolto."
MSG_INFO_AT_REST_FOLDER_ABSENT="%s non esiste ancora, quindi non c'è nulla da escludere dai backup."
MSG_WARN_DB_KEY_NOT_EXCLUDED="Il file della chiave del database %s NON è escluso da Time Machine, quindi potrebbe essere copiato sul disco di backup."
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="Non è stato possibile salvare la tua scelta sull'arricchimento in background in ~/.ostler/posture/. La scelta viene comunque applicata a questa installazione; semplicemente non comparirà in un rapporto per l'assistenza."
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="Database cifrati. I servizi dell'Hub leggono la chiave da un file protetto nella tua cartella Home, quindi si avviano senza chiederti nulla."
MSG_OK_DB_KEY_DELIVERED="Chiave del database consegnata ai servizi dell'Hub (%s, leggibile solo da te)."
MSG_WARN_DB_KEY_NOT_DELIVERED="Non è stato possibile consegnare la chiave del database ai servizi dell'Hub. Apriranno i database non cifrati finché il problema non sarà risolto."
MSG_INFO_DB_KEY_RECOVER_HINT="Esegui questo comando per recuperarla e consegnarla: %s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="Cifratura degli eventuali database rimasti da un'installazione precedente"
MSG_WARN_DB_MIGRATION_FAILED="Non è stato possibile cifrare alcuni database esistenti. Restano leggibili su disco."
MSG_WARN_DB_KEY_MISSING_ON_RERUN="Questa installazione non ha un file della chiave del database, quindi i servizi dell'Hub aprono i database non cifrati."
MSG_WARN_DB_PLAINTEXT_COUNT="%s database su questo Mac sono al momento leggibili su disco."
MSG_INFO_DB_MIGRATE_HINT="Poi cifra quelli già presenti: %s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="Nuovo tentativo differito di registrazione del dispositivo installato (viene eseguito ogni ora finché la coda non si svuota)"
MSG_OK_DOCKER_RUNNING="Docker in esecuzione"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker in esecuzione (in %ss)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Agente Doctor clonato da %s"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="File dell'agente Doctor inclusi nell'installer"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Dipendenze di Doctor installate"
MSG_OK_EMAIL_CHANNEL_FOLDER="Canale email: %s (cartella: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent di acquisizione email caricato (label com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="Script di acquisizione email inclusi nell'installer"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="Script di acquisizione email clonati da %s"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="Configurazione della memoria delle conversazioni di WhatsApp"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  Lettore delle conversazioni di WhatsApp installato."
MSG_WARN_WHATSAPP_SOURCE_FAILED="Installazione del lettore delle conversazioni di WhatsApp non riuscita; il flusso delle conversazioni di WhatsApp non verrà eseguito. Vedi l'output sopra."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="Sorgente del lettore delle conversazioni di WhatsApp non trovata; il flusso delle conversazioni di WhatsApp viene saltato."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="Pacchetto del flusso delle conversazioni di WhatsApp non trovato in questo installer; viene saltato. La cronologia dei messaggi di WhatsApp (con chi hai scritto e quando) non è interessata."
MSG_OK_WHATSAPP_BUNDLE_LOADED="LaunchAgent del flusso delle conversazioni di WhatsApp caricato (label com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  Il primo ciclo legge le conversazioni WhatsApp recenti sincronizzate sul tuo Mac (circa l'ultimo anno); restano sul tuo Mac."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  Log: %s/whatsapp-bundle.log e whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="Installazione del LaunchAgent del flusso delle conversazioni di WhatsApp non riuscita. Vedi l'output sopra; il resto dell'installazione non è interessato."
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  Non ancora avviato: il programma dell'assistente eseguito da questo agente non è presente sul disco. Percorso cercato: %s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="Configurazione della memoria delle conversazioni email"
MSG_OK_EMAIL_SOURCE_INSTALLED="  Lettore delle conversazioni email installato."
MSG_WARN_EMAIL_SOURCE_FAILED="Installazione del lettore delle conversazioni email non riuscita; il flusso delle conversazioni email non verrà eseguito. Vedi l'output sopra."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="Sorgente del lettore delle conversazioni email non trovata; il flusso delle conversazioni email viene saltato."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="Pacchetto del flusso delle conversazioni email non trovato in questo installer; viene saltato. L'acquisizione email oraria non è interessata."
MSG_OK_EMAIL_BUNDLE_LOADED="LaunchAgent del flusso delle conversazioni email caricato (label com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Legge le tue conversazioni email recenti dall'archivio locale di Apple Mail; tutto resta sul tuo Mac."
MSG_INFO_EMAIL_BUNDLE_LOGS="  Log: %s/email-bundle.log e email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="Installazione del LaunchAgent del flusso delle conversazioni email non riuscita. Vedi l'output sopra; il resto dell'installazione non è interessato."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="Configurazione della memoria delle conversazioni di riunioni e voce"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  Lettore delle conversazioni di riunioni e voce installato."
MSG_WARN_SPOKEN_SOURCE_FAILED="Installazione del lettore delle conversazioni di riunioni e voce non riuscita; il flusso non verrà eseguito. Vedi l'output sopra."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="Sorgente del lettore delle conversazioni di riunioni e voce non trovata; il flusso viene saltato."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="Pacchetto del flusso delle conversazioni di riunioni e voce non trovato in questo installer; viene saltato."
MSG_OK_SPOKEN_BUNDLE_LOADED="LaunchAgent del flusso delle conversazioni di riunioni e voce caricato (label com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  Trascrive le tue riunioni e note vocali in conversazioni ricercabili; tutto resta sul tuo Mac."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  Log: %s/spoken-bundle.log e spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="Installazione del LaunchAgent del flusso delle conversazioni di riunioni e voce non riuscita. Vedi l'output sopra; il resto dell'installazione non è interessato."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="Configurazione della memoria delle conversazioni di iMessage"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  Lettore delle conversazioni di iMessage installato."
MSG_WARN_IMESSAGE_SOURCE_FAILED="Installazione del lettore delle conversazioni di iMessage non riuscita; il flusso delle conversazioni di iMessage non verrà eseguito. Vedi l'output sopra."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="Sorgente del lettore delle conversazioni iMessage non trovata; salto il feed delle conversazioni iMessage."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="Pacchetto del feed delle conversazioni iMessage non trovato in questo installer; salto."
MSG_OK_IMESSAGE_BUNDLE_LOADED="LaunchAgent del feed delle conversazioni iMessage caricato (etichetta com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  Legge le tue conversazioni iMessage recenti dall'archivio di Messaggi di questo Mac; tutto resta sul tuo Mac."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  Log: %s/imessage-bundle.log e imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="Installazione del LaunchAgent del feed delle conversazioni iMessage non riuscita. Vedi l'output qui sopra; il resto dell'installazione non è interessato."
MSG_OK_EMBEDDING_MODEL_READY="Modello di embedding pronto"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="Esportati %s contatti (verranno importati automaticamente)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="Controllo delle esportazioni installato (analizza Download ogni 4 ore)"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  Controllo delle esportazioni non ancora avviato: il programma dell'assistente che esegue non è presente sul disco. Percorso cercato: %s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="Invio del riepilogo pre-riunione installato (controlla ogni 10 minuti durante le ore di veglia)"
MSG_OK_MEMORY_HYGIENE_INSTALLED="Pulizia della memoria pianificata (ogni giorno, evita che i dati obsoleti oscurino quelli attuali)"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="Il tuo Mac resterà attivo quando è collegato alla corrente, così Ostler continua a funzionare (con la batteria va comunque in stop)"
MSG_OK_EXTRACTED="Estratto in %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="Estratto da %s sorgenti. Dati salvati in %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="Nuova esecuzione FDA pianificata ogni %s minuti (intercetta le sincronizzazioni lente di iCloud e completa il recupero del calendario)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro attivo per 30 giorni. Abbonati nell'app Ostler sul tuo iPhone per proseguire dopo la prova."
MSG_OK_FOUND="Trovato: %s"
MSG_OK_FOUND_EXPORTS="Esportazioni trovate in %s"
MSG_OK_FOUND_GDPR_EXPORT_S="Trovate %s esportazioni GDPR:"
MSG_OK_GB_FREE_DISK_SPACE="%s GB di spazio libero su disco"
MSG_OK_GB_RAM_DETECTED="Rilevati %s GB di RAM"
MSG_OK_GDPR_IMPORT_COMPLETE="Importazione GDPR completata"
MSG_OK_GIT_AVAILABLE="Git disponibile"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="Installazione degli strumenti da riga di comando avviata (download in background mentre rispondi alle domande qui sotto)."
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils installato (i passaggi lunghi ora hanno un limite di tempo)"
MSG_OK_HOMEBREW_INSTALLED="Homebrew installato"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent di alimentazione dell'Hub caricato (etichetta com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Script di alimentazione dell'Hub inclusi nell'installer"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Script di alimentazione dell'Hub clonati da %s"
MSG_OK_ICAL_SERVER_INSTALLED="API dell'assistente installata (loopback 127.0.0.1:8090, tramite proxy di Doctor)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="LaunchAgent del bridge iMessage caricato (etichetta com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="Script del bridge iMessage inclusi nell'installer"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="Script del bridge iMessage clonati da %s"
MSG_OK_IMESSAGE_CHANNEL="Canale iMessage: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="Pipeline di importazione inclusa nell'installer"
MSG_OK_IMPORT_PIPELINE_READY="Pipeline di importazione pronta"
MSG_OK_CM048_PIPELINE_READY="Motore della memoria delle conversazioni pronto."
MSG_INFO_CM048_SETTINGS_WRITTEN="  Modelli di conversazione impostati su %s (adatti ai tuoi %s GB di memoria)"
MSG_INFO_CM048_SETTINGS_KEPT="  Le impostazioni di conversazione esistenti restano invariate (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="Servizio di conoscenza pronto: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="Testi delle licenze installati in %s/ (origine: %s)"
MSG_OK_MACOS_DETECTED="macOS %s rilevato"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="Apertura di Impostazioni di Sistema > Account Internet per aggiungere un account di posta. Torna a questa finestra dopo aver effettuato l'accesso al tuo primo account."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="Passaggio Account Internet saltato. Puoi aggiungere un account di posta più tardi da Impostazioni di Sistema; Doctor mostrerà un promemoria se non arriva posta entro 24 ore."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Recupero dell'intera cronologia di Apple Mail in corso. Con una casella di posta molto grande può volerci un po' più tempo."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="Viene mantenuto l'intervallo standard di cinque anni per la posta. Potrai recuperarne altra più tardi da Doctor."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text già disponibile"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="Ollama installato"
MSG_WARN_OLLAMA_CUSTOMER_APP_PRESENT="An Ollama app is already installed in Applications. Ostler leaves it exactly as it is and runs its own copy of Ollama %s alongside it. If that app is open in the menu bar, quit it so Ostler can start its own."
MSG_WARN_OLLAMA_PIN_DEFERRED="Could not update Ollama to %s this time, so Ostler is keeping the copy it already runs (%s). Your assistant keeps working. The update will be tried again the next time the installer runs. Details: %s"
MSG_WARN_MODEL_PULL_HELD_OLLAMA_UNPINNED="Not downloading %s this time: Ostler's tested copy of Ollama (%s) is not installed yet, and a different Ollama could fetch the wrong build. The next installer run downloads it."
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama installato (solo CLI – potrebbe richiedere l'avvio manuale dopo il riavvio)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama installato (app per desktop)"
MSG_OK_OLLAMA_RUNNING="Ollama in esecuzione"
MSG_OK_EMBEDDINGS_VERIFIED="Motore di embedding verificato (vettori a 768 dimensioni)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: 0 errori nei suoi controlli di avvio"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent dell'assistente Ostler caricato (etichetta com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s preparato in %s (firmato)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s preparato in %s (non firmato)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor in esecuzione su http://localhost:8089/doctor"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  Il modulo di estrazione dei dati si carica correttamente."
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Lettore di Apple Mail installato."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  Motore di acquisizione della posta installato."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="Comandi ostler-import, ostler-fda e ostler-uninstall installati"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="Passphrase registrata. Cifrerà i tuoi database durante la Fase 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="Passphrase di recupero configurata."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="Informativa sulla passphrase confermata."
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="Password dell'esportazione di Disney+ registrata. Verrà usata durante l'importazione."
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="Esportazione di Disney+ saltata: non è stata fornita alcuna password. Nient'altro ne risente."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="Alimentazione: rete elettrica (Mac desktop, senza batteria)"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="Alimentazione: rete elettrica (bene – l'installazione può durare da 45 minuti a qualche ora, e la corrente di rete la mantiene stabile)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="Installazione precedente rilevata. Caricamento della configurazione..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="Uso di Python %s incluso (nessuna installazione di sistema necessaria)"
MSG_OK_PYTHON_INSTALLED="Python %s installato"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="Servizio di abbinamento funzionante"
MSG_WARN_GATEWAY_NOT_RESPONDING="Il servizio di abbinamento non risponde (127.0.0.1:8000) - l'abbinamento con telefono/browser e l'assistente in chat potrebbero non funzionare ancora"
MSG_OK_DOCTOR_HEALTHY="Doctor funziona correttamente"
MSG_WARN_DOCTOR_NOT_RESPONDING="Doctor non risponde (127.0.0.1:8089): l'app e il browser raggiungono Ostler tramite Doctor, quindi dati e abbinamento potrebbero non essere disponibili"
MSG_OK_WIKI_HEALTHY="Il tuo wiki funziona correttamente"
MSG_OK_ICAL_SERVER_HEALTHY="L'API dell'assistente funziona correttamente"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="L'API dell'assistente non risponde (127.0.0.1:8090): Persone, Riunioni e Cronologia potrebbero restare vuote finché non si avvia"
MSG_OK_READY="%s pronto"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="Fonti consigliate selezionate"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="Chiave di recupero salvata nel Portachiavi (cerca 'Ostler' nell'app Password)"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Estensione di Safari installata in %s"
MSG_OK_SAFARI_EXTENSION_PAIRED="Estensione di Safari abbinata a questo Hub"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="La sicurezza era già stata configurata in un'esecuzione precedente."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="Modulo di sicurezza installato nel venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="Nuovo JWT_SECRET generato in %s"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="Token di servizio PWG generato in %s"
MSG_OK_SEEDED_EXTENSION_TOKEN="Chiave dell'estensione del browser generata in %s"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="Servizi avviati (Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  Raccolta di ricerca preparata: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="Impossibile preparare per ora la raccolta di ricerca %s; l'importazione dei dati qui sotto riproverà e si fermerà, senza scartare i tuoi dati, se ancora non riesce."
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="L'indice di ricerca non è ancora pronto; l'importazione dei dati qui sotto lo attenderà, preparerà le raccolte e si fermerà, senza scartare i tuoi dati, se l'archivio non sarà ancora pronto."
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="I tuoi dati non sono stati importati. Non è stato possibile preparare l'archivio di ricerca per contenerli (mancante: %s) e importarli comunque li avrebbe scartati in silenzio. Non è andato perso nulla. Riesegui l'installer quando il computer è inattivo, oppure imposta OSTLER_QDRANT_READY_WAIT_S per attendere più a lungo."
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="L'importazione dei dati ha elaborato %s record, ma non ne ha salvato nessuno: l'archivio di ricerca li ha rifiutati tutti, quindi il risultato sarebbe un grafo della conoscenza vuoto presentato come completo. Mi fermo invece di mostrartelo. Riesegui l'installer quando il computer è inattivo."
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="Impossibile leggere il log dell'importazione, quindi non è stato possibile verificare che i tuoi dati siano arrivati a destinazione. Questo non significa che l'importazione sia fallita, né che sia riuscita."
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="Stop disattivato con alimentatore, stop a batteria mantenuto, riattivazione dalla rete abilitata"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="Stop disattivato, riattivazione dalla rete abilitata"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale già installato"
MSG_OK_TAILSCALE_INSTALLED="Tailscale installato"
MSG_OK_TAILSCALE_ENV_PERSISTED="IP di Tailscale salvato in .env – l'app Ostler sul tuo iPhone lo userà al primo avvio."
MSG_OK_TAILSCALE_IP="IP di Tailscale: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Servizio in background di Tailscale avviato (modalità userspace, nessuna estensione di sistema)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="Impossibile avviare il servizio in background di Tailscale. Potrai rieseguire la configurazione più tardi da Impostazioni."
MSG_INFO_TAILSCALE_SIGN_IN_URL="Apertura del browser per accedere a Tailscale: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Porta %s dell'Hub esposta sulla tua tailnet"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="Impossibile esporre la porta %s dell'Hub sulla tua tailnet; l'accesso fuori dalla rete locale potrebbe essere limitato"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="Il tuo wiki ora è leggibile dai tuoi dispositivi all'indirizzo %s – con il tuo accesso, e solo il tuo."
MSG_INFO_WIKI_TAILNET_OWNER="L'accesso al wiki è limitato al tuo account Tailscale (%s). Le altre persone sulla tua tailnet ricevono un errore 403."
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="Il tuo wiki resta solo su questo Mac. Apri Ostler e scegli Wiki nella barra laterale per leggerlo."
MSG_INFO_WIKI_TAILNET_BANNER="%s  (dai tuoi dispositivi, tramite Tailscale. È l'unico percorso che ti chiede l'accesso indicato sopra.)"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="nell'app Ostler. Apri Ostler e scegli Wiki nella barra laterale; le tue pagine sono lì, con l'accesso già effettuato."
MSG_INFO_WIKI_INTERNAL_ADDRESS="Ostler recupera quelle pagine da http://localhost:8044 su questo Mac. Quell'indirizzo è interno e non richiede alcun accesso da parte tua."
MSG_INFO_WIKI_SIGN_IN="Il tuo nome utente per il wiki è %s e la password è %s. Ostler li inserisce per te, quindi su questo Mac non devi digitare nulla; ti servono solo quando apri il wiki da un altro tuo dispositivo tramite Tailscale."
MSG_INFO_WIKI_SIGN_IN_WITHHELD="Il tuo accesso alla wiki è %s. La password non viene scritta in questo log: è negli appunti e nel file indicato qui sotto. Ostler la inserisce per te, quindi su questo Mac non devi digitare nulla."
MSG_INFO_WIKI_PORT_LAST_STATUS="Ultimo stato HTTP dalla porta della wiki: %s (000 significa che nessuno ha risposto; 403 significa che ha risposto e ha rifiutato la credenziale)."
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="La tua password è conservata anche in %s, quindi gli appunti non sono l'unica copia."
MSG_INFO_WIKI_STILL_BUILDING="Creazione ancora in corso. Sul disco ci sono già %s pagine e l'ultima risposta dall'indirizzo della wiki è stata HTTP %s. Comparirà da sola nell'app Ostler. Non devi fare nulla."
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="La prima creazione non ha ancora prodotto pagine (vedi gli avvisi sopra). La tua wiki si aprirà comunque nell'app Ostler non appena sarà pronta, e l'accesso qui sopra resta tuo."
MSG_INFO_WIKI_READINESS_NOT_MEASURED="Questa esecuzione non ha verificato se la wiki è già in linea, quindi non afferma né una cosa né l'altra. La tua wiki si apre comunque nell'app Ostler e l'accesso qui sopra resta tuo."
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="Non è stato possibile confermare quale account Tailscale possieda questo Mac, quindi la wiki NON è stata resa accessibile sulla tua tailnet. È comunque disponibile su questo Mac, nell'app Ostler sotto Wiki."
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="Non è stato possibile pubblicare la wiki sulla tua tailnet; è comunque disponibile su questo Mac, nell'app Ostler sotto Wiki."
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="Non è stato possibile ricaricare il controllo di accesso della wiki, quindi la wiki NON è stata resa accessibile sulla tua tailnet."
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="Tailscale Funnel è attivo per %s. Funnel pubblica su internet aperto. Ostler non attiva mai Funnel e la tua wiki rifiuta il traffico di Funnel, quindi nulla di Ostler è pubblico – ma se non volevi attivarlo, disattivalo nella console di amministrazione di Tailscale per questo computer."
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="Attribuzioni di terze parti installate (origine: %s)"
MSG_OK_USER_FACING_TREE_READY="Struttura visibile all'utente pronta"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="Verrà usata la cartella/etichetta 'Ostler'."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane funziona correttamente (ricerca web locale)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane in esecuzione su http://localhost:3000 (dialoga con il tuo Ollama locale)"
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="WhatsApp connector will be enabled (consent recorded)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="LaunchAgent di recupero della wiki del primo giorno caricato (ricostruisce la wiki ogni 30 minuti per le prime ore, poi si ferma)"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="Unione dei contatti duplicati ancora in corso – le rubriche grandi possono richiedere alcuni minuti (%ss trascorsi)"
MSG_INFO_DEDUPE_MERGED="Contatti duplicati uniti"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="L'unione dei contatti duplicati richiede un po' di tempo per una rubrica di queste dimensioni. Continuerà in background dopo l'installazione – la tua wiki si aggiorna automaticamente al termine."
MSG_WARN_DEDUPE_INCOMPLETE="Il passaggio di deduplicazione dell'intero grafo non si è concluso correttamente (vedi %s); si continua"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="Contatti duplicati uniti completamente durante l'installazione; non serve alcun recupero in background"
MSG_OK_DEDUPE_CATCHUP_LOADED="LaunchAgent di deduplicazione dei contatti in background caricato (termina l'unione dei duplicati dopo l'installazione, poi si ferma)"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="Impossibile caricare il LaunchAgent di deduplicazione dei contatti in background. I duplicati verranno comunque uniti dalla manutenzione giornaliera; ci vorrà solo più tempo per sistemare tutto."
MSG_OK_ENRICH_AGENT_LOADED="LaunchAgent di arricchimento in background caricato (completa i dettagli su film, luoghi, libri e link; viene eseguito a fasi nell'arco di circa un giorno)"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="Impossibile caricare il LaunchAgent di arricchimento in background. Le tue preferenze sono salvate e ricercabili; mancheranno solo i dettagli di riferimento aggiuntivi (registi, cast, luoghi) fino alla sua esecuzione."
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent di ricompilazione della wiki caricato (etichetta com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Script di ricompilazione della wiki inclusi nell'installer"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Script di ricompilazione della wiki clonati da %s"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="Configurazione della tua Prima pagina (aggiornamento ogni ora)"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="Generatore della Prima pagina incluso nell'installer"
MSG_OK_EDITOR_FRONTPAGE_LOADED="LaunchAgent della Prima pagina caricato (etichetta com.creativemachines.ostler.editor-frontpage)"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  Il primo aggiornamento parte ora; la Prima pagina della Dashboard si riempie man mano che Ostler legge le tue preferenze."
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  Log: %s/editor-frontpage.log e editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="Generatore della Prima pagina non trovato in questo installer; la Prima pagina della Dashboard non verrà aggiornata."
MSG_WARN_EDITOR_FRONTPAGE_FAILED="Installazione del LaunchAgent della Prima pagina non riuscita. Vedi l'output sopra; il resto dell'installazione non è interessato."
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="Configurazione del recupero della tua Prima pagina"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="LaunchAgent di recupero della Prima pagina caricato (controlla ogni 5 minuti finché i tuoi interessi non sono stati letti, poi si ferma)"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="Impossibile caricare il LaunchAgent di recupero della Prima pagina. La tua Prima pagina e ciò che Ostler sa dei tuoi interessi si completeranno invece al prossimo aggiornamento orario."
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="Recupero della Prima pagina saltato: l'aggiornamento della Prima pagina non è installato, quindi non c'è nulla da rieseguire."
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki in esecuzione su http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="La tua wiki è pronta da consultare. Ostler sta scrivendo i riepiloghi delle pagine in background, quindi compariranno gradualmente nel giro di un po'. Puoi iniziare a usare subito la tua wiki."
MSG_OK_YOUR_ASSISTANT_CALLED="Il tuo assistente si chiama %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="Script del riepilogo del contesto personale inclusi nell'installer"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="LaunchAgent del riepilogo del contesto personale caricato (etichetta com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  Log: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="Riutilizzo l'installazione di context-refresh esistente in %s"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="Script del riepilogo del contesto personale non inclusi; l'assistente si baserà solo su ricerche in tempo reale (nessun riepilogo del contesto sempre attivo)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="Impossibile caricare il LaunchAgent del riepilogo del contesto personale; consulta context-refresh.err. L'assistente risponde comunque tramite ricerche in tempo reale"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="Nel sorgente clonato del servizio Knowledge manca la configurazione di pacchettizzazione, quindi il suo ambiente non è stato configurato."
MSG_WARN_BUNDLE="  Bundle: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s è disponibile solo per Apple Silicon (rilevato: %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="Impossibile scaricare Ostler RemoteCapture v%s da %s"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="Cause comuni: tag di rilascio non ancora pubblicato, rete non disponibile o notarizzazione a monte ancora in corso. Riesegui l'installer quando il rilascio sarà disponibile."
MSG_WARN_CM042_EXTRACT_FAILED="Impossibile estrarre il tarball di Ostler RemoteCapture; salto il LaunchAgent."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Caricamento del LaunchAgent di Ostler RemoteCapture non riuscito. Consulta l'output sopra e ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  L'arricchimento delle conversazioni non sarà disponibile. Il resto di Ostler si installa normalmente; riesegui senza --allow-plaintext per collegare il motore di memoria delle conversazioni."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="Installazione del motore di memoria delle conversazioni non riuscita (clone)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  Cercato in: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  Di solito significa che l'.app dell'installer è stata creata senza"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  il pacchetto cm048_pipeline integrato in"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Scarica di nuovo l'installer oppure"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  riesegui con --allow-plaintext per un'installazione dev/CI."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="Motore di memoria delle conversazioni non trovato. L'arricchimento delle conversazioni non può funzionare senza di esso."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="Configurazione del motore di memoria delle conversazioni saltata (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="Sorgente del motore di memoria delle conversazioni trovato ma pyproject.toml manca; configurazione del venv saltata."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Colima non si è avviato. Provo Docker Desktop come alternativa..."
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="Impossibile installare GNU coreutils; i passaggi lunghi verranno eseguiti senza limite di tempo (una riga di avanzamento mostra comunque che sono in corso)."
MSG_WARN_COLIMA_START_RETRY="Colima non si è avviato correttamente (il socket Docker non era pronto). Nuovo tentativo tra %ss..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="Cause comuni: tag v%s non ancora pubblicato, rete non disponibile,"
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  consent_cli stderr (first 400 chars):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  Script da console non creato in %s; in pyproject.toml potrebbe mancare la voce [project.scripts]."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="Continuo perché è stato passato --allow-plaintext."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="Continuo l'installazione. Riesegui \`ostler-fda\` dopo aver diagnosticato l'errore sopra."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="Continuo senza la compilazione automatica dalla scheda contatto – Ostler te lo chiederà direttamente."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  Le conversazioni inviate a iMessage falliranno in silenzio finché"
# NEEDS REVIEW: Source names the Energy panel (Italian macOS: "Energia"), not Batteria; exact Apple Italian wording of the option label needs verification against macOS.
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="Impossibile modificare le impostazioni di stop. Attiva \"Impedisci stop automatico quando collegato all'alimentazione\" in Impostazioni di Sistema > Energia."
# NEEDS REVIEW: Source says Energy pane (desktop Macs); 'Batteria' is the laptop pane. Verify Apple's exact Italian pane name and option label for the target macOS version.
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="Impossibile modificare le impostazioni di stop. Attiva \"Impedisci lo stop automatico\" in Impostazioni di Sistema > Energia."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="Impossibile scaricare ostler-assistant v%s da %s"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="Impossibile estrarre l'mbox di Gmail dallo zip di Takeout – salto."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="Impossibile estrarre il tarball di ostler-assistant; salto il LaunchAgent."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="Impossibile trovare la CLI di Tailscale. Potrai configurarla manualmente più tardi."
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Could not install legal/ consent-strings package; continuing"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="Impossibile installare la cartella LICENSES/ (non critico)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="Impossibile installare ostler_security nel venv dell'Hub."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="Impossibile installare THIRD_PARTY_NOTICES.md (non critico)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="Impossibile ottenere l'agente Doctor (sia la copia inclusa sia il clone non sono riusciti)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="File di Ostler Doctor non trovati. Sono necessari per l'abbinamento con iOS (Ostler.app incorpora :8089/pair-ios in un iframe)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  Cercato in: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  Di solito significa che l'.app dell'installer è stata creata senza"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  il sorgente doctor/agent/ incluso in"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Scarica di nuovo l'installer oppure"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  riesegui con --allow-plaintext per un'installazione dev/CI."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Installazione di Doctor interrotta: è necessario per l'abbinamento con iOS. Scarica di nuovo l'installer oppure usa --allow-plaintext per un'installazione dev/CI."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="Impossibile ottenere gli script di importazione email (sia la copia inclusa sia il clone non sono riusciti)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="Impossibile ottenere gli script hub-power (sia la copia inclusa sia il clone non sono riusciti)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="Impossibile ottenere gli script wiki-recompile (sia la copia inclusa sia il clone non sono riusciti)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="Impossibile aprire automaticamente l'URL del Chrome Web Store: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="Impossibile salvare region.json (continuo: Doctor lo segnalerà)"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="Impossibile registrare che la chiave di recupero è stata consegnata. Il riepilogo di questa esecuzione è comunque corretto, ma un'esecuzione successiva potrebbe non saperlo e avvisare di nuovo – tra i possibili errori, è quello più sicuro."
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="Your recovery key was not saved to Keychain. Write it down and keep it somewhere safe, away from this Mac."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="Impossibile avviare Ollama automaticamente."
MSG_FAIL_OLLAMA_PORT_IN_USE="Un altro programma sta già usando la porta 11434, di cui Ostler ha bisogno per la sua AI locale. Ostler non è riuscito ad avviare la propria copia, quindi l'installazione si è fermata qui invece di restare a metà.

  Cosa occupa la porta: %s
  L'errore esatto si trova in: %s

Di solito è una copia di Ollama che avevi già, oppure una rimasta attiva da un'installazione precedente di Ostler. Chiudila (o riavvia questo Mac) ed esegui di nuovo l'installer."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="Impossibile aggiornare la pipeline (sei offline?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="Impossibile scrivere pipeline_signals.json. La diagnostica di Doctor per Mail vuota userà valori predefiniti sicuri fino alla prossima installazione o al prossimo ciclo."
MSG_WARN_CURL_SAID="Curl ha risposto:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="Cartella non trovata: %s – salto l'importazione."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker non si è avviato entro %s secondi."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker è installato ma non in esecuzione. Va avviato."
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="Il comando Docker è presente su questo Mac, ma dietro non c'è nulla in esecuzione. Su macOS il comando Docker è solo un client: serve un motore come Colima o Docker Desktop per eseguire davvero qualcosa. L'installer ne configurerà uno."
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="Diagnostica del runtime dei container - client docker: %s | colima: %s | Docker Desktop: %s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="Il container della wiki è stato avviato, ma nulla ha risposto su http://localhost:8044 entro 60 secondi. Considera la wiki come NON in esecuzione: il codice di uscita del comando di avvio non prova che la pagina si carichi."
MSG_WARN_WIKI_NOT_RESPONDING="La tua wiki non risponde (127.0.0.1:8044). Funziona in un container, quindi di solito significa che il runtime dei container si è fermato. Apri Ostler Doctor su http://localhost:8089/doctor per scoprirne il motivo."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama a metà installazione e bloccano i controlli di disponibilità."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  primi indicatori (canali ancora in connessione + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="Installazione del LaunchAgent per l'importazione delle email non riuscita. Vedi l'output qui sopra."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="Installazione del LaunchAgent del bridge iMessage non riuscita. Le risposte iMessage dell'utente dell'assistente non funzioneranno finché non esegui di nuovo l'installer o lanci INSTALL_SNIPPET.sh manualmente."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Gli script del bridge iMessage non sono inclusi ed è stato passato --allow-plaintext; l'installazione del LaunchAgent verrà saltata. Le risposte iMessage dell'utente dell'assistente non funzioneranno."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="La crittografia non funzionerà."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="La crittografia non funzionerà e"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="assicurati che il tag PWG_KNOWLEDGE_REPO fissato lo includa."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  Events per Messages.app)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="L'estrattore FDA è terminato con codice diverso da zero (%s). Ultime 20 righe dell'output:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="Il modulo di estrazione FDA non è incluso in questo installer."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="Percorso previsto: Contents/Resources/ostler_fda/ (all'interno del .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="Causa più probabile: una regressione nella build ha escluso la copia del vendor. Scarica di nuovo il .app da ostler.ai/install."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="Il modulo di estrazione FDA non è incluso. Si continua perché è stato passato --allow-plaintext – l'estrazione istantanea dei dati verrà saltata."
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="Il modulo di estrazione dei dati è presente sul disco, ma le sue dipendenze non sono state installate, quindi non può essere caricato:"
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="Si continua perché è stato passato --allow-plaintext – l'aggiornamento pianificato dei dati non riuscirà a ogni esecuzione."
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault NON è attivo."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="Impossibile attivare il primo mese gratuito in questo momento; l'installazione continuerà. Apri l'app Ostler sul tuo iPhone dopo l'abbinamento per risolvere."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="Accesso completo al disco non concesso a Terminale."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="Rilevati %s GB di RAM. Avrai l'assistente compatto (gemma4:e2b): affidabile, preciso, con risposte in meno di un secondo alle domande brevi, con chiamate a strumenti e un onesto «non lo so» quando non sa rispondere. Per risposte più ricche a domande più lunghe, da 24 GB in su si sblocca l'assistente standard (qwen3.5:9b). Potrai cambiare Mac in seguito reinstallando."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="L'importazione GDPR ha riscontrato errori. Puoi riprovare con:"
MSG_WARN_GRAPH_DB_PULL_RETRY="Download del database non completato (tentativo %s di %s). Nuovo tentativo tra %ss..."
MSG_WARN_GRAPH_DB_UP_RETRY="I database del grafo della conoscenza non si sono avviati (tentativo %s di %s). Nuovo tentativo..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="L'importazione GDPR fa parte dell'installazione completa del prodotto. Senza di essa, il tuo grafo sociale (LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google Calendar) non può essere importato."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="L'importazione GDPR non sarà disponibile su questa istanza finché la pipeline di importazione non verrà reinstallata."
MSG_WARN_GIT_SAID="Git ha risposto:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  Controllo di integrità non riuscito: ostler-knowledge --version non ha prodotto alcun output."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  Controllo di integrità non riuscito: il motore della memoria delle conversazioni non è stato caricato (pwg-convo o l'importazione della sua pipeline non si è conclusa correttamente)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="L'installer di Homebrew è terminato con %s. Seguono le ultime 30 righe di %s:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Log di installazione di Homebrew (ultime righe) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="L'installazione pip di Doctor è terminata con %s. Seguono le ultime 30 righe di %s:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Log di installazione pip di Doctor (ultime righe) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="L'installazione pip della pipeline è terminata con %s. Seguono le ultime 30 righe di %s:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- Log di installazione pip della pipeline (ultime righe) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Installazione del LaunchAgent per l'alimentazione dell'Hub non riuscita. Vedi l'output qui sopra."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="Script di alimentazione dell'Hub non trovati nel percorso previsto del bundle."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  Sembra che nel .app dell'installer manchi vendor/hub_power/"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  in Contents/Resources/hub-power/. La regolazione in base alla batteria non verrà installata; il resto dell'installazione continuerà."
MSG_WARN_ICAL_SERVER_FAILED="Impossibile avviare l'API dell'assistente; l'app Ostler sul tuo iPhone avrà un accesso limitato fino alla prossima esecuzione dell'installazione."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - Download dell'immagine non riuscito (rete, spazio su disco o timeout del registro)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="Impossibile scrivere il segnale FDA di iMessage in pipeline_signals.json. Il dashboard Doctor potrebbe non mostrare automaticamente la scheda Accesso completo al disco."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="L'host IMAP è vuoto: riprova."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="Permesso di Automazione per iMessage: non concesso (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="Permesso di Automazione per iMessage: verifica non conclusiva."
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="La cronologia di iMessage (chat.db) non è leggibile: l'accesso completo al disco non è ancora stato concesso al daemon di Ostler. La lettura della cronologia di iMessage resta disattivata finché non lo concedi in Impostazioni di Sistema > Privacy e sicurezza > Accesso completo al disco."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="Apertura di Impostazioni di Sistema > Privacy e sicurezza > Automazione. Seleziona la riga Messaggi per OstlerInstaller (o Terminale) per attivare l'invio tramite iMessage."
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="Non è un indirizzo email completo, quindi ignorato: %s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="Inserisci almeno un indirizzo email completo (ad esempio you@example.com)."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage richiede almeno un contatto consentito. Riprova oppure"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="Pipeline di importazione non disponibile (repository privato, solo per beta tester)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="Pipeline di importazione non inclusa nell'installer. Errore bloccante ignorato."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Pipeline di importazione non inclusa nell'installer. Questo è il percorso di installazione del prodotto: il pacchetto Python contact_syncer dovrebbe essere incluso nel bundle .app."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX significa che l'assistente leggerà ogni email che ricevi."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Spazio su disco insufficiente per il volume di output del wiki"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Rilevato un Mac Intel: le prestazioni saranno limitate. Si consiglia Apple Silicon."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s è un host di un provider cloud."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="JWT_SECRET in %s è nella lista di esclusione; viene rigenerato per mantenere importabili i servizi del grafo della conoscenza"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="JWT_SECRET in %s è troppo corto (%s < %s caratteri); viene rigenerato"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="Repository della conoscenza clonato ma pyproject.toml mancante; configurazione del venv saltata."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="Installazione del servizio di conoscenza non riuscita (clone)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="Licenza: %s è distribuito con i Termini di utilizzo di Gemma di Google, non con Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="Sui MacBook serve per la gestione di batteria e stop attività."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="Il permesso per Contatti di macOS è stato rifiutato o non ancora concesso."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS NON lo richiederà da uno script: devi concederlo manualmente."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Le installazioni su Mac mini non sono interessate; gli utenti MacBook dovrebbero riprovare."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="I dati di Mail possono comunque essere importati manualmente:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  Nuovo tentativo manuale: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  Nuovo tentativo manuale dopo aver risolto la causa:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Né Apple Mail né IMAP personalizzato selezionati: si usa Apple Mail per impostazione predefinita."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="Nessuna passkey impostata; i database non saranno cifrati."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="Un'installazione precedente ha generato la tua chiave di recupero ma non è stata completata, quindi non ti è mai stata mostrata. Non può essere recuperata: non viene mai memorizzata da nessuna parte, nemmeno qui."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="La tua passphrase funziona ancora e oggi nulla è bloccato. Ma al momento non c'è modo di rientrare se dovessi dimenticarla."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="Contatta l'assistenza per configurare di nuovo la sicurezza: ti verrà mostrata una nuova chiave di recupero da conservare."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="Le passphrase non corrispondono. Riprova."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="Configurazione della passphrase non riuscita. Output:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="Input vuoto. Passphrase saltata."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="La passphrase deve contenere almeno 12 caratteri. Riprova."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="Per cifrare i tuoi dati è necessaria una passphrase."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="Non è un numero internazionale. Usa un + iniziale, poi il prefisso del paese e il resto del numero, ad es. +447700900123. Riprova."
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama non risponde"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s non riuscito (tentativo %s/3). Nuovo tentativo tra %ss..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="Solo %s GB liberi. Consigliamo almeno 35 GB (immagini Docker + modello AI + dati)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="A batteria, il LaunchAgent di alimentazione dell'Hub (passaggio 3.14) potrebbe andare in pausa"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="oppure riesegui l'installer e scegli un'altra opzione di canale."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="oppure è in anticipo rispetto alla pipeline di rilascio della Fase B. Riesegui l'installer quando"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor ha segnalato %s errori."

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="Ostler ha terminato, ma durante l'installazione sono stati generati %s errori."
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  Tutti i dettagli sono in ~/.ostler/logs/install.log. Ostler si avvierà comunque; apri il Doctor per vedere cosa richiede attenzione."
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="Ostler ha terminato, ma %s passaggi dell'installazione non sono stati completati correttamente: %s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="Ostler ha terminato senza errori durante l'installazione."

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant è stato estratto, ma il controllo di --version non è riuscito."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Installazione del LaunchAgent dell'assistente Ostler non riuscita dopo 3 tentativi. Output diagnostico sopra e sotto."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Tentativo %s di installazione del LaunchAgent dell'assistente Ostler non riuscito; nuovo tentativo."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="Stderr completo del daemon in: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="Ultimo frammento di stderr:"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s è solo per Apple Silicon (rilevato: %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  Impossibile installare la dipendenza per l'archiviazione cifrata nel venv della memoria delle conversazioni; l'arricchimento delle conversazioni non verrà eseguito."
MSG_INFO_COACH_DB_READY="  Coaching database ready, encrypted: %s"
MSG_WARN_COACH_DB_NOT_CREATED="  Could not prepare the encrypted coaching database (it will be created on the first coaching note): %s"
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  Sorgente della dipendenza per l'archiviazione cifrata non trovata in SCRIPT_DIR; il motore della memoria delle conversazioni non può caricarsi e l'arricchimento delle conversazioni non verrà eseguito."
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - immagine ostler-wiki-compiler non ancora scaricabile (registry non collegato)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph non risponde"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph non ancora operativo in questa fase (controlla i log sopra)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="Le password non corrispondono (o erano vuote). Riprova."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="L'installazione principale richiede in genere da 45 minuti a qualche ora (download di Docker + Ollama + prima configurazione), di più con una connessione lenta o un Mac con anni di cronologia. Lunghi periodi di apparente inattività sono normali – sta scaricando e configurando in background, non è bloccata."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  pip install non riuscito; il motore della memoria delle conversazioni non sarà disponibile."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  pip install non riuscito; email-ingest userà il python di sistema (potrebbe fallire anche in esecuzione)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  pip install non riuscito; ostler-knowledge non sarà disponibile."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  pip install non riuscito; il motore di acquisizione delle email non è disponibile. Il LaunchAgent orario continuerà a generare file mbox, ma non potrà acquisirli nel grafo finché il problema non sarà risolto."
MSG_WARN_CM021_SOURCE_NOT_FOUND="Sorgente del motore di acquisizione delle email non trovata nel bundle dell'app; l'attività oraria in background salverà i file di posta senza acquisirli."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="Sorgente di ostler_fda non trovata nel bundle dell'app; il LaunchAgent email-ingest userà il python di sistema in esecuzione."
MSG_WARN_PIP_SAID="pip ha risposto:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="Collega l'alimentatore per l'installazione completa."
MSG_WARN_PORT_1_ALREADY_USE_PID="La porta %s è già in uso da %s (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - Porta 3000 già in uso da un altro servizio"
MSG_WARN_POWER_SOURCE="Fonte di alimentazione: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="Installazione di sqlcipher3 non riuscita."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="Installazione di sqlcipher3 non riuscita. I database non saranno cifrati."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="Python 3 non trovato. Installazione di Python 3.12..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s è troppo vecchio (serve 3.10+). Installo Python 3.12..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant non risponde"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         Leggi https://ai.google.dev/gemma/terms prima dell'uso commerciale."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="Leggi la versione pubblica su https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis non risponde"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="sarà disponibile la nuova versione, oppure installa il binario manualmente:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="Riesecuzione in corso – digita un host self-hosted, oppure premi Ctrl-C e riavvia scegliendo Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="riesegui l'installer deselezionando iMessage per saltarlo."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="ESECUZIONE CON --allow-plaintext: crittografia disattivata. NON PER LA PRODUZIONE."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  Esegui \`%s doctor\` dopo il primo avvio"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="Esegui 'tailscale ip --4' dopo aver effettuato l'accesso, poi aggiungi l'indirizzo all'app per iOS."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Copia dell'estensione di Safari non riuscita; puoi installarla manualmente più tardi"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="Estensione di Safari installata, ma non era disponibile alcun token per associarla; l'acquisizione della navigazione resterà disattivata finché non riesegui l'installer"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="Impossibile associare l'estensione di Safari a questo Hub; l'acquisizione della navigazione resterà disattivata finché non riesegui l'installer"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="Modulo di sicurezza non trovato. La configurazione della passkey verrà saltata."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  Cercato in: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  Di solito significa che l'installer .app è stato creato senza"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  il pacchetto ostler_security incluso in"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Scarica di nuovo l'installer oppure"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  riesegui con --allow-plaintext per un'installazione dev/CI."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="Configurazione della sicurezza non riuscita. Si continua senza crittografia del database."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="Configurazione della sicurezza non riuscita. Output:"
MSG_WARN_SEE_STDERR_FRAGMENT="  Vedi %s per il frammento di stderr."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="Installazione del binario saltata. Il config.toml scritto dalla procedura guidata resta invariato."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Installazione del LaunchAgent di Doctor saltata."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="Installazione del LaunchAgent di email-ingest saltata."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="Installazione del LaunchAgent saltata. Le installazioni su Mac mini non sono interessate."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="Installazione del LaunchAgent saltata. Prova: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="Installazione del LaunchAgent di wiki-recompile saltata."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="Alcune porte sono in uso. I container Docker potrebbero non avviarsi."
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="La porta %s è già in uso da %s (PID %s), che appartiene a questo account. Chiudilo ed esegui di nuovo l'installer."
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="La porta %s è già in uso da un programma di un ALTRO account utente su questo Mac. Ostler non può condividerla e avviarsi comunque potrebbe mescolare i dati dei due account. Esci dall'altro account oppure installa Ostler su un Mac in cui sia l'unico account a usare questa porta."
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="Ostler non può avviare i suoi database perché le porte necessarie sono già occupate."
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="Ferma ciò che usa le porte elencate sopra, poi esegui di nuovo l'installer."
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="Impossibile verificare se la porta %s è libera. Non significa che la porta sia libera."
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="Una o più verifiche delle porte non sono state eseguite, quindi non si può escludere un conflitto con un altro programma."
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="Impossibile eseguire il controllo delle porte più affidabile su questo Mac, quindi le verifiche seguenti sono meno accurate del solito."
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="Ostler non ha potuto confermare che quelle porte siano libere e non avvierà i suoi database su una porta non verificata. Contatta l'assistenza con il log di installazione."
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="Impossibile rimuovere una voce di avvio obsoleta di Colima. Il tuo wiki potrebbe non caricarsi dopo un riavvio; contatta l'assistenza."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="Ferma i servizi in conflitto oppure cambia le porte in docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscale non ha effettuato l'accesso entro 3 minuti. Puoi riprovare più tardi da Impostazioni."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="L'IP di Tailscale è stato scritto in .env, ma una lettura successiva non è riuscita a trovarlo. L'app Ostler sul tuo iPhone potrebbe non rilevarlo: in tal caso esegui di nuovo install.sh --repair."
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="Non è stato possibile salvare la tua risposta sull'accesso remoto, quindi alla prossima reinstallazione ti verrà chiesto di nuovo. Tutto il resto non cambia."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="Installazione di Tailscale non riuscita – puoi installarlo più tardi da tailscale.com"
MSG_WARN_TAILSCALE_STATE_UNREADABLE="Questo Mac ha impostazioni di Tailscale esistenti che non è stato possibile leggere, quindi non sappiamo se sia ancora connesso alla tua rete. Scegli qui sotto – se è già connesso, configurarlo di nuovo non causa alcun problema."
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="i servizi installati non si avviano senza di essi."
# NEEDS REVIEW: Fragment continues a previous line (likely '...until this is resolved'); original translation said the problem IS resolved. Check join with preceding string.
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  il problema non sarà risolto. Consulta il banner dei prossimi passi per la soluzione."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  da controllare. cron-delivery / imessage-tcc sono casi comuni"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  Prova: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  Prova: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="Scelta non riconosciuta '%s'; verrà usato iMessage + email."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="Scelta non riconosciuta. Verrà usata l'opzione consigliata."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  Aggiornamento non riuscito; si continua con il checkout esistente."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="Per quell'account usa Apple Mail (consigliato sopra): Ostler non memorizza mai le password del cloud."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="Verrà usata la INBOX. L'assistente leggerà ogni email in arrivo."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="Il container Vane è stato avviato, ma http://localhost:3000 non ha risposto entro 60 s."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Impossibile avviare Vane (ricerca web locale). Cause comuni:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  La ricerca web è facoltativa; il resto di Ostler funziona senza."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="Ti consigliamo vivamente di usare invece un'etichetta o una cartella dedicata."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp richiede un numero di telefono per la consegna del riepilogo. Riprova,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="Wiki compilata, ma il container wiki-site non si è avviato."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="Prima compilazione della wiki non riuscita. Cause comuni:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="Impossibile caricare il LaunchAgent di recupero della wiki del primo giorno. La ricostruzione giornaliera della wiki continua a funzionare; la wiki si aggiornerà semplicemente il giorno dopo invece che entro un'ora."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Installazione del LaunchAgent di ricompilazione della wiki non riuscita. Vedi l'output sopra."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="La wiki non si aggiornerà automaticamente; la ricostruzione manuale resta disponibile:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="La configurazione della procedura guidata resta al suo posto; il binario resta pronto. Nuovo tentativo manuale:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="Il tuo assistente ha bisogno di un nome. Scegli tra i suggerimenti sopra o scrivine uno tuo."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="Puoi concedere di nuovo l'accesso in Impostazioni di Sistema > Privacy e sicurezza > Contatti."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="Puoi eseguire la configurazione della sicurezza più tardi: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="Potrebbe essere necessario installarlo manualmente: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  effettivo: %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="Il bundle di Ostler RemoteCapture non era presente in %s dopo l'estrazione. L'archivio della release potrebbe essere danneggiato."
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="Impossibile creare o raggiungere %s, quindi Ostler RemoteCapture non ha dove essere installato. Si tratta di un problema di permessi della cartella, non del download."
MSG_ERR_CM042_RENAME_FAILED="Ostler RemoteCapture è stato scaricato e decompresso correttamente, ma non è stato possibile spostarlo in %s. L'app decompressa è rimasta in /Applications. Non è un problema di firma."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify ha riportato:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  Preparazione annullata: il bundle non corrisponde al checksum pubblicato."
MSG_ERR_CM042_SHA_256_MISMATCH="SHA-256 dell'archivio di Ostler RemoteCapture non corrispondente."
MSG_ERR_CM042_PIN_FAILED="Ostler non ha potuto confermare l'autenticità di questo download di RemoteCapture, quindi non è stato installato."
MSG_ERR_CM042_VERSION_UNKNOWN="Questa versione di RemoteCapture non è riconosciuta da Ostler, quindi non è stata installata."
MSG_ERR_CM042_SIDECAR_DISAGREES="Il checksum pubblicato con questo download di RemoteCapture non corrisponde al file, quindi non è stato installato."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess ha riportato:"
MSG_ERR_CM042_VERIFY_FAILED="Verifica della firma e della notarizzazione di Ostler RemoteCapture non riuscita."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv ha riportato:"
MSG_ERR_EXPECTED="  previsto: %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief ha riportato: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="Il binario ostler-assistant in %s non è un eseguibile Mach-O."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="Il checksum SHA-256 del tarball di ostler-assistant non corrisponde."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  Mi rifiuto di preparare un binario che non corrisponde al checksum pubblicato."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="Mi rifiuto di rimuovere la quarantena o di caricare il LaunchAgent."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="Riesegui l'installer dopo che il tarball upstream sarà stato corretto."
MSG_ERR_URL="  url:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="I Mac Intel non sono supportati. Ostler richiede Apple Silicon (M1, M2, M3 o M4)."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="Sono necessari almeno 16 GB di RAM. Ne hai %s GB. Se ne consigliano 24 GB."
MSG_FAIL_CM042_SIGNATURE_FAILED="Installazione di Ostler RemoteCapture interrotta: verifica della firma o della notarizzazione non riuscita. Il bundle è stato lasciato in /Applications per l'assistenza. Scrivi a support@ostler.ai e riesegui l'installer."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="Impossibile scaricare %s dopo 3 tentativi. Controlla la rete e riesegui l'installer."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="Impossibile scaricare nomic-embed-text dopo 3 tentativi. Controlla la rete e riesegui l'installer."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker non è disponibile. Riesegui l'installer per installare Colima."
MSG_FAIL_CONTAINER_CLIENT_MISSING="Il comando docker non è presente su questo Mac, quindi Ostler non può avviare i servizi di cui ha bisogno. Riesegui l'installer; se fallisce di nuovo, inviaci il log in %s."
MSG_FAIL_CONTAINER_ENGINE_ABSENT="Ostler ha bisogno di un runtime per container e su questo Mac nessuno risponde. Il tuo wiki, il tuo grafo della conoscenza e il tuo indice di ricerca funzionano tutti all'interno di container, quindi l'installazione si è fermata qui invece di terminare lasciandoli mancanti. Per risolvere: apri Terminale ed esegui 'colima start', poi riesegui questo installer. Se usi Docker Desktop, aprilo, attendi che l'icona della balena si stabilizzi, poi riesegui. Il log completo è in %s."
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="Docker non è diventato pronto in tempo per avviare i database del grafo della conoscenza. Assicurati che Colima o Docker sia in esecuzione, poi riesegui l'installer."
MSG_FAIL_GRAPH_DB_PULL_FAILED="Impossibile scaricare le immagini dei database del grafo della conoscenza dopo vari tentativi. Di solito è un problema di rete. Controlla la connessione a internet e riesegui l'installer."
MSG_FAIL_GRAPH_DB_UP_FAILED="I database del grafo della conoscenza sono stati scaricati ma non è stato possibile avviarli. Riesegui l'installer; se il problema persiste, apri Terminale ed esegui: cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="Ostler non è riuscito a completare una richiesta autenticata al database del grafo della conoscenza. Ha provato due volte, a due secondi di distanza, e entrambi i tentativi sono stati rifiutati. Non ne conosciamo ancora il motivo: il database potrebbe essere ancora in fase di avvio, oppure la credenziale in possesso di Ostler potrebbe non essere quella attesa. I tuoi dati non sono stati toccati. Rieseguire l'installer spesso funziona, e se succede vorremmo comunque saperlo – inviaci il log di installazione, perché è un errore che stiamo cercando attivamente di riprodurre."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="Il modulo di estrazione FDA manca dal bundle dell'installer. Scarica di nuovo l'.app da ostler.ai/install, oppure riesegui con --allow-plaintext per dev/CI."
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="Il modulo di estrazione dei dati è stato installato ma non può essere caricato, quindi l'aggiornamento in background fallirebbe a ogni esecuzione. L'output completo è salvato in %s – riesegui l'installer e allega quel file se contatti l'assistenza (Riferimento: ERR-10-FDA-DEPS-IMPORT)."
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="Errore interno: il modulo di estrazione dei dati è stato posizionato all'interno del bundle dell'applicazione, cosa che ne comprometterebbe la firma. È un difetto di build, non un problema del tuo Mac. Scarica di nuovo l'.app da ostler.ai/install (Riferimento: ERR-10-FDA-DEPS-UNSAFE-PATH)."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Installazione delle dipendenze di Doctor non riuscita. L'output completo è salvato in %s – allegalo quando scrivi a support@ostler.ai (Riferimento: ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="Installazione delle dipendenze della pipeline di importazione non riuscita. L'output completo è salvato in %s – allegalo quando scrivi a support@ostler.ai (Riferimento: ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Installazione di Homebrew non riuscita. L'output completo è salvato in %s – allegalo quando scrivi a support@ostler.ai."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="Installazione della pipeline di importazione non riuscita. Il bundle contact_syncer è necessario per l'installazione del prodotto. Riesegui con --allow-plaintext per dev/CI, oppure scarica di nuovo l'installer e riprova."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="Serve l'accesso sudo per disattivare la sospensione e installare Homebrew. Riesegui quando sei pronto."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Né Colima né Docker Desktop sono riusciti ad avviarsi. Installa Docker Desktop e riesegui."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="Spazio su disco insufficiente (%s GB). Libera dello spazio e riprova."
MSG_FAIL_MACOS_BELOW_FLOOR="macOS %s è precedente alla versione supportata da Ostler. Ostler richiede macOS %s o successivo: l'app di installazione è creata per quella versione e non si aprirà su versioni precedenti. Aggiorna macOS, poi esegui di nuovo l'installer."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="Nessuna passkey impostata e nessuna configurazione di sicurezza esistente. Riesegui con --allow-plaintext per dev/CI, oppure riesegui l'installer e conferma l'informativa su Touch ID."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="Il motore della memoria delle conversazioni è necessario. Riesegui con --allow-plaintext per dev/CI, oppure correggi il bundle mancante indicato sopra e riprova."
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="Il daemon Ostler incluso (v%s in %s) non supporta il comando 'run-source' di cui questo installer ha bisogno per instradare l'acquisizione tramite Accesso completo al disco. Si tratta di un'incompatibilità di versione all'interno del bundle dell'installer: installarlo lascerebbe tutte le fonti di acquisizione non funzionanti in silenzio e il prodotto resterebbe obsoleto senza alcun errore visibile. Scarica di nuovo l'.app da ostler.ai/install e riprova (Riferimento: ERR-11-DAEMON-RUN-SOURCE-SKEW)."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="Installazione di ostler_security non riuscita. Riesegui con --allow-plaintext per dev/CI, oppure correggi l'errore di pip indicato sopra e riprova."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="Configurazione della passkey non riuscita. Riesegui con --allow-plaintext per dev/CI, oppure correggi l'errore indicato sopra e riprova."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="sqlcipher3 è necessario per i database cifrati. Riesegui con --allow-plaintext per dev/CI, oppure correggi l'errore di pip indicato sopra e riprova."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Questo installer è solo per macOS."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="L'installazione degli Xcode Command Line Tools non è stata completata entro 15 minuti. Apri Terminale ed esegui 'xcode-select --install', fai clic su Installa nella finestra di macOS e attendi il termine, poi riesegui questo installer."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="L'installazione di Homebrew ha riportato successo, ma /opt/homebrew/bin/brew non esiste. Controlla %s per la trascrizione completa. Ripristino: apri Terminale ed esegui '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"', poi riesegui l'installer."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew è installato in /opt/homebrew/bin/brew, ma il comando 'brew' non è nel PATH dopo la valutazione di shellenv. Apri un nuovo Terminale e riesegui l'installer."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' ha riportato successo, ma colima non è nel PATH. Controlla %s per eventuali errori di Homebrew. Ripristino: apri Terminale ed esegui manualmente 'brew install colima docker docker-compose', poi riesegui l'installer."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' ha riportato successo, ma la CLI di docker non è nel PATH. Controlla %s. Ripristino: esegui manualmente 'brew install docker', poi riesegui l'installer."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="The Ollama install reported success but its binary is missing. Check %s, then re-run the installer."
MSG_FAIL_OLLAMA_PIN_DOWNLOAD="Could not download Ollama %s. Check your internet connection, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_PIN_SHA256="The Ollama %s download did not match its recorded fingerprint, so it was not installed. This can mean the download was damaged or altered. Re-run the installer; if it happens again, contact support. Details: %s"
MSG_FAIL_OLLAMA_PIN_UNPACK="Ollama %s downloaded but could not be unpacked. Check free disk space, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_AGENT_NOT_PINNED="The local AI service is set to run %s instead of the copy of Ollama this installer verified (%s), so it would not stay on a tested version. The install has stopped. Re-run the installer; if this repeats, contact support. Details: %s"
MSG_FAIL_EMBED_HEALTHCHECK="Ollama è in esecuzione, ma il modello di embedding non ha restituito alcun vettore (HTTP diverso da 200, oppure risultato vuoto). La scheda Persone, la ricerca e la navigazione sarebbero vuote. Controlla %s. Ripristino: assicurati che l'app Ollama (non la formula di Homebrew) sia installata e in esecuzione, poi riesegui l'installer."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' ha riportato successo, ma sqlcipher non è nel PATH. Controlla %s. Ripristino: esegui manualmente 'brew install sqlcipher', poi riesegui l'installer."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' non ha creato /Applications/Tailscale.app. Controlla %s. Ripristino: scarica Tailscale da https://tailscale.com/download/macos e trascinalo in /Applications, poi riesegui l'installer."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' ha riportato successo, ma l'eseguibile python3.11 non esiste in /opt/homebrew/opt/python@3.11/bin/python3.11. Controlla %s. Ripristino: esegui 'brew reinstall python@3.11', poi riesegui l'installer."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="Abbiamo trovato le tue risposte precedenti"
MSG_PROMPT_REUSE_SETTINGS_HELP="Abbiamo rilevato un precedente tentativo di installazione su questo Mac. Le domande a cui hai già risposto (nome, nome dell'assistente, fuso orario, prefisso internazionale, canali e così via) verranno riutilizzate, così non dovrai inserirle di nuovo. Scegli Sì per riprendere da dove avevi interrotto, oppure No per rivedere tutte le domande dall'inizio."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Risposte precedenti trovate: nome = %s, assistente = %s, fuso orario = %s."

MSG_PROMPT_PERMS_OK_TITLE="Vuoi continuare?"
MSG_PROMPT_PERMS_OK_HELP="macOS chiederà l'accesso a Contatti e a File e cartelle. L'Accesso completo al disco, facoltativo, potrà essere concesso in seguito."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Nome completo (come appare nei tuoi contatti)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Nome completo (es. Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="Come deve chiamarti il tuo assistente?"
MSG_PROMPT_USER_ID_HELP="Un nome breve che il tuo assistente userà per rivolgersi a te (es. 'Andy', 'Andrew', 'signora Smith'). È quello che compare nei tuoi riepiloghi del mattino e nelle risposte in chat. Diverso dal tuo nome completo qui sopra."

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
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="Ecco i tuoi calendari. Ti sembrano corretti?"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="Abbiamo ipotizzato a chi appartiene ciascuno, così il tuo riepilogo non confonde mai i viaggi di una persona con quelli di un'altra."
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="Messi da parte automaticamente, non usati per il tuo riepilogo:"
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="tuo"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="%s evento"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="%s eventi"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="festività pubbliche"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="compleanni"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="suggerimenti di Siri"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="un calendario a cui sei iscritto"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="promemoria"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="Usare \"%s\" per il tuo riepilogo?"
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="Lo abbiamo messo da parte perché sembra essere %s. Rispondi sì se è davvero l'agenda di qualcuno."
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="Di chi è il calendario \"%s\"?"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="Che tipo di calendario è \"%s\"?"
MSG_CONFIRM_CALENDAR_TYPE_HELP="Una tra: personale, lavoro, famiglia, condiviso, altro. Determina con quale riservatezza vengono trattati i suoi eventi."
MSG_CONFIRM_CALENDARS_SAVED="Proprietari dei calendari salvati"
MSG_CONFIRM_CALENDARS_FAILED="Impossibile salvare i proprietari dei calendari (non grave; puoi impostarli in seguito)"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="Pensiamo che questi profili siano tutti tuoi (%s). Unirli in uno solo?"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="Questi profili hanno in comune con te un segnale di identità certo (un dominio email, un profilo LinkedIn o un datore di lavoro). Unirli evita che il tuo assistente consideri la tua stessa cronologia come più persone diverse. Potrai annullare in seguito."
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="Qualcuno ha il tuo stesso nome ma sembra una persona diversa (%s). Sei tu o è un'altra persona?"
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="Scegli «diversa» per tenerla come persona separata (il tuo assistente non la unirà mai a te). Scegli «io» solo se sei davvero tu."
MSG_CONFIRM_IDENTITY_SAVED="Scelta salvata: chi sei tu"
MSG_CONFIRM_IDENTITY_FAILED="Impossibile salvare le scelte di identità (non grave; puoi confermarle più tardi)"

# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="Installazione in background (da circa 45 minuti a qualche ora)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="Usare +%s?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Inserisci il prefisso internazionale (es. 44 per il Regno Unito, 1 per gli Stati Uniti)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Prefisso internazionale predefinito"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Serve a normalizzare i numeri di telefono durante l'importazione dei contatti e a impostare la tua regione (Regno Unito / UE / Stati Uniti / altro) per i valori predefiniti di conformità legale."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="Abbiamo rilevato +%s. Vuoi usarlo per il tuo Hub?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Rilevato dal tuo numero di telefono qui sopra. Scegli Sì per usarlo, oppure No per inserire un prefisso diverso."

MSG_PROMPT_TZ_CONFIRM_TITLE="Usare questo fuso orario?"
MSG_PROMPT_TZ_CONFIRM_HELP="Fuso orario rilevato: %s"
MSG_PROMPT_USER_TZ_TITLE="Inserisci il fuso orario (es. Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="Come vuoi chiamare il tuo assistente?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="Il nome nel campo è un suggerimento casuale: sovrascrivilo con quello che preferisci. Marvin, Samantha, Joshua, Friday, Athena, Sage e Rosie sono tutte scelte molto popolari." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Scrivi il nome che preferisci: il suggerimento è solo un punto di partenza."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="Come ti contatterà il tuo assistente?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Scegli i canali di messaggistica che vuoi far usare al tuo assistente. Puoi cambiare questa scelta più tardi nella sezione Doctor dell'app."

MSG_PROMPT_WHATSAPP_CONSENT_TITLE="Enable WhatsApp messaging for your assistant?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web is a third-party service. By enabling, you accept that your messages route through WhatsApp's own infrastructure before reaching your local Ostler instance, and that WhatsApp (Meta Platforms Ireland Ltd) may suspend, restrict, or terminate your WhatsApp account because of automated use. You can disable this later from Settings."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="Il tuo numero di telefono WhatsApp"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Numero internazionale con prefisso, es. +447700900123. Solo cifre e un + iniziale: niente spazi, parentesi o trattini."
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="Salvato come %s. WhatsApp richiede il numero senza spazi né parentesi."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Attiva Accesso completo al disco per l'assistente Ostler"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="Impostazioni di Sistema è aperto su Accesso completo al disco."
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
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Trova \"%s\" nell'elenco e attiva il relativo interruttore di Accesso completo al disco."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="Non è nell'elenco? Trascina \"%s\" dalla finestra del Finder nell'elenco, poi attiva il relativo interruttore. L'ordine non conta: fai clic su Fine prima o dopo; l'installer attende finché l'interruttore non è davvero attivo."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="Non è nell'elenco? Ostler non è riuscito ad aprire una finestra del Finder. Nel Finder premi ⌘⇧G, inserisci il percorso qui sotto, poi trascina \"%s\" nell'elenco e attiva il relativo interruttore. L'ordine non conta: fai clic su Fine prima o dopo; l'installer attende finché l'interruttore non è davvero attivo."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="L'app si trova in: %s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="L'app si trova in: %s – questo percorso è negli appunti, quindi nel Finder premi ⌘⇧G, poi ⌘V, poi Invio."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Fine"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="Puoi fare clic su Fine prima o dopo aver attivato l'interruttore: l'installer attende finché non è davvero attivo."

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Consenti a Ostler di leggere i dati del tuo Mac"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="Impostazioni di Sistema è aperto su Accesso completo al disco."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Trova \"OstlerInstaller\" nell'elenco e attivalo."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Fai clic su Fine al termine e Ostler leggerà la cronologia di Safari, Note, iMessage e Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Fine"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="Poi: Accesso completo al disco per l'installer"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="Ora macOS ti chiederà di concedere l'Accesso completo al disco a OstlerInstaller."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Dopo aver attivato l'interruttore, macOS mostrerà una finestra che ti chiede di scegliere \"Esci e riapri\" oppure \"Più tardi\"."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Fai clic su \"Esci e riapri\". L'installer si riavvierà da solo e riprenderà automaticamente da questo passaggio."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="OK"
MSG_INFO_INSTALLER_FDA_PREWARN="Ti spiego come concedere l'Accesso completo al disco..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="Apro Impostazioni di Sistema così puoi concedere l'Accesso completo al disco all'installer..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="Accesso completo al disco concesso all'installer. Ora leggo Safari, Note, iMessage e Mail."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="L'Accesso completo al disco non è ancora stato concesso. Continuo senza: puoi eseguire di nuovo l'installer più tardi per estrarre Safari / Note / iMessage."
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="L'Accesso completo al disco per l'installer è a posto. Ora inizia la parte lunga, che in gran parte procede da sola, ma tieni d'occhio una finestra di macOS che chiede di installare gli strumenti per sviluppatori e torna per un paio di minuti di configurazione verso la fine."
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="Un ultimo permesso (la cronologia di Messaggi per il tuo assistente) arriva verso la fine, quando il tuo assistente sarà installato: ti indicheremo noi come fare."
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="Serve ancora l'Accesso completo al disco"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostler sta per leggere i dati del tuo Mac, ma l'Accesso completo al disco per OstlerInstaller è ancora disattivato. Trova \"OstlerInstaller\" nell'elenco e attivalo."
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="Oppure fai clic su Continua per terminare l'installazione con meno dati: potrai concedere l'accesso e rieseguire l'estrazione più tardi."
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="Continua"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="Contatti consentiti"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="Persone fidate: numeri di telefono e email dell'ID Apple (separati da virgola). %s risponde solo alle persone in questo elenco; i messaggi di chiunque altro vengono ignorati. È richiesta almeno una voce.

Per esempio:
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="Leggere la posta tramite Apple Mail?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Legge qualsiasi account email che hai aggiunto ad Apple Mail (iCloud, Gmail, Outlook e altri) usando l'Accesso completo al disco. Nessuna password viene memorizzata. Consigliato a quasi tutti."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="Aggiungere un account di posta ad Apple Mail?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="Apple Mail non ha ancora account collegati su questo Mac, quindi Ostler non avrà email da leggere. Scegli Sì per aprire ora Impostazioni di Sistema > Account Internet (lì puoi aggiungere iCloud, Gmail o Outlook). Scegli No per saltare: potrai aggiungere un account più tardi e Doctor ti mostrerà un avviso se non arriva posta entro 24 ore."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="Importare tutta la cronologia di Apple Mail?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Per impostazione predefinita Ostler legge gli ultimi cinque anni di posta in Apple Mail. Se su questo Mac ne conservi di più e vuoi tutto nel tuo grafo della conoscenza, scegli Sì per importare ora l'intera cronologia locale (con una casella di posta molto grande può volerci un po' di più). Scegli No per mantenere i cinque anni: potrai sempre estenderli più tardi da Doctor."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="Configurare anche un server IMAP+SMTP personalizzato?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="Solo per caselle di posta self-hosted. Lascia su NO se i tuoi account sono con Gmail, iCloud o Outlook: funzionano meglio tramite Apple Mail, sopra."

MSG_PROMPT_IMAP_HOST_TITLE="Host IMAP"
MSG_PROMPT_IMAP_HOST_HELP="Solo per server IMAP self-hosted o personalizzati. Usa Apple Mail (sopra) per Gmail / iCloud / Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="Porta IMAP"

MSG_PROMPT_SMTP_HOST_TITLE="Host SMTP"
MSG_PROMPT_SMTP_PORT_TITLE="Porta SMTP"

MSG_PROMPT_EMAIL_USERNAME_TITLE="Indirizzo email (usato anche come nome utente IMAP/SMTP)"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="Chi può scrivere via email al tuo assistente?"
MSG_PROMPT_EMAIL_ALLOWED_HELP="I tuoi indirizzi email, separati da virgola. %s risponde solo alle email provenienti dagli indirizzi in questo elenco; la posta di chiunque altro viene ignorata. È richiesto almeno un indirizzo. Il tuo indirizzo è già inserito: modificalo o aggiungine un altro."

MSG_PROMPT_EMAIL_PASSWORD_TITLE="Password (nascosta)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Password for your self-hosted IMAP/SMTP server. Stored locally in ~/.ostler/secrets/, not in your settings file, and never sent to Creative Machines. It is saved in plain text: the only thing protecting it is the file's permissions, which allow your macOS account and nobody else. Nothing encrypts it later. Use an app password rather than your main account password."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Conferma password"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="Quale cartella deve controllare l'assistente?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="Consigliato: un'etichetta o una cartella dedicata (ad es. Ostler). Leggeremo solo i messaggi lì contenuti, senza toccare la tua posta in arrivo principale."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="Digita di nuovo INBOX per confermare, oppure premi Continua per usare \"Ostler\""
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX significa che l'assistente leggerà ogni email che ricevi. Consigliamo vivamente di usare invece un'etichetta o una cartella dedicata."

MSG_PROMPT_EXPORTS_ACK_TITLE="Hai richiesto l'esportazione dei tuoi dati?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler importa da circa 20 piattaforme. L'elenco completo, con i link diretti alla pagina di richiesta di ogni servizio, è su docs.ostler.ai/data-exports.

La maggior parte degli archivi arriva via email in 1-3 giorni. Quando arrivano i file ZIP, mettili nella cartella Download e Ostler li troverà automaticamente.

Salta quelli che non usi: potrai sempre importarne altri più tardi."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="Continuare con il disco NON cifrato a riposo?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="FileVault è DISATTIVATO su questo Mac, quindi il disco non è cifrato a riposo.

Cosa significa se continui: tutto ciò che Ostler memorizza, cioè l'intero grafo personale (wiki, conversazioni, note di conoscenza) in ~/Documents/Ostler, più i segreti dei servizi e i database in ~/.ostler, viene scritto su disco NON cifrato. Chiunque possa avviare il Mac da questa unità, rimuoverla o accedere a una sessione sbloccata può leggere tutto. Ostler cifra comunque i suoi database più sensibili con una passphrase, ma il resto dei tuoi dati è protetto solo quanto il disco stesso.

FileVault è vivamente consigliato. Puoi attivarlo in qualsiasi momento in Impostazioni di Sistema > Privacy e sicurezza > FileVault: cifra in background senza bisogno di reinstallare.

Scegli Sì per continuare ora con il disco non cifrato a riposo (è una scelta deliberata e consapevole, e verrà registrata).
Scegli No per fermarti qui, attivare prima FileVault e poi eseguire di nuovo l'installer. In entrambi i casi non è andato storto nulla."

MSG_PROMPT_PASSKEY_ACK_TITLE="Pronto a configurare la cifratura del disco"
MSG_PROMPT_PASSKEY_ACK_HELP="I database sensibili di Ostler sono cifrati con SQLCipher tramite una passphrase che sceglierai nella schermata successiva. Dovrai digitare questa passphrase ogni volta che avvii l'interfaccia dell'Hub. Viene inoltre generata una chiave di recupero separata, mostrata una sola volta al termine dell'installazione. Per una protezione completa a riposo di tutto ciò che è sul tuo Mac, lascia attivo FileVault di macOS. Premi Continua quando sei pronto."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="Impostare anche una passphrase di recupero? (consigliato)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="Scegli la tua passphrase"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="Questa passphrase cifra il tuo grafo di conoscenza e sblocca l'interfaccia dell'Hub a ogni avvio. Almeno 12 caratteri. Non possiamo recuperarla per te. Si consiglia di conservarla in un gestore di password."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="Conferma la tua passphrase"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="Inserisci di nuovo la stessa passphrase per confermare."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="Importare questi dati durante l'installazione?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="Le esportazioni GDPR trovate verranno importate nel tuo grafo di conoscenza durante l'installazione."

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="Password dell'esportazione di Disney+"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="Disney+ fornisce l'esportazione GDPR come foglio di calcolo protetto da password: è normale e non indica un problema con il download. Inserisci la password per importare ora la cronologia di visione di Disney+, oppure lascia vuoto per saltare; tutto il resto verrà comunque importato."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="Hai già pronte delle esportazioni di dati?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler può importare gli archivi dei social media e delle piattaforme – tutta la tua storia con amici, familiari, luoghi, opinioni – fin dall'inizio. Più Ostler sa fin dal primo giorno, più è utile fin dal primo giorno. Puoi anche aggiungerli più tardi, senza fretta.

Richiedi l'esportazione dei tuoi dati a ciascuna piattaforma (Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp, ecc.), scarica i file ZIP e mettili nella cartella Download.

Per impostazione predefinita Ostler cercherà in ~/Downloads. Vuoi un'altra cartella? Sceglila qui sotto. Altrimenti salta e importa più tardi."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="Importare i messaggi Gmail da questo Takeout?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Legge il contenuto di Gmail direttamente dal file Takeout. Google non vede mai Ostler."

MSG_PROMPT_FDA_PRESET_TITLE="Da quali fonti del Mac deve imparare Ostler?"
MSG_PROMPT_FDA_PRESET_HELP="Tre preset, oppure scegli tu ogni fonte. Le fonti sensibili (riconoscimento facciale) sono disattivate per impostazione predefinita in ogni preset: scegli con consapevolezza se le vuoi."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="Consigliato. Include Apple Mail, Contatti, Calendario, Note, Messaggi, Promemoria, cronologia di Safari, segnalibri di Safari ed eventi di Foto (date e luoghi, senza riconoscimento facciale). La cronologia di WhatsApp Desktop e quella di Chrome vengono aggiunte automaticamente se l'app è installata. Esclude i dati di riconoscimento facciale di Foto e qualsiasi archivio di esportazione di terze parti."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="Tutto. Ogni fonte che Ostler può leggere su questo Mac. Il riconoscimento facciale di Foto resta disattivato finché non lo selezioni deliberatamente."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="Personalizza. Scegli ogni fonte nella schermata successiva. Le fonti sensibili restano disattivate finché non le selezioni."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="Attiva o disattiva questa fonte di dati."

MSG_PROMPT_CONSENT_ARTICLE_9_TITLE="Your decision (Y / N)"
MSG_PROMPT_CONSENT_ARTICLE_9_HELP="Article 9 special-category consent (UK GDPR). Required for the lawful basis of processing."

MSG_PROMPT_CONSENT_VOICE_EU_TITLE="Recognise voices on the calls you capture?"
MSG_PROMPT_CONSENT_VOICE_EU_HELP="Speaker recognition stays on this Mac. Creative Machines never receives the fingerprints."

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
MSG_PROMPT_CONSENT_ENRICHMENT_TITLE="Look up public facts about things you save?"
MSG_PROMPT_CONSENT_ENRICHMENT_HELP="Ostler can add public reference detail to things it finds – a book, a film, an album, a place. To do that it sends the NAME of that one thing to public reference services such as Wikidata, MusicBrainz and OpenLibrary and stores the answer on this Mac.

What leaves your Mac: the name of the thing being looked up. Nothing else. Not your messages, not your contacts, not your files, and not who mentioned it.

What the service on the other end can see: your IP address, and that the request came from Ostler. The lookup goes straight from your Mac to them - nothing passes through our servers - so there is no way to ask without them knowing someone asked.

If you say No: no lookups are made, and the background enrichment job is not installed at all. Everything else works exactly the same. Your library simply carries what you gave it rather than what a public catalogue adds.

You can say No now and change your mind later by re-running the installer."

MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE="One last thing: how third-party data works"
MSG_PROMPT_CONSENT_THIRD_PARTY_HELP="Any data you import from third parties (Google Takeout, Meta downloads, LinkedIn exports, etc.) stays on this Mac. Ostler stores it in your local knowledge graph; nothing leaves your device.

By continuing you understand and agree that you are solely responsible for the processing and keeping of this data on your machine, just like the email messages already on your hard drive.

Legal note: For records you import to this Mac, you are the data controller and processor under UK and EU law (UK GDPR Article 4(7) and 4(8)). Creative Machines never receives this data and is not the controller. Your processing for personal and household purposes falls within UK/EU GDPR Article 2(2)(c).

Read more at docs.ostler.ai/privacy/third-party-data."

# Spoken-capture recording-consent acknowledgement (every region). Shown
# in the Phase-2 consent batch. The HELP string is the substantive text
# GUI installer users read on the decision sheet, so it is self-contained.
# ── Personal-use-only terms (vendor/legal/consent_strings.py PERSONAL_USE_ONLY) ──
# A LICENCE TERM, not an optional consent, which is why it acknowledges rather
# than offering a decline that leaves a half-licensed install. Wording verbatim
# from the versioned ConsentString so the Doctor can flag drift.
MSG_TERMS_PERSONAL_USE_HEADING="What Ostler is for"
MSG_TERMS_PERSONAL_USE_INTRO="Ostler is built for one person, on their own Mac, to understand their own life. That is the whole design, and it is why your data never leaves this machine."
MSG_TERMS_PERSONAL_USE_BUSINESS="It is not built for business use. Please do not deploy Ostler to staff, or use it in the course of your job to capture colleagues, clients, patients or customers. If an organisation does that, the organisation becomes responsible for everyone whose information it collects, and Ostler is not designed to carry that."
MSG_TERMS_PERSONAL_USE_RECORDER="You are the one recording. Ostler is the tool. Where your local law requires consent before a conversation is recorded, obtaining it is yours to do, and we cannot know from here whether any particular recording is lawful where you are."
MSG_TERMS_PERSONAL_USE_ASK_HEADING="Three things we ask you not to do:"
MSG_TERMS_PERSONAL_USE_ASK_1="Do not record children without a parent or guardian agreeing. A child cannot give that agreement themselves, and your own assurance does not stand in for theirs."
MSG_TERMS_PERSONAL_USE_ASK_2="Do not record in places where people expect real privacy: a doctor's appointment, a solicitor's meeting, a therapy session, a religious confession, a bathroom or changing room."
MSG_TERMS_PERSONAL_USE_ASK_3="Do not use Ostler to record anyone covertly where the law where you are does not allow it."
MSG_TERMS_PERSONAL_USE_LEGAL="Ostler is licensed for personal, non-commercial use by a natural person. Creative Machines is not a data controller or processor of the information you keep on your Mac, receives none of it, and gives no warranty that any particular recording or capture is lawful in your jurisdiction."
MSG_PROMPT_TERMS_PERSONAL_USE_TITLE="Ostler is for personal use"
MSG_PROMPT_TERMS_PERSONAL_USE_HELP="Ostler is licensed for your own personal use on your own Mac. Please do not deploy it to staff or use it at work to capture colleagues, clients or patients. Do not record children without a parent agreeing, and do not record in places where people expect real privacy such as a doctor, solicitor or therapy appointment. Press Continue to accept these terms."
MSG_INFO_TERMS_PERSONAL_USE_DECLINED="No problem. Nothing has been installed."

MSG_CONSENT_SPOKEN_CAPTURE_HEADING="Turning spoken conversations into text"
MSG_CONSENT_SPOKEN_CAPTURE_INTRO="In short: when you capture spoken audio to transcribe it, getting any consent the law requires is your responsibility, not ours. Typing and messaging are not affected."
MSG_CONSENT_SPOKEN_CAPTURE_LAW="Ostler can turn spoken conversations you capture – calls and meetings – into searchable text; this is only about audio you choose to transcribe. Rules on recording people speaking vary by country – in some places (Germany and France, for example) everyone taking part must agree first."
MSG_CONSENT_SPOKEN_CAPTURE_LOCAL="Ostler transcribes captured audio on the device that captured it and deletes the audio straight away. It is never kept and never sent anywhere, including to your own Mac. That does not remove this duty: you still need consent where your local law requires it."
MSG_CONSENT_SPOKEN_CAPTURE_ASK_HEADING="What we ask of you:"
MSG_CONSENT_SPOKEN_CAPTURE_ASK_1="Obtain whatever consent your local law requires before you capture a spoken conversation."
MSG_CONSENT_SPOKEN_CAPTURE_ASK_2="Make it clear to the people you are with that audio is being captured – for example, say so at the start, or keep a visible indicator on."
MSG_CONSENT_SPOKEN_CAPTURE_ASK_3="If in doubt, leave spoken transcription off. Your text conversations work either way."
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_LABEL="Your decision:"
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_Y="[Y] I understand, and I will obtain any consent my local law requires."
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_N="[N] Not now – keep spoken transcription off. (You can turn it on later in Settings.)"
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL="Legal note: Recording the spoken word can be regulated by national law – for example section 201 of the German Criminal Code (Verletzung der Vertraulichkeit des Wortes) or Article 226-1 of the French Penal Code – independently of data-protection law. As the person making the recording on this Mac, you are responsible for compliance. Creative Machines never receives your recordings and is not a party to them."

MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_TITLE="Turn spoken conversations into text?"
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_HELP="In short: when you capture spoken audio to transcribe it, getting any consent the law requires is your responsibility. Typing and messaging are not affected.

Ostler can turn spoken conversations you capture – calls and meetings – into searchable text. This is only about audio you choose to transcribe.

What we ask of you:
• Get whatever consent your local law requires before you capture audio.
• Make it clear audio is being captured – say so, or keep a visible indicator on.
• If in doubt, leave this off. Your text conversations work either way, and you can turn it on later in Settings.

Legal note: recording the spoken word can be regulated by national law independently of data-protection law – for example section 201 of the German Criminal Code or Article 226-1 of the French Penal Code. As the person making the recording, you are responsible for compliance. Creative Machines never receives your recordings."
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="La trascrizione del parlato resterà disattivata. Potrai attivarla più tardi in Impostazioni."

MSG_PROMPT_CONSENT_INSTALL_TITLE="Ready to install?"
MSG_PROMPT_CONSENT_INSTALL_HELP="Please type INSTALL to confirm you accept the terms."
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Type INSTALL"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Install Ostler"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Cancel"
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Type INSTALL exactly (case does not matter) to confirm, or click Cancel to go back."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="Collega il tuo iPhone e Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale dà a questo Mac un indirizzo privato stabile che il tuo iPhone e Watch possono raggiungere da ovunque, con cifratura e senza esposizione pubblica."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="Salvare la chiave di recupero nel Portachiavi?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="Conserva la tua chiave di recupero della cifratura nel Portachiavi di macOS."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="Popolamento del grafo"
MSG_HYDRATE_CONTACTS_STARTED="Importazione dei tuoi contatti nel grafo"
MSG_HYDRATE_CONTACTS_DONE="Importati %s contatti"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="L'importazione dei contatti ha richiesto più di %ss, quindi abbiamo smesso di aspettare e siamo andati avanti. Finora sono stati importati %s contatti e Ostler completerà il resto in background."
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="Caricamento dello storico del calendario (cinque anni indietro, un anno avanti)"
MSG_HYDRATE_CALENDAR_DONE="Importati %s eventi"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  Sto ancora caricando il tuo calendario (finora %ss). Un Mac con anni di riunioni richiede un po' di tempo."
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="Creo i tuoi Luoghi a partire dai posti dei tuoi incontri"
MSG_HYDRATE_PLACES_DONE="Sezione Luoghi creata"
MSG_HYDRATE_PLACES_SKIPPED="Nessun segnale di posizione trovato per ora; i Luoghi si popoleranno man mano che il calendario si riempie"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="La creazione dei Luoghi ha avuto un problema: esistono segnali di posizione, ma non è stato prodotto alcun Luogo. La pagina Luoghi potrebbe restare vuota. Vedi %s"
MSG_HYDRATE_PLACES_ERROR_WARN="La creazione dei Luoghi non è stata completata (errore imprevisto). La pagina Luoghi potrebbe essere incompleta. Vedi %s"
MSG_HYDRATE_WIKI_RECOMPILE="Sto creando la tua wiki. Ostler scrive un breve riassunto per ogni persona, organizzazione e argomento principale, quindi con una rubrica molto grande possono volerci da qualche minuto a circa un'ora. Succede una sola volta, avviene interamente sul tuo Mac e puoi lasciarlo lavorare."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="Controllo l'indice di ricerca (%s raccolte rilevate)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="Carico la cronologia di navigazione nell'indice di ricerca"
MSG_INITIAL_HYDRATE_QDRANT_READY="Indice di ricerca pronto (%s raccolte)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="L'indice di ricerca si popolerà in background al termine dell'installazione"
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
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="L'archivio di ricerca è attivo; creo le raccolte che mancano ancora: %s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="L'indice di ricerca è incompleto: non è stato possibile creare %s anche se l'archivio di ricerca è attivo e risponde. Ostler continuerà a funzionare e il Doctor mostra questa lacuna, ma questa parte della ricerca resterà vuota finché non sarà risolta."
MSG_WARN_QDRANT_COLLECTIONS_MISSING="L'indice di ricerca è incompleto: non è stato possibile creare %s. Ostler continuerà a funzionare e il Doctor mostra questa lacuna."
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="Non è stato possibile verificare quali raccolte di ricerca esistano (%s). Questo non significa che manchino."
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="L'indice di ricerca si popolerà in background al termine dell'installazione (in attesa di: %s)"
MSG_HYDRATE_DONE="Il tuo grafo è pronto: %s persone, %s eventi"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud potrebbe ancora star sincronizzando i tuoi contatti – li riesporto ora per includere ciò che è appena arrivato."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="Nessun contatto trovato nell'app Contatti (locale o iCloud). Aggiungine qualcuno in Contatti e riesegui da Impostazioni."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="Nessun contatto iCloud da importare. Puoi aggiungerli più tardi da Impostazioni."
MSG_HYDRATE_SKIPPED_NO_EVENTS="Nessun evento del calendario negli ultimi 5 anni. Puoi recuperarli più tardi da Impostazioni."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="Leggo le email degli ultimi 90 giorni – le tue email restano su questo Mac (la cronologia più lunga viene recuperata in background)"
MSG_HYDRATE_EMAIL_DONE="Trovate %s persone nelle tue email recenti"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="Nessuna email recente da leggere. Puoi aggiungere un account in Apple Mail e riprovare più tardi."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="Il lettore email non è ancora pronto. Puoi aggiungere un account in Apple Mail e riprovare più tardi."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="Le email sono ancora in caricamento in background. La tua wiki si riempie man mano e ti mostra a che punto è."
MSG_HYDRATE_EMAIL_HEARTBEAT="  Sto ancora leggendo le tue email (finora %ss). Può richiedere un po' di tempo su un Mac con anni di cronologia."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="Aprire Apple Mail per avviare la sincronizzazione?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="Hai %s account di posta configurati, ma Apple Mail non ha ancora scaricato alcun messaggio. Possiamo aprire Mail.app ora e attendere la sincronizzazione."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="Aprire Calendario per avviare la sincronizzazione?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="Hai %s account calendario configurati, ma Calendar.app non contiene ancora eventi. Possiamo aprire Calendario ora e attendere la sincronizzazione da iCloud."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="Aprire Contatti per avviare la sincronizzazione?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="Hai %s account contatti configurati, ma Contacts.app non contiene ancora voci. Possiamo aprire Contatti ora e attendere la sincronizzazione da iCloud."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="In attesa che %s avvii la sincronizzazione (fino a %s secondi)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="Ancora in attesa della sincronizzazione di %s (%ss trascorsi, %ss rimanenti). La prima sincronizzazione di iCloud può richiedere qualche minuto dopo un nuovo accesso."
MSG_OK_APP_HAS_POPULATED="%s ha popolato il proprio archivio locale. Procedo."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="Non abbiamo rilevato la sincronizzazione di %s nel tempo di attesa. Procedo; puoi rieseguire l'importazione più tardi da Impostazioni."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="Account di Apple Mail visibili: %s. Apri Mail.app una volta così può iniziare a scaricare i messaggi."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="Account di Calendario visibili: %s. Apri Calendar.app una volta così può sincronizzare i tuoi eventi."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="Account di Contatti visibili: %s. Apri Contacts.app una volta così può sincronizzare la tua rubrica."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="Impossibile leggere i tuoi Contatti. Ostler li legge tramite Accesso completo al disco: concedilo in Impostazioni di Sistema > Privacy e sicurezza > Accesso completo al disco, poi riesegui l'idratazione da Impostazioni. Continueremo a riprovare in background."
MSG_HYDRATE_CONTACTS_PENDING="L'app Contatti non si è ancora sincronizzata. Apri Contatti una volta, attendi la sincronizzazione, poi riesegui l'idratazione da Impostazioni."
MSG_HYDRATE_CONTACTS_READ_FAILED="I tuoi contatti sono su questo Mac ma Ostler ne ha importati 0, cosa inattesa. L'importazione verrà ritentata automaticamente in background. Se il problema persiste, riesegui l'idratazione da Impostazioni o controlla il log di installazione."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler continuerà a controllare in background e importerà i tuoi contatti automaticamente quando iCloud avrà finito di sincronizzare."
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="Importati %s contatti con numeri di telefono ma quasi senza indirizzi email (%s telefono vs %s email). Di solito significa che il lettore dei contatti ha ignorato le email. I tuoi contatti sono comunque utilizzabili; consulta %s e riesegui l'idratazione da Impostazioni una volta risolto."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="Nuovi contatti importati; ricostruzione della tua wiki in background."
MSG_HYDRATE_CALENDAR_PENDING="L'app Calendario non ha ancora sincronizzato gli eventi. Apri Calendario una volta, attendi la sincronizzazione, poi riesegui l'idratazione da Impostazioni."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="Questa volta non è stato possibile leggere il tuo calendario (l'estrattore ha segnalato un errore, non un calendario vuoto). Gli altri tuoi dati non sono stati toccati; consulta %s, poi riesegui l'idratazione da Impostazioni."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="Lettura della cronologia di WhatsApp – i tuoi messaggi restano su questo Mac"
MSG_HYDRATE_WHATSAPP_DONE="Trovate %s persone nelle tue chat di WhatsApp"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="Le chat di WhatsApp sono state lette ma non scritte nel tuo grafo delle persone (uscita %s). Ostler riproverà. Dettagli: %s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="Nessuna chat di WhatsApp da leggere. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktop non è installato. Installalo dal Mac App Store e riesegui da Impostazioni."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="Il lettore di WhatsApp non è ancora pronto. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp è ancora in caricamento in background. La tua wiki si riempie man mano e ti mostra a che punto è."

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
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="I tuoi contatti di WhatsApp sono già nel tuo grafo delle persone (%s identificatori). Niente da rileggere."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="I tuoi contatti di WhatsApp erano stati letti in precedenza, ma il tuo grafo delle persone non li contiene più. Li leggo di nuovo."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="Impossibile verificare se i tuoi contatti di WhatsApp sono ancora nel tuo grafo delle persone. Li leggo di nuovo invece di presumere che ci siano."

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="Lettura della cronologia delle chat IA – le tue conversazioni restano su questo Mac"
MSG_HYDRATE_AICONV_DONE="Salvate %s conversazioni IA nella tua wiki"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="Il lettore delle conversazioni IA non è ancora pronto. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="Nessuna cronologia delle chat IA da leggere. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="Le chat IA sono ancora in caricamento in background. La tua wiki si riempie man mano e ti mostra a che punto è."
MSG_HYDRATE_AICONV_HEARTBEAT="  Lettura della cronologia delle chat IA ancora in corso (%ss finora). Una cronologia ampia può richiedere diversi minuti."


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="Importazione della cronologia di navigazione – le tue visite restano su questo Mac"
MSG_HYDRATE_BROWSING_DONE="Importate %s pagine della cronologia di navigazione"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="Saltate %s pagine segnalate come sensibili (banche, salute, ecc.)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="Nessuna cronologia di navigazione da importare. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="Il lettore della cronologia di navigazione non è ancora pronto. Puoi riprovare più tardi da Impostazioni."

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
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="La tua cronologia di navigazione è già stata importata (%s pagine). Niente da reimportare."
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="Nessuna cronologia di navigazione esportata da importare. Puoi riprovare più tardi da Impostazioni."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="La tua cronologia di navigazione era stata importata in precedenza, ma il tuo indice di ricerca non la contiene più. La importo di nuovo."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="Impossibile verificare se la tua cronologia di navigazione è ancora nel tuo indice di ricerca. La importo di nuovo invece di presumere che ci sia."
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="La tua cronologia di navigazione non è arrivata nel tuo indice di ricerca, quindi la pagina Navigazione sarà vuota. Riesegui da Impostazioni o apri Doctor."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="La cronologia di navigazione è ancora in caricamento in background. La tua wiki si riempie man mano e ti mostra a che punto è."

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="Caricamento delle tue preferenze email. Resta su questo Mac e può richiedere qualche minuto."
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="Caricate %s preferenze dalla tua cronologia email"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="Nessun file delle preferenze email configurato. Niente da caricare."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="Nessun file delle preferenze email trovato in %s. Niente da caricare."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="La pipeline delle preferenze non è ancora pronta. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="Le preferenze email sono ancora in caricamento in background. La tua wiki si riempie man mano e ti mostra a che punto è."
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  Caricamento delle preferenze email ancora in corso (%ss finora). Una cronologia molto estesa può richiedere alcuni minuti."

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="Le tue preferenze email sono già caricate (%s voci). Non serve ricaricarle."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="Le tue preferenze email erano state caricate in precedenza, ma il tuo indice di ricerca non le contiene più. Le carico di nuovo."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="Impossibile verificare se le tue preferenze email sono ancora nel tuo indice di ricerca. Le carico di nuovo, senza dare per scontato che ci siano."

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
MSG_HYDRATE_PREFERENCES_DONE="Importate %s preferenze"
MSG_HYDRATE_PREFERENCES_ENRICHED="Arricchite %s di esse con dati di riferimento pubblici"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="Importate %s preferenze, ma nessuna rientra in Cibo, Musica o Professionale. Le tue pagine wiki Cibo e Musica resteranno vuote."
MSG_WARN_PREFS_HEADLINE_HINT="Di solito significa che non era presente alcuna esportazione di musica o cibo (Spotify, Apple Music, Uber Eats, Google Takeout) oppure che i dati non erano categorizzati. Aggiungi queste esportazioni e riesegui da Impostazioni, poi ricostruisci la wiki."
MSG_WARN_PREFS_UNCATEGORISED="%s preferenze su %s (%s%%) non hanno una categoria e non compariranno in nessuna pagina di argomento. Controlla il formato dell'esportazione di origine."

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="Configurazione dell'arricchimento delle preferenze"
MSG_CM019_SETUP_DONE="Arricchimento delle preferenze pronto"
MSG_CM019_SETUP_FAILED="La configurazione dell'arricchimento delle preferenze non è terminata. Le tue pagine delle preferenze si riempiranno una volta risolto il problema; il resto di Ostler non è interessato."
MSG_CM019_SETUP_SKIPPED="Pipeline di arricchimento delle preferenze non inclusa; per ora la salto."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="Lettura della cronologia di iMessage – i tuoi messaggi restano su questo Mac"
MSG_HYDRATE_IMESSAGE_DONE="Trovate %s persone nella cronologia di iMessage"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="Nessuna cronologia di iMessage da leggere. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="Il lettore di iMessage non è ancora pronto. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage è ancora in caricamento in background. La tua wiki si riempie man mano e ti mostra a che punto è."
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  Lettura della cronologia di iMessage ancora in corso (%ss finora). Una cronologia di messaggi molto estesa può richiedere diversi minuti."

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="I tuoi contatti di iMessage sono già nel tuo grafo delle persone (%s identificatori). Non serve rileggerli."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="I tuoi contatti di iMessage erano stati letti in precedenza, ma il tuo grafo delle persone non li contiene più. Li leggo di nuovo."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="Impossibile verificare se i tuoi contatti di iMessage sono ancora nel tuo grafo delle persone. Li leggo di nuovo, senza dare per scontato che ci siano."

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="Lettura delle tue Note: restano su questo Mac"
MSG_HYDRATE_APPLE_NOTES_DONE="Aggiunte %s note alla tua base di conoscenza"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="Nessuna nota di Apple da leggere. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="Le tue Note di Apple sono già nella tua base di conoscenza. Salto."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="Le Note di Apple sono disattivate per la ricerca nella base di conoscenza. Puoi attivarle in Impostazioni."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="Importatore di conoscenza non ancora pronto. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="Le Note di Apple sono ancora in caricamento in background. La tua base di conoscenza si riempie man mano e ti mostra a che punto è."
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  Lettura delle tue Note di Apple ancora in corso (%ss finora). Una libreria di note molto estesa può richiedere alcuni minuti."

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="Le tue Note di Apple sono già nella tua base di conoscenza (%s voci). Non serve rileggerle."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="Le tue Note di Apple erano state aggiunte in precedenza, ma la tua base di conoscenza non le contiene più. Le aggiungo di nuovo."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="Impossibile verificare se le tue Note di Apple sono ancora nella tua base di conoscenza. Le aggiungo di nuovo, senza dare per scontato che ci siano."

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="Lettura dei tuoi Promemoria: restano su questo Mac"
MSG_HYDRATE_REMINDERS_DONE="Aggiunti %s promemoria alla tua base di conoscenza"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="Nessun promemoria da leggere. Puoi riprovare più tardi da Impostazioni."
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="I tuoi Promemoria sono già nella tua base di conoscenza. Salto."
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="I Promemoria sono disattivati per la ricerca nella base di conoscenza. Puoi attivarli in Impostazioni."
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="Importatore di conoscenza non ancora pronto. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="I promemoria vengono ancora caricati in background. La tua base di conoscenza si riempie man mano e ti mostra a che punto è."
MSG_HYDRATE_REMINDERS_HEARTBEAT="  Lettura dei tuoi Promemoria ancora in corso (%ss finora). Un elenco molto grande può richiedere qualche minuto."

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="I tuoi Promemoria sono già nella tua base di conoscenza (%s elementi). Non serve rileggerli."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="I tuoi Promemoria erano stati aggiunti in precedenza, ma la tua base di conoscenza non li contiene più. Li aggiungo di nuovo."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="Non è stato possibile verificare se i tuoi Promemoria sono ancora nella tua base di conoscenza. Li aggiungo di nuovo senza dare per scontato che ci siano."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="Indicizzazione delle persone per la ricerca"
MSG_HYDRATE_PEOPLE_DONE="%s persone indicizzate per la ricerca"
MSG_HYDRATE_PEOPLE_PARTIAL="Finora %s di %s persone sono state indicizzate per la ricerca. Le altre non erano ancora ricercabili; Ostler riproverà automaticamente."
MSG_HYDRATE_PEOPLE_FAILED="Questa volta non è stato possibile indicizzare le tue persone per la ricerca (l'archivio del grafo non ha risposto). Ostler riproverà automaticamente. Dettagli: %s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="Ancora nessuna persona da indicizzare. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="L'indicizzatore delle persone non è ancora pronto. Puoi riprovare più tardi da Impostazioni."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="Le tue persone vengono ancora indicizzate in background. La ricerca si completa man mano e la wiki ti mostra a che punto è."

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="Le tue persone sono già indicizzate per la ricerca (%s persone). Non serve reindicizzarle."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="Le tue persone erano state indicizzate in precedenza, ma il tuo indice di ricerca non le contiene più. Le indicizzo di nuovo."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="Non è stato possibile verificare se le tue persone sono ancora nel tuo indice di ricerca. Le indicizzo di nuovo senza dare per scontato che ci siano."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="Stanno per arrivare tre richieste di accesso alle cartelle"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="La finestra degli strumenti da riga di comando è apparsa davanti a questa finestra: fai clic su Installa, poi torna qui (oppure attendi qualche secondo, ti riporteremo noi questa finestra in primo piano). Gli strumenti vengono scaricati in background mentre continui a rispondere alle domande qui sotto; niente è bloccato."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="Autorizzazione necessaria: Automazione di iMessage"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ora Ostler chiederà a macOS l'autorizzazione a comunicare con Messages.app. macOS mostrerà un popup con scritto \"OstlerInstaller vuole accedere per controllare Messaggi\": fai clic su Consenti, così l'assistente potrà inviare e ricevere iMessage per tuo conto. Senza questa autorizzazione i messaggi iMessage non partiranno mai, senza alcun avviso. Si concede una sola volta; puoi modificarla in seguito in Impostazioni di Sistema > Privacy e sicurezza > Automazione."

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="La tua chiave di recupero"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="Scrivila o stampala adesso. È l'unico modo per rientrare se perdi la passphrase E il tuo Portachiavi diventa inaccessibile. Ostler non può recuperarla per te: la chiave non lascia mai questo Mac e non è salvata su alcun server."
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="L'ho salvata in un posto sicuro"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="Copia negli appunti"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="Salva come PDF..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="Stampa..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="Continua"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Chiave di recupero Ostler.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Chiave di recupero Ostler"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="Chiave di recupero copiata negli appunti"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="Chiave di recupero salvata in %s"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="Associa il tuo iPhone"
MSG_INFO_PAIR_IPHONE_HELP="Apri l'app Ostler sul tuo iPhone e inquadra questo codice QR per collegarlo a questo Hub. Puoi anche associarlo più tardi dal menu Impostazioni dell'Hub."
MSG_INFO_PAIR_IPHONE_FETCHING="Generazione del codice di associazione..."
MSG_INFO_PAIR_REFRESH="Aggiorna codice"
MSG_ERR_PAIR_FETCH_FAILED="Impossibile raggiungere il gateway di Ostler per ora. Potrebbe essere ancora in avvio: fai clic su Aggiorna per riprovare."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agent non incluso nell'installer. I riepiloghi giornalieri e il LaunchAgent di keepalive di WhatsApp non verranno caricati."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Script di ricompilazione della wiki non inclusi nell'installer. La wiki non si aggiornerà automaticamente."

# F3 - legal package missing
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="legal package not bundled with installer. Article 9 / WhatsApp / voice consent gates will raise ModuleNotFoundError until re-installed."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s installata in %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s già installata, lasciata dov'è"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Architettura CPU non supportata per Google Workspace CLI; le funzioni di Gmail e Google Calendar sono ridotte."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl non disponibile; installazione di Google Workspace CLI saltata. Le funzioni di Gmail e Google Calendar sono ridotte."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="Impossibile scaricare Google Workspace CLI da %s"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="SHA256 di Google Workspace CLI non corrispondente (atteso %s, ottenuto %s). Installazione di questo binario interrotta."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="Impossibile estrarre l'archivio di Google Workspace CLI."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI installato in %s, ma il controllo con --version non è riuscito."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="Bridge del calendario iCloud / CalDAV installato in %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="Il bridge del calendario iCloud / CalDAV in %s non è eseguibile. Il calendario non restituirà alcun evento."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh non è incluso nell'installer. Il nuovo tentativo di registrazione del dispositivo alla prossima connessione di rete è disattivato."

MSG_WARN_EMBED_DIMS_UNREADABLE="Impossibile leggere la dimensione degli embedding dal controllo di stato. La memoria è configurata per 768 dimensioni; se il richiamo si comporta in modo strano, controlla il modello di embedding."
MSG_FAIL_EMBED_DIMS="Il modello di embedding ha restituito vettori a %s dimensioni, ma Ostler è configurato per %s. La memoria salverebbe vettori che non potrebbe mai confrontare. Controlla il modello di embedding e riesegui."

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
MSG_PROGRESS_REBOOT_SELFHEAL="Configurazione del ripristino automatico al riavvio"
MSG_INFO_AUTOLOGIN_EXPLAIN="Ostler è un hub sempre attivo, quindi dopo un'interruzione di corrente o un riavvio deve ripartire senza nessuno alla tastiera. Questo funziona solo se il Mac accede da solo, e macOS può farlo solo se la password di login di %s è memorizzata su questo Mac.

Memorizzarla indebolisce la sicurezza di questo Mac. La password viene offuscata, non cifrata, quindi chiunque possa usare un account amministratore qui, o possa estrarre il disco e leggerlo altrove, può ricavare la tua password. Vedrai esattamente dove viene salvata prima di digitare qualsiasi cosa.

Se rispondi di no, non viene memorizzato nulla e non cambia nient'altro. Dopo un'interruzione di corrente accedi come al solito e i servizi di Ostler si avviano con la tua sessione. Puoi cambiare questa scelta più tardi in Impostazioni di Sistema > Utenti e gruppi > Login automatico."
MSG_PROMPT_AUTOLOGIN_CONSENT="Store your login password on this Mac so it can sign itself in after a restart? [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="Ostler scrive questa password in un file su questo Mac, in /etc/kcpassword. Lì viene offuscata con uno schema fisso, uguale su ogni Mac e documentato pubblicamente, quindi non è cifratura e può essere annullata. Chiunque possa usare un account amministratore su questo Mac, o possa estrarre il disco e leggerlo altrove, può riconvertire quel file nella password di login di %s.

FileVault lo impedirebbe, perché il disco non può essere letto affatto senza la password di avvio. Per lo stesso motivo FileVault impedisce anche l'accesso automatico, ed è per questo che Ostler lo propone solo quando FileVault è disattivato.

Ciò che dipende dall'installer: non mostra la password mentre la digiti e non la scrive nel log di installazione. Il file offuscato è l'unica copia creata dall'installer.

Lascia vuoto per saltare l'accesso automatico."
MSG_PROMPT_AUTOLOGIN_PASSWORD="Password di login per %s"
MSG_OK_AUTOLOGIN_CONFIGURED="L'accesso automatico è attivo per %s e la password di login è ora su questo Mac in /etc/kcpassword in forma offuscata. Dopo un riavvio questo Mac accede da solo e i servizi di Ostler si avviano con quella sessione. Per annullare, disattiva Login automatico in Impostazioni di Sistema > Utenti e gruppi."
MSG_INFO_AUTOLOGIN_ALREADY="L'accesso automatico è già configurato per %s, quindi su questo Mac è già memorizzata quella password di login in /etc/kcpassword. Lascio entrambi invariati. Per annullare, disattiva Login automatico in Impostazioni di Sistema > Utenti e gruppi."
MSG_INFO_AUTOLOGIN_DECLINED="L'accesso automatico non è stato attivato e nessuna password è stata memorizzata. Dopo un riavvio o un'interruzione di corrente, accedi come al solito e i servizi di Ostler si avviano con la tua sessione."
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="Configurazione dell'accesso automatico saltata: qui non è possibile chiedere una password di login e non è stato memorizzato nulla. Puoi attivare Login automatico più tardi in Impostazioni di Sistema > Utenti e gruppi se vuoi che questo Mac si riprenda da un riavvio senza assistenza. Memorizza la tua password di login sul Mac in forma offuscata e reversibile, quindi conviene informarsi prima di farlo."
MSG_WARN_AUTOLOGIN_NO_PASSWORD="Non è stata inserita alcuna password, quindi l'accesso automatico non è stato attivato e non è stato memorizzato nulla. Se lo vorrai più avanti, attiva Login automatico in Impostazioni di Sistema > Utenti e gruppi."
MSG_WARN_AUTOLOGIN_FAILED="Impossibile attivare l'accesso automatico (%s). Non verrà ritentato. Se /etc/kcpassword esiste su questo Mac, contiene quella password di login in forma offuscata anche se la funzione è disattivata; puoi rimuoverlo da Terminale con: sudo rm /etc/kcpassword. Per riprovare, attiva Login automatico in Impostazioni di Sistema > Utenti e gruppi."
MSG_WARN_AUTOLOGIN_FILEVAULT="FileVault è attivo, quindi questo Mac chiede una password nella schermata di avvio per sbloccare il disco prima che qualcuno possa accedere. L'accesso automatico non può rispondere a questa richiesta, quindi dopo un'interruzione di corrente questo Mac resta in attesa nella schermata di sblocco di FileVault finché qualcuno non la inserisce. L'accesso automatico non è stato attivato e nessuna password è stata memorizzata. È la soluzione più sicura delle due: il ripristino automatico al riavvio non è possibile con FileVault attivo e, in cambio, il disco resta illeggibile a chi non ha quella password."

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
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="Ostler non è riuscito ad aprire Impostazioni di Sistema per te. Apri Impostazioni di Sistema manualmente e vai a Privacy e sicurezza > Accesso completo al disco."
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="Ostler esegue la tua wiki e la ricerca in container, quindi installa e gestisce su questo Mac un motore di container (Colima). Se questo motore viene rimosso o riconfigurato, la wiki e la ricerca smetteranno di funzionare – Ostler te lo comunicherà e proverà a riavviarlo."
MSG_INFO_ENGINE_ALREADY_PRESENT="Su questo Mac è già installato un motore di container. Ostler lo userà invece di installarne uno proprio e non lo gestirà né lo modificherà."

# OS003 #233: model weight pins (install.sh OSTLER_MODEL_PINS).
MSG_OK_MODEL_DIGEST_VERIFIED="%s verified against its pinned digest (%s)"
MSG_FAIL_MODEL_DIGEST_MISMATCH="The installed %s is not the model this installer ships: found %s, expected %s (%s). The download source may have changed, so the install has stopped before using it. Contact support with this message."
MSG_FAIL_MODEL_UNPINNED="%s has no pinned digest in this installer, so it cannot be verified and will not be used. This is an installer defect. Contact support with this message."
MSG_FAIL_MODEL_DIGEST_UNREADABLE="Could not verify the downloaded %s against its pinned digest (%s). The model will not be used unverified. Re-run the installer; if this repeats, contact support with this message."
