#!/usr/bin/env bash
# CM051 install.sh -- it-IT strings catalogue
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

MSG_STEP_CHECKING_PREREQUISITES="Verifica dei prerequisiti"
MSG_STEP_RUNNING_HEALTH_CHECK="Controllo dello stato in corso"
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="Configurazione (rispondi a poche domande, poi puoi andare via)"

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="poi riesegui: ostler-fda"
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="Account Apple Mail visibili: %s (informativo)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mail non sembra contenere ancora messaggi locali. Doctor mostrera un promemoria se non arriva posta entro 24 ore."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mail ha messaggi in cache. L'acquisizione li recuperera al prossimo ciclo orario."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="Apple Mail e selezionato, ma su questo Mac non ci sono ancora messaggi locali da leggere. Apri Apple Mail e aggiungi un account (Impostazioni di Sistema > Account Internet, poi spunta Mail) e lascia che completi una prima sincronizzazione."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="Una volta arrivata la posta, riesegui: ostler-fda. Ostler la recuperera automaticamente; non serve altro."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="La notarizzazione Apple verra verificata da Gatekeeper al primo avvio."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="disponibile, l'installer saltera automaticamente questo passaggio."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="I beta tester con accesso possono impostare PWG_PIPELINE_REPO=<url> e rieseguire."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="I beta tester con accesso possono impostare PWG_KNOWLEDGE_REPO=<url> e rieseguire."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="Estensioni del browser saltate (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  Clonato in %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture e solo per Apple Silicon. Installazione saltata su questa macchina."
MSG_INFO_CM042_LOGS_AT="Log di RemoteCapture: %s/ostler-remotecapture.log (e .err)"
MSG_INFO_CM042_TCC_PRE_PROMPT="Al primo avvio, Ostler RemoteCapture chiedera a macOS il permesso di Registrazione Schermo e Microfono. Concedi entrambi cosi chiamate e riunioni possono essere trascritte localmente. Nessun indicatore viola di registrazione appare nella barra dei menu: la cattura audio e silenziosa per scelta progettuale."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  Motore della memoria delle conversazioni installato nel venv."
MSG_INFO_HUB_APP_VERIFYING="Verifica di Ostler.app in %s"
MSG_INFO_HUB_APP_STAGING="Predisposizione di Ostler.app in /Applications da %s"
MSG_INFO_HUB_APP_DRAG_HINT="Apri il DMG dell'installer e trascina sia Ostler.app sia OstlerInstaller.app sul collegamento Applicazioni, poi riesegui l'installer."
MSG_OK_HUB_APP_PRESENT="Ostler.app gia presente in %s; firma verificata."
MSG_OK_HUB_APP_STAGED="Ostler.app installato in %s"
MSG_WARN_HUB_APP_NOT_FOUND="Ostler.app non e stato trovato in /Applications e non e disponibile alcuna copia in bundle."
MSG_WARN_HUB_APP_VERIFY_FAILED="La verifica della firma o della notarizzazione di Ostler.app non e riuscita. Il bundle resta al suo posto cosi l'assistenza puo esaminarlo."
MSG_INFO_CLONING_DOCTOR_AGENT="Clonazione dell'agente Doctor..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="Clonazione degli script di acquisizione email..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Clonazione degli script hub-power..."
MSG_INFO_CLONING_IMPORT_PIPELINE="Clonazione della pipeline di importazione..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="Clonazione degli script di ricompilazione del wiki..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima e installato ma non in esecuzione. Verra avviato."
MSG_INFO_COLIMA_START_ATTEMPT="Avvio di Colima (tentativo %s di %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="Impossibile esportare i contatti. Puoi importarli manualmente piu tardi."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="Impossibile leggere la scheda contatto. Nessun problema: te lo chiederemo invece."
MSG_INFO_CONTACT_CARD_WILL_ASK="Tra poco ti chiederemo nome e paese. I tuoi contatti vengono letti piu tardi usando l'accesso a Tutto il Disco che concedi, e nulla lascia questo Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  Creazione del venv Python in %s..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="Creazione dell'albero dei contenuti per l'utente in %s/"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="Ciclo giornaliero. Esecuzione manuale: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="Hub desktop (nessuna batteria) rilevato: disattivazione dello stop a livello di sistema"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker non installato. Verranno installati Colima + Docker CLI + plugin docker-compose (leggeri, non serve Docker Desktop)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="File dell'agente Doctor non inclusi nell'installer."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="Script di acquisizione email non inclusi nell'installer."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="Gli script di acquisizione email mancano dal bundle dell'installer. Scarica di nuovo la .app da ostler.ai/install e riprova."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Script di acquisizione email non inclusi ed e stato passato --allow-plaintext; l'installazione del LaunchAgent verra saltata. Le email future non verranno scaricate."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  Checkout esistente in %s; aggiornamento..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Estrazione della mbox di Gmail dallo zip di Takeout (per archivi grandi puo richiedere un minuto)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="Modulo di estrazione FDA non incluso. Estrazione istantanea dei dati saltata."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Attivazione dei tuoi primi 30 giorni di Ostler Pro..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Ostler Pro costa \$9.99 USD al mese dopo la prova. Abbonati tramite l'app iOS Companion."
MSG_INFO_FOUND_GMAIL_MBOX_MB="Trovata mbox di Gmail in %s (%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Trovato zip di Google Takeout in %s (%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="Full Disk Access rilevato: estrazione completa disponibile."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="Export GDPR rilevati ma la pipeline di importazione non e ancora disponibile."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="L'importazione degli export GDPR sara disponibile quando la pipeline verra rilasciata."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="Sto per analizzare Download, Scrivania e Documenti alla ricerca di export di IA (Google Takeout, download di Meta, LinkedIn, ecc.) che potresti aver salvato. macOS mostrera tre richieste di accesso alle cartelle: concedile tutte. Richiede circa 5-10 secondi in totale. Nulla viene spostato o copiato durante la scansione; controlliamo solo cosa c'e."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS potrebbe chiedere il permesso di leggere il tuo Calendario. Concedilo cosi Ostler puo costruire la parte di riunioni ed eventi del tuo grafo di conoscenza. (I dati del calendario restano su questa macchina.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS sta chiedendo il permesso per Download. Clicca OK."
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS sta chiedendo il permesso per Scrivania. Clicca OK."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS sta chiedendo il permesso per Documenti. Clicca OK."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="Full Disk Access concesso. Preparazione della prossima richiesta di macOS (automazione di Messages)..."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="Servono gli Xcode Command Line Tools. macOS chiedera il permesso di installarli: cerca una piccola finestra grigia (se non la vedi, premi Cmd+Tab o controlla il Dock). Clicca Installa. Gli strumenti vengono scaricati in background mentre rispondi alle domande qui sotto."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  Attesa dei Command Line Tools ancora in corso (trascorsi: %ss)..."
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="Attesa del completamento dell'installazione dei Command Line Tools (ci siamo quasi)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="Ciclo orario. La prima esecuzione recupera gli ultimi 5 anni di posta."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="Disattivazione del LaunchAgent del bridge iMessage legacy (single-machine v1.0)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Hub solo a corrente (nessuna batteria rilevata), LaunchAgent hub-power saltato."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Script hub-power non inclusi nell'installer."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="API dell'assistente inclusa nell'installer; uso della sorgente in bundle."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="Sorgente dell'API dell'assistente non inclusa; gli endpoint dell'iOS Companion saranno limitati."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Quando appare la finestra di Tailscale, accedi con Apple / Google / Microsoft."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="Apertura di Tailscale cosi puoi accedere..."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale saltato: l'iOS Companion funzionera solo sul tuo Wi-Fi di casa. Puoi configurarlo piu tardi dalle Impostazioni."
MSG_INFO_TAILSCALE_STILL_WAITING="Attesa dell'accesso a Tailscale ancora in corso (%ss trascorsi): completa l'accesso nella finestra di Tailscale."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="Full Disk Access concesso; riavvio dell'assistente per applicare il nuovo permesso."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="Apertura di Impostazioni di Sistema + Finder per guidarti nella concessione del Full Disk Access all'assistente..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="Il Full Disk Access e ancora in attesa. La dashboard Doctor terra visibile la scheda finche l'accesso non viene concesso."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant ha gia il Full Disk Access; non serve altro."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Verifica se l'assistente Ostler puo leggere la cronologia di Messages..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="L'assistente puo leggere la cronologia di Messages; il canale iMessage funzionera."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="L'assistente non puo ancora leggere la cronologia di Messages. La dashboard Doctor mostrera una scheda che ti guidera attraverso Impostazioni di Sistema."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="Il LaunchAgent dell'assistente non si e caricato; verifica del Full Disk Access per iMessage saltata."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="L'interfaccia Importa-Evernote in Doctor mostrera un 'servizio non disponibile'"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Pipeline di importazione non inclusa nell'installer."
MSG_INFO_INSTALLING_CM042="Installazione di Ostler RemoteCapture v%s (trascrizione di chiamate + riunioni)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="Installazione del motore della memoria delle conversazioni da %s..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  Installazione del motore della memoria delle conversazioni nel venv..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="Installazione di Colima + Docker CLI..."
MSG_INFO_INSTALLING_HOMEBREW="Installazione di Homebrew..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="Installazione del servizio Knowledge da %s..."
MSG_INFO_INSTALLING_OLLAMA="Installazione di Ollama..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Installazione del lettore di Apple Mail in un venv dedicato..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  Installazione di ostler-knowledge nel venv..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Installazione dell'estensione Safari in /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="Installazione delle dipendenze Python di sicurezza..."
MSG_INFO_INSTALLING_SQLCIPHER="Installazione di SQLCipher..."
MSG_INFO_INSTALLING_TAILSCALE="Installazione di Tailscale..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="Il supporto Intel non e in roadmap; apri una richiesta se necessario."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Servizio Knowledge incluso nell'installer; uso della sorgente in bundle."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Servizio Knowledge non installato: PWG_KNOWLEDGE_REPO vuoto."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="piu tardi in Impostazioni di Sistema > Privacy e Sicurezza > Full Disk Access"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  avvio per verificare lo stato di cron-delivery + imessage-tcc)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="Licenza: %s e Apache 2.0. Testo completo: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licenza: %s: controlla i termini upstream prima dell'uso commerciale."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="archivio locale: Google non vede mai che Ostler esiste."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="Log: %s/email-ingest.log (e .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="Log: %s/ostler-assistant.log (e .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="Log: %s/wiki-recompile.log (e .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="Hub su MacBook: imposta PWG_HUB_POWER_REPO=<url> e riesegui."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="Hub MacBook rilevato: impostazione di mai-in-stop solo a corrente (hub-power gestisce le transizioni a batteria)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Le installazioni su Mac Mini / Studio non sono interessate (sempre a corrente)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="I dati lato Mac (iMessage, Safari, ecc.) sono stati estratti sopra."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="Riavvio manuale: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="Esecuzione manuale: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="Installazione di com.ostler.meeting-brief-sender saltata (funzione v1.0.1; endpoint non ancora rilasciati)."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="messaggio quando il feature flag verra attivato piu tardi."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="Hai bisogno di aiuto? Scrivi a support@ostler.ai. Cerchiamo di rispondere entro 2 giorni lavorativi."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="Nessun canale configurato. Esegui piu tardi: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="Nessuna sorgente FDA disponibile al momento. Puoi concedere il Full Disk Access"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="Nessun export GDPR trovato in Download, Scrivania o Documenti."
MSG_INFO_OPENING_CHROME_WEB_STORE="Apertura del Chrome Web Store: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="binario ostler-assistant non installato; verifica doctor saltata"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: rinviato (il daemon potrebbe essere ancora"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="Uso del binario ostler-assistant incluso in questo DMG (percorso di installazione offline)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge installato nel venv."
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler mostrera una schermata di consenso aggiuntiva prima di installare"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  Sovrascrivi il repo sorgente per il motore della memoria delle conversazioni tramite la variabile d'ambiente documentata in ./install.sh --help."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  Sovrascrivi il repo sorgente con PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  Sovrascrivi il repo sorgente con PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  Sovrascrivi il repo sorgente con PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  Sovrascrivi il repo sorgente con PWG_PIPELINE_REPO=<url> ./install.sh"
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Salvataggio dei record di consenso e della regione..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="Watcher della batteria della Fase 3 attivato (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="Lettura della tua rubrica (le librerie grandi possono richiedere un paio di minuti: non chiudere l'installer)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="Override della policy: modifica ~/.ostler/power.conf (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="Verifica del permesso di automazione iMessage (sola lettura)..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="Download di nomic-embed-text (274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="Download di %s (%s)... puo richiedere alcuni minuti."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="Attributo quarantine rimosso. Una volta che la build Developer-ID e"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Lettura di Safari, iMessage, Note, Calendario, Foto, Promemoria, Mail..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="Lettura della tua scheda contatto per precompilare i tuoi dati..."
MSG_INFO_REGION_EU_EEA_SOURCE="Regione: UE/SEE (%s, fonte: %s)"
MSG_INFO_REGION_SOURCE="Regione: %s (fonte: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="Regione: Regno Unito (fonte: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="Regione: Stati Uniti (fonte: %s)"
MSG_INFO_REPO_URL="URL del repo: %s"
MSG_INFO_REPO_URL_2="URL del repo: %s"
MSG_INFO_REPO_URL_3="URL del repo: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="Ora scegli la passphrase che sbloccera il tuo Hub. La digiterai ogni volta che avvii l'interfaccia dell'Hub."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="Passphrase di recupero saltata. (Deprecato: la v1.0 richiede sempre una passphrase.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="Riutilizzo dell'installazione esistente dell'agente Doctor in %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="Riutilizzo dell'installazione esistente di email-ingest in %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="Riutilizzo dell'installazione esistente di hub-power in %s"
MSG_INFO_REUSING_EXISTING_JWT_SECRET="Riutilizzo del JWT_SECRET esistente in %s"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="Riutilizzo del token di servizio PWG esistente in %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="Riutilizzo dell'installazione esistente di wiki-recompile in %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="Bundle dell'estensione Safari non presente in questa build dell'installer (saltato)"
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="Scansione degli export di dati GDPR..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="Imposta PWG_DOCTOR_REPO=<url> e riesegui per installare."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="Imposta PWG_HUB_POWER_REPO=<url HR015> e riesegui per installare."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="Modello di conversazione saltato. Scaricalo piu tardi: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Avvio di Colima (runtime Docker leggero)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Avvio di Docker Desktop..."
MSG_INFO_STARTING_OLLAMA="Avvio di Ollama..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="Rimozione della vecchia formula Ollama (senza llama-server); passaggio all'app Ollama..."
MSG_INFO_VERIFYING_EMBEDDINGS="Verifica che il motore di embedding restituisca vettori..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="Impossibile avviare Ollama automaticamente. Caricalo con: launchctl bootstrap gui/\$(id -u) %s -- poi riesegui l'installer."
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  in avvio; esegui \`ostler-assistant doctor\` dopo il primo"
MSG_INFO_SYMLINKING="  Creazione del symlink %s -> %s"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(Impostazioni di Sistema > Account Internet). Ostler legge dall'archivio di Mail"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(Il resto di Ostler funziona senza la dashboard Doctor.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="Per ora e previsto. L'importazione GDPR sara disponibile in un aggiornamento futuro."
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="Puo richiedere 5-15 minuti a seconda di quanti dati hai..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="Questo legge direttamente i database di macOS: non serve alcun export."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="Suggerimento: per includere il tuo Gmail, aggiungilo prima a Mac Mail"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="Per installare piu tardi, una volta ottenuto l'accesso:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="Avvio della sincronizzazione iCloud per %s (silenziosa, solo al primo avvio)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (UK GDPR Articolo 9 - richiesto per i dati di categoria particolare)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="Aggiornamento della pipeline esistente..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="Albero per l'utente gia annunciato (sentinella presente); saltato"
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane non risponde (opzionale; vedi gli avvisi della Fase 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="Visualizzalo in qualsiasi momento con: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="Il riconoscimento vocale restera disattivato. Puoi attivarlo piu tardi nelle Impostazioni."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="Attesa che tu acceda a Tailscale (fino a 3 minuti)..."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="Connettore WhatsApp lasciato disattivato. Puoi attivarlo piu tardi dalle Impostazioni."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="Keepalive WhatsApp pianificato alle 08:50 + 17:50 (etichetta com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="Recupero del wiki del primo giorno saltato: il ciclo di ricompilazione del wiki non e installato. La ricostruzione giornaliera del wiki, se installata, viene comunque eseguita."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Script di ricompilazione del wiki non inclusi nell'installer."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="Il wiki non si aggiornera automaticamente; puoi rieseguire la prima compilazione manualmente:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="Marker di stato scritto: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="I tuoi export sono al sicuro. Importali piu tardi con: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="I tuoi dati Mac (iMessage, Safari, ecc.) sono gia stati estratti sopra."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="Puoi aggiungerlo piu tardi per un onboarding istantaneo da Safari, iMessage, ecc."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="Modello IA: %s (%s): selezionato per i tuoi %s GB di RAM"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="Tutte le sorgenti selezionate (riconoscimento facciale comunque disattivato)"
MSG_OK_ALREADY_AVAILABLE="%s gia disponibile"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon rilevato"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="App avviate per innescare la sincronizzazione iCloud"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="Database delle app gia presenti (pre-avvio saltato)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="Configurazione dell'assistente salvata in %s (modo 0600)"
MSG_OK_BACKED_UP_CONTACTS="Backup di %s contatti in %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s installato in %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="LaunchAgent di Ostler RemoteCapture caricato (etichetta %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima e Docker CLI installati"
MSG_OK_COLIMA_WILL_START_AUTOMATICALLY_BOOT="Colima si avviera automaticamente all'accensione"
MSG_OK_CONFIG_SAVED_ENV="Configurazione salvata in %s/.env"
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Record di consenso e regione salvati in ~/.ostler/posture/"
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="Database cifrati. La passphrase e richiesta a ogni avvio."
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="Ritentativo differito di registrazione dispositivo installato (viene eseguito ogni ora finche la coda non si svuota)"
MSG_OK_DOCKER_RUNNING="Docker in esecuzione"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker in esecuzione (impiegati %ss)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Agente Doctor clonato da %s"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="File dell'agente Doctor inclusi nell'installer"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Dipendenze di Doctor installate"
MSG_OK_EMAIL_CHANNEL_FOLDER="Canale email: %s (cartella: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent di email-ingest caricato (etichetta com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="Script di acquisizione email inclusi nell'installer"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="Script di acquisizione email clonati da %s"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="Configurazione della memoria delle conversazioni WhatsApp"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  Lettore di conversazioni WhatsApp installato."
MSG_WARN_WHATSAPP_SOURCE_FAILED="Installazione del lettore di conversazioni WhatsApp non riuscita; il feed delle conversazioni WhatsApp non verra eseguito. Vedi l'output sopra."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="Sorgente del lettore di conversazioni WhatsApp non trovata; feed delle conversazioni WhatsApp saltato."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="Pacchetto del feed delle conversazioni WhatsApp non trovato in questo installer; saltato. La cronologia dei messaggi WhatsApp (a chi hai scritto e quando) non e interessata."
MSG_OK_WHATSAPP_BUNDLE_LOADED="LaunchAgent del feed delle conversazioni WhatsApp caricato (etichetta com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  Il primo ciclo legge le conversazioni WhatsApp recenti che il tuo Mac ha sincronizzato (circa l'ultimo anno); restano sul tuo Mac."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  Log: %s/whatsapp-bundle.log e whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="Installazione del LaunchAgent del feed delle conversazioni WhatsApp non riuscita. Vedi l'output sopra; il resto dell'installazione non e interessato."
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="Configurazione della memoria delle conversazioni email"
MSG_OK_EMAIL_SOURCE_INSTALLED="  Lettore di conversazioni email installato."
MSG_WARN_EMAIL_SOURCE_FAILED="Installazione del lettore di conversazioni email non riuscita; il feed delle conversazioni email non verra eseguito. Vedi l'output sopra."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="Sorgente del lettore di conversazioni email non trovata; feed delle conversazioni email saltato."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="Pacchetto del feed delle conversazioni email non trovato in questo installer; saltato. L'acquisizione oraria delle email non e interessata."
MSG_OK_EMAIL_BUNDLE_LOADED="LaunchAgent del feed delle conversazioni email caricato (etichetta com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Legge i tuoi thread email recenti dall'archivio locale di Apple Mail; tutto resta sul tuo Mac."
MSG_INFO_EMAIL_BUNDLE_LOGS="  Log: %s/email-bundle.log e email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="Installazione del LaunchAgent del feed delle conversazioni email non riuscita. Vedi l'output sopra; il resto dell'installazione non e interessato."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="Configurazione della memoria delle conversazioni di riunioni e voce"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  Lettore di conversazioni di riunioni e voce installato."
MSG_WARN_SPOKEN_SOURCE_FAILED="Installazione del lettore di conversazioni di riunioni e voce non riuscita; il feed non verra eseguito. Vedi l'output sopra."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="Sorgente del lettore di conversazioni di riunioni e voce non trovata; feed saltato."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="Pacchetto del feed delle conversazioni di riunioni e voce non trovato in questo installer; saltato."
MSG_OK_SPOKEN_BUNDLE_LOADED="LaunchAgent del feed delle conversazioni di riunioni e voce caricato (etichetta com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  Trasforma le tue riunioni registrate e le note vocali in conversazioni ricercabili; tutto resta sul tuo Mac."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  Log: %s/spoken-bundle.log e spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="Installazione del LaunchAgent del feed delle conversazioni di riunioni e voce non riuscita. Vedi l'output sopra; il resto dell'installazione non e interessato."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="Configurazione della memoria delle conversazioni iMessage"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  Lettore di conversazioni iMessage installato."
MSG_WARN_IMESSAGE_SOURCE_FAILED="Installazione del lettore di conversazioni iMessage non riuscita; il feed delle conversazioni iMessage non verra eseguito. Vedi l'output sopra."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="Sorgente del lettore di conversazioni iMessage non trovata; feed delle conversazioni iMessage saltato."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="Pacchetto del feed delle conversazioni iMessage non trovato in questo installer; saltato."
MSG_OK_IMESSAGE_BUNDLE_LOADED="LaunchAgent del feed delle conversazioni iMessage caricato (etichetta com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  Legge le tue conversazioni iMessage recenti dall'archivio Messages di questo Mac; tutto resta sul tuo Mac."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  Log: %s/imessage-bundle.log e imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="Installazione del LaunchAgent del feed delle conversazioni iMessage non riuscita. Vedi l'output sopra; il resto dell'installazione non e interessato."
MSG_OK_EMBEDDING_MODEL_READY="Modello di embedding pronto"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="Esportati %s contatti (verranno importati automaticamente)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="Watcher degli export installato (analizza Download ogni 4 ore)"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="Invio dei brief pre-riunione installato (controlla ogni 10 minuti durante le ore di veglia)"
MSG_OK_EXTRACTED="Estratto in %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="Estratto da %s sorgente/i. Dati salvati in %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_12_HOURS="Riesecuzione FDA pianificata tra circa 12 ore (per intercettare le sincronizzazioni iCloud lente)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro attivo per 30 giorni. Abbonati tramite l'app iOS Companion per estenderlo dopo la prova."
MSG_OK_FOUND="Trovato: %s"
MSG_OK_FOUND_EXPORTS="Trovati export in %s"
MSG_OK_FOUND_GDPR_EXPORT_S="Trovati %s export GDPR:"
MSG_OK_GB_FREE_DISK_SPACE="%s GB di spazio libero su disco"
MSG_OK_GB_RAM_DETECTED="%s GB di RAM rilevati"
MSG_OK_GDPR_IMPORT_COMPLETE="Importazione GDPR completata"
MSG_OK_GIT_AVAILABLE="Git disponibile"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="Installazione dei Command Line Tools avviata (download in background mentre rispondi alle domande qui sotto)."
MSG_OK_HOMEBREW_INSTALLED="Homebrew installato"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent hub-power caricato (etichetta com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Script hub-power inclusi nell'installer"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Script hub-power clonati da %s"
MSG_OK_ICAL_SERVER_INSTALLED="API dell'assistente installata (loopback 127.0.0.1:8090, con proxy da Doctor)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="Permesso di automazione iMessage: concesso"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="LaunchAgent del bridge iMessage caricato (etichetta com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="Script del bridge iMessage inclusi nell'installer"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="Script del bridge iMessage clonati da %s"
MSG_OK_IMESSAGE_CHANNEL="Canale iMessage: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="Pipeline di importazione inclusa nell'installer"
MSG_OK_IMPORT_PIPELINE_READY="Pipeline di importazione pronta"
MSG_OK_CM048_PIPELINE_READY="Motore della memoria delle conversazioni pronto."
MSG_INFO_CM048_SETTINGS_WRITTEN="  Modelli di conversazione impostati su %s (adattati ai tuoi %s GB di memoria)"
MSG_INFO_CM048_SETTINGS_KEPT="  Mantengo le tue impostazioni di conversazione esistenti (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="Servizio Knowledge pronto: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="Testi delle licenze installati in %s/ (fonte: %s)"
MSG_OK_MACOS_DETECTED="macOS %s rilevato"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="Apertura di Impostazioni di Sistema > Account Internet cosi puoi aggiungere un account di posta. Torna a questa finestra una volta effettuato l'accesso al tuo primo account."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="Passaggio Account Internet saltato. Puoi aggiungere un account di posta piu tardi da Impostazioni di Sistema; Doctor mostrera un promemoria se non arriva posta entro 24 ore."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Recupero ora dell'intera cronologia di Apple Mail. Per una casella grande puo richiedere un po' piu di tempo."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="Mantengo la finestra standard di cinque anni di posta. Puoi recuperarne altra piu tardi da Doctor."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text gia disponibile"
MSG_OK_OLLAMA_HEALTHY="Ollama in salute"
MSG_OK_OLLAMA_INSTALLED="Ollama installato"
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama installato (solo CLI: potrebbe servire un avvio manuale dopo il riavvio)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama installato (app desktop)"
MSG_OK_OLLAMA_RUNNING="Ollama in esecuzione"
MSG_OK_EMBEDDINGS_VERIFIED="Motore di embedding verificato (vettori a 768 dimensioni)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: nessun errore rilevato"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent dell'assistente Ostler caricato (etichetta com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s predisposto in %s (firmato)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s predisposto in %s (non firmato)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor in esecuzione su http://localhost:8089/doctor"
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Lettore di Apple Mail installato."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  Motore di acquisizione email installato."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="Comandi ostler-import, ostler-fda e ostler-uninstall installati"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph in salute"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="Passphrase annotata. Cifrera i tuoi database durante la Fase 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="Passphrase di recupero configurata."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="Informativa sulla passphrase confermata."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="Alimentazione: corrente (Mac desktop, nessuna batteria)"
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="Alimentazione: corrente (ideale per l'installazione di 10-15 minuti)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="Installazione precedente rilevata. Caricamento della configurazione..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="Uso del Python %s incluso (non serve un'installazione di sistema)"
MSG_OK_PYTHON_INSTALLED="Python %s installato"
MSG_OK_QDRANT_HEALTHY="Qdrant in salute"
MSG_OK_READY="%s pronto"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="Sorgenti consigliate selezionate"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="Chiave di recupero salvata nel Portachiavi (cerca 'Ostler' nell'app Password)"
MSG_OK_REDIS_HEALTHY="Redis in salute"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Estensione Safari installata in %s"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="Sicurezza gia configurata in un'esecuzione precedente."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="Modulo di sicurezza installato nel venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="Nuovo JWT_SECRET generato in %s"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="Token di servizio PWG generato in %s"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="Servizi avviati (Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant optional-collection pre-create (#606) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  Collezione di ricerca preparata: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="Impossibile preparare la collezione di ricerca %s; il wiki verra comunque costruito (il lettore la tratta come vuota)"
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="Indice di ricerca non pronto in tempo; preparazione delle collezioni opzionali saltata (il wiki verra comunque costruito)"
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="Stop disattivato a corrente, stop a batteria preservato, riattivazione via rete abilitata"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="Stop disattivato, riattivazione via rete abilitata"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale gia installato"
MSG_OK_TAILSCALE_INSTALLED="Tailscale installato"
MSG_OK_TAILSCALE_ENV_PERSISTED="IP di Tailscale salvato in .env: l'iOS Companion lo usera al primo avvio."
MSG_OK_TAILSCALE_IP="IP di Tailscale: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Servizio in background di Tailscale avviato (modalita userspace, nessuna estensione di sistema)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="Impossibile avviare il servizio in background di Tailscale. Puoi rieseguire la configurazione piu tardi dalle Impostazioni."
MSG_INFO_TAILSCALE_SIGN_IN_URL="Apertura del browser per accedere a Tailscale: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Porta Hub %s esposta sulla tua tailnet"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="Impossibile esporre la porta Hub %s sulla tua tailnet; la raggiungibilita fuori LAN potrebbe essere limitata"
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="Attribuzioni di terze parti installate (fonte: %s)"
MSG_OK_USER_FACING_TREE_READY="Albero per l'utente pronto"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="Uso invece della cartella/etichetta 'Ostler'."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane in salute (ricerca web locale)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane in esecuzione su http://localhost:3000 (comunica con il tuo Ollama locale)"
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="Il connettore WhatsApp verra abilitato (consenso registrato)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="LaunchAgent di recupero del wiki del primo giorno caricato (ricostruisce il tuo wiki ogni 30 minuti per le prime ore, poi si ferma)"
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent di wiki-recompile caricato (etichetta com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Script di ricompilazione del wiki inclusi nell'installer"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Script di ricompilazione del wiki clonati da %s"
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki in esecuzione su http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="Il tuo wiki e pronto da consultare. Ostler sta ora scrivendo i riepiloghi delle pagine in background, quindi si riempiranno nel giro di poco. Puoi iniziare a usare il tuo wiki subito."
MSG_OK_YOUR_ASSISTANT_CALLED="Il tuo assistente si chiama %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="Script del digest del contesto personale inclusi nell'installer"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="LaunchAgent del digest del contesto personale caricato (etichetta com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  Log: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="Riutilizzo dell'installazione esistente di context-refresh in %s"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="Script del digest del contesto personale non inclusi; l'assistente si affidera solo a ricerche in tempo reale (nessun riepilogo di contesto sempre attivo)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="Il LaunchAgent del digest del contesto personale non si e caricato; vedi context-refresh.err. L'assistente risponde comunque tramite ricerche in tempo reale"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="Il Blocco 3.1 dello stack di produzione del servizio Knowledge aggiunge pyproject.toml…"
MSG_WARN_BUNDLE="  Bundle: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s e solo per Apple Silicon (rilevato: %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="Impossibile scaricare Ostler RemoteCapture v%s da %s"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="Cause comuni: tag della release non ancora pubblicato, rete offline, o notarizzazione upstream ancora in corso. Riesegui l'installer quando la release e attiva."
MSG_WARN_CM042_EXTRACT_FAILED="Impossibile estrarre il tarball di Ostler RemoteCapture; LaunchAgent saltato."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Caricamento del LaunchAgent di Ostler RemoteCapture non riuscito. Vedi l'output sopra e ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  L'arricchimento delle conversazioni non sara disponibile. Il resto di Ostler si installa normalmente; riesegui senza --allow-plaintext per collegare il motore della memoria delle conversazioni."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="Installazione del motore della memoria delle conversazioni non riuscita (clone)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  Cercato in: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  Di solito significa che la .app dell'installer e stata costruita senza"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  il pacchetto cm048_pipeline incluso in"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Scarica di nuovo l'installer oppure"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  riesegui con --allow-plaintext per un'installazione dev/CI."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="Motore della memoria delle conversazioni non trovato. L'arricchimento delle conversazioni non puo funzionare senza di esso."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="Configurazione del motore della memoria delle conversazioni saltata (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="Sorgente del motore della memoria delle conversazioni risolta ma pyproject.toml manca; configurazione del venv saltata."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Avvio di Colima non riuscito. Provo Docker Desktop come ripiego..."
MSG_WARN_COLIMA_START_RETRY="Colima non si e avviato correttamente (il socket Docker non era pronto). Nuovo tentativo tra %ss..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="Cause comuni: tag v%s non ancora pubblicato, rete offline,"
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  stderr di consent_cli (primi 400 caratteri):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  Console script non creato in %s; in pyproject.toml potrebbe mancare la voce [project.scripts]."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="Continuo perche e stato passato --allow-plaintext."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="Continuo l'installazione. Riesegui \`ostler-fda\` dopo aver diagnosticato l'errore sopra."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="Continuo senza la precompilazione dalla scheda contatto: Ostler te lo chiedera invece."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  Le conversazioni inviate a iMessage falliranno silenziosamente finche"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="Impossibile modificare le impostazioni di stop. Attiva 'Impedisci lo stop automatico quando collegato all'alimentazione' in Impostazioni di Sistema > Energia."
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="Impossibile modificare le impostazioni di stop. Attiva 'Impedisci lo stop automatico' in Impostazioni di Sistema > Energia."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="Impossibile scaricare ostler-assistant v%s da %s"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="Impossibile estrarre la mbox di Gmail dallo zip di Takeout: saltato."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="Impossibile estrarre il tarball di ostler-assistant; LaunchAgent saltato."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="Impossibile trovare la CLI di Tailscale. Puoi configurarla manualmente piu tardi."
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Impossibile installare il pacchetto legal/ delle stringhe di consenso; continuo"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="Impossibile installare la directory LICENSES/ (non fatale)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="Impossibile installare ostler_security nel venv dell'Hub."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="Impossibile installare THIRD_PARTY_NOTICES.md (non fatale)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="Impossibile ottenere l'agente Doctor (sia bundle sia clone falliti)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="File di Ostler Doctor non trovati. Necessari per il flusso di abbinamento iOS (Ostler.app carica in iframe :8089/pair-ios)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  Cercato in: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  Di solito significa che la .app dell'installer e stata costruita senza"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  la sorgente doctor/agent/ inclusa in"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Scarica di nuovo l'installer oppure"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  riesegui con --allow-plaintext per un'installazione dev/CI."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Installazione di Doctor interrotta: necessaria per il flusso di abbinamento iOS. Scarica di nuovo l'installer oppure passa --allow-plaintext per un'installazione dev/CI."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="Impossibile ottenere gli script di acquisizione email (sia bundle sia clone falliti)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="Impossibile ottenere gli script hub-power (sia bundle sia clone falliti)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="Impossibile ottenere gli script di ricompilazione del wiki (sia bundle sia clone falliti)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="Impossibile aprire automaticamente l'URL del Chrome Web Store: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="Impossibile salvare region.json (continuo - Doctor lo segnalera)"
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="Impossibile salvare nel Portachiavi. Annotala."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="Impossibile avviare Ollama automaticamente."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="Impossibile aggiornare la pipeline (offline?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="Impossibile scrivere pipeline_signals.json. La diagnostica Doctor della Mail vuota usera valori predefiniti sicuri fino alla prossima installazione o ciclo."
MSG_WARN_CURL_SAID="Curl ha detto:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="Directory non trovata: %s: importazione saltata."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker non si e avviato entro %s secondi."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker e installato ma non in esecuzione. Sara necessario avviarlo."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama a meta installazione e bloccare le verifiche di prontezza."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  marker iniziali (i canali si stanno ancora connettendo + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="Installazione del LaunchAgent di email-ingest non riuscita. Vedi l'output sopra."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="Installazione del LaunchAgent del bridge iMessage non riuscita. Le risposte iMessage dell'utente-assistente non funzioneranno finche non riesegui l'installer o esegui INSTALL_SNIPPET.sh manualmente."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Script del bridge iMessage non inclusi ed e stato passato --allow-plaintext; l'installazione del LaunchAgent verra saltata. Le risposte iMessage dell'utente-assistente non funzioneranno."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="La cifratura non funzionera."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="La cifratura non funzionera, e"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="assicurati che il tag PWG_KNOWLEDGE_REPO fissato lo includa."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  permesso Events per Messages.app)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="L'estrattore FDA e uscito con codice diverso da zero (%s). Ultime 20 righe di output:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="Modulo di estrazione FDA non incluso in questo installer."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="Previsto in: Contents/Resources/ostler_fda/ (dentro la .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="Causa piu probabile: una regressione di build ha rimosso la copia vendor. Scarica di nuovo la .app da ostler.ai/install."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="Modulo di estrazione FDA non incluso. Continuo perche e stato passato --allow-plaintext: l'estrazione istantanea dei dati verra saltata."
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault NON e abilitato."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="Impossibile attivare il primo mese gratuito in questo momento; l'installazione continuera. Apri l'app iOS Companion una volta abbinata per risolvere."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="Full Disk Access non concesso a Terminal."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="%s GB di RAM rilevati. Avrai l'assistente compatto (gemma4:e2b): affidabile, accurato, sotto il secondo sulle domande brevi, con chiamate a strumenti e un onesto 'non lo so' quando non sa. Per risposte piu ricche su domande lunghe, 24 GB o piu sbloccano l'assistente standard (qwen3.5:9b). Puoi cambiare Mac piu tardi reinstallando."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="L'importazione GDPR ha avuto errori. Puoi rieseguirla con:"
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="L'importazione GDPR fa parte dell'installazione di produzione. Senza di essa, il tuo grafo sociale (LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google Calendar) non puo essere importato."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="L'importazione GDPR non sara disponibile su questa istanza finche la pipeline di importazione non viene reinstallata."
MSG_WARN_GIT_SAID="Git ha detto:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  Controllo di stato fallito: ostler-knowledge --version non ha prodotto output."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  Controllo di stato fallito: pwg-convo --help non e tornato correttamente."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="L'installer di Homebrew e uscito con %s. Seguono le ultime 30 righe di /tmp/ostler-brew-install.log:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Log di installazione Homebrew (coda) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="L'installazione pip di Doctor e uscita con %s. Seguono le ultime 30 righe di /tmp/ostler-doctor-pip.log:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Log di installazione pip di Doctor (coda) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="L'installazione pip della pipeline e uscita con %s. Seguono le ultime 30 righe di /tmp/ostler-pipeline-pip.log:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- Log di installazione pip della pipeline (coda) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Installazione del LaunchAgent hub-power non riuscita. Vedi l'output sopra."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="Script hub-power non trovati nel percorso del bundle previsto."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  Nella .app dell'installer sembra mancare vendor/hub_power/"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  in Contents/Resources/hub-power/. La limitazione adattiva alla batteria non verra installata; il resto dell'installazione continuera."
MSG_WARN_ICAL_SERVER_FAILED="Impossibile avviare l'API dell'assistente; gli endpoint dell'iOS Companion saranno limitati fino alla prossima esecuzione dell'installer."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - Download dell'immagine fallito (rete, spazio su disco o timeout del registry)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="Impossibile scrivere il segnale FDA di iMessage in pipeline_signals.json. La dashboard Doctor potrebbe non mostrare automaticamente la scheda del Full Disk Access."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="L'host IMAP e vuoto: riprova."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="Permesso di automazione iMessage: non concesso (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="Permesso di automazione iMessage: verifica inconcludente."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="Apertura di Impostazioni di Sistema > Privacy e Sicurezza > Automazione. Spunta la riga Messages per OstlerInstaller (o Terminal) per collegare l'invio di iMessage."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage ha bisogno di almeno un contatto consentito. Riprova oppure"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="Pipeline di importazione non disponibile (repo privato - solo beta tester)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="Pipeline di importazione non inclusa nell'installer. Hard-fail aggirato."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Pipeline di importazione non inclusa nell'installer. Questo e il percorso di installazione di produzione; il pacchetto Python contact_syncer dovrebbe essere incluso nella .app."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX significa che l'assistente leggera ogni email che ricevi."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Spazio su disco insufficiente per il volume di output del wiki"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Mac Intel rilevato: le prestazioni saranno limitate. Consigliato Apple Silicon."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s e un host di un provider cloud."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="JWT_SECRET in %s e nella banlist; rigenerazione per mantenere importabili i servizi del grafo di conoscenza"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="JWT_SECRET in %s e troppo corto (%s < %s caratteri); rigenerazione"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="Repo Knowledge clonato ma pyproject.toml manca; configurazione del venv saltata."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="Installazione del servizio Knowledge non riuscita (clone)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="Licenza: %s e distribuito sotto i Gemma Terms of Use di Google, non Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="Le installazioni su MacBook ne hanno bisogno per la gestione di batteria / stop."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="Il permesso Contatti di macOS e stato rifiutato o non ancora concesso."
MSG_WARN_MACOS_OUTDATED_WE_RECOMMEND_MACOS_13="macOS %s e obsoleto. Consigliamo macOS 13 (Ventura) o successivo."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS NON lo chiedera da uno script: devi concederlo manualmente."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Le installazioni su Mac Mini non sono interessate; gli utenti MacBook dovrebbero riprovare."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="I dati della posta sono comunque acquisibili manualmente:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  Ritentativo manuale: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  Ritentativo manuale una volta risolta la causa:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Ne Apple Mail ne IMAP personalizzato selezionati: imposto Apple Mail come predefinito."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="Nessuna passkey impostata; i database non verranno cifrati."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="Le passphrase non coincidono. Riprova."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="Configurazione della passphrase non riuscita. Output:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="Input vuoto. Passphrase saltata."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="La passphrase deve avere almeno 12 caratteri. Riprova."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="E necessaria una passphrase per cifrare i tuoi dati."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="Il numero deve iniziare con +. Riprova."
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama non risponde"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s fallito (tentativo %s/3). Nuovo tentativo tra %ss..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="Solo %s GB liberi. Consigliamo almeno 35 GB (immagini Docker + modello IA + dati)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="A batteria, il LaunchAgent hub-power (passaggio 3.14) potrebbe mettersi in pausa"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="oppure riesegui l'installer e scegli un'opzione di canale diversa."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="o in anticipo rispetto alla pipeline di rilascio della Fase B. Riesegui l'installer una volta che il"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor ha segnalato %s errore/i."
MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant estratto ma il controllo --version e fallito."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Installazione del LaunchAgent dell'assistente Ostler non riuscita dopo 3 tentativi. Output diagnostico sopra + sotto."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Tentativo %s di installazione del LaunchAgent dell'assistente Ostler fallito; nuovo tentativo."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="Stderr completo del daemon in: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="Ultimo stderr dello snippet:"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s e solo per Apple Silicon (rilevato: %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - immagine ostler-wiki-compiler non ancora scaricabile (registry non collegato)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph non risponde"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph non ancora in salute in questa fase (controlla i log sopra)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="Le password non coincidono (o erano vuote). Riprova."
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="La Fase 3 richiede 10-15 minuti di download di Docker + Ollama."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  installazione pip fallita; il motore della memoria delle conversazioni non sara disponibile."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  installazione pip fallita; email-ingest ripieghera sul python di sistema (potrebbe fallire anche a runtime)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  installazione pip fallita; ostler-knowledge non sara disponibile."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  installazione pip fallita; motore di acquisizione email non disponibile. Il LaunchAgent orario emettera comunque i file mbox ma non potra acquisirli nel grafo finche non viene riparato."
MSG_WARN_CM021_SOURCE_NOT_FOUND="Sorgente del motore di acquisizione email non trovata nella .app; il job orario in background salvera i file di posta senza acquisirli."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="sorgente ostler_fda non trovata nella .app; il LaunchAgent di email-ingest ripieghera sul python di sistema a runtime."
MSG_WARN_PIP_SAID="pip ha detto:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="Collega all'alimentazione per l'installazione completa."
MSG_WARN_PORT_1_ALREADY_USE_PID="La porta %s e gia in uso da %s (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - Porta 3000 gia in uso da un altro servizio"
MSG_WARN_POWER_SOURCE="Alimentazione: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="Installazione di sqlcipher3 fallita."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="Installazione di sqlcipher3 fallita. I database non verranno cifrati."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="Python 3 non trovato. Installazione di Python 3.12..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s e troppo vecchio (serve 3.10+). Installazione di Python 3.12..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant non risponde"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         Leggi https://ai.google.dev/gemma/terms prima dell'uso commerciale."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="Leggi la versione pubblica su https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis non risponde"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="rilascio arriva, oppure predisponi il binario manualmente:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="Riesecuzione: digita un host self-hosted, oppure premi Ctrl-C e riavvia scegliendo Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="riesegui l'installer con iMessage deselezionato per saltarlo."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="ESECUZIONE CON --allow-plaintext: cifratura disabilitata. NON PER LA PRODUZIONE."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  Esegui \`%s doctor\` dopo il primo avvio"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="Esegui 'tailscale ip --4' una volta effettuato l'accesso, poi aggiungi l'indirizzo nell'app iOS."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Copia dell'estensione Safari fallita; puoi installarla manualmente piu tardi"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="Modulo di sicurezza non trovato. La configurazione della passkey verra saltata."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  Cercato in: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  Di solito significa che la .app dell'installer e stata costruita senza"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  il pacchetto ostler_security incluso in"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Scarica di nuovo l'installer oppure"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  riesegui con --allow-plaintext per un'installazione dev/CI."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="Configurazione della sicurezza fallita. Continuo senza cifratura del database."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="Configurazione della sicurezza fallita. Output:"
MSG_WARN_SEE_STDERR_FRAGMENT="  Vedi %s per il frammento di stderr."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="Installazione del binario saltata. Il config.toml scritto dalla procedura guidata resta al suo posto."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Installazione del LaunchAgent di Doctor saltata."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="Installazione del LaunchAgent di email-ingest saltata."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="Installazione del LaunchAgent saltata. Le installazioni su Mac Mini non sono interessate."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="Installazione del LaunchAgent saltata. Prova: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="Installazione del LaunchAgent di wiki-recompile saltata."
MSG_WARN_SOME_FEATURES_MAY_NOT_WORK_CORRECTLY="Alcune funzioni potrebbero non funzionare correttamente sulle versioni piu vecchie."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="Alcune porte sono in uso. I container Docker potrebbero non avviarsi."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="Ferma i servizi in conflitto o cambia le porte in docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscale non ha effettuato l'accesso entro 3 minuti. Puoi tornarci piu tardi dalle Impostazioni."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="L'IP di Tailscale e stato scritto in .env ma una lettura successiva non l'ha trovato. L'iOS Companion potrebbe non rilevarlo: riesegui install.sh --repair se succede."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="Installazione di Tailscale fallita: puoi installarlo piu tardi da tailscale.com"
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="i servizi installati si rifiutano di avviarsi senza di essi."
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  questo viene risolto. Vedi il banner dei passi successivi per la soluzione."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  da ispezionare. cron-delivery / imessage-tcc sono comuni"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  Prova: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  Prova: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="Scelta '%s' non riconosciuta; imposto iMessage + email come predefinito."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="Scelta non riconosciuta. Uso Consigliata."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  Aggiornamento fallito; continuo con il checkout esistente."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="Usa Apple Mail (consigliato sopra) per quell'account: Ostler non memorizza mai le password cloud."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="Uso INBOX. L'assistente leggera ogni email in arrivo."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="Il container di Vane si e avviato ma http://localhost:3000 non ha risposto entro 60s."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane (ricerca web locale) non si e avviato. Cause comuni:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  La ricerca web e opzionale; il resto di Ostler funziona senza di essa."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="Consigliamo vivamente invece un'etichetta/cartella dedicata."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp ha bisogno di un numero di telefono per la consegna dei brief. Riprova,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="Wiki compilato ma il container wiki-site non si e avviato."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="Prima compilazione del wiki fallita. Cause comuni:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="Impossibile caricare il LaunchAgent di recupero del wiki del primo giorno. La ricostruzione giornaliera del wiki viene comunque eseguita; il tuo wiki si aggiornera semplicemente il giorno dopo anziche entro l'ora."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Installazione del LaunchAgent di wiki-recompile non riuscita. Vedi l'output sopra."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="Il wiki non si aggiornera automaticamente; la ricostruzione manuale resta disponibile:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="La configurazione della procedura guidata resta al suo posto; il binario resta predisposto. Ritentativo manuale:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="Il tuo assistente ha bisogno di un nome. Scegli tra i suggerimenti sopra o digita il tuo."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="Puoi riconcederlo in Impostazioni di Sistema > Privacy e Sicurezza > Contatti."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="Puoi eseguire la configurazione della sicurezza piu tardi: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="Potrebbe essere necessario installarlo manualmente: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  effettivo: %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="Il bundle di Ostler RemoteCapture non era presente in %s dopo l'estrazione. Il tarball della release potrebbe essere malformato."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify ha segnalato:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  Rifiuto di predisporre un bundle che non corrisponde al checksum pubblicato."
MSG_ERR_CM042_SHA_256_MISMATCH="Mancata corrispondenza SHA-256 del tarball di Ostler RemoteCapture."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess ha segnalato:"
MSG_ERR_CM042_VERIFY_FAILED="Verifica della firma / notarizzazione di Ostler RemoteCapture non riuscita."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv ha segnalato:"
MSG_ERR_EXPECTED="  previsto:  %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief ha segnalato: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="Il binario ostler-assistant in %s non e un eseguibile Mach-O."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="Mancata corrispondenza SHA-256 del tarball di ostler-assistant."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  Rifiuto di predisporre un binario che non corrisponde al checksum pubblicato."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="Rifiuto di rimuovere la quarantena o di caricare il LaunchAgent."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="Riesegui l'installer una volta corretto il tarball upstream."
MSG_ERR_URL="  url:       %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="I Mac Intel non sono supportati nella v1.0. E richiesto Apple Silicon (M1, M2, M3 o M4). Il supporto Intel arrivera nella v1.0.1."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="Sono richiesti almeno 16 GB di RAM. Tu ne hai %s GB. Consigliati 24 GB."
MSG_FAIL_CM042_SIGNATURE_FAILED="Installazione di Ostler RemoteCapture interrotta: controllo della firma o della notarizzazione fallito. Il bundle e stato lasciato in /Applications per l'assistenza. Scrivi a support@ostler.ai e riesegui l'installer."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="Impossibile scaricare %s dopo 3 tentativi. Controlla la rete e riesegui l'installer."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="Impossibile scaricare nomic-embed-text dopo 3 tentativi. Controlla la rete e riesegui l'installer."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker non disponibile. Riesegui l'installer per installare Colima."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="Il modulo di estrazione FDA manca dal bundle dell'installer. Scarica di nuovo la .app da ostler.ai/install, oppure riesegui con --allow-plaintext per dev/CI."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Installazione delle dipendenze di Doctor fallita. Output completo salvato in /tmp/ostler-doctor-pip.log: allegalo quando scrivi a support@ostler.ai (Riferimento: ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="Installazione delle dipendenze della pipeline di importazione fallita. Output completo salvato in /tmp/ostler-pipeline-pip.log: allegalo quando scrivi a support@ostler.ai (Riferimento: ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Installazione di Homebrew fallita. Output completo salvato in /tmp/ostler-brew-install.log: allegalo quando scrivi a support@ostler.ai."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="Installazione della pipeline di importazione fallita. Il bundle contact_syncer e richiesto per l'installazione di produzione. Riesegui con --allow-plaintext per dev/CI, oppure scarica di nuovo l'installer e riprova."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="Serve l'accesso sudo per disattivare lo stop + installare Homebrew. Riesegui quando sei pronto."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Ne Colima ne Docker Desktop sono riusciti ad avviarsi. Installa Docker Desktop e riesegui."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="Spazio su disco insufficiente (%s GB). Libera spazio e riprova."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="Nessuna passkey impostata e nessuna configurazione di sicurezza esistente. Riesegui con --allow-plaintext per dev/CI, oppure riesegui l'installer e conferma l'informativa Touch ID."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="Il motore della memoria delle conversazioni e richiesto. Riesegui con --allow-plaintext per dev/CI, oppure correggi il bundle mancante sopra e riprova."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="Installazione di ostler_security fallita. Riesegui con --allow-plaintext per dev/CI, oppure correggi l'errore pip sopra e riprova."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="Configurazione della passkey fallita. Riesegui con --allow-plaintext per dev/CI, oppure correggi l'errore sopra e riprova."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="sqlcipher3 e richiesto per i database cifrati. Riesegui con --allow-plaintext per dev/CI, oppure correggi l'errore pip sopra e riprova."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Questo installer e solo per macOS. Il supporto Linux arrivera presto."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="L'installazione degli Xcode Command Line Tools non si e completata in 10 minuti. Esegui 'xcode-select --install' manualmente, accetta la finestra, poi riesegui questo installer."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="L'installazione di Homebrew ha segnalato successo ma /opt/homebrew/bin/brew manca. Controlla %s per la trascrizione completa. Ripristino: apri Terminal ed esegui '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' poi riesegui l'installer."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew e installato in /opt/homebrew/bin/brew ma il comando 'brew' non e nel PATH dopo l'eval di shellenv. Apri un nuovo Terminal e riesegui l'installer."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' ha segnalato successo ma colima non e nel PATH. Controlla %s per gli errori di Homebrew. Ripristino: apri Terminal ed esegui 'brew install colima docker docker-compose' manualmente, poi riesegui l'installer."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' ha segnalato successo ma la CLI docker non e nel PATH. Controlla %s. Ripristino: 'brew install docker' manualmente poi riesegui l'installer."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="L'installazione dell'app Ollama ha segnalato successo ma il suo binario manca in /Applications/Ollama.app. Controlla %s. Ripristino: 'brew install --cask ollama-app' manualmente poi riesegui l'installer."
MSG_FAIL_EMBED_HEALTHCHECK="Ollama e in esecuzione ma il modello di embedding non ha restituito alcun vettore (HTTP diverso da 200, o un risultato vuoto). La scheda Persone, la ricerca e la navigazione sarebbero tutte vuote. Controlla %s. Ripristino: assicurati che l'app Ollama (non la formula Homebrew) sia installata e attiva, poi riesegui l'installer."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' ha segnalato successo ma sqlcipher non e nel PATH. Controlla %s. Ripristino: 'brew install sqlcipher' manualmente poi riesegui l'installer."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' non ha prodotto /Applications/Tailscale.app. Controlla %s. Ripristino: scarica Tailscale da https://tailscale.com/download/macos e trascinalo in /Applications, poi riesegui l'installer."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' ha segnalato successo ma il binario python3.11 manca in /opt/homebrew/opt/python@3.11/bin/python3.11. Controlla %s. Ripristino: 'brew reinstall python@3.11' poi riesegui l'installer."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="Abbiamo trovato le tue risposte precedenti"
MSG_PROMPT_REUSE_SETTINGS_HELP="Abbiamo rilevato un precedente tentativo di installazione su questo Mac. Le domande a cui hai gia risposto (nome, nome dell'assistente, fuso orario, prefisso paese, canali e cosi via) verranno riutilizzate cosi non dovrai reinserirle. Scegli Si per continuare da dove eri rimasto, o No per ripercorrere le domande dall'inizio."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Risposte precedenti trovate: nome = %s, assistente = %s, fuso orario = %s."

MSG_PROMPT_PERMS_OK_TITLE="Pronto a continuare?"
MSG_PROMPT_PERMS_OK_HELP="macOS chiedera l'accesso a Contatti e a File e cartelle. Il Full Disk Access opzionale puo essere concesso piu tardi."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Nome completo (come appare nei tuoi contatti)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Nome completo (es. Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="Come dovrebbe chiamarti il tuo assistente?"
MSG_PROMPT_USER_ID_HELP="Un nome breve che il tuo assistente usera per rivolgersi a te (es. 'Andy', 'Andrew', 'Sig.ra Smith'). E quello che appare nei tuoi brief mattutini e nelle risposte in chat. Diverso dal tuo nome completo qui sopra."

MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="Installazione (puo richiedere un po': sentiti libero di andare via)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="Usare +%s?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Inserisci il prefisso paese (es. 44 per UK, 1 per US)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Prefisso paese predefinito"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Usato per normalizzare i numeri di telefono durante l'importazione dei contatti e per impostare la tua regione (UK / UE / US / altro) per i valori predefiniti di conformita legale."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="Abbiamo rilevato +%s. Usarlo per il tuo Hub?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Rilevato dal tuo numero di telefono qui sopra. Scegli Si per usarlo, o No per inserire un prefisso paese diverso."

MSG_PROMPT_TZ_CONFIRM_TITLE="Usare questo fuso orario?"
MSG_PROMPT_TZ_CONFIRM_HELP="Fuso orario rilevato: %s"
MSG_PROMPT_USER_TZ_TITLE="Inserisci il fuso orario (es. Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="Come vorresti chiamare il tuo assistente?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="Il nome nel campo e un suggerimento casuale: sovrascrivilo con quello che preferisci. Marvin, Samantha, Joshua, Friday, Athena, Sage e Rosie sono tutte scelte popolari." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Digita qualsiasi nome ti piaccia: il suggerimento e solo un punto di partenza."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="Come ti raggiungera il tuo assistente?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Scegli i canali di messaggistica che vorresti far usare al tuo assistente. Puoi cambiarli piu tardi nella sezione Doctor dell'app."

MSG_PROMPT_WHATSAPP_CONSENT_TITLE="Abilitare la messaggistica WhatsApp per il tuo assistente?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web e un servizio di terze parti. Abilitandolo, accetti che i tuoi messaggi passino attraverso l'infrastruttura di WhatsApp prima di raggiungere la tua istanza locale di Ostler, e che WhatsApp (Meta Platforms Ireland Ltd) possa sospendere, limitare o chiudere il tuo account WhatsApp a causa dell'uso automatizzato. Puoi disabilitarlo piu tardi dalle Impostazioni."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="Il tuo numero di telefono WhatsApp"
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Numero internazionale con il prefisso paese, es. +44 7700 900123. Solo cifre e un + iniziale: niente spazi, parentesi o trattini."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Consenti a Ostler di leggere i tuoi Messages"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="Impostazioni di Sistema e aperto su Full Disk Access."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Trova \"Ostler\" e attivalo."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="Clicca Fine quando hai finito."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Fine"

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Consenti a Ostler di leggere i dati del tuo Mac"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="Impostazioni di Sistema e aperto su Full Disk Access."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Trova \"OstlerInstaller\" nell'elenco e attivalo."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Clicca Fine quando hai finito e Ostler leggera la tua cronologia di Safari, le Note, gli iMessage e Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Fine"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="Prossimo passo: Full Disk Access per l'installer"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="Ora macOS ti chiedera di concedere il Full Disk Access a OstlerInstaller."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Dopo aver attivato l'interruttore, macOS mostrera una finestra che ti chiede di scegliere 'Esci e riapri' o 'Piu tardi'."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Clicca Esci e riapri. L'installer si riavviera da solo e continuera automaticamente da questo passaggio."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="OK"
MSG_INFO_INSTALLER_FDA_PREWARN="Ti spiego il flusso di concessione del Full Disk Access..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="Apertura di Impostazioni di Sistema cosi puoi concedere il Full Disk Access all'installer..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="Full Disk Access concesso all'installer. Lettura di Safari, Note, iMessage e Mail in corso."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="Full Disk Access ancora non concesso. Continuo senza; puoi rieseguire l'installer piu tardi per estrarre Safari / Note / iMessage."

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="Contatti consentiti"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="Persone fidate: numeri di telefono ed email Apple ID (separati da virgola). %s risponde solo alle persone in questo elenco; i messaggi di chiunque altro vengono ignorati. E richiesta almeno una voce.

Per esempio:
+447700900000, tu@esempio.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="Leggere la posta tramite Apple Mail?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Legge qualsiasi account email che hai aggiunto ad Apple Mail (iCloud, Gmail, Outlook, ecc.) usando il Full Disk Access. Nessuna password memorizzata. Consigliato per quasi tutti."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="Aggiungere un account di posta ad Apple Mail?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="Apple Mail non ha ancora account connessi su questo Mac, quindi Ostler non avra posta da leggere. Scegli Si per aprire ora Impostazioni di Sistema > Account Internet (puoi aggiungere iCloud, Gmail o Outlook). Scegli No per saltare; puoi aggiungere un account piu tardi e Doctor mostrera un promemoria se non arriva posta entro 24 ore."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="Recuperare l'intera cronologia di Apple Mail?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Per impostazione predefinita Ostler legge gli ultimi cinque anni di Apple Mail. Se su questo Mac ne conservi di piu e vuoi tutto nel tuo grafo di conoscenza, scegli Si per recuperare ora l'intera cronologia locale (per una casella grande puo richiedere un po' piu di tempo). Scegli No per mantenere la finestra di cinque anni; puoi sempre estenderla piu tardi da Doctor."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="Configurare anche un server IMAP+SMTP personalizzato?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="Solo per caselle self-hosted. Lascia su NO se i tuoi account sono con Gmail, iCloud o Outlook: quelli funzionano meglio tramite Apple Mail qui sopra."

MSG_PROMPT_IMAP_HOST_TITLE="Host IMAP"
MSG_PROMPT_IMAP_HOST_HELP="Solo server IMAP self-hosted o personalizzato. Usa Apple Mail (sopra) per Gmail / iCloud / Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="Porta IMAP"

MSG_PROMPT_SMTP_HOST_TITLE="Host SMTP"
MSG_PROMPT_SMTP_PORT_TITLE="Porta SMTP"

MSG_PROMPT_EMAIL_USERNAME_TITLE="Indirizzo email (usato anche come username IMAP/SMTP)"

MSG_PROMPT_EMAIL_PASSWORD_TITLE="Password (nascosta)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Password per il tuo server IMAP/SMTP self-hosted. Memorizzata localmente in ~/.ostler/: mai inviata a Creative Machines."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Conferma Password"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="Quale cartella dovrebbe controllare l'assistente?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="Consigliato: un'etichetta o cartella dedicata (es. Ostler). Leggeremo solo i messaggi li, lasciando intatta la tua casella di posta principale."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="Digita di nuovo INBOX per confermare, o premi Continua per usare 'Ostler'"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX significa che l'assistente leggera ogni email che ricevi. Consigliamo vivamente invece un'etichetta/cartella dedicata."

MSG_PROMPT_EXPORTS_ACK_TITLE="Hai richiesto i tuoi export di dati?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler importa da circa 20 piattaforme. L'elenco completo, con link diretti alla pagina di richiesta di ciascun provider, e su docs.ostler.ai/data-exports.

La maggior parte degli archivi impiega da 1 a 3 giorni per arrivare via email. Quando gli ZIP arrivano, mettili nella tua cartella Download e Ostler li trovera automaticamente.

Salta quelli che non usi; puoi sempre importarne altri piu tardi."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="Continuare senza FileVault?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="FileVault e fortemente consigliato. Senza di esso, l'accesso fisico al tuo Mac significa accesso ai tuoi dati."

MSG_PROMPT_PASSKEY_ACK_TITLE="Pronto a configurare la cifratura del disco"
MSG_PROMPT_PASSKEY_ACK_HELP="Il tuo grafo di conoscenza viene cifrato con una passphrase che scegli nella schermata successiva. Digiterai questa passphrase ogni volta che avvii l'interfaccia dell'Hub. Viene inoltre generata una chiave di recupero separata, mostrata una sola volta alla fine dell'installazione. Premi Continua quando sei pronto."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="Impostare anche una passphrase di recupero? (consigliato)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="Scegli la tua passphrase"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="Questa passphrase cifra il tuo grafo di conoscenza e sblocca l'interfaccia dell'Hub a ogni avvio. Almeno 12 caratteri. Non possiamo recuperarla per te. Si consiglia di conservarla in un gestore di password."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="Conferma la tua passphrase"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="Reinserisci la stessa passphrase per confermare."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="Importarli durante l'installazione?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="Gli export GDPR trovati verranno importati nel tuo grafo di conoscenza durante l'installazione."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="Hai degli export di dati pronti?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler puo importare archivi di social media e piattaforme - la tua intera storia con amici, familiari, luoghi, opinioni - fin dall'inizio. Piu cose Ostler sa il primo giorno, piu e utile il primo giorno. Puoi anche aggiungerli piu tardi; nessuna fretta.

Richiedi l'export dei tuoi dati da ciascuna piattaforma (Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp, ecc.), scarica i file ZIP e mettili nella tua cartella Download.

Ostler cerchera in ~/Downloads per impostazione predefinita. Vuoi una cartella diversa? Scegline una qui sotto. Altrimenti, salta e importa piu tardi."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="Importare i messaggi Gmail da questo Takeout?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Legge i contenuti Gmail direttamente dal file Takeout. Google non vede mai Ostler."

MSG_PROMPT_FDA_PRESET_TITLE="Da quali sorgenti del Mac dovrebbe imparare Ostler?"
MSG_PROMPT_FDA_PRESET_HELP="Tre preset, oppure scegli ognuna tu stesso. Le sorgenti sensibili (riconoscimento facciale) sono disattivate per impostazione predefinita in ogni preset: scegline una deliberatamente se le vuoi."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="Consigliata. Include Apple Mail, Contatti, Calendario, Note, Messages, Promemoria, cronologia di Safari e segnalibri di Safari. La cronologia di WhatsApp Desktop e la cronologia di Chrome vengono aggiunte automaticamente quando l'app e installata. Esclude i dati di riconoscimento facciale di Foto e qualsiasi archivio di export di terze parti."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="Tutto. Consigliata + eventi di Foto (nessun riconoscimento facciale). Il riconoscimento facciale di Foto resta disattivato finche non lo spunti deliberatamente."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="Personalizza. Scegli ogni sorgente nella schermata successiva. Le sorgenti sensibili restano disattivate finche non le spunti."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="Attiva o disattiva questa sorgente di dati."

MSG_PROMPT_CONSENT_ARTICLE_9_TITLE="La tua decisione (S / N)"
MSG_PROMPT_CONSENT_ARTICLE_9_HELP="Consenso per dati di categoria particolare ai sensi dell'Articolo 9 (UK GDPR). Richiesto per la base giuridica del trattamento."

MSG_PROMPT_CONSENT_VOICE_EU_TITLE="Riconoscere le voci nelle tue registrazioni di chiamate?"
MSG_PROMPT_CONSENT_VOICE_EU_HELP="Il riconoscimento del parlante resta su questo Mac. Creative Machines non riceve mai le impronte vocali."

MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE="Un'ultima cosa: come funzionano i dati di terze parti"
MSG_PROMPT_CONSENT_THIRD_PARTY_HELP="Qualsiasi dato che importi da terze parti (Google Takeout, download di Meta, export di LinkedIn, ecc.) resta su questo Mac. Ostler lo memorizza nel tuo grafo di conoscenza locale; nulla lascia il tuo dispositivo.

Continuando comprendi e accetti di essere l'unico responsabile del trattamento e della conservazione di questi dati sulla tua macchina, proprio come i messaggi email gia presenti sul tuo disco rigido.

Nota legale: Per i record che importi su questo Mac, sei il titolare e il responsabile del trattamento ai sensi del diritto del Regno Unito e dell'UE (UK GDPR Articolo 4(7) e 4(8)). Creative Machines non riceve mai questi dati e non e il titolare. Il tuo trattamento per scopi personali e domestici rientra nell'Articolo 2(2)(c) del GDPR UK/UE.

Leggi di piu su docs.ostler.ai/privacy/third-party-data."

MSG_PROMPT_CONSENT_INSTALL_TITLE="Pronto a installare?"
MSG_PROMPT_CONSENT_INSTALL_HELP="Digita INSTALL per confermare che accetti i termini."
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Digita INSTALL"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Installa Ostler"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Annulla"
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Digita INSTALL esattamente (le maiuscole non contano) per confermare, oppure clicca Annulla per tornare indietro."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="Connetti il tuo iPhone e il tuo Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale da a questo Mac un indirizzo privato stabile che il tuo iPhone e il tuo Watch possono raggiungere da ovunque: cifrato, senza esposizione pubblica."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="Salvare la chiave di recupero nel Portachiavi?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="Memorizza la tua chiave di recupero della cifratura nel Portachiavi di macOS per maggiore sicurezza."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="Idratazione del tuo grafo"
MSG_HYDRATE_CONTACTS_STARTED="Importazione dei tuoi contatti nel grafo"
MSG_HYDRATE_CONTACTS_DONE="Importati %s contatti"
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="Caricamento dei tuoi ultimi 90 giorni di calendario (la cronologia piu lunga viene recuperata in background)"
MSG_HYDRATE_CALENDAR_DONE="Importati %s eventi"
MSG_HYDRATE_WIKI_RECOMPILE="Costruzione del tuo wiki. Ostler sta scrivendo un breve riepilogo per ciascuna delle tue persone, organizzazioni e argomenti chiave, quindi su una rubrica grande questo puo richiedere da pochi minuti fino a circa un'ora. Succede una sola volta, viene eseguito interamente sul tuo Mac, ed e sicuro lasciarlo in corso."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="Controllo del tuo indice di ricerca (%s collezioni rilevate)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="Caricamento della tua cronologia di navigazione nell'indice di ricerca"
MSG_INITIAL_HYDRATE_QDRANT_READY="Indice di ricerca pronto (%s collezioni)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="L'indice di ricerca si popolera in background al termine dell'installazione"
MSG_HYDRATE_DONE="Il tuo grafo e pronto: %s persone, %s eventi"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud potrebbe ancora sincronizzare i tuoi contatti: riesporto ora per recuperare quanto appena arrivato."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="Nessun contatto trovato nella tua app Contatti (locale o iCloud). Aggiungine qualcuno a Contatti e riesegui dalle Impostazioni."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="Nessun contatto iCloud da importare. Puoi aggiungerlo piu tardi dalle Impostazioni."
MSG_HYDRATE_SKIPPED_NO_EVENTS="Nessun evento di calendario negli ultimi 5 anni. Puoi recuperarlo piu tardi dalle Impostazioni."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="Lettura dei tuoi ultimi 90 giorni di email: le tue email restano su questo Mac (la cronologia piu lunga viene recuperata in background)"
MSG_HYDRATE_EMAIL_DONE="Trovate %s persone nelle tue email recenti"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="Nessuna email recente da leggere. Puoi aggiungere un account Mail in Apple Mail e rieseguire piu tardi."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="Lettore di email non ancora pronto. Puoi aggiungere un account Mail in Apple Mail e rieseguire piu tardi."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="Le email si stanno ancora caricando in background: il tuo wiki si riempira nel corso della prossima ora."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="Aprire Apple Mail cosi puo iniziare a sincronizzare?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="Hai %s account di posta configurato/i, ma Apple Mail non ha ancora scaricato alcun messaggio. Possiamo aprire ora Mail.app e attendere mentre sincronizza."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="Aprire Calendario cosi puo iniziare a sincronizzare?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="Hai %s account di calendario configurato/i, ma Calendario.app non ha ancora eventi memorizzati. Possiamo aprire ora Calendario e attendere mentre sincronizza da iCloud."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="Aprire Contatti cosi puo iniziare a sincronizzare?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="Hai %s account di contatti configurato/i, ma Contatti.app non ha ancora voci memorizzate. Possiamo aprire ora Contatti e attendere mentre sincronizza da iCloud."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="Attesa che %s inizi a sincronizzare (fino a %s secondi)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="Attesa della sincronizzazione di %s ancora in corso (%ss trascorsi, %ss rimanenti). La prima sincronizzazione di iCloud puo richiedere alcuni minuti su un accesso nuovo."
MSG_OK_APP_HAS_POPULATED="%s ha popolato il suo archivio locale. Proseguo."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="Non abbiamo rilevato la sincronizzazione di %s entro la finestra di attesa. Proseguo; puoi rieseguire l'idratazione dalle Impostazioni piu tardi."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="Account Apple Mail visibili: %s. Apri Mail.app una volta cosi puo iniziare a scaricare i messaggi."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="Account di calendario visibili: %s. Apri Calendario.app una volta cosi puo sincronizzare i tuoi eventi."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="Account di contatti visibili: %s. Apri Contatti.app una volta cosi puo sincronizzare la tua rubrica."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="Impossibile leggere i tuoi Contatti. Ostler li legge tramite il Full Disk Access - concedilo in Impostazioni di Sistema > Privacy e Sicurezza > Full Disk Access, poi riesegui l'idratazione dalle Impostazioni. Continueremo a riprovare in background."
MSG_HYDRATE_CONTACTS_PENDING="La tua app Contatti non ha ancora sincronizzato. Apri Contatti una volta, attendi che sincronizzi, poi riesegui l'idratazione dalle Impostazioni."
MSG_HYDRATE_CONTACTS_READ_FAILED="I tuoi contatti sono su questo Mac ma Ostler ne ha importati 0, il che e inatteso. L'importazione riprovera automaticamente in background. Se persiste, riesegui l'idratazione dalle Impostazioni o controlla il log di installazione."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler continuera a controllare in background e importera i tuoi contatti automaticamente una volta che iCloud avra finito di sincronizzare."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="Nuovi contatti importati; ricostruzione del tuo wiki in background."
MSG_HYDRATE_CALENDAR_PENDING="La tua app Calendario non ha ancora sincronizzato gli eventi. Apri Calendario una volta, attendi che sincronizzi, poi riesegui l'idratazione dalle Impostazioni."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="Impossibile leggere il tuo calendario questa volta (l'estrattore ha segnalato un errore, non un calendario vuoto). Gli altri tuoi dati non sono stati interessati; vedi /tmp/ostler-hydrate-calendar.log, poi riesegui l'idratazione dalle Impostazioni."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="Lettura della tua cronologia WhatsApp: i tuoi messaggi restano su questo Mac"
MSG_HYDRATE_WHATSAPP_DONE="Trovate %s persone nelle tue chat WhatsApp"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="Nessuna chat WhatsApp da leggere. Puoi rieseguire piu tardi dalle Impostazioni."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktop non e installato. Installalo dal Mac App Store e riesegui dalle Impostazioni."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="Lettore di WhatsApp non ancora pronto. Puoi rieseguire piu tardi dalle Impostazioni."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp si sta ancora caricando in background: il tuo wiki si riempira nel corso della prossima ora."

# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="Importazione della tua cronologia di navigazione: le tue visite restano su questo Mac"
MSG_HYDRATE_BROWSING_DONE="Importate %s pagine di cronologia di navigazione"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="Saltate %s pagine contrassegnate come sensibili (bancarie, mediche, ecc.)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="Nessuna cronologia di navigazione da importare. Puoi rieseguire piu tardi dalle Impostazioni."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="Lettore della cronologia di navigazione non ancora pronto. Puoi rieseguire piu tardi dalle Impostazioni."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="La cronologia di navigazione si sta ancora caricando in background: il tuo wiki si riempira nel corso della prossima ora."

# Preferences import counts-only confirmation, shown by phase 3.12b after
# the shared ostler-import fan-out runs. The other hydrate_preferences
# strings were removed when the standalone block was collapsed into the
# shared importer; only this done-count line is still referenced.
# Privacy: enrich's lookup clients call PUBLIC item-metadata APIs only
# (about the item, never the user); this string is a count.
MSG_HYDRATE_PREFERENCES_DONE="Importate e arricchite %s preferenze"

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="Configurazione dell'arricchimento delle preferenze (una tantum)"
MSG_CM019_SETUP_DONE="Arricchimento delle preferenze pronto"
MSG_CM019_SETUP_FAILED="La configurazione dell'arricchimento delle preferenze non si e completata. Le tue pagine delle preferenze si riempiranno una volta risolto; il resto di Ostler non e interessato."
MSG_CM019_SETUP_EXISTS="Arricchimento delle preferenze gia configurato"
MSG_CM019_SETUP_SKIPPED="Pipeline di arricchimento delle preferenze non inclusa; saltata per ora."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="Lettura della tua cronologia iMessage: i tuoi messaggi restano su questo Mac"
MSG_HYDRATE_IMESSAGE_DONE="Trovate %s persone nella tua cronologia iMessage"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="Nessuna cronologia iMessage da leggere. Puoi rieseguire piu tardi dalle Impostazioni."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="Lettore di iMessage non ancora pronto. Puoi rieseguire piu tardi dalle Impostazioni."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage si sta ancora caricando in background: il tuo wiki si riempira nel corso della prossima ora."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="Indicizzazione delle tue persone per la ricerca"
MSG_HYDRATE_PEOPLE_DONE="Indicizzate %s persone per la ricerca"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="Nessuna persona da indicizzare per ora. Puoi rieseguire piu tardi dalle Impostazioni."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="Indicizzatore delle persone non ancora pronto. Puoi rieseguire piu tardi dalle Impostazioni."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="Sto ancora indicizzando le tue persone in background; la ricerca si riempira a breve."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="In arrivo tre richieste di accesso alle cartelle"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="La finestra di installazione dei Command Line Tools e apparsa davanti a questa finestra: clicca Installa su di essa, poi torna qui (o attendi qualche secondo, riporteremo questa finestra in primo piano per te). Gli strumenti si scaricano in background mentre continui a rispondere alle domande qui sotto; nulla qui e bloccato."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="Permesso necessario: automazione iMessage"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostler chiedera ora a macOS il permesso di comunicare con Messages.app. macOS mostrera un popup che dice \"OstlerInstaller vuole accedere per controllare Messages\": clicca Consenti cosi l'assistente puo inviare e ricevere iMessage per tuo conto. Senza questo permesso i messaggi iMessage non lasceranno mai silenziosamente la macchina. E una concessione una tantum; puoi modificarla piu tardi in Impostazioni di Sistema > Privacy e Sicurezza > Automazione."

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
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="Annotala o stampala ora. E l'unico modo per rientrare se perdi la tua passphrase E il tuo Portachiavi diventa inaccessibile. Ostler non puo recuperarla per te: la chiave non lascia mai questo Mac e non e memorizzata su alcun server."
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
MSG_INFO_PAIR_IPHONE_TITLE="Abbina il tuo iPhone"
MSG_INFO_PAIR_IPHONE_HELP="Apri l'app Ostler sul tuo iPhone e scansiona questo codice QR per collegarlo a questo Hub. Puoi anche abbinarlo piu tardi dal menu Impostazioni dell'Hub."
MSG_INFO_PAIR_IPHONE_FETCHING="Generazione del codice di abbinamento..."
MSG_INFO_PAIR_REFRESH="Aggiorna codice"
MSG_ERR_PAIR_FETCH_FAILED="Non riesco ancora a raggiungere il gateway di Ostler. Potrebbe essere ancora in avvio: clicca Aggiorna per riprovare."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agent non incluso nell'installer. Il LaunchAgent dei brief giornalieri + keepalive WhatsApp non si carichera."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Script di ricompilazione del wiki non inclusi nell'installer. Il wiki non si aggiornera automaticamente."

# F3 - legal package missing
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="pacchetto legal non incluso nell'installer. I gate di consenso Articolo 9 / WhatsApp / voce solleveranno ModuleNotFoundError finche non viene reinstallato."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s installato in %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s gia installato, lasciato al suo posto"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Architettura CPU non supportata per Google Workspace CLI; funzioni Gmail / Google Calendar ridotte."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl non disponibile; installazione di Google Workspace CLI saltata. Funzioni Gmail / Google Calendar ridotte."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="Impossibile scaricare Google Workspace CLI da %s"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="Mancata corrispondenza SHA256 di Google Workspace CLI (previsto %s, ottenuto %s). Installazione di questo binario interrotta."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="Impossibile estrarre l'archivio di Google Workspace CLI."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI installato in %s ma la verifica --version e fallita."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="Bridge calendario iCloud / CalDAV installato in %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="Il bridge calendario iCloud / CalDAV in %s non e eseguibile. Il calendario non restituira eventi."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh non incluso nell'installer. Il ritentativo di registrazione dispositivo alla prossima rete e disabilitato."
