#!/usr/bin/env bash
# CM051 install.sh -- es-ES strings catalogue
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

MSG_STEP_CHECKING_PREREQUISITES="Comprobando los requisitos previos"
MSG_STEP_RUNNING_HEALTH_CHECK="Ejecutando la comprobación de estado"
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="Setup (a few quick questions, then it keeps going on its own)"

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="y vuelve a ejecutar: ostler-fda"
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="Cuentas de Apple Mail visibles: %s (informativo)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mail no parece tener todavía ningún mensaje local. Doctor mostrará un aviso de seguimiento si no llega ningún correo en 24 horas."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mail tiene mensajes en caché. La ingesta los recogerá en el próximo ciclo horario."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="Apple Mail está seleccionado, pero todavía no hay mensajes locales que leer en este Mac. Abre Apple Mail y añade una cuenta (Ajustes del Sistema > Cuentas de Internet, y luego marca Mail), y deja que termine una primera sincronización."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="Cuando haya llegado el correo, vuelve a ejecutar: ostler-fda. Ostler lo recogerá automáticamente; no hace falta nada más."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="La notarización de Apple la verificará Gatekeeper en el primer arranque."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="disponible, el instalador omitirá este paso automáticamente."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="Los probadores beta con acceso pueden definir PWG_PIPELINE_REPO=<url> y volver a ejecutar."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="Los probadores beta con acceso pueden definir PWG_KNOWLEDGE_REPO=<url> y volver a ejecutar."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="Extensiones de navegador omitidas (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  Clonado en %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture solo funciona en Apple Silicon. Se omite la instalación en esta máquina."
MSG_INFO_CM042_LOGS_AT="Registros de RemoteCapture: %s/ostler-remotecapture.log (y .err)"
MSG_INFO_CM042_TCC_PRE_PROMPT="En el primer arranque, Ostler RemoteCapture pedirá a macOS permiso de Grabación de Pantalla y de Micrófono. Concede ambos para que las llamadas y reuniones puedan transcribirse localmente. No aparece ningún indicador morado de grabación en la barra de menús: la captura de audio es silenciosa por diseño."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  Motor de memoria de conversaciones instalado en el venv."
MSG_INFO_HUB_APP_VERIFYING="Verificando Ostler.app en %s"
MSG_INFO_HUB_APP_STAGING="Preparando Ostler.app en /Applications desde %s"
MSG_INFO_HUB_APP_DRAG_HINT="Abre el DMG del instalador y arrastra Ostler.app y OstlerInstaller.app al acceso directo de Aplicaciones, y luego vuelve a ejecutar el instalador."
MSG_OK_HUB_APP_PRESENT="Ostler.app ya está presente en %s; firma verificada."
MSG_OK_HUB_APP_STAGED="Ostler.app instalado en %s"
MSG_WARN_HUB_APP_NOT_FOUND="No se encontró Ostler.app en /Applications y no hay ninguna copia incluida disponible."
MSG_WARN_HUB_APP_VERIFY_FAILED="Falló la verificación de la firma o la notarización de Ostler.app. Se deja el paquete en su sitio para que el equipo de soporte pueda inspeccionarlo."
MSG_INFO_CLONING_DOCTOR_AGENT="Clonando el agente Doctor..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="Clonando los scripts de ingesta de correo..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Clonando los scripts de energía del Hub..."
MSG_INFO_CLONING_IMPORT_PIPELINE="Clonando la canalización de importación..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="Clonando los scripts de recompilación de la wiki..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima está instalado pero no en ejecución. Se iniciará."
MSG_INFO_COLIMA_START_ATTEMPT="Iniciando Colima (intento %s de %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="No se pudieron exportar los contactos. Puedes importarlos manualmente más tarde."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="No se pudo leer la tarjeta de contacto. No pasa nada: te lo preguntaremos en su lugar."
MSG_INFO_CONTACT_CARD_WILL_ASK="Dentro de un momento te preguntaremos tu nombre y tu país. Tus contactos se leen más adelante usando el Acceso Total al Disco que concedas, y nada sale de este Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  Creando un venv de Python en %s..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="Creando el árbol de contenido para el usuario en %s/"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="Ciclo diario. Ejecución manual: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="Hub de escritorio (sin batería) detectado: desactivando la suspensión en todo el sistema"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker no está instalado. Se instalará Colima + Docker CLI + el plugin docker-compose (ligero, sin necesidad de Docker Desktop)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="Los archivos del agente Doctor no vienen incluidos con el instalador."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="Los scripts de ingesta de correo no vienen incluidos con el instalador."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="Faltan los scripts de ingesta de correo en el paquete del instalador. Vuelve a descargar el .app desde ostler.ai/install e inténtalo de nuevo."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Los scripts de ingesta de correo no vienen incluidos y se pasó --allow-plaintext; se omitirá la instalación del LaunchAgent. Los correos futuros no se vaciarán."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  Ya existe un checkout en %s; actualizando..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Extrayendo el mbox de Gmail del zip de Takeout (esto puede tardar un minuto en archivos grandes)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="El módulo de extracción de FDA no viene incluido. Se omite la extracción instantánea de datos."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Activando tus primeros 30 días de Ostler Pro..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Ostler Pro cuesta \$9.99 USD al mes tras la prueba. Suscríbete desde la app iOS Companion."
MSG_INFO_FOUND_GMAIL_MBOX_MB="Se encontró el mbox de Gmail en %s (%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Se encontró el zip de Google Takeout en %s (%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="Full Disk Access detectado: extracción completa disponible."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="Se detectaron exportaciones de GDPR pero la canalización de importación todavía no está disponible."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="La importación de exportaciones de GDPR estará disponible cuando se publique la canalización."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="Vamos a analizar Descargas, Escritorio y Documentos en busca de exportaciones de IA (Google Takeout, descargas de Meta, LinkedIn, etc.) que puedas haber guardado. macOS mostrará tres avisos de acceso a carpetas: permite cada uno, por favor. Tarda en total unos 5 a 10 segundos. Durante el análisis no se mueve ni se copia nada; solo comprobamos lo que hay."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS puede pedir permiso para leer tu Calendario. Concédelo para que Ostler pueda crear la parte de reuniones y eventos de tu grafo de conocimiento. (Los datos del Calendario permanecen en esta máquina.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS está pidiendo permiso para Descargas. Haz clic en Aceptar."
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS está pidiendo permiso para Escritorio. Haz clic en Aceptar."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS está pidiendo permiso para Documentos. Haz clic en Aceptar."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="Full Disk Access concedido. Preparando el siguiente aviso de macOS (automatización de Messages)..."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="Se necesitan las Herramientas de Línea de Comandos de Xcode. macOS pedirá permiso para instalarlas: busca un pequeño cuadro de diálogo gris (si no lo ves, pulsa Cmd+Tab o mira en el Dock). Haz clic en Instalar. Las herramientas se descargan en segundo plano mientras respondes las preguntas de abajo."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  Todavía configurando las Herramientas de Línea de Comandos (%ss). Si un pequeño diálogo gris de macOS pide instalar las herramientas de desarrollador, haz clic en Instalar – este paso está esperando eso. (Cmd+Tab o mira el Dock si no lo ves.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="Esperando a que terminen de instalarse las Herramientas de Línea de Comandos (ya casi está)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="Ciclo horario. La primera ejecución recupera los últimos 5 años de correo."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="Desactivando el LaunchAgent del puente iMessage heredado (monomáquina v1.0)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Hub solo con CA (no se detectó batería); se omite el LaunchAgent de energía del Hub."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Los scripts de energía del Hub no vienen incluidos con el instalador."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="API del asistente incluida con el instalador; se usa la fuente vendorizada."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="La fuente de la API del asistente no viene incluida; los endpoints de la iOS Companion serán limitados."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Cuando aparezca la ventana de Tailscale, inicia sesión con Apple / Google / Microsoft."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="Abriendo Tailscale para que puedas iniciar sesión..."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale omitido: la iOS Companion solo funcionará en tu Wi-Fi de casa. Puedes configurarlo más tarde desde Ajustes."
MSG_INFO_TAILSCALE_STILL_WAITING="Sigo esperando el inicio de sesión en Tailscale (%ss transcurridos): completa el inicio de sesión en la ventana de Tailscale, por favor."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="Full Disk Access concedido; reiniciando el asistente para que recoja el nuevo permiso."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="Abriendo Ajustes del Sistema y Finder para guiarte al conceder Full Disk Access al asistente..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="Full Disk Access sigue pendiente. El panel de Doctor mantendrá la tarjeta visible hasta que se conceda el acceso."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant ya tiene Full Disk Access; no hace falta nada más."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Comprobando si el asistente de Ostler puede leer tu historial de Messages..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="El asistente puede leer el historial de Messages; el canal de iMessage funcionará."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="El asistente todavía no puede leer el historial de Messages. El panel de Doctor mostrará una tarjeta que te guiará por Ajustes del Sistema."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="El LaunchAgent del asistente no se cargó; se omite la prueba de Full Disk Access de iMessage."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="La interfaz de Importar Evernote en Doctor mostrará un 'servicio no disponible'"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="La canalización de importación no viene incluida con el instalador."
MSG_INFO_INSTALLING_CM042="Instalando Ostler RemoteCapture v%s (transcripción de llamadas y reuniones)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="Instalando el motor de memoria de conversaciones desde %s..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  Instalando el motor de memoria de conversaciones en el venv..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="Instalando Colima + Docker CLI..."
MSG_INFO_INSTALLING_HOMEBREW="Instalando Homebrew..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="Instalando el servicio de conocimiento desde %s..."
MSG_INFO_INSTALLING_OLLAMA="Instalando Ollama..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Instalando el lector de Apple Mail en un venv dedicado..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  Instalando ostler-knowledge en el venv..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Instalando la extensión de Safari en /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="Instalando las dependencias de Python de seguridad..."
MSG_INFO_INSTALLING_SQLCIPHER="Instalando SQLCipher..."
MSG_INFO_INSTALLING_TAILSCALE="Instalando Tailscale..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="El soporte para Intel no está en la hoja de ruta; haz una solicitud si lo necesitas."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Servicio de conocimiento incluido con el instalador; se usa la fuente vendorizada."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Servicio de conocimiento no instalado: PWG_KNOWLEDGE_REPO está vacío."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="más tarde en Ajustes del Sistema > Privacidad y Seguridad > Full Disk Access"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  arranca para verificar la entrega por cron + la postura de imessage-tcc)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="Licencia: %s es Apache 2.0. Texto completo: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licencia: %s: revisa los términos originales antes de un uso comercial."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="almacén local: Google nunca sabe que Ostler existe."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="Registros: %s/email-ingest.log (y .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="Registros: %s/ostler-assistant.log (y .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="Registros: %s/wiki-recompile.log (y .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="Hubs en MacBook: define PWG_HUB_POWER_REPO=<url> y vuelve a ejecutar."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="Hub en MacBook detectado: configurando no suspender solo con CA (hub-power gestiona las transiciones de batería)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Las instalaciones en Mac Mini / Studio no se ven afectadas (siempre con CA)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Los datos del lado del Mac (iMessage, Safari, etc.) se extrajeron más arriba."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="Reinicio manual: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="Ejecución manual: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="Se omite la instalación de com.ostler.meeting-brief-sender (función de v1.0.1; los endpoints aún no se han publicado)."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="mensaje cuando se active más tarde el indicador de función."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="¿Necesitas ayuda? Escribe a support@ostler.ai. Intentamos responder en un plazo de 2 días laborables."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="No hay canales configurados. Ejecuta más tarde: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="No hay fuentes de FDA disponibles ahora mismo. Puedes conceder Full Disk Access"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="No se encontraron exportaciones de GDPR en Descargas, Escritorio ni Documentos."
MSG_INFO_OPENING_CHROME_WEB_STORE="Abriendo Chrome Web Store: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="el binario ostler-assistant no está instalado; se omite la prueba de doctor"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: aplazado (el daemon puede que todavía esté"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="Usando el binario ostler-assistant incluido en este DMG (ruta de instalación con capacidad sin conexión)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge instalado en el venv."
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler mostrará una pantalla de consentimiento adicional antes de instalar"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  Anula el repositorio de origen del motor de memoria de conversaciones mediante la variable de entorno documentada en ./install.sh --help."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  Anula el repositorio de origen con PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  Anula el repositorio de origen con PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  Anula el repositorio de origen con PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  Anula el repositorio de origen con PWG_PIPELINE_REPO=<url> ./install.sh"
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Guardando los registros de consentimiento y la región..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="Vigilante de batería de la fase 3 activado (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="Leyendo tu agenda de contactos (las bibliotecas grandes pueden tardar un par de minutos: no cierres el instalador, por favor)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="Anulación de política: edita ~/.ostler/power.conf (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="Sondeando el permiso de automatización de iMessage (solo lectura)..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="Descargando nomic-embed-text (274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="Descargando %s (%s)... esto puede tardar unos minutos."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="Atributo de cuarentena eliminado. Una vez que la compilación con Developer-ID esté"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Leyendo Safari, iMessage, Notas, Calendario, Fotos, Recordatorios, Mail..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="Leyendo tu tarjeta de contacto para rellenar tus datos por adelantado..."
MSG_INFO_REGION_EU_EEA_SOURCE="Región: UE/EEE (%s, origen: %s)"
MSG_INFO_REGION_SOURCE="Región: %s (origen: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="Región: Reino Unido (origen: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="Región: Estados Unidos (origen: %s)"
MSG_INFO_REPO_URL="URL del repositorio: %s"
MSG_INFO_REPO_URL_2="URL del repositorio: %s"
MSG_INFO_REPO_URL_3="URL del repositorio: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="Ahora elige la frase de contraseña que desbloqueará tu Hub. La escribirás cada vez que inicies la interfaz del Hub."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="Frase de contraseña de recuperación omitida. (Obsoleto: v1.0 siempre requiere una frase de contraseña.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="Reutilizando la instalación existente del agente Doctor en %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="Reutilizando la instalación existente de ingesta de correo en %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="Reutilizando la instalación existente de energía del Hub en %s"
MSG_INFO_REUSING_EXISTING_JWT_SECRET="Reutilizando el JWT_SECRET existente en %s"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="Reutilizando el token de servicio de PWG existente en %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="Reutilizando la instalación existente de recompilación de la wiki en %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="El paquete de la extensión de Safari no está presente en esta compilación del instalador (se omite)"
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="Buscando exportaciones de datos de GDPR..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="Define PWG_DOCTOR_REPO=<url> y vuelve a ejecutar para instalar."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="Define PWG_HUB_POWER_REPO=<url de HR015> y vuelve a ejecutar para instalar."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="Se omitió el modelo de conversación. Descárgalo más tarde: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Iniciando Colima (runtime ligero de Docker)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Iniciando Docker Desktop..."
MSG_INFO_STARTING_OLLAMA="Iniciando Ollama..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="Eliminando la fórmula heredada de Ollama (sin llama-server); cambiando a la app de Ollama..."
MSG_INFO_VERIFYING_EMBEDDINGS="Verificando que el motor de embeddings devuelve vectores..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="No se pudo iniciar Ollama automáticamente. Cárgalo con: launchctl bootstrap gui/\$(id -u) %s -- y luego vuelve a ejecutar el instalador."
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  arrancando; ejecuta \`ostler-assistant doctor\` después del primer"
MSG_INFO_SYMLINKING="  Creando enlace simbólico %s -> %s"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(Ajustes del Sistema > Cuentas de Internet). Ostler lee del"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(El resto de Ostler funciona sin el panel de Doctor.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="Esto es lo esperado por ahora. La importación de GDPR estará disponible en una actualización futura."
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="This usually takes 15 to 45 minutes, and can run longer if you have a lot of history or a slower Mac. That is normal – it is working, not stuck, so feel free to leave it running..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="Esto lee las bases de datos de macOS directamente: no hace falta exportar nada."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="Consejo: para incluir tu Gmail, añádelo antes a Mac Mail"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="Para instalar más tarde cuando tengas acceso:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="Activando la sincronización de iCloud para %s (silenciosa, solo en la primera ejecución)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (Artículo 9 del UK GDPR: requerido para datos de categoría especial)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="Actualizando la canalización existente..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="El árbol para el usuario ya se anunció (centinela presente); se omite"
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane no responde (opcional; consulta las advertencias de la fase 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="Míralo en cualquier momento con: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="El reconocimiento de voz seguirá desactivado. Puedes activarlo más tarde en Ajustes."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="Esperando a que inicies sesión en Tailscale (hasta 3 minutos)..."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="El conector de WhatsApp se ha dejado desactivado. Puedes activarlo más tarde desde Ajustes."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="Keepalive de WhatsApp programado a las 08:50 + 17:50 (etiqueta com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="Se omite la puesta al día de la wiki del primer día: el ciclo de recompilación de la wiki no está instalado. La reconstrucción diaria de la wiki, si está instalada, sigue ejecutándose."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Los scripts de recompilación de la wiki no vienen incluidos con el instalador."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="La wiki no se actualizará automáticamente; puedes volver a ejecutar la primera compilación manualmente:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="Marcador de postura escrito: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="Tus exportaciones están a salvo. Impórtalas más tarde con: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="Los datos de tu Mac (iMessage, Safari, etc.) ya se extrajeron más arriba."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="Puedes añadirlo más tarde para una incorporación instantánea desde Safari, iMessage, etc."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="Modelo de IA: %s (%s): seleccionado para tus %s GB de RAM"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="Todas las fuentes seleccionadas (el reconocimiento facial sigue desactivado)"
MSG_OK_ALREADY_AVAILABLE="%s ya está disponible"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon detectado"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="Apps abiertas para activar la sincronización de iCloud"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="Las bases de datos de las apps ya están presentes (se omite el prearranque)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="Configuración del asistente guardada en %s (modo 0600)"
MSG_OK_BACKED_UP_CONTACTS="Se hizo copia de seguridad de %s contactos en %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s instalado en %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="LaunchAgent de Ostler RemoteCapture cargado (etiqueta %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima y Docker CLI instalados"
MSG_OK_COLIMA_WILL_START_AUTOMATICALLY_BOOT="Colima se iniciará automáticamente al arrancar"
MSG_OK_CONFIG_SAVED_ENV="Configuración guardada en %s/.env"
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Registros de consentimiento y región guardados en ~/.ostler/posture/"
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="Bases de datos cifradas. Se requiere la frase de contraseña en cada arranque."
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="Reintento de registro de dispositivo aplazado instalado (se ejecuta cada hora hasta que se vacíe la cola)"
MSG_OK_DOCKER_RUNNING="Docker en ejecución"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker en ejecución (tardó %ss)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Agente Doctor clonado desde %s"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Archivos del agente Doctor incluidos con el instalador"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Dependencias de Doctor instaladas"
MSG_OK_EMAIL_CHANNEL_FOLDER="Canal de correo: %s (carpeta: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de ingesta de correo cargado (etiqueta com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de ingesta de correo incluidos con el instalador"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="Scripts de ingesta de correo clonados desde %s"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="Configurando la memoria de conversaciones de WhatsApp"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  Lector de conversaciones de WhatsApp instalado."
MSG_WARN_WHATSAPP_SOURCE_FAILED="Falló la instalación del lector de conversaciones de WhatsApp; el feed de conversaciones de WhatsApp no se ejecutará. Consulta la salida de arriba."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="No se encontró la fuente del lector de conversaciones de WhatsApp; se omite el feed de conversaciones de WhatsApp."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="No se encontró el paquete del feed de conversaciones de WhatsApp en este instalador; se omite. El historial de mensajes de WhatsApp (a quién enviaste mensajes y cuándo) no se ve afectado."
MSG_OK_WHATSAPP_BUNDLE_LOADED="LaunchAgent del feed de conversaciones de WhatsApp cargado (etiqueta com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  El primer ciclo lee las conversaciones recientes de WhatsApp que tu Mac ha sincronizado (más o menos del último año); permanecen en tu Mac."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  Registros: %s/whatsapp-bundle.log y whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="Falló la instalación del LaunchAgent del feed de conversaciones de WhatsApp. Consulta la salida de arriba; el resto de la instalación no se ve afectado."
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="Configurando la memoria de conversaciones de correo"
MSG_OK_EMAIL_SOURCE_INSTALLED="  Lector de conversaciones de correo instalado."
MSG_WARN_EMAIL_SOURCE_FAILED="Falló la instalación del lector de conversaciones de correo; el feed de conversaciones de correo no se ejecutará. Consulta la salida de arriba."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="No se encontró la fuente del lector de conversaciones de correo; se omite el feed de conversaciones de correo."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="No se encontró el paquete del feed de conversaciones de correo en este instalador; se omite. La ingesta horaria de correo no se ve afectada."
MSG_OK_EMAIL_BUNDLE_LOADED="LaunchAgent del feed de conversaciones de correo cargado (etiqueta com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Lee tus hilos de correo recientes del almacén local de Apple Mail; todo permanece en tu Mac."
MSG_INFO_EMAIL_BUNDLE_LOGS="  Registros: %s/email-bundle.log y email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="Falló la instalación del LaunchAgent del feed de conversaciones de correo. Consulta la salida de arriba; el resto de la instalación no se ve afectado."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="Configurando la memoria de conversaciones de reuniones y voz"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  Lector de conversaciones de reuniones y voz instalado."
MSG_WARN_SPOKEN_SOURCE_FAILED="Falló la instalación del lector de conversaciones de reuniones y voz; el feed no se ejecutará. Consulta la salida de arriba."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="No se encontró la fuente del lector de conversaciones de reuniones y voz; se omite el feed."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="No se encontró el paquete del feed de conversaciones de reuniones y voz en este instalador; se omite."
MSG_OK_SPOKEN_BUNDLE_LOADED="LaunchAgent del feed de conversaciones de reuniones y voz cargado (etiqueta com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  Convierte tus propias reuniones grabadas y notas de voz en conversaciones que se pueden buscar; todo permanece en tu Mac."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  Registros: %s/spoken-bundle.log y spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="Falló la instalación del LaunchAgent del feed de conversaciones de reuniones y voz. Consulta la salida de arriba; el resto de la instalación no se ve afectado."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="Configurando la memoria de conversaciones de iMessage"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  Lector de conversaciones de iMessage instalado."
MSG_WARN_IMESSAGE_SOURCE_FAILED="Falló la instalación del lector de conversaciones de iMessage; el feed de conversaciones de iMessage no se ejecutará. Consulta la salida de arriba."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="No se encontró la fuente del lector de conversaciones de iMessage; se omite el feed de conversaciones de iMessage."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="No se encontró el paquete del feed de conversaciones de iMessage en este instalador; se omite."
MSG_OK_IMESSAGE_BUNDLE_LOADED="LaunchAgent del feed de conversaciones de iMessage cargado (etiqueta com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  Lee tus conversaciones recientes de iMessage del almacén de Messages de este Mac; todo permanece en tu Mac."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  Registros: %s/imessage-bundle.log y imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="Falló la instalación del LaunchAgent del feed de conversaciones de iMessage. Consulta la salida de arriba; el resto de la instalación no se ve afectado."
MSG_OK_EMBEDDING_MODEL_READY="Modelo de embeddings listo"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="%s contactos exportados (se importarán automáticamente)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="Vigilante de exportaciones instalado (analiza Descargas cada 4 horas)"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="Emisor de resúmenes previos a reuniones instalado (consulta cada 10 minutos durante las horas de vigilia)"
MSG_OK_EXTRACTED="Extraído en %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="Extraído de %s fuente(s). Datos guardados en %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_12_HOURS="Reejecución de FDA programada para dentro de ~12 horas (recoge las sincronizaciones lentas de iCloud)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro activo durante 30 días. Suscríbete desde la app iOS Companion para ampliarlo tras la prueba."
MSG_OK_FOUND="Encontrado: %s"
MSG_OK_FOUND_EXPORTS="Se encontraron exportaciones en %s"
MSG_OK_FOUND_GDPR_EXPORT_S="Se encontraron %s exportación(es) de GDPR:"
MSG_OK_GB_FREE_DISK_SPACE="%s GB de espacio libre en disco"
MSG_OK_GB_RAM_DETECTED="%s GB de RAM detectados"
MSG_OK_GDPR_IMPORT_COMPLETE="Importación de GDPR completa"
MSG_OK_GIT_AVAILABLE="Git disponible"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="Instalación de las Herramientas de Línea de Comandos iniciada (descargando en segundo plano mientras respondes las preguntas de abajo)."
MSG_OK_HOMEBREW_INSTALLED="Homebrew instalado"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de energía del Hub cargado (etiqueta com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de energía del Hub incluidos con el instalador"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Scripts de energía del Hub clonados desde %s"
MSG_OK_ICAL_SERVER_INSTALLED="API del asistente instalada (loopback 127.0.0.1:8090, con proxy de Doctor)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="Permiso de automatización de iMessage: concedido"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="LaunchAgent del puente iMessage cargado (etiqueta com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts del puente iMessage incluidos con el instalador"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="Scripts del puente iMessage clonados desde %s"
MSG_OK_IMESSAGE_CHANNEL="Canal de iMessage: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="Canalización de importación incluida con el instalador"
MSG_OK_IMPORT_PIPELINE_READY="Canalización de importación lista"
MSG_OK_CM048_PIPELINE_READY="Motor de memoria de conversaciones listo."
MSG_INFO_CM048_SETTINGS_WRITTEN="  Modelos de conversación configurados en %s (ajustados a tus %s GB de memoria)"
MSG_INFO_CM048_SETTINGS_KEPT="  Manteniendo tu configuración de conversación existente (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="Servicio de conocimiento listo: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="Textos de licencia instalados en %s/ (origen: %s)"
MSG_OK_MACOS_DETECTED="macOS %s detectado"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="Abriendo Ajustes del Sistema > Cuentas de Internet para que puedas añadir una cuenta de correo. Vuelve a esta ventana cuando hayas iniciado sesión en tu primera cuenta."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="Se omite el paso de Cuentas de Internet. Puedes añadir una cuenta de correo más tarde desde Ajustes del Sistema; Doctor mostrará un aviso de seguimiento si no llega ningún correo en 24 horas."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Recuperando ahora todo tu historial de Apple Mail. Esto puede tardar un poco más en un buzón grande."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="Manteniendo la ventana estándar de cinco años de correo. Puedes recuperar más tarde desde Doctor."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text ya está disponible"
MSG_OK_OLLAMA_HEALTHY="Ollama en buen estado"
MSG_OK_OLLAMA_INSTALLED="Ollama instalado"
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama instalado (solo CLI: puede necesitar un arranque manual tras reiniciar)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama instalado (app de escritorio)"
MSG_OK_OLLAMA_RUNNING="Ollama en ejecución"
MSG_OK_EMBEDDINGS_VERIFIED="Motor de embeddings verificado (vectores de 768 dimensiones)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: no se detectaron errores"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent del asistente de Ostler cargado (etiqueta com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s preparado en %s (firmado)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s preparado en %s (sin firmar)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor en ejecución en http://localhost:8089/doctor"
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Lector de Apple Mail instalado."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  Motor de ingesta de correo instalado."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="Comandos ostler-import, ostler-fda y ostler-uninstall instalados"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph en buen estado"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="Frase de contraseña registrada. Cifrará tus bases de datos durante la fase 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="Frase de contraseña de recuperación configurada."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="Información sobre la frase de contraseña confirmada."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="Fuente de energía: CA (Mac de escritorio, sin batería)"
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="Power source: AC (good – the install can run 30 to 60 minutes or more, so mains power keeps it steady)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="Instalación previa detectada. Cargando la configuración..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="Usando el Python %s incluido (no hace falta una instalación del sistema)"
MSG_OK_PYTHON_INSTALLED="Python %s instalado"
MSG_OK_QDRANT_HEALTHY="Qdrant en buen estado"
MSG_OK_READY="%s listo"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="Fuentes recomendadas seleccionadas"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="Clave de recuperación guardada en el Llavero (busca 'Ostler' en la app Contraseñas)"
MSG_OK_REDIS_HEALTHY="Redis en buen estado"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Extensión de Safari instalada en %s"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="La seguridad ya se configuró en una ejecución anterior."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="Módulo de seguridad instalado en el venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="Se generó un JWT_SECRET nuevo en %s"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="Se generó el token de servicio de PWG en %s"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="Servicios iniciados (Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant optional-collection pre-create (#606) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  Colección de búsqueda preparada: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="No se pudo preparar la colección de búsqueda %s; la wiki se seguirá construyendo (el lector la trata como vacía)"
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="El índice de búsqueda no estuvo listo a tiempo; se omitió la preparación de las colecciones opcionales (la wiki se seguirá construyendo)"
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="Suspensión desactivada con CA, suspensión con batería preservada, activación por red habilitada"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="Suspensión desactivada, activación por red habilitada"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale ya está instalado"
MSG_OK_TAILSCALE_INSTALLED="Tailscale instalado"
MSG_OK_TAILSCALE_ENV_PERSISTED="IP de Tailscale guardada en .env: la iOS Companion la usará en el primer arranque."
MSG_OK_TAILSCALE_IP="IP de Tailscale: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Servicio en segundo plano de Tailscale iniciado (modo userspace, sin extensión del sistema)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="No se pudo iniciar el servicio en segundo plano de Tailscale. Puedes volver a ejecutar la configuración desde Ajustes más tarde."
MSG_INFO_TAILSCALE_SIGN_IN_URL="Abriendo tu navegador para iniciar sesión en Tailscale: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Puerto del Hub %s expuesto en tu tailnet"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="No se pudo exponer el puerto del Hub %s en tu tailnet; el alcance fuera de la LAN puede ser limitado"
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="Atribuciones de terceros instaladas (origen: %s)"
MSG_OK_USER_FACING_TREE_READY="Árbol para el usuario listo"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="Usando la carpeta/etiqueta 'Ostler' en su lugar."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane en buen estado (búsqueda web local)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane en ejecución en http://localhost:3000 (habla con tu Ollama local)"
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="El conector de WhatsApp se habilitará (consentimiento registrado)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="LaunchAgent de puesta al día de la wiki del primer día cargado (reconstruye tu wiki cada 30 minutos durante las primeras horas y luego se detiene)"
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de recompilación de la wiki cargado (etiqueta com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de recompilación de la wiki incluidos con el instalador"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Scripts de recompilación de la wiki clonados desde %s"
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki en ejecución en http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="Tu wiki está lista para explorar. Ostler está escribiendo ahora los resúmenes de las páginas en segundo plano, así que se irán completando a lo largo de un rato. Puedes empezar a usar tu wiki de inmediato."
MSG_OK_YOUR_ASSISTANT_CALLED="Tu asistente se llama %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="Scripts del resumen de contexto personal incluidos con el instalador"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="LaunchAgent del resumen de contexto personal cargado (etiqueta com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  Registros: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="Reutilizando la instalación existente de context-refresh en %s"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="Los scripts del resumen de contexto personal no vienen incluidos; el asistente dependerá solo de las consultas en vivo (sin un resumen de contexto permanente)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="El LaunchAgent del resumen de contexto personal no se cargó; consulta context-refresh.err. El asistente sigue respondiendo mediante consultas en vivo"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="A la fuente clonada del servicio de conocimiento le falta su configuración de empaquetado, así que su entorno no se configuró."
MSG_WARN_BUNDLE="  Paquete: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s solo funciona en Apple Silicon (detectado: %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="No se pudo descargar Ostler RemoteCapture v%s desde %s"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="Causas habituales: la etiqueta de la release aún no está publicada, la red está sin conexión o la notarización original sigue en curso. Vuelve a ejecutar el instalador cuando la release esté activa."
MSG_WARN_CM042_EXTRACT_FAILED="No se pudo extraer el tarball de Ostler RemoteCapture; se omite el LaunchAgent."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Falló la carga del LaunchAgent de Ostler RemoteCapture. Consulta la salida de arriba y ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  El enriquecimiento de conversaciones no estará disponible. El resto de Ostler se instala con normalidad; vuelve a ejecutar sin --allow-plaintext para conectar el motor de memoria de conversaciones."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="Falló la instalación del motor de memoria de conversaciones (clonado)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  Se buscó en: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  Esto suele significar que el .app del instalador se compiló sin"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  el paquete cm048_pipeline vendorizado incluido en"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Vuelve a descargar el instalador o"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  vuelve a ejecutar con --allow-plaintext para una instalación de dev/CI."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="No se encontró el motor de memoria de conversaciones. El enriquecimiento de conversaciones no puede ejecutarse sin él."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="Configuración del motor de memoria de conversaciones omitida (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="Se resolvió la fuente del motor de memoria de conversaciones pero falta pyproject.toml; se omite la configuración del venv."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Colima no pudo iniciarse. Probando Docker Desktop como alternativa..."
MSG_WARN_COLIMA_START_RETRY="Colima no arrancó del todo bien (el socket de Docker no estaba listo). Reintentando en %ss..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="Causas habituales: la etiqueta v%s aún no está publicada, la red está sin conexión,"
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  stderr de consent_cli (primeros 400 caracteres):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  No se creó el script de consola en %s; puede que a pyproject.toml le falte la entrada [project.scripts]."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="Continuando porque se pasó --allow-plaintext."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="Continuando con la instalación. Vuelve a ejecutar \`ostler-fda\` después de diagnosticar el error de arriba."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="Continuando sin el autorrelleno de la tarjeta de contacto: Ostler te lo preguntará en su lugar."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  Las conversaciones enviadas a iMessage fallarán en silencio hasta que"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="No se pudo cambiar la configuración de suspensión. Activa 'Impedir que el Mac se suspenda automáticamente cuando esté enchufado' en Ajustes del Sistema > Energía."
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="No se pudo cambiar la configuración de suspensión. Activa 'Impedir la suspensión automática' en Ajustes del Sistema > Energía."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="No se pudo descargar ostler-assistant v%s desde %s"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="No se pudo extraer el mbox de Gmail del zip de Takeout; se omite."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="No se pudo extraer el tarball de ostler-assistant; se omite el LaunchAgent."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="No se pudo encontrar la CLI de Tailscale. Puedes configurarla manualmente más tarde."
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="No se pudo instalar el paquete legal/ de cadenas de consentimiento; continuando"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="No se pudo instalar el directorio LICENSES/ (no fatal)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="No se pudo instalar ostler_security en el venv del Hub."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="No se pudo instalar THIRD_PARTY_NOTICES.md (no fatal)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="No se pudo obtener el agente Doctor (fallaron tanto el incluido como el clonado)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="No se encontraron los archivos de Ostler Doctor. Son necesarios para el flujo de emparejamiento con iOS (Ostler.app inserta :8089/pair-ios en un iframe)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  Se buscó en: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  Esto suele significar que el .app del instalador se compiló sin"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  la fuente doctor/agent/ vendorizada incluida en"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Vuelve a descargar el instalador o"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  vuelve a ejecutar con --allow-plaintext para una instalación de dev/CI."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Instalación de Doctor abortada: es necesaria para el flujo de emparejamiento con iOS. Vuelve a descargar el instalador o pasa --allow-plaintext para una instalación de dev/CI."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="No se pudieron obtener los scripts de ingesta de correo (fallaron tanto el incluido como el clonado)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="No se pudieron obtener los scripts de energía del Hub (fallaron tanto el incluido como el clonado)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="No se pudieron obtener los scripts de recompilación de la wiki (fallaron tanto el incluido como el clonado)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="No se pudo abrir automáticamente la URL de Chrome Web Store: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="No se pudo guardar region.json (continuando; Doctor lo mostrará)"
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="No se pudo guardar en el Llavero. Apúntalo, por favor."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="No se pudo iniciar Ollama automáticamente."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="No se pudo actualizar la canalización (¿sin conexión?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="No se pudo escribir pipeline_signals.json. El diagnóstico de Doctor de buzón vacío recurrirá a valores seguros por defecto hasta la próxima instalación o ciclo."
MSG_WARN_CURL_SAID="Curl dijo:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="Directorio no encontrado: %s; se omite la importación."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker no se inició en %s segundos."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker está instalado pero no en ejecución. Habrá que iniciarlo."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama a mitad de instalación y bloquean los sondeos de disponibilidad."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  marcadores tempranos (los canales todavía se están conectando + permiso de Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="Falló la instalación del LaunchAgent de ingesta de correo. Consulta la salida de arriba."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="Falló la instalación del LaunchAgent del puente iMessage. Las respuestas de iMessage del usuario asistente no funcionarán hasta que vuelvas a ejecutar el instalador o ejecutes INSTALL_SNIPPET.sh manualmente."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Los scripts del puente iMessage no vienen incluidos y se pasó --allow-plaintext; se omitirá la instalación del LaunchAgent. Las respuestas de iMessage del usuario asistente no funcionarán."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="El cifrado no funcionará."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="El cifrado no funcionará, y"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="asegúrate de que la etiqueta fijada de PWG_KNOWLEDGE_REPO la incluye."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  permiso de Eventos para Messages.app)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="El extractor de FDA terminó con un código distinto de cero (%s). Últimas 20 líneas de la salida:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="El módulo de extracción de FDA no viene incluido en este instalador."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="Se esperaba en: Contents/Resources/ostler_fda/ (dentro del .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="Causa más probable: una regresión de compilación dejó fuera la copia vendorizada. Vuelve a descargar el .app desde ostler.ai/install."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="El módulo de extracción de FDA no viene incluido. Continuando porque se pasó --allow-plaintext: se omitirá la extracción instantánea de datos."
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault NO está habilitado."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="No se pudo activar el primer mes gratis en este momento; la instalación continuará. Abre la app iOS Companion una vez emparejada para resolverlo."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="No se ha concedido Full Disk Access a Terminal."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="%s GB de RAM detectados. Obtendrás el asistente compacto (gemma4:e2b): fiable, preciso, con respuestas en menos de un segundo en preguntas cortas, con llamadas a herramientas y un sincero 'no lo sé' cuando no lo sabe. Para respuestas más ricas en preguntas más largas, 24 GB o más desbloquean el asistente estándar (qwen3.5:9b). Puedes cambiar de Mac más tarde reinstalando."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="La importación de GDPR tuvo errores. Puedes volver a ejecutarla con:"
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="La importación de GDPR forma parte de la instalación productizada. Sin ella, tu grafo social (LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google Calendar) no se puede importar."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="La importación de GDPR no estará disponible en esta instancia hasta que se reinstale la canalización de importación."
MSG_WARN_GIT_SAID="Git dijo:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  Comprobación de estado fallida: ostler-knowledge --version no produjo salida."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  Comprobación de estado fallida: el motor de memoria de conversaciones no pudo cargarse (pwg-convo o el import de su pipeline no devolvió correctamente)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="El instalador de Homebrew terminó con %s. A continuación, las últimas 30 líneas de /tmp/ostler-brew-install.log:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Registro de instalación de Homebrew (final) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="La instalación de pip de Doctor terminó con %s. A continuación, las últimas 30 líneas de /tmp/ostler-doctor-pip.log:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Registro de instalación de pip de Doctor (final) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="La instalación de pip de la canalización terminó con %s. A continuación, las últimas 30 líneas de /tmp/ostler-pipeline-pip.log:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- Registro de instalación de pip de la canalización (final) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Falló la instalación del LaunchAgent de energía del Hub. Consulta la salida de arriba."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="No se encontraron los scripts de energía del Hub en la ruta esperada del paquete."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  Al .app del instalador parece faltarle vendor/hub_power/"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  en Contents/Resources/hub-power/. No se instalará la regulación según la batería; el resto de la instalación continuará."
MSG_WARN_ICAL_SERVER_FAILED="No se pudo iniciar la API del asistente; los endpoints de la iOS Companion serán limitados hasta la próxima ejecución de la instalación."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - Falló la descarga de la imagen (red, espacio en disco o tiempo de espera del registro)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="No se pudo escribir la señal de FDA de iMessage en pipeline_signals.json. El panel de Doctor puede que no muestre automáticamente la tarjeta de Full Disk Access."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="El host de IMAP está vacío; inténtalo de nuevo."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="Permiso de automatización de iMessage: no concedido (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="Permiso de automatización de iMessage: sondeo no concluyente."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="Abriendo Ajustes del Sistema > Privacidad y Seguridad > Automatización. Marca la fila de Messages para OstlerInstaller (o Terminal) para conectar la entrega de iMessage."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage necesita al menos un contacto permitido. Inténtalo de nuevo o"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="Canalización de importación no disponible (repositorio privado: solo probadores beta)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="La canalización de importación no viene incluida con el instalador. Se omitió el fallo crítico."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="La canalización de importación no viene incluida con el instalador. Esta es la ruta de instalación productizada; el paquete de Python contact_syncer debería venir dentro del paquete .app."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX significa que el asistente leerá todos los correos que recibas."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Disco insuficiente para el volumen de salida de la wiki"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Mac con Intel detectado: el rendimiento será limitado. Se recomienda Apple Silicon."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s es un host de un proveedor de nube."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="El JWT_SECRET en %s está en la lista de bloqueo; regenerándolo para que los servicios del grafo de conocimiento se puedan importar"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="El JWT_SECRET en %s es demasiado corto (%s < %s caracteres); regenerándolo"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="Se clonó el repositorio de conocimiento pero falta pyproject.toml; se omite la configuración del venv."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="Falló la instalación del servicio de conocimiento (clonado)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="Licencia: %s se distribuye bajo los Términos de Uso de Gemma de Google, no Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="Las instalaciones en MacBook necesitan esto para la gestión de batería / suspensión."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="El permiso de Contactos de macOS se rechazó o todavía no se ha concedido."
MSG_WARN_MACOS_OUTDATED_WE_RECOMMEND_MACOS_13="macOS %s está desactualizado. Recomendamos macOS 13 (Ventura) o posterior."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS NO lo pedirá desde un script: tienes que concederlo manualmente."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Las instalaciones en Mac Mini no se ven afectadas; los usuarios de MacBook deberían reintentar."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="Los datos de correo todavía se pueden ingerir manualmente:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  Reintento manual: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  Reintento manual una vez resuelta la causa:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="No se seleccionó ni Apple Mail ni IMAP personalizado; usando Apple Mail por defecto."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="No se ha establecido ninguna clave de acceso; las bases de datos no se cifrarán."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="Las frases de contraseña no coinciden. Inténtalo de nuevo."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="Falló la configuración de la frase de contraseña. Salida:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="Entrada vacía. Frase de contraseña omitida."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="La frase de contraseña debe tener al menos 12 caracteres. Inténtalo de nuevo."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="Se necesita una frase de contraseña para cifrar tus datos."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="El número debe empezar por +. Inténtalo de nuevo."
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama no responde"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s falló (intento %s/3). Reintentando en %ss..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="Solo quedan %s GB libres. Recomendamos al menos 35 GB (imágenes de Docker + modelo de IA + datos)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="Con batería, el LaunchAgent de energía del Hub (paso 3.14) puede pausarse"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="o vuelve a ejecutar el instalador y elige una opción de canal diferente."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="o vas por delante de la canalización de releases de la fase B. Vuelve a ejecutar el instalador cuando la"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor informó de %s error(es)."
MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant se extrajo pero falló la comprobación de --version."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Falló la instalación del LaunchAgent del asistente de Ostler tras 3 intentos. Salida de diagnóstico arriba + abajo."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Falló el intento %s de instalación del LaunchAgent del asistente de Ostler; reintentando."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="stderr completo del daemon en: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="Último stderr del snippet:"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s solo funciona en Apple Silicon (detectado: %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - la imagen ostler-wiki-compiler todavía no se puede descargar (registro no conectado)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph no responde"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph todavía no está en buen estado en esta fase (revisa los registros de arriba)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="Las contraseñas no coincidían (o estaban vacías). Inténtalo de nuevo."
# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="The main install typically takes 30 to 60 minutes (Docker + Ollama downloads + first-time setup) and can run longer on a slower connection. Long quiet stretches are normal – it is downloading and setting up in the background, not stuck."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  falló la instalación de pip; el motor de memoria de conversaciones no estará disponible."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  falló la instalación de pip; la ingesta de correo recurrirá al python del sistema (que también puede fallar en tiempo de ejecución)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  falló la instalación de pip; ostler-knowledge no estará disponible."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  falló la instalación de pip; el motor de ingesta de correo no está disponible. El LaunchAgent horario seguirá generando archivos mbox pero no podrá ingerirlos en el grafo hasta que esto se repare."
MSG_WARN_CM021_SOURCE_NOT_FOUND="No se encontró la fuente del motor de ingesta de correo en el paquete de la app; el trabajo en segundo plano horario guardará los archivos de correo sin ingerirlos."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="No se encontró la fuente de ostler_fda en el paquete de la app; el LaunchAgent de ingesta de correo recurrirá al python del sistema en tiempo de ejecución."
MSG_WARN_PIP_SAID="pip dijo:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="Conéctate a la corriente CA para la instalación completa."
MSG_WARN_PORT_1_ALREADY_USE_PID="El puerto %s ya está en uso por %s (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - El puerto 3000 ya está en uso por otro servicio"
MSG_WARN_POWER_SOURCE="Fuente de energía: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="Falló la instalación de sqlcipher3."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="Falló la instalación de sqlcipher3. Las bases de datos no se cifrarán."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="No se encontró Python 3. Instalando Python 3.12..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s es demasiado antiguo (se necesita 3.10+). Instalando Python 3.12..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant no responde"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         Lee https://ai.google.dev/gemma/terms antes de un uso comercial."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="Lee la versión pública en https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis no responde"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="se publique la release, o prepara el binario manualmente:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="Reejecutando: escribe un host autoalojado, o pulsa Ctrl-C y vuelve a lanzar eligiendo Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="vuelve a ejecutar el instalador con iMessage desmarcado para omitirlo."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="EJECUTANDO CON --allow-plaintext: cifrado desactivado. NO APTO PARA PRODUCCIÓN."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  Ejecuta \`%s doctor\` después del primer arranque"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="Ejecuta 'tailscale ip --4' una vez que hayas iniciado sesión, y luego añade la dirección a la app de iOS."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Falló la copia de la extensión de Safari; puedes instalarla manualmente más tarde"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="No se encontró el módulo de seguridad. Se omitirá la configuración de la clave de acceso."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  Se buscó en: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  Esto suele significar que el .app del instalador se compiló sin"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  el paquete ostler_security vendorizado incluido en"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Vuelve a descargar el instalador o"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  vuelve a ejecutar con --allow-plaintext para una instalación de dev/CI."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="Falló la configuración de seguridad. Continuando sin cifrado de la base de datos."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="Falló la configuración de seguridad. Salida:"
MSG_WARN_SEE_STDERR_FRAGMENT="  Consulta %s para ver el fragmento de stderr."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="Se omite la instalación del binario. El config.toml escrito por el asistente permanece en su sitio."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Se omite la instalación del LaunchAgent de Doctor."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="Se omite la instalación del LaunchAgent de ingesta de correo."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="Se omite la instalación del LaunchAgent. Las instalaciones en Mac Mini no se ven afectadas."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="Se omite la instalación del LaunchAgent. Prueba: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="Se omite la instalación del LaunchAgent de recompilación de la wiki."
MSG_WARN_SOME_FEATURES_MAY_NOT_WORK_CORRECTLY="Es posible que algunas funciones no funcionen correctamente en versiones anteriores."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="Algunos puertos están en uso. Los contenedores de Docker pueden fallar al iniciarse."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="Detén los servicios en conflicto o cambia los puertos en docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscale no inició sesión en 3 minutos. Puedes volver a esto más tarde desde Ajustes."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="La IP de Tailscale se escribió en .env pero una lectura posterior no pudo verla. La iOS Companion puede que no la recoja: vuelve a ejecutar install.sh --repair si eso ocurre."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="Falló la instalación de Tailscale: puedes instalarlo más tarde desde tailscale.com"
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="los servicios desplegados se niegan a iniciarse sin ellos."
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  esto se resuelva. Consulta el banner de próximos pasos para la solución."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  para inspeccionar. cron-delivery / imessage-tcc son comunes"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  Prueba: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  Prueba: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="Opción no reconocida '%s'; usando iMessage + correo por defecto."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="Opción no reconocida. Usando la recomendada."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  Falló la actualización; continuando con el checkout existente."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="Usa Apple Mail (recomendado arriba) para esa cuenta: Ostler nunca almacena contraseñas de la nube."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="Usando INBOX. El asistente leerá todos los correos entrantes."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="El contenedor de Vane se inició pero http://localhost:3000 no respondió en 60s."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane (búsqueda web local) no pudo iniciarse. Causas habituales:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  La búsqueda web es opcional; el resto de Ostler funciona sin ella."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="Recomendamos encarecidamente una etiqueta/carpeta dedicada en su lugar."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp necesita un número de teléfono para la entrega de resúmenes. Inténtalo de nuevo,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="La wiki se compiló pero el contenedor wiki-site falló al iniciarse."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="Falló la primera compilación de la wiki. Causas habituales:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="No se pudo cargar el LaunchAgent de puesta al día de la wiki del primer día. La reconstrucción diaria de la wiki sigue ejecutándose; tu wiki simplemente se actualizará al día siguiente en lugar de en la primera hora."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Falló la instalación del LaunchAgent de recompilación de la wiki. Consulta la salida de arriba."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="La wiki no se actualizará automáticamente; la reconstrucción manual sigue disponible:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="La configuración del asistente permanece en su sitio; el binario sigue preparado. Reintento manual:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="Tu asistente necesita un nombre. Elige una de las sugerencias de arriba o escribe el tuyo."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="Puedes volver a concederlo en Ajustes del Sistema > Privacidad y Seguridad > Contactos."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="Puedes ejecutar la configuración de seguridad más tarde: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="Puede que necesites instalarlo manualmente: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  real:     %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="El paquete de Ostler RemoteCapture no estaba presente en %s tras la extracción. El tarball de la release puede estar dañado."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify informó de:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  Se rechaza preparar un paquete que no coincide con la suma de comprobación publicada."
MSG_ERR_CM042_SHA_256_MISMATCH="El SHA-256 del tarball de Ostler RemoteCapture no coincide."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess informó de:"
MSG_ERR_CM042_VERIFY_FAILED="Falló la verificación de la firma / notarización de Ostler RemoteCapture."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv informó de:"
MSG_ERR_EXPECTED="  esperado: %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief informó de: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="El binario ostler-assistant en %s no es un ejecutable Mach-O."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="El SHA-256 del tarball de ostler-assistant no coincide."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  Se rechaza preparar un binario que no coincide con la suma de comprobación publicada."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="Se rechaza eliminar la cuarentena o cargar el LaunchAgent."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="Vuelve a ejecutar el instalador cuando se arregle el tarball original."
MSG_ERR_URL="  url:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Los Mac con Intel no son compatibles en v1.0. Se requiere Apple Silicon (M1, M2, M3 o M4). El soporte para Intel llegará en v1.0.1."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="Se requieren al menos 16 GB de RAM. Tienes %s GB. Se recomiendan 24 GB."
MSG_FAIL_CM042_SIGNATURE_FAILED="Instalación de Ostler RemoteCapture abortada: falló la comprobación de la firma o la notarización. El paquete se dejó en /Applications para el equipo de soporte. Escribe a support@ostler.ai y vuelve a ejecutar el instalador."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="No se pudo descargar %s tras 3 intentos. Comprueba tu red y vuelve a ejecutar el instalador."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="No se pudo descargar nomic-embed-text tras 3 intentos. Comprueba tu red y vuelve a ejecutar el instalador."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker no está disponible. Vuelve a ejecutar el instalador para instalar Colima."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="Falta el módulo de extracción de FDA en el paquete del instalador. Vuelve a descargar el .app desde ostler.ai/install, o vuelve a ejecutar con --allow-plaintext para dev/CI."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Falló la instalación de las dependencias de Doctor. La salida completa se guardó en /tmp/ostler-doctor-pip.log: adjúntalo cuando escribas a support@ostler.ai (Referencia: ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="Falló la instalación de las dependencias de la canalización de importación. La salida completa se guardó en /tmp/ostler-pipeline-pip.log: adjúntalo cuando escribas a support@ostler.ai (Referencia: ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Falló la instalación de Homebrew. La salida completa se guardó en /tmp/ostler-brew-install.log: adjúntalo cuando escribas a support@ostler.ai."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="Falló la instalación de la canalización de importación. El paquete contact_syncer es necesario para la instalación productizada. Vuelve a ejecutar con --allow-plaintext para dev/CI, o vuelve a descargar el instalador e inténtalo de nuevo."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="Se necesita acceso sudo para desactivar la suspensión + instalar Homebrew. Vuelve a ejecutar cuando estés listo."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Ni Colima ni Docker Desktop pudieron iniciarse. Instala Docker Desktop y vuelve a ejecutar."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="No hay suficiente espacio en disco (%s GB). Libera espacio e inténtalo de nuevo."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="No se ha establecido ninguna clave de acceso y no hay configuración de seguridad existente. Vuelve a ejecutar con --allow-plaintext para dev/CI, o vuelve a ejecutar el instalador y confirma la información de Touch ID."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="El motor de memoria de conversaciones es necesario. Vuelve a ejecutar con --allow-plaintext para dev/CI, o arregla el paquete que falta arriba y reinténtalo."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="Falló la instalación de ostler_security. Vuelve a ejecutar con --allow-plaintext para dev/CI, o arregla el error de pip de arriba y reinténtalo."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="Falló la configuración de la clave de acceso. Vuelve a ejecutar con --allow-plaintext para dev/CI, o arregla el error de arriba y reinténtalo."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="sqlcipher3 es necesario para las bases de datos cifradas. Vuelve a ejecutar con --allow-plaintext para dev/CI, o arregla el error de pip de arriba y reinténtalo."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Este instalador es solo para macOS. El soporte para Linux llegará pronto."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="La instalación de las Herramientas de Línea de Comandos de Xcode no se completó en 15 minutos. Abre Terminal y ejecuta 'xcode-select --install', haz clic en Instalar en el diálogo de macOS, espera a que termine y vuelve a ejecutar este instalador."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="La instalación de Homebrew informó de éxito pero falta /opt/homebrew/bin/brew. Revisa %s para ver la transcripción completa. Recuperación: abre Terminal y ejecuta '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' y luego vuelve a ejecutar el instalador."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew está instalado en /opt/homebrew/bin/brew pero el comando 'brew' no está en el PATH tras evaluar shellenv. Abre un Terminal nuevo y vuelve a ejecutar el instalador."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' informó de éxito pero colima no está en el PATH. Revisa %s en busca de fallos de Homebrew. Recuperación: abre Terminal y ejecuta 'brew install colima docker docker-compose' manualmente, y luego vuelve a ejecutar el instalador."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' informó de éxito pero la CLI de docker no está en el PATH. Revisa %s. Recuperación: 'brew install docker' manualmente y luego vuelve a ejecutar el instalador."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="La instalación de la app de Ollama informó de éxito pero falta su binario en /Applications/Ollama.app. Revisa %s. Recuperación: 'brew install --cask ollama-app' manualmente y luego vuelve a ejecutar el instalador."
MSG_FAIL_EMBED_HEALTHCHECK="Ollama está en ejecución pero el modelo de embeddings no devolvió ningún vector (HTTP distinto de 200, o un resultado vacío). La tarjeta de Personas, la búsqueda y la navegación estarían todas vacías. Revisa %s. Recuperación: asegúrate de que está instalada y sirviendo la app de Ollama (no la fórmula de Homebrew), y luego vuelve a ejecutar el instalador."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' informó de éxito pero sqlcipher no está en el PATH. Revisa %s. Recuperación: 'brew install sqlcipher' manualmente y luego vuelve a ejecutar el instalador."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' no produjo /Applications/Tailscale.app. Revisa %s. Recuperación: descarga Tailscale desde https://tailscale.com/download/macos y arrástralo a /Applications, y luego vuelve a ejecutar el instalador."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' informó de éxito pero falta el binario python3.11 en /opt/homebrew/opt/python@3.11/bin/python3.11. Revisa %s. Recuperación: 'brew reinstall python@3.11' y luego vuelve a ejecutar el instalador."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="Encontramos tus respuestas anteriores"
MSG_PROMPT_REUSE_SETTINGS_HELP="Detectamos un intento de instalación anterior en este Mac. Las preguntas que ya respondiste (nombre, nombre del asistente, zona horaria, código de país, canales, etc.) se reutilizarán para que no tengas que volver a introducirlas. Elige Sí para continuar donde lo dejaste, o No para volver a recorrer las preguntas desde el principio."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Respuestas anteriores que encontramos: nombre = %s, asistente = %s, zona horaria = %s."

MSG_PROMPT_PERMS_OK_TITLE="¿Listo para continuar?"
MSG_PROMPT_PERMS_OK_HELP="macOS pedirá acceso a Contactos y a Archivos y Carpetas. El Full Disk Access opcional se puede conceder más tarde."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Nombre completo (tal y como aparece en tus contactos)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Nombre completo (p. ej. Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="¿Cómo debería llamarte tu asistente?"
MSG_PROMPT_USER_ID_HELP="Un nombre corto que tu asistente usará para dirigirse a ti (p. ej. 'Andy', 'Andrew', 'Sra. Smith'). Es lo que aparece en tus resúmenes matutinos y respuestas de chat. Distinto de tu nombre completo de arriba."

# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="Installing in the background (about 15 to 60 minutes)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="¿Usar +%s?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Introduce el código de país (p. ej. 44 para Reino Unido, 1 para EE. UU.)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Código de país por defecto"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Se usa para normalizar los números de teléfono durante la importación de contactos y para definir tu región (Reino Unido / UE / EE. UU. / otra) para los valores por defecto de cumplimiento legal."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="Detectamos +%s. ¿Usarlo para tu Hub?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Detectado a partir de tu número de teléfono de arriba. Elige Sí para usarlo, o No para introducir un código de país diferente."

MSG_PROMPT_TZ_CONFIRM_TITLE="¿Usar esta zona horaria?"
MSG_PROMPT_TZ_CONFIRM_HELP="Zona horaria detectada: %s"
MSG_PROMPT_USER_TZ_TITLE="Introduce la zona horaria (p. ej. Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="¿Cómo te gustaría llamar a tu asistente?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="El nombre del campo es una sugerencia aleatoria: escribe encima lo que quieras. Marvin, Samantha, Joshua, Friday, Athena, Sage y Rosie son todas opciones populares." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Escribe el nombre que quieras: la sugerencia es solo un punto de partida."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="¿Cómo te localizará tu asistente?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Elige los canales de mensajería que te gustaría que usara tu asistente. Puedes cambiarlo más tarde en la sección Doctor de la app."

MSG_PROMPT_WHATSAPP_CONSENT_TITLE="¿Habilitar la mensajería de WhatsApp para tu asistente?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web es un servicio de terceros. Al habilitarlo, aceptas que tus mensajes pasen por la propia infraestructura de WhatsApp antes de llegar a tu instancia local de Ostler, y que WhatsApp (Meta Platforms Ireland Ltd) pueda suspender, restringir o cancelar tu cuenta de WhatsApp por un uso automatizado. Puedes desactivarlo más tarde desde Ajustes."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="Tu número de teléfono de WhatsApp"
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Número internacional con el código de país, p. ej. +44 7700 900123. Solo dígitos y un + inicial: sin espacios, paréntesis ni guiones."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Permitir que Ostler lea tus Messages"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="Ajustes del Sistema está abierto en Full Disk Access."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Busca \"Ostler\" y actívalo."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="Haz clic en Hecho cuando termines."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Hecho"

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Permitir que Ostler lea los datos de tu Mac"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="Ajustes del Sistema está abierto en Full Disk Access."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Busca \"OstlerInstaller\" en la lista y actívalo."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Haz clic en Hecho cuando termines y Ostler leerá tu historial de Safari, Notas, iMessages y Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Hecho"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="A continuación: Full Disk Access para el instalador"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="A continuación, macOS te pedirá que concedas Full Disk Access a OstlerInstaller."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Después de activar el interruptor, macOS mostrará un diálogo pidiéndote que elijas 'Salir y reabrir' o 'Más tarde'."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Haz clic en Salir y reabrir. El instalador se relanzará solo y continuará desde este paso automáticamente."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="Aceptar"
MSG_INFO_INSTALLER_FDA_PREWARN="Explicándote el flujo de concesión de Full Disk Access..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="Abriendo Ajustes del Sistema para que puedas conceder Full Disk Access al instalador..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="Full Disk Access concedido al instalador. A continuación, leyendo Safari, Notas, iMessages y Mail."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="Full Disk Access todavía no concedido. Continuando sin él; puedes volver a ejecutar el instalador más tarde para extraer Safari / Notas / iMessages."

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="Contactos permitidos"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="Personas de confianza: números de teléfono y correos de Apple ID (separados por comas). %s solo responde a las personas de esta lista; los mensajes de cualquier otra persona se ignoran. Se requiere al menos una entrada.

Por ejemplo:
+447700900000, tu@ejemplo.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="¿Leer el correo mediante Apple Mail?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Lee cualquier cuenta de correo que hayas añadido a Apple Mail (iCloud, Gmail, Outlook, etc.) usando Full Disk Access. No se almacenan contraseñas. Recomendado para casi todo el mundo."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="¿Añadir una cuenta de correo a Apple Mail?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="Apple Mail todavía no tiene ninguna cuenta conectada en este Mac, así que Ostler no tendrá ningún correo que leer. Elige Sí para abrir ahora Ajustes del Sistema > Cuentas de Internet (ahí puedes añadir iCloud, Gmail u Outlook). Elige No para omitirlo; puedes añadir una cuenta más tarde y Doctor mostrará un aviso de seguimiento si no llega ningún correo en 24 horas."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="¿Recuperar todo tu historial de Apple Mail?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Por defecto Ostler lee los últimos cinco años de tu Apple Mail. Si guardas más que eso en este Mac y quieres todo en tu grafo de conocimiento, elige Sí para recuperar ahora todo el historial local (esto puede tardar un poco más en un buzón grande). Elige No para mantener la ventana de cinco años; siempre puedes ampliarla más tarde desde Doctor."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="¿Configurar también un servidor IMAP+SMTP personalizado?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="Solo para buzones autoalojados. Déjalo en NO si tus cuentas son de Gmail, iCloud u Outlook: esas funcionan mejor mediante Apple Mail arriba."

MSG_PROMPT_IMAP_HOST_TITLE="Host de IMAP"
MSG_PROMPT_IMAP_HOST_HELP="Solo servidor IMAP autoalojado o personalizado. Usa Apple Mail (arriba) para Gmail / iCloud / Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="Puerto de IMAP"

MSG_PROMPT_SMTP_HOST_TITLE="Host de SMTP"
MSG_PROMPT_SMTP_PORT_TITLE="Puerto de SMTP"

MSG_PROMPT_EMAIL_USERNAME_TITLE="Dirección de correo (también se usa como nombre de usuario de IMAP/SMTP)"

MSG_PROMPT_EMAIL_PASSWORD_TITLE="Contraseña (oculta)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Contraseña de tu servidor IMAP/SMTP autoalojado. Se almacena localmente en ~/.ostler/: nunca se envía a Creative Machines."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Confirmar contraseña"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="¿Qué carpeta debería vigilar el asistente?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="Recomendado: una etiqueta o carpeta dedicada (p. ej. Ostler). Solo leeremos los mensajes de ahí, dejando tu bandeja de entrada principal intacta."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="Escribe INBOX otra vez para confirmar, o pulsa Continuar para usar 'Ostler'"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX significa que el asistente leerá todos los correos que recibas. Recomendamos encarecidamente una etiqueta/carpeta dedicada en su lugar."

MSG_PROMPT_EXPORTS_ACK_TITLE="¿Has solicitado tus exportaciones de datos?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler importa desde alrededor de 20 plataformas. La lista completa, con enlaces directos a la página de solicitud de cada proveedor, está en docs.ostler.ai/data-exports.

La mayoría de los archivos tardan de 1 a 3 días en llegar por correo. Cuando lleguen los ZIP, déjalos en tu carpeta de Descargas y Ostler los encontrará automáticamente.

Omite los que no uses; siempre puedes importar más tarde."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="¿Continuar sin FileVault?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="FileVault es muy recomendable. Sin él, el acceso físico a tu Mac significa acceso a tus datos."

MSG_PROMPT_PASSKEY_ACK_TITLE="Listo para configurar el cifrado del disco"
MSG_PROMPT_PASSKEY_ACK_HELP="Tu grafo de conocimiento se cifra con una frase de contraseña que eliges en la pantalla siguiente. Escribirás esta frase de contraseña cada vez que inicies la interfaz del Hub. También se genera una clave de recuperación aparte que se muestra una sola vez al final de la instalación. Pulsa Continuar cuando estés listo."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="¿Establecer también una frase de contraseña de recuperación? (recomendado)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="Elige tu frase de contraseña"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="Esta frase de contraseña cifra tu grafo de conocimiento y desbloquea la interfaz del Hub en cada arranque. Al menos 12 caracteres. No podemos recuperarla por ti. Se recomienda guardarla en un gestor de contraseñas."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="Confirma tu frase de contraseña"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="Vuelve a introducir la misma frase de contraseña para confirmar."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="¿Importar estos durante la instalación?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="Las exportaciones de GDPR encontradas se importarán a tu grafo de conocimiento durante la instalación."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="¿Tienes exportaciones de datos listas?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler puede importar archivos de redes sociales y plataformas (tu historial completo con amigos, familia, lugares, opiniones) desde el principio. Cuanto más sepa Ostler el primer día, más útil es el primer día. También puedes añadir esto más tarde; sin prisa.

Solicita tu exportación de datos a cada plataforma (Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp, etc.), descarga los archivos ZIP y déjalos en tu carpeta de Descargas.

Ostler buscará en ~/Downloads por defecto. ¿Quieres otra carpeta? Elige una abajo. Si no, omítelo e importa más tarde."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="¿Importar los mensajes de Gmail de este Takeout?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Lee el contenido de Gmail directamente del archivo de Takeout. Google nunca ve Ostler."

MSG_PROMPT_FDA_PRESET_TITLE="¿De qué fuentes del Mac debería aprender Ostler?"
MSG_PROMPT_FDA_PRESET_HELP="Tres preajustes, o elige cada uno tú mismo. Las fuentes sensibles (reconocimiento facial) están desactivadas por defecto en todos los preajustes: elígelas deliberadamente si las quieres."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="Recomendado. Incluye Apple Mail, Contactos, Calendario, Notas, Messages, Recordatorios, historial de Safari y marcadores de Safari. El historial de WhatsApp Desktop y el historial de Chrome se añaden automáticamente cuando la app está instalada. Excluye los datos de reconocimiento facial de Fotos y cualquier archivo de exportación de terceros."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="Todo. Recomendado + eventos de Fotos (sin reconocimiento facial). El reconocimiento facial de Fotos permanece desactivado hasta que lo marques deliberadamente."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="Personalizar. Elige cada fuente en la pantalla siguiente. Las fuentes sensibles permanecen desactivadas hasta que las marques."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="Activa o desactiva esta fuente de datos."

MSG_PROMPT_CONSENT_ARTICLE_9_TITLE="Tu decisión (S / N)"
MSG_PROMPT_CONSENT_ARTICLE_9_HELP="Consentimiento de categoría especial del Artículo 9 (UK GDPR). Necesario para la base jurídica del tratamiento."

MSG_PROMPT_CONSENT_VOICE_EU_TITLE="¿Reconocer voces en tus grabaciones de llamadas?"
MSG_PROMPT_CONSENT_VOICE_EU_HELP="El reconocimiento de voz permanece en este Mac. Creative Machines nunca recibe las huellas."

MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE="Una última cosa: cómo funcionan los datos de terceros"
MSG_PROMPT_CONSENT_THIRD_PARTY_HELP="Cualquier dato que importes de terceros (Google Takeout, descargas de Meta, exportaciones de LinkedIn, etc.) permanece en este Mac. Ostler lo almacena en tu grafo de conocimiento local; nada sale de tu dispositivo.

Al continuar entiendes y aceptas que eres el único responsable del tratamiento y la conservación de estos datos en tu máquina, igual que los mensajes de correo que ya están en tu disco duro.

Nota legal: Para los registros que importes a este Mac, eres el responsable del tratamiento bajo la ley del Reino Unido y la UE (UK GDPR Artículo 4(7) y 4(8)). Creative Machines nunca recibe estos datos y no es el responsable. Tu tratamiento con fines personales y domésticos queda dentro del UK/EU GDPR Artículo 2(2)(c).

Más información en docs.ostler.ai/privacy/third-party-data."

MSG_PROMPT_CONSENT_INSTALL_TITLE="¿Listo para instalar?"
MSG_PROMPT_CONSENT_INSTALL_HELP="Escribe INSTALL para confirmar que aceptas los términos."
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Escribe INSTALL"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Instalar Ostler"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Cancelar"
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Escribe INSTALL exactamente (no importan las mayúsculas) para confirmar, o haz clic en Cancelar para volver atrás."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="Conecta tu iPhone y tu Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale le da a este Mac una dirección privada estable que tu iPhone y tu Watch pueden alcanzar desde cualquier lugar: cifrada, sin exposición pública."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="¿Guardar la clave de recuperación en el Llavero?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="Almacena tu clave de recuperación de cifrado en el Llavero de macOS para mayor seguridad."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="Hidratando tu grafo"
MSG_HYDRATE_CONTACTS_STARTED="Importando tus contactos al grafo"
MSG_HYDRATE_CONTACTS_DONE="%s contactos importados"
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="Cargando tus últimos 90 días de calendario (el historial más antiguo se rellena en segundo plano)"
MSG_HYDRATE_CALENDAR_DONE="%s eventos importados"
MSG_HYDRATE_WIKI_RECOMPILE="Construyendo tu wiki. Ostler está escribiendo un resumen corto para cada una de tus personas, organizaciones y temas clave, así que en una agenda de contactos grande esto puede tardar desde unos minutos hasta alrededor de una hora. Solo ocurre una vez, se ejecuta enteramente en tu Mac y es seguro dejarlo."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="Comprobando tu índice de búsqueda (%s colecciones detectadas)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="Cargando tu historial de navegación en el índice de búsqueda"
MSG_INITIAL_HYDRATE_QDRANT_READY="Índice de búsqueda listo (%s colecciones)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="El índice de búsqueda se rellenará en segundo plano una vez que termine la instalación"
MSG_HYDRATE_DONE="Tu grafo está listo: %s personas, %s eventos"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud puede que todavía esté sincronizando tus contactos: reexportando ahora para recoger lo que acabe de llegar."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="No se encontraron contactos en tu app Contactos (local ni iCloud). Añade algunos a Contactos y vuelve a ejecutar desde Ajustes."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="No hay contactos de iCloud que importar. Puedes añadir esto más tarde desde Ajustes."
MSG_HYDRATE_SKIPPED_NO_EVENTS="No hay eventos de calendario en los últimos 5 años. Puedes rellenarlos más tarde desde Ajustes."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="Leyendo tus últimos 90 días de correo: tus correos permanecen en este Mac (el historial más antiguo se rellena en segundo plano)"
MSG_HYDRATE_EMAIL_DONE="Se encontraron %s personas en tu correo reciente"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="No hay correo reciente que leer. Puedes añadir una cuenta de Mail en Apple Mail y volver a ejecutar más tarde."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="El lector de correo todavía no está listo. Puedes añadir una cuenta de Mail en Apple Mail y volver a ejecutar más tarde."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="El correo todavía se está cargando en segundo plano: tu wiki se irá completando a lo largo de la próxima hora."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="¿Abrir Apple Mail para que empiece a sincronizar?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="Tienes %s cuenta(s) de correo configurada(s), pero Apple Mail todavía no ha recuperado ningún mensaje. Podemos abrir Mail.app ahora y esperar mientras sincroniza."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="¿Abrir Calendario para que empiece a sincronizar?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="Tienes %s cuenta(s) de calendario configurada(s), pero Calendario.app todavía no tiene eventos almacenados. Podemos abrir Calendario ahora y esperar mientras sincroniza desde iCloud."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="¿Abrir Contactos para que empiece a sincronizar?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="Tienes %s cuenta(s) de contactos configurada(s), pero Contactos.app todavía no tiene entradas almacenadas. Podemos abrir Contactos ahora y esperar mientras sincroniza desde iCloud."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="Esperando a que %s empiece a sincronizar (hasta %s segundos)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="Sigo esperando la sincronización de %s (%ss transcurridos, %ss restantes). La primera sincronización de iCloud puede tardar unos minutos en un inicio de sesión nuevo."
MSG_OK_APP_HAS_POPULATED="%s ha rellenado su almacén local. Continuando."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="No detectamos la sincronización de %s dentro de la ventana de espera. Continuando; puedes volver a ejecutar la hidratación desde Ajustes más tarde."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="Cuentas de Apple Mail visibles: %s. Abre Mail.app una vez para que pueda empezar a recuperar mensajes."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="Cuentas de calendario visibles: %s. Abre Calendario.app una vez para que pueda sincronizar tus eventos."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="Cuentas de contactos visibles: %s. Abre Contactos.app una vez para que pueda sincronizar tu agenda."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="No se pudieron leer tus Contactos. Ostler los lee a través de Full Disk Access: concédelo en Ajustes del Sistema > Privacidad y Seguridad > Full Disk Access, y luego vuelve a ejecutar la hidratación desde Ajustes. Seguiremos reintentando en segundo plano."
MSG_HYDRATE_CONTACTS_PENDING="Tu app Contactos todavía no ha sincronizado. Abre Contactos una vez, espera a que sincronice y luego vuelve a ejecutar la hidratación desde Ajustes."
MSG_HYDRATE_CONTACTS_READ_FAILED="Tus contactos están en este Mac pero Ostler importó 0 de ellos, lo cual es inesperado. La importación se reintentará automáticamente en segundo plano. Si persiste, vuelve a ejecutar la hidratación desde Ajustes o revisa el registro de instalación."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler seguirá comprobando en segundo plano e importará tus contactos automáticamente una vez que iCloud termine de sincronizar."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="Nuevos contactos importados; reconstruyendo tu wiki en segundo plano."
MSG_HYDRATE_CALENDAR_PENDING="Tu app Calendario todavía no ha sincronizado eventos. Abre Calendario una vez, espera a que sincronice y luego vuelve a ejecutar la hidratación desde Ajustes."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="No se pudo leer tu calendario esta vez (el extractor informó de un error, no de un calendario vacío). Tus otros datos no se vieron afectados; consulta /tmp/ostler-hydrate-calendar.log y luego vuelve a ejecutar la hidratación desde Ajustes."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="Leyendo tu historial de WhatsApp: tus mensajes permanecen en este Mac"
MSG_HYDRATE_WHATSAPP_DONE="Se encontraron %s personas en tus chats de WhatsApp"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="No hay chats de WhatsApp que leer. Puedes volver a ejecutar más tarde desde Ajustes."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktop no está instalado. Instálalo desde la Mac App Store y vuelve a ejecutar desde Ajustes."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="El lector de WhatsApp todavía no está listo. Puedes volver a ejecutar más tarde desde Ajustes."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp todavía se está cargando en segundo plano: tu wiki se irá completando a lo largo de la próxima hora."

# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="Importando tu historial de navegación: tus visitas permanecen en este Mac"
MSG_HYDRATE_BROWSING_DONE="%s páginas de historial de navegación importadas"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="Se omitieron %s páginas marcadas como sensibles (banca, salud, etc.)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="No hay historial de navegación que importar. Puedes volver a ejecutar más tarde desde Ajustes."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="El lector del historial de navegación todavía no está listo. Puedes volver a ejecutar más tarde desde Ajustes."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="El historial de navegación todavía se está cargando en segundo plano: tu wiki se irá completando a lo largo de la próxima hora."

# Preferences import counts-only confirmation, shown by phase 3.12b after
# the shared ostler-import fan-out runs. The other hydrate_preferences
# strings were removed when the standalone block was collapsed into the
# shared importer; only this done-count line is still referenced.
# Privacy: enrich's lookup clients call PUBLIC item-metadata APIs only
# (about the item, never the user); this string is a count.
MSG_HYDRATE_PREFERENCES_DONE="Se importaron y enriquecieron %s preferencias"

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="Configurando el enriquecimiento de preferencias (única vez)"
MSG_CM019_SETUP_DONE="Enriquecimiento de preferencias listo"
MSG_CM019_SETUP_FAILED="La configuración del enriquecimiento de preferencias no terminó. Tus páginas de preferencias se completan una vez que se arregle; el resto de Ostler no se ve afectado."
MSG_CM019_SETUP_EXISTS="El enriquecimiento de preferencias ya está configurado"
MSG_CM019_SETUP_SKIPPED="La canalización de enriquecimiento de preferencias no viene incluida; se omite por ahora."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="Leyendo tu historial de iMessage: tus mensajes permanecen en este Mac"
MSG_HYDRATE_IMESSAGE_DONE="Se encontraron %s personas en tu historial de iMessage"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="No hay historial de iMessage que leer. Puedes volver a ejecutar más tarde desde Ajustes."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="El lector de iMessage todavía no está listo. Puedes volver a ejecutar más tarde desde Ajustes."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage todavía se está cargando en segundo plano: tu wiki se irá completando a lo largo de la próxima hora."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="Indexando tus personas para la búsqueda"
MSG_HYDRATE_PEOPLE_DONE="%s personas indexadas para la búsqueda"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="Todavía no hay personas que indexar. Puedes volver a ejecutar más tarde desde Ajustes."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="El indexador de personas todavía no está listo. Puedes volver a ejecutar más tarde desde Ajustes."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="Todavía indexando tus personas en segundo plano; la búsqueda se irá completando en breve."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="Vienen tres avisos de acceso a carpetas"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="El diálogo de las Herramientas de Línea de Comandos ha aparecido delante de esta ventana: haz clic en Instalar en él y luego vuelve aquí (o espera unos segundos, traeremos esta ventana al frente por ti). Las herramientas se descargan en segundo plano mientras sigues respondiendo las preguntas de abajo; aquí no se bloquea nada."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="Permiso necesario: automatización de iMessage"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostler pedirá ahora a macOS permiso para hablar con Messages.app. macOS mostrará una ventana emergente que dice \"OstlerInstaller quiere acceso para controlar Messages\": haz clic en Permitir para que el asistente pueda enviar y recibir iMessages en tu nombre. Sin este permiso, los iMessages nunca saldrán de la máquina en silencio. Es una concesión única; puedes cambiarla más tarde en Ajustes del Sistema > Privacidad y Seguridad > Automatización."

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
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="Apúntala o imprímela ahora. Es la única forma de volver a entrar si pierdes tu frase de contraseña Y tu Llavero queda inaccesible. Ostler no puede recuperarla por ti: la clave nunca sale de este Mac y no se almacena en ningún servidor."
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
MSG_INFO_PAIR_IPHONE_TITLE="Empareja tu iPhone"
MSG_INFO_PAIR_IPHONE_HELP="Abre la app Ostler en tu iPhone y escanea este código QR para vincularlo a este Hub. También puedes emparejar más tarde desde el menú de Ajustes del Hub."
MSG_INFO_PAIR_IPHONE_FETCHING="Generando el código de emparejamiento..."
MSG_INFO_PAIR_REFRESH="Actualizar código"
MSG_ERR_PAIR_FETCH_FAILED="Todavía no se pudo contactar con el gateway de Ostler. Puede que aún se esté iniciando: haz clic en Actualizar para volver a intentarlo."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agent no viene incluido con el instalador. El LaunchAgent de resúmenes diarios + keepalive de WhatsApp no se cargará."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Los scripts de recompilación de la wiki no vienen incluidos con el instalador. La wiki no se actualizará automáticamente."

# F3 - legal package missing
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="el paquete legal no viene incluido con el instalador. Las puertas de consentimiento del Artículo 9 / WhatsApp / voz lanzarán ModuleNotFoundError hasta que se reinstale."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s instalado en %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s ya está instalado, se deja en su sitio"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Arquitectura de CPU no compatible para Google Workspace CLI; las funciones de Gmail / Google Calendar quedan degradadas."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl no está disponible; se omite la instalación de Google Workspace CLI. Las funciones de Gmail / Google Calendar quedan degradadas."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="No se pudo descargar Google Workspace CLI desde %s"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="El SHA256 de Google Workspace CLI no coincide (esperado %s, obtenido %s). Abortando la instalación de este binario."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="No se pudo extraer el archivo de Google Workspace CLI."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI instalado en %s pero falló el sondeo de --version."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="Puente de calendario de iCloud / CalDAV instalado en %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="El puente de calendario de iCloud / CalDAV en %s no es ejecutable. El calendario no devolverá eventos."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh no viene incluido con el instalador. El reintento de registro de dispositivo en la próxima red está desactivado."

# ── Parity top-up 2026-07-12 (MACHINE DRAFT) ──
# Keys added to en-GB between the 2026-05-19 extraction and 2026-07-12.
# Machine-draft translations; review before shipping a localised installer.

MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="Docker no estuvo listo a tiempo para iniciar las bases de datos del grafo de conocimiento. Asegúrate de que Colima o Docker esté en ejecución y vuelve a ejecutar el instalador."

MSG_FAIL_GRAPH_DB_PULL_FAILED="No se pudieron descargar las imágenes de las bases de datos del grafo de conocimiento tras varios intentos. Suele ser un problema de red. Comprueba tu conexión a Internet y vuelve a ejecutar el instalador."

MSG_FAIL_GRAPH_DB_UP_FAILED="Las bases de datos del grafo de conocimiento se descargaron pero no se pudieron iniciar. Vuelve a ejecutar el instalador; si sigue ocurriendo, abre Terminal y ejecuta: cd ~/.ostler && docker compose up -d qdrant oxigraph redis"

MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="Se importaron %s contactos con números de teléfono pero casi sin direcciones de correo (%s teléfono frente a %s correo). Esto suele significar que el lector de contactos descartó los correos. Tus contactos siguen siendo utilizables; consulta /tmp/ostler-hydrate-contacts.log y vuelve a ejecutar la importación de datos desde Ajustes cuando esté resuelto."

MSG_HYDRATE_EMAIL_HEARTBEAT="  Todavía leyendo tu correo (%ss hasta ahora). Puede tardar un rato en un Mac con años de historial."

MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="Las preferencias de correo aún se están cargando en segundo plano. Tu wiki se completará en breve."

MSG_HYDRATE_EMAIL_PREFERENCES_DONE="Se cargaron %s preferencias de tu historial de correo"

MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  Todavía cargando tus preferencias de correo (%ss hasta ahora). Un historial grande puede tardar unos minutos."

MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="No hay ningún archivo de preferencias de correo configurado. Nada que cargar."

MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="No se encontró ningún archivo de preferencias de correo en %s. Nada que cargar."

MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="El pipeline de preferencias aún no está listo. Puedes volver a ejecutarlo más tarde desde Ajustes."

MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="Cargando tus preferencias de correo. Todo se queda en este Mac y puede tardar unos minutos."

MSG_HYDRATE_IMESSAGE_HEARTBEAT="  Todavía leyendo tu historial de iMessage (%ss hasta ahora). Un historial de mensajes grande puede tardar varios minutos."

MSG_HYDRATE_PLACES_DONE="Se creó tu sección Places"

MSG_HYDRATE_PLACES_ERROR_WARN="La construcción de Places no se completó (error inesperado). Tu página Places puede estar incompleta. Consulta /tmp/ostler-places-ingest.log"

MSG_HYDRATE_PLACES_GUARD_WARN="La construcción de Places encontró un problema: existen señales de ubicación pero no se generó ningún lugar. Tu página Places puede quedarse vacía. Consulta /tmp/ostler-places-ingest.log"

MSG_HYDRATE_PLACES_SKIPPED="Aún no se han encontrado señales de ubicación; Places se irá completando a medida que se llene tu calendario"

MSG_HYDRATE_PLACES_STARTED="Creando tus lugares (Places) a partir de los sitios donde te reúnes"

MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="Reiniciando el asistente para que detecte el Acceso total al disco que acabas de conceder (necesario para leer tu historial de Mensajes)."

MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="Un permiso más (historial de Mensajes para tu asistente) llega casi al final, una vez instalado tu asistente – te lo indicaremos entonces."

MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="Contactos duplicados fusionados por completo durante la instalación; no hace falta ponerse al día en segundo plano"

MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="La mayoría de los contactos duplicados se han fusionado. El resto terminará en segundo plano tras la instalación – tu wiki se actualizará automáticamente."

MSG_INFO_DEDUPE_MERGED="Contactos duplicados fusionados"

MSG_INFO_DEDUPE_STILL_MERGING="Todavía fusionando contactos duplicados – las agendas grandes pueden tardar varios minutos (%ss transcurridos)"

MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="Concede el acceso en Ajustes del Sistema > Privacidad y seguridad > Archivos y carpetas (o Acceso total al disco) y vuelve a ejecutar, o indica manualmente a Ostler tu carpeta de exportaciones abajo."

MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="No se pudieron examinar una o más carpetas en busca de exportaciones de datos porque macOS bloqueó el acceso. Concede el acceso y vuelve a ejecutar, o indícame manualmente tu carpeta de exportaciones."

MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="El Acceso total al disco para el instalador está listo. A partir de aquí, la instalación larga sigue sola – puedes irte."

MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="Instalando GNU coreutils (para límites de tiempo en pasos largos)..."

MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  Instalando la dependencia de almacenamiento cifrado en el venv de la memoria de conversaciones..."

MSG_INFO_PULLING_GRAPH_DB_IMAGES="Descargando las bases de datos del grafo de conocimiento (solo la primera vez). Puede tardar un minuto en una instalación nueva..."

MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="Queda un paso manual: abre Safari, elige Safari > Ajustes > Extensiones y marca Ostler para activarlo."

MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="Anotado – puedes irte mientras Ostler se instala. Casi al final hay un paso corto opcional: iniciar sesión en Tailscale para que tu iPhone y tu Watch puedan llegar a este Mac desde cualquier lugar. Entonces abriremos tu navegador."

MSG_MODELFIT_HEADER="Ajustando el modelo del asistente a tu Mac (%s, %s GB de RAM, contexto del asistente %s tokens):"

MSG_MODELFIT_PILL_FITS="Adecuado"

MSG_MODELFIT_PILL_NOFIT="No es adecuado"

MSG_MODELFIT_PILL_SLOW="Puede ser lento"

MSG_MODELFIT_RECOMMENDED_TAG="  <- Recomendado"

MSG_MODELFIT_ROW="  %s  %s (%s, %s)"

MSG_MODELFIT_SELECTED="Modelo de IA: %s (%s) – el que mejor se ajusta a tus %s GB de RAM con la ventana de contexto que requiere el asistente"

MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils instalado (los pasos largos ahora tienen un límite de tiempo)"

MSG_OK_DEDUPE_CATCHUP_LOADED="LaunchAgent de deduplicación de contactos en segundo plano cargado (termina de fusionar duplicados tras la instalación y luego se detiene)"

MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="Continuar"

MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostler está a punto de leer los datos de tu Mac, pero el Acceso total al disco para OstlerInstaller sigue desactivado. Busca \"OstlerInstaller\" en Ajustes del Sistema (abierto ahora en Acceso total al disco) y actívalo."

MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="O simplemente haz clic en Continuar para terminar la instalación con menos datos – puedes conceder el acceso y volver a ejecutar el extractor más tarde."

MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="Aún se necesita el Acceso total al disco"

# TODO(i18n): reworded in en-GB (#596/#573) -- needs human re-translation;
# en-GB text used until then so the install-time expectations stay honest.
MSG_STEP_SETUP_COMPLETE_WRAP_UP="Questions done. Ostler is now installing in the background – this part takes roughly 15 to 60 minutes and needs nothing further from you, so you can leave it running and check back later."

MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="No se pudo instalar GNU coreutils; los pasos largos se ejecutarán sin límite de tiempo (una línea de progreso sigue mostrando que están trabajando)."

MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="No se pudo cargar el LaunchAgent de deduplicación de contactos en segundo plano. Los duplicados se fusionarán igualmente en la pasada de mantenimiento diaria; simplemente tardará más en asentarse."

MSG_WARN_DEDUPE_INCOMPLETE="La pasada de deduplicación de todo el grafo no terminó limpiamente (ver %s); continuando"

MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="No se pudo leer %s para buscar exportaciones de datos. macOS está bloqueando el acceso a esa carpeta."

MSG_WARN_GRAPH_DB_PULL_RETRY="La descarga de la base de datos no terminó (intento %s de %s). Reintentando en %ss..."

MSG_WARN_GRAPH_DB_UP_RETRY="Las bases de datos del grafo de conocimiento no se iniciaron (intento %s de %s). Reintentando..."

MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  No se pudo instalar la dependencia de almacenamiento cifrado en el venv de la memoria de conversaciones; el enriquecimiento de conversaciones no se ejecutará."

MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  No se encontró la fuente de la dependencia de almacenamiento cifrado en SCRIPT_DIR; el motor de memoria de conversaciones no puede cargarse y el enriquecimiento de conversaciones no se ejecutará."

MSG_WARN_PREFS_HEADLINE_HINT="Esto suele significar que no había ninguna exportación de música/comida (Spotify, Apple Music, Uber Eats, Google Takeout), o que los datos no se categorizaron. Añade esas exportaciones, vuelve a ejecutar desde Ajustes y luego reconstruye el wiki."

MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="Se importaron %s preferencias, pero ninguna quedó en Food, Music o Professional. Tus páginas wiki de Food y Music estarán vacías."

MSG_WARN_PREFS_UNCATEGORISED="%s de %s preferencias (%s%%) no tienen categoría y no aparecerán en ninguna página de temas. Comprueba el formato de la exportación de origen."
