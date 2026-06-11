#!/usr/bin/env bash
# CM051 install.sh -- es (Spanish) strings catalogue
# Localisation pilot (v1.0.1). See:
#   HR015 launch/LOCALISATION_DESIGN_2026-06-04.md
#
# HOW THIS FILE IS USED
# ---------------------
# install.sh ALWAYS sources install.sh.strings.en-GB.sh first as the
# English base, then sources THIS file on top when the resolved locale
# is "es". Any MSG_* key NOT present here keeps its English value
# (per-key fallback). So this file only needs the strings a Spanish
# speaker actually sees during a normal first run; the long tail of
# rare/diagnostic strings inherits English until a translator gets to
# them. This is intentional: a partial translation never blanks a
# string and never breaks the installer.
#
# Run the installer in Spanish:   OSTLER_LANG=es  (or a Spanish macOS)
#
# TRANSLATOR NOTES
# ----------------
# - Keep the SAME number and ORDER of %s placeholders as the English
#   source. install.sh wraps these in printf "$KEY" "$arg1" ...
# - No em-dashes. Use periods, hyphens, or en-dashes (-).
# - Do not translate product names (Ostler, Ostler Pro, WhatsApp,
#   Apple Mail, Gmail, iCloud, Outlook, macOS, Tailscale, Homebrew,
#   Colima, Docker), command snippets, paths, or labels in quotes that
#   the customer must match in System Settings.
# - Lines tagged  # REVIEW(es): ...  are machine-assisted and want a
#   native-speaker pass before they ship to customers.
# - Spanish here uses the neutral usted register, suitable across
#   Spain and Latin America.

# ── Step (top-level phase) banners ──

MSG_STEP_CHECKING_PREREQUISITES="Comprobando requisitos previos"
MSG_STEP_RUNNING_HEALTH_CHECK="Ejecutando comprobacion de estado"
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="Configuracion (responda unas preguntas y luego dejelo trabajar)"
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="Instalando (puede tardar un rato. Puede alejarse mientras tanto)"

# ── Prerequisite checks ──

MSG_OK_MACOS_DETECTED="macOS %s detectado"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon detectado"
MSG_OK_GIT_AVAILABLE="Git disponible"
MSG_OK_HOMEBREW_INSTALLED="Homebrew instalado"
MSG_OK_OLLAMA_INSTALLED="Ollama instalado"
MSG_OK_EMBEDDING_MODEL_READY="Modelo de incrustaciones listo"
MSG_OK_ALREADY_AVAILABLE="%s ya disponible"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima y la CLI de Docker instaladas"

# ── First-run questions (the heart of the pilot) ──

MSG_PROMPT_PERMS_OK_TITLE="Listo para continuar?"
MSG_PROMPT_PERMS_OK_HELP="macOS le pedira acceso a Contactos y a Archivos y carpetas. El acceso opcional a todo el disco se puede conceder mas tarde."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Nombre completo (tal como aparece en sus contactos)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Nombre completo (por ejemplo, Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="Como quiere que le llame su asistente?"
MSG_PROMPT_USER_ID_HELP="Un nombre corto que su asistente usara para dirigirse a usted (por ejemplo, 'Ana', 'Andres', 'Sra. Lopez'). Es lo que aparece en sus resumenes matutinos y en las respuestas del chat. Es distinto del nombre completo de arriba."

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="Usar +%s?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Introduzca el codigo de pais (por ejemplo, 34 para Espana, 52 para Mexico)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Codigo de pais predeterminado"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Se usa para normalizar los numeros de telefono al importar contactos y para fijar su region (UE / EE. UU. / Reino Unido / otra) a efectos de los valores legales predeterminados."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="Hemos detectado +%s. Usarlo para su Hub?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Detectado a partir de su numero de telefono de arriba. Elija Si para usarlo, o No para introducir otro codigo de pais."

MSG_PROMPT_TZ_CONFIRM_TITLE="Usar esta zona horaria?"
MSG_PROMPT_TZ_CONFIRM_HELP="Zona horaria detectada: %s"
MSG_PROMPT_USER_TZ_TITLE="Introduzca la zona horaria (por ejemplo, Europe/Madrid, America/Mexico_City)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="Como le gustaria llamar a su asistente?"
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Escriba el nombre que quiera. La sugerencia es solo un punto de partida."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="Como le contactara su asistente?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Elija los canales de mensajeria que quiere que use su asistente. Puede cambiarlo mas tarde en la seccion Doctor de la aplicacion."

# REVIEW(es): legal consent wording. Native-speaker + legal pass before shipping.
MSG_PROMPT_WHATSAPP_CONSENT_TITLE="Activar la mensajeria de WhatsApp para su asistente?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web es un servicio de terceros. Al activarlo, acepta que sus mensajes pasen por la infraestructura de WhatsApp antes de llegar a su instancia local de Ostler, y que WhatsApp (Meta Platforms Ireland Ltd) pueda suspender, restringir o cancelar su cuenta de WhatsApp por el uso automatizado. Puede desactivarlo mas tarde en Ajustes."
MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="Su numero de telefono de WhatsApp"
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Numero internacional con el codigo de pais, por ejemplo +34 600 123 456. Solo digitos y un + inicial. Sin espacios, parentesis ni guiones."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Permitir que Ostler lea sus Mensajes"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="Ajustes del Sistema esta abierto en Acceso a todo el disco."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Busque \"Ostler\" y actívelo."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="Pulse Hecho cuando termine."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Hecho"
MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Permitir que Ostler lea los datos de su Mac"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="Ajustes del Sistema esta abierto en Acceso a todo el disco."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Busque \"OstlerInstaller\" en la lista y actívelo."
# REVIEW(es): long instruction, verify reads naturally.
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Pulse Hecho cuando termine y Ostler leera su historial de Safari, Notas, iMessages y Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Hecho"
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="A continuacion: Acceso a todo el disco para el instalador"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="A continuacion, macOS le pedira que conceda Acceso a todo el disco a OstlerInstaller."
# REVIEW(es): verify the System dialog button names match the Spanish macOS UI.
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Despues de activar el interruptor, macOS mostrara un dialogo pidiendole que elija 'Salir y reabrir' o 'Mas tarde'."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Pulse Salir y reabrir. El instalador se reiniciara solo y continuara desde este paso automaticamente."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="Aceptar"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="Leer el correo a traves de Apple Mail?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Lee cualquier cuenta de correo que haya anadido a Apple Mail (iCloud, Gmail, Outlook, etc.) mediante el Acceso a todo el disco. No se guardan contrasenas. Recomendado para casi todo el mundo."
MSG_PROMPT_EMAIL_PASSWORD_TITLE="Contrasena (oculta)"
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Confirmar contrasena"
MSG_PROMPT_IMAP_HOST_TITLE="Servidor IMAP"
MSG_PROMPT_IMAP_PORT_TITLE="Puerto IMAP"
MSG_PROMPT_SMTP_HOST_TITLE="Servidor SMTP"
MSG_PROMPT_SMTP_PORT_TITLE="Puerto SMTP"

MSG_PROMPT_REUSE_SETTINGS_TITLE="Hemos encontrado sus respuestas anteriores"
# REVIEW(es): long help paragraph, verify reads naturally.
MSG_PROMPT_REUSE_SETTINGS_HELP="Hemos detectado un intento de instalacion anterior en este Mac. Las preguntas que ya respondio (nombre, nombre del asistente, zona horaria, codigo de pais, canales, etc.) se reutilizaran para que no tenga que volver a introducirlas. Elija Si para continuar donde lo dejo, o No para responder las preguntas de nuevo desde el principio."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Respuestas anteriores encontradas: nombre = %s, asistente = %s, zona horaria = %s."

# ── Progress / completion messages a customer sees ──

MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Activando sus primeros 30 dias de Ostler Pro..."
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro activo durante 30 dias. Suscribase desde la aplicacion de iOS para continuar despues de la prueba."
MSG_OK_IMPORT_PIPELINE_READY="Canalizacion de importacion lista"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Dependencias de Doctor instaladas"
MSG_OK_GDPR_IMPORT_COMPLETE="Importacion conforme al RGPD completada"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker no esta instalado. Se instalaran Colima, la CLI de Docker y el complemento docker-compose (ligero, no requiere Docker Desktop)."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima esta instalado pero no en ejecucion. Se iniciara."

# ── Errors the customer can hit early ──

MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Este instalador es solo para macOS."
# REVIEW(es): keep "v1.0.1" wording consistent with English source.
MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Los Mac con Intel no son compatibles en la v1.0. Se requiere Apple Silicon (M1, M2, M3 o M4). La compatibilidad con Intel llegara en la v1.0.1."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="Se requieren al menos 16 GB de RAM. Usted tiene %s GB. Se recomiendan 24 GB."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="No hay suficiente espacio en disco (%s GB). Libere espacio y vuelva a intentarlo."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="Se necesita acceso de administrador (sudo) para desactivar el reposo e instalar Homebrew. Vuelva a ejecutarlo cuando este listo."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="No se pudo descargar %s tras 3 intentos. Compruebe su conexion y vuelva a ejecutar el instalador."
