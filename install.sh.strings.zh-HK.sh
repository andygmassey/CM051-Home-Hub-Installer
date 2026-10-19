#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to zh-HK by l10n/ostler_l10n.py.
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

MSG_STEP_CHECKING_PREREQUISITES="正在檢查先決條件"
MSG_STEP_RUNNING_HEALTH_CHECK="正在執行健康檢查"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="連接你的 iPhone 和 Apple Watch"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="設定(幾個簡單問題,之後會自行繼續)"
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
MSG_STEP_SETUP_COMPLETE_WRAP_UP="問題已完成。Ostler 現在會在背景安裝,大約需要 45 分鐘至數小時。仍有三件事需要你處理:如果 macOS 詢問是否安裝開發者工具,請按「安裝」;接近尾聲時有一分鐘的設定(開啟「完整磁碟取用權限」);最後在健康檢查之後,你需要登入 Tailscale,並允許助理使用「提醒事項」。在這些步驟之間,你可以讓它自行運行。"
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="問題已完成。Ostler 現在會在背景安裝,大約需要 45 分鐘至數小時。仍有三件事需要你處理:如果 macOS 詢問是否安裝開發者工具,請按「安裝」;接近尾聲時有一分鐘的設定(開啟「完整磁碟取用權限」);最後你需要允許助理使用「提醒事項」。在這些步驟之間,你可以讓它自行運行。"

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="然後重新執行:ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="正在重新啟動助理,讓它可以使用「完整磁碟取用權限」讀取你的「訊息」記錄。剛授予的權限需要重新啟動才會生效;如果你尚未授權,Doctor 儀表板會繼續引導你。"
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="你的助理正在運行,並已獲得「完整磁碟取用權限」,因此可以讀取所需的檔案。"
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="你的助理正在運行,但尚未獲得「完整磁碟取用權限」。在你開啟之前,Ostler 無法保持「訊息」、「郵件」、「日曆」、「提醒事項」、「備忘錄」、「照片」、Safari、「通訊錄」或 WhatsApp 的資料為最新,也無法讀取你的「文稿」資料夾。已讀取的內容會保留。Doctor 儀表板會引導你開啟。"
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="你的助理正在運行。我們無法檢查它在這部 Mac 上是否已獲得「完整磁碟取用權限」,因此無法確認。Doctor 儀表板在可以檢查時會告訴你。"
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="可見的 Apple Mail 帳戶:%s(僅供參考)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mail 似乎尚未有任何本機郵件。如果 24 小時內沒有郵件送達,Doctor 會提出後續提示。"
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mail 已有快取郵件。擷取程序會在下一個每小時週期處理這些郵件。"
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="已選取 Apple Mail,但這部 Mac 上尚無可讀取的本機郵件。請開啟 Apple Mail 並新增帳戶(「系統設定」>「互聯網帳戶」,然後剔選「郵件」),並讓它完成首次同步。"
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="郵件送達後,請重新執行:ostler-fda。Ostler 會自動處理,無需其他操作。"
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="Gatekeeper 會在首次啟動時驗證 Apple 公證。"
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="可用,安裝程式會自動略過此步驟。"
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="有權限的 Beta 測試人員可以設定 PWG_PIPELINE_REPO=<url> 然後重新執行。"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="有權限的 Beta 測試人員可以設定 PWG_KNOWLEDGE_REPO=<url> 然後重新執行。"
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="已略過瀏覽器擴充功能 (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  已複製到 %s。"
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture 僅支援 Apple 晶片。已在這部機器上略過安裝。"
MSG_INFO_CM042_LOGS_AT="RemoteCapture 日誌:%s/ostler-remotecapture.log(及 .err)"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="先前的安裝讓 Ostler RemoteCapture 在登入時啟動。它已停止,不會再次啟動。"
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="未安裝 Ostler RemoteCapture:你選擇了保持語音轉錄關閉。如果你改變主意,請在「設定」中開啟,然後再次執行安裝程式。"
MSG_INFO_CM042_TCC_PRE_PROMPT="首次啟動時,Ostler RemoteCapture 會向 macOS 要求「螢幕錄製」和「麥克風」權限。請同時允許,讓通話和會議可在本機轉錄。你的選單列不會出現紫色錄製指示燈,因為音訊擷取設計上是靜默的。"
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
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="Ostler 會把你的個人維基和對話記錄儲存在這部 Mac 的「文稿」/Ostler 之中。這些內容屬於你,並且只會留在這部機器上。為了寫入這些內容,Ostler 需要取用你的「文稿」資料夾,因此 macOS 可能會在設定期間詢問,並在今天稍後 Ostler 首次整理你的維基時再次詢問。該要求可能顯示為來自 python3.11,這是 Ostler 用來寫入檔案的內置輔助程式。每當出現時,請按「允許」。如果你錯過或拒絕了,可隨時在「系統設定」的「私隱與安全性」中,選擇「檔案和資料夾」開啟,之後你的維基和對話記錄便會繼續寫入。"
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  對話記憶引擎已安裝在 venv 中。"
MSG_INFO_HUB_APP_VERIFYING="正在驗證位於 %s 的 Ostler.app"
MSG_INFO_HUB_APP_STAGING="正在從 %s 將 Ostler.app 放置到 /Applications"
MSG_INFO_HUB_APP_DRAG_HINT="請開啟安裝程式 DMG,將 Ostler.app 和 OstlerInstaller.app 都拖到「應用程式」捷徑上,然後重新執行安裝程式。"
MSG_OK_HUB_APP_PRESENT="%s 已有 Ostler.app,簽章已驗證。"
MSG_OK_HUB_APP_STAGED="Ostler.app 已安裝於 %s"
MSG_WARN_HUB_APP_NOT_FOUND="在 /Applications 中找不到 Ostler.app,也沒有可用的內附副本。"
MSG_WARN_HUB_APP_VERIFY_FAILED="Ostler.app 的簽章或公證驗證失敗。已保留該套件,以便支援人員檢查。"
MSG_OK_UNINSTALLER_APP_STAGED="Ostler Uninstaller.app 已安裝於 %s"
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="無法將 Ostler Uninstaller.app 放入「應用程式」資料夾(/Applications)。你仍可執行以下指令來解除安裝:~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="正在複製 Doctor 代理程式⋯⋯"
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="正在複製電郵匯入腳本⋯⋯"
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="正在複製 Hub 電源腳本⋯⋯"
MSG_INFO_CLONING_IMPORT_PIPELINE="正在複製匯入流程⋯⋯"
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="正在複製 Wiki 重新編譯腳本⋯⋯"
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima 已安裝但未運行。將會啟動它。"
MSG_INFO_COLIMA_START_ATTEMPT="正在啟動 Colima(第 %s 次嘗試,共 %s 次)⋯⋯"
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="無法匯出聯絡人。你稍後可以手動匯入。"
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="無法讀取聯絡人卡片。沒問題 – 我們會改為詢問你。"
MSG_INFO_CONTACT_CARD_WILL_ASK="我們稍後會詢問你的姓名和所在國家或地區。你的聯絡人資料稍後會透過你授予的「完整磁碟取用權限」讀取,所有資料都不會離開這部 Mac。"
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  正在 %s 建立 Python venv⋯⋯"
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="正在 %s/ 建立面向用戶的內容目錄樹"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="每日定時執行。手動執行:bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="偵測到桌面式 Hub(沒有電池):正在全系統停用睡眠"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="尚未安裝 Docker。將會安裝 Colima + Docker CLI + docker-compose 外掛程式(輕量,無需 Docker Desktop)。"
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="安裝程式未附帶 Doctor 代理程式檔案。"
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="安裝程式未附帶電郵匯入腳本。"
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="安裝程式套件缺少電郵匯入腳本。請從 ostler.ai/install 重新下載 .app,然後再試一次。"
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="未附帶電郵匯入腳本,而且已傳入 --allow-plaintext;將略過 LaunchAgent 安裝。日後的電郵將不會被匯入。"
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  %s 已有現成的檢出內容;正在更新⋯⋯"
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="正在從 Takeout zip 解壓 Gmail mbox(大型封存可能需要一分鐘)⋯⋯"
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="未附帶 FDA 擷取模組。略過即時資料擷取。"
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="正在啟用你的首 30 天 Ostler Pro⋯⋯"
MSG_INFO_SUBSCRIPTION_PRICING_HINT="試用期後,Ostler Pro 每月收費 9.99 美元。請在 iPhone 上的 Ostler app 訂閱。"
MSG_INFO_FOUND_GMAIL_MBOX_MB="在 %s 找到 Gmail mbox(%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="在 %s 找到 Google Takeout zip(%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="已偵測到「全磁碟取用權」– 可進行完整擷取。"
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="已偵測到 GDPR 匯出檔案,但匯入流程尚未推出。"
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="流程推出後,即可匯入 GDPR 匯出檔案。"
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="即將掃描「下載項目」、「桌面」和「文件」資料夾,尋找你可能已儲存的 AI 匯出檔案(Google Takeout、Meta 下載檔案、LinkedIn 等)。macOS 會顯示三次資料夾取用提示,請逐一允許。整個過程約需 5 至 10 秒。掃描期間不會移動或複製任何內容,我們只會檢查有哪些檔案。"
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS 可能會要求取得讀取「日曆」的權限。請允許,讓 Ostler 建立你知識圖譜中的會議和活動部分。(日曆資料只會留在這部 Mac 上。)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS 正在要求「下載項目」的權限。請按「好」。"
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS 正在要求「桌面」的權限。請按「好」。"
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS 正在要求「文件」的權限。請按「好」。"
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="已授予「全磁碟取用權」。正在準備下一個 macOS 提示(「訊息」自動化)⋯⋯"
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="「訊息」權限提示沒有回應,所以我們繼續下一步。在允許之前,你的訊息不會被讀取。Ostler 會再次詢問,你也可以在「系統設定」>「私隱與安全性」>「自動化」中授予權限。"
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="需要 Xcode 命令行工具。macOS 會請求你允許安裝 – 請留意一個灰色的小對話框(如果看不到,請按 Cmd+Tab 或查看 Dock)。按一下「安裝」。你回答下面的問題時,工具會在背景下載。"
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  仍在設定命令行工具(%s 秒)。如果有灰色的 macOS 小對話框詢問是否安裝開發者工具,請按一下「安裝」– 此步驟正在等待這個操作。(如果看不到,請按 Cmd+Tab 或查看 Dock。)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="正在等待命令行工具安裝完成(快完成了)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="每小時執行一次。首次執行會擷取過去 5 年的郵件。"
MSG_INFO_IMESSAGE_BRIDGE_STARTED="正在停用舊版 iMessage 橋接 LaunchAgent(單一機器 v1.0)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="此 Hub 僅使用交流電(未偵測到電池),略過 hub-power LaunchAgent。"
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="安裝程式未附帶 Hub 電源指令碼。"
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="手提電腦 Hub。在螢幕打開並接上交流電時,它會持續運作。"
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="合上螢幕,或在使用電池時閒置,macOS 就會讓它進入睡眠。"
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="睡眠期間,助理不會接收任何內容。"
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="在這段時間內送達的訊息,喚醒後不會被擷取。"
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="在合蓋模式下,螢幕可以保持合上。"
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="這需要接上交流電,以及外接顯示器、鍵盤和滑鼠。"
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="Docker 和 Ollama 在使用電池時會暫停,接上交流電後恢復。"
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="重新啟動後,FileVault 會讓這部 Mac 停留在登入畫面。"
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="你登入後,Ostler 就會啟動。"
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="安裝程式已附帶助理 API,正在使用內附的原始碼。"
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="安裝程式未附帶助理 API 原始碼,你 iPhone 上的 Ostler app 將只能有限度存取。"
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="正在安裝助理 API 的執行時期相依項目(phonenumbers、httpx)..."
MSG_WARN_ICAL_SERVER_DEPS_FAILED="無法安裝助理 API 的執行時期相依項目(phonenumbers/httpx);在下次執行安裝前,「人物」和「時間線」可能仍然是空白。"
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Tailscale 視窗出現後,請使用 Apple / Google / Microsoft 登入。"
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="正在打開 Tailscale,讓你登入..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="明白了 – 從這裡開始,Ostler 大部分會自行安裝。接近尾聲時,它需要你回來約兩分鐘:開啟「全磁碟取用權」,然後登入 Tailscale,讓你的 iPhone 和 Apple Watch 可以隨時隨地連接這部 Mac。我們會為你打開瀏覽器進行登入。"
MSG_INFO_TAILSCALE_SKIPPED="已略過 Tailscale – 你 iPhone 上的 Ostler app 只能在家中 Wi-Fi 使用。你日後可以在「設定」中設定。"
MSG_INFO_TAILSCALE_STILL_WAITING="仍在等待 Tailscale 登入(已過 %s 秒)– 請在 Tailscale 視窗中完成登入。"
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="已授予「全磁碟取用權」;正在重新啟動助理以套用新權限。"
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="正在打開「系統設定」和 Finder,引導你為助理授予「全磁碟取用權」..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="正在向 macOS 註冊 Ostler 助理,讓它在「全磁碟取用權」中顯示為開關..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="「全磁碟取用權」仍待處理。在授予權限之前,Doctor 儀表板會一直顯示該卡片。"
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant 已擁有「全磁碟取用權」,無需再做任何操作。"
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="這一步需要你花約兩分鐘:現在為助理開啟「全磁碟取用權」,然後在下一步登入 Tailscale。之後,你就可以讓 Ostler 自行完成其餘部分。"
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="這一步需要你花約一分鐘:為助理開啟「全磁碟取用權」。之後,你就可以讓 Ostler 自行完成其餘部分。"
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="「%s」已列在「全磁碟取用權」中,你只需將它開啟。無需從 Finder 拖放任何項目。"
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="正在檢查 Ostler 助理是否擁有「全磁碟取用權」..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="助理可以讀取「訊息」記錄;iMessage 頻道將可正常使用。"
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="Ostler 助理尚未獲得「完整磁碟取用權限」。助理需要此權限，才能讓你 Mac 內置的 App 保持最新，不論有沒有使用「訊息」。如果你現在略過，Doctor 儀表板會引導你前往「系統設定」。"
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="助理 LaunchAgent 未能載入，略過 iMessage 完整磁碟取用權限檢查。"
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="Doctor 內的 Evernote 匯入介面會顯示「服務無法使用」"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="安裝程式未包含匯入流程。"
MSG_INFO_INSTALLING_CM042="正在安裝 Ostler RemoteCapture v%s（通話及會議轉錄）⋯⋯"
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="正在從 %s 安裝對話記憶引擎⋯⋯"
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  正在將對話記憶引擎安裝到 venv⋯⋯"
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="正在安裝 Colima + Docker CLI⋯⋯"
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="正在安裝 GNU coreutils（用於為耗時步驟設定逾時上限）⋯⋯"
MSG_INFO_INSTALLING_HOMEBREW="正在安裝 Homebrew⋯⋯"
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="正在從 %s 安裝知識服務⋯⋯"
MSG_INFO_INSTALLING_OLLAMA="正在安裝 Ollama⋯⋯"
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  正在安裝資料擷取模組的相依項目⋯⋯"
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  正在將 Apple Mail 讀取器安裝到專用 venv⋯⋯"
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  正在將 ostler-knowledge 安裝到 venv⋯⋯"
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  正在將加密儲存相依項目安裝到對話記憶 venv⋯⋯"
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="正在將 Safari 延伸功能安裝到 /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="正在安裝安全性 Python 相依項目⋯⋯"
MSG_INFO_INSTALLING_SQLCIPHER="正在安裝 SQLCipher⋯⋯"
MSG_INFO_INSTALLING_TAILSCALE="正在安裝 Tailscale⋯⋯"
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="路線圖未包括支援 Intel；如有需要，請提出要求。"
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="知識服務已隨安裝程式附帶，使用內附的原始碼。"
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="未安裝知識服務：PWG_KNOWLEDGE_REPO 為空。"
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="這部 Mac 是手提電腦。作為你的 Hub，它在螢幕打開並接駁電源時會持續運作。"
MSG_INFO_LAPTOP_HUB_SLEEP_COST="如果合上螢幕，或使用電池時閒置，macOS 會讓它進入睡眠。睡眠期間助理不會收到任何內容，而在這段時間送達的訊息，喚醒後也不會被擷取。"
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="在合蓋模式下，螢幕可以保持合上，但需要接駁電源，以及外接顯示器、鍵盤和滑鼠。"
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="Mac Mini 或 Mac Studio 的 Hub 會自行保持喚醒狀態，如果你想安裝在這類 Mac 上也可以。"
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="稍後在「系統設定」>「私隱與安全性」>「完整磁碟取用權限」"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  啟動以驗證 cron-delivery + imessage-tcc 狀態）。"
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="授權條款：%s 為 Apache 2.0。全文：%s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licence: %s – check upstream terms before commercial use."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="本機儲存 – Google 完全不會知道 Ostler 的存在。"
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="記錄檔：%s/email-ingest.log（及 .err）"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="記錄檔：%s/ostler-assistant.log（及 .err）"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="記錄檔：%s/wiki-recompile.log（及 .err）"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="MacBook Hub：請設定 PWG_HUB_POWER_REPO=<url> 並重新執行。"
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="偵測到 MacBook Hub：只在接駁電源時設定為永不睡眠（hub-power 會處理電池狀態切換）"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Mac Mini / Studio 部署不受影響（持續接駁電源）。"
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Mac 端資料（iMessage、Safari 等）已在上方擷取。"
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="手動重新啟動：launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="手動執行：bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="略過安裝 com.ostler.meeting-brief-sender（v1.0.1 功能；端點尚未推出）。"
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="略過記憶整理程序（此安裝程式未包含）；在加入之前，系統不會自動降低任何內容的權重。"
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="當功能旗標日後開啟時顯示的訊息。"
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="需要協助？請電郵至 support@ostler.ai。我們會盡量在 2 個工作天內回覆。"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="尚未設定任何頻道。稍後可執行：%s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="已移除工作區根目錄中過時的舊版 config.toml；現行的助理設定位於 assistant-config/ 之下。"
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="目前沒有可用的 FDA 來源。你可以授予「完整磁碟取用權限」"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="在「下載項目」、「桌面」或「文件」中找不到 GDPR 匯出檔案。"
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="無法讀取 %s 以尋找資料匯出檔案。macOS 正在阻止存取該資料夾。"
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="請在「系統設定」>「私隱與安全性」>「檔案和資料夾」（或「完整磁碟取用權限」）中授予取用權限，然後重新執行，或在下方手動為 Ostler 指定你的匯出檔案資料夾。"
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="由於 macOS 阻止存取，無法掃描一個或多個資料夾以尋找資料匯出檔案。請授予取用權限並重新執行，或手動指定你的匯出檔案資料夾。"
MSG_INFO_OPENING_CHROME_WEB_STORE="正在開啟 Chrome 網上應用程式商店：%s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="尚未安裝 ostler-assistant 二進位檔；略過 doctor 探測"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor：已延後（常駐程式可能仍未"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="使用此 DMG 內附的 ostler-assistant 二進位檔（支援離線安裝的途徑）。"
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge 已安裝於 venv。"
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler will show an extra consent screen before installing"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  可透過 ./install.sh --help 所載的環境變數，覆寫對話記憶引擎的來源儲存庫。"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  可使用 PWG_DOCTOR_REPO=<url> ./install.sh 覆寫來源儲存庫"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  可使用 PWG_HUB_POWER_REPO=<url> ./install.sh 覆寫來源儲存庫"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  可使用 PWG_KNOWLEDGE_REPO=<url> ./install.sh 覆寫來源儲存庫"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  可使用 PWG_PIPELINE_REPO=<url> ./install.sh 覆寫來源儲存庫"
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Persisting consent records and region..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="第 3 階段電池監察程式已啟動（PID %s）"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="正在讀取你的通訊錄（大型通訊錄可能需要數分鐘 – 請勿關閉安裝程式）…"
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="策略覆寫：編輯 ~/.ostler/power.conf（normal / aggressive / eco）"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="正在探測 iMessage「自動化」權限（唯讀）…"
MSG_INFO_PULLING_GRAPH_DB_IMAGES="正在下載知識圖譜資料庫（僅限首次執行）。全新安裝可能需要一分鐘…"
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="正在拉取 nomic-embed-text（274 MB）…"
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="正在拉取 %s（%s）…可能需要數分鐘。"
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="已清除隔離 xattr。待 Developer-ID 版本"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="正在讀取 Safari、iMessage、備忘錄、日曆、相片、提醒事項、郵件…"
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="正在讀取你的聯絡人資訊卡以預先填寫你的資料…"
MSG_INFO_REGION_EU_EEA_SOURCE="地區：歐盟／歐洲經濟區（%s，來源：%s）"
MSG_INFO_REGION_SOURCE="地區：%s（來源：%s）"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="地區：英國（來源：%s）"
MSG_INFO_REGION_UNITED_STATES_SOURCE="地區：美國（來源：%s）"
MSG_INFO_REPO_URL="儲存庫網址：%s"
MSG_INFO_REPO_URL_2="儲存庫網址：%s"
MSG_INFO_REPO_URL_3="儲存庫網址：%s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="現在請選擇用來解鎖你的 Hub 的密碼短語。每次啟動 Hub 介面時，你都需要輸入這個密碼短語。"
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="已略過復原密碼短語。（已淘汰：v1.0 一律需要密碼短語。）"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="正在重用位於 %s 的現有 Doctor 代理程式安裝"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="正在重用位於 %s 的現有電郵擷取安裝"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="正在重用位於 %s 的現有 hub-power 安裝"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="正在重用位於 %s 的現有瀏覽器擴充功能密鑰"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="此版本不包含適用於 Chrome 的 Ostler 擴充功能。"
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="Email conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="電郵對話：未設定，因為這部 Mac 尚未設定 Apple Mail。"
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="Messages conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="訊息對話：未設定，因為這部 Mac 上沒有「訊息」記錄。"
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  使用 Ostler 轉錄通話後，此功能會自動開啟。"
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="口述對話：尚未設定，因為沒有可讀取的轉錄內容。"
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="口述對話：已關閉，因為自安裝 Ostler 後，「Transcripts」資料夾已被移除。"
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  重新建立 %s 即可再次開啟。Ostler 不會替你重新建立。"
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="WhatsApp conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="WhatsApp 對話：未設定，因為 WhatsApp 已關閉。"
MSG_INFO_CHROME_HISTORY_STILL_READ="  Ostler 仍會讀取你的 Chrome 瀏覽記錄，因此你瀏覽過的頁面會被記住。目前只有 Safari 支援瀏覽時即時擷取。"
MSG_INFO_REUSING_EXISTING_JWT_SECRET="正在重用 %s 中現有的 JWT_SECRET"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="正在重用位於 %s 的現有 PWG 服務權杖"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="正在重用位於 %s 的現有 wiki-recompile 安裝"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="此安裝程式版本不包含 Safari 延伸功能套件（已略過）"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="還有一個手動步驟：打開 Safari，選擇「Safari」>「設定」>「延伸功能」，然後剔選 Ostler 以啟用。"
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="正在掃描 GDPR 資料匯出檔案..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="請設定 PWG_DOCTOR_REPO=<url> 並重新執行以進行安裝。"
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="請設定 PWG_HUB_POWER_REPO=<HR015 url> 並重新執行以進行安裝。"
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="已略過對話模型。稍後可下載：ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="正在啟動 Colima（輕量 Docker 執行環境）..."
MSG_INFO_STARTING_DOCKER_DESKTOP="正在啟動 Docker Desktop..."
MSG_INFO_STARTING_OLLAMA="正在啟動 Ollama..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="正在移除舊版本遺留的過時 Colima 啟動項目..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="正在移除舊版 Ollama formula（不含 llama-server）；正在改用 Ollama App..."
MSG_INFO_VERIFYING_EMBEDDINGS="正在驗證嵌入引擎是否會傳回向量..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="無法自動啟動 Ollama。請用以下指令載入：launchctl bootstrap gui/\$(id -u) %s – 然後重新執行安裝程式。"
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="Ollama 未能透過背景服務啟動；本次執行將直接啟動它..."
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  啟動中；首次啟動後請執行 \`ostler-assistant doctor\`"
MSG_INFO_SYMLINKING="  正在建立 %s -> %s 的符號連結"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="（系統設定 > 互聯網帳户）。Ostler 會讀取「郵件」的"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="（沒有 Doctor 儀表板，Ostler 其餘部分仍可運作。）"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="目前會是這樣，屬正常情況。GDPR 匯入功能將於日後更新提供。"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="這通常需要 15 至 45 分鐘；如果你的記錄很多，或 Mac 較慢，可能需要更長時間。這是正常的 – 它正在運作，並沒有停頓，你可以放心讓它繼續執行..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="這會直接讀取 macOS 資料庫 – 無需匯出。"
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="提示：如要包含你的 Gmail，請先把它加入 Mac 的「郵件」"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="如要在取得權限後再安裝："
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="正在為 %s 觸發 iCloud 同步（靜默，只限首次執行）..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      （英國 GDPR 第 9 條 - 處理特殊類別資料所必需）。"
MSG_INFO_UPDATING_EXISTING_PIPELINE="正在更新現有管線..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="已顯示過面向使用者的目錄樹（已有標記檔案）；略過"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="正在下載本機網絡搜尋引擎（約 3.5 GB）。首次安裝時這是最耗時的步驟，可能需時最多一小時。此步驟沒有進度列，因此長時間沒有任何顯示屬正常，並不代表安裝已停頓。"
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane 沒有回應（選用；請參閱第 3.8b 階段的警告）"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="隨時可用以下指令查看：bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="語音辨識將保持關閉。你可以稍後在「設定」中啟用。"
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="正在等候你登入 Tailscale（最多 3 分鐘）..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="未設定 Tailscale 遠端存取。你 iPhone 上的 Ostler app 可在家中 Wi-Fi 下使用；你可以稍後在「設定」中設定遠端存取。"
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="這部 Mac 已連接到你的 Tailscale 網絡，無需另行設定。將保留現有連線。"
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="遠端存取：保留你上次的選擇，即略過設定。你的 iOS app 可在家中 Wi-Fi 下使用，你可以稍後在「設定」中設定遠端存取。"
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="遠端存取：保留你上次的選擇，即進行設定。"
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="WhatsApp 連接器已保持關閉。你可以稍後透過「設定」啟用。"
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="WhatsApp 保持連線已排程於 08:50 + 17:50（標籤 com.creativemachines.ostler.whatsapp-keepalive）"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="略過首日 wiki 補編：未安裝 wiki 重新編譯排程。若已安裝每日 wiki 重建，仍會照常執行。"
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="安裝程式未附帶 wiki 重新編譯的腳本。"
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="Wiki 不會自動更新；你可以手動重新執行首次編譯："
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="已寫入狀態標記：%s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="你的匯出檔案安然無恙。稍後可用以下指令匯入：ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="你 Mac 上的資料（iMessage、Safari 等）已在上面擷取完成。"
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="你可以稍後再加入，以便即時從 Safari、iMessage 等匯入資料完成設定。"

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="AI 模型：%s（%s）– 已按你的 %s GB RAM 選定"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="適合"
MSG_MODELFIT_PILL_SLOW="可能較慢"
MSG_MODELFIT_PILL_NOFIT="不適合"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="正在為你的 Mac 配對助理模型（%s、%s GB RAM、助理上下文 %s 個 token）："
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- 建議"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="AI 模型：%s（%s）– 在助理所需的上下文視窗下，最適合你的 %s GB RAM"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="已選取所有來源（面容辨識仍然關閉）"
MSG_OK_ALREADY_AVAILABLE="%s 已可使用"
MSG_OK_APPLE_SILICON_DETECTED="已偵測到 Apple Silicon"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="已啟動 App 以觸發 iCloud 同步"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="App 資料庫已存在（略過預先啟動）"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="助理設定已儲存至 %s（模式 0600）"
MSG_OK_BACKED_UP_CONTACTS="已將 %s 位聯絡人備份至 %s"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s 已安裝於 %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="Ostler RemoteCapture LaunchAgent 已載入（標籤 %s）"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="已安裝 Colima 和 Docker CLI"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="已安裝容器執行環境監察程式（每 5 分鐘檢查一次，如執行環境停止便會重新啟動）"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="無法排程容器執行環境監察程式。Ostler 仍會安裝，但如果執行環境日後停止，將不會自動恢復，你的 wiki 會一直無法使用，直至你重新執行安裝程式。"
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="此安裝程式缺少容器執行環境監察程式的檔案，因此未有排程。Ostler 仍會安裝，但執行環境的自動恢復功能並未啟用。"
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="無法啟動 Ostler Doctor 儀表板，因此 http://localhost:8089 不會回應。App 中讀取該儀表板資料的頁面，包括「人物」、「時間線」、「Governor」及頻道狀態，在儀表板重新運作前都會顯示為無法使用。請重新執行安裝程式再試一次。"
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="無法排程保持喚醒的輔助程式。Ostler 仍可運作，但這部 Mac 可能會在執行較長的背景工作時進入睡眠，工作會在喚醒後繼續，而不會在夜間完成。"
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="無法排程背景補充輔助程式，因此新的訊息、郵件和日曆項目不會自動擷取。請重新執行安裝程式以恢復此功能。"
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="%s not set up: Ostler has no record of your answer to the question that governs it, so it did not assume one."
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  Re-run Ostler and choose to answer the questions again to turn it on. (consent record: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="無法排程每日簡報，因此你不會收到早晨摘要。其他功能不受影響；請重新執行安裝程式以恢復。"
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="無法排程記憶整理程序，因此過時或已被取代的資料不會自動降低權重。其他功能不受影響；請重新執行安裝程式以恢復。"
MSG_WARN_EXPORT_SCAN_NOT_LOADED="無法啟動「下載項目」監察程式，因此你放入「下載項目」的檔案不會自動擷取。已匯入的內容不受影響，你仍可在 App 內加入檔案。請重新執行安裝程式以恢復。"
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="無法排程裝置註冊的重試輔助程式。如果你的 iPhone 已在設定期間完成註冊，這不會有任何影響；如果未完成，你需要在 App 內重新配對，而不會自動完成。"
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="容器執行環境回應正常"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="已移除舊版本遺留的過時 Colima 啟動項目"
MSG_OK_CONFIG_SAVED_ENV="設定已儲存至 %s/.env"
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Consent records and region persisted to ~/.ostler/posture/"
MSG_OK_AT_REST_EXCLUDED="已確認不納入 Spotlight 和 Time Machine：%s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s 並未從 Time Machine 或 Spotlight 中排除：%s。其內容，包括 Ostler 的機密資料，可能會被複製到你的備份磁碟。Doctor 會持續顯示此提示，直至問題解決。"
MSG_INFO_AT_REST_FOLDER_ABSENT="%s 尚未存在，因此沒有需要從備份中排除的項目。"
MSG_WARN_DB_KEY_NOT_EXCLUDED="資料庫密鑰檔案 %s 並未從 Time Machine 中排除，因此可能會被複製到你的備份磁碟。"
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="無法將你對背景豐富化的選擇儲存至 ~/.ostler/posture/。你的選擇仍會套用於此次安裝，只是不會出現在支援報告中。"
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="資料庫已加密。Hub 服務會從你的個人資料夾中的受保護檔案讀取密鑰，因此啟動時不會提示你。"
MSG_OK_DB_KEY_DELIVERED="資料庫密鑰已交付予 Hub 服務（%s，只有你可以讀取）。"
MSG_WARN_DB_KEY_NOT_DELIVERED="無法將資料庫密鑰交予 Hub 服務。在問題解決前，它們會以未加密方式開啟資料庫。"
MSG_INFO_DB_KEY_RECOVER_HINT="執行此指令以復原並交付密鑰：%s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="正在加密先前安裝遺留的資料庫"
MSG_WARN_DB_MIGRATION_FAILED="部分現有資料庫無法加密，仍可在磁碟上讀取。"
MSG_WARN_DB_KEY_MISSING_ON_RERUN="此安裝沒有資料庫密鑰檔案，因此 Hub 服務會以未加密方式開啟資料庫。"
MSG_WARN_DB_PLAINTEXT_COUNT="這部 Mac 上目前有 %s 個資料庫可在磁碟上讀取。"
MSG_INFO_DB_MIGRATE_HINT="然後加密現有的資料庫：%s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="已安裝延後的裝置註冊重試程序（每小時執行一次，直至佇列清空）"
MSG_OK_DOCKER_RUNNING="Docker 已在運行"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker 已在運行（耗時 %s 秒）"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="已從 %s 複製 Doctor 代理程式"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Doctor 代理程式檔案已隨安裝程式一併提供"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="已安裝 Doctor 所需的相依項目"
MSG_OK_EMAIL_CHANNEL_FOLDER="電郵頻道：%s（資料夾：%s）"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="已載入電郵擷取 LaunchAgent（標籤 com.creativemachines.ostler.email-ingest）"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="電郵擷取指令碼已隨安裝程式一併提供"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="已從 %s 複製電郵擷取指令碼"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="正在設定 WhatsApp 對話記憶"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  已安裝 WhatsApp 對話讀取程式。"
MSG_WARN_WHATSAPP_SOURCE_FAILED="WhatsApp 對話讀取程式安裝失敗，WhatsApp 對話來源將不會運行。請參閱上方輸出內容。"
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="找不到 WhatsApp 對話讀取程式的來源,已略過 WhatsApp 對話來源。"
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="此安裝程式內找不到 WhatsApp 對話來源套件，已略過。WhatsApp 訊息記錄（你曾與誰在何時傳訊息）不受影響。"
MSG_OK_WHATSAPP_BUNDLE_LOADED="已載入 WhatsApp 對話來源 LaunchAgent（標籤 com.creativemachines.ostler.whatsapp-bundle）"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  首次執行會讀取你的 Mac 已同步的近期 WhatsApp 對話（約過去一年），資料只會留在你的 Mac 上。"
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  記錄檔：%s/whatsapp-bundle.log 及 whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="WhatsApp 對話來源 LaunchAgent 安裝失敗。請參閱上方輸出內容；其餘安裝不受影響。"
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  尚未啟動：此代理所執行的助理程式不在磁碟上。已尋找：%s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="正在設定電郵對話記憶"
MSG_OK_EMAIL_SOURCE_INSTALLED="  已安裝電郵對話讀取程式。"
MSG_WARN_EMAIL_SOURCE_FAILED="電郵對話讀取程式安裝失敗，電郵對話來源將不會運行。請參閱上方輸出內容。"
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="找不到電郵對話讀取程式的來源，已略過電郵對話來源。"
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="此安裝程式內找不到電郵對話來源套件，已略過。每小時一次的電郵擷取不受影響。"
MSG_OK_EMAIL_BUNDLE_LOADED="已載入電郵對話來源 LaunchAgent（標籤 com.creativemachines.ostler.email-bundle）"
MSG_INFO_EMAIL_BUNDLE_TICK="  從 Apple Mail 的本機儲存空間讀取你的近期電郵討論串；所有資料都只會留在你的 Mac 上。"
MSG_INFO_EMAIL_BUNDLE_LOGS="  記錄檔：%s/email-bundle.log 及 email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="電郵對話來源 LaunchAgent 安裝失敗。請參閱上方輸出內容；其餘安裝不受影響。"
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="正在設定會議及語音對話記憶"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  已安裝會議及語音對話讀取程式。"
MSG_WARN_SPOKEN_SOURCE_FAILED="會議及語音對話讀取程式安裝失敗，此來源將不會運行。請參閱上方輸出內容。"
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="找不到會議及語音對話讀取程式的來源，已略過此來源。"
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="此安裝程式內找不到會議及語音對話來源套件，已略過。"
MSG_OK_SPOKEN_BUNDLE_LOADED="已載入會議及語音對話來源 LaunchAgent（標籤 com.creativemachines.ostler.spoken-bundle）"
MSG_INFO_SPOKEN_BUNDLE_TICK="  將你自己的會議和語音備忘轉錄成可搜尋的對話；所有資料都只會留在你的 Mac 上。"
MSG_INFO_SPOKEN_BUNDLE_LOGS="  記錄檔：%s/spoken-bundle.log 及 spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="會議及語音對話來源 LaunchAgent 安裝失敗。請參閱上方輸出內容；其餘安裝不受影響。"
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="正在設定 iMessage 對話記憶"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  已安裝 iMessage 對話讀取程式。"
MSG_WARN_IMESSAGE_SOURCE_FAILED="iMessage 對話讀取程式安裝失敗，iMessage 對話來源將不會運行。請參閱上方輸出內容。"
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="找不到 iMessage 對話讀取器的來源，已略過 iMessage 對話資料流。"
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="此安裝程式中找不到 iMessage 對話資料流套件，已略過。"
MSG_OK_IMESSAGE_BUNDLE_LOADED="iMessage 對話資料流 LaunchAgent 已載入（標籤 com.creativemachines.ostler.imessage-bundle）"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  從這部 Mac 的「訊息」資料庫讀取你最近的 iMessage 對話；所有內容都只會留在你的 Mac 上。"
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  記錄檔：%s/imessage-bundle.log 及 imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="iMessage 對話資料流 LaunchAgent 安裝失敗。請參閱上方輸出內容；其餘安裝不受影響。"
MSG_OK_EMBEDDING_MODEL_READY="嵌入模型已就緒"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="已匯出 %s 位聯絡人（將自動匯入）"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="匯出監察程式已安裝（每 4 小時掃描一次「下載項目」）"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  匯出監察程式尚未啟動：它要執行的助理程式不在磁碟上。已尋找：%s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="會議前簡報寄送程式已安裝（在清醒時段每 10 分鐘檢查一次）"
MSG_OK_MEMORY_HYGIENE_INSTALLED="記憶整理已排程（每日執行，避免過時的資料擠掉目前的資料）"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="接駁電源時，你的 Mac 會保持喚醒，讓 Ostler 持續運作（使用電池時仍會睡眠）"
MSG_OK_EXTRACTED="已解壓縮至 %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="已從 %s 個來源擷取資料。資料已儲存至 %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="已排程每 %s 分鐘重新執行 FDA（以處理較慢的 iCloud 同步並完成日曆回填）"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro 已啟用，為期 30 天。試用期後如要延長，請在 iPhone 上的 Ostler app 訂閱。"
MSG_OK_FOUND="已找到：%s"
MSG_OK_FOUND_EXPORTS="在 %s 找到匯出檔案"
MSG_OK_FOUND_GDPR_EXPORT_S="找到 %s 個 GDPR 匯出檔案："
MSG_OK_GB_FREE_DISK_SPACE="可用磁碟空間 %s GB"
MSG_OK_GB_RAM_DETECTED="偵測到 %s GB RAM"
MSG_OK_GDPR_IMPORT_COMPLETE="GDPR 匯入完成"
MSG_OK_GIT_AVAILABLE="Git 可用"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="已觸發安裝「命令列工具」（會在你回答以下問題時於背景下載）。"
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils 已安裝（耗時較長的步驟現已設有時間上限）"
MSG_OK_HOMEBREW_INSTALLED="Homebrew 已安裝"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="Hub 電源 LaunchAgent 已載入（標籤 com.creativemachines.ostler.hub-power）"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Hub 電源腳本已隨安裝程式附帶"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Hub 電源腳本已從 %s 複製"
MSG_OK_ICAL_SERVER_INSTALLED="助理 API 已安裝（回送位址 127.0.0.1:8090，由 Doctor 代理）"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="iMessage 橋接 LaunchAgent 已載入（標籤 com.ostler.imessage-bridge）"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="iMessage 橋接腳本已隨安裝程式附帶"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="iMessage 橋接腳本已從 %s 複製"
MSG_OK_IMESSAGE_CHANNEL="iMessage 頻道：%s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="匯入管線已隨安裝程式附帶"
MSG_OK_IMPORT_PIPELINE_READY="匯入管線已就緒"
MSG_OK_CM048_PIPELINE_READY="對話記憶引擎已就緒。"
MSG_INFO_CM048_SETTINGS_WRITTEN="  對話模型已設定為 %s（配合你的 %s GB 記憶體）"
MSG_INFO_CM048_SETTINGS_KEPT="  保留你現有的對話設定（%s）"
MSG_OK_KNOWLEDGE_SERVICE_READY="知識服務已就緒：%s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="授權條款文本已安裝於 %s/（來源：%s）"
MSG_OK_MACOS_DETECTED="偵測到 macOS %s"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="正在打開「系統設定」>「Internet 帳户」，讓你加入郵件帳户。登入第一個帳户後，請返回此視窗。"
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="略過「Internet 帳户」步驟。你日後可在「系統設定」加入郵件帳户；如果 24 小時內仍沒有郵件送達，Doctor 會提示你跟進。"
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="正在擷取你完整的 Apple Mail 記錄。如果郵箱很大，可能需要多一點時間。"
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="保留標準的五年郵件範圍。你日後可在 Doctor 擷取更多。"
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text 已可使用"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="Ollama 已安裝"
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama 已安裝（僅命令列工具 – 重新啟動後可能需要手動啟動）"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama 已安裝（桌面 App）"
MSG_OK_OLLAMA_RUNNING="Ollama 運行中"
MSG_OK_EMBEDDINGS_VERIFIED="嵌入引擎已驗證（768 維向量）"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor：自身啟動檢查中有 0 個錯誤"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="Ostler 助理 LaunchAgent 已載入（標籤 com.creativemachines.ostler.assistant）"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s 已放置於 %s（已簽署）"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s 已放置於 %s（未簽署）"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor 運行於 http://localhost:8089/doctor"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  資料擷取模組載入正常。"
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Apple Mail 讀取工具已安裝。"
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  電郵匯入引擎已安裝。"
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="ostler-import、ostler-fda 和 ostler-uninstall 指令已安裝"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="已記下密碼短語。第 3 階段會用它加密你的資料庫。"
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="已設定復原密碼短語。"
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="已確認密碼短語說明。"
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="已記下 Disney+ 匯出檔案的密碼，匯入時會使用。"
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="略過 Disney+ 匯出：未提供密碼。其他項目不受影響。"
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="電源：交流電（桌面 Mac，無電池）"
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="電源：交流電（良好 – 安裝可能需要 45 分鐘至數小時，使用市電可保持穩定）"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="偵測到先前的安裝。正在載入設定..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="使用內建的 Python %s（無需安裝系統版本）"
MSG_OK_PYTHON_INSTALLED="Python %s 已安裝"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="配對服務運作正常"
MSG_WARN_GATEWAY_NOT_RESPONDING="配對服務沒有回應（127.0.0.1:8000） - 手機/瀏覽器配對和聊天助理可能暫時無法使用"
MSG_OK_DOCTOR_HEALTHY="Doctor 運作正常"
MSG_WARN_DOCTOR_NOT_RESPONDING="Doctor 沒有回應（127.0.0.1:8089）- App 和瀏覽器透過它連接 Ostler，所以資料和配對可能無法使用"
MSG_OK_WIKI_HEALTHY="你的 wiki 運作正常"
MSG_OK_ICAL_SERVER_HEALTHY="助理 API 運作正常"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="助理 API 沒有回應（127.0.0.1:8090）- 在它啟動前，「人物」、「會議」和「時間線」可能會是空白"
MSG_OK_READY="%s 已就緒"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="已選取建議的來源"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="復原金鑰已儲存到「鑰匙圈」(在「密碼」App 中搜尋「Ostler」)"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Safari 擴充功能已安裝於 %s"
MSG_OK_SAFARI_EXTENSION_PAIRED="Safari 擴充功能已與此 Hub 配對"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="上次執行時已設定好安全性。"
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="安全模組已安裝到 venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="已在 %s 建立全新的 JWT_SECRET"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="已在 %s 建立 PWG 服務權杖"
MSG_OK_SEEDED_EXTENSION_TOKEN="已在 %s 建立瀏覽器擴充功能金鑰"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="服務已啟動(Qdrant :6333、Oxigraph :7878、Redis :6379)"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  已準備搜尋集合:%s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="暫時未能準備 %s 搜尋集合;下方的資料匯入會再試一次,如果仍然未能準備好,會停止而不會丟棄你的資料。"
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="搜尋索引尚未及時準備好;下方的資料匯入會等待它、準備好各個集合,如果儲存庫仍未就緒,會停止而不會丟棄你的資料。"
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="你的資料尚未匯入。搜尋儲存庫未能準備好來存放資料（缺少：%s），而強行匯入會在無聲無息間丟失資料。沒有任何資料遺失。請在這部 Mac 閒置時重新執行安裝程式，或設定 OSTLER_QDRANT_READY_WAIT_S 以等待更長時間。"
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="你的資料匯入處理了 %s 筆記錄,但一筆都沒有儲存;搜尋儲存庫拒絕了每一筆,結果會是一個空的知識圖譜卻顯示為已完成。因此已停止,不會向你顯示這樣的結果。請在這部 Mac 閒置時重新執行安裝程式。"
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="無法讀取匯入本身的記錄檔,因此未能檢查資料是否確實已存入。這並不表示匯入失敗,也不表示匯入成功。"
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="已停用接電源時的睡眠,保留電池睡眠,並已啟用網絡喚醒"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="已停用睡眠,並已啟用網絡喚醒"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale 已安裝"
MSG_OK_TAILSCALE_INSTALLED="Tailscale 已安裝完成"
MSG_OK_TAILSCALE_ENV_PERSISTED="Tailscale IP 已儲存到 .env – 你 iPhone 上的 Ostler app 首次開啟時會使用它。"
MSG_OK_TAILSCALE_IP="Tailscale IP:%s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Tailscale 背景服務已啟動(使用者空間模式,無系統擴充功能)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="無法啟動 Tailscale 背景服務。你稍後可以在「設定」中重新執行設定。"
MSG_INFO_TAILSCALE_SIGN_IN_URL="正在開啟瀏覽器以登入 Tailscale:%s"
MSG_INFO_TAILSCALE_SERVE_PORT="已在你的 tailnet 上開放 Hub 連接埠 %s"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="無法在你的 tailnet 上開放 Hub 連接埠 %s;在區域網絡以外的連接可能受限"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="你現在可以在自己的裝置上透過 %s 閱讀 wiki – 以你的身分登入,只有你能存取。"
MSG_INFO_WIKI_TAILNET_OWNER="Wiki 存取權限只限你的 Tailscale 帳戶(%s)。你 tailnet 上的其他人會收到 403。"
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="你的 wiki 只會留在這部 Mac 上。開啟 Ostler,在側邊欄選擇「Wiki」即可閱讀。"
MSG_INFO_WIKI_TAILNET_BANNER="%s  (從你自己的裝置經 Tailscale 連接。這是唯一會要求你使用上述登入資料的途徑。)"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="在 Ostler app 中。開啟 Ostler,在側邊欄選擇「Wiki」;你的頁面就在那裡,已自動登入。"
MSG_INFO_WIKI_INTERNAL_ADDRESS="Ostler 會從這部 Mac 上的 http://localhost:8044 擷取這些頁面。該位址屬內部使用,沒有任何需要你登入的內容。"
MSG_INFO_WIKI_SIGN_IN="你的 wiki 登入資料是 %s,密碼是 %s。Ostler 會代你提交,所以在這部 Mac 上無需輸入任何內容;只有當你從其他裝置經 Tailscale 開啟 wiki 時,才需要親自使用它。"
MSG_INFO_WIKI_SIGN_IN_WITHHELD="你的 wiki 登入資料是 %s。密碼不會寫入此記錄；它已在你的剪貼簿，也存放在下方所列的檔案中。Ostler 會代你填入，所以在這部 Mac 上無需輸入任何內容。"
MSG_INFO_WIKI_PORT_LAST_STATUS="wiki 連接埠最後的 HTTP 狀態：%s（000 代表沒有回應；403 代表有回應但拒絕了憑證）。"
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="你的密碼亦保存在 %s，所以剪貼簿並非唯一的副本。"
MSG_INFO_WIKI_STILL_BUILDING="仍在建置中。磁碟上已有 %s 個頁面，wiki 位址最近一次的回應是 HTTP %s。完成後會自動在 Ostler app 中出現，你無需進行任何操作。"
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="首次建置尚未產生任何頁面（請參閱上方的警告）。建置完成後，你的 wiki 仍會在 Ostler app 中開啟，上方的登入資料依然屬於你。"
MSG_INFO_WIKI_READINESS_NOT_MEASURED="這次執行未有檢查 wiki 是否已開始提供服務，因此不作任何斷言。無論如何，你的 wiki 都可在 Ostler app 中開啟，上方的登入資料依然屬於你。"
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="無法確認這部 Mac 屬於哪個 Tailscale 帳戶，因此 wiki 尚未在你的 tailnet 上公開。你仍可在這部 Mac 上使用，請在 Ostler app 的「Wiki」中開啟。"
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="無法在你的 tailnet 上發佈 wiki；你仍可在這部 Mac 上使用，請在 Ostler app 的「Wiki」中開啟。"
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="無法重新載入 wiki 存取閘，因此 wiki 尚未在你的 tailnet 上公開。"
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="Tailscale Funnel 已為 %s 開啟。Funnel 會向公開互聯網發佈內容。Ostler 從不會開啟 Funnel，而且你的 wiki 會拒絕 Funnel 流量，所以 Ostler 的內容並不會公開 – 但如果你並非有意啟用，請在 Tailscale 管理控制台中為這部裝置關閉。"
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="已安裝第三方版權聲明（來源：%s）"
MSG_OK_USER_FACING_TREE_READY="面向使用者的目錄結構已就緒"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="改用「Ostler」資料夾／標籤。"
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane 運作正常（本機網絡搜尋）"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane 正在 http://localhost:3000 運行（與你本機的 Ollama 連接）"
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="WhatsApp connector will be enabled (consent recorded)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="首日 wiki 補全 LaunchAgent 已載入（最初數小時內每 30 分鐘重建一次你的 wiki，之後便會停止）"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="仍在合併重複的聯絡人 – 通訊錄較大時可能需要數分鐘（已經過 %s 秒）"
MSG_INFO_DEDUPE_MERGED="已合併重複的聯絡人"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="以這個通訊錄的大小，合併重複聯絡人需要一段時間。安裝後會繼續在背景進行 – 完成時你的 wiki 會自動更新。"
MSG_WARN_DEDUPE_INCOMPLETE="全圖去重程序未能順利完成（請參閱 %s）；繼續進行"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="重複的聯絡人已在安裝期間完全合併；無需在背景補做"
MSG_OK_DEDUPE_CATCHUP_LOADED="背景聯絡人去重 LaunchAgent 已載入（安裝後繼續合併重複項目，完成後便會停止）"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="無法載入背景聯絡人去重 LaunchAgent。重複項目仍會由每日維護程序合併，只是需要較長時間才能整理妥當。"
MSG_OK_ENRICH_AGENT_LOADED="背景充實資料 LaunchAgent 已載入（為你的電影、地點、書籍和連結補充詳細資料；會在未來一天左右分段執行）"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="無法載入背景充實資料 LaunchAgent。你的偏好設定已儲存並可搜尋；在它執行之前，只是欠缺額外的參考詳情（導演、演員、地點）。"
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="wiki 重新編譯 LaunchAgent 已載入（標籤 com.creativemachines.ostler.wiki-recompile）"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="wiki 重新編譯腳本已隨安裝程式附上"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="wiki 重新編譯腳本已從 %s 複製"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="正在設定你的「頭版」（每小時更新）"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="「頭版」產生程式已隨安裝程式附上"
MSG_OK_EDITOR_FRONTPAGE_LOADED="「頭版」LaunchAgent 已載入（標籤 com.creativemachines.ostler.editor-frontpage）"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  首次更新現正執行；隨着 Ostler 讀入你的偏好，你儀表板上的「頭版」會逐漸充實。"
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  記錄檔：%s/editor-frontpage.log 及 editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="此安裝程式中找不到「頭版」產生程式；儀表板上的「頭版」將不會更新。"
MSG_WARN_EDITOR_FRONTPAGE_FAILED="「頭版」LaunchAgent 安裝失敗。請參閱上方輸出；其餘安裝不受影響。"
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="正在設定你的「頭版」補全"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="「頭版」補全 LaunchAgent 已載入（每 5 分鐘檢查一次，直至你的興趣讀入完成，之後便會停止）"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="無法載入「頭版」補全 LaunchAgent。你的「頭版」以及 Ostler 對你興趣的了解，將改為在下一次每小時更新時逐步補上。"
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="略過「頭版」補全：「頭版」更新尚未安裝，因此沒有可重新執行的項目。"
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki 已在 http://localhost:8044 運行"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="你的 Wiki 已準備好瀏覽。Ostler 現正在背景撰寫頁面摘要，稍後會陸續補上。你可以立即開始使用 Wiki。"
MSG_OK_YOUR_ASSISTANT_CALLED="你的助理名為 %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="安裝程式隨附的個人情境摘要腳本"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="個人情境摘要 LaunchAgent 已載入（標籤 com.creativemachines.ostler.context-refresh）"
MSG_INFO_CONTEXT_REFRESH_LOGS="  記錄檔：%s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="重用位於 %s 的現有 context-refresh 安裝"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="未隨附個人情境摘要腳本；助理將只依靠即時查詢（不設常駐情境摘要）"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="個人情境摘要 LaunchAgent 未能載入；請參閱 context-refresh.err。助理仍可透過即時查詢回答"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="已複製的知識服務原始碼缺少打包設定，因此未能設定其環境。"
MSG_WARN_BUNDLE="  套件：%s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s 只支援 Apple 晶片（偵測到：%s）。"
MSG_WARN_CM042_DOWNLOAD_FAILED="無法下載 Ostler RemoteCapture v%s（來源：%s）"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="常見原因：發行標籤尚未發佈、網絡已離線，或上游公證仍在處理中。待發行版本上線後，請重新執行安裝程式。"
MSG_WARN_CM042_EXTRACT_FAILED="無法解壓縮 Ostler RemoteCapture tarball；略過 LaunchAgent。"
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Ostler RemoteCapture LaunchAgent 載入失敗。請參閱上方輸出內容及 ~/Library/LaunchAgents/。"
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  對話強化功能將無法使用。Ostler 其餘部分會正常安裝；如要接入對話記憶引擎，請不加 --allow-plaintext 重新執行。"
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="對話記憶引擎安裝失敗（複製）。"
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  已尋找：%s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  這通常表示安裝程式 .app 在建置時沒有"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  將內附的 cm048_pipeline 套件打包到"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/。請重新下載安裝程式，或"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  加上 --allow-plaintext 重新執行，以進行開發/CI 安裝。"
MSG_WARN_CM048_PIPELINE_NOT_FOUND="找不到對話記憶引擎。沒有它，對話強化功能無法運作。"
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="已略過對話記憶引擎設定（--allow-plaintext）。"
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="已找到對話記憶引擎原始碼，但缺少 pyproject.toml；已略過 venv 設定。"
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Colima 啟動失敗。正在嘗試改用 Docker Desktop……"
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="無法安裝 GNU coreutils；較長的步驟將不設時間上限執行（仍會顯示進度行，表示正在運作）。"
MSG_WARN_COLIMA_START_RETRY="Colima 未能順利啟動（Docker socket 尚未就緒）。%s 秒後重試……"
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="常見原因：標籤 v%s 尚未發佈、網絡已離線，"
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  consent_cli stderr (first 400 chars):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  未在 %s 建立主控台腳本；pyproject.toml 可能缺少 [project.scripts] 項目。"
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="由於已傳入 --allow-plaintext，安裝繼續進行。"
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="安裝繼續進行。診斷上述錯誤後，請重新執行 \`ostler-fda\`。"
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="繼續進行，但不自動填寫聯絡人資料卡 – Ostler 會改為詢問你。"
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  傳送至 iMessage 的對話將會無聲失敗，直至"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="無法更改睡眠設定。請在「系統設定」>「能源」中啟用「連接電源時防止自動進入睡眠」。"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="無法更改睡眠設定。請在「系統設定」>「能源」中開啟「防止自動進入睡眠」。"
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="無法下載 ostler-assistant v%s（來源：%s）"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="無法從 Takeout zip 中提取 Gmail mbox – 已略過。"
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="無法解開 ostler-assistant tarball,已略過 LaunchAgent。"
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="找不到 Tailscale CLI。你可以稍後手動設定。"
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Could not install legal/ consent-strings package; continuing"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="無法安裝 LICENSES/ 目錄(不影響安裝)。"
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="無法將 ostler_security 安裝到 Hub 的 venv。"
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="無法安裝 THIRD_PARTY_NOTICES.md(不影響安裝)。"
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="無法取得 Doctor 代理程式(內附版本及複製均失敗)。"
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="找不到 Ostler Doctor 檔案。iOS 配對流程需要這些檔案(Ostler.app iframes :8089/pair-ios)。"
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  已尋找:%s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  這通常表示安裝程式 .app 建置時沒有附上"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  內含的 doctor/agent/ 原始碼,應位於"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/。請重新下載安裝程式,或"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  加上 --allow-plaintext 重新執行,以進行開發/CI 安裝。"
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Doctor 安裝已中止:iOS 配對流程需要它。請重新下載安裝程式,或加上 --allow-plaintext 以進行開發/CI 安裝。"
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="無法取得電郵匯入腳本(內附版本及複製均失敗)。"
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="無法取得 hub-power 腳本(內附版本及複製均失敗)。"
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="無法取得 wiki-recompile 腳本(內附版本及複製均失敗)。"
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="無法自動開啟 Chrome 網上應用程式商店網址:%s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="無法儲存 region.json(繼續進行,Doctor 會顯示此問題)"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="無法記下復原密鑰已交付。今次執行的摘要仍然正確,但之後的執行可能無法得知,並可能再次提醒你。這已是出錯時較安全的結果。"
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="無法儲存到「鑰匙圈」。請將它抄寫下來。"
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="無法自動啟動 Ollama。"
MSG_FAIL_OLLAMA_PORT_IN_USE="另一個程式已在使用埠 11434,而 Ostler 的本機 AI 需要使用此埠。Ostler 無法啟動自己的副本,因此安裝在此停止,而不是只完成一半。

  佔用此埠的是:%s
  詳細錯誤載於:%s

這通常是你原本已有的 Ollama,或是先前 Ostler 安裝後仍在運行的副本。請將它結束(或重新啟動這部 Mac),然後再次執行安裝程式。"
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="無法更新管線(是否離線?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="無法寫入 pipeline_signals.json。在下次安裝或定時執行前,Doctor 的空白「郵件」診斷會使用安全預設值。"
MSG_WARN_CURL_SAID="Curl 回應:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="找不到目錄:%s – 已略過匯入。"
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker 未能在 %s 秒內啟動。"
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker 已安裝但未運行,需要啟動它。"
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="這部 Mac 上有 Docker 指令,但背後沒有任何運行中的引擎。在 macOS 上,Docker 指令只是客戶端,需要 Colima 或 Docker Desktop 等引擎才能實際運行。安裝程式會為你設定一個。"
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="容器運行環境診斷 - docker 客戶端:%s | colima:%s | Docker Desktop:%s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="Wiki 容器已啟動,但 60 秒內 http://localhost:8044 沒有任何回應。請視 Wiki 為未運行,因為啟動指令的結束碼並不能證明頁面可以載入。"
MSG_WARN_WIKI_NOT_RESPONDING="你的 Wiki 沒有回應(127.0.0.1:8044)。它在容器中運行,所以這通常表示容器運行環境已停止。請開啟 http://localhost:8089/doctor 的 Ostler Doctor 查看原因。"
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama 安裝途中,令就緒探測卡住。"
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  早期標記(頻道仍在連接 + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="電郵擷取 LaunchAgent 安裝失敗。請參閱上方輸出。"
MSG_WARN_IMESSAGE_BRIDGE_FAILED="iMessage 橋接 LaunchAgent 安裝失敗。在你重新執行安裝程式或手動執行 INSTALL_SNIPPET.sh 之前,助理使用者的 iMessage 回覆將無法使用。"
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="iMessage 橋接腳本未有隨附,而且已傳入 --allow-plaintext;LaunchAgent 安裝將會略過。助理使用者的 iMessage 回覆將無法使用。"
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="加密將無法使用。"
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="加密將無法使用,而且"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="請確保已固定的 PWG_KNOWLEDGE_REPO 標籤包含它。"
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  「訊息」App 的事件權限)。"
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="FDA 擷取程式以非零狀態結束(%s)。輸出的最後 20 行:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="此安裝程式未有隨附 FDA 擷取模組。"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="預期位置:Contents/Resources/ostler_fda/(位於 .app 內)。"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="最可能的原因:建置回歸令隨附的模組副本遺失。請從 ostler.ai/install 重新下載 .app。"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="FDA 擷取模組未有隨附。由於已傳入 --allow-plaintext,安裝會繼續 – 即時資料擷取將會略過。"
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="資料擷取模組已在磁碟上,但其相依項目未能安裝,因此無法載入:"
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="由於已傳入 --allow-plaintext,安裝會繼續 – 排程資料更新每次執行都會失敗。"
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault 尚未啟用。"
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="暫時無法啟用首月免費;安裝會繼續。配對後,請在 iPhone 上開啟 Ostler app 解決。"
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="「終端機」未獲「全盤取用權限」。"
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="偵測到 %s GB RAM。你會使用精簡版助理(gemma4:e2b):可靠、準確,短問題可在一秒內回應,支援工具呼叫,不懂時會坦白說「我不知道」。如要為較長的問題提供更豐富的答案,24 GB 或以上可使用標準版助理(qwen3.5:9b)。你日後可重新安裝以更換 Mac。"
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="GDPR 匯入出現錯誤。你可以用以下指令重新執行:"
MSG_WARN_GRAPH_DB_PULL_RETRY="資料庫下載未能完成(第 %s 次嘗試,共 %s 次)。將於 %s 秒後重試..."
MSG_WARN_GRAPH_DB_UP_RETRY="知識圖譜資料庫未能啟動(第 %s 次嘗試,共 %s 次)。正在重試..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="GDPR 匯入是產品化安裝的一部分。沒有它,你的社交圖譜(LinkedIn、Facebook、Instagram、WhatsApp、Twitter、Google 日曆)將無法匯入。"
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="在重新安裝匯入管線之前,此實例將無法使用 GDPR 匯入。"
MSG_WARN_GIT_SAID="Git 表示:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  健康檢查失敗:ostler-knowledge --version 沒有產生輸出。"
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  健康檢查失敗:對話記憶引擎無法載入(pwg-convo 或其管線匯入未能正常返回)。"
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="Homebrew 安裝程式以 %s 結束。%s 的最後 30 行如下:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Homebrew 安裝記錄（末段）---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="Doctor pip 安裝以 %s 結束。%s 的最後 30 行如下："
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Doctor pip 安裝記錄（末段）---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="管線 pip 安裝以 %s 結束。%s 的最後 30 行如下："
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- 管線 pip 安裝記錄（末段）---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Hub 電源 LaunchAgent 安裝失敗。請參閱上方輸出。"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="在預期的套件路徑找不到 Hub 電源指令碼。"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  安裝程式 .app 似乎缺少 vendor/hub_power/"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  位於 Contents/Resources/hub-power/。將不會安裝電池感知節流；其餘安裝會繼續。"
MSG_WARN_ICAL_SERVER_FAILED="無法啟動助理 API；在下次執行安裝之前，iPhone 上的 Ostler app 只能有限度取用。"
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - 映像檔拉取失敗（網絡、磁碟空間或登錄庫逾時）"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="無法將 iMessage 的「全碟取用權限」訊號寫入 pipeline_signals.json。Doctor 儀表板可能不會自動顯示「全碟取用權限」卡片。"
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="IMAP 主機為空 – 請再試一次。"
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="iMessage 自動化權限：未授權 (-1743)。"
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="iMessage 自動化權限：探測結果不明確。"
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="無法讀取 iMessage 記錄 (chat.db)：Ostler 常駐程式尚未獲授「全碟取用權限」。在「系統設定」>「私隱與安全性」>「全碟取用權限」中授權之前，讀取 iMessage 記錄會保持關閉。"
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="正在打開「系統設定」>「私隱與安全性」>「自動化」。請剔選 OstlerInstaller（或「終端機」）的「訊息」一列，以接通 iMessage 傳送功能。"
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="不是完整的電郵地址，已略過：%s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="請至少輸入一個完整的電郵地址（例如 you@example.com）。"
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage 需要至少一個獲允許的聯絡人。請再試一次，或"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="匯入管線不可用（私人儲存庫，僅限 Beta 測試人員）。"
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="安裝程式未附帶匯入管線。已略過強制失敗。"
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="安裝程式未附帶匯入管線。這是正式產品的安裝途徑；contact_syncer Python 套件應內置於 .app 套件中。"
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX 代表助理會讀取你收到的每一封電郵。"
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - wiki 輸出卷宗的磁碟空間不足"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="偵測到 Intel Mac – 效能會受限。建議使用 Apple 晶片。"
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s 是雲端供應商的主機。"
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="%s 中的 JWT_SECRET 在禁用清單內；正在重新產生，以確保知識圖譜服務可以載入"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="%s 中的 JWT_SECRET 太短（%s < %s 個字元）；正在重新產生"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="已複製知識儲存庫，但缺少 pyproject.toml；已略過 venv 設定。"
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="知識服務安裝失敗（複製）。"
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="授權條款：%s 依據 Google 的 Gemma 使用條款發佈，而非 Apache 2.0。"
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="MacBook 部署需要此項目來處理電池與睡眠。"
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="macOS「聯絡人」權限已被拒絕，或尚未授權。"
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS 不會由腳本提示此權限 – 你必須手動授權。"
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Mac Mini 部署不受影響；MacBook 用戶應重試。"
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="仍可手動匯入郵件資料："
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  手動重試：cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  問題解決後手動重試："
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Apple Mail 與自訂 IMAP 均未選取 – 預設使用 Apple Mail。"
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="未設定通行密碼；資料庫將不會加密。"
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="先前的安裝已產生你的復原密鑰，但未能完成，因此從未向你顯示。此密鑰無法取回 – 它不會儲存在任何地方，包括這裏。"
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="你的通行密碼仍然有效，目前沒有任何內容被鎖住。但如果你忘記通行密碼，現時將無法重新進入。"
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="請聯絡支援人員重新設定保安，過程會顯示一組新的復原密鑰讓你保管。"
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="通行密碼不相符。請再試一次。"
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="通行密碼設定失敗。輸出內容："
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="輸入為空。已略過通行密碼。"
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="通行密碼至少須有 12 個字元。請再試一次。"
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="需要通行密碼才能加密你的資料。"
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="這不是國際電話號碼。請以 + 開頭，後接國家或地區編號及其餘號碼，例如 +447700900123。請再試一次。"
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama 沒有回應"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s 失敗（第 %s/3 次嘗試）。%s 秒後重試⋯⋯"
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="只剩 %s GB 可用空間。建議至少預留 35 GB（Docker 映像檔、AI 模型及資料）。"
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="使用電池時，Hub 電源 LaunchAgent（步驟 3.14）可能會暫停"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="或重新執行安裝程式，然後選擇另一個頻道選項。"
# NEEDS REVIEW: The source is a fragment that continues on the next line. A human should check the restructured sentence flows with that line. Also switched to full-width punct
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="或領先於 Phase B 的發佈流程。請待以下條件就緒後，再重新執行安裝程式："
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor 回報了 %s 個錯誤。"

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="Ostler 已完成，但安裝期間出現 %s 個錯誤。"
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  完整詳情載於 ~/.ostler/logs/install.log。Ostler 仍會啟動；請開啟 Doctor 查看需要處理的項目。"
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="Ostler 已完成，但有 %s 個安裝步驟未能順利完成：%s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="Ostler 已完成，安裝期間沒有出現錯誤。"

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant 已解壓縮，但 --version 檢查失敗。"
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Ostler 助理的 LaunchAgent 嘗試安裝 3 次後仍失敗。診斷輸出見上下方。"
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Ostler 助理的 LaunchAgent 第 %s 次安裝嘗試失敗，正在重試。"
MSG_WARN_ASSISTANT_ERR_LOG_PATH="完整的 daemon stderr 位於：%s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="最後一段 stderr："
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s 只支援 Apple 晶片（偵測到：%s）。"
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  無法將加密儲存依賴項目安裝到對話記憶 venv；對話強化功能將不會執行。"
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  在 SCRIPT_DIR 找不到加密儲存依賴項目的來源；對話記憶引擎無法載入，對話強化功能將不會執行。"
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - ostler-wiki-compiler 映像檔暫時無法拉取（登錄庫尚未接通）"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph 沒有回應"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph 在此階段尚未正常運作（請查看上方記錄）"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="密碼不相符（或為空白）。請再試一次。"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="主要安裝通常需時 45 分鐘至數小時（包括下載 Docker 及 Ollama 和首次設定），如果網絡連線較慢，或 Mac 內有多年的紀錄，時間會更長。長時間沒有動靜屬正常，因為它正在背景下載和設定，並沒有卡住。"
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  pip 安裝失敗；對話記憶引擎將無法使用。"
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  pip 安裝失敗；email-ingest 將改用系統 python（執行時也可能失敗）。"
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  pip 安裝失敗；ostler-knowledge 將無法使用。"
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  pip 安裝失敗；電郵匯入引擎無法使用。每小時的 LaunchAgent 仍會輸出 mbox 檔案，但在修復之前，無法將它們匯入圖譜。"
MSG_WARN_CM021_SOURCE_NOT_FOUND="在 App 套件中找不到電郵匯入引擎的來源；每小時的背景工作會儲存郵件檔案，但不會匯入。"
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="在 App 套件中找不到 ostler_fda 來源；email-ingest LaunchAgent 在執行時將改用系統 python。"
MSG_WARN_PIP_SAID="pip 表示："
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="請接上交流電源，以進行完整安裝。"
MSG_WARN_PORT_1_ALREADY_USE_PID="連接埠 %s 已被 %s 使用（PID %s）"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - 連接埠 3000 已被另一項服務使用"
MSG_WARN_POWER_SOURCE="電源：%s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="sqlcipher3 安裝失敗。"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="sqlcipher3 安裝失敗。資料庫將不會加密。"
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="找不到 Python 3。正在安裝 Python 3.12⋯⋯"
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s 版本過舊（需要 3.10 或以上）。正在安裝 Python 3.12⋯⋯"
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant 沒有回應"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         商業使用前，請先閱讀 https://ai.google.dev/gemma/terms。"
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="公開版本請見 https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis 沒有回應"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="發佈後再試，或手動放置該執行檔："
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="正在重新執行 – 請輸入自行託管的主機，或按 Ctrl-C，然後重新啟動並選擇 Apple Mail。"
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="取消剔選 iMessage 後重新執行安裝程式，即可略過此項目。"
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="正以 --allow-plaintext 執行：已停用加密。不適用於正式環境。"
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  首次啟動後，請執行 \`%s doctor\`"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="登入後請執行 'tailscale ip --4'，然後將該位址加入 iOS App。"
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Safari 擴充功能複製失敗；你可以稍後手動安裝"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="Safari 擴充功能已安裝，但沒有可用的擴充功能代碼進行配對；在你重新執行安裝程式之前，瀏覽擷取會保持關閉"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="無法將 Safari 擴充功能與此 Hub 配對；在你重新執行安裝程式之前，瀏覽擷取會保持關閉"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="找不到保安模組。將略過通行密鑰設定。"
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  已搜尋：%s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  這通常表示安裝程式 .app 在建置時沒有"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  將附帶的 ostler_security 套件打包到"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/。請重新下載安裝程式，或"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  使用 --allow-plaintext 重新執行，以進行開發/CI 安裝。"
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="保安設定失敗。將在沒有資料庫加密的情況下繼續。"
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="保安設定失敗。輸出內容："
MSG_WARN_SEE_STDERR_FRAGMENT="  stderr 片段請見 %s。"
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="略過執行檔安裝。精靈寫入的 config.toml 會保留不變。"
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="略過 Doctor LaunchAgent 安裝。"
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="略過電郵擷取 LaunchAgent 安裝。"
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="略過 LaunchAgent 安裝。Mac Mini 部署不受影響。"
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="略過 LaunchAgent 安裝。請試試：%s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="略過 wiki 重新編譯 LaunchAgent 安裝。"
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="部分連接埠已被佔用。Docker 容器可能無法啟動。"
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="連接埠 %s 已被 %s（PID %s）佔用，該程式屬於此帳戶。請先結束該程式，然後再次執行安裝程式。"
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="連接埠 %s 已被此 Mac 上屬於「另一個」使用者帳戶的程式佔用。Ostler 無法共用該連接埠，強行啟動可能會令兩個帳戶的資料混淆。請登出另一個帳戶，或在一部只有 Ostler 所在帳戶使用此連接埠的 Mac 上安裝 Ostler。"
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="Ostler 需要的連接埠已被佔用，因此無法啟動其資料庫。"
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="請停止佔用上列連接埠的程式，然後再次執行安裝程式。"
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="無法檢查連接埠 %s 是否可用。這不代表該連接埠是可用的。"
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="有一項或多項連接埠檢查無法執行，因此無法排除與其他程式衝突的可能。"
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="無法在此 Mac 上執行最可靠的連接埠檢查，因此以下檢查不如平常全面。"
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="Ostler 無法確認這些連接埠可用，而且不會在未經檢查的連接埠上啟動其資料庫。請附上你的安裝記錄聯絡支援團隊。"
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="無法移除過期的 Colima 啟動項目。重新啟動後，你的 wiki 可能無法載入；請聯絡支援團隊。"
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="請停止互相衝突的服務，或更改 docker-compose.yml 中的連接埠"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscale 未能在 3 分鐘內完成登入。你可以稍後在「設定」中再試。"
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="Tailscale IP 已寫入 .env，但後續讀取時找不到。你 iPhone 上的 Ostler app 可能無法取得它。如發生這種情況，請重新執行 install.sh --repair。"
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="未能儲存你的遠端存取選擇，因此下次重新安裝時會再次詢問。其他一切不受影響。"
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="Tailscale 安裝失敗 – 你可以稍後在 tailscale.com 安裝"
MSG_WARN_TAILSCALE_STATE_UNREADABLE="這部 Mac 有無法讀取的現有 Tailscale 設定，因此我們無法確定它是否仍連接到你的網絡。請在下方選擇 – 如果已經連接，再次設定也不會有影響。"
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="沒有這些項目，已部署的服務將拒絕啟動。"
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  直至此問題解決為止。請參閱後續步驟橫幅了解補救方法。"
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  以便檢查。cron-delivery / imessage-tcc 是常見原因"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  請嘗試：docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  請嘗試：docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="無法識別的選擇「%s」；將預設使用 iMessage + 電郵。"
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="無法識別的選擇。將使用建議選項。"
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  更新失敗；繼續使用現有的檢出版本。"
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="該帳戶請使用 Apple Mail（見上方建議） – Ostler 絕不會儲存雲端密碼。"
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="使用 INBOX。助理會讀取每一封收到的電郵。"
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="Vane 容器已啟動，但 http://localhost:3000 在 60 秒內沒有回應。"
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane（本機網絡搜尋）啟動失敗。常見原因："
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  網絡搜尋為選用功能；沒有它，Ostler 的其他部分仍可運作。"
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="我們強烈建議改用專用的標籤/資料夾。"
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp 需要電話號碼才能傳送簡報。請再試一次，"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="Wiki 已編譯，但 wiki-site 容器啟動失敗。"
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="Wiki 首次編譯失敗。常見原因："
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="首日 wiki 補更 LaunchAgent 無法載入。每日 wiki 重建仍會執行；你的 wiki 只會在隔日更新，而不是一小時內更新。"
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Wiki 重新編譯 LaunchAgent 安裝失敗。請參閱上方輸出。"
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="Wiki 不會自動更新；仍可手動重建："
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="精靈設定保持不變；二進位檔仍已暫存。手動重試："
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="你的助理需要一個名字。請從上方建議中選擇，或自行輸入。"
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="你可以在「系統設定」>「私隱與安全性」>「通訊錄」中重新授權。"
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="你可以稍後執行保安設定：python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="你可能需要手動安裝：%s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  實際值：   %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="解壓後，在 %s 找不到 Ostler RemoteCapture 套件。發佈的 tarball 可能已損壞。"
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="無法建立或存取 %s，因此 Ostler RemoteCapture 沒有可安裝的位置。這是資料夾權限問題，與下載無關。"
MSG_ERR_CM042_RENAME_FAILED="Ostler RemoteCapture 已正確下載並解壓，但無法移至 %s。解壓後的 app 已留在 /Applications。這不是簽署問題。"
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify 回報："
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  拒絕暫存與已發佈校驗碼不符的套件。"
MSG_ERR_CM042_SHA_256_MISMATCH="Ostler RemoteCapture tarball 的 SHA-256 不符。"
MSG_ERR_CM042_PIN_FAILED="Ostler 無法確認此次下載的 RemoteCapture 是否真確，因此沒有安裝。"
MSG_ERR_CM042_VERSION_UNKNOWN="Ostler 不認得此 RemoteCapture 版本，因此沒有安裝。"
MSG_ERR_CM042_SIDECAR_DISAGREES="此 RemoteCapture 下載所附的校驗碼與檔案不符，因此沒有安裝。"
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess 回報："
MSG_ERR_CM042_VERIFY_FAILED="Ostler RemoteCapture 簽署/公證驗證失敗。"
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv 回報："
MSG_ERR_EXPECTED="  預期：%s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief 回報：%s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="位於 %s 的 ostler-assistant 二進位檔不是 Mach-O 可執行檔。"
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="ostler-assistant tarball 的 SHA-256 不相符。"
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  拒絕暫存與已發佈核對碼不相符的二進位檔。"
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="拒絕移除隔離標記或載入 LaunchAgent。"
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="待上游 tarball 修正後，請重新執行安裝程式。"
MSG_ERR_URL="  url:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="不支援 Intel Mac。Ostler 需要 Apple 晶片（M1、M2、M3 或 M4）。"
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="需要至少 16 GB 記憶體。你的 Mac 有 %s GB。建議 24 GB。"
MSG_FAIL_CM042_SIGNATURE_FAILED="Ostler RemoteCapture 安裝已中止:簽署或公證檢查失敗。套件已保留在 /Applications 供支援人員查看。請電郵至 support@ostler.ai,然後重新執行安裝程式。"
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="嘗試 3 次後仍無法拉取 %s。請檢查網絡,然後重新執行安裝程式。"
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="嘗試 3 次後仍無法拉取 nomic-embed-text。請檢查網絡,然後重新執行安裝程式。"
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker 無法使用。請重新執行安裝程式以安裝 Colima。"
MSG_FAIL_CONTAINER_CLIENT_MISSING="這部 Mac 上沒有 docker 指令,Ostler 無法啟動所需的服務。請重新執行安裝程式;如再次失敗,請把記錄檔 %s 寄給我們。"
MSG_FAIL_CONTAINER_ENGINE_ABSENT="Ostler 需要容器執行環境,但這部 Mac 上沒有任何執行環境回應。你的 wiki、知識圖譜和搜尋索引都在容器內運行,所以安裝在此停止,而不是完成後讓它們缺失。解決方法:開啟「終端機」並執行 'colima start',然後再次執行此安裝程式。如果你改用 Docker Desktop,請開啟它,等鯨魚圖示穩定後再重新執行。完整記錄位於 %s。"
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="Docker 未能及時就緒,無法啟動知識圖譜資料庫。請確保 Colima 或 Docker 正在運行,然後重新執行安裝程式。"
MSG_FAIL_GRAPH_DB_PULL_FAILED="嘗試多次後仍無法下載知識圖譜資料庫映像檔。這通常是網絡問題。請檢查你的互聯網連線,然後重新執行安裝程式。"
MSG_FAIL_GRAPH_DB_UP_FAILED="知識圖譜資料庫已下載,但無法啟動。請重新執行安裝程式;如問題持續,請開啟「終端機」並執行:cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="Ostler 無法完成向知識圖譜資料庫發出的已驗證請求。它嘗試了兩次,每次相隔兩秒,兩次都被拒絕。我們暫時未知原因:資料庫可能仍在啟動,或 Ostler 持有的憑證可能並非資料庫預期的那一個。你的資料並未被改動。重新執行安裝程式通常會成功;即使成功,我們仍希望你告知我們 – 請把安裝記錄寄給我們,因為這是我們正積極嘗試重現的故障。"
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="安裝程式套件中缺少 FDA 擷取模組。請從 ostler.ai/install 重新下載 .app,或在開發/CI 環境以 --allow-plaintext 重新執行。"
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="資料擷取模組已安裝但無法載入,因此背景更新每次執行都會失敗。完整輸出已儲存至 %s – 請重新執行安裝程式,如聯絡支援人員,請附上該檔案(參考編號:ERR-10-FDA-DEPS-IMPORT)。"
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="內部錯誤:資料擷取模組被暫存在應用程式套件內,這會破壞其簽署。這是建置故障,並非你的 Mac 出現問題。請從 ostler.ai/install 重新下載 .app(參考編號:ERR-10-FDA-DEPS-UNSAFE-PATH)。"
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Doctor 相依項目安裝失敗。完整輸出已儲存至 %s – 電郵至 support@ostler.ai 時請附上(參考編號:ERR-17-DOCTOR-PIP)。"
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="匯入管線相依項目安裝失敗。完整輸出已儲存至 %s – 電郵至 support@ostler.ai 時請附上(參考編號:ERR-14-PIPELINE-PIP)。"
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Homebrew 安裝失敗。完整輸出已儲存至 %s – 電郵至 support@ostler.ai 時請附上。"
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="匯入管線安裝失敗。產品化安裝需要 contact_syncer 套件。請在開發/CI 環境以 --allow-plaintext 重新執行,或重新下載安裝程式後再試。"
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="需要 sudo 權限才能停用睡眠並安裝 Homebrew。準備好後請重新執行。"
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Colima 和 Docker Desktop 都無法啟動。請安裝 Docker Desktop 後重新執行。"
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="磁碟空間不足(%s GB)。請釋出空間後再試。"
MSG_FAIL_MACOS_BELOW_FLOOR="macOS %s 版本低於 Ostler 支援的版本。Ostler 需要 macOS %s 或更高版本:安裝程式 app 是為其建置的,在更舊的系統上無法開啟。請更新 macOS,然後再次執行安裝程式。"
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="未設定密碼匙,亦沒有現有的安全設定。請在開發/CI 環境以 --allow-plaintext 重新執行,或重新執行安裝程式並確認 Touch ID 說明。"
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="需要對話記憶引擎。請在開發/CI 環境以 --allow-plaintext 重新執行,或修正上述缺少的套件後再試。"
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="內附的 Ostler 常駐程式(v%s,位於 %s)不支援此安裝程式所需的 'run-source' 指令,無法透過「全磁碟存取權」處理擷取。這是安裝程式套件內的版本不一致:若照樣安裝,所有擷取來源都會在無聲無息下失效,產品會過時而不顯示任何錯誤。請從 ostler.ai/install 重新下載 .app 後再試(參考編號:ERR-11-DAEMON-RUN-SOURCE-SKEW)。"
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="ostler_security 安裝失敗。請在開發/CI 環境以 --allow-plaintext 重新執行,或修正上述 pip 錯誤後再試。"
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="密碼匙設定失敗。請在開發/CI 環境以 --allow-plaintext 重新執行,或修正上述錯誤後再試。"
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="加密資料庫需要 sqlcipher3。請在開發/CI 環境以 --allow-plaintext 重新執行,或修正上述 pip 錯誤後再試。"
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="此安裝程式只適用於 macOS。"
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="Xcode Command Line Tools 未能在 15 分鐘內完成安裝。請開啟「終端機」並執行 'xcode-select --install',在 macOS 對話框中按「安裝」,等待完成後再重新執行此安裝程式。"

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="Homebrew 安裝顯示成功,但找不到 /opt/homebrew/bin/brew。請查看 %s 取得完整記錄。復原方法:開啟「終端機」並執行 '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"',然後重新執行安裝程式。"
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew 已安裝在 /opt/homebrew/bin/brew,但執行 shellenv 後,PATH 中仍找不到 'brew' 指令。請開啟新的「終端機」視窗,再重新執行安裝程式。"
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' 顯示成功,但 PATH 中找不到 colima。請查看 %s 了解 Homebrew 的失敗原因。復原方法:開啟「終端機」並手動執行 'brew install colima docker docker-compose',然後重新執行安裝程式。"
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' 顯示成功,但 PATH 中找不到 docker CLI。請查看 %s。復原方法:手動執行 'brew install docker',然後重新執行安裝程式。"
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="Ollama app 安裝顯示成功,但 /Applications/Ollama.app 中找不到其執行檔。請查看 %s。復原方法:手動執行 'brew install --cask ollama-app',然後重新執行安裝程式。"
MSG_FAIL_EMBED_HEALTHCHECK="Ollama 正在運行,但嵌入模型沒有傳回向量(HTTP 不是 200,或結果為空)。「人物」卡片、搜尋和瀏覽都會是空白。請查看 %s。復原方法:確保已安裝並運行 Ollama app(而非 Homebrew formula),然後重新執行安裝程式。"
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' 顯示成功,但 PATH 中找不到 sqlcipher。請查看 %s。復原方法:手動執行 'brew install sqlcipher',然後重新執行安裝程式。"
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' 沒有產生 /Applications/Tailscale.app。請查看 %s。復原方法:從 https://tailscale.com/download/macos 下載 Tailscale 並拖到 /Applications,然後重新執行安裝程式。"
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' 顯示成功,但 /opt/homebrew/opt/python@3.11/bin/python3.11 中找不到 python3.11 執行檔。請查看 %s。復原方法:執行 'brew reinstall python@3.11',然後重新執行安裝程式。"

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="我們找到你之前的回答"
MSG_PROMPT_REUSE_SETTINGS_HELP="我們偵測到這部 Mac 上有較早的安裝嘗試。你已回答的問題(姓名、助理名稱、時區、國家代碼、頻道等)會被沿用,無需重新輸入。選「是」從上次中斷的地方繼續,選「否」則從頭重新回答問題。"
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="我們找到的先前回答:姓名 = %s,助理 = %s,時區 = %s。"

MSG_PROMPT_PERMS_OK_TITLE="準備好繼續了嗎?"
MSG_PROMPT_PERMS_OK_HELP="macOS 會要求「通訊錄」和「檔案和檔案夾」的取用權限。「完整磁碟取用權限」為選用,可稍後再授權。"

MSG_PROMPT_USER_NAME_DETECTED_TITLE="全名(與通訊錄中顯示的相同)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="全名(例如:陳大文)"

MSG_PROMPT_USER_ID_TITLE="你希望助理怎樣稱呼你?"
MSG_PROMPT_USER_ID_HELP="助理用來稱呼你的簡短名稱(例如「Andy」、「Andrew」、「陳太」)。早晨簡報和聊天回覆中會顯示這個名稱。與上面的全名不同。"

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
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="以下是你的日曆。看起來正確嗎?"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="我們已推測每個日曆屬於誰,這樣你的簡報就不會混淆誰的行程是誰的。"
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="已自動擱置,不會用於你的簡報:"
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="你的"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="%s 項活動"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="%s 項活動"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="公眾假期"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="生日"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="Siri 建議"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="你訂閱的日曆"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="提醒事項"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="要在簡報中使用「%s」嗎?"
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="我們擱置了這個日曆,因為它看起來像是%s。如果它其實是某人的日程,請回答「是」。"
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="「%s」是誰的日曆?"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="「%s」是哪種日曆?"
MSG_CONFIRM_CALENDAR_TYPE_HELP="請選擇其中一項:個人、工作、家庭、共享、其他。這會決定其活動的敏感程度。"
MSG_CONFIRM_CALENDARS_SAVED="已儲存日曆擁有者"
MSG_CONFIRM_CALENDARS_FAILED="無法儲存日曆擁有者(不影響安裝,你可稍後再設定)"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="我們認為這些個人檔案全都是你(%s)。要合併為一個嗎?"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="這些個人檔案與你有確切的身分關聯(電郵網域、LinkedIn 個人檔案或僱主)。合併後,助理就不會把你自己的紀錄當成幾個不同的人。你可稍後還原。"
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="有人與你同名,但看來是另一個人(%s)。這是你本人,還是別人?"
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="選擇「不同」會將對方保留為獨立人物(你的助理絕不會把對方合併到你身上)。只有確實是你本人,才選擇「我」。"
MSG_CONFIRM_IDENTITY_SAVED="已儲存身分選擇"
MSG_CONFIRM_IDENTITY_FAILED="無法儲存身分選擇(不影響安裝,你可以稍後再確認)"

# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="正在背景安裝(約需 45 分鐘至數小時)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="使用 +%s?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="輸入國家或地區編號(例如英國為 44,美國為 1)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="預設國家或地區編號"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="用於在匯入聯絡人時統一電話號碼格式,並設定你的地區(英國/歐盟/美國/其他),以套用合規預設值。"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="我們偵測到 +%s。要用於你的 Hub 嗎?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="根據上方的電話號碼偵測所得。選擇「是」即使用此編號,選擇「否」則輸入其他國家或地區編號。"

MSG_PROMPT_TZ_CONFIRM_TITLE="使用此時區?"
MSG_PROMPT_TZ_CONFIRM_HELP="偵測到的時區:%s"
MSG_PROMPT_USER_TZ_TITLE="輸入時區(例如 Europe/London、Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="你想為你的助理取什麼名字?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="欄位中的名字只是隨機建議,你可以改成任何喜歡的名字。Marvin、Samantha、Joshua、Friday、Athena、Sage 和 Rosie 都是熱門選擇。" # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="可輸入任何你喜歡的名字,建議只是起點。"

MSG_PROMPT_CHANNEL_CHOICE_TITLE="你的助理該如何聯絡你?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="選擇你想讓助理使用的訊息渠道。你可以稍後在 App 的 Doctor 部分更改。"

MSG_PROMPT_WHATSAPP_CONSENT_TITLE="Enable WhatsApp messaging for your assistant?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web is a third-party service. By enabling, you accept that your messages route through WhatsApp's own infrastructure before reaching your local Ostler instance, and that WhatsApp (Meta Platforms Ireland Ltd) may suspend, restrict, or terminate your WhatsApp account because of automated use. You can disable this later from Settings."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="你的 WhatsApp 電話號碼"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="含國家或地區編號的國際號碼,例如 +447700900123。只可輸入數字及開頭的 +,不要有空格、括號或連字號。"
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="已儲存為 %s。WhatsApp 需要不含空格或括號的號碼。"

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="為 Ostler 助理開啟「完整磁碟取用權限」"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="「系統設定」已開啟至「完整磁碟取用權限」。"
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
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="在列表中找到「%s」,然後開啟它的「完整磁碟取用權限」開關。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="列表中沒有?請將「%s」從 Finder 視窗拖到列表中,然後開啟它的開關。先後次序不影響:你可以在之前或之後按「完成」,安裝程式會等到開關真正開啟為止。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="列表中沒有?Ostler 無法為你開啟 Finder 視窗。請在 Finder 按 ⌘⇧G,輸入下方路徑,然後將「%s」拖到列表中並開啟它的開關。先後次序不影響:你可以在之前或之後按「完成」,安裝程式會等到開關真正開啟為止。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="App 位於:%s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="App 位於:%s – 此路徑已拷貝到剪貼板,請在 Finder 按 ⌘⇧G,再按 ⌘V,然後按 Return。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="完成"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="你可以在開啟開關之前或之後按「完成」,安裝程式會等到開關真正開啟為止。"

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="允許 Ostler 讀取你的 Mac 資料"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="「系統設定」已開啟至「完整磁碟取用權限」。"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="在列表中找到「OstlerInstaller」並將它開啟。"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="完成後按「完成」,Ostler 便會讀取你的 Safari 瀏覽記錄、備忘錄、iMessage 訊息和郵件。"
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="完成"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="下一步:為安裝程式開啟「完整磁碟取用權限」"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="接下來,macOS 會要求你向 OstlerInstaller 授予「完整磁碟取用權限」。"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="開啟開關後,macOS 會彈出對話框,讓你選擇「結束並重新開啟」或「稍後」。"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="按一下「結束並重新開啟」。安裝程式會自動重新啟動,並從這一步繼續。"
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="好"
MSG_INFO_INSTALLER_FDA_PREWARN="正在向你說明「完整磁碟取用權限」的授權步驟⋯⋯"
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="正在打開「系統設定」，讓你為安裝程式授予「完整磁碟取用權限」⋯⋯"
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="已為安裝程式授予「完整磁碟取用權限」。接下來會讀取 Safari、「備忘錄」、iMessage 和「郵件」。"
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="仍未授予「完整磁碟取用權限」。將在沒有該權限的情況下繼續；你之後可以重新執行安裝程式，以擷取 Safari / 「備忘錄」/ iMessage 的資料。"
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="安裝程式的「完整磁碟取用權限」已設定好。接下來的步驟較長，大部分會自行執行，但請留意 macOS 可能會彈出要求安裝開發者工具的對話框，而且接近尾聲時需要你回來花幾分鐘完成設定。"
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="還有一項權限(讓你的助理讀取「訊息」記錄)會在接近尾聲、助理安裝完成後出現,屆時我們會引導你前往設定。"
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="仍需要「完整磁碟取用權限」"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostler 即將讀取你 Mac 上的資料，但 OstlerInstaller 的「完整磁碟取用權限」仍未開啟。請在列表中找到「OstlerInstaller」並將它開啟。"
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="或者直接按「繼續」,以較少的資料完成安裝。你之後可以授予權限,再重新執行擷取程式。"
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="繼續"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="允許的聯絡人"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="信任的人:電話號碼和 Apple ID 電郵地址(以逗號分隔)。%s 只會回覆此列表中的人,其他人的訊息會被忽略。至少需要填寫一項。

例如:
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="透過 Apple Mail 讀取電郵?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="使用「完整磁碟取用權限」讀取你已加入 Apple Mail 的任何電郵帳户（iCloud、Gmail、Outlook 等）。不會儲存密碼。建議幾乎所有人使用。"

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="要在 Apple Mail 加入電郵帳户嗎?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="這部 Mac 上的 Apple Mail 尚未連接任何帳户,因此 Ostler 沒有電郵可讀取。選擇「是」會立即打開「系統設定」>「互聯網帳户」(你可以在那裡加入 iCloud、Gmail 或 Outlook)。選擇「否」則略過;你可以稍後再加入帳户,若 24 小時內仍沒有郵件送達,Doctor 會提醒你跟進。"

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="要擷取完整的 Apple Mail 記錄嗎?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Ostler 預設會讀取你 Apple Mail 最近五年的郵件。如果你在這部 Mac 上保存的郵件超過五年,而且想把全部郵件放進你的知識圖譜,請選擇「是」立即擷取完整的本機記錄(郵箱較大時可能需要多一點時間)。選擇「否」則維持五年範圍;你隨時可以在 Doctor 中延長。"

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="同時設定自訂 IMAP+SMTP 伺服器?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="僅適用於自行架設的郵箱。如果你的帳户是 Gmail、iCloud 或 Outlook,請保持「否」,因為透過上述 Apple Mail 效果更好。"

MSG_PROMPT_IMAP_HOST_TITLE="IMAP 主機"
MSG_PROMPT_IMAP_HOST_HELP="僅適用於自行架設或自訂的 IMAP 伺服器。Gmail / iCloud / Outlook 請使用上述 Apple Mail。"
MSG_PROMPT_IMAP_PORT_TITLE="IMAP 連接埠"

MSG_PROMPT_SMTP_HOST_TITLE="SMTP 主機"
MSG_PROMPT_SMTP_PORT_TITLE="SMTP 連接埠"

MSG_PROMPT_EMAIL_USERNAME_TITLE="電郵地址(同時用作 IMAP/SMTP 用戶名稱)"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="誰可以發電郵給你的助理?"
MSG_PROMPT_EMAIL_ALLOWED_HELP="你自己的電郵地址,以逗號分隔。%s 只會回覆此列表中地址的電郵,其他人的郵件會被忽略。至少需要填寫一個地址。系統已為你填入你自己的地址:你可以修改,或再加入其他地址。"

MSG_PROMPT_EMAIL_PASSWORD_TITLE="密碼(已隱藏)"
# NEEDS REVIEW: Security disclosure about plaintext storage; human check. Also fixed punctuation and HK 帳户.
MSG_PROMPT_EMAIL_PASSWORD_HELP="你自行架設的 IMAP/SMTP 伺服器的密碼。儲存在本機的 ~/.ostler/ 下,絕不會傳送給 Creative Machines。密碼以純文字儲存:唯一的保護是檔案權限,只允許你的 macOS 帳户存取,其他人不能。之後不會再加密。請使用 App 專用密碼,而非你的主要帳户密碼。"
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="確認密碼"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="助理應該監察哪個資料夾?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="建議:使用專用的標籤或資料夾(例如 Ostler)。我們只會讀取該處的郵件,不會動你的主收件箱。"

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="再次輸入 INBOX 以確認,或按「繼續」使用「Ostler」"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX 表示助理會讀取你收到的每一封電郵。我們強烈建議改用專用的標籤或資料夾。"

MSG_PROMPT_EXPORTS_ACK_TITLE="你已經申請資料匯出了嗎?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler 可從約 20 個平台匯入資料。完整列表及各服務供應商申請頁面的直接連結,請見 docs.ostler.ai/data-exports。

大多數封存檔需要 1 至 3 天才會透過電郵送達。收到 ZIP 檔後,把它們放進「下載項目」資料夾,Ostler 會自動找到。

你沒有使用的平台可以略過;之後隨時可以匯入更多。"

MSG_PROMPT_FILEVAULT_SKIP_TITLE="要在磁碟靜態資料「未加密」的情況下繼續嗎？"
MSG_PROMPT_FILEVAULT_SKIP_HELP="這部 Mac 的 FileVault 已關閉，所以你的磁碟並未進行靜態加密。

如果繼續，代表：Ostler 儲存的所有內容，包括 ~/Documents/Ostler 下你的整個個人圖譜（維基、對話、知識筆記），以及 ~/.ostler 下的服務密鑰和資料庫，都會以「未加密」的狀態寫入磁碟。任何人只要能從這個磁碟啟動、把它取出，或接觸到已解鎖的工作階段，就能讀取全部內容。Ostler 無論如何都會用密碼短語加密最敏感的資料庫，但其餘資料的保護程度只取決於磁碟本身。

強烈建議開啟 FileVault。你隨時可以在「系統設定」>「私隱與安全性」> FileVault 中開啟，它會在背景加密，無需重新安裝。

選擇「是」：現在就在磁碟未進行靜態加密的情況下繼續（這是經過深思熟慮的知情選擇，並會被記錄下來）。
選擇「否」：在此停止，讓你先開啟 FileVault，然後再重新執行安裝程式。無論選哪一個，都沒有出錯。"

MSG_PROMPT_PASSKEY_ACK_TITLE="準備設定磁碟加密"
MSG_PROMPT_PASSKEY_ACK_HELP="Ostler 的敏感資料庫會使用 SQLCipher 加密，密碼短語由你在下一個畫面自行選擇。每次啟動 Hub UI 時，你都需要輸入這個密碼短語。安裝結束時還會產生一個獨立的復原密鑰，只顯示一次。為了讓 Mac 上的所有內容都受到靜態保護，請保持 macOS FileVault 開啟。準備好後，請按「繼續」。"

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="也設定復原密碼短語嗎？（建議）"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="選擇你的密碼短語"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="這個密碼短語會加密你的知識圖譜，並在每次啟動時解鎖 Hub UI。至少 12 個字元。我們無法為你找回，建議把它存放在密碼管理工具中。"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="確認你的密碼短語"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="請再次輸入相同的密碼短語以確認。"

MSG_PROMPT_IMPORT_CONFIRM_TITLE="要在安裝期間匯入這些嗎？"
MSG_PROMPT_IMPORT_CONFIRM_HELP="找到的 GDPR 匯出檔會在安裝期間匯入你的知識圖譜。"

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="Disney+ 匯出檔密碼"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="Disney+ 的 GDPR 匯出檔是受密碼保護的試算表，這是正常情況，並不是你的下載出了問題。輸入密碼即可立即匯入你的 Disney+ 觀看記錄；留空則略過此項，其他內容仍會照常匯入。"

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="你已備妥資料匯出檔嗎？"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler 可以匯入社交媒體和平台的封存檔，包括你與朋友、家人、地點和看法有關的完整歷史，讓你一開始就能使用。Ostler 第一天了解得越多，第一天就越有用。你也可以稍後再加入，不用急。

請向各個平台（Twitter / X、Facebook、Instagram、LinkedIn、WhatsApp 等）申請匯出你的資料，下載 ZIP 檔案，然後放進「下載項目」資料夾。

Ostler 預設會在 ~/Downloads 中尋找。想用其他資料夾？請在下方選擇。否則請略過，稍後再匯入。"

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="要從這個 Takeout 匯入 Gmail 郵件嗎？"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="直接從 Takeout 檔案讀取 Gmail 內容。Google 完全看不到 Ostler。"

MSG_PROMPT_FDA_PRESET_TITLE="Ostler 應該從哪些 Mac 來源學習？"
MSG_PROMPT_FDA_PRESET_HELP="提供三種預設，或由你逐項選擇。敏感來源（人臉辨識）在每種預設中都預設關閉，如需使用，請自行審慎選擇。"
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="建議選項。包括 Apple Mail、通訊錄、日曆、備忘錄、訊息、提醒事項、Safari 瀏覽記錄、Safari 書籤，以及「照片」事件（日期和地點，不含人臉辨識）。如果已安裝 WhatsApp Desktop 和 Chrome，其記錄會自動加入。不包括「照片」的人臉辨識資料和任何第三方匯出封存檔。"
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="全部。Ostler 在這部 Mac 上能讀取的所有來源。「照片」人臉辨識會保持關閉，直到你自行勾選。"
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="自訂。在下一個畫面逐項選擇來源。敏感來源會保持關閉，直到你自行勾選。"

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="開啟或關閉此資料來源。"

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
MSG_CONSENT_SPOKEN_CAPTURE_LOCAL="Keeping the captured audio on your own Mac does not remove this duty – Ostler never sends it anywhere, but you still need consent where your local law requires it."
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
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="口述轉錄會保持關閉。你日後可在「設定」中啟用。"

MSG_PROMPT_CONSENT_INSTALL_TITLE="Ready to install?"
MSG_PROMPT_CONSENT_INSTALL_HELP="Please type INSTALL to confirm you accept the terms."
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Type INSTALL"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Install Ostler"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Cancel"
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Type INSTALL exactly (case does not matter) to confirm, or click Cancel to go back."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="連接你的 iPhone 和 Apple Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale 會為這部 Mac 提供穩定的私人地址，讓你的 iPhone 和 Apple Watch 可以在任何地方連接，全程加密，不會公開暴露。"

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="要將復原密鑰儲存到鑰匙圈嗎？"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="將你的加密復原密鑰安全保存在 macOS 鑰匙圈中。"

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="正在填充你的圖譜"
MSG_HYDRATE_CONTACTS_STARTED="正在將你的聯絡人匯入圖譜"
MSG_HYDRATE_CONTACTS_DONE="已匯入 %s 位聯絡人"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="聯絡人處理超過 %s 秒，因此我們不再等待並繼續進行。目前已匯入 %s 位聯絡人，其餘的會由 Ostler 在背景完成。"
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="正在載入你的日曆記錄（過去五年至未來一年）"
MSG_HYDRATE_CALENDAR_DONE="已匯入 %s 個活動"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  仍在載入你的日曆（目前已用 %s 秒）。如果 Mac 內有多年的會議記錄，需要多一點時間。"
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="正在根據你開會的地點建立「地點」"
MSG_HYDRATE_PLACES_DONE="已建立你的「地點」部分"
MSG_HYDRATE_PLACES_SKIPPED="暫時未找到任何位置訊號。隨着日曆資料增加，「地點」會逐步完善"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="建立「地點」時發生問題：已有位置訊號，但沒有產生任何地點。你的「地點」頁面可能會一直是空白。請參閱 %s"
MSG_HYDRATE_PLACES_ERROR_WARN="建立「地點」未能完成（發生意外錯誤）。你的「地點」頁面可能不完整。請參閱 %s"
MSG_HYDRATE_WIKI_RECOMPILE="正在建立你的 wiki。Ostler 會為你的重要人物、機構和主題各撰寫一段簡短摘要，所以如果通訊錄很大，可能需要幾分鐘至大約一小時。此過程只會進行一次，完全在你的 Mac 上運行，你可以放心離開。"

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="正在檢查你的搜尋索引（偵測到 %s 個集合）"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="正在將你的瀏覽記錄載入搜尋索引"
MSG_INITIAL_HYDRATE_QDRANT_READY="搜尋索引已準備好（%s 個集合）"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="安裝完成後，搜尋索引會在背景逐步建立"
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
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="搜尋儲存庫現已啟動；正在建立仍然缺少的集合：%s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="搜尋索引不完整：雖然搜尋儲存庫正在運行並有回應，仍無法建立 %s。Ostler 會繼續運作，Doctor 會顯示這個缺口，但在問題修復之前，這部分搜尋會保持空白。"
MSG_WARN_QDRANT_COLLECTIONS_MISSING="搜尋索引不完整：無法建立 %s。Ostler 會繼續運作，Doctor 會顯示這個缺口。"
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="無法檢查有哪些搜尋集合（%s）。這並不表示它們不存在。"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="安裝完成後，搜尋索引會在背景逐步建立（正在等待：%s）"
MSG_HYDRATE_DONE="你的圖譜已準備好：%s 位人物、%s 項事件"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud 可能仍在同步你的聯絡人 – 正在重新匯出，以載入剛同步的內容。"
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="在「通訊錄」App 中找不到任何聯絡人（本機或 iCloud）。請先在「通訊錄」新增，然後從「設定」重新執行。"
MSG_HYDRATE_SKIPPED_NO_CONTACTS="沒有可匯入的 iCloud 聯絡人。你可以稍後在「設定」中新增。"
MSG_HYDRATE_SKIPPED_NO_EVENTS="過去 5 年沒有任何日曆事件。你可以稍後在「設定」中補充匯入。"

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="正在讀取你過去 90 天的電郵 – 你的電郵只會保留在這部 Mac 上（更早的記錄會在背景補充匯入）"
MSG_HYDRATE_EMAIL_DONE="在你最近的電郵中找到 %s 位人物"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="沒有可讀取的近期電郵。你可以在 Apple Mail 新增郵件帳户，稍後再重新執行。"
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="電郵讀取器尚未準備好。你可以在 Apple Mail 新增郵件帳户，稍後再重新執行。"
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="電郵仍在背景載入中。你的 wiki 會隨之逐步充實，並顯示目前的進度。"
MSG_HYDRATE_EMAIL_HEARTBEAT="  仍在讀取你的電郵（目前已用 %s 秒）。如果 Mac 內有多年的記錄，可能需要一段時間。"

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="要開啟 Apple Mail 以開始同步嗎？"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="你已設定 %s 個郵件帳户，但 Apple Mail 尚未擷取任何郵件。我們可以現在開啟「郵件」，並在同步期間等候。"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="要開啟「日曆」以開始同步嗎？"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="你已設定 %s 個日曆帳户，但「日曆」App 尚未儲存任何事件。我們可以現在開啟「日曆」，並在它從 iCloud 同步期間等候。"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="要開啟「通訊錄」以開始同步嗎？"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="你已設定 %s 個聯絡人帳户，但「通訊錄」App 尚未儲存任何項目。我們可以現在開啟「通訊錄」，並在它從 iCloud 同步期間等候。"

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="正在等候 %s 開始同步（最多 %s 秒）。"
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="仍在等候 %s 同步（已等 %s 秒，尚餘 %s 秒）。如果是剛登入，iCloud 首次同步可能需要幾分鐘。"
MSG_OK_APP_HAS_POPULATED="%s 已填入本機儲存庫。繼續進行。"
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="在等候時間內未偵測到 %s 同步。繼續進行；你可以稍後在「設定」中重新執行匯入。"

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="可見的 Apple Mail 帳户：%s。請先開啟「郵件」一次，讓它開始擷取郵件。"
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="可見的日曆帳户：%s。請先開啟「日曆」一次，讓它同步你的事件。"
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="可見的聯絡人帳户：%s。請先開啟「通訊錄」一次，讓它同步你的通訊錄資料。"

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="無法讀取你的「通訊錄」。Ostler 透過「全磁碟取用權」讀取通訊錄，請前往「系統設定」>「私隱與保安」>「全磁碟取用權」授予權限，然後在「設定」中重新執行資料匯入。我們會在背景持續重試。"
MSG_HYDRATE_CONTACTS_PENDING="你的「通訊錄」App 尚未完成同步。請先開啟一次「通訊錄」，等待同步完成，然後在「設定」中重新執行資料匯入。"
MSG_HYDRATE_CONTACTS_READ_FAILED="你的聯絡人已在這部 Mac 上，但 Ostler 匯入了 0 位，這並不正常。匯入會在背景自動重試。如果問題持續，請在「設定」中重新執行資料匯入，或查看安裝記錄。"
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler 會在背景持續檢查，並在 iCloud 同步完成後自動匯入你的聯絡人。"
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="已匯入 %s 位有電話號碼的聯絡人，但幾乎沒有電郵地址（電話 %s 對電郵 %s）。這通常表示聯絡人讀取程式漏掉了電郵。你的聯絡人仍可使用；請參閱 %s，問題解決後在「設定」中重新執行資料匯入。"
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="已匯入新聯絡人；正在背景重建你的 wiki。"
MSG_HYDRATE_CALENDAR_PENDING="你的「日曆」App 尚未同步事件。請先開啟一次「日曆」，等待同步完成，然後在「設定」中重新執行資料匯入。"
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="這次無法讀取你的日曆（擷取程式回報錯誤，並非日曆為空）。你的其他資料不受影響；請參閱 %s，然後在「設定」中重新執行資料匯入。"

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="正在讀取你的 WhatsApp 記錄 – 你的訊息只會留在這部 Mac 上"
MSG_HYDRATE_WHATSAPP_DONE="在你的 WhatsApp 對話中找到 %s 位人物"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="已讀取 WhatsApp 對話，但未能寫入你的人物圖譜（結束代碼 %s）。Ostler 會重試。詳情：%s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="沒有可讀取的 WhatsApp 對話。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="尚未安裝 WhatsApp Desktop。請從 Mac App Store 安裝，然後在「設定」中重新執行。"
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="WhatsApp 讀取程式尚未就緒。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp 仍在背景載入。你的 wiki 會逐步充實，並顯示目前進度。"

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
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="你的 WhatsApp 聯絡人已在人物圖譜中（%s 個識別碼）。無需重新讀取。"
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="你的 WhatsApp 聯絡人之前已讀取過，但人物圖譜中已不再有這些資料。正在重新讀取。"
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="無法確認你的 WhatsApp 聯絡人是否仍在人物圖譜中。為免假設資料存在，正在重新讀取。"

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="正在讀取你的 AI 對話記錄 – 你的對話只會留在這部 Mac 上"
MSG_HYDRATE_AICONV_DONE="已將 %s 個 AI 對話儲存到你的 wiki"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="AI 對話讀取程式尚未就緒。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="沒有可讀取的 AI 對話記錄。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="AI 對話仍在背景載入。你的 wiki 會逐步充實，並顯示目前進度。"
MSG_HYDRATE_AICONV_HEARTBEAT="  仍在讀取你的 AI 對話記錄（目前已 %s 秒）。記錄龐大時可能需要數分鐘。"


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="正在匯入你的瀏覽記錄 – 你的瀏覽內容只會留在這部 Mac 上"
MSG_HYDRATE_BROWSING_DONE="已匯入 %s 頁瀏覽記錄"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="已略過 %s 個被標示為敏感的頁面（銀行、醫療等）"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="沒有可匯入的瀏覽記錄。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="瀏覽記錄讀取程式尚未就緒。你可以稍後在「設定」中重新執行。"

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
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="你的瀏覽記錄已匯入（%s 頁）。無需重新匯入。"
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="找不到可匯入的已匯出瀏覽記錄。你可以稍後在「設定」中重新執行。"
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="你的瀏覽記錄之前已匯入過，但搜尋索引中已不再有這些資料。正在重新匯入。"
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="無法確認你的瀏覽記錄是否仍在搜尋索引中。為免假設資料存在，正在重新匯入。"
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="你的瀏覽記錄未能進入搜尋索引，因此「瀏覽」頁面會是空的。請在「設定」中重新執行，或開啟 Doctor。"
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="瀏覽記錄仍在背景載入。你的 wiki 會逐步充實，並顯示目前進度。"

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="正在載入你的電郵偏好。資料只會留在這部 Mac 上，可能需要數分鐘。"
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="已從你的電郵記錄載入 %s 項偏好"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="未設定電郵偏好檔案。沒有可載入的內容。"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="在 %s 找不到電郵偏好檔案。沒有可載入的內容。"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="偏好處理流程尚未就緒。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="電郵偏好仍在背景載入。你的 wiki 會邊載入邊更新，並顯示目前進度。"
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  仍在載入你的電郵偏好（目前已 %s 秒）。記錄龐大時可能需要幾分鐘。"

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="你的電郵偏好已載入（%s 個項目）。無需重新載入。"
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="你的電郵偏好之前已載入，但搜尋索引已不再包含這些資料。正在重新載入。"
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="無法檢查你的電郵偏好是否仍在搜尋索引中。為免假設資料仍在，現正重新載入。"

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
MSG_HYDRATE_PREFERENCES_DONE="已匯入 %s 項偏好"
MSG_HYDRATE_PREFERENCES_ENRICHED="其中 %s 項已以公開參考資料補充詳情"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="已匯入 %s 項偏好，但沒有任何一項歸入「飲食」、「音樂」或「專業」。你的飲食和音樂 wiki 頁面將會是空白。"
MSG_WARN_PREFS_HEADLINE_HINT="這通常表示沒有音樂或飲食匯出檔案（Spotify、Apple Music、Uber Eats、Google Takeout），或資料未有分類。請加入這些匯出檔案，在「設定」中重新執行，然後重建 wiki。"
MSG_WARN_PREFS_UNCATEGORISED="%s 項偏好（共 %s 項，%s%%）沒有分類，不會顯示在任何主題頁面上。請檢查來源匯出格式。"

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="正在設定偏好資料補充功能"
MSG_CM019_SETUP_DONE="偏好資料補充功能已就緒"
MSG_CM019_SETUP_FAILED="偏好資料補充功能的設定未能完成。問題修復後，你的偏好頁面便會填好內容，Ostler 的其他部分不受影響。"
MSG_CM019_SETUP_SKIPPED="偏好資料補充管線未有隨附，暫時略過。"

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="正在讀取你的 iMessage 記錄 – 你的訊息只會留在這部 Mac 上"
MSG_HYDRATE_IMESSAGE_DONE="在你的 iMessage 記錄中找到 %s 位人物"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="沒有可讀取的 iMessage 記錄。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="iMessage 讀取器尚未就緒。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage 仍在背景載入。你的 wiki 會邊載入邊更新，並顯示目前進度。"
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  仍在讀取你的 iMessage 記錄（目前已 %s 秒）。訊息記錄龐大時可能需要幾分鐘。"

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="你的 iMessage 聯絡人已在人物圖譜中（%s 個識別碼）。無需重新讀取。"
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="你的 iMessage 聯絡人之前已讀取，但人物圖譜已不再包含這些資料。正在重新讀取。"
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="無法檢查你的 iMessage 聯絡人是否仍在人物圖譜中。為免假設資料仍在，現正重新讀取。"

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="正在讀取你的「備忘錄」- 內容只會留在這部 Mac 上"
MSG_HYDRATE_APPLE_NOTES_DONE="已將 %s 則備忘錄加入你的知識庫"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="沒有可讀取的「備忘錄」。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="你的「備忘錄」已在知識庫中。略過。"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="「備忘錄」已在知識搜尋中關閉。你可以在「設定」中開啟。"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="知識匯入工具尚未就緒。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="「備忘錄」仍在背景載入。你的知識庫會邊載入邊更新，並顯示目前進度。"
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  仍在讀取你的「備忘錄」（目前已 %s 秒）。備忘錄數量龐大時可能需要幾分鐘。"

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="你的「備忘錄」已在知識庫中（%s 個項目）。無需重新讀取。"
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="你的「備忘錄」之前已加入，但知識庫已不再包含這些內容。正在重新加入。"
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="無法檢查你的「備忘錄」是否仍在知識庫中。為免假設內容仍在，現正重新加入。"

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="正在讀取你的「提醒事項」- 內容只會留在這部 Mac 上"
MSG_HYDRATE_REMINDERS_DONE="已將 %s 項提醒事項加入你的知識庫"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="沒有可讀取的「提醒事項」。你可以稍後在「設定」中重新執行。"
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="你的「提醒事項」已在知識庫中。略過。"
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="「提醒事項」已在知識搜尋中關閉。你可以在「設定」中開啟。"
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="知識匯入工具尚未就緒。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="提醒事項仍在背景載入。你的知識庫會逐步填滿，並會顯示目前進度。"
MSG_HYDRATE_REMINDERS_HEARTBEAT="  仍在讀取你的提醒事項（目前已 %s 秒）。提醒事項清單較大時，可能需要幾分鐘。"

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="你的提醒事項已在知識庫中（%s 個項目）。無需重新讀取。"
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="你的提醒事項之前已加入，但知識庫已不再包含它們。正在重新加入。"
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="無法確認你的提醒事項是否仍在知識庫中。為免誤以為它們仍在，現正重新加入。"

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="正在為你的人物建立搜尋索引"
MSG_HYDRATE_PEOPLE_DONE="已為 %s 位人物建立搜尋索引"
MSG_HYDRATE_PEOPLE_PARTIAL="目前已為 %s 位人物建立搜尋索引（共 %s 位）。其餘人物暫時未能搜尋，Ostler 會自動重試。"
MSG_HYDRATE_PEOPLE_FAILED="這次未能為你的人物建立搜尋索引（圖譜儲存庫沒有回應）。Ostler 會自動重試。詳細資料：%s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="暫時沒有需要建立索引的人物。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="人物索引工具尚未就緒。你可以稍後在「設定」中重新執行。"
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="你的人物仍在背景建立索引。搜尋會逐步完善，而 wiki 會顯示目前進度。"

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="你的人物已建立搜尋索引（%s 位人物）。無需重新建立索引。"
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="你的人物之前已建立索引，但搜尋索引已不再包含他們。正在重新建立索引。"
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="無法確認你的人物是否仍在搜尋索引中。為免誤以為他們仍在，現正重新建立索引。"

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="即將出現三個檔案夾存取提示"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="「命令列工具」對話框已出現在此視窗前面 – 請在其中按「安裝」，然後返回此處（或等候幾秒，我們會將此視窗移回最前）。工具會在背景下載，你可以繼續回答下方的問題，所有步驟都不會被阻擋。"

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="需要權限：iMessage 自動化"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostler 現在會向 macOS 要求與「訊息」App 通訊的權限。macOS 會顯示彈出視窗，內容為「OstlerInstaller 想要控制『訊息』」– 請按「允許」，讓助理可代你傳送和接收 iMessage。若沒有此權限，iMessage 訊息將永遠無法發出，而且不會有任何提示。這是一次性授權，你日後可在「系統設定」>「私隱與安全性」>「自動化」中更改。"

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="你的復原密鑰"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="請現在抄下或列印。如果你遺失密碼短語，而且「鑰匙圈」又無法存取，這是唯一能重新進入的方法。Ostler 無法為你復原密鑰 – 密鑰不會離開這部 Mac，亦不會儲存在任何伺服器上。"
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="我已將它妥善保存"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="拷貝到剪貼板"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="儲存為 PDF..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="列印..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="繼續"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Ostler 復原密鑰.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Ostler 復原密鑰"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="復原密鑰已拷貝到剪貼板"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="復原密鑰已儲存到 %s"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="配對你的 iPhone"
MSG_INFO_PAIR_IPHONE_HELP="在你的 iPhone 上打開 Ostler app，掃描此 QR 碼，即可與此 Hub 連結。你亦可稍後在 Hub 的「設定」選單中配對。"
MSG_INFO_PAIR_IPHONE_FETCHING="正在產生配對碼..."
MSG_INFO_PAIR_REFRESH="重新整理配對碼"
MSG_ERR_PAIR_FETCH_FAILED="暫時未能連接 Ostler 閘道。它可能仍在啟動 – 請按「重新整理」再試一次。"

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="安裝程式未附帶 assistant-agent。每日簡報及 WhatsApp 保持連線的 LaunchAgent 將不會載入。"

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="安裝程式未附帶 wiki 重新編譯腳本。wiki 將不會自動更新。"

# F3 - legal package missing
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="legal package not bundled with installer. Article 9 / WhatsApp / voice consent gates will raise ModuleNotFoundError until re-installed."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s 已安裝於 %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s 已安裝，保持原樣"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Google Workspace CLI 不支援此 CPU 架構；Gmail / Google Calendar 功能會受影響。"
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="找不到 curl，已略過安裝 Google Workspace CLI。Gmail / Google Calendar 功能會受影響。"
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="無法從 %s 下載 Google Workspace CLI"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="Google Workspace CLI 的 SHA256 不符（預期 %s，實際 %s）。已中止安裝此執行檔。"
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="無法解壓縮 Google Workspace CLI 封存檔。"
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI 已安裝於 %s，但 --version 檢測失敗。"

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="iCloud / CalDAV 日曆橋接已安裝於 %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="位於 %s 的 iCloud / CalDAV 日曆橋接無法執行。「日曆」將不會傳回任何事件。"

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="安裝程式未附帶 scripts/deferred-register-device.sh。下次連線時重試裝置註冊的功能已停用。"

MSG_WARN_EMBED_DIMS_UNREADABLE="無法從健康檢查讀取嵌入向量維度。記憶已設定為 768 維；如果回憶表現異常，請檢查嵌入模型。"
MSG_FAIL_EMBED_DIMS="嵌入模型傳回 %s 維向量，但 Ostler 設定為 %s 維。記憶會儲存永遠無法比對的向量。請檢查嵌入模型後重新執行。"

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
MSG_PROGRESS_REBOOT_SELFHEAL="正在設定重新開機自我修復"
MSG_INFO_AUTOLOGIN_EXPLAIN="Ostler 是長期開啟的 Hub，所以在停電或重新啟動後，需要在無人操作鍵盤的情況下自行恢復運作。這必須由這部 Mac 自動登入才行，而 macOS 要自動登入，就必須在這部 Mac 上儲存 %s 的登入密碼。

儲存密碼會降低這部 Mac 的安全性。密碼只是經過混淆，並非加密，所以任何能使用這裡管理員帳户的人，或能取出磁碟並在別處讀取的人，都可以把它還原成你的密碼。在你輸入任何內容之前，會先清楚顯示密碼的儲存位置。

如果你選擇不儲存，就不會儲存任何內容，其他設定也不會改變。停電後你照常登入，Ostler 的服務會隨你的工作階段啟動。你日後可以在「系統設定」>「用户與群組」>「自動登入」中更改。"
MSG_PROMPT_AUTOLOGIN_CONSENT="Store your login password on this Mac so it can sign itself in after a restart? [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="Ostler 會把這個密碼寫入這部 Mac 上的 /etc/kcpassword 檔案。密碼在檔案中以固定模式混淆,該模式在每部 Mac 上都相同且已公開記載,所以這不是加密,可以被還原。任何能使用這部 Mac 管理員帳户的人,或能取出磁碟並在別處讀取的人,都可以把該檔案還原成 %s 的登入密碼。

FileVault 可以防止這種情況,因為沒有啟動密碼就完全無法讀取磁碟。同樣原因,FileVault 也會阻止自動登入,所以 Ostler 只會在 FileVault 關閉時提供此選項。

安裝程式可以控制的部分:輸入密碼時不會顯示密碼,也不會把密碼寫入安裝記錄。安裝程式只會建立這一份混淆後的檔案。

留空即可略過自動登入。"
MSG_PROMPT_AUTOLOGIN_PASSWORD="%s 的登入密碼"
MSG_OK_AUTOLOGIN_CONFIGURED="已為 %s 開啟自動登入,該登入密碼現以混淆形式儲存在這部 Mac 的 /etc/kcpassword。重新啟動後,這部 Mac 會自動登入,Ostler 的服務會隨該工作階段啟動。如要還原,請在「系統設定」>「用户與群組」中關閉「自動登入」。"
MSG_INFO_AUTOLOGIN_ALREADY="已為 %s 設定自動登入,所以這部 Mac 已在 /etc/kcpassword 儲存該登入密碼。兩者均保持不變。如要還原,請在「系統設定」>「用户與群組」中關閉「自動登入」。"
MSG_INFO_AUTOLOGIN_DECLINED="未開啟自動登入,也沒有儲存任何密碼。重新啟動或停電後,請照常登入,Ostler 的服務會隨你的工作階段啟動。"
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="已略過自動登入設定:此處無法要求輸入登入密碼,也沒有儲存任何內容。如果你想讓這部 Mac 在重新啟動後無人看管也能自行恢復,日後可在「系統設定」>「用户與群組」中開啟「自動登入」。這會把你的登入密碼以混淆且可還原的形式儲存在 Mac 上,建議先了解清楚再決定。"
MSG_WARN_AUTOLOGIN_NO_PASSWORD="由於沒有輸入密碼,自動登入未開啟,也沒有儲存任何內容。如日後需要,請在「系統設定」>「用户與群組」中開啟「自動登入」。"
MSG_WARN_AUTOLOGIN_FAILED="無法開啟自動登入(%s)。系統不會再重試。如果這部 Mac 上有 /etc/kcpassword,即使此功能已關閉,該檔案仍以混淆形式保存該登入密碼;你可以在「終端機」中以此指令移除:sudo rm /etc/kcpassword。如要再試一次,請在「系統設定」>「用户與群組」中開啟「自動登入」。"
MSG_WARN_AUTOLOGIN_FILEVAULT="FileVault 已開啟,所以這部 Mac 在啟動畫面會先要求輸入密碼解鎖磁碟,之後才能登入。自動登入無法回應此要求,因此停電後,這部 Mac 會停在 FileVault 解鎖畫面,直到有人輸入密碼。自動登入未開啟,也沒有儲存任何密碼。這是兩種安排中較安全的一種:FileVault 開啟時無法在無人看管下於重新啟動後自行恢復,但作為交換,沒有該密碼的人無法讀取磁碟。"

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
# NEEDS REVIEW: HK Apple uses 私隱; Full Disk Access term needs verification against zh-HK macOS.
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="Ostler 無法為你開啟「系統設定」。請自行開啟「系統設定」,然後前往「私隱與安全性」>「全磁碟取用權」。"
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="Ostler 以容器運行你的 wiki 和搜尋,因此會在這部 Mac 上安裝並管理容器引擎(Colima)。如果該引擎被移除或重新設定,你的 wiki 和搜尋將無法運作 – Ostler 會通知你並嘗試重新啟動它。"
MSG_INFO_ENGINE_ALREADY_PRESENT="這部 Mac 已安裝容器引擎。Ostler 會使用它,而不會另外安裝,也不會管理或修改它。"

