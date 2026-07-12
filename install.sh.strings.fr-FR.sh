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

MSG_STEP_CHECKING_PREREQUISITES="Vérification des prérequis"
MSG_STEP_RUNNING_HEALTH_CHECK="Contrôle de l'état du système"
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="Setup (a few quick questions, then it keeps going on its own)"

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="puis relancez : ostler-fda"
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="Comptes Apple Mail visibles : %s (à titre informatif)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mail ne semble contenir encore aucun message local. Doctor affichera un rappel si aucun courrier n'arrive dans les 24 heures."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mail contient des messages en cache. L'ingestion les récupérera au prochain cycle horaire."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="Apple Mail est sélectionné, mais il n'y a encore aucun message local à lire sur ce Mac. Ouvrez Apple Mail et ajoutez un compte (Réglages Système > Comptes Internet, puis cochez Mail), et laissez-le terminer une première synchronisation."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="Une fois le courrier arrivé, relancez : ostler-fda. Ostler le récupérera automatiquement ; rien d'autre n'est nécessaire."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="La notarisation Apple sera vérifiée par Gatekeeper au premier lancement."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="disponible, le programme d'installation ignorera automatiquement cette étape."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="Les bêta-testeurs disposant d'un accès peuvent définir PWG_PIPELINE_REPO=<url> et relancer."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="Les bêta-testeurs disposant d'un accès peuvent définir PWG_KNOWLEDGE_REPO=<url> et relancer."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="Extensions de navigateur ignorées (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  Cloné dans %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture fonctionne uniquement sur Apple Silicon. Installation ignorée sur cette machine."
MSG_INFO_CM042_LOGS_AT="Journaux RemoteCapture : %s/ostler-remotecapture.log (et .err)"
MSG_INFO_CM042_TCC_PRE_PROMPT="Au premier lancement, Ostler RemoteCapture demandera à macOS l'autorisation d'enregistrement de l'écran et du microphone. Accordez les deux pour que les appels et réunions puissent être transcrits localement. Aucun indicateur d'enregistrement violet n'apparaît dans votre barre des menus : la capture audio est silencieuse par conception."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  Moteur de mémoire de conversation installé dans le venv."
MSG_INFO_HUB_APP_VERIFYING="Vérification d'Ostler.app dans %s"
MSG_INFO_HUB_APP_STAGING="Installation d'Ostler.app dans /Applications depuis %s"
MSG_INFO_HUB_APP_DRAG_HINT="Ouvrez le DMG d'installation et faites glisser Ostler.app et OstlerInstaller.app sur le raccourci Applications, puis relancez le programme d'installation."
MSG_OK_HUB_APP_PRESENT="Ostler.app déjà présent dans %s ; signature vérifiée."
MSG_OK_HUB_APP_STAGED="Ostler.app installé dans %s"
MSG_WARN_HUB_APP_NOT_FOUND="Ostler.app est introuvable dans /Applications et aucune copie fournie n'est disponible."
MSG_WARN_HUB_APP_VERIFY_FAILED="Échec de la vérification de la signature ou de la notarisation d'Ostler.app. Le paquet est laissé en place pour que le support puisse l'examiner."
MSG_INFO_CLONING_DOCTOR_AGENT="Clonage de l'agent Doctor..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="Clonage des scripts d'ingestion d'e-mails..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Clonage des scripts hub-power..."
MSG_INFO_CLONING_IMPORT_PIPELINE="Clonage du pipeline d'import..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="Clonage des scripts wiki-recompile..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima est installé mais n'est pas en cours d'exécution. Il va être démarré."
MSG_INFO_COLIMA_START_ATTEMPT="Démarrage de Colima (tentative %s sur %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="Impossible d'exporter les contacts. Vous pourrez les importer manuellement plus tard."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="Impossible de lire la fiche de contact. Aucun problème, nous vous poserons la question à la place."
MSG_INFO_CONTACT_CARD_WILL_ASK="Nous vous demanderons votre nom et votre pays dans un instant. Vos contacts sont lus plus tard à l'aide de l'accès complet au disque que vous accordez, et rien ne quitte ce Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  Création du venv Python dans %s..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="Création de l'arborescence de contenu visible par l'utilisateur dans %s/"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="Cycle quotidien. Exécution manuelle : bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="Hub de bureau (sans batterie) détecté : désactivation de la mise en veille à l'échelle du système"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker n'est pas installé. Colima + Docker CLI + le plugin docker-compose seront installés (légers, sans Docker Desktop requis)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="Fichiers de l'agent Doctor non inclus dans le programme d'installation."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="Scripts d'ingestion d'e-mails non inclus dans le programme d'installation."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="Les scripts d'ingestion d'e-mails sont absents du paquet d'installation. Re-téléchargez le .app depuis ostler.ai/install et réessayez."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Scripts d'ingestion d'e-mails non inclus et --allow-plaintext a été passé ; l'installation du LaunchAgent sera ignorée. Les futurs e-mails ne seront pas récupérés."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  Copie existante dans %s ; mise à jour..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Extraction du mbox Gmail depuis le zip Takeout (cela peut prendre une minute pour les grandes archives)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="Module d'extraction FDA non inclus. Extraction instantanée des données ignorée."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Activation de vos 30 premiers jours d'Ostler Pro..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Ostler Pro coûte \$9.99 USD par mois après la période d'essai. Abonnez-vous via l'app iOS Companion."
MSG_INFO_FOUND_GMAIL_MBOX_MB="Mbox Gmail trouvé dans %s (%s Mo)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Zip Google Takeout trouvé dans %s (%s Mo)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="Accès complet au disque détecté : extraction complète disponible."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="Exports RGPD détectés mais le pipeline d'import n'est pas encore disponible."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="L'import des exports RGPD sera disponible dès la livraison du pipeline."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="Analyse imminente des dossiers Téléchargements, Bureau et Documents à la recherche d'exports IA (Google Takeout, téléchargements Meta, LinkedIn, etc.) que vous auriez pu enregistrer. macOS affichera trois demandes d'accès aux dossiers : veuillez autoriser chacune d'elles. Cela prend environ 5 à 10 secondes au total. Rien n'est déplacé ni copié pendant l'analyse ; nous vérifions seulement ce qui est présent."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS peut demander l'autorisation de lire votre Calendrier. Autorisez-la pour qu'Ostler puisse construire la partie réunions + événements de votre graphe de connaissances. (Les données de calendrier restent sur cette machine.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS demande l'autorisation d'accéder aux Téléchargements. Cliquez sur OK."
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS demande l'autorisation d'accéder au Bureau. Cliquez sur OK."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS demande l'autorisation d'accéder aux Documents. Cliquez sur OK."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="Accès complet au disque accordé. Préparation de la prochaine demande macOS (automatisation de Messages)..."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="Les Xcode Command Line Tools sont nécessaires. macOS va demander l'autorisation de les installer : recherchez une petite boîte de dialogue grise (si vous ne la voyez pas, appuyez sur Cmd+Tab ou regardez dans votre Dock). Cliquez sur Installer. Les outils se téléchargent en arrière-plan pendant que vous répondez aux questions ci-dessous."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  Configuration des Command Line Tools en cours (%ss). Si une petite boîte de dialogue grise de macOS demande d'installer les outils de développement, cliquez sur Installer – cette étape attend cela. (Cmd+Tab ou regardez le Dock si vous ne la voyez pas.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="En attente de la fin de l'installation des Command Line Tools (presque terminé)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="Cycle horaire. La première exécution récupère les 5 dernières années de courrier."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="Désactivation de l'ancien LaunchAgent du pont iMessage (machine unique v1.0)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Hub sur secteur uniquement (aucune batterie détectée), LaunchAgent hub-power ignoré."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Scripts hub-power non inclus dans le programme d'installation."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="API Assistant incluse dans le programme d'installation ; utilisation de la source fournie."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="Source de l'API Assistant non incluse ; les points de terminaison de l'iOS Companion seront limités."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Lorsque la fenêtre Tailscale apparaît, connectez-vous avec Apple / Google / Microsoft."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="Ouverture de Tailscale pour que vous puissiez vous connecter..."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale ignoré : l'iOS Companion ne fonctionnera que sur votre Wi-Fi domestique. Vous pourrez le configurer plus tard depuis les Réglages."
MSG_INFO_TAILSCALE_STILL_WAITING="Toujours en attente de la connexion à Tailscale (%ss écoulées) : veuillez terminer la connexion dans la fenêtre Tailscale."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="Accès complet au disque accordé ; redémarrage de l'assistant pour prendre en compte la nouvelle autorisation."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="Ouverture des Réglages Système + du Finder pour vous guider dans l'octroi de l'accès complet au disque à l'assistant..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="L'accès complet au disque est toujours en attente. Le tableau de bord Doctor gardera la fiche visible jusqu'à ce que l'accès soit accordé."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant dispose déjà de l'accès complet au disque ; aucune action supplémentaire n'est nécessaire."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Vérification de la capacité de l'assistant Ostler à lire votre historique Messages..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="L'assistant peut lire l'historique Messages ; le canal iMessage fonctionnera."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="L'assistant ne peut pas encore lire l'historique Messages. Le tableau de bord Doctor affichera une fiche pour vous guider dans les Réglages Système."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="Le LaunchAgent de l'assistant ne s'est pas chargé ; vérification de l'accès complet au disque pour iMessage ignorée."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="L'interface d'import Evernote dans Doctor affichera un message « service indisponible »"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Pipeline d'import non inclus dans le programme d'installation."
MSG_INFO_INSTALLING_CM042="Installation d'Ostler RemoteCapture v%s (transcription des appels + réunions)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="Installation du moteur de mémoire de conversation depuis %s..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  Installation du moteur de mémoire de conversation dans le venv..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="Installation de Colima + Docker CLI..."
MSG_INFO_INSTALLING_HOMEBREW="Installation de Homebrew..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="Installation du service Knowledge depuis %s..."
MSG_INFO_INSTALLING_OLLAMA="Installation d'Ollama..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Installation du lecteur Apple Mail dans un venv dédié..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  Installation d'ostler-knowledge dans le venv..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Installation de l'extension Safari dans /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="Installation des dépendances Python de sécurité..."
MSG_INFO_INSTALLING_SQLCIPHER="Installation de SQLCipher..."
MSG_INFO_INSTALLING_TAILSCALE="Installation de Tailscale..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="La prise en charge d'Intel n'est pas prévue ; soumettez une demande si nécessaire."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Service Knowledge inclus dans le programme d'installation ; utilisation de la source fournie."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Service Knowledge non installé : PWG_KNOWLEDGE_REPO est vide."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="plus tard dans Réglages Système > Confidentialité et sécurité > Accès complet au disque"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  lancement pour vérifier la posture cron-delivery + imessage-tcc)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="Licence : %s est sous Apache 2.0. Texte complet : %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licence : %s : vérifiez les conditions en amont avant tout usage commercial."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="stockage local : Google ne sait jamais qu'Ostler existe."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="Journaux : %s/email-ingest.log (et .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="Journaux : %s/ostler-assistant.log (et .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="Journaux : %s/wiki-recompile.log (et .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="Hubs MacBook : définissez PWG_HUB_POWER_REPO=<url> et relancez."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="Hub MacBook détecté : désactivation de la mise en veille sur secteur uniquement (hub-power gère les transitions sur batterie)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Les déploiements Mac Mini / Studio ne sont pas affectés (toujours sur secteur)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Les données côté Mac (iMessage, Safari, etc.) ont été extraites ci-dessus."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="Redémarrage manuel : launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="Exécution manuelle : bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="Installation de com.ostler.meeting-brief-sender ignorée (fonctionnalité v1.0.1 ; points de terminaison pas encore livrés)."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="message lorsque l'indicateur de fonctionnalité sera activé ultérieurement."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="Besoin d'aide ? Écrivez à support@ostler.ai. Nous nous efforçons de répondre sous 2 jours ouvrés."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="Aucun canal configuré. À exécuter plus tard : %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="Aucune source FDA disponible pour le moment. Vous pouvez accorder l'accès complet au disque"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="Aucun export RGPD trouvé dans Téléchargements, Bureau ou Documents."
MSG_INFO_OPENING_CHROME_WEB_STORE="Ouverture du Chrome Web Store : %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="Binaire ostler-assistant non installé ; vérification doctor ignorée"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="doctor ostler-assistant : différé (le démon est peut-être encore en cours de"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="Utilisation du binaire ostler-assistant inclus dans ce DMG (chemin d'installation hors ligne)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge installé dans le venv."
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler affichera un écran de consentement supplémentaire avant l'installation"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  Remplacez le dépôt source du moteur de mémoire de conversation via la variable d'environnement documentée dans ./install.sh --help."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  Remplacez le dépôt source avec PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  Remplacez le dépôt source avec PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  Remplacez le dépôt source avec PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  Remplacez le dépôt source avec PWG_PIPELINE_REPO=<url> ./install.sh"
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Enregistrement des consentements et de la région..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="Surveillance de batterie de la phase 3 armée (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="Lecture de votre carnet d'adresses (les grandes bibliothèques peuvent prendre quelques minutes : ne fermez pas le programme d'installation)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="Remplacement de la politique : modifiez ~/.ostler/power.conf (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="Vérification de l'autorisation d'automatisation iMessage (lecture seule)..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="Téléchargement de nomic-embed-text (274 Mo)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="Téléchargement de %s (%s)... cela peut prendre quelques minutes."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="Attribut étendu de quarantaine effacé. Une fois que la version Developer-ID sera"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Lecture de Safari, iMessage, Notes, Calendrier, Photos, Rappels, Mail..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="Lecture de votre fiche de contact pour pré-remplir vos informations..."
MSG_INFO_REGION_EU_EEA_SOURCE="Région : UE/EEE (%s, source : %s)"
MSG_INFO_REGION_SOURCE="Région : %s (source : %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="Région : Royaume-Uni (source : %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="Région : États-Unis (source : %s)"
MSG_INFO_REPO_URL="URL du dépôt : %s"
MSG_INFO_REPO_URL_2="URL du dépôt : %s"
MSG_INFO_REPO_URL_3="URL du dépôt : %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="Choisissez maintenant la phrase secrète qui déverrouillera votre Hub. Vous la saisirez à chaque démarrage de l'interface du Hub."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="Phrase secrète de récupération ignorée. (Obsolète : la v1.0 exige toujours une phrase secrète.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="Réutilisation de l'installation existante de l'agent Doctor dans %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="Réutilisation de l'installation existante d'email-ingest dans %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="Réutilisation de l'installation existante de hub-power dans %s"
MSG_INFO_REUSING_EXISTING_JWT_SECRET="Réutilisation du JWT_SECRET existant dans %s"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="Réutilisation du jeton de service PWG existant dans %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="Réutilisation de l'installation existante de wiki-recompile dans %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="Le paquet de l'extension Safari n'est pas présent dans cette version du programme d'installation (ignoré)"
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="Recherche d'exports de données RGPD..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="Définissez PWG_DOCTOR_REPO=<url> et relancez pour installer."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="Définissez PWG_HUB_POWER_REPO=<url HR015> et relancez pour installer."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="Modèle de conversation ignoré. À télécharger plus tard : ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Démarrage de Colima (runtime Docker léger)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Démarrage de Docker Desktop..."
MSG_INFO_STARTING_OLLAMA="Démarrage d'Ollama..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="Suppression de l'ancienne formule Ollama (sans llama-server) ; passage à l'app Ollama..."
MSG_INFO_VERIFYING_EMBEDDINGS="Vérification que le moteur d'embeddings renvoie des vecteurs..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="Impossible de démarrer Ollama automatiquement. Chargez-le avec : launchctl bootstrap gui/\$(id -u) %s puis relancez le programme d'installation."
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  démarrage ; exécutez \`ostler-assistant doctor\` après le premier"
MSG_INFO_SYMLINKING="  Création du lien symbolique %s -> %s"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(Réglages Système > Comptes Internet). Ostler lit depuis le stockage de Mail"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(Le reste d'Ostler fonctionne sans le tableau de bord Doctor.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="C'est normal pour l'instant. L'import RGPD sera disponible dans une future mise à jour."
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="This usually takes 15 to 45 minutes, and can run longer if you have a lot of history or a slower Mac. That is normal – it is working, not stuck, so feel free to leave it running..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="Cela lit directement les bases de données macOS : aucun export n'est nécessaire."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="Astuce : pour inclure votre Gmail, ajoutez-le d'abord à Mac Mail"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="Pour installer plus tard, une fois que vous aurez l'accès :"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="Déclenchement de la synchronisation iCloud pour %s (silencieux, première exécution uniquement)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (RGPD britannique Article 9 : requis pour les données de catégorie particulière)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="Mise à jour du pipeline existant..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="Arborescence visible par l'utilisateur déjà annoncée (sentinelle présente) ; ignorée"
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane ne répond pas (facultatif ; voir les avertissements de la phase 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="Consultez-le à tout moment avec : bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="La reconnaissance vocale restera désactivée. Vous pourrez l'activer plus tard dans les Réglages."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="En attente de votre connexion à Tailscale (jusqu'à 3 minutes)..."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="Connecteur WhatsApp laissé désactivé. Vous pourrez l'activer plus tard via les Réglages."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="Maintien de connexion WhatsApp programmé à 08:50 + 17:50 (libellé com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="Rattrapage du wiki au premier jour ignoré : le cycle wiki-recompile n'est pas installé. La reconstruction quotidienne du wiki, si elle est installée, s'exécute toujours."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Scripts wiki-recompile non inclus dans le programme d'installation."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="Le wiki ne se mettra pas à jour automatiquement ; vous pouvez relancer la première compilation manuellement :"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="Marqueur de posture écrit : %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="Vos exports sont en sécurité. Importez-les plus tard avec : ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="Vos données Mac (iMessage, Safari, etc.) ont déjà été extraites ci-dessus."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="Vous pourrez l'ajouter plus tard pour un démarrage instantané depuis Safari, iMessage, etc."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="Modèle d'IA : %s (%s) : sélectionné pour vos %s Go de RAM"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="Toutes les sources sélectionnées (la reconnaissance faciale reste désactivée)"
MSG_OK_ALREADY_AVAILABLE="%s déjà disponible"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon détecté"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="Applications lancées pour déclencher la synchronisation iCloud"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="Bases de données des applications déjà présentes (pré-lancement ignoré)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="Configuration de l'assistant enregistrée dans %s (mode 0600)"
MSG_OK_BACKED_UP_CONTACTS="%s contacts sauvegardés dans %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s installé dans %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="LaunchAgent Ostler RemoteCapture chargé (libellé %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima et Docker CLI installés"
MSG_OK_COLIMA_WILL_START_AUTOMATICALLY_BOOT="Colima démarrera automatiquement au démarrage"
MSG_OK_CONFIG_SAVED_ENV="Configuration enregistrée dans %s/.env"
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Consentements et région enregistrés dans ~/.ostler/posture/"
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="Bases de données chiffrées. Phrase secrète requise à chaque démarrage."
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="Nouvelle tentative différée d'enregistrement d'appareil installée (s'exécute toutes les heures jusqu'à ce que la file soit vidée)"
MSG_OK_DOCKER_RUNNING="Docker en cours d'exécution"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker en cours d'exécution (a pris %ss)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Agent Doctor cloné depuis %s"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Fichiers de l'agent Doctor inclus dans le programme d'installation"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Dépendances de Doctor installées"
MSG_OK_EMAIL_CHANNEL_FOLDER="Canal e-mail : %s (dossier : %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent email-ingest chargé (libellé com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts d'ingestion d'e-mails inclus dans le programme d'installation"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="Scripts d'ingestion d'e-mails clonés depuis %s"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="Configuration de la mémoire de conversation WhatsApp"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  Lecteur de conversations WhatsApp installé."
MSG_WARN_WHATSAPP_SOURCE_FAILED="Échec de l'installation du lecteur de conversations WhatsApp ; le flux de conversations WhatsApp ne s'exécutera pas. Voir la sortie ci-dessus."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="Source du lecteur de conversations WhatsApp introuvable ; flux de conversations WhatsApp ignoré."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="Paquet du flux de conversations WhatsApp introuvable dans ce programme d'installation ; ignoré. L'historique des messages WhatsApp (qui vous avez contacté et quand) n'est pas affecté."
MSG_OK_WHATSAPP_BUNDLE_LOADED="LaunchAgent du flux de conversations WhatsApp chargé (libellé com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  Le premier cycle lit les conversations WhatsApp récentes que votre Mac a synchronisées (environ la dernière année) ; elles restent sur votre Mac."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  Journaux : %s/whatsapp-bundle.log et whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="Échec de l'installation du LaunchAgent du flux de conversations WhatsApp. Voir la sortie ci-dessus ; le reste de l'installation n'est pas affecté."
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="Configuration de la mémoire de conversation par e-mail"
MSG_OK_EMAIL_SOURCE_INSTALLED="  Lecteur de conversations par e-mail installé."
MSG_WARN_EMAIL_SOURCE_FAILED="Échec de l'installation du lecteur de conversations par e-mail ; le flux de conversations par e-mail ne s'exécutera pas. Voir la sortie ci-dessus."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="Source du lecteur de conversations par e-mail introuvable ; flux de conversations par e-mail ignoré."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="Paquet du flux de conversations par e-mail introuvable dans ce programme d'installation ; ignoré. L'ingestion horaire des e-mails n'est pas affectée."
MSG_OK_EMAIL_BUNDLE_LOADED="LaunchAgent du flux de conversations par e-mail chargé (libellé com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Lit vos fils d'e-mails récents depuis le stockage local d'Apple Mail ; tout reste sur votre Mac."
MSG_INFO_EMAIL_BUNDLE_LOGS="  Journaux : %s/email-bundle.log et email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="Échec de l'installation du LaunchAgent du flux de conversations par e-mail. Voir la sortie ci-dessus ; le reste de l'installation n'est pas affecté."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="Configuration de la mémoire de conversation des réunions et de la voix"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  Lecteur de conversations des réunions et de la voix installé."
MSG_WARN_SPOKEN_SOURCE_FAILED="Échec de l'installation du lecteur de conversations des réunions et de la voix ; le flux ne s'exécutera pas. Voir la sortie ci-dessus."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="Source du lecteur de conversations des réunions et de la voix introuvable ; flux ignoré."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="Paquet du flux de conversations des réunions et de la voix introuvable dans ce programme d'installation ; ignoré."
MSG_OK_SPOKEN_BUNDLE_LOADED="LaunchAgent du flux de conversations des réunions et de la voix chargé (libellé com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  Transforme vos propres réunions enregistrées et notes vocales en conversations consultables ; tout reste sur votre Mac."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  Journaux : %s/spoken-bundle.log et spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="Échec de l'installation du LaunchAgent du flux de conversations des réunions et de la voix. Voir la sortie ci-dessus ; le reste de l'installation n'est pas affecté."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="Configuration de la mémoire de conversation iMessage"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  Lecteur de conversations iMessage installé."
MSG_WARN_IMESSAGE_SOURCE_FAILED="Échec de l'installation du lecteur de conversations iMessage ; le flux de conversations iMessage ne s'exécutera pas. Voir la sortie ci-dessus."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="Source du lecteur de conversations iMessage introuvable ; flux de conversations iMessage ignoré."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="Paquet du flux de conversations iMessage introuvable dans ce programme d'installation ; ignoré."
MSG_OK_IMESSAGE_BUNDLE_LOADED="LaunchAgent du flux de conversations iMessage chargé (libellé com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  Lit vos conversations iMessage récentes depuis le stockage Messages de ce Mac ; tout reste sur votre Mac."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  Journaux : %s/imessage-bundle.log et imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="Échec de l'installation du LaunchAgent du flux de conversations iMessage. Voir la sortie ci-dessus ; le reste de l'installation n'est pas affecté."
MSG_OK_EMBEDDING_MODEL_READY="Modèle d'embeddings prêt"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="%s contacts exportés (seront importés automatiquement)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="Surveillance des exports installée (analyse les Téléchargements toutes les 4 heures)"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="Envoi des briefings de pré-réunion installé (interroge toutes les 10 minutes pendant les heures d'éveil)"
MSG_OK_EXTRACTED="Extrait dans %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="Extrait depuis %s source(s). Données enregistrées dans %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_12_HOURS="Nouvelle exécution FDA programmée dans environ 12 heures (rattrape les synchronisations iCloud lentes)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro actif pendant 30 jours. Abonnez-vous via l'app iOS Companion pour prolonger après la période d'essai."
MSG_OK_FOUND="Trouvé : %s"
MSG_OK_FOUND_EXPORTS="Exports trouvés dans %s"
MSG_OK_FOUND_GDPR_EXPORT_S="%s export(s) RGPD trouvé(s) :"
MSG_OK_GB_FREE_DISK_SPACE="%s Go d'espace disque libre"
MSG_OK_GB_RAM_DETECTED="%s Go de RAM détectés"
MSG_OK_GDPR_IMPORT_COMPLETE="Import RGPD terminé"
MSG_OK_GIT_AVAILABLE="Git disponible"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="Installation des Command Line Tools déclenchée (téléchargement en arrière-plan pendant que vous répondez aux questions ci-dessous)."
MSG_OK_HOMEBREW_INSTALLED="Homebrew installé"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent hub-power chargé (libellé com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts hub-power inclus dans le programme d'installation"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Scripts hub-power clonés depuis %s"
MSG_OK_ICAL_SERVER_INSTALLED="API Assistant installée (boucle locale 127.0.0.1:8090, relayée par Doctor)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="Autorisation d'automatisation iMessage : accordée"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="LaunchAgent du pont iMessage chargé (libellé com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts du pont iMessage inclus dans le programme d'installation"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="Scripts du pont iMessage clonés depuis %s"
MSG_OK_IMESSAGE_CHANNEL="Canal iMessage : %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="Pipeline d'import inclus dans le programme d'installation"
MSG_OK_IMPORT_PIPELINE_READY="Pipeline d'import prêt"
MSG_OK_CM048_PIPELINE_READY="Moteur de mémoire de conversation prêt."
MSG_INFO_CM048_SETTINGS_WRITTEN="  Modèles de conversation réglés sur %s (adaptés à vos %s Go de mémoire)"
MSG_INFO_CM048_SETTINGS_KEPT="  Conservation de vos réglages de conversation existants (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="Service Knowledge prêt : %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="Textes de licence installés dans %s/ (source : %s)"
MSG_OK_MACOS_DETECTED="macOS %s détecté"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="Ouverture de Réglages Système > Comptes Internet pour que vous puissiez ajouter un compte de messagerie. Revenez à cette fenêtre une fois connecté à votre premier compte."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="Étape Comptes Internet ignorée. Vous pourrez ajouter un compte de messagerie plus tard depuis les Réglages Système ; Doctor affichera un rappel si aucun courrier n'arrive dans les 24 heures."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Récupération de l'intégralité de votre historique Apple Mail. Cela peut prendre un peu plus de temps pour une grande boîte aux lettres."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="Conservation de la fenêtre de courrier standard de cinq ans. Vous pourrez en récupérer davantage plus tard depuis Doctor."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text déjà disponible"
MSG_OK_OLLAMA_HEALTHY="Ollama opérationnel"
MSG_OK_OLLAMA_INSTALLED="Ollama installé"
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama installé (CLI uniquement : peut nécessiter un démarrage manuel après redémarrage)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama installé (application de bureau)"
MSG_OK_OLLAMA_RUNNING="Ollama en cours d'exécution"
MSG_OK_EMBEDDINGS_VERIFIED="Moteur d'embeddings vérifié (vecteurs à 768 dimensions)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="doctor ostler-assistant : aucune erreur détectée"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de l'assistant Ostler chargé (libellé com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s installé dans %s (signé)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s installé dans %s (non signé)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor en cours d'exécution à l'adresse http://localhost:8089/doctor"
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Lecteur Apple Mail installé."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  Moteur d'ingestion d'e-mails installé."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="Commandes ostler-import, ostler-fda et ostler-uninstall installées"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph opérationnel"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="Phrase secrète notée. Elle chiffrera vos bases de données pendant la phase 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="Phrase secrète de récupération configurée."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="Information sur la phrase secrète prise en compte."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="Source d'alimentation : secteur (Mac de bureau, sans batterie)"
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="Power source: AC (good – the install can run 30 to 60 minutes or more, so mains power keeps it steady)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="Installation précédente détectée. Chargement de la configuration..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="Utilisation du Python fourni %s (aucune installation système nécessaire)"
MSG_OK_PYTHON_INSTALLED="Python %s installé"
MSG_OK_QDRANT_HEALTHY="Qdrant opérationnel"
MSG_OK_READY="%s prêt"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="Sources recommandées sélectionnées"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="Clé de récupération enregistrée dans le trousseau (recherchez « Ostler » dans l'app Mots de passe)"
MSG_OK_REDIS_HEALTHY="Redis opérationnel"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Extension Safari installée dans %s"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="La sécurité a déjà été configurée lors d'une exécution précédente."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="Module de sécurité installé dans le venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="Nouveau JWT_SECRET généré dans %s"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="Jeton de service PWG généré dans %s"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="Services démarrés (Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant optional-collection pre-create (#606) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  Collection de recherche préparée : %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="Impossible de préparer la collection de recherche %s ; le wiki se construira quand même (le lecteur la traite comme vide)"
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="Index de recherche pas prêt à temps ; préparation des collections facultatives ignorée (le wiki se construira quand même)"
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="Mise en veille désactivée sur secteur, veille sur batterie préservée, réveil sur le réseau activé"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="Mise en veille désactivée, réveil sur le réseau activé"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale déjà installé"
MSG_OK_TAILSCALE_INSTALLED="Tailscale installé"
MSG_OK_TAILSCALE_ENV_PERSISTED="Adresse IP Tailscale enregistrée dans .env : l'iOS Companion l'utilisera au premier lancement."
MSG_OK_TAILSCALE_IP="Adresse IP Tailscale : %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Service d'arrière-plan Tailscale démarré (mode espace utilisateur, sans extension système)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="Impossible de démarrer le service d'arrière-plan Tailscale. Vous pourrez relancer la configuration depuis les Réglages plus tard."
MSG_INFO_TAILSCALE_SIGN_IN_URL="Ouverture de votre navigateur pour vous connecter à Tailscale : %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Port du Hub %s exposé sur votre tailnet"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="Impossible d'exposer le port du Hub %s sur votre tailnet ; l'accès hors réseau local peut être limité"
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="Attributions tierces installées (source : %s)"
MSG_OK_USER_FACING_TREE_READY="Arborescence visible par l'utilisateur prête"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="Utilisation du dossier/libellé « Ostler » à la place."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane opérationnel (recherche web locale)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane en cours d'exécution à l'adresse http://localhost:3000 (communique avec votre Ollama local)"
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="Le connecteur WhatsApp sera activé (consentement enregistré)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="LaunchAgent de rattrapage du wiki au premier jour chargé (reconstruit votre wiki toutes les 30 minutes pendant les premières heures, puis s'arrête)"
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent wiki-recompile chargé (libellé com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts wiki-recompile inclus dans le programme d'installation"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Scripts wiki-recompile clonés depuis %s"
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki en cours d'exécution à l'adresse http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="Votre wiki est prêt à être consulté. Ostler rédige maintenant les résumés des pages en arrière-plan, ils se rempliront donc au cours des prochains instants. Vous pouvez commencer à utiliser votre wiki immédiatement."
MSG_OK_YOUR_ASSISTANT_CALLED="Votre assistant s'appelle %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="Scripts de synthèse du contexte personnel inclus dans le programme d'installation"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="LaunchAgent de synthèse du contexte personnel chargé (libellé com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  Journaux : %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="Réutilisation de l'installation existante de context-refresh dans %s"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="Scripts de synthèse du contexte personnel non inclus ; l'assistant s'appuiera uniquement sur des recherches en direct (aucun résumé de contexte permanent)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="Le LaunchAgent de synthèse du contexte personnel ne s'est pas chargé ; voir context-refresh.err. L'assistant répond toujours via des recherches en direct"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="La source clonée du service Knowledge n'a pas sa configuration d'empaquetage ; son environnement n'a donc pas été mis en place."
MSG_WARN_BUNDLE="  Paquet : %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s fonctionne uniquement sur Apple Silicon (détecté : %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="Impossible de télécharger Ostler RemoteCapture v%s depuis %s"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="Causes courantes : tag de version pas encore publié, réseau hors ligne, ou notarisation en amont encore en cours. Relancez le programme d'installation une fois la version disponible."
MSG_WARN_CM042_EXTRACT_FAILED="Impossible d'extraire l'archive Ostler RemoteCapture ; LaunchAgent ignoré."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Échec du chargement du LaunchAgent Ostler RemoteCapture. Voir la sortie ci-dessus et ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  L'enrichissement des conversations ne sera pas disponible. Le reste d'Ostler s'installe normalement ; relancez sans --allow-plaintext pour intégrer le moteur de mémoire de conversation."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="Échec de l'installation du moteur de mémoire de conversation (clonage)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  Recherché : %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  Cela signifie généralement que le .app du programme d'installation a été construit sans"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  le paquet cm048_pipeline fourni inclus dans"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Re-téléchargez le programme d'installation ou"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  relancez avec --allow-plaintext pour une installation dev/CI."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="Moteur de mémoire de conversation introuvable. L'enrichissement des conversations ne peut pas s'exécuter sans lui."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="Configuration du moteur de mémoire de conversation ignorée (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="Source du moteur de mémoire de conversation résolue mais pyproject.toml est manquant ; configuration du venv ignorée."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Échec du démarrage de Colima. Tentative avec Docker Desktop en solution de repli..."
MSG_WARN_COLIMA_START_RETRY="Colima n'a pas démarré proprement (le socket Docker n'était pas prêt). Nouvelle tentative dans %ss..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="Causes courantes : tag v%s pas encore publié, réseau hors ligne,"
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  stderr de consent_cli (400 premiers caractères) :"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  Script de console non créé dans %s ; il manque peut-être l'entrée [project.scripts] dans pyproject.toml."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="Poursuite car --allow-plaintext a été passé."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="Poursuite de l'installation. Relancez \`ostler-fda\` après avoir diagnostiqué l'erreur ci-dessus."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="Poursuite sans remplissage automatique de la fiche de contact : Ostler vous le demandera à la place."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  Les conversations envoyées à iMessage échoueront silencieusement jusqu'à ce que"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="Impossible de modifier les réglages de mise en veille. Activez « Empêcher la mise en veille automatique lorsque l'appareil est branché » dans Réglages Système > Énergie."
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="Impossible de modifier les réglages de mise en veille. Activez « Empêcher la mise en veille automatique » dans Réglages Système > Énergie."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="Impossible de télécharger ostler-assistant v%s depuis %s"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="Impossible d'extraire le mbox Gmail du zip Takeout : ignoré."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="Impossible d'extraire l'archive ostler-assistant ; LaunchAgent ignoré."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="Impossible de trouver le CLI Tailscale. Vous pourrez le configurer manuellement plus tard."
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Impossible d'installer le paquet de chaînes de consentement legal/ ; poursuite"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="Impossible d'installer le répertoire LICENSES/ (non bloquant)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="Impossible d'installer ostler_security dans le venv du Hub."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="Impossible d'installer THIRD_PARTY_NOTICES.md (non bloquant)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="Impossible d'obtenir l'agent Doctor (échec de la version fournie et du clonage)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="Fichiers Ostler Doctor introuvables. Requis pour le flux d'appairage iOS (Ostler.app intègre :8089/pair-ios)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  Recherché : %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  Cela signifie généralement que le .app du programme d'installation a été construit sans"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  la source doctor/agent/ fournie incluse dans"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Re-téléchargez le programme d'installation ou"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  relancez avec --allow-plaintext pour une installation dev/CI."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Installation de Doctor abandonnée : requise pour le flux d'appairage iOS. Re-téléchargez le programme d'installation ou passez --allow-plaintext pour une installation dev/CI."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="Impossible d'obtenir les scripts d'ingestion d'e-mails (échec de la version fournie et du clonage)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="Impossible d'obtenir les scripts hub-power (échec de la version fournie et du clonage)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="Impossible d'obtenir les scripts wiki-recompile (échec de la version fournie et du clonage)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="Impossible d'ouvrir automatiquement l'URL du Chrome Web Store : %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="Impossible d'enregistrer region.json (poursuite : Doctor l'affichera)"
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="Impossible d'enregistrer dans le trousseau. Veuillez la noter."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="Impossible de démarrer Ollama automatiquement."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="Impossible de mettre à jour le pipeline (hors ligne ?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="Impossible d'écrire pipeline_signals.json. Le diagnostic de Mail vide de Doctor reviendra aux valeurs par défaut sûres jusqu'à la prochaine installation ou au prochain cycle."
MSG_WARN_CURL_SAID="Curl a indiqué :"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="Répertoire introuvable : %s : import ignoré."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker n'a pas démarré en %s secondes."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker est installé mais n'est pas en cours d'exécution. Il faudra le démarrer."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama en cours d'installation et bloquent les sondes de disponibilité."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  marqueurs précoces (les canaux se connectent encore + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="Échec de l'installation du LaunchAgent email-ingest. Voir la sortie ci-dessus."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="Échec de l'installation du LaunchAgent du pont iMessage. Les réponses iMessage de l'utilisateur assistant ne fonctionneront pas tant que vous n'aurez pas relancé le programme d'installation ou exécuté INSTALL_SNIPPET.sh manuellement."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Scripts du pont iMessage non inclus et --allow-plaintext a été passé ; l'installation du LaunchAgent sera ignorée. Les réponses iMessage de l'utilisateur assistant ne fonctionneront pas."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="Le chiffrement ne fonctionnera pas."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="Le chiffrement ne fonctionnera pas, et"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="assurez-vous que le tag PWG_KNOWLEDGE_REPO épinglé l'inclut."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  autorisation Événements pour Messages.app)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="L'extracteur FDA s'est terminé avec un code non nul (%s). 20 dernières lignes de sortie :"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="Module d'extraction FDA non inclus dans ce programme d'installation."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="Attendu à : Contents/Resources/ostler_fda/ (à l'intérieur du .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="Cause la plus probable : une régression de build a supprimé la copie fournie. Re-téléchargez le .app depuis ostler.ai/install."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="Module d'extraction FDA non inclus. Poursuite car --allow-plaintext a été passé : l'extraction instantanée des données sera ignorée."
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault n'est PAS activé."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="Impossible d'activer le premier mois gratuit pour le moment ; l'installation se poursuivra. Ouvrez l'app iOS Companion une fois appairée pour résoudre cela."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="Accès complet au disque non accordé à Terminal."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="%s Go de RAM détectés. Vous obtiendrez l'assistant compact (gemma4:e2b) : fiable, précis, en moins d'une seconde sur les questions courtes, avec appels d'outils et un honnête « je ne sais pas » quand il ne sait pas. Pour des réponses plus riches sur les questions plus longues, 24 Go ou plus débloquent l'assistant standard (qwen3.5:9b). Vous pourrez changer de Mac plus tard en réinstallant."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="L'import RGPD a rencontré des erreurs. Vous pouvez relancer avec :"
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="L'import RGPD fait partie de l'installation produit. Sans lui, votre graphe social (LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google Calendar) ne peut pas être importé."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="L'import RGPD ne sera pas disponible sur cette instance jusqu'à la réinstallation du pipeline d'import."
MSG_WARN_GIT_SAID="Git a indiqué :"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  Échec du contrôle de l'état : ostler-knowledge --version n'a produit aucune sortie."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  Échec du contrôle de l'état : le moteur de mémoire de conversations n'a pas pu se charger (pwg-convo ou l'import de son pipeline n'a pas retourné proprement)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="Le programme d'installation de Homebrew s'est terminé avec le code %s. Les 30 dernières lignes de /tmp/ostler-brew-install.log suivent :"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Journal d'installation de Homebrew (fin) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="L'installation pip de Doctor s'est terminée avec le code %s. Les 30 dernières lignes de /tmp/ostler-doctor-pip.log suivent :"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Journal d'installation pip de Doctor (fin) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="L'installation pip du pipeline s'est terminée avec le code %s. Les 30 dernières lignes de /tmp/ostler-pipeline-pip.log suivent :"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- Journal d'installation pip du pipeline (fin) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Échec de l'installation du LaunchAgent hub-power. Voir la sortie ci-dessus."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="Scripts hub-power introuvables au chemin attendu du paquet."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  Le .app du programme d'installation semble manquer de vendor/hub_power/"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  dans Contents/Resources/hub-power/. La limitation selon la batterie ne sera pas installée ; le reste de l'installation se poursuivra."
MSG_WARN_ICAL_SERVER_FAILED="Impossible de démarrer l'API Assistant ; les points de terminaison de l'iOS Companion seront limités jusqu'à la prochaine exécution de l'installation."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - Échec du téléchargement de l'image (réseau, espace disque ou délai d'attente du registre dépassé)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="Impossible d'écrire le signal FDA iMessage dans pipeline_signals.json. Le tableau de bord Doctor n'affichera peut-être pas automatiquement la fiche d'accès complet au disque."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="L'hôte IMAP est vide : réessayez."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="Autorisation d'automatisation iMessage : non accordée (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="Autorisation d'automatisation iMessage : sonde non concluante."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="Ouverture de Réglages Système > Confidentialité et sécurité > Automatisation. Cochez la ligne Messages pour OstlerInstaller (ou Terminal) pour activer la distribution iMessage."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage a besoin d'au moins un contact autorisé. Réessayez ou"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="Pipeline d'import non disponible (dépôt privé : bêta-testeurs uniquement)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="Pipeline d'import non inclus dans le programme d'installation. Échec bloquant contourné."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Pipeline d'import non inclus dans le programme d'installation. C'est le chemin d'installation produit ; le paquet Python contact_syncer devrait être livré à l'intérieur du paquet .app."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX signifie que l'assistant lira chaque e-mail que vous recevez."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Espace disque insuffisant pour le volume de sortie du wiki"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Mac Intel détecté : les performances seront limitées. Apple Silicon recommandé."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s est un hôte de fournisseur cloud."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="Le JWT_SECRET dans %s figure sur la liste d'exclusion ; régénération pour que les services du graphe de connaissances restent importables"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="Le JWT_SECRET dans %s est trop court (%s < %s caractères) ; régénération"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="Dépôt Knowledge cloné mais pyproject.toml manquant ; configuration du venv ignorée."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="Échec de l'installation du service Knowledge (clonage)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="Licence : %s est distribué sous les Conditions d'utilisation Gemma de Google, et non sous Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="Les déploiements MacBook en ont besoin pour la gestion de la batterie / mise en veille."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="L'autorisation Contacts de macOS a été refusée ou n'est pas encore accordée."
MSG_WARN_MACOS_OUTDATED_WE_RECOMMEND_MACOS_13="macOS %s est obsolète. Nous recommandons macOS 13 (Ventura) ou une version ultérieure."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS ne la demandera PAS depuis un script : vous devez l'accorder manuellement."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Les déploiements Mac Mini ne sont pas affectés ; les utilisateurs MacBook devraient réessayer."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="Les données de courrier restent ingestibles manuellement :"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  Nouvelle tentative manuelle : cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  Nouvelle tentative manuelle une fois la cause résolue :"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Ni Apple Mail ni IMAP personnalisé sélectionné : Apple Mail par défaut."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="Aucune clé d'accès définie ; les bases de données ne seront pas chiffrées."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="Les phrases secrètes ne correspondent pas. Réessayez."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="Échec de la configuration de la phrase secrète. Sortie :"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="Saisie vide. Phrase secrète ignorée."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="La phrase secrète doit comporter au moins 12 caractères. Réessayez."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="Une phrase secrète est requise pour chiffrer vos données."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="Le numéro doit commencer par +. Réessayez."
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama ne répond pas"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s a échoué (tentative %s/3). Nouvelle tentative dans %ss..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="Seulement %s Go libres. Nous recommandons au moins 35 Go (images Docker + modèle d'IA + données)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="Sur batterie, le LaunchAgent hub-power (étape 3.14) peut se mettre en pause"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="ou relancez le programme d'installation et choisissez un autre canal."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="ou vous devancez le pipeline de publication de la phase B. Relancez le programme d'installation une fois que le"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="doctor ostler-assistant a signalé %s erreur(s)."
MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant extrait mais la vérification --version a échoué."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Échec de l'installation du LaunchAgent de l'assistant Ostler après 3 tentatives. Sortie de diagnostic ci-dessus + ci-dessous."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Tentative d'installation %s du LaunchAgent de l'assistant Ostler échouée ; nouvelle tentative."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="stderr complet du démon à : %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="Dernier stderr du snippet :"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s fonctionne uniquement sur Apple Silicon (détecté : %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - image ostler-wiki-compiler pas encore téléchargeable (registre non configuré)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph ne répond pas"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph pas encore opérationnel à cette phase (vérifiez les journaux ci-dessus)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="Les mots de passe ne correspondaient pas (ou étaient vides). Réessayez."
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="The main install typically takes 30 to 60 minutes (Docker + Ollama downloads + first-time setup) and can run longer on a slower connection. Long quiet stretches are normal – it is downloading and setting up in the background, not stuck."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  l'installation pip a échoué ; le moteur de mémoire de conversation ne sera pas disponible."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  l'installation pip a échoué ; email-ingest reviendra au python système (peut aussi échouer à l'exécution)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  l'installation pip a échoué ; ostler-knowledge ne sera pas disponible."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  l'installation pip a échoué ; moteur d'ingestion d'e-mails non disponible. Le LaunchAgent horaire émettra toujours des fichiers mbox mais ne pourra pas les ingérer dans le graphe tant que cela n'est pas réparé."
MSG_WARN_CM021_SOURCE_NOT_FOUND="Source du moteur d'ingestion d'e-mails introuvable dans le paquet de l'app ; la tâche d'arrière-plan horaire enregistrera les fichiers de courrier sans les ingérer."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="Source ostler_fda introuvable dans le paquet de l'app ; le LaunchAgent email-ingest reviendra au python système à l'exécution."
MSG_WARN_PIP_SAID="pip a indiqué :"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="Branchez sur secteur pour l'installation complète."
MSG_WARN_PORT_1_ALREADY_USE_PID="Le port %s est déjà utilisé par %s (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - Port 3000 déjà utilisé par un autre service"
MSG_WARN_POWER_SOURCE="Source d'alimentation : %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="Échec de l'installation de sqlcipher3."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="Échec de l'installation de sqlcipher3. Les bases de données ne seront pas chiffrées."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="Python 3 introuvable. Installation de Python 3.12..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s est trop ancien (3.10+ requis). Installation de Python 3.12..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant ne répond pas"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         Lisez https://ai.google.dev/gemma/terms avant tout usage commercial."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="Lisez la version publique sur https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis ne répond pas"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="soit disponible, ou installez le binaire manuellement :"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="Nouvelle exécution : saisissez un hôte auto-hébergé, ou appuyez sur Ctrl-C et relancez en choisissant Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="relancez le programme d'installation avec iMessage décoché pour l'ignorer."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="EXÉCUTION AVEC --allow-plaintext : chiffrement désactivé. NE PAS UTILISER EN PRODUCTION."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  Exécutez \`%s doctor\` après le premier lancement"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="Exécutez 'tailscale ip --4' une fois connecté, puis ajoutez l'adresse à l'app iOS."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Échec de la copie de l'extension Safari ; vous pourrez l'installer manuellement plus tard"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="Module de sécurité introuvable. La configuration de la clé d'accès sera ignorée."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  Recherché : %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  Cela signifie généralement que le .app du programme d'installation a été construit sans"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  le paquet ostler_security fourni inclus dans"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Re-téléchargez le programme d'installation ou"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  relancez avec --allow-plaintext pour une installation dev/CI."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="Échec de la configuration de la sécurité. Poursuite sans chiffrement de la base de données."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="Échec de la configuration de la sécurité. Sortie :"
MSG_WARN_SEE_STDERR_FRAGMENT="  Voir %s pour le fragment stderr."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="Installation du binaire ignorée. Le fichier config.toml écrit par l'assistant reste en place."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Installation du LaunchAgent Doctor ignorée."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="Installation du LaunchAgent email-ingest ignorée."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="Installation du LaunchAgent ignorée. Les déploiements Mac Mini ne sont pas affectés."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="Installation du LaunchAgent ignorée. Essayez : %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="Installation du LaunchAgent wiki-recompile ignorée."
MSG_WARN_SOME_FEATURES_MAY_NOT_WORK_CORRECTLY="Certaines fonctionnalités peuvent ne pas fonctionner correctement sur les versions plus anciennes."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="Certains ports sont utilisés. Les conteneurs Docker peuvent ne pas démarrer."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="Arrêtez les services en conflit ou changez les ports dans docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscale ne s'est pas connecté en 3 minutes. Vous pourrez y revenir plus tard depuis les Réglages."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="L'adresse IP Tailscale a été écrite dans .env mais une relecture n'a pas pu la voir. L'iOS Companion pourrait ne pas la récupérer : relancez install.sh --repair si cela se produit."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="Échec de l'installation de Tailscale : vous pourrez l'installer plus tard depuis tailscale.com"
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="les services déployés refusent de démarrer sans eux."
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  c'est résolu. Voir la bannière des prochaines étapes pour la correction."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  à inspecter. cron-delivery / imessage-tcc sont courants"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  Essayez : docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  Essayez : docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="Choix non reconnu '%s' ; iMessage + e-mail par défaut."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="Choix non reconnu. Utilisation de Recommandé."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  Échec de la mise à jour ; poursuite avec la copie existante."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="Utilisez Apple Mail (recommandé ci-dessus) pour ce compte : Ostler ne stocke jamais les mots de passe cloud."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="Utilisation d'INBOX. L'assistant lira chaque e-mail entrant."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="Le conteneur Vane a démarré mais http://localhost:3000 n'a pas répondu en 60 s."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane (recherche web locale) n'a pas pu démarrer. Causes courantes :"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  La recherche web est facultative ; le reste d'Ostler fonctionne sans elle."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="Nous recommandons fortement un libellé/dossier dédié à la place."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp a besoin d'un numéro de téléphone pour la distribution des briefings. Réessayez,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="Wiki compilé mais le conteneur wiki-site n'a pas pu démarrer."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="Échec de la première compilation du wiki. Causes courantes :"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="Le LaunchAgent de rattrapage du wiki au premier jour n'a pas pu être chargé. La reconstruction quotidienne du wiki s'exécute toujours ; votre wiki s'actualisera simplement le lendemain plutôt que dans l'heure."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Échec de l'installation du LaunchAgent wiki-recompile. Voir la sortie ci-dessus."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="Le wiki ne se mettra pas à jour automatiquement ; la reconstruction manuelle reste disponible :"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="La configuration de l'assistant reste en place ; le binaire reste installé. Nouvelle tentative manuelle :"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="Votre assistant a besoin d'un nom. Choisissez parmi les suggestions ci-dessus ou saisissez le vôtre."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="Vous pouvez la réaccorder dans Réglages Système > Confidentialité et sécurité > Contacts."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="Vous pouvez exécuter la configuration de la sécurité plus tard : python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="Vous devrez peut-être l'installer manuellement : %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  réel :     %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="Le paquet Ostler RemoteCapture n'était pas présent dans %s après extraction. L'archive de la version est peut-être malformée."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify a signalé :"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  Refus d'installer un paquet qui ne correspond pas à la somme de contrôle publiée."
MSG_ERR_CM042_SHA_256_MISMATCH="Non-concordance SHA-256 de l'archive Ostler RemoteCapture."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess a signalé :"
MSG_ERR_CM042_VERIFY_FAILED="Échec de la vérification de la signature / notarisation d'Ostler RemoteCapture."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv a signalé :"
MSG_ERR_EXPECTED="  attendu : %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief a signalé : %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="Le binaire ostler-assistant à %s n'est pas un exécutable Mach-O."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="Non-concordance SHA-256 de l'archive ostler-assistant."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  Refus d'installer un binaire qui ne correspond pas à la somme de contrôle publiée."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="Refus de retirer la quarantaine ou de charger le LaunchAgent."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="Relancez le programme d'installation une fois l'archive en amont corrigée."
MSG_ERR_URL="  url :      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Les Mac Intel ne sont pas pris en charge dans la v1.0. Apple Silicon (M1, M2, M3 ou M4) est requis. La prise en charge d'Intel arrivera en v1.0.1."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="Au moins 16 Go de RAM requis. Vous disposez de %s Go. 24 Go recommandés."
MSG_FAIL_CM042_SIGNATURE_FAILED="Installation d'Ostler RemoteCapture abandonnée : échec de la vérification de la signature ou de la notarisation. Le paquet a été laissé dans /Applications pour le support. Écrivez à support@ostler.ai et relancez le programme d'installation."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="Impossible de télécharger %s après 3 tentatives. Vérifiez votre réseau et relancez le programme d'installation."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="Impossible de télécharger nomic-embed-text après 3 tentatives. Vérifiez votre réseau et relancez le programme d'installation."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker non disponible. Relancez le programme d'installation pour installer Colima."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="Le module d'extraction FDA est absent du paquet d'installation. Re-téléchargez le .app depuis ostler.ai/install, ou relancez avec --allow-plaintext pour dev/CI."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Échec de l'installation des dépendances de Doctor. Sortie complète enregistrée dans /tmp/ostler-doctor-pip.log : joignez-la lorsque vous écrivez à support@ostler.ai (Référence : ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="Échec de l'installation des dépendances du pipeline d'import. Sortie complète enregistrée dans /tmp/ostler-pipeline-pip.log : joignez-la lorsque vous écrivez à support@ostler.ai (Référence : ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Échec de l'installation de Homebrew. Sortie complète enregistrée dans /tmp/ostler-brew-install.log : joignez-la lorsque vous écrivez à support@ostler.ai."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="Échec de l'installation du pipeline d'import. Le paquet contact_syncer est requis pour l'installation produit. Relancez avec --allow-plaintext pour dev/CI, ou re-téléchargez le programme d'installation et réessayez."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="Accès sudo nécessaire pour désactiver la mise en veille + installer Homebrew. Relancez lorsque vous êtes prêt."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Ni Colima ni Docker Desktop n'ont pu démarrer. Installez Docker Desktop et relancez."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="Espace disque insuffisant (%s Go). Libérez de l'espace et réessayez."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="Aucune clé d'accès définie et aucune configuration de sécurité existante. Relancez avec --allow-plaintext pour dev/CI, ou relancez le programme d'installation et confirmez l'information sur Touch ID."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="Le moteur de mémoire de conversation est requis. Relancez avec --allow-plaintext pour dev/CI, ou corrigez le paquet manquant ci-dessus et réessayez."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="Échec de l'installation d'ostler_security. Relancez avec --allow-plaintext pour dev/CI, ou corrigez l'erreur pip ci-dessus et réessayez."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="Échec de la configuration de la clé d'accès. Relancez avec --allow-plaintext pour dev/CI, ou corrigez l'erreur ci-dessus et réessayez."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="sqlcipher3 est requis pour les bases de données chiffrées. Relancez avec --allow-plaintext pour dev/CI, ou corrigez l'erreur pip ci-dessus et réessayez."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Ce programme d'installation est destiné à macOS uniquement. La prise en charge de Linux arrive bientôt."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="L'installation des Xcode Command Line Tools ne s'est pas terminée en 15 minutes. Ouvrez le Terminal et exécutez 'xcode-select --install', cliquez sur Installer dans la boîte de dialogue macOS, attendez la fin, puis relancez ce programme d'installation."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="L'installation de Homebrew a signalé une réussite mais /opt/homebrew/bin/brew est manquant. Consultez %s pour la transcription complète. Récupération : ouvrez Terminal et exécutez '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' puis relancez le programme d'installation."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew est installé à /opt/homebrew/bin/brew mais la commande 'brew' n'est pas dans le PATH après l'évaluation de shellenv. Ouvrez un nouveau Terminal et relancez le programme d'installation."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' a signalé une réussite mais colima n'est pas dans le PATH. Consultez %s pour les échecs Homebrew. Récupération : ouvrez Terminal et exécutez 'brew install colima docker docker-compose' manuellement, puis relancez le programme d'installation."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' a signalé une réussite mais le CLI docker n'est pas dans le PATH. Consultez %s. Récupération : 'brew install docker' manuellement puis relancez le programme d'installation."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="L'installation de l'app Ollama a signalé une réussite mais son binaire est manquant à /Applications/Ollama.app. Consultez %s. Récupération : 'brew install --cask ollama-app' manuellement puis relancez le programme d'installation."
MSG_FAIL_EMBED_HEALTHCHECK="Ollama est en cours d'exécution mais le modèle d'embeddings n'a renvoyé aucun vecteur (HTTP différent de 200, ou résultat vide). La fiche Personnes, la recherche et la navigation seraient toutes vides. Consultez %s. Récupération : assurez-vous que l'app Ollama (et non la formule Homebrew) est installée et active, puis relancez le programme d'installation."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' a signalé une réussite mais sqlcipher n'est pas dans le PATH. Consultez %s. Récupération : 'brew install sqlcipher' manuellement puis relancez le programme d'installation."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' n'a pas produit /Applications/Tailscale.app. Consultez %s. Récupération : téléchargez Tailscale depuis https://tailscale.com/download/macos et faites-le glisser dans /Applications, puis relancez le programme d'installation."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' a signalé une réussite mais le binaire python3.11 est manquant à /opt/homebrew/opt/python@3.11/bin/python3.11. Consultez %s. Récupération : 'brew reinstall python@3.11' puis relancez le programme d'installation."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="Nous avons trouvé vos réponses précédentes"
MSG_PROMPT_REUSE_SETTINGS_HELP="Nous avons détecté une tentative d'installation antérieure sur ce Mac. Les questions auxquelles vous avez déjà répondu (nom, nom de l'assistant, fuseau horaire, indicatif pays, canaux, etc.) seront réutilisées pour que vous n'ayez pas à les ressaisir. Choisissez Oui pour reprendre là où vous vous êtes arrêté, ou Non pour parcourir à nouveau les questions depuis le début."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Réponses précédentes trouvées : nom = %s, assistant = %s, fuseau horaire = %s."

MSG_PROMPT_PERMS_OK_TITLE="Prêt à continuer ?"
MSG_PROMPT_PERMS_OK_HELP="macOS demandera l'accès aux Contacts ainsi qu'aux Fichiers et dossiers. L'accès complet au disque, facultatif, pourra être accordé plus tard."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Nom complet (tel qu'il apparaît dans vos contacts)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Nom complet (par ex. Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="Comment votre assistant doit-il vous appeler ?"
MSG_PROMPT_USER_ID_HELP="Un nom court que votre assistant utilisera pour s'adresser à vous (par ex. « Andy », « Andrew », « Mme Smith »). C'est ce qui apparaît dans vos briefings du matin et vos réponses de chat. Différent de votre nom complet ci-dessus."

# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="Installing in the background (about 15 to 60 minutes)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="Utiliser +%s ?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Saisissez l'indicatif pays (par ex. 44 pour le Royaume-Uni, 1 pour les États-Unis)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Indicatif pays par défaut"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Utilisé pour normaliser les numéros de téléphone lors de l'import des contacts et pour définir votre région (Royaume-Uni / UE / États-Unis / autre) pour les valeurs par défaut de conformité légale."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="Nous avons détecté +%s. L'utiliser pour votre Hub ?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Détecté à partir de votre numéro de téléphone ci-dessus. Choisissez Oui pour l'utiliser, ou Non pour saisir un autre indicatif pays."

MSG_PROMPT_TZ_CONFIRM_TITLE="Utiliser ce fuseau horaire ?"
MSG_PROMPT_TZ_CONFIRM_HELP="Fuseau horaire détecté : %s"
MSG_PROMPT_USER_TZ_TITLE="Saisissez le fuseau horaire (par ex. Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="Comment souhaitez-vous appeler votre assistant ?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="Le nom dans le champ est une suggestion aléatoire : remplacez-le par ce que vous voulez. Marvin, Samantha, Joshua, Friday, Athena, Sage et Rosie sont autant de choix populaires." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Saisissez le nom que vous voulez : la suggestion n'est qu'un point de départ."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="Comment votre assistant vous contactera-t-il ?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Choisissez les canaux de messagerie que vous souhaitez voir utiliser par votre assistant. Vous pourrez modifier cela plus tard dans la section Doctor de l'app."

MSG_PROMPT_WHATSAPP_CONSENT_TITLE="Activer la messagerie WhatsApp pour votre assistant ?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web est un service tiers. En l'activant, vous acceptez que vos messages transitent par l'infrastructure de WhatsApp avant d'atteindre votre instance Ostler locale, et que WhatsApp (Meta Platforms Ireland Ltd) puisse suspendre, restreindre ou résilier votre compte WhatsApp en raison d'une utilisation automatisée. Vous pourrez désactiver cela plus tard depuis les Réglages."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="Votre numéro de téléphone WhatsApp"
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Numéro international avec l'indicatif pays, par ex. +44 7700 900123. Chiffres et un + en tête uniquement : pas d'espaces, de parenthèses ni de tirets."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Autoriser Ostler à lire vos Messages"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="Les Réglages Système sont ouverts sur Accès complet au disque."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Trouvez \"Ostler\" et activez-le."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="Cliquez sur Terminé une fois fini."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Terminé"

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Autoriser Ostler à lire les données de votre Mac"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="Les Réglages Système sont ouverts sur Accès complet au disque."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Trouvez \"OstlerInstaller\" dans la liste et activez-le."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Cliquez sur Terminé une fois fini et Ostler lira votre historique Safari, vos Notes, vos iMessages et votre Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Terminé"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="Étape suivante : Accès complet au disque pour le programme d'installation"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="Ensuite, macOS vous demandera d'accorder l'accès complet au disque à OstlerInstaller."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Après avoir activé l'interrupteur, macOS affichera une boîte de dialogue vous demandant de choisir « Quitter et rouvrir » ou « Plus tard »."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Cliquez sur Quitter et rouvrir. Le programme d'installation se relancera et reprendra automatiquement à partir de cette étape."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="OK"
MSG_INFO_INSTALLER_FDA_PREWARN="Présentation du processus d'octroi de l'accès complet au disque..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="Ouverture des Réglages Système pour que vous puissiez accorder l'accès complet au disque au programme d'installation..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="Accès complet au disque accordé au programme d'installation. Lecture de Safari, Notes, iMessages et Mail à suivre."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="Accès complet au disque toujours non accordé. Poursuite sans lui ; vous pourrez relancer le programme d'installation plus tard pour extraire Safari / Notes / iMessages."

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="Contacts autorisés"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="Personnes de confiance : numéros de téléphone et e-mails Apple ID (séparés par des virgules). %s ne répond qu'aux personnes de cette liste ; les messages de quiconque d'autre sont ignorés. Au moins une entrée est requise.

Par exemple :
+447700900000, vous@exemple.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="Lire le courrier via Apple Mail ?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Lit tout compte de messagerie que vous avez ajouté à Apple Mail (iCloud, Gmail, Outlook, etc.) à l'aide de l'accès complet au disque. Aucun mot de passe stocké. Recommandé pour presque tout le monde."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="Ajouter un compte de messagerie à Apple Mail ?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="Apple Mail n'a encore aucun compte connecté sur ce Mac, Ostler n'aura donc aucun e-mail à lire. Choisissez Oui pour ouvrir maintenant Réglages Système > Comptes Internet (vous pouvez y ajouter iCloud, Gmail ou Outlook). Choisissez Non pour ignorer ; vous pourrez ajouter un compte plus tard et Doctor affichera un rappel si aucun courrier n'arrive dans les 24 heures."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="Récupérer l'intégralité de votre historique Apple Mail ?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Par défaut, Ostler lit les cinq dernières années de votre Apple Mail. Si vous en conservez davantage sur ce Mac et souhaitez tout intégrer à votre graphe de connaissances, choisissez Oui pour récupérer maintenant l'intégralité de l'historique local (cela peut prendre un peu plus de temps pour une grande boîte aux lettres). Choisissez Non pour conserver la fenêtre de cinq ans ; vous pourrez toujours l'étendre plus tard depuis Doctor."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="Configurer également un serveur IMAP+SMTP personnalisé ?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="Pour les boîtes aux lettres auto-hébergées uniquement. Gardez NON si vos comptes sont chez Gmail, iCloud ou Outlook : ceux-ci fonctionnent mieux via Apple Mail ci-dessus."

MSG_PROMPT_IMAP_HOST_TITLE="Hôte IMAP"
MSG_PROMPT_IMAP_HOST_HELP="Serveur IMAP auto-hébergé ou personnalisé uniquement. Utilisez Apple Mail (ci-dessus) pour Gmail / iCloud / Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="Port IMAP"

MSG_PROMPT_SMTP_HOST_TITLE="Hôte SMTP"
MSG_PROMPT_SMTP_PORT_TITLE="Port SMTP"

MSG_PROMPT_EMAIL_USERNAME_TITLE="Adresse e-mail (également utilisée comme nom d'utilisateur IMAP/SMTP)"

MSG_PROMPT_EMAIL_PASSWORD_TITLE="Mot de passe (masqué)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Mot de passe de votre serveur IMAP/SMTP auto-hébergé. Stocké localement sous ~/.ostler/ : jamais envoyé à Creative Machines."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Confirmer le mot de passe"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="Quel dossier l'assistant doit-il surveiller ?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="Recommandé : un libellé ou dossier dédié (par ex. Ostler). Nous n'y lirons que les messages, laissant votre boîte de réception principale intacte."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="Saisissez à nouveau INBOX pour confirmer, ou appuyez sur Continuer pour utiliser « Ostler »"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX signifie que l'assistant lira chaque e-mail que vous recevez. Nous recommandons fortement un libellé/dossier dédié à la place."

MSG_PROMPT_EXPORTS_ACK_TITLE="Avez-vous demandé vos exports de données ?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler importe depuis une vingtaine de plateformes. La liste complète, avec des liens directs vers la page de demande de chaque fournisseur, se trouve sur docs.ostler.ai/data-exports.

La plupart des archives arrivent par e-mail sous 1 à 3 jours. Lorsque les ZIP arrivent, déposez-les dans votre dossier Téléchargements et Ostler les trouvera automatiquement.

Ignorez celles que vous n'utilisez pas ; vous pourrez toujours en importer davantage plus tard."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="Continuer sans FileVault ?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="FileVault est fortement recommandé. Sans lui, un accès physique à votre Mac signifie un accès à vos données."

MSG_PROMPT_PASSKEY_ACK_TITLE="Prêt à configurer le chiffrement du disque"
MSG_PROMPT_PASSKEY_ACK_HELP="Votre graphe de connaissances est chiffré avec une phrase secrète que vous choisirez à l'écran suivant. Vous saisirez cette phrase secrète à chaque démarrage de l'interface du Hub. Une clé de récupération distincte est également générée et affichée une seule fois à la fin de l'installation. Appuyez sur Continuer lorsque vous êtes prêt."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="Définir aussi une phrase secrète de récupération ? (recommandé)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="Choisissez votre phrase secrète"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="Cette phrase secrète chiffre votre graphe de connaissances et déverrouille l'interface du Hub à chaque démarrage. Au moins 12 caractères. Nous ne pouvons pas la récupérer pour vous. Il est recommandé de la stocker dans un gestionnaire de mots de passe."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="Confirmez votre phrase secrète"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="Ressaisissez la même phrase secrète pour confirmer."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="Les importer pendant l'installation ?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="Les exports RGPD trouvés seront importés dans votre graphe de connaissances pendant l'installation."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="Avez-vous des exports de données prêts ?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler peut importer des archives de réseaux sociaux et de plateformes : tout votre historique avec vos amis, votre famille, les lieux, vos opinions, dès le départ. Plus Ostler en sait dès le premier jour, plus il est utile dès le premier jour. Vous pouvez aussi ajouter cela plus tard ; rien ne presse.

Demandez votre export de données à chaque plateforme (Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp, etc.), téléchargez les fichiers ZIP et déposez-les dans votre dossier Téléchargements.

Ostler regardera dans ~/Downloads par défaut. Vous voulez un autre dossier ? Choisissez-en un ci-dessous. Sinon, ignorez et importez plus tard."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="Importer les messages Gmail depuis ce Takeout ?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Lit le contenu Gmail directement depuis le fichier Takeout. Google ne voit jamais Ostler."

MSG_PROMPT_FDA_PRESET_TITLE="De quelles sources Mac Ostler doit-il apprendre ?"
MSG_PROMPT_FDA_PRESET_HELP="Trois préréglages, ou choisissez chacun vous-même. Les sources sensibles (reconnaissance faciale) sont désactivées par défaut dans chaque préréglage : choisissez-les délibérément si vous les voulez."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="Recommandé. Comprend Apple Mail, Contacts, Calendrier, Notes, Messages, Rappels, l'historique Safari et les signets Safari. L'historique de WhatsApp Desktop et l'historique Chrome sont ajoutés automatiquement lorsque l'app est installée. Exclut les données de reconnaissance faciale de Photos et toute archive d'export tierce."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="Tout. Recommandé + les événements Photos (sans reconnaissance faciale). La reconnaissance faciale de Photos reste désactivée jusqu'à ce que vous la cochiez délibérément."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="Personnaliser. Choisissez chaque source à l'écran suivant. Les sources sensibles restent désactivées jusqu'à ce que vous les cochiez."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="Activez ou désactivez cette source de données."

MSG_PROMPT_CONSENT_ARTICLE_9_TITLE="Votre décision (O / N)"
MSG_PROMPT_CONSENT_ARTICLE_9_HELP="Consentement de catégorie particulière de l'Article 9 (RGPD britannique). Requis comme base légale du traitement."

MSG_PROMPT_CONSENT_VOICE_EU_TITLE="Reconnaître les voix sur vos enregistrements d'appels ?"
MSG_PROMPT_CONSENT_VOICE_EU_HELP="La reconnaissance des locuteurs reste sur ce Mac. Creative Machines ne reçoit jamais les empreintes."

MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE="Une dernière chose : comment fonctionnent les données tierces"
MSG_PROMPT_CONSENT_THIRD_PARTY_HELP="Toutes les données que vous importez de tiers (Google Takeout, téléchargements Meta, exports LinkedIn, etc.) restent sur ce Mac. Ostler les stocke dans votre graphe de connaissances local ; rien ne quitte votre appareil.

En continuant, vous comprenez et acceptez que vous êtes seul responsable du traitement et de la conservation de ces données sur votre machine, tout comme les e-mails déjà présents sur votre disque dur.

Note juridique : Pour les enregistrements que vous importez sur ce Mac, vous êtes le responsable du traitement au sens du droit britannique et européen (RGPD britannique Article 4(7) et 4(8)). Creative Machines ne reçoit jamais ces données et n'en est pas le responsable. Votre traitement à des fins personnelles et domestiques relève de l'Article 2(2)(c) du RGPD britannique/de l'UE.

En savoir plus sur docs.ostler.ai/privacy/third-party-data."

MSG_PROMPT_CONSENT_INSTALL_TITLE="Prêt à installer ?"
MSG_PROMPT_CONSENT_INSTALL_HELP="Veuillez saisir INSTALL pour confirmer que vous acceptez les conditions."
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Saisissez INSTALL"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Installer Ostler"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Annuler"
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Saisissez INSTALL exactement (la casse importe peu) pour confirmer, ou cliquez sur Annuler pour revenir en arrière."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="Connectez votre iPhone et votre Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale donne à ce Mac une adresse privée stable que votre iPhone et votre Watch peuvent joindre depuis n'importe où : chiffrée, sans aucune exposition publique."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="Enregistrer la clé de récupération dans le trousseau ?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="Stocke votre clé de récupération de chiffrement dans le trousseau macOS pour la conserver en sécurité."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="Hydratation de votre graphe"
MSG_HYDRATE_CONTACTS_STARTED="Import de vos contacts dans le graphe"
MSG_HYDRATE_CONTACTS_DONE="%s contacts importés"
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="Chargement de vos 90 derniers jours de calendrier (l'historique plus ancien se remplit en arrière-plan)"
MSG_HYDRATE_CALENDAR_DONE="%s événements importés"
MSG_HYDRATE_WIKI_RECOMPILE="Construction de votre wiki. Ostler rédige un court résumé pour chacune de vos personnes, organisations et sujets clés ; pour un grand carnet d'adresses, cela peut donc prendre de quelques minutes jusqu'à environ une heure. Cela ne se produit qu'une seule fois, s'exécute entièrement sur votre Mac et vous pouvez laisser faire en toute tranquillité."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="Vérification de votre index de recherche (%s collections détectées)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="Chargement de votre historique de navigation dans l'index de recherche"
MSG_INITIAL_HYDRATE_QDRANT_READY="Index de recherche prêt (%s collections)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="L'index de recherche se remplira en arrière-plan une fois l'installation terminée"
MSG_HYDRATE_DONE="Votre graphe est prêt : %s personnes, %s événements"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud est peut-être encore en train de synchroniser vos contacts : réexport en cours pour récupérer tout ce qui vient d'arriver."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="Aucun contact trouvé dans votre app Contacts (local ou iCloud). Ajoutez-en dans Contacts et relancez depuis les Réglages."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="Aucun contact iCloud à importer. Vous pourrez l'ajouter plus tard depuis les Réglages."
MSG_HYDRATE_SKIPPED_NO_EVENTS="Aucun événement de calendrier au cours des 5 dernières années. Vous pourrez en récupérer plus tard depuis les Réglages."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="Lecture de vos 90 derniers jours d'e-mails : vos e-mails restent sur ce Mac (l'historique plus ancien se remplit en arrière-plan)"
MSG_HYDRATE_EMAIL_DONE="%s personnes trouvées dans vos e-mails récents"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="Aucun e-mail récent à lire. Vous pouvez ajouter un compte Mail dans Apple Mail et relancer plus tard."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="Lecteur d'e-mails pas encore prêt. Vous pouvez ajouter un compte Mail dans Apple Mail et relancer plus tard."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="Les e-mails se chargent encore en arrière-plan : votre wiki se remplira au cours de la prochaine heure."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="Ouvrir Apple Mail pour qu'il commence à se synchroniser ?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="Vous avez %s compte(s) de messagerie configuré(s), mais Apple Mail n'a encore récupéré aucun message. Nous pouvons ouvrir Mail.app maintenant et attendre pendant qu'il se synchronise."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="Ouvrir Calendrier pour qu'il commence à se synchroniser ?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="Vous avez %s compte(s) de calendrier configuré(s), mais Calendrier.app n'a encore aucun événement stocké. Nous pouvons ouvrir Calendrier maintenant et attendre pendant qu'il se synchronise depuis iCloud."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="Ouvrir Contacts pour qu'il commence à se synchroniser ?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="Vous avez %s compte(s) de contacts configuré(s), mais Contacts.app n'a encore aucune entrée stockée. Nous pouvons ouvrir Contacts maintenant et attendre pendant qu'il se synchronise depuis iCloud."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="En attente du début de la synchronisation de %s (jusqu'à %s secondes)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="Toujours en attente de la synchronisation de %s (%ss écoulées, %ss restantes). La première synchronisation iCloud peut prendre quelques minutes lors d'une nouvelle connexion."
MSG_OK_APP_HAS_POPULATED="%s a rempli son stockage local. Poursuite."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="Nous n'avons pas détecté la synchronisation de %s dans le délai d'attente. Poursuite ; vous pourrez relancer l'hydratation depuis les Réglages plus tard."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="Comptes Apple Mail visibles : %s. Ouvrez Mail.app une fois pour qu'il commence à récupérer les messages."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="Comptes Calendrier visibles : %s. Ouvrez Calendrier.app une fois pour qu'il synchronise vos événements."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="Comptes Contacts visibles : %s. Ouvrez Contacts.app une fois pour qu'il synchronise votre carnet d'adresses."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="Impossible de lire vos Contacts. Ostler les lit via l'accès complet au disque : accordez-le dans Réglages Système > Confidentialité et sécurité > Accès complet au disque, puis relancez l'hydratation depuis les Réglages. Nous continuerons à réessayer en arrière-plan."
MSG_HYDRATE_CONTACTS_PENDING="Votre app Contacts ne s'est pas encore synchronisée. Ouvrez Contacts une fois, attendez la synchronisation, puis relancez l'hydratation depuis les Réglages."
MSG_HYDRATE_CONTACTS_READ_FAILED="Vos contacts sont sur ce Mac mais Ostler n'en a importé aucun, ce qui est inattendu. L'import réessaiera automatiquement en arrière-plan. Si cela persiste, relancez l'hydratation depuis les Réglages ou consultez le journal d'installation."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler continuera de vérifier en arrière-plan et importera automatiquement vos contacts une fois qu'iCloud aura terminé la synchronisation."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="Nouveaux contacts importés ; reconstruction de votre wiki en arrière-plan."
MSG_HYDRATE_CALENDAR_PENDING="Votre app Calendrier n'a pas encore synchronisé ses événements. Ouvrez Calendrier une fois, attendez la synchronisation, puis relancez l'hydratation depuis les Réglages."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="Impossible de lire votre calendrier cette fois (l'extracteur a signalé une erreur, et non un calendrier vide). Vos autres données n'ont pas été affectées ; consultez /tmp/ostler-hydrate-calendar.log, puis relancez l'hydratation depuis les Réglages."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="Lecture de votre historique WhatsApp : vos messages restent sur ce Mac"
MSG_HYDRATE_WHATSAPP_DONE="%s personnes trouvées dans vos conversations WhatsApp"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="Aucune conversation WhatsApp à lire. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktop n'est pas installé. Installez-le depuis le Mac App Store et relancez depuis les Réglages."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="Lecteur WhatsApp pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp se charge encore en arrière-plan : votre wiki se remplira au cours de la prochaine heure."

# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="Import de votre historique de navigation : vos visites restent sur ce Mac"
MSG_HYDRATE_BROWSING_DONE="%s pages d'historique de navigation importées"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="%s pages signalées comme sensibles ignorées (banque, santé, etc.)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="Aucun historique de navigation à importer. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="Lecteur d'historique de navigation pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="L'historique de navigation se charge encore en arrière-plan : votre wiki se remplira au cours de la prochaine heure."

# Preferences import counts-only confirmation, shown by phase 3.12b after
# the shared ostler-import fan-out runs. The other hydrate_preferences
# strings were removed when the standalone block was collapsed into the
# shared importer; only this done-count line is still referenced.
# Privacy: enrich's lookup clients call PUBLIC item-metadata APIs only
# (about the item, never the user); this string is a count.
MSG_HYDRATE_PREFERENCES_DONE="%s préférences importées et enrichies"

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="Configuration de l'enrichissement des préférences (unique)"
MSG_CM019_SETUP_DONE="Enrichissement des préférences prêt"
MSG_CM019_SETUP_FAILED="La configuration de l'enrichissement des préférences ne s'est pas terminée. Vos pages de préférences se rempliront une fois le problème corrigé ; le reste d'Ostler n'est pas affecté."
MSG_CM019_SETUP_EXISTS="Enrichissement des préférences déjà configuré"
MSG_CM019_SETUP_SKIPPED="Pipeline d'enrichissement des préférences non inclus ; ignoré pour le moment."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="Lecture de votre historique iMessage : vos messages restent sur ce Mac"
MSG_HYDRATE_IMESSAGE_DONE="%s personnes trouvées dans votre historique iMessage"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="Aucun historique iMessage à lire. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="Lecteur iMessage pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage se charge encore en arrière-plan : votre wiki se remplira au cours de la prochaine heure."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="Indexation de vos personnes pour la recherche"
MSG_HYDRATE_PEOPLE_DONE="%s personnes indexées pour la recherche"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="Aucune personne à indexer pour l'instant. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="Indexeur de personnes pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="Indexation de vos personnes encore en cours en arrière-plan ; la recherche se remplira sous peu."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="Trois demandes d'accès aux dossiers à venir"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="La boîte de dialogue des Command Line Tools est apparue devant cette fenêtre : cliquez sur Installer dessus, puis revenez ici (ou patientez quelques secondes, nous ramènerons cette fenêtre au premier plan pour vous). Les outils se téléchargent en arrière-plan pendant que vous continuez à répondre aux questions ci-dessous ; rien ici n'est bloqué."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="Autorisation nécessaire : automatisation iMessage"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostler va maintenant demander à macOS l'autorisation de communiquer avec Messages.app. macOS affichera une fenêtre indiquant \"OstlerInstaller souhaite contrôler Messages\" : cliquez sur Autoriser pour que l'assistant puisse envoyer et recevoir des iMessages en votre nom. Sans cette autorisation, les iMessages ne quitteront jamais la machine, silencieusement. Il s'agit d'un octroi unique ; vous pourrez le modifier plus tard dans Réglages Système > Confidentialité et sécurité > Automatisation."

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="Votre clé de récupération"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="Notez-la ou imprimez-la maintenant. C'est le seul moyen de récupérer l'accès si vous perdez votre phrase secrète ET que votre trousseau devient inaccessible. Ostler ne peut pas la récupérer pour vous : la clé ne quitte jamais ce Mac et n'est stockée sur aucun serveur."
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="Je l'ai enregistrée en lieu sûr"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="Copier dans le presse-papiers"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="Enregistrer au format PDF..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="Imprimer..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="Continuer"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Clé de récupération Ostler.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Clé de récupération Ostler"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="Clé de récupération copiée dans le presse-papiers"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="Clé de récupération enregistrée dans %s"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="Appairez votre iPhone"
MSG_INFO_PAIR_IPHONE_HELP="Ouvrez l'app Ostler sur votre iPhone et scannez ce QR code pour le relier à ce Hub. Vous pouvez aussi l'appairer plus tard depuis le menu Réglages du Hub."
MSG_INFO_PAIR_IPHONE_FETCHING="Génération du code d'appairage..."
MSG_INFO_PAIR_REFRESH="Actualiser le code"
MSG_ERR_PAIR_FETCH_FAILED="Impossible de joindre la passerelle Ostler pour l'instant. Elle est peut-être encore en cours de démarrage : cliquez sur Actualiser pour réessayer."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agent non inclus dans le programme d'installation. Le LaunchAgent des briefings quotidiens + maintien de connexion WhatsApp ne se chargera pas."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Scripts wiki-recompile non inclus dans le programme d'installation. Le wiki ne se mettra pas à jour automatiquement."

# F3 - legal package missing
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="Paquet legal non inclus dans le programme d'installation. Les contrôles de consentement Article 9 / WhatsApp / voix déclencheront une ModuleNotFoundError jusqu'à la réinstallation."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s installé dans %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s déjà installé, laissé en place"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Architecture de processeur non prise en charge pour Google Workspace CLI ; fonctionnalités Gmail / Google Calendar dégradées."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl non disponible ; installation de Google Workspace CLI ignorée. Fonctionnalités Gmail / Google Calendar dégradées."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="Impossible de télécharger Google Workspace CLI depuis %s"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="Non-concordance SHA256 de Google Workspace CLI (attendu %s, obtenu %s). Installation de ce binaire abandonnée."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="L'archive Google Workspace CLI n'a pas pu être extraite."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI installé dans %s mais la vérification --version a échoué."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="Passerelle de calendrier iCloud / CalDAV installée dans %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="La passerelle de calendrier iCloud / CalDAV dans %s n'est pas exécutable. Le calendrier ne renverra aucun événement."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh non inclus dans le programme d'installation. La nouvelle tentative d'enregistrement d'appareil au prochain réseau est désactivée."

# ── Parity top-up 2026-07-12 (MACHINE DRAFT) ──
# Keys added to en-GB between the 2026-05-19 extraction and 2026-07-12.
# Machine-draft translations; review before shipping a localised installer.

MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="Docker n'était pas prêt à temps pour démarrer les bases de données du graphe de connaissances. Vérifiez que Colima ou Docker est en cours d'exécution, puis relancez le programme d'installation."

MSG_FAIL_GRAPH_DB_PULL_FAILED="Impossible de télécharger les images des bases de données du graphe de connaissances après plusieurs tentatives. C'est généralement un problème de réseau. Vérifiez votre connexion Internet et relancez le programme d'installation."

MSG_FAIL_GRAPH_DB_UP_FAILED="Les bases de données du graphe de connaissances ont été téléchargées mais n'ont pas pu démarrer. Relancez le programme d'installation ; si le problème persiste, ouvrez le Terminal et exécutez : cd ~/.ostler && docker compose up -d qdrant oxigraph redis"

MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="%s contacts importés avec des numéros de téléphone mais presque sans adresses e-mail (%s téléphone contre %s e-mail). Cela signifie généralement que le lecteur de contacts a perdu les e-mails. Vos contacts restent utilisables ; consultez /tmp/ostler-hydrate-contacts.log et relancez l'import des données depuis les Réglages une fois le problème résolu."

MSG_HYDRATE_EMAIL_HEARTBEAT="  Lecture de vos e-mails en cours (%ss pour l'instant). Cela peut prendre un moment sur un Mac avec des années d'historique."

MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="Les préférences e-mail se chargent encore en arrière-plan. Votre wiki se remplira sous peu."

MSG_HYDRATE_EMAIL_PREFERENCES_DONE="%s préférences chargées depuis votre historique e-mail"

MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  Chargement de vos préférences e-mail en cours (%ss pour l'instant). Un historique volumineux peut prendre quelques minutes."

MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="Aucun fichier de préférences e-mail configuré. Rien à charger."

MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="Aucun fichier de préférences e-mail trouvé à %s. Rien à charger."

MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="Le pipeline de préférences n'est pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."

MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="Chargement de vos préférences e-mail. Tout reste sur ce Mac et cela peut prendre quelques minutes."

MSG_HYDRATE_IMESSAGE_HEARTBEAT="  Lecture de votre historique iMessage en cours (%ss pour l'instant). Un historique volumineux peut prendre plusieurs minutes."

MSG_HYDRATE_PLACES_DONE="Votre section Places a été créée"

MSG_HYDRATE_PLACES_ERROR_WARN="La construction de Places ne s'est pas terminée (erreur inattendue). Votre page Places est peut-être incomplète. Voir /tmp/ostler-places-ingest.log"

MSG_HYDRATE_PLACES_GUARD_WARN="La construction de Places a rencontré un problème : des signaux de localisation existent mais aucun lieu n'a été produit. Votre page Places peut rester vide. Voir /tmp/ostler-places-ingest.log"

MSG_HYDRATE_PLACES_SKIPPED="Aucun signal de localisation trouvé pour l'instant ; Places se remplira au fur et à mesure que votre calendrier se remplit"

MSG_HYDRATE_PLACES_STARTED="Construction de vos lieux (Places) à partir des endroits où vous avez vos rendez-vous"

MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="Redémarrage de l'assistant pour qu'il prenne en compte l'accès complet au disque que vous venez d'accorder (nécessaire pour lire votre historique Messages)."

MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="Une dernière autorisation (historique Messages pour votre assistant) arrive vers la fin, une fois votre assistant installé – nous vous l'indiquerons à ce moment-là."

MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="Contacts en double entièrement fusionnés pendant l'installation ; aucun rattrapage en arrière-plan nécessaire"

MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="La plupart des contacts en double ont été fusionnés. Le reste se terminera en arrière-plan après l'installation – votre wiki se mettra à jour automatiquement."

MSG_INFO_DEDUPE_MERGED="Contacts en double fusionnés"

MSG_INFO_DEDUPE_STILL_MERGING="Fusion des contacts en double en cours – les gros carnets d'adresses peuvent prendre plusieurs minutes (%ss écoulées)"

MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="Accordez l'accès dans Réglages Système > Confidentialité et sécurité > Fichiers et dossiers (ou Accès complet au disque), puis relancez, ou indiquez manuellement à Ostler votre dossier d'exports ci-dessous."

MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="Impossible d'analyser un ou plusieurs dossiers à la recherche d'exports de données car macOS a bloqué l'accès. Accordez l'accès et relancez, ou indiquez-moi manuellement votre dossier d'exports."

MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="L'accès complet au disque pour le programme d'installation est réglé. À partir d'ici, la longue installation se déroule toute seule – vous pouvez vous éloigner."

MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="Installation de GNU coreutils (pour limiter la durée des étapes longues)..."

MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  Installation de la dépendance de stockage chiffré dans le venv de la mémoire de conversations..."

MSG_INFO_PULLING_GRAPH_DB_IMAGES="Téléchargement des bases de données du graphe de connaissances (premier lancement uniquement). Cela peut prendre une minute sur une installation neuve..."

MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="Une dernière étape manuelle : ouvrez Safari, choisissez Safari > Réglages > Extensions, puis cochez Ostler pour l'activer."

MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="C'est noté – vous pouvez vous éloigner pendant qu'Ostler s'installe. Vers la fin, il reste une courte étape facultative : la connexion à Tailscale pour que votre iPhone et votre Watch puissent joindre ce Mac depuis n'importe où. Nous ouvrirons alors votre navigateur."

MSG_MODELFIT_HEADER="Choix du modèle d'assistant adapté à votre Mac (%s, %s Go de RAM, contexte de l'assistant %s tokens) :"

MSG_MODELFIT_PILL_FITS="Convient"

MSG_MODELFIT_PILL_NOFIT="Ne convient pas"

MSG_MODELFIT_PILL_SLOW="Peut être lent"

MSG_MODELFIT_RECOMMENDED_TAG="  <- Recommandé"

MSG_MODELFIT_ROW="  %s  %s (%s, %s)"

MSG_MODELFIT_SELECTED="Modèle d'IA : %s (%s) – le mieux adapté à vos %s Go de RAM pour la fenêtre de contexte requise par l'assistant"

MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils installé (les étapes longues ont désormais une durée maximale)"

MSG_OK_DEDUPE_CATCHUP_LOADED="LaunchAgent de déduplication des contacts en arrière-plan chargé (termine la fusion des doublons après l'installation, puis s'arrête)"

MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="Continuer"

MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostler va lire les données de votre Mac, mais l'accès complet au disque pour OstlerInstaller est encore désactivé. Trouvez \"OstlerInstaller\" dans Réglages Système (ouvert sur Accès complet au disque) et activez-le."

MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="Ou cliquez simplement sur Continuer pour terminer l'installation avec moins de données – vous pourrez accorder l'accès et relancer l'extracteur plus tard."

MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="Accès complet au disque encore requis"

# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_STEP_SETUP_COMPLETE_WRAP_UP="Questions done. Ostler is now installing in the background – this part takes roughly 15 to 60 minutes and needs nothing further from you, so you can leave it running and check back later."

MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="GNU coreutils n'a pas pu être installé ; les étapes longues s'exécuteront sans durée maximale (une ligne de progression montre toujours qu'elles travaillent)."

MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="Le LaunchAgent de déduplication des contacts en arrière-plan n'a pas pu être chargé. Les doublons seront tout de même fusionnés par la passe de maintenance quotidienne ; cela prendra simplement plus de temps."

MSG_WARN_DEDUPE_INCOMPLETE="La passe de déduplication sur tout le graphe ne s'est pas terminée proprement (voir %s) ; on continue"

MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="Impossible de lire %s pour rechercher des exports de données. macOS bloque l'accès à ce dossier."

MSG_WARN_GRAPH_DB_PULL_RETRY="Le téléchargement de la base de données ne s'est pas terminé (tentative %s sur %s). Nouvelle tentative dans %ss..."

MSG_WARN_GRAPH_DB_UP_RETRY="Les bases de données du graphe de connaissances n'ont pas démarré (tentative %s sur %s). Nouvelle tentative..."

MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  Impossible d'installer la dépendance de stockage chiffré dans le venv de la mémoire de conversations ; l'enrichissement des conversations ne fonctionnera pas."

MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  Source de la dépendance de stockage chiffré introuvable dans SCRIPT_DIR ; le moteur de mémoire de conversations ne peut pas se charger et l'enrichissement des conversations ne fonctionnera pas."

MSG_WARN_PREFS_HEADLINE_HINT="Cela signifie généralement qu'aucun export musique/restauration (Spotify, Apple Music, Uber Eats, Google Takeout) n'était présent, ou que les données n'ont pas été catégorisées. Ajoutez ces exports, relancez depuis les Réglages, puis reconstruisez le wiki."

MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="%s préférences importées, mais aucune ne relève de Food, Music ou Professional. Vos pages wiki Food et Music seront vides."

MSG_WARN_PREFS_UNCATEGORISED="%s préférences sur %s (%s%%) n'ont pas de catégorie et n'apparaîtront sur aucune page de sujet. Vérifiez le format de l'export source."
