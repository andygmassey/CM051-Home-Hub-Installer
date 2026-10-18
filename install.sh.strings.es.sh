#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to es by l10n/ostler_l10n.py.
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

MSG_STEP_CHECKING_PREREQUISITES="Comprobando requisitos previos"
MSG_STEP_RUNNING_HEALTH_CHECK="Ejecutando la comprobación de estado"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="Conecta tu iPhone y tu Watch"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="Configuración (unas preguntas rápidas y después continúa por sí solo)"
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
MSG_STEP_SETUP_COMPLETE_WRAP_UP="Preguntas terminadas. Ostler ahora se instala en segundo plano, entre unos 45 minutos y unas horas. Todavía habrá tres cosas que requerirán tu atención: si macOS te pide instalar las herramientas de desarrollo, haz clic en Instalar; cerca del final hay un minuto de configuración (activar Acceso total al disco); y al final del todo, después de la comprobación de estado, inicias sesión en Tailscale y permites que el asistente use Recordatorios. Entre una y otra puedes dejarlo funcionando."
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="Preguntas terminadas. Ostler ahora se instala en segundo plano, entre unos 45 minutos y unas horas. Todavía habrá tres cosas que requerirán tu atención: si macOS te pide instalar las herramientas de desarrollo, haz clic en Instalar; cerca del final hay un minuto de configuración (activar Acceso total al disco); y al final del todo permites que el asistente use Recordatorios. Entre una y otra puedes dejarlo funcionando."

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="y vuelve a ejecutar: ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="Reiniciando el asistente para que pueda usar el Acceso total al disco y leer tu historial de Mensajes. Un reinicio es lo que hace que un permiso recién concedido surta efecto; si aún no lo has concedido, el panel Doctor seguirá guiándote."
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="Tu asistente está en funcionamiento y tiene Acceso total al disco, así que puede leer los archivos que necesita."
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="Tu asistente está en funcionamiento, pero todavía no tiene Acceso total al disco. Hasta que lo actives, Ostler no puede mantener al día Mensajes, Mail, Calendario, Recordatorios, Notas, Fotos, Safari, Contactos ni WhatsApp, y tampoco puede leer tu carpeta Documentos. Lo que ya haya leído se conserva. El panel Doctor te guiará para activarlo."
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="Tu asistente está en funcionamiento. No hemos podido comprobar si tiene Acceso total al disco en este Mac, así que esto no confirma ni una cosa ni la otra. El panel Doctor te lo indicará en cuanto pueda comprobarlo."
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="Cuentas de Apple Mail visibles: %s (informativo)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mail todavía no parece tener mensajes locales. Doctor mostrará un aviso de seguimiento si no llega correo en 24 horas."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mail tiene mensajes en caché. La ingesta los recogerá en el próximo ciclo horario."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="Apple Mail está seleccionado, pero todavía no hay mensajes locales que leer en este Mac. Abre Apple Mail y añade una cuenta (Ajustes del Sistema > Cuentas de Internet, y marca Mail), y deja que termine una primera sincronización."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="Cuando haya llegado correo, vuelve a ejecutar: ostler-fda. Ostler lo recogerá automáticamente; no hace falta nada más."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="Gatekeeper verificará la notarización de Apple en el primer inicio."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="disponible, el instalador omitirá este paso automáticamente."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="Los probadores beta con acceso pueden definir PWG_PIPELINE_REPO=<url> y volver a ejecutar."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="Los probadores beta con acceso pueden definir PWG_KNOWLEDGE_REPO=<url> y volver a ejecutar."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="Extensiones del navegador omitidas (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  Clonado en %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture solo funciona con Apple Silicon. Se omite la instalación en este equipo."
MSG_INFO_CM042_LOGS_AT="Registros de RemoteCapture: %s/ostler-remotecapture.log (y .err)"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="En una instalación anterior, Ostler RemoteCapture se iniciaba al iniciar sesión. Se ha detenido y no volverá a iniciarse."
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="Ostler RemoteCapture no se instaló: elegiste mantener desactivada la transcripción de voz. Actívala en Ajustes y vuelve a ejecutar el instalador si cambias de opinión."
MSG_INFO_CM042_TCC_PRE_PROMPT="En el primer inicio, Ostler RemoteCapture pedirá a macOS permiso de Grabación de pantalla y de Micrófono. Concede ambos para que las llamadas y reuniones puedan transcribirse localmente. No aparece ningún indicador morado en la barra de menús: la captura de audio es silenciosa por diseño."
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
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="Ostler guarda tu wiki personal y las transcripciones de tus conversaciones en Documentos/Ostler, en este Mac. Son tuyas y permanecen en este equipo. Para escribirlas, Ostler necesita acceso a tu carpeta Documentos, así que macOS puede pedirlo durante la configuración y de nuevo más tarde hoy, cuando Ostler organice tu wiki por primera vez. La solicitud puede aparecer como procedente de python3.11, el ayudante incluido que Ostler usa para escribir tus archivos. Haz clic en Permitir cuando aparezca. Si no la ves o la rechazas, puedes activarlo en cualquier momento en Ajustes del Sistema, en Privacidad y seguridad, después en Archivos y carpetas, y a partir de entonces se escribirán tu wiki y las transcripciones de tus conversaciones."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  Motor de memoria de conversaciones instalado en venv."
MSG_INFO_HUB_APP_VERIFYING="Verificando Ostler.app en %s"
MSG_INFO_HUB_APP_STAGING="Copiando Ostler.app a /Applications desde %s"
MSG_INFO_HUB_APP_DRAG_HINT="Abre el DMG del instalador, arrastra Ostler.app y OstlerInstaller.app al acceso directo de Aplicaciones y vuelve a ejecutar el instalador."
MSG_OK_HUB_APP_PRESENT="Ostler.app ya está presente en %s; firma verificada."
MSG_OK_HUB_APP_STAGED="Ostler.app instalada en %s"
MSG_WARN_HUB_APP_NOT_FOUND="No se encontró Ostler.app en /Applications y no hay ninguna copia incluida disponible."
MSG_WARN_HUB_APP_VERIFY_FAILED="Falló la verificación de la firma o la notarización de Ostler.app. Se deja el paquete en su sitio para que el soporte pueda inspeccionarlo."
MSG_OK_UNINSTALLER_APP_STAGED="Ostler Uninstaller.app instalada en %s"
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="No se pudo colocar Ostler Uninstaller.app en /Applications. Aún puedes desinstalar ejecutando: ~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="Clonando el agente de Doctor..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="Clonando los scripts de ingesta de correo..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Clonando los scripts de energía del Hub..."
MSG_INFO_CLONING_IMPORT_PIPELINE="Clonando el flujo de importación..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="Clonando los scripts de recompilación de la wiki..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima está instalado pero no se está ejecutando. Se iniciará."
MSG_INFO_COLIMA_START_ATTEMPT="Iniciando Colima (intento %s de %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="No se pudieron exportar los contactos. Puedes importarlos manualmente más tarde."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="No se pudo leer la tarjeta de contacto. No pasa nada: te lo preguntaremos."
MSG_INFO_CONTACT_CARD_WILL_ASK="En un momento te preguntaremos tu nombre y tu país. Tus contactos se leen más tarde con el Acceso total al disco que concedas, y nada sale de este Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  Creando el entorno virtual de Python en %s..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="Creando el árbol de contenido para el usuario en %s/"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="Ejecución diaria. Ejecución manual: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="Hub de escritorio (sin batería) detectado: desactivando el reposo en todo el sistema"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker no está instalado. Se instalarán Colima, Docker CLI y el complemento docker-compose (ligero, sin necesidad de Docker Desktop)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="Los archivos del agente de Doctor no están incluidos en el instalador."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="Los scripts de ingesta de correo no están incluidos en el instalador."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="Faltan los scripts de ingesta de correo en el paquete del instalador. Vuelve a descargar la .app desde ostler.ai/install e inténtalo de nuevo."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Los scripts de ingesta de correo no están incluidos y se usó --allow-plaintext; se omitirá la instalación del LaunchAgent. Los correos futuros no se procesarán."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  Ya existe una copia en %s; actualizando..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Extrayendo el mbox de Gmail del zip de Takeout (puede tardar un minuto con archivos grandes)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="El módulo de extracción de FDA no está incluido. Se omite la extracción instantánea de datos."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Activando tus primeros 30 días de Ostler Pro..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Ostler Pro cuesta 9,99 USD al mes tras la prueba. Suscríbete en la app Ostler de tu iPhone."
MSG_INFO_FOUND_GMAIL_MBOX_MB="Mbox de Gmail encontrado en %s (%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Zip de Google Takeout encontrado en %s (%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="Acceso total al disco detectado – extracción completa disponible."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="Se detectaron exportaciones del RGPD, pero el flujo de importación aún no está disponible."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="La importación de exportaciones del RGPD estará disponible cuando se lance el flujo."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="Se van a analizar Descargas, Escritorio y Documentos en busca de exportaciones de IA (Google Takeout, descargas de Meta, LinkedIn, etc.) que hayas guardado. macOS mostrará tres solicitudes de acceso a carpetas: permite cada una. Tarda unos 5-10 segundos en total. Durante el análisis no se mueve ni se copia nada; solo comprobamos lo que hay."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS puede pedirte permiso para leer tu Calendario. Permítelo para que Ostler pueda crear la parte de reuniones y eventos de tu grafo de conocimiento. (Los datos del Calendario se quedan en este equipo.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS está pidiendo permiso para Descargas. Haz clic en Aceptar."
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS está pidiendo permiso para Escritorio. Haz clic en Aceptar."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS está pidiendo permiso para Documentos. Haz clic en Aceptar."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="Acceso total al disco concedido. Preparando la siguiente solicitud de macOS (automatización de Mensajes)..."
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="No hubo respuesta a la solicitud de permiso de Mensajes, así que seguimos adelante. Tus mensajes no se leerán hasta que lo permitas. Ostler volverá a preguntar, o puedes concederlo en Ajustes del Sistema > Privacidad y seguridad > Automatización."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="Se necesitan las Herramientas de línea de comandos de Xcode. macOS te pedirá permiso para instalarlas: busca un pequeño cuadro de diálogo gris (si no lo ves, pulsa Cmd+Tab o mira en el Dock). Haz clic en Instalar. Las herramientas se descargan en segundo plano mientras respondes a las preguntas siguientes."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  Aún se están configurando las Herramientas de línea de comandos (%ss). Si un pequeño cuadro de diálogo gris de macOS te pide instalar las herramientas de desarrollo, haz clic en Instalar: este paso está esperando a que lo hagas. (Pulsa Cmd+Tab o mira en el Dock si no lo ves.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="Esperando a que terminen de instalarse las Herramientas de línea de comandos (casi listo)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="Ciclo cada hora. La primera ejecución descarga los últimos 5 años de correo."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="Desactivando el LaunchAgent del puente de iMessage heredado (un solo equipo, v1.0)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Hub solo con corriente (no se detectó batería); se omite el LaunchAgent de hub-power."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Los scripts de energía del Hub no están incluidos en el instalador."
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="Hub portátil. Sigue funcionando con la tapa abierta y conectado a la corriente."
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="Si cierras la tapa, o lo dejas inactivo con batería, macOS lo suspende."
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="Mientras está suspendido, el asistente no recibe nada."
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="Los mensajes que lleguen en ese tiempo no se recuperan al reactivarse."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="La tapa puede permanecer cerrada en el modo de pantalla cerrada."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="Para eso hace falta corriente, además de una pantalla, un teclado y un ratón externos."
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="Docker y Ollama se pausan con batería y se reanudan con corriente."
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="Tras un reinicio, FileVault mantiene este Mac en la pantalla de inicio de sesión."
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="Ostler se inicia cuando inicias sesión."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="API del asistente incluida en el instalador; se usa el código fuente incorporado."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="El código fuente de la API del asistente no está incluido; la app Ostler de tu iPhone tendrá acceso limitado."
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="Instalando las dependencias de ejecución de la API del asistente (phonenumbers, httpx)..."
# NEEDS REVIEW: People/Timeline appear to be app section names; confirm they match the localised app UI.
MSG_WARN_ICAL_SERVER_DEPS_FAILED="No se pudieron instalar las dependencias de ejecución de la API del asistente (phonenumbers/httpx); Personas y Cronología podrían quedar vacías hasta la próxima instalación."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Cuando aparezca la ventana de Tailscale, inicia sesión con Apple / Google / Microsoft."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="Abriendo Tailscale para que puedas iniciar sesión..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="Entendido: a partir de aquí, Ostler se instala casi solo. Hacia el final te necesitará unos dos minutos: activar el Acceso total al disco e iniciar sesión en Tailscale para que tu iPhone y tu Watch puedan conectarse a este Mac desde cualquier lugar. Abriremos tu navegador para iniciar sesión."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale omitido: la app Ostler de tu iPhone solo funcionará con tu Wi-Fi de casa. Puedes configurarlo más tarde en Ajustes."
MSG_INFO_TAILSCALE_STILL_WAITING="Aún esperando el inicio de sesión en Tailscale (%ss transcurridos): completa el inicio de sesión en la ventana de Tailscale."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="Acceso total al disco concedido; reiniciando el asistente para que aplique el nuevo permiso."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="Abriendo Ajustes del Sistema y el Finder para guiarte mientras concedes Acceso total al disco al asistente..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="Registrando el asistente de Ostler en macOS para que aparezca como interruptor en Acceso total al disco..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="El Acceso total al disco sigue pendiente. El panel Doctor mantendrá visible la tarjeta hasta que se conceda el acceso."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant ya tiene Acceso total al disco; no hace falta hacer nada más."
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="Esta parte te necesita durante unos dos minutos: activa ahora el Acceso total al disco para el asistente y luego inicia sesión en Tailscale en el siguiente paso. Después, puedes dejar que Ostler termine por su cuenta."
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="Esta parte te necesita durante un minuto aproximadamente: activa el Acceso total al disco para el asistente. Después, puedes dejar que Ostler termine por su cuenta."
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="\"%s\" ya aparece en Acceso total al disco, así que solo tienes que activarlo. No hace falta arrastrar nada desde el Finder."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Comprobando si el asistente de Ostler tiene Acceso total al disco..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="El asistente puede leer el historial de Mensajes; el canal de iMessage funcionará."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="El asistente de Ostler aún no tiene Acceso total al disco. Lo necesita para mantener actualizadas las apps propias de tu Mac, uses Mensajes o no. Si lo omites ahora, el panel de Doctor te guiará por Ajustes del Sistema."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="El LaunchAgent del asistente no se cargó; se omite la comprobación de Acceso total al disco para iMessage."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="La interfaz de importación de Evernote en Doctor mostrará un aviso de «servicio no disponible»"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="El proceso de importación no está incluido en el instalador."
MSG_INFO_INSTALLING_CM042="Instalando Ostler RemoteCapture v%s (transcripción de llamadas y reuniones)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="Instalando el motor de memoria de conversaciones desde %s..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  Instalando el motor de memoria de conversaciones en el venv..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="Instalando Colima + Docker CLI..."
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="Instalando GNU coreutils (para limitar con timeout los pasos largos)..."
MSG_INFO_INSTALLING_HOMEBREW="Instalando Homebrew..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="Instalando el servicio Knowledge desde %s..."
MSG_INFO_INSTALLING_OLLAMA="Instalando Ollama..."
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  Instalando las dependencias del módulo de extracción de datos..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Instalando el lector de Apple Mail en un venv dedicado..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  Instalando ostler-knowledge en el venv..."
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  Instalando la dependencia de almacenamiento cifrado en el venv de memoria de conversaciones..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Instalando la extensión de Safari en /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="Instalando las dependencias de seguridad de Python..."
MSG_INFO_INSTALLING_SQLCIPHER="Instalando SQLCipher..."
MSG_INFO_INSTALLING_TAILSCALE="Instalando Tailscale..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="La compatibilidad con Intel no está en la hoja de ruta; envía una solicitud si la necesitas."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Servicio Knowledge incluido en el instalador; se usa el código fuente integrado."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Servicio Knowledge no instalado: PWG_KNOWLEDGE_REPO está vacío."
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="Este Mac es un portátil. Como Hub, sigue funcionando mientras la tapa esté abierta y el Mac esté conectado a la corriente."
MSG_INFO_LAPTOP_HUB_SLEEP_COST="Si cierras la tapa, o lo dejas inactivo con batería, macOS lo suspende. El asistente no recibe nada mientras está suspendido, y los mensajes que lleguen en ese tiempo no se recuperan al reactivarse."
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="La tapa puede permanecer cerrada en modo de pantalla cerrada, que requiere corriente además de una pantalla, un teclado y un ratón externos."
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="Un Hub en Mac mini o Mac Studio se mantiene activo por sí solo, por si prefieres instalarlo en uno de ellos."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="más tarde en Ajustes del Sistema > Privacidad y seguridad > Acceso total al disco"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  al iniciar para verificar la entrega por cron y la configuración de imessage-tcc)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="Licencia: %s es Apache 2.0. Texto completo: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licencia: %s – consulta los términos originales antes de usarlo comercialmente."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="almacén local – Google nunca sabe que Ostler existe."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="Registros: %s/email-ingest.log (y .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="Registros: %s/ostler-assistant.log (y .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="Registros: %s/wiki-recompile.log (y .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="Hubs en MacBook: define PWG_HUB_POWER_REPO=<url> y vuelve a ejecutar."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="Hub en MacBook detectado: se desactiva la suspensión solo con corriente (hub-power gestiona los cambios a batería)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Las instalaciones en Mac mini / Studio no se ven afectadas (siempre con corriente)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Los datos del Mac (iMessage, Safari, etc.) se extrajeron más arriba."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="Reinicio manual: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="Ejecución manual: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="Omitiendo la instalación de com.ostler.meeting-brief-sender (función de la v1.0.1; los endpoints aún no están disponibles)."
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="Omitiendo el repaso de higiene de memoria (no incluido en este instalador); no se reducirá automáticamente la prioridad de nada hasta que lo esté."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="mensaje cuando el indicador de función se active más adelante."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="¿Necesitas ayuda? Escribe a support@ostler.ai. Intentamos responder en un plazo de 2 días laborables."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="No hay canales configurados. Ejecútalo más tarde: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="Se eliminó un config.toml heredado obsoleto en la raíz del espacio de trabajo; la configuración activa del asistente está en assistant-config/."
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="No hay fuentes FDA disponibles ahora mismo. Puedes conceder Acceso total al disco"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="No se encontraron exportaciones del RGPD en Descargas, Escritorio ni Documentos."
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="No se pudo leer %s para buscar exportaciones de datos. macOS está bloqueando el acceso a esa carpeta."
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="Concede el acceso en Ajustes del Sistema > Privacidad y seguridad > Archivos y carpetas (o Acceso total al disco) y vuelve a ejecutarlo, o indica a Ostler tu carpeta de exportaciones manualmente más abajo."
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="No se pudieron analizar una o más carpetas en busca de exportaciones de datos porque macOS bloqueó el acceso. Concede el acceso y vuelve a ejecutarlo, o indícame tu carpeta de exportaciones manualmente."
MSG_INFO_OPENING_CHROME_WEB_STORE="Abriendo Chrome Web Store: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="El binario ostler-assistant no está instalado; se omite la comprobación de doctor"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: aplazado (puede que el daemon aún esté"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="Usando el binario ostler-assistant incluido en este DMG (ruta de instalación sin conexión)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge instalado en el venv."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler mostrará una pantalla de consentimiento adicional antes de instalar"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  Cambia el repositorio de origen del motor de memoria de conversaciones mediante la variable de entorno documentada en ./install.sh --help."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  Cambia el repositorio de origen con PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  Cambia el repositorio de origen con PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  Cambia el repositorio de origen con PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  Cambia el repositorio de origen con PWG_PIPELINE_REPO=<url> ./install.sh"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Guardando registros de consentimiento y región..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="Vigilante de batería de la fase 3 activado (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="Leyendo tu libreta de direcciones (las bibliotecas grandes pueden tardar un par de minutos – no cierres el instalador)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="Anulación de política: edita ~/.ostler/power.conf (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="Comprobando el permiso de Automatización de iMessage (solo lectura)..."
MSG_INFO_PULLING_GRAPH_DB_IMAGES="Descargando las bases de datos del grafo de conocimiento (solo la primera vez). Puede tardar un minuto en una instalación nueva..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="Descargando nomic-embed-text (274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="Descargando %s (%s)... puede tardar unos minutos."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="Atributo xattr de cuarentena eliminado. Una vez que la compilación con Developer ID esté"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Leyendo Safari, iMessage, Notas, Calendario, Fotos, Recordatorios, Mail..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="Leyendo tu tarjeta de contacto para rellenar tus datos..."
MSG_INFO_REGION_EU_EEA_SOURCE="Región: UE/EEE (%s, origen: %s)"
MSG_INFO_REGION_SOURCE="Región: %s (origen: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="Región: Reino Unido (origen: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="Región: Estados Unidos (origen: %s)"
MSG_INFO_REPO_URL="URL del repositorio: %s"
MSG_INFO_REPO_URL_2="URL del repositorio: %s"
MSG_INFO_REPO_URL_3="URL del repositorio: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="Ahora elige la frase de contraseña que desbloqueará tu Hub. La escribirás cada vez que inicies la interfaz del Hub."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="Frase de contraseña de recuperación omitida. (Obsoleto: la v1.0 siempre requiere una frase de contraseña.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="Reutilizando la instalación existente del agente Doctor en %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="Reutilizando la instalación existente de email-ingest en %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="Reutilizando la instalación existente de hub-power en %s"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="Reutilizando la clave existente de la extensión del navegador en %s"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="La extensión de Ostler para Chrome no forma parte de esta versión."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="Conversaciones de correo: no configuradas, porque no aceptaste que Ostler lea los mensajes de otras personas."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="Conversaciones de correo: no configuradas, porque Apple Mail no está configurado en este Mac."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="Conversaciones de Mensajes: no configuradas, porque no aceptaste que Ostler lea los mensajes de otras personas."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="Conversaciones de Mensajes: no configuradas, porque no hay historial de Mensajes en este Mac."
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  Transcribe una llamada con Ostler y esto se activará solo."
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="Conversaciones habladas: aún no configuradas, porque no hay transcripciones que leer."
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="Conversaciones habladas: desactivadas, porque la carpeta Transcripts se eliminó después de instalar Ostler."
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  Vuelve a crear %s para reactivarlas. Ostler no la recreará por ti."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="Conversaciones de WhatsApp: no configuradas, porque no aceptaste que Ostler lea los mensajes de otras personas."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="Conversaciones de WhatsApp: no configuradas, porque WhatsApp está desactivado."
MSG_INFO_CHROME_HISTORY_STILL_READ="  Ostler sigue leyendo tu historial de Chrome, así que se recuerdan las páginas que has visitado. La captura en directo mientras navegas por ahora solo funciona en Safari."
MSG_INFO_REUSING_EXISTING_JWT_SECRET="Reutilizando el JWT_SECRET existente en %s"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="Reutilizando el token de servicio PWG existente en %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="Reutilizando la instalación existente de wiki-recompile en %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="El paquete de la extensión de Safari no está presente en esta compilación del instalador (se omite)"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="Queda un paso manual: abre Safari, elige Safari > Ajustes > Extensiones y marca Ostler para activarla."
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="Buscando exportaciones de datos del RGPD..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="Define PWG_DOCTOR_REPO=<url> y vuelve a ejecutar para instalar."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="Define PWG_HUB_POWER_REPO=<HR015 url> y vuelve a ejecutar para instalar."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="Modelo de conversación omitido. Descárgalo más tarde: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Iniciando Colima (entorno de ejecución ligero de Docker)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Iniciando Docker Desktop..."
MSG_INFO_STARTING_OLLAMA="Iniciando Ollama..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="Eliminando un elemento de inicio de Colima obsoleto dejado por una versión anterior..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="Eliminando la fórmula antigua de Ollama (sin llama-server); cambiando a la app de Ollama..."
MSG_INFO_VERIFYING_EMBEDDINGS="Verificando que el motor de incrustaciones devuelve vectores..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="No se pudo iniciar Ollama automáticamente. Cárgalo con: launchctl bootstrap gui/\$(id -u) %s – y vuelve a ejecutar el instalador."
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="Ollama no se inició mediante el servicio en segundo plano; iniciándolo directamente para esta ejecución..."
# NEEDS REVIEW: Fragment of a sentence split across lines. The proposed text changed 'after first' to 'primero'. Word order depends on the adjacent lines, so a human should che
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  arranque; ejecuta \`ostler-assistant doctor\` tras el primer"
MSG_INFO_SYMLINKING="  Creando enlace simbólico de %s -> %s"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(Ajustes del Sistema > Cuentas de Internet). Ostler lee de Mail de"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(El resto de Ostler funciona sin el panel de Doctor.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="Es lo esperado por ahora. La importación de datos del RGPD estará disponible en una próxima actualización."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="Suele tardar entre 15 y 45 minutos, y puede tardar más si tienes mucho historial o un Mac más lento. Es normal: está trabajando, no se ha detenido, así que puedes dejarlo en marcha..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="Esto lee las bases de datos de macOS directamente: no hace falta exportar nada."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="Consejo: para incluir tu Gmail, añádelo primero a Mail en el Mac"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="Para instalarlo más tarde, cuando tengas acceso:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="Activando la sincronización de iCloud para %s (silenciosa, solo la primera vez)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (Artículo 9 del RGPD del Reino Unido: obligatorio para datos de categoría especial)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="Actualizando el pipeline existente..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="El árbol visible para el usuario ya se anunció (marca presente); se omite"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="Descargando el motor de búsqueda web local (unos 3,5 GB). En una primera instalación es el paso más largo y puede tardar hasta una hora. No hay barra de progreso, así que un silencio prolongado es normal y no significa que la instalación se haya detenido."
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane no responde (opcional; consulta las advertencias de la fase 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="Consúltalas cuando quieras con: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="El reconocimiento de voz seguirá desactivado. Puedes activarlo más tarde en Ajustes."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="Esperando a que inicies sesión en Tailscale (hasta 3 minutos)..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="No se configuró el acceso remoto con Tailscale. La app Ostler de tu iPhone funcionará con tu Wi-Fi de casa; puedes configurar el acceso remoto más tarde en Ajustes."
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="Este Mac ya está conectado a tu red de Tailscale, así que no hay nada que configurar. Se mantiene tu conexión actual."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="Acceso remoto: se mantiene la respuesta que diste la última vez, que fue omitirlo. Tu app de iOS funcionará con tu Wi-Fi de casa y podrás configurar el acceso remoto más tarde en Ajustes."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="Acceso remoto: se mantiene la respuesta que diste la última vez, que fue configurarlo."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="Conector de WhatsApp desactivado. Puedes activarlo más tarde en Ajustes."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="Mantenimiento de conexión de WhatsApp programado a las 08:50 y 17:50 (etiqueta com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="Se omite la puesta al día inicial de la wiki: la tarea de recompilación de la wiki no está instalada. La reconstrucción diaria de la wiki, si está instalada, sigue ejecutándose."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Los scripts de recompilación de la wiki no vienen incluidos en el instalador."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="La wiki no se actualizará automáticamente; puedes volver a ejecutar la primera compilación manualmente:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="Marcador de postura escrito: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="Tus exportaciones están a salvo. Impórtalas más tarde con: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="Los datos de tu Mac (iMessage, Safari, etc.) ya se extrajeron más arriba."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="Puedes añadirlo más tarde para una incorporación instantánea desde Safari, iMessage, etc."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="Modelo de IA: %s (%s) – elegido para tus %s GB de RAM"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="Cabe"
MSG_MODELFIT_PILL_SLOW="Puede ir lento"
MSG_MODELFIT_PILL_NOFIT="No cabe"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="Ajustando el modelo del asistente a tu Mac (%s, %s GB de RAM, contexto del asistente de %s tokens):"
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- Recomendado"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="Modelo de IA: %s (%s) – el que mejor se ajusta a tus %s GB de RAM con la ventana de contexto que necesita el asistente"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="Todas las fuentes seleccionadas (el reconocimiento facial sigue desactivado)"
MSG_OK_ALREADY_AVAILABLE="%s ya está disponible"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon detectado"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="Apps abiertas para activar la sincronización de iCloud"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="Las bases de datos de las apps ya existen (se omite la apertura previa)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="Configuración del asistente guardada en %s (modo 0600)"
MSG_OK_BACKED_UP_CONTACTS="Se hizo una copia de seguridad de %s contactos en %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s instalado en %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="LaunchAgent de Ostler RemoteCapture cargado (etiqueta %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima y la CLI de Docker instalados"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="Supervisor del entorno de contenedores instalado (comprueba cada 5 minutos y reinicia el entorno si se detiene)"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="No se pudo programar el supervisor del entorno de contenedores. Ostler se instalará igualmente, pero si el entorno se detiene más adelante, nada lo reiniciará por sí solo: tu wiki seguiría inactivo hasta que vuelvas a ejecutar el instalador."
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="Faltan los archivos del supervisor del entorno de contenedores en este instalador, así que no se programó. Ostler se instalará igualmente, pero la recuperación automática del entorno no está activa."
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
# NEEDS REVIEW: Section names People/Timeline/Governor must match the app's localised section labels; confirm.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="No se pudo iniciar el panel Doctor de Ostler, por lo que http://localhost:8089 no responderá. Las páginas de la app que leen de él (Personas, Cronología, Governor, estado de los canales) aparecerán como no disponibles hasta que esté en marcha. Vuelve a ejecutar el instalador para intentarlo de nuevo."
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="No se pudo programar el ayudante que mantiene el Mac activo. Ostler sigue funcionando, pero este Mac puede suspenderse durante tareas largas en segundo plano, que se reanudarán al reactivarse en lugar de terminar durante la noche."
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="No se pudo programar el ayudante de actualización en segundo plano, así que los mensajes, correos y eventos de calendario nuevos no se recogerán por sí solos. Vuelve a ejecutar el instalador para restaurarlo."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="%s no se ha configurado: Ostler no tiene constancia de tu respuesta a la pregunta que lo regula, así que no ha supuesto ninguna."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  Vuelve a ejecutar Ostler y elige responder de nuevo a las preguntas para activarlo. (registro de consentimiento: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="No se pudo programar el resumen diario, así que no recibirás el resumen de la mañana. Todo lo demás funciona; vuelve a ejecutar el instalador para restaurarlo."
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="No se pudo programar la limpieza de memoria, así que los datos obsoletos o reemplazados no perderán peso automáticamente. Todo lo demás funciona; vuelve a ejecutar el instalador para restaurarla."
MSG_WARN_EXPORT_SCAN_NOT_LOADED="No se pudo iniciar el vigilante de Descargas, así que los archivos que dejes en Descargas no se recogerán automáticamente. Lo ya importado no se ve afectado y aún puedes añadir archivos desde la app. Vuelve a ejecutar el instalador para restaurarlo."
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="No se pudo programar el ayudante de reintento del registro del dispositivo. Si tu iPhone se registró durante la configuración, no cambia nada; si no, tendrás que volver a emparejarlo desde la app en lugar de que se complete solo."
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="El entorno de contenedores responde"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="Se eliminó un elemento de inicio de Colima obsoleto dejado por una versión anterior"
MSG_OK_CONFIG_SAVED_ENV="Configuración guardada en %s/.env"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Registros de consentimiento y región guardados en ~/.ostler/posture/"
MSG_OK_AT_REST_EXCLUDED="Excluido de Spotlight y Time Machine (comprobado): %s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s NO está excluido de Time Machine ni de Spotlight: %s. Su contenido, incluidos los secretos de Ostler, podría copiarse en tu disco de copia de seguridad. Doctor seguirá mostrando este aviso hasta que se solucione."
MSG_INFO_AT_REST_FOLDER_ABSENT="%s aún no existe, así que no hay nada que excluir de las copias de seguridad."
MSG_WARN_DB_KEY_NOT_EXCLUDED="El archivo de clave de la base de datos %s NO está excluido de Time Machine, por lo que podría copiarse en tu disco de copia de seguridad."
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="No se pudo guardar en ~/.ostler/posture/ tu elección sobre el enriquecimiento en segundo plano. Tu elección se sigue aplicando a esta instalación; simplemente no aparecerá en un informe de soporte."
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="Bases de datos cifradas. Los servicios del Hub leen la clave de un archivo protegido en tu carpeta personal, así que se inician sin pedirte nada."
MSG_OK_DB_KEY_DELIVERED="Clave de la base de datos entregada a los servicios del Hub (%s, legible solo por ti)."
MSG_WARN_DB_KEY_NOT_DELIVERED="No se pudo entregar la clave de la base de datos a los servicios del Hub. Abrirán las bases de datos sin cifrar hasta que se solucione."
MSG_INFO_DB_KEY_RECOVER_HINT="Ejecuta esto para recuperarla y entregarla: %s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="Cifrando las bases de datos que queden de una instalación anterior"
MSG_WARN_DB_MIGRATION_FAILED="No se pudieron cifrar algunas bases de datos existentes. Siguen siendo legibles en el disco."
MSG_WARN_DB_KEY_MISSING_ON_RERUN="Esta instalación no tiene archivo de clave de base de datos, así que los servicios del Hub abren las bases de datos sin cifrar."
MSG_WARN_DB_PLAINTEXT_COUNT="%s base(s) de datos de este Mac son legibles en el disco ahora mismo."
MSG_INFO_DB_MIGRATE_HINT="Después cifra lo que ya existe: %s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="Reintento diferido del registro del dispositivo instalado (se ejecuta cada hora hasta vaciar la cola)"
MSG_OK_DOCKER_RUNNING="Docker en ejecución"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker en ejecución (tardó %ss)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Agente de Doctor clonado desde %s"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Archivos del agente de Doctor incluidos en el instalador"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Dependencias de Doctor instaladas"
MSG_OK_EMAIL_CHANNEL_FOLDER="Canal de correo: %s (carpeta: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de ingesta de correo cargado (etiqueta com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de ingesta de correo incluidos en el instalador"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="Scripts de ingesta de correo clonados desde %s"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="Configurando la memoria de conversaciones de WhatsApp"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  Lector de conversaciones de WhatsApp instalado."
MSG_WARN_WHATSAPP_SOURCE_FAILED="Error al instalar el lector de conversaciones de WhatsApp; la fuente de conversaciones de WhatsApp no se ejecutará. Consulta el resultado anterior."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="No se encontró el origen del lector de conversaciones de WhatsApp; se omite la fuente de conversaciones de WhatsApp."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="No se encontró el paquete de la fuente de conversaciones de WhatsApp en este instalador; se omite. El historial de mensajes de WhatsApp (con quién hablaste y cuándo) no se ve afectado."
MSG_OK_WHATSAPP_BUNDLE_LOADED="LaunchAgent de la fuente de conversaciones de WhatsApp cargado (etiqueta com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  La primera ejecución lee las conversaciones recientes de WhatsApp que tu Mac ha sincronizado (aproximadamente el último año); se queda en tu Mac."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  Registros: %s/whatsapp-bundle.log y whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="Error al instalar el LaunchAgent de la fuente de conversaciones de WhatsApp. Consulta el resultado anterior; el resto de la instalación no se ve afectado."
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  Aún no se ha iniciado: el programa del asistente que ejecuta este agente no está en el disco. Se buscó en: %s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="Configurando la memoria de conversaciones de correo"
MSG_OK_EMAIL_SOURCE_INSTALLED="  Lector de conversaciones de correo instalado."
MSG_WARN_EMAIL_SOURCE_FAILED="Error al instalar el lector de conversaciones de correo; la fuente de conversaciones de correo no se ejecutará. Consulta el resultado anterior."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="No se encontró el origen del lector de conversaciones de correo; se omite la fuente de conversaciones de correo."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="No se encontró el paquete de la fuente de conversaciones de correo en este instalador; se omite. La ingesta de correo cada hora no se ve afectada."
MSG_OK_EMAIL_BUNDLE_LOADED="LaunchAgent de la fuente de conversaciones de correo cargado (etiqueta com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Lee tus hilos de correo recientes del almacén local de Apple Mail; todo se queda en tu Mac."
MSG_INFO_EMAIL_BUNDLE_LOGS="  Registros: %s/email-bundle.log y email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="Error al instalar el LaunchAgent de la fuente de conversaciones de correo. Consulta el resultado anterior; el resto de la instalación no se ve afectado."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="Configurando la memoria de conversaciones de reuniones y voz"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  Lector de conversaciones de reuniones y voz instalado."
MSG_WARN_SPOKEN_SOURCE_FAILED="Error al instalar el lector de conversaciones de reuniones y voz; la fuente no se ejecutará. Consulta el resultado anterior."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="No se encontró el origen del lector de conversaciones de reuniones y voz; se omite la fuente."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="No se encontró el paquete de la fuente de conversaciones de reuniones y voz en este instalador; se omite."
MSG_OK_SPOKEN_BUNDLE_LOADED="LaunchAgent de la fuente de conversaciones de reuniones y voz cargado (etiqueta com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  Transcribe tus propias reuniones y notas de voz en conversaciones en las que se puede buscar; todo se queda en tu Mac."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  Registros: %s/spoken-bundle.log y spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="Error al instalar el LaunchAgent de la fuente de conversaciones de reuniones y voz. Consulta el resultado anterior; el resto de la instalación no se ve afectado."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="Configurando la memoria de conversaciones de iMessage"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  Lector de conversaciones de iMessage instalado."
MSG_WARN_IMESSAGE_SOURCE_FAILED="Error al instalar el lector de conversaciones de iMessage; la fuente de conversaciones de iMessage no se ejecutará. Consulta el resultado anterior."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="No se encontró el origen del lector de conversaciones de iMessage; se omite el flujo de conversaciones de iMessage."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="No se encontró el paquete del flujo de conversaciones de iMessage en este instalador; se omite."
MSG_OK_IMESSAGE_BUNDLE_LOADED="LaunchAgent del flujo de conversaciones de iMessage cargado (etiqueta com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  Lee tus conversaciones recientes de iMessage del almacén de Mensajes de este Mac; todo permanece en tu Mac."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  Registros: %s/imessage-bundle.log e imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="No se pudo instalar el LaunchAgent del flujo de conversaciones de iMessage. Consulta la salida anterior; el resto de la instalación no se ve afectado."
MSG_OK_EMBEDDING_MODEL_READY="Modelo de incrustación listo"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="%s contactos exportados (se importarán automáticamente)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="Vigilante de exportaciones instalado (revisa Descargas cada 4 horas)"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  El vigilante de exportaciones aún no se ha iniciado: el programa del asistente que ejecuta no está en el disco. Se buscó en: %s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="Envío del resumen previo a reuniones instalado (consulta cada 10 minutos durante las horas de vigilia)"
MSG_OK_MEMORY_HYGIENE_INSTALLED="Limpieza de memoria programada (se ejecuta a diario para que los datos obsoletos no desplacen a los actuales)"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="Tu Mac permanecerá activo con corriente eléctrica para que Ostler siga funcionando (con batería sí entra en reposo)"
MSG_OK_EXTRACTED="Extraído en %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="Extraído de %s fuente(s). Datos guardados en %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="Nueva ejecución de FDA programada cada %s minutos (detecta sincronizaciones lentas de iCloud y termina de completar el calendario)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro activo durante 30 días. Suscríbete en la app Ostler de tu iPhone para continuar después de la prueba."
MSG_OK_FOUND="Encontrado: %s"
MSG_OK_FOUND_EXPORTS="Exportaciones encontradas en %s"
MSG_OK_FOUND_GDPR_EXPORT_S="Se encontraron %s exportación(es) del RGPD:"
MSG_OK_GB_FREE_DISK_SPACE="%s GB de espacio libre en disco"
MSG_OK_GB_RAM_DETECTED="%s GB de RAM detectados"
MSG_OK_GDPR_IMPORT_COMPLETE="Importación del RGPD completada"
MSG_OK_GIT_AVAILABLE="Git disponible"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="Instalación de Command Line Tools iniciada (se descarga en segundo plano mientras respondes las preguntas siguientes)."
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils instalado (los pasos largos ahora tienen un límite de tiempo)"
MSG_OK_HOMEBREW_INSTALLED="Homebrew instalado"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de energía del Hub cargado (etiqueta com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de energía del Hub incluidos en el instalador"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Scripts de energía del Hub clonados desde %s"
MSG_OK_ICAL_SERVER_INSTALLED="API del asistente instalada (loopback 127.0.0.1:8090, con proxy de Doctor)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="LaunchAgent del puente de iMessage cargado (etiqueta com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts del puente de iMessage incluidos en el instalador"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="Scripts del puente de iMessage clonados desde %s"
MSG_OK_IMESSAGE_CHANNEL="Canal de iMessage: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="Canal de importación incluido en el instalador"
MSG_OK_IMPORT_PIPELINE_READY="Canal de importación listo"
MSG_OK_CM048_PIPELINE_READY="Motor de memoria de conversaciones listo."
MSG_INFO_CM048_SETTINGS_WRITTEN="  Modelos de conversación configurados en %s (según tus %s GB de memoria)"
MSG_INFO_CM048_SETTINGS_KEPT="  Se conservan tus ajustes de conversación actuales (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="Servicio de conocimiento listo: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="Textos de licencia instalados en %s/ (origen: %s)"
MSG_OK_MACOS_DETECTED="macOS %s detectado"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="Abriendo Ajustes del Sistema > Cuentas de Internet para que puedas añadir una cuenta de correo. Vuelve a esta ventana cuando hayas iniciado sesión en tu primera cuenta."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="Se omite el paso de Cuentas de Internet. Puedes añadir una cuenta de correo más tarde desde Ajustes del Sistema; Doctor mostrará un aviso de seguimiento si no llega ningún correo en 24 horas."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Obteniendo todo tu historial de Apple Mail. Puede tardar un poco más si el buzón es grande."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="Se mantiene el periodo estándar de cinco años de correo. Puedes obtener más después desde Doctor."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text ya está disponible"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="Ollama instalado"
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama instalado (solo CLI – puede requerir inicio manual tras reiniciar)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama instalado (app de escritorio)"
MSG_OK_OLLAMA_RUNNING="Ollama en ejecución"
MSG_OK_EMBEDDINGS_VERIFIED="Motor de embeddings verificado (vectores de 768 dimensiones)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: 0 errores en sus propias comprobaciones de inicio"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent del asistente de Ostler cargado (etiqueta com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s preparado en %s (firmado)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s preparado en %s (sin firmar)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor en ejecución en http://localhost:8089/doctor"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  El módulo de extracción de datos se carga correctamente."
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Lector de Apple Mail instalado."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  Motor de ingesta de correo instalado."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="Comandos ostler-import, ostler-fda y ostler-uninstall instalados"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="Contraseña anotada. Cifrará tus bases de datos durante la Fase 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="Contraseña de recuperación configurada."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="Información sobre la contraseña confirmada."
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="Contraseña de la exportación de Disney+ anotada. Se usará durante la importación."
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="Se omite la exportación de Disney+: no se indicó ninguna contraseña. Nada más se ve afectado."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="Fuente de alimentación: corriente (Mac de escritorio, sin batería)"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="Fuente de alimentación: corriente (bien – la instalación puede durar de 45 minutos a varias horas, y la corriente eléctrica la mantiene estable)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="Instalación anterior detectada. Cargando configuración..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="Usando Python %s incluido (no hace falta instalarlo en el sistema)"
MSG_OK_PYTHON_INSTALLED="Python %s instalado"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="El servicio de emparejamiento funciona correctamente"
MSG_WARN_GATEWAY_NOT_RESPONDING="El servicio de emparejamiento no responde (127.0.0.1:8000) - puede que el emparejamiento con el teléfono o el navegador y el asistente de chat aún no funcionen"
MSG_OK_DOCTOR_HEALTHY="Doctor funciona correctamente"
MSG_WARN_DOCTOR_NOT_RESPONDING="Doctor no responde (127.0.0.1:8089): la app y el navegador acceden a Ostler a través de él, por lo que los datos y el emparejamiento pueden no estar disponibles"
MSG_OK_WIKI_HEALTHY="Tu wiki funciona correctamente"
MSG_OK_ICAL_SERVER_HEALTHY="La API del asistente funciona correctamente"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="La API del asistente no responde (127.0.0.1:8090): Personas, Reuniones y Cronología pueden aparecer vacías hasta que se inicie"
MSG_OK_READY="%s listo"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="Fuentes recomendadas seleccionadas"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="Clave de recuperación guardada en el Llavero (busca 'Ostler' en la app Contraseñas)"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Extensión de Safari instalada en %s"
MSG_OK_SAFARI_EXTENSION_PAIRED="Extensión de Safari emparejada con este Hub"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="La seguridad ya se configuró en una ejecución anterior."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="Módulo de seguridad instalado en venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="JWT_SECRET nuevo generado en %s"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="Token de servicio PWG generado en %s"
MSG_OK_SEEDED_EXTENSION_TOKEN="Clave de la extensión del navegador generada en %s"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="Servicios iniciados (Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  Colección de búsqueda preparada: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="Aún no se pudo preparar la colección de búsqueda %s; la importación de datos que sigue volverá a intentarlo y se detendrá, sin descartar tus datos, si aún no puede."
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="El índice de búsqueda aún no está listo; la importación de datos que sigue lo esperará, preparará las colecciones y se detendrá, sin descartar tus datos, si el almacén sigue sin estar listo."
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="Tus datos no se importaron. No se pudo preparar el almacén de búsqueda para guardarlos (falta: %s) y, de importarlos igualmente, se habrían descartado en silencio. No se perdió nada. Vuelve a ejecutar el instalador cuando el equipo esté inactivo, o define OSTLER_QDRANT_READY_WAIT_S para esperar más tiempo."
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="La importación de tus datos procesó %s registros pero no guardó ninguno; el almacén de búsqueda los rechazó todos, así que el resultado sería un grafo de conocimiento vacío presentado como completo. Se detiene el proceso en lugar de mostrártelo así. Vuelve a ejecutar el instalador cuando el equipo esté inactivo."
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="No se pudo leer el registro propio de la importación, así que no se pudo comprobar si tus datos llegaron realmente. Esto no indica que la importación haya fallado, ni que haya tenido éxito."
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="Suspensión desactivada con corriente, suspensión con batería conservada, activación por red habilitada"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="Suspensión desactivada, activación por red habilitada"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale ya está instalado"
MSG_OK_TAILSCALE_INSTALLED="Tailscale instalado"
MSG_OK_TAILSCALE_ENV_PERSISTED="IP de Tailscale guardada en .env – la app Ostler de tu iPhone la usará en el primer inicio."
MSG_OK_TAILSCALE_IP="IP de Tailscale: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Servicio en segundo plano de Tailscale iniciado (modo de espacio de usuario, sin extensión del sistema)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="No se pudo iniciar el servicio en segundo plano de Tailscale. Puedes volver a ejecutar la configuración desde Ajustes más tarde."
MSG_INFO_TAILSCALE_SIGN_IN_URL="Abriendo el navegador para iniciar sesión en Tailscale: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Puerto %s del Hub expuesto en tu tailnet"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="No se pudo exponer el puerto %s del Hub en tu tailnet; el acceso fuera de la red local puede ser limitado"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="Tu wiki ya se puede leer desde tus propios dispositivos en %s – con tu cuenta, y solo para ti."
MSG_INFO_WIKI_TAILNET_OWNER="El acceso a la wiki está restringido a tu cuenta de Tailscale (%s). Otras personas de tu tailnet reciben un error 403."
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="Tu wiki permanece solo en este Mac. Abre Ostler y elige Wiki en la barra lateral para leerla."
MSG_INFO_WIKI_TAILNET_BANNER="%s  (desde tus propios dispositivos, mediante Tailscale. Esta es la única ruta que te pide el inicio de sesión indicado arriba.)"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="en la app Ostler. Abre Ostler y elige Wiki en la barra lateral; tus páginas están ahí, con la sesión ya iniciada."
MSG_INFO_WIKI_INTERNAL_ADDRESS="Ostler obtiene esas páginas de http://localhost:8044 en este Mac. Esa dirección es interna y no hay nada en ella donde tengas que iniciar sesión."
MSG_INFO_WIKI_SIGN_IN="Tu inicio de sesión de la wiki es %s con la contraseña %s. Ostler lo introduce por ti, así que no hay nada que escribir en este Mac; solo lo necesitas a mano cuando abras la wiki desde otro de tus dispositivos mediante Tailscale."
MSG_INFO_WIKI_SIGN_IN_WITHHELD="Tu acceso al wiki es %s. La contraseña no se escribe en este registro: está en el portapapeles y en el archivo que se indica abajo. Ostler la introduce por ti, así que no tienes que escribir nada en este Mac."
MSG_INFO_WIKI_PORT_LAST_STATUS="Último estado HTTP del puerto del wiki: %s (000 significa que nadie respondió; 403 significa que respondió y rechazó la credencial)."
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="Tu contraseña también se guarda en %s, así que el portapapeles no es la única copia."
MSG_INFO_WIKI_STILL_BUILDING="Aún se está compilando. Ya hay %s páginas en el disco y la última respuesta de la dirección del wiki fue HTTP %s. Aparecerá por sí solo en la app de Ostler. No tienes que hacer nada."
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="La primera compilación todavía no ha generado páginas (consulta las advertencias de arriba). Tu wiki se abrirá en la app de Ostler cuando esté compilado, y el acceso de arriba sigue siendo tuyo."
MSG_INFO_WIKI_READINESS_NOT_MEASURED="Esta ejecución no comprobó si el wiki ya está en servicio, así que no afirma nada en ningún sentido. Tu wiki se abre en la app de Ostler de todos modos, y el acceso de arriba sigue siendo tuyo."
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="No se pudo confirmar qué cuenta de Tailscale es la propietaria de este Mac, así que el wiki NO se ha expuesto en tu tailnet. Sigue disponible en este Mac, en la app de Ostler, en Wiki."
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="No se pudo publicar el wiki en tu tailnet; sigue disponible en este Mac, en la app de Ostler, en Wiki."
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="No se pudo recargar la puerta de acceso del wiki, así que el wiki NO se ha expuesto en tu tailnet."
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="Tailscale Funnel está activado para %s. Funnel publica en internet abierto. Ostler nunca activa Funnel y tu wiki rechaza el tráfico de Funnel, así que nada de Ostler es público – pero si no querías activarlo, desactívalo en la consola de administración de Tailscale para este equipo."
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="Atribuciones de terceros instaladas (origen: %s)"
MSG_OK_USER_FACING_TREE_READY="Árbol de carpetas para el usuario listo"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="Se usará en su lugar la carpeta o etiqueta «Ostler»."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane funciona correctamente (búsqueda web local)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane en ejecución en http://localhost:3000 (se comunica con tu Ollama local)"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="El conector de WhatsApp se activará (consentimiento registrado)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="LaunchAgent de puesta al día del wiki del primer día cargado (reconstruye tu wiki cada 30 minutos durante las primeras horas y luego se detiene)"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="Aún se están fusionando contactos duplicados – las libretas de direcciones grandes pueden tardar varios minutos (%ss transcurridos)"
MSG_INFO_DEDUPE_MERGED="Contactos duplicados fusionados"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="Fusionar los contactos duplicados está tardando con una libreta de direcciones de este tamaño. Continuará en segundo plano tras la instalación – tu wiki se actualiza automáticamente cuando termine."
MSG_WARN_DEDUPE_INCOMPLETE="La pasada de deduplicación de todo el grafo no terminó correctamente (consulta %s); se continúa"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="Contactos duplicados totalmente fusionados durante la instalación; no hace falta ponerse al día en segundo plano"
MSG_OK_DEDUPE_CATCHUP_LOADED="LaunchAgent de deduplicación de contactos en segundo plano cargado (termina de fusionar duplicados tras la instalación y luego se detiene)"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="No se pudo cargar el LaunchAgent de deduplicación de contactos en segundo plano. La pasada de mantenimiento diaria seguirá fusionando los duplicados; solo tardará más en completarse."
MSG_OK_ENRICH_AGENT_LOADED="LaunchAgent de enriquecimiento en segundo plano cargado (completa los detalles de tus películas, lugares, libros y enlaces; se ejecuta por tandas durante aproximadamente el próximo día)"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="No se pudo cargar el LaunchAgent de enriquecimiento en segundo plano. Tus preferencias están guardadas y se pueden buscar; solo les faltará el detalle de referencia adicional (directores, reparto, ubicaciones) hasta que se ejecute."
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de recompilación del wiki cargado (etiqueta com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de recompilación del wiki incluidos con el instalador"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Scripts de recompilación del wiki clonados desde %s"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="Configurando tu Portada (actualización cada hora)"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="Generador de la Portada incluido con el instalador"
MSG_OK_EDITOR_FRONTPAGE_LOADED="LaunchAgent de la Portada cargado (etiqueta com.creativemachines.ostler.editor-frontpage)"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  La primera actualización se ejecuta ahora; la Portada de tu panel se completa a medida que Ostler lee tus preferencias."
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  Registros: %s/editor-frontpage.log y editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="No se encontró el generador de la Portada en este instalador; la Portada del panel no se actualizará."
MSG_WARN_EDITOR_FRONTPAGE_FAILED="Falló la instalación del LaunchAgent de la Portada. Consulta la salida de arriba; el resto de la instalación no se ve afectado."
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="Configurando la puesta al día de tu Portada"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="LaunchAgent de puesta al día de la Portada cargado (comprueba cada 5 minutos hasta que se hayan leído tus intereses y luego se detiene)"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="No se pudo cargar el LaunchAgent de puesta al día de la Portada. Tu Portada y lo que Ostler sabe de tus intereses se completarán en la próxima actualización horaria."
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="Se omite la puesta al día de la Portada: la actualización de la Portada no está instalada, así que no hay nada que volver a ejecutar."
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki en funcionamiento en http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="Tu wiki está lista para explorar. Ostler está escribiendo ahora los resúmenes de las páginas en segundo plano, así que se irán completando poco a poco. Puedes empezar a usar tu wiki de inmediato."
MSG_OK_YOUR_ASSISTANT_CALLED="Tu asistente se llama %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="Scripts del resumen de contexto personal incluidos con el instalador"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="LaunchAgent del resumen de contexto personal cargado (etiqueta com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  Registros: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="Reutilizando la instalación existente de context-refresh en %s"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="Los scripts del resumen de contexto personal no están incluidos; el asistente usará solo consultas en tiempo real (sin resumen de contexto permanente)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="No se pudo cargar el LaunchAgent del resumen de contexto personal; consulta context-refresh.err. El asistente sigue respondiendo mediante consultas en tiempo real"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="Al código fuente clonado del servicio Knowledge le falta su configuración de empaquetado, por lo que no se configuró su entorno."
MSG_WARN_BUNDLE="  Paquete: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s solo es compatible con Apple Silicon (detectado: %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="No se pudo descargar Ostler RemoteCapture v%s desde %s"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="Causas habituales: la versión aún no está publicada, no hay conexión a internet o la notarización sigue en curso. Vuelve a ejecutar el instalador cuando la versión esté disponible."
MSG_WARN_CM042_EXTRACT_FAILED="No se pudo extraer el tarball de Ostler RemoteCapture; se omite el LaunchAgent."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="No se pudo cargar el LaunchAgent de Ostler RemoteCapture. Consulta la salida anterior y ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  El enriquecimiento de conversaciones no estará disponible. El resto de Ostler se instala con normalidad; vuelve a ejecutar sin --allow-plaintext para incorporar el motor de memoria de conversaciones."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="Falló la instalación del motor de memoria de conversaciones (clonación)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  Se buscó: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  Normalmente esto significa que la app del instalador se compiló sin"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  el paquete cm048_pipeline incluido en"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Vuelve a descargar el instalador o"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  vuelve a ejecutar con --allow-plaintext para una instalación de desarrollo/CI."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="No se encontró el motor de memoria de conversaciones. El enriquecimiento de conversaciones no puede funcionar sin él."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="Se omitió la configuración del motor de memoria de conversaciones (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="Se encontró el origen del motor de memoria de conversaciones, pero falta pyproject.toml; se omite la configuración del venv."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Colima no pudo iniciarse. Probando Docker Desktop como alternativa..."
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="No se pudo instalar GNU coreutils; los pasos largos se ejecutarán sin límite de tiempo (una línea de progreso seguirá indicando que están en marcha)."
MSG_WARN_COLIMA_START_RETRY="Colima no arrancó correctamente (el socket de Docker no estaba listo). Reintentando en %ss..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="Causas habituales: la etiqueta v%s aún no está publicada, no hay conexión a internet,"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  stderr de consent_cli (primeros 400 caracteres):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  No se creó el script de consola en %s; es posible que a pyproject.toml le falte la entrada [project.scripts]."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="Se continúa porque se indicó --allow-plaintext."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="Se continúa con la instalación. Vuelve a ejecutar \`ostler-fda\` tras diagnosticar el error anterior."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="Se continúa sin el autorrelleno de la tarjeta de contacto – Ostler te preguntará en su lugar."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  Las conversaciones enviadas a iMessage fallarán silenciosamente hasta que"
# NEEDS REVIEW: Source pane is Energy (Energía), not Battery; the exact Spanish macOS label of the sleep option should be verified against Apple's localisation.
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="No se pudieron cambiar los ajustes de reposo. Activa «Impedir el reposo automático cuando esté conectado a la corriente» en Ajustes del Sistema > Energía."
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="No se pudo cambiar la configuración de reposo. Activa «Evitar el reposo automático» en Ajustes del Sistema > Energía."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="No se pudo descargar ostler-assistant v%s desde %s"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="No se pudo extraer el mbox de Gmail del zip de Takeout – se omite."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="No se pudo extraer el tarball de ostler-assistant; se omite el LaunchAgent."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="No se encontró la CLI de Tailscale. Puedes configurarla manualmente más tarde."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="No se pudo instalar el paquete legal/ de textos de consentimiento; se continúa"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="No se pudo instalar el directorio LICENSES/ (no es grave)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="No se pudo instalar ostler_security en el venv del Hub."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="No se pudo instalar THIRD_PARTY_NOTICES.md (no es grave)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="No se pudo obtener el agente de Doctor (fallaron tanto el incluido como la clonación)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="No se encontraron los archivos de Ostler Doctor. Son necesarios para el emparejamiento con iOS (Ostler.app incrusta :8089/pair-ios mediante iframe)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  Se buscó en: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  Esto suele significar que el instalador .app se compiló sin"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  el código fuente de doctor/agent/ incluido en"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Vuelve a descargar el instalador o"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  vuelve a ejecutarlo con --allow-plaintext para una instalación de desarrollo/CI."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Instalación de Doctor cancelada: es necesario para el emparejamiento con iOS. Vuelve a descargar el instalador o usa --allow-plaintext para una instalación de desarrollo/CI."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="No se pudieron obtener los scripts de ingesta de correo (fallaron tanto los incluidos como la clonación)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="No se pudieron obtener los scripts de hub-power (fallaron tanto los incluidos como la clonación)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="No se pudieron obtener los scripts de wiki-recompile (fallaron tanto los incluidos como la clonación)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="No se pudo abrir automáticamente la URL de Chrome Web Store: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="No se pudo guardar region.json (se continúa; Doctor lo mostrará)"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="No se pudo registrar que la clave de recuperación se entregó. El resumen de esta ejecución sigue siendo correcto, pero una ejecución posterior podría no saberlo y avisar de nuevo: es la forma más segura de que esto falle."
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="No se pudo guardar en el Llavero. Anótala, por favor."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="No se pudo iniciar Ollama automáticamente."
MSG_FAIL_OLLAMA_PORT_IN_USE="Otro programa ya está usando el puerto 11434, que Ostler necesita para su IA local. Ostler no pudo iniciar su propia copia, así que la instalación se detuvo aquí en lugar de quedar a medias.

  Qué ocupa el puerto: %s
  El error exacto está en: %s

Suele ser una copia de Ollama que ya tenías o una que quedó abierta de una instalación anterior de Ostler. Ciérrala (o reinicia este Mac) y vuelve a ejecutar el instalador."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="No se pudo actualizar el pipeline (¿sin conexión?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="No se pudo escribir pipeline_signals.json. El diagnóstico de Mail vacío de Doctor usará valores seguros por defecto hasta la próxima instalación o ciclo."
MSG_WARN_CURL_SAID="Curl indicó:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="Directorio no encontrado: %s – se omite la importación."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker no se inició en %s segundos."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker está instalado pero no se está ejecutando. Habrá que iniciarlo."
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="El comando de Docker está en este Mac, pero no hay nada en ejecución detrás. En macOS, el comando de Docker es solo un cliente: necesita un motor como Colima o Docker Desktop para ejecutar algo. El instalador configurará uno."
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="Diagnóstico del entorno de contenedores - cliente de docker: %s | colima: %s | Docker Desktop: %s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="El contenedor del wiki se inició, pero nada respondió en http://localhost:8044 en 60 segundos. Considera que el wiki NO está en ejecución: el código de salida del comando de inicio no prueba que la página cargue."
MSG_WARN_WIKI_NOT_RESPONDING="Tu wiki no responde (127.0.0.1:8044). Se ejecuta en un contenedor, así que esto suele significar que el entorno de contenedores se detuvo. Abre Ostler Doctor en http://localhost:8089/doctor para ver el motivo."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama a mitad de la instalación y bloquean las comprobaciones de disponibilidad."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  indicadores tempranos (canales aún conectándose + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="No se pudo instalar el LaunchAgent de importación de correo. Consulta la salida anterior."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="No se pudo instalar el LaunchAgent del puente de iMessage. Las respuestas de iMessage del usuario del asistente no funcionarán hasta que vuelvas a ejecutar el instalador o ejecutes INSTALL_SNIPPET.sh manualmente."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Los scripts del puente de iMessage no están incluidos y se pasó --allow-plaintext; se omitirá la instalación del LaunchAgent. Las respuestas de iMessage del usuario del asistente no funcionarán."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="El cifrado no funcionará."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="El cifrado no funcionará, y"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="asegúrate de que la etiqueta fijada de PWG_KNOWLEDGE_REPO lo incluya."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  permiso de Eventos para Messages.app)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="El extractor de FDA terminó con un código distinto de cero (%s). Últimas 20 líneas de la salida:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="El módulo de extracción de FDA no está incluido en este instalador."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="Se esperaba en: Contents/Resources/ostler_fda/ (dentro de la .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="Causa más probable: una regresión de compilación omitió la copia del proveedor. Vuelve a descargar la .app desde ostler.ai/install."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="El módulo de extracción de FDA no está incluido. Se continúa porque se pasó --allow-plaintext – se omitirá la extracción instantánea de datos."
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="El módulo de extracción de datos está en el disco, pero sus dependencias no se instalaron, por lo que no se puede cargar:"
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="Se continúa porque se pasó --allow-plaintext – la actualización programada de datos fallará en cada ejecución."
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault NO está activado."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="No se pudo activar el primer mes gratis en este momento; la instalación continuará. Abre la app Ostler en tu iPhone una vez emparejado para resolverlo."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="No se ha concedido Acceso total al disco a Terminal."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="Se detectaron %s GB de RAM. Tendrás el asistente compacto (gemma4:e2b): fiable, preciso, en menos de un segundo con preguntas cortas, con llamadas a herramientas y un sincero «No lo sé» cuando no lo sabe. Para respuestas más completas a preguntas más largas, con 24 GB o más se activa el asistente estándar (qwen3.5:9b). Puedes cambiar de Mac más adelante reinstalando."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="La importación de GDPR tuvo errores. Puedes volver a ejecutarla con:"
MSG_WARN_GRAPH_DB_PULL_RETRY="La descarga de la base de datos no terminó (intento %s de %s). Reintentando en %ss..."
MSG_WARN_GRAPH_DB_UP_RETRY="Las bases de datos del grafo de conocimiento no se iniciaron (intento %s de %s). Reintentando..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="La importación de GDPR forma parte de la instalación estándar del producto. Sin ella, no se puede importar tu grafo social (LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google Calendar)."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="La importación de GDPR no estará disponible en esta instancia hasta que se reinstale el flujo de importación."
MSG_WARN_GIT_SAID="Git indicó:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  Falló la comprobación de estado: ostler-knowledge --version no produjo ninguna salida."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  Falló la comprobación de estado: no se pudo cargar el motor de memoria de conversaciones (pwg-convo o la importación de su flujo no terminó correctamente)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="El instalador de Homebrew terminó con el código %s. A continuación, las últimas 30 líneas de %s:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Registro de instalación de Homebrew (final) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="La instalación de Doctor con pip terminó con el código %s. A continuación, las últimas 30 líneas de %s:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Registro de instalación de Doctor con pip (final) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="La instalación del flujo con pip terminó con el código %s. A continuación, las últimas 30 líneas de %s:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- Registro de instalación del flujo con pip (final) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="No se pudo instalar el LaunchAgent de energía del Hub. Consulta la salida anterior."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="No se encontraron los scripts de energía del Hub en la ruta esperada del paquete."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  Parece que a la .app del instalador le falta vendor/hub_power/"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  en Contents/Resources/hub-power/. No se instalará la limitación según la batería; el resto de la instalación continuará."
MSG_WARN_ICAL_SERVER_FAILED="No se pudo iniciar la API del asistente; la app Ostler en tu iPhone tendrá acceso limitado hasta la próxima ejecución de la instalación."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - Falló la descarga de la imagen (red, espacio en disco o tiempo de espera del registro)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="No se pudo escribir la señal de FDA de iMessage en pipeline_signals.json. Es posible que el panel Doctor no muestre automáticamente la tarjeta de Acceso total al disco."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="El host IMAP está vacío. Inténtalo de nuevo."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="Permiso de automatización de iMessage: no concedido (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="Permiso de automatización de iMessage: la comprobación no fue concluyente."
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="No se puede leer el historial de iMessage (chat.db): el daemon de Ostler aún no tiene Acceso total al disco. La lectura del historial de iMessage seguirá desactivada hasta que lo concedas en Ajustes del Sistema > Privacidad y seguridad > Acceso total al disco."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="Abriendo Ajustes del Sistema > Privacidad y seguridad > Automatización. Marca la fila de Mensajes para OstlerInstaller (o Terminal) para activar el envío por iMessage."
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="No es una dirección de correo completa, se ignora: %s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="Introduce al menos una dirección de correo completa (por ejemplo, you@example.com)."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage necesita al menos un contacto permitido. Inténtalo de nuevo o"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="El pipeline de importación no está disponible (repositorio privado, solo para probadores beta)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="El pipeline de importación no está incluido en el instalador. Fallo grave omitido."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="El pipeline de importación no está incluido en el instalador. Esta es la ruta de instalación del producto; el paquete de Python contact_syncer debería venir dentro del paquete .app."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX significa que el asistente leerá todos los correos que recibas."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Espacio en disco insuficiente para el volumen de salida de la wiki"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Se ha detectado un Mac con Intel: el rendimiento será limitado. Se recomienda Apple Silicon."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s es un host de proveedor en la nube."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="JWT_SECRET en %s está en la lista de bloqueo; se regenera para que los servicios del grafo de conocimiento se puedan importar"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="JWT_SECRET en %s es demasiado corto (%s < %s caracteres); se regenera"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="Repositorio de conocimiento clonado, pero falta pyproject.toml; se omite la configuración del venv."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="Falló la instalación del servicio de conocimiento (clonación)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="Licencia: %s se distribuye bajo los Términos de uso de Gemma de Google, no bajo Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="Las instalaciones en MacBook necesitan esto para gestionar la batería y la suspensión."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="El permiso de Contactos de macOS fue rechazado o aún no se ha concedido."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS NO lo solicitará desde un script: debes concederlo manualmente."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Las instalaciones en Mac Mini no se ven afectadas; los usuarios de MacBook deberían reintentarlo."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="Los datos de Mail aún se pueden importar manualmente:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  Reintento manual: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  Reintento manual una vez resuelta la causa:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="No se seleccionó Apple Mail ni IMAP personalizado: se usará Apple Mail por defecto."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="No hay clave de acceso definida; las bases de datos no se cifrarán."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="Una instalación anterior generó tu clave de recuperación pero no terminó, así que nunca se te mostró. No se puede recuperar: no se guarda en ningún sitio, tampoco aquí."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="Tu frase de contraseña sigue funcionando y hoy no hay nada bloqueado. Pero ahora mismo no hay forma de volver a entrar si la olvidas."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="Contacta con el soporte para configurar la seguridad desde cero; así se te mostrará una nueva clave de recuperación para que la guardes."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="Las frases de contraseña no coinciden. Inténtalo de nuevo."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="Falló la configuración de la frase de contraseña. Salida:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="Entrada vacía. Se omite la frase de contraseña."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="La frase de contraseña debe tener al menos 12 caracteres. Inténtalo de nuevo."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="Se necesita una frase de contraseña para cifrar tus datos."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="Ese no es un número internacional. Empieza con + seguido del código de país y el resto del número, p. ej. +447700900123. Inténtalo de nuevo."
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama no responde"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="Error en ollama pull %s (intento %s/3). Reintentando en %s s..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="Solo hay %s GB libres. Recomendamos al menos 35 GB (imágenes de Docker + modelo de IA + datos)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="Con batería, el LaunchAgent de energía del Hub (paso 3.14) puede pausarse"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="o vuelve a ejecutar el instalador y elige otro canal."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="o se está adelantando al flujo de publicación de la Fase B. Vuelve a ejecutar el instalador cuando"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor notificó %s error(es)."

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="Ostler ha terminado, pero se produjeron %s error(es) durante la instalación."
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  Encontrarás todos los detalles en ~/.ostler/logs/install.log. Ostler se iniciará de todos modos; abre Doctor para ver qué necesita atención."
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="Ostler ha terminado, pero %s paso(s) de la instalación no se completaron correctamente: %s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="Ostler ha terminado sin errores durante la instalación."

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant se extrajo, pero falló la comprobación de --version."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Falló la instalación del LaunchAgent del asistente de Ostler tras 3 intentos. Consulta la salida de diagnóstico de arriba y de abajo."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Falló el intento %s de instalar el LaunchAgent del asistente de Ostler; reintentando."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="stderr completo del daemon en: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="Último fragmento de stderr:"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s solo es compatible con Apple Silicon (detectado: %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  No se pudo instalar la dependencia de almacenamiento cifrado en el venv de memoria de conversaciones; el enriquecimiento de conversaciones no se ejecutará."
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  No se encontró el origen de la dependencia de almacenamiento cifrado en SCRIPT_DIR; el motor de memoria de conversaciones no puede cargarse y el enriquecimiento de conversaciones no se ejecutará."
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - la imagen ostler-wiki-compiler aún no se puede descargar (registro no configurado)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph no responde"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph aún no está en buen estado en esta fase (revisa los registros de arriba)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="Las contraseñas no coinciden (o estaban vacías). Inténtalo de nuevo."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="La instalación principal suele tardar entre 45 minutos y unas horas (descargas de Docker y Ollama + primera configuración), más si tu conexión es lenta o tu Mac tiene años de historial. Es normal que haya largos periodos sin actividad visible: se está descargando y configurando en segundo plano, no se ha bloqueado."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  Falló pip install; el motor de memoria de conversaciones no estará disponible."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  Falló pip install; email-ingest recurrirá al python del sistema (también puede fallar en la ejecución)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  Falló pip install; ostler-knowledge no estará disponible."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  Falló pip install; el motor de ingesta de correo no está disponible. El LaunchAgent que se ejecuta cada hora seguirá generando archivos mbox, pero no podrá ingerirlos en el grafo hasta que se repare."
MSG_WARN_CM021_SOURCE_NOT_FOUND="No se encontró el origen del motor de ingesta de correo en el paquete de la app; la tarea en segundo plano de cada hora guardará los archivos de correo sin ingerirlos."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="No se encontró el origen de ostler_fda en el paquete de la app; el LaunchAgent de email-ingest recurrirá al python del sistema en la ejecución."
MSG_WARN_PIP_SAID="pip indicó:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="Conecta el Mac a la corriente para la instalación completa."
MSG_WARN_PORT_1_ALREADY_USE_PID="El puerto %s ya está en uso por %s (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - El puerto 3000 ya está en uso por otro servicio"
MSG_WARN_POWER_SOURCE="Fuente de alimentación: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="Falló la instalación de sqlcipher3."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="Falló la instalación de sqlcipher3. Las bases de datos no se cifrarán."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="No se encontró Python 3. Instalando Python 3.12..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s es demasiado antiguo (se necesita 3.10 o superior). Instalando Python 3.12..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant no responde"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         Lee https://ai.google.dev/gemma/terms antes de un uso comercial."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="Lee la versión pública en https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis no responde"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="se publique la versión, o prepara el binario manualmente:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="Reintentando – escribe un host autoalojado, o pulsa Ctrl-C y vuelve a abrir el instalador eligiendo Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="vuelve a ejecutar el instalador con iMessage desmarcado para omitirlo."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="EJECUTANDO CON --allow-plaintext: cifrado desactivado. NO APTO PARA PRODUCCIÓN."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  Ejecuta \`%s doctor\` tras el primer arranque"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="Ejecuta 'tailscale ip --4' una vez iniciada la sesión y luego añade la dirección a la app de iOS."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="No se pudo copiar la extensión de Safari; puedes instalarla manualmente más tarde"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="La extensión de Safari se instaló, pero no había ningún token de extensión disponible para vincularla; la captura de navegación seguirá desactivada hasta que vuelvas a ejecutar el instalador"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="No se pudo vincular la extensión de Safari con este Hub; la captura de navegación seguirá desactivada hasta que vuelvas a ejecutar el instalador"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="No se encontró el módulo de seguridad. Se omitirá la configuración de la llave de acceso."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  Se buscó en: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  Esto suele significar que el instalador .app se creó sin"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  el paquete ostler_security incluido en"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Vuelve a descargar el instalador o"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  vuelve a ejecutarlo con --allow-plaintext para una instalación de desarrollo o CI."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="Falló la configuración de seguridad. Se continuará sin cifrado de la base de datos."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="Falló la configuración de seguridad. Salida:"
MSG_WARN_SEE_STDERR_FRAGMENT="  Consulta %s para ver el fragmento de stderr."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="Se omite la instalación del binario. El config.toml creado por el asistente se mantiene."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Se omite la instalación del LaunchAgent de Doctor."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="Se omite la instalación del LaunchAgent de ingesta de correo."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="Se omite la instalación del LaunchAgent. Las instalaciones en Mac mini no se ven afectadas."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="Se omite la instalación del LaunchAgent. Prueba: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="Se omite la instalación del LaunchAgent de recompilación de la wiki."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="Algunos puertos están en uso. Es posible que los contenedores de Docker no se inicien."
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="El puerto %s ya está en uso por %s (PID %s), que pertenece a esta cuenta. Ciérralo y vuelve a ejecutar el instalador."
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="El puerto %s ya está en uso por un programa de OTRA cuenta de usuario de este Mac. Ostler no puede compartirlo, y arrancar de todos modos podría mezclar los datos de ambas cuentas. Cierra la sesión de la otra cuenta, o instala Ostler en un Mac donde sea la única cuenta que use este puerto."
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="Ostler no puede iniciar sus bases de datos porque los puertos que necesita ya están ocupados."
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="Detén lo que esté usando los puertos indicados arriba y vuelve a ejecutar el instalador."
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="No se pudo comprobar si el puerto %s está libre. Esto no significa que el puerto esté libre."
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="No se pudieron realizar una o más comprobaciones de puertos, por lo que no se puede descartar un conflicto con otro programa."
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="No se pudo realizar la comprobación de puertos más fiable en este Mac, así que las comprobaciones siguientes son menos exhaustivas de lo habitual."
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="Ostler no pudo confirmar que esos puertos estén libres y no iniciará sus bases de datos en un puerto que no ha comprobado. Ponte en contacto con el soporte y adjunta tu registro de instalación."
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="No se pudo eliminar un elemento de inicio obsoleto de Colima. Es posible que tu wiki no se cargue tras un reinicio; ponte en contacto con el soporte."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="Detén los servicios en conflicto o cambia los puertos en docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscale no inició sesión en 3 minutos. Puedes volver a esto más tarde desde Ajustes."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="La IP de Tailscale se escribió en .env, pero una lectura posterior no pudo verla. Es posible que la app Ostler de tu iPhone no la detecte. Si ocurre, vuelve a ejecutar install.sh --repair."
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="No se pudo guardar tu respuesta sobre el acceso remoto, así que la próxima reinstalación te lo volverá a preguntar. Todo lo demás sigue igual."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="La instalación de Tailscale falló. Puedes instalarlo más tarde desde tailscale.com"
MSG_WARN_TAILSCALE_STATE_UNREADABLE="Este Mac tiene ajustes de Tailscale que no se pudieron leer, así que no sabemos si sigue conectado a tu red. Elige una opción abajo. Si ya está conectado, configurarlo de nuevo no causa ningún problema."
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="los servicios desplegados se niegan a iniciarse sin ellos."
# NEEDS REVIEW: Sentence fragment; if the preceding line ends with 'until', Spanish needs subjunctive ('se resuelva esto'). Check the full sentence.
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  esto está resuelto. Consulta el banner de próximos pasos para la solución."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  para inspeccionar. cron-delivery / imessage-tcc son comunes"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  Prueba: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  Prueba: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="Opción '%s' no reconocida; se usará iMessage + correo electrónico por defecto."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="Opción no reconocida. Se usará la recomendada."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  La actualización falló; se continúa con la copia existente."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="Usa Apple Mail (recomendado arriba) para esa cuenta. Ostler nunca guarda contraseñas de la nube."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="Se usará INBOX. El asistente leerá todos los correos entrantes."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="El contenedor de Vane se inició, pero http://localhost:3000 no respondió en 60 s."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane (búsqueda web local) no pudo iniciarse. Causas habituales:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  La búsqueda web es opcional; el resto de Ostler funciona sin ella."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="Recomendamos encarecidamente usar una etiqueta o carpeta dedicada."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp necesita un número de teléfono para enviar el resumen. Inténtalo de nuevo,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="La wiki se compiló, pero el contenedor wiki-site no pudo iniciarse."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="La primera compilación de la wiki falló. Causas habituales:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="No se pudo cargar el LaunchAgent de puesta al día de la wiki del primer día. La reconstrucción diaria de la wiki sigue funcionando; tu wiki se actualizará al día siguiente en lugar de en la próxima hora."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Falló la instalación del LaunchAgent de recompilación de la wiki. Consulta la salida anterior."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="La wiki no se actualizará automáticamente; la reconstrucción manual sigue disponible:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="La configuración del asistente de instalación se conserva; el binario sigue preparado. Reintento manual:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="Tu asistente necesita un nombre. Elige una de las sugerencias anteriores o escribe el tuyo."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="Puedes volver a concederlo en Ajustes del Sistema > Privacidad y seguridad > Contactos."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="Puedes ejecutar la configuración de seguridad más tarde: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="Puede que tengas que instalarlo manualmente: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  real:     %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="El paquete de Ostler RemoteCapture no estaba en %s tras la extracción. Es posible que el archivo de la versión esté dañado."
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="No se pudo crear o acceder a %s, así que Ostler RemoteCapture no tiene dónde instalarse. Es un problema de permisos de carpeta, no de la descarga."
MSG_ERR_CM042_RENAME_FAILED="Ostler RemoteCapture se descargó y descomprimió correctamente, pero no se pudo mover a %s. La app descomprimida se ha dejado en /Applications. No es un problema de firma."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify informó:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  No se preparará un paquete que no coincide con la suma de comprobación publicada."
MSG_ERR_CM042_SHA_256_MISMATCH="La suma SHA-256 del archivo de Ostler RemoteCapture no coincide."
MSG_ERR_CM042_PIN_FAILED="Ostler no pudo confirmar que esta descarga de RemoteCapture sea auténtica, así que no se instaló."
MSG_ERR_CM042_VERSION_UNKNOWN="Ostler no reconoce esta versión de RemoteCapture, así que no se instaló."
MSG_ERR_CM042_SIDECAR_DISAGREES="La suma de comprobación publicada con esta descarga de RemoteCapture no coincide con el archivo, así que no se instaló."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess informó:"
MSG_ERR_CM042_VERIFY_FAILED="Falló la verificación de la firma y la notarización de Ostler RemoteCapture."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv informó:"
MSG_ERR_EXPECTED="  esperado: %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief informó: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="El binario de ostler-assistant en %s no es un ejecutable Mach-O."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="El SHA-256 del tarball de ostler-assistant no coincide."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  No se preparará un binario que no coincida con la suma de comprobación publicada."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="No se quitará la cuarentena ni se cargará el LaunchAgent."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="Vuelve a ejecutar el instalador cuando se corrija el tarball de origen."
MSG_ERR_URL="  url:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Los Mac con Intel no son compatibles. Ostler necesita Apple Silicon (M1, M2, M3 o M4)."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="Se requieren al menos 16 GB de RAM. Tienes %s GB. Se recomiendan 24 GB."
MSG_FAIL_CM042_SIGNATURE_FAILED="Se canceló la instalación de Ostler RemoteCapture: falló la comprobación de firma o notarización. El paquete se dejó en /Applications para el soporte técnico. Escribe a support@ostler.ai y vuelve a ejecutar el instalador."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="No se pudo descargar %s después de 3 intentos. Revisa tu conexión de red y vuelve a ejecutar el instalador."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="No se pudo descargar nomic-embed-text después de 3 intentos. Revisa tu conexión de red y vuelve a ejecutar el instalador."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker no está disponible. Vuelve a ejecutar el instalador para instalar Colima."
MSG_FAIL_CONTAINER_CLIENT_MISSING="El comando docker no está en este Mac, así que Ostler no puede iniciar los servicios que necesita. Vuelve a ejecutar el instalador; si falla de nuevo, envíanos el registro en %s."
MSG_FAIL_CONTAINER_ENGINE_ABSENT="Ostler necesita un entorno de ejecución de contenedores y ninguno responde en este Mac. Tu wiki, tu grafo de conocimiento y tu índice de búsqueda se ejecutan dentro de contenedores, así que la instalación se ha detenido aquí en lugar de terminar y dejarlos sin funcionar. Para solucionarlo: abre Terminal y ejecuta 'colima start', y luego vuelve a ejecutar este instalador. Si usas Docker Desktop, ábrelo, espera a que el icono de la ballena se estabilice y vuelve a ejecutarlo. El registro completo está en %s."
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="Docker no estuvo listo a tiempo para iniciar las bases de datos del grafo de conocimiento. Asegúrate de que Colima o Docker se esté ejecutando y vuelve a ejecutar el instalador."
MSG_FAIL_GRAPH_DB_PULL_FAILED="No se pudieron descargar las imágenes de las bases de datos del grafo de conocimiento tras varios intentos. Suele ser un problema de red. Revisa tu conexión a internet y vuelve a ejecutar el instalador."
MSG_FAIL_GRAPH_DB_UP_FAILED="Las bases de datos del grafo de conocimiento se descargaron, pero no se pudieron iniciar. Vuelve a ejecutar el instalador; si sigue ocurriendo, abre Terminal y ejecuta: cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="Ostler no pudo completar una solicitud autenticada a la base de datos del grafo de conocimiento. Lo intentó dos veces, con dos segundos de diferencia, y ambos intentos fueron rechazados. Aún no sabemos por qué: puede que la base de datos todavía se estuviera iniciando, o que la credencial que guarda Ostler no sea la que espera. Tus datos no se han tocado. Volver a ejecutar el instalador suele funcionar, y si funciona, aun así nos gustaría saberlo: envíanos el registro de instalación, porque es un fallo que estamos intentando reproducir activamente."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="Falta el módulo de extracción de FDA en el paquete del instalador. Vuelve a descargar la .app desde ostler.ai/install, o vuelve a ejecutar con --allow-plaintext para desarrollo/CI."
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="El módulo de extracción de datos se instaló, pero no se puede cargar, así que la actualización en segundo plano fallaría cada vez. La salida completa se guardó en %s. Vuelve a ejecutar el instalador y adjunta ese archivo si contactas con el soporte técnico (Referencia: ERR-10-FDA-DEPS-IMPORT)."
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="Error interno: el módulo de extracción de datos se colocó dentro del paquete de la aplicación, lo que rompería su firma. Es un fallo de compilación, no un problema de tu Mac. Vuelve a descargar la .app desde ostler.ai/install (Referencia: ERR-10-FDA-DEPS-UNSAFE-PATH)."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Falló la instalación de las dependencias de Doctor. La salida completa se guardó en %s. Adjúntala cuando escribas a support@ostler.ai (Referencia: ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="Falló la instalación de las dependencias del proceso de importación. La salida completa se guardó en %s. Adjúntala cuando escribas a support@ostler.ai (Referencia: ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Falló la instalación de Homebrew. La salida completa se guardó en %s. Adjúntala cuando escribas a support@ostler.ai."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="Falló la instalación del proceso de importación. El paquete contact_syncer es obligatorio en la instalación de producto. Vuelve a ejecutar con --allow-plaintext para desarrollo/CI, o descarga de nuevo el instalador e inténtalo otra vez."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="Se necesita acceso sudo para desactivar la suspensión e instalar Homebrew. Vuelve a ejecutar cuando estés listo."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="No se pudo iniciar ni Colima ni Docker Desktop. Instala Docker Desktop y vuelve a ejecutar."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="No hay suficiente espacio en disco (%s GB). Libera espacio e inténtalo de nuevo."
MSG_FAIL_MACOS_BELOW_FLOOR="macOS %s es anterior a las versiones compatibles con Ostler. Ostler necesita macOS %s o posterior: la app del instalador está compilada para esa versión y no se abrirá en una anterior. Actualiza macOS y vuelve a ejecutar el instalador."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="No hay ninguna llave de acceso configurada ni una configuración de seguridad existente. Vuelve a ejecutar con --allow-plaintext para desarrollo/CI, o vuelve a ejecutar el instalador y confirma la información sobre Touch ID."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="Se requiere el motor de memoria de conversaciones. Vuelve a ejecutar con --allow-plaintext para desarrollo/CI, o corrige el paquete que falta indicado arriba y vuelve a intentarlo."
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="El daemon de Ostler incluido (v%s en %s) no admite el comando 'run-source' que este instalador necesita para dirigir la ingesta a través del Acceso total al disco. Es una incompatibilidad de versiones dentro del paquete del instalador: instalarlo dejaría todas las fuentes de ingesta rotas sin avisar y el producto quedaría obsoleto sin ningún error visible. Vuelve a descargar la .app desde ostler.ai/install e inténtalo de nuevo (Referencia: ERR-11-DAEMON-RUN-SOURCE-SKEW)."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="Falló la instalación de ostler_security. Vuelve a ejecutar con --allow-plaintext para desarrollo/CI, o corrige el error de pip indicado arriba y vuelve a intentarlo."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="Falló la configuración de la llave de acceso. Vuelve a ejecutar con --allow-plaintext para desarrollo/CI, o corrige el error indicado arriba y vuelve a intentarlo."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="sqlcipher3 es necesario para las bases de datos cifradas. Vuelve a ejecutar con --allow-plaintext para desarrollo/CI, o corrige el error de pip indicado arriba y vuelve a intentarlo."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Este instalador es solo para macOS."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="La instalación de Xcode Command Line Tools no se completó en 15 minutos. Abre Terminal y ejecuta 'xcode-select --install', haz clic en Instalar en el cuadro de diálogo de macOS y espera a que termine. Después, vuelve a ejecutar este instalador."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="La instalación de Homebrew indicó que se completó, pero falta /opt/homebrew/bin/brew. Consulta %s para ver la transcripción completa. Recuperación: abre Terminal, ejecuta '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' y vuelve a ejecutar el instalador."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew está instalado en /opt/homebrew/bin/brew, pero el comando 'brew' no está en PATH después de evaluar shellenv. Abre una ventana nueva de Terminal y vuelve a ejecutar el instalador."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' indicó que se completó, pero colima no está en PATH. Consulta %s para ver los fallos de Homebrew. Recuperación: abre Terminal, ejecuta 'brew install colima docker docker-compose' manualmente y vuelve a ejecutar el instalador."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' indicó que se completó, pero la CLI de docker no está en PATH. Consulta %s. Recuperación: ejecuta 'brew install docker' manualmente y vuelve a ejecutar el instalador."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="La instalación de la app Ollama indicó que se completó, pero falta su binario en /Applications/Ollama.app. Consulta %s. Recuperación: ejecuta 'brew install --cask ollama-app' manualmente y vuelve a ejecutar el instalador."
MSG_FAIL_EMBED_HEALTHCHECK="Ollama está en ejecución, pero el modelo de embeddings no devolvió ningún vector (HTTP distinto de 200, o un resultado vacío). La ficha de Personas, la búsqueda y la navegación aparecerían vacías. Consulta %s. Recuperación: asegúrate de que la app Ollama (no la fórmula de Homebrew) esté instalada y en funcionamiento, y vuelve a ejecutar el instalador."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' indicó que se completó, pero sqlcipher no está en PATH. Consulta %s. Recuperación: ejecuta 'brew install sqlcipher' manualmente y vuelve a ejecutar el instalador."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' no generó /Applications/Tailscale.app. Consulta %s. Recuperación: descarga Tailscale desde https://tailscale.com/download/macos, arrástralo a /Applications y vuelve a ejecutar el instalador."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' indicó que se completó, pero falta el binario python3.11 en /opt/homebrew/opt/python@3.11/bin/python3.11. Consulta %s. Recuperación: ejecuta 'brew reinstall python@3.11' y vuelve a ejecutar el instalador."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="Hemos encontrado tus respuestas anteriores"
MSG_PROMPT_REUSE_SETTINGS_HELP="Hemos detectado un intento de instalación anterior en este Mac. Las preguntas que ya respondiste (nombre, nombre del asistente, zona horaria, prefijo de país, canales, etc.) se reutilizarán para que no tengas que volver a introducirlas. Elige Sí para continuar donde lo dejaste, o No para repasar las preguntas desde el principio."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Respuestas anteriores encontradas: nombre = %s, asistente = %s, zona horaria = %s."

MSG_PROMPT_PERMS_OK_TITLE="¿Todo listo para continuar?"
MSG_PROMPT_PERMS_OK_HELP="macOS pedirá acceso a Contactos y a Archivos y carpetas. El Acceso total al disco, opcional, se puede conceder más tarde."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Nombre completo (tal como aparece en tus contactos)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Nombre completo (p. ej., Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="¿Cómo quieres que te llame tu asistente?"
MSG_PROMPT_USER_ID_HELP="Un nombre corto con el que tu asistente se dirigirá a ti (p. ej., 'Andy', 'Andrew', 'Sra. Smith'). Es el que aparece en tus resúmenes matutinos y en las respuestas del chat. Es distinto de tu nombre completo indicado arriba."

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
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="Estos son tus calendarios. ¿Te parecen correctos?"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="Hemos supuesto de quién es cada uno, para que tu resumen nunca confunda de quién es cada viaje."
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="Apartados automáticamente, no se usan en tu resumen:"
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="tuyo"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="%s evento"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="%s eventos"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="días festivos"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="cumpleaños"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="sugerencias de Siri"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="un calendario al que te has suscrito"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="recordatorios"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="¿Usar \"%s\" para tu resumen?"
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="Hemos apartado este porque parece %s. Responde que sí si en realidad es la agenda de alguien."
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="¿De quién es el calendario \"%s\"?"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="¿Qué tipo de calendario es \"%s\"?"
# NEEDS REVIEW: The option words may be typed answers the installer compares against English values (personal, work, family, shared, other); a developer must confirm whether th
MSG_CONFIRM_CALENDAR_TYPE_HELP="Una de estas opciones: personal, trabajo, familia, compartido, otro. Esto determina lo sensibles que se consideran sus eventos."
MSG_CONFIRM_CALENDARS_SAVED="Se han guardado los propietarios de tus calendarios"
MSG_CONFIRM_CALENDARS_FAILED="No se pudieron guardar los propietarios de los calendarios (no es grave; puedes configurarlos más tarde)"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="Creemos que todos estos perfiles son tuyos (%s). ¿Quieres combinarlos en uno?"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="Estos perfiles comparten contigo una señal de identidad firme (un dominio de correo, un perfil de LinkedIn o un empleador). Al combinarlos, tu asistente no tratará tu propio historial como si fuera de varias personas distintas. Puedes deshacerlo más tarde."
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="Alguien comparte tu nombre pero parece una persona distinta (%s). ¿Eres tú u otra persona?"
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="Elige «distinta» para mantenerla como una persona aparte (tu asistente nunca la fusionará contigo). Elige «yo» solo si realmente eres tú."
MSG_CONFIRM_IDENTITY_SAVED="Se guardó quién eres"
MSG_CONFIRM_IDENTITY_FAILED="No se pudieron guardar las elecciones de identidad (no es grave; puedes confirmarlas más tarde)"

# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="Instalando en segundo plano (de unos 45 minutos a varias horas)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="¿Usar +%s?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Introduce el prefijo de país (p. ej., 44 para Reino Unido, 1 para EE. UU.)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Prefijo de país predeterminado"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Se usa para normalizar los números de teléfono al importar contactos y para establecer tu región (Reino Unido / UE / EE. UU. / otra) en los valores predeterminados de cumplimiento legal."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="Detectamos +%s. ¿Quieres usarlo para tu Hub?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Detectado a partir de tu número de teléfono anterior. Elige Sí para usarlo o No para introducir otro prefijo de país."

MSG_PROMPT_TZ_CONFIRM_TITLE="¿Usar esta zona horaria?"
MSG_PROMPT_TZ_CONFIRM_HELP="Zona horaria detectada: %s"
MSG_PROMPT_USER_TZ_TITLE="Introduce la zona horaria (p. ej., Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="¿Cómo quieres llamar a tu asistente?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="El nombre del campo es una sugerencia aleatoria: escribe encima lo que quieras. Marvin, Samantha, Joshua, Friday, Athena, Sage y Rosie son opciones muy populares." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Escribe el nombre que quieras: la sugerencia es solo un punto de partida."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="¿Cómo se pondrá en contacto contigo tu asistente?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Elige los canales de mensajería que quieres que use tu asistente. Puedes cambiarlo más tarde en la sección Doctor de la app."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_WHATSAPP_CONSENT_TITLE="¿Activar la mensajería de WhatsApp para tu asistente?"
# NEEDS REVIEW: Consent/liability wording; legal review recommended.
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web es un servicio de terceros. Al activarlo, aceptas que tus mensajes pasen por la propia infraestructura de WhatsApp antes de llegar a tu instancia local de Ostler, y que WhatsApp (Meta Platforms Ireland Ltd) pueda suspender, restringir o cancelar tu cuenta de WhatsApp por el uso automatizado. Puedes desactivarlo más tarde en Ajustes."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="Tu número de teléfono de WhatsApp"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Número internacional con prefijo de país, p. ej., +447700900123. Solo dígitos y un + inicial: sin espacios, paréntesis ni guiones."
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="Guardado como %s. WhatsApp necesita el número sin espacios ni paréntesis."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Activa el Acceso total al disco para el asistente de Ostler"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="Ajustes del Sistema está abierto en Acceso total al disco."
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
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Busca «%s» en la lista y activa su interruptor de Acceso total al disco."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="¿No aparece? Arrastra «%s» desde la ventana del Finder a la lista y activa su interruptor. El orden no importa: haz clic en Listo antes o después; el instalador espera hasta que el interruptor esté realmente activado."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="¿No aparece? Ostler no pudo abrir una ventana del Finder por ti. En el Finder pulsa ⌘⇧G, introduce la ruta de abajo, arrastra «%s» a la lista y activa su interruptor. El orden no importa: haz clic en Listo antes o después; el instalador espera hasta que el interruptor esté realmente activado."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="La app está en: %s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="La app está en: %s – esta ruta está en tu portapapeles, así que en el Finder pulsa ⌘⇧G, luego ⌘V y después Retorno."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Listo"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="Puedes hacer clic en Listo antes o después de activar el interruptor: el instalador espera hasta que esté realmente activado."

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Permite que Ostler lea los datos de tu Mac"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="Ajustes del Sistema está abierto en Acceso total al disco."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Busca «OstlerInstaller» en la lista y actívalo."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Haz clic en Listo al terminar y Ostler leerá tu historial de Safari, Notas, iMessages y Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Listo"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="Siguiente: Acceso total al disco para el instalador"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="A continuación, macOS te pedirá que concedas Acceso total al disco a OstlerInstaller."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Después de activar el interruptor, macOS mostrará un cuadro de diálogo para que elijas «Salir y volver a abrir» o «Más tarde»."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Haz clic en «Salir y volver a abrir». El instalador se reiniciará solo y continuará desde este paso automáticamente."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="OK"
MSG_INFO_INSTALLER_FDA_PREWARN="Te explicamos cómo conceder el Acceso total al disco..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="Abriendo Ajustes del Sistema para que puedas conceder el Acceso total al disco al instalador..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="Acceso total al disco concedido al instalador. A continuación se leerán Safari, Notas, iMessage y Mail."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="El Acceso total al disco sigue sin concederse. Continuamos sin él; puedes volver a ejecutar el instalador más tarde para extraer Safari / Notas / iMessage."
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="El Acceso total al disco para el instalador está listo. Ahora empieza la parte larga, que en su mayor parte se ejecuta sola, pero está atento a un cuadro de diálogo de macOS que pedirá instalar las herramientas de desarrollo, y vuelve para unos minutos de configuración cerca del final."
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="Un permiso más (el historial de Mensajes para tu asistente) llegará cerca del final, cuando tu asistente esté instalado. Entonces te indicaremos cómo hacerlo."
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="Aún se necesita el Acceso total al disco"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostler está a punto de leer los datos de tu Mac, pero el Acceso total al disco para OstlerInstaller sigue desactivado. Busca «OstlerInstaller» en la lista y actívalo."
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="O haz clic en Continuar para terminar la instalación con menos datos; puedes concederlo y volver a ejecutar el extractor más tarde."
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="Continuar"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="Contactos permitidos"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="Personas de confianza: números de teléfono y correos del ID de Apple (separados por comas). %s solo responde a las personas de esta lista; los mensajes de cualquier otra persona se ignoran. Se requiere al menos una entrada.

Por ejemplo:
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="¿Leer el correo a través de Apple Mail?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Lee cualquier cuenta de correo que hayas añadido a Apple Mail (iCloud, Gmail, Outlook, etc.) mediante el Acceso total al disco. No se guardan contraseñas. Recomendado para casi todo el mundo."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="¿Añadir una cuenta de correo a Apple Mail?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="Apple Mail aún no tiene cuentas conectadas en este Mac, así que Ostler no tendrá correo que leer. Elige Sí para abrir ahora Ajustes del Sistema > Cuentas de Internet (allí puedes añadir iCloud, Gmail u Outlook). Elige No para omitirlo; puedes añadir una cuenta más tarde y Doctor mostrará un aviso si no llega correo en 24 horas."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="¿Importar todo tu historial de Apple Mail?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="De forma predeterminada, Ostler lee los últimos cinco años de tu Apple Mail. Si guardas más en este Mac y quieres todo en tu grafo de conocimiento, elige Sí para importar ahora el historial local completo (puede tardar un poco más con un buzón grande). Elige No para mantener la ventana de cinco años; siempre podrás ampliarla más tarde desde Doctor."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="¿Configurar también un servidor IMAP+SMTP personalizado?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="Solo para buzones autoalojados. Déjalo en NO si tus cuentas son de Gmail, iCloud u Outlook: funcionan mejor a través de Apple Mail, como se indica arriba."

MSG_PROMPT_IMAP_HOST_TITLE="Host IMAP"
MSG_PROMPT_IMAP_HOST_HELP="Solo para servidores IMAP autoalojados o personalizados. Usa Apple Mail (arriba) para Gmail / iCloud / Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="Puerto IMAP"

MSG_PROMPT_SMTP_HOST_TITLE="Host SMTP"
MSG_PROMPT_SMTP_PORT_TITLE="Puerto SMTP"

MSG_PROMPT_EMAIL_USERNAME_TITLE="Dirección de correo (también se usa como nombre de usuario IMAP/SMTP)"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="¿Quién puede escribir a tu asistente por correo?"
MSG_PROMPT_EMAIL_ALLOWED_HELP="Tus propias direcciones de correo, separadas por comas. %s solo responde a correos de las direcciones de esta lista; el correo de cualquier otra persona se ignora. Se requiere al menos una dirección. Tu propia dirección ya está rellenada: cámbiala o añade otra."

MSG_PROMPT_EMAIL_PASSWORD_TITLE="Contraseña (oculta)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Contraseña de tu servidor IMAP/SMTP autoalojado. Se guarda localmente en ~/.ostler/ y nunca se envía a Creative Machines. Se guarda en texto plano: lo único que la protege son los permisos del archivo, que permiten el acceso a tu cuenta de macOS y a nadie más. Nada la cifra después. Usa una contraseña de aplicación en lugar de la contraseña de tu cuenta principal."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Confirmar contraseña"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="¿Qué carpeta debe vigilar el asistente?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="Recomendado: una etiqueta o carpeta dedicada (p. ej., Ostler). Solo leeremos los mensajes de allí y dejaremos intacta tu bandeja de entrada principal."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="Escribe INBOX de nuevo para confirmar, o pulsa Continuar para usar «Ostler»"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX significa que el asistente leerá todos los correos que recibas. Recomendamos encarecidamente usar en su lugar una etiqueta o carpeta dedicada."

MSG_PROMPT_EXPORTS_ACK_TITLE="¿Has solicitado la exportación de tus datos?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler importa datos de unas 20 plataformas. La lista completa, con enlaces directos a la página de solicitud de cada proveedor, está en docs.ostler.ai/data-exports.

La mayoría de los archivos tardan de 1 a 3 días en llegar por correo. Cuando lleguen los ZIP, déjalos en tu carpeta Descargas y Ostler los encontrará automáticamente.

Omite los que no uses; siempre podrás importar otros más adelante."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="¿Continuar con el disco SIN CIFRAR en reposo?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="FileVault está desactivado en este Mac, así que tu disco no está cifrado en reposo.

Qué significa esto si continúas: todo lo que guarda Ostler (todo tu grafo personal: wiki, conversaciones y notas de conocimiento en ~/Documents/Ostler, además de los secretos de servicio y las bases de datos en ~/.ostler) se escribe en el disco SIN CIFRAR. Cualquiera que pueda arrancar desde esta unidad, extraerla o acceder a una sesión desbloqueada puede leerlo todo. Ostler cifra de todos modos sus bases de datos más sensibles con una contraseña, pero el resto de tus datos solo está tan protegido como el propio disco.

Se recomienda encarecidamente activar FileVault. Puedes hacerlo en cualquier momento en Ajustes del Sistema > Privacidad y seguridad > FileVault. Cifra en segundo plano, sin reinstalar.

Elige Sí para continuar ahora con el disco sin cifrar en reposo (es una decisión deliberada e informada, y quedará registrada).
Elige No para detenerte aquí, activar FileVault primero y volver a ejecutar el instalador. En ambos casos no ha pasado nada malo."

MSG_PROMPT_PASSKEY_ACK_TITLE="Listo para configurar el cifrado del disco"
MSG_PROMPT_PASSKEY_ACK_HELP="Las bases de datos sensibles de Ostler se cifran con SQLCipher usando una contraseña que eliges en la siguiente pantalla. Tendrás que escribirla cada vez que inicies la interfaz del Hub. También se genera una clave de recuperación independiente, que se muestra una sola vez al final de la instalación. Para proteger en reposo todo lo que hay en tu Mac, mantén activado FileVault de macOS. Pulsa Continuar cuando estés listo."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="¿Quieres definir también una contraseña de recuperación? (recomendado)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="Elige tu contraseña"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="Esta contraseña cifra tu grafo de conocimiento y desbloquea la interfaz del Hub en cada inicio. Mínimo 12 caracteres. No podemos recuperarla por ti. Se recomienda guardarla en un gestor de contraseñas."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="Confirma tu contraseña"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="Vuelve a escribir la misma contraseña para confirmar."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="¿Importar esto durante la instalación?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="Las exportaciones RGPD encontradas se importarán a tu grafo de conocimiento durante la instalación."

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="Contraseña de la exportación de Disney+"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="Disney+ entrega su exportación RGPD como una hoja de cálculo protegida con contraseña, algo normal que no indica ningún problema con tu descarga. Introduce la contraseña para importar ahora tu historial de visualización de Disney+, o déjala en blanco para omitirlo; todo lo demás se importa igualmente."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="¿Tienes exportaciones de datos listas?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler puede importar archivos de redes sociales y plataformas (todo tu historial con amigos, familia, lugares, opiniones) desde el principio. Cuanto más sepa Ostler el primer día, más útil será desde ese mismo día. También puedes añadirlos más tarde; sin prisa.

Solicita la exportación de tus datos en cada plataforma (Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp, etc.), descarga los archivos ZIP y colócalos en tu carpeta Descargas.

Ostler buscará en ~/Downloads de forma predeterminada. ¿Prefieres otra carpeta? Elige una abajo. Si no, omite este paso e importa más tarde."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="¿Importar los mensajes de Gmail de este Takeout?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Lee el contenido de Gmail directamente del archivo de Takeout. Google nunca ve a Ostler."

MSG_PROMPT_FDA_PRESET_TITLE="¿De qué fuentes del Mac debe aprender Ostler?"
MSG_PROMPT_FDA_PRESET_HELP="Tres ajustes predefinidos, o elige cada fuente tú mismo. Las fuentes sensibles (reconocimiento facial) están desactivadas por defecto en todos los ajustes: actívalas solo si lo decides deliberadamente."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="Recomendado. Incluye Apple Mail, Contactos, Calendario, Notas, Mensajes, Recordatorios, historial de Safari, marcadores de Safari y eventos de Fotos (fechas y lugares, sin reconocimiento facial). El historial de WhatsApp Desktop y el de Chrome se añaden automáticamente si la app está instalada. Excluye los datos de reconocimiento facial de Fotos y cualquier archivo de exportación de terceros."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="Todo. Cada fuente que Ostler puede leer en este Mac. El reconocimiento facial de Fotos permanece desactivado hasta que lo marques deliberadamente."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="Personalizar. Elige cada fuente en la siguiente pantalla. Las fuentes sensibles permanecen desactivadas hasta que las marques."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="Activa o desactiva esta fuente de datos."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_ARTICLE_9_TITLE="Tu decisión (Y / N)"
# NEEDS REVIEW: Legal consent wording; lawyer should confirm.
MSG_PROMPT_CONSENT_ARTICLE_9_HELP="Consentimiento de categoría especial del artículo 9 (RGPD del Reino Unido). Necesario para la base jurídica del tratamiento."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_VOICE_EU_TITLE="¿Reconocer voces en las llamadas que captures?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_VOICE_EU_HELP="El reconocimiento de hablantes permanece en este Mac. Creative Machines nunca recibe las huellas de voz."

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
MSG_PROMPT_CONSENT_ENRICHMENT_TITLE="¿Buscar datos públicos sobre lo que guardas?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_ENRICHMENT_HELP="Ostler puede añadir información de referencia pública a lo que encuentra: un libro, una película, un álbum, un lugar. Para ello envía el NOMBRE de ese elemento a servicios de referencia públicos como Wikidata, MusicBrainz y OpenLibrary, y guarda la respuesta en este Mac.

Lo que sale de tu Mac: el nombre del elemento que se busca. Nada más. Ni tus mensajes, ni tus contactos, ni tus archivos, ni quién lo mencionó.

Lo que puede ver el servicio al otro lado: tu dirección IP y que la solicitud viene de Ostler. La consulta va directamente de tu Mac a ellos, sin pasar por nuestros servidores, así que no hay forma de preguntar sin que sepan que alguien ha preguntado.

Si dices No: no se hace ninguna consulta y el proceso de enriquecimiento en segundo plano no se instala. Todo lo demás funciona exactamente igual. Tu biblioteca simplemente contendrá lo que tú le diste, en lugar de lo que añade un catálogo público.

Puedes decir No ahora y cambiar de opinión más tarde volviendo a ejecutar el instalador."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE="Una última cosa: cómo funcionan los datos de terceros"
# NEEDS REVIEW: Legal text on controller/processor roles; lawyer should check.
MSG_PROMPT_CONSENT_THIRD_PARTY_HELP="Cualquier dato que importes de terceros (Google Takeout, descargas de Meta, exportaciones de LinkedIn, etc.) permanece en este Mac. Ostler lo guarda en tu grafo de conocimiento local; nada sale de tu dispositivo.

Al continuar, entiendes y aceptas que eres el único responsable del tratamiento y la conservación de estos datos en tu equipo, igual que ocurre con los mensajes de correo que ya tienes en tu disco duro.

Nota legal: respecto a los registros que importas a este Mac, eres el responsable y el encargado del tratamiento según la legislación del Reino Unido y de la UE (RGPD del Reino Unido, artículo 4(7) y 4(8)). Creative Machines nunca recibe estos datos y no es el responsable del tratamiento. Tu tratamiento con fines personales y domésticos queda dentro del artículo 2(2)(c) del RGPD del Reino Unido y de la UE.

Más información en docs.ostler.ai/privacy/third-party-data."

# Spoken-capture recording-consent acknowledgement (every region). Shown
# in the Phase-2 consent batch. The HELP string is the substantive text
# GUI installer users read on the decision sheet, so it is self-contained.
# ── Personal-use-only terms (vendor/legal/consent_strings.py PERSONAL_USE_ONLY) ──
# A LICENCE TERM, not an optional consent, which is why it acknowledges rather
# than offering a decline that leaves a half-licensed install. Wording verbatim
# from the versioned ConsentString so the Doctor can flag drift.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TERMS_PERSONAL_USE_HEADING="Para qué sirve Ostler"
MSG_TERMS_PERSONAL_USE_INTRO="Ostler está pensado para una sola persona, en su propio Mac, para entender su propia vida. Ese es todo el diseño, y por eso tus datos nunca salen de este equipo."
# NEEDS REVIEW: Licence term; lawyer should confirm wording.
MSG_TERMS_PERSONAL_USE_BUSINESS="No está pensado para uso empresarial. Por favor, no implantes Ostler entre empleados ni lo uses en tu trabajo para captar datos de compañeros, clientes, pacientes o usuarios. Si una organización lo hace, pasa a ser responsable de todas las personas cuya información recopila, y Ostler no está diseñado para asumir eso."
# NEEDS REVIEW: Legal/consent wording; a lawyer should confirm its legal force.
MSG_TERMS_PERSONAL_USE_RECORDER="Tú eres quien graba. Ostler es la herramienta. Cuando la ley de tu país exija consentimiento antes de grabar una conversación, obtenerlo es cosa tuya, y desde aquí no podemos saber si una grabación concreta es legal donde estás."
MSG_TERMS_PERSONAL_USE_ASK_HEADING="Te pedimos que no hagas tres cosas:"
# NEEDS REVIEW: Legal/consent wording; a lawyer should confirm its legal force.
MSG_TERMS_PERSONAL_USE_ASK_1="No grabes a menores sin el acuerdo de un progenitor o tutor. Un menor no puede dar ese acuerdo por sí mismo, y tu propia garantía no sustituye la suya."
MSG_TERMS_PERSONAL_USE_ASK_2="No grabes en lugares donde las personas esperan una privacidad real: una consulta médica, una reunión con un abogado, una sesión de terapia, una confesión religiosa, un baño o un vestuario."
# NEEDS REVIEW: Legal wording; a lawyer should confirm its legal force.
MSG_TERMS_PERSONAL_USE_ASK_3="No uses Ostler para grabar a nadie a escondidas cuando la ley de tu país no lo permita."
# NEEDS REVIEW: Licence and GDPR controller/processor terms; a lawyer should check.
MSG_TERMS_PERSONAL_USE_LEGAL="Ostler se licencia para uso personal y no comercial por parte de una persona física. Creative Machines no es responsable ni encargada del tratamiento de la información que guardas en tu Mac, no recibe nada de ella y no garantiza que una grabación o captura concreta sea legal en tu jurisdicción."
MSG_PROMPT_TERMS_PERSONAL_USE_TITLE="Ostler es para uso personal"
# NEEDS REVIEW: Licence acceptance text; a lawyer should check.
MSG_PROMPT_TERMS_PERSONAL_USE_HELP="Ostler se licencia para tu uso personal en tu propio Mac. No lo implantes entre empleados ni lo uses en el trabajo para captar a compañeros, clientes o pacientes. No grabes a menores sin el acuerdo de un progenitor y no grabes en lugares donde las personas esperan una privacidad real, como una consulta médica, una reunión con un abogado o una sesión de terapia. Pulsa Continuar para aceptar estos términos."
MSG_INFO_TERMS_PERSONAL_USE_DECLINED="No hay problema. No se ha instalado nada."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_HEADING="Convertir conversaciones habladas en texto"
# NEEDS REVIEW: Legal/consent wording; a lawyer should check.
MSG_CONSENT_SPOKEN_CAPTURE_INTRO="En resumen: cuando captas audio hablado para transcribirlo, obtener el consentimiento que exija la ley es responsabilidad tuya, no nuestra. Escribir y enviar mensajes no se ve afectado."
# NEEDS REVIEW: Legal wording; a lawyer should check.
MSG_CONSENT_SPOKEN_CAPTURE_LAW="Ostler puede convertir en texto con función de búsqueda las conversaciones habladas que captes, como llamadas y reuniones; esto solo se refiere al audio que decidas transcribir. Las normas sobre grabar a personas mientras hablan varían según el país; en algunos (Alemania y Francia, por ejemplo) todos los participantes deben estar de acuerdo antes."
# NEEDS REVIEW: Legal/consent wording; a lawyer should check.
MSG_CONSENT_SPOKEN_CAPTURE_LOCAL="Guardar el audio captado en tu propio Mac no elimina esta obligación: Ostler nunca lo envía a ningún sitio, pero aun así necesitas consentimiento cuando tu ley local lo exija."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_HEADING="Lo que te pedimos:"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_1="Obtén el consentimiento que exija tu ley local antes de captar una conversación hablada."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_2="Deja claro a las personas con las que estás que se está captando audio; por ejemplo, dilo al principio o mantén un indicador visible."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_3="Si tienes dudas, deja desactivada la transcripción de voz. Tus conversaciones de texto funcionan igual."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_LABEL="Tu decisión:"
# NEEDS REVIEW: Consent affirmation by the user; a lawyer should confirm wording.
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_Y="[Y] Lo entiendo y obtendré el consentimiento que exija mi ley local."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_N="[N] Ahora no: mantener desactivada la transcripción de voz. (Puedes activarla más tarde en Ajustes.)"
# NEEDS REVIEW: Spanish legal usage cites § 201 StGB as 'artículo'; legal text needs lawyer review.
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL="Nota legal: grabar la palabra hablada puede estar regulado por la ley nacional, por ejemplo el artículo 201 del Código Penal alemán (Verletzung der Vertraulichkeit des Wortes) o el artículo 226-1 del Código Penal francés, con independencia de la ley de protección de datos. Como persona que realiza la grabación en este Mac, eres responsable de su cumplimiento. Creative Machines nunca recibe tus grabaciones y no es parte en ellas."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_TITLE="¿Convertir conversaciones habladas en texto?"
# NEEDS REVIEW: Use 'artículo 201' per Spanish legal citation; consent text needs lawyer review.
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_HELP="En resumen: cuando captas audio hablado para transcribirlo, obtener el consentimiento que exija la ley es responsabilidad tuya. Escribir y enviar mensajes no se ve afectado.

Ostler puede convertir en texto con función de búsqueda las conversaciones habladas que captes, como llamadas y reuniones. Esto solo se refiere al audio que decidas transcribir.

Lo que te pedimos:
• Obtén el consentimiento que exija tu ley local antes de captar audio.
• Deja claro que se está captando audio: dilo o mantén un indicador visible.
• Si tienes dudas, déjalo desactivado. Tus conversaciones de texto funcionan igual, y puedes activarlo más tarde en Ajustes.

Nota legal: grabar la palabra hablada puede estar regulado por la ley nacional, con independencia de la ley de protección de datos; por ejemplo, el artículo 201 del Código Penal alemán o el artículo 226-1 del Código Penal francés. Como persona que realiza la grabación, eres responsable de su cumplimiento. Creative Machines nunca recibe tus grabaciones."
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="La transcripción de voz seguirá desactivada. Puedes activarla más tarde en Ajustes."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_TITLE="¿Listo para instalar?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_HELP="Escribe INSTALL para confirmar que aceptas los términos."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Escribe INSTALL"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Instalar Ostler"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Cancelar"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Escribe INSTALL exactamente (no importan las mayúsculas) para confirmar, o haz clic en Cancelar para volver."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="Conecta tu iPhone y tu Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale da a este Mac una dirección privada estable a la que tu iPhone y tu Watch pueden acceder desde cualquier lugar, cifrada y sin exposición pública."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="¿Guardar la clave de recuperación en el llavero?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="Guarda tu clave de recuperación de cifrado en el llavero de macOS para mantenerla a salvo."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="Cargando tu grafo"
MSG_HYDRATE_CONTACTS_STARTED="Importando tus contactos al grafo"
MSG_HYDRATE_CONTACTS_DONE="%s contactos importados"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="Los contactos tardaron más de %ss, así que dejamos de esperar y seguimos adelante. Hasta ahora hay %s contactos, y Ostler terminará el resto en segundo plano."
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="Cargando el historial de tu calendario (cinco años atrás, un año por delante)"
MSG_HYDRATE_CALENDAR_DONE="%s eventos importados"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  Aún se está cargando tu calendario (%ss hasta ahora). Un Mac con años de reuniones tarda un poco."
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="Creando tus Lugares a partir de los sitios donde te reúnes"
MSG_HYDRATE_PLACES_DONE="Se ha creado tu sección de Lugares"
MSG_HYDRATE_PLACES_SKIPPED="Aún no se han encontrado señales de ubicación; los Lugares se irán completando a medida que se llene tu calendario"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="La creación de Lugares ha tenido un problema: hay señales de ubicación, pero no se ha generado ningún Lugar. Es posible que tu página de Lugares siga vacía. Consulta %s"
MSG_HYDRATE_PLACES_ERROR_WARN="La creación de Lugares no se ha completado (error inesperado). Es posible que tu página de Lugares esté incompleta. Consulta %s"
MSG_HYDRATE_WIKI_RECOMPILE="Creando tu wiki. Ostler está escribiendo un breve resumen de cada una de tus personas, organizaciones y temas clave, así que, con una libreta de direcciones grande, puede tardar desde unos minutos hasta aproximadamente una hora. Solo ocurre una vez, se ejecuta por completo en tu Mac y puedes dejarlo trabajando sin problema."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="Comprobando tu índice de búsqueda (%s colecciones detectadas)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="Cargando tu historial de navegación en el índice de búsqueda"
MSG_INITIAL_HYDRATE_QDRANT_READY="Índice de búsqueda listo (%s colecciones)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="El índice de búsqueda se completará en segundo plano cuando termine la instalación"
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
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="El almacén de búsqueda ya está activo; creando las colecciones que aún faltan: %s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="El índice de búsqueda está incompleto: no se pudo crear %s aunque el almacén de búsqueda está en marcha y responde. Ostler seguirá funcionando y el Doctor muestra esta carencia, pero esta parte de la búsqueda seguirá vacía hasta que se solucione."
MSG_WARN_QDRANT_COLLECTIONS_MISSING="El índice de búsqueda está incompleto: no se pudo crear %s. Ostler seguirá funcionando y el Doctor muestra esta carencia."
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="No se pudo comprobar qué colecciones de búsqueda existen (%s). Esto no indica que falten."
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="El índice de búsqueda se completará en segundo plano cuando termine la instalación (esperando: %s)"
MSG_HYDRATE_DONE="Tu grafo está listo: %s personas, %s eventos"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="Es posible que iCloud aún esté sincronizando tus contactos – volviendo a exportar ahora para recoger lo que acaba de llegar."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="No se encontraron contactos en la app Contactos (ni locales ni de iCloud). Añade algunos a Contactos y vuelve a ejecutarlo desde Ajustes."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="No hay contactos de iCloud que importar. Puedes añadirlos más tarde desde Ajustes."
MSG_HYDRATE_SKIPPED_NO_EVENTS="No hay eventos de calendario en los últimos 5 años. Puedes completarlos más tarde desde Ajustes."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="Leyendo tus últimos 90 días de correo – tus correos permanecen en este Mac (el historial más antiguo se completa en segundo plano)"
MSG_HYDRATE_EMAIL_DONE="Se encontraron %s personas en tu correo reciente"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="No hay correo reciente que leer. Puedes añadir una cuenta en Apple Mail y volver a ejecutarlo más tarde."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="El lector de correo aún no está listo. Puedes añadir una cuenta en Apple Mail y volver a ejecutarlo más tarde."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="El correo aún se está cargando en segundo plano. Tu wiki se va completando poco a poco y te muestra por dónde va."
MSG_HYDRATE_EMAIL_HEARTBEAT="  Aún se está leyendo tu correo (%ss hasta ahora). Puede tardar un rato en un Mac con años de historial."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="¿Abrir Apple Mail para que empiece a sincronizar?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="Tienes %s cuenta(s) de correo configurada(s), pero Apple Mail aún no ha descargado ningún mensaje. Podemos abrir Mail.app ahora y esperar mientras se sincroniza."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="¿Abrir Calendario para que empiece a sincronizar?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="Tienes %s cuenta(s) de calendario configurada(s), pero Calendar.app aún no tiene eventos guardados. Podemos abrir Calendario ahora y esperar mientras se sincroniza desde iCloud."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="¿Abrir Contactos para que empiece a sincronizar?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="Tienes %s cuenta(s) de contactos configurada(s), pero Contacts.app aún no tiene entradas guardadas. Podemos abrir Contactos ahora y esperar mientras se sincroniza desde iCloud."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="Esperando a que %s empiece a sincronizar (hasta %s segundos)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="Aún se espera la sincronización de %s (%ss transcurridos, %ss restantes). La primera sincronización de iCloud puede tardar unos minutos tras un inicio de sesión reciente."
MSG_OK_APP_HAS_POPULATED="%s ya ha rellenado su almacén local. Continuando."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="No detectamos la sincronización de %s durante el tiempo de espera. Continuando; puedes volver a ejecutar la carga desde Ajustes más tarde."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="Cuentas de Apple Mail visibles: %s. Abre Mail.app una vez para que empiece a descargar mensajes."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="Cuentas de calendario visibles: %s. Abre Calendar.app una vez para que sincronice tus eventos."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="Cuentas de contactos visibles: %s. Abre Contacts.app una vez para que sincronice tu libreta de direcciones."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="No se pudieron leer tus Contactos. Ostler los lee mediante el Acceso total al disco: concédelo en Ajustes del Sistema > Privacidad y seguridad > Acceso total al disco y vuelve a ejecutar la hidratación desde Ajustes. Seguiremos intentándolo en segundo plano."
MSG_HYDRATE_CONTACTS_PENDING="Tu app Contactos aún no se ha sincronizado. Abre Contactos una vez, espera a que se sincronice y vuelve a ejecutar la hidratación desde Ajustes."
MSG_HYDRATE_CONTACTS_READ_FAILED="Tus contactos están en este Mac, pero Ostler importó 0 de ellos, lo cual es inesperado. La importación se reintentará automáticamente en segundo plano. Si el problema persiste, vuelve a ejecutar la hidratación desde Ajustes o revisa el registro de instalación."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler seguirá comprobándolo en segundo plano e importará tus contactos automáticamente cuando iCloud termine de sincronizar."
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="Se importaron %s contactos con números de teléfono pero casi sin direcciones de correo (%s con teléfono frente a %s con correo). Normalmente esto significa que el lector de contactos omitió los correos. Tus contactos siguen siendo utilizables; consulta %s y vuelve a ejecutar la hidratación desde Ajustes una vez resuelto."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="Se importaron contactos nuevos; se está reconstruyendo tu wiki en segundo plano."
MSG_HYDRATE_CALENDAR_PENDING="Tu app Calendario aún no ha sincronizado los eventos. Abre Calendario una vez, espera a que se sincronice y vuelve a ejecutar la hidratación desde Ajustes."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="No se pudo leer tu calendario esta vez (el extractor informó de un error, no de un calendario vacío). El resto de tus datos no se ha visto afectado; consulta %s y vuelve a ejecutar la hidratación desde Ajustes."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="Leyendo tu historial de WhatsApp – tus mensajes se quedan en este Mac"
MSG_HYDRATE_WHATSAPP_DONE="Se encontraron %s personas en tus chats de WhatsApp"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="Se leyeron los chats de WhatsApp, pero no se escribieron en tu grafo de personas (código de salida %s). Ostler lo reintentará. Detalles: %s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="No hay chats de WhatsApp que leer. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktop no está instalado. Instálalo desde la Mac App Store y vuelve a ejecutarlo desde Ajustes."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="El lector de WhatsApp aún no está listo. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp sigue cargándose en segundo plano. Tu wiki se va completando poco a poco y te muestra hasta dónde ha llegado."

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
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="Tus contactos de WhatsApp ya están en tu grafo de personas (%s identificadores). No hay nada que volver a leer."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="Tus contactos de WhatsApp se leyeron antes, pero tu grafo de personas ya no los contiene. Se están leyendo de nuevo."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="No se pudo comprobar si tus contactos de WhatsApp siguen en tu grafo de personas. Se leerán de nuevo en lugar de dar por hecho que están ahí."

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="Leyendo tu historial de chats de IA – tus conversaciones se quedan en este Mac"
MSG_HYDRATE_AICONV_DONE="Se guardaron %s conversaciones de IA en tu wiki"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="El lector de conversaciones de IA aún no está listo. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="No hay historial de chats de IA que leer. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="Los chats de IA siguen cargándose en segundo plano. Tu wiki se va completando poco a poco y te muestra hasta dónde ha llegado."
MSG_HYDRATE_AICONV_HEARTBEAT="  Sigo leyendo tu historial de chats de IA (%ss hasta ahora). Un historial grande puede tardar varios minutos."


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="Importando tu historial de navegación – tus visitas se quedan en este Mac"
MSG_HYDRATE_BROWSING_DONE="Se importaron %s páginas del historial de navegación"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="Se omitieron %s páginas marcadas como sensibles (banca, salud, etc.)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="No hay historial de navegación que importar. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="El lector del historial de navegación aún no está listo. Puedes volver a ejecutarlo más tarde desde Ajustes."

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
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="Tu historial de navegación ya está importado (%s páginas). No hay nada que volver a importar."
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="No se encontró ningún historial de navegación exportado para importar. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="Tu historial de navegación se importó antes, pero tu índice de búsqueda ya no lo contiene. Se está importando de nuevo."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="No se pudo comprobar si tu historial de navegación sigue en tu índice de búsqueda. Se importará de nuevo en lugar de dar por hecho que está ahí."
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="Tu historial de navegación no llegó a tu índice de búsqueda, así que tu página Navegación estará vacía. Vuelve a ejecutarlo desde Ajustes o abre Doctor."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="El historial de navegación sigue cargándose en segundo plano. Tu wiki se va completando poco a poco y te muestra hasta dónde ha llegado."

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="Cargando tus preferencias de correo. Esto se queda en este Mac y puede tardar unos minutos."
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="Se cargaron %s preferencias de tu historial de correo"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="No hay ningún archivo de preferencias de correo configurado. No hay nada que cargar."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="No se encontró ningún archivo de preferencias de correo en %s. No hay nada que cargar."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="El proceso de preferencias aún no está listo. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="Las preferencias de correo se siguen cargando en segundo plano. Tu wiki se va completando poco a poco y te muestra en qué punto está."
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  Se siguen cargando tus preferencias de correo (%ss hasta ahora). Un historial grande puede tardar unos minutos."

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="Tus preferencias de correo ya están cargadas (%s entradas). No hay nada que volver a cargar."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="Tus preferencias de correo se cargaron antes, pero tu índice de búsqueda ya no las contiene. Se cargarán de nuevo."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="No se pudo comprobar si tus preferencias de correo siguen en tu índice de búsqueda. Se cargarán de nuevo en lugar de dar por hecho que están ahí."

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
MSG_HYDRATE_PREFERENCES_DONE="Se importaron %s preferencias"
MSG_HYDRATE_PREFERENCES_ENRICHED="Se enriquecieron %s de ellas con datos de referencia públicos"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="Se importaron %s preferencias, pero ninguna quedó en Comida, Música o Profesional. Tus páginas de wiki de Comida y Música estarán vacías."
MSG_WARN_PREFS_HEADLINE_HINT="Esto suele significar que no había ninguna exportación de música o comida (Spotify, Apple Music, Uber Eats, Google Takeout) o que los datos no se categorizaron. Añade esas exportaciones, vuelve a ejecutarlo desde Ajustes y reconstruye la wiki."
MSG_WARN_PREFS_UNCATEGORISED="%s de %s preferencias (%s%%) no tienen categoría y no aparecerán en ninguna página de temas. Revisa el formato de la exportación de origen."

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="Configurando el enriquecimiento de preferencias"
MSG_CM019_SETUP_DONE="Enriquecimiento de preferencias listo"
MSG_CM019_SETUP_FAILED="La configuración del enriquecimiento de preferencias no terminó. Tus páginas de preferencias se completarán cuando se solucione; el resto de Ostler no se ve afectado."
MSG_CM019_SETUP_SKIPPED="El proceso de enriquecimiento de preferencias no está incluido; se omite por ahora."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="Leyendo tu historial de iMessage – tus mensajes se quedan en este Mac"
MSG_HYDRATE_IMESSAGE_DONE="Se encontraron %s personas en tu historial de iMessage"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="No hay historial de iMessage que leer. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="El lector de iMessage aún no está listo. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage se sigue cargando en segundo plano. Tu wiki se va completando poco a poco y te muestra en qué punto está."
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  Se sigue leyendo tu historial de iMessage (%ss hasta ahora). Un historial de mensajes grande puede tardar varios minutos."

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="Tus contactos de iMessage ya están en tu grafo de personas (%s identificadores). No hay nada que volver a leer."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="Tus contactos de iMessage se leyeron antes, pero tu grafo de personas ya no los contiene. Se leerán de nuevo."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="No se pudo comprobar si tus contactos de iMessage siguen en tu grafo de personas. Se leerán de nuevo en lugar de dar por hecho que están ahí."

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="Leyendo tus Apple Notes - se quedan en este Mac"
MSG_HYDRATE_APPLE_NOTES_DONE="Se añadieron %s notas a tu base de conocimiento"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="No hay Apple Notes que leer. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="Tus Apple Notes ya están en tu base de conocimiento. Se omite."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="Apple Notes está desactivado para la búsqueda de conocimiento. Puedes activarlo en Ajustes."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="El importador de conocimiento aún no está listo. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="Apple Notes se sigue cargando en segundo plano. Tu base de conocimiento se va completando poco a poco y te muestra en qué punto está."
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  Se siguen leyendo tus Apple Notes (%ss hasta ahora). Una biblioteca de notas grande puede tardar unos minutos."

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="Tus Apple Notes ya están en tu base de conocimiento (%s entradas). No hay nada que volver a leer."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="Tus Apple Notes se añadieron antes, pero tu base de conocimiento ya no las contiene. Se añadirán de nuevo."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="No se pudo comprobar si tus Apple Notes siguen en tu base de conocimiento. Se añadirán de nuevo en lugar de dar por hecho que están ahí."

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="Leyendo tus Recordatorios - se quedan en este Mac"
MSG_HYDRATE_REMINDERS_DONE="Se añadieron %s recordatorios a tu base de conocimiento"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="No hay Recordatorios que leer. Puedes volver a ejecutarlo más tarde desde Ajustes."
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="Tus Recordatorios ya están en tu base de conocimiento. Se omite."
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="Recordatorios está desactivado para la búsqueda de conocimiento. Puedes activarlo en Ajustes."
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="El importador de conocimiento aún no está listo. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="Los recordatorios todavía se están cargando en segundo plano. Tu base de conocimiento se va completando poco a poco y te muestra por dónde va."
MSG_HYDRATE_REMINDERS_HEARTBEAT="  Aún se están leyendo tus recordatorios (%ss hasta ahora). Una lista de recordatorios grande puede tardar unos minutos."

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="Tus recordatorios ya están en tu base de conocimiento (%s entradas). No hay nada que volver a leer."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="Tus recordatorios se añadieron antes, pero tu base de conocimiento ya no los contiene. Se añadirán de nuevo."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="No se pudo comprobar si tus recordatorios siguen en tu base de conocimiento. Se añadirán de nuevo en lugar de dar por hecho que están."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="Indexando a tus contactos para la búsqueda"
MSG_HYDRATE_PEOPLE_DONE="Se indexaron %s personas para la búsqueda"
MSG_HYDRATE_PEOPLE_PARTIAL="Hasta ahora se han indexado %s de %s personas para la búsqueda. El resto aún no se podía buscar; Ostler lo reintentará automáticamente."
MSG_HYDRATE_PEOPLE_FAILED="Esta vez no se pudo indexar a tus contactos para la búsqueda (el almacén de grafos no respondió). Ostler lo reintentará automáticamente. Detalles: %s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="Aún no hay personas que indexar. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="El indexador de personas aún no está listo. Puedes volver a ejecutarlo más tarde desde Ajustes."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="Tus contactos todavía se están indexando en segundo plano. La búsqueda se va completando poco a poco y la wiki te muestra por dónde va."

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="Tus contactos ya están indexados para la búsqueda (%s personas). No hay nada que volver a indexar."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="Tus contactos se indexaron antes, pero tu índice de búsqueda ya no los contiene. Se indexarán de nuevo."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="No se pudo comprobar si tus contactos siguen en tu índice de búsqueda. Se indexarán de nuevo en lugar de dar por hecho que están."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="Vienen tres avisos de acceso a carpetas"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="El cuadro de diálogo de las Herramientas de línea de comandos ha aparecido delante de esta ventana: haz clic en Instalar y luego vuelve aquí (o espera unos segundos, traeremos esta ventana al frente por ti). Las herramientas se descargan en segundo plano mientras sigues respondiendo las preguntas de abajo; nada queda bloqueado."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="Permiso necesario: automatización de iMessage"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostler va a pedirle permiso a macOS para comunicarse con Mensajes. macOS mostrará una ventana que dice \"OstlerInstaller quiere acceso para controlar Mensajes\": haz clic en Permitir para que el asistente pueda enviar y recibir iMessages en tu nombre. Sin este permiso, los mensajes de iMessage nunca saldrán de este equipo, sin ningún aviso. Este permiso se concede una sola vez; puedes cambiarlo más tarde en Ajustes del Sistema > Privacidad y seguridad > Automatización."

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="Tu clave de recuperación"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="Anótala o imprímela ahora. Es la única forma de volver a entrar si pierdes tu contraseña Y tu Llavero deja de estar accesible. Ostler no puede recuperarla por ti: la clave nunca sale de este Mac y no se guarda en ningún servidor."
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="La he guardado en un lugar seguro"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="Copiar al portapapeles"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="Guardar como PDF..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="Imprimir..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="Continuar"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Clave de recuperación de Ostler.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Clave de recuperación de Ostler"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="Clave de recuperación copiada al portapapeles"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="Clave de recuperación guardada en %s"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="Vincula tu iPhone"
MSG_INFO_PAIR_IPHONE_HELP="Abre la app de Ostler en tu iPhone y escanea este código QR para vincularla con este Hub. También puedes vincularla más tarde desde el menú de Ajustes del Hub."
MSG_INFO_PAIR_IPHONE_FETCHING="Generando código de vinculación..."
MSG_INFO_PAIR_REFRESH="Actualizar código"
MSG_ERR_PAIR_FETCH_FAILED="Aún no se pudo conectar con la pasarela de Ostler. Puede que todavía se esté iniciando: haz clic en Actualizar para intentarlo de nuevo."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agent no está incluido en el instalador. Los resúmenes diarios y el LaunchAgent de mantenimiento de WhatsApp no se cargarán."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Los scripts de recompilación de la wiki no están incluidos en el instalador. La wiki no se actualizará automáticamente."

# F3 - legal package missing
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="El paquete legal no está incluido en el instalador. Los controles de consentimiento del Artículo 9, WhatsApp y voz generarán ModuleNotFoundError hasta que se reinstale."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s instalada en %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s ya está instalada, se deja como está"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Arquitectura de CPU no compatible con Google Workspace CLI; las funciones de Gmail / Google Calendar quedarán limitadas."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl no está disponible; se omitió la instalación de Google Workspace CLI. Las funciones de Gmail / Google Calendar quedarán limitadas."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="No se pudo descargar Google Workspace CLI desde %s"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="El SHA256 de Google Workspace CLI no coincide (esperado %s, obtenido %s). Se cancela la instalación de este binario."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="No se pudo extraer el archivo de Google Workspace CLI."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI se instaló en %s, pero falló la comprobación con --version."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="Puente de calendario iCloud / CalDAV instalado en %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="El puente de calendario iCloud / CalDAV en %s no es ejecutable. El calendario no devolverá eventos."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh no está incluido en el instalador. El reintento de registro del dispositivo cuando haya red está desactivado."

MSG_WARN_EMBED_DIMS_UNREADABLE="No se pudo leer la dimensión de los embeddings desde la comprobación de estado. La memoria está configurada para 768 dimensiones; si la recuperación se comporta de forma extraña, revisa el modelo de embeddings."
MSG_FAIL_EMBED_DIMS="El modelo de embeddings devolvió vectores de %s dimensiones, pero Ostler está configurado para %s. La memoria guardaría vectores que nunca podrá comparar. Revisa el modelo de embeddings y vuelve a ejecutar."

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
MSG_PROGRESS_REBOOT_SELFHEAL="Configurando la recuperación automática tras reinicio"
MSG_INFO_AUTOLOGIN_EXPLAIN="Ostler es un Hub siempre activo, así que tras un corte de luz o un reinicio necesita volver a funcionar sin nadie frente al teclado. Eso solo es posible si este Mac inicia sesión por sí mismo, y macOS solo puede hacerlo si la contraseña de inicio de sesión de %s está guardada en este Mac.

Guardarla debilita la seguridad de este Mac. La contraseña se ofusca, no se cifra, así que cualquiera que pueda usar una cuenta de administrador aquí, o que pueda extraer el disco y leerlo en otro equipo, puede recuperar tu contraseña. Verás exactamente dónde se guarda antes de escribir nada.

Si dices que no, no se guarda nada y nada más cambia. Tras un corte de luz inicias sesión como siempre, y los servicios de Ostler arrancan con tu sesión. Puedes cambiarlo más tarde en Ajustes del Sistema > Usuarios y grupos > Inicio de sesión automático."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_AUTOLOGIN_CONSENT="¿Guardar tu contraseña de inicio de sesión en este Mac para que pueda iniciar sesión por sí mismo tras un reinicio? [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="Ostler escribe esta contraseña en un archivo de este Mac, en /etc/kcpassword. Allí se ofusca con un patrón fijo, igual en todos los Mac y documentado públicamente, por lo que no es cifrado y se puede revertir. Cualquiera que pueda usar una cuenta de administrador en este Mac, o que pueda extraer el disco y leerlo en otro equipo, puede convertir ese archivo de nuevo en la contraseña de inicio de sesión de %s.

FileVault lo impediría, porque el disco no se puede leer en absoluto sin la contraseña de arranque. FileVault también impide el inicio de sesión automático, por la misma razón, y por eso Ostler solo ofrece esto cuando FileVault está desactivado.

Lo que el instalador sí controla: no muestra la contraseña mientras la escribes y no la escribe en el registro de instalación. El archivo ofuscado es la única copia que crea el instalador.

Déjalo en blanco para omitir el inicio de sesión automático."
MSG_PROMPT_AUTOLOGIN_PASSWORD="Contraseña de inicio de sesión de %s"
MSG_OK_AUTOLOGIN_CONFIGURED="El inicio de sesión automático está activado para %s, y esa contraseña de inicio de sesión ahora está en este Mac, en /etc/kcpassword, de forma ofuscada. Tras un reinicio, este Mac inicia sesión por sí mismo y los servicios de Ostler arrancan con esa sesión. Para deshacerlo, desactiva Inicio de sesión automático en Ajustes del Sistema > Usuarios y grupos."
MSG_INFO_AUTOLOGIN_ALREADY="El inicio de sesión automático ya está configurado para %s, así que este Mac ya tiene esa contraseña de inicio de sesión guardada en /etc/kcpassword. Se dejan ambos como están. Para deshacerlo, desactiva Inicio de sesión automático en Ajustes del Sistema > Usuarios y grupos."
MSG_INFO_AUTOLOGIN_DECLINED="No se activó el inicio de sesión automático y no se guardó ninguna contraseña. Tras un reinicio o un corte de luz, inicia sesión como siempre y los servicios de Ostler arrancarán con tu sesión."
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="Se omite la configuración del inicio de sesión automático: aquí no hay forma de pedir una contraseña de inicio de sesión y no se guardó nada. Puedes activar Inicio de sesión automático más tarde en Ajustes del Sistema > Usuarios y grupos si quieres que este Mac se recupere solo tras un reinicio. Esta opción guarda tu contraseña de inicio de sesión en el Mac de forma ofuscada y reversible, así que conviene informarse antes de hacerlo."
MSG_WARN_AUTOLOGIN_NO_PASSWORD="No se introdujo ninguna contraseña, así que no se activó el inicio de sesión automático y no se guardó nada. Si lo quieres más adelante, activa Inicio de sesión automático en Ajustes del Sistema > Usuarios y grupos."
MSG_WARN_AUTOLOGIN_FAILED="No se pudo activar el inicio de sesión automático (%s). No se reintentará. Si /etc/kcpassword existe en este Mac, contiene esa contraseña de inicio de sesión de forma ofuscada aunque la función esté desactivada; puedes eliminarlo desde Terminal con: sudo rm /etc/kcpassword. Para volver a intentarlo, activa Inicio de sesión automático en Ajustes del Sistema > Usuarios y grupos."
MSG_WARN_AUTOLOGIN_FILEVAULT="FileVault está activado, así que este Mac pide una contraseña en la pantalla de arranque para desbloquear el disco antes de que nadie pueda iniciar sesión. El inicio de sesión automático no puede responder a eso, así que tras un corte de luz este Mac espera en la pantalla de desbloqueo de FileVault hasta que alguien la introduzca. No se activó el inicio de sesión automático y no se guardó ninguna contraseña. Es la más segura de las dos opciones: la recuperación desatendida tras un reinicio no es posible con FileVault activado y, a cambio, el disco sigue siendo ilegible para quien no tenga esa contraseña."

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
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="Ostler no pudo abrir Ajustes del Sistema por ti. Abre Ajustes del Sistema tú mismo y ve a Privacidad y seguridad > Acceso total al disco."
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="Ostler ejecuta tu wiki y la búsqueda en contenedores, así que instala y gestiona un motor de contenedores (Colima) en este Mac. Si ese motor se elimina o se reconfigura, tu wiki y la búsqueda dejarán de funcionar. Ostler te avisará e intentará reiniciarlo."
MSG_INFO_ENGINE_ALREADY_PRESENT="Ya hay un motor de contenedores instalado en este Mac. Ostler lo usará en lugar de instalar el suyo, y no lo gestionará ni lo modificará."

# ── Consent screens, terminal/log path (lifted from inline echo, l10n) ──
# Printed by _ostler_tty in install.sh: each value is a printf format whose
# %s pairs switch bold/dim on and off. Keep every %s, every line break and
# the [Y]/[N] answer tokens. Legal wording: translations ship needs_review.

# install.sh consent screen (TTY/log path), lifted from install.sh:11865. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_EU_01="
%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s

  %sUna última cosa – qué va a consultar Ostler en tu Mac%s

  Ostler es un asistente personal, así que funciona consultando las
  partes de tu vida que guardas en este Mac. Parte de ello es
  sensible. La ley de privacidad del Reino Unido y de la UE nos
  obliga a preguntarte con claridad antes de tocar nada de eso.

  %sDónde se guardan los datos.%s Todo lo que Ostler lee se queda en
  este Mac, en carpetas cifradas que solo tú puedes abrir. Nunca
  recibimos una copia. No existe una versión de tus datos en la \"nube\".

  %sQué se incluye.%s Según los conectores que actives, Ostler
  puede procesar los siguientes tipos de información que la ley
  considera datos de \"categoría especial\":

    - Información de salud mencionada en correos, mensajes,
      entradas de calendario o conversaciones transcritas
    - Creencias religiosas o filosóficas
    - Orientación sexual
    - Afiliación sindical
    - Capturas de voz, usadas solo para indicar *quién* habla en las
      llamadas (identificación del hablante). No deducimos estado de
      ánimo, emoción, sentimiento, estrés ni engaño a partir de la voz.
    - Menciones de delitos – propios o de otras personas

  No realizamos reconocimiento de emociones. Si esto cambiara, te lo
  preguntaríamos de nuevo, por separado, en una nueva pantalla de consentimiento.

  Todo esto se queda en tu Mac. Nada se envía a Creative Machines ni
  a ningún tercero, salvo en los casos concretos que se indican en
  nuestra Política de privacidad en ostler.ai/privacy.

  %sPuedes cambiar de opinión cuando quieras.%s Desactiva conectores
  concretos en Ajustes, borra todo con \"Reset Ostler\" o desinstala
  por completo ejecutando ostler-uninstall en Terminal.

  Retirar el consentimiento detiene el tratamiento a partir de ese
  momento. No deshace el trabajo que Ostler ya hizo con tu consentimiento anterior.

  Tu decisión:

    [Y] Doy mi consentimiento para que Ostler trate las categorías de
        datos personales anteriores, localmente en este Mac, para
        ejecutar mi asistente personal. (continúa la instalación)

    [N] No doy mi consentimiento. (cancela y elimina el
        instalador; no se guarda nada en este Mac)

  %sNota legal: Tú eres el responsable del tratamiento de todos
  los datos de categoría especial que Ostler procesa en este Mac
  (UK GDPR, artículo 4(7)). Creative Machines nunca recibe
  ninguno de estos datos. Tu consentimiento explícito anterior
  (UK GDPR, artículo 9(2)(a)) es la base jurídica del
  tratamiento. Para uso personal y doméstico, el artículo 2(2)(c)
  limita aún más el alcance. Este consentimiento es revocable en
  cualquier momento sin afectar al tratamiento ya realizado.%s
"
# install.sh consent screen (TTY/log path), lifted from install.sh:11973. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_EU_02="  No hay problema. La configuración se ha detenido y tus datos
  de Ostler existentes se han dejado exactamente como estaban."
# install.sh consent screen (TTY/log path), lifted from install.sh:11976. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_EU_03="  No hay problema. No se ha instalado nada y no se ha escrito
  nada en tu Mac."
# install.sh consent screen (TTY/log path), lifted from install.sh:11979. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_EU_04="
  Si cambias de opinión, vuelve a ejecutar el instalador."
# install.sh consent screen (TTY/log path), lifted from install.sh:11985. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_EU_05="  Responde Y o N."
# install.sh consent screen (TTY/log path), lifted from install.sh:12031. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_01="  %sReconocimiento de voces en llamadas (en la app Ostler para iPhone)%s

  La app Ostler Companion para iPhone puede etiquetar las transcripciones
  con quién habla – por ejemplo, \"Sam\", \"Alex\" – guardando una huella
  numérica de cada voz en un almacén cifrado de tu iPhone. Las huellas
  nunca salen de tu teléfono y nunca se envían a este Mac ni a nosotros;
  el Mac solo recibe la etiqueta de texto (el nombre), nunca la huella.
  Según la ley de privacidad del Reino Unido y de la UE, una huella de
  voz es un dato biométrico, por eso preguntamos antes de que
  Companion registre cualquier voz.

  %sQué hacemos.%s Identificar *quién* habla en una llamada que captures.
  %sQué no hacemos.%s Detectar el estado de ánimo, la emoción, el sentimiento,
  el estrés ni ningún otro estado psicológico deducido a partir de la voz.

  Las huellas se quedan en tu iPhone. Nunca las recibimos, y este
  Mac tampoco. Puedes desactivarlo cuando quieras en la app del
  iPhone, en Ajustes -> Reconocimiento de voz; al desactivarlo se
  borran las huellas ya guardadas en el teléfono. Si nunca
  instalas Companion en el iPhone, no se crea ninguna huella de
  voz.

  %sNota legal: Las huellas de voz guardadas en tu iPhone por la
  app Ostler Companion son datos biométricos según el artículo
  9(1) del UK GDPR. Tu consentimiento explícito anterior
  (artículo 9(2)(a)) es la base jurídica del tratamiento. Tú eres
  el responsable del tratamiento (artículo 4(7)); Creative
  Machines nunca recibe las huellas, y nunca se envían a este
  Mac. Para uso personal y doméstico, el artículo 2(2)(c) limita
  aún más el alcance. Retirar el consentimiento en la app del
  iPhone borra las huellas guardadas.%s
"
# install.sh consent screen (TTY/log path), lifted from install.sh:12102. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_02="
%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s

  %sSobre los datos de tu Mac que no son solo tuyos%s

  Ostler lee partes de tu vida que contienen información sobre
  otras personas – correos que te enviaron, mensajes que
  escribieron, caras en tus fotos, datos de contacto, asistentes
  a eventos del calendario. Es algo normal. Es tu bandeja de
  entrada, tus contactos, tu vida tal como existe en realidad.

  Todo permanece en este Mac. Creative Machines nunca recibe
  nada de ello. No hay ninguna cuenta en la nube que lo guarde.

  %sAntes de continuar, ten en cuenta lo siguiente:%s

    - Guardas estos registros para ti, como una agenda privada,
      un diario personal o un cuaderno. Ostler es la herramienta
      que te ayuda a organizar y buscar lo que ya tienes. Tú
      decides qué conservar y qué eliminar.

    - Solicitudes específicas de eliminación. Si alguna persona
      de la que tienes registros te pide que la elimines, puedes
      borrarla por completo de Ostler (Ajustes -> Personas ->
      Eliminar una persona). El borrado elimina sus datos de tu wiki,
      tu grafo, tu índice de búsqueda y la memoria de tu asistente.

    - Nada sale de tu Mac. Ni hacia nosotros, ni hacia una nube,
      ni hacia terceros – salvo en los casos concretos indicados en
      nuestra Política de privacidad en ostler.ai/privacy (sobre todo:
      enrutamiento opcional a la nube para preguntas no personales,
      comprobación de actualizaciones y enriquecimiento con metadatos públicos).

  Más información en docs.ostler.ai/privacy/third-party-data.

  Tu decisión:

    [Y] Lo entiendo. Continuar.
    [N] No doy mi consentimiento. (cancela y elimina el instalador;
        no se guarda nada en este Mac)

  %sNota legal: Respecto a los registros que conservas en este Mac,
  eres el responsable del tratamiento según la legislación del Reino
  Unido y de la UE (UK GDPR, artículo 4(7)). Creative Machines nunca
  recibe estos datos y no es el responsable del tratamiento. Tu tratamiento
  con fines personales y domésticos entra en el ámbito del artículo 2(2)(c) del RGPD del Reino Unido y de la UE.%s
"
# install.sh consent screen (TTY/log path), lifted from install.sh:12175. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_03="  No hay problema. La configuración se ha detenido y tus datos
  de Ostler existentes se han dejado exactamente como estaban."
# install.sh consent screen (TTY/log path), lifted from install.sh:12178. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_04="  No hay problema. No se ha instalado nada y no se ha escrito
  nada en tu Mac."
# install.sh consent screen (TTY/log path), lifted from install.sh:12181. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_05="
  Si cambias de opinión, vuelve a ejecutar el instalador."
# install.sh consent screen (TTY/log path), lifted from install.sh:12187. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_06="  Responde Y o N."
# install.sh consent screen (TTY/log path), lifted from install.sh:12214. %s pairs are bold/dim on and off.
MSG_TTY_CONSENT_MORE_07="
%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s
"
# install.sh consent screen (TTY/log path), lifted from install.sh:12253. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_08="  Responde Y o N."
# install.sh consent screen (TTY/log path), lifted from install.sh:12293. %s pairs are bold/dim on and off.
MSG_TTY_CONSENT_MORE_09="
%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s
"
