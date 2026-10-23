#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to pt-PT by l10n/ostler_l10n.py.
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

MSG_STEP_CHECKING_PREREQUISITES="A verificar os pré-requisitos"
MSG_STEP_RUNNING_HEALTH_CHECK="A executar a verificação de estado"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="Ligue o iPhone e o Watch"
# NEEDS REVIEW: source asks for human translation of this key
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="Configuração (algumas perguntas rápidas e depois continua sozinho)"
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
# NEEDS REVIEW: source asks for human translation of this key
MSG_STEP_SETUP_COMPLETE_WRAP_UP="Perguntas concluídas. O Ostler instala-se agora em segundo plano – cerca de 45 minutos a algumas horas. Três coisas vão ainda precisar de si: se o macOS pedir para instalar as ferramentas de programador, clique em Instalar; perto do fim, há um minuto de configuração (ativar o Acesso total ao disco); e mesmo no fim, depois da verificação de estado, inicia sessão no Tailscale e permite que o assistente utilize os Lembretes. Entre estes passos, pode deixar a instalação a decorrer."
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="Perguntas concluídas. O Ostler instala-se agora em segundo plano – cerca de 45 minutos a algumas horas. Três coisas vão ainda precisar de si: se o macOS pedir para instalar as ferramentas de programador, clique em Instalar; perto do fim, há um minuto de configuração (ativar o Acesso total ao disco); e mesmo no fim permite que o assistente utilize os Lembretes. Entre estes passos, pode deixar a instalação a decorrer."

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="e execute novamente: ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="A reiniciar o assistente para que possa usar o Acesso total ao disco para ler o histórico das suas Mensagens. É o reinício que faz com que uma permissão acabada de conceder entre em vigor; se ainda não a concedeu, o painel Doctor continuará a orientá-lo."
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="O seu assistente está em execução e tem Acesso total ao disco, por isso pode ler os ficheiros de que precisa."
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="O seu assistente está em execução, mas ainda não tem Acesso total ao disco. Até o ativar, o Ostler não consegue manter atualizados as Mensagens, o Mail, o Calendário, os Lembretes, as Notas, as Fotos, o Safari, os Contactos nem o WhatsApp, e não consegue ler a sua pasta Documentos. O que já foi lido mantém-se. O painel Doctor irá guiá-lo na ativação."
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="O seu assistente está em execução. Não foi possível verificar se tem Acesso total ao disco neste Mac, pelo que isto não é uma confirmação num sentido nem noutro. O painel Doctor dir-lhe-á assim que puder verificar."
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="Contas do Apple Mail visíveis: %s (informativo)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="O Apple Mail não parece ter ainda quaisquer mensagens locais. O Doctor apresentará um seguimento se não chegar nenhum correio nas próximas 24 horas."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="O Apple Mail tem mensagens em cache. A ingestão vai recolhê-las no próximo ciclo horário."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="O Apple Mail está selecionado, mas ainda não há mensagens locais para ler neste Mac. Abra o Apple Mail e adicione uma conta (Definições do Sistema > Contas de Internet, e depois selecione Mail) e deixe-o concluir a primeira sincronização."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="Depois de chegar correio, execute novamente: ostler-fda. O Ostler vai recolhê-lo automaticamente; não é necessário mais nada."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="A notarização da Apple será verificada pelo Gatekeeper no primeiro arranque."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="disponível, o instalador ignorará este passo automaticamente."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="Os beta testers com acesso podem definir PWG_PIPELINE_REPO=<url> e executar novamente."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="Os beta testers com acesso podem definir PWG_KNOWLEDGE_REPO=<url> e executar novamente."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="Extensões do navegador ignoradas (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  Clonado para %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="O Ostler RemoteCapture só funciona em Apple Silicon. A ignorar a instalação neste computador."
MSG_INFO_CM042_LOGS_AT="Registos do RemoteCapture: %s/ostler-remotecapture.log (e .err)"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="Uma instalação anterior tinha o Ostler RemoteCapture a iniciar no arranque da sessão. Foi parado e não voltará a iniciar."
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="O Ostler RemoteCapture não foi instalado: escolheu manter desativada a transcrição de voz. Ative-a nas Definições e execute o instalador novamente se mudar de ideias."
MSG_INFO_CM042_TCC_PRE_PROMPT="No primeiro arranque, o Ostler RemoteCapture pedirá ao macOS a permissão de Gravação do Ecrã e de Microfone. Conceda ambas para que as chamadas e reuniões possam ser transcritas localmente. Não aparece nenhum indicador roxo na barra de menus – a captação de áudio é silenciosa por conceção."
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
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="O Ostler guarda a sua wiki pessoal e os registos das suas conversas em Documentos/Ostler, neste Mac. Pertencem-lhe e permanecem neste computador. Para os escrever, o Ostler precisa de acesso à sua pasta Documentos, pelo que o macOS pode pedi-lo durante a configuração e novamente mais tarde no mesmo dia, quando o Ostler organizar a sua wiki pela primeira vez. O pedido pode aparecer como proveniente de python3.11, o auxiliar incluído que o Ostler usa para escrever os seus ficheiros. Clique em Permitir sempre que surgir. Se não o vir ou recusar, pode ativá-lo a qualquer momento em Definições do Sistema, em Privacidade e segurança, depois Ficheiros e pastas, e a sua wiki e os registos das conversas passarão a ser escritos a partir daí."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  Motor de memória de conversas instalado no venv."
MSG_INFO_HUB_APP_VERIFYING="A verificar o Ostler.app em %s"
MSG_INFO_HUB_APP_STAGING="A copiar o Ostler.app para /Applications a partir de %s"
MSG_INFO_HUB_APP_DRAG_HINT="Abra o DMG do instalador e arraste o Ostler.app e o OstlerInstaller.app para o atalho Aplicações, e depois execute o instalador novamente."
MSG_OK_HUB_APP_PRESENT="O Ostler.app já existe em %s; assinatura verificada."
MSG_OK_HUB_APP_STAGED="Ostler.app instalado em %s"
MSG_WARN_HUB_APP_NOT_FOUND="O Ostler.app não foi encontrado em /Applications e não está disponível nenhuma cópia incluída."
MSG_WARN_HUB_APP_VERIFY_FAILED="A verificação da assinatura ou da notarização do Ostler.app falhou. O pacote foi deixado no local para que o suporte o possa inspecionar."
MSG_OK_UNINSTALLER_APP_STAGED="Ostler Uninstaller.app instalado em %s"
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="Não foi possível colocar Ostler Uninstaller.app em /Applications. Pode, ainda assim, desinstalar executando: ~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="A clonar o agente Doctor..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="A clonar os scripts de importação de email..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="A clonar os scripts hub-power..."
MSG_INFO_CLONING_IMPORT_PIPELINE="A clonar o pipeline de importação..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="A clonar os scripts wiki-recompile..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="O Colima está instalado, mas não está em execução. Vai ser iniciado."
MSG_INFO_COLIMA_START_ATTEMPT="A iniciar o Colima (tentativa %s de %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="Não foi possível exportar os contactos. Pode importá-los manualmente mais tarde."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="Não foi possível ler o cartão de contacto. Sem problema – vamos perguntar."
MSG_INFO_CONTACT_CARD_WILL_ASK="Daqui a pouco vamos pedir-lhe o seu nome e país. Os seus contactos são lidos mais tarde, através do Acesso total ao disco que conceder, e nada sai deste Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  A criar o venv de Python em %s..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="A criar a árvore de conteúdos para o utilizador em %s/"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="Execução diária. Execução manual: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="Hub de secretária (sem bateria) detetado: a desativar a suspensão em todo o sistema"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="O Docker não está instalado. Vão ser instalados o Colima, a CLI do Docker e o plugin docker-compose (leve, sem necessidade do Docker Desktop)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="Os ficheiros do agente Doctor não estão incluídos no instalador."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="Os scripts de importação de email não estão incluídos no instalador."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="Os scripts de importação de email estão em falta no pacote do instalador. Transfira novamente a app a partir de ostler.ai/install e tente de novo."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Os scripts de importação de email não estão incluídos e foi passado --allow-plaintext; a instalação do LaunchAgent será ignorada. Os emails futuros não serão importados."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  Já existe uma cópia em %s; a atualizar..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="A extrair o mbox do Gmail do ficheiro zip do Takeout (pode demorar um minuto em arquivos grandes)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="O módulo de extração FDA não está incluído. A ignorar a extração instantânea de dados."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="A ativar os seus primeiros 30 dias do Ostler Pro..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Após o período de avaliação, o Ostler Pro custa 9,99 USD por mês. Subscreva na app Ostler no seu iPhone."
MSG_INFO_FOUND_GMAIL_MBOX_MB="mbox do Gmail encontrado em %s (%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Ficheiro zip do Google Takeout encontrado em %s (%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="Acesso total ao disco detetado – extração completa disponível."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="Exportações RGPD detetadas, mas o pipeline de importação ainda não está disponível."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="A importação de exportações RGPD estará disponível quando o pipeline for lançado."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="Vamos analisar as pastas Descargas, Secretária e Documentos à procura de exportações de IA (Google Takeout, transferências da Meta, LinkedIn, etc.) que possa ter guardado. O macOS vai mostrar três pedidos de acesso a pastas – permita cada um deles. Demora cerca de 5 a 10 segundos no total. Nada é movido nem copiado durante a análise; apenas verificamos o que lá está."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="O macOS poderá pedir autorização para ler o seu Calendário. Permita-o para que o Ostler possa construir a parte de reuniões e eventos do seu grafo de conhecimento. (Os dados do Calendário ficam neste Mac.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="O macOS está a pedir autorização para Descargas. Clique em OK."
MSG_INFO_FOLDER_PREWARM_DESKTOP="O macOS está a pedir autorização para Secretária. Clique em OK."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="O macOS está a pedir autorização para Documentos. Clique em OK."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="Acesso total ao disco concedido. A preparar o próximo pedido do macOS (automação das Mensagens)..."
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="Não houve resposta ao pedido de autorização das Mensagens, por isso avançámos. As suas mensagens não serão lidas até ser permitido. O Ostler voltará a perguntar, ou pode concedê-lo em Definições do Sistema > Privacidade e segurança > Automação."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="São necessárias as Xcode Command Line Tools. O macOS vai pedir autorização para as instalar – procure uma pequena janela cinzenta (se não a vir, prima Cmd+Tab ou verifique o Dock). Clique em Instalar. As ferramentas são transferidas em segundo plano enquanto responde às perguntas abaixo."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  A configurar ainda as Command Line Tools (%ss). Se uma pequena janela cinzenta do macOS estiver a pedir para instalar ferramentas de programação, clique em Instalar – este passo está à espera disso. (Prima Cmd+Tab ou verifique o Dock se não a vir.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="A aguardar a conclusão da instalação das Command Line Tools (quase pronto)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="Execução horária. A primeira execução obtém os últimos 5 anos de correio."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="A desativar o LaunchAgent antigo da ponte do iMessage (v1.0 de uma só máquina)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Hub apenas com alimentação elétrica (sem bateria detetada), a ignorar o LaunchAgent hub-power."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Os scripts de energia do Hub não estão incluídos no instalador."
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="Hub portátil. Continua a funcionar com a tampa aberta e ligado à corrente."
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="Se fechar a tampa, ou o deixar inativo com bateria, o macOS suspende-o."
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="Enquanto está suspenso, o assistente não recebe nada."
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="As mensagens que chegam nesse período não são recolhidas quando é reativado."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="A tampa pode ficar fechada no modo de ecrã fechado."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="Isso requer corrente elétrica, um ecrã externo, teclado e rato."
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="O Docker e o Ollama pausam com bateria e retomam com corrente elétrica."
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="Após um reinício, o FileVault mantém este Mac no ecrã de início de sessão."
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="O Ostler arranca assim que iniciar sessão."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="API do assistente incluída no instalador; a utilizar o código-fonte incorporado."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="Código-fonte da API do assistente não incluído; a app Ostler no seu iPhone terá acesso limitado."
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="A instalar as dependências de execução da API do assistente (phonenumbers, httpx)..."
MSG_WARN_ICAL_SERVER_DEPS_FAILED="Não foi possível instalar as dependências de execução da API do assistente (phonenumbers/httpx); Pessoas e Cronologia podem ficar vazias até à próxima execução da instalação."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Quando a janela do Tailscale aparecer, inicie sessão com Apple / Google / Microsoft."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="A abrir o Tailscale para que possa iniciar sessão..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="Anotado – a partir daqui, o Ostler instala-se quase sozinho. Perto do fim, vai precisar de si durante cerca de dois minutos: ativar o Acesso total ao disco e depois iniciar sessão no Tailscale, para que o iPhone e o Apple Watch possam aceder a este Mac a partir de qualquer lugar. Vamos abrir o navegador para o início de sessão."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale ignorado – a app Ostler no seu iPhone só funcionará na sua rede Wi-Fi doméstica. Pode configurar isto mais tarde nas Definições."
MSG_INFO_TAILSCALE_STILL_WAITING="A aguardar o início de sessão no Tailscale (%ss decorridos) – conclua o início de sessão na janela do Tailscale."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="Acesso total ao disco concedido; a reiniciar o assistente para aplicar a nova autorização."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="A abrir as Definições do Sistema e o Finder para o guiar na concessão do Acesso total ao disco ao assistente..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="A registar o assistente Ostler no macOS para que apareça como interruptor em Acesso total ao disco..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="O Acesso total ao disco ainda está pendente. O painel Doctor manterá o cartão visível até o acesso ser concedido."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="O ostler-assistant já tem Acesso total ao disco; não é necessária mais nenhuma ação."
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="Esta parte precisa de si durante cerca de dois minutos: ative agora o Acesso total ao disco para o assistente e depois inicie sessão no Tailscale no passo seguinte. Depois disso, pode deixar o Ostler terminar sozinho."
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="Esta parte precisa de si durante cerca de um minuto: ative o Acesso total ao disco para o assistente. Depois disso, pode deixar o Ostler terminar sozinho."
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="\"%s\" já está na lista do Acesso total ao disco, por isso basta ativá-lo. Não é preciso arrastar nada do Finder."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="A verificar se o assistente Ostler tem Acesso total ao disco..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="O assistente consegue ler o histórico das Mensagens; o canal iMessage vai funcionar."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="O assistente do Ostler ainda não tem Acesso total ao disco. Precisa dele para manter atualizadas as apps do seu próprio Mac, com ou sem Mensagens. Se o ignorar agora, o painel Doctor irá guiá-lo pelas Definições do Sistema."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="O LaunchAgent do assistente não foi carregado; a ignorar a verificação do Acesso total ao disco para o iMessage."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="A interface de importação do Evernote no Doctor irá apresentar um aviso de «serviço indisponível»"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="O processo de importação não está incluído no instalador."
MSG_INFO_INSTALLING_CM042="A instalar o Ostler RemoteCapture v%s (transcrição de chamadas e reuniões)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="A instalar o motor de memória de conversas a partir de %s..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  A instalar o motor de memória de conversas no venv..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="A instalar o Colima + Docker CLI..."
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="A instalar o GNU coreutils (para limites de tempo em passos longos)..."
MSG_INFO_INSTALLING_HOMEBREW="A instalar o Homebrew..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="A instalar o serviço Knowledge a partir de %s..."
MSG_INFO_INSTALLING_OLLAMA="A instalar o Ollama..."
MSG_INFO_INSTALLING_OLLAMA_PINNED="Installing Ollama %s (verified release)..."
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  A instalar as dependências do módulo de extração de dados..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  A instalar o leitor do Apple Mail num venv dedicado..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  A instalar o ostler-knowledge no venv..."
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  A instalar a dependência de armazenamento cifrado no venv da memória de conversas..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="A instalar a extensão do Safari em /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="A instalar as dependências Python de segurança..."
MSG_INFO_INSTALLING_SQLCIPHER="A instalar o SQLCipher..."
MSG_INFO_INSTALLING_TAILSCALE="A instalar o Tailscale..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="O suporte para Intel não está previsto; faça um pedido, se necessário."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Serviço Knowledge incluído no instalador; a utilizar o código-fonte incorporado."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Serviço Knowledge não instalado: PWG_KNOWLEDGE_REPO está vazio."
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="Este Mac é um portátil. Como Hub, continua a funcionar enquanto a tampa estiver aberta e o Mac estiver ligado à corrente."
MSG_INFO_LAPTOP_HUB_SLEEP_COST="Se fechar a tampa ou o deixar inativo com bateria, o macOS suspende-o. O assistente não recebe nada enquanto o Mac está em suspensão, e as mensagens que chegam nesse período não são recolhidas quando ele acorda."
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="A tampa pode permanecer fechada no modo de ecrã fechado, que exige ligação à corrente, mais um ecrã, um teclado e um rato externos."
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="Um Hub num Mac Mini ou Mac Studio permanece ativo por si só, se preferir instalar num destes."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="mais tarde em Definições do Sistema > Privacidade e segurança > Acesso total ao disco"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  iniciar para verificar a entrega por cron + a configuração imessage-tcc)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="Licença: %s é Apache 2.0. Texto completo: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licence: %s – check upstream terms before commercial use."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="armazenamento local – a Google nunca sabe que o Ostler existe."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="Registos: %s/email-ingest.log (e .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="Registos: %s/ostler-assistant.log (e .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="Registos: %s/wiki-recompile.log (e .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="Hubs em MacBook: defina PWG_HUB_POWER_REPO=<url> e execute novamente."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="Hub em MacBook detetado: a desativar a suspensão apenas com corrente (o hub-power gere as transições para bateria)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="As instalações em Mac Mini / Studio não são afetadas (sempre ligados à corrente)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Os dados do Mac (iMessage, Safari, etc.) foram extraídos acima."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="Reinício manual: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="Execução manual: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="A ignorar a instalação de com.ostler.meeting-brief-sender (funcionalidade da v1.0.1; os endpoints ainda não foram lançados)."
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="A ignorar a passagem de higiene da memória (não incluída neste instalador); nada é desvalorizado automaticamente até que seja incluída."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="mensagem quando a funcionalidade for ativada mais tarde."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="Precisa de ajuda? Envie um e-mail para support@ostler.ai. Procuramos responder no prazo de 2 dias úteis."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="Nenhum canal configurado. Execute mais tarde: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="Foi removido um config.toml antigo e obsoleto na raiz da área de trabalho; a configuração ativa do assistente está em assistant-config/."
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="Nenhuma fonte FDA disponível neste momento. Pode conceder o Acesso total ao disco"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="Não foram encontradas exportações RGPD em Transferências, Secretária ou Documentos."
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="Não foi possível ler %s para procurar exportações de dados. O macOS está a bloquear o acesso a essa pasta."
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="Conceda acesso em Definições do Sistema > Privacidade e segurança > Ficheiros e pastas (ou Acesso total ao disco) e execute novamente, ou indique manualmente abaixo a pasta das suas exportações ao Ostler."
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="Não foi possível analisar uma ou mais pastas à procura de exportações de dados porque o macOS bloqueou o acesso. Conceda acesso e execute novamente, ou indique manualmente a pasta das suas exportações."
MSG_INFO_OPENING_CHROME_WEB_STORE="A abrir a Chrome Web Store: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="binário ostler-assistant não instalado; a ignorar a verificação do doctor"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: adiado (o daemon ainda pode estar"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="A utilizar o binário ostler-assistant incluído neste DMG (instalação possível sem ligação à internet)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge instalado no venv."
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler will show an extra consent screen before installing"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  Substitua o repositório de origem do motor de memória de conversas através da variável de ambiente documentada em ./install.sh --help."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  Substitua o repositório de origem com PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  Substitua o repositório de origem com PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  Substitua o repositório de origem com PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  Substitua o repositório de origem com PWG_PIPELINE_REPO=<url> ./install.sh"
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Persisting consent records and region..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="Monitor de bateria da fase 3 ativado (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="A ler a sua lista de contactos (as bibliotecas grandes podem demorar alguns minutos – não feche o instalador)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="Substituição da política: edite ~/.ostler/power.conf (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="A verificar a permissão de Automatização do iMessage (só de leitura)..."
MSG_INFO_PULLING_GRAPH_DB_IMAGES="A transferir as bases de dados do grafo de conhecimento (apenas na primeira execução). Numa instalação nova, isto pode demorar um minuto..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="A transferir nomic-embed-text (274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="A transferir %s (%s)... pode demorar alguns minutos."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="Atributo xattr de quarentena removido. Quando a compilação com Developer ID estiver"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="A ler Safari, iMessage, Notas, Calendário, Fotografias, Lembretes, Mail..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="A ler o seu cartão de contacto para pré-preencher os seus dados..."
MSG_INFO_REGION_EU_EEA_SOURCE="Região: UE/EEE (%s, origem: %s)"
MSG_INFO_REGION_SOURCE="Região: %s (origem: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="Região: Reino Unido (origem: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="Região: Estados Unidos (origem: %s)"
MSG_INFO_REPO_URL="URL do repositório: %s"
MSG_INFO_REPO_URL_2="URL do repositório: %s"
MSG_INFO_REPO_URL_3="URL do repositório: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="Escolha agora a frase de acesso que irá desbloquear o seu Hub. Terá de a introduzir sempre que iniciar a interface do Hub."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="Frase de acesso de recuperação ignorada. (Descontinuado: a v1.0 exige sempre uma frase de acesso.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="A reutilizar a instalação existente do agente Doctor em %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="A reutilizar a instalação existente de email-ingest em %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="A reutilizar a instalação existente de hub-power em %s"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="A reutilizar a chave existente da extensão do navegador em %s"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="A extensão do Ostler para o Chrome não faz parte desta versão."
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="Email conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="Conversas de email: não configuradas, porque o Apple Mail não está configurado neste Mac."
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="Messages conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="Conversas da app Mensagens: não configuradas, porque não existe histórico da app Mensagens neste Mac."
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  Transcreva uma chamada com o Ostler e isto ativa-se automaticamente."
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="Conversas faladas: ainda não configuradas, porque não há transcrições para ler."
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="Conversas faladas: desativadas, porque a pasta Transcripts foi removida desde a instalação do Ostler."
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  Volte a criar %s para as reativar. O Ostler não a voltará a criar por si."
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="WhatsApp conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="Conversas do WhatsApp: não configuradas, porque o WhatsApp está desativado."
MSG_INFO_CHROME_HISTORY_STILL_READ="  O Ostler continua a ler o seu histórico do Chrome, pelo que as páginas que visitou ficam memorizadas. Por agora, a captura em direto durante a navegação só funciona no Safari."
MSG_INFO_REUSING_EXISTING_JWT_SECRET="A reutilizar o JWT_SECRET existente em %s"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="A reutilizar o token de serviço PWG existente em %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="A reutilizar a instalação existente de wiki-recompile em %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="O pacote da extensão do Safari não está presente nesta compilação do instalador (a ignorar)"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="Falta um passo manual: abra o Safari, escolha Safari > Definições > Extensões e assinale Ostler para a ativar."
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="A procurar exportações de dados RGPD..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="Defina PWG_DOCTOR_REPO=<url> e execute novamente para instalar."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="Defina PWG_HUB_POWER_REPO=<HR015 url> e execute novamente para instalar."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="Modelo de conversação ignorado. Transfira mais tarde: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="A iniciar o Colima (ambiente de execução Docker leve)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="A iniciar o Docker Desktop..."
MSG_INFO_STARTING_OLLAMA="A iniciar o Ollama..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="A remover um item de arranque do Colima obsoleto deixado por uma versão anterior..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="A remover a fórmula antiga do Ollama (sem llama-server); a mudar para a app Ollama..."
MSG_INFO_VERIFYING_EMBEDDINGS="A verificar se o motor de embeddings devolve vetores..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="Não foi possível iniciar o Ollama automaticamente. Carregue-o com: launchctl bootstrap gui/\$(id -u) %s – e execute novamente o instalador."
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="O Ollama não arrancou através do serviço em segundo plano; a iniciá-lo diretamente para esta execução..."
# NEEDS REVIEW: Source is a line fragment ('after first' continues on the next line); 'depois da primeira vez' may not join correctly with the continuation. Check the full sent
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  a iniciar; execute \`ostler-assistant doctor\` depois da primeira vez"
MSG_INFO_SYMLINKING="  A criar ligação simbólica de %s -> %s"
# NEEDS REVIEW: Source line is cut mid-phrase ('Mail's ...'). The split may not join naturally with the next line in Portuguese. Check against the full sentence.
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(Definições do Sistema > Contas de Internet). O Ostler lê do Mail"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(O resto do Ostler funciona sem o painel Doctor.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="Por agora, isto é normal. A importação RGPD estará disponível numa atualização futura."
# NEEDS REVIEW: source asks for human translation of this key
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="Normalmente demora entre 15 e 45 minutos e pode demorar mais se tiver muito histórico ou um Mac mais lento. É normal – está a funcionar, não está bloqueado, por isso pode deixá-lo a correr..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="Isto lê diretamente as bases de dados do macOS – não é necessário exportar."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="Sugestão: para incluir o seu Gmail, adicione-o primeiro ao Mail do Mac"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="Para instalar mais tarde, quando tiver acesso:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="A acionar a sincronização do iCloud para %s (silenciosa, apenas na primeira execução)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (UK GDPR Article 9 - required for special-category data)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="A atualizar o pipeline existente..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="A árvore visível para o utilizador já foi anunciada (sentinela presente); a ignorar"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="A transferir o motor de pesquisa web local (cerca de 3,5 GB). Numa primeira instalação, este é o passo mais longo e pode demorar até uma hora. Não existe barra de progresso, por isso é normal haver um longo silêncio aqui, o que não significa que a instalação tenha parado."
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="O Vane não responde (opcional; consulte os avisos da fase 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="Consulte em qualquer altura com: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="O reconhecimento de voz permanecerá desativado. Pode ativá-lo mais tarde nas Definições."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="A aguardar que inicie sessão no Tailscale (até 3 minutos)..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="O acesso remoto através do Tailscale não foi configurado. A app Ostler no seu iPhone funcionará na sua rede Wi-Fi doméstica; pode configurar o acesso remoto mais tarde nas Definições."
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="Este Mac já está ligado à sua rede Tailscale, por isso não é necessário configurar nada. A manter a ligação existente."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="Acesso remoto: a manter a resposta que deu da última vez, que foi não o configurar. A app iOS funcionará na sua rede Wi-Fi doméstica e pode configurar o acesso remoto mais tarde nas Definições."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="Acesso remoto: a manter a resposta que deu da última vez, que foi configurá-lo."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="Conector do WhatsApp desativado. Pode ativá-lo mais tarde nas Definições."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="Manutenção da ligação do WhatsApp agendada às 08:50 + 17:50 (etiqueta com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="A ignorar a atualização inicial da wiki: a tarefa de recompilação da wiki não está instalada. A reconstrução diária da wiki, se instalada, continua a ser executada."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Os scripts de recompilação da wiki não estão incluídos no instalador."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="A wiki não será atualizada automaticamente; pode executar novamente a primeira compilação manualmente:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="Marcador de postura escrito: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="As suas exportações estão seguras. Importe-as mais tarde com: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="Os dados do seu Mac (iMessage, Safari, etc.) já foram extraídos acima."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="Pode adicioná-lo mais tarde para uma integração instantânea a partir do Safari, iMessage, etc."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="Modelo de IA: %s (%s) – selecionado para os seus %s GB de RAM"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="Compatível"
MSG_MODELFIT_PILL_SLOW="Pode ser lento"
MSG_MODELFIT_PILL_NOFIT="Não é compatível"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="A adaptar o modelo do assistente ao seu Mac (%s, %s GB de RAM, contexto do assistente de %s tokens):"
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- Recomendado"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="Modelo de IA: %s (%s) – a melhor opção para os seus %s GB de RAM na janela de contexto exigida pelo assistente"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="Todas as fontes selecionadas (reconhecimento facial ainda desativado)"
MSG_OK_ALREADY_AVAILABLE="%s já disponível"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon detetado"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="Apps iniciadas para acionar a sincronização do iCloud"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="As bases de dados das apps já existem (pré-arranque ignorado)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="Configuração do assistente guardada em %s (modo 0600)"
MSG_OK_BACKED_UP_CONTACTS="Cópia de segurança de %s contactos guardada em %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s instalado em %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="LaunchAgent do Ostler RemoteCapture carregado (etiqueta %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima e Docker CLI instalados"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="Supervisor do motor de contentores instalado (verifica a cada 5 minutos e reinicia o motor se este parar)"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="Não foi possível agendar o supervisor do motor de contentores. O Ostler será instalado na mesma, mas, se o motor parar mais tarde, nada o voltará a iniciar sozinho – a sua wiki ficaria indisponível até voltar a executar o instalador."
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="Os ficheiros do supervisor do motor de contentores não existem neste instalador, pelo que não foi agendado. O Ostler será instalado na mesma, mas a recuperação automática do motor não está ativa."
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="Não foi possível iniciar o painel Doctor do Ostler, pelo que http://localhost:8089 não responderá. As páginas da própria app que dele dependem – Pessoas, Cronologia, Governor, estado dos canais – aparecerão como indisponíveis até que esteja em execução. Volte a executar o instalador para tentar de novo."
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="Não foi possível agendar o auxiliar que evita a suspensão. O Ostler continua a funcionar, mas este Mac pode entrar em suspensão durante tarefas longas em segundo plano, que serão retomadas quando sair da suspensão, em vez de terminarem durante a noite."
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="Não foi possível agendar o auxiliar de atualização em segundo plano, pelo que as novas mensagens, o correio e os eventos do calendário não serão recolhidos automaticamente. Volte a executar o instalador para o restaurar."
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="%s not set up: Ostler has no record of your answer to the question that governs it, so it did not assume one."
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  Re-run Ostler and choose to answer the questions again to turn it on. (consent record: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="Não foi possível agendar o resumo diário, pelo que não receberá o resumo da manhã. Tudo o resto funciona; volte a executar o instalador para o restaurar."
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="Não foi possível agendar a passagem de higiene da memória, pelo que os factos desatualizados ou substituídos não terão o seu peso reduzido automaticamente. Tudo o resto funciona; volte a executar o instalador para a restaurar."
MSG_WARN_EXPORT_SCAN_NOT_LOADED="Não foi possível iniciar o observador da pasta Transferências, pelo que os ficheiros que colocar em Transferências não serão recolhidos automaticamente. Tudo o que já foi importado não é afetado e pode continuar a adicionar ficheiros a partir da app. Volte a executar o instalador para o restaurar."
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="Não foi possível agendar o auxiliar de nova tentativa do registo de dispositivos. Se o seu iPhone foi registado durante a configuração, nada muda; caso contrário, terá de o emparelhar novamente a partir da app, em vez de o processo se concluir sozinho."
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="Motor de contentores a responder"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="Removido um item de arranque do Colima obsoleto, deixado por uma versão anterior"
MSG_OK_CONFIG_SAVED_ENV="Configuração guardada em %s/.env"
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Consent records and region persisted to ~/.ostler/posture/"
MSG_OK_AT_REST_EXCLUDED="Excluído do Spotlight e do Time Machine (verificado): %s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s NÃO está excluído do Time Machine nem do Spotlight: %s. O seu conteúdo, incluindo os segredos do Ostler, pode ser copiado para o disco de cópia de segurança. O Doctor continuará a mostrar este aviso até ser corrigido."
MSG_INFO_AT_REST_FOLDER_ABSENT="%s ainda não existe, pelo que não há nada a excluir das cópias de segurança."
MSG_WARN_DB_KEY_NOT_EXCLUDED="O ficheiro da chave da base de dados %s NÃO está excluído do Time Machine, pelo que pode ser copiado para o disco de cópia de segurança."
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="Não foi possível guardar a sua escolha sobre o enriquecimento em segundo plano em ~/.ostler/posture/. A escolha continua a ser aplicada a esta instalação; apenas não aparecerá num relatório de suporte."
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="Bases de dados encriptadas. Os serviços do Hub leem a chave a partir de um ficheiro protegido na sua pasta pessoal, pelo que arrancam sem lhe pedir nada."
MSG_OK_DB_KEY_DELIVERED="Chave da base de dados entregue aos serviços do Hub (%s, legível apenas por si)."
MSG_WARN_DB_KEY_NOT_DELIVERED="Não foi possível entregar a chave da base de dados aos serviços do Hub. Estes abrirão as bases de dados sem encriptação até que seja corrigido."
MSG_INFO_DB_KEY_RECOVER_HINT="Execute isto para a recuperar e entregar: %s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="A encriptar as bases de dados que restam de uma instalação anterior"
MSG_WARN_DB_MIGRATION_FAILED="Não foi possível encriptar algumas bases de dados existentes. Continuam legíveis no disco."
MSG_WARN_DB_KEY_MISSING_ON_RERUN="Esta instalação não tem ficheiro de chave da base de dados, pelo que os serviços do Hub estão a abrir as bases de dados sem encriptação."
MSG_WARN_DB_PLAINTEXT_COUNT="%s base(s) de dados neste Mac estão atualmente legíveis no disco."
MSG_INFO_DB_MIGRATE_HINT="Depois encripte o que já existe: %s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="Nova tentativa diferida do registo de dispositivos instalada (é executada de hora a hora até a fila ficar vazia)"
MSG_OK_DOCKER_RUNNING="Docker em execução"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker em execução (demorou %ss)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Agente Doctor clonado de %s"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Ficheiros do agente Doctor incluídos no instalador"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Dependências do Doctor instaladas"
MSG_OK_EMAIL_CHANNEL_FOLDER="Canal de email: %s (pasta: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de ingestão de email carregado (label com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de ingestão de email incluídos no instalador"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="Scripts de ingestão de email clonados de %s"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="A configurar a memória de conversas do WhatsApp"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  Leitor de conversas do WhatsApp instalado."
MSG_WARN_WHATSAPP_SOURCE_FAILED="Falha na instalação do leitor de conversas do WhatsApp; o feed de conversas do WhatsApp não será executado. Consulte o resultado acima."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="Origem do leitor de conversas do WhatsApp não encontrada; o feed de conversas do WhatsApp será ignorado."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="Pacote do feed de conversas do WhatsApp não encontrado neste instalador; será ignorado. O histórico de mensagens do WhatsApp (com quem trocou mensagens e quando) não é afetado."
MSG_OK_WHATSAPP_BUNDLE_LOADED="LaunchAgent do feed de conversas do WhatsApp carregado (label com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  A primeira execução lê as conversas recentes do WhatsApp que o seu Mac sincronizou (aproximadamente o último ano); tudo permanece no seu Mac."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  Registos: %s/whatsapp-bundle.log e whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="Falha na instalação do LaunchAgent do feed de conversas do WhatsApp. Consulte o resultado acima; o resto da instalação não é afetado."
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  Ainda não iniciado: o programa do assistente que este agente executa não está no disco. Caminho procurado: %s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="A configurar a memória de conversas de email"
MSG_OK_EMAIL_SOURCE_INSTALLED="  Leitor de conversas de email instalado."
MSG_WARN_EMAIL_SOURCE_FAILED="Falha na instalação do leitor de conversas de email; o feed de conversas de email não será executado. Consulte o resultado acima."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="Origem do leitor de conversas de email não encontrada; o feed de conversas de email será ignorado."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="Pacote do feed de conversas de email não encontrado neste instalador; será ignorado. A ingestão de email de hora a hora não é afetada."
MSG_OK_EMAIL_BUNDLE_LOADED="LaunchAgent do feed de conversas de email carregado (label com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Lê as suas conversas de email recentes a partir do armazenamento local do Apple Mail; tudo permanece no seu Mac."
MSG_INFO_EMAIL_BUNDLE_LOGS="  Registos: %s/email-bundle.log e email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="Falha na instalação do LaunchAgent do feed de conversas de email. Consulte o resultado acima; o resto da instalação não é afetado."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="A configurar a memória de reuniões e conversas de voz"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  Leitor de reuniões e conversas de voz instalado."
MSG_WARN_SPOKEN_SOURCE_FAILED="Falha na instalação do leitor de reuniões e conversas de voz; o feed não será executado. Consulte o resultado acima."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="Origem do leitor de reuniões e conversas de voz não encontrada; o feed será ignorado."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="Pacote do feed de reuniões e conversas de voz não encontrado neste instalador; será ignorado."
MSG_OK_SPOKEN_BUNDLE_LOADED="LaunchAgent do feed de reuniões e conversas de voz carregado (label com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  Transcreve as suas próprias reuniões e notas de voz em conversas pesquisáveis; tudo permanece no seu Mac."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  Registos: %s/spoken-bundle.log e spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="Falha na instalação do LaunchAgent do feed de reuniões e conversas de voz. Consulte o resultado acima; o resto da instalação não é afetado."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="A configurar a memória de conversas do iMessage"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  Leitor de conversas do iMessage instalado."
MSG_WARN_IMESSAGE_SOURCE_FAILED="Falha na instalação do leitor de conversas do iMessage; o feed de conversas do iMessage não será executado. Consulte o resultado acima."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="Código-fonte do leitor de conversas do iMessage não encontrado; a ignorar o feed de conversas do iMessage."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="Pacote do feed de conversas do iMessage não encontrado neste instalador; a ignorar."
MSG_OK_IMESSAGE_BUNDLE_LOADED="LaunchAgent do feed de conversas do iMessage carregado (etiqueta com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  Lê as suas conversas recentes do iMessage a partir do armazenamento das Mensagens deste Mac; tudo permanece no seu Mac."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  Registos: %s/imessage-bundle.log e imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="Falha na instalação do LaunchAgent do feed de conversas do iMessage. Consulte o resultado acima; o resto da instalação não é afetado."
MSG_OK_EMBEDDING_MODEL_READY="Modelo de incorporação pronto"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="%s contactos exportados (serão importados automaticamente)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="Monitor de exportações instalado (analisa as Transferências de 4 em 4 horas)"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  O monitor de exportações ainda não foi iniciado: o programa do assistente que executa não está no disco. Procurado em: %s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="Emissor de resumos pré-reunião instalado (verifica de 10 em 10 minutos durante as horas de vigília)"
MSG_OK_MEMORY_HYGIENE_INSTALLED="Limpeza de memória agendada (é executada diariamente para evitar que factos obsoletos se sobreponham aos atuais)"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="O Mac permanecerá ativo quando ligado à corrente, para que o Ostler continue a funcionar (em bateria, entra em repouso)"
MSG_OK_EXTRACTED="Extraído para %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="Extraído de %s fonte(s). Dados guardados em %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="Nova execução do FDA agendada a cada %s minutos (apanha sincronizações lentas do iCloud e conclui o preenchimento do calendário)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro ativo durante 30 dias. Subscreva na app Ostler no iPhone para prolongar após o período experimental."
MSG_OK_FOUND="Encontrado: %s"
MSG_OK_FOUND_EXPORTS="Exportações encontradas em %s"
MSG_OK_FOUND_GDPR_EXPORT_S="Encontrada(s) %s exportação(ões) RGPD:"
MSG_OK_GB_FREE_DISK_SPACE="%s GB de espaço livre em disco"
MSG_OK_GB_RAM_DETECTED="%s GB de RAM detetados"
MSG_OK_GDPR_IMPORT_COMPLETE="Importação RGPD concluída"
MSG_OK_GIT_AVAILABLE="Git disponível"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="Instalação das Command Line Tools iniciada (a transferir em segundo plano enquanto responde às perguntas abaixo)."
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils instalado (os passos longos têm agora um limite de tempo)"
MSG_OK_HOMEBREW_INSTALLED="Homebrew instalado"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de energia do Hub carregado (etiqueta com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de energia do Hub incluídos no instalador"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Scripts de energia do Hub clonados de %s"
MSG_OK_ICAL_SERVER_INSTALLED="API do assistente instalada (loopback 127.0.0.1:8090, com proxy do Doctor)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="LaunchAgent da ponte do iMessage carregado (etiqueta com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts da ponte do iMessage incluídos no instalador"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="Scripts da ponte do iMessage clonados de %s"
MSG_OK_IMESSAGE_CHANNEL="Canal iMessage: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="Pipeline de importação incluído no instalador"
MSG_OK_IMPORT_PIPELINE_READY="Pipeline de importação pronto"
MSG_OK_CM048_PIPELINE_READY="Motor de memória de conversas pronto."
MSG_INFO_CM048_SETTINGS_WRITTEN="  Modelos de conversa definidos para %s (adequados aos seus %s GB de memória)"
MSG_INFO_CM048_SETTINGS_KEPT="  A manter as definições de conversa existentes (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="Serviço de conhecimento pronto: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="Textos de licença instalados em %s/ (origem: %s)"
MSG_OK_MACOS_DETECTED="macOS %s detetado"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="A abrir Definições do Sistema > Contas de Internet para poder adicionar uma conta de e-mail. Volte a esta janela depois de iniciar sessão na primeira conta."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="A saltar o passo das Contas de Internet. Pode adicionar uma conta de e-mail mais tarde nas Definições do Sistema; o Doctor apresentará um aviso se não chegar nenhum e-mail nas próximas 24 horas."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="A obter agora todo o seu histórico do Apple Mail. Pode demorar um pouco mais com uma caixa de correio grande."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="A manter a janela de e-mail padrão de cinco anos. Mais tarde, pode obter mais a partir do Doctor."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text já disponível"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="Ollama instalado"
MSG_WARN_OLLAMA_CUSTOMER_APP_PRESENT="An Ollama app is already installed in Applications. Ostler leaves it exactly as it is and runs its own copy of Ollama %s alongside it. If that app is open in the menu bar, quit it so Ostler can start its own."
MSG_WARN_OLLAMA_PIN_DEFERRED="Could not update Ollama to %s this time, so Ostler is keeping the copy it already runs (%s). Your assistant keeps working. The update will be tried again the next time the installer runs. Details: %s"
MSG_WARN_MODEL_PULL_HELD_OLLAMA_UNPINNED="Not downloading %s this time: Ostler's tested copy of Ollama (%s) is not installed yet, and a different Ollama could fetch the wrong build. The next installer run downloads it."
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama instalado (apenas CLI – pode ser necessário iniciar manualmente após reiniciar)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama instalado (aplicação de secretária)"
MSG_OK_OLLAMA_RUNNING="Ollama em execução"
MSG_OK_EMBEDDINGS_VERIFIED="Motor de embeddings verificado (vetores de 768 dimensões)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: 0 erros nas suas próprias verificações de arranque"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent do assistente Ostler carregado (etiqueta com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s preparado em %s (assinado)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s preparado em %s (não assinado)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor em execução em http://localhost:8089/doctor"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  O módulo de extração de dados carrega corretamente."
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Leitor do Apple Mail instalado."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  Motor de ingestão de e-mail instalado."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="Comandos ostler-import, ostler-fda e ostler-uninstall instalados"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="Frase de acesso registada. Irá cifrar as suas bases de dados durante a Fase 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="Frase de acesso de recuperação configurada."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="Instruções sobre a frase de acesso confirmadas."
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="Palavra-passe da exportação do Disney+ registada. Será utilizada durante a importação."
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="A saltar a exportação do Disney+: não foi indicada nenhuma palavra-passe. Nada mais é afetado."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="Fonte de energia: corrente elétrica (Mac de secretária, sem bateria)"
# NEEDS REVIEW: source asks for human translation of this key
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="Fonte de energia: corrente elétrica (bom – a instalação pode demorar de 45 minutos a algumas horas, por isso a ligação à corrente mantém-na estável)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="Instalação anterior detetada. A carregar a configuração..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="A utilizar o Python %s incluído (não é necessária instalação no sistema)"
MSG_OK_PYTHON_INSTALLED="Python %s instalado"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="Serviço de emparelhamento em bom estado"
MSG_WARN_GATEWAY_NOT_RESPONDING="O serviço de emparelhamento não responde (127.0.0.1:8000) - o emparelhamento com o telemóvel/navegador e o assistente de conversa podem ainda não funcionar"
MSG_OK_DOCTOR_HEALTHY="Doctor em bom estado"
MSG_WARN_DOCTOR_NOT_RESPONDING="O Doctor não responde (127.0.0.1:8089) - a aplicação e o navegador acedem ao Ostler através dele, pelo que os dados e o emparelhamento podem estar indisponíveis"
MSG_OK_WIKI_HEALTHY="A sua wiki em bom estado"
MSG_OK_ICAL_SERVER_HEALTHY="API do assistente em bom estado"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="A API do assistente não responde (127.0.0.1:8090) - Pessoas, Reuniões e Cronologia podem estar vazias até iniciar"
MSG_OK_READY="%s pronto"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="Fontes recomendadas selecionadas"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="Chave de recuperação guardada no Porta-chaves (pesquise 'Ostler' na app Palavras-passe)"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Extensão do Safari instalada em %s"
MSG_OK_SAFARI_EXTENSION_PAIRED="Extensão do Safari emparelhada com este Hub"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="A segurança já foi configurada numa execução anterior."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="Módulo de segurança instalado no venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="JWT_SECRET novo criado em %s"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="Token de serviço PWG criado em %s"
MSG_OK_SEEDED_EXTENSION_TOKEN="Chave da extensão do navegador criada em %s"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="Serviços iniciados (Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  Coleção de pesquisa preparada: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="Ainda não foi possível preparar a coleção de pesquisa %s; a importação de dados abaixo tentará novamente e, se continuar a não ser possível, para em vez de descartar os seus dados."
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="O índice de pesquisa ainda não ficou pronto a tempo; a importação de dados abaixo vai aguardar por ele, preparar as coleções e parar em vez de descartar os seus dados se o armazenamento continuar por preparar."
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="Os seus dados não foram importados. Não foi possível preparar o armazenamento de pesquisa para os receber (em falta: %s) e importá-los mesmo assim tê-los-ia descartado em silêncio. Nada se perdeu. Volte a executar o instalador quando o computador estiver inativo ou defina OSTLER_QDRANT_READY_WAIT_S para esperar mais tempo."
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="A importação de dados percorreu %s registos, mas não guardou nenhum; o armazenamento de pesquisa rejeitou-os todos, pelo que o resultado seria um grafo de conhecimento vazio apresentado como completo. A parar em vez de lhe mostrar isso. Volte a executar o instalador quando o computador estiver inativo."
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="Não foi possível ler o registo da própria importação, por isso a verificação de que os seus dados chegaram realmente ao destino não pôde ser executada. Isto não indica que a importação falhou, nem que foi bem-sucedida."
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="Suspensão desativada com corrente, suspensão com bateria mantida, reativação por rede ativada"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="Suspensão desativada, reativação por rede ativada"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale já instalado"
MSG_OK_TAILSCALE_INSTALLED="Tailscale instalado"
MSG_OK_TAILSCALE_ENV_PERSISTED="IP do Tailscale guardado em .env – a app Ostler no seu iPhone vai usá-lo no primeiro arranque."
MSG_OK_TAILSCALE_IP="IP do Tailscale: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Serviço em segundo plano do Tailscale iniciado (modo de espaço do utilizador, sem extensão do sistema)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="Não foi possível iniciar o serviço em segundo plano do Tailscale. Pode voltar a executar a configuração mais tarde, em Definições."
MSG_INFO_TAILSCALE_SIGN_IN_URL="A abrir o navegador para iniciar sessão no Tailscale: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Porta %s do Hub exposta na sua tailnet"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="Não foi possível expor a porta %s do Hub na sua tailnet; o acesso fora da rede local pode ficar limitado"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="A sua wiki já pode ser lida a partir dos seus próprios dispositivos em %s – com a sua sessão iniciada, e apenas a sua."
MSG_INFO_WIKI_TAILNET_OWNER="O acesso à wiki está restrito à sua conta Tailscale (%s). As outras pessoas na sua tailnet recebem um 403."
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="A sua wiki fica apenas neste Mac. Abra o Ostler e escolha Wiki na barra lateral para a ler."
MSG_INFO_WIKI_TAILNET_BANNER="%s  (a partir dos seus próprios dispositivos, através do Tailscale. Este é o único caminho que lhe pede o início de sessão acima.)"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="na app Ostler. Abra o Ostler e escolha Wiki na barra lateral; as suas páginas estão lá, com a sessão já iniciada."
MSG_INFO_WIKI_INTERNAL_ADDRESS="O Ostler obtém essas páginas a partir de http://localhost:8044 neste Mac. Esse endereço é interno e não há nele nada em que precise de iniciar sessão."
MSG_INFO_WIKI_SIGN_IN="O seu início de sessão na wiki é %s com a palavra-passe %s. O Ostler apresenta-o por si, por isso não precisa de escrever nada neste Mac; só precisa dele à mão quando abrir a wiki a partir de outro dos seus dispositivos através do Tailscale."
MSG_INFO_WIKI_SIGN_IN_WITHHELD="O seu início de sessão na wiki é %s. A palavra-passe não é escrita neste registo; está na área de transferência e no ficheiro indicado abaixo. O Ostler apresenta-a por si, por isso não precisa de escrever nada neste Mac."
MSG_INFO_WIKI_PORT_LAST_STATUS="Último estado HTTP da porta da wiki: %s (000 significa que nada respondeu; 403 significa que respondeu e recusou a credencial)."
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="A sua palavra-passe também está guardada em %s, por isso a área de transferência não é a única cópia."
MSG_INFO_WIKI_STILL_BUILDING="Ainda a compilar. Já existem %s páginas no disco e a última resposta do endereço da wiki foi HTTP %s. Vai aparecer automaticamente na app Ostler. Não precisa de fazer nada."
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="A primeira compilação ainda não produziu páginas (veja os avisos acima). A sua wiki continua a abrir-se na app Ostler depois de compilada, e o início de sessão acima continua a ser seu."
MSG_INFO_WIKI_READINESS_NOT_MEASURED="Esta execução não verificou se a wiki já está a funcionar, por isso não afirma nada num sentido nem noutro. A sua wiki abre na app Ostler de qualquer forma, e o início de sessão acima continua a ser seu."
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="Não foi possível confirmar qual a conta Tailscale que é proprietária deste Mac, por isso a wiki NÃO foi exposta na sua tailnet. Continua disponível neste Mac, na app Ostler, em Wiki."
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="Não foi possível publicar a wiki na sua tailnet; continua disponível neste Mac, na app Ostler, em Wiki."
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="Não foi possível recarregar o controlo de acesso da wiki, por isso a wiki NÃO foi exposta na sua tailnet."
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="O Tailscale Funnel está ativado para %s. O Funnel publica na internet aberta. O Ostler nunca ativa o Funnel e a sua wiki recusa tráfego do Funnel, por isso nada do Ostler é público – mas, se não pretendia ativá-lo, desative-o na consola de administração do Tailscale para esta máquina."
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="Atribuições de terceiros instaladas (origem: %s)"
MSG_OK_USER_FACING_TREE_READY="Estrutura visível para o utilizador pronta"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="A utilizar a pasta/etiqueta 'Ostler' em vez disso."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane operacional (pesquisa web local)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane em execução em http://localhost:3000 (comunica com o seu Ollama local)"
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="WhatsApp connector will be enabled (consent recorded)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="LaunchAgent de atualização da wiki do primeiro dia carregado (reconstrói a sua wiki de 30 em 30 minutos durante as primeiras horas e depois para)"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="Ainda a unir contactos duplicados – listas de contactos grandes podem demorar vários minutos (%ss decorridos)"
MSG_INFO_DEDUPE_MERGED="Contactos duplicados unidos"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="A união de contactos duplicados está a demorar algum tempo numa lista de contactos deste tamanho. Continuará em segundo plano após a instalação – a sua wiki é atualizada automaticamente quando terminar."
MSG_WARN_DEDUPE_INCOMPLETE="A passagem de deduplicação de todo o grafo não terminou corretamente (consulte %s); a continuar"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="Contactos duplicados totalmente unidos durante a instalação; não é necessária atualização em segundo plano"
MSG_OK_DEDUPE_CATCHUP_LOADED="LaunchAgent de deduplicação de contactos em segundo plano carregado (termina a união de duplicados após a instalação e depois para)"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="Não foi possível carregar o LaunchAgent de deduplicação de contactos em segundo plano. Os duplicados continuarão a ser unidos pela manutenção diária; apenas demorará mais a ficar tudo em ordem."
MSG_OK_ENRICH_AGENT_LOADED="LaunchAgent de enriquecimento em segundo plano carregado (completa os detalhes dos seus filmes, locais, livros e links; é executado por partes ao longo do dia seguinte, aproximadamente)"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="Não foi possível carregar o LaunchAgent de enriquecimento em segundo plano. As suas preferências estão guardadas e pesquisáveis; apenas faltarão os detalhes de referência adicionais (realizadores, elenco, locais) até ser executado."
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de recompilação da wiki carregado (etiqueta com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de recompilação da wiki incluídos no instalador"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Scripts de recompilação da wiki clonados de %s"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="A configurar a sua Página Inicial (atualização de hora a hora)"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="Produtor da Página Inicial incluído no instalador"
MSG_OK_EDITOR_FRONTPAGE_LOADED="LaunchAgent da Página Inicial carregado (etiqueta com.creativemachines.ostler.editor-frontpage)"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  A primeira atualização decorre agora; a Página Inicial do seu Dashboard vai-se preenchendo à medida que o Ostler lê as suas preferências."
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  Registos: %s/editor-frontpage.log e editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="Produtor da Página Inicial não encontrado neste instalador; a Página Inicial do Dashboard não será atualizada."
MSG_WARN_EDITOR_FRONTPAGE_FAILED="A instalação do LaunchAgent da Página Inicial falhou. Consulte o resultado acima; o resto da instalação não é afetado."
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="A configurar a recuperação da sua Página Inicial"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="LaunchAgent de recuperação da Página Inicial carregado (verifica de 5 em 5 minutos até os seus interesses terem sido lidos e depois para)"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="Não foi possível carregar o LaunchAgent de recuperação da Página Inicial. A sua Página Inicial e o que o Ostler sabe sobre os seus interesses serão preenchidos na próxima atualização horária."
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="A ignorar a recuperação da Página Inicial: a atualização da Página Inicial não está instalada, por isso não há nada para executar novamente."
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki em execução em http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="A sua wiki está pronta a explorar. O Ostler está agora a escrever os resumos das páginas em segundo plano, por isso vão aparecendo dentro de pouco tempo. Pode começar a utilizar a sua wiki de imediato."
MSG_OK_YOUR_ASSISTANT_CALLED="O seu assistente chama-se %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="Scripts do resumo de contexto pessoal incluídos no instalador"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="LaunchAgent do resumo de contexto pessoal carregado (etiqueta com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  Registos: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="A reutilizar a instalação existente de context-refresh em %s"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="Os scripts de resumo do contexto pessoal não estão incluídos; o assistente vai basear-se apenas em consultas em tempo real (sem resumo de contexto sempre ativo)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="O LaunchAgent do resumo do contexto pessoal não foi carregado; consulte context-refresh.err. O assistente continua a responder através de consultas em tempo real"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="O código-fonte clonado do serviço Knowledge não tem a configuração de empacotamento, por isso o respetivo ambiente não foi configurado."
MSG_WARN_BUNDLE="  Pacote: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="O Ostler RemoteCapture v%s só funciona em Apple Silicon (detetado: %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="Não foi possível transferir o Ostler RemoteCapture v%s de %s"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="Causas comuns: a etiqueta da versão ainda não foi publicada, a rede está desligada ou a notarização ainda está em curso. Execute novamente o instalador quando a versão estiver disponível."
MSG_WARN_CM042_EXTRACT_FAILED="Não foi possível extrair o ficheiro tarball do Ostler RemoteCapture; o LaunchAgent será ignorado."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Falha ao carregar o LaunchAgent do Ostler RemoteCapture. Consulte o resultado acima e ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  O enriquecimento de conversas não estará disponível. O resto do Ostler é instalado normalmente; execute novamente sem --allow-plaintext para integrar o motor de memória de conversas."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="A instalação do motor de memória de conversas falhou (clonagem)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  Procurado em: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  Isto significa normalmente que a app do instalador foi criada sem"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  o pacote cm048_pipeline incluído em"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Transfira novamente o instalador ou"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  execute novamente com --allow-plaintext para uma instalação de desenvolvimento/CI."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="Motor de memória de conversas não encontrado. O enriquecimento de conversas não pode funcionar sem ele."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="Configuração do motor de memória de conversas ignorada (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="O código-fonte do motor de memória de conversas foi encontrado, mas falta o pyproject.toml; a configuração do venv foi ignorada."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="O Colima não conseguiu iniciar. A tentar o Docker Desktop como alternativa..."
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="Não foi possível instalar o GNU coreutils; os passos longos serão executados sem limite de tempo (uma linha de progresso continua a mostrar que estão a funcionar)."
MSG_WARN_COLIMA_START_RETRY="O Colima não arrancou corretamente (o socket do Docker não estava pronto). A tentar novamente dentro de %ss..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="Causas comuns: a etiqueta v%s ainda não foi publicada, a rede está desligada,"
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  consent_cli stderr (first 400 chars):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  O script de consola não foi criado em %s; pode faltar a entrada [project.scripts] no pyproject.toml."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="A continuar porque foi indicado --allow-plaintext."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="A continuar a instalação. Execute novamente \`ostler-fda\` depois de diagnosticar o erro acima."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="A continuar sem o preenchimento automático a partir do cartão de contacto – o Ostler vai perguntar-lhe."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  As conversas enviadas para o iMessage falharão silenciosamente até"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="Não foi possível alterar as definições de suspensão. Ative \"Impedir suspensão automática quando ligado à corrente\" em Definições do Sistema > Energia."
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="Não foi possível alterar as definições de suspensão. Ative \"Impedir suspensão automática\" em Definições do Sistema > Energia."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="Não foi possível transferir o ostler-assistant v%s de %s"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="Não foi possível extrair o mbox do Gmail do zip do Takeout – a ignorar."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="Não foi possível extrair o ficheiro tarball do ostler-assistant; o LaunchAgent será ignorado."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="Não foi possível encontrar a CLI do Tailscale. Pode configurá-la manualmente mais tarde."
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Could not install legal/ consent-strings package; continuing"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="Não foi possível instalar o diretório LICENSES/ (não fatal)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="Não foi possível instalar o ostler_security no venv do Hub."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="Não foi possível instalar o THIRD_PARTY_NOTICES.md (não fatal)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="Não foi possível obter o agente Doctor (falharam tanto o incluído como o clonado)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="Ficheiros do Ostler Doctor não encontrados. São necessários para o processo de emparelhamento com o iOS (o Ostler.app incorpora :8089/pair-ios num iframe)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  Procurado em: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  Isto significa normalmente que o instalador .app foi criado sem"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  o código-fonte doctor/agent/ incluído em"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Transfira novamente o instalador ou"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  execute de novo com --allow-plaintext para uma instalação de desenvolvimento/CI."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Instalação do Doctor interrompida: é necessário para o processo de emparelhamento com o iOS. Transfira novamente o instalador ou use --allow-plaintext para uma instalação de desenvolvimento/CI."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="Não foi possível obter os scripts de ingestão de email (falharam tanto os incluídos como os clonados)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="Não foi possível obter os scripts hub-power (falharam tanto os incluídos como os clonados)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="Não foi possível obter os scripts wiki-recompile (falharam tanto os incluídos como os clonados)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="Não foi possível abrir automaticamente o URL da Chrome Web Store: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="Não foi possível guardar o region.json (a continuar - o Doctor irá assinalar)"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="Não foi possível registar que a chave de recuperação foi entregue. O resumo desta execução continua correto, mas uma execução posterior pode não conseguir sabê-lo e voltar a avisar – se tiver de falhar, é preferível que falhe neste sentido."
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="Your recovery key was not saved to Keychain. Write it down and keep it somewhere safe, away from this Mac."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="Não foi possível iniciar o Ollama automaticamente."
MSG_FAIL_OLLAMA_PORT_IN_USE="Outro programa já está a usar a porta 11434, de que o Ostler precisa para a sua IA local. O Ostler não conseguiu iniciar a sua própria cópia, pelo que a instalação parou aqui em vez de ficar a meio.

  O que está a ocupar a porta: %s
  O erro exato está em: %s

Normalmente é uma cópia do Ollama que já tinha, ou uma deixada a funcionar por uma instalação anterior do Ostler. Feche-a (ou reinicie este Mac) e execute o instalador novamente."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="Não foi possível atualizar o pipeline (sem ligação?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="Não foi possível escrever o pipeline_signals.json. O diagnóstico do Doctor para o Mail vazio usará valores predefinidos seguros até à próxima instalação ou ciclo."
MSG_WARN_CURL_SAID="O curl indicou:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="Diretório não encontrado: %s – a ignorar a importação."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="O Docker não iniciou em %s segundos."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="O Docker está instalado, mas não está a funcionar. Será necessário iniciá-lo."
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="O comando Docker está neste Mac, mas não há nada a funcionar por trás dele. No macOS, o comando Docker é apenas um cliente – precisa de um motor, como o Colima ou o Docker Desktop, para executar o que quer que seja. O instalador irá configurar um."
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="Diagnóstico do ambiente de contentores - cliente docker: %s | colima: %s | Docker Desktop: %s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="O contentor da wiki foi iniciado, mas nada respondeu em http://localhost:8044 em 60 segundos. Considere a wiki como NÃO a funcionar – o código de saída do comando de arranque não prova que a página carrega."
MSG_WARN_WIKI_NOT_RESPONDING="A sua wiki não está a responder (127.0.0.1:8044). Funciona num contentor, pelo que normalmente significa que o ambiente de contentores parou. Abra o Ostler Doctor em http://localhost:8089/doctor para ver o motivo."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama a meio da instalação e bloqueiam as verificações de disponibilidade."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  marcadores iniciais (canais ainda a ligar + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="A instalação do LaunchAgent de ingestão de email falhou. Veja o resultado acima."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="A instalação do LaunchAgent da ponte iMessage falhou. As respostas por iMessage ao utilizador do assistente não funcionarão até executar o instalador novamente ou executar o INSTALL_SNIPPET.sh manualmente."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Os scripts da ponte iMessage não estão incluídos e foi indicado --allow-plaintext; a instalação do LaunchAgent será ignorada. As respostas por iMessage ao utilizador do assistente não funcionarão."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="A encriptação não vai funcionar."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="A encriptação não vai funcionar, e"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="certifique-se de que a etiqueta PWG_KNOWLEDGE_REPO fixada a inclui."
# NEEDS REVIEW: Fragment likely continues a previous line ending in 'Apple' (Apple Events); check that the joined pt-PT sentence reads correctly.
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  permissão de Eventos para a app Mensagens)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="O extrator FDA terminou com código diferente de zero (%s). Últimas 20 linhas de saída:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="O módulo de extração FDA não está incluído neste instalador."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="Esperado em: Contents/Resources/ostler_fda/ (dentro da .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="Causa mais provável: uma regressão na compilação omitiu a cópia do fornecedor. Transfira novamente a .app a partir de ostler.ai/install."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="O módulo de extração FDA não está incluído. A continuar porque --allow-plaintext foi indicado – a extração instantânea de dados será ignorada."
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="O módulo de extração de dados está no disco, mas as suas dependências não foram instaladas, pelo que não pode ser carregado:"
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="A continuar porque --allow-plaintext foi indicado – a atualização agendada dos dados vai falhar em cada execução."
MSG_WARN_FILEVAULT_NOT_ENABLED="O FileVault NÃO está ativado."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="Não foi possível ativar o primeiro mês gratuito neste momento; a instalação vai continuar. Abra a app Ostler no iPhone depois de emparelhar para resolver."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="O Acesso total ao disco não foi concedido ao Terminal."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="%s GB de RAM detetados. Vai obter o assistente compacto (gemma4:e2b) – fiável, preciso, com resposta em menos de um segundo em perguntas curtas, com chamadas de ferramentas e um sincero “não sei” quando não sabe. Para respostas mais completas a perguntas mais longas, 24 GB ou mais desbloqueiam o assistente padrão (qwen3.5:9b). Pode mudar de Mac mais tarde, reinstalando."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="A importação RGPD teve erros. Pode executá-la novamente com:"
MSG_WARN_GRAPH_DB_PULL_RETRY="A transferência da base de dados não terminou (tentativa %s de %s). A tentar novamente dentro de %ss..."
MSG_WARN_GRAPH_DB_UP_RETRY="As bases de dados do grafo de conhecimento não iniciaram (tentativa %s de %s). A tentar novamente..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="A importação RGPD faz parte da instalação do produto. Sem ela, o seu grafo social (LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google Calendar) não pode ser importado."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="A importação RGPD ficará indisponível nesta instância até que o pipeline de importação seja reinstalado."
MSG_WARN_GIT_SAID="O Git indicou:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  Falha na verificação de estado: ostler-knowledge --version não produziu saída."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  Falha na verificação de estado: não foi possível carregar o motor de memória de conversas (o pwg-convo ou a importação do respetivo pipeline não terminou corretamente)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="O instalador do Homebrew terminou com o código %s. Seguem-se as últimas 30 linhas de %s:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Registo de instalação do Homebrew (final) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="A instalação pip do Doctor terminou com o código %s. Seguem-se as últimas 30 linhas de %s:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Registo de instalação pip do Doctor (final) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="A instalação pip do pipeline terminou com o código %s. Seguem-se as últimas 30 linhas de %s:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- Registo de instalação pip do pipeline (final) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Falha na instalação do LaunchAgent de energia do Hub. Consulte a saída acima."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="Os scripts de energia do Hub não foram encontrados no caminho esperado do pacote."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  A .app do instalador parece não ter vendor/hub_power/"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  em Contents/Resources/hub-power/. A limitação consoante a bateria não será instalada; o resto da instalação vai continuar."
MSG_WARN_ICAL_SERVER_FAILED="Não foi possível iniciar a API do assistente; a app Ostler no iPhone terá acesso limitado até à próxima execução da instalação."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - Falha ao obter a imagem (rede, espaço em disco ou tempo limite do repositório de imagens)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="Não foi possível escrever o sinal FDA do iMessage em pipeline_signals.json. O painel do Doctor pode não mostrar automaticamente o cartão de Acesso total ao disco."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="O servidor IMAP está vazio – tente novamente."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="Permissão de Automatização do iMessage: não concedida (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="Permissão de Automatização do iMessage: teste inconclusivo."
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="O histórico do iMessage (chat.db) não é legível: o Acesso total ao disco ainda não foi concedido ao daemon do Ostler. A leitura do histórico do iMessage permanece desativada até o conceder em Definições do Sistema > Privacidade e segurança > Acesso total ao disco."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="A abrir Definições do Sistema > Privacidade e segurança > Automatização. Assinale a linha Mensagens para OstlerInstaller (ou Terminal) para ativar o envio por iMessage."
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="Não é um endereço de email completo, por isso foi ignorado: %s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="Introduza pelo menos um endereço de email completo (por exemplo, you@example.com)."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="O iMessage precisa de pelo menos um contacto autorizado. Tente novamente ou"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="Pipeline de importação não disponível (repositório privado - apenas para testadores beta)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="Pipeline de importação não incluído no instalador. Falha crítica ignorada."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="Pipeline de importação não incluído no instalador. Este é o caminho de instalação do produto; o pacote Python contact_syncer deve vir dentro do pacote .app."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX significa que o assistente vai ler todos os emails que receber."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Espaço em disco insuficiente para o volume de saída da wiki"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Mac Intel detetado – o desempenho será limitado. Recomenda-se Apple Silicon."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s é um anfitrião de fornecedor de cloud."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="JWT_SECRET em %s consta da lista de bloqueio; a regenerar para manter os serviços do grafo de conhecimento importáveis"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="JWT_SECRET em %s é demasiado curto (%s < %s carateres); a regenerar"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="Repositório de conhecimento clonado, mas falta o pyproject.toml; configuração do venv ignorada."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="A instalação do serviço de conhecimento falhou (clonagem)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="Licença: %s é distribuído sob os Termos de Utilização do Gemma da Google, não sob Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="As instalações em MacBook precisam disto para a gestão da bateria e da suspensão."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="A permissão de Contactos do macOS foi recusada ou ainda não foi concedida."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="O macOS NÃO a pede a partir de um script – tem de a conceder manualmente."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="As instalações em Mac Mini não são afetadas; os utilizadores de MacBook devem tentar novamente."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="Os dados do Mail ainda podem ser importados manualmente:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  Nova tentativa manual: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  Nova tentativa manual depois de resolvida a causa:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Não foi selecionado o Apple Mail nem IMAP personalizado – a usar o Apple Mail por predefinição."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="Nenhuma chave de acesso definida; as bases de dados não serão encriptadas."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="Uma instalação anterior gerou a sua chave de recuperação mas não terminou, pelo que nunca lhe foi mostrada. Não pode ser recuperada – nunca é guardada em lado nenhum, nem aqui."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="A sua frase-passe continua a funcionar e nada está bloqueado hoje. Mas, neste momento, não há forma de voltar a entrar se alguma vez a esquecer."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="Contacte o suporte para configurar de novo a segurança, o que lhe mostrará uma nova chave de recuperação para guardar."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="As frases-passe não coincidem. Tente novamente."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="A configuração da frase-passe falhou. Saída:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="Entrada vazia. Frase-passe ignorada."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="A frase-passe deve ter pelo menos 12 carateres. Tente novamente."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="É necessária uma frase-passe para encriptar os seus dados."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="Isso não é um número internacional. Use um + inicial, seguido do indicativo do país e do resto do número, por exemplo +447700900123. Tente novamente."
MSG_WARN_OLLAMA_NOT_RESPONDING="O Ollama não responde"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s falhou (tentativa %s/3). A tentar novamente dentro de %ss..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="Apenas %s GB livres. Recomendamos pelo menos 35 GB (imagens Docker + modelo de IA + dados)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="A funcionar com bateria, o LaunchAgent de energia do Hub (passo 3.14) pode pausar"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="ou execute novamente o instalador e escolha outro canal."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="ou está adiantado em relação ao pipeline de lançamento da Fase B. Execute novamente o instalador quando o"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="O ostler-assistant doctor reportou %s erro(s)."

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="O Ostler terminou, mas ocorreram %s erro(s) durante a instalação."
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  Os detalhes completos estão em ~/.ostler/logs/install.log. O Ostler iniciará na mesma; abra o Doctor para ver o que requer atenção."
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="O Ostler terminou, mas %s passo(s) da instalação não foram concluídos corretamente: %s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="O Ostler terminou sem erros durante a instalação."

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="O ostler-assistant foi extraído, mas a verificação de --version falhou."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="A instalação do LaunchAgent do assistente Ostler falhou após 3 tentativas. Consulte o resultado de diagnóstico acima e abaixo."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="A tentativa %s de instalação do LaunchAgent do assistente Ostler falhou; a tentar novamente."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="Stderr completo do daemon em: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="Último excerto do stderr:"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="O ostler-assistant v%s é apenas para Apple Silicon (detetado: %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  Não foi possível instalar a dependência de armazenamento cifrado no venv da memória de conversas; o enriquecimento de conversas não será executado."
MSG_INFO_COACH_DB_READY="  Coaching database ready, encrypted: %s"
MSG_WARN_COACH_DB_NOT_CREATED="  Could not prepare the encrypted coaching database (it will be created on the first coaching note): %s"
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  Origem da dependência de armazenamento cifrado não encontrada em SCRIPT_DIR; o motor de memória de conversas não pode ser carregado e o enriquecimento de conversas não será executado."
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - imagem ostler-wiki-compiler ainda não disponível para transferência (registo não configurado)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="O Oxigraph não está a responder"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - O Oxigraph ainda não está operacional nesta fase (consulte os registos acima)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="As palavras-passe não coincidem (ou estavam vazias). Tente novamente."
# NEEDS REVIEW: source asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="A instalação principal demora normalmente de 45 minutos a algumas horas (transferências do Docker e do Ollama + configuração inicial), mais tempo com uma ligação lenta ou num Mac com muitos anos de histórico. Longos períodos sem atividade são normais – está a transferir e a configurar em segundo plano, não está bloqueado."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  A instalação com pip falhou; o motor de memória de conversas não estará disponível."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  A instalação com pip falhou; o email-ingest recorrerá ao Python do sistema (pode também falhar durante a execução)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  A instalação com pip falhou; o ostler-knowledge não estará disponível."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  A instalação com pip falhou; o motor de ingestão de email não está disponível. O LaunchAgent horário continuará a gerar ficheiros mbox, mas não os poderá ingerir no grafo até a situação ser reparada."
MSG_WARN_CM021_SOURCE_NOT_FOUND="Origem do motor de ingestão de email não encontrada no pacote da app; a tarefa horária em segundo plano guardará os ficheiros de correio sem os ingerir."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="Origem do ostler_fda não encontrada no pacote da app; o LaunchAgent do email-ingest recorrerá ao Python do sistema durante a execução."
MSG_WARN_PIP_SAID="O pip indicou:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="Ligue o Mac à corrente elétrica para a instalação completa."
MSG_WARN_PORT_1_ALREADY_USE_PID="A porta %s já está a ser utilizada por %s (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - A porta 3000 já está a ser utilizada por outro serviço"
MSG_WARN_POWER_SOURCE="Fonte de energia: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="A instalação do sqlcipher3 falhou."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="A instalação do sqlcipher3 falhou. As bases de dados não serão cifradas."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="Python 3 não encontrado. A instalar o Python 3.12..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="O Python %s é demasiado antigo (é necessário 3.10+). A instalar o Python 3.12..."
MSG_WARN_QDRANT_NOT_RESPONDING="O Qdrant não está a responder"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         Leia https://ai.google.dev/gemma/terms antes de utilizar comercialmente."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="Leia a versão pública em https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="O Redis não está a responder"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="a versão for lançada, ou instale o binário manualmente:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="A repetir – introduza um anfitrião autoalojado, ou prima Ctrl-C e reinicie o instalador escolhendo o Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="execute novamente o instalador com o iMessage desmarcado para o ignorar."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="A EXECUTAR COM --allow-plaintext: encriptação desativada. NÃO USAR EM PRODUÇÃO."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  Execute \`%s doctor\` após o primeiro arranque"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="Execute 'tailscale ip --4' depois de iniciar sessão e adicione o endereço à app iOS."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Falha ao copiar a extensão do Safari; pode instalá-la manualmente mais tarde"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="A extensão do Safari foi instalada, mas não estava disponível nenhum token de extensão para a emparelhar; a captura de navegação permanecerá desativada até executar novamente o instalador"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="Não foi possível emparelhar a extensão do Safari com este Hub; a captura de navegação permanecerá desativada até executar novamente o instalador"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="Módulo de segurança não encontrado. A configuração da chave de acesso será ignorada."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  Procurado em: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  Isto significa normalmente que a .app do instalador foi criada sem"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  o pacote ostler_security incluído em"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Transfira novamente o instalador ou"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  execute novamente com --allow-plaintext para uma instalação de desenvolvimento/CI."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="A configuração de segurança falhou. A continuar sem encriptação da base de dados."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="A configuração de segurança falhou. Resultado:"
MSG_WARN_SEE_STDERR_FRAGMENT="  Consulte %s para ver o fragmento de stderr."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="A ignorar a instalação do binário. O config.toml criado pelo assistente mantém-se."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="A ignorar a instalação do LaunchAgent do Doctor."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="A ignorar a instalação do LaunchAgent de importação de e-mail."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="A ignorar a instalação do LaunchAgent. As implementações em Mac Mini não são afetadas."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="A ignorar a instalação do LaunchAgent. Experimente: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="A ignorar a instalação do LaunchAgent de recompilação da wiki."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="Algumas portas estão em uso. Os contentores Docker podem não arrancar."
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="A porta %s já está a ser usada por %s (PID %s), que pertence a esta conta. Feche-o e execute o instalador novamente."
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="A porta %s já está a ser usada por um programa pertencente a OUTRA conta de utilizador neste Mac. O Ostler não a pode partilhar e, se arrancasse mesmo assim, poderia misturar os dados das duas contas. Termine a sessão da outra conta ou instale o Ostler num Mac onde seja a única conta a usar esta porta."
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="O Ostler não consegue iniciar as suas bases de dados porque as portas de que precisa já estão ocupadas."
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="Pare o que estiver a usar as portas indicadas acima e execute o instalador novamente."
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="Não foi possível verificar se a porta %s está livre. Isto não é o mesmo que a porta estar livre."
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="Uma ou mais verificações de portas não puderam ser executadas, pelo que não é possível excluir um conflito com outro programa."
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="Não foi possível executar a verificação de portas mais fiável neste Mac, pelo que as verificações seguintes são menos completas do que o habitual."
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="O Ostler não conseguiu confirmar que essas portas estão livres e não iniciará as suas bases de dados numa porta que não verificou. Contacte o suporte com o registo de instalação."
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="Não foi possível remover um item de arranque antigo do Colima. A sua wiki pode não carregar após reiniciar; contacte o suporte."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="Pare os serviços em conflito ou altere as portas em docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="O Tailscale não iniciou sessão em 3 minutos. Pode voltar a isto mais tarde nas Definições."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="O IP do Tailscale foi escrito em .env, mas uma leitura posterior não o conseguiu ver. A app Ostler no seu iPhone pode não o detetar – se isso acontecer, execute novamente install.sh --repair."
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="Não foi possível guardar a sua resposta sobre o acesso remoto, por isso a próxima reinstalação voltará a perguntar. Tudo o resto não é afetado."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="A instalação do Tailscale falhou – pode instalá-lo mais tarde a partir de tailscale.com"
MSG_WARN_TAILSCALE_STATE_UNREADABLE="Este Mac tem definições do Tailscale existentes que não puderam ser lidas, por isso não sabemos se ainda está ligado à sua rede. Escolha abaixo – se já estiver ligado, configurá-lo novamente não causa problemas."
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="os serviços instalados recusam-se a iniciar sem eles."
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  isto esteja resolvido. Consulte o aviso de próximos passos para saber como corrigir."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  para inspecionar. cron-delivery / imessage-tcc são comuns"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  Tente: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  Tente: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="Opção '%s' não reconhecida; a usar iMessage + email por predefinição."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="Opção não reconhecida. A usar a recomendada."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  A atualização falhou; a continuar com a cópia existente."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="Utilize o Apple Mail (recomendado acima) para essa conta – o Ostler nunca guarda palavras-passe na nuvem."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="A usar INBOX. O assistente vai ler todos os emails recebidos."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="O contentor do Vane foi iniciado, mas http://localhost:3000 não respondeu em 60 s."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="O Vane (pesquisa web local) não conseguiu iniciar. Causas comuns:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  A pesquisa web é opcional; o resto do Ostler funciona sem ela."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="Recomendamos vivamente uma etiqueta/pasta dedicada."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="O WhatsApp precisa de um número de telefone para enviar o resumo. Tente novamente,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="A wiki foi compilada, mas o contentor wiki-site não conseguiu iniciar."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="A primeira compilação da wiki falhou. Causas comuns:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="Não foi possível carregar o LaunchAgent de atualização da wiki do primeiro dia. A reconstrução diária da wiki continua a funcionar; a sua wiki será simplesmente atualizada no dia seguinte, em vez de dentro de uma hora."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="A instalação do LaunchAgent de recompilação da wiki falhou. Consulte o resultado acima."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="A wiki não será atualizada automaticamente; a reconstrução manual continua disponível:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="A configuração do assistente de instalação mantém-se; o binário continua preparado. Nova tentativa manual:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="O seu assistente precisa de um nome. Escolha uma das sugestões acima ou escreva o seu."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="Pode voltar a conceder acesso em Definições do Sistema > Privacidade e segurança > Contactos."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="Pode executar a configuração de segurança mais tarde: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="Pode ser necessário instalar manualmente: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  real:     %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="O pacote Ostler RemoteCapture não estava presente em %s após a extração. O tarball da versão pode estar corrompido."
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="Não foi possível criar ou aceder a %s, pelo que o Ostler RemoteCapture não tem onde ser instalado. Trata-se de um problema de permissões da pasta, não do descarregamento."
MSG_ERR_CM042_RENAME_FAILED="O Ostler RemoteCapture foi descarregado e descompactado corretamente, mas não foi possível movê-lo para %s. A app descompactada ficou em /Applications. Não é um problema de assinatura."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify indicou:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  A recusar preparar um pacote que não corresponde à soma de verificação publicada."
MSG_ERR_CM042_SHA_256_MISMATCH="A soma de verificação SHA-256 do tarball do Ostler RemoteCapture não coincide."
MSG_ERR_CM042_PIN_FAILED="O Ostler não conseguiu confirmar que este descarregamento do RemoteCapture é genuíno, por isso não foi instalado."
MSG_ERR_CM042_VERSION_UNKNOWN="Esta versão do RemoteCapture não é reconhecida pelo Ostler, por isso não foi instalada."
MSG_ERR_CM042_SIDECAR_DISAGREES="A soma de verificação publicada com este descarregamento do RemoteCapture não corresponde ao ficheiro, por isso não foi instalado."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess indicou:"
MSG_ERR_CM042_VERIFY_FAILED="A verificação da assinatura / notarização do Ostler RemoteCapture falhou."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv indicou:"
MSG_ERR_EXPECTED="  esperado: %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief indicou: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="O binário ostler-assistant em %s não é um executável Mach-O."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="A soma de verificação SHA-256 do tarball do ostler-assistant não corresponde."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  Recusa-se a preparar um binário que não corresponde à soma de verificação publicada."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="Recusa-se a remover a quarentena ou a carregar o LaunchAgent."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="Execute o instalador novamente quando o tarball de origem estiver corrigido."
MSG_ERR_URL="  url:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Os Macs Intel não são suportados. O Ostler requer Apple Silicon (M1, M2, M3 ou M4)."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="São necessários pelo menos 16 GB de RAM. Tem %s GB. Recomendam-se 24 GB."
MSG_FAIL_CM042_SIGNATURE_FAILED="A instalação do Ostler RemoteCapture foi interrompida: falha na verificação da assinatura ou da notarização. O pacote foi deixado em /Applications para o suporte. Envie um email para support@ostler.ai e execute o instalador novamente."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="Não foi possível transferir %s após 3 tentativas. Verifique a rede e execute o instalador novamente."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="Não foi possível transferir nomic-embed-text após 3 tentativas. Verifique a rede e execute o instalador novamente."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="O Docker não está disponível. Execute o instalador novamente para instalar o Colima."
MSG_FAIL_CONTAINER_CLIENT_MISSING="O comando docker não existe neste Mac, por isso o Ostler não consegue iniciar os serviços de que precisa. Execute o instalador novamente; se voltar a falhar, envie-nos o registo em %s."
MSG_FAIL_CONTAINER_ENGINE_ABSENT="O Ostler precisa de um ambiente de execução de contentores e nenhum está a responder neste Mac. A sua wiki, o seu grafo de conhecimento e o seu índice de pesquisa funcionam todos dentro de contentores, por isso a instalação parou aqui em vez de terminar e os deixar em falta. Para resolver: abra o Terminal e execute 'colima start' e, depois, execute este instalador novamente. Se utiliza o Docker Desktop, abra-o, aguarde que o ícone da baleia estabilize e execute novamente. O registo completo está em %s."
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="O Docker não ficou pronto a tempo de iniciar as bases de dados do grafo de conhecimento. Certifique-se de que o Colima ou o Docker está em execução e execute o instalador novamente."
MSG_FAIL_GRAPH_DB_PULL_FAILED="Não foi possível transferir as imagens das bases de dados do grafo de conhecimento após várias tentativas. Normalmente, trata-se de um problema de rede. Verifique a ligação à internet e execute o instalador novamente."
MSG_FAIL_GRAPH_DB_UP_FAILED="As bases de dados do grafo de conhecimento foram transferidas, mas não foi possível iniciá-las. Execute o instalador novamente; se continuar a acontecer, abra o Terminal e execute: cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="O Ostler não conseguiu concluir um pedido autenticado à base de dados do grafo de conhecimento. Tentou duas vezes, com dois segundos de intervalo, e ambas as tentativas foram recusadas. Ainda não sabemos porquê: a base de dados pode ainda estar a iniciar, ou a credencial que o Ostler guarda pode não ser a esperada. Os seus dados não foram alterados. Executar o instalador novamente resolve muitas vezes e, se resolver, gostaríamos na mesma de saber – envie-nos o registo da instalação, porque é uma falha que estamos a tentar reproduzir ativamente."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="O módulo de extração FDA não consta do pacote do instalador. Transfira novamente a .app a partir de ostler.ai/install ou execute novamente com --allow-plaintext para dev/CI."
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="O módulo de extração de dados foi instalado, mas não pode ser carregado, pelo que a atualização em segundo plano falharia sempre que fosse executada. O resultado completo foi guardado em %s – execute o instalador novamente e anexe esse ficheiro se contactar o suporte (Referência: ERR-10-FDA-DEPS-IMPORT)."
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="Erro interno: o módulo de extração de dados foi colocado dentro do pacote da aplicação, o que invalidaria a sua assinatura. É uma falha de compilação, não um problema do seu Mac. Transfira novamente a .app a partir de ostler.ai/install (Referência: ERR-10-FDA-DEPS-UNSAFE-PATH)."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Falha na instalação das dependências do Doctor. O resultado completo foi guardado em %s – anexe-o ao enviar email para support@ostler.ai (Referência: ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="Falha na instalação das dependências do pipeline de importação. O resultado completo foi guardado em %s – anexe-o ao enviar email para support@ostler.ai (Referência: ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Falha na instalação do Homebrew. O resultado completo foi guardado em %s – anexe-o ao enviar email para support@ostler.ai."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="Falha na instalação do pipeline de importação. O pacote contact_syncer é necessário para a instalação de produto. Execute novamente com --allow-plaintext para dev/CI ou transfira novamente o instalador e tente de novo."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="É necessário acesso sudo para desativar a suspensão e instalar o Homebrew. Execute novamente quando estiver pronto."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Nem o Colima nem o Docker Desktop conseguiram iniciar. Instale o Docker Desktop e execute novamente."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="Não há espaço em disco suficiente (%s GB). Liberte espaço e tente novamente."
MSG_FAIL_MACOS_BELOW_FLOOR="O macOS %s é anterior ao suportado pelo Ostler. O Ostler requer o macOS %s ou posterior: a aplicação de instalação foi criada para essa versão e não abre em versões anteriores. Atualize o macOS e execute o instalador novamente."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="Nenhuma chave de acesso definida e nenhuma configuração de segurança existente. Execute novamente com --allow-plaintext para dev/CI ou execute o instalador novamente e confirme as informações sobre o Touch ID."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="O motor de memória de conversas é necessário. Execute novamente com --allow-plaintext para dev/CI ou corrija o pacote em falta indicado acima e tente de novo."
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="O daemon do Ostler incluído (v%s em %s) não suporta o comando 'run-source' de que este instalador precisa para encaminhar a ingestão através do Acesso total ao disco. Trata-se de uma incompatibilidade de versões dentro do pacote do instalador: instalá-lo deixaria todas as fontes de ingestão avariadas em silêncio e o produto ficaria desatualizado sem qualquer erro visível. Transfira novamente a .app a partir de ostler.ai/install e tente de novo (Referência: ERR-11-DAEMON-RUN-SOURCE-SKEW)."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="Falha na instalação do ostler_security. Execute novamente com --allow-plaintext para dev/CI ou corrija o erro do pip indicado acima e tente de novo."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="Falha na configuração da chave de acesso. Execute novamente com --allow-plaintext para dev/CI ou corrija o erro indicado acima e tente de novo."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="O sqlcipher3 é necessário para as bases de dados cifradas. Execute novamente com --allow-plaintext para dev/CI ou corrija o erro do pip indicado acima e tente de novo."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Este instalador destina-se apenas ao macOS."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="A instalação das Ferramentas de Linha de Comando do Xcode não terminou em 15 minutos. Abra o Terminal e execute 'xcode-select --install', clique em Instalar na janela do macOS, aguarde que termine e execute este instalador novamente."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="A instalação do Homebrew indicou sucesso, mas /opt/homebrew/bin/brew não existe. Consulte %s para ver a transcrição completa. Recuperação: abra o Terminal e execute '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' e, depois, execute o instalador novamente."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="O Homebrew está instalado em /opt/homebrew/bin/brew, mas o comando 'brew' não está no PATH após a avaliação do shellenv. Abra um novo Terminal e execute o instalador novamente."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' indicou sucesso, mas o colima não está no PATH. Consulte %s para ver as falhas do Homebrew. Recuperação: abra o Terminal e execute manualmente 'brew install colima docker docker-compose' e, depois, execute o instalador novamente."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' indicou sucesso, mas a CLI do docker não está no PATH. Consulte %s. Recuperação: execute 'brew install docker' manualmente e volte a executar o instalador."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="The Ollama install reported success but its binary is missing. Check %s, then re-run the installer."
MSG_FAIL_OLLAMA_PIN_DOWNLOAD="Could not download Ollama %s. Check your internet connection, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_PIN_SHA256="The Ollama %s download did not match its recorded fingerprint, so it was not installed. This can mean the download was damaged or altered. Re-run the installer; if it happens again, contact support. Details: %s"
MSG_FAIL_OLLAMA_PIN_UNPACK="Ollama %s downloaded but could not be unpacked. Check free disk space, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_AGENT_NOT_PINNED="The local AI service is set to run %s instead of the copy of Ollama this installer verified (%s), so it would not stay on a tested version. The install has stopped. Re-run the installer; if this repeats, contact support. Details: %s"
MSG_FAIL_EMBED_HEALTHCHECK="O Ollama está em execução, mas o modelo de embeddings não devolveu nenhum vetor (HTTP diferente de 200, ou resultado vazio). O cartão Pessoas, a pesquisa e a navegação ficariam todos vazios. Consulte %s. Recuperação: certifique-se de que a app Ollama (não a fórmula do Homebrew) está instalada e em execução e volte a executar o instalador."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' indicou sucesso, mas o sqlcipher não está no PATH. Consulte %s. Recuperação: execute 'brew install sqlcipher' manualmente e volte a executar o instalador."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' não criou /Applications/Tailscale.app. Consulte %s. Recuperação: transfira o Tailscale a partir de https://tailscale.com/download/macos, arraste-o para /Applications e volte a executar o instalador."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' indicou sucesso, mas o binário python3.11 não existe em /opt/homebrew/opt/python@3.11/bin/python3.11. Consulte %s. Recuperação: execute 'brew reinstall python@3.11' e volte a executar o instalador."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="Encontrámos as suas respostas anteriores"
MSG_PROMPT_REUSE_SETTINGS_HELP="Detetámos uma tentativa de instalação anterior neste Mac. As perguntas a que já respondeu (nome, nome do assistente, fuso horário, indicativo do país, canais, etc.) serão reutilizadas para não ter de as introduzir novamente. Escolha Sim para continuar de onde ficou, ou Não para voltar a percorrer as perguntas desde o início."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Respostas anteriores encontradas: nome = %s, assistente = %s, fuso horário = %s."

MSG_PROMPT_PERMS_OK_TITLE="Pronto para continuar?"
MSG_PROMPT_PERMS_OK_HELP="O macOS vai pedir acesso a Contactos e a Ficheiros e pastas. O Acesso total ao disco, opcional, pode ser concedido mais tarde."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Nome completo (como aparece nos seus contactos)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Nome completo (p. ex., Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="Que nome deve o seu assistente usar consigo?"
MSG_PROMPT_USER_ID_HELP="Um nome curto com que o seu assistente se dirigirá a si (p. ex., 'Andy', 'Andrew', 'Sra. Smith'). É o que aparece nos resumos matinais e nas respostas da conversa. Diferente do nome completo acima."

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
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="Aqui estão os seus calendários. Parecem corretos?"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="Calculámos de quem é cada um, para que o seu resumo nunca confunda as viagens de uns e de outros."
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="Postos de parte automaticamente, não usados no seu resumo:"
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="seu"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="%s evento"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="%s eventos"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="feriados"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="aniversários"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="sugestões da Siri"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="um calendário que subscreveu"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="lembretes"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="Usar \"%s\" no seu resumo?"
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="Pusemos este de parte porque parece ser %s. Diga que sim se for mesmo a agenda de alguém."
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="De quem é o calendário \"%s\"?"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="Que tipo de calendário é \"%s\"?"
# NEEDS REVIEW: If the installer compares typed input to personal/work/family/shared/other, these values must stay in English; inconsistent with s876 which kept tokens in Engli
MSG_CONFIRM_CALENDAR_TYPE_HELP="Um de: pessoal, trabalho, família, partilhado, outro. Isto define o grau de sensibilidade com que os eventos são tratados."
MSG_CONFIRM_CALENDARS_SAVED="Proprietários dos calendários guardados"
MSG_CONFIRM_CALENDARS_FAILED="Não foi possível guardar os proprietários dos calendários (não crítico; pode defini-los mais tarde)"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="Parece-nos que todos estes perfis correspondem a si (%s). Combiná-los num só?"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="Estes perfis partilham consigo um sinal de identidade forte (um domínio de email, um perfil do LinkedIn ou uma entidade empregadora). Combiná-los evita que o seu assistente trate o seu próprio historial como várias pessoas diferentes. Pode anular isto mais tarde."
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="Alguém partilha o seu nome, mas parece ser uma pessoa diferente (%s). É você ou outra pessoa?"
# NEEDS REVIEW: Confirm whether 'different'/'me' are typed tokens compared by the installer; if not, they should be translated.
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="Escolha 'different' para manter essa pessoa separada (o seu assistente nunca a irá fundir consigo). Escolha 'me' apenas se for mesmo você."
MSG_CONFIRM_IDENTITY_SAVED="Identidade guardada"
MSG_CONFIRM_IDENTITY_FAILED="Não foi possível guardar as escolhas de identidade (não crítico; pode confirmá-las mais tarde)"

# NEEDS REVIEW: source asks for human translation of this key
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="A instalar em segundo plano (cerca de 45 minutos a algumas horas)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="Usar +%s?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Introduza o indicativo do país (p. ex., 44 para o Reino Unido, 1 para os EUA)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Indicativo de país predefinido"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Utilizado para normalizar os números de telefone durante a importação de contactos e para definir a sua região (Reino Unido / UE / EUA / outra) nas predefinições de conformidade legal."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="Detetámos +%s. Usar este indicativo para o seu Hub?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Detetado a partir do seu número de telefone acima. Escolha Sim para o usar ou Não para introduzir outro indicativo."

MSG_PROMPT_TZ_CONFIRM_TITLE="Usar este fuso horário?"
MSG_PROMPT_TZ_CONFIRM_HELP="Fuso horário detetado: %s"
MSG_PROMPT_USER_TZ_TITLE="Introduza o fuso horário (p. ex., Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="Que nome gostaria de dar ao seu assistente?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="O nome no campo é uma sugestão aleatória – escreva por cima o que quiser. Marvin, Samantha, Joshua, Friday, Athena, Sage e Rosie são escolhas populares." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Escreva o nome que quiser – a sugestão é apenas um ponto de partida."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="Como o contactará o seu assistente?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Escolha os canais de mensagens que gostaria que o seu assistente utilizasse. Pode alterar isto mais tarde na secção Doctor da app."

MSG_PROMPT_WHATSAPP_CONSENT_TITLE="Enable WhatsApp messaging for your assistant?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web is a third-party service. By enabling, you accept that your messages route through WhatsApp's own infrastructure before reaching your local Ostler instance, and that WhatsApp (Meta Platforms Ireland Ltd) may suspend, restrict, or terminate your WhatsApp account because of automated use. You can disable this later from Settings."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="O seu número de telefone do WhatsApp"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Número internacional com indicativo do país, p. ex., +447700900123. Apenas dígitos e um + no início – sem espaços, parênteses ou hífenes."
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="Guardado como %s. O WhatsApp precisa do número sem espaços nem parênteses."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Ative o Acesso total ao disco para o assistente Ostler"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="As Definições do Sistema estão abertas em Acesso total ao disco."
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
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Encontre \"%s\" na lista e ative o respetivo interruptor de Acesso total ao disco."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="Não aparece? Arraste \"%s\" da janela do Finder para a lista e ative o respetivo interruptor. A ordem não importa – clique em Concluído antes ou depois; o instalador aguarda até o interruptor estar realmente ativo."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="Não aparece? O Ostler não conseguiu abrir uma janela do Finder. No Finder, prima ⌘⇧G, introduza o caminho abaixo, arraste \"%s\" para a lista e ative o respetivo interruptor. A ordem não importa – clique em Concluído antes ou depois; o instalador aguarda até o interruptor estar realmente ativo."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="A app encontra-se em: %s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="A app encontra-se em: %s – este caminho está na área de transferência, por isso, no Finder, prima ⌘⇧G, depois ⌘V e, por fim, Return."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Concluído"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="Pode clicar em Concluído antes ou depois de ativar o interruptor – o instalador aguarda até estar realmente ativo."

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Permitir que o Ostler leia os dados do seu Mac"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="As Definições do Sistema estão abertas em Acesso total ao disco."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Encontre \"OstlerInstaller\" na lista e ative-o."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Clique em Concluído quando terminar e o Ostler lerá o seu histórico do Safari, as Notas, as iMessages e o Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Concluído"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="Seguinte: Acesso total ao disco para o instalador"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="A seguir, o macOS irá pedir-lhe que conceda Acesso total ao disco ao OstlerInstaller."
# NEEDS REVIEW: Button labels must match the exact macOS pt-PT dialog; verify on a pt-PT Mac (also s916).
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Depois de ativar o interruptor, o macOS irá apresentar uma caixa de diálogo a pedir que escolha 'Sair e reabrir' ou 'Mais tarde'."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Clique em Sair e reabrir. O instalador reabrirá automaticamente e continuará a partir deste passo."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="OK"
MSG_INFO_INSTALLER_FDA_PREWARN="A explicar-lhe o processo de concessão do Acesso total ao disco..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="A abrir as Definições do Sistema para que possa conceder Acesso total ao disco ao instalador..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="Acesso total ao disco concedido ao instalador. A seguir: leitura do Safari, das Notas, das iMessages e do Mail."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="O Acesso total ao disco continua por conceder. A continuar sem ele; pode executar novamente o instalador mais tarde para extrair o Safari / as Notas / as iMessages."
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="O Acesso total ao disco para o instalador está tratado. A parte longa começa agora e decorre quase toda sozinha – mas fique atento a uma caixa de diálogo do macOS a pedir para instalar as ferramentas de programação e volte para alguns minutos de configuração perto do fim."
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="Mais uma autorização (o histórico do Mensagens para o seu assistente) surge perto do fim, depois de o seu assistente estar instalado – nessa altura, indicamos onde a conceder."
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="O Acesso total ao disco ainda é necessário"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="O Ostler está prestes a ler os dados do seu Mac, mas o Acesso total ao disco para o OstlerInstaller continua desativado. Encontre \"OstlerInstaller\" na lista e ative-o."
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="Ou clique em Continuar para concluir a instalação com menos dados – pode concedê-lo e executar novamente o extrator mais tarde."
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="Continuar"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="Contactos autorizados"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="Pessoas de confiança: números de telefone e e-mails do Apple ID (separados por vírgulas). O %s só responde a pessoas desta lista; as mensagens de qualquer outra pessoa são ignoradas. É necessária pelo menos uma entrada.

Por exemplo:
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="Ler o correio através do Mail?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Lê qualquer conta de e-mail que tenha adicionado ao Mail (iCloud, Gmail, Outlook, etc.) através do Acesso total ao disco. Não são guardadas palavras-passe. Recomendado para quase todas as pessoas."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="Adicionar uma conta de correio ao Mail?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="O Mail ainda não tem contas ligadas neste Mac, pelo que o Ostler não terá e-mails para ler. Escolha Sim para abrir agora as Definições do Sistema > Contas de Internet (aí pode adicionar iCloud, Gmail ou Outlook). Escolha Não para ignorar; pode adicionar uma conta mais tarde e o Doctor apresentará um aviso de seguimento se não chegar correio nas próximas 24 horas."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="Importar todo o histórico do Mail?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Por predefinição, o Ostler lê os últimos cinco anos do seu Mail. Se tiver mais do que isso neste Mac e quiser tudo no seu grafo de conhecimento, escolha Sim para importar agora todo o histórico local (pode demorar um pouco mais numa caixa de correio grande). Escolha Não para manter a janela de cinco anos; pode sempre alargá-la mais tarde a partir do Doctor."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="Configurar também um servidor IMAP+SMTP personalizado?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="Apenas para caixas de correio alojadas por si. Mantenha NÃO se as suas contas forem do Gmail, iCloud ou Outlook – estas funcionam melhor através do Mail, acima."

MSG_PROMPT_IMAP_HOST_TITLE="Anfitrião IMAP"
MSG_PROMPT_IMAP_HOST_HELP="Apenas para servidores IMAP próprios ou personalizados. Use o Mail (acima) para Gmail / iCloud / Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="Porta IMAP"

MSG_PROMPT_SMTP_HOST_TITLE="Anfitrião SMTP"
MSG_PROMPT_SMTP_PORT_TITLE="Porta SMTP"

MSG_PROMPT_EMAIL_USERNAME_TITLE="Endereço de e-mail (também usado como nome de utilizador IMAP/SMTP)"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="Quem pode enviar e-mails ao seu assistente?"
MSG_PROMPT_EMAIL_ALLOWED_HELP="Os seus próprios endereços de e-mail, separados por vírgulas. O %s só responde a e-mails de endereços desta lista; o correio de qualquer outra pessoa é ignorado. É necessário pelo menos um endereço. O seu próprio endereço já vem preenchido: altere-o ou adicione outro."

MSG_PROMPT_EMAIL_PASSWORD_TITLE="Palavra-passe (oculta)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Password for your self-hosted IMAP/SMTP server. Stored locally in ~/.ostler/secrets/, not in your settings file, and never sent to Creative Machines. It is saved in plain text: the only thing protecting it is the file's permissions, which allow your macOS account and nobody else. Nothing encrypts it later. Use an app password rather than your main account password."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Confirmar palavra-passe"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="Que pasta deve o assistente vigiar?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="Recomendado: uma etiqueta ou pasta dedicada (p. ex., Ostler). Só leremos as mensagens aí existentes, sem tocar na sua caixa de entrada principal."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="Escreva INBOX novamente para confirmar ou prima Continuar para usar 'Ostler'"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX significa que o assistente lerá todos os e-mails que receber. Recomendamos vivamente uma etiqueta/pasta dedicada."

MSG_PROMPT_EXPORTS_ACK_TITLE="Já pediu as suas exportações de dados?"
MSG_PROMPT_EXPORTS_ACK_HELP="O Ostler importa de cerca de 20 plataformas. A lista completa, com ligações diretas para a página de pedido de cada fornecedor, está em docs.ostler.ai/data-exports.

A maioria dos arquivos demora entre 1 e 3 dias a chegar por e-mail. Quando os ZIP chegarem, coloque-os na pasta Transferências e o Ostler encontrá-los-á automaticamente.

Ignore os que não utiliza; pode sempre importar mais tarde."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="Continuar com o disco SEM CIFRAGEM em repouso?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="O FileVault está DESATIVADO neste Mac, pelo que o disco não está cifrado em repouso.

O que isto significa se continuar: tudo o que o Ostler guarda -- todo o seu grafo pessoal (wiki, conversas, notas de conhecimento) em ~/Documents/Ostler, além de segredos e bases de dados de serviços em ~/.ostler -- é gravado no disco SEM CIFRAGEM. Quem conseguir arrancar a partir deste disco, retirá-lo ou aceder a uma sessão desbloqueada pode ler tudo. O Ostler cifra sempre as suas bases de dados mais sensíveis com uma frase de acesso, mas o resto dos seus dados fica tão protegido quanto o próprio disco.

O FileVault é vivamente recomendado. Pode ativá-lo a qualquer momento em Definições do Sistema > Privacidade e segurança > FileVault -- cifra em segundo plano, sem reinstalar.

Escolha Sim para continuar agora com o disco sem cifragem em repouso (é uma escolha deliberada e informada -- ficará registada).
Escolha Não para parar aqui e ativar primeiro o FileVault; depois, execute novamente o instalador. Em qualquer dos casos, nada correu mal."

MSG_PROMPT_PASSKEY_ACK_TITLE="Pronto para configurar a cifragem do disco"
MSG_PROMPT_PASSKEY_ACK_HELP="As bases de dados sensíveis do Ostler são cifradas com SQLCipher através de uma frase de acesso que escolhe no ecrã seguinte. Terá de a introduzir sempre que iniciar a IU do Hub. É também gerada uma chave de recuperação separada, apresentada uma só vez no fim da instalação. Para uma proteção total em repouso de tudo o que está no seu Mac, mantenha o FileVault do macOS ativado. Prima Continuar quando estiver pronto."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="Definir também uma frase de acesso de recuperação? (recomendado)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="Escolha a sua frase-passe"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="Esta frase-passe cifra o seu grafo de conhecimento e desbloqueia a interface do Hub em cada arranque. Mínimo de 12 caracteres. Não a conseguimos recuperar por si. Recomendamos guardá-la num gestor de palavras-passe."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="Confirme a sua frase-passe"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="Introduza novamente a mesma frase-passe para confirmar."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="Importar estes dados durante a instalação?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="As exportações RGPD encontradas serão importadas para o seu grafo de conhecimento durante a instalação."

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="Palavra-passe da exportação do Disney+"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="O Disney+ fornece a exportação RGPD como uma folha de cálculo protegida por palavra-passe, o que é normal e não é um problema com a sua transferência. Introduza a palavra-passe para importar agora o seu histórico de visualização do Disney+ ou deixe em branco para ignorar; tudo o resto continua a ser importado."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="Tem exportações de dados prontas?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="O Ostler pode importar arquivos de redes sociais e de plataformas – todo o seu historial com amigos, família, locais, opiniões – logo desde o início. Quanto mais o Ostler souber no primeiro dia, mais útil será nesse dia. Também pode adicioná-los mais tarde; sem pressa.

Peça a exportação dos seus dados a cada plataforma (Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp, etc.), transfira os ficheiros ZIP e coloque-os na pasta Transferências.

Por predefinição, o Ostler procura em ~/Downloads. Quer outra pasta? Escolha uma abaixo. Caso contrário, ignore e importe mais tarde."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="Importar mensagens do Gmail deste Takeout?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Lê o conteúdo do Gmail diretamente do ficheiro Takeout. A Google nunca vê o Ostler."

MSG_PROMPT_FDA_PRESET_TITLE="De que fontes do Mac deve o Ostler aprender?"
MSG_PROMPT_FDA_PRESET_HELP="Três predefinições, ou escolha cada fonte. As fontes sensíveis (reconhecimento facial) estão desativadas por predefinição em todas as opções – escolha-as apenas de forma deliberada."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="Recomendado. Inclui Apple Mail, Contactos, Calendário, Notas, Mensagens, Lembretes, histórico do Safari, marcadores do Safari e eventos de Fotografias (datas e locais, sem reconhecimento facial). O histórico do WhatsApp Desktop e o histórico do Chrome são adicionados automaticamente quando a aplicação está instalada. Exclui os dados de reconhecimento facial de Fotografias e quaisquer arquivos de exportação de terceiros."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="Tudo. Todas as fontes que o Ostler consegue ler neste Mac. O reconhecimento facial de Fotografias fica desativado até o selecionar deliberadamente."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="Personalizar. Escolha cada fonte no ecrã seguinte. As fontes sensíveis ficam desativadas até as selecionar."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="Ative ou desative esta fonte de dados."

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
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="A transcrição de voz vai permanecer desativada. Pode ativá-la mais tarde nas Definições."

MSG_PROMPT_CONSENT_INSTALL_TITLE="Ready to install?"
MSG_PROMPT_CONSENT_INSTALL_HELP="Please type INSTALL to confirm you accept the terms."
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Type INSTALL"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Install Ostler"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Cancel"
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Type INSTALL exactly (case does not matter) to confirm, or click Cancel to go back."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="Ligue o seu iPhone e o Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="O Tailscale dá a este Mac um endereço privado estável a que o seu iPhone e o Watch conseguem aceder de qualquer lugar – cifrado e sem exposição pública."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="Guardar a chave de recuperação no Porta-chaves?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="Guarda a sua chave de recuperação de cifragem no Porta-chaves do macOS, em segurança."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="A preencher o seu grafo"
MSG_HYDRATE_CONTACTS_STARTED="A importar os seus contactos para o grafo"
MSG_HYDRATE_CONTACTS_DONE="%s contactos importados"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="Os contactos demoraram mais de %ss, por isso deixámos de esperar e avançámos. Até agora, %s contactos foram importados e o Ostler vai concluir o resto em segundo plano."
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="A carregar o histórico do seu calendário (cinco anos atrás, um ano à frente)"
MSG_HYDRATE_CALENDAR_DONE="%s eventos importados"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  Ainda a carregar o seu calendário (%ss até agora). Um Mac com anos de reuniões demora um pouco."
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="A criar os seus Locais a partir dos sítios onde se reúne"
MSG_HYDRATE_PLACES_DONE="A secção Locais foi criada"
MSG_HYDRATE_PLACES_SKIPPED="Ainda não foram encontrados sinais de localização; os Locais vão sendo preenchidos à medida que o seu calendário for povoado"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="A criação dos Locais encontrou um problema: existem sinais de localização, mas não foi produzido nenhum Local. A sua página de Locais pode ficar vazia. Consulte %s"
MSG_HYDRATE_PLACES_ERROR_WARN="A criação dos Locais não foi concluída (erro inesperado). A sua página de Locais pode ficar incompleta. Consulte %s"
MSG_HYDRATE_WIKI_RECOMPILE="A criar a sua wiki. O Ostler está a escrever um breve resumo para cada uma das suas pessoas, organizações e temas principais, pelo que, numa agenda de contactos grande, isto pode demorar entre alguns minutos e cerca de uma hora. Só acontece uma vez, decorre inteiramente no seu Mac e pode deixá-lo a trabalhar sem receio."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="A verificar o seu índice de pesquisa (%s coleções detetadas)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="A carregar o seu histórico de navegação para o índice de pesquisa"
MSG_INITIAL_HYDRATE_QDRANT_READY="Índice de pesquisa pronto (%s coleções)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="O índice de pesquisa será preenchido em segundo plano depois de a instalação terminar"
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
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="O armazenamento de pesquisa já está ativo; a criar as coleções que ainda faltam: %s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="O índice de pesquisa está incompleto: não foi possível criar %s, embora o armazenamento de pesquisa esteja ativo e a responder. O Ostler continuará a funcionar e o Doctor mostra esta lacuna, mas esta parte da pesquisa ficará vazia até ser corrigida."
MSG_WARN_QDRANT_COLLECTIONS_MISSING="O índice de pesquisa está incompleto: não foi possível criar %s. O Ostler continuará a funcionar e o Doctor mostra esta lacuna."
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="Não foi possível verificar que coleções de pesquisa existem (%s). Isto não significa que estejam em falta."
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="O índice de pesquisa será preenchido em segundo plano depois de a instalação terminar (a aguardar: %s)"
MSG_HYDRATE_DONE="O seu grafo está pronto: %s pessoas, %s eventos"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="O iCloud pode ainda estar a sincronizar os seus contactos – a exportar novamente para incluir tudo o que acabou de chegar."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="Não foram encontrados contactos na app Contactos (locais ou do iCloud). Adicione alguns a Contactos e execute novamente a partir das Definições."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="Não há contactos do iCloud para importar. Pode adicioná-los mais tarde a partir das Definições."
MSG_HYDRATE_SKIPPED_NO_EVENTS="Não há eventos de calendário nos últimos 5 anos. Pode preenchê-los mais tarde a partir das Definições."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="A ler os últimos 90 dias do seu e-mail – o seu e-mail permanece neste Mac (o histórico mais antigo é carregado em segundo plano)"
MSG_HYDRATE_EMAIL_DONE="Foram encontradas %s pessoas no seu e-mail recente"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="Não há e-mail recente para ler. Pode adicionar uma conta de e-mail no Apple Mail e executar novamente mais tarde."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="O leitor de e-mail ainda não está pronto. Pode adicionar uma conta de e-mail no Apple Mail e executar novamente mais tarde."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="O e-mail ainda está a ser carregado em segundo plano. A sua wiki vai sendo preenchida e mostra-lhe em que ponto se encontra."
MSG_HYDRATE_EMAIL_HEARTBEAT="  A ler ainda o seu e-mail (%ss até agora). Isto pode demorar num Mac com anos de histórico."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="Abrir o Apple Mail para iniciar a sincronização?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="Tem %s conta(s) de e-mail configurada(s), mas o Apple Mail ainda não obteve nenhuma mensagem. Podemos abrir o Mail.app agora e aguardar enquanto sincroniza."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="Abrir o Calendário para iniciar a sincronização?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="Tem %s conta(s) de calendário configurada(s), mas o Calendar.app ainda não tem eventos guardados. Podemos abrir o Calendário agora e aguardar enquanto sincroniza a partir do iCloud."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="Abrir os Contactos para iniciar a sincronização?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="Tem %s conta(s) de contactos configurada(s), mas o Contacts.app ainda não tem entradas guardadas. Podemos abrir os Contactos agora e aguardar enquanto sincroniza a partir do iCloud."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="A aguardar que %s inicie a sincronização (até %s segundos)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="Ainda a aguardar a sincronização de %s (%ss decorridos, %ss em falta). A primeira sincronização do iCloud pode demorar alguns minutos após um novo início de sessão."
MSG_OK_APP_HAS_POPULATED="%s preencheu o seu armazenamento local. A continuar."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="Não detetámos a sincronização de %s dentro do tempo de espera. A continuar; pode executar novamente a hidratação a partir das Definições mais tarde."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="Contas do Apple Mail visíveis: %s. Abra o Mail.app uma vez para que comece a obter mensagens."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="Contas do Calendário visíveis: %s. Abra o Calendar.app uma vez para que sincronize os seus eventos."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="Contas de Contactos visíveis: %s. Abra o Contacts.app uma vez para que sincronize a sua lista de contactos."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="Não foi possível ler os seus Contactos. O Ostler lê-os através do Acesso total ao disco - conceda-o em Definições do Sistema > Privacidade e segurança > Acesso total ao disco e, depois, execute novamente a hidratação a partir das Definições. Continuaremos a tentar em segundo plano."
MSG_HYDRATE_CONTACTS_PENDING="A sua app Contactos ainda não sincronizou. Abra os Contactos uma vez, aguarde que sincronize e execute novamente a hidratação a partir das Definições."
MSG_HYDRATE_CONTACTS_READ_FAILED="Os seus contactos estão neste Mac, mas o Ostler importou 0 deles, o que é inesperado. A importação será repetida automaticamente em segundo plano. Se persistir, execute novamente a hidratação a partir das Definições ou consulte o registo de instalação."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="O Ostler continuará a verificar em segundo plano e importará automaticamente os seus contactos assim que o iCloud terminar a sincronização."
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="Foram importados %s contactos com números de telefone, mas quase sem endereços de e-mail (%s de telefone vs %s de e-mail). Isto significa normalmente que o leitor de contactos ignorou os e-mails. Os seus contactos continuam utilizáveis; consulte %s e execute novamente a hidratação a partir das Definições depois de resolvido."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="Novos contactos importados; a reconstruir a sua wiki em segundo plano."
MSG_HYDRATE_CALENDAR_PENDING="A sua app Calendário ainda não sincronizou eventos. Abra o Calendário uma vez, aguarde que sincronize e execute novamente a hidratação a partir das Definições."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="Não foi possível ler o seu calendário desta vez (o extrator comunicou um erro, não um calendário vazio). Os seus outros dados não foram afetados; consulte %s e execute novamente a hidratação a partir das Definições."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="A ler o seu histórico do WhatsApp – as suas mensagens permanecem neste Mac"
MSG_HYDRATE_WHATSAPP_DONE="Foram encontradas %s pessoas nas suas conversas do WhatsApp"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="As conversas do WhatsApp foram lidas, mas não foram gravadas no seu grafo de pessoas (saída %s). O Ostler vai tentar novamente. Detalhes: %s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="Não há conversas do WhatsApp para ler. Pode voltar a executar mais tarde em Definições."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="O WhatsApp Desktop não está instalado. Instale-o a partir da Mac App Store e volte a executar em Definições."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="O leitor do WhatsApp ainda não está pronto. Pode voltar a executar mais tarde em Definições."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="O WhatsApp ainda está a carregar em segundo plano. A sua wiki vai-se preenchendo e mostra-lhe em que ponto está."

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
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="Os seus contactos do WhatsApp já estão no seu grafo de pessoas (%s identificadores). Não é preciso voltar a ler."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="Os seus contactos do WhatsApp já foram lidos antes, mas o seu grafo de pessoas já não os contém. A ler novamente."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="Não foi possível verificar se os seus contactos do WhatsApp ainda estão no seu grafo de pessoas. A ler novamente, em vez de presumir que lá estão."

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="A ler o seu histórico de conversas de IA – as suas conversas ficam neste Mac"
MSG_HYDRATE_AICONV_DONE="%s conversas de IA guardadas na sua wiki"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="O leitor de conversas de IA ainda não está pronto. Pode voltar a executar mais tarde em Definições."
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="Não há histórico de conversas de IA para ler. Pode voltar a executar mais tarde em Definições."
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="As conversas de IA ainda estão a carregar em segundo plano. A sua wiki vai-se preenchendo e mostra-lhe em que ponto está."
MSG_HYDRATE_AICONV_HEARTBEAT="  Ainda a ler o seu histórico de conversas de IA (%ss até agora). Um histórico grande pode demorar vários minutos."


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="A importar o seu histórico de navegação – as suas visitas ficam neste Mac"
MSG_HYDRATE_BROWSING_DONE="%s páginas do histórico de navegação importadas"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="%s páginas ignoradas por estarem marcadas como sensíveis (banca, saúde, etc.)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="Não há histórico de navegação para importar. Pode voltar a executar mais tarde em Definições."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="O leitor do histórico de navegação ainda não está pronto. Pode voltar a executar mais tarde em Definições."

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
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="O seu histórico de navegação já está importado (%s páginas). Não é preciso voltar a importar."
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="Não foi encontrado nenhum histórico de navegação exportado para importar. Pode voltar a executar mais tarde em Definições."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="O seu histórico de navegação foi importado antes, mas o seu índice de pesquisa já não o contém. A importar novamente."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="Não foi possível verificar se o seu histórico de navegação ainda está no seu índice de pesquisa. A importar novamente, em vez de presumir que lá está."
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="O seu histórico de navegação não chegou ao índice de pesquisa, pelo que a página Navegação ficará vazia. Volte a executar em Definições ou abra o Doctor."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="O histórico de navegação ainda está a carregar em segundo plano. A sua wiki vai-se preenchendo e mostra-lhe em que ponto está."

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="A carregar as suas preferências de email. Isto fica neste Mac e pode demorar alguns minutos."
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="%s preferências carregadas do seu histórico de email"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="Nenhum ficheiro de preferências de email configurado. Nada para carregar."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="Nenhum ficheiro de preferências de email encontrado em %s. Nada para carregar."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="O processo de preferências ainda não está pronto. Pode voltar a executar mais tarde em Definições."
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="As preferências de email ainda estão a carregar em segundo plano. A sua wiki vai-se preenchendo e mostra-lhe em que ponto está."
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  Ainda a carregar as suas preferências de email (%ss até agora). Um histórico grande pode demorar alguns minutos."

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="As suas preferências de email já estão carregadas (%s entradas). Não é preciso voltar a carregar."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="As suas preferências de email foram carregadas antes, mas o seu índice de pesquisa já não as contém. A carregar novamente."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="Não foi possível verificar se as suas preferências de email ainda estão no seu índice de pesquisa. A carregar novamente, em vez de presumir que lá estão."

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
MSG_HYDRATE_PREFERENCES_DONE="%s preferências importadas"
MSG_HYDRATE_PREFERENCES_ENRICHED="%s delas enriquecidas com dados de referência públicos"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="%s preferências importadas, mas nenhuma ficou em Comida, Música ou Profissional. As suas páginas de Comida e Música na wiki ficarão vazias."
MSG_WARN_PREFS_HEADLINE_HINT="Isto costuma significar que não havia nenhuma exportação de música ou comida (Spotify, Apple Music, Uber Eats, Google Takeout) ou que os dados não foram categorizados. Adicione essas exportações, volte a executar em Definições e reconstrua a wiki."
MSG_WARN_PREFS_UNCATEGORISED="%s de %s preferências (%s%%) não têm categoria e não aparecerão em nenhuma página de tema. Verifique o formato da exportação de origem."

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="A configurar o enriquecimento de preferências"
MSG_CM019_SETUP_DONE="Enriquecimento de preferências pronto"
MSG_CM019_SETUP_FAILED="A configuração do enriquecimento de preferências não foi concluída. As suas páginas de preferências serão preenchidas assim que isto for resolvido; o resto do Ostler não é afetado."
MSG_CM019_SETUP_SKIPPED="O processo de enriquecimento de preferências não está incluído; a ignorar por agora."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="A ler o seu histórico do iMessage – as suas mensagens ficam neste Mac"
MSG_HYDRATE_IMESSAGE_DONE="Encontradas %s pessoas no seu histórico do iMessage"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="Não há histórico do iMessage para ler. Pode executar novamente mais tarde em Definições."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="O leitor do iMessage ainda não está pronto. Pode executar novamente mais tarde em Definições."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="O iMessage ainda está a carregar em segundo plano. A sua wiki vai sendo preenchida e mostra-lhe em que ponto está."
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  A ler ainda o seu histórico do iMessage (%ss até agora). Um histórico de mensagens grande pode demorar vários minutos."

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="Os seus contactos do iMessage já estão no seu grafo de pessoas (%s identificadores). Nada para ler novamente."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="Os seus contactos do iMessage foram lidos anteriormente, mas o seu grafo de pessoas já não os contém. A ler novamente."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="Não foi possível verificar se os seus contactos do iMessage ainda estão no seu grafo de pessoas. A ler novamente, em vez de presumir que lá estão."

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="A ler as suas Notas da Apple - ficam neste Mac"
MSG_HYDRATE_APPLE_NOTES_DONE="Adicionadas %s notas à sua base de conhecimento"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="Não há Notas da Apple para ler. Pode executar novamente mais tarde em Definições."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="As suas Notas da Apple já estão na sua base de conhecimento. A ignorar."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="As Notas da Apple estão desativadas na pesquisa de conhecimento. Pode ativá-las em Definições."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="O importador de conhecimento ainda não está pronto. Pode executar novamente mais tarde em Definições."
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="As Notas da Apple ainda estão a carregar em segundo plano. A sua base de conhecimento vai sendo preenchida e mostra-lhe em que ponto está."
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  A ler ainda as suas Notas da Apple (%ss até agora). Uma biblioteca de notas grande pode demorar alguns minutos."

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="As suas Notas da Apple já estão na sua base de conhecimento (%s entradas). Nada para ler novamente."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="As suas Notas da Apple foram adicionadas anteriormente, mas a sua base de conhecimento já não as contém. A adicioná-las novamente."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="Não foi possível verificar se as suas Notas da Apple ainda estão na sua base de conhecimento. A adicioná-las novamente, em vez de presumir que lá estão."

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="A ler os seus Lembretes - ficam neste Mac"
MSG_HYDRATE_REMINDERS_DONE="Adicionados %s lembretes à sua base de conhecimento"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="Não há Lembretes para ler. Pode executar novamente mais tarde em Definições."
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="Os seus Lembretes já estão na sua base de conhecimento. A ignorar."
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="Os Lembretes estão desativados na pesquisa de conhecimento. Pode ativá-los em Definições."
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="O importador de conhecimento ainda não está pronto. Pode executar novamente mais tarde em Definições."
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="Os Lembretes ainda estão a carregar em segundo plano. A sua base de conhecimento vai sendo preenchida e mostra-lhe em que ponto está."
MSG_HYDRATE_REMINDERS_HEARTBEAT="  A ler ainda os seus Lembretes (%ss até agora). Uma lista de lembretes grande pode demorar alguns minutos."

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="Os seus Lembretes já estão na sua base de conhecimento (%s entradas). Nada para ler novamente."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="Os seus Lembretes foram adicionados anteriormente, mas a sua base de conhecimento já não os contém. A adicioná-los novamente."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="Não foi possível verificar se os seus Lembretes ainda estão na sua base de conhecimento. A adicioná-los novamente, em vez de presumir que lá estão."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="A indexar as suas pessoas para pesquisa"
MSG_HYDRATE_PEOPLE_DONE="Indexadas %s pessoas para pesquisa"
MSG_HYDRATE_PEOPLE_PARTIAL="Indexadas até agora %s de %s pessoas para pesquisa. As restantes ainda não eram pesquisáveis; o Ostler tentará novamente de forma automática."
MSG_HYDRATE_PEOPLE_FAILED="Não foi possível indexar as suas pessoas para pesquisa desta vez (o armazenamento do grafo não respondeu). O Ostler tentará novamente de forma automática. Detalhes: %s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="Ainda não há pessoas para indexar. Pode executar novamente mais tarde em Definições."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="O indexador de pessoas ainda não está pronto. Pode voltar a executá-lo mais tarde nas Definições."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="As suas pessoas ainda estão a ser indexadas em segundo plano. A pesquisa vai sendo preenchida à medida que avança, e a wiki mostra-lhe em que ponto está."

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="As suas pessoas já estão indexadas para pesquisa (%s pessoas). Não é preciso voltar a indexar."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="As suas pessoas foram indexadas anteriormente, mas o índice de pesquisa já não as contém. A indexar novamente."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="Não foi possível verificar se as suas pessoas ainda estão no índice de pesquisa. A indexar novamente, em vez de presumir que estão lá."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="Vêm aí três pedidos de acesso a pastas"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="A caixa de diálogo das Ferramentas de Linha de Comandos apareceu à frente desta janela – clique em Instalar nela e depois volte aqui (ou aguarde alguns segundos, vamos trazer esta janela de volta para a frente). As ferramentas são transferidas em segundo plano enquanto continua a responder às perguntas abaixo; nada aqui fica bloqueado."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="Permissão necessária: Automatização do iMessage"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="O Ostler vai agora pedir ao macOS permissão para comunicar com a app Mensagens (Messages.app). O macOS vai mostrar uma janela com a mensagem \"OstlerInstaller wants access to control Messages\" – clique em Permitir para que o assistente possa enviar e receber iMessages em seu nome. Sem esta permissão, as mensagens iMessage nunca sairão do Mac, sem qualquer aviso. Esta autorização é concedida uma única vez; pode alterá-la mais tarde em Definições do Sistema > Privacidade e segurança > Automatização."

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="A sua chave de recuperação"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="Anote-a ou imprima-a agora. É a única forma de voltar a entrar se perder a sua palavra-passe E o seu porta-chaves ficar inacessível. O Ostler não a pode recuperar por si – a chave nunca sai deste Mac e não é guardada em nenhum servidor."
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="Guardei-a num local seguro"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="Copiar para a área de transferência"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="Guardar como PDF..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="Imprimir..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="Continuar"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Chave de recuperação do Ostler.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Chave de recuperação do Ostler"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="Chave de recuperação copiada para a área de transferência"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="Chave de recuperação guardada em %s"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="Emparelhar o iPhone"
MSG_INFO_PAIR_IPHONE_HELP="Abra a app Ostler no iPhone e leia este código QR para a ligar a este Hub. Também pode emparelhar mais tarde no menu Definições do Hub."
MSG_INFO_PAIR_IPHONE_FETCHING="A gerar o código de emparelhamento..."
MSG_INFO_PAIR_REFRESH="Atualizar código"
MSG_ERR_PAIR_FETCH_FAILED="Ainda não foi possível contactar o gateway do Ostler. Pode ainda estar a iniciar – clique em Atualizar para tentar novamente."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="O assistant-agent não está incluído no instalador. O LaunchAgent dos resumos diários e da manutenção da ligação ao WhatsApp não será carregado."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Os scripts de recompilação da wiki não estão incluídos no instalador. A wiki não será atualizada automaticamente."

# F3 - legal package missing
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="legal package not bundled with installer. Article 9 / WhatsApp / voice consent gates will raise ModuleNotFoundError until re-installed."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s instalado em %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s já instalado, mantido tal como está"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Arquitetura de CPU não suportada pelo Google Workspace CLI; as funcionalidades do Gmail / Google Calendar ficam limitadas."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl não disponível; instalação do Google Workspace CLI ignorada. As funcionalidades do Gmail / Google Calendar ficam limitadas."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="Não foi possível transferir o Google Workspace CLI de %s"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="SHA256 do Google Workspace CLI não corresponde (esperado %s, obtido %s). A abortar a instalação deste binário."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="Não foi possível extrair o arquivo do Google Workspace CLI."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI instalado em %s, mas a verificação com --version falhou."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="Ponte de calendário iCloud / CalDAV instalada em %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="A ponte de calendário iCloud / CalDAV em %s não é executável. O Calendário não devolverá eventos."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh não está incluído no instalador. A nova tentativa de registo do dispositivo quando houver rede está desativada."

MSG_WARN_EMBED_DIMS_UNREADABLE="Não foi possível ler a largura dos embeddings a partir da verificação de estado. A memória está configurada para 768 dimensões; se a recuperação de memórias tiver um comportamento estranho, verifique o modelo de embeddings."
MSG_FAIL_EMBED_DIMS="O modelo de embeddings devolveu vetores com %s dimensões, mas o Ostler está configurado para %s. A memória guardaria vetores que nunca poderia fazer corresponder. Verifique o modelo de embeddings e execute novamente."

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
MSG_PROGRESS_REBOOT_SELFHEAL="A configurar a recuperação automática após reinício"
MSG_INFO_AUTOLOGIN_EXPLAIN="O Ostler é um hub sempre ligado, por isso, após um corte de energia ou um reinício, tem de voltar a funcionar sem ninguém ao teclado. Isso só é possível se este Mac iniciar sessão sozinho, e o macOS só consegue fazê-lo se a palavra-passe de início de sessão de %s estiver guardada neste Mac.

Guardá-la enfraquece a segurança deste Mac. A palavra-passe é baralhada, não cifrada, pelo que qualquer pessoa que possa usar uma conta de administrador aqui, ou que possa retirar o disco e lê-lo noutro local, consegue convertê-la de novo na sua palavra-passe. Verá exatamente onde fica guardada antes de escrever o que quer que seja.

Se disser que não, nada é guardado e nada mais muda. Após um corte de energia, inicia sessão como habitualmente e os serviços do Ostler arrancam com a sua sessão. Pode alterar isto mais tarde em Definições do Sistema > Utilizadores e grupos > Início de sessão automático."
MSG_PROMPT_AUTOLOGIN_CONSENT="Store your login password on this Mac so it can sign itself in after a restart? [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="O Ostler escreve esta palavra-passe num ficheiro neste Mac, em /etc/kcpassword. Aí fica baralhada com um padrão fixo, igual em todos os Mac e documentado publicamente, pelo que não se trata de cifragem e pode ser revertida. Qualquer pessoa que possa usar uma conta de administrador neste Mac, ou que possa retirar o disco e lê-lo noutro local, consegue converter esse ficheiro de novo na palavra-passe de início de sessão de %s.

O FileVault impediria isso, porque o disco não pode ser lido de todo sem a palavra-passe de arranque. O FileVault também impede o início de sessão automático, pelo mesmo motivo, e é por isso que o Ostler só oferece esta opção quando o FileVault está desativado.

O que o instalador controla: não mostra a palavra-passe enquanto a introduz e não a grava no registo de instalação. O ficheiro baralhado é a única cópia que o instalador cria.

Deixe em branco para ignorar o início de sessão automático."
MSG_PROMPT_AUTOLOGIN_PASSWORD="Palavra-passe de início de sessão de %s"
MSG_OK_AUTOLOGIN_CONFIGURED="O início de sessão automático está ativado para %s e essa palavra-passe de início de sessão está agora neste Mac, em /etc/kcpassword, de forma baralhada. Após um reinício, este Mac inicia sessão sozinho e os serviços do Ostler arrancam com essa sessão. Para anular, desative o Início de sessão automático em Definições do Sistema > Utilizadores e grupos."
MSG_INFO_AUTOLOGIN_ALREADY="O início de sessão automático já está configurado para %s, pelo que este Mac já tem essa palavra-passe de início de sessão guardada em /etc/kcpassword. Ambos ficam como estão. Para anular, desative o Início de sessão automático em Definições do Sistema > Utilizadores e grupos."
MSG_INFO_AUTOLOGIN_DECLINED="O início de sessão automático não foi ativado e nenhuma palavra-passe foi guardada. Após um reinício ou corte de energia, inicie sessão como habitualmente e os serviços do Ostler arrancam com a sua sessão."
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="A ignorar a configuração do início de sessão automático: não há forma de pedir uma palavra-passe de início de sessão aqui e nada foi guardado. Pode ativar o Início de sessão automático mais tarde em Definições do Sistema > Utilizadores e grupos, se quiser que este Mac recupere sozinho de um reinício. Isso guarda a palavra-passe de início de sessão no Mac de forma baralhada e reversível, por isso convém informar-se antes de o fazer."
MSG_WARN_AUTOLOGIN_NO_PASSWORD="Não foi introduzida nenhuma palavra-passe, por isso o início de sessão automático não foi ativado e nada foi guardado. Se o quiser mais tarde, ative o Início de sessão automático em Definições do Sistema > Utilizadores e grupos."
MSG_WARN_AUTOLOGIN_FAILED="Não foi possível ativar o início de sessão automático (%s). Não será feita nova tentativa. Se /etc/kcpassword existir neste Mac, contém essa palavra-passe de início de sessão de forma baralhada, mesmo com a funcionalidade desativada; pode removê-lo a partir do Terminal com: sudo rm /etc/kcpassword. Para tentar novamente, ative o Início de sessão automático em Definições do Sistema > Utilizadores e grupos."
MSG_WARN_AUTOLOGIN_FILEVAULT="O FileVault está ativado, por isso este Mac pede uma palavra-passe no ecrã de arranque para desbloquear o disco antes de qualquer pessoa poder iniciar sessão. O início de sessão automático não consegue responder a esse pedido, pelo que, após um corte de energia, este Mac fica à espera no ecrã de desbloqueio do FileVault até alguém a introduzir. O início de sessão automático não foi ativado e nenhuma palavra-passe foi guardada. Essa é a mais segura das duas opções: a recuperação autónoma após reinício não é possível com o FileVault ativado e, em troca, o disco permanece ilegível para quem não tenha essa palavra-passe."

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
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="O Ostler não conseguiu abrir as Definições do Sistema por si. Abra as Definições do Sistema e aceda a Privacidade e segurança > Acesso total ao disco."
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="O Ostler executa o seu wiki e a pesquisa em contentores, por isso instala e gere um motor de contentores (Colima) neste Mac. Se esse motor for removido ou reconfigurado, o wiki e a pesquisa deixam de funcionar – o Ostler avisa-o e tenta reiniciá-lo."
MSG_INFO_ENGINE_ALREADY_PRESENT="Já existe um motor de contentores instalado neste Mac. O Ostler vai utilizá-lo em vez de instalar o seu próprio e não o vai gerir nem modificar."

# OS003 #233: model weight pins (install.sh OSTLER_MODEL_PINS).
MSG_OK_MODEL_DIGEST_VERIFIED="%s verified against its pinned digest (%s)"
MSG_FAIL_MODEL_DIGEST_MISMATCH="The installed %s is not the model this installer ships: found %s, expected %s (%s). The download source may have changed, so the install has stopped before using it. Contact support with this message."
MSG_FAIL_MODEL_UNPINNED="%s has no pinned digest in this installer, so it cannot be verified and will not be used. This is an installer defect. Contact support with this message."
MSG_FAIL_MODEL_DIGEST_UNREADABLE="Could not verify the downloaded %s against its pinned digest (%s). The model will not be used unverified. Re-run the installer; if this repeats, contact support with this message."
