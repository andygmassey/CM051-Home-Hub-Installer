#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to zh-Hans by l10n/ostler_l10n.py.
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

MSG_STEP_CHECKING_PREREQUISITES="正在检查先决条件"
MSG_STEP_RUNNING_HEALTH_CHECK="正在运行健康检查"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="连接你的 iPhone 和 Apple Watch"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="设置（几个简单的问题，之后会自动继续）"
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
MSG_STEP_SETUP_COMPLETE_WRAP_UP="问题已回答完毕。Ostler 现在会在后台安装，大约需要 45 分钟到几个小时。仍有三件事需要你来处理：如果 macOS 询问是否安装开发者工具，请点击“安装”；接近结束时有一分钟的设置（开启“完全磁盘访问权限”）；最后，在健康检查之后，你需要登录 Tailscale，并允许助手使用“提醒事项”。除此之外，你可以让它自行运行。"
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="问题已回答完毕。Ostler 现在会在后台安装，大约需要 45 分钟到几个小时。仍有三件事需要你来处理：如果 macOS 询问是否安装开发者工具，请点击“安装”；接近结束时有一分钟的设置（开启“完全磁盘访问权限”）；最后，你需要允许助手使用“提醒事项”。除此之外，你可以让它自行运行。"

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="然后重新运行：ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="正在重启助手，以便它使用“完全磁盘访问权限”读取你的“信息”记录。重启后，刚授予的权限才会生效；如果你尚未授予，Doctor 仪表板会继续引导你。"
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="你的助手正在运行，并已获得“完全磁盘访问权限”，因此可以读取所需的文件。"
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="你的助手正在运行，但尚未获得“完全磁盘访问权限”。在你开启之前，Ostler 无法持续更新“信息”、“邮件”、“日历”、“提醒事项”、“备忘录”、“照片”、Safari 浏览器、“通讯录”或 WhatsApp 的内容，也无法读取你的“文稿”文件夹。已读取的内容会保留。Doctor 仪表板会引导你完成开启。"
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="你的助手正在运行。我们无法检查它在这台 Mac 上是否拥有“完全磁盘访问权限”，因此无法确认是否已开启。一旦可以检查，Doctor 仪表板会告知你。"
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="可见的“邮件”账户：%s（仅供参考）"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="“邮件”似乎还没有任何本地邮件。如果 24 小时内没有邮件到达，Doctor 会提示后续处理。"
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="“邮件”中已有缓存的邮件。下一个整点周期会自动读取这些邮件。"
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="已选择“邮件”，但这台 Mac 上还没有可读取的本地邮件。请打开“邮件”并添加账户（系统设置 > 互联网账户，然后勾选“邮件”），并等待它完成首次同步。"
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="邮件到达后，请重新运行：ostler-fda。Ostler 会自动读取，无需其他操作。"
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="Gatekeeper 将在首次启动时验证 Apple 公证。"
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="可用，安装程序将自动跳过此步骤。"
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="有访问权限的测试人员可以设置 PWG_PIPELINE_REPO=<url> 后重新运行。"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="有访问权限的测试人员可以设置 PWG_KNOWLEDGE_REPO=<url> 后重新运行。"
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="已跳过浏览器扩展（--no-extensions）"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  已克隆到 %s。"
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture 仅支持 Apple 芯片。已在这台机器上跳过安装。"
MSG_INFO_CM042_LOGS_AT="RemoteCapture 日志：%s/ostler-remotecapture.log（以及 .err）"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="之前的安装让 Ostler RemoteCapture 在登录时启动。它已被停止，不会再次启动。"
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="未安装 Ostler RemoteCapture：你选择了关闭语音转写。如果改变主意，请在“设置”中开启，然后再次运行安装程序。"
MSG_INFO_CM042_TCC_PRE_PROMPT="首次启动时，Ostler RemoteCapture 会请求 macOS 授予“屏幕录制”和“麦克风”权限。请同时允许，以便在本地转写通话和会议。菜单栏中不会出现紫色录制指示标志，音频采集在设计上是静默的。"
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
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="Ostler 会将你的个人维基和对话记录保存在这台 Mac 的 Documents/Ostler 下。它们归你所有，并且只保留在这台设备上。为了写入这些内容，Ostler 需要访问你的“文稿”文件夹，因此 macOS 可能会在设置期间请求授权，并在今天稍后 Ostler 首次整理你的维基时再次请求。该请求可能显示为来自 python3.11，这是 Ostler 用来写入你文件的内置辅助程序。请在其出现时点击“允许”。如果你错过或拒绝了，可随时在“系统设置”的“隐私与安全性”中，选择“文件和文件夹”来开启，之后你的维基和对话记录就会被写入。"
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  对话记忆引擎已安装到 venv 中。"
MSG_INFO_HUB_APP_VERIFYING="正在验证位于 %s 的 Ostler.app"
MSG_INFO_HUB_APP_STAGING="正在从 %s 将 Ostler.app 放入 /Applications"
MSG_INFO_HUB_APP_DRAG_HINT="请打开安装程序 DMG，将 Ostler.app 和 OstlerInstaller.app 都拖到“应用程序”快捷方式上，然后重新运行安装程序。"
MSG_OK_HUB_APP_PRESENT="%s 中已存在 Ostler.app，签名已验证。"
MSG_OK_HUB_APP_STAGED="Ostler.app 已安装在 %s"
MSG_WARN_HUB_APP_NOT_FOUND="在 /Applications 中未找到 Ostler.app，也没有可用的内置副本。"
MSG_WARN_HUB_APP_VERIFY_FAILED="Ostler.app 的签名或公证验证失败。已保留该应用包，以便支持人员检查。"
MSG_OK_UNINSTALLER_APP_STAGED="Ostler Uninstaller.app 已安装在 %s"
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="无法将 Ostler Uninstaller.app 放入 /Applications。你仍可通过运行以下命令来卸载：~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="正在克隆 Doctor 代理..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="正在克隆邮件导入脚本..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="正在克隆 Hub 电源脚本..."
MSG_INFO_CLONING_IMPORT_PIPELINE="正在克隆导入流程..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="正在克隆 wiki 重新编译脚本..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima 已安装但未运行。将启动它。"
MSG_INFO_COLIMA_START_ATTEMPT="正在启动 Colima（第 %s 次尝试，共 %s 次）..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="无法导出通讯录。你可以稍后手动导入。"
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="无法读取联系人卡片。没关系，我们会改为询问你。"
MSG_INFO_CONTACT_CARD_WILL_ASK="稍后我们会询问你的姓名和所在国家或地区。你的通讯录将在之后通过你授予的“完全磁盘访问权限”读取，任何内容都不会离开这台 Mac。"
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  正在 %s 创建 Python 虚拟环境..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="正在 %s/ 创建面向用户的内容目录树"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="每日定时任务。手动运行：bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="检测到台式 Hub（无电池）：正在全系统禁用睡眠"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="未安装 Docker。将安装 Colima、Docker CLI 和 docker-compose 插件（轻量，无需 Docker Desktop）。"
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="安装程序未附带 Doctor 代理文件。"
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="安装程序未附带邮件导入脚本。"
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="安装程序包中缺少邮件导入脚本。请从 ostler.ai/install 重新下载 .app，然后重试。"
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="未附带邮件导入脚本，且已传入 --allow-plaintext；将跳过 LaunchAgent 安装。后续邮件将不会被导入。"
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  %s 处已有检出副本；正在更新..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="正在从 Takeout 压缩包中提取 Gmail mbox（大型归档可能需要一分钟）..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="未附带 FDA 提取模块。跳过即时数据提取。"
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="正在激活你前 30 天的 Ostler Pro..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="试用结束后，Ostler Pro 每月 9.99 美元。请在 iPhone 上的 Ostler app 中订阅。"
MSG_INFO_FOUND_GMAIL_MBOX_MB="在 %s 找到 Gmail mbox(%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="在 %s 找到 Google Takeout 压缩包（%s MB）"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="已检测到“完全磁盘访问权限” – 可进行完整提取。"
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="已检测到 GDPR 导出文件，但导入流程尚不可用。"
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="待导入流程发布后，即可导入 GDPR 导出文件。"
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="即将扫描“下载”、“桌面”和“文稿”文件夹，查找你可能保存的 AI 导出文件（Google Takeout、Meta 下载内容、LinkedIn 等）。macOS 会弹出三个文件夹访问提示，请逐一允许。整个过程大约需要 5-10 秒。扫描期间不会移动或复制任何内容，我们只检查有什么文件。"
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS 可能会请求读取你的“日历”的权限。请允许，以便 Ostler 构建你知识图谱中的会议与活动部分。（日历数据保留在这台设备上。）"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS 正在请求“下载”文件夹的权限。请点按“好”。"
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS 正在请求“桌面”文件夹的权限。请点按“好”。"
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS 正在请求“文稿”文件夹的权限。请点按“好”。"
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="已授予“完全磁盘访问权限”。正在准备下一个 macOS 提示（“信息”自动化）..."
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="“信息”权限提示未得到回应，因此我们已继续。在获得允许之前，不会读取你的信息。Ostler 会再次询问，你也可以在“系统设置”>“隐私与安全性”>“自动化”中授予权限。"
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="需要 Xcode 命令行工具。macOS 会请求安装权限，请留意一个灰色的小对话框（如果没有看到，请按 Cmd+Tab 或查看程序坞）。点击“安装”。在你回答下面的问题时，工具会在后台下载。"
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  仍在设置命令行工具（%s 秒）。如果有一个灰色的 macOS 小对话框正在询问是否安装开发者工具，请点击“安装”，此步骤正在等待它。（如果看不到，请按 Cmd+Tab 或查看程序坞。）"
MSG_WARN_CLT_STILL_WAITING_AFTER_TIMEOUT="Still waiting for Apple's developer tools. Click Install developer tools if you don't see the dialog."
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="正在等待命令行工具安装完成（马上就好）..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="每小时运行一次。首次运行会拉取最近 5 年的邮件。"
MSG_INFO_IMESSAGE_BRIDGE_STARTED="正在停用旧版 iMessage 桥接 LaunchAgent（单机 v1.0）"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="仅交流电源的 Hub（未检测到电池），跳过 hub-power LaunchAgent。"
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="安装程序未附带 Hub 电源脚本。"
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="笔记本 Hub。只要屏幕打开并接通电源，它就会持续运行。"
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="合上屏幕，或在使用电池且闲置时，macOS 会让它进入睡眠。"
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="睡眠期间，助手不会收到任何内容。"
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="这段时间内到达的消息，在唤醒后不会被接收。"
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="在合盖模式下，屏幕可以保持合上。"
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="这需要接通电源，并连接外接显示器、键盘和鼠标。"
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="Docker 和 Ollama 在使用电池时暂停，接通电源后恢复。"
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="重启后，FileVault 会让这台 Mac 停留在登录屏幕。"
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="你登录后，Ostler 才会启动。"
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="助手 API 已随安装程序附带，使用内置源代码。"
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="未附带助手 API 源代码，你 iPhone 上的 Ostler app 的访问将受限。"
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="正在安装助手 API 运行时依赖项（phonenumbers、httpx）..."
MSG_WARN_ICAL_SERVER_DEPS_FAILED="无法安装助手 API 运行时依赖项（phonenumbers/httpx），在下次运行安装之前，“人物”和“时间线”可能保持为空。"
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Tailscale 窗口出现后，请使用 Apple / Google / Microsoft 账户登录。"
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="正在打开 Tailscale，以便你登录..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="明白了。接下来 Ostler 大部分会自动安装。临近结束时，它需要你回来大约两分钟：开启“完全磁盘访问权限”，然后登录 Tailscale，这样你的 iPhone 和 Apple Watch 就能随时随地连接这台 Mac。我们会打开浏览器供你登录。"
MSG_INFO_TAILSCALE_SKIPPED="已跳过 Tailscale，你 iPhone 上的 Ostler app 将只能在家庭 Wi-Fi 下使用。你可以稍后在“设置”中进行设置。"
MSG_INFO_TAILSCALE_STILL_WAITING="仍在等待 Tailscale 登录（已过 %s 秒），请在 Tailscale 窗口中完成登录。"
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="已授予“完全磁盘访问权限”，正在重新启动助手以使新权限生效。"
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="正在打开“系统设置”和访达，引导你为助手授予“完全磁盘访问权限”..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="正在向 macOS 注册 Ostler 助手，使其作为开关出现在“完全磁盘访问权限”中..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="“完全磁盘访问权限”仍待授予。在授予之前，Doctor 仪表板会一直显示该卡片。"
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant 已拥有“完全磁盘访问权限”，无需进一步操作。"
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="这一步需要你参与大约两分钟：现在为助手开启“完全磁盘访问权限”，然后在下一步登录 Tailscale。之后，你就可以让 Ostler 自行完成剩余部分。"
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="这一步需要你参与大约一分钟：为助手开启“完全磁盘访问权限”。之后，你就可以让 Ostler 自行完成剩余部分。"
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="“%s”已列在“完全磁盘访问权限”中，你只需将其开启。无需从访达拖移任何内容。"
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="正在检查 Ostler 助手是否拥有“完全磁盘访问权限”..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="助手可以读取“信息”历史记录，iMessage 渠道将可正常使用。"
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="Ostler 助手尚未获得“完全磁盘访问权限”。它需要此权限来保持你 Mac 自带 App 的数据最新，无论你是否使用“信息”。如果现在跳过，Doctor 仪表板会引导你前往“系统设置”进行设置。"
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="助手 LaunchAgent 未加载，正在跳过 iMessage 的“完全磁盘访问权限”检测。"
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="Doctor 中的 Evernote 导入界面将显示“服务不可用”"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="安装程序未内置导入流程。"
MSG_INFO_INSTALLING_CM042="正在安装 Ostler RemoteCapture v%s（通话和会议转写）..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="正在从 %s 安装对话记忆引擎..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  正在将对话记忆引擎安装到 venv..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="正在安装 Colima + Docker CLI..."
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="正在安装 GNU coreutils（用于为耗时较长的步骤设置超时上限）..."
MSG_INFO_INSTALLING_HOMEBREW="正在安装 Homebrew..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="正在从 %s 安装知识服务..."
MSG_INFO_INSTALLING_OLLAMA="正在安装 Ollama..."
MSG_INFO_INSTALLING_OLLAMA_PINNED="Installing Ollama %s (verified release)..."
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  正在安装数据提取模块的依赖项..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  正在将 Apple Mail 读取器安装到专用 venv..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  正在将 ostler-knowledge 安装到 venv..."
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  正在将加密存储依赖项安装到对话记忆 venv..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="正在将 Safari 扩展安装到 /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="正在安装安全相关的 Python 依赖项..."
MSG_INFO_INSTALLING_SQLCIPHER="正在安装 SQLCipher..."
MSG_INFO_INSTALLING_TAILSCALE="正在安装 Tailscale..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="Intel 支持不在路线图中；如有需要，请提交请求。"
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="知识服务已随安装程序内置，将使用内置源码。"
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="知识服务未安装：PWG_KNOWLEDGE_REPO 为空。"
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="这台 Mac 是笔记本电脑。作为你的 Hub，它在屏幕打开且接通电源时才能持续工作。"
MSG_INFO_LAPTOP_HUB_SLEEP_COST="合上屏幕，或在使用电池时闲置，macOS 就会让它进入睡眠。睡眠期间助手无法接收任何内容，这段时间到达的消息在唤醒后也不会被补收。"
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="在合盖模式下可以保持屏幕合上，但需要接通电源，并连接外接显示器、键盘和鼠标。"
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="Mac Mini 或 Mac Studio 作为 Hub 可自行保持唤醒，如果你更愿意安装在这类设备上的话。"
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="稍后在“系统设置”>“隐私与安全性”>“完全磁盘访问权限”中设置"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  启动以验证 cron 投递和 imessage-tcc 状态)。"
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="许可证：%s 采用 Apache 2.0。全文：%s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licence: %s – check upstream terms before commercial use."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="本地存储 – Google 永远不会知道 Ostler 的存在。"
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="日志：%s/email-ingest.log（以及 .err）"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="日志：%s/ostler-assistant.log（以及 .err）"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="日志：%s/wiki-recompile.log（以及 .err）"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="MacBook Hub：请设置 PWG_HUB_POWER_REPO=<url> 并重新运行。"
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="检测到 MacBook Hub：仅在接通电源时设为永不睡眠（电池状态切换由 hub-power 处理）"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Mac Mini / Studio 部署不受影响（始终接通电源）。"
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Mac 端数据（iMessage、Safari 等）已在上方提取。"
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="手动重启：launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="手动运行：bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="正在跳过 com.ostler.meeting-brief-sender 的安装（v1.0.1 功能；接口尚未发布）。"
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="正在跳过记忆整理（此安装程序未包含）；在其可用之前，不会自动降低任何内容的权重。"
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="功能开关日后开启时的提示信息。"
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="需要帮助？请发送邮件至 support@ostler.ai。我们力争在 2 个工作日内回复。"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="尚未配置任何渠道。稍后运行：%s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="已删除工作区根目录中过时的旧版 config.toml；当前使用的助手配置位于 assistant-config/ 下。"
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="目前没有可用的“完全磁盘访问权限”数据源。你可以授予“完全磁盘访问权限”"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="在“下载”、“桌面”或“文稿”中未找到 GDPR 导出文件。"
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="无法读取 %s 以查找数据导出文件。macOS 正在阻止访问该文件夹。"
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="请在“系统设置”>“隐私与安全性”>“文件和文件夹”（或“完全磁盘访问权限”）中授予访问权限后重新运行，或在下方手动为 Ostler 指定你的导出文件夹。"
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="由于 macOS 阻止了访问，无法扫描一个或多个文件夹中的数据导出文件。请授予访问权限后重新运行，或手动告诉我你的导出文件夹位置。"
MSG_INFO_OPENING_CHROME_WEB_STORE="正在打开 Chrome 网上应用店：%s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="未安装 ostler-assistant 二进制文件；正在跳过 doctor 检测"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor：已推迟（守护进程可能仍在"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="正在使用此 DMG 中附带的 ostler-assistant 二进制文件（支持离线安装）。"
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge 已安装到 venv 中。"
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler will show an extra consent screen before installing"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  可通过 ./install.sh --help 中说明的环境变量覆盖对话记忆引擎的源仓库。"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  使用 PWG_DOCTOR_REPO=<url> ./install.sh 覆盖源仓库"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  使用 PWG_HUB_POWER_REPO=<url> ./install.sh 覆盖源仓库"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  使用 PWG_KNOWLEDGE_REPO=<url> ./install.sh 覆盖源仓库"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  使用 PWG_PIPELINE_REPO=<url> ./install.sh 覆盖源仓库"
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Persisting consent records and region..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="第 3 阶段电池监视器已启动（PID %s）"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="正在读取你的通讯录（较大的通讯录可能需要几分钟 – 请勿关闭安装程序）..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="策略覆盖：编辑 ~/.ostler/power.conf(normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="正在检测 iMessage 自动化权限（只读）..."
MSG_INFO_PULLING_GRAPH_DB_IMAGES="正在下载知识图谱数据库（仅首次运行）。全新安装可能需要一分钟..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="正在拉取 nomic-embed-text(274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="正在拉取 %s(%s)...可能需要几分钟。"
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="隔离 xattr 已清除。一旦 Developer-ID 版本"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="正在读取 Safari、iMessage、备忘录、日历、照片、提醒事项、邮件..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="正在读取你的通讯录名片以预填你的信息..."
MSG_INFO_REGION_EU_EEA_SOURCE="地区：欧盟/欧洲经济区（%s，来源：%s）"
MSG_INFO_REGION_SOURCE="地区：%s（来源：%s）"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="地区：英国（来源：%s）"
MSG_INFO_REGION_UNITED_STATES_SOURCE="地区：美国（来源：%s）"
MSG_INFO_REPO_URL="仓库 URL:%s"
MSG_INFO_REPO_URL_2="仓库 URL:%s"
MSG_INFO_REPO_URL_3="仓库 URL:%s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="现在请选择用于解锁你的 Hub 的口令。每次启动 Hub 界面时，你都需要输入这个口令。"
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="已跳过恢复口令。（已弃用：v1.0 始终需要设置口令。）"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="正在复用位于 %s 的现有 Doctor 代理安装"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="正在复用位于 %s 的现有邮件导入安装"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="正在复用位于 %s 的现有 hub-power 安装"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="正在复用位于 %s 的现有浏览器扩展密钥"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="Chrome 版 Ostler 扩展不包含在此版本中。"
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="Email conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="邮件对话：未设置，因为这台 Mac 上尚未设置 Apple Mail。"
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="Messages conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="信息对话：未设置，因为这台 Mac 上没有“信息”记录。"
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  用 Ostler 转录一次通话后，此功能会自动开启。"
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="语音对话：尚未设置，因为没有可读取的转录内容。"
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="语音对话：已关闭，因为自安装 Ostler 以来，转录文稿文件夹已被移除。"
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  重新创建 %s 即可再次开启。Ostler 不会替你重新创建它。"
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="WhatsApp conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="WhatsApp 对话：未设置，因为 WhatsApp 已关闭。"
MSG_INFO_CHROME_HISTORY_STILL_READ="  Ostler 仍会读取你的 Chrome 历史记录，因此你访问过的页面会被记住。目前，浏览时的实时捕获仅支持 Safari。"
MSG_INFO_REUSING_EXISTING_JWT_SECRET="正在复用 %s 中现有的 JWT_SECRET"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="正在复用位于 %s 的现有 PWG 服务令牌"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="正在复用位于 %s 的现有 wiki-recompile 安装"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="此安装器版本不含 Safari 扩展包（已跳过）"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="还剩一个手动步骤：打开 Safari，选取“Safari 浏览器”>“设置”>“扩展”，然后勾选 Ostler 以启用。"
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="正在扫描 GDPR 数据导出文件..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="请设置 PWG_DOCTOR_REPO=<url> 后重新运行以进行安装。"
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="请设置 PWG_HUB_POWER_REPO=<HR015 url> 后重新运行以进行安装。"
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="已跳过对话模型。稍后可拉取：ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="正在启动 Colima（轻量级 Docker 运行环境）..."
MSG_INFO_STARTING_DOCKER_DESKTOP="正在启动 Docker Desktop..."
MSG_INFO_STARTING_OLLAMA="正在启动 Ollama..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="正在移除旧版本遗留的过时 Colima 启动项..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="正在移除旧版 Ollama formula（不含 llama-server），并切换到 Ollama 应用..."
MSG_INFO_VERIFYING_EMBEDDINGS="正在验证嵌入引擎是否返回向量..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="无法自动启动 Ollama。请使用以下命令加载：launchctl bootstrap gui/\$(id -u) %s – 然后重新运行安装器。"
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="Ollama 未能通过后台服务启动；本次运行将直接启动它..."
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  启动中；首次启动后请运行 \`ostler-assistant doctor\`"
MSG_INFO_SYMLINKING="  正在为 %s 创建符号链接 -> %s"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="（系统设置 > 互联网帐户）。Ostler 会读取“邮件”的"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="（没有 Doctor 仪表板，Ostler 的其余部分仍可运行。）"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="目前这是正常现象。GDPR 导入将在日后的更新中提供。"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="这通常需要 15 到 45 分钟；如果你的历史记录很多或 Mac 较慢，可能会更久。这是正常的 – 它正在工作，并没有卡住，你可以放心让它继续运行……"
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="这会直接读取 macOS 数据库 – 无需导出。"
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="提示：若要包含你的 Gmail，请先将其添加到 Mac 的“邮件”中"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="获得访问权限后，如需稍后安装："
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="正在为 %s 触发 iCloud 同步（静默进行，仅首次运行）..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (UK GDPR Article 9 - required for special-category data)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="正在更新现有流程..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="面向用户的目录树已发布过（存在标记文件）；已跳过"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="正在下载本地网页搜索引擎（约 3.5 GB）。首次安装时这是最耗时的一步，可能需要长达一小时。此步骤没有进度条，因此长时间没有动静是正常的，并不表示安装已停滞。"
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane 无响应（可选；请参阅 Phase 3.8b 的警告）"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="随时可通过以下命令查看：bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="语音识别将保持关闭。你可以稍后在“设置”中启用。"
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="正在等待你登录 Tailscale（最长 3 分钟）..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="未设置 Tailscale 远程访问。你 iPhone 上的 Ostler app 可在家庭 Wi-Fi 下使用；你可以稍后在“设置”中设置远程访问。"
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="这台 Mac 已连接到你的 Tailscale 网络，因此无需设置。将保留你现有的连接。"
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="远程访问：沿用你上次的选择，即跳过。你的 iOS app 可在家庭 Wi-Fi 下使用，你也可以稍后在“设置”中设置远程访问。"
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="远程访问：沿用你上次的选择，即进行设置。"
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="WhatsApp 连接器已保持关闭。你可以稍后在“设置”中启用。"
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="WhatsApp 保活任务已安排在 08:50 + 17:50（标签 com.creativemachines.ostler.whatsapp-keepalive）"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="正在跳过首日 wiki 补编译：未安装 wiki-recompile 定时任务。若已安装每日 wiki 重建，它仍会照常运行。"
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="安装程序未附带 wiki-recompile 脚本。"
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="Wiki 不会自动更新；你可以手动重新运行首次编译："
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="已写入状态标记：%s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="你的导出文件是安全的。之后可通过以下命令导入：ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="你的 Mac 数据（iMessage、Safari 等）已在上方提取完成。"
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="你可以稍后再添加，以便从 Safari、iMessage 等快速完成引导。"

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="AI 模型：%s（%s）– 已根据你的 %s GB 内存选定"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="适合"
MSG_MODELFIT_PILL_SLOW="可能较慢"
MSG_MODELFIT_PILL_NOFIT="无法运行"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="正在为你的 Mac 匹配助手模型（%s，%s GB 内存，助手上下文 %s 个 token）："
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- 推荐"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="AI 模型：%s（%s）– 在助手所需的上下文窗口下，最适合你的 %s GB 内存"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="已选择所有来源（人脸识别仍为关闭）"
MSG_OK_ALREADY_AVAILABLE="%s 已可用"
MSG_OK_APPLE_SILICON_DETECTED="检测到 Apple 芯片"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="已启动 App 以触发 iCloud 同步"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="App 数据库已存在（跳过预启动）"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="助手配置已保存到 %s（权限 0600）"
MSG_OK_BACKED_UP_CONTACTS="已将 %s 位联系人备份到 %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s 已安装在 %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="Ostler RemoteCapture 启动代理已加载（标签 %s）"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="已安装 Colima 和 Docker CLI"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="已安装容器运行时监管程序（每 5 分钟检查一次，运行时停止后会自动重启）"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="无法安排容器运行时监管程序。Ostler 仍会安装，但如果之后运行时停止，将没有任何机制自动将其恢复，你的 wiki 会一直无法使用，直到你重新运行安装程序。"
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="此安装程序缺少容器运行时监管程序的文件，因此未安排该程序。Ostler 仍会安装，但运行时的自动恢复功能未启用。"
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="无法启动 Ostler Doctor 仪表板，因此 http://localhost:8089 将无法响应。App 中读取该仪表板数据的页面，包括人物、时间线、Governor 和频道状态，在其运行之前将显示为不可用。请重新运行安装程序再试一次。"
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="无法安排保持唤醒辅助程序。Ostler 仍可正常使用，但这台 Mac 可能会在长时间的后台任务期间进入睡眠，任务会在唤醒后继续，而不是在夜间完成。"
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="无法安排后台补充辅助程序，因此新的信息、邮件和日历条目将不会自动获取。请重新运行安装程序以恢复。"
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="%s not set up: Ostler has no record of your answer to the question that governs it, so it did not assume one."
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  Re-run Ostler and choose to answer the questions again to turn it on. (consent record: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="无法安排每日简报，因此你将不会收到早间摘要。其他功能均正常；请重新运行安装程序以恢复。"
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="无法安排记忆整理任务，因此过时或已被取代的事实不会被自动降低权重。其他功能均正常；请重新运行安装程序以恢复。"
MSG_WARN_EXPORT_SCAN_NOT_LOADED="无法启动“下载”文件夹监视程序，因此你放入“下载”的文件不会被自动获取。已导入的内容不受影响，你仍可在 App 内添加文件。请重新运行安装程序以恢复。"
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="无法安排设备注册的重试辅助程序。如果你的 iPhone 在设置期间已注册，则不受影响；如果未注册，你需要在 App 中重新配对，而不会自动完成。"
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="容器运行时正在响应"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="已移除旧版本遗留的过时 Colima 启动项"
MSG_OK_CONFIG_SAVED_ENV="配置已保存到 %s/.env"
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Consent records and region persisted to ~/.ostler/posture/"
MSG_OK_AT_REST_EXCLUDED="已排除在 Spotlight 和 Time Machine 之外（已检查）：%s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s 未被排除在 Time Machine 或 Spotlight 之外：%s。其内容，包括 Ostler 的密钥，可能会被复制到你的备份磁盘。在问题解决之前，Doctor 会一直显示此提示。"
MSG_INFO_AT_REST_FOLDER_ABSENT="%s 尚不存在，因此没有需要从备份中排除的内容。"
MSG_WARN_DB_KEY_NOT_EXCLUDED="数据库密钥文件 %s 未被排除在 Time Machine 之外，因此可能会被复制到你的备份磁盘。"
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="无法将你的后台扩充选择保存到 ~/.ostler/posture/。你的选择仍会应用于此次安装，只是不会出现在支持报告中。"
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="数据库已加密。Hub 服务会从你个人文件夹中的受保护文件读取密钥，因此启动时无需向你询问。"
MSG_OK_DB_KEY_DELIVERED="数据库密钥已交付给 Hub 服务（%s，仅你本人可读）。"
MSG_WARN_DB_KEY_NOT_DELIVERED="无法将数据库密钥交给 Hub 服务。在问题解决之前，它们将以未加密方式打开数据库。"
MSG_INFO_DB_KEY_RECOVER_HINT="运行以下命令以恢复密钥并交付：%s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="正在加密早期安装遗留的数据库"
MSG_WARN_DB_MIGRATION_FAILED="部分现有数据库无法加密，它们在磁盘上仍可被读取。"
MSG_WARN_DB_KEY_MISSING_ON_RERUN="此安装没有数据库密钥文件，因此 Hub 服务正在以未加密方式打开数据库。"
MSG_WARN_DB_PLAINTEXT_COUNT="这台 Mac 上目前有 %s 个数据库在磁盘上可被读取。"
MSG_INFO_DB_MIGRATE_HINT="然后加密已有的数据库：%s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="已安装延迟的设备注册重试程序（每小时运行一次，直到队列清空）"
MSG_OK_DOCKER_RUNNING="Docker 已运行"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker 已运行（用时 %s 秒）"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="已从 %s 克隆 Doctor 代理"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Doctor 代理文件已随安装程序打包"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Doctor 依赖项已安装"
MSG_OK_EMAIL_CHANNEL_FOLDER="邮件通道：%s（文件夹：%s）"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="邮件导入 LaunchAgent 已加载（标签 com.creativemachines.ostler.email-ingest）"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="邮件导入脚本已随安装程序打包"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="已从 %s 克隆邮件导入脚本"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="正在设置 WhatsApp 对话记忆"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  WhatsApp 对话读取器已安装。"
MSG_WARN_WHATSAPP_SOURCE_FAILED="WhatsApp 对话读取器安装失败；WhatsApp 对话源将不会运行。请查看上方输出。"
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="未找到 WhatsApp 对话读取器源文件；已跳过 WhatsApp 对话源。"
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="此安装程序中未找到 WhatsApp 对话源软件包；已跳过。WhatsApp 消息历史（你与谁在何时发过消息）不受影响。"
MSG_OK_WHATSAPP_BUNDLE_LOADED="WhatsApp 对话源 LaunchAgent 已加载（标签 com.creativemachines.ostler.whatsapp-bundle）"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  首次运行会读取你的 Mac 已同步的近期 WhatsApp 对话（约最近一年）；数据只保留在你的 Mac 上。"
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  日志：%s/whatsapp-bundle.log 和 whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="WhatsApp 对话源 LaunchAgent 安装失败。请查看上方输出；其余安装不受影响。"
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  尚未启动：此代理要运行的助手程序不在磁盘上。已查找：%s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="正在设置邮件对话记忆"
MSG_OK_EMAIL_SOURCE_INSTALLED="  邮件对话读取器已安装。"
MSG_WARN_EMAIL_SOURCE_FAILED="邮件对话读取器安装失败；邮件对话源将不会运行。请查看上方输出。"
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="未找到邮件对话读取器源文件；已跳过邮件对话源。"
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="此安装程序中未找到邮件对话源软件包；已跳过。每小时一次的邮件导入不受影响。"
MSG_OK_EMAIL_BUNDLE_LOADED="邮件对话源 LaunchAgent 已加载（标签 com.creativemachines.ostler.email-bundle）"
MSG_INFO_EMAIL_BUNDLE_TICK="  从 Apple Mail 的本地存储中读取你近期的邮件会话；所有内容都保留在你的 Mac 上。"
MSG_INFO_EMAIL_BUNDLE_LOGS="  日志：%s/email-bundle.log 和 email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="邮件对话源 LaunchAgent 安装失败。请查看上方输出；其余安装不受影响。"
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="正在设置会议和语音对话记忆"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  会议和语音对话读取器已安装。"
MSG_WARN_SPOKEN_SOURCE_FAILED="会议和语音对话读取器安装失败；该对话源将不会运行。请查看上方输出。"
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="未找到会议和语音对话读取器源文件；已跳过该对话源。"
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="此安装程序中未找到会议和语音对话源软件包；已跳过。"
MSG_OK_SPOKEN_BUNDLE_LOADED="会议和语音对话源 LaunchAgent 已加载（标签 com.creativemachines.ostler.spoken-bundle）"
MSG_INFO_SPOKEN_BUNDLE_TICK="  将你自己的会议和语音备忘转录为可搜索的对话；所有内容都保留在你的 Mac 上。"
MSG_INFO_SPOKEN_BUNDLE_LOGS="  日志：%s/spoken-bundle.log 和 spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="会议和语音对话源 LaunchAgent 安装失败。请查看上方输出；其余安装不受影响。"
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="正在设置 iMessage 对话记忆"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  iMessage 对话读取器已安装。"
MSG_WARN_IMESSAGE_SOURCE_FAILED="iMessage 对话读取器安装失败；iMessage 对话源将不会运行。请查看上方输出。"
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="未找到 iMessage 对话读取器源文件，已跳过 iMessage 对话信息流。"
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="此安装程序中未找到 iMessage 对话信息流软件包，已跳过。"
MSG_OK_IMESSAGE_BUNDLE_LOADED="iMessage 对话源 LaunchAgent 已加载（标签 com.creativemachines.ostler.imessage-bundle）"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  从这台 Mac 的“信息”存储中读取你最近的 iMessage 对话；所有内容都保留在你的 Mac 上。"
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  日志：%s/imessage-bundle.log 和 imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="iMessage 对话源 LaunchAgent 安装失败。请查看上方输出；其余安装不受影响。"
MSG_OK_EMBEDDING_MODEL_READY="嵌入模型已就绪"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="已导出 %s 位联系人（将自动导入）"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="导出监视器已安装（每 4 小时扫描一次“下载”文件夹）"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  导出监视器尚未启动：它要运行的助手程序不在磁盘上。已查找：%s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="会前简报发送器已安装（在清醒时段每 10 分钟轮询一次）"
MSG_OK_MEMORY_HYGIENE_INSTALLED="记忆整理已安排（每天运行，避免过时的信息挤占当前信息）"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="接通电源时你的 Mac 将保持唤醒，以便 Ostler 持续工作（使用电池时仍会休眠）"
MSG_OK_EXTRACTED="已解压到 %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="已从 %s 个来源提取。数据已保存到 %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="FDA 重新运行已安排为每 %s 分钟一次（可捕获较慢的 iCloud 同步并完成日历回填）"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro 已启用，有效期 30 天。试用结束后，如需继续使用，请在 iPhone 上的 Ostler app 中订阅。"
MSG_OK_FOUND="已找到：%s"
MSG_OK_FOUND_EXPORTS="已在 %s 找到导出文件"
MSG_OK_FOUND_GDPR_EXPORT_S="已找到 %s 个 GDPR 导出文件："
MSG_OK_GB_FREE_DISK_SPACE="可用磁盘空间 %s GB"
MSG_OK_GB_RAM_DETECTED="检测到 %s GB 内存"
MSG_OK_GDPR_IMPORT_COMPLETE="GDPR 导入完成"
MSG_OK_GIT_AVAILABLE="Git 可用"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="已触发命令行工具安装（在你回答下方问题时于后台下载）。"
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils 已安装（耗时较长的步骤现已设置时间上限）"
MSG_OK_HOMEBREW_INSTALLED="Homebrew 已安装"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="Hub 电源 LaunchAgent 已加载（标签 com.creativemachines.ostler.hub-power）"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Hub 电源脚本已随安装程序打包"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Hub 电源脚本已从 %s 克隆"
MSG_OK_ICAL_SERVER_INSTALLED="助手 API 已安装（回环地址 127.0.0.1:8090，由 Doctor 代理）"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="iMessage 桥接 LaunchAgent 已加载（标签 com.ostler.imessage-bridge）"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="iMessage 桥接脚本已随安装程序打包"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="iMessage 桥接脚本已从 %s 克隆"
MSG_OK_IMESSAGE_CHANNEL="iMessage 渠道：%s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="导入管线已随安装程序打包"
MSG_OK_IMPORT_PIPELINE_READY="导入管线已就绪"
MSG_OK_CM048_PIPELINE_READY="对话记忆引擎已就绪。"
MSG_INFO_CM048_SETTINGS_WRITTEN="  对话模型已设为 %s（与你的 %s GB 内存相匹配）"
MSG_INFO_CM048_SETTINGS_KEPT="  保留你现有的对话设置（%s）"
MSG_OK_KNOWLEDGE_SERVICE_READY="知识服务已就绪：%s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="许可文本已安装到 %s/（来源：%s）"
MSG_OK_MACOS_DETECTED="检测到 macOS %s"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="正在打开“系统设置”>“互联网账户”，以便你添加邮件账户。登录第一个账户后，请回到此窗口。"
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="正在跳过“互联网账户”步骤。你之后可以在“系统设置”中添加邮件账户；如果 24 小时内没有收到邮件，Doctor 会提示后续操作。"
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="正在拉取你完整的 Apple Mail 历史记录。邮箱较大时可能需要多等一会儿。"
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="保留标准的五年邮件时间范围。你之后可以在 Doctor 中拉取更多邮件。"
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text 已可用"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="Ollama 已安装"
MSG_WARN_OLLAMA_CUSTOMER_APP_PRESENT="An Ollama app is already installed in Applications. Ostler leaves it exactly as it is and runs its own copy of Ollama %s alongside it. If that app is open in the menu bar, quit it so Ostler can start its own."
MSG_WARN_OLLAMA_PIN_DEFERRED="Could not update Ollama to %s this time, so Ostler is keeping the copy it already runs (%s). Your assistant keeps working. The update will be tried again the next time the installer runs. Details: %s"
MSG_WARN_MODEL_PULL_HELD_OLLAMA_UNPINNED="Not downloading %s this time: Ostler's tested copy of Ollama (%s) is not installed yet, and a different Ollama could fetch the wrong build. The next installer run downloads it."
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama 已安装（仅命令行工具 – 重启后可能需要手动启动）"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama 已安装（桌面应用）"
MSG_OK_OLLAMA_RUNNING="Ollama 正在运行"
MSG_OK_EMBEDDINGS_VERIFIED="嵌入引擎已验证（768 维向量）"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor：自身启动检查中 0 个错误"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="Ostler 助手 LaunchAgent 已加载（标签 com.creativemachines.ostler.assistant）"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s 已放置于 %s（已签名）"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s 已放置于 %s（未签名）"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor 正在运行：http://localhost:8089/doctor"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  数据提取模块加载正常。"
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Apple Mail 读取器已安装。"
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  邮件导入引擎已安装。"
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="ostler-import、ostler-fda 和 ostler-uninstall 命令已安装"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="已记下密码短语。它将在第 3 阶段用于加密你的数据库。"
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="恢复密码短语已设置。"
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="已确认密码短语说明。"
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="已记下 Disney+ 导出文件的密码。导入时会用到。"
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="正在跳过 Disney+ 导出：未提供密码。其他内容不受影响。"
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="电源：交流电（台式 Mac，无电池）"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="电源：交流电（很好 – 安装可能需要 45 分钟到数小时，市电供电更稳定）"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="检测到之前的安装。正在加载配置..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="使用内置的 Python %s（无需系统安装）"
MSG_OK_PYTHON_INSTALLED="Python %s 已安装"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="配对服务运行正常"
MSG_WARN_GATEWAY_NOT_RESPONDING="配对服务无响应（127.0.0.1:8000）- 手机/浏览器配对和聊天助手可能暂时无法使用"
MSG_OK_DOCTOR_HEALTHY="Doctor 运行正常"
MSG_WARN_DOCTOR_NOT_RESPONDING="Doctor 无响应（127.0.0.1:8089）- App 和浏览器通过它连接 Ostler，因此数据和配对可能无法使用"
MSG_OK_WIKI_HEALTHY="你的 Wiki 运行正常"
MSG_OK_ICAL_SERVER_HEALTHY="助手 API 运行正常"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="助手 API 无响应（127.0.0.1:8090）- 在其启动之前，“人物”“会议”和“时间线”可能为空"
MSG_OK_READY="%s 已就绪"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="已选择推荐的来源"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="恢复密钥已存入钥匙串（在“密码”App 中搜索“Ostler”）"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Safari 扩展已安装到 %s"
MSG_OK_SAFARI_EXTENSION_PAIRED="Safari 扩展已与此 Hub 配对"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="安全设置已在之前的运行中配置完成。"
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="安全模块已安装到 venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="已在 %s 中写入新的 JWT_SECRET"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="已在 %s 写入 PWG 服务令牌"
MSG_OK_SEEDED_EXTENSION_TOKEN="已在 %s 写入浏览器扩展密钥"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="服务已启动（Qdrant :6333, Oxigraph :7878, Redis :6379）"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  已准备搜索集合：%s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="暂时无法准备 %s 搜索集合；下方的数据导入会重试，如果仍然无法准备，将停止而不会丢弃你的数据。"
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="搜索索引尚未在预期时间内就绪；下方的数据导入会等待其就绪并准备集合，如果存储仍未就绪，将停止而不会丢弃你的数据。"
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="你的数据未被导入。无法准备好搜索存储来容纳这些数据（缺少：%s），若仍继续导入，数据会被悄无声息地丢弃。没有任何数据丢失。请在这台电脑空闲时重新运行安装程序，或设置 OSTLER_QDRANT_READY_WAIT_S 以延长等待时间。"
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="你的数据导入处理了 %s 条记录，但一条也未存储；搜索存储拒绝了所有记录，结果会是一个被当作完整呈现的空知识图谱。因此已停止，而不是向你展示这样的结果。请在这台电脑空闲时重新运行安装程序。"
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="无法读取导入本身的日志，因此无法检查你的数据是否确实已写入。这并不表示导入失败，也不表示导入成功。"
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="已禁用接通电源时的睡眠，保留电池供电时的睡眠，已启用网络唤醒"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="已禁用睡眠，已启用网络唤醒"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale 已安装"
MSG_OK_TAILSCALE_INSTALLED="Tailscale 已安装完成"
MSG_OK_TAILSCALE_ENV_PERSISTED="Tailscale IP 已保存到 .env – 你 iPhone 上的 Ostler app 将在首次启动时使用它。"
MSG_OK_TAILSCALE_IP="Tailscale IP：%s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Tailscale 后台服务已启动（用户空间模式，无系统扩展）"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="无法启动 Tailscale 后台服务。你可以稍后在“设置”中重新运行设置。"
MSG_INFO_TAILSCALE_SIGN_IN_URL="正在打开浏览器以登录 Tailscale：%s"
MSG_INFO_TAILSCALE_SERVE_PORT="已在你的 tailnet 上开放 Hub 端口 %s"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="无法在你的 tailnet 上开放 Hub 端口 %s；局域网之外的访问可能受限"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="现在可以在你自己的设备上通过 %s 阅读你的 Wiki – 以你的身份登录，仅限你本人。"
MSG_INFO_WIKI_TAILNET_OWNER="Wiki 访问仅限你的 Tailscale 账户（%s）。你的 tailnet 上的其他人会收到 403。"
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="你的 Wiki 仅保留在这台 Mac 上。打开 Ostler，在边栏中选择“Wiki”即可阅读。"
MSG_INFO_WIKI_TAILNET_BANNER="%s（从你自己的设备通过 Tailscale 访问。这是唯一会要求你使用上述登录信息的途径。）"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="在 Ostler app 中。打开 Ostler，在边栏中选择“Wiki”；你的页面就在那里，已经登录。"
MSG_INFO_WIKI_INTERNAL_ADDRESS="Ostler 从这台 Mac 上的 http://localhost:8044 获取这些页面。该地址仅供内部使用，上面没有需要你登录的内容。"
MSG_INFO_WIKI_SIGN_IN="你的 Wiki 登录名是 %s，密码是 %s。Ostler 会替你提交，因此在这台 Mac 上无需输入任何内容；只有当你通过 Tailscale 从自己的其他设备打开 Wiki 时，才需要亲自使用它。"
MSG_INFO_WIKI_SIGN_IN_WITHHELD="你的 wiki 登录名是 %s。密码不会写入此日志，而是在你的剪贴板中，也保存在下方所列的文件里。Ostler 会替你填入密码，因此无需在这台 Mac 上输入任何内容。"
MSG_INFO_WIKI_PORT_LAST_STATUS="wiki 端口返回的最近一次 HTTP 状态：%s（000 表示没有任何响应；403 表示已响应但拒绝了凭据）。"
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="你的密码也保存在 %s，因此剪贴板不是唯一的副本。"
MSG_INFO_WIKI_STILL_BUILDING="仍在构建中。磁盘上已有 %s 个页面，wiki 地址最近一次返回的是 HTTP %s。它会自动出现在 Ostler app 中，你无需做任何事。"
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="首次构建尚未生成任何页面（见上方警告）。构建完成后，你的 wiki 仍可在 Ostler app 中打开，上方的登录信息依然属于你。"
MSG_INFO_WIKI_READINESS_NOT_MEASURED="本次运行未检测 wiki 是否已开始提供服务，因此不做任何判断。无论如何，你的 wiki 都可在 Ostler app 中打开，上方的登录信息依然属于你。"
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="无法确认这台 Mac 属于哪个 Tailscale 账户，因此 wiki 尚未在你的 tailnet 上公开。它仍可在这台 Mac 上使用，位于 Ostler app 的“Wiki”下。"
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="无法在你的 tailnet 上发布 wiki；它仍可在这台 Mac 上使用，位于 Ostler app 的“Wiki”下。"
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="无法重新加载 wiki 访问网关，因此 wiki 尚未在你的 tailnet 上公开。"
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="%s 已开启 Tailscale Funnel。Funnel 会发布到公共互联网。Ostler 从不开启 Funnel，你的 wiki 也会拒绝 Funnel 流量，因此 Ostler 的任何内容都不是公开的 – 但如果你并非有意开启，请在 Tailscale 管理控制台中为这台设备将其关闭。"
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="已安装第三方版权声明（来源：%s）"
MSG_OK_USER_FACING_TREE_READY="用户目录结构已就绪"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="改用“Ostler”文件夹/标签。"
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane 运行正常（本地网页搜索）"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane 正在 http://localhost:3000 运行（与你本地的 Ollama 通信）"
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="WhatsApp connector will be enabled (consent recorded)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="首日 wiki 补充更新 LaunchAgent 已加载（前几个小时内每 30 分钟重建一次你的 wiki，之后停止）"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="仍在合并重复的联系人 – 通讯录较大时可能需要几分钟（已用时 %s 秒）"
MSG_INFO_DEDUPE_MERGED="重复的联系人已合并"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="对于这么大的通讯录，合并重复联系人需要一些时间。安装后它会在后台继续进行 – 完成后你的 wiki 会自动更新。"
MSG_WARN_DEDUPE_INCOMPLETE="全图去重过程未能顺利完成（见 %s）；继续安装"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="重复的联系人已在安装期间全部合并，无需后台补充处理"
MSG_OK_DEDUPE_CATCHUP_LOADED="后台联系人去重 LaunchAgent 已加载（安装后继续合并重复项，然后停止）"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="无法加载后台联系人去重 LaunchAgent。重复项仍会由每日维护流程合并，只是需要更长时间才能处理完毕。"
MSG_OK_ENRICH_AGENT_LOADED="后台充实 LaunchAgent 已加载（补全你的电影、地点、图书和链接的详细信息；将在接下来一天左右分批运行）"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="无法加载后台充实 LaunchAgent。你的偏好已保存且可搜索，只是在其运行之前会缺少额外的参考信息（导演、演员、地点）。"
MSG_OK_DERIVE_AGENT_LOADED="\"What you like\" agent loaded (works out your tastes from your saved preferences on this Mac, every few hours; nothing leaves your Mac)"
MSG_WARN_DERIVE_AGENT_LOAD_FAILED="\"What you like\" agent could not be loaded. Your preferences are saved and searchable; the What you like page will stay empty until it runs."
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="wiki 重新编译 LaunchAgent 已加载（标签 com.creativemachines.ostler.wiki-recompile）"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="wiki 重新编译脚本已随安装程序打包"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="wiki 重新编译脚本已从 %s 克隆"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="正在设置你的“头版”（每小时刷新）"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="“头版”生成程序已随安装程序打包"
MSG_OK_EDITOR_FRONTPAGE_LOADED="“头版”LaunchAgent 已加载（标签 com.creativemachines.ostler.editor-frontpage）"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  首次刷新现在开始；随着 Ostler 读取你的偏好，仪表板上的“头版”会逐渐丰富。"
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  日志：%s/editor-frontpage.log 和 editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="此安装程序中未找到“头版”生成程序；仪表板上的“头版”将不会刷新。"
MSG_WARN_EDITOR_FRONTPAGE_FAILED="“头版”LaunchAgent 安装失败。请查看上方输出；其余安装不受影响。"
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="正在设置你的“头版”补充更新"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="“头版”补充更新 LaunchAgent 已加载（每 5 分钟检查一次，直到读取完你的兴趣，然后停止）"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="无法加载“头版”补充更新 LaunchAgent。你的“头版”以及 Ostler 对你兴趣的了解将改为在下一次每小时刷新时逐步补全。"
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="跳过“头版”补充更新：未安装“头版”刷新，因此没有可重新运行的内容。"
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki 运行于 http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="你的 Wiki 已准备就绪，可以浏览了。Ostler 正在后台撰写页面摘要，接下来一小段时间内会逐步补全。你可以立即开始使用 Wiki。"
MSG_OK_YOUR_ASSISTANT_CALLED="你的助手名为 %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="安装程序已捆绑个人情境摘要脚本"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="个人情境摘要 LaunchAgent 已加载（标签 com.creativemachines.ostler.context-refresh）"
MSG_INFO_CONTEXT_REFRESH_LOGS="  日志：%s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="正在复用 %s 处现有的 context-refresh 安装"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="未捆绑个人情境摘要脚本；助手将仅依赖实时查询（没有常驻的情境摘要）"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="个人情境摘要 LaunchAgent 未能加载，请查看 context-refresh.err。助手仍可通过实时查询作答"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="已克隆的知识服务源码缺少打包配置，因此未能设置其环境。"
MSG_WARN_BUNDLE="  软件包：%s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s 仅支持 Apple 芯片（检测到：%s）。"
MSG_WARN_CM042_DOWNLOAD_FAILED="无法下载 Ostler RemoteCapture v%s（来源：%s）"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="常见原因：版本标签尚未发布、网络离线，或上游公证仍在进行。请在版本正式发布后重新运行安装程序。"
MSG_WARN_CM042_EXTRACT_FAILED="无法解压 Ostler RemoteCapture 压缩包，正在跳过 LaunchAgent。"
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Ostler RemoteCapture LaunchAgent 加载失败。请查看上方输出和 ~/Library/LaunchAgents/。"
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  对话增强功能将不可用。Ostler 的其余部分会正常安装；如需接入对话记忆引擎，请不带 --allow-plaintext 重新运行。"
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="对话记忆引擎安装失败（克隆）。"
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  查找路径：%s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  这通常表示构建安装程序 .app 时没有"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  将内置的 cm048_pipeline 软件包打包进"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/。请重新下载安装程序，或"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  使用 --allow-plaintext 重新运行以进行开发/CI 安装。"
MSG_WARN_CM048_PIPELINE_NOT_FOUND="未找到对话记忆引擎。没有它，对话增强功能无法运行。"
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="已跳过对话记忆引擎设置（--allow-plaintext）。"
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="已找到对话记忆引擎源码，但缺少 pyproject.toml；已跳过 venv 设置。"
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Colima 启动失败。正在尝试改用 Docker Desktop……"
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="无法安装 GNU coreutils；耗时较长的步骤将不设时间上限（仍会显示进度行，表明它们在运行）。"
MSG_WARN_COLIMA_START_RETRY="Colima 未能正常启动（Docker socket 尚未就绪）。%s 秒后重试……"
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="常见原因：标签 v%s 尚未发布、网络离线，"
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  consent_cli stderr (first 400 chars):"
MSG_WARN_CONSENT_DISPLAY_LANGUAGE_NOT_RECORDED="Your consent was saved, but not which language it was shown in (details in ~/.ostler/posture/consent-cli-failures.log)."
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  未在 %s 创建控制台脚本；pyproject.toml 可能缺少 [project.scripts] 条目。"
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="由于传入了 --allow-plaintext，继续执行。"
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="继续安装。排查上述错误后，请重新运行 \`ostler-fda\`。"
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="将在不自动填写通讯录名片的情况下继续 – Ostler 会改为询问你。"
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  发送到 iMessage 的对话将静默失败，直到"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="无法更改睡眠设置。请在“系统设置”>“能源”中启用“接入电源时防止自动进入睡眠”。"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="无法更改睡眠设置。请在“系统设置”>“能源”中启用“防止自动进入睡眠”。"
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="无法下载 ostler-assistant v%s（来源：%s）"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="无法从 Takeout zip 中提取 Gmail mbox，正在跳过。"
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="无法解压 ostler-assistant 压缩包，正在跳过 LaunchAgent。"
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="找不到 Tailscale CLI。你可以稍后手动配置。"
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Could not install legal/ consent-strings package; continuing"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="无法安装 LICENSES/ 目录（非致命）。"
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="无法将 ostler_security 安装到 Hub 的 venv 中。"
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="无法安装 THIRD_PARTY_NOTICES.md（非致命）。"
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="无法获取 Doctor 代理（内置版本和克隆均失败）。"
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="找不到 Ostler Doctor 文件。iOS 配对流程需要这些文件（Ostler.app 以 iframe 载入 :8089/pair-ios）。"
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  查找位置：%s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  这通常意味着构建安装器 .app 时没有"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  将内置的 doctor/agent/ 源代码打包到"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/ 中。请重新下载安装器，或"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  使用 --allow-plaintext 重新运行，以进行开发/CI 安装。"
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Doctor 安装已中止：iOS 配对流程需要它。请重新下载安装器，或传入 --allow-plaintext 以进行开发/CI 安装。"
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="无法获取邮件导入脚本（内置版本和克隆均失败）。"
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="无法获取 hub-power 脚本（内置版本和克隆均失败）。"
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="无法获取 wiki-recompile 脚本（内置版本和克隆均失败）。"
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="无法自动打开 Chrome 网上应用店网址：%s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="无法保存 region.json（继续执行，Doctor 会显示相关提示）"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="无法记录恢复密钥已送达。本次运行的摘要仍然正确，但之后的运行可能无法判断，并可能再次发出警告 – 这是此情况下较安全的失败方式。"
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="Your recovery key was not saved to Keychain. Write it down and keep it somewhere safe, away from this Mac."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="无法自动启动 Ollama。"
MSG_FAIL_OLLAMA_PORT_IN_USE="另一个程序已占用端口 11434，而 Ostler 的本地 AI 需要使用该端口。Ostler 无法启动自己的副本，因此安装在此停止，而不是只完成一半。

  占用端口的程序：%s
  具体错误见：%s

这通常是你之前已有的 Ollama，或是之前的 Ostler 安装遗留的运行实例。请退出它（或重新启动这台 Mac），然后再次运行安装器。"
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="无法更新流水线（是否离线？）"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="无法写入 pipeline_signals.json。在下次安装或定时检查之前，Doctor 的“邮件为空”诊断将使用安全的默认值。"
MSG_WARN_CURL_SAID="Curl 返回："
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="未找到目录：%s，已跳过导入。"
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker 未在 %s 秒内启动。"
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker 已安装但未运行，需要启动它。"
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="这台 Mac 上有 Docker 命令，但背后没有任何运行中的引擎。在 macOS 上，Docker 命令只是客户端，需要 Colima 或 Docker Desktop 这样的引擎才能真正运行内容。安装器会为你设置一个。"
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="容器运行时诊断：docker 客户端：%s | colima:%s | Docker Desktop:%s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="wiki 容器已启动，但在 60 秒内 http://localhost:8044 没有任何响应。请将 wiki 视为未运行，启动命令的退出代码并不能证明页面可以加载。"
MSG_WARN_WIKI_NOT_RESPONDING="你的 wiki 没有响应（127.0.0.1:8044）。它在容器中运行，所以这通常意味着容器运行时已停止。请打开 http://localhost:8089/doctor 上的 Ostler Doctor 查看原因。"
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama 安装到一半时卡住，导致就绪探测挂起。"
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  早期标记（通道仍在连接，且 Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="电子邮件导入 LaunchAgent 安装失败。请查看上方输出。"
MSG_WARN_IMESSAGE_BRIDGE_FAILED="iMessage 桥接 LaunchAgent 安装失败。在你重新运行安装程序或手动运行 INSTALL_SNIPPET.sh 之前，助手用户的 iMessage 回复将无法使用。"
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="iMessage 桥接脚本未随包提供，且已传入 --allow-plaintext；将跳过 LaunchAgent 安装。助手用户的 iMessage 回复将无法使用。"
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="加密将无法使用。"
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="加密将无法使用，并且"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="请确保固定的 PWG_KNOWLEDGE_REPO 标签包含它。"
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  事件权限，针对“信息”App）。"
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="FDA 提取程序以非零状态退出（%s）。输出的最后 20 行："
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="此安装程序未包含 FDA 提取模块。"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="应位于：Contents/Resources/ostler_fda/（.app 内部）。"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="最可能的原因：构建回归导致第三方副本丢失。请从 ostler.ai/install 重新下载 .app。"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="FDA 提取模块未随包提供。因已传入 --allow-plaintext 而继续 – 将跳过即时数据提取。"
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="数据提取模块已在磁盘上，但其依赖项未能安装，因此无法加载："
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="因已传入 --allow-plaintext 而继续 – 每次运行时，定时数据刷新都会失败。"
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault 未启用。"
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="目前无法激活首月免费；安装将继续。配对后，请在 iPhone 上打开 Ostler app 以解决此问题。"
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="“终端”未获得“完全磁盘访问权限”。"
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="检测到 %s GB 内存。你将使用精简版助手（gemma4:e2b）：可靠、准确，简短问题可在一秒内响应，支持工具调用，并在不知道时坦诚回答“我不知道”。若想在较长问题上获得更丰富的回答，24 GB 或更大内存可解锁标准版助手（qwen3.5:9b）。你之后可以通过重新安装来更换 Mac。"
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="GDPR 导入出现错误。你可以使用以下命令重新运行："
MSG_WARN_GRAPH_DB_PULL_RETRY="数据库下载未完成（第 %s 次尝试，共 %s 次）。%s 秒后重试..."
MSG_WARN_GRAPH_DB_UP_RETRY="知识图谱数据库未能启动（第 %s 次尝试，共 %s 次）。正在重试..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="GDPR 导入是正式安装的一部分。没有它，你的社交图谱（LinkedIn、Facebook、Instagram、WhatsApp、Twitter、Google 日历）将无法导入。"
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="在重新安装导入流程之前，此实例上的 GDPR 导入将不可用。"
MSG_WARN_GIT_SAID="Git 返回："
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  健康检查失败：ostler-knowledge --version 没有输出。"
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  健康检查失败：对话记忆引擎无法加载（pwg-convo 或其流程导入未能正常返回）。"
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="Homebrew 安装程序已退出，状态 %s。%s 的最后 30 行如下："
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Homebrew 安装日志（末尾）---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="Doctor 的 pip 安装已退出，状态 %s。%s 的最后 30 行如下："
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Doctor pip 安装日志（末尾）---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="流程的 pip 安装已退出，状态 %s。%s 的最后 30 行如下："
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- 流程 pip 安装日志（末尾）---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Hub 电源 LaunchAgent 安装失败。请查看上方输出。"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="在预期的包路径下未找到 Hub 电源脚本。"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  安装程序 .app 似乎缺少 vendor/hub_power/"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  （位于 Contents/Resources/hub-power/ 中）。将不会安装电池感知节流；其余安装将继续。"
MSG_WARN_ICAL_SERVER_FAILED="无法启动助手 API；在下次运行安装之前，iPhone 上的 Ostler app 将只有有限的访问权限。"
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - 镜像拉取失败（网络、磁盘空间或镜像仓库超时）"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="无法将 iMessage 的“完全磁盘访问权限”信号写入 pipeline_signals.json。Doctor 仪表盘可能不会自动显示“完全磁盘访问权限”卡片。"
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="IMAP 主机为空，请重试。"
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="iMessage 自动化权限：未授予（-1743）。"
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="iMessage 自动化权限：检测结果不确定。"
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="无法读取 iMessage 历史记录（chat.db）：Ostler 守护进程尚未获得“完全磁盘访问权限”。在你于“系统设置”>“隐私与安全性”>“完全磁盘访问权限”中授权之前，读取 iMessage 历史记录将保持关闭。"
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="正在打开“系统设置”>“隐私与安全性”>“自动化”。请勾选 OstlerInstaller（或“终端”）下的“信息”一行，以启用 iMessage 投递。"
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="不是完整的电子邮件地址，已忽略：%s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="请至少输入一个完整的电子邮件地址（例如 you@example.com）。"
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage 至少需要一个允许的联系人。请重试或"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="导入管线不可用（私有仓库，仅限测试版用户）。"
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="安装程序未内置导入管线。已绕过强制失败。"
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="安装程序未内置导入管线。这是产品化的安装路径；contact_syncer Python 包应随 .app 包一同提供。"
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX 表示助手将读取你收到的每一封电子邮件。"
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - 磁盘空间不足，无法容纳 wiki 输出卷"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="检测到 Intel Mac，性能将受限。建议使用 Apple 芯片。"
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s 是云服务提供商的主机。"
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="%s 中的 JWT_SECRET 在禁用列表中；正在重新生成，以确保知识图谱服务可正常导入"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="%s 中的 JWT_SECRET 太短（%s < %s 个字符）；正在重新生成"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="知识仓库已克隆，但缺少 pyproject.toml；已跳过 venv 设置。"
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="知识服务安装失败（克隆）。"
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="许可：%s 采用 Google 的 Gemma 使用条款发布，而非 Apache 2.0。"
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="MacBook 部署需要此项来处理电池和睡眠。"
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="macOS“通讯录”权限已被拒绝或尚未授予。"
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS 不会通过脚本提示授权，你必须手动授予。"
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Mac mini 部署不受影响；MacBook 用户应重试。"
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="邮件数据仍可手动导入："
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  手动重试：cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  原因解决后可手动重试："
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="未选择 Apple Mail 或自定义 IMAP，默认使用 Apple Mail。"
# NEEDS REVIEW: "passkey" here likely means the encryption passphrase; 通行密钥 is Apple's WebAuthn passkey term. Confirm intended meaning (maybe 密码短语).
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="未设置通行密钥；数据库将不会被加密。"
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="之前的一次安装生成了你的恢复密钥但未能完成，因此从未向你显示。该密钥无法找回，因为它不会存储在任何地方，包括此处。"
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="你的密码短语仍然有效，目前没有任何内容被锁定。但如果你忘记密码短语，目前将无法重新进入。"
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="请联系支持人员重新设置安全功能，届时会向你显示一个新的恢复密钥，请妥善保管。"
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="两次输入的密码短语不一致，请重试。"
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="密码短语设置失败。输出："
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="输入为空。已跳过密码短语。"
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="密码短语至少需要 12 个字符，请重试。"
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="需要设置密码短语才能加密你的数据。"
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="这不是国际号码。请以 + 开头，后接国家或地区代码和其余号码，例如 +447700900123。请重试。"
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama 无响应"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s 失败（第 %s/3 次尝试）。将在 %s 秒后重试..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="仅有 %s GB 可用空间。建议至少预留 35 GB（Docker 镜像、AI 模型和数据）。"
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="使用电池供电时，Hub 电源 LaunchAgent（步骤 3.14）可能会暂停"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="或重新运行安装程序，并选择其他渠道。"
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="或领先于 Phase B 的发布流程。请在以下条件满足后重新运行安装程序："
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor 报告了 %s 个错误。"

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="Ostler 已完成，但安装过程中出现了 %s 个错误。"
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  完整详情见 ~/.ostler/logs/install.log。Ostler 仍会启动；请打开 Doctor 查看需要处理的事项。"
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="Ostler 已完成，但有 %s 个安装步骤未能顺利完成：%s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="Ostler 已完成，安装过程中没有出现错误。"

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant 已解压，但 --version 检查失败。"
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Ostler 助手 LaunchAgent 安装在 3 次尝试后失败。诊断输出见上方和下方。"
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Ostler 助手 LaunchAgent 第 %s 次安装尝试失败；正在重试。"
MSG_WARN_ASSISTANT_ERR_LOG_PATH="守护进程完整 stderr 位于：%s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="stderr 最后片段："
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s 仅支持 Apple 芯片（检测到：%s）。"
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  无法将加密存储依赖项安装到对话记忆 venv 中；对话增强将不会运行。"
MSG_INFO_COACH_DB_READY="  Coaching database ready, encrypted: %s"
MSG_WARN_COACH_DB_NOT_CREATED="  Could not prepare the encrypted coaching database (it will be created on the first coaching note): %s"
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  在 SCRIPT_DIR 中未找到加密存储依赖项源文件；对话记忆引擎无法加载，对话增强将不会运行。"
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - ostler-wiki-compiler 镜像暂时无法拉取（镜像仓库尚未接入）"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph 无响应"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph 在此阶段尚未正常运行（请查看上方日志）"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="密码不一致（或为空）。请重试。"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="主要安装通常需要 45 分钟到数小时（Docker 和 Ollama 下载以及首次设置），网速较慢或 Mac 上有多年历史数据时会更久。长时间没有动静是正常的 – 它正在后台下载和设置，并没有卡住。"
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  pip 安装失败；对话记忆引擎将不可用。"
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  pip 安装失败；email-ingest 将回退到系统 python（运行时也可能失败）。"
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  pip 安装失败；ostler-knowledge 将不可用。"
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  pip 安装失败；邮件导入引擎不可用。每小时运行的 LaunchAgent 仍会生成 mbox 文件，但在修复之前无法将其导入图谱。"
MSG_WARN_CM021_SOURCE_NOT_FOUND="在应用包中未找到邮件导入引擎源文件；每小时的后台任务将保存邮件文件，但不会导入。"
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="在应用包中未找到 ostler_fda 源文件；email-ingest LaunchAgent 将在运行时回退到系统 python。"
MSG_WARN_PIP_SAID="pip 输出："
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="请接入交流电源以完成完整安装。"
MSG_WARN_PORT_1_ALREADY_USE_PID="端口 %s 已被 %s 占用（PID %s）"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - 端口 3000 已被其他服务占用"
MSG_WARN_POWER_SOURCE="电源：%s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="sqlcipher3 安装失败。"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="sqlcipher3 安装失败。数据库将不会加密。"
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="未找到 Python 3。正在安装 Python 3.12..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s 版本过旧（需要 3.10+）。正在安装 Python 3.12..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant 无响应"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         商用前请阅读 https://ai.google.dev/gemma/terms。"
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="请阅读公开版本：https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis 无响应"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="待新版本发布，或手动放置二进制文件："
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="正在重新运行 – 请输入自托管主机，或按 Ctrl-C 后重新启动并选择 Apple Mail。"
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="请取消勾选 iMessage 后重新运行安装程序，以跳过该项。"
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="正在使用 --allow-plaintext 运行：加密已停用。不适用于生产环境。"
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  首次启动后请运行 \`%s doctor\`"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="登录后运行 'tailscale ip --4'，然后将该地址添加到 iOS 应用中。"
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Safari 扩展复制失败；你可以稍后手动安装"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="Safari 扩展已安装，但没有可用于配对的扩展令牌；在你重新运行安装程序之前，浏览记录采集将保持关闭"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="无法将 Safari 扩展与此 Hub 配对；在你重新运行安装程序之前，浏览记录采集将保持关闭"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="未找到安全模块。将跳过通行密钥设置。"
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  查找位置：%s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  这通常意味着安装程序 .app 在构建时没有"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  将内置的 ostler_security 软件包打包到"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/ 中。请重新下载安装程序，或"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  使用 --allow-plaintext 重新运行以进行开发/CI 安装。"
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="安全设置失败。将在没有数据库加密的情况下继续。"
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="安全设置失败。输出："
MSG_WARN_SEE_STDERR_FRAGMENT="  stderr 片段请见 %s。"
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="正在跳过二进制文件安装。向导写入的 config.toml 将保持不变。"
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="正在跳过 Doctor LaunchAgent 安装。"
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="正在跳过邮件导入 LaunchAgent 安装。"
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="正在跳过 LaunchAgent 安装。Mac Mini 部署不受影响。"
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="正在跳过 LaunchAgent 安装。请尝试：%s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="正在跳过 wiki 重新编译 LaunchAgent 安装。"
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="部分端口已被占用。Docker 容器可能无法启动。"
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="端口 %s 已被 %s（PID %s）占用，该程序属于此账户。请退出它，然后重新运行安装程序。"
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="端口 %s 已被此 Mac 上另一个用户账户的程序占用。Ostler 无法共用该端口，强行启动可能会混淆两个账户的数据。请让另一个账户退出登录，或在仅由 Ostler 所在账户使用此端口的 Mac 上安装 Ostler。"
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="Ostler 无法启动其数据库，因为所需的端口已被占用。"
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="请停止占用上述端口的程序，然后重新运行安装程序。"
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="无法检查端口 %s 是否空闲。这不代表该端口是空闲的。"
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="有一项或多项端口检查未能运行，因此无法排除与其他程序冲突的可能。"
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="无法在此 Mac 上运行最可靠的端口检查，因此下面的检查不如平常全面。"
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="Ostler 无法确认这些端口是否空闲，也不会在未检查的端口上启动其数据库。请附上你的安装日志并联系支持团队。"
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="无法移除过期的 Colima 启动项。重启后你的 wiki 可能无法加载；请联系支持团队。"
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="请停止冲突的服务，或在 docker-compose.yml 中更改端口"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscale 在 3 分钟内未完成登录。你可以稍后在“设置”中再回来完成。"
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="Tailscale IP 已写入 .env，但随后的读取未能找到它。你 iPhone 上的 Ostler app 可能无法获取它。如果出现这种情况，请重新运行 install.sh --repair。"
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="无法保存你的远程访问选择，因此下次重新安装时会再次询问你。其他一切不受影响。"
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="Tailscale 安装失败。你可以稍后在 tailscale.com 安装它"
MSG_WARN_TAILSCALE_STATE_UNREADABLE="这台 Mac 上有无法读取的现有 Tailscale 设置，因此我们无法判断它是否仍连接到你的网络。请在下方选择。如果它已连接，再次设置也无妨。"
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="没有它们，已部署的服务将拒绝启动。"
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  直至此问题解决。请参阅后续步骤横幅了解修复方法。"
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  以进行检查。cron-delivery / imessage-tcc 是常见原因"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  请尝试：docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  请尝试：docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="无法识别的选项“%s”；默认使用 iMessage + 电子邮件。"
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="无法识别的选项。将使用“推荐”。"
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  更新失败；将继续使用现有的检出内容。"
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="该账户请使用 Apple Mail（见上方推荐）。Ostler 绝不会存储云端密码。"
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="正在使用 INBOX。助手将读取每一封收到的电子邮件。"
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="Vane 容器已启动，但 http://localhost:3000 在 60 秒内没有响应。"
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane（本地网络搜索）启动失败。常见原因："
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  网络搜索是可选功能；没有它，Ostler 的其余部分仍可正常使用。"
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="我们强烈建议改用专用的标签/文件夹。"
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp 需要一个电话号码来发送简报。请重试，"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="Wiki 已编译，但 wiki-site 容器启动失败。"
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="Wiki 首次编译失败。常见原因："
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="首日 Wiki 补全 LaunchAgent 无法加载。每日 Wiki 重建仍会运行；你的 Wiki 只是会在次日刷新，而不是在一小时内刷新。"
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Wiki 重新编译 LaunchAgent 安装失败。请查看上方输出。"
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="Wiki 不会自动更新；仍可手动重建："
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="向导配置保持不变；二进制文件仍已暂存。手动重试："
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="你的助手需要一个名字。请从上方建议中选择，或输入你自己的名字。"
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="你可以在“系统设置”>“隐私与安全性”>“通讯录”中重新授予权限。"
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="你可以稍后运行安全设置：python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="你可能需要手动安装：%s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  实际值：%s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="解压后，在 %s 未找到 Ostler RemoteCapture 包。发布的压缩包可能已损坏。"
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="无法创建或访问 %s，因此 Ostler RemoteCapture 没有可安装的位置。这是文件夹权限问题，与下载无关。"
MSG_ERR_CM042_RENAME_FAILED="Ostler RemoteCapture 已正确下载并解压，但无法移动到 %s。解压后的 App 已保留在 /Applications 中。这不是签名问题。"
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify 报告："
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  拒绝暂存与已发布校验和不匹配的包。"
MSG_ERR_CM042_SHA_256_MISMATCH="Ostler RemoteCapture 压缩包 SHA-256 不匹配。"
MSG_ERR_CM042_PIN_FAILED="Ostler 无法确认此次下载的 RemoteCapture 真实可靠，因此未安装。"
MSG_ERR_CM042_VERSION_UNKNOWN="此 RemoteCapture 版本不是 Ostler 可识别的版本，因此未安装。"
MSG_ERR_CM042_SIDECAR_DISAGREES="此 RemoteCapture 下载附带发布的校验和与文件不匹配，因此未安装。"
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess 报告："
MSG_ERR_CM042_VERIFY_FAILED="Ostler RemoteCapture 签名/公证验证失败。"
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv 报告："
MSG_ERR_EXPECTED="  预期：%s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief 报告：%s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="位于 %s 的 ostler-assistant 二进制文件不是 Mach-O 可执行文件。"
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="ostler-assistant 压缩包的 SHA-256 不匹配。"
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  拒绝暂存与已发布校验和不一致的二进制文件。"
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="拒绝移除隔离属性或加载 LaunchAgent。"
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="上游压缩包修复后，请重新运行安装程序。"
MSG_ERR_URL="  网址：%s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="不支持 Intel 版 Mac。Ostler 需要 Apple 芯片（M1、M2、M3 或 M4）。"
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="至少需要 16 GB 内存。你的 Mac 为 %s GB。建议 24 GB。"
MSG_FAIL_CM042_SIGNATURE_FAILED="Ostler RemoteCapture 安装已中止：签名或公证检查失败。该安装包已保留在 /Applications 中以供支持人员查看。请发送邮件至 support@ostler.ai，并重新运行安装程序。"
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="尝试 3 次后仍无法拉取 %s。请检查网络，然后重新运行安装程序。"
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="尝试 3 次后仍无法拉取 nomic-embed-text。请检查网络，然后重新运行安装程序。"
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker 不可用。请重新运行安装程序以安装 Colima。"
MSG_FAIL_CONTAINER_CLIENT_MISSING="这台 Mac 上没有 docker 命令，因此 Ostler 无法启动所需的服务。请重新运行安装程序；如果再次失败，请将日志发送给我们，日志位于 %s。"
MSG_FAIL_CONTAINER_ENGINE_ABSENT="Ostler 需要容器运行环境，但这台 Mac 上没有任何容器运行环境响应。你的维基、知识图谱和搜索索引都在容器中运行，因此安装在此处停止，而不是在缺少这些组件的情况下完成。修复方法：打开“终端”并运行 'colima start'，然后再次运行此安装程序。如果你使用的是 Docker Desktop，请打开它，等待鲸鱼图标稳定后再重新运行。完整日志位于 %s。"
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="Docker 未能及时就绪，无法启动知识图谱数据库。请确保 Colima 或 Docker 正在运行，然后重新运行安装程序。"
MSG_FAIL_GRAPH_DB_PULL_FAILED="多次尝试后仍无法下载知识图谱数据库镜像。这通常是网络问题。请检查你的网络连接，然后重新运行安装程序。"
MSG_FAIL_GRAPH_DB_UP_FAILED="知识图谱数据库已下载，但无法启动。请重新运行安装程序；如果问题持续出现，请打开“终端”并运行：cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="Ostler 无法完成对知识图谱数据库的已认证请求。它间隔两秒尝试了两次，均被拒绝。我们目前还不清楚原因：可能是数据库仍在启动，也可能是 Ostler 持有的凭据并非数据库所期望的那一个。你的数据没有被改动。重新运行安装程序通常会成功；即便成功，我们仍希望你告诉我们，请把安装日志发给我们，因为这是我们正在努力复现的故障。"
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="安装包中缺少 FDA 提取模块。请从 ostler.ai/install 重新下载 .app，或在开发/CI 环境中使用 --allow-plaintext 重新运行。"
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="数据提取模块已安装但无法加载，因此后台刷新每次运行都会失败。完整输出已保存到 %s。请重新运行安装程序，联系支持人员时请附上该文件（参考编号：ERR-10-FDA-DEPS-IMPORT）。"
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="内部错误：数据提取模块被放置在应用程序包内部，这会破坏其签名。这是构建故障，并非你的 Mac 出现问题。请从 ostler.ai/install 重新下载 .app（参考编号：ERR-10-FDA-DEPS-UNSAFE-PATH）。"
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Doctor 依赖项安装失败。完整输出已保存到 %s。发送邮件至 support@ostler.ai 时请附上该文件（参考编号：ERR-17-DOCTOR-PIP）。"
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="导入管线依赖项安装失败。完整输出已保存到 %s。发送邮件至 support@ostler.ai 时请附上该文件（参考编号：ERR-14-PIPELINE-PIP）。"
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Homebrew 安装失败。完整输出已保存到 %s。发送邮件至 support@ostler.ai 时请附上该文件。"
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="导入管线安装失败。产品化安装需要 contact_syncer 安装包。请在开发/CI 环境中使用 --allow-plaintext 重新运行，或重新下载安装程序后再试。"
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="需要 sudo 权限来禁用睡眠并安装 Homebrew。准备好后请重新运行。"
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Colima 和 Docker Desktop 均无法启动。请安装 Docker Desktop 后重新运行。"
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="磁盘空间不足（%s GB）。请释放空间后重试。"
MSG_FAIL_MACOS_BELOW_FLOOR="macOS %s 低于 Ostler 支持的版本。Ostler 需要 macOS %s 或更高版本：安装程序是为该版本构建的，在更低版本上无法打开。请更新 macOS，然后再次运行安装程序。"
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="未设置通行密钥，也没有现有的安全配置。请在开发/CI 环境中使用 --allow-plaintext 重新运行，或重新运行安装程序并确认 Touch ID 说明。"
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="需要对话记忆引擎。请在开发/CI 环境中使用 --allow-plaintext 重新运行，或修复上述缺失的安装包后重试。"
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="内置的 Ostler 守护进程（v%s，位于 %s）不支持此安装程序所需的 'run-source' 命令，无法通过“完全磁盘访问权限”来路由数据导入。这是安装包内部的版本不匹配：继续安装会导致所有导入来源悄然失效，产品会在没有任何可见错误的情况下逐渐过时。请从 ostler.ai/install 重新下载 .app 后再试（参考编号：ERR-11-DAEMON-RUN-SOURCE-SKEW）。"
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="ostler_security 安装失败。请在开发/CI 环境中使用 --allow-plaintext 重新运行，或修复上述 pip 错误后重试。"
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="通行密钥设置失败。请在开发/CI 环境中使用 --allow-plaintext 重新运行，或修复上述错误后重试。"
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="加密数据库需要 sqlcipher3。请在开发/CI 环境中使用 --allow-plaintext 重新运行，或修复上述 pip 错误后重试。"
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="此安装程序仅适用于 macOS。"

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="Homebrew 安装报告成功，但找不到 /opt/homebrew/bin/brew。完整记录请查看 %s。恢复方法：打开“终端”，运行 '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"'，然后重新运行安装程序。"
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew 已安装在 /opt/homebrew/bin/brew，但在执行 shellenv 后，'brew' 命令仍不在 PATH 中。请打开新的“终端”窗口，然后重新运行安装程序。"
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' 报告成功，但 PATH 中找不到 colima。请查看 %s 了解 Homebrew 的失败信息。恢复方法：打开“终端”，手动运行 'brew install colima docker docker-compose'，然后重新运行安装程序。"
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' 报告成功，但 PATH 中找不到 docker CLI。请查看 %s。恢复方法：手动运行 'brew install docker'，然后重新运行安装程序。"
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="The Ollama install reported success but its binary is missing. Check %s, then re-run the installer."
MSG_FAIL_OLLAMA_PIN_DOWNLOAD="Could not download Ollama %s. Check your internet connection, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_PIN_SHA256="The Ollama %s download did not match its recorded fingerprint, so it was not installed. This can mean the download was damaged or altered. Re-run the installer; if it happens again, contact support. Details: %s"
MSG_FAIL_OLLAMA_PIN_UNPACK="Ollama %s downloaded but could not be unpacked. Check free disk space, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_AGENT_NOT_PINNED="The local AI service is set to run %s instead of the copy of Ollama this installer verified (%s), so it would not stay on a tested version. The install has stopped. Re-run the installer; if this repeats, contact support. Details: %s"
MSG_FAIL_EMBED_HEALTHCHECK="Ollama 正在运行，但嵌入模型没有返回向量（HTTP 状态不是 200，或结果为空）。这样“人物”卡片、搜索和浏览都将为空。请查看 %s。恢复方法：确保已安装并运行 Ollama 应用（而非 Homebrew formula），然后重新运行安装程序。"
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' 报告成功，但 PATH 中找不到 sqlcipher。请查看 %s。恢复方法：手动运行 'brew install sqlcipher'，然后重新运行安装程序。"
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' 没有生成 /Applications/Tailscale.app。请查看 %s。恢复方法：从 https://tailscale.com/download/macos 下载 Tailscale，将其拖入 /Applications，然后重新运行安装程序。"
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' 报告成功，但在 /opt/homebrew/opt/python@3.11/bin/python3.11 找不到 python3.11 可执行文件。请查看 %s。恢复方法：运行 'brew reinstall python@3.11'，然后重新运行安装程序。"

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="找到了你之前的回答"
MSG_PROMPT_REUSE_SETTINGS_HELP="我们在这台 Mac 上检测到之前的安装尝试。你已回答过的问题（姓名、助手名称、时区、国家/地区代码、渠道等）将被沿用，无需重新输入。选择“是”从上次中断的地方继续，或选择“否”从头重新回答这些问题。"
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="找到的先前回答：姓名 = %s，助手 = %s，时区 = %s。"

MSG_PROMPT_PERMS_OK_TITLE="准备好继续了吗？"
MSG_PROMPT_PERMS_OK_HELP="macOS 会请求“通讯录”以及“文件与文件夹”的访问权限。“完全磁盘访问权限”为可选项，之后也可以授予。"

MSG_PROMPT_USER_NAME_DETECTED_TITLE="全名（与通讯录中的显示一致）"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="全名（例如 Tom Harrison）"

MSG_PROMPT_USER_ID_TITLE="你希望助手怎么称呼你？"
MSG_PROMPT_USER_ID_HELP="助手称呼你时使用的简短名称（例如“Andy”“Andrew”“Smith 女士”）。它会出现在你的早间简报和聊天回复中，与上面的全名不同。"

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
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="这是你的日历。看起来对吗？"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="我们已推测每个日历属于谁，这样你的简报就不会混淆谁的行程是谁的。"
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="已自动搁置，不用于你的简报："
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="你的"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="%s 个事件"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="%s 个事件"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="公共假日"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="生日"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="Siri 建议"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="你订阅的日历"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="提醒事项"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="Include \"%s\" in your brief?"
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="This looks like %s rather than appointments, so we left it out. Switch on if it holds real plans."
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="“%s”是谁的日历？"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="“%s”是哪种日历？"
# NEEDS REVIEW: Option words may be typed answers compared in English; kept English values with Chinese glosses. Developer should confirm.
MSG_CONFIRM_CALENDAR_TYPE_HELP="可选：personal（个人）、work（工作）、family（家庭）、shared（共享）、other（其他）。这决定其中事件的敏感程度如何处理。"
MSG_CONFIRM_CALENDARS_SAVED="已保存你的日历所有者"
MSG_CONFIRM_CALENDARS_FAILED="无法保存日历所有者（不影响继续；你可以稍后设置）"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="我们认为这些资料都是你本人（%s）。要合并为一个吗？"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="这些资料与你有相同的明确身份特征（电子邮件域名、LinkedIn 资料或雇主）。合并后，助手就不会把你自己的历史记录当作几个不同的人。你之后可以撤销。"
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="有人与你同名，但看起来是另一个人（%s）。这是你本人，还是别人？"
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="选择“不是我”可将其保留为单独的人（你的助手绝不会把他们合并到你的资料中）。只有确实是你本人时，才选择“是我”。"
MSG_CONFIRM_IDENTITY_SAVED="已保存身份选择"
MSG_CONFIRM_IDENTITY_FAILED="无法保存身份选择（不影响安装，你可以稍后确认）"

MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="正在后台安装（约需 45 分钟到数小时）"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="使用 +%s？"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="输入国家或地区代码（例如英国为 44，美国为 1）"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="默认国家或地区代码"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="用于在导入通讯录时规范电话号码格式，并设定你所在的地区（英国/欧盟/美国/其他）以采用相应的合规默认设置。"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="检测到 +%s。要用于你的 Hub 吗？"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="根据上方的电话号码检测得出。选择“是”使用该代码，或选择“否”输入其他国家或地区代码。"

MSG_PROMPT_TZ_CONFIRM_TITLE="使用此时区？"
MSG_PROMPT_TZ_CONFIRM_HELP="检测到的时区：%s"
MSG_PROMPT_USER_TZ_TITLE="输入时区（例如 Europe/London、Asia/Hong_Kong）"

MSG_PROMPT_ASSISTANT_NAME_TITLE="你想给助手取什么名字？"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="输入框中的名字是随机建议，你可以改成任何喜欢的名字。Marvin、Samantha、Joshua、Friday、Athena、Sage 和 Rosie 都是热门选择。" # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="可以输入任何你喜欢的名字，建议的名字只是个起点。"

MSG_PROMPT_CHANNEL_CHOICE_TITLE="助手将如何联系你？"
MSG_PROMPT_CHANNEL_CHOICE_HELP="选择你希望助手使用的消息渠道。你可以稍后在 App 的 Doctor 部分更改。"

MSG_PROMPT_WHATSAPP_CONSENT_TITLE="Enable WhatsApp messaging for your assistant?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web is a third-party service. By enabling, you accept that your messages route through WhatsApp's own infrastructure before reaching your local Ostler instance, and that WhatsApp (Meta Platforms Ireland Ltd) may suspend, restrict, or terminate your WhatsApp account because of automated use. You can disable this later from Settings."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="你的 WhatsApp 电话号码"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="带国家或地区代码的国际号码，例如 +447700900123。只能包含数字和开头的 +，不要有空格、括号或短横线。"
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="已存储为 %s。WhatsApp 需要不含空格或括号的号码。"

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="为 Ostler 助手开启“完全磁盘访问权限”"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="“系统设置”已打开“完全磁盘访问权限”。"
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
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="在列表中找到“%s”，并打开其“完全磁盘访问权限”开关。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="列表中没有？请将“%s”从“访达”窗口拖到列表中，然后打开其开关。顺序无关紧要：可在此之前或之后点按“完成”，安装程序会一直等到开关真正打开。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="列表中没有？Ostler 无法为你打开“访达”窗口。请在“访达”中按 ⌘⇧G，输入下方路径，然后将“%s”拖到列表中并打开其开关。顺序无关紧要：可在此之前或之后点按“完成”，安装程序会一直等到开关真正打开。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="App 位于：%s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="App 位于：%s – 此路径已在你的剪贴板中，请在“访达”中按 ⌘⇧G，然后按 ⌘V，再按回车键。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="完成"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="你可以在拨动开关之前或之后点按“完成”，安装程序会一直等到开关真正打开。"

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="允许 Ostler 读取你的 Mac 数据"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="“系统设置”已打开“完全磁盘访问权限”。"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="在列表中找到“OstlerInstaller”并将其打开。"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="完成后点按“完成”,Ostler 将读取你的 Safari 历史记录、“备忘录”、iMessage 信息和“邮件”。"
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="完成"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="下一步：为安装程序开启“完全磁盘访问权限”"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="接下来，macOS 会请你授予 OstlerInstaller“完全磁盘访问权限”。"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="打开开关后，macOS 会弹出一个对话框，让你选择“退出并重新打开”或“稍后”。"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="点按“退出并重新打开”。安装器会自动重新启动，并从这一步继续。"
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="好"
MSG_INFO_INSTALLER_FDA_PREWARN="正在向你说明“完全磁盘访问权限”的授权流程..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="正在打开“系统设置”，以便你为安装器授予“完全磁盘访问权限”..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="已为安装器授予“完全磁盘访问权限”。接下来读取 Safari 浏览器、备忘录、iMessage 信息和邮件。"
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="仍未授予“完全磁盘访问权限”。将在没有该权限的情况下继续；你之后可以重新运行安装器来提取 Safari 浏览器、备忘录和 iMessage 信息。"
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="安装器的“完全磁盘访问权限”已设置好。接下来是耗时较长的部分，大多会自动运行，但请留意 macOS 是否弹出安装开发者工具的对话框，并在接近结束时回来完成几分钟的设置。"
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="还有一项权限（供你的助手读取信息历史记录）会在接近结束、助手安装完成后出现，届时我们会引导你前往设置。"
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="仍需要“完全磁盘访问权限”"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostler 即将读取你的 Mac 数据，但 OstlerInstaller 的“完全磁盘访问权限”仍未开启。请在列表中找到“OstlerInstaller”并将其打开。"
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="或者直接点按“继续”，以较少的数据完成安装。你之后可以授予权限并重新运行提取器。"
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="继续"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="允许的联系人"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="可信任的人：电话号码和 Apple ID 邮箱（用逗号分隔）。%s 只会回复此列表中的人，其他任何人发来的信息都会被忽略。至少需要填写一项。

例如：
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="通过“邮件”读取邮件？"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="使用“完全磁盘访问权限”读取你已添加到“邮件”的任何电子邮件账户（iCloud、Gmail、Outlook 等）。不会存储密码。适合几乎所有人，推荐开启。"

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="向“邮件”添加邮件账户？"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="这台 Mac 上的“邮件”尚未连接任何账户，因此 Ostler 将没有可读取的电子邮件。选择“是”可立即打开“系统设置”>“互联网账户”（你可以在那里添加 iCloud、Gmail 或 Outlook）。选择“否”可跳过；你之后可以再添加账户，如果 24 小时内没有收到邮件，Doctor 会提示后续处理。"

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="拉取完整的“邮件”历史记录？"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="默认情况下，Ostler 会读取你“邮件”中最近五年的内容。如果这台 Mac 上保存的邮件超过五年，并且你希望全部纳入知识图谱，请选择“是”，立即拉取完整的本地历史记录（邮箱较大时可能需要稍长时间）。选择“否”则保留五年范围；你之后随时可以在 Doctor 中扩展。"

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="同时配置自定义 IMAP+SMTP 服务器？"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="仅适用于自建邮箱。如果你的账户使用 Gmail、iCloud 或 Outlook，请保持为“否”，通过上方的“邮件”会更好用。"

MSG_PROMPT_IMAP_HOST_TITLE="IMAP 主机"
MSG_PROMPT_IMAP_HOST_HELP="仅限自建或自定义 IMAP 服务器。Gmail、iCloud、Outlook 请使用上方的“邮件”。"
MSG_PROMPT_IMAP_PORT_TITLE="IMAP 端口"

MSG_PROMPT_SMTP_HOST_TITLE="SMTP 主机"
MSG_PROMPT_SMTP_PORT_TITLE="SMTP 端口"

MSG_PROMPT_EMAIL_USERNAME_TITLE="电子邮件地址（同时用作 IMAP/SMTP 用户名）"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="谁可以给你的助手发邮件？"
MSG_PROMPT_EMAIL_ALLOWED_HELP="你自己的电子邮件地址，用逗号分隔。%s 只会回复此列表中地址发来的邮件，其他任何人发来的邮件都会被忽略。至少需要一个地址。你自己的地址已为你填好，可以修改，也可以再添加一个。"

MSG_PROMPT_EMAIL_PASSWORD_TITLE="密码（已隐藏）"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Password for your self-hosted IMAP/SMTP server. Stored locally in ~/.ostler/secrets/, not in your settings file, and never sent to Creative Machines. It is saved in plain text: the only thing protecting it is the file's permissions, which allow your macOS account and nobody else. Nothing encrypts it later. Use an app password rather than your main account password."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="确认密码"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="助手应该监视哪个文件夹？"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="推荐：使用专用的标签或文件夹（例如 Ostler）。我们只会读取其中的邮件，不会动你的主收件箱。"

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="再次输入 INBOX 以确认，或点按“继续”使用“Ostler”"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX 表示助手将读取你收到的每一封邮件。我们强烈建议改用专用的标签或文件夹。"

MSG_PROMPT_EXPORTS_ACK_TITLE="你已经申请数据导出了吗？"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler imports 18 platform exports. The full list, with direct links to each provider's request page, is at https://ostler.ai/docs/getting-started/data-exports/.

Most archives take 1 to 3 days to arrive by email. When the ZIPs land, drop them in your Downloads folder and Ostler will find them automatically.

Skip any you do not use; you can always import more later."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="在磁盘静态数据【未加密】的情况下继续吗？"
MSG_PROMPT_FILEVAULT_SKIP_HELP="这台 Mac 上的“文件保险箱”（FileVault）已关闭，因此你的磁盘处于未加密状态。

如果继续，这意味着：Ostler 存储的所有内容，包括 ~/Documents/Ostler 下你的整个个人图谱（维基、对话、知识笔记），以及 ~/.ostler 下的服务密钥和数据库，都会以未加密的方式写入磁盘。任何人只要能从这块磁盘启动、把它取出，或者使用一个未锁定的会话，就能读取全部内容。无论如何，Ostler 都会用口令加密其最敏感的数据库，但其余数据的安全程度仅取决于磁盘本身。

强烈建议开启“文件保险箱”。你可以随时在“系统设置”>“隐私与安全性”>“文件保险箱”中开启，它会在后台加密，无需重新安装。

选择“是”，将在磁盘未加密的情况下继续（这是经过深思熟虑、知情的选择，并且会被记录）。
选择“否”，将在此停止，以便你先开启“文件保险箱”，然后重新运行安装程序。无论哪种选择，都没有出错。"

MSG_PROMPT_PASSKEY_ACK_TITLE="准备设置磁盘加密"
MSG_PROMPT_PASSKEY_ACK_HELP="Ostler 的敏感数据库使用 SQLCipher 加密，口令由你在下一个屏幕上设定。每次启动 Hub 界面时，你都需要输入此口令。安装结束时还会生成一个单独的恢复密钥，并仅显示一次。若要为 Mac 上的所有内容提供完整的静态加密保护，请保持 macOS 的“文件保险箱”开启。准备好后，请点按“继续”。"

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="同时设置恢复口令吗？（推荐）"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="选择你的口令"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="此口令用于加密你的知识图谱，并在每次启动时解锁 Hub 界面。至少 12 个字符。我们无法为你找回口令。建议将其保存在密码管理器中。"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="确认你的口令"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="请再次输入相同的口令以确认。"

MSG_PROMPT_IMPORT_CONFIRM_TITLE="安装时导入这些内容吗？"
MSG_PROMPT_IMPORT_CONFIRM_HELP="安装期间，找到的 GDPR 导出数据将被导入你的知识图谱。"

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="Disney+ 导出文件密码"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="Disney+ 的 GDPR 导出文件是一份受密码保护的电子表格，这是正常现象，并不是你的下载出了问题。输入密码即可立即导入你的 Disney+ 观看记录；留空则跳过此项，其他内容仍会照常导入。"

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="你准备好数据导出文件了吗？"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler 可以在一开始就导入社交媒体和各平台的存档，包括你与朋友、家人、地点和观点相关的完整历史。Ostler 第一天了解得越多，第一天就越有用。你也可以稍后再添加，不用着急。

请向各个平台（Twitter / X、Facebook、Instagram、LinkedIn、WhatsApp 等）申请导出你的数据，下载 ZIP 文件，并放入“下载”文件夹。

Ostler 默认会在 ~/Downloads 中查找。想使用其他文件夹？请在下方选择。否则，请跳过，稍后再导入。"

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="从此 Takeout 导入 Gmail 邮件吗？"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="直接从 Takeout 文件中读取 Gmail 内容。Google 不会知道 Ostler 的存在。"

MSG_PROMPT_FDA_PRESET_TITLE="Ostler 应该从 Mac 上的哪些来源学习？"
MSG_PROMPT_FDA_PRESET_HELP="提供三种预设，也可以自行逐项选择。在每种预设中，敏感来源（人脸识别）默认都是关闭的，如需启用请慎重选择。"
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="推荐。包括 Apple Mail、通讯录、日历、备忘录、信息、提醒事项、Safari 历史记录、Safari 书签，以及照片事件（日期和地点，不含人脸识别）。安装了 WhatsApp 桌面版和 Chrome 时，其历史记录会自动加入。不包括照片的人脸识别数据和任何第三方导出存档。"
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="全部。Ostler 在这台 Mac 上能读取的每一个来源。照片的人脸识别在你主动勾选之前保持关闭。"
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="自定。在下一个屏幕上逐项选择来源。敏感来源在你勾选之前保持关闭。"

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="开启或关闭此数据来源。"

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
# Legal: the "English version prevails" line (owner ruling 2026-10-24). install.sh prints it
# before every legal/consent prompt, but ONLY when this line is itself translated
# for OSTLER_LANG, i.e. a native reviewer has passed it (l10n/legal_reviews.tsv).
MSG_LEGAL_ENGLISH_PREVAILS="This is a translation. If it differs from the English version, the English version prevails."
# English prevails over any translation. Legal text stays English in every locale.
MSG_TERMS_LANGUAGE="Language. These terms are written in English. Any translation is provided for convenience only. If a translation differs from the English version, the English version prevails."
MSG_PROMPT_TERMS_PERSONAL_USE_TITLE="Ostler is for personal use"
MSG_PROMPT_TERMS_PERSONAL_USE_HELP="Ostler is licensed for your own personal use on your own Mac. Please do not deploy it to staff or use it at work to capture colleagues, clients or patients. Do not record children without a parent agreeing, and do not record in places where people expect real privacy such as a doctor, solicitor or therapy appointment. Press Continue to accept these terms.

Language. These terms are written in English. Any translation is provided for convenience only. If a translation differs from the English version, the English version prevails."
MSG_INFO_TERMS_PERSONAL_USE_DECLINED="No problem. Nothing has been installed."

MSG_CONSENT_SPOKEN_CAPTURE_HEADING="Turning spoken conversations into text"
MSG_CONSENT_SPOKEN_CAPTURE_INTRO="In short: when you capture spoken audio to transcribe it, getting any consent the law requires is your responsibility, not ours. Typing and messaging are not affected."
MSG_CONSENT_SPOKEN_CAPTURE_LAW="Ostler can turn spoken conversations you capture – calls and meetings – into searchable text; this is only about audio you choose to transcribe."
MSG_CONSENT_SPOKEN_CAPTURE_LOCAL="Ostler transcribes captured audio on the device that captured it and deletes the audio straight away. It is never kept and never sent anywhere, including to your own Mac. That does not remove this duty: you still need consent where your local law requires it."
MSG_CONSENT_SPOKEN_CAPTURE_ASK_HEADING="What we ask of you:"
MSG_CONSENT_SPOKEN_CAPTURE_ASK_1="Obtain whatever consent your local law requires before you capture a spoken conversation."
MSG_CONSENT_SPOKEN_CAPTURE_ASK_2="Make it clear to the people you are with that audio is being captured – for example, say so at the start, or keep a visible indicator on."
MSG_CONSENT_SPOKEN_CAPTURE_ASK_3="If in doubt, leave spoken transcription off. Your text conversations work either way."
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_LABEL="Your decision:"
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_Y="[Y] I understand, and I will obtain any consent my local law requires."
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_N="[N] Not now – keep spoken transcription off. (You can turn it on later in Settings.)"
# ── Spoken-capture legal note, chosen by the Mac's REGION (not its language) ──
# Composed by _ostler_spoken_capture_legal_note in install.sh as
#   "Legal note: " + CORE + LOCAL + the region line(s) + RESPONSIBILITY,
# byte for byte the note the GUI renders, and the note the consent record pins.
# CORE, LOCAL and RESPONSIBILITY show in every region. The region is the country part
# of AppleLocale (zh-Hant_GB is GB), read the same way by the GUI
# (LegalRegion in gui/OstlerInstaller/Steps/ViewCopy.swift), which renders the
# same text from ViewCopy.json consent_spoken_capture.legal_*.
# These are consent / legal keys (l10n legal gate: key carries CONSENT): a
# translation needs human legal review, and English prevails.
# Each REGION line is a BEST-EFFORT DRAFT, NOT LEGAL ADVICE, and NEEDS LOCAL
# PROFESSIONAL SIGN-OFF before it is relied on. Statute numbers appear only
# where the wording predates this change (UK GDPR, StGB 201, French Penal Code
# 226-1) or is certain (PDPO Cap. 486). Any region not listed: CORE only.
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_PREFIX="Legal note:"
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_CORE="Recording laws differ by country, and some require everyone taking part to agree first. Check the law where you are. Ostler never sends your audio anywhere."
# Shown in every region; the GUI twin is consent_spoken_capture.legal_local.
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_LOCAL="Ostler transcribes captured audio on the device that captured it and deletes the audio straight away. It is never kept or sent, including to your own Mac."
# Region GB. Best-effort draft, needs local professional sign-off (UK).
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_REGION_GB="UK GDPR applies: you are the data controller for what you capture, including any special-category data (UK GDPR Article 4(7)). Explicit consent is the lawful basis (Article 9(2)(a)), and for personal and household use Article 2(2)(c) further limits scope."
# Region EU-27 and EEA. Best-effort draft, needs local professional sign-off (EU).
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_REGION_EU="The GDPR applies: you are the data controller for what you capture, including any special-category data (GDPR Article 4(7)). Explicit consent is the lawful basis (Article 9(2)(a)), and for personal and household use Article 2(2)(c) further limits scope."
# Region DE, shown after the EU line. Best-effort draft, needs local professional sign-off (DE).
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_REGION_DE="In Germany, recording the privately spoken word is also regulated by section 201 of the Criminal Code (Verletzung der Vertraulichkeit des Wortes)."
# Region FR, shown after the EU line. Best-effort draft, needs local professional sign-off (FR).
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_REGION_FR="In France, recording words spoken in private without the speaker's consent is also regulated by Article 226-1 of the Penal Code."
# Region HK. Best-effort draft, needs local professional sign-off (HK).
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_REGION_HK="In Hong Kong, the Personal Data (Privacy) Ordinance (Cap. 486) and its data protection principles, such as collecting personal data by lawful and fair means, can apply to what you capture. Hong Kong has no general rule that everyone must agree before you record a conversation you take part in, but that does not make every recording lawful."
# Region US. Best-effort draft, needs local professional sign-off (US).
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_REGION_US="In the US, federal law allows a conversation to be recorded with the consent of one person taking part, but some US states, including California, require everyone's consent. Check the law of the state you and the other people are in."
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL_RESPONSIBILITY="As the person making the recording on this Mac, you are responsible for compliance. Creative Machines never receives your recordings and is not a party to them."

MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_TITLE="Turn spoken conversations into text?"
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_HELP="In short: when you capture spoken audio to transcribe it, getting any consent the law requires is your responsibility. Typing and messaging are not affected.

Ostler can turn spoken conversations you capture – calls and meetings – into searchable text. This is only about audio you choose to transcribe.

What we ask of you:
• Get whatever consent your local law requires before you capture audio.
• Make it clear audio is being captured – say so, or keep a visible indicator on.
• If in doubt, leave this off. Your text conversations work either way, and you can turn it on later in Settings."
# install.sh appends the region-chosen legal note (_ostler_spoken_capture_legal_note)
# to this help text at the gui_read call, so the help carries no legal note itself.
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="语音转写将保持关闭。你可以稍后在“设置”中启用。"

MSG_PROMPT_CONSENT_INSTALL_TITLE="Ready to install?"
MSG_PROMPT_CONSENT_INSTALL_HELP="Please type INSTALL to confirm you accept the terms."
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Type INSTALL"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Install Ostler"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Cancel"
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Type INSTALL exactly (case does not matter) to confirm, or click Cancel to go back."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="连接你的 iPhone 和 Apple Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale 会为这台 Mac 提供一个稳定的私有地址，你的 iPhone 和 Apple Watch 可以在任何地方访问它：全程加密，不公开暴露。"

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="将恢复密钥存储到钥匙串？"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="将你的加密恢复密钥存储在 macOS 钥匙串中妥善保管。"

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="正在填充你的图谱"
MSG_HYDRATE_CONTACTS_STARTED="正在将你的通讯录导入图谱"
MSG_HYDRATE_CONTACTS_DONE="已导入 %s 位联系人"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="导入通讯录耗时超过 %s 秒，因此我们不再等待，先继续下一步。目前已导入 %s 位联系人，Ostler 会在后台完成其余部分。"
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="正在载入你的日历历史（向前五年，向后一年）"
MSG_HYDRATE_CALENDAR_DONE="已导入 %s 个日程"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  仍在加载你的日历（已用 %s 秒）。如果你的 Mac 上有多年的会议记录，需要稍等片刻。"
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="正在根据你开会的地点构建“地点”"
MSG_HYDRATE_PLACES_DONE="已构建“地点”部分"
MSG_HYDRATE_PLACES_SKIPPED="尚未找到位置信号；随着日历内容增加，“地点”会逐渐丰富"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="“地点”构建遇到问题：已有位置信号，但没有生成任何地点。你的“地点”页面可能仍为空。请参阅 %s"
MSG_HYDRATE_PLACES_ERROR_WARN="“地点”构建未完成（意外错误）。你的“地点”页面可能不完整。请参阅 %s"
MSG_HYDRATE_WIKI_RECOMPILE="正在构建你的百科。Ostler 正在为你的每位重要人物、机构和主题撰写简短摘要，因此通讯录较大时，可能需要几分钟到大约一小时。此过程只会进行一次，完全在你的 Mac 上运行，可以放心让它继续运行。"

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="正在检查你的搜索索引（检测到 %s 个集合）"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="正在将你的浏览历史载入搜索索引"
MSG_INITIAL_HYDRATE_QDRANT_READY="搜索索引已就绪（%s 个集合）"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="安装完成后，搜索索引将在后台填充"
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
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="搜索存储已启动；正在创建仍缺少的集合：%s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="搜索索引不完整：尽管搜索存储正在运行并有响应，仍无法创建 %s。Ostler 将继续工作，Doctor 会显示这一缺口，但在修复之前，这部分搜索将保持为空。"
MSG_WARN_QDRANT_COLLECTIONS_MISSING="搜索索引不完整：无法创建 %s。Ostler 将继续工作，Doctor 会显示这一缺口。"
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="无法检查存在哪些搜索集合（%s）。这并不表示它们缺失。"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="安装完成后，搜索索引将在后台填充（正在等待：%s）"
MSG_HYDRATE_DONE="你的图谱已就绪：%s 位人物，%s 个事件"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud 可能仍在同步你的联系人 – 现在重新导出，以获取刚刚到达的内容。"
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="在“通讯录”App 中未找到联系人（本地或 iCloud）。请先在“通讯录”中添加联系人，然后在“设置”中重新运行。"
MSG_HYDRATE_SKIPPED_NO_CONTACTS="没有可导入的 iCloud 联系人。你可以稍后在“设置”中添加。"
MSG_HYDRATE_SKIPPED_NO_EVENTS="过去 5 年内没有日历事件。你可以稍后在“设置”中回填。"

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="正在读取你最近 90 天的邮件 – 你的邮件会保留在这台 Mac 上（更早的历史会在后台回填）"
MSG_HYDRATE_EMAIL_DONE="在你最近的邮件中找到 %s 位联系人"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="没有可读取的近期邮件。你可以在“邮件”中添加邮件账户，稍后重新运行。"
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="邮件读取器尚未就绪。你可以在“邮件”中添加邮件账户，稍后重新运行。"
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="邮件仍在后台加载。你的百科会随之逐步充实，并显示当前进度。"
MSG_HYDRATE_EMAIL_HEARTBEAT="  仍在读取你的邮件（已用 %s 秒）。如果 Mac 上有多年的历史邮件，可能需要一段时间。"

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="要打开“邮件”以开始同步吗？"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="你已配置 %s 个邮件账户，但“邮件”尚未拉取任何邮件。我们现在可以打开“邮件”，并在同步时等待。"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="要打开“日历”以开始同步吗？"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="你已配置 %s 个日历账户，但“日历”中尚未存储任何事件。我们现在可以打开“日历”，并在它从 iCloud 同步时等待。"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="要打开“通讯录”以开始同步吗？"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="你已配置 %s 个通讯录账户，但“通讯录”中尚未存储任何条目。我们现在可以打开“通讯录”，并在它从 iCloud 同步时等待。"

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="正在等待 %s 开始同步（最多 %s 秒）。"
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="仍在等待 %s 同步（已过 %s 秒，剩余 %s 秒）。刚登录时，iCloud 的首次同步可能需要几分钟。"
MSG_OK_APP_HAS_POPULATED="%s 已填充其本地存储。继续。"
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="在等待时间内未检测到 %s 同步。继续；你可以稍后在“设置”中重新运行数据载入。"

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="可见的“邮件”账户：%s。请打开一次“邮件”，以便开始拉取邮件。"
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="可见的“日历”账户：%s。请打开一次“日历”，以便同步你的事件。"
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="可见的“通讯录”账户：%s。请打开一次“通讯录”，以便同步你的通讯录。"

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="无法读取你的“通讯录”。Ostler 通过“完全磁盘访问权限”读取通讯录。请前往“系统设置”>“隐私与安全性”>“完全磁盘访问权限”授予权限，然后在“设置”中重新运行数据导入。我们会在后台继续重试。"
MSG_HYDRATE_CONTACTS_PENDING="你的“通讯录”App 尚未同步。请先打开一次“通讯录”，等待同步完成，然后在“设置”中重新运行数据导入。"
MSG_HYDRATE_CONTACTS_READ_FAILED="你的联系人在这台 Mac 上，但 Ostler 一个都没有导入（0 个），这不符合预期。导入会在后台自动重试。如果问题仍然存在，请在“设置”中重新运行数据导入，或查看安装日志。"
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler 会在后台持续检查，并在 iCloud 同步完成后自动导入你的联系人。"
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="已导入 %s 位带电话号码的联系人，但几乎没有电子邮件地址（电话 %s 个，电子邮件 %s 个）。这通常表示联系人读取器丢失了电子邮件。你的联系人仍可正常使用；请查看 %s，问题解决后在“设置”中重新运行数据导入。"
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="已导入新联系人，正在后台重建你的 wiki。"
MSG_HYDRATE_CALENDAR_PENDING="你的“日历”App 尚未同步日程。请先打开一次“日历”，等待同步完成，然后在“设置”中重新运行数据导入。"
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="这次无法读取你的日历（提取器报告了错误，并非日历为空）。你的其他数据未受影响；请查看 %s，然后在“设置”中重新运行数据导入。"

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="正在读取你的 WhatsApp 历史记录 – 你的消息只保留在这台 Mac 上"
MSG_HYDRATE_WHATSAPP_DONE="在你的 WhatsApp 聊天中找到 %s 位联系人"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="WhatsApp 聊天已读取，但未写入你的人物图谱（退出码 %s）。Ostler 将重试。详情：%s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="没有可读取的 WhatsApp 聊天。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="未安装 WhatsApp Desktop。请从 Mac App Store 安装，然后在“设置”中重新运行。"
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="WhatsApp 读取器尚未就绪。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp 仍在后台加载。你的 wiki 会随之逐步充实，并显示当前进度。"

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
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="你的 WhatsApp 联系人已在人物图谱中（%s 个标识符）。无需重新读取。"
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="你的 WhatsApp 联系人之前已读取过，但人物图谱中已不再包含他们。正在重新读取。"
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="无法确认你的 WhatsApp 联系人是否仍在人物图谱中。将重新读取，而不是假定它们还在。"

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="正在读取你的 AI 聊天历史记录 – 你的对话只保留在这台 Mac 上"
MSG_HYDRATE_AICONV_DONE="已将 %s 个 AI 对话保存到你的 wiki"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="AI 对话读取器尚未就绪。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="没有可读取的 AI 聊天历史记录。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="AI 聊天仍在后台加载。你的 wiki 会随之逐步充实，并显示当前进度。"
MSG_HYDRATE_AICONV_HEARTBEAT="  仍在读取你的 AI 聊天历史记录（已用时 %s 秒）。历史记录较多时可能需要几分钟。"


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="正在导入你的浏览历史记录 – 你的访问记录只保留在这台 Mac 上"
MSG_HYDRATE_BROWSING_DONE="已导入 %s 个浏览历史页面"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="已跳过 %s 个被标记为敏感的页面（银行、医疗等）"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="没有可导入的浏览历史记录。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="浏览历史读取器尚未就绪。你可以稍后在“设置”中重新运行。"

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
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="你的浏览历史记录已导入（%s 个页面）。无需重新导入。"
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="未找到可导入的已导出浏览历史记录。你可以稍后在“设置”中重新运行。"
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="你的浏览历史记录之前已导入，但搜索索引中已不再包含它。正在重新导入。"
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="无法确认你的浏览历史记录是否仍在搜索索引中。将重新导入，而不是假定它还在。"
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="你的浏览历史记录未进入搜索索引，因此“浏览”页面将为空。请在“设置”中重新运行，或打开 Doctor。"
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="浏览历史记录仍在后台加载。你的 wiki 会随之逐步充实，并显示当前进度。"

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="正在加载你的电子邮件偏好。数据只保留在这台 Mac 上，可能需要几分钟。"
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="已从你的电子邮件历史记录中加载 %s 条偏好"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="未配置电子邮件偏好文件。无需加载。"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="在 %s 未找到电子邮件偏好文件。无需加载。"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="偏好处理流程尚未就绪。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="邮件偏好仍在后台加载。你的 wiki 会随加载逐步填充，并显示当前进度。"
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  仍在加载你的邮件偏好（已用时 %s 秒）。历史记录较多时可能需要几分钟。"

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="你的邮件偏好已加载（%s 条）。无需重新加载。"
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="你的邮件偏好之前已加载，但搜索索引中已不再包含它们。正在重新加载。"
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="无法检查你的邮件偏好是否仍在搜索索引中。将重新加载，而不是假定它们仍然存在。"

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
MSG_HYDRATE_PREFERENCES_DONE="已导入 %s 条偏好"
MSG_HYDRATE_PREFERENCES_ENRICHED="其中 %s 条已用公开参考数据进行了丰富"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="已导入 %s 条偏好，但没有任何一条归入“饮食”、“音乐”或“职业”。你的饮食和音乐 wiki 页面将为空。"
MSG_WARN_PREFS_HEADLINE_HINT="这通常意味着没有音乐或饮食导出数据（Spotify、Apple Music、Uber Eats、Google Takeout），或数据未被分类。请添加这些导出数据，在“设置”中重新运行，然后重建 wiki。"
MSG_WARN_PREFS_UNCATEGORISED="%s 条偏好（共 %s 条，占 %s%%）没有分类，不会出现在任何主题页面上。请检查源导出格式。"

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="正在设置偏好丰富功能"
MSG_CM019_SETUP_DONE="偏好丰富功能已就绪"
MSG_CM019_SETUP_FAILED="偏好丰富功能的设置未完成。问题修复后，你的偏好页面会随之填充；Ostler 的其他部分不受影响。"
MSG_CM019_SETUP_SKIPPED="偏好丰富流程未随附，暂时跳过。"

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="正在读取你的 iMessage 历史记录 – 你的信息会保留在这台 Mac 上"
MSG_HYDRATE_IMESSAGE_DONE="在你的 iMessage 历史记录中找到 %s 位联系人"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="没有可读取的 iMessage 历史记录。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="iMessage 读取器尚未就绪。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage 仍在后台加载。你的 wiki 会随加载逐步填充，并显示当前进度。"
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  仍在读取你的 iMessage 历史记录（已用时 %s 秒）。信息历史较多时可能需要几分钟。"

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="你的 iMessage 联系人已在人物图谱中（%s 个标识符）。无需重新读取。"
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="你的 iMessage 联系人之前已读取，但人物图谱中已不再包含他们。正在重新读取。"
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="无法检查你的 iMessage 联系人是否仍在人物图谱中。将重新读取，而不是假定他们仍然存在。"

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="正在读取你的“备忘录”，它们会保留在这台 Mac 上"
MSG_HYDRATE_APPLE_NOTES_DONE="已将 %s 条备忘录添加到你的知识库"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="没有可读取的“备忘录”。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="你的“备忘录”已在知识库中。已跳过。"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="“备忘录”已在知识搜索中关闭。你可以在“设置”中将其打开。"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="知识导入器尚未就绪。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="“备忘录”仍在后台加载。你的知识库会随加载逐步填充，并显示当前进度。"
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  仍在读取你的“备忘录”（已用时 %s 秒）。备忘录较多时可能需要几分钟。"

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="你的“备忘录”已在知识库中（%s 条）。无需重新读取。"
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="你的“备忘录”之前已添加，但知识库中已不再包含它们。正在重新添加。"
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="无法检查你的“备忘录”是否仍在知识库中。将重新添加，而不是假定它们仍然存在。"

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="正在读取你的“提醒事项”，它们会保留在这台 Mac 上"
MSG_HYDRATE_REMINDERS_DONE="已将 %s 条提醒事项添加到你的知识库"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="没有可读取的“提醒事项”。你可以稍后在“设置”中重新运行。"
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="你的“提醒事项”已在知识库中。已跳过。"
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="“提醒事项”已在知识搜索中关闭。你可以在“设置”中将其打开。"
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="知识导入器尚未就绪。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="提醒事项仍在后台载入。你的知识库会逐步填充，并显示当前进度。"
MSG_HYDRATE_REMINDERS_HEARTBEAT="  仍在读取你的提醒事项（目前已用 %s 秒）。提醒事项列表较大时可能需要几分钟。"

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="你的提醒事项已在知识库中（%s 条）。无需重新读取。"
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="你的提醒事项之前已添加，但知识库中已不再包含它们。正在重新添加。"
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="无法检查你的提醒事项是否仍在知识库中。为稳妥起见，将重新添加，而不是假定它们仍然存在。"

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="正在为你的联系人建立搜索索引"
MSG_HYDRATE_PEOPLE_DONE="已为 %s 位联系人建立搜索索引"
MSG_HYDRATE_PEOPLE_PARTIAL="目前已为 %s 位联系人建立搜索索引（共 %s 位）。其余联系人暂时还无法搜索，Ostler 会自动重试。"
MSG_HYDRATE_PEOPLE_FAILED="这次无法为你的联系人建立搜索索引（图谱存储没有响应）。Ostler 会自动重试。详细信息：%s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="暂无可建立索引的联系人。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="联系人索引器尚未就绪。你可以稍后在“设置”中重新运行。"
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="你的联系人仍在后台建立索引。搜索会逐步完善，维基会显示当前进度。"

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="你的联系人已建立搜索索引（%s 位）。无需重新建立索引。"
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="你的联系人之前已建立索引，但搜索索引中已不再包含他们。正在重新建立索引。"
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="无法检查你的联系人是否仍在搜索索引中。为稳妥起见，将重新建立索引，而不是假定他们仍然存在。"

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="即将出现三个文件夹访问提示"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="“命令行工具”对话框已出现在此窗口前面。请在其中点按“安装”，然后回到这里（或等待几秒，我们会帮你把此窗口带回最前面）。工具会在后台下载，你可以继续回答下面的问题，此处的操作不受影响。"

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="需要权限：iMessage 自动化"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostler 现在会请求 macOS 授权，以便与“信息”App 通信。macOS 会弹出提示：“OstlerInstaller 想要访问并控制‘信息’”。请点按“允许”，这样助手才能代你收发 iMessage。如果没有此权限，iMessage 信息将始终无法发出，也不会有任何提示。这是一次性授权，你之后可以在“系统设置”>“隐私与安全性”>“自动化”中更改。"

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="你的恢复密钥"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="请现在抄写或打印下来。如果你忘记了密码短语，并且无法访问“钥匙串”，这将是你重新进入的唯一方式。Ostler 无法为你找回它：密钥不会离开这台 Mac，也不会存储在任何服务器上。"
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="我已将其保存在安全的地方"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="拷贝到剪贴板"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="存储为 PDF..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="打印..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="继续"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Ostler 恢复密钥.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Ostler 恢复密钥"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="恢复密钥已拷贝到剪贴板"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="恢复密钥已存储到 %s"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="配对你的 iPhone"
MSG_INFO_PAIR_IPHONE_HELP="在 iPhone 上打开 Ostler app，扫描此二维码，将其与这台 Hub 关联。你也可以稍后在 Hub 的“设置”菜单中配对。"
MSG_INFO_PAIR_IPHONE_FETCHING="正在生成配对码..."
MSG_INFO_PAIR_REFRESH="刷新配对码"
MSG_ERR_PAIR_FETCH_FAILED="暂时无法连接 Ostler 网关。它可能仍在启动，请点按“刷新”重试。"

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="安装器中未包含 assistant-agent。每日简报和 WhatsApp 保活 LaunchAgent 将无法载入。"

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="安装器中未包含维基重新编译脚本。维基将不会自动更新。"

# F3 - legal package missing
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="legal package not bundled with installer. Article 9 / WhatsApp / voice consent gates will raise ModuleNotFoundError until re-installed."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s 已安装于 %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s 已安装，保持原样"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Google Workspace CLI 不支持当前 CPU 架构；Gmail / Google 日历功能将受限。"
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl 不可用；已跳过 Google Workspace CLI 的安装。Gmail / Google 日历功能将受限。"
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="无法从 %s 下载 Google Workspace CLI"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="Google Workspace CLI 的 SHA256 不匹配（应为 %s，实际为 %s）。已中止安装此二进制文件。"
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="无法解压 Google Workspace CLI 压缩包。"
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI 已安装在 %s，但 --version 检测失败。"

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="iCloud / CalDAV 日历桥接已安装在 %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="位于 %s 的 iCloud / CalDAV 日历桥接不可执行。日历将不会返回任何事件。"

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="安装器中未包含 scripts/deferred-register-device.sh。下次联网时重试设备注册的功能已停用。"

MSG_WARN_EMBED_DIMS_UNREADABLE="无法从健康检测中读取嵌入向量维度。记忆功能已按 768 维配置；如果记忆检索表现异常，请检查嵌入模型。"
MSG_FAIL_EMBED_DIMS="嵌入模型返回的是 %s 维向量，但 Ostler 配置的是 %s 维。记忆功能会存储永远无法匹配的向量。请检查嵌入模型后重新运行。"

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
MSG_PROGRESS_REBOOT_SELFHEAL="正在配置重启自动恢复"
MSG_INFO_AUTOLOGIN_EXPLAIN="Ostler 是常开的 Hub，因此在断电或重启后，它需要在无人操作键盘的情况下自行恢复。这只有在这台 Mac 能自动登录时才可行，而 macOS 要自动登录，就必须在这台 Mac 上存储 %s 的登录密码。

存储密码会降低这台 Mac 的安全性。密码只是被打乱，并未加密，因此任何能使用这里管理员账户的人，或能取出磁盘在别处读取的人，都可以将其还原为你的密码。在你输入任何内容之前，你会先看到它的具体存储位置。

如果你选择否，将不会存储任何内容，其他设置也不会改变。断电后你照常登录，Ostler 的服务会随你的登录会话启动。你之后可以在“系统设置”>“用户与群组”>“自动登录”中更改。"
MSG_PROMPT_AUTOLOGIN_CONSENT="Store your login password on this Mac so it can sign itself in after a restart? [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="Ostler 会将此密码写入这台 Mac 上的文件 /etc/kcpassword。密码在其中以一种固定模式被打乱，这种模式在每台 Mac 上都相同且已公开，因此这不是加密，可以被还原。任何能使用这台 Mac 管理员账户的人，或能取出磁盘在别处读取的人，都可以将该文件还原为 %s 的登录密码。

“文件保险箱”可以阻止这种情况，因为没有启动密码就完全无法读取磁盘。出于同样的原因，“文件保险箱”也会阻止自动登录，所以只有在“文件保险箱”关闭时，Ostler 才提供此选项。

安装器能够控制的是：输入密码时不会显示它，也不会将其写入安装日志。被打乱的文件是安装器创建的唯一副本。

留空即可跳过自动登录。"
MSG_PROMPT_AUTOLOGIN_PASSWORD="%s 的登录密码"
MSG_OK_AUTOLOGIN_CONFIGURED="已为 %s 开启自动登录，该登录密码现以打乱的形式存储在这台 Mac 的 /etc/kcpassword 中。重启后这台 Mac 会自动登录，Ostler 的服务会随该会话启动。若要撤销，请在“系统设置”>“用户与群组”中关闭“自动登录”。"
MSG_INFO_AUTOLOGIN_ALREADY="已为 %s 设置过自动登录，因此这台 Mac 已在 /etc/kcpassword 中存储了该登录密码。两者均保持不变。若要撤销，请在“系统设置”>“用户与群组”中关闭“自动登录”。"
MSG_INFO_AUTOLOGIN_DECLINED="未启用自动登录，也未存储任何密码。重启或断电后，请照常登录，Ostler 的服务会随你的会话启动。"
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="已跳过自动登录设置：这里无法询问登录密码，也未存储任何内容。如果你希望这台 Mac 在重启后无人值守也能恢复，可以稍后在“系统设置”>“用户与群组”中开启“自动登录”。它会以打乱但可还原的形式在这台 Mac 上存储你的登录密码，因此建议你在开启前先了解清楚。"
MSG_WARN_AUTOLOGIN_NO_PASSWORD="未输入密码，因此未启用自动登录，也未存储任何内容。如果之后需要，请在“系统设置”>“用户与群组”中开启“自动登录”。"
MSG_WARN_AUTOLOGIN_FAILED="无法启用自动登录（%s）。此操作不会重试。如果这台 Mac 上存在 /etc/kcpassword，即使该功能处于关闭状态，它仍以打乱的形式保存着该登录密码；你可以在“终端”中运行以下命令将其删除：sudo rm /etc/kcpassword。若要重试，请在“系统设置”>“用户与群组”中开启“自动登录”。"
MSG_WARN_AUTOLOGIN_FILEVAULT="“文件保险箱”已开启，因此这台 Mac 会在启动界面要求输入密码来解锁磁盘，之后才能登录。自动登录无法代为输入该密码，所以断电后这台 Mac 会停留在“文件保险箱”解锁界面，直到有人输入密码。未启用自动登录，也未存储任何密码。这是两种方案中更安全的一种：开启“文件保险箱”时无法无人值守地从重启中恢复，作为交换，没有该密码的人无法读取磁盘。"

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
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="Ostler 无法为你打开“系统设置”。请自行打开“系统设置”，前往“隐私与安全性”>“完全磁盘访问权限”。"
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="Ostler 在容器中运行你的维基和搜索，因此会在这台 Mac 上安装并管理容器引擎（Colima）。如果该引擎被移除或重新配置，你的维基和搜索将停止工作 – Ostler 会告知你并尝试重新启动它。"
MSG_INFO_ENGINE_ALREADY_PRESENT="这台 Mac 上已安装容器引擎。Ostler 将使用它，而不是安装自己的引擎，也不会管理或修改它。"

# OS003 #233: model weight pins (install.sh OSTLER_MODEL_PINS).
MSG_OK_MODEL_DIGEST_VERIFIED="%s verified against its pinned digest (%s)"
MSG_FAIL_MODEL_DIGEST_MISMATCH="The installed %s is not the model this installer ships: found %s, expected %s (%s). The download source may have changed, so the install has stopped before using it. Contact support with this message."
MSG_FAIL_MODEL_UNPINNED="%s has no pinned digest in this installer, so it cannot be verified and will not be used. This is an installer defect. Contact support with this message."
MSG_FAIL_MODEL_DIGEST_UNREADABLE="Could not verify the downloaded %s against its pinned digest (%s). The model will not be used unverified. Re-run the installer; if this repeats, contact support with this message."
