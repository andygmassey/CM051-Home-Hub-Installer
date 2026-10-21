#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to pt-BR by l10n/ostler_l10n.py.
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

MSG_STEP_CHECKING_PREREQUISITES="Verificando pré-requisitos"
MSG_STEP_RUNNING_HEALTH_CHECK="Executando verificação de integridade"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="Conecte seu iPhone e seu Watch"
# NEEDS REVIEW: en-GB header asks for human translation of this key
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
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_SETUP_COMPLETE_WRAP_UP="Perguntas concluídas. O Ostler agora instala em segundo plano – de cerca de 45 minutos a algumas horas. Três coisas ainda vão precisar de você: se o macOS pedir para instalar as ferramentas de desenvolvedor, clique em Instalar; perto do fim há um minuto de configuração (ativar o Acesso Total ao Disco); e bem no final, depois da verificação de integridade, você entra no Tailscale e permite que o assistente use os Lembretes. Entre essas etapas, você pode deixar rodando."
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="Perguntas concluídas. O Ostler agora instala em segundo plano – de cerca de 45 minutos a algumas horas. Três coisas ainda vão precisar de você: se o macOS pedir para instalar as ferramentas de desenvolvedor, clique em Instalar; perto do fim há um minuto de configuração (ativar o Acesso Total ao Disco); e bem no final você permite que o assistente use os Lembretes. Entre essas etapas, você pode deixar rodando."

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="e execute novamente: ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="Reiniciando o assistente para que ele possa usar o Acesso Total ao Disco e ler seu histórico do app Mensagens. A reinicialização é o que faz uma permissão recém-concedida entrar em vigor; se você ainda não a concedeu, o painel Doctor continuará orientando você."
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="Seu assistente está em execução e tem Acesso Total ao Disco, então pode ler os arquivos de que precisa."
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="Seu assistente está em execução, mas ainda não tem Acesso Total ao Disco. Até você ativá-lo, o Ostler não consegue manter atualizados o Mensagens, o Mail, o Calendário, os Lembretes, as Notas, as Fotos, o Safari, os Contatos nem o WhatsApp, e não consegue ler sua pasta Documentos. Tudo o que ele já leu continua guardado. O painel Doctor vai orientar você a ativá-lo."
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="Seu assistente está em execução. Não foi possível verificar se ele tem Acesso Total ao Disco neste Mac, então isto não confirma nem uma coisa nem outra. O painel Doctor avisará quando conseguir verificar."
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="Contas do Apple Mail visíveis: %s (informativo)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="O Apple Mail ainda não parece ter nenhuma mensagem local. O Doctor mostrará um acompanhamento se nenhum e-mail chegar em 24 horas."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="O Apple Mail tem mensagens em cache. A ingestão vai buscá-las no próximo ciclo de hora em hora."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="O Apple Mail está selecionado, mas ainda não há mensagens locais para ler neste Mac. Abra o Apple Mail e adicione uma conta (Ajustes do Sistema > Contas de Internet, depois marque Mail) e deixe terminar a primeira sincronização."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="Depois que os e-mails chegarem, execute novamente: ostler-fda. O Ostler vai detectá-los automaticamente; nada mais é necessário."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="A notarização da Apple será verificada pelo Gatekeeper na primeira abertura."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="disponível, o instalador pulará esta etapa automaticamente."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="Beta testers com acesso podem definir PWG_PIPELINE_REPO=<url> e executar novamente."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="Beta testers com acesso podem definir PWG_KNOWLEDGE_REPO=<url> e executar novamente."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="Extensões de navegador ignoradas (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  Clonado para %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="O Ostler RemoteCapture funciona somente em Apple Silicon. Ignorando a instalação neste computador."
MSG_INFO_CM042_LOGS_AT="Logs do RemoteCapture: %s/ostler-remotecapture.log (e .err)"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="Uma instalação anterior fazia o Ostler RemoteCapture iniciar no login. Ele foi interrompido e não iniciará novamente."
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="O Ostler RemoteCapture não foi instalado: você optou por manter a transcrição de voz desativada. Ative-a nos Ajustes e execute o instalador novamente se mudar de ideia."
MSG_INFO_CM042_TCC_PRE_PROMPT="Na primeira abertura, o Ostler RemoteCapture pedirá ao macOS as permissões de Gravação de Tela e de Microfone. Conceda as duas para que chamadas e reuniões possam ser transcritas localmente. Nenhum indicador roxo de gravação aparece na barra de menus – a captura de áudio é silenciosa por projeto."
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
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="O Ostler salva sua wiki pessoal e os registros das suas conversas em Documentos/Ostler, neste Mac. Eles são seus e ficam nesta máquina. Para gravá-los, o Ostler precisa de acesso à sua pasta Documentos, então o macOS pode pedir essa permissão durante a configuração e de novo mais tarde hoje, quando o Ostler organizar sua wiki pela primeira vez. O pedido pode aparecer como vindo de python3.11, o auxiliar incluído que o Ostler usa para gravar seus arquivos. Toda vez que o pedido aparecer, clique em Permitir. Se você perder o pedido ou recusar, pode ativar a permissão a qualquer momento em Ajustes do Sistema, em Privacidade e Segurança, depois Arquivos e Pastas, e sua wiki e os registros das conversas passarão a ser gravados a partir daí."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  Mecanismo de memória de conversas instalado no venv."
MSG_INFO_HUB_APP_VERIFYING="Verificando o Ostler.app em %s"
MSG_INFO_HUB_APP_STAGING="Copiando o Ostler.app para /Applications a partir de %s"
MSG_INFO_HUB_APP_DRAG_HINT="Abra o DMG do instalador e arraste o Ostler.app e o OstlerInstaller.app para o atalho da pasta Aplicativos, depois execute o instalador novamente."
MSG_OK_HUB_APP_PRESENT="O Ostler.app já está presente em %s; assinatura verificada."
MSG_OK_HUB_APP_STAGED="Ostler.app instalado em %s"
MSG_WARN_HUB_APP_NOT_FOUND="O Ostler.app não foi encontrado em /Applications e não há nenhuma cópia incluída disponível."
MSG_WARN_HUB_APP_VERIFY_FAILED="Falha na verificação da assinatura ou da notarização do Ostler.app. O pacote foi mantido no lugar para que o suporte possa inspecioná-lo."
MSG_OK_UNINSTALLER_APP_STAGED="Ostler Uninstaller.app instalado em %s"
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="Não foi possível colocar o Ostler Uninstaller.app em /Applications. Você ainda pode desinstalar executando: ~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="Clonando o agente do Doctor..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="Clonando os scripts de ingestão de e-mail..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Clonando os scripts de energia do Hub..."
MSG_INFO_CLONING_IMPORT_PIPELINE="Clonando o pipeline de importação..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="Clonando os scripts de recompilação da wiki..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="O Colima está instalado, mas não está em execução. Ele será iniciado."
MSG_INFO_COLIMA_START_ATTEMPT="Iniciando o Colima (tentativa %s de %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="Não foi possível exportar os contatos. Você pode importá-los manualmente mais tarde."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="Não foi possível ler o cartão de contato. Sem problema – vamos perguntar a você."
MSG_INFO_CONTACT_CARD_WILL_ASK="Vamos pedir seu nome e país em instantes. Seus contatos são lidos depois, com o Acesso Total ao Disco que você conceder, e nada sai deste Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  Criando o venv do Python em %s..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="Criando a árvore de conteúdo para o usuário em %s/"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="Execução diária. Execução manual: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="Hub de mesa (sem bateria) detectado: desativando o repouso em todo o sistema"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="O Docker não está instalado. Serão instalados o Colima, a CLI do Docker e o plugin docker-compose (leve, sem precisar do Docker Desktop)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="Os arquivos do agente do Doctor não estão incluídos no instalador."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="Os scripts de ingestão de e-mail não estão incluídos no instalador."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="Os scripts de ingestão de e-mail estão ausentes do pacote do instalador. Baixe o .app novamente em ostler.ai/install e tente de novo."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Os scripts de ingestão de e-mail não estão incluídos e --allow-plaintext foi usado; a instalação do LaunchAgent será ignorada. Os próximos e-mails não serão processados."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  Cópia existente em %s; atualizando..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Extraindo o mbox do Gmail do zip do Takeout (pode levar um minuto em arquivos grandes)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="O módulo de extração via Acesso Total ao Disco não está incluído. Ignorando a extração instantânea de dados."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Ativando seus primeiros 30 dias do Ostler Pro..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Após o período de teste, o Ostler Pro custa US\$ 9,99 por mês. Assine no app Ostler no seu iPhone."
MSG_INFO_FOUND_GMAIL_MBOX_MB="mbox do Gmail encontrado em %s (%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Zip do Google Takeout encontrado em %s (%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="Acesso Total ao Disco detectado – extração completa disponível."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="Exportações do GDPR detectadas, mas o pipeline de importação ainda não está disponível."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="A importação de exportações do GDPR estará disponível quando o pipeline for lançado."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="Vamos verificar Downloads, Mesa e Documentos em busca de exportações de IA (Google Takeout, downloads da Meta, LinkedIn etc.) que você possa ter salvo. O macOS mostrará três solicitações de acesso a pastas – permita cada uma. Leva cerca de 5 a 10 segundos no total. Nada é movido ou copiado durante a verificação; apenas conferimos o que há lá."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="O macOS pode pedir permissão para ler seu Calendário. Permita para que o Ostler monte a parte de reuniões e eventos do seu grafo de conhecimento. (Os dados do Calendário ficam nesta máquina.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="O macOS está pedindo permissão para Downloads. Clique em OK."
MSG_INFO_FOLDER_PREWARM_DESKTOP="O macOS está pedindo permissão para a Mesa. Clique em OK."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="O macOS está pedindo permissão para Documentos. Clique em OK."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="Acesso Total ao Disco concedido. Preparando a próxima solicitação do macOS (automação do Mensagens)..."
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="Não houve resposta à solicitação de permissão do Mensagens, então seguimos em frente. Suas mensagens não serão lidas até que seja permitido. O Ostler perguntará novamente, ou você pode conceder em Ajustes do Sistema > Privacidade e Segurança > Automação."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="As Ferramentas de Linha de Comando do Xcode são necessárias. O macOS vai pedir permissão para instalar – procure uma pequena janela cinza (se não a vir, pressione Cmd+Tab ou confira o Dock). Clique em Instalar. As ferramentas são baixadas em segundo plano enquanto você responde às perguntas abaixo."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  Ainda configurando as Ferramentas de Linha de Comando (%ss). Se uma pequena janela cinza do macOS estiver pedindo para instalar as ferramentas de desenvolvedor, clique em Instalar nela – esta etapa está esperando por isso. (Use Cmd+Tab ou confira o Dock se não a vir.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="Aguardando a conclusão da instalação das Ferramentas de Linha de Comando (quase lá)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="Execução a cada hora. A primeira execução busca os últimos 5 anos de e-mails."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="Desativando o LaunchAgent antigo da ponte do iMessage (v1.0, máquina única)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Hub somente com tomada (nenhuma bateria detectada); ignorando o LaunchAgent hub-power."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Os scripts de energia do Hub não estão incluídos no instalador."
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="Hub em notebook. Ele continua funcionando com a tampa aberta e ligado na tomada."
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="Se você fechar a tampa, ou deixá-lo parado na bateria, o macOS o coloca em repouso."
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="Enquanto ele estiver em repouso, o assistente não recebe nada."
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="As mensagens que chegarem nesse período não são recuperadas quando ele despertar."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="A tampa pode ficar fechada no modo de tela fechada."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="Isso exige tomada, além de uma tela, um teclado e um mouse externos."
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="Docker e Ollama pausam na bateria e retomam quando ligados na tomada."
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="Após reiniciar, o FileVault mantém este Mac na tela de login."
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="O Ostler inicia assim que você fizer login."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="API do assistente incluída no instalador; usando o código-fonte embarcado."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="Código-fonte da API do assistente não incluído; o app Ostler no seu iPhone terá acesso limitado."
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="Instalando as dependências de execução da API do assistente (phonenumbers, httpx)..."
MSG_WARN_ICAL_SERVER_DEPS_FAILED="Não foi possível instalar as dependências de execução da API do assistente (phonenumbers/httpx); Pessoas e Linha do Tempo podem ficar vazias até a próxima execução da instalação."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Quando a janela do Tailscale aparecer, faça login com Apple / Google / Microsoft."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="Abrindo o Tailscale para você fazer login..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="Entendido – a partir daqui, o Ostler se instala quase sozinho. Perto do fim, ele vai precisar de você por cerca de dois minutos: ativar o Acesso Total ao Disco e depois fazer login no Tailscale, para que seu iPhone e seu Watch alcancem este Mac de qualquer lugar. Vamos abrir o navegador para o login."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale ignorado – o app Ostler no seu iPhone só funcionará na sua rede Wi-Fi doméstica. Você pode configurar isso depois em Ajustes."
MSG_INFO_TAILSCALE_STILL_WAITING="Ainda aguardando o login no Tailscale (%ss decorridos) – conclua o login na janela do Tailscale."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="Acesso Total ao Disco concedido; reiniciando o assistente para aplicar a nova permissão."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="Abrindo os Ajustes do Sistema e o Finder para guiar você na concessão do Acesso Total ao Disco ao assistente..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="Registrando o assistente do Ostler no macOS para que apareça como uma chave em Acesso Total ao Disco..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="O Acesso Total ao Disco ainda está pendente. O painel Doctor manterá o cartão visível até que o acesso seja concedido."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="O ostler-assistant já tem Acesso Total ao Disco; nenhuma ação adicional necessária."
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="Esta parte precisa de você por cerca de dois minutos: ative agora o Acesso Total ao Disco para o assistente e, na próxima etapa, faça login no Tailscale. Depois disso, você pode deixar o Ostler terminar sozinho."
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="Esta parte precisa de você por cerca de um minuto: ative o Acesso Total ao Disco para o assistente. Depois disso, você pode deixar o Ostler terminar sozinho."
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="\"%s\" já está na lista de Acesso Total ao Disco, então basta ativá-lo. Não é preciso arrastar nada do Finder."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Verificando se o assistente do Ostler tem Acesso Total ao Disco..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="O assistente consegue ler o histórico do Mensagens; o canal do iMessage vai funcionar."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="O assistente do Ostler ainda não tem Acesso Total ao Disco. Ele precisa disso para manter atualizados os próprios apps do seu Mac, com ou sem o Mensagens. Se você pular isso agora, o painel Doctor vai orientar você pelos Ajustes do Sistema."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="O LaunchAgent do assistente não foi carregado; pulando a verificação de Acesso Total ao Disco do iMessage."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="A interface de importação do Evernote no Doctor vai exibir um aviso de \"serviço indisponível\""
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="O pipeline de importação não está incluído no instalador."
MSG_INFO_INSTALLING_CM042="Instalando o Ostler RemoteCapture v%s (transcrição de chamadas e reuniões)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="Instalando o mecanismo de memória de conversas a partir de %s..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  Instalando o mecanismo de memória de conversas no venv..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="Instalando Colima + Docker CLI..."
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="Instalando GNU coreutils (para limites de tempo em etapas longas)..."
MSG_INFO_INSTALLING_HOMEBREW="Instalando o Homebrew..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="Instalando o serviço Knowledge a partir de %s..."
MSG_INFO_INSTALLING_OLLAMA="Instalando o Ollama..."
MSG_INFO_INSTALLING_OLLAMA_PINNED="Installing Ollama %s (verified release)..."
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  Instalando as dependências do módulo de extração de dados..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Instalando o leitor do Apple Mail em um venv dedicado..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  Instalando o ostler-knowledge no venv..."
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  Instalando a dependência de armazenamento criptografado no venv da memória de conversas..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Instalando a extensão do Safari em /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="Instalando as dependências Python de segurança..."
MSG_INFO_INSTALLING_SQLCIPHER="Instalando o SQLCipher..."
MSG_INFO_INSTALLING_TAILSCALE="Instalando o Tailscale..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="O suporte a Intel não está no roteiro de desenvolvimento; envie uma solicitação, se necessário."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Serviço Knowledge incluído no instalador; usando o código-fonte embarcado."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Serviço Knowledge não instalado: PWG_KNOWLEDGE_REPO está vazio."
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="Este Mac é um notebook. Funcionando como seu Hub, ele continua ativo enquanto a tampa estiver aberta e o Mac estiver ligado na tomada."
MSG_INFO_LAPTOP_HUB_SLEEP_COST="Se você fechar a tampa ou deixá-lo inativo na bateria, o macOS o coloca em repouso. O assistente não recebe nada enquanto ele está em repouso, e as mensagens que chegarem nesse período não são recuperadas quando ele volta a funcionar."
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="A tampa pode ficar fechada no modo de tela fechada, que exige energia da tomada, além de monitor, teclado e mouse externos."
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="Um Hub em Mac Mini ou Mac Studio permanece ativo por conta própria, se você preferir instalar em um deles."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="mais tarde em Ajustes do Sistema > Privacidade e Segurança > Acesso Total ao Disco"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  iniciar para verificar a entrega via cron + a postura imessage-tcc)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="Licença: %s é Apache 2.0. Texto completo: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licence: %s – check upstream terms before commercial use."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="armazenamento local – o Google nunca fica sabendo que o Ostler existe."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="Logs: %s/email-ingest.log (e .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="Logs: %s/ostler-assistant.log (e .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="Logs: %s/wiki-recompile.log (e .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="Hubs em MacBook: defina PWG_HUB_POWER_REPO=<url> e execute novamente."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="Hub em MacBook detectado: configurando para nunca entrar em repouso apenas na tomada (o hub-power cuida das transições para a bateria)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Instalações em Mac Mini / Studio não são afetadas (sempre na tomada)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Os dados do lado do Mac (iMessage, Safari etc.) foram extraídos acima."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="Reinício manual: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="Execução manual: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="Ignorando a instalação de com.ostler.meeting-brief-sender (recurso da v1.0.1; endpoints ainda não lançados)."
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="Ignorando a etapa de higiene da memória (não incluída neste instalador); nada terá o peso reduzido automaticamente até que ela seja incluída."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="mensagem quando o recurso for ativado mais tarde."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="Precisa de ajuda? Envie um e-mail para support@ostler.ai. Procuramos responder em até 2 dias úteis."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="Nenhum canal configurado. Execute depois: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="Um config.toml legado e obsoleto foi removido da raiz do workspace; a configuração ativa do assistente fica em assistant-config/."
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="Nenhuma fonte de FDA disponível no momento. Você pode conceder Acesso Total ao Disco"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="Nenhuma exportação do GDPR encontrada em Downloads, Mesa ou Documentos."
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="Não foi possível ler %s para procurar exportações de dados. O macOS está bloqueando o acesso a essa pasta."
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="Conceda o acesso em Ajustes do Sistema > Privacidade e Segurança > Arquivos e Pastas (ou Acesso Total ao Disco) e execute de novo, ou indique abaixo manualmente a pasta de exportações ao Ostler."
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="Não foi possível verificar uma ou mais pastas em busca de exportações de dados porque o macOS bloqueou o acesso. Conceda o acesso e execute de novo, ou indique manualmente a pasta de exportações."
MSG_INFO_OPENING_CHROME_WEB_STORE="Abrindo a Chrome Web Store: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="binário ostler-assistant não instalado; ignorando a verificação do doctor"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: adiado (o daemon ainda pode estar"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="Usando o binário ostler-assistant incluído neste DMG (instalação compatível com uso offline)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge instalado no venv."
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler will show an extra consent screen before installing"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  Substitua o repositório de origem do mecanismo de memória de conversas pela variável de ambiente documentada em ./install.sh --help."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  Substitua o repositório de origem com PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  Substitua o repositório de origem com PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  Substitua o repositório de origem com PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  Substitua o repositório de origem com PWG_PIPELINE_REPO=<url> ./install.sh"
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Persisting consent records and region..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="Monitor de bateria da Fase 3 ativado (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="Lendo sua lista de contatos (bibliotecas grandes podem levar alguns minutos – não feche o instalador)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="Substituir política: edite ~/.ostler/power.conf (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="Verificando a permissão de Automação do iMessage (somente leitura)..."
MSG_INFO_PULLING_GRAPH_DB_IMAGES="Baixando os bancos de dados do grafo de conhecimento (somente na primeira execução). Isso pode levar um minuto em uma instalação nova..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="Baixando nomic-embed-text (274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="Baixando %s (%s)... isso pode levar alguns minutos."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="xattr de quarentena removido. Quando a versão com Developer ID estiver"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Lendo Safari, iMessage, Notas, Calendário, Fotos, Lembretes, Mail..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="Lendo seu cartão de contato para preencher seus dados..."
MSG_INFO_REGION_EU_EEA_SOURCE="Região: UE/EEE (%s, origem: %s)"
MSG_INFO_REGION_SOURCE="Região: %s (origem: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="Região: Reino Unido (origem: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="Região: Estados Unidos (origem: %s)"
MSG_INFO_REPO_URL="URL do repositório: %s"
MSG_INFO_REPO_URL_2="URL do repositório: %s"
MSG_INFO_REPO_URL_3="URL do repositório: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="Agora escolha a senha que vai desbloquear seu Hub. Você vai digitá-la sempre que abrir a interface do Hub."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="Senha de recuperação ignorada. (Obsoleto: a v1.0 sempre exige uma senha.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="Reutilizando a instalação existente do agente Doctor em %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="Reutilizando a instalação existente do email-ingest em %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="Reutilizando a instalação existente do hub-power em %s"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="Reutilizando a chave existente da extensão de navegador em %s"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="A extensão do Ostler para Chrome não faz parte desta versão."
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="Email conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="Conversas por e-mail: não configuradas, porque o Apple Mail não está configurado neste Mac."
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="Messages conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="Conversas do Mensagens: não configuradas, porque não há histórico do Mensagens neste Mac."
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  Transcreva uma ligação com o Ostler e isto será ativado automaticamente."
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="Conversas faladas: ainda não configuradas, porque não há transcrições para ler."
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="Conversas faladas: desativadas, porque a pasta Transcripts foi removida desde a instalação do Ostler."
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  Recrie %s para reativar. O Ostler não vai recriá-la para você."
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="WhatsApp conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="Conversas do WhatsApp: não configuradas, porque o WhatsApp está desativado."
MSG_INFO_CHROME_HISTORY_STILL_READ="  O Ostler ainda lê seu histórico do Chrome, então as páginas que você visitou são lembradas. A captura em tempo real enquanto você navega, por enquanto, só funciona no Safari."
MSG_INFO_REUSING_EXISTING_JWT_SECRET="Reutilizando o JWT_SECRET existente em %s"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="Reutilizando o token de serviço PWG existente em %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="Reutilizando a instalação existente do wiki-recompile em %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="O pacote da extensão do Safari não está presente nesta versão do instalador (ignorando)"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="Falta uma etapa manual: abra o Safari, escolha Safari > Ajustes > Extensões e marque Ostler para ativá-lo."
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="Procurando exportações de dados do GDPR..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="Defina PWG_DOCTOR_REPO=<url> e execute novamente para instalar."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="Defina PWG_HUB_POWER_REPO=<HR015 url> e execute novamente para instalar."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="Modelo de conversa ignorado. Baixe depois: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Iniciando o Colima (ambiente de execução Docker leve)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Iniciando o Docker Desktop..."
MSG_INFO_STARTING_OLLAMA="Iniciando o Ollama..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="Removendo um item de inicialização obsoleto do Colima deixado por uma versão anterior..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="Removendo a fórmula antiga do Ollama (sem llama-server); mudando para o app Ollama..."
MSG_INFO_VERIFYING_EMBEDDINGS="Verificando se o mecanismo de embeddings retorna vetores..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="Não foi possível iniciar o Ollama automaticamente. Carregue-o com: launchctl bootstrap gui/\$(id -u) %s – depois execute o instalador novamente."
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="O Ollama não iniciou pelo serviço em segundo plano; iniciando diretamente para esta execução..."
# NEEDS REVIEW: The source line is cut mid-sentence ('after first ...'). The draft's 'primeiro' changed the meaning to 'first'. Restored 'after the first'. Check gender and agr
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  iniciando; execute \`ostler-assistant doctor\` após o primeiro"
MSG_INFO_SYMLINKING="  Criando link simbólico de %s -> %s"
# NEEDS REVIEW: The source is split across lines ('Mail's ...'). Check that the next translated line joins grammatically with 'lê do Mail'.
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(Ajustes do Sistema > Contas de Internet). O Ostler lê do Mail"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(O restante do Ostler funciona sem o painel Doctor.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="Isso é esperado por enquanto. A importação do GDPR estará disponível em uma atualização futura."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="Isso costuma levar de 15 a 45 minutos e pode demorar mais se você tiver muito histórico ou um Mac mais lento. É normal – está funcionando, não travou, então pode deixar rodando..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="Isso lê os bancos de dados do macOS diretamente – sem necessidade de exportar."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="Dica: para incluir seu Gmail, adicione-o primeiro ao Mail do Mac"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="Para instalar depois, quando você tiver acesso:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="Acionando a sincronização do iCloud para %s (silenciosa, apenas na primeira execução)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (Artigo 9 do GDPR do Reino Unido - exigido para dados de categoria especial)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="Atualizando o pipeline existente..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="A árvore voltada ao usuário já foi anunciada (sentinela presente); ignorando"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="Baixando o mecanismo local de busca na web (cerca de 3,5 GB). Em uma primeira instalação, esta é a etapa mais longa e pode levar até uma hora. Ela não tem barra de progresso, então um longo silêncio aqui é esperado e não significa que a instalação travou."
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane não está respondendo (opcional; veja os avisos da Fase 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="Veja a qualquer momento com: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="O reconhecimento de voz continuará desativado. Você pode ativá-lo depois em Ajustes."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="Aguardando você entrar no Tailscale (até 3 minutos)..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="O acesso remoto do Tailscale não foi configurado. O app Ostler no seu iPhone funcionará no Wi-Fi de casa; você pode configurar o acesso remoto depois em Ajustes."
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="Este Mac já está conectado à sua rede Tailscale, então não há nada para configurar. Mantendo sua conexão existente."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="Acesso remoto: mantendo a resposta que você deu da última vez, que foi pular. Seu app iOS funcionará no Wi-Fi de casa, e você pode configurar o acesso remoto depois em Ajustes."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="Acesso remoto: mantendo a resposta que você deu da última vez, que foi configurar."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="O conector do WhatsApp ficou desativado. Você pode ativá-lo depois em Ajustes."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="Keepalive do WhatsApp agendado para 08:50 + 17:50 (label com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="Ignorando a atualização inicial da wiki: o tick de recompilação da wiki não está instalado. A reconstrução diária da wiki, se instalada, continua sendo executada."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Os scripts de recompilação da wiki não estão incluídos no instalador."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="A wiki não será atualizada automaticamente; você pode executar novamente a primeira compilação manualmente:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="Marcador de postura gravado: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="Suas exportações estão seguras. Importe-as depois com: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="Os dados do seu Mac (iMessage, Safari etc.) já foram extraídos acima."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="Você pode adicioná-lo depois para uma configuração inicial instantânea a partir do Safari, iMessage etc."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="Modelo de IA: %s (%s) – selecionado para os seus %s GB de RAM"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="Compatível"
MSG_MODELFIT_PILL_SLOW="Pode ser lento"
MSG_MODELFIT_PILL_NOFIT="Não cabe"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="Ajustando o modelo do assistente ao seu Mac (%s, %s GB de RAM, contexto do assistente de %s tokens):"
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- Recomendado"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="Modelo de IA: %s (%s) – melhor opção para os seus %s GB de RAM na janela de contexto exigida pelo assistente"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="Todas as fontes selecionadas (reconhecimento facial ainda desativado)"
MSG_OK_ALREADY_AVAILABLE="%s já disponível"
MSG_OK_APPLE_SILICON_DETECTED="Apple Silicon detectado"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="Apps abertos para acionar a sincronização do iCloud"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="Bancos de dados dos apps já presentes (pulando a abertura prévia)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="Configuração do assistente salva em %s (modo 0600)"
MSG_OK_BACKED_UP_CONTACTS="Backup de %s contatos feito em %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s instalado em %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="LaunchAgent do Ostler RemoteCapture carregado (rótulo %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima e Docker CLI instalados"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="Supervisor do ambiente de contêineres instalado (verifica a cada 5 minutos e reinicia o ambiente se ele parar)"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="Não foi possível agendar o supervisor do ambiente de contêineres. O Ostler ainda será instalado, mas, se o ambiente parar mais tarde, nada o trará de volta sozinho – sua wiki ficaria fora do ar até você executar o instalador novamente."
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="Os arquivos do supervisor do ambiente de contêineres estão ausentes deste instalador, então ele não foi agendado. O Ostler ainda será instalado, mas a recuperação automática do ambiente não está ativa."
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
# NEEDS REVIEW: Page names must match the app's localised navigation; confirm whether 'Governor' is translated in the app.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="Não foi possível iniciar o painel Doctor do Ostler, então http://localhost:8089 não vai responder. As páginas do próprio app que dependem dele – Pessoas, Linha do tempo, Governor, status dos canais – aparecerão como indisponíveis até que ele esteja em execução. Execute o instalador novamente para tentar de novo."
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="Não foi possível agendar o auxiliar que mantém o Mac ativo. O Ostler continua funcionando, mas este Mac pode entrar em repouso durante tarefas longas em segundo plano, e elas serão retomadas quando ele despertar, em vez de terminar durante a noite."
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="Não foi possível agendar o auxiliar de atualização em segundo plano, então novas mensagens, e-mails e eventos do calendário não serão buscados automaticamente. Execute o instalador novamente para restaurá-lo."
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="%s not set up: Ostler has no record of your answer to the question that governs it, so it did not assume one."
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  Re-run Ostler and choose to answer the questions again to turn it on. (consent record: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="Não foi possível agendar o resumo diário, então você não receberá o resumo da manhã. Todo o resto funciona; execute o instalador novamente para restaurá-lo."
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="Não foi possível agendar a limpeza da memória, então fatos obsoletos ou substituídos não terão o peso reduzido automaticamente. Todo o resto funciona; execute o instalador novamente para restaurá-la."
MSG_WARN_EXPORT_SCAN_NOT_LOADED="Não foi possível iniciar o monitor da pasta Downloads, então os arquivos que você colocar em Downloads não serão importados automaticamente. Tudo o que já foi importado não é afetado, e você ainda pode adicionar arquivos de dentro do app. Execute o instalador novamente para restaurá-lo."
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="Não foi possível agendar o auxiliar de nova tentativa do registro de dispositivo. Se o seu iPhone foi registrado durante a configuração, nada muda; se não foi, você precisará fazer o pareamento novamente pelo app, pois ele não será concluído sozinho."
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="Ambiente de contêineres respondendo"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="Item de inicialização obsoleto do Colima, deixado por uma versão anterior, removido"
MSG_OK_CONFIG_SAVED_ENV="Configuração salva em %s/.env"
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Consent records and region persisted to ~/.ostler/posture/"
MSG_OK_AT_REST_EXCLUDED="Fora do Spotlight e do Time Machine (verificado): %s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s NÃO está excluído do Time Machine nem do Spotlight: %s. Seu conteúdo, incluindo os segredos do Ostler, pode ser copiado para o disco de backup. O Doctor continuará mostrando este aviso até que seja corrigido."
MSG_INFO_AT_REST_FOLDER_ABSENT="%s ainda não existe, então não há nada a excluir dos backups."
MSG_WARN_DB_KEY_NOT_EXCLUDED="O arquivo de chave do banco de dados %s NÃO está excluído do Time Machine, então pode ser copiado para o disco de backup."
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="Não foi possível salvar sua escolha sobre o enriquecimento em segundo plano em ~/.ostler/posture/. Sua escolha continua sendo aplicada a esta instalação; ela apenas não aparecerá em um relatório de suporte."
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="Bancos de dados criptografados. Os serviços do Hub leem a chave de um arquivo protegido na sua pasta pessoal, então iniciam sem pedir nada a você."
MSG_OK_DB_KEY_DELIVERED="Chave do banco de dados entregue aos serviços do Hub (%s, legível somente por você)."
MSG_WARN_DB_KEY_NOT_DELIVERED="Não foi possível entregar a chave do banco de dados aos serviços do Hub. Eles abrirão os bancos de dados sem criptografia até que isso seja corrigido."
MSG_INFO_DB_KEY_RECOVER_HINT="Execute isto para recuperá-la e entregá-la: %s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="Criptografando quaisquer bancos de dados restantes de uma instalação anterior"
MSG_WARN_DB_MIGRATION_FAILED="Não foi possível criptografar alguns bancos de dados existentes. Eles continuam legíveis no disco."
MSG_WARN_DB_KEY_MISSING_ON_RERUN="Esta instalação não tem arquivo de chave do banco de dados, então os serviços do Hub estão abrindo os bancos de dados sem criptografia."
MSG_WARN_DB_PLAINTEXT_COUNT="%s banco(s) de dados neste Mac estão legíveis no disco agora."
MSG_INFO_DB_MIGRATE_HINT="Depois, criptografe o que já existe: %s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="Nova tentativa adiada de registro de dispositivo instalada (executa a cada hora até a fila ser esvaziada)"
MSG_OK_DOCKER_RUNNING="Docker em execução"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker em execução (levou %ss)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Agente do Doctor clonado de %s"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Arquivos do agente do Doctor incluídos no instalador"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Dependências do Doctor instaladas"
MSG_OK_EMAIL_CHANNEL_FOLDER="Canal de e-mail: %s (pasta: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de ingestão de e-mail carregado (label com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de ingestão de e-mail incluídos no instalador"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="Scripts de ingestão de e-mail clonados de %s"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="Configurando a memória de conversas do WhatsApp"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  Leitor de conversas do WhatsApp instalado."
MSG_WARN_WHATSAPP_SOURCE_FAILED="Falha ao instalar o leitor de conversas do WhatsApp; o feed de conversas do WhatsApp não será executado. Veja a saída acima."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="Código-fonte do leitor de conversas do WhatsApp não encontrado; ignorando o feed de conversas do WhatsApp."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="Pacote do feed de conversas do WhatsApp não encontrado neste instalador; ignorando. O histórico de mensagens do WhatsApp (com quem você trocou mensagens e quando) não é afetado."
MSG_OK_WHATSAPP_BUNDLE_LOADED="LaunchAgent do feed de conversas do WhatsApp carregado (label com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  A primeira execução lê as conversas recentes do WhatsApp que seu Mac sincronizou (aproximadamente o último ano); tudo fica no seu Mac."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  Logs: %s/whatsapp-bundle.log e whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="Falha ao instalar o LaunchAgent do feed de conversas do WhatsApp. Veja a saída acima; o restante da instalação não é afetado."
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  Ainda não iniciado: o programa do assistente que este agente executa não está no disco. Procurado em: %s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="Configurando a memória de conversas por e-mail"
MSG_OK_EMAIL_SOURCE_INSTALLED="  Leitor de conversas por e-mail instalado."
MSG_WARN_EMAIL_SOURCE_FAILED="Falha ao instalar o leitor de conversas por e-mail; o feed de conversas por e-mail não será executado. Veja a saída acima."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="Código-fonte do leitor de conversas por e-mail não encontrado; ignorando o feed de conversas por e-mail."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="Pacote do feed de conversas por e-mail não encontrado neste instalador; ignorando. A ingestão de e-mail a cada hora não é afetada."
MSG_OK_EMAIL_BUNDLE_LOADED="LaunchAgent do feed de conversas por e-mail carregado (label com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Lê suas conversas de e-mail recentes do armazenamento local do Apple Mail; tudo fica no seu Mac."
MSG_INFO_EMAIL_BUNDLE_LOGS="  Logs: %s/email-bundle.log e email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="Falha ao instalar o LaunchAgent do feed de conversas por e-mail. Veja a saída acima; o restante da instalação não é afetado."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="Configurando a memória de conversas de reuniões e voz"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  Leitor de conversas de reuniões e voz instalado."
MSG_WARN_SPOKEN_SOURCE_FAILED="Falha ao instalar o leitor de conversas de reuniões e voz; o feed não será executado. Veja a saída acima."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="Código-fonte do leitor de conversas de reuniões e voz não encontrado; ignorando o feed."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="Pacote do feed de conversas de reuniões e voz não encontrado neste instalador; ignorando."
MSG_OK_SPOKEN_BUNDLE_LOADED="LaunchAgent do feed de conversas de reuniões e voz carregado (label com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  Transcreve suas próprias reuniões e notas de voz em conversas pesquisáveis; tudo fica no seu Mac."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  Logs: %s/spoken-bundle.log e spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="Falha ao instalar o LaunchAgent do feed de conversas de reuniões e voz. Veja a saída acima; o restante da instalação não é afetado."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="Configurando a memória de conversas do iMessage"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  Leitor de conversas do iMessage instalado."
MSG_WARN_IMESSAGE_SOURCE_FAILED="Falha ao instalar o leitor de conversas do iMessage; o feed de conversas do iMessage não será executado. Veja a saída acima."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="Código-fonte do leitor de conversas do iMessage não encontrado; ignorando o feed de conversas do iMessage."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="Pacote do feed de conversas do iMessage não encontrado neste instalador; ignorando."
MSG_OK_IMESSAGE_BUNDLE_LOADED="LaunchAgent do feed de conversas do iMessage carregado (rótulo com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  Lê suas conversas recentes do iMessage no armazenamento do app Mensagens deste Mac; tudo permanece no seu Mac."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  Registros: %s/imessage-bundle.log e imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="Falha ao instalar o LaunchAgent do feed de conversas do iMessage. Veja a saída acima; o restante da instalação não é afetado."
MSG_OK_EMBEDDING_MODEL_READY="Modelo de embeddings pronto"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="%s contatos exportados (serão importados automaticamente)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="Monitor de exportações instalado (verifica Downloads a cada 4 horas)"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  O monitor de exportações ainda não foi iniciado: o programa do assistente que ele executa não está no disco. Procurado em: %s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="Envio de resumos pré-reunião instalado (verifica a cada 10 minutos durante o dia)"
MSG_OK_MEMORY_HYGIENE_INSTALLED="Rotina de higiene da memória agendada (executa diariamente para evitar que fatos obsoletos escondam os atuais)"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="Seu Mac permanecerá ativo na tomada para que o Ostler continue funcionando (ele ainda entra em repouso na bateria)"
MSG_OK_EXTRACTED="Extraído para %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="Extraído de %s fonte(s). Dados salvos em %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="Nova execução do FDA agendada a cada %s minutos (captura sincronizações lentas do iCloud e conclui o preenchimento retroativo do calendário)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro ativo por 30 dias. Assine no app Ostler do seu iPhone para continuar após o período de teste."
MSG_OK_FOUND="Encontrado: %s"
MSG_OK_FOUND_EXPORTS="Exportações encontradas em %s"
MSG_OK_FOUND_GDPR_EXPORT_S="%s exportação(ões) GDPR encontrada(s):"
MSG_OK_GB_FREE_DISK_SPACE="%s GB de espaço livre em disco"
MSG_OK_GB_RAM_DETECTED="%s GB de RAM detectados"
MSG_OK_GDPR_IMPORT_COMPLETE="Importação GDPR concluída"
MSG_OK_GIT_AVAILABLE="Git disponível"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="Instalação das Ferramentas de Linha de Comando iniciada (baixando em segundo plano enquanto você responde às perguntas abaixo)."
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils instalado (as etapas longas agora têm limite de tempo)"
MSG_OK_HOMEBREW_INSTALLED="Homebrew instalado"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de energia do Hub carregado (rótulo com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de energia do Hub incluídos no instalador"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Scripts de energia do Hub clonados de %s"
MSG_OK_ICAL_SERVER_INSTALLED="API do assistente instalada (loopback 127.0.0.1:8090, com proxy do Doctor)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="LaunchAgent da ponte do iMessage carregado (rótulo com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts da ponte do iMessage incluídos no instalador"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="Scripts da ponte do iMessage clonados de %s"
MSG_OK_IMESSAGE_CHANNEL="Canal do iMessage: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="Pipeline de importação incluído no instalador"
MSG_OK_IMPORT_PIPELINE_READY="Pipeline de importação pronto"
MSG_OK_CM048_PIPELINE_READY="Mecanismo de memória de conversas pronto."
MSG_INFO_CM048_SETTINGS_WRITTEN="  Modelos de conversa definidos como %s (de acordo com seus %s GB de memória)"
MSG_INFO_CM048_SETTINGS_KEPT="  Mantendo suas configurações de conversa existentes (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="Serviço de conhecimento pronto: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="Textos de licença instalados em %s/ (origem: %s)"
MSG_OK_MACOS_DETECTED="macOS %s detectado"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="Abrindo Ajustes do Sistema > Contas de Internet para você adicionar uma conta de e-mail. Volte a esta janela depois de entrar na sua primeira conta."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="Pulando a etapa de Contas de Internet. Você pode adicionar uma conta de e-mail depois nos Ajustes do Sistema; o Doctor vai avisar se nenhum e-mail chegar em 24 horas."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Importando todo o seu histórico do Apple Mail agora. Pode levar um pouco mais de tempo para uma caixa de correio grande."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="Mantendo a janela padrão de cinco anos de e-mails. Você pode importar mais depois pelo Doctor."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text já disponível"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="Ollama instalado"
MSG_WARN_OLLAMA_CUSTOMER_APP_PRESENT="An Ollama app is already installed in Applications. Ostler leaves it exactly as it is and runs its own copy of Ollama %s alongside it. If that app is open in the menu bar, quit it so Ostler can start its own."
MSG_WARN_OLLAMA_PIN_DEFERRED="Could not update Ollama to %s this time, so Ostler is keeping the copy it already runs (%s). Your assistant keeps working. The update will be tried again the next time the installer runs. Details: %s"
MSG_WARN_MODEL_PULL_HELD_OLLAMA_UNPINNED="Not downloading %s this time: Ostler's tested copy of Ollama (%s) is not installed yet, and a different Ollama could fetch the wrong build. The next installer run downloads it."
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama instalado (somente CLI – pode precisar de início manual após reiniciar)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama instalado (app para Mac)"
MSG_OK_OLLAMA_RUNNING="Ollama em execução"
MSG_OK_EMBEDDINGS_VERIFIED="Mecanismo de embeddings verificado (vetores de 768 dimensões)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: 0 erros nas próprias verificações de inicialização"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent do assistente Ostler carregado (rótulo com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s preparado em %s (assinado)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s preparado em %s (não assinado)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor em execução em http://localhost:8089/doctor"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  O módulo de extração de dados carrega corretamente."
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Leitor do Apple Mail instalado."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  Mecanismo de ingestão de e-mails instalado."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="Comandos ostler-import, ostler-fda e ostler-uninstall instalados"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="Senha registrada. Ela vai criptografar seus bancos de dados durante a Fase 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="Senha de recuperação configurada."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="Orientações sobre a senha confirmadas."
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="Senha da exportação do Disney+ registrada. Ela será usada durante a importação."
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="Pulando a exportação do Disney+: nenhuma senha foi informada. Nada mais é afetado."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="Fonte de energia: tomada (Mac de mesa, sem bateria)"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="Fonte de energia: tomada (ótimo – a instalação pode levar de 45 minutos a algumas horas, e a energia da tomada a mantém estável)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="Instalação anterior detectada. Carregando configuração..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="Usando o Python %s incluído (não é preciso instalar no sistema)"
MSG_OK_PYTHON_INSTALLED="Python %s instalado"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="Serviço de pareamento em bom estado"
MSG_WARN_GATEWAY_NOT_RESPONDING="O serviço de pareamento não está respondendo (127.0.0.1:8000) - o pareamento com iPhone/navegador e o assistente de chat podem ainda não funcionar"
MSG_OK_DOCTOR_HEALTHY="Doctor em bom estado"
MSG_WARN_DOCTOR_NOT_RESPONDING="O Doctor não está respondendo (127.0.0.1:8089). O app e o navegador acessam o Ostler por ele, então os dados e o pareamento podem ficar indisponíveis"
MSG_OK_WIKI_HEALTHY="Seu wiki está saudável"
MSG_OK_ICAL_SERVER_HEALTHY="API do assistente saudável"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="A API do assistente não está respondendo (127.0.0.1:8090). Pessoas, Reuniões e Linha do tempo podem ficar vazias até ela iniciar"
MSG_OK_READY="%s pronto"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="Fontes recomendadas selecionadas"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="Chave de recuperação salva nas Chaves do iCloud/Acesso às Chaves (procure 'Ostler' no app Senhas)"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Extensão do Safari instalada em %s"
MSG_OK_SAFARI_EXTENSION_PAIRED="Extensão do Safari pareada com este Hub"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="A segurança já foi configurada em uma execução anterior."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="Módulo de segurança instalado no venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="Novo JWT_SECRET gerado em %s"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="Token de serviço do PWG gerado em %s"
MSG_OK_SEEDED_EXTENSION_TOKEN="Chave da extensão do navegador gerada em %s"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="Serviços iniciados (Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  Coleção de busca preparada: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="Ainda não foi possível preparar a coleção de busca %s. A importação de dados abaixo tentará novamente e vai parar, sem descartar seus dados, se ainda não conseguir."
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="O índice de busca ainda não ficou pronto a tempo. A importação de dados abaixo vai esperar por ele, preparar as coleções e parar, sem descartar seus dados, se o armazenamento ainda não estiver pronto."
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="Seus dados não foram importados. Não foi possível preparar o armazenamento de busca para recebê-los (ausente: %s), e importar assim mesmo os teria descartado em silêncio. Nada foi perdido. Execute o instalador novamente quando o computador estiver ocioso, ou defina OSTLER_QDRANT_READY_WAIT_S para esperar mais."
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="A importação dos seus dados processou %s registros, mas não armazenou nenhum: o armazenamento de busca rejeitou todos, e o resultado seria um grafo de conhecimento vazio apresentado como completo. Interrompendo em vez de mostrar isso a você. Execute o instalador novamente quando o computador estiver ocioso."
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="Não foi possível ler o log da própria importação, então a verificação de que seus dados realmente chegaram não pôde ser feita. Isto não indica que a importação falhou, nem que foi bem-sucedida."
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="Repouso desativado na tomada, repouso na bateria preservado, ativação por rede habilitada"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="Repouso desativado, ativação por rede habilitada"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale já instalado"
MSG_OK_TAILSCALE_INSTALLED="Tailscale instalado"
MSG_OK_TAILSCALE_ENV_PERSISTED="IP do Tailscale salvo em .env – o app Ostler no seu iPhone vai usá-lo na primeira abertura."
MSG_OK_TAILSCALE_IP="IP do Tailscale: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Serviço em segundo plano do Tailscale iniciado (modo userspace, sem extensão do sistema)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="Não foi possível iniciar o serviço em segundo plano do Tailscale. Você pode executar a configuração novamente depois, em Ajustes."
MSG_INFO_TAILSCALE_SIGN_IN_URL="Abrindo seu navegador para entrar no Tailscale: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Porta %s do Hub exposta na sua tailnet"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="Não foi possível expor a porta %s do Hub na sua tailnet; o acesso fora da rede local pode ser limitado"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="Seu wiki agora pode ser lido a partir dos seus próprios dispositivos em %s – com login feito como você, e somente você."
MSG_INFO_WIKI_TAILNET_OWNER="O acesso ao wiki é restrito à sua conta do Tailscale (%s). Outras pessoas na sua tailnet recebem um 403."
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="Seu wiki fica somente neste Mac. Abra o Ostler e escolha Wiki na barra lateral para lê-lo."
MSG_INFO_WIKI_TAILNET_BANNER="%s  (a partir dos seus próprios dispositivos, pelo Tailscale. Esta é a única rota que pede o login acima.)"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="no app Ostler. Abra o Ostler e escolha Wiki na barra lateral; suas páginas estão lá, já com o login feito."
MSG_INFO_WIKI_INTERNAL_ADDRESS="O Ostler busca essas páginas em http://localhost:8044 neste Mac. Esse endereço é interno e não há nada nele em que você precise fazer login."
MSG_INFO_WIKI_SIGN_IN="O login do seu wiki é %s com a senha %s. O Ostler o apresenta por você, então não há nada para digitar neste Mac; você só precisa dele em mãos quando abrir o wiki a partir de outro dispositivo seu pelo Tailscale."
MSG_INFO_WIKI_SIGN_IN_WITHHELD="Seu login da wiki é %s. A senha não é gravada neste registro; ela está na área de transferência e no arquivo indicado abaixo. O Ostler a preenche para você, então não há nada para digitar neste Mac."
MSG_INFO_WIKI_PORT_LAST_STATUS="Último status HTTP da porta da wiki: %s (000 significa que nada respondeu; 403 significa que respondeu e recusou a credencial)."
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="Sua senha também está guardada em %s, então a área de transferência não é a única cópia."
MSG_INFO_WIKI_STILL_BUILDING="Ainda em construção. %s páginas já estão no disco, e a última resposta do endereço da wiki foi HTTP %s. Ela aparecerá no app Ostler sozinha. Você não precisa fazer nada."
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="A primeira construção ainda não gerou nenhuma página (veja os avisos acima). Mesmo assim, sua wiki abrirá no app Ostler quando estiver construída, e o login acima continua sendo seu."
MSG_INFO_WIKI_READINESS_NOT_MEASURED="Esta execução não verificou se a wiki já está em funcionamento, então não afirma nada nem num sentido nem no outro. Sua wiki abre no app Ostler de qualquer forma, e o login acima continua sendo seu."
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="Não foi possível confirmar qual conta do Tailscale é dona deste Mac, então a wiki NÃO foi exposta na sua tailnet. Ela continua disponível neste Mac, no app Ostler, em Wiki."
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="Não foi possível publicar a wiki na sua tailnet; ela continua disponível neste Mac, no app Ostler, em Wiki."
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="Não foi possível recarregar o controle de acesso da wiki, então a wiki NÃO foi exposta na sua tailnet."
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="O Tailscale Funnel está ativado para %s. O Funnel publica na internet aberta. O Ostler nunca ativa o Funnel e sua wiki recusa tráfego do Funnel, então nada do Ostler fica público – mas, se você não pretendia ativá-lo, desative-o no console de administração do Tailscale para esta máquina."
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="Atribuições de terceiros instaladas (origem: %s)"
MSG_OK_USER_FACING_TREE_READY="Estrutura visível ao usuário pronta"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="Usando a pasta/etiqueta 'Ostler' no lugar."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane funcionando bem (pesquisa local na web)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane em execução em http://localhost:3000 (conversa com seu Ollama local)"
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="WhatsApp connector will be enabled (consent recorded)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="LaunchAgent de atualização da wiki do primeiro dia carregado (reconstrói sua wiki a cada 30 minutos nas primeiras horas e depois para)"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="Ainda mesclando contatos duplicados – agendas grandes podem levar vários minutos (%ss decorridos)"
MSG_INFO_DEDUPE_MERGED="Contatos duplicados mesclados"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="Mesclar contatos duplicados está demorando para uma agenda deste tamanho. O processo continuará em segundo plano após a instalação – sua wiki é atualizada automaticamente quando terminar."
MSG_WARN_DEDUPE_INCOMPLETE="A etapa de deduplicação de todo o grafo não terminou corretamente (veja %s); continuando"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="Contatos duplicados totalmente mesclados durante a instalação; nenhuma atualização em segundo plano necessária"
MSG_OK_DEDUPE_CATCHUP_LOADED="LaunchAgent de deduplicação de contatos em segundo plano carregado (termina de mesclar duplicados após a instalação e depois para)"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="Não foi possível carregar o LaunchAgent de deduplicação de contatos em segundo plano. Os duplicados ainda serão mesclados pela manutenção diária; só vai demorar mais para se estabilizar."
MSG_OK_ENRICH_AGENT_LOADED="LaunchAgent de enriquecimento em segundo plano carregado (completa detalhes de seus filmes, lugares, livros e links; roda em etapas ao longo do próximo dia, mais ou menos)"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="Não foi possível carregar o LaunchAgent de enriquecimento em segundo plano. Suas preferências estão salvas e pesquisáveis; só ficarão sem os detalhes extras de referência (diretores, elenco, locais) até que ele rode."
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="LaunchAgent de recompilação da wiki carregado (label com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Scripts de recompilação da wiki incluídos no instalador"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Scripts de recompilação da wiki clonados de %s"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="Configurando sua Página Inicial (atualização a cada hora)"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="Gerador da Página Inicial incluído no instalador"
MSG_OK_EDITOR_FRONTPAGE_LOADED="LaunchAgent da Página Inicial carregado (label com.creativemachines.ostler.editor-frontpage)"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  A primeira atualização roda agora; a Página Inicial do seu painel vai se completando conforme o Ostler lê suas preferências."
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  Registros: %s/editor-frontpage.log e editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="Gerador da Página Inicial não encontrado neste instalador; a Página Inicial do painel não será atualizada."
MSG_WARN_EDITOR_FRONTPAGE_FAILED="Falha ao instalar o LaunchAgent da Página Inicial. Veja a saída acima; o restante da instalação não é afetado."
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="Configurando a atualização complementar da Página Inicial"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="LaunchAgent complementar da Página Inicial carregado (verifica a cada 5 minutos até que seus interesses sejam lidos e depois para)"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="Não foi possível carregar o LaunchAgent complementar da Página Inicial. Sua Página Inicial e o que o Ostler sabe sobre seus interesses serão preenchidos na próxima atualização horária."
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="Pulando a atualização complementar da Página Inicial: a atualização da Página Inicial não está instalada, então não há nada para executar de novo."
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki em execução em http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="Seu wiki está pronto para ser explorado. O Ostler está escrevendo os resumos das páginas em segundo plano, então eles vão aparecendo aos poucos. Você já pode começar a usar seu wiki agora mesmo."
MSG_OK_YOUR_ASSISTANT_CALLED="Seu assistente se chama %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="Scripts do resumo de contexto pessoal incluídos no instalador"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="LaunchAgent do resumo de contexto pessoal carregado (label com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  Logs: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="Reutilizando a instalação existente de context-refresh em %s"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="Scripts do resumo de contexto pessoal não incluídos; o assistente usará apenas consultas em tempo real (sem resumo de contexto sempre ativo)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="O LaunchAgent do resumo de contexto pessoal não foi carregado; veja context-refresh.err. O assistente continua respondendo por consultas em tempo real"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="O código-fonte clonado do serviço Knowledge não tem a configuração de empacotamento, então o ambiente dele não foi configurado."
MSG_WARN_BUNDLE="  Pacote: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="O Ostler RemoteCapture v%s funciona apenas em Apple Silicon (detectado: %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="Não foi possível baixar o Ostler RemoteCapture v%s de %s"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="Causas comuns: a tag da versão ainda não foi publicada, a rede está offline ou a notarização ainda está em andamento. Execute o instalador novamente quando a versão estiver disponível."
MSG_WARN_CM042_EXTRACT_FAILED="Não foi possível extrair o tarball do Ostler RemoteCapture; ignorando o LaunchAgent."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Falha ao carregar o LaunchAgent do Ostler RemoteCapture. Veja a saída acima e ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  O enriquecimento de conversas não estará disponível. O restante do Ostler é instalado normalmente; execute novamente sem --allow-plaintext para ativar o mecanismo de memória de conversas."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="Falha na instalação do mecanismo de memória de conversas (clone)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  Procurado em: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  Isso geralmente significa que o instalador .app foi criado sem"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  o pacote cm048_pipeline incorporado em"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Baixe o instalador novamente ou"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  execute novamente com --allow-plaintext para uma instalação de dev/CI."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="Mecanismo de memória de conversas não encontrado. O enriquecimento de conversas não pode funcionar sem ele."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="Configuração do mecanismo de memória de conversas ignorada (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="A fonte do mecanismo de memória de conversas foi encontrada, mas falta o pyproject.toml; configuração do venv ignorada."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Falha ao iniciar o Colima. Tentando o Docker Desktop como alternativa..."
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="Não foi possível instalar o GNU coreutils; as etapas longas serão executadas sem limite de tempo (uma linha de progresso ainda mostrará que estão em andamento)."
MSG_WARN_COLIMA_START_RETRY="O Colima não iniciou corretamente (o socket do Docker não estava pronto). Tentando novamente em %ss..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="Causas comuns: a tag v%s ainda não foi publicada, a rede está offline,"
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  consent_cli stderr (first 400 chars):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  O script de console não foi criado em %s; o pyproject.toml pode estar sem a entrada [project.scripts]."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="Continuando porque --allow-plaintext foi informado."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="Continuando a instalação. Execute \`ostler-fda\` novamente depois de diagnosticar o erro acima."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="Continuando sem o preenchimento automático pelo cartão de contato – o Ostler vai perguntar a você."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  As conversas enviadas ao iMessage falharão silenciosamente até que"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="Não foi possível alterar os ajustes de repouso. Ative \"Impedir repouso automático quando conectado à tomada\" em Ajustes do Sistema > Energia."
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="Não foi possível alterar os ajustes de repouso. Ative \"Impedir repouso automático\" em Ajustes do Sistema > Energia."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="Não foi possível baixar o ostler-assistant v%s de %s"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="Não foi possível extrair o mbox do Gmail do zip do Takeout – ignorando."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="Não foi possível extrair o tarball do ostler-assistant; ignorando o LaunchAgent."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="Não foi possível encontrar a CLI do Tailscale. Você pode configurá-la manualmente mais tarde."
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Could not install legal/ consent-strings package; continuing"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="Não foi possível instalar o diretório LICENSES/ (não fatal)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="Não foi possível instalar o ostler_security no venv do Hub."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="Não foi possível instalar o THIRD_PARTY_NOTICES.md (não fatal)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="Não foi possível obter o agente do Doctor (a cópia incluída e a clonagem falharam)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="Arquivos do Ostler Doctor não encontrados. Necessários para o fluxo de pareamento do iOS (o Ostler.app incorpora :8089/pair-ios em iframe)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  Procurado em: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  Isso geralmente significa que o .app do instalador foi criado sem"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  o código-fonte doctor/agent/ incluído em"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Baixe o instalador novamente ou"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  execute de novo com --allow-plaintext para uma instalação de dev/CI."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Instalação do Doctor interrompida: necessário para o fluxo de pareamento do iOS. Baixe o instalador novamente ou use --allow-plaintext para uma instalação de dev/CI."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="Não foi possível obter os scripts de ingestão de e-mail (a cópia incluída e a clonagem falharam)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="Não foi possível obter os scripts de hub-power (a cópia incluída e a clonagem falharam)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="Não foi possível obter os scripts de wiki-recompile (a cópia incluída e a clonagem falharam)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="Não foi possível abrir automaticamente a URL da Chrome Web Store: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="Não foi possível gravar o region.json (continuando; o Doctor vai avisar)"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="Não foi possível registrar que a chave de recuperação foi entregue. O resumo desta execução continua correto, mas uma execução futura pode não perceber isso e avisar de novo – essa é a direção segura para essa falha."
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="Your recovery key was not saved to Keychain. Write it down and keep it somewhere safe, away from this Mac."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="Não foi possível iniciar o Ollama automaticamente."
MSG_FAIL_OLLAMA_PORT_IN_USE="Outro programa já está usando a porta 11434, de que o Ostler precisa para a IA local. O Ostler não conseguiu iniciar a própria cópia, então a instalação parou aqui em vez de ficar pela metade.

  O que está ocupando a porta: %s
  O erro exato está em: %s

Geralmente é uma cópia do Ollama que você já tinha ou uma deixada em execução por uma instalação anterior do Ostler. Feche-a (ou reinicie este Mac) e execute o instalador novamente."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="Não foi possível atualizar o pipeline (sem conexão?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="Não foi possível gravar o pipeline_signals.json. O diagnóstico de Mail vazio do Doctor usará padrões seguros até a próxima instalação ou ciclo."
MSG_WARN_CURL_SAID="O curl disse:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="Diretório não encontrado: %s – ignorando a importação."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="O Docker não iniciou em %s segundos."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="O Docker está instalado, mas não está em execução. Será necessário iniciá-lo."
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="O comando docker está neste Mac, mas não há nada em execução por trás dele. No macOS, o comando docker é apenas um cliente: ele precisa de um mecanismo, como o Colima ou o Docker Desktop, para executar qualquer coisa. O instalador vai configurar um."
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="Diagnóstico do ambiente de contêineres - cliente docker: %s | colima: %s | Docker Desktop: %s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="O contêiner da wiki foi iniciado, mas nada respondeu em http://localhost:8044 em 60 segundos. Considere que a wiki NÃO está em execução: o código de saída do comando de início não prova que a página carrega."
MSG_WARN_WIKI_NOT_RESPONDING="Sua wiki não está respondendo (127.0.0.1:8044). Ela roda em um contêiner, então isso geralmente significa que o ambiente de contêineres parou. Abra o Ostler Doctor em http://localhost:8089/doctor para ver o motivo."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama no meio da instalação e travam as verificações de prontidão."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  primeiros indícios (canais ainda se conectando + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="Falha ao instalar o LaunchAgent de ingestão de e-mail. Veja a saída acima."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="Falha ao instalar o LaunchAgent da ponte do iMessage. As respostas do iMessage para o usuário do assistente não vão funcionar até você executar o instalador novamente ou executar INSTALL_SNIPPET.sh manualmente."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="Os scripts da ponte do iMessage não estão incluídos e --allow-plaintext foi usado; a instalação do LaunchAgent será ignorada. As respostas do iMessage para o usuário do assistente não vão funcionar."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="A criptografia não vai funcionar."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="A criptografia não vai funcionar, e"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="confirme se a tag PWG_KNOWLEDGE_REPO fixada o inclui."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  Events, permissão para o app Mensagens)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="O extrator FDA foi encerrado com código diferente de zero (%s). Últimas 20 linhas da saída:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="O módulo de extração FDA não está incluído neste instalador."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="Esperado em: Contents/Resources/ostler_fda/ (dentro do .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="Causa mais provável: uma regressão de build removeu a cópia do vendor. Baixe o .app novamente em ostler.ai/install."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="O módulo de extração FDA não está incluído. Continuando porque --allow-plaintext foi usado – a extração instantânea de dados será ignorada."
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="O módulo de extração de dados está no disco, mas suas dependências não foram instaladas, então ele não pode ser carregado:"
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="Continuando porque --allow-plaintext foi usado – a atualização agendada dos dados vai falhar a cada execução."
MSG_WARN_FILEVAULT_NOT_ENABLED="O FileVault NÃO está ativado."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="Não foi possível ativar o primeiro mês grátis agora; a instalação vai continuar. Abra o app Ostler no seu iPhone depois de parear para resolver."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="Acesso Total ao Disco não concedido ao Terminal."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="%s GB de RAM detectados. Você vai receber o assistente compacto (gemma4:e2b): confiável, preciso, em menos de um segundo em perguntas curtas, com chamadas de ferramentas e um sincero “não sei” quando for o caso. Para respostas mais ricas em perguntas mais longas, 24 GB ou mais liberam o assistente padrão (qwen3.5:9b). Você pode trocar de Mac depois reinstalando."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="A importação de dados via GDPR teve erros. Você pode executar novamente com:"
MSG_WARN_GRAPH_DB_PULL_RETRY="O download do banco de dados não foi concluído (tentativa %s de %s). Tentando novamente em %ss..."
MSG_WARN_GRAPH_DB_UP_RETRY="Os bancos de dados do grafo de conhecimento não iniciaram (tentativa %s de %s). Tentando novamente..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="A importação do GDPR faz parte da instalação padrão do produto. Sem ela, seu grafo social (LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google Calendar) não pode ser importado."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="A importação do GDPR ficará indisponível nesta instância até que o pipeline de importação seja reinstalado."
MSG_WARN_GIT_SAID="O Git informou:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  Falha na verificação de integridade: ostler-knowledge --version não produziu saída."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  Falha na verificação de integridade: o mecanismo de memória de conversas não pôde ser carregado (pwg-convo ou a importação do pipeline não retornou corretamente)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="O instalador do Homebrew encerrou com %s. Seguem as últimas 30 linhas de %s:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Log de instalação do Homebrew (final) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="A instalação do pip do Doctor encerrou com %s. Seguem as últimas 30 linhas de %s:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Log de instalação do pip do Doctor (final) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="A instalação do pip do pipeline encerrou com %s. Seguem as últimas 30 linhas de %s:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- Log de instalação do pip do pipeline (final) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Falha ao instalar o LaunchAgent de energia do Hub. Veja a saída acima."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="Scripts de energia do Hub não encontrados no caminho esperado do pacote."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  O .app do instalador parece não ter vendor/hub_power/"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  em Contents/Resources/hub-power/. O controle de consumo baseado na bateria não será instalado; o restante da instalação vai continuar."
MSG_WARN_ICAL_SERVER_FAILED="Não foi possível iniciar a API do assistente; o app Ostler no seu iPhone terá acesso limitado até a próxima execução da instalação."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - Falha ao baixar a imagem (rede, espaço em disco ou tempo esgotado do registro)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="Não foi possível gravar o sinal de FDA do iMessage em pipeline_signals.json. O painel do Doctor pode não exibir automaticamente o cartão de Acesso Total ao Disco."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="O host IMAP está vazio – tente novamente."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="Permissão de Automação do iMessage: não concedida (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="Permissão de Automação do iMessage: verificação inconclusiva."
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="O histórico do iMessage (chat.db) não pode ser lido: o Acesso Total ao Disco ainda não foi concedido ao daemon do Ostler. A leitura do histórico do iMessage continua desativada até você concedê-lo em Ajustes do Sistema > Privacidade e Segurança > Acesso Total ao Disco."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="Abrindo Ajustes do Sistema > Privacidade e Segurança > Automação. Marque a linha Mensagens para OstlerInstaller (ou Terminal) para configurar o envio pelo iMessage."
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="Não é um endereço de e-mail completo, portanto foi ignorado: %s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="Digite pelo menos um endereço de e-mail completo (por exemplo, you@example.com)."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="O iMessage precisa de pelo menos um contato permitido. Tente novamente ou"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="Pipeline de importação indisponível (repositório privado, somente para testadores beta)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="O pipeline de importação não está incluído no instalador. Falha crítica ignorada."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="O pipeline de importação não está incluído no instalador. Este é o caminho de instalação do produto; o pacote Python contact_syncer deveria vir dentro do bundle .app."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX significa que o assistente lerá todos os e-mails que você receber."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Espaço em disco insuficiente para o volume de saída da wiki"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Mac Intel detectado – o desempenho será limitado. Recomendamos Apple Silicon."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s é um host de provedor de nuvem."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="JWT_SECRET em %s está na lista de bloqueio; gerando novamente para manter os serviços do grafo de conhecimento importáveis"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="JWT_SECRET em %s é curto demais (%s < %s caracteres); gerando novamente"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="Repositório de conhecimento clonado, mas pyproject.toml ausente; configuração do venv ignorada."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="Falha na instalação do serviço de conhecimento (clone)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="Licença: %s é distribuído sob os Termos de Uso do Gemma do Google, não sob Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="Instalações em MacBook precisam disso para o gerenciamento de bateria e repouso."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="A permissão de Contatos do macOS foi negada ou ainda não foi concedida."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="O macOS NÃO solicitará essa permissão a partir de um script – você precisa concedê-la manualmente."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Instalações em Mac mini não são afetadas; usuários de MacBook devem tentar novamente."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="Os dados do Mail ainda podem ser importados manualmente:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  Nova tentativa manual: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  Nova tentativa manual depois que a causa for resolvida:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Nem Apple Mail nem IMAP personalizado selecionado – usando Apple Mail como padrão."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="Nenhuma senha definida; os bancos de dados não serão criptografados."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="Uma instalação anterior gerou sua chave de recuperação, mas não foi concluída, então ela nunca foi mostrada a você. Não é possível recuperá-la – ela nunca é armazenada em lugar nenhum, nem aqui."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="Sua senha ainda funciona e nada está bloqueado hoje. Mas, no momento, não há como voltar a entrar caso você a esqueça."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="Entre em contato com o suporte para configurar a segurança do zero, o que mostrará uma nova chave de recuperação para você guardar."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="As senhas não coincidem. Tente novamente."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="Falha na configuração da senha. Saída:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="Entrada vazia. Senha ignorada."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="A senha deve ter pelo menos 12 caracteres. Tente novamente."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="É necessária uma senha para criptografar seus dados."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="Esse não é um número internacional. Use um + no início, depois o código do país e o restante do número, por exemplo +447700900123. Tente novamente."
MSG_WARN_OLLAMA_NOT_RESPONDING="O Ollama não está respondendo"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="Falha em ollama pull %s (tentativa %s/3). Tentando novamente em %ss..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="Apenas %s GB livres. Recomendamos pelo menos 35 GB (imagens do Docker + modelo de IA + dados)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="Na bateria, o LaunchAgent de energia do Hub (etapa 3.14) pode pausar"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="ou execute o instalador novamente e escolha outro canal."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="ou está adiantado em relação ao pipeline de lançamento da Fase B. Execute o instalador novamente assim que o"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="O doctor do ostler-assistant relatou %s erro(s)."

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="O Ostler terminou, mas %s erro(s) ocorreram durante a instalação."
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  Todos os detalhes estão em ~/.ostler/logs/install.log. O Ostler ainda vai iniciar; abra o Doctor para ver o que precisa de atenção."
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="O Ostler terminou, mas %s etapa(s) da instalação não foram concluídas corretamente: %s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="O Ostler terminou sem erros durante a instalação."

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="O ostler-assistant foi extraído, mas a verificação de --version falhou."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="A instalação do LaunchAgent do assistente Ostler falhou após 3 tentativas. Veja a saída de diagnóstico acima e abaixo."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="A tentativa %s de instalar o LaunchAgent do assistente Ostler falhou; tentando novamente."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="stderr completo do daemon em: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="Último trecho do stderr:"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="O ostler-assistant v%s funciona apenas em Apple Silicon (detectado: %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  Não foi possível instalar a dependência de armazenamento criptografado no venv da memória de conversas; o enriquecimento de conversas não será executado."
MSG_INFO_COACH_DB_READY="  Coaching database ready, encrypted: %s"
MSG_WARN_COACH_DB_NOT_CREATED="  Could not prepare the encrypted coaching database (it will be created on the first coaching note): %s"
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  Fonte da dependência de armazenamento criptografado não encontrada em SCRIPT_DIR; o mecanismo de memória de conversas não pode ser carregado e o enriquecimento de conversas não será executado."
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - imagem ostler-wiki-compiler ainda não disponível para download (registro não configurado)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph não está respondendo"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph ainda não está íntegro nesta fase (veja os logs acima)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="As senhas não coincidem (ou estavam vazias). Tente novamente."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="A instalação principal normalmente leva de 45 minutos a algumas horas (downloads do Docker e do Ollama + primeira configuração), mais tempo em uma conexão lenta ou em um Mac com anos de histórico. Longos períodos sem atividade são normais – ele está baixando e configurando em segundo plano, não travado."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  Falha no pip install; o mecanismo de memória de conversas não estará disponível."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  Falha no pip install; o email-ingest usará o python do sistema (que também pode falhar na execução)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  Falha no pip install; o ostler-knowledge não estará disponível."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  Falha no pip install; o mecanismo de ingestão de e-mails não está disponível. O LaunchAgent executado a cada hora ainda vai gerar arquivos mbox, mas não poderá ingeri-los no grafo até que isso seja reparado."
MSG_WARN_CM021_SOURCE_NOT_FOUND="Fonte do mecanismo de ingestão de e-mails não encontrada no pacote do app; a tarefa em segundo plano executada a cada hora salvará os arquivos de e-mail sem ingeri-los."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="Fonte do ostler_fda não encontrada no pacote do app; o LaunchAgent do email-ingest usará o python do sistema na execução."
MSG_WARN_PIP_SAID="O pip informou:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="Conecte à tomada para a instalação completa."
MSG_WARN_PORT_1_ALREADY_USE_PID="A porta %s já está em uso por %s (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - A porta 3000 já está em uso por outro serviço"
MSG_WARN_POWER_SOURCE="Fonte de energia: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="Falha na instalação do sqlcipher3."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="Falha na instalação do sqlcipher3. Os bancos de dados não serão criptografados."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="Python 3 não encontrado. Instalando o Python 3.12..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="O Python %s é muito antigo (é necessário o 3.10 ou superior). Instalando o Python 3.12..."
MSG_WARN_QDRANT_NOT_RESPONDING="O Qdrant não está respondendo"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         Leia https://ai.google.dev/gemma/terms antes de usar comercialmente."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="Leia a versão pública em https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="O Redis não está respondendo"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="a versão for lançada, ou instale o binário manualmente:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="Executando novamente – digite um host próprio (self-hosted) ou pressione Ctrl-C e abra o instalador de novo escolhendo Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="execute o instalador novamente com o iMessage desmarcado para ignorá-lo."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="EXECUTANDO COM --allow-plaintext: criptografia desativada. NÃO USE EM PRODUÇÃO."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  Execute \`%s doctor\` após a primeira inicialização"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="Execute 'tailscale ip --4' depois de fazer login e adicione o endereço ao app para iOS."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Falha ao copiar a extensão do Safari; você pode instalá-la manualmente depois"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="A extensão do Safari foi instalada, mas não havia token de extensão disponível para pareá-la; a captura de navegação ficará desativada até você executar o instalador novamente"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="Não foi possível parear a extensão do Safari com este Hub; a captura de navegação ficará desativada até você executar o instalador novamente"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="Módulo de segurança não encontrado. A configuração da chave de acesso será ignorada."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  Procurado em: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  Isso geralmente significa que o .app do instalador foi criado sem"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  o pacote ostler_security incluído em"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. Baixe o instalador novamente ou"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  execute novamente com --allow-plaintext para uma instalação de dev/CI."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="Falha na configuração de segurança. Continuando sem criptografia do banco de dados."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="Falha na configuração de segurança. Saída:"
MSG_WARN_SEE_STDERR_FRAGMENT="  Consulte %s para ver o trecho do stderr."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="Ignorando a instalação do binário. O config.toml gerado pelo instalador continua no lugar."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Ignorando a instalação do LaunchAgent do Doctor."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="Ignorando a instalação do LaunchAgent de ingestão de e-mail."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="Ignorando a instalação do LaunchAgent. Implantações em Mac mini não são afetadas."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="Ignorando a instalação do LaunchAgent. Tente: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="Ignorando a instalação do LaunchAgent de recompilação da wiki."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="Algumas portas estão em uso. Os contêineres do Docker podem não iniciar."
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="A porta %s já está em uso por %s (PID %s), que pertence a esta conta. Encerre-o e execute o instalador novamente."
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="A porta %s já está em uso por um programa de OUTRA conta de usuário neste Mac. O Ostler não pode compartilhá-la, e iniciar mesmo assim poderia misturar os dados das duas contas. Encerre a sessão da outra conta ou instale o Ostler em um Mac em que esta seja a única conta usando essa porta."
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="O Ostler não consegue iniciar seus bancos de dados porque as portas de que precisa já estão ocupadas."
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="Pare o que estiver usando as portas listadas acima e execute o instalador novamente."
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="Não foi possível verificar se a porta %s está livre. Isso não é o mesmo que a porta estar livre."
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="Uma ou mais verificações de porta não puderam ser executadas, então não é possível descartar um conflito com outro programa."
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="Não foi possível executar a verificação de porta mais confiável neste Mac, então as verificações abaixo são menos completas do que o normal."
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="O Ostler não conseguiu confirmar que essas portas estão livres e não iniciará seus bancos de dados em uma porta que não verificou. Entre em contato com o suporte e envie o log de instalação."
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="Não foi possível remover um item de inicialização obsoleto do Colima. Sua wiki pode não carregar após uma reinicialização; entre em contato com o suporte."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="Pare os serviços em conflito ou altere as portas em docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="O Tailscale não fez login em 3 minutos. Você pode voltar a isso mais tarde em Ajustes."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="O IP do Tailscale foi gravado em .env, mas uma leitura posterior não conseguiu encontrá-lo. O app Ostler no seu iPhone pode não detectá-lo – execute install.sh --repair novamente se isso acontecer."
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="Não foi possível salvar sua resposta sobre o acesso remoto, então a próxima reinstalação vai perguntar de novo. Todo o resto não foi afetado."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="A instalação do Tailscale falhou – você pode instalá-lo depois em tailscale.com"
MSG_WARN_TAILSCALE_STATE_UNREADABLE="Este Mac tem ajustes do Tailscale que não puderam ser lidos, então não sabemos se ele ainda está conectado à sua rede. Escolha abaixo – se ele já estiver conectado, configurá-lo novamente não causa problema."
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="os serviços implantados se recusam a iniciar sem eles."
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  isso seja resolvido. Veja o banner de próximos passos para a correção."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  para inspecionar. cron-delivery / imessage-tcc são comuns"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  Tente: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  Tente: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="Opção '%s' não reconhecida; usando iMessage + e-mail por padrão."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="Opção não reconhecida. Usando Recomendado."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  Falha na atualização; continuando com o checkout existente."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="Use o Apple Mail (recomendado acima) para essa conta – o Ostler nunca armazena senhas da nuvem."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="Usando INBOX. O assistente vai ler todos os e-mails recebidos."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="O contêiner do Vane foi iniciado, mas http://localhost:3000 não respondeu em 60s."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="O Vane (busca local na web) não conseguiu iniciar. Causas comuns:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  A busca na web é opcional; o restante do Ostler funciona sem ela."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="Recomendamos fortemente usar um marcador/pasta dedicado em vez disso."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="O WhatsApp precisa de um número de telefone para enviar o resumo. Tente novamente,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="A wiki foi compilada, mas o contêiner wiki-site não conseguiu iniciar."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="A primeira compilação da wiki falhou. Causas comuns:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="Não foi possível carregar o LaunchAgent de atualização da wiki do primeiro dia. A reconstrução diária da wiki continua funcionando; sua wiki será atualizada no dia seguinte, e não dentro de uma hora."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Falha ao instalar o LaunchAgent de recompilação da wiki. Veja a saída acima."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="A wiki não será atualizada automaticamente; a reconstrução manual continua disponível:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="A configuração do assistente de configuração permanece no lugar; o binário continua preparado. Nova tentativa manual:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="Seu assistente precisa de um nome. Escolha uma das sugestões acima ou digite o seu."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="Você pode conceder o acesso novamente em Ajustes do Sistema > Privacidade e Segurança > Contatos."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="Você pode executar a configuração de segurança depois: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="Pode ser necessário instalar manualmente: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  obtido:   %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="O pacote do Ostler RemoteCapture não estava em %s após a extração. O tarball da versão pode estar corrompido."
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="Não foi possível criar ou acessar %s, então o Ostler RemoteCapture não tem onde ser instalado. Isso é um problema de permissões de pasta, não do download."
MSG_ERR_CM042_RENAME_FAILED="O Ostler RemoteCapture foi baixado e descompactado corretamente, mas não pôde ser movido para %s. O app descompactado foi deixado em /Applications. Isso não é um problema de assinatura."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify informou:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  Recusando-se a preparar um pacote que não corresponde ao checksum publicado."
MSG_ERR_CM042_SHA_256_MISMATCH="Divergência de SHA-256 no tarball do Ostler RemoteCapture."
MSG_ERR_CM042_PIN_FAILED="O Ostler não conseguiu confirmar que este download do RemoteCapture é autêntico, então ele não foi instalado."
MSG_ERR_CM042_VERSION_UNKNOWN="Esta versão do RemoteCapture não é reconhecida pelo Ostler, então não foi instalada."
MSG_ERR_CM042_SIDECAR_DISAGREES="O checksum publicado com este download do RemoteCapture não corresponde ao arquivo, então ele não foi instalado."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess informou:"
MSG_ERR_CM042_VERIFY_FAILED="A verificação de assinatura / notarização do Ostler RemoteCapture falhou."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv informou:"
MSG_ERR_EXPECTED="  esperado: %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief informou: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="O binário ostler-assistant em %s não é um executável Mach-O."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="O SHA-256 do tarball do ostler-assistant não confere."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  Recusando-se a preparar um binário que não corresponde ao checksum publicado."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="Recusando-se a remover a quarentena ou carregar o LaunchAgent."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="Execute o instalador novamente depois que o tarball de origem for corrigido."
MSG_ERR_URL="  url:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Macs com Intel não são compatíveis. O Ostler precisa de Apple Silicon (M1, M2, M3 ou M4)."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="São necessários pelo menos 16 GB de RAM. Você tem %s GB. Recomendamos 24 GB."
MSG_FAIL_CM042_SIGNATURE_FAILED="Instalação do Ostler RemoteCapture cancelada: a verificação de assinatura ou notarização falhou. O pacote foi deixado em /Applications para o suporte. Envie um e-mail para support@ostler.ai e execute o instalador novamente."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="Não foi possível baixar %s após 3 tentativas. Verifique sua rede e execute o instalador novamente."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="Não foi possível baixar nomic-embed-text após 3 tentativas. Verifique sua rede e execute o instalador novamente."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker indisponível. Execute o instalador novamente para instalar o Colima."
MSG_FAIL_CONTAINER_CLIENT_MISSING="O comando docker não está neste Mac, então o Ostler não consegue iniciar os serviços de que precisa. Execute o instalador novamente; se falhar de novo, envie-nos o registro em %s."
MSG_FAIL_CONTAINER_ENGINE_ABSENT="O Ostler precisa de um ambiente de execução de contêineres e nenhum está respondendo neste Mac. Sua wiki, seu grafo de conhecimento e seu índice de busca rodam dentro de contêineres, por isso a instalação parou aqui, em vez de terminar e deixá-los ausentes. Para corrigir: abra o Terminal e execute 'colima start', depois execute este instalador novamente. Se você usa o Docker Desktop, abra-o, espere o ícone da baleia se estabilizar e execute de novo. O registro completo está em %s."
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="O Docker não ficou pronto a tempo de iniciar os bancos de dados do grafo de conhecimento. Verifique se o Colima ou o Docker está em execução e execute o instalador novamente."
MSG_FAIL_GRAPH_DB_PULL_FAILED="Não foi possível baixar as imagens dos bancos de dados do grafo de conhecimento após várias tentativas. Em geral é um problema de rede. Verifique sua conexão com a internet e execute o instalador novamente."
MSG_FAIL_GRAPH_DB_UP_FAILED="Os bancos de dados do grafo de conhecimento foram baixados, mas não puderam ser iniciados. Execute o instalador novamente; se continuar acontecendo, abra o Terminal e execute: cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="O Ostler não conseguiu concluir uma requisição autenticada ao banco de dados do grafo de conhecimento. Tentou duas vezes, com dois segundos de intervalo, e as duas foram recusadas. Ainda não sabemos o motivo: o banco pode ainda estar iniciando, ou a credencial que o Ostler tem pode não ser a esperada. Seus dados não foram alterados. Executar o instalador novamente muitas vezes resolve, e, se resolver, ainda assim gostaríamos de saber – envie-nos o registro da instalação, porque é uma falha que estamos tentando reproduzir."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="O módulo de extração FDA está ausente do pacote do instalador. Baixe o .app novamente em ostler.ai/install ou execute de novo com --allow-plaintext para dev/CI."
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="O módulo de extração de dados foi instalado, mas não pode ser carregado, então a atualização em segundo plano falharia toda vez que fosse executada. A saída completa foi salva em %s – execute o instalador novamente e anexe esse arquivo se entrar em contato com o suporte (Referência: ERR-10-FDA-DEPS-IMPORT)."
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="Erro interno: o módulo de extração de dados foi preparado dentro do pacote do aplicativo, o que quebraria sua assinatura. Isso é uma falha de compilação, não um problema do seu Mac. Baixe o .app novamente em ostler.ai/install (Referência: ERR-10-FDA-DEPS-UNSAFE-PATH)."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="A instalação das dependências do Doctor falhou. A saída completa foi salva em %s – anexe-a ao enviar e-mail para support@ostler.ai (Referência: ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="A instalação das dependências do pipeline de importação falhou. A saída completa foi salva em %s – anexe-a ao enviar e-mail para support@ostler.ai (Referência: ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="A instalação do Homebrew falhou. A saída completa foi salva em %s – anexe-a ao enviar e-mail para support@ostler.ai."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="A instalação do pipeline de importação falhou. O pacote contact_syncer é obrigatório na instalação do produto. Execute de novo com --allow-plaintext para dev/CI, ou baixe o instalador novamente e tente outra vez."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="É necessário acesso sudo para desativar a suspensão e instalar o Homebrew. Execute novamente quando estiver pronto."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Nem o Colima nem o Docker Desktop puderam ser iniciados. Instale o Docker Desktop e execute novamente."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="Espaço em disco insuficiente (%s GB). Libere espaço e tente novamente."
MSG_FAIL_MACOS_BELOW_FLOOR="O macOS %s é anterior ao que o Ostler suporta. O Ostler precisa do macOS %s ou posterior: o aplicativo instalador foi criado para ele e não abrirá em versões anteriores. Atualize o macOS e execute o instalador novamente."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="Nenhuma chave-senha definida e nenhuma configuração de segurança existente. Execute de novo com --allow-plaintext para dev/CI, ou execute o instalador novamente e confirme o aviso sobre o Touch ID."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="O mecanismo de memória de conversas é obrigatório. Execute de novo com --allow-plaintext para dev/CI, ou corrija o pacote ausente acima e tente novamente."
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="O daemon do Ostler incluído (v%s em %s) não oferece suporte ao comando 'run-source' de que este instalador precisa para encaminhar a ingestão pelo Acesso Total ao Disco. É uma incompatibilidade de versões dentro do pacote do instalador: instalá-lo deixaria todas as fontes de ingestão quebradas em silêncio e o produto ficaria desatualizado sem nenhum erro visível. Baixe o .app novamente em ostler.ai/install e tente outra vez (Referência: ERR-11-DAEMON-RUN-SOURCE-SKEW)."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="A instalação do ostler_security falhou. Execute de novo com --allow-plaintext para dev/CI, ou corrija o erro do pip acima e tente novamente."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="A configuração da chave-senha falhou. Execute de novo com --allow-plaintext para dev/CI, ou corrija o erro acima e tente novamente."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="O sqlcipher3 é obrigatório para bancos de dados criptografados. Execute de novo com --allow-plaintext para dev/CI, ou corrija o erro do pip acima e tente novamente."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="Este instalador é apenas para macOS."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="A instalação das Xcode Command Line Tools não foi concluída em 15 minutos. Abra o Terminal e execute 'xcode-select --install', clique em Instalar na caixa de diálogo do macOS e aguarde o término. Depois, execute este instalador novamente."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="A instalação do Homebrew informou sucesso, mas /opt/homebrew/bin/brew não foi encontrado. Consulte %s para ver o registro completo. Recuperação: abra o Terminal e execute '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' e depois execute o instalador novamente."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="O Homebrew está instalado em /opt/homebrew/bin/brew, mas o comando 'brew' não está no PATH após a avaliação do shellenv. Abra um novo Terminal e execute o instalador novamente."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' informou sucesso, mas o colima não está no PATH. Consulte %s para ver as falhas do Homebrew. Recuperação: abra o Terminal e execute 'brew install colima docker docker-compose' manualmente, depois execute o instalador novamente."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' informou sucesso, mas a CLI do docker não está no PATH. Consulte %s. Recuperação: execute 'brew install docker' manualmente e depois execute o instalador novamente."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="The Ollama install reported success but its binary is missing. Check %s, then re-run the installer."
MSG_FAIL_OLLAMA_PIN_DOWNLOAD="Could not download Ollama %s. Check your internet connection, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_PIN_SHA256="The Ollama %s download did not match its recorded fingerprint, so it was not installed. This can mean the download was damaged or altered. Re-run the installer; if it happens again, contact support. Details: %s"
MSG_FAIL_OLLAMA_PIN_UNPACK="Ollama %s downloaded but could not be unpacked. Check free disk space, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_AGENT_NOT_PINNED="The local AI service is set to run %s instead of the copy of Ollama this installer verified (%s), so it would not stay on a tested version. The install has stopped. Re-run the installer; if this repeats, contact support. Details: %s"
MSG_FAIL_EMBED_HEALTHCHECK="O Ollama está em execução, mas o modelo de embedding não retornou nenhum vetor (HTTP diferente de 200 ou resultado vazio). O cartão Pessoas, a busca e a navegação ficariam vazios. Consulte %s. Recuperação: verifique se o app Ollama (não a fórmula do Homebrew) está instalado e em execução, depois execute o instalador novamente."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' informou sucesso, mas o sqlcipher não está no PATH. Consulte %s. Recuperação: execute 'brew install sqlcipher' manualmente e depois execute o instalador novamente."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' não gerou /Applications/Tailscale.app. Consulte %s. Recuperação: baixe o Tailscale em https://tailscale.com/download/macos e arraste-o para /Applications. Depois, execute o instalador novamente."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' informou sucesso, mas o binário python3.11 não foi encontrado em /opt/homebrew/opt/python@3.11/bin/python3.11. Consulte %s. Recuperação: execute 'brew reinstall python@3.11' e depois execute o instalador novamente."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="Encontramos suas respostas anteriores"
MSG_PROMPT_REUSE_SETTINGS_HELP="Detectamos uma tentativa de instalação anterior neste Mac. As perguntas que você já respondeu (nome, nome do assistente, fuso horário, código do país, canais e assim por diante) serão reaproveitadas para que você não precise digitá-las de novo. Escolha Sim para continuar de onde parou ou Não para repassar as perguntas desde o início."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="Respostas anteriores encontradas: nome = %s, assistente = %s, fuso horário = %s."

MSG_PROMPT_PERMS_OK_TITLE="Pronto para continuar?"
MSG_PROMPT_PERMS_OK_HELP="O macOS vai solicitar acesso a Contatos e a Arquivos e Pastas. O Acesso Total ao Disco, opcional, pode ser concedido depois."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="Nome completo (como aparece nos seus contatos)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="Nome completo (ex.: Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="Como seu assistente deve chamar você?"
MSG_PROMPT_USER_ID_HELP="Um nome curto que seu assistente usará para se dirigir a você (ex.: 'Andy', 'Andrew', 'Sra. Smith'). É o que aparece nos seus resumos da manhã e nas respostas do chat. Diferente do seu nome completo acima."

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
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="Estes são seus calendários. Estão corretos?"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="Deduzimos de quem é cada um, para que seu resumo nunca confunda de quem é cada viagem."
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="Separados automaticamente, não usados no seu resumo:"
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="seu"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="%s evento"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="%s eventos"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="feriados"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="aniversários"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="sugestões da Siri"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="um calendário que você assina"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="lembretes"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="Usar \"%s\" no seu resumo?"
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="Separamos este porque parece ser %s. Responda sim se for mesmo a agenda de alguém."
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="De quem é o calendário \"%s\"?"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="Que tipo de calendário é \"%s\"?"
# NEEDS REVIEW: Option words may be typed input compared against English values; a developer must confirm whether they must stay in English. Also smoothed second sentence.
MSG_CONFIRM_CALENDAR_TYPE_HELP="Um destes: pessoal, trabalho, família, compartilhado, outro. Isso define o nível de sensibilidade com que os eventos são tratados."
MSG_CONFIRM_CALENDARS_SAVED="Os donos dos seus calendários foram salvos"
MSG_CONFIRM_CALENDARS_FAILED="Não foi possível salvar os donos dos calendários (não fatal; você pode definir isso depois)"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="Achamos que todos estes perfis são você (%s). Combiná-los em um só?"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="Estes perfis têm um sinal de identidade forte em comum com você (um domínio de e-mail, um perfil do LinkedIn ou um empregador). Combiná-los evita que seu assistente trate seu próprio histórico como várias pessoas diferentes. Você pode desfazer isso depois."
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="Alguém com o mesmo nome que você parece ser outra pessoa (%s). É você ou é outra pessoa?"
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="Escolha \"outra pessoa\" para mantê-la como uma pessoa separada (seu assistente nunca vai mesclá-la com você). Escolha \"eu\" só se realmente for você."
MSG_CONFIRM_IDENTITY_SAVED="Identidade salva"
MSG_CONFIRM_IDENTITY_FAILED="Não foi possível salvar as escolhas de identidade (não é grave; você pode confirmar depois)"

# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="Instalando em segundo plano (de cerca de 45 minutos a algumas horas)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="Usar +%s?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="Digite o código do país (por ex., 44 para o Reino Unido, 1 para os EUA)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="Código de país padrão"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="Usado para normalizar números de telefone na importação de contatos e para definir sua região (Reino Unido / UE / EUA / outra) nos padrões de conformidade legal."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="Detectamos +%s. Usar este código para o seu Hub?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="Detectado a partir do seu número de telefone acima. Escolha Sim para usá-lo ou Não para digitar outro código de país."

MSG_PROMPT_TZ_CONFIRM_TITLE="Usar este fuso horário?"
MSG_PROMPT_TZ_CONFIRM_HELP="Fuso horário detectado: %s"
MSG_PROMPT_USER_TZ_TITLE="Digite o fuso horário (por ex., Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="Como você gostaria de chamar seu assistente?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="O nome no campo é uma sugestão aleatória: escreva por cima o que quiser. Marvin, Samantha, Joshua, Friday, Athena, Sage e Rosie são escolhas populares." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="Digite o nome que quiser: a sugestão é só um ponto de partida."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="Como seu assistente vai entrar em contato com você?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="Escolha os canais de mensagem que você quer que seu assistente use. Você pode mudar isso depois na seção Doctor do app."

MSG_PROMPT_WHATSAPP_CONSENT_TITLE="Enable WhatsApp messaging for your assistant?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web is a third-party service. By enabling, you accept that your messages route through WhatsApp's own infrastructure before reaching your local Ostler instance, and that WhatsApp (Meta Platforms Ireland Ltd) may suspend, restrict, or terminate your WhatsApp account because of automated use. You can disable this later from Settings."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="Seu número de telefone do WhatsApp"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="Número internacional com o código do país, por ex. +447700900123. Apenas dígitos e um + no início, sem espaços, parênteses ou hifens."
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="Salvo como %s. O WhatsApp precisa do número sem espaços nem parênteses."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Ative o Acesso Total ao Disco para o assistente Ostler"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="Os Ajustes do Sistema estão abertos em Acesso Total ao Disco."
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
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="Encontre \"%s\" na lista e ative o interruptor de Acesso Total ao Disco dele."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="Não está na lista? Arraste \"%s\" da janela do Finder para a lista e ative o interruptor. A ordem não importa: clique em Concluído antes ou depois; o instalador espera até o interruptor estar realmente ativado."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="Não está na lista? O Ostler não conseguiu abrir uma janela do Finder para você. No Finder, pressione ⌘⇧G, digite o caminho abaixo, depois arraste \"%s\" para a lista e ative o interruptor. A ordem não importa: clique em Concluído antes ou depois; o instalador espera até o interruptor estar realmente ativado."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="O app está em: %s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="O app está em: %s – este caminho está na sua área de transferência; no Finder, pressione ⌘⇧G, depois ⌘V e então Return."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="Concluído"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="Você pode clicar em Concluído antes ou depois de ativar o interruptor: o instalador espera até ele estar realmente ativado."

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Permitir que o Ostler leia os dados do seu Mac"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="Os Ajustes do Sistema estão abertos em Acesso Total ao Disco."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="Encontre \"OstlerInstaller\" na lista e ative-o."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="Clique em Concluído quando terminar, e o Ostler vai ler seu histórico do Safari, Notas, iMessages e Mail."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="Concluído"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="A seguir: Acesso Total ao Disco para o instalador"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="Em seguida, o macOS vai pedir que você conceda Acesso Total ao Disco ao OstlerInstaller."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="Depois que você ativar a chave, o macOS vai exibir uma caixa de diálogo pedindo que você escolha \"Encerrar e Reabrir\" ou \"Mais Tarde\"."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="Clique em Encerrar e Reabrir. O instalador será reaberto e continuará a partir desta etapa automaticamente."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="OK"
MSG_INFO_INSTALLER_FDA_PREWARN="Explicando como conceder o Acesso Total ao Disco..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="Abrindo os Ajustes do Sistema para você conceder o Acesso Total ao Disco ao instalador..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="Acesso Total ao Disco concedido ao instalador. Em seguida, lendo Safari, Notas, iMessages e Mail."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="O Acesso Total ao Disco ainda não foi concedido. Continuando sem ele; você pode executar o instalador de novo mais tarde para extrair Safari / Notas / iMessages."
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="O Acesso Total ao Disco para o instalador está resolvido. A parte longa começa agora e quase sempre roda sozinha – mas fique atento a uma caixa de diálogo do macOS pedindo para instalar as ferramentas de desenvolvedor, e volte para alguns minutos de configuração perto do fim."
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="Mais uma permissão (histórico do Mensagens para o seu assistente) aparece perto do fim, depois que o seu assistente estiver instalado – nós vamos indicar o caminho naquele momento."
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="Acesso Total ao Disco ainda necessário"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="O Ostler está prestes a ler os dados do seu Mac, mas o Acesso Total ao Disco para o OstlerInstaller ainda está desativado. Encontre \"OstlerInstaller\" na lista e ative-o."
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="Ou clique em Continuar para concluir a instalação com menos dados – você pode conceder a permissão e executar o extrator de novo mais tarde."
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="Continuar"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="Contatos permitidos"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="Pessoas de confiança: números de telefone e e-mails de ID Apple (separados por vírgula). %s só responde a pessoas desta lista; mensagens de qualquer outra pessoa são ignoradas. É necessária pelo menos uma entrada.

Por exemplo:
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="Ler e-mails pelo Apple Mail?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Lê qualquer conta de e-mail que você adicionou ao Apple Mail (iCloud, Gmail, Outlook etc.) usando o Acesso Total ao Disco. Nenhuma senha é armazenada. Recomendado para quase todas as pessoas."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="Adicionar uma conta de e-mail ao Apple Mail?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="O Apple Mail ainda não tem contas conectadas neste Mac, então o Ostler não terá e-mails para ler. Escolha Sim para abrir agora Ajustes do Sistema > Contas de Internet (lá você pode adicionar iCloud, Gmail ou Outlook). Escolha Não para pular; você pode adicionar uma conta depois, e o Doctor vai mostrar um aviso de acompanhamento se nenhum e-mail chegar em 24 horas."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="Importar todo o seu histórico do Apple Mail?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Por padrão, o Ostler lê os últimos cinco anos do seu Apple Mail. Se você guarda mais do que isso neste Mac e quer tudo no seu grafo de conhecimento, escolha Sim para importar agora todo o histórico local (pode demorar um pouco mais em caixas de correio grandes). Escolha Não para manter a janela de cinco anos; você sempre pode ampliá-la depois pelo Doctor."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="Configurar também um servidor IMAP+SMTP personalizado?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="Somente para caixas de correio auto-hospedadas. Mantenha NÃO se suas contas forem do Gmail, iCloud ou Outlook – essas funcionam melhor pelo Apple Mail, acima."

MSG_PROMPT_IMAP_HOST_TITLE="Host IMAP"
MSG_PROMPT_IMAP_HOST_HELP="Somente para servidor IMAP auto-hospedado ou personalizado. Use o Apple Mail (acima) para Gmail / iCloud / Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="Porta IMAP"

MSG_PROMPT_SMTP_HOST_TITLE="Host SMTP"
MSG_PROMPT_SMTP_PORT_TITLE="Porta SMTP"

MSG_PROMPT_EMAIL_USERNAME_TITLE="Endereço de e-mail (também usado como usuário IMAP/SMTP)"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="Quem pode enviar e-mails ao seu assistente?"
MSG_PROMPT_EMAIL_ALLOWED_HELP="Seus próprios endereços de e-mail, separados por vírgula. %s só responde a e-mails de endereços desta lista; e-mails de qualquer outra pessoa são ignorados. É necessário pelo menos um endereço. Seu próprio endereço já vem preenchido: altere-o ou adicione outro."

MSG_PROMPT_EMAIL_PASSWORD_TITLE="Senha (oculta)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Password for your self-hosted IMAP/SMTP server. Stored locally in ~/.ostler/secrets/, not in your settings file, and never sent to Creative Machines. It is saved in plain text: the only thing protecting it is the file's permissions, which allow your macOS account and nobody else. Nothing encrypts it later. Use an app password rather than your main account password."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="Confirmar senha"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="Qual pasta o assistente deve observar?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="Recomendado: um marcador ou pasta dedicada (por exemplo, Ostler). Vamos ler apenas as mensagens que estiverem lá, sem tocar na sua caixa de entrada principal."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="Digite INBOX novamente para confirmar ou pressione Continuar para usar \"Ostler\""
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX significa que o assistente vai ler todos os e-mails que você receber. Recomendamos fortemente usar um marcador/pasta dedicado."

MSG_PROMPT_EXPORTS_ACK_TITLE="Você já solicitou a exportação dos seus dados?"
MSG_PROMPT_EXPORTS_ACK_HELP="O Ostler importa dados de cerca de 20 plataformas. A lista completa, com links diretos para a página de solicitação de cada provedor, está em docs.ostler.ai/data-exports.

A maioria dos arquivos leva de 1 a 3 dias para chegar por e-mail. Quando os ZIPs chegarem, coloque-os na pasta Downloads e o Ostler os encontrará automaticamente.

Pule os que você não usa; você sempre pode importar mais depois."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="Continuar com o disco SEM criptografia em repouso?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="O FileVault está DESATIVADO neste Mac, então seu disco não está criptografado em repouso.

O que isso significa se você continuar: tudo o que o Ostler armazena – todo o seu grafo pessoal (wiki, conversas, notas de conhecimento) em ~/Documents/Ostler, além de segredos de serviços e bancos de dados em ~/.ostler – é gravado no disco SEM criptografia. Qualquer pessoa que consiga iniciar o Mac a partir desse disco, removê-lo ou acessar uma sessão desbloqueada pode ler tudo isso. O Ostler criptografa seus bancos de dados mais sensíveis com uma senha de qualquer forma, mas o restante dos seus dados fica protegido apenas até onde o próprio disco estiver.

O FileVault é fortemente recomendado. Você pode ativá-lo a qualquer momento em Ajustes do Sistema > Privacidade e Segurança > FileVault – ele criptografa em segundo plano, sem precisar reinstalar.

Escolha Sim para continuar agora com o disco sem criptografia em repouso (é uma escolha deliberada e informada, e ela será registrada).
Escolha Não para parar aqui, ativar o FileVault primeiro e depois executar o instalador novamente. Nada deu errado em nenhum dos casos."

MSG_PROMPT_PASSKEY_ACK_TITLE="Pronto para configurar a criptografia do disco"
MSG_PROMPT_PASSKEY_ACK_HELP="Os bancos de dados sensíveis do Ostler são criptografados com SQLCipher usando uma senha que você escolhe na próxima tela. Você vai digitar essa senha sempre que iniciar a interface do Hub. Uma chave de recuperação separada também é gerada e exibida uma única vez, no final da instalação. Para proteger em repouso tudo o que está no seu Mac, mantenha o FileVault do macOS ativado. Clique em Continuar quando estiver pronto."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="Definir também uma senha de recuperação? (recomendado)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="Escolha sua senha"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="Esta senha criptografa seu grafo de conhecimento e desbloqueia a interface do Hub a cada inicialização. Mínimo de 12 caracteres. Não podemos recuperá-la para você. Recomendamos guardá-la em um gerenciador de senhas."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="Confirme sua senha"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="Digite a mesma senha novamente para confirmar."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="Importar estes itens durante a instalação?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="As exportações do GDPR encontradas serão importadas para o seu grafo de conhecimento durante a instalação."

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="Senha da exportação do Disney+"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="O Disney+ entrega a exportação do GDPR como uma planilha protegida por senha, o que é normal e não indica problema com o seu download. Digite a senha para importar agora seu histórico de exibição do Disney+ ou deixe em branco para pular; todo o resto continua sendo importado."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="Você já tem exportações de dados prontas?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="O Ostler pode importar arquivos de redes sociais e plataformas – todo o seu histórico com amigos, família, lugares, opiniões – logo no início. Quanto mais o Ostler souber no primeiro dia, mais útil ele será no primeiro dia. Você também pode adicionar isso depois; sem pressa.

Solicite a exportação dos seus dados em cada plataforma (Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp etc.), baixe os arquivos ZIP e coloque-os na pasta Downloads.

O Ostler procura em ~/Downloads por padrão. Prefere outra pasta? Escolha uma abaixo. Caso contrário, pule e importe depois."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="Importar mensagens do Gmail deste Takeout?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Lê o conteúdo do Gmail diretamente do arquivo do Takeout. O Google nunca vê o Ostler."

MSG_PROMPT_FDA_PRESET_TITLE="De quais fontes do Mac o Ostler deve aprender?"
MSG_PROMPT_FDA_PRESET_HELP="Três predefinições, ou escolha cada fonte você mesmo. Fontes sensíveis (reconhecimento facial) ficam desativadas por padrão em todas as predefinições – escolha com cuidado se quiser ativá-las."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="Recomendado. Inclui Apple Mail, Contatos, Calendário, Notas, Mensagens, Lembretes, histórico do Safari, favoritos do Safari e eventos de Fotos (datas e lugares, sem reconhecimento facial). O histórico do WhatsApp Desktop e o do Chrome são adicionados automaticamente quando o app está instalado. Exclui os dados de reconhecimento facial de Fotos e quaisquer arquivos de exportação de terceiros."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="Tudo. Todas as fontes que o Ostler consegue ler neste Mac. O reconhecimento facial de Fotos permanece desativado até você marcá-lo deliberadamente."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="Personalizar. Escolha cada fonte na próxima tela. As fontes sensíveis permanecem desativadas até você marcá-las."

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
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="A transcrição de voz continuará desativada. Você pode ativá-la depois em Ajustes."

MSG_PROMPT_CONSENT_INSTALL_TITLE="Ready to install?"
MSG_PROMPT_CONSENT_INSTALL_HELP="Please type INSTALL to confirm you accept the terms."
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Type INSTALL"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Install Ostler"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Cancel"
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Type INSTALL exactly (case does not matter) to confirm, or click Cancel to go back."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="Conecte seu iPhone e seu Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="O Tailscale dá a este Mac um endereço privado estável que seu iPhone e seu Watch alcançam de qualquer lugar, com criptografia e sem exposição pública."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="Salvar a chave de recuperação nas Chaves?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="Guarda sua chave de recuperação de criptografia nas Chaves do macOS, em segurança."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="Preenchendo seu grafo"
MSG_HYDRATE_CONTACTS_STARTED="Importando seus contatos para o grafo"
MSG_HYDRATE_CONTACTS_DONE="%s contatos importados"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="Os contatos levaram mais de %ss, então paramos de esperar e seguimos em frente. Até agora, %s contatos foram importados, e o Ostler vai concluir o restante em segundo plano."
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="Carregando o histórico da sua agenda (cinco anos para trás, um ano para a frente)"
MSG_HYDRATE_CALENDAR_DONE="%s eventos importados"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  Ainda carregando seu calendário (%ss até agora). Um Mac com anos de reuniões leva um momento."
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="Criando seus Lugares a partir dos locais onde você tem compromissos"
MSG_HYDRATE_PLACES_DONE="Seção Lugares criada"
MSG_HYDRATE_PLACES_SKIPPED="Nenhum sinal de localização encontrado ainda; os Lugares serão preenchidos conforme seu calendário for sendo carregado"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="A criação dos Lugares encontrou um problema: há sinais de localização, mas nenhum Lugar foi gerado. Sua página de Lugares pode ficar vazia. Veja %s"
MSG_HYDRATE_PLACES_ERROR_WARN="A criação dos Lugares não foi concluída (erro inesperado). Sua página de Lugares pode ficar incompleta. Veja %s"
MSG_HYDRATE_WIKI_RECOMPILE="Criando sua wiki. O Ostler está escrevendo um breve resumo para cada uma das suas pessoas, organizações e tópicos principais, então, com uma lista de contatos grande, isso pode levar de alguns minutos a cerca de uma hora. Isso acontece só uma vez, roda inteiramente no seu Mac e você pode deixar em andamento."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="Verificando seu índice de busca (%s coleções detectadas)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="Carregando seu histórico de navegação no índice de busca"
MSG_INITIAL_HYDRATE_QDRANT_READY="Índice de busca pronto (%s coleções)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="O índice de busca será preenchido em segundo plano depois que a instalação terminar"
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
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="O armazenamento de busca já está ativo; criando as coleções que ainda faltam: %s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="O índice de busca está incompleto: não foi possível criar %s, embora o armazenamento de busca esteja em execução e respondendo. O Ostler continuará funcionando e o Doctor mostra essa lacuna, mas essa parte da busca ficará vazia até que seja corrigida."
MSG_WARN_QDRANT_COLLECTIONS_MISSING="O índice de busca está incompleto: não foi possível criar %s. O Ostler continuará funcionando, e o Doctor mostra essa lacuna."
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="Não foi possível verificar quais coleções de busca existem (%s). Isso não indica que elas estejam ausentes."
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="O índice de busca será preenchido em segundo plano depois que a instalação terminar (aguardando: %s)"
MSG_HYDRATE_DONE="Seu grafo está pronto: %s pessoas, %s eventos"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="O iCloud ainda pode estar sincronizando seus contatos – exportando novamente agora para incluir o que acabou de chegar."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="Nenhum contato encontrado no app Contatos (local ou iCloud). Adicione alguns em Contatos e execute novamente em Configurações."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="Nenhum contato do iCloud para importar. Você pode adicionar isso depois em Configurações."
MSG_HYDRATE_SKIPPED_NO_EVENTS="Nenhum evento de calendário nos últimos 5 anos. Você pode importar depois em Configurações."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="Lendo seus últimos 90 dias de e-mail – seus e-mails ficam neste Mac (o histórico mais antigo é carregado em segundo plano)"
MSG_HYDRATE_EMAIL_DONE="%s pessoas encontradas nos seus e-mails recentes"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="Nenhum e-mail recente para ler. Você pode adicionar uma conta de e-mail no Apple Mail e executar novamente depois."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="O leitor de e-mail ainda não está pronto. Você pode adicionar uma conta de e-mail no Apple Mail e executar novamente depois."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="O e-mail ainda está sendo carregado em segundo plano. Sua wiki é preenchida aos poucos e mostra até onde chegou."
MSG_HYDRATE_EMAIL_HEARTBEAT="  Ainda lendo seus e-mails (%ss até agora). Isso pode demorar em um Mac com anos de histórico."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="Abrir o Apple Mail para iniciar a sincronização?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="Você tem %s conta(s) de e-mail configurada(s), mas o Apple Mail ainda não baixou nenhuma mensagem. Podemos abrir o Mail agora e aguardar a sincronização."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="Abrir o Calendário para iniciar a sincronização?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="Você tem %s conta(s) de calendário configurada(s), mas o Calendário ainda não tem eventos armazenados. Podemos abrir o Calendário agora e aguardar a sincronização com o iCloud."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="Abrir o Contatos para iniciar a sincronização?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="Você tem %s conta(s) de contatos configurada(s), mas o Contatos ainda não tem entradas armazenadas. Podemos abrir o Contatos agora e aguardar a sincronização com o iCloud."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="Aguardando %s iniciar a sincronização (até %s segundos)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="Ainda aguardando a sincronização de %s (%ss decorridos, %ss restantes). A primeira sincronização do iCloud pode levar alguns minutos em um login recente."
MSG_OK_APP_HAS_POPULATED="%s preencheu seu armazenamento local. Continuando."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="Não detectamos a sincronização de %s dentro do tempo de espera. Continuando; você pode executar a importação novamente depois em Configurações."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="Contas do Apple Mail visíveis: %s. Abra o Mail uma vez para que ele comece a baixar mensagens."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="Contas do Calendário visíveis: %s. Abra o Calendário uma vez para que ele sincronize seus eventos."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="Contas de contatos visíveis: %s. Abra o Contatos uma vez para que ele sincronize seus contatos."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="Não foi possível ler seus Contatos. O Ostler os lê por meio do Acesso Total ao Disco: conceda-o em Ajustes do Sistema > Privacidade e Segurança > Acesso Total ao Disco e, depois, execute a hidratação novamente em Ajustes. Vamos continuar tentando em segundo plano."
MSG_HYDRATE_CONTACTS_PENDING="O app Contatos ainda não sincronizou. Abra o Contatos uma vez, aguarde a sincronização e execute a hidratação novamente em Ajustes."
MSG_HYDRATE_CONTACTS_READ_FAILED="Seus contatos estão neste Mac, mas o Ostler importou 0 deles, o que é inesperado. A importação será tentada novamente em segundo plano. Se o problema persistir, execute a hidratação novamente em Ajustes ou consulte o log de instalação."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="O Ostler continuará verificando em segundo plano e importará seus contatos automaticamente quando o iCloud terminar de sincronizar."
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="Foram importados %s contatos com números de telefone, mas quase nenhum endereço de e-mail (%s com telefone e %s com e-mail). Isso geralmente significa que o leitor de contatos descartou os e-mails. Seus contatos continuam utilizáveis; consulte %s e execute a hidratação novamente em Ajustes depois de resolver."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="Novos contatos importados; reconstruindo sua wiki em segundo plano."
MSG_HYDRATE_CALENDAR_PENDING="O app Calendário ainda não sincronizou os eventos. Abra o Calendário uma vez, aguarde a sincronização e execute a hidratação novamente em Ajustes."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="Não foi possível ler seu calendário desta vez (o extrator relatou um erro, não um calendário vazio). Seus outros dados não foram afetados; consulte %s e execute a hidratação novamente em Ajustes."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="Lendo seu histórico do WhatsApp – suas mensagens permanecem neste Mac"
MSG_HYDRATE_WHATSAPP_DONE="Encontradas %s pessoas nas suas conversas do WhatsApp"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="As conversas do WhatsApp foram lidas, mas não gravadas no seu grafo de pessoas (código %s). O Ostler tentará novamente. Detalhes: %s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="Nenhuma conversa do WhatsApp para ler. Você pode executar novamente depois em Ajustes."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="O WhatsApp Desktop não está instalado. Instale-o pela Mac App Store e execute novamente em Ajustes."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="O leitor do WhatsApp ainda não está pronto. Você pode executar novamente depois em Ajustes."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="O WhatsApp ainda está sendo carregado em segundo plano. Sua wiki vai sendo preenchida aos poucos e mostra até onde chegou."

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
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="Seus contatos do WhatsApp já estão no seu grafo de pessoas (%s identificadores). Não há nada para ler novamente."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="Seus contatos do WhatsApp já foram lidos antes, mas seu grafo de pessoas não os contém mais. Lendo novamente."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="Não foi possível verificar se seus contatos do WhatsApp ainda estão no seu grafo de pessoas. Lendo novamente, em vez de presumir que estão lá."

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="Lendo seu histórico de conversas com IA – suas conversas permanecem neste Mac"
MSG_HYDRATE_AICONV_DONE="%s conversas com IA salvas na sua wiki"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="O leitor de conversas com IA ainda não está pronto. Você pode executar novamente depois em Ajustes."
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="Nenhum histórico de conversas com IA para ler. Você pode executar novamente depois em Ajustes."
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="As conversas com IA ainda estão sendo carregadas em segundo plano. Sua wiki vai sendo preenchida aos poucos e mostra até onde chegou."
MSG_HYDRATE_AICONV_HEARTBEAT="  Ainda lendo seu histórico de conversas com IA (%ss até agora). Um histórico grande pode levar vários minutos."


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="Importando seu histórico de navegação – suas visitas permanecem neste Mac"
MSG_HYDRATE_BROWSING_DONE="%s páginas do histórico de navegação importadas"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="%s páginas marcadas como sensíveis foram ignoradas (bancos, saúde etc.)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="Nenhum histórico de navegação para importar. Você pode executar novamente depois em Ajustes."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="O leitor do histórico de navegação ainda não está pronto. Você pode executar novamente depois em Ajustes."

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
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="Seu histórico de navegação já foi importado (%s páginas). Não há nada para importar novamente."
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="Nenhum histórico de navegação exportado foi encontrado para importar. Você pode executar novamente depois em Ajustes."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="Seu histórico de navegação foi importado antes, mas seu índice de busca não o contém mais. Importando novamente."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="Não foi possível verificar se seu histórico de navegação ainda está no seu índice de busca. Importando novamente, em vez de presumir que está lá."
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="Seu histórico de navegação não chegou ao seu índice de busca, então sua página Navegação ficará vazia. Execute novamente em Ajustes ou abra o Doctor."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="O histórico de navegação ainda está sendo carregado em segundo plano. Sua wiki vai sendo preenchida aos poucos e mostra até onde chegou."

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="Carregando suas preferências de e-mail. Isso permanece neste Mac e pode levar alguns minutos."
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="%s preferências carregadas do seu histórico de e-mail"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="Nenhum arquivo de preferências de e-mail configurado. Nada para carregar."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="Nenhum arquivo de preferências de e-mail encontrado em %s. Nada para carregar."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="O pipeline de preferências ainda não está pronto. Você pode executar novamente depois em Ajustes."
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="As preferências de e-mail ainda estão sendo carregadas em segundo plano. Seu wiki vai se preenchendo aos poucos e mostra em que ponto está."
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  Ainda carregando suas preferências de e-mail (%ss até agora). Um histórico grande pode levar alguns minutos."

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="Suas preferências de e-mail já foram carregadas (%s entradas). Nada a recarregar."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="Suas preferências de e-mail foram carregadas antes, mas seu índice de busca não as contém mais. Carregando de novo."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="Não foi possível verificar se suas preferências de e-mail ainda estão no seu índice de busca. Carregando de novo, em vez de presumir que estão lá."

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
MSG_HYDRATE_PREFERENCES_ENRICHED="%s delas foram enriquecidas com dados de referência públicos"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="%s preferências importadas, mas nenhuma entrou em Comida, Música ou Profissional. Suas páginas de Comida e Música no wiki ficarão vazias."
MSG_WARN_PREFS_HEADLINE_HINT="Isso geralmente significa que não havia nenhuma exportação de música ou comida (Spotify, Apple Music, Uber Eats, Google Takeout) ou que os dados não foram categorizados. Adicione essas exportações, execute de novo em Ajustes e depois reconstrua o wiki."
MSG_WARN_PREFS_UNCATEGORISED="%s de %s preferências (%s%%) não têm categoria e não aparecerão em nenhuma página de tópico. Verifique o formato da exportação de origem."

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="Configurando o enriquecimento de preferências"
MSG_CM019_SETUP_DONE="Enriquecimento de preferências pronto"
MSG_CM019_SETUP_FAILED="A configuração do enriquecimento de preferências não foi concluída. Suas páginas de preferências serão preenchidas quando isso for corrigido; o restante do Ostler não é afetado."
MSG_CM019_SETUP_SKIPPED="O pipeline de enriquecimento de preferências não está incluído; ignorando por enquanto."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="Lendo seu histórico do iMessage – suas mensagens ficam neste Mac"
MSG_HYDRATE_IMESSAGE_DONE="%s pessoas encontradas no seu histórico do iMessage"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="Nenhum histórico do iMessage para ler. Você pode executar de novo depois em Ajustes."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="O leitor do iMessage ainda não está pronto. Você pode executar de novo depois em Ajustes."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="O iMessage ainda está sendo carregado em segundo plano. Seu wiki vai se preenchendo aos poucos e mostra em que ponto está."
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  Ainda lendo seu histórico do iMessage (%ss até agora). Um histórico grande de mensagens pode levar vários minutos."

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="Seus contatos do iMessage já estão no seu grafo de pessoas (%s identificadores). Nada a ler de novo."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="Seus contatos do iMessage foram lidos antes, mas seu grafo de pessoas não os contém mais. Lendo de novo."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="Não foi possível verificar se seus contatos do iMessage ainda estão no seu grafo de pessoas. Lendo de novo, em vez de presumir que estão lá."

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="Lendo suas notas do app Notas - elas ficam neste Mac"
MSG_HYDRATE_APPLE_NOTES_DONE="%s notas adicionadas à sua base de conhecimento"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="Nenhuma nota do app Notas para ler. Você pode executar de novo depois em Ajustes."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="Suas notas do app Notas já estão na sua base de conhecimento. Ignorando."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="As notas do app Notas estão desativadas na busca de conhecimento. Você pode ativá-las em Ajustes."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="O importador de conhecimento ainda não está pronto. Você pode executar de novo depois em Ajustes."
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="As notas do app Notas ainda estão sendo carregadas em segundo plano. Sua base de conhecimento vai se preenchendo aos poucos e mostra em que ponto está."
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  Ainda lendo suas notas do app Notas (%ss até agora). Uma biblioteca grande de notas pode levar alguns minutos."

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="Suas notas do app Notas já estão na sua base de conhecimento (%s entradas). Nada a ler de novo."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="Suas notas do app Notas foram adicionadas antes, mas sua base de conhecimento não as contém mais. Adicionando de novo."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="Não foi possível verificar se suas notas do app Notas ainda estão na sua base de conhecimento. Adicionando de novo, em vez de presumir que estão lá."

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="Lendo seus Lembretes - eles ficam neste Mac"
MSG_HYDRATE_REMINDERS_DONE="%s lembretes adicionados à sua base de conhecimento"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="Nenhum lembrete para ler em Lembretes. Você pode executar de novo depois em Ajustes."
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="Seus Lembretes já estão na sua base de conhecimento. Ignorando."
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="Os Lembretes estão desativados na busca de conhecimento. Você pode ativá-los em Ajustes."
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="O importador de conhecimento ainda não está pronto. Você pode executar de novo depois em Ajustes."
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="Os Lembretes ainda estão sendo carregados em segundo plano. Sua base de conhecimento vai sendo preenchida aos poucos e mostra em que ponto está."
MSG_HYDRATE_REMINDERS_HEARTBEAT="  Ainda lendo seus Lembretes (%ss até agora). Uma lista grande de lembretes pode levar alguns minutos."

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="Seus Lembretes já estão na sua base de conhecimento (%s itens). Não há nada para ler de novo."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="Seus Lembretes foram adicionados antes, mas sua base de conhecimento não os contém mais. Adicionando de novo."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="Não foi possível verificar se seus Lembretes ainda estão na sua base de conhecimento. Adicionando de novo em vez de presumir que estão lá."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="Indexando suas pessoas para a busca"
MSG_HYDRATE_PEOPLE_DONE="%s pessoas indexadas para a busca"
MSG_HYDRATE_PEOPLE_PARTIAL="%s de %s pessoas indexadas para a busca até agora. As demais ainda não estavam disponíveis para busca; o Ostler tentará de novo automaticamente."
MSG_HYDRATE_PEOPLE_FAILED="Não foi possível indexar suas pessoas para a busca desta vez (o armazenamento do grafo não respondeu). O Ostler tentará de novo automaticamente. Detalhes: %s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="Ainda não há pessoas para indexar. Você pode executar de novo mais tarde em Ajustes."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="O indexador de pessoas ainda não está pronto. Você pode executar de novo mais tarde em Ajustes."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="Suas pessoas ainda estão sendo indexadas em segundo plano. A busca vai sendo preenchida aos poucos, e a wiki mostra em que ponto está."

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="Suas pessoas já estão indexadas para a busca (%s pessoas). Não há nada para reindexar."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="Suas pessoas foram indexadas antes, mas seu índice de busca não as contém mais. Indexando de novo."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="Não foi possível verificar se suas pessoas ainda estão no seu índice de busca. Indexando de novo em vez de presumir que estão lá."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="Três pedidos de acesso a pastas a seguir"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="A caixa de diálogo das Ferramentas de Linha de Comando apareceu na frente desta janela – clique em Instalar nela e volte aqui (ou aguarde alguns segundos, traremos esta janela de volta para a frente). As ferramentas são baixadas em segundo plano enquanto você continua respondendo às perguntas abaixo; nada aqui fica bloqueado."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="Permissão necessária: Automação do iMessage"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="O Ostler vai agora pedir permissão ao macOS para se comunicar com o app Mensagens. O macOS mostrará um aviso dizendo \"OstlerInstaller quer acesso para controlar o Mensagens\" – clique em Permitir para que o assistente possa enviar e receber iMessages em seu nome. Sem essa permissão, as mensagens do iMessage nunca sairão do computador, sem nenhum aviso. Essa permissão é concedida uma única vez; você pode alterá-la depois em Ajustes do Sistema > Privacidade e Segurança > Automação."

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="Sua chave de recuperação"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="Anote esta chave ou imprima agora. Ela é a única forma de voltar a entrar se você perder sua frase secreta E o Acesso às Chaves ficar inacessível. O Ostler não consegue recuperá-la para você – a chave nunca sai deste Mac e não é armazenada em nenhum servidor."
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="Guardei em um lugar seguro"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="Copiar para a área de transferência"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="Salvar como PDF..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="Imprimir..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="Continuar"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Chave de Recuperação do Ostler.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Chave de Recuperação do Ostler"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="Chave de recuperação copiada para a área de transferência"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="Chave de recuperação salva em %s"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="Emparelhe seu iPhone"
MSG_INFO_PAIR_IPHONE_HELP="Abra o app Ostler no iPhone e escaneie este código QR para vinculá-lo a este Hub. Você também pode emparelhar depois, no menu Ajustes do Hub."
MSG_INFO_PAIR_IPHONE_FETCHING="Gerando código de emparelhamento..."
MSG_INFO_PAIR_REFRESH="Atualizar código"
MSG_ERR_PAIR_FETCH_FAILED="Ainda não foi possível acessar o gateway do Ostler. Ele pode estar iniciando – clique em Atualizar para tentar de novo."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="O assistant-agent não está incluído no instalador. Os resumos diários e o LaunchAgent de manutenção da conexão do WhatsApp não serão carregados."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Os scripts de recompilação da wiki não estão incluídos no instalador. A wiki não será atualizada automaticamente."

# F3 - legal package missing
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="legal package not bundled with installer. Article 9 / WhatsApp / voice consent gates will raise ModuleNotFoundError until re-installed."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s instalado em %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s já instalado, mantido como está"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Arquitetura de CPU não compatível com a CLI do Google Workspace; os recursos do Gmail / Google Agenda ficarão limitados."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl não está disponível; a instalação da CLI do Google Workspace foi ignorada. Os recursos do Gmail / Google Agenda ficarão limitados."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="Não foi possível baixar a CLI do Google Workspace de %s"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="SHA256 da CLI do Google Workspace não confere (esperado %s, obtido %s). Interrompendo a instalação deste binário."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="Não foi possível extrair o arquivo da CLI do Google Workspace."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="A CLI do Google Workspace foi instalada em %s, mas a verificação com --version falhou."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="Ponte de calendário iCloud / CalDAV instalada em %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="A ponte de calendário iCloud / CalDAV em %s não é executável. O Calendário não retornará nenhum evento."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh não está incluído no instalador. A nova tentativa de registro do dispositivo na próxima conexão de rede está desativada."

MSG_WARN_EMBED_DIMS_UNREADABLE="Não foi possível ler a largura do embedding na verificação de integridade. A memória está configurada para 768 dimensões; se a recuperação se comportar de forma estranha, verifique o modelo de embedding."
MSG_FAIL_EMBED_DIMS="O modelo de embedding retornou vetores de %s dimensões, mas o Ostler está configurado para %s. A memória armazenaria vetores que nunca poderia comparar. Verifique o modelo de embedding e execute novamente."

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
MSG_PROGRESS_REBOOT_SELFHEAL="Configurando a recuperação automática após reinício"
MSG_INFO_AUTOLOGIN_EXPLAIN="O Ostler é um hub sempre ligado, então, após uma queda de energia ou uma reinicialização, ele precisa voltar a funcionar sem ninguém no teclado. Isso só funciona se este Mac entrar na sessão sozinho, e o macOS só consegue fazer isso se a senha de login de %s estiver armazenada neste Mac.

Armazená-la torna este Mac menos seguro. A senha é embaralhada, não criptografada, então qualquer pessoa que possa usar uma conta de administrador aqui, ou que consiga retirar o disco e lê-lo em outro lugar, pode transformá-la de volta na sua senha. Você verá exatamente onde ela fica armazenada antes de digitar qualquer coisa.

Se você disser não, nada será armazenado e nada mais muda. Após uma queda de energia, você entra como de costume e os serviços do Ostler iniciam com a sua sessão. Você pode mudar isso depois em Ajustes do Sistema > Usuários e Grupos > Login automático."
MSG_PROMPT_AUTOLOGIN_CONSENT="Store your login password on this Mac so it can sign itself in after a restart? [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="O Ostler grava esta senha em um arquivo neste Mac, em /etc/kcpassword. Lá ela é embaralhada com um padrão fixo, igual em todos os Macs e documentado publicamente, então não é criptografia e pode ser desfeita. Qualquer pessoa que possa usar uma conta de administrador neste Mac, ou que consiga retirar o disco e lê-lo em outro lugar, pode transformar esse arquivo de volta na senha de login de %s.

O FileVault impediria isso, pois o disco não pode ser lido sem a senha de inicialização. Pelo mesmo motivo, o FileVault também impede o login automático, e é por isso que o Ostler só oferece esta opção quando o FileVault está desativado.

O que o instalador controla: ele não mostra a senha enquanto você a digita e não a grava no registro de instalação. O arquivo embaralhado é a única cópia que o instalador cria.

Deixe em branco para pular o login automático."
MSG_PROMPT_AUTOLOGIN_PASSWORD="Senha de login de %s"
MSG_OK_AUTOLOGIN_CONFIGURED="O login automático está ativado para %s, e essa senha de login agora está neste Mac, em /etc/kcpassword, de forma embaralhada. Após uma reinicialização, este Mac entra na sessão sozinho e os serviços do Ostler iniciam com essa sessão. Para desfazer, desative o Login automático em Ajustes do Sistema > Usuários e Grupos."
MSG_INFO_AUTOLOGIN_ALREADY="O login automático já está configurado para %s, então este Mac já tem essa senha de login armazenada em /etc/kcpassword. Mantendo ambos como estão. Para desfazer, desative o Login automático em Ajustes do Sistema > Usuários e Grupos."
MSG_INFO_AUTOLOGIN_DECLINED="O login automático não foi ativado e nenhuma senha foi armazenada. Após uma reinicialização ou queda de energia, entre como de costume e os serviços do Ostler iniciam com a sua sessão."
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="Pulando a configuração do login automático: não há como pedir a senha de login aqui e nada foi armazenado. Você pode ativar o Login automático depois em Ajustes do Sistema > Usuários e Grupos, se quiser que este Mac se recupere de uma reinicialização sem supervisão. Isso armazena sua senha de login no Mac de forma embaralhada e reversível, então vale a pena se informar antes de fazer isso."
MSG_WARN_AUTOLOGIN_NO_PASSWORD="Nenhuma senha foi digitada, então o login automático não foi ativado e nada foi armazenado. Se quiser ativá-lo depois, ative o Login automático em Ajustes do Sistema > Usuários e Grupos."
MSG_WARN_AUTOLOGIN_FAILED="Não foi possível ativar o login automático (%s). Isso não será tentado novamente. Se /etc/kcpassword existir neste Mac, ele contém essa senha de login de forma embaralhada, mesmo com o recurso desativado; você pode removê-lo pelo Terminal com: sudo rm /etc/kcpassword. Para tentar de novo, ative o Login automático em Ajustes do Sistema > Usuários e Grupos."
MSG_WARN_AUTOLOGIN_FILEVAULT="O FileVault está ativado, então este Mac pede uma senha na tela de inicialização para desbloquear o disco antes que alguém possa entrar. O login automático não consegue respondê-la, então, após uma queda de energia, este Mac espera na tela de desbloqueio do FileVault até que alguém digite a senha. O login automático não foi ativado e nenhuma senha foi armazenada. Esse é o mais seguro dos dois arranjos: a recuperação sem supervisão após reinicialização não é possível com o FileVault ativado e, em troca, o disco permanece ilegível para quem não tem essa senha."

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
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="O Ostler não conseguiu abrir os Ajustes do Sistema para você. Abra os Ajustes do Sistema manualmente e acesse Privacidade e Segurança > Acesso Total ao Disco."
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="O Ostler executa sua wiki e sua busca em contêineres, então instala e gerencia um mecanismo de contêineres (Colima) neste Mac. Se esse mecanismo for removido ou reconfigurado, sua wiki e sua busca deixarão de funcionar – o Ostler avisará você e tentará reiniciá-lo."
MSG_INFO_ENGINE_ALREADY_PRESENT="Já há um mecanismo de contêineres instalado neste Mac. O Ostler o usará em vez de instalar o seu próprio e não irá gerenciá-lo nem modificá-lo."

# OS003 #233: model weight pins (install.sh OSTLER_MODEL_PINS).
MSG_OK_MODEL_DIGEST_VERIFIED="%s verified against its pinned digest (%s)"
MSG_FAIL_MODEL_DIGEST_MISMATCH="The installed %s is not the model this installer ships: found %s, expected %s (%s). The download source may have changed, so the install has stopped before using it. Contact support with this message."
MSG_FAIL_MODEL_UNPINNED="%s has no pinned digest in this installer, so it cannot be verified and will not be used. This is an installer defect. Contact support with this message."
MSG_FAIL_MODEL_DIGEST_UNREADABLE="Could not verify the downloaded %s against its pinned digest (%s). The model will not be used unverified. Re-run the installer; if this repeats, contact support with this message."
