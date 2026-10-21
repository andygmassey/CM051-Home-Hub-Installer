#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to fr by l10n/ostler_l10n.py.
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

MSG_STEP_CHECKING_PREREQUISITES="Vérification des prérequis"
MSG_STEP_RUNNING_HEALTH_CHECK="Exécution du contrôle d’état"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="Connectez votre iPhone et votre Watch"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="Configuration (quelques questions rapides, puis l’installation se poursuit d’elle-même)"
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
MSG_STEP_SETUP_COMPLETE_WRAP_UP="Questions terminées. Ostler s’installe maintenant en arrière-plan, en 45 minutes à quelques heures environ. Trois étapes auront encore besoin de vous : si macOS propose d’installer les outils de développement, cliquez sur Installer ; vers la fin, une minute de configuration est nécessaire (activation de l’Accès complet au disque) ; et tout à la fin, après le contrôle d’état, vous vous connectez à Tailscale et autorisez l’assistant à utiliser Rappels. Entre ces étapes, vous pouvez le laisser tourner."
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="Questions terminées. Ostler s’installe maintenant en arrière-plan, en 45 minutes à quelques heures environ. Trois étapes auront encore besoin de vous : si macOS propose d’installer les outils de développement, cliquez sur Installer ; vers la fin, une minute de configuration est nécessaire (activation de l’Accès complet au disque) ; et tout à la fin, vous autorisez l’assistant à utiliser Rappels. Entre ces étapes, vous pouvez le laisser tourner."

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="puis relancez : ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="Redémarrage de l’assistant pour qu’il puisse utiliser l’Accès complet au disque et lire l’historique de vos Messages. Un redémarrage est nécessaire pour qu’une autorisation tout juste accordée prenne effet ; si vous ne l’avez pas encore accordée, le tableau de bord Doctor continuera de vous guider."
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="Votre assistant est en cours d’exécution et dispose de l’Accès complet au disque : il peut donc lire les fichiers dont il a besoin."
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="Votre assistant est en cours d’exécution, mais il ne dispose pas encore de l’Accès complet au disque. Tant que vous ne l’avez pas activé, Ostler ne peut pas tenir à jour Messages, Mail, Calendrier, Rappels, Notes, Photos, Safari, Contacts ni WhatsApp, et ne peut pas lire votre dossier Documents. Ce qu’il a déjà lu est conservé. Le tableau de bord Doctor vous guidera pour l’activer."
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="Votre assistant est en cours d’exécution. Nous n’avons pas pu vérifier s’il dispose de l’Accès complet au disque sur ce Mac : ce n’est donc une confirmation ni dans un sens ni dans l’autre. Le tableau de bord Doctor vous le dira dès qu’il pourra le vérifier."
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="Comptes Apple Mail visibles : %s (à titre indicatif)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mail ne semble pas encore contenir de messages en local. Doctor vous proposera un suivi si aucun e-mail n’arrive dans les 24 heures."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mail contient des messages en cache. L’ingestion les récupérera au prochain passage horaire."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="Apple Mail est sélectionné, mais aucun message local n’est encore disponible à la lecture sur ce Mac. Ouvrez Apple Mail et ajoutez un compte (Réglages Système > Comptes Internet, puis cochez Mail), et laissez-le terminer une première synchronisation."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="Une fois les e-mails arrivés, relancez : ostler-fda. Ostler les prendra en compte automatiquement ; rien d’autre n’est nécessaire."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="La notarisation Apple sera vérifiée par Gatekeeper au premier lancement."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="disponible, l’installateur ignorera automatiquement cette étape."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="Les bêta-testeurs ayant accès peuvent définir PWG_PIPELINE_REPO=<url> et relancer."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="Les bêta-testeurs ayant accès peuvent définir PWG_KNOWLEDGE_REPO=<url> et relancer."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="Extensions de navigateur ignorées (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  Cloné dans %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture ne fonctionne que sur Apple Silicon. Installation ignorée sur cette machine."
MSG_INFO_CM042_LOGS_AT="Journaux de RemoteCapture : %s/ostler-remotecapture.log (et .err)"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="Une installation précédente lançait Ostler RemoteCapture à l’ouverture de session. Il a été arrêté et ne redémarrera plus."
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="Ostler RemoteCapture n’a pas été installé : vous avez choisi de laisser la transcription vocale désactivée. Activez-la dans les réglages et relancez l’installateur si vous changez d’avis."
MSG_INFO_CM042_TCC_PRE_PROMPT="Au premier lancement, Ostler RemoteCapture demandera à macOS l’autorisation Enregistrement de l’écran et Microphone. Accordez les deux pour que les appels et les réunions puissent être transcrits en local. Aucun indicateur violet d’enregistrement n’apparaît dans votre barre des menus : la capture audio est silencieuse par conception."
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
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="Ostler enregistre votre wiki personnel et vos comptes rendus de conversations dans Documents/Ostler, sur ce Mac. Ils vous appartiennent et restent sur cette machine. Pour les écrire, Ostler a besoin d’accéder à votre dossier Documents : macOS peut donc vous le demander pendant la configuration, puis de nouveau plus tard dans la journée, lorsque Ostler organisera votre wiki pour la première fois. La demande peut sembler provenir de python3.11, l’outil intégré qu’Ostler utilise pour écrire vos fichiers. Cliquez sur Autoriser chaque fois qu’elle apparaît. Si vous la manquez ou la refusez, vous pouvez l’activer à tout moment dans Réglages Système, sous Confidentialité et sécurité, puis Fichiers et dossiers ; votre wiki et vos comptes rendus de conversations seront alors écrits à partir de ce moment."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  Moteur de mémoire des conversations installé dans venv."
MSG_INFO_HUB_APP_VERIFYING="Vérification d’Ostler.app dans %s"
MSG_INFO_HUB_APP_STAGING="Copie d’Ostler.app dans /Applications depuis %s"
MSG_INFO_HUB_APP_DRAG_HINT="Ouvrez l’image disque de l’installateur et faites glisser Ostler.app et OstlerInstaller.app sur le raccourci Applications, puis relancez l’installateur."
MSG_OK_HUB_APP_PRESENT="Ostler.app est déjà présent dans %s ; signature vérifiée."
MSG_OK_HUB_APP_STAGED="Ostler.app installé dans %s"
MSG_WARN_HUB_APP_NOT_FOUND="Ostler.app est introuvable dans /Applications et aucune copie intégrée n’est disponible."
MSG_WARN_HUB_APP_VERIFY_FAILED="La vérification de la signature ou de la notarisation d’Ostler.app a échoué. Le paquet est laissé en place pour que l’assistance puisse l’examiner."
MSG_OK_UNINSTALLER_APP_STAGED="Ostler Uninstaller.app installé dans %s"
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="Impossible de placer Ostler Uninstaller.app dans /Applications. Vous pouvez tout de même désinstaller en exécutant : ~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="Clonage de l'agent Doctor..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="Clonage des scripts d'ingestion des e-mails..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Clonage des scripts hub-power..."
MSG_INFO_CLONING_IMPORT_PIPELINE="Clonage du pipeline d'importation..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="Clonage des scripts wiki-recompile..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima est installé mais n'est pas en cours d'exécution. Il va être démarré."
MSG_INFO_COLIMA_START_ATTEMPT="Démarrage de Colima (tentative %s sur %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="Impossible d'exporter les contacts. Vous pourrez les importer manuellement plus tard."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="Impossible de lire la fiche de contact. Pas de souci : nous vous poserons la question."
MSG_INFO_CONTACT_CARD_WILL_ASK="Nous vous demanderons dans un instant votre nom et votre pays. Vos contacts seront lus plus tard grâce à l'Accès complet au disque que vous accordez, et rien ne quitte ce Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  Création de l'environnement virtuel Python dans %s..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="Création de l'arborescence de contenu utilisateur dans %s/"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="Exécution quotidienne. Lancement manuel : bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="Hub de bureau (sans batterie) détecté : désactivation de la veille pour tout le système"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker n'est pas installé. Colima, la CLI Docker et le plugin docker-compose seront installés (solution légère, Docker Desktop n'est pas nécessaire)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="Les fichiers de l'agent Doctor ne sont pas inclus dans l'installateur."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="Les scripts d'ingestion des e-mails ne sont pas inclus dans l'installateur."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="Les scripts d'ingestion des e-mails sont absents du paquet de l'installateur. Téléchargez de nouveau l'app depuis ostler.ai/install, puis réessayez."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Les scripts d'ingestion des e-mails ne sont pas inclus et --allow-plaintext a été transmis ; l'installation du LaunchAgent sera ignorée. Les prochains e-mails ne seront pas récupérés."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  Copie existante dans %s ; mise à jour..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Extraction du mbox Gmail depuis l'archive zip Takeout (cela peut prendre une minute pour les grandes archives)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="Le module d'extraction FDA n'est pas inclus. L'extraction instantanée des données est ignorée."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Activation de vos 30 premiers jours d'Ostler Pro..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Après la période d'essai, Ostler Pro coûte 9,99 USD par mois. Abonnez-vous dans l'app Ostler sur votre iPhone."
MSG_INFO_FOUND_GMAIL_MBOX_MB="Mbox Gmail trouvé dans %s (%s Mo)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Archive zip Google Takeout trouvée dans %s (%s Mo)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="Accès complet au disque détecté : extraction complète disponible."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="Des exports RGPD ont été détectés, mais le pipeline d'importation n'est pas encore disponible."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="L'importation des exports RGPD sera disponible à la sortie du pipeline."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="Nous allons analyser Téléchargements, Bureau et Documents à la recherche d'exports d'IA (Google Takeout, téléchargements Meta, LinkedIn, etc.) que vous auriez enregistrés. macOS affichera trois demandes d'accès aux dossiers : veuillez les autoriser une par une. Cela prend environ 5 à 10 secondes au total. Rien n'est déplacé ni copié pendant l'analyse ; nous vérifions seulement ce qui s'y trouve."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS peut vous demander l'autorisation de lire votre Calendrier. Autorisez-la pour qu'Ostler puisse construire la partie réunions et événements de votre graphe de connaissances. (Les données du Calendrier restent sur cette machine.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS demande l'autorisation pour Téléchargements. Cliquez sur OK."
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS demande l'autorisation pour Bureau. Cliquez sur OK."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS demande l'autorisation pour Documents. Cliquez sur OK."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="Accès complet au disque accordé. Préparation de la prochaine demande macOS (automatisation de Messages)..."
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="Aucune réponse à la demande d'autorisation pour Messages, nous avons donc poursuivi. Vos messages ne seront pas lus tant qu'elle n'est pas accordée. Ostler vous la redemandera, ou vous pouvez l'accorder dans Réglages Système > Confidentialité et sécurité > Automatisation."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="Les outils de ligne de commande Xcode sont nécessaires. macOS va demander l'autorisation de les installer – cherchez une petite boîte de dialogue grise (si vous ne la voyez pas, appuyez sur Cmd+Tab ou regardez dans votre Dock). Cliquez sur Installer. Les outils se téléchargent en arrière-plan pendant que vous répondez aux questions ci-dessous."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  Configuration des outils de ligne de commande toujours en cours (%ss). Si une petite boîte de dialogue grise de macOS vous propose d'installer les outils de développement, cliquez sur Installer : cette étape attend votre réponse. (Appuyez sur Cmd+Tab ou regardez dans le Dock si vous ne la voyez pas.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="En attente de la fin de l'installation des outils de ligne de commande (presque terminé)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="Exécution toutes les heures. La première exécution récupère les 5 dernières années d'e-mails."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="Désactivation de l'ancien LaunchAgent du pont iMessage (v1.0 sur une seule machine)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Hub sur secteur uniquement (aucune batterie détectée) : le LaunchAgent hub-power est ignoré."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Les scripts d'alimentation du Hub ne sont pas inclus dans l'installateur."
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="Hub sur portable. Il continue de fonctionner tant que l'écran est ouvert et que le Mac est branché sur secteur."
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="Si vous fermez l'écran ou laissez le Mac inactif sur batterie, macOS le met en veille."
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="Pendant la veille, l'assistant ne reçoit rien."
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="Les messages arrivés pendant ce temps ne sont pas récupérés au réveil."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="L'écran peut rester fermé en mode écran fermé."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="Cela nécessite le secteur, un écran externe, un clavier et une souris."
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="Docker et Ollama se mettent en pause sur batterie et reprennent sur secteur."
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="Après un redémarrage, FileVault garde ce Mac sur l'écran de connexion."
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="Ostler démarre dès que vous ouvrez votre session."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="API de l'assistant incluse dans l'installateur : utilisation des sources intégrées."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="Sources de l'API de l'assistant non incluses : l'app Ostler sur votre iPhone aura un accès limité."
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="Installation des dépendances d'exécution de l'API de l'assistant (phonenumbers, httpx)..."
MSG_WARN_ICAL_SERVER_DEPS_FAILED="Impossible d'installer les dépendances d'exécution de l'API de l'assistant (phonenumbers/httpx) ; Personnes et Chronologie risquent de rester vides jusqu'à la prochaine installation."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Quand la fenêtre Tailscale apparaît, connectez-vous avec Apple / Google / Microsoft."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="Ouverture de Tailscale pour que vous puissiez vous connecter..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="C'est noté – Ostler s'installe presque entièrement seul à partir de maintenant. Vers la fin, il aura de nouveau besoin de vous pendant environ deux minutes : activer l'Accès complet au disque, puis vous connecter à Tailscale pour que votre iPhone et votre Watch puissent joindre ce Mac de n'importe où. Nous ouvrirons votre navigateur pour la connexion."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale ignoré – l'app Ostler sur votre iPhone ne fonctionnera que sur votre Wi-Fi à la maison. Vous pourrez le configurer plus tard dans les Réglages."
MSG_INFO_TAILSCALE_STILL_WAITING="Toujours en attente de la connexion à Tailscale (%ss écoulées) – veuillez terminer la connexion dans la fenêtre Tailscale."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="Accès complet au disque accordé ; redémarrage de l'assistant pour prendre en compte la nouvelle autorisation."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="Ouverture des Réglages Système et du Finder pour vous guider dans l'octroi de l'Accès complet au disque à l'assistant..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="Enregistrement de l'assistant Ostler auprès de macOS pour qu'il apparaisse comme option dans Accès complet au disque..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="L'Accès complet au disque est toujours en attente. Le tableau de bord Doctor gardera la carte visible jusqu'à ce que l'accès soit accordé."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant dispose déjà de l'Accès complet au disque ; aucune action supplémentaire n'est nécessaire."
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="Cette étape a besoin de vous pendant environ deux minutes : activez dès maintenant l'Accès complet au disque pour l'assistant, puis connectez-vous à Tailscale à l'étape suivante. Ensuite, vous pourrez laisser Ostler terminer seul."
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="Cette étape a besoin de vous pendant environ une minute : activez l'Accès complet au disque pour l'assistant. Ensuite, vous pourrez laisser Ostler terminer seul."
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="« %s » figure déjà dans Accès complet au disque, il suffit donc de l'activer. Inutile de faire glisser quoi que ce soit depuis le Finder."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Vérification de l'Accès complet au disque pour l'assistant Ostler..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="L'assistant peut lire l'historique de Messages ; le canal iMessage fonctionnera."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="L'assistant Ostler n'a pas encore l'Accès complet au disque. Il en a besoin pour tenir à jour les apps propres à votre Mac, qu'il s'agisse de Messages ou non. Si vous l'ignorez maintenant, le tableau de bord Doctor vous guidera dans les Réglages Système."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="Le LaunchAgent de l'assistant ne s'est pas chargé ; vérification de l'Accès complet au disque pour iMessage ignorée."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="L'interface d'importation Evernote de Doctor affichera « service indisponible »"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Le pipeline d'importation n'est pas inclus dans l'installateur."
MSG_INFO_INSTALLING_CM042="Installation d'Ostler RemoteCapture v%s (transcription des appels et réunions)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="Installation du moteur de mémoire des conversations depuis %s..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  Installation du moteur de mémoire des conversations dans le venv..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="Installation de Colima + Docker CLI..."
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="Installation de GNU coreutils (pour limiter la durée des étapes longues)..."
MSG_INFO_INSTALLING_HOMEBREW="Installation de Homebrew..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="Installation du service Knowledge depuis %s..."
MSG_INFO_INSTALLING_OLLAMA="Installation d'Ollama..."
MSG_INFO_INSTALLING_OLLAMA_PINNED="Installing Ollama %s (verified release)..."
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  Installation des dépendances du module d'extraction de données..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Installation du lecteur d'Apple Mail dans un venv dédié..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  Installation d'ostler-knowledge dans le venv..."
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  Installation de la dépendance de stockage chiffré dans le venv de la mémoire des conversations..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Installation de l'extension Safari dans /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="Installation des dépendances Python de sécurité..."
MSG_INFO_INSTALLING_SQLCIPHER="Installation de SQLCipher..."
MSG_INFO_INSTALLING_TAILSCALE="Installation de Tailscale..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="La prise en charge d'Intel n'est pas prévue ; faites une demande si nécessaire."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Service Knowledge inclus dans l'installateur ; utilisation des sources intégrées."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Service Knowledge non installé : PWG_KNOWLEDGE_REPO est vide."
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="Ce Mac est un portable. Utilisé comme Hub, il continue de fonctionner tant que l'écran est ouvert et que le Mac est branché sur secteur."
MSG_INFO_LAPTOP_HUB_SLEEP_COST="Si vous fermez l'écran, ou laissez le Mac inactif sur batterie, macOS le met en veille. L'assistant ne reçoit rien pendant la veille, et les messages arrivés entre-temps ne sont pas récupérés au réveil."
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="L'écran peut rester fermé en mode clapet, qui nécessite une alimentation secteur ainsi qu'un écran externe, un clavier et une souris."
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="Un Hub sur Mac mini ou Mac Studio reste éveillé de lui-même, si vous préférez installer Ostler sur l'un de ces Mac."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="plus tard dans Réglages Système > Confidentialité et sécurité > Accès complet au disque"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  lancement pour vérifier la livraison cron et la configuration imessage-tcc)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="Licence : %s est sous Apache 2.0. Texte complet : %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licence: %s – check upstream terms before commercial use."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="stockage local – Google ne saura jamais qu'Ostler existe."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="Journaux : %s/email-ingest.log (et .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="Journaux : %s/ostler-assistant.log (et .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="Journaux : %s/wiki-recompile.log (et .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="Hubs sur MacBook : définissez PWG_HUB_POWER_REPO=<url> et relancez."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="Hub sur MacBook détecté : désactivation de la veille sur secteur uniquement (hub-power gère les passages sur batterie)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Les déploiements sur Mac mini / Studio ne sont pas concernés (toujours sur secteur)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Les données côté Mac (iMessage, Safari, etc.) ont été extraites ci-dessus."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="Redémarrage manuel : launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="Exécution manuelle : bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="Installation de com.ostler.meeting-brief-sender ignorée (fonctionnalité de la v1.0.1 ; points d'accès pas encore disponibles)."
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="Passage d'entretien de la mémoire ignoré (non inclus dans cet installateur) ; rien n'est minoré automatiquement tant qu'il n'est pas inclus."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="message lorsque l'indicateur de fonctionnalité sera activé plus tard."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="Besoin d'aide ? Écrivez à support@ostler.ai. Nous visons une réponse sous 2 jours ouvrés."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="Aucun canal configuré. À exécuter plus tard : %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="Ancien fichier config.toml obsolète supprimé à la racine de l'espace de travail ; la configuration active de l'assistant se trouve dans assistant-config/."
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="Aucune source FDA disponible pour le moment. Vous pouvez accorder l'Accès complet au disque"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="Aucune exportation RGPD trouvée dans Téléchargements, Bureau ou Documents."
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="Impossible de lire %s pour rechercher des exportations de données. macOS bloque l'accès à ce dossier."
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="Accordez l'accès dans Réglages Système > Confidentialité et sécurité > Fichiers et dossiers (ou Accès complet au disque) et relancez, ou indiquez manuellement ci-dessous le dossier de vos exportations à Ostler."
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="Impossible d'analyser un ou plusieurs dossiers à la recherche d'exportations de données, car macOS a bloqué l'accès. Accordez l'accès et relancez, ou indiquez-moi manuellement le dossier de vos exportations."
MSG_INFO_OPENING_CHROME_WEB_STORE="Ouverture du Chrome Web Store : %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="binaire ostler-assistant non installé ; sonde doctor ignorée"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor : reporté (le démon peut encore être"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="Utilisation du binaire ostler-assistant inclus dans ce DMG (installation possible hors ligne)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge installé dans l'environnement virtuel."
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler will show an extra consent screen before installing"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  Remplacez le dépôt source du moteur de mémoire des conversations via la variable d'environnement décrite dans ./install.sh --help."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  Remplacez le dépôt source avec PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  Remplacez le dépôt source avec PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  Remplacez le dépôt source avec PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  Remplacez le dépôt source avec PWG_PIPELINE_REPO=<url> ./install.sh"
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Persisting consent records and region..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="Surveillance de la batterie de la phase 3 activée (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="Lecture de votre carnet d'adresses (les grandes bibliothèques peuvent prendre quelques minutes – veuillez ne pas fermer l'installateur)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="Pour changer de stratégie : modifiez ~/.ostler/power.conf (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="Vérification de l'autorisation d'automatisation iMessage (lecture seule)..."
MSG_INFO_PULLING_GRAPH_DB_IMAGES="Téléchargement des bases de données du graphe de connaissances (première exécution uniquement). Cela peut prendre une minute sur une nouvelle installation..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="Téléchargement de nomic-embed-text (274 Mo)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="Téléchargement de %s (%s)... cela peut prendre quelques minutes."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="Attribut xattr de quarantaine supprimé. Une fois que la version signée Developer ID sera"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Lecture de Safari, iMessage, Notes, Calendrier, Photos, Rappels, Mail..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="Lecture de votre fiche de contact pour préremplir vos informations..."
MSG_INFO_REGION_EU_EEA_SOURCE="Région : UE/EEE (%s, source : %s)"
MSG_INFO_REGION_SOURCE="Région : %s (source : %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="Région : Royaume-Uni (source : %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="Région : États-Unis (source : %s)"
MSG_INFO_REPO_URL="URL du dépôt : %s"
MSG_INFO_REPO_URL_2="URL du dépôt : %s"
MSG_INFO_REPO_URL_3="URL du dépôt : %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="Choisissez maintenant la phrase secrète qui déverrouillera votre Hub. Vous la saisirez à chaque démarrage de l'interface du Hub."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="Phrase secrète de récupération ignorée. (Obsolète : la version 1.0 exige toujours une phrase secrète.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="Réutilisation de l'installation existante de l'agent Doctor dans %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="Réutilisation de l'installation existante d'email-ingest dans %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="Réutilisation de l'installation existante de hub-power dans %s"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="Réutilisation de la clé existante de l'extension de navigateur dans %s"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="L'extension Ostler pour Chrome ne fait pas partie de cette version."
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="Email conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="Conversations par e-mail : non configurées, car Apple Mail n'est pas configuré sur ce Mac."
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="Messages conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="Conversations Messages : non configurées, car il n'y a aucun historique Messages sur ce Mac."
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  Transcrivez un appel avec Ostler et cette fonction s'activera d'elle-même."
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="Conversations orales : pas encore configurées, car il n'y a aucune transcription à lire."
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="Conversations orales : désactivées, car le dossier Transcripts a été supprimé depuis l'installation d'Ostler."
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  Recréez %s pour réactiver cette fonction. Ostler ne le recréera pas à votre place."
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="WhatsApp conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="Conversations WhatsApp : non configurées, car WhatsApp est désactivé."
MSG_INFO_CHROME_HISTORY_STILL_READ="  Ostler lit toujours votre historique Chrome, donc les pages que vous avez visitées sont mémorisées. La capture en direct pendant la navigation n'est disponible que pour Safari pour l'instant."
MSG_INFO_REUSING_EXISTING_JWT_SECRET="Réutilisation du JWT_SECRET existant dans %s"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="Réutilisation du jeton de service PWG existant dans %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="Réutilisation de l'installation existante de wiki-recompile dans %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="Le bundle de l'extension Safari n'est pas inclus dans cette version de l'installateur (ignoré)"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="Il reste une étape manuelle : ouvrez Safari, choisissez Safari > Réglages > Extensions, puis cochez Ostler pour l'activer."
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="Recherche d'exports de données RGPD..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="Définissez PWG_DOCTOR_REPO=<url> et relancez pour installer."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="Définissez PWG_HUB_POWER_REPO=<HR015 url> et relancez pour installer."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="Modèle de conversation ignoré. À télécharger plus tard : ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Démarrage de Colima (environnement d'exécution Docker léger)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Démarrage de Docker Desktop..."
MSG_INFO_STARTING_OLLAMA="Démarrage d'Ollama..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="Suppression d'un ancien élément de démarrage Colima laissé par une version antérieure..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="Suppression de l'ancienne formule Ollama (sans llama-server) ; passage à l'app Ollama..."
MSG_INFO_VERIFYING_EMBEDDINGS="Vérification que le moteur d'embeddings renvoie bien des vecteurs..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="Impossible de démarrer Ollama automatiquement. Chargez-le avec : launchctl bootstrap gui/\$(id -u) %s – puis relancez l'installateur."
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="Ollama n'a pas démarré via le service en arrière-plan ; démarrage direct pour cette exécution..."
# NEEDS REVIEW: Split-line fragment; 'after first' continues on the next line and 'd'abord' changed the meaning. Check against the adjacent strings.
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  démarrage ; exécutez \`ostler-assistant doctor\` après le premier"
MSG_INFO_SYMLINKING="  Création du lien symbolique %s -> %s"
# NEEDS REVIEW: Sentence continues on the next line ('Mail's ...'); check that it joins up grammatically with the following string.
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(Réglages Système > Comptes Internet). Ostler lit les données de Mail"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(Le reste d'Ostler fonctionne sans le tableau de bord Doctor.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="C'est normal pour le moment. L'importation RGPD sera disponible dans une prochaine mise à jour."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="Cela prend généralement de 15 à 45 minutes, et peut durer plus longtemps si votre historique est volumineux ou si votre Mac est plus lent. C'est normal : le processus est en cours et n'est pas bloqué, vous pouvez donc le laisser se poursuivre..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="Les bases de données macOS sont lues directement : aucune exportation n'est nécessaire."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="Astuce : pour inclure votre compte Gmail, ajoutez-le d'abord à Mail sur votre Mac"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="Pour l'installer plus tard, une fois que vous aurez l'accès :"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="Déclenchement de la synchronisation iCloud pour %s (silencieuse, au premier lancement uniquement)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (RGPD du Royaume-Uni, article 9 : requis pour les catégories particulières de données)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="Mise à jour du pipeline existant..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="Arborescence destinée à l'utilisateur déjà annoncée (sentinelle présente) ; étape ignorée"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="Téléchargement du moteur de recherche web local (environ 3,5 Go). Lors d'une première installation, c'est l'étape la plus longue et elle peut durer jusqu'à une heure. Elle n'affiche pas de barre de progression : un long silence est donc normal et ne signifie pas que l'installation est bloquée."
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane ne répond pas (facultatif ; voir les avertissements de la phase 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="À consulter à tout moment avec : bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="La reconnaissance vocale restera désactivée. Vous pourrez l'activer plus tard dans les Réglages."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="En attente de votre connexion à Tailscale (jusqu'à 3 minutes)..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="L'accès à distance Tailscale n'a pas été configuré. L'app Ostler sur votre iPhone fonctionnera sur votre Wi-Fi à domicile ; vous pourrez configurer l'accès à distance plus tard dans les Réglages."
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="Ce Mac est déjà connecté à votre réseau Tailscale, il n'y a donc rien à configurer. Votre connexion existante est conservée."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="Accès à distance : votre réponse précédente, qui était de l'ignorer, est conservée. Votre app iOS fonctionnera sur votre Wi-Fi à domicile, et vous pourrez configurer l'accès à distance plus tard dans les Réglages."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="Accès à distance : votre réponse précédente, qui était de le configurer, est conservée."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="Connecteur WhatsApp laissé désactivé. Vous pourrez l'activer plus tard dans les Réglages."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="Maintien de connexion WhatsApp planifié à 08:50 + 17:50 (label com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="Rattrapage du wiki du premier jour ignoré : la tâche de recompilation du wiki n'est pas installée. La reconstruction quotidienne du wiki, si elle est installée, s'exécute quand même."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Les scripts de recompilation du wiki ne sont pas inclus dans l'installateur."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="Le wiki ne se mettra pas à jour automatiquement ; vous pouvez relancer la première compilation manuellement :"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="Marqueur de posture écrit : %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="Vos exportations sont en sécurité. Importez-les plus tard avec : ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="Les données de votre Mac (iMessage, Safari, etc.) ont déjà été extraites ci-dessus."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="Vous pourrez l'ajouter plus tard pour une prise en main instantanée depuis Safari, iMessage, etc."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="Modèle d'IA : %s (%s) – sélectionné pour vos %s Go de RAM"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="Compatible"
MSG_MODELFIT_PILL_SLOW="Peut être lent"
MSG_MODELFIT_PILL_NOFIT="Incompatible"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="Adaptation du modèle de l'assistant à votre Mac (%s, %s Go de RAM, contexte de l'assistant : %s jetons) :"
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- Recommandé"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="Modèle d'IA : %s (%s) – le mieux adapté à vos %s Go de RAM avec la fenêtre de contexte requise par l'assistant"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="Toutes les sources sont sélectionnées (reconnaissance faciale toujours désactivée)"
MSG_OK_ALREADY_AVAILABLE="%s déjà disponible"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon détecté"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="Apps lancées pour déclencher la synchronisation iCloud"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="Bases de données des apps déjà présentes (lancement préalable ignoré)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="Configuration de l'assistant enregistrée dans %s (mode 0600)"
MSG_OK_BACKED_UP_CONTACTS="%s contacts sauvegardés dans %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s installé dans %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="LaunchAgent Ostler RemoteCapture chargé (étiquette %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima et Docker CLI installés"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="Superviseur du moteur de conteneurs installé (vérifie toutes les 5 minutes et redémarre le moteur s'il s'arrête)"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="Le superviseur du moteur de conteneurs n'a pas pu être planifié. Ostler s'installera quand même, mais si le moteur s'arrête plus tard, rien ne le relancera de lui-même : votre wiki resterait inaccessible jusqu'à ce que vous relanciez l'installateur."
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="Les fichiers du superviseur du moteur de conteneurs sont absents de cet installateur, il n'a donc pas été planifié. Ostler s'installera quand même, mais la reprise automatique du moteur n'est pas active."
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
# NEEDS REVIEW: Section names (People, Timeline, Governor) must match the app's localised labels; Governor left in English needs confirmation.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="Le tableau de bord Ostler Doctor n'a pas pu être démarré, donc http://localhost:8089 ne répondra pas. Les pages de l'app qui en dépendent (Personnes, Chronologie, Governor, état des canaux) s'afficheront comme indisponibles tant qu'il ne fonctionne pas. Relancez l'installateur pour réessayer."
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="L'utilitaire anti-veille n'a pas pu être planifié. Ostler fonctionne toujours, mais ce Mac pourrait se mettre en veille pendant les longues tâches en arrière-plan, qui reprendront à sa réactivation au lieu de se terminer pendant la nuit."
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="L'utilitaire de mise à jour en arrière-plan n'a pas pu être planifié, donc les nouveaux messages, e-mails et événements du calendrier ne seront pas récupérés automatiquement. Relancez l'installateur pour le rétablir."
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="%s not set up: Ostler has no record of your answer to the question that governs it, so it did not assume one."
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  Re-run Ostler and choose to answer the questions again to turn it on. (consent record: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="Le récapitulatif quotidien n'a pas pu être planifié, vous ne recevrez donc pas le résumé du matin. Tout le reste fonctionne ; relancez l'installateur pour le rétablir."
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="Le nettoyage de la mémoire n'a pas pu être planifié, donc les informations obsolètes ou remplacées ne seront pas dépriorisées automatiquement. Tout le reste fonctionne ; relancez l'installateur pour le rétablir."
MSG_WARN_EXPORT_SCAN_NOT_LOADED="Le surveillant du dossier Téléchargements n'a pas pu être démarré, donc les fichiers que vous y déposez ne seront pas pris en compte automatiquement. Tout ce qui a déjà été importé n'est pas affecté, et vous pouvez toujours ajouter des fichiers depuis l'app. Relancez l'installateur pour le rétablir."
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="L'utilitaire de nouvelle tentative pour l'enregistrement de l'appareil n'a pas pu être planifié. Si votre iPhone s'est enregistré pendant la configuration, rien ne change ; sinon, vous devrez l'associer à nouveau depuis l'app, car cela ne se terminera pas tout seul."
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="Moteur de conteneurs opérationnel"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="Ancien élément de démarrage Colima, laissé par une version précédente, supprimé"
MSG_OK_CONFIG_SAVED_ENV="Configuration enregistrée dans %s/.env"
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Consent records and region persisted to ~/.ostler/posture/"
MSG_OK_AT_REST_EXCLUDED="Exclu de Spotlight et de Time Machine (vérifié) : %s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s n'est PAS exclu de Time Machine ni de Spotlight : %s. Son contenu, y compris les secrets d'Ostler, peut être copié sur votre disque de sauvegarde. Le Doctor continuera de l'indiquer tant que ce ne sera pas corrigé."
MSG_INFO_AT_REST_FOLDER_ABSENT="%s n'existe pas encore, il n'y a donc rien à exclure des sauvegardes."
MSG_WARN_DB_KEY_NOT_EXCLUDED="Le fichier de clé de la base de données %s n'est PAS exclu de Time Machine, il peut donc être copié sur votre disque de sauvegarde."
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="Impossible d'enregistrer votre choix d'enrichissement en arrière-plan dans ~/.ostler/posture/. Votre choix reste appliqué à cette installation ; il n'apparaîtra simplement pas dans un rapport d'assistance."
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="Bases de données chiffrées. Les services du Hub lisent la clé dans un fichier protégé de votre dossier personnel, et démarrent donc sans vous solliciter."
MSG_OK_DB_KEY_DELIVERED="Clé de base de données transmise aux services du Hub (%s, lisible uniquement par vous)."
MSG_WARN_DB_KEY_NOT_DELIVERED="Impossible de transmettre la clé de base de données aux services du Hub. Ils ouvriront les bases de données sans chiffrement tant que ce ne sera pas corrigé."
MSG_INFO_DB_KEY_RECOVER_HINT="Exécutez ceci pour la récupérer et la transmettre : %s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="Chiffrement des bases de données restantes d'une installation précédente"
MSG_WARN_DB_MIGRATION_FAILED="Certaines bases de données existantes n'ont pas pu être chiffrées. Elles restent lisibles sur le disque."
MSG_WARN_DB_KEY_MISSING_ON_RERUN="Cette installation n'a pas de fichier de clé de base de données, donc les services du Hub ouvrent les bases de données sans chiffrement."
MSG_WARN_DB_PLAINTEXT_COUNT="%s base(s) de données de ce Mac sont actuellement lisibles sur le disque."
MSG_INFO_DB_MIGRATE_HINT="Chiffrez ensuite ce qui existe déjà : %s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="Nouvelle tentative différée d'enregistrement de l'appareil installée (s'exécute toutes les heures jusqu'à ce que la file soit vide)"
MSG_OK_DOCKER_RUNNING="Docker en cours d'exécution"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker en cours d'exécution (démarré en %ss)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Agent Doctor cloné depuis %s"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Fichiers de l'agent Doctor inclus dans l'installateur"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Dépendances de Doctor installées"
MSG_OK_EMAIL_CHANNEL_FOLDER="Canal e-mail : %s (dossier : %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent d'ingestion des e-mails chargé (label com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts d'ingestion des e-mails inclus dans l'installateur"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="Scripts d'ingestion des e-mails clonés depuis %s"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="Configuration de la mémoire des conversations WhatsApp"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  Lecteur de conversations WhatsApp installé."
MSG_WARN_WHATSAPP_SOURCE_FAILED="L'installation du lecteur de conversations WhatsApp a échoué ; le flux de conversations WhatsApp ne fonctionnera pas. Voir le résultat ci-dessus."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="Source du lecteur de conversations WhatsApp introuvable ; le flux de conversations WhatsApp est ignoré."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="Paquet du flux de conversations WhatsApp introuvable dans cet installateur ; étape ignorée. L'historique des messages WhatsApp (à qui vous avez écrit et quand) n'est pas affecté."
MSG_OK_WHATSAPP_BUNDLE_LOADED="LaunchAgent du flux de conversations WhatsApp chargé (label com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  La première exécution lit les conversations WhatsApp récentes synchronisées par votre Mac (environ la dernière année) ; elles restent sur votre Mac."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  Journaux : %s/whatsapp-bundle.log et whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="L'installation du LaunchAgent du flux de conversations WhatsApp a échoué. Voir le résultat ci-dessus ; le reste de l'installation n'est pas affecté."
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  Pas encore démarré : le programme de l'assistant exécuté par cet agent n'est pas présent sur le disque. Emplacement recherché : %s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="Configuration de la mémoire des conversations e-mail"
MSG_OK_EMAIL_SOURCE_INSTALLED="  Lecteur de conversations e-mail installé."
MSG_WARN_EMAIL_SOURCE_FAILED="L'installation du lecteur de conversations e-mail a échoué ; le flux de conversations e-mail ne fonctionnera pas. Voir le résultat ci-dessus."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="Source du lecteur de conversations e-mail introuvable ; le flux de conversations e-mail est ignoré."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="Paquet du flux de conversations e-mail introuvable dans cet installateur ; étape ignorée. L'ingestion horaire des e-mails n'est pas affectée."
MSG_OK_EMAIL_BUNDLE_LOADED="LaunchAgent du flux de conversations e-mail chargé (label com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Lit vos fils d'e-mails récents dans le stockage local d'Apple Mail ; tout reste sur votre Mac."
MSG_INFO_EMAIL_BUNDLE_LOGS="  Journaux : %s/email-bundle.log et email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="L'installation du LaunchAgent du flux de conversations e-mail a échoué. Voir le résultat ci-dessus ; le reste de l'installation n'est pas affecté."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="Configuration de la mémoire des conversations de réunions et vocales"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  Lecteur de conversations de réunions et vocales installé."
MSG_WARN_SPOKEN_SOURCE_FAILED="L'installation du lecteur de conversations de réunions et vocales a échoué ; le flux ne fonctionnera pas. Voir le résultat ci-dessus."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="Source du lecteur de conversations de réunions et vocales introuvable ; le flux est ignoré."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="Paquet du flux de conversations de réunions et vocales introuvable dans cet installateur ; étape ignorée."
MSG_OK_SPOKEN_BUNDLE_LOADED="LaunchAgent du flux de conversations de réunions et vocales chargé (label com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  Transcrit vos propres réunions et notes vocales en conversations consultables ; tout reste sur votre Mac."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  Journaux : %s/spoken-bundle.log et spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="L'installation du LaunchAgent du flux de conversations de réunions et vocales a échoué. Voir le résultat ci-dessus ; le reste de l'installation n'est pas affecté."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="Configuration de la mémoire des conversations iMessage"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  Lecteur de conversations iMessage installé."
MSG_WARN_IMESSAGE_SOURCE_FAILED="L'installation du lecteur de conversations iMessage a échoué ; le flux de conversations iMessage ne fonctionnera pas. Voir le résultat ci-dessus."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="Source du lecteur de conversations iMessage introuvable ; le flux de conversations iMessage est ignoré."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="Package du flux de conversations iMessage introuvable dans cet installateur ; étape ignorée."
MSG_OK_IMESSAGE_BUNDLE_LOADED="LaunchAgent du flux de conversations iMessage chargé (label com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  Lit vos conversations iMessage récentes depuis la base Messages de ce Mac ; tout reste sur votre Mac."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  Journaux : %s/imessage-bundle.log et imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="Échec de l'installation du LaunchAgent du flux de conversations iMessage. Voir la sortie ci-dessus ; le reste de l'installation n'est pas affecté."
MSG_OK_EMBEDDING_MODEL_READY="Modèle d'embedding prêt"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="%s contacts exportés (seront importés automatiquement)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="Surveillant d'exports installé (analyse le dossier Téléchargements toutes les 4 heures)"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  Le surveillant d'exports n'est pas encore démarré : le programme de l'assistant qu'il exécute est absent du disque. Emplacement recherché : %s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="Expéditeur de résumés avant réunion installé (vérification toutes les 10 minutes pendant la journée)"
MSG_OK_MEMORY_HYGIENE_INSTALLED="Nettoyage de la mémoire planifié (quotidien, pour éviter que des faits périmés ne masquent les faits actuels)"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="Votre Mac restera éveillé sur secteur pour qu'Ostler continue de fonctionner (il se met toujours en veille sur batterie)"
MSG_OK_EXTRACTED="Extrait vers %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="Données extraites de %s source(s). Enregistrées dans %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="Nouvelle exécution FDA planifiée toutes les %s minutes (rattrape les synchronisations iCloud lentes et termine l'import de l'historique du calendrier)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro actif pendant 30 jours. Abonnez-vous dans l'app Ostler sur votre iPhone pour prolonger après l'essai."
MSG_OK_FOUND="Trouvé : %s"
MSG_OK_FOUND_EXPORTS="Exports trouvés dans %s"
MSG_OK_FOUND_GDPR_EXPORT_S="%s export(s) RGPD trouvé(s) :"
MSG_OK_GB_FREE_DISK_SPACE="%s Go d'espace disque libre"
MSG_OK_GB_RAM_DETECTED="%s Go de RAM détectés"
MSG_OK_GDPR_IMPORT_COMPLETE="Importation RGPD terminée"
MSG_OK_GIT_AVAILABLE="Git disponible"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="Installation des Command Line Tools lancée (téléchargement en arrière-plan pendant que vous répondez aux questions ci-dessous)."
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils installé (les longues étapes ont désormais une limite de durée)"
MSG_OK_HOMEBREW_INSTALLED="Homebrew installé"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent d'alimentation du Hub chargé (label com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts d'alimentation du Hub inclus dans l'installateur"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Scripts d'alimentation du Hub clonés depuis %s"
MSG_OK_ICAL_SERVER_INSTALLED="API de l'assistant installée (bouclage local 127.0.0.1:8090, relayée par Doctor)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="LaunchAgent du pont iMessage chargé (label com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts du pont iMessage inclus dans l'installateur"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="Scripts du pont iMessage clonés depuis %s"
MSG_OK_IMESSAGE_CHANNEL="Canal iMessage : %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="Pipeline d'importation inclus dans l'installateur"
MSG_OK_IMPORT_PIPELINE_READY="Pipeline d'importation prêt"
MSG_OK_CM048_PIPELINE_READY="Moteur de mémoire des conversations prêt."
MSG_INFO_CM048_SETTINGS_WRITTEN="  Modèles de conversation réglés sur %s (adaptés à vos %s Go de mémoire)"
MSG_INFO_CM048_SETTINGS_KEPT="  Conservation de vos réglages de conversation existants (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="Service de connaissances prêt : %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="Textes de licence installés dans %s/ (source : %s)"
MSG_OK_MACOS_DETECTED="macOS %s détecté"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="Ouverture de Réglages Système > Comptes Internet pour que vous puissiez ajouter un compte mail. Revenez à cette fenêtre une fois connecté à votre premier compte."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="Étape Comptes Internet ignorée. Vous pourrez ajouter un compte mail plus tard dans Réglages Système ; Doctor vous le signalera si aucun mail n'arrive dans les 24 heures."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Récupération de tout votre historique Apple Mail en cours. Cela peut prendre un peu plus de temps pour une grande boîte mail."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="Conservation de la période standard de cinq ans pour les mails. Vous pourrez en récupérer davantage plus tard depuis Doctor."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text déjà disponible"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="Ollama installé"
MSG_WARN_OLLAMA_CUSTOMER_APP_PRESENT="An Ollama app is already installed in Applications. Ostler leaves it exactly as it is and runs its own copy of Ollama %s alongside it. If that app is open in the menu bar, quit it so Ostler can start its own."
MSG_WARN_OLLAMA_PIN_DEFERRED="Could not update Ollama to %s this time, so Ostler is keeping the copy it already runs (%s). Your assistant keeps working. The update will be tried again the next time the installer runs. Details: %s"
MSG_WARN_MODEL_PULL_HELD_OLLAMA_UNPINNED="Not downloading %s this time: Ostler's tested copy of Ollama (%s) is not installed yet, and a different Ollama could fetch the wrong build. The next installer run downloads it."
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama installé (CLI uniquement – un démarrage manuel peut être nécessaire après un redémarrage)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama installé (app de bureau)"
MSG_OK_OLLAMA_RUNNING="Ollama en cours d'exécution"
MSG_OK_EMBEDDINGS_VERIFIED="Moteur d'embedding vérifié (vecteurs à 768 dimensions)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor : 0 erreur dans ses propres vérifications de démarrage"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de l'assistant Ostler chargé (label com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s placé dans %s (signé)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s placé dans %s (non signé)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor en cours d'exécution sur http://localhost:8089/doctor"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  Le module d'extraction de données se charge correctement."
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Lecteur Apple Mail installé."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  Moteur d'ingestion des mails installé."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="Commandes ostler-import, ostler-fda et ostler-uninstall installées"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="Phrase secrète enregistrée. Elle chiffrera vos bases de données pendant la phase 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="Phrase secrète de récupération configurée."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="Explications sur la phrase secrète lues et acceptées."
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="Mot de passe de l'export Disney+ enregistré. Il sera utilisé pendant l'import."
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="Export Disney+ ignoré : aucun mot de passe n'a été fourni. Rien d'autre n'est affecté."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="Source d'alimentation : secteur (Mac de bureau, sans batterie)"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="Source d'alimentation : secteur (parfait – l'installation peut durer de 45 minutes à plusieurs heures, le branchement sur secteur assure sa stabilité)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="Installation précédente détectée. Chargement de la configuration..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="Utilisation de Python %s inclus (aucune installation système nécessaire)"
MSG_OK_PYTHON_INSTALLED="Python %s installé"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="Service d'appairage opérationnel"
MSG_WARN_GATEWAY_NOT_RESPONDING="Le service d'appairage ne répond pas (127.0.0.1:8000) - l'appairage du téléphone ou du navigateur et l'assistant de discussion peuvent ne pas encore fonctionner"
MSG_OK_DOCTOR_HEALTHY="Doctor fonctionne correctement"
MSG_WARN_DOCTOR_NOT_RESPONDING="Doctor ne répond pas (127.0.0.1:8089) : l'app et le navigateur accèdent à Ostler par ce biais, donc les données et le jumelage peuvent être indisponibles"
MSG_OK_WIKI_HEALTHY="Votre wiki fonctionne correctement"
MSG_OK_ICAL_SERVER_HEALTHY="L'API de l'assistant fonctionne correctement"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="L'API de l'assistant ne répond pas (127.0.0.1:8090) : Personnes, Réunions et Chronologie peuvent rester vides tant qu'elle n'a pas démarré"
MSG_OK_READY="%s prêt"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="Sources recommandées sélectionnées"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="Clé de récupération enregistrée dans le Trousseau (cherchez « Ostler » dans l'app Mots de passe)"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Extension Safari installée dans %s"
MSG_OK_SAFARI_EXTENSION_PAIRED="Extension Safari jumelée avec ce Hub"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="La sécurité a déjà été configurée lors d'une exécution précédente."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="Module de sécurité installé dans le venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="Nouveau JWT_SECRET généré dans %s"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="Jeton de service PWG généré dans %s"
MSG_OK_SEEDED_EXTENSION_TOKEN="Clé de l'extension de navigateur générée dans %s"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="Services démarrés (Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  Collection de recherche préparée : %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="Impossible de préparer pour l'instant la collection de recherche %s ; l'importation des données ci-dessous réessaiera et s'arrêtera, sans supprimer vos données, si elle n'y parvient toujours pas."
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="L'index de recherche n'a pas été prêt à temps ; l'importation des données ci-dessous l'attendra, préparera les collections et s'arrêtera, sans supprimer vos données, si le stockage n'est toujours pas prêt."
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="Vos données n'ont pas été importées. Le stockage de recherche n'a pas pu être préparé pour les accueillir (manquant : %s), et une importation malgré tout les aurait perdues en silence. Rien n'a été perdu. Relancez l'installateur lorsque la machine sera inactive, ou définissez OSTLER_QDRANT_READY_WAIT_S pour attendre plus longtemps."
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="L'importation de vos données a traité %s enregistrements mais n'en a stocké aucun ; le stockage de recherche les a tous rejetés, ce qui aurait produit un graphe de connaissances vide présenté comme complet. L'installation s'arrête plutôt que de vous présenter ce résultat. Relancez l'installateur lorsque la machine sera inactive."
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="Impossible de lire le journal propre à l'importation, donc la vérification de l'arrivée effective de vos données n'a pas pu s'exécuter. Cela ne signale ni un échec de l'importation, ni une réussite."
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="Veille désactivée sur secteur, veille sur batterie conservée, réactivation par le réseau activée"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="Veille désactivée, réactivation par le réseau activée"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale est déjà installé"
MSG_OK_TAILSCALE_INSTALLED="Tailscale installé"
MSG_OK_TAILSCALE_ENV_PERSISTED="IP Tailscale enregistrée dans .env – l'app Ostler sur votre iPhone l'utilisera au premier lancement."
MSG_OK_TAILSCALE_IP="IP Tailscale : %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Service Tailscale en arrière-plan démarré (mode userspace, sans extension système)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="Impossible de démarrer le service Tailscale en arrière-plan. Vous pourrez relancer la configuration plus tard depuis les Réglages."
MSG_INFO_TAILSCALE_SIGN_IN_URL="Ouverture de votre navigateur pour vous connecter à Tailscale : %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Port %s du Hub exposé sur votre tailnet"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="Impossible d'exposer le port %s du Hub sur votre tailnet ; l'accès hors du réseau local pourrait être limité"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="Votre wiki est désormais lisible depuis vos propres appareils à l'adresse %s – avec votre propre connexion, et pour vous seul."
MSG_INFO_WIKI_TAILNET_OWNER="L'accès au wiki est réservé à votre compte Tailscale (%s). Les autres personnes de votre tailnet reçoivent une erreur 403."
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="Votre wiki reste uniquement sur ce Mac. Ouvrez Ostler et choisissez Wiki dans la barre latérale pour le lire."
MSG_INFO_WIKI_TAILNET_BANNER="%s  (depuis vos propres appareils, via Tailscale. C'est la seule voie qui vous demande la connexion ci-dessus.)"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="dans l'app Ostler. Ouvrez Ostler et choisissez Wiki dans la barre latérale ; vos pages s'y trouvent, et vous êtes déjà connecté."
MSG_INFO_WIKI_INTERNAL_ADDRESS="Ostler récupère ces pages depuis http://localhost:8044 sur ce Mac. Cette adresse est interne et n'offre rien à quoi vous connecter."
MSG_INFO_WIKI_SIGN_IN="Votre identifiant de connexion au wiki est %s avec le mot de passe %s. Ostler le présente à votre place, donc il n'y a rien à saisir sur ce Mac ; vous n'avez besoin de l'avoir sous la main que lorsque vous ouvrez le wiki depuis un autre de vos appareils via Tailscale."
MSG_INFO_WIKI_SIGN_IN_WITHHELD="Votre identifiant de connexion au wiki est %s. Le mot de passe n'est pas écrit dans ce journal : il se trouve dans votre presse-papiers et dans le fichier indiqué ci-dessous. Ostler le présente à votre place, il n'y a donc rien à saisir sur ce Mac."
MSG_INFO_WIKI_PORT_LAST_STATUS="Dernier statut HTTP du port du wiki : %s (000 signifie qu'aucune réponse n'est arrivée ; 403 signifie que le wiki a répondu et refusé l'identifiant)."
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="Votre mot de passe est également conservé dans %s : le presse-papiers n'en est donc pas la seule copie."
MSG_INFO_WIKI_STILL_BUILDING="Construction toujours en cours. %s pages sont déjà sur le disque, et la dernière réponse de l'adresse du wiki était HTTP %s. Le wiki apparaîtra de lui-même dans l'app Ostler. Vous n'avez rien à faire."
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="La première construction n'a encore produit aucune page (voir les avertissements ci-dessus). Votre wiki s'ouvrira dans l'app Ostler une fois construit, et l'identifiant de connexion ci-dessus reste le vôtre."
MSG_INFO_WIKI_READINESS_NOT_MEASURED="Cette exécution n'a pas vérifié si le wiki est déjà en service, et ne l'affirme donc ni dans un sens ni dans l'autre. Votre wiki s'ouvre dans l'app Ostler dans tous les cas, et l'identifiant de connexion ci-dessus reste le vôtre."
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="Impossible de confirmer à quel compte Tailscale appartient ce Mac : le wiki n'a donc PAS été exposé sur votre tailnet. Il reste disponible sur ce Mac, dans l'app Ostler sous Wiki."
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="Impossible de publier le wiki sur votre tailnet ; il reste disponible sur ce Mac, dans l'app Ostler sous Wiki."
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="Impossible de recharger la barrière d'accès au wiki : le wiki n'a donc PAS été exposé sur votre tailnet."
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="Tailscale Funnel est activé pour %s. Funnel publie sur Internet. Ostler n'active jamais Funnel et votre wiki refuse le trafic Funnel, donc rien d'Ostler n'est public – mais si vous n'aviez pas l'intention de l'activer, désactivez-le dans la console d'administration Tailscale pour cette machine."
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="Mentions de tiers installées (source : %s)"
MSG_OK_USER_FACING_TREE_READY="Arborescence utilisateur prête"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="Utilisation du dossier/de l'étiquette « Ostler » à la place."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane fonctionne correctement (recherche web locale)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane en cours d'exécution sur http://localhost:3000 (communique avec votre Ollama local)"
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="WhatsApp connector will be enabled (consent recorded)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="LaunchAgent de rattrapage du wiki du premier jour chargé (reconstruit votre wiki toutes les 30 minutes pendant les premières heures, puis s'arrête)"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="Fusion des contacts en double toujours en cours – les grands carnets d'adresses peuvent prendre plusieurs minutes (%ss écoulées)"
MSG_INFO_DEDUPE_MERGED="Contacts en double fusionnés"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="La fusion des contacts en double prend du temps pour un carnet d'adresses de cette taille. Elle se poursuivra en arrière-plan après l'installation – votre wiki se mettra à jour automatiquement à la fin."
MSG_WARN_DEDUPE_INCOMPLETE="La passe de déduplication de l'ensemble du graphe ne s'est pas terminée correctement (voir %s) ; poursuite"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="Contacts en double entièrement fusionnés pendant l'installation ; aucun rattrapage en arrière-plan nécessaire"
MSG_OK_DEDUPE_CATCHUP_LOADED="LaunchAgent de déduplication des contacts en arrière-plan chargé (termine la fusion des doublons après l'installation, puis s'arrête)"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="Impossible de charger le LaunchAgent de déduplication des contacts en arrière-plan. Les doublons seront tout de même fusionnés par la passe de maintenance quotidienne ; cela prendra simplement plus de temps."
MSG_OK_ENRICH_AGENT_LOADED="LaunchAgent d'enrichissement en arrière-plan chargé (complète les détails de vos films, lieux, livres et liens ; s'exécute par tranches pendant environ une journée)"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="Impossible de charger le LaunchAgent d'enrichissement en arrière-plan. Vos préférences sont enregistrées et consultables par recherche ; il leur manquera simplement les détails de référence supplémentaires (réalisateurs, distribution, lieux) jusqu'à son exécution."
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de recompilation du wiki chargé (étiquette com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de recompilation du wiki inclus dans l'installateur"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Scripts de recompilation du wiki clonés depuis %s"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="Configuration de votre Une (actualisation toutes les heures)"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="Producteur de la Une inclus dans l'installateur"
MSG_OK_EDITOR_FRONTPAGE_LOADED="LaunchAgent de la Une chargé (étiquette com.creativemachines.ostler.editor-frontpage)"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  La première actualisation s'exécute maintenant ; la Une de votre tableau de bord se remplit à mesure qu'Ostler lit vos préférences."
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  Journaux : %s/editor-frontpage.log et editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="Producteur de la Une introuvable dans cet installateur ; la Une du tableau de bord ne sera pas actualisée."
MSG_WARN_EDITOR_FRONTPAGE_FAILED="Échec de l'installation du LaunchAgent de la Une. Voir la sortie ci-dessus ; le reste de l'installation n'est pas affecté."
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="Configuration du rattrapage de votre Une"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="LaunchAgent de rattrapage de la Une chargé (vérifie toutes les 5 minutes jusqu'à ce que vos centres d'intérêt aient été lus, puis s'arrête)"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="Impossible de charger le LaunchAgent de rattrapage de la Une. Votre Une et ce qu'Ostler sait de vos centres d'intérêt se rempliront à la prochaine actualisation horaire."
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="Rattrapage de la Une ignoré : l'actualisation de la Une n'est pas installée, il n'y a donc rien à relancer."
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki en cours d'exécution sur http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="Votre wiki est prêt à être parcouru. Ostler rédige maintenant les résumés des pages en arrière-plan : ils apparaîtront peu à peu. Vous pouvez commencer à utiliser votre wiki dès maintenant."
MSG_OK_YOUR_ASSISTANT_CALLED="Votre assistant s'appelle %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="Scripts de synthèse du contexte personnel inclus dans l'installateur"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="LaunchAgent de synthèse du contexte personnel chargé (label com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  Journaux : %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="Réutilisation de l'installation context-refresh existante dans %s"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="Scripts de synthèse du contexte personnel non inclus : l'assistant s'appuiera uniquement sur des recherches en direct (pas de résumé de contexte permanent)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="Le LaunchAgent de synthèse du contexte personnel n'a pas pu être chargé ; consultez context-refresh.err. L'assistant répond toujours grâce à des recherches en direct"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="Il manque la configuration de packaging dans la source clonée du service Knowledge : son environnement n'a donc pas été configuré."
MSG_WARN_BUNDLE="  Bundle : %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s est réservé aux Mac Apple Silicon (détecté : %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="Impossible de télécharger Ostler RemoteCapture v%s depuis %s"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="Causes courantes : la version n'est pas encore publiée, le réseau est hors ligne ou la notarisation en amont est encore en cours. Relancez l'installateur une fois la version disponible."
MSG_WARN_CM042_EXTRACT_FAILED="Impossible d'extraire l'archive tar d'Ostler RemoteCapture ; le LaunchAgent est ignoré."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Échec du chargement du LaunchAgent d'Ostler RemoteCapture. Consultez la sortie ci-dessus et ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  L'enrichissement des conversations ne sera pas disponible. Le reste d'Ostler s'installe normalement ; relancez sans --allow-plaintext pour intégrer le moteur de mémoire des conversations."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="Échec de l'installation du moteur de mémoire des conversations (clonage)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  Recherché : %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  Cela signifie généralement que l'installateur .app a été créé sans"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  le paquet cm048_pipeline intégré dans"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Téléchargez à nouveau l'installateur ou"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  relancez avec --allow-plaintext pour une installation de développement/CI."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="Moteur de mémoire des conversations introuvable. L'enrichissement des conversations ne peut pas fonctionner sans lui."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="Configuration du moteur de mémoire des conversations ignorée (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="Source du moteur de mémoire des conversations trouvée, mais pyproject.toml est absent ; configuration du venv ignorée."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Colima n'a pas pu démarrer. Essai de Docker Desktop en solution de secours..."
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="Impossible d'installer GNU coreutils ; les longues étapes s'exécuteront sans limite de durée (une ligne de progression indique toujours qu'elles sont en cours)."
MSG_WARN_COLIMA_START_RETRY="Colima n'a pas démarré correctement (le socket Docker n'était pas prêt). Nouvelle tentative dans %ss..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="Causes courantes : la version v%s n'est pas encore publiée, le réseau est hors ligne,"
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  consent_cli stderr (first 400 chars):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  Script de console non créé dans %s ; il manque peut-être l'entrée [project.scripts] dans pyproject.toml."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="Poursuite de l'installation car --allow-plaintext a été transmis."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="Poursuite de l'installation. Relancez \`ostler-fda\` après avoir diagnostiqué l'erreur ci-dessus."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="Poursuite sans remplissage automatique depuis la fiche de contact – Ostler vous posera la question."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  Les conversations envoyées à iMessage échoueront silencieusement jusqu'à ce que"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="Impossible de modifier les réglages de suspension d'activité. Activez « Empêcher la suspension d'activité automatique sur adaptateur secteur » dans Réglages Système > Énergie."
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="Impossible de modifier les réglages de veille. Activez « Empêcher la suspension d'activité automatique » dans Réglages Système > Énergie."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="Impossible de télécharger ostler-assistant v%s depuis %s"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="Impossible d'extraire le mbox Gmail de l'archive Takeout (zip) – étape ignorée."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="Impossible d'extraire l'archive tarball d'ostler-assistant ; LaunchAgent ignoré."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="Impossible de trouver la CLI Tailscale. Vous pourrez la configurer manuellement plus tard."
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Could not install legal/ consent-strings package; continuing"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="Impossible d'installer le dossier LICENSES/ (non bloquant)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="Impossible d'installer ostler_security dans l'environnement virtuel (venv) du Hub."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="Impossible d'installer THIRD_PARTY_NOTICES.md (non bloquant)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="Impossible d'obtenir l'agent Doctor (la version intégrée et le clonage ont tous deux échoué)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="Fichiers d'Ostler Doctor introuvables. Ils sont nécessaires au jumelage avec iOS (Ostler.app intègre :8089/pair-ios dans une iframe)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  Recherché dans : %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  Cela signifie généralement que l'app d'installation a été créée sans"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  les sources doctor/agent/ intégrées dans"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Téléchargez de nouveau l'installateur ou"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  relancez avec --allow-plaintext pour une installation de développement ou d'intégration continue."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Installation de Doctor interrompue : il est nécessaire au jumelage avec iOS. Téléchargez de nouveau l'installateur ou utilisez --allow-plaintext pour une installation de développement ou d'intégration continue."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="Impossible d'obtenir les scripts d'ingestion des e-mails (la version intégrée et le clonage ont tous deux échoué)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="Impossible d'obtenir les scripts hub-power (la version intégrée et le clonage ont tous deux échoué)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="Impossible d'obtenir les scripts wiki-recompile (la version intégrée et le clonage ont tous deux échoué)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="Impossible d'ouvrir automatiquement l'URL du Chrome Web Store : %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="Impossible d'enregistrer region.json (poursuite : Doctor le signalera)"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="Impossible de consigner la remise de la clé de récupération. Le récapitulatif de cette exécution reste exact, mais une exécution ultérieure pourrait ne pas le savoir et avertir de nouveau – c'est la façon la moins risquée d'échouer."
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="Your recovery key was not saved to Keychain. Write it down and keep it somewhere safe, away from this Mac."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="Impossible de démarrer Ollama automatiquement."
MSG_FAIL_OLLAMA_PORT_IN_USE="Un autre programme utilise déjà le port 11434, dont Ostler a besoin pour son IA locale. Ostler n'a pas pu démarrer sa propre copie ; l'installation s'est donc arrêtée ici plutôt que de rester inachevée.

  Ce qui occupe le port : %s
  L'erreur exacte se trouve dans : %s

Il s'agit généralement d'une copie d'Ollama que vous aviez déjà, ou restée active après une installation précédente d'Ostler. Quittez-la (ou redémarrez ce Mac), puis relancez l'installateur."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="Impossible de mettre à jour le pipeline (hors ligne ?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="Impossible d'écrire pipeline_signals.json. Le diagnostic de Doctor pour Mail vide utilisera des valeurs par défaut sûres jusqu'à la prochaine installation ou au prochain cycle."
MSG_WARN_CURL_SAID="Curl a indiqué :"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="Dossier introuvable : %s – importation ignorée."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker n'a pas démarré en %s secondes."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker est installé mais ne fonctionne pas. Il faudra le démarrer."
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="La commande Docker est présente sur ce Mac, mais rien ne fonctionne derrière. Sur macOS, la commande Docker n'est qu'un client : il lui faut un moteur, comme Colima ou Docker Desktop, pour exécuter quoi que ce soit. L'installateur en configurera un."
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="Diagnostic de l'environnement de conteneurs - client docker : %s | colima : %s | Docker Desktop : %s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="Le conteneur du wiki a été lancé, mais rien n'a répondu sur http://localhost:8044 en 60 secondes. Considérez que le wiki ne fonctionne PAS : le code de sortie de la commande de démarrage ne prouve pas que la page se charge."
MSG_WARN_WIKI_NOT_RESPONDING="Votre wiki ne répond pas (127.0.0.1:8044). Il s'exécute dans un conteneur, ce qui signifie généralement que l'environnement de conteneurs s'est arrêté. Ouvrez Ostler Doctor à l'adresse http://localhost:8089/doctor pour en connaître la raison."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama en cours d'installation et bloquent les sondes de disponibilité."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  premiers indicateurs (canaux encore en cours de connexion + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="L'installation du LaunchAgent d'ingestion des e-mails a échoué. Consultez la sortie ci-dessus."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="L'installation du LaunchAgent du pont iMessage a échoué. Les réponses iMessage de l'utilisateur de l'assistant ne fonctionneront pas tant que vous n'aurez pas relancé l'installateur ou exécuté INSTALL_SNIPPET.sh manuellement."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Les scripts du pont iMessage ne sont pas inclus et --allow-plaintext a été transmis ; l'installation du LaunchAgent sera ignorée. Les réponses iMessage de l'utilisateur de l'assistant ne fonctionneront pas."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="Le chiffrement ne fonctionnera pas."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="Le chiffrement ne fonctionnera pas, et"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="vérifiez que la balise PWG_KNOWLEDGE_REPO épinglée l'inclut."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  Events pour Messages.app)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="L'extracteur FDA s'est terminé avec un code non nul (%s). 20 dernières lignes de la sortie :"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="Le module d'extraction FDA n'est pas inclus dans cet installateur."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="Emplacement attendu : Contents/Resources/ostler_fda/ (dans le .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="Cause la plus probable : une régression de compilation a supprimé la copie du module. Téléchargez à nouveau le .app depuis ostler.ai/install."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="Le module d'extraction FDA n'est pas inclus. L'installation continue car --allow-plaintext a été transmis – l'extraction instantanée des données sera ignorée."
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="Le module d'extraction de données est présent sur le disque, mais ses dépendances ne se sont pas installées ; il ne peut donc pas être chargé :"
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="L'installation continue car --allow-plaintext a été transmis – l'actualisation programmée des données échouera à chaque exécution."
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault n'est PAS activé."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="Impossible d'activer le premier mois gratuit pour le moment ; l'installation va continuer. Ouvrez l'app Ostler sur votre iPhone une fois l'appairage effectué pour régler cela."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="L'Accès complet au disque n'a pas été accordé à Terminal."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="%s Go de RAM détectés. Vous disposerez de l'assistant compact (gemma4:e2b) – fiable, précis, réactif en moins d'une seconde sur les questions courtes, avec appels d'outils et un honnête « je ne sais pas » lorsque c'est le cas. Pour des réponses plus riches aux questions plus longues, 24 Go ou plus donnent accès à l'assistant standard (qwen3.5:9b). Vous pourrez changer de Mac plus tard en réinstallant."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="L'importation RGPD a rencontré des erreurs. Vous pouvez la relancer avec :"
MSG_WARN_GRAPH_DB_PULL_RETRY="Le téléchargement de la base de données n'a pas abouti (tentative %s sur %s). Nouvel essai dans %ss..."
MSG_WARN_GRAPH_DB_UP_RETRY="Les bases de données du graphe de connaissances n'ont pas démarré (tentative %s sur %s). Nouvel essai..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="L'importation RGPD fait partie de l'installation complète. Sans elle, votre graphe social (LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google Agenda) ne peut pas être importé."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="L'importation RGPD sera indisponible sur cette instance tant que le pipeline d'importation n'aura pas été réinstallé."
MSG_WARN_GIT_SAID="Git a indiqué :"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  Échec du contrôle d'intégrité : ostler-knowledge --version n'a produit aucune sortie."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  Échec du contrôle d'intégrité : le moteur de mémoire des conversations n'a pas pu se charger (pwg-convo ou l'import de son pipeline ne s'est pas terminé correctement)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="Le programme d'installation de Homebrew s'est terminé avec le code %s. Voici les 30 dernières lignes de %s :"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Journal d'installation de Homebrew (fin) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="L'installation pip de Doctor s'est terminée avec le code %s. Voici les 30 dernières lignes de %s :"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Journal d'installation pip de Doctor (fin) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="L'installation pip du pipeline s'est terminée avec le code %s. Voici les 30 dernières lignes de %s :"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- Journal d'installation pip du pipeline (fin) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="L'installation du LaunchAgent d'alimentation du Hub a échoué. Consultez la sortie ci-dessus."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="Scripts d'alimentation du Hub introuvables à l'emplacement prévu dans le bundle."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  Il semble que vendor/hub_power/ soit absent du .app de l'installateur"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  dans Contents/Resources/hub-power/. La limitation tenant compte de la batterie ne sera pas installée ; le reste de l'installation se poursuivra."
MSG_WARN_ICAL_SERVER_FAILED="Impossible de démarrer l'API de l'assistant ; l'app Ostler sur votre iPhone aura un accès limité jusqu'à la prochaine installation."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - Échec du téléchargement de l'image (réseau, espace disque ou délai d'attente du registre)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="Impossible d'écrire le signal FDA d'iMessage dans pipeline_signals.json. Il se peut que le tableau de bord Doctor n'affiche pas automatiquement la carte Accès complet au disque."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="L'hôte IMAP est vide. Réessayez."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="Autorisation d'automatisation iMessage : non accordée (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="Autorisation d'automatisation iMessage : test non concluant."
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="L'historique iMessage (chat.db) n'est pas lisible : l'Accès complet au disque n'a pas encore été accordé au démon Ostler. La lecture de l'historique iMessage reste désactivée tant que vous ne l'accordez pas dans Réglages Système > Confidentialité et sécurité > Accès complet au disque."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="Ouverture de Réglages Système > Confidentialité et sécurité > Automatisation. Cochez la ligne Messages pour OstlerInstaller (ou Terminal) afin d'activer l'envoi iMessage."
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="Adresse e-mail incomplète, ignorée : %s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="Saisissez au moins une adresse e-mail complète (par exemple you@example.com)."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage nécessite au moins un contact autorisé. Réessayez ou"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="Pipeline d'importation indisponible (dépôt privé, réservé aux bêta-testeurs)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="Le pipeline d'importation n'est pas inclus dans l'installateur. Échec bloquant contourné."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Le pipeline d'importation n'est pas inclus dans l'installateur. C'est le chemin d'installation standard ; le paquet Python contact_syncer devrait être livré dans le bundle .app."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX signifie que l'assistant lira tous les e-mails que vous recevez."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Espace disque insuffisant pour le volume de sortie du wiki"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Mac Intel détecté – les performances seront limitées. Apple Silicon recommandé."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s est un hôte de fournisseur cloud."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="JWT_SECRET dans %s figure sur la liste d'interdiction ; régénération pour que les services du graphe de connaissances restent importables"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="JWT_SECRET dans %s est trop court (%s < %s caractères) ; régénération"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="Dépôt de connaissances cloné, mais pyproject.toml est introuvable ; configuration du venv ignorée."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="Échec de l'installation du service de connaissances (clonage)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="Licence : %s est distribué sous les Conditions d'utilisation de Gemma de Google, et non sous Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="Les installations sur MacBook en ont besoin pour la gestion de la batterie et de la mise en veille."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="L'autorisation d'accès à Contacts sur macOS a été refusée ou n'a pas encore été accordée."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS ne la demandera PAS depuis un script – vous devez l'accorder manuellement."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Les Mac mini ne sont pas concernés ; les utilisateurs de MacBook doivent réessayer."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="Les données de messagerie peuvent toujours être ingérées manuellement :"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  Nouvelle tentative manuelle : cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  Nouvelle tentative manuelle une fois la cause résolue :"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Ni Apple Mail ni IMAP personnalisé n'a été sélectionné – Apple Mail est utilisé par défaut."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="Aucune clé d'accès définie ; les bases de données ne seront pas chiffrées."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="Une installation précédente a généré votre clé de récupération sans aller à son terme, et elle ne vous a donc jamais été montrée. Elle est irrécupérable – elle n'est stockée nulle part, y compris ici."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="Votre phrase secrète fonctionne toujours et rien n'est verrouillé aujourd'hui. Mais il n'existe actuellement aucun moyen de récupérer l'accès si vous l'oubliez."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="Contactez l'assistance pour faire reconfigurer la sécurité à neuf ; une nouvelle clé de récupération à conserver vous sera alors présentée."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="Les phrases secrètes ne correspondent pas. Réessayez."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="Échec de la configuration de la phrase secrète. Sortie :"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="Saisie vide. Phrase secrète ignorée."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="La phrase secrète doit comporter au moins 12 caractères. Réessayez."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="Une phrase secrète est nécessaire pour chiffrer vos données."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="Ce n'est pas un numéro international. Commencez par + suivi de l'indicatif du pays puis du reste du numéro, par exemple +447700900123. Réessayez."
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama ne répond pas"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="Échec de ollama pull %s (tentative %s/3). Nouvelle tentative dans %s s..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="Seulement %s Go disponibles. Nous recommandons au moins 35 Go (images Docker + modèle d'IA + données)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="Sur batterie, le LaunchAgent d'alimentation du Hub (étape 3.14) peut se mettre en pause"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="ou relancez l'installateur et choisissez un autre canal."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="ou en avance sur le pipeline de publication de la phase B. Relancez l'installateur une fois que"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor a signalé %s erreur(s)."

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="Ostler a terminé, mais %s erreur(s) sont survenues pendant l'installation."
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  Le détail complet se trouve dans ~/.ostler/logs/install.log. Ostler démarrera quand même ; ouvrez Doctor pour voir ce qui demande votre attention."
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="Ostler a terminé, mais %s étape(s) d'installation ne se sont pas terminées correctement : %s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="Ostler a terminé sans aucune erreur pendant l'installation."

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant a été extrait, mais la vérification de --version a échoué."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="L'installation du LaunchAgent de l'assistant Ostler a échoué après 3 tentatives. Sortie de diagnostic ci-dessus et ci-dessous."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="La tentative %s d'installation du LaunchAgent de l'assistant Ostler a échoué ; nouvelle tentative."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="Stderr complet du daemon : %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="Dernier extrait de stderr :"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s ne fonctionne que sur Apple Silicon (détecté : %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  Impossible d'installer la dépendance de stockage chiffré dans le venv de la mémoire des conversations ; l'enrichissement des conversations ne s'exécutera pas."
MSG_INFO_COACH_DB_READY="  Coaching database ready, encrypted: %s"
MSG_WARN_COACH_DB_NOT_CREATED="  Could not prepare the encrypted coaching database (it will be created on the first coaching note): %s"
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  Source de la dépendance de stockage chiffré introuvable dans SCRIPT_DIR ; le moteur de mémoire des conversations ne peut pas se charger et l'enrichissement des conversations ne s'exécutera pas."
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - image ostler-wiki-compiler pas encore téléchargeable (registre non connecté)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph ne répond pas"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph pas encore opérationnel à cette étape (consultez les journaux ci-dessus)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="Les mots de passe ne correspondent pas (ou étaient vides). Veuillez réessayer."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="L'installation principale prend généralement de 45 minutes à quelques heures (téléchargements de Docker et Ollama + première configuration), davantage avec une connexion lente ou un Mac qui a des années d'historique. De longues périodes sans activité visible sont normales – le téléchargement et la configuration se poursuivent en arrière-plan, rien n'est bloqué."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  Échec de pip install ; le moteur de mémoire des conversations ne sera pas disponible."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  Échec de pip install ; email-ingest se rabattra sur le Python du système (il peut aussi échouer à l'exécution)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  Échec de pip install ; ostler-knowledge ne sera pas disponible."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  Échec de pip install ; le moteur d'ingestion des e-mails n'est pas disponible. Le LaunchAgent horaire produira toujours des fichiers mbox, mais ne pourra pas les ingérer dans le graphe tant que ce problème n'est pas résolu."
MSG_WARN_CM021_SOURCE_NOT_FOUND="Source du moteur d'ingestion des e-mails introuvable dans le bundle de l'app ; la tâche horaire en arrière-plan enregistrera les fichiers de courrier sans les ingérer."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="Source ostler_fda introuvable dans le bundle de l'app ; le LaunchAgent email-ingest se rabattra sur le Python du système à l'exécution."
MSG_WARN_PIP_SAID="pip a indiqué :"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="Branchez le Mac au secteur pour l'installation complète."
MSG_WARN_PORT_1_ALREADY_USE_PID="Le port %s est déjà utilisé par %s (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - Le port 3000 est déjà utilisé par un autre service"
MSG_WARN_POWER_SOURCE="Source d'alimentation : %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="Échec de l'installation de sqlcipher3."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="Échec de l'installation de sqlcipher3. Les bases de données ne seront pas chiffrées."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="Python 3 introuvable. Installation de Python 3.12…"
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s est trop ancien (3.10 ou version ultérieure requise). Installation de Python 3.12…"
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant ne répond pas"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         Lisez https://ai.google.dev/gemma/terms avant tout usage commercial."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="Lisez la version publique sur https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis ne répond pas"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="version disponible, ou placez le binaire manuellement :"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="Nouvelle tentative – saisissez un hôte auto-hébergé, ou appuyez sur Ctrl-C et relancez en choisissant Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="relancez l'installateur en décochant iMessage pour l'ignorer."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="EXÉCUTION AVEC --allow-plaintext : chiffrement désactivé. NE PAS UTILISER EN PRODUCTION."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  Exécutez \`%s doctor\` après le premier lancement"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="Exécutez 'tailscale ip --4' une fois connecté, puis ajoutez l'adresse dans l'app iOS."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Échec de la copie de l'extension Safari ; vous pourrez l'installer manuellement plus tard"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="L'extension Safari est installée, mais aucun jeton d'extension n'était disponible pour l'associer ; la capture de navigation restera désactivée jusqu'à ce que vous relanciez l'installateur"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="Impossible d'associer l'extension Safari à ce Hub ; la capture de navigation restera désactivée jusqu'à ce que vous relanciez l'installateur"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="Module de sécurité introuvable. La configuration de la clé d'accès sera ignorée."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  Recherché : %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  Cela signifie généralement que l'installateur .app a été créé sans"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  le paquet ostler_security intégré dans"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Téléchargez à nouveau l'installateur ou"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  relancez avec --allow-plaintext pour une installation de développement ou d'intégration continue."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="Échec de la configuration de la sécurité. Poursuite sans chiffrement de la base de données."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="Échec de la configuration de la sécurité. Sortie :"
MSG_WARN_SEE_STDERR_FRAGMENT="  Consultez %s pour l'extrait de stderr."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="Installation du binaire ignorée. Le fichier config.toml écrit par l'assistant de configuration reste en place."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Installation du LaunchAgent de Doctor ignorée."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="Installation du LaunchAgent d'ingestion des e-mails ignorée."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="Installation du LaunchAgent ignorée. Les déploiements sur Mac mini ne sont pas concernés."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="Installation du LaunchAgent ignorée. Essayez : %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="Installation du LaunchAgent de recompilation du wiki ignorée."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="Certains ports sont utilisés. Le démarrage des conteneurs Docker pourrait échouer."
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="Le port %s est déjà utilisé par %s (PID %s), qui appartient à ce compte. Quittez-le et relancez l'installateur."
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="Le port %s est déjà utilisé par un programme appartenant à un AUTRE compte utilisateur sur ce Mac. Ostler ne peut pas le partager, et démarrer malgré tout pourrait mélanger les données des deux comptes. Fermez la session de l'autre compte, ou installez Ostler sur un Mac où ce compte est le seul à utiliser ce port."
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="Ostler ne peut pas démarrer ses bases de données, car des ports dont il a besoin sont déjà pris."
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="Arrêtez ce qui utilise les ports indiqués ci-dessus, puis relancez l'installateur."
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="Impossible de vérifier si le port %s est libre. Cela ne signifie pas pour autant que le port est libre."
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="Une ou plusieurs vérifications de ports n'ont pas pu s'exécuter ; un conflit avec un autre programme ne peut donc pas être exclu."
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="Impossible d'exécuter la vérification de port la plus fiable sur ce Mac ; les vérifications ci-dessous sont donc moins approfondies que d'habitude."
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="Ostler n'a pas pu confirmer que ces ports sont libres et ne démarrera pas ses bases de données sur un port qu'il n'a pas vérifié. Veuillez contacter l'assistance avec votre journal d'installation."
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="Impossible de supprimer un ancien élément de démarrage de Colima. Votre wiki pourrait ne pas se charger après un redémarrage ; contactez l'assistance."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="Arrêtez les services en conflit ou modifiez les ports dans docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscale ne s'est pas connecté dans les 3 minutes. Vous pourrez y revenir plus tard depuis les paramètres."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="L'adresse IP Tailscale a été écrite dans .env, mais une relecture ultérieure ne l'a pas retrouvée. L'app Ostler sur votre iPhone risque de ne pas la prendre en compte. Si c'est le cas, relancez install.sh --repair."
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="Votre réponse sur l'accès à distance n'a pas pu être enregistrée : la prochaine réinstallation vous la redemandera. Rien d'autre n'est affecté."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="L'installation de Tailscale a échoué. Vous pourrez l'installer plus tard depuis tailscale.com"
MSG_WARN_TAILSCALE_STATE_UNREADABLE="Ce Mac possède des réglages Tailscale existants qui n'ont pas pu être lus. Nous ne savons donc pas s'il est encore connecté à votre réseau. Faites votre choix ci-dessous : s'il est déjà connecté, le configurer à nouveau ne pose aucun problème."
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="les services déployés refusent de démarrer sans eux."
# NEEDS REVIEW: Fragment continues a previous line (likely '...until this is resolved'); French may need subjunctive 'soit résolu' depending on the preceding line.
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  ce problème est résolu. Consultez la bannière des prochaines étapes pour le correctif."
# NEEDS REVIEW: Fragment continues on next line (probably 'culprits'); added 'causes' may duplicate the next line's word. Check line pairing.
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  à examiner. cron-delivery / imessage-tcc sont des causes courantes"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  Essayez : docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  Essayez : docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="Choix non reconnu « %s » ; iMessage + e-mail sera utilisé par défaut."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="Choix non reconnu. L'option recommandée sera utilisée."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  La mise à jour a échoué ; poursuite avec la copie existante."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="Utilisez Apple Mail (recommandé ci-dessus) pour ce compte : Ostler ne stocke jamais les mots de passe du cloud."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="Utilisation de INBOX. L'assistant lira chaque e-mail reçu."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="Le conteneur Vane a démarré, mais http://localhost:3000 n'a pas répondu en 60 s."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane (recherche web locale) n'a pas pu démarrer. Causes courantes :"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  La recherche web est facultative ; le reste d'Ostler fonctionne sans elle."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="Nous vous recommandons vivement d'utiliser plutôt un libellé ou un dossier dédié."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp a besoin d'un numéro de téléphone pour l'envoi du résumé. Réessayez,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="Le wiki a été compilé, mais le conteneur wiki-site n'a pas pu démarrer."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="La première compilation du wiki a échoué. Causes courantes :"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="L'agent de lancement (LaunchAgent) de rattrapage du wiki du premier jour n'a pas pu être chargé. La reconstruction quotidienne du wiki s'exécute toujours ; votre wiki sera simplement actualisé le lendemain plutôt que dans l'heure."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="L'installation du LaunchAgent de recompilation du wiki a échoué. Voir la sortie ci-dessus."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="Le wiki ne se mettra pas à jour automatiquement ; la reconstruction manuelle reste disponible :"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="La configuration de l'assistant d'installation reste en place ; le binaire reste préparé. Nouvel essai manuel :"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="Votre assistant a besoin d'un nom. Choisissez parmi les suggestions ci-dessus ou saisissez le vôtre."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="Vous pouvez le réautoriser dans Réglages Système > Confidentialité et sécurité > Contacts."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="Vous pourrez lancer la configuration de sécurité plus tard : python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="Vous devrez peut-être l'installer manuellement : %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  réel :    %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="Le bundle Ostler RemoteCapture était absent de %s après l'extraction. L'archive de la version est peut-être corrompue."
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="Impossible de créer ou d'atteindre %s : Ostler RemoteCapture n'a donc aucun emplacement où s'installer. Il s'agit d'un problème d'autorisations de dossier, pas du téléchargement."
MSG_ERR_CM042_RENAME_FAILED="Ostler RemoteCapture a été téléchargé et décompressé correctement, mais n'a pas pu être déplacé vers %s. L'app décompressée a été laissée dans /Applications. Il ne s'agit pas d'un problème de signature."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify a signalé :"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  Refus de préparer un bundle qui ne correspond pas à la somme de contrôle publiée."
MSG_ERR_CM042_SHA_256_MISMATCH="Somme de contrôle SHA-256 de l'archive Ostler RemoteCapture non concordante."
MSG_ERR_CM042_PIN_FAILED="Ostler n'a pas pu confirmer l'authenticité de ce téléchargement de RemoteCapture ; il n'a donc pas été installé."
MSG_ERR_CM042_VERSION_UNKNOWN="Cette version de RemoteCapture n'est pas reconnue par Ostler ; elle n'a donc pas été installée."
MSG_ERR_CM042_SIDECAR_DISAGREES="La somme de contrôle publiée avec ce téléchargement de RemoteCapture ne correspond pas au fichier ; il n'a donc pas été installé."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess a indiqué :"
MSG_ERR_CM042_VERIFY_FAILED="La vérification de la signature et de la notarisation d'Ostler RemoteCapture a échoué."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv a indiqué :"
MSG_ERR_EXPECTED="  attendu : %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief a indiqué : %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="Le binaire ostler-assistant situé à %s n'est pas un exécutable Mach-O."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="Le SHA-256 de l'archive tarball ostler-assistant ne correspond pas."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  Refus de préparer un binaire qui ne correspond pas à la somme de contrôle publiée."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="Refus de retirer la quarantaine ou de charger le LaunchAgent."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="Relancez l'installateur une fois l'archive tarball en amont corrigée."
MSG_ERR_URL="  url :     %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Les Mac Intel ne sont pas pris en charge. Ostler nécessite une puce Apple Silicon (M1, M2, M3 ou M4)."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="Au moins 16 Go de RAM sont nécessaires. Vous disposez de %s Go. 24 Go sont recommandés."
MSG_FAIL_CM042_SIGNATURE_FAILED="L'installation d'Ostler RemoteCapture a été interrompue : la vérification de la signature ou de la notarisation a échoué. Le bundle a été laissé dans /Applications pour le support. Écrivez à support@ostler.ai, puis relancez l'installateur."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="Impossible de télécharger %s après 3 tentatives. Vérifiez votre réseau et relancez l'installateur."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="Impossible de télécharger nomic-embed-text après 3 tentatives. Vérifiez votre réseau et relancez l'installateur."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker n'est pas disponible. Relancez l'installateur pour installer Colima."
MSG_FAIL_CONTAINER_CLIENT_MISSING="La commande docker est absente de ce Mac, donc Ostler ne peut pas démarrer les services dont il a besoin. Relancez l'installateur ; si l'échec se reproduit, envoyez-nous le journal situé à %s."
MSG_FAIL_CONTAINER_ENGINE_ABSENT="Ostler a besoin d'un environnement d'exécution de conteneurs, et aucun ne répond sur ce Mac. Votre wiki, votre graphe de connaissances et votre index de recherche fonctionnent tous dans des conteneurs ; l'installation s'est donc arrêtée ici plutôt que de se terminer en les laissant absents. Pour corriger : ouvrez Terminal et exécutez 'colima start', puis relancez cet installateur. Si vous utilisez plutôt Docker Desktop, ouvrez-le, attendez que l'icône de baleine se stabilise, puis relancez. Le journal complet se trouve à %s."
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="Docker n'est pas devenu prêt à temps pour démarrer les bases de données du graphe de connaissances. Assurez-vous que Colima ou Docker est en cours d'exécution, puis relancez l'installateur."
MSG_FAIL_GRAPH_DB_PULL_FAILED="Impossible de télécharger les images des bases de données du graphe de connaissances après plusieurs tentatives. Il s'agit généralement d'un problème de réseau. Vérifiez votre connexion Internet et relancez l'installateur."
MSG_FAIL_GRAPH_DB_UP_FAILED="Les bases de données du graphe de connaissances ont été téléchargées, mais n'ont pas pu être démarrées. Relancez l'installateur ; si le problème persiste, ouvrez Terminal et exécutez : cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="Ostler n'a pas pu mener à bien une requête authentifiée auprès de la base de données du graphe de connaissances. Il a essayé deux fois, à deux secondes d'intervalle, et les deux tentatives ont été refusées. Nous ignorons encore pourquoi : la base de données était peut-être encore en cours de démarrage, ou l'identifiant détenu par Ostler n'est peut-être pas celui attendu. Vos données n'ont pas été touchées. Relancer l'installateur réussit souvent, et si c'est le cas, nous aimerions tout de même en être informés – envoyez-nous le journal d'installation, car il s'agit d'un défaut que nous cherchons activement à reproduire."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="Le module d'extraction FDA est absent du bundle de l'installateur. Téléchargez à nouveau le .app depuis ostler.ai/install, ou relancez avec --allow-plaintext pour le développement/CI."
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="Le module d'extraction de données a été installé mais ne peut pas être chargé ; l'actualisation en arrière-plan échouerait donc à chaque exécution. La sortie complète est enregistrée dans %s – relancez l'installateur et joignez ce fichier si vous contactez le support (Référence : ERR-10-FDA-DEPS-IMPORT)."
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="Erreur interne : le module d'extraction de données a été placé à l'intérieur du bundle de l'application, ce qui en briserait la signature. Il s'agit d'un défaut de compilation, pas d'un problème lié à votre Mac. Téléchargez à nouveau le .app depuis ostler.ai/install (Référence : ERR-10-FDA-DEPS-UNSAFE-PATH)."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="L'installation des dépendances de Doctor a échoué. La sortie complète est enregistrée dans %s – joignez-la à votre e-mail à support@ostler.ai (Référence : ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="L'installation des dépendances du pipeline d'importation a échoué. La sortie complète est enregistrée dans %s – joignez-la à votre e-mail à support@ostler.ai (Référence : ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="L'installation de Homebrew a échoué. La sortie complète est enregistrée dans %s – joignez-la à votre e-mail à support@ostler.ai."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="L'installation du pipeline d'importation a échoué. Le bundle contact_syncer est requis pour l'installation produit. Relancez avec --allow-plaintext pour le développement/CI, ou téléchargez à nouveau l'installateur et réessayez."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="L'accès sudo est nécessaire pour désactiver la mise en veille et installer Homebrew. Relancez quand vous êtes prêt."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Ni Colima ni Docker Desktop n'ont pu démarrer. Installez Docker Desktop et relancez."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="Espace disque insuffisant (%s Go). Libérez de l'espace et réessayez."
MSG_FAIL_MACOS_BELOW_FLOOR="macOS %s est plus ancien que les versions prises en charge par Ostler. Ostler nécessite macOS %s ou ultérieur : l'app d'installation est conçue pour cette version et ne s'ouvrira pas sur une version plus ancienne. Mettez à jour macOS, puis relancez l'installateur."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="Aucune clé d'accès définie et aucune configuration de sécurité existante. Relancez avec --allow-plaintext pour le développement/CI, ou relancez l'installateur et validez la présentation de Touch ID."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="Le moteur de mémoire des conversations est requis. Relancez avec --allow-plaintext pour le développement/CI, ou corrigez le bundle manquant ci-dessus et réessayez."
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="Le daemon Ostler intégré (v%s à %s) ne prend pas en charge la commande 'run-source' dont cet installateur a besoin pour acheminer l'ingestion via l'Accès complet au disque. Il s'agit d'une incompatibilité de versions dans le bundle de l'installateur : l'installer laisserait toutes les sources d'ingestion silencieusement défaillantes et le produit deviendrait obsolète sans erreur visible. Téléchargez à nouveau le .app depuis ostler.ai/install et réessayez (Référence : ERR-11-DAEMON-RUN-SOURCE-SKEW)."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="L'installation de ostler_security a échoué. Relancez avec --allow-plaintext pour le développement/CI, ou corrigez l'erreur pip ci-dessus et réessayez."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="La configuration de la clé d'accès a échoué. Relancez avec --allow-plaintext pour le développement/CI, ou corrigez l'erreur ci-dessus et réessayez."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="sqlcipher3 est requis pour les bases de données chiffrées. Relancez avec --allow-plaintext pour le développement/CI, ou corrigez l'erreur pip ci-dessus et réessayez."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Cet installateur est réservé à macOS."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="L'installation des outils en ligne de commande Xcode n'a pas abouti en 15 minutes. Ouvrez Terminal et exécutez « xcode-select --install », cliquez sur Installer dans la fenêtre macOS et attendez la fin de l'opération, puis relancez cet installateur."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="L'installation de Homebrew a signalé une réussite, mais /opt/homebrew/bin/brew est introuvable. Consultez %s pour la transcription complète. Solution : ouvrez Terminal et exécutez '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"', puis relancez l'installateur."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew est installé dans /opt/homebrew/bin/brew, mais la commande « brew » n'est pas dans le PATH après l'évaluation de shellenv. Ouvrez un nouveau Terminal et relancez l'installateur."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="« brew install colima docker docker-compose » a signalé une réussite, mais colima n'est pas dans le PATH. Consultez %s pour les échecs de Homebrew. Solution : ouvrez Terminal et exécutez manuellement « brew install colima docker docker-compose », puis relancez l'installateur."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="« brew install colima docker docker-compose » a signalé une réussite, mais la CLI docker n'est pas dans le PATH. Consultez %s. Solution : exécutez manuellement « brew install docker », puis relancez l'installateur."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="The Ollama install reported success but its binary is missing. Check %s, then re-run the installer."
MSG_FAIL_OLLAMA_PIN_DOWNLOAD="Could not download Ollama %s. Check your internet connection, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_PIN_SHA256="The Ollama %s download did not match its recorded fingerprint, so it was not installed. This can mean the download was damaged or altered. Re-run the installer; if it happens again, contact support. Details: %s"
MSG_FAIL_OLLAMA_PIN_UNPACK="Ollama %s downloaded but could not be unpacked. Check free disk space, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_AGENT_NOT_PINNED="The local AI service is set to run %s instead of the copy of Ollama this installer verified (%s), so it would not stay on a tested version. The install has stopped. Re-run the installer; if this repeats, contact support. Details: %s"
MSG_FAIL_EMBED_HEALTHCHECK="Ollama est en cours d'exécution, mais le modèle d'embedding n'a renvoyé aucun vecteur (HTTP différent de 200, ou résultat vide). La fiche Personnes, la recherche et la navigation seraient toutes vides. Consultez %s. Solution : vérifiez que l'app Ollama (et non la formule Homebrew) est installée et en service, puis relancez l'installateur."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="« brew install sqlcipher » a signalé une réussite, mais sqlcipher n'est pas dans le PATH. Consultez %s. Solution : exécutez manuellement « brew install sqlcipher », puis relancez l'installateur."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="« brew install --cask tailscale » n'a pas produit /Applications/Tailscale.app. Consultez %s. Solution : téléchargez Tailscale depuis https://tailscale.com/download/macos et faites-le glisser dans /Applications, puis relancez l'installateur."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="« brew install python@3.11 » a signalé une réussite, mais le binaire python3.11 est introuvable dans /opt/homebrew/opt/python@3.11/bin/python3.11. Consultez %s. Solution : exécutez « brew reinstall python@3.11 », puis relancez l'installateur."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="Nous avons retrouvé vos réponses précédentes"
MSG_PROMPT_REUSE_SETTINGS_HELP="Nous avons détecté une tentative d'installation antérieure sur ce Mac. Les questions auxquelles vous avez déjà répondu (nom, nom de l'assistant, fuseau horaire, indicatif du pays, canaux, etc.) seront réutilisées pour vous éviter de les saisir à nouveau. Choisissez Oui pour reprendre là où vous vous étiez arrêté, ou Non pour répondre à nouveau aux questions depuis le début."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Réponses précédentes retrouvées : nom = %s, assistant = %s, fuseau horaire = %s."

MSG_PROMPT_PERMS_OK_TITLE="Prêt à continuer ?"
MSG_PROMPT_PERMS_OK_HELP="macOS demandera l'accès aux Contacts et à Fichiers et dossiers. L'accès complet au disque, facultatif, pourra être accordé plus tard."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Nom complet (tel qu'il apparaît dans vos contacts)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Nom complet (p. ex. Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="Comment votre assistant doit-il vous appeler ?"
MSG_PROMPT_USER_ID_HELP="Un nom court que votre assistant utilisera pour s'adresser à vous (p. ex. « Andy », « Andrew », « Mme Smith »). C'est celui qui apparaît dans vos résumés du matin et les réponses du chat. Il est différent de votre nom complet ci-dessus."

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
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="Voici vos calendriers. Cela vous semble-t-il correct ?"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="Nous avons deviné à qui appartient chacun, afin que votre résumé ne confonde jamais les voyages des uns et des autres."
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="Mis de côté automatiquement, non utilisés pour votre résumé :"
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="à vous"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="%s événement"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="%s événements"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="jours fériés"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="anniversaires"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="suggestions de Siri"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="un calendrier auquel vous êtes abonné"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="rappels"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="Utiliser « %s » pour votre résumé ?"
# NEEDS REVIEW: Inserted fragments ('jours fériés', 'un calendrier auquel…') don't fit 'ressemble à' grammatically; colon form is safer. Check rendered output with each fragmen
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="Nous avons mis celui-ci de côté car il semble s'agir de : %s. Répondez oui s'il s'agit vraiment de l'agenda de quelqu'un."
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="À qui appartient le calendrier « %s » ?"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="De quel type est le calendrier « %s » ?"
# NEEDS REVIEW: If the installer compares typed input to the English values (personal, work, family, shared, other), these must stay in English. Developer should confirm.
MSG_CONFIRM_CALENDAR_TYPE_HELP="Une des valeurs : personnel, travail, famille, partagé, autre. Cela détermine la sensibilité accordée à ses événements."
MSG_CONFIRM_CALENDARS_SAVED="Propriétaires de calendriers enregistrés"
MSG_CONFIRM_CALENDARS_FAILED="Impossible d'enregistrer les propriétaires de calendriers (non bloquant ; vous pourrez les définir plus tard)"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="Nous pensons que tous ces profils vous correspondent (%s). Les fusionner en un seul ?"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="Ces profils partagent avec vous un signal d'identité fort (un domaine d'e-mail, un profil LinkedIn ou un employeur). Les fusionner évite que votre assistant traite votre propre historique comme celui de plusieurs personnes. Vous pourrez annuler cela plus tard."
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="Une personne porte le même nom que vous mais semble être quelqu'un d'autre (%s). Est-ce vous, ou une autre personne ?"
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="Choisissez « différent » pour la garder comme personne distincte (votre assistant ne la fusionnera jamais avec vous). Choisissez « moi » uniquement si c'est vraiment vous."
MSG_CONFIRM_IDENTITY_SAVED="Identité enregistrée"
MSG_CONFIRM_IDENTITY_FAILED="Impossible d'enregistrer les choix d'identité (non bloquant ; vous pourrez confirmer plus tard)"

# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="Installation en arrière-plan (environ 45 minutes à quelques heures)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="Utiliser +%s ?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Saisissez l'indicatif du pays (par ex. 44 pour le Royaume-Uni, 1 pour les États-Unis)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Indicatif pays par défaut"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Sert à normaliser les numéros de téléphone lors de l'import des contacts et à définir votre région (Royaume-Uni / UE / États-Unis / autre) pour les réglages de conformité légale par défaut."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="Nous avons détecté +%s. L'utiliser pour votre Hub ?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Détecté à partir de votre numéro de téléphone ci-dessus. Choisissez Oui pour l'utiliser, ou Non pour saisir un autre indicatif."

MSG_PROMPT_TZ_CONFIRM_TITLE="Utiliser ce fuseau horaire ?"
MSG_PROMPT_TZ_CONFIRM_HELP="Fuseau horaire détecté : %s"
MSG_PROMPT_USER_TZ_TITLE="Saisissez le fuseau horaire (par ex. Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="Comment souhaitez-vous appeler votre assistant ?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="Le nom dans le champ est une suggestion aléatoire : remplacez-le par ce que vous voulez. Marvin, Samantha, Joshua, Friday, Athena, Sage et Rosie sont des choix populaires." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Saisissez le nom de votre choix : la suggestion n'est qu'un point de départ."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="Comment votre assistant vous contactera-t-il ?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Choisissez les canaux de messagerie que votre assistant pourra utiliser. Vous pourrez modifier ce choix plus tard dans la section Doctor de l'app."

MSG_PROMPT_WHATSAPP_CONSENT_TITLE="Enable WhatsApp messaging for your assistant?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web is a third-party service. By enabling, you accept that your messages route through WhatsApp's own infrastructure before reaching your local Ostler instance, and that WhatsApp (Meta Platforms Ireland Ltd) may suspend, restrict, or terminate your WhatsApp account because of automated use. You can disable this later from Settings."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="Votre numéro de téléphone WhatsApp"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Numéro international avec indicatif du pays, par ex. +447700900123. Uniquement des chiffres et un + initial : sans espaces, parenthèses ni tirets."
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="Enregistré sous la forme %s. WhatsApp exige le numéro sans espaces ni parenthèses."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Activez l'Accès complet au disque pour l'assistant Ostler"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="Les Réglages Système sont ouverts sur Accès complet au disque."
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
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Trouvez « %s » dans la liste et activez son interrupteur d'Accès complet au disque."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="Absent de la liste ? Faites glisser « %s » depuis la fenêtre du Finder dans la liste, puis activez son interrupteur. L'ordre n'a pas d'importance : cliquez sur Terminé avant ou après ; l'installateur attend que l'interrupteur soit réellement activé."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="Absent de la liste ? Ostler n'a pas pu ouvrir de fenêtre du Finder pour vous. Dans le Finder, appuyez sur ⌘⇧G, saisissez le chemin ci-dessous, puis faites glisser « %s » dans la liste et activez son interrupteur. L'ordre n'a pas d'importance : cliquez sur Terminé avant ou après ; l'installateur attend que l'interrupteur soit réellement activé."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="L'app se trouve ici : %s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="L'app se trouve ici : %s – ce chemin est dans votre presse-papiers : dans le Finder, appuyez sur ⌘⇧G, puis ⌘V, puis Retour."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Terminé"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="Vous pouvez cliquer sur Terminé avant ou après avoir activé l'interrupteur : l'installateur attend qu'il soit réellement activé."

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Autoriser Ostler à lire les données de votre Mac"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="Les Réglages Système sont ouverts sur Accès complet au disque."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Trouvez « OstlerInstaller » dans la liste et activez-le."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Cliquez sur Terminé une fois fini et Ostler lira votre historique Safari, vos Notes, vos iMessages et Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Terminé"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="Ensuite : Accès complet au disque pour l'installateur"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="Ensuite, macOS vous demandera d'accorder l'Accès complet au disque à OstlerInstaller."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Une fois l’interrupteur activé, macOS affichera une fenêtre vous demandant de choisir « Quitter et rouvrir » ou « Plus tard »."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Cliquez sur « Quitter et rouvrir ». L’installateur se relancera de lui-même et reprendra automatiquement à cette étape."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="OK"
MSG_INFO_INSTALLER_FDA_PREWARN="Présentation de l’autorisation d’accès complet au disque..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="Ouverture des Réglages Système pour que vous puissiez accorder l’accès complet au disque à l’installateur..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="Accès complet au disque accordé à l’installateur. Prochaine étape : lecture de Safari, Notes, iMessage et Mail."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="L’accès complet au disque n’est toujours pas accordé. L’installation continue sans cet accès ; vous pourrez relancer l’installateur plus tard pour extraire Safari / Notes / iMessage."
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="L’accès complet au disque pour l’installateur est en place. La partie longue commence maintenant et se déroule en grande partie seule, mais gardez un œil sur une fenêtre macOS demandant d’installer les outils de développement, et revenez pour quelques minutes de configuration vers la fin."
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="Une autre autorisation (l’historique de Messages pour votre assistant) sera demandée vers la fin, une fois votre assistant installé : nous vous indiquerons alors où la trouver."
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="Accès complet au disque toujours nécessaire"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostler s’apprête à lire les données de votre Mac, mais l’accès complet au disque pour OstlerInstaller est toujours désactivé. Repérez « OstlerInstaller » dans la liste et activez-le."
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="Vous pouvez aussi cliquer sur Continuer pour terminer l’installation avec moins de données : vous pourrez accorder l’accès et relancer l’extracteur plus tard."
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="Continuer"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="Contacts autorisés"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="Personnes de confiance : numéros de téléphone et adresses e-mail Apple ID (séparés par des virgules). %s ne répond qu’aux personnes de cette liste ; les messages de toute autre personne sont ignorés. Au moins une entrée est requise.

Par exemple :
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="Lire le courrier via Apple Mail ?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Lit tous les comptes e-mail ajoutés à Apple Mail (iCloud, Gmail, Outlook, etc.) grâce à l’accès complet au disque. Aucun mot de passe n’est stocké. Recommandé pour presque tout le monde."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="Ajouter un compte de messagerie à Apple Mail ?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="Aucun compte n’est encore connecté à Apple Mail sur ce Mac, donc Ostler n’aura aucun e-mail à lire. Choisissez Oui pour ouvrir maintenant Réglages Système > Comptes internet (vous pourrez y ajouter iCloud, Gmail ou Outlook). Choisissez Non pour passer ; vous pourrez ajouter un compte plus tard et Doctor vous le signalera si aucun e-mail n’arrive dans les 24 heures."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="Récupérer tout l’historique d’Apple Mail ?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Par défaut, Ostler lit les cinq dernières années de votre Apple Mail. Si vous conservez plus sur ce Mac et souhaitez tout intégrer à votre graphe de connaissances, choisissez Oui pour récupérer maintenant tout l’historique local (cela peut prendre un peu plus de temps pour une grande boîte). Choisissez Non pour garder la fenêtre de cinq ans ; vous pourrez toujours l’étendre plus tard depuis Doctor."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="Configurer aussi un serveur IMAP+SMTP personnalisé ?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="Uniquement pour les boîtes auto-hébergées. Laissez sur NON si vos comptes sont chez Gmail, iCloud ou Outlook : ils fonctionnent mieux via Apple Mail, ci-dessus."

MSG_PROMPT_IMAP_HOST_TITLE="Hôte IMAP"
MSG_PROMPT_IMAP_HOST_HELP="Uniquement pour un serveur IMAP auto-hébergé ou personnalisé. Utilisez Apple Mail (ci-dessus) pour Gmail / iCloud / Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="Port IMAP"

MSG_PROMPT_SMTP_HOST_TITLE="Hôte SMTP"
MSG_PROMPT_SMTP_PORT_TITLE="Port SMTP"

MSG_PROMPT_EMAIL_USERNAME_TITLE="Adresse e-mail (aussi utilisée comme identifiant IMAP/SMTP)"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="Qui peut écrire à votre assistant ?"
MSG_PROMPT_EMAIL_ALLOWED_HELP="Vos propres adresses e-mail, séparées par des virgules. %s ne répond qu’aux e-mails provenant des adresses de cette liste ; le courrier de toute autre personne est ignoré. Au moins une adresse est requise. Votre adresse est déjà renseignée : modifiez-la ou ajoutez-en une autre."

MSG_PROMPT_EMAIL_PASSWORD_TITLE="Mot de passe (masqué)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Password for your self-hosted IMAP/SMTP server. Stored locally in ~/.ostler/secrets/, not in your settings file, and never sent to Creative Machines. It is saved in plain text: the only thing protecting it is the file's permissions, which allow your macOS account and nobody else. Nothing encrypts it later. Use an app password rather than your main account password."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Confirmer le mot de passe"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="Quel dossier l’assistant doit-il surveiller ?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="Recommandé : un libellé ou dossier dédié (par ex. Ostler). Nous ne lirons que les messages qui s’y trouvent, sans toucher à votre boîte de réception principale."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="Saisissez à nouveau INBOX pour confirmer, ou appuyez sur Continuer pour utiliser « Ostler »"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX signifie que l’assistant lira chaque e-mail que vous recevez. Nous recommandons vivement d’utiliser plutôt un libellé ou dossier dédié."

MSG_PROMPT_EXPORTS_ACK_TITLE="Avez-vous demandé vos exportations de données ?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler importe depuis une vingtaine de plateformes. La liste complète, avec des liens directs vers la page de demande de chaque fournisseur, se trouve sur docs.ostler.ai/data-exports.

La plupart des archives mettent de 1 à 3 jours à arriver par e-mail. Lorsque les ZIP arrivent, déposez-les dans votre dossier Téléchargements et Ostler les trouvera automatiquement.

Ignorez celles que vous n’utilisez pas ; vous pourrez toujours en importer d’autres plus tard."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="Continuer avec votre disque NON CHIFFRÉ au repos ?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="FileVault est désactivé sur ce Mac : votre disque n’est donc pas chiffré au repos.

Ce que cela implique si vous continuez : tout ce qu’Ostler stocke, c’est-à-dire l’ensemble de votre graphe personnel (wiki, conversations, notes de connaissance) dans ~/Documents/Ostler, ainsi que les secrets des services et les bases de données dans ~/.ostler, est écrit sur le disque NON CHIFFRÉ. Toute personne pouvant démarrer depuis ce disque, le retirer ou accéder à une session déverrouillée peut tout lire. Ostler chiffre de toute façon ses bases de données les plus sensibles avec une phrase secrète, mais le reste de vos données n’est protégé que par le disque lui-même.

FileVault est fortement recommandé. Vous pouvez l’activer à tout moment dans Réglages Système > Confidentialité et sécurité > FileVault : le chiffrement s’effectue en arrière-plan, sans réinstallation.

Choisissez Oui pour continuer maintenant avec le disque non chiffré au repos (c’est un choix délibéré et éclairé, il sera consigné).
Choisissez Non pour vous arrêter ici, activer d’abord FileVault, puis relancer l’installateur. Dans les deux cas, rien n’a mal tourné."

MSG_PROMPT_PASSKEY_ACK_TITLE="Prêt à configurer le chiffrement du disque"
MSG_PROMPT_PASSKEY_ACK_HELP="Les bases de données sensibles d’Ostler sont chiffrées avec SQLCipher à l’aide d’une phrase secrète que vous choisirez à l’écran suivant. Vous la saisirez à chaque démarrage de l’interface du Hub. Une clé de récupération distincte est également générée et affichée une seule fois à la fin de l’installation. Pour protéger au repos tout le contenu de votre Mac, laissez FileVault de macOS activé. Cliquez sur Continuer quand vous êtes prêt."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="Définir aussi une phrase secrète de récupération ? (recommandé)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="Choisissez votre phrase secrète"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="Cette phrase secrète chiffre votre graphe de connaissances et déverrouille l’interface du Hub à chaque démarrage. 12 caractères minimum. Nous ne pouvons pas la récupérer pour vous. Il est recommandé de la conserver dans un gestionnaire de mots de passe."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="Confirmez votre phrase secrète"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="Saisissez à nouveau la même phrase secrète pour confirmer."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="Importer ces éléments pendant l’installation ?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="Les exports RGPD trouvés seront importés dans votre graphe de connaissances pendant l’installation."

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="Mot de passe de l’export Disney+"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="Disney+ fournit son export RGPD sous forme de feuille de calcul protégée par mot de passe. C’est normal et votre téléchargement n’est pas en cause. Saisissez le mot de passe pour importer dès maintenant votre historique de visionnage Disney+, ou laissez le champ vide pour l’ignorer ; tout le reste sera tout de même importé."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="Avez-vous des exports de données prêts ?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler peut importer des archives de réseaux sociaux et de plateformes – tout votre historique avec vos amis, votre famille, vos lieux, vos opinions – dès le départ. Plus Ostler en sait le premier jour, plus il est utile dès ce jour. Vous pouvez aussi l’ajouter plus tard, rien ne presse.

Demandez l’export de vos données à chaque plateforme (Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp, etc.), téléchargez les fichiers ZIP et placez-les dans votre dossier Téléchargements.

Ostler cherchera par défaut dans ~/Downloads. Vous préférez un autre dossier ? Choisissez-en un ci-dessous. Sinon, passez cette étape et importez plus tard."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="Importer les messages Gmail de ce Takeout ?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Lit le contenu Gmail directement depuis le fichier Takeout. Google ne voit jamais Ostler."

MSG_PROMPT_FDA_PRESET_TITLE="Quelles sources du Mac Ostler doit-il utiliser pour apprendre ?"
MSG_PROMPT_FDA_PRESET_HELP="Trois préréglages, ou choisissez chaque source vous-même. Les sources sensibles (reconnaissance faciale) sont désactivées par défaut dans chaque préréglage : choisissez-les en connaissance de cause si vous le souhaitez."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="Recommandé. Comprend Apple Mail, Contacts, Calendrier, Notes, Messages, Rappels, l’historique de Safari, les signets de Safari et les événements de Photos (dates et lieux, sans reconnaissance faciale). L’historique de WhatsApp Desktop et celui de Chrome sont ajoutés automatiquement lorsque l’app est installée. Exclut les données de reconnaissance faciale de Photos et toute archive d’export tierce."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="Tout. Toutes les sources qu’Ostler peut lire sur ce Mac. La reconnaissance faciale de Photos reste désactivée tant que vous ne la cochez pas délibérément."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="Personnaliser. Choisissez chaque source à l’écran suivant. Les sources sensibles restent désactivées tant que vous ne les cochez pas."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="Activer ou désactiver cette source de données."

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
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="La transcription orale restera désactivée. Vous pourrez l'activer plus tard dans Réglages."

MSG_PROMPT_CONSENT_INSTALL_TITLE="Ready to install?"
MSG_PROMPT_CONSENT_INSTALL_HELP="Please type INSTALL to confirm you accept the terms."
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Type INSTALL"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Install Ostler"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Cancel"
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Type INSTALL exactly (case does not matter) to confirm, or click Cancel to go back."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="Connecter votre iPhone et votre Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale donne à ce Mac une adresse privée stable que votre iPhone et votre Watch peuvent joindre de n'importe où, chiffrée et sans exposition publique."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="Enregistrer la clé de récupération dans le Trousseau ?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="Conserve votre clé de récupération du chiffrement en lieu sûr dans le trousseau de macOS."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="Alimentation de votre graphe"
MSG_HYDRATE_CONTACTS_STARTED="Importation de vos contacts dans le graphe"
MSG_HYDRATE_CONTACTS_DONE="%s contacts importés"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="L'importation des contacts a dépassé %s s, nous avons donc cessé d'attendre et poursuivi. %s contacts sont déjà importés, et Ostler terminera le reste en arrière-plan."
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="Chargement de l'historique de votre calendrier (cinq ans en arrière, un an en avant)"
MSG_HYDRATE_CALENDAR_DONE="%s événements importés"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  Chargement de votre calendrier en cours (%ss écoulées). Sur un Mac avec des années de réunions, cela prend un moment."
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="Création de vos Lieux à partir des endroits où vous avez des rendez-vous"
MSG_HYDRATE_PLACES_DONE="Votre section Lieux est créée"
MSG_HYDRATE_PLACES_SKIPPED="Aucune information de lieu pour l'instant. Les Lieux apparaîtront à mesure que votre calendrier se remplira"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="La création des Lieux a rencontré un problème : des informations de lieu existent, mais aucun Lieu n'a été produit. Votre page Lieux risque de rester vide. Voir %s"
MSG_HYDRATE_PLACES_ERROR_WARN="La création des Lieux ne s'est pas terminée (erreur inattendue). Votre page Lieux risque d'être incomplète. Voir %s"
MSG_HYDRATE_WIKI_RECOMPILE="Création de votre wiki. Ostler rédige un court résumé pour chacune de vos personnes, organisations et thématiques clés ; avec un grand carnet d'adresses, cela peut prendre de quelques minutes à environ une heure. Cela n'arrive qu'une seule fois, se déroule entièrement sur votre Mac, et vous pouvez le laisser tourner sans crainte."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="Vérification de votre index de recherche (%s collections détectées)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="Chargement de votre historique de navigation dans l'index de recherche"
MSG_INITIAL_HYDRATE_QDRANT_READY="Index de recherche prêt (%s collections)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="L'index de recherche se remplira en arrière-plan une fois l'installation terminée"
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
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="Le stockage de recherche est actif ; création des collections qui lui manquent encore : %s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="L'index de recherche est incomplet : %s n'a pas pu être créé, alors que le stockage de recherche fonctionne et répond. Ostler continuera de fonctionner et le Doctor signale cette lacune, mais cette partie de la recherche restera vide tant que le problème ne sera pas résolu."
MSG_WARN_QDRANT_COLLECTIONS_MISSING="L'index de recherche est incomplet : %s n'a pas pu être créé. Ostler continuera de fonctionner, et le Doctor signale cette lacune."
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="Impossible de vérifier quelles collections de recherche existent (%s). Cela ne signifie pas qu'elles sont manquantes."
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="L'index de recherche se remplira en arrière-plan une fois l'installation terminée (en attente de : %s)"
MSG_HYDRATE_DONE="Votre graphe est prêt : %s personnes, %s événements"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud est peut-être encore en train de synchroniser vos contacts – nouvelle exportation en cours pour récupérer ce qui vient d'arriver."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="Aucun contact trouvé dans votre app Contacts (en local ou sur iCloud). Ajoutez-en dans Contacts, puis relancez depuis les Réglages."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="Aucun contact iCloud à importer. Vous pourrez les ajouter plus tard depuis les Réglages."
MSG_HYDRATE_SKIPPED_NO_EVENTS="Aucun événement de calendrier au cours des 5 dernières années. Vous pourrez récupérer l'historique plus tard depuis les Réglages."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="Lecture de vos e-mails des 90 derniers jours – vos e-mails restent sur ce Mac (l'historique plus ancien est récupéré en arrière-plan)"
MSG_HYDRATE_EMAIL_DONE="%s personnes trouvées dans vos e-mails récents"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="Aucun e-mail récent à lire. Vous pouvez ajouter un compte dans Apple Mail et relancer plus tard."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="Le lecteur d'e-mails n'est pas encore prêt. Vous pouvez ajouter un compte dans Apple Mail et relancer plus tard."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="Les e-mails sont encore en cours de chargement en arrière-plan. Votre wiki se remplit au fur et à mesure et vous indique où il en est."
MSG_HYDRATE_EMAIL_HEARTBEAT="  Lecture de vos e-mails en cours (%ss écoulées). Cela peut prendre du temps sur un Mac avec des années d'historique."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="Ouvrir Apple Mail pour qu'il commence à se synchroniser ?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="Vous avez %s compte(s) de messagerie configuré(s), mais Apple Mail n'a encore récupéré aucun message. Nous pouvons ouvrir Mail.app maintenant et attendre la fin de la synchronisation."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="Ouvrir Calendrier pour qu'il commence à se synchroniser ?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="Vous avez %s compte(s) de calendrier configuré(s), mais Calendar.app ne contient encore aucun événement. Nous pouvons ouvrir Calendrier maintenant et attendre la synchronisation depuis iCloud."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="Ouvrir Contacts pour qu'il commence à se synchroniser ?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="Vous avez %s compte(s) de contacts configuré(s), mais Contacts.app ne contient encore aucune fiche. Nous pouvons ouvrir Contacts maintenant et attendre la synchronisation depuis iCloud."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="En attente du début de la synchronisation de %s (jusqu'à %s secondes)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="Toujours en attente de la synchronisation de %s (%ss écoulées, %ss restantes). La première synchronisation iCloud peut prendre quelques minutes après une nouvelle connexion."
MSG_OK_APP_HAS_POPULATED="%s a rempli son stockage local. Poursuite de l'installation."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="Nous n'avons pas détecté la synchronisation de %s pendant le délai d'attente. Poursuite de l'installation ; vous pourrez relancer l'importation plus tard depuis les Réglages."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="Comptes Apple Mail visibles : %s. Ouvrez Mail.app une fois pour qu'il commence à récupérer les messages."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="Comptes de calendrier visibles : %s. Ouvrez Calendar.app une fois pour qu'il synchronise vos événements."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="Comptes de contacts visibles : %s. Ouvrez Contacts.app une fois pour qu'il synchronise votre carnet d'adresses."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="Impossible de lire vos Contacts. Ostler les lit grâce à l'Accès complet au disque : autorisez-le dans Réglages Système > Confidentialité et sécurité > Accès complet au disque, puis relancez l'hydratation depuis les Réglages. Nous continuerons de réessayer en arrière-plan."
MSG_HYDRATE_CONTACTS_PENDING="Votre app Contacts n'a pas encore été synchronisée. Ouvrez Contacts une fois, attendez la fin de la synchronisation, puis relancez l'hydratation depuis les Réglages."
MSG_HYDRATE_CONTACTS_READ_FAILED="Vos contacts sont sur ce Mac, mais Ostler n'en a importé aucun (0), ce qui est inattendu. L'importation sera réessayée automatiquement en arrière-plan. Si le problème persiste, relancez l'hydratation depuis les Réglages ou consultez le journal d'installation."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler continuera de vérifier en arrière-plan et importera automatiquement vos contacts dès qu'iCloud aura terminé la synchronisation."
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="%s contacts importés avec numéros de téléphone, mais presque aucune adresse e-mail (%s téléphones contre %s e-mails). Cela signifie généralement que le lecteur de contacts a ignoré les e-mails. Vos contacts restent utilisables ; consultez %s et relancez l'hydratation depuis les Réglages une fois le problème résolu."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="Nouveaux contacts importés ; reconstruction de votre wiki en arrière-plan."
MSG_HYDRATE_CALENDAR_PENDING="Votre app Calendrier n'a pas encore synchronisé les événements. Ouvrez Calendrier une fois, attendez la fin de la synchronisation, puis relancez l'hydratation depuis les Réglages."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="Impossible de lire votre calendrier cette fois (l'extracteur a signalé une erreur, et non un calendrier vide). Vos autres données n'ont pas été affectées ; consultez %s, puis relancez l'hydratation depuis les Réglages."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="Lecture de votre historique WhatsApp – vos messages restent sur ce Mac"
MSG_HYDRATE_WHATSAPP_DONE="%s personnes trouvées dans vos discussions WhatsApp"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="Les discussions WhatsApp ont été lues mais n'ont pas été écrites dans votre graphe de personnes (code de sortie %s). Ostler réessaiera. Détails : %s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="Aucune discussion WhatsApp à lire. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktop n'est pas installé. Installez-le depuis le Mac App Store, puis relancez depuis les Réglages."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="Le lecteur WhatsApp n'est pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp est toujours en cours de chargement en arrière-plan. Votre wiki se remplit au fur et à mesure et vous montre où en est le chargement."

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
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="Vos contacts WhatsApp sont déjà dans votre graphe de personnes (%s identifiants). Rien à relire."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="Vos contacts WhatsApp ont déjà été lus, mais votre graphe de personnes ne les contient plus. Nouvelle lecture en cours."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="Impossible de vérifier si vos contacts WhatsApp figurent toujours dans votre graphe de personnes. Nouvelle lecture, plutôt que de supposer qu'ils y sont."

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="Lecture de votre historique de discussions IA – vos conversations restent sur ce Mac"
MSG_HYDRATE_AICONV_DONE="%s conversations IA enregistrées dans votre wiki"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="Le lecteur de conversations IA n'est pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="Aucun historique de discussions IA à lire. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="Les discussions IA sont toujours en cours de chargement en arrière-plan. Votre wiki se remplit au fur et à mesure et vous montre où en est le chargement."
MSG_HYDRATE_AICONV_HEARTBEAT="  Lecture de votre historique de discussions IA toujours en cours (%ss écoulées). Un historique volumineux peut prendre plusieurs minutes."


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="Importation de votre historique de navigation – vos visites restent sur ce Mac"
MSG_HYDRATE_BROWSING_DONE="%s pages d'historique de navigation importées"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="%s pages signalées comme sensibles ont été ignorées (banque, santé, etc.)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="Aucun historique de navigation à importer. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="Le lecteur d'historique de navigation n'est pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."

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
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="Votre historique de navigation est déjà importé (%s pages). Rien à réimporter."
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="Aucun historique de navigation exporté à importer n'a été trouvé. Vous pourrez relancer plus tard depuis les Réglages."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="Votre historique de navigation a déjà été importé, mais votre index de recherche ne le contient plus. Nouvelle importation en cours."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="Impossible de vérifier si votre historique de navigation figure toujours dans votre index de recherche. Nouvelle importation, plutôt que de supposer qu'il y est."
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="Votre historique de navigation n'a pas atteint votre index de recherche, donc votre page Navigation sera vide. Relancez depuis les Réglages ou ouvrez Doctor."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="L'historique de navigation est toujours en cours de chargement en arrière-plan. Votre wiki se remplit au fur et à mesure et vous montre où en est le chargement."

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="Chargement de vos préférences e-mail. Ces données restent sur ce Mac et le chargement peut prendre quelques minutes."
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="%s préférences chargées depuis votre historique d'e-mails"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="Aucun fichier de préférences e-mail configuré. Rien à charger."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="Aucun fichier de préférences e-mail trouvé à l'emplacement %s. Rien à charger."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="Le pipeline de préférences n'est pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="Vos préférences e-mail sont encore en cours de chargement en arrière-plan. Votre wiki se remplit au fur et à mesure et vous indique où en est le chargement."
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  Chargement de vos préférences e-mail en cours (%ss écoulées). Un historique volumineux peut prendre quelques minutes."

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="Vos préférences e-mail sont déjà chargées (%s entrées). Rien à recharger."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="Vos préférences e-mail ont déjà été chargées, mais votre index de recherche ne les contient plus. Nouveau chargement en cours."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="Impossible de vérifier si vos préférences e-mail figurent toujours dans votre index de recherche. Nouveau chargement plutôt que de supposer qu’elles y sont."

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
MSG_HYDRATE_PREFERENCES_DONE="%s préférences importées"
MSG_HYDRATE_PREFERENCES_ENRICHED="%s d’entre elles enrichies avec des données de référence publiques"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="%s préférences importées, mais aucune n’a été classée dans Cuisine, Musique ou Professionnel. Vos pages wiki Cuisine et Musique seront vides."
MSG_WARN_PREFS_HEADLINE_HINT="Cela signifie généralement qu’aucun export de musique ou de cuisine (Spotify, Apple Music, Uber Eats, Google Takeout) n’était présent, ou que les données n’ont pas été catégorisées. Ajoutez ces exports et relancez depuis les Réglages, puis reconstruisez le wiki."
MSG_WARN_PREFS_UNCATEGORISED="%s préférences sur %s (%s%%) n’ont pas de catégorie et n’apparaîtront sur aucune page thématique. Vérifiez le format de l’export source."

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="Configuration de l’enrichissement des préférences"
MSG_CM019_SETUP_DONE="Enrichissement des préférences prêt"
MSG_CM019_SETUP_FAILED="La configuration de l’enrichissement des préférences n’a pas abouti. Vos pages de préférences se rempliront une fois le problème résolu ; le reste d’Ostler n’est pas affecté."
MSG_CM019_SETUP_SKIPPED="Le pipeline d’enrichissement des préférences n’est pas inclus ; étape ignorée pour le moment."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="Lecture de votre historique iMessage – vos messages restent sur ce Mac"
MSG_HYDRATE_IMESSAGE_DONE="%s personnes trouvées dans votre historique iMessage"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="Aucun historique iMessage à lire. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="Le lecteur iMessage n’est pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage est encore en cours de chargement en arrière-plan. Votre wiki se remplit au fur et à mesure et vous indique où en est le chargement."
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  Lecture de votre historique iMessage en cours (%ss écoulées). Un historique de messages volumineux peut prendre plusieurs minutes."

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="Vos contacts iMessage figurent déjà dans votre graphe de personnes (%s identifiants). Rien à relire."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="Vos contacts iMessage ont déjà été lus, mais votre graphe de personnes ne les contient plus. Nouvelle lecture en cours."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="Impossible de vérifier si vos contacts iMessage figurent toujours dans votre graphe de personnes. Nouvelle lecture plutôt que de supposer qu’ils y sont."

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="Lecture de vos notes Apple Notes - elles restent sur ce Mac"
MSG_HYDRATE_APPLE_NOTES_DONE="%s notes ajoutées à votre base de connaissances"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="Aucune note Apple Notes à lire. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="Vos notes Apple Notes sont déjà dans votre base de connaissances. Étape ignorée."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="Apple Notes est désactivé pour la recherche de connaissances. Vous pouvez l’activer dans les Réglages."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="L’outil d’import des connaissances n’est pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="Apple Notes est encore en cours de chargement en arrière-plan. Votre base de connaissances se remplit au fur et à mesure et vous indique où en est le chargement."
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  Lecture de vos notes Apple Notes en cours (%ss écoulées). Une grande bibliothèque de notes peut prendre quelques minutes."

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="Vos notes Apple Notes sont déjà dans votre base de connaissances (%s entrées). Rien à relire."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="Vos notes Apple Notes ont déjà été ajoutées, mais votre base de connaissances ne les contient plus. Nouvel ajout en cours."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="Impossible de vérifier si vos notes Apple Notes figurent toujours dans votre base de connaissances. Nouvel ajout plutôt que de supposer qu’elles y sont."

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="Lecture de vos Rappels – ils restent sur ce Mac"
MSG_HYDRATE_REMINDERS_DONE="%s rappels ajoutés à votre base de connaissances"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="Aucun rappel à lire. Vous pourrez relancer plus tard depuis les Réglages."
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="Vos Rappels sont déjà dans votre base de connaissances. Étape ignorée."
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="Les Rappels sont désactivés pour la recherche de connaissances. Vous pouvez les activer dans les Réglages."
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="L’outil d’import des connaissances n’est pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="Les Rappels sont encore en cours de chargement en arrière-plan. Votre base de connaissances se remplit au fur et à mesure et vous montre où en est le chargement."
MSG_HYDRATE_REMINDERS_HEARTBEAT="  Lecture de vos Rappels en cours (%s s écoulées). Une longue liste de rappels peut prendre quelques minutes."

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="Vos Rappels sont déjà dans votre base de connaissances (%s éléments). Rien à relire."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="Vos Rappels ont déjà été ajoutés, mais votre base de connaissances ne les contient plus. Nouvel ajout en cours."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="Impossible de vérifier si vos Rappels figurent toujours dans votre base de connaissances. Nouvel ajout plutôt que de supposer qu’ils y sont."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="Indexation de vos contacts pour la recherche"
MSG_HYDRATE_PEOPLE_DONE="%s personnes indexées pour la recherche"
MSG_HYDRATE_PEOPLE_PARTIAL="%s personnes sur %s indexées pour la recherche jusqu'ici. Les autres n'apparaissent pas encore dans la recherche ; Ostler réessaiera automatiquement."
MSG_HYDRATE_PEOPLE_FAILED="Vos contacts n'ont pas pu être indexés pour la recherche cette fois (la base de données de graphe n'a pas répondu). Ostler réessaiera automatiquement. Détails : %s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="Aucune personne à indexer pour l'instant. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="L'indexeur de personnes n'est pas encore prêt. Vous pourrez relancer plus tard depuis les Réglages."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="Vos contacts sont encore en cours d'indexation en arrière-plan. La recherche se remplit au fur et à mesure et le wiki vous montre où en est l'indexation."

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="Vos contacts sont déjà indexés pour la recherche (%s personnes). Rien à réindexer."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="Vos contacts ont déjà été indexés, mais votre index de recherche ne les contient plus. Nouvelle indexation en cours."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="Impossible de vérifier si vos contacts figurent toujours dans votre index de recherche. Nouvelle indexation plutôt que de supposer qu'ils y sont."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="Trois demandes d'accès aux dossiers vont apparaître"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="La fenêtre des outils en ligne de commande est apparue devant cette fenêtre – cliquez sur Installer, puis revenez ici (ou patientez quelques secondes, nous ramènerons cette fenêtre au premier plan). Les outils se téléchargent en arrière-plan pendant que vous répondez aux questions ci-dessous ; rien n'est bloqué."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="Autorisation requise : automatisation d'iMessage"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostler va maintenant demander à macOS l'autorisation de communiquer avec Messages. macOS affichera une fenêtre indiquant « OstlerInstaller souhaite contrôler Messages » – cliquez sur Autoriser pour que l'assistant puisse envoyer et recevoir des iMessages en votre nom. Sans cette autorisation, les messages iMessage ne partiront jamais, sans aucun avertissement. Cette autorisation est accordée une seule fois ; vous pourrez la modifier plus tard dans Réglages Système > Confidentialité et sécurité > Automatisation."

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
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="Notez-la ou imprimez-la maintenant. C'est le seul moyen de retrouver l'accès si vous perdez votre phrase secrète ET que votre trousseau devient inaccessible. Ostler ne peut pas la récupérer pour vous – la clé ne quitte jamais ce Mac et n'est stockée sur aucun serveur."
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="Je l'ai enregistrée en lieu sûr"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="Copier dans le presse-papiers"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="Enregistrer en PDF..."
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
MSG_INFO_PAIR_IPHONE_TITLE="Associer votre iPhone"
MSG_INFO_PAIR_IPHONE_HELP="Ouvrez l'app Ostler sur votre iPhone et scannez ce QR code pour la lier à ce Hub. Vous pouvez aussi l'associer plus tard depuis le menu Réglages du Hub."
MSG_INFO_PAIR_IPHONE_FETCHING="Génération du code d'association..."
MSG_INFO_PAIR_REFRESH="Actualiser le code"
MSG_ERR_PAIR_FETCH_FAILED="Impossible de joindre la passerelle Ostler pour l'instant. Elle est peut-être encore en cours de démarrage – cliquez sur Actualiser pour réessayer."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agent n'est pas inclus dans l'installateur. Les résumés quotidiens et le LaunchAgent de maintien de connexion WhatsApp ne se chargeront pas."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Les scripts de recompilation du wiki ne sont pas inclus dans l'installateur. Le wiki ne se mettra pas à jour automatiquement."

# F3 - legal package missing
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="legal package not bundled with installer. Article 9 / WhatsApp / voice consent gates will raise ModuleNotFoundError until re-installed."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s installé dans %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s déjà installé, laissé en place"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Architecture de processeur non prise en charge pour la CLI Google Workspace ; les fonctions Gmail / Google Agenda sont dégradées."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl n'est pas disponible ; l'installation de la CLI Google Workspace est ignorée. Les fonctions Gmail / Google Agenda sont dégradées."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="Impossible de télécharger la CLI Google Workspace depuis %s"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="Somme SHA256 de la CLI Google Workspace non conforme (attendue : %s, obtenue : %s). Installation de ce binaire interrompue."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="Impossible d'extraire l'archive de la CLI Google Workspace."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="La CLI Google Workspace est installée dans %s, mais le test --version a échoué."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="Passerelle de calendrier iCloud / CalDAV installée dans %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="La passerelle de calendrier iCloud / CalDAV située dans %s n'est pas exécutable. Le calendrier ne renverra aucun événement."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh n'est pas inclus dans l'installateur. La nouvelle tentative d'enregistrement de l'appareil au prochain accès au réseau est désactivée."

MSG_WARN_EMBED_DIMS_UNREADABLE="Impossible de lire la dimension des embeddings depuis le test d'état. La mémoire est configurée pour 768 dimensions ; si le rappel se comporte de façon étrange, vérifiez le modèle d'embedding."
MSG_FAIL_EMBED_DIMS="Le modèle d'embedding a renvoyé des vecteurs de %s dimensions, alors qu'Ostler est configuré pour %s. La mémoire enregistrerait des vecteurs qu'elle ne pourrait jamais faire correspondre. Vérifiez le modèle d'embedding, puis relancez."

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
MSG_PROGRESS_REBOOT_SELFHEAL="Configuration de l'autoréparation au redémarrage"
MSG_INFO_AUTOLOGIN_EXPLAIN="Ostler est un Hub toujours actif : après une coupure de courant ou un redémarrage, il doit repartir sans personne devant le clavier. Cela ne fonctionne que si ce Mac ouvre lui-même la session, et macOS ne peut le faire que si le mot de passe de session de %s est stocké sur ce Mac.

Le stocker affaiblit la sécurité de ce Mac. Le mot de passe est brouillé et non chiffré : toute personne pouvant utiliser un compte administrateur ici, ou pouvant retirer le disque et le lire ailleurs, peut le décoder et retrouver votre mot de passe. Vous verrez exactement où il est stocké avant de saisir quoi que ce soit.

Si vous refusez, rien n'est stocké et rien d'autre ne change. Après une coupure de courant, vous ouvrez votre session comme d'habitude, et les services d'Ostler démarrent avec votre session. Vous pourrez modifier ce choix plus tard dans Réglages Système > Utilisateurs et groupes > Ouverture de session automatique."
MSG_PROMPT_AUTOLOGIN_CONSENT="Store your login password on this Mac so it can sign itself in after a restart? [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="Ostler écrit ce mot de passe dans un fichier de ce Mac, /etc/kcpassword. Il y est brouillé selon un schéma fixe, identique sur tous les Mac et documenté publiquement : ce n'est donc pas du chiffrement et l'opération peut être inversée. Toute personne pouvant utiliser un compte administrateur sur ce Mac, ou pouvant retirer le disque et le lire ailleurs, peut retrouver à partir de ce fichier le mot de passe de session de %s.

FileVault l'empêcherait, car le disque est totalement illisible sans le mot de passe de démarrage. Pour la même raison, FileVault empêche aussi l'ouverture de session automatique, ce qui explique pourquoi Ostler ne propose cette option que lorsque FileVault est désactivé.

Ce que l'installateur contrôle : il n'affiche pas le mot de passe pendant la saisie et ne l'écrit pas dans le journal d'installation. Le fichier brouillé est la seule copie créée par l'installateur.

Laissez ce champ vide pour ignorer l'ouverture de session automatique."
MSG_PROMPT_AUTOLOGIN_PASSWORD="Mot de passe de session de %s"
MSG_OK_AUTOLOGIN_CONFIGURED="L'ouverture de session automatique est activée pour %s, et ce mot de passe de session est désormais stocké sur ce Mac dans /etc/kcpassword, sous forme brouillée. Après un redémarrage, ce Mac ouvre lui-même la session et les services d'Ostler démarrent avec cette session. Pour annuler, désactivez l'ouverture de session automatique dans Réglages Système > Utilisateurs et groupes."
MSG_INFO_AUTOLOGIN_ALREADY="L'ouverture de session automatique est déjà configurée pour %s : ce Mac a donc déjà ce mot de passe de session stocké dans /etc/kcpassword. Les deux restent tels quels. Pour annuler, désactivez l'ouverture de session automatique dans Réglages Système > Utilisateurs et groupes."
MSG_INFO_AUTOLOGIN_DECLINED="L'ouverture de session automatique n'a pas été activée et aucun mot de passe n'a été stocké. Après un redémarrage ou une coupure de courant, ouvrez votre session comme d'habitude : les services d'Ostler démarrent avec votre session."
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="Configuration de l'ouverture de session automatique ignorée : il est impossible de demander un mot de passe de session ici, et rien n'a été stocké. Vous pourrez activer l'ouverture de session automatique plus tard dans Réglages Système > Utilisateurs et groupes si vous souhaitez que ce Mac redémarre sans intervention. Cela stocke votre mot de passe de session sur le Mac sous une forme brouillée et réversible : mieux vaut donc vous renseigner avant de le faire."
MSG_WARN_AUTOLOGIN_NO_PASSWORD="Aucun mot de passe n'a été saisi : l'ouverture de session automatique n'a donc pas été activée et rien n'a été stocké. Si vous la souhaitez plus tard, activez l'ouverture de session automatique dans Réglages Système > Utilisateurs et groupes."
MSG_WARN_AUTOLOGIN_FAILED="Impossible d'activer l'ouverture de session automatique (%s). Aucune nouvelle tentative n'aura lieu. Si /etc/kcpassword existe sur ce Mac, il contient ce mot de passe de session sous forme brouillée même si la fonction est désactivée ; vous pouvez le supprimer depuis le Terminal avec : sudo rm /etc/kcpassword. Pour réessayer, activez l'ouverture de session automatique dans Réglages Système > Utilisateurs et groupes."
MSG_WARN_AUTOLOGIN_FILEVAULT="FileVault est activé : ce Mac demande donc un mot de passe à l'écran de démarrage pour déverrouiller le disque avant que quiconque puisse ouvrir une session. L'ouverture de session automatique ne peut pas y répondre : après une coupure de courant, ce Mac reste donc sur l'écran de déverrouillage FileVault jusqu'à ce que quelqu'un saisisse le mot de passe. L'ouverture de session automatique n'a pas été activée et aucun mot de passe n'a été stocké. C'est la plus sûre des deux configurations : la reprise sans intervention après un redémarrage est impossible tant que FileVault est activé, mais en contrepartie le disque reste illisible pour quiconque n'a pas ce mot de passe."

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
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="Ostler n'a pas pu ouvrir Réglages Système pour vous. Ouvrez Réglages Système vous-même, puis allez dans Confidentialité et sécurité > Accès complet au disque."
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="Ostler exécute votre wiki et votre recherche dans des conteneurs ; il installe et gère donc un moteur de conteneurs (Colima) sur ce Mac. Si ce moteur est supprimé ou reconfiguré, votre wiki et votre recherche cesseront de fonctionner – Ostler vous le signalera et essaiera de le redémarrer."
MSG_INFO_ENGINE_ALREADY_PRESENT="Un moteur de conteneurs est déjà installé sur ce Mac. Ostler l'utilisera au lieu d'installer le sien, et ne le gérera ni ne le modifiera."

# OS003 #233: model weight pins (install.sh OSTLER_MODEL_PINS).
MSG_OK_MODEL_DIGEST_VERIFIED="%s verified against its pinned digest (%s)"
MSG_FAIL_MODEL_DIGEST_MISMATCH="The installed %s is not the model this installer ships: found %s, expected %s (%s). The download source may have changed, so the install has stopped before using it. Contact support with this message."
MSG_FAIL_MODEL_UNPINNED="%s has no pinned digest in this installer, so it cannot be verified and will not be used. This is an installer defect. Contact support with this message."
MSG_FAIL_MODEL_DIGEST_UNREADABLE="Could not verify the downloaded %s against its pinned digest (%s). The model will not be used unverified. Re-run the installer; if this repeats, contact support with this message."
