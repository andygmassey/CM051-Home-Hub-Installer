#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to ja by l10n/ostler_l10n.py.
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

MSG_STEP_CHECKING_PREREQUISITES="前提条件を確認中"
MSG_STEP_RUNNING_HEALTH_CHECK="ヘルスチェックを実行中"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="iPhoneとWatchを接続"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="セットアップ(いくつかの簡単な質問に答えると、あとは自動で進みます)"
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
MSG_STEP_SETUP_COMPLETE_WRAP_UP="質問は以上です。Ostlerはバックグラウンドでインストールを続けます。所要時間は約45分から数時間です。ただし、次の3つはあなたの操作が必要です。macOSが開発者ツールのインストールを求めたら「インストール」をクリックすること、終盤にセットアップが1分ほどあること(フルディスクアクセスをオンにします)、そして最後のヘルスチェックのあとにTailscaleへサインインし、アシスタントが「リマインダー」を使えるように許可することです。それ以外の間は、そのまま実行しておいて大丈夫です。"
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="質問は以上です。Ostlerはバックグラウンドでインストールを続けます。所要時間は約45分から数時間です。ただし、次の3つはあなたの操作が必要です。macOSが開発者ツールのインストールを求めたら「インストール」をクリックすること、終盤にセットアップが1分ほどあること(フルディスクアクセスをオンにします)、そして最後にアシスタントが「リマインダー」を使えるように許可することです。それ以外の間は、そのまま実行しておいて大丈夫です。"

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="その後、次を再実行してください: ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="アシスタントを再起動しています。フルディスクアクセスを使って「メッセージ」の履歴を読み取れるようにするためです。許可した権限は再起動後に有効になります。まだ許可していない場合は、Doctorダッシュボードが案内を続けます。"
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="アシスタントは実行中で、フルディスクアクセスも許可されているため、必要なファイルを読み取れます。"
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="アシスタントは実行中ですが、フルディスクアクセスがまだ許可されていません。オンにするまで、Ostlerは「メッセージ」「メール」「カレンダー」「リマインダー」「メモ」「写真」「Safari」「連絡先」「WhatsApp」を最新の状態に保てず、書類フォルダも読み取れません。すでに読み取った内容はそのまま残ります。オンにする手順はDoctorダッシュボードが案内します。"
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="アシスタントは実行中です。このMacでフルディスクアクセスが許可されているかどうかは確認できなかったため、許可の有無は不明です。確認できるようになり次第、Doctorダッシュボードでお知らせします。"
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="表示可能なApple Mailアカウント: %s(参考情報)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mailにはまだローカルのメッセージがないようです。24時間以内にメールが届かない場合は、Doctorが対応のご案内を表示します。"
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mailにキャッシュされたメッセージがあります。次回の1時間ごとの処理で取り込まれます。"
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="Apple Mailが選択されていますが、このMacにはまだ読み取れるローカルのメッセージがありません。Apple Mailを開いてアカウントを追加し(システム設定 > インターネットアカウントで「メール」をオンにします)、最初の同期が終わるまでお待ちください。"
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="メールが届いたら、次を再実行してください: ostler-fda。Ostlerが自動的に取り込むため、ほかの操作は不要です。"
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="Appleの公証は、初回起動時にGatekeeperが検証します。"
# NEEDS REVIEW: Source is a fragment continuing a previous line; Japanese word order may not join correctly with the preceding string. Needs a human to check the pair.
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="利用可能な場合、インストーラはこの手順を自動的にスキップします。"
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="アクセス権のあるベータテスターは、PWG_PIPELINE_REPO=<url> を設定して再実行できます。"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="アクセス権のあるベータテスターは、PWG_KNOWLEDGE_REPO=<url> を設定して再実行できます。"
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="ブラウザ拡張機能をスキップしました(--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  %s にクローンしました。"
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCaptureはApple Silicon専用です。このMacではインストールをスキップします。"
MSG_INFO_CM042_LOGS_AT="RemoteCaptureのログ: %s/ostler-remotecapture.log(および .err)"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="以前のインストールでは、Ostler RemoteCaptureがログイン時に起動する設定でした。これは停止され、今後は起動しません。"
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="音声の文字起こしをオフにする設定を選択されたため、Ostler RemoteCaptureはインストールされませんでした。気が変わった場合は、設定でオンにして、インストーラをもう一度実行してください。"
MSG_INFO_CM042_TCC_PRE_PROMPT="初回起動時に、Ostler RemoteCaptureはmacOSに「画面収録」とマイクの権限を求めます。通話や会議をローカルで文字起こしできるよう、両方を許可してください。メニューバーに紫色の録音インジケータは表示されません。音声の取り込みは、設計上インジケータなしで行われます。"
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
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="Ostlerは、あなたの個人用ウィキと会話の記録を、このMacの「書類」内のOstlerフォルダ(Documents/Ostler)に保存します。これらはあなたのものであり、このMacの外には出ません。書き込むには「書類」フォルダへのアクセスが必要なため、セットアップ中と、今日このあとOstlerが初めてウィキを整理するときに、macOSが許可を求めることがあります。要求は、Ostlerがファイルの書き込みに使う同梱ヘルパーのpython3.11からのものとして表示される場合があります。表示されたら、その都度「許可」をクリックしてください。見逃した場合や許可しなかった場合でも、システム設定の「プライバシーとセキュリティ」、「ファイルとフォルダ」からいつでもオンにでき、以降はウィキと会話の記録が書き込まれます。"
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  会話メモリエンジンをvenvにインストールしました。"
MSG_INFO_HUB_APP_VERIFYING="%s にあるOstler.appを検証中"
MSG_INFO_HUB_APP_STAGING="%s からOstler.appを/Applicationsへ配置中"
MSG_INFO_HUB_APP_DRAG_HINT="インストーラのDMGを開き、Ostler.appとOstlerInstaller.appの両方をアプリケーションのショートカットへドラッグしてから、インストーラを再実行してください。"
MSG_OK_HUB_APP_PRESENT="Ostler.appはすでに %s にあります。署名を確認しました。"
MSG_OK_HUB_APP_STAGED="Ostler.appを %s にインストールしました"
MSG_WARN_HUB_APP_NOT_FOUND="/ApplicationsにOstler.appが見つからず、同梱のコピーもありません。"
MSG_WARN_HUB_APP_VERIFY_FAILED="Ostler.appの署名または公証の検証に失敗しました。サポートが調査できるよう、バンドルはそのまま残します。"
MSG_OK_UNINSTALLER_APP_STAGED="Ostler Uninstaller.appを %s にインストールしました"
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="Ostler Uninstaller.app を /Applications に配置できませんでした。次のコマンドを実行すればアンインストールできます: ~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="Doctor エージェントをクローンしています..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="メール取り込みスクリプトをクローンしています..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Hub 電源管理スクリプトをクローンしています..."
MSG_INFO_CLONING_IMPORT_PIPELINE="インポートパイプラインをクローンしています..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="Wiki 再コンパイルスクリプトをクローンしています..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima はインストール済みですが、起動していません。起動します。"
MSG_INFO_COLIMA_START_ATTEMPT="Colima を起動しています（%s 回目 / 最大 %s 回）..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="連絡先を書き出せませんでした。後で手動で読み込めます。"
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="連絡先カードを読み取れませんでした。問題ありません。代わりにお尋ねします。"
MSG_INFO_CONTACT_CARD_WILL_ASK="このあと、お名前と国をお尋ねします。連絡先は、あなたが許可したフルディスクアクセスを使って後で読み取られ、データがこの Mac の外に出ることはありません。"
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  %s に Python venv を作成しています..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="ユーザー向けコンテンツツリーを %s/ に作成しています"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="毎日の実行です。手動で実行するには: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="デスクトップ型の Hub（バッテリーなし）を検出しました。システム全体でスリープを無効にします"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker がインストールされていません。Colima、Docker CLI、docker-compose プラグインをインストールします（軽量で、Docker Desktop は不要です）。"
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="Doctor エージェントのファイルがインストーラに同梱されていません。"
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="メール取り込みスクリプトがインストーラに同梱されていません。"
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="メール取り込みスクリプトがインストーラのバンドルに含まれていません。ostler.ai/install から .app をもう一度ダウンロードして、再試行してください。"
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="メール取り込みスクリプトが同梱されておらず、--allow-plaintext が指定されたため、LaunchAgent のインストールはスキップされます。今後のメールは取り込まれません。"
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  %s に既存のチェックアウトがあります。更新しています..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Takeout の zip から Gmail の mbox を展開しています（大きなアーカイブでは1分ほどかかります）..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="FDA 抽出モジュールが同梱されていません。データの即時抽出をスキップします。"
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Ostler Pro の最初の30日間を有効にしています..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="Ostler Pro はトライアル終了後、月額 \$9.99 USD です。iPhone の Ostler app でご登録ください。"
MSG_INFO_FOUND_GMAIL_MBOX_MB="Gmail の mbox が見つかりました: %s（%s MB）"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="Google Takeout の zip が見つかりました: %s（%s MB）"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="フルディスクアクセスを検出しました。完全な抽出を利用できます。"
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="GDPR エクスポートを検出しましたが、インポートパイプラインはまだ利用できません。"
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="GDPR エクスポートのインポートは、パイプラインの提供開始後に利用できます。"
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="ダウンロード、デスクトップ、書類フォルダ内に保存されている可能性のある AI エクスポート（Google Takeout、Meta のダウンロード、LinkedIn など）をスキャンします。macOS からフォルダへのアクセス確認が3回表示されますので、それぞれ許可してください。所要時間は合計で5～10秒ほどです。スキャン中にファイルが移動またはコピーされることはなく、何があるかを確認するだけです。"
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS からカレンダーの読み取り許可を求められる場合があります。Ostler があなたのナレッジグラフの会議や予定の部分を作成できるよう、許可してください。（カレンダーのデータはこの Mac の外に出ません。）"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS がダウンロードフォルダへのアクセス許可を求めています。「OK」をクリックしてください。"
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS がデスクトップフォルダへのアクセス許可を求めています。「OK」をクリックしてください。"
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS が書類フォルダへのアクセス許可を求めています。「OK」をクリックしてください。"
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="フルディスクアクセスが許可されました。次の macOS の確認（メッセージのオートメーション）を準備しています..."
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="メッセージの許可確認に応答がなかったため、先に進みました。許可されるまで、メッセージは読み取られません。Ostler が後で再度確認しますが、「システム設定」>「プライバシーとセキュリティ」>「オートメーション」で許可することもできます。"
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="Xcode コマンドラインツールが必要です。macOS からインストールの許可を求められます。小さなグレーのダイアログを探してください（表示されない場合は Cmd+Tab を押すか、Dock を確認してください）。「インストール」をクリックします。ツールは、以下の質問に答えている間にバックグラウンドでダウンロードされます。"
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  コマンドラインツールをまだセットアップしています(%s 秒)。開発者ツールのインストールを求める小さなグレーの macOS ダイアログが表示されている場合は、「インストール」をクリックしてください。この手順はその操作を待っています。(見つからない場合は Cmd+Tab を押すか、Dock を確認してください。)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="コマンドラインツールのインストールが完了するのを待っています(もうすぐです)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="1時間ごとに実行します。初回は過去5年分のメールを取得します。"
MSG_INFO_IMESSAGE_BRIDGE_STARTED="従来の iMessage ブリッジ LaunchAgent を無効にしています(単一マシン v1.0)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="AC電源のみの Hub です(バッテリーが検出されませんでした)。hub-power LaunchAgent をスキップします。"
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Hub の電源管理スクリプトはインストーラに含まれていません。"
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="ノート型の Hub です。蓋を開けていて、電源に接続している間は動作し続けます。"
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="蓋を閉じるか、バッテリー駆動のまま放置すると、macOS によって Mac がスリープします。"
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="スリープ中、アシスタントは何も受信しません。"
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="その間に届いたメッセージは、復帰しても取得されません。"
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="クラムシェルモードなら、蓋を閉じたままにできます。"
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="それには、電源への接続と、外付けディスプレイ、キーボード、マウスが必要です。"
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="Docker と Ollama は、バッテリー駆動中は一時停止し、電源に接続すると再開します。"
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="再起動後は、FileVault によりこの Mac はログイン画面で待機します。"
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="Ostler は、サインインすると起動します。"
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="アシスタント API はインストーラに含まれています。同梱のソースを使用します。"
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="アシスタント API のソースが含まれていないため、iPhone の Ostler app のアクセスは制限されます。"
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="アシスタント API の実行時依存関係(phonenumbers、httpx)をインストールしています..."
MSG_WARN_ICAL_SERVER_DEPS_FAILED="アシスタント API の実行時依存関係(phonenumbers/httpx)をインストールできませんでした。次回のインストール実行まで、人物とタイムラインが空のままになる場合があります。"
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Tailscale のウインドウが表示されたら、Apple / Google / Microsoft でサインインしてください。"
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="サインインできるように Tailscale を開いています..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="了解しました。ここから先、Ostler はほとんど自動でインストールされます。終盤で、約2分だけ操作をお願いします。フルディスクアクセスをオンにし、続いて Tailscale にサインインして、iPhone と Watch がどこからでもこの Mac に接続できるようにします。サインインのためにブラウザを開きます。"
MSG_INFO_TAILSCALE_SKIPPED="Tailscale をスキップしました。iPhone の Ostler app は自宅の Wi-Fi でのみ動作します。設定であとからセットアップできます。"
MSG_INFO_TAILSCALE_STILL_WAITING="Tailscale のサインインをまだ待っています(%s 秒経過)。Tailscale のウインドウでサインインを完了してください。"
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="フルディスクアクセスが許可されました。新しい権限を反映するため、アシスタントを再起動します。"
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="システム設定と Finder を開き、アシスタントにフルディスクアクセスを許可する手順をご案内します..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="フルディスクアクセスにスイッチとして表示されるよう、Ostler アシスタントを macOS に登録しています..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="フルディスクアクセスはまだ許可されていません。許可されるまで、Doctor ダッシュボードにカードが表示され続けます。"
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant にはすでにフルディスクアクセスがあります。これ以上の操作は不要です。"
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="ここで約2分だけ操作が必要です。今すぐアシスタントのフルディスクアクセスをオンにし、次の手順で Tailscale にサインインしてください。その後は、Ostler に任せて完了を待つだけです。"
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="ここで約1分だけ操作が必要です。アシスタントのフルディスクアクセスをオンにしてください。その後は、Ostler に任せて完了を待つだけです。"
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="「%s」はすでにフルディスクアクセスに表示されているため、オンにするだけで大丈夫です。Finder からドラッグする必要はありません。"
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Ostler アシスタントにフルディスクアクセスがあるか確認しています..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="アシスタントは「メッセージ」の履歴を読み取れます。iMessage チャンネルが動作します。"
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="Ostlerアシスタントにはまだフルディスクアクセスが許可されていません。メッセージを使うかどうかにかかわらず、Macの標準アプリを最新の状態に保つために必要です。今はスキップしても、Doctorダッシュボードがシステム設定での手順を案内します。"
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="アシスタントのLaunchAgentが読み込まれなかったため、iMessageのフルディスクアクセスの確認をスキップします。"
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="DoctorのEvernote読み込み画面に「サービスを利用できません」と表示されます"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="読み込みパイプラインはインストーラに含まれていません。"
MSG_INFO_INSTALLING_CM042="Ostler RemoteCapture v%s(通話と会議の文字起こし)をインストールしています…"
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="%s から会話メモリエンジンをインストールしています…"
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  会話メモリエンジンをvenvにインストールしています…"
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="ColimaとDocker CLIをインストールしています…"
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="GNU coreutilsをインストールしています(時間のかかる手順のタイムアウト制限用)…"
MSG_INFO_INSTALLING_HOMEBREW="Homebrewをインストールしています…"
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="%s からナレッジサービスをインストールしています…"
MSG_INFO_INSTALLING_OLLAMA="Ollamaをインストールしています…"
MSG_INFO_INSTALLING_OLLAMA_PINNED="Installing Ollama %s (verified release)..."
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  データ抽出モジュールの依存関係をインストールしています…"
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Apple Mailリーダーを専用のvenvにインストールしています…"
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  ostler-knowledgeをvenvにインストールしています…"
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  暗号化ストレージの依存関係を会話メモリのvenvにインストールしています…"
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Safari機能拡張を/Applicationsにインストールしています"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="セキュリティ用のPython依存関係をインストールしています…"
MSG_INFO_INSTALLING_SQLCIPHER="SQLCipherをインストールしています…"
MSG_INFO_INSTALLING_TAILSCALE="Tailscaleをインストールしています…"
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="Intel搭載Macへの対応は予定されていません。必要な場合はリクエストをお送りください。"
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="ナレッジサービスはインストーラに含まれています。同梱のソースを使用します。"
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="ナレッジサービスはインストールされていません: PWG_KNOWLEDGE_REPOが空です。"
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="このMacはノートブックです。Hubとして使う場合、蓋を開けたまま電源に接続している間は動作し続けます。"
MSG_INFO_LAPTOP_HUB_SLEEP_COST="蓋を閉じた場合や、バッテリー駆動でアイドル状態になった場合、macOSはスリープします。スリープ中はアシスタントは何も受信できず、その間に届いたメッセージは復帰後も取得されません。"
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="クラムシェルモードなら蓋を閉じたまま使えますが、電源接続に加えて、外部ディスプレイ、キーボード、マウスが必要です。"
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="Mac mini や Mac Studio の Hub なら、何もしなくてもスリープしません。そちらにインストールしたい場合はどうぞ。"
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="あとで システム設定 > プライバシーとセキュリティ > フルディスクアクセス で設定"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  起動して、cron配信とimessage-tccの状態を確認してください)。"
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="ライセンス: %s はApache 2.0です。全文: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="Licence: %s – check upstream terms before commercial use."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="ローカルストア – GoogleにはOstlerの存在が一切知られません。"
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="ログ: %s/email-ingest.log(および .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="ログ: %s/ostler-assistant.log(および .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="ログ: %s/wiki-recompile.log(および .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="MacBookのHub: PWG_HUB_POWER_REPO=<url> を設定して、再実行してください。"
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="MacBook Hubを検出しました。AC電源接続時のみスリープしない設定にします(バッテリーへの切り替えはhub-powerが処理します)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Mac miniとMac Studioでの運用には影響しません(常時AC電源接続のため)。"
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Mac側のデータ(iMessage、Safariなど)は上で抽出されました。"
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="手動で再起動: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="手動実行: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="com.ostler.meeting-brief-sender のインストールをスキップします(v1.0.1 の機能で、エンドポイントはまだ提供されていません)。"
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="メモリ整理の処理をスキップします(このインストーラには含まれていません)。含まれるまでは、重み付けの自動的な引き下げは行われません。"
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="機能フラグが後でオンになったときのメッセージ。"
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="お困りですか?support@ostler.ai までメールでご連絡ください。2営業日以内の返信を目指しています。"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="チャンネルが設定されていません。後で実行してください: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="ワークスペースのルートにあった古い従来の config.toml を削除しました。現在使用中のアシスタント設定は assistant-config/ にあります。"
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="現在利用できる FDA ソースはありません。フルディスクアクセスを許可できます"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="ダウンロード、デスクトップ、書類に GDPR エクスポートが見つかりませんでした。"
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="データエクスポートを探すために %s を読み取れませんでした。macOS がそのフォルダへのアクセスをブロックしています。"
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="システム設定 > プライバシーとセキュリティ > ファイルとフォルダ(またはフルディスクアクセス)でアクセスを許可してから再実行するか、下で Ostler にエクスポートフォルダを手動で指定してください。"
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="macOS によってアクセスがブロックされたため、1つ以上のフォルダでデータエクスポートをスキャンできませんでした。アクセスを許可して再実行するか、エクスポートフォルダを手動で指定してください。"
MSG_INFO_OPENING_CHROME_WEB_STORE="Chrome ウェブストアを開いています: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="ostler-assistant バイナリがインストールされていないため、doctor プローブをスキップします"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: 保留(デーモンがまだ"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="この DMG に同梱されている ostler-assistant バイナリを使用します(オフライン対応のインストール経路)。"
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge を venv にインストールしました。"
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler will show an extra consent screen before installing"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  会話メモリエンジンのソースリポジトリは、./install.sh --help に記載の環境変数で上書きできます。"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  ソースリポジトリは PWG_DOCTOR_REPO=<url> ./install.sh で上書きできます"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  ソースリポジトリは PWG_HUB_POWER_REPO=<url> ./install.sh で上書きできます"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  ソースリポジトリは PWG_KNOWLEDGE_REPO=<url> ./install.sh で上書きできます"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  ソースリポジトリは PWG_PIPELINE_REPO=<url> ./install.sh で上書きできます"
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="Persisting consent records and region..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="フェーズ3のバッテリー監視を開始しました(PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="アドレスブックを読み込んでいます(大規模なライブラリでは数分かかることがあります。インストーラを閉じないでください)…"
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="ポリシーの上書き: ~/.ostler/power.conf を編集してください(normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="iMessage のオートメーション権限を確認しています(読み取り専用)…"
MSG_INFO_PULLING_GRAPH_DB_IMAGES="ナレッジグラフのデータベースをダウンロードしています(初回のみ)。新規インストールでは1分ほどかかることがあります…"
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="nomic-embed-text(274 MB)を取得しています…"
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="%s(%s)を取得しています…数分かかることがあります。"
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="隔離 xattr を解除しました。Developer ID ビルドが"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Safari、iMessage、メモ、カレンダー、写真、リマインダー、メールを読み込んでいます…"
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="連絡先カードを読み込み、あなたの情報を事前入力しています…"
MSG_INFO_REGION_EU_EEA_SOURCE="地域: EU/EEA(%s、ソース: %s)"
MSG_INFO_REGION_SOURCE="地域: %s(ソース: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="地域: イギリス (ソース: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="地域: アメリカ合衆国 (ソース: %s)"
MSG_INFO_REPO_URL="リポジトリURL: %s"
MSG_INFO_REPO_URL_2="リポジトリURL: %s"
MSG_INFO_REPO_URL_3="リポジトリURL: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="次に、Hubのロックを解除するパスフレーズを設定します。Hub UIを起動するたびに入力します。"
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="リカバリー用パスフレーズをスキップしました。(非推奨: v1.0ではパスフレーズが常に必要です。)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="既存のDoctorエージェントのインストールを再利用します: %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="既存のemail-ingestのインストールを再利用します: %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="既存のhub-powerのインストールを再利用します: %s"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="既存のブラウザ拡張機能キーを再利用します: %s"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="Chrome用のOstler拡張機能は、このリリースには含まれていません。"
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="Email conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="メールの会話: 設定していません。このMacでApple Mailが設定されていないためです。"
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="Messages conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="メッセージの会話: 設定していません。このMacにメッセージの履歴がないためです。"
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  Ostlerで通話を文字起こしすると、自動的にオンになります。"
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="音声会話: まだ設定していません。読み取る文字起こしがないためです。"
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="音声会話: オフにしました。Ostlerのインストール後に「Transcripts」フォルダが削除されたためです。"
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  オンに戻すには %s を作り直してください。Ostlerは自動では作り直しません。"
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="WhatsApp conversations: not set up, because you did not agree to Ostler reading other people's messages."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="WhatsAppの会話: 設定していません。WhatsAppがオフになっているためです。"
MSG_INFO_CHROME_HISTORY_STILL_READ="  OstlerはChromeの履歴を引き続き読み取るため、訪問したページは記憶されます。閲覧中のライブキャプチャは、現時点ではSafariのみ対応です。"
MSG_INFO_REUSING_EXISTING_JWT_SECRET="既存のJWT_SECRETを再利用します: %s"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="既存のPWGサービストークンを再利用します: %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="既存のwiki-recompileのインストールを再利用します: %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="Safari拡張機能のバンドルは、このインストーラのビルドに含まれていません(スキップします)"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="手動での操作が1つ残っています。Safariを開き、「Safari」>「設定」>「機能拡張」を選んで、Ostlerにチェックを入れて有効にしてください。"
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="GDPRデータエクスポートを検索しています..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="PWG_DOCTOR_REPO=<url> を設定してから、再実行してインストールしてください。"
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="PWG_HUB_POWER_REPO=<HR015 url> を設定してから、再実行してインストールしてください。"
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="会話モデルをスキップしました。後で取得するには: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Colima(軽量Dockerランタイム)を起動しています..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Docker Desktopを起動しています..."
MSG_INFO_STARTING_OLLAMA="Ollamaを起動しています..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="旧バージョンが残した古いColimaの起動項目を削除しています..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="従来のOllama formula(llama-serverなし)を削除し、Ollamaアプリに切り替えています..."
MSG_INFO_VERIFYING_EMBEDDINGS="埋め込みエンジンがベクトルを返すことを確認しています..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="Ollamaを自動で起動できませんでした。次のコマンドで読み込んでください: launchctl bootstrap gui/\$(id -u) %s – その後、インストーラを再実行してください。"
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="Ollamaがバックグラウンドサービス経由で起動しませんでした。今回は直接起動します..."
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  初回起動後に \`ostler-assistant doctor\` を実行してください"
MSG_INFO_SYMLINKING="  %s -> %s のシンボリックリンクを作成中"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(システム設定 > インターネットアカウント)。Ostlerは「メール」の"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(Doctorダッシュボードがなくても、Ostlerのそれ以外の機能は動作します。)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="現時点では想定どおりの動作です。GDPRデータの読み込みは、今後のアップデートで利用できるようになります。"
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="通常は15〜45分ほどかかります。履歴が多い場合やMacの処理速度が遅い場合は、さらに長くかかることがあります。これは正常な動作で、止まっているのではなく処理中ですので、そのまま実行したままにしておいてかまいません..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="macOSのデータベースを直接読み取るため、書き出しは不要です。"
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="ヒント: Gmailを含めるには、先にMacの「メール」にGmailを追加してください"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="アクセスできるようになった後でインストールするには:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="%s のiCloud同期を開始しています(通知なし、初回のみ)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (UK GDPR Article 9 - required for special-category data)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="既存のパイプラインを更新しています..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="ユーザー向けツリーはすでに通知済みです(センチネルあり)。スキップします"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="ローカルWeb検索エンジン(約3.5 GB)をダウンロードしています。初回インストールでは最も時間のかかる手順で、最大1時間ほどかかることがあります。進行状況バーは表示されないため、しばらく何も表示されなくても正常で、インストールが止まったわけではありません。"
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vaneが応答していません(任意。フェーズ3.8bの警告を参照)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="いつでも次のコマンドで確認できます: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="音声認識はオフのままになります。あとから設定で有効にできます。"
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="Tailscaleへのサインインをお待ちしています(最大3分)..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="Tailscaleによる遠隔アクセスは設定されませんでした。iPhoneのOstlerアプリは自宅のWi-Fiで使えます。遠隔アクセスは、あとから設定で行えます。"
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="このMacはすでにTailscaleネットワークに接続されているため、設定は不要です。現在の接続を維持します。"
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="遠隔アクセス: 前回の回答(設定しない)を維持します。iOSアプリは自宅のWi-Fiで使え、遠隔アクセスはあとから設定で行えます。"
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="遠隔アクセス: 前回の回答(設定する)を維持します。"
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="WhatsAppコネクタはオフのままです。あとから設定で有効にできます。"
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="WhatsAppのキープアライブを08:50と17:50にスケジュールしました(ラベル com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="初日のWiki追い付き処理をスキップします: wiki-recompileのティックがインストールされていません。毎日のWiki再構築は、インストールされていれば引き続き実行されます。"
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="Wiki再コンパイル用スクリプトはインストーラに含まれていません。"
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="Wikiは自動更新されません。初回コンパイルは手動で再実行できます:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="ポスチャーマーカーを書き込みました: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="書き出したデータは安全です。あとから次のコマンドで読み込めます: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="Macのデータ(iMessage、Safariなど)は、上ですでに抽出済みです。"
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="あとから追加すると、Safari、iMessageなどからすぐに取り込めます。"

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="AIモデル: %s(%s) – お使いの %s GB のRAMに合わせて選択"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="動作可"
MSG_MODELFIT_PILL_SLOW="遅い場合あり"
MSG_MODELFIT_PILL_NOFIT="動作不可"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="アシスタントのモデルをMacに合わせています(%s、%s GB RAM、アシスタントのコンテキスト %s トークン):"
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- おすすめ"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="AIモデル: %s(%s) – アシスタントに必要なコンテキストウィンドウで、お使いの %s GB のRAMに最適"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="すべてのソースを選択しました(顔認識はオフのままです)"
MSG_OK_ALREADY_AVAILABLE="%s はすでに利用可能です"
MSG_OK_APPLE_SILICON_DETECTED="Appleシリコンを検出しました"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="iCloud の同期を開始するためにAppを起動しました"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="Appのデータベースはすでに存在します(事前起動をスキップ)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="アシスタントの設定を %s に保存しました(モード 0600)"
MSG_OK_BACKED_UP_CONTACTS="%s 件の連絡先を %s にバックアップしました"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s を %s にインストールしました"
MSG_OK_CM042_LAUNCHAGENT_LOADED="Ostler RemoteCapture の LaunchAgent を読み込みました(ラベル %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima と Docker CLI をインストールしました"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="コンテナランタイムの監視機能をインストールしました(5分ごとに確認し、停止していれば再起動します)"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="コンテナランタイムの監視機能を登録できませんでした。Ostler のインストールは続行しますが、ランタイムが後で停止しても自動では復旧しません。インストーラを再実行するまで、Wiki は停止したままになります。"
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="コンテナランタイムの監視機能のファイルがこのインストーラに含まれていないため、登録しませんでした。Ostler のインストールは続行しますが、ランタイムの自動復旧は有効になりません。"
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
# NEEDS REVIEW: Confirm whether the page name 'Governor' should be kept in English or localised to match the app's Japanese UI.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="Ostler の Doctor ダッシュボードを起動できなかったため、http://localhost:8089 は応答しません。ここから情報を読み込む App 内のページ(人物、タイムライン、Governor、チャンネルの状況)は、Doctor が起動するまで利用できないと表示されます。もう一度試すには、インストーラを再実行してください。"
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="スリープ防止ヘルパーを登録できませんでした。Ostler は引き続き動作しますが、長時間のバックグラウンド処理中にこの Mac がスリープすることがあり、処理は一晩で完了せず、復帰後に再開されます。"
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="バックグラウンドの補完ヘルパーを登録できなかったため、新しいメッセージ、メール、カレンダーの項目は自動では取り込まれません。復旧するには、インストーラを再実行してください。"
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="%s not set up: Ostler has no record of your answer to the question that governs it, so it did not assume one."
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  Re-run Ostler and choose to answer the questions again to turn it on. (consent record: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="デイリーブリーフを登録できなかったため、朝のサマリーは届きません。ほかの機能は問題なく動作します。復旧するには、インストーラを再実行してください。"
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="メモリーの整理処理を登録できなかったため、古くなった情報や更新済みの情報の重みは自動では下げられません。ほかの機能は問題なく動作します。復旧するには、インストーラを再実行してください。"
MSG_WARN_EXPORT_SCAN_NOT_LOADED="ダウンロードフォルダの監視を開始できなかったため、ダウンロードに入れたファイルは自動では取り込まれません。すでに読み込んだ内容には影響せず、App 内からファイルを追加することもできます。復旧するには、インストーラを再実行してください。"
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="デバイス登録の再試行ヘルパーを登録できませんでした。セットアップ中に iPhone が登録されていれば影響ありません。登録されていない場合は、自動では完了しないため、App からもう一度ペアリングする必要があります。"
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="コンテナランタイムが応答しています"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="古いバージョンが残した Colima の起動項目を削除しました"
MSG_OK_CONFIG_SAVED_ENV="設定を %s/.env に保存しました"
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="Consent records and region persisted to ~/.ostler/posture/"
MSG_OK_AT_REST_EXCLUDED="Spotlight と Time Machine の対象外にしました(確認済み): %s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s は Time Machine または Spotlight の対象から除外されていません: %s。Ostler の機密情報を含む内容が、バックアップディスクにコピーされる可能性があります。修正されるまで、Doctor にはこの警告が表示され続けます。"
MSG_INFO_AT_REST_FOLDER_ABSENT="%s はまだ存在しないため、バックアップから除外する対象がありません。"
MSG_WARN_DB_KEY_NOT_EXCLUDED="データベースの鍵ファイル %s は Time Machine の対象から除外されていないため、バックアップディスクにコピーされる可能性があります。"
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="バックグラウンド補完の選択内容を ~/.ostler/posture/ に保存できませんでした。選択内容はこのインストールには引き続き適用されますが、サポートレポートには表示されません。"
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="データベースを暗号化しました。Hub のサービスは、ホームフォルダ内の保護されたファイルから鍵を読み込むため、入力を求められることなく起動します。"
MSG_OK_DB_KEY_DELIVERED="データベースの鍵を Hub のサービスに渡しました(%s、あなただけが読み取れます)。"
MSG_WARN_DB_KEY_NOT_DELIVERED="データベースの鍵を Hub のサービスに渡せませんでした。修正されるまで、データベースは暗号化されないまま開かれます。"
MSG_INFO_DB_KEY_RECOVER_HINT="次のコマンドを実行して、鍵を復旧し渡してください: %s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="以前のインストールから残っているデータベースを暗号化しています"
MSG_WARN_DB_MIGRATION_FAILED="既存のデータベースの一部を暗号化できませんでした。ディスク上で読み取れる状態のままです。"
MSG_WARN_DB_KEY_MISSING_ON_RERUN="このインストールにはデータベースの鍵ファイルがないため、Hub のサービスはデータベースを暗号化せずに開いています。"
MSG_WARN_DB_PLAINTEXT_COUNT="この Mac 上の %s 個のデータベースは、現在ディスク上で読み取れる状態です。"
MSG_INFO_DB_MIGRATE_HINT="その後、すでにあるデータを暗号化してください: %s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="保留中のデバイス登録の再試行をインストールしました(キューが空になるまで1時間ごとに実行)"
MSG_OK_DOCKER_RUNNING="Docker が実行中です"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker が実行中です(%s秒かかりました)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="Doctor エージェントを %s からクローンしました"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Doctor エージェントのファイルをインストーラに同梱しました"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Doctor の依存関係をインストールしました"
MSG_OK_EMAIL_CHANNEL_FOLDER="メールチャンネル: %s(フォルダ: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="メール取り込み用 LaunchAgent を読み込みました(ラベル com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="メール取り込みスクリプトをインストーラに同梱しました"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="メール取り込みスクリプトを %s からクローンしました"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="WhatsApp の会話メモリを設定しています"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  WhatsApp 会話リーダーをインストールしました。"
MSG_WARN_WHATSAPP_SOURCE_FAILED="WhatsApp 会話リーダーのインストールに失敗しました。WhatsApp 会話フィードは実行されません。上の出力を確認してください。"
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="WhatsApp 会話リーダーのソースが見つかりません。WhatsApp 会話フィードをスキップします。"
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="このインストーラに WhatsApp 会話フィードのパッケージが見つかりません。スキップします。WhatsApp のメッセージ履歴(誰といつメッセージしたか)には影響しません。"
MSG_OK_WHATSAPP_BUNDLE_LOADED="WhatsApp 会話フィード用 LaunchAgent を読み込みました(ラベル com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  最初の実行では、Mac が同期した最近の WhatsApp の会話(約1年分)を読み取ります。データは Mac の外には出ません。"
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  ログ: %s/whatsapp-bundle.log と whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="WhatsApp 会話フィード用 LaunchAgent のインストールに失敗しました。上の出力を確認してください。それ以外のインストールには影響しません。"
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  まだ開始していません: このエージェントが実行するアシスタントのプログラムがディスク上にありません。確認した場所: %s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="メールの会話メモリを設定しています"
MSG_OK_EMAIL_SOURCE_INSTALLED="  メール会話リーダーをインストールしました。"
MSG_WARN_EMAIL_SOURCE_FAILED="メール会話リーダーのインストールに失敗しました。メール会話フィードは実行されません。上の出力を確認してください。"
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="メール会話リーダーのソースが見つかりません。メール会話フィードをスキップします。"
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="このインストーラにメール会話フィードのパッケージが見つかりません。スキップします。1時間ごとのメール取り込みには影響しません。"
MSG_OK_EMAIL_BUNDLE_LOADED="メール会話フィード用 LaunchAgent を読み込みました(ラベル com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Apple Mail のローカルストアから最近のメールスレッドを読み取ります。すべてのデータは Mac の中にとどまります。"
MSG_INFO_EMAIL_BUNDLE_LOGS="  ログ: %s/email-bundle.log と email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="メール会話フィード用 LaunchAgent のインストールに失敗しました。上の出力を確認してください。それ以外のインストールには影響しません。"
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="会議と音声の会話メモリを設定しています"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  会議・音声会話リーダーをインストールしました。"
MSG_WARN_SPOKEN_SOURCE_FAILED="会議・音声会話リーダーのインストールに失敗しました。フィードは実行されません。上の出力を確認してください。"
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="会議・音声会話リーダーのソースが見つかりません。フィードをスキップします。"
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="このインストーラに会議・音声会話フィードのパッケージが見つかりません。スキップします。"
MSG_OK_SPOKEN_BUNDLE_LOADED="会議・音声会話フィード用 LaunchAgent を読み込みました(ラベル com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  ご自身の会議や音声メモを文字に起こし、検索できる会話にします。すべてのデータは Mac の中にとどまります。"
MSG_INFO_SPOKEN_BUNDLE_LOGS="  ログ: %s/spoken-bundle.log と spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="会議・音声会話フィード用 LaunchAgent のインストールに失敗しました。上の出力を確認してください。それ以外のインストールには影響しません。"
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="iMessage の会話メモリを設定しています"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  iMessage 会話リーダーをインストールしました。"
MSG_WARN_IMESSAGE_SOURCE_FAILED="iMessage 会話リーダーのインストールに失敗しました。iMessage 会話フィードは実行されません。上の出力を確認してください。"
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="iMessageの会話リーダーのソースが見つかりません。iMessage会話フィードをスキップします。"
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="このインストーラにiMessage会話フィードのパッケージが見つかりません。スキップします。"
MSG_OK_IMESSAGE_BUNDLE_LOADED="iMessage会話フィードのLaunchAgentを読み込みました(ラベル: com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  このMacの「メッセージ」のデータから最近のiMessage会話を読み取ります。すべてのデータはMac上にとどまります。"
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  ログ: %s/imessage-bundle.log と imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="iMessage会話フィードのLaunchAgentのインストールに失敗しました。上の出力を確認してください。インストールのその他の部分には影響しません。"
MSG_OK_EMBEDDING_MODEL_READY="埋め込みモデルの準備ができました"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="%s件の連絡先を書き出しました(自動的に読み込まれます)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="書き出しウォッチャーをインストールしました(4時間ごとにダウンロードフォルダを確認します)"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  書き出しウォッチャーはまだ開始されていません。実行するアシスタントのプログラムがディスク上にありません。確認した場所: %s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="ミーティング前ブリーフの送信機能をインストールしました(起きている時間帯は10分ごとに確認します)"
MSG_OK_MEMORY_HYGIENE_INSTALLED="メモリーの整理をスケジュールしました(毎日実行し、古い情報が最新の情報を押しのけないようにします)"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="Ostlerが動き続けるよう、電源に接続中はMacがスリープしません(バッテリー駆動時はスリープします)"
MSG_OK_EXTRACTED="%sに展開しました"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="%s個のソースから抽出しました。データは%s/imports/fda/に保存されました"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="FDAの再実行を%s分ごとにスケジュールしました(iCloudの遅い同期に対応し、カレンダーの取り込みを完了させます)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Proは30日間ご利用いただけます。体験期間後も続けるには、iPhoneのOstlerアプリで購読してください。"
MSG_OK_FOUND="見つかりました: %s"
MSG_OK_FOUND_EXPORTS="%sにエクスポートが見つかりました"
MSG_OK_FOUND_GDPR_EXPORT_S="%s件のGDPRエクスポートが見つかりました:"
MSG_OK_GB_FREE_DISK_SPACE="ディスクの空き容量: %s GB"
MSG_OK_GB_RAM_DETECTED="RAMを%s GB検出しました"
MSG_OK_GDPR_IMPORT_COMPLETE="GDPRエクスポートの読み込みが完了しました"
MSG_OK_GIT_AVAILABLE="Gitを利用できます"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="コマンドラインツールのインストールを開始しました(以下の質問に答えている間、バックグラウンドでダウンロードします)。"
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutilsをインストールしました(時間のかかる手順に時間制限を設けました)"
MSG_OK_HOMEBREW_INSTALLED="Homebrewをインストールしました"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="Hub電源のLaunchAgentを読み込みました(ラベル: com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Hub電源のスクリプトはインストーラに同梱されています"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="Hub電源のスクリプトを%sからクローンしました"
MSG_OK_ICAL_SERVER_INSTALLED="アシスタントAPIをインストールしました(ループバック 127.0.0.1:8090、Doctor経由でプロキシ)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="iMessageブリッジのLaunchAgentを読み込みました(ラベル: com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="iMessageブリッジのスクリプトはインストーラに同梱されています"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="iMessageブリッジのスクリプトを%sからクローンしました"
MSG_OK_IMESSAGE_CHANNEL="iMessageチャンネル: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="読み込みパイプラインはインストーラに同梱されています"
MSG_OK_IMPORT_PIPELINE_READY="読み込みパイプラインの準備ができました"
MSG_OK_CM048_PIPELINE_READY="会話メモリーエンジンの準備ができました。"
MSG_INFO_CM048_SETTINGS_WRITTEN="  会話モデルを%sに設定しました(お使いの%s GBのメモリーに合わせています)"
MSG_INFO_CM048_SETTINGS_KEPT="  既存の会話設定を維持します (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="ナレッジサービスの準備ができました: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="ライセンス文書を %s/ にインストールしました (ソース: %s)"
MSG_OK_MACOS_DETECTED="macOS %s を検出しました"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="システム設定 > インターネットアカウントを開いています。メールアカウントを追加してください。最初のアカウントにサインインしたら、このウインドウに戻ってください。"
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="インターネットアカウントの手順をスキップします。メールアカウントは後からシステム設定で追加できます。24時間以内にメールが届かない場合、Doctor がフォローアップを表示します。"
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Apple Mail の全履歴を取得しています。メールボックスが大きい場合は、少し時間がかかることがあります。"
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="標準の5年分のメール範囲を維持します。さらに多くの履歴は後から Doctor で取得できます。"
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text は既に利用可能です"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="Ollama をインストールしました"
MSG_WARN_OLLAMA_CUSTOMER_APP_PRESENT="An Ollama app is already installed in Applications. Ostler leaves it exactly as it is and runs its own copy of Ollama %s alongside it. If that app is open in the menu bar, quit it so Ostler can start its own."
MSG_WARN_OLLAMA_PIN_DEFERRED="Could not update Ollama to %s this time, so Ostler is keeping the copy it already runs (%s). Your assistant keeps working. The update will be tried again the next time the installer runs. Details: %s"
MSG_WARN_MODEL_PULL_HELD_OLLAMA_UNPINNED="Not downloading %s this time: Ostler's tested copy of Ollama (%s) is not installed yet, and a different Ollama could fetch the wrong build. The next installer run downloads it."
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama をインストールしました (CLI のみ – 再起動後に手動で起動が必要な場合があります)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama をインストールしました (デスクトップアプリ)"
MSG_OK_OLLAMA_RUNNING="Ollama は実行中です"
MSG_OK_EMBEDDINGS_VERIFIED="埋め込みエンジンを確認しました (768次元ベクトル)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: 自身の起動チェックでエラーは0件でした"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="Ostler アシスタントの LaunchAgent を読み込みました (ラベル com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s を %s に配置しました (署名済み)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s を %s に配置しました (未署名)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor が http://localhost:8089/doctor で実行中です"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  データ抽出モジュールは正しく読み込まれます。"
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Apple Mail リーダーをインストールしました。"
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  メール取り込みエンジンをインストールしました。"
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="ostler-import、ostler-fda、ostler-uninstall コマンドをインストールしました"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="パスフレーズを記録しました。フェーズ3でデータベースの暗号化に使用されます。"
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="リカバリー用パスフレーズを設定しました。"
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="パスフレーズの説明を確認しました。"
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="Disney+ のエクスポート用パスワードを記録しました。インポート時に使用されます。"
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="Disney+ のエクスポートをスキップします: パスワードが入力されていません。他には影響しません。"
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="電源: AC (デスクトップ Mac、バッテリーなし)"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="電源: AC (良好 – インストールには45分から数時間かかることがあるため、AC電源なら安定します)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="以前のインストールを検出しました。設定を読み込んでいます..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="同梱の Python %s を使用します (システムへのインストールは不要です)"
MSG_OK_PYTHON_INSTALLED="Python %s をインストールしました"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="ペアリングサービスは正常です"
MSG_WARN_GATEWAY_NOT_RESPONDING="ペアリングサービスが応答していません (127.0.0.1:8000)。iPhone/ブラウザのペアリングとチャットアシスタントがまだ動作しない可能性があります"
MSG_OK_DOCTOR_HEALTHY="Doctor は正常です"
MSG_WARN_DOCTOR_NOT_RESPONDING="Doctor が応答していません (127.0.0.1:8089)。App とブラウザは Doctor 経由で Ostler に接続するため、データやペアリングを利用できない可能性があります"
MSG_OK_WIKI_HEALTHY="Wiki は正常です"
MSG_OK_ICAL_SERVER_HEALTHY="アシスタント API は正常です"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="アシスタント API が応答していません (127.0.0.1:8090)。起動するまで、人物、ミーティング、タイムラインが空になる場合があります"
MSG_OK_READY="%s の準備ができました"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="推奨ソースを選択しました"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="リカバリキーをキーチェーンに保存しました (パスワード App で「Ostler」を検索)"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Safari 機能拡張を %s にインストールしました"
MSG_OK_SAFARI_EXTENSION_PAIRED="Safari 機能拡張をこの Hub とペアリングしました"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="セキュリティは前回の実行時にすでに設定されています。"
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="セキュリティモジュールを venv にインストールしました"
MSG_OK_SEEDED_FRESH_JWT_SECRET="新しい JWT_SECRET を %s に設定しました"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="PWG サービストークンを %s に設定しました"
MSG_OK_SEEDED_EXTENSION_TOKEN="ブラウザ機能拡張キーを %s に設定しました"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="サービスを起動しました (Qdrant :6333、Oxigraph :7878、Redis :6379)"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  検索コレクションを準備しました: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="%s の検索コレクションをまだ準備できていません。以下のデータ読み込みで再試行し、それでも準備できない場合は、データを破棄せずに停止します。"
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="検索インデックスの準備がまだ間に合っていません。以下のデータ読み込みで準備を待ち、コレクションを用意します。ストアがまだ準備できていない場合は、データを破棄せずに停止します。"
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="データは読み込まれませんでした。データを保持する検索ストアを準備できず (不足: %s)、そのまま読み込むとデータが通知なく破棄されるところでした。失われたものはありません。Mac が使われていないときにインストーラを再実行するか、OSTLER_QDRANT_READY_WAIT_S を設定して待ち時間を延ばしてください。"
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="データの読み込みで %s 件のレコードを処理しましたが、1件も保存されませんでした。検索ストアがすべて拒否したため、このままでは空のナレッジグラフが完了したかのように表示されてしまいます。そのため、表示せずに停止しました。Mac が使われていないときにインストーラを再実行してください。"
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="読み込み処理のログを読み取れなかったため、データが実際に保存されたかどうかの確認を実行できませんでした。これは読み込みの失敗を示すものでも、成功を示すものでもありません。"
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="AC 電源使用時のスリープを無効にしました。バッテリ使用時のスリープは維持され、ネットワークからのスリープ解除が有効です"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="スリープを無効にし、ネットワークからのスリープ解除を有効にしました"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale はすでにインストールされています"
MSG_OK_TAILSCALE_INSTALLED="Tailscale をインストールしました"
MSG_OK_TAILSCALE_ENV_PERSISTED="Tailscale の IP を .env に保存しました。iPhone の Ostler app が初回起動時に使用します。"
MSG_OK_TAILSCALE_IP="Tailscale IP: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Tailscale のバックグラウンドサービスを起動しました (ユーザスペースモード、システム機能拡張なし)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="Tailscale のバックグラウンドサービスを起動できませんでした。後で設定からセットアップを再実行できます。"
MSG_INFO_TAILSCALE_SIGN_IN_URL="ブラウザを開いて Tailscale にサインインします: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Hub のポート %s を tailnet に公開しました"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="Hub のポート %s を tailnet に公開できませんでした。外出先からの接続が制限される場合があります"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="ご自身のデバイスから %s で Wiki を読めるようになりました。あなた本人としてサインインし、アクセスできるのはあなただけです。"
MSG_INFO_WIKI_TAILNET_OWNER="Wiki へのアクセスは、あなたの Tailscale アカウント (%s) に限定されています。tailnet 内のほかのユーザには 403 が返されます。"
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="Wiki はこの Mac 内にのみ保存されます。Wiki を読むには、Ostler を開き、サイドバーで「Wiki」を選択してください。"
MSG_INFO_WIKI_TAILNET_BANNER="%s  (Tailscale 経由でご自身のデバイスから。上記のサインインを求められるのは、この経路だけです。)"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="Ostler app 内で開きます。Ostler を開き、サイドバーで「Wiki」を選択してください。ページはサインイン済みの状態で表示されます。"
MSG_INFO_WIKI_INTERNAL_ADDRESS="Ostler はこの Mac 上の http://localhost:8044 からそれらのページを取得します。このアドレスは内部用で、サインインするものは何もありません。"
MSG_INFO_WIKI_SIGN_IN="Wiki のサインインは %s、パスワードは %s です。Ostler が代わりに入力するため、この Mac で入力する必要はありません。Tailscale 経由で別のデバイスから Wiki を開くときにのみ、手元に必要です。"
MSG_INFO_WIKI_SIGN_IN_WITHHELD="Wikiのサインイン情報は %s です。パスワードはこのログには書き込まれません。クリップボードと、下に示すファイルに保存されています。Ostlerが代わりに入力するので、この Mac で入力する必要はありません。"
MSG_INFO_WIKI_PORT_LAST_STATUS="Wikiのポートからの最新のHTTPステータス: %s(000は応答なし、403は応答したものの認証情報が拒否されたことを示します)。"
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="パスワードは %s にも保存されているため、コピーはクリップボードだけではありません。"
MSG_INFO_WIKI_STILL_BUILDING="構築中です。すでに %s ページがディスク上にあり、Wikiアドレスからの最新の応答はHTTP %s でした。構築が終わると、Ostlerアプリに自動的に表示されます。操作は必要ありません。"
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="最初の構築では、まだページが作成されていません(上の警告を参照してください)。構築が完了すれば、Wikiは引き続きOstlerアプリで開けます。上のサインイン情報もそのままお使いいただけます。"
MSG_INFO_WIKI_READINESS_NOT_MEASURED="今回の実行では、Wikiがすでに提供中かどうかを確認していないため、どちらとも判断していません。いずれの場合でも、WikiはOstlerアプリで開けます。上のサインイン情報もそのままお使いいただけます。"
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="この Mac を所有するTailscaleアカウントを確認できなかったため、Wikiはtailnet上に公開されていません。Wikiはこの Mac 上で、Ostlerアプリの「Wiki」から引き続き利用できます。"
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="Wikiをtailnet上に公開できませんでした。Wikiはこの Mac 上で、Ostlerアプリの「Wiki」から引き続き利用できます。"
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="Wikiのアクセスゲートを再読み込みできなかったため、Wikiはtailnet上に公開されていません。"
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="%s ではTailscale Funnelがオンになっています。Funnelはインターネット上に一般公開します。OstlerがFunnelをオンにすることはなく、WikiもFunnel経由の通信を拒否するため、Ostlerのものが公開されることはありません。ただし、意図してオンにしたのでない場合は、このマシンのTailscale管理コンソールでオフにしてください。"
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="サードパーティの著作権表示をインストールしました(取得元: %s)"
MSG_OK_USER_FACING_TREE_READY="ユーザー向けフォルダ構成の準備ができました"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="代わりに「Ostler」フォルダ/ラベルを使用します。"
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vaneは正常です(ローカルWeb検索)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vaneは http://localhost:3000 で実行中です(ローカルのOllamaと連携します)"
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="WhatsApp connector will be enabled (consent recorded)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="初日のWikiキャッチアップ用LaunchAgentを読み込みました(最初の数時間は30分ごとにWikiを再構築し、その後は停止します)"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="引き続き重複した連絡先を統合しています。アドレス帳が大きい場合は数分かかることがあります(%s秒経過)"
MSG_INFO_DEDUPE_MERGED="重複した連絡先を統合しました"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="このサイズのアドレス帳では、重複した連絡先の統合に時間がかかっています。インストール後もバックグラウンドで続行され、完了するとWikiが自動的に更新されます。"
MSG_WARN_DEDUPE_INCOMPLETE="グラフ全体の重複排除処理が正常に完了しませんでした(%s を参照)。処理を続行します"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="重複した連絡先はインストール中にすべて統合されました。バックグラウンドでのキャッチアップは不要です"
MSG_OK_DEDUPE_CATCHUP_LOADED="バックグラウンドの連絡先重複排除用LaunchAgentを読み込みました(インストール後に重複の統合を完了し、その後は停止します)"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="バックグラウンドの連絡先重複排除用LaunchAgentを読み込めませんでした。重複は毎日のメンテナンス処理で統合されますが、完了までに時間がかかります。"
MSG_OK_ENRICH_AGENT_LOADED="バックグラウンドの情報補完用LaunchAgentを読み込みました(映画、場所、本、リンクの詳細を補い、今後1日ほどかけて少しずつ実行されます)"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="バックグラウンドの情報補完用LaunchAgentを読み込めませんでした。好みの情報は保存され検索もできますが、実行されるまでは監督、キャスト、場所などの参考情報が欠けた状態になります。"
MSG_OK_DERIVE_AGENT_LOADED="\"What you like\" agent loaded (works out your tastes from your saved preferences on this Mac, every few hours; nothing leaves your Mac)"
MSG_WARN_DERIVE_AGENT_LOAD_FAILED="\"What you like\" agent could not be loaded. Your preferences are saved and searchable; the What you like page will stay empty until it runs."
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="Wiki再コンパイル用LaunchAgentを読み込みました(ラベル com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="Wiki再コンパイル用スクリプトをインストーラに同梱しました"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="Wiki再コンパイル用スクリプトを %s からクローンしました"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="フロントページを設定しています(1時間ごとに更新)"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="フロントページ生成ツールをインストーラに同梱しました"
MSG_OK_EDITOR_FRONTPAGE_LOADED="フロントページ用LaunchAgentを読み込みました(ラベル com.creativemachines.ostler.editor-frontpage)"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  最初の更新を今すぐ実行します。Ostlerが好みの情報を読み込むにつれて、ダッシュボードのフロントページが充実していきます。"
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  ログ: %s/editor-frontpage.log と editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="このインストーラにフロントページ生成ツールが見つかりません。ダッシュボードのフロントページは更新されません。"
MSG_WARN_EDITOR_FRONTPAGE_FAILED="フロントページ用LaunchAgentのインストールに失敗しました。上の出力を確認してください。その他のインストールには影響ありません。"
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="フロントページのキャッチアップを設定しています"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="フロントページのキャッチアップ用LaunchAgentを読み込みました(興味・関心の読み込みが終わるまで5分ごとに確認し、その後は停止します)"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="フロントページのキャッチアップ用LaunchAgentを読み込めませんでした。フロントページと、Ostlerが把握するあなたの興味・関心は、次回の1時間ごとの更新で反映されます。"
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="フロントページのキャッチアップをスキップします。フロントページの更新がインストールされておらず、再実行する対象がありません。"
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="Wiki が http://localhost:8044 で実行中です"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="Wiki を閲覧する準備ができました。Ostler はバックグラウンドでページの要約を作成しており、しばらくすると順次表示されます。Wiki はすぐにお使いいただけます。"
MSG_OK_YOUR_ASSISTANT_CALLED="アシスタントの名前は %s です"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="パーソナルコンテキストのダイジェスト用スクリプトをインストーラに同梱"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="パーソナルコンテキストのダイジェスト用 LaunchAgent を読み込みました (ラベル com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  ログ: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="既存の context-refresh のインストールを再利用します: %s"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="パーソナルコンテキストのダイジェスト用スクリプトが同梱されていません。アシスタントはリアルタイムの検索のみを使用します (常時利用できるコンテキスト要約はありません)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="パーソナルコンテキストのダイジェスト用 LaunchAgent を読み込めませんでした。context-refresh.err を確認してください。アシスタントはリアルタイムの検索で引き続き回答します"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="クローンした Knowledge サービスのソースにパッケージ設定がないため、環境を設定できませんでした。"
MSG_WARN_BUNDLE="  バンドル: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s は Apple Silicon 専用です (検出: %s)。"
MSG_WARN_CM042_DOWNLOAD_FAILED="Ostler RemoteCapture v%s を %s からダウンロードできませんでした"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="考えられる原因: リリースタグがまだ公開されていない、ネットワークがオフライン、または上流の公証が処理中です。リリースが公開されたら、インストーラをもう一度実行してください。"
MSG_WARN_CM042_EXTRACT_FAILED="Ostler RemoteCapture の tarball を展開できませんでした。LaunchAgent をスキップします。"
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Ostler RemoteCapture の LaunchAgent を読み込めませんでした。上の出力と ~/Library/LaunchAgents/ を確認してください。"
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  会話の補強は利用できません。Ostler のそれ以外の部分は通常どおりインストールされます。会話メモリーエンジンを組み込むには、--allow-plaintext を付けずにもう一度実行してください。"
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="会話メモリーエンジンのインストールに失敗しました (クローン)。"
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  検索先: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  通常、これはインストーラの .app のビルド時に、"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  同梱されるはずのベンダー版 cm048_pipeline パッケージが"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/ に含まれなかったことを意味します。インストーラを再ダウンロードするか、"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  開発/CI 用のインストールの場合は --allow-plaintext を付けて再実行してください。"
MSG_WARN_CM048_PIPELINE_NOT_FOUND="会話メモリーエンジンが見つかりません。これがないと会話の補強は実行できません。"
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="会話メモリーエンジンの設定をスキップしました (--allow-plaintext)。"
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="会話メモリーエンジンのソースは見つかりましたが pyproject.toml がないため、venv の設定をスキップしました。"
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Colima を起動できませんでした。代わりに Docker Desktop を試します..."
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="GNU coreutils をインストールできませんでした。時間のかかる手順は時間制限なしで実行されます (動作中であることは進行状況の行で確認できます)。"
MSG_WARN_COLIMA_START_RETRY="Colima が正常に起動しませんでした (Docker ソケットの準備ができていません)。%s 秒後に再試行します..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="考えられる原因: タグ v%s がまだ公開されていない、ネットワークがオフライン、"
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  consent_cli stderr (first 400 chars):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  コンソールスクリプトが %s に作成されませんでした。pyproject.toml に [project.scripts] のエントリがない可能性があります。"
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="--allow-plaintext が指定されたため、続行します。"
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="インストールを続行します。上のエラーを調べたあと、\`ostler-fda\` をもう一度実行してください。"
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="連絡先カードの自動入力なしで続行します。代わりに Ostler がお尋ねします。"
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  iMessage に送信された会話は、次の対応が済むまで通知なしに失敗します:"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="スリープ設定を変更できませんでした。「システム設定」>「エネルギー」で「電源アダプタ接続時に自動的にスリープさせない」を有効にしてください。"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="スリープ設定を変更できませんでした。「システム設定」>「エネルギー」で「自動的にスリープさせない」を有効にしてください。"
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="ostler-assistant v%s を %s からダウンロードできませんでした"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="Takeout zip から Gmail の mbox を展開できませんでした – スキップします。"
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="ostler-assistant の tarball を展開できませんでした。LaunchAgent をスキップします。"
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="Tailscale CLI が見つかりませんでした。後で手動で設定できます。"
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="Could not install legal/ consent-strings package; continuing"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="LICENSES/ ディレクトリをインストールできませんでした(致命的ではありません)。"
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="ostler_security を Hub の venv にインストールできませんでした。"
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="THIRD_PARTY_NOTICES.md をインストールできませんでした(致命的ではありません)。"
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="Doctor エージェントを取得できませんでした(同梱版とクローンの両方に失敗)。"
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="Ostler Doctor のファイルが見つかりません。iOS のペアリングフローに必要です(Ostler.app が :8089/pair-ios を iframe で表示します)。"
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  検索場所: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  通常、インストーラの .app が次のものを含めずに"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  ビルドされたことを意味します: 同梱されるはずの doctor/agent/ ソースが"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/ にありません。インストーラを再ダウンロードするか、"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  開発/CI 用のインストールの場合は --allow-plaintext を付けて再実行してください。"
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Doctor のインストールを中止しました。iOS のペアリングフローに必要です。インストーラを再ダウンロードするか、開発/CI 用のインストールの場合は --allow-plaintext を指定してください。"
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="メール取り込みスクリプトを取得できませんでした(同梱版とクローンの両方に失敗)。"
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="hub-power スクリプトを取得できませんでした(同梱版とクローンの両方に失敗)。"
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="wiki-recompile スクリプトを取得できませんでした(同梱版とクローンの両方に失敗)。"
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="Chrome ウェブストアの URL を自動で開けませんでした: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="region.json を保存できませんでした(続行します。Doctor に表示されます)"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="復旧キーを渡したことを記録できませんでした。今回の実行の概要は正しいままですが、次回以降の実行ではそれを判断できず、再度警告が出る場合があります。失敗するならこちら側のほうが安全です。"
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="Your recovery key was not saved to Keychain. Write it down and keep it somewhere safe, away from this Mac."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="Ollama を自動的に起動できませんでした。"
MSG_FAIL_OLLAMA_PORT_IN_USE="別のプログラムがすでにポート 11434 を使用しています。このポートは Ostler のローカル AI に必要です。Ostler は独自のコピーを起動できなかったため、中途半端に終わらないようここでインストールを停止しました。

  ポートを使用しているもの: %s
  詳しいエラーの保存先: %s

多くの場合、すでにお使いの Ollama か、以前の Ostler のインストールで起動したままのものが原因です。それを終了して(またはこの Mac を再起動して)、インストーラをもう一度実行してください。"
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="パイプラインを更新できませんでした(オフライン?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="pipeline_signals.json を書き込めませんでした。次回のインストールまたは更新まで、Doctor の空メール診断は安全な既定値で動作します。"
MSG_WARN_CURL_SAID="curl の出力:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="ディレクトリが見つかりません: %s – 読み込みをスキップします。"
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker が %s 秒以内に起動しませんでした。"
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker はインストールされていますが、起動していません。起動が必要です。"
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="Docker コマンドはこの Mac にありますが、その背後で動いているものがありません。macOS の Docker コマンドはクライアントにすぎず、実際に動かすには Colima や Docker Desktop などのエンジンが必要です。インストーラが用意します。"
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="コンテナランタイム診断 - docker クライアント: %s | colima: %s | Docker Desktop: %s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="wiki コンテナは起動しましたが、60 秒以内に http://localhost:8044 から応答がありませんでした。wiki は動作していないものとして扱ってください。起動コマンドの終了コードは、ページが読み込めることの証拠にはなりません。"
MSG_WARN_WIKI_NOT_RESPONDING="wiki が応答していません(127.0.0.1:8044)。wiki はコンテナ内で動作するため、多くの場合コンテナランタイムが停止しています。http://localhost:8089/doctor で Ostler Doctor を開き、原因を確認してください。"
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama のインストール途中で、準備状況の確認がハングします。"
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  早期マーカー(チャンネルがまだ接続中 + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="メール取り込み用 LaunchAgent のインストールに失敗しました。上の出力を確認してください。"
MSG_WARN_IMESSAGE_BRIDGE_FAILED="iMessage ブリッジの LaunchAgent のインストールに失敗しました。インストーラを再実行するか INSTALL_SNIPPET.sh を手動で実行するまで、アシスタントユーザの iMessage 返信は動作しません。"
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="iMessage ブリッジのスクリプトが同梱されておらず、--allow-plaintext が指定されたため、LaunchAgent のインストールをスキップします。アシスタントユーザの iMessage 返信は動作しません。"
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="暗号化は動作しません。"
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="暗号化は動作せず、さらに"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="固定された PWG_KNOWLEDGE_REPO タグに含まれていることを確認してください。"
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  Events の Messages.app 用権限)。"
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="FDA 抽出ツールが異常終了しました(%s)。出力の最後の20行:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="FDA 抽出モジュールがこのインストーラに同梱されていません。"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="想定される場所: Contents/Resources/ostler_fda/(.app の内部)。"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="最も可能性の高い原因: ビルドの不具合でベンダーコピーが抜け落ちました。ostler.ai/install から .app を再ダウンロードしてください。"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="FDA 抽出モジュールが同梱されていません。--allow-plaintext が指定されたため続行します。即時のデータ抽出はスキップされます。"
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="データ抽出モジュールはディスク上にありますが、依存関係がインストールされなかったため読み込めません:"
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="--allow-plaintext が指定されたため続行します。定期的なデータ更新は毎回失敗します。"
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault は有効になっていません。"
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="現在、最初の1か月無料を有効にできませんでした。インストールは続行します。ペアリング後に iPhone の Ostler app を開いて解決してください。"
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="ターミナルにフルディスクアクセスが許可されていません。"
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="%s GB の RAM を検出しました。コンパクトなアシスタント(gemma4:e2b)をご利用いただけます。信頼性と正確さがあり、短い質問には1秒未満で応答し、ツール呼び出しにも対応し、分からないときは正直に「分かりません」と答えます。長い質問により豊かな回答が必要な場合は、24 GB 以上でスタンダードアシスタント(qwen3.5:9b)が使えます。後から別の Mac に再インストールして切り替えることもできます。"
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="GDPR インポートでエラーが発生しました。次のコマンドで再実行できます:"
MSG_WARN_GRAPH_DB_PULL_RETRY="データベースのダウンロードが完了しませんでした(%s 回目 / 全 %s 回)。%s 秒後に再試行します..."
MSG_WARN_GRAPH_DB_UP_RETRY="ナレッジグラフのデータベースが起動しませんでした(%s 回目 / 全 %s 回)。再試行しています..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="GDPR インポートは製品版インストールの一部です。これがないと、ソーシャルグラフ(LinkedIn、Facebook、Instagram、WhatsApp、Twitter、Google カレンダー)をインポートできません。"
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="インポートパイプラインを再インストールするまで、このインスタンスでは GDPR インポートを利用できません。"
MSG_WARN_GIT_SAID="Git からのメッセージ:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  ヘルスチェックに失敗しました: ostler-knowledge --version が出力を返しませんでした。"
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  ヘルスチェックに失敗しました: 会話メモリエンジンを読み込めませんでした(pwg-convo またはそのパイプラインのインポートが正常に完了しませんでした)。"
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="Homebrew インストーラが %s で終了しました。%s の最後の30行は次のとおりです:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Homebrew インストールログ(末尾)---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="Doctor の pip インストールが %s で終了しました。%s の最後の30行は次のとおりです:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Doctor pip インストールログ(末尾)---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="パイプラインの pip インストールが %s で終了しました。%s の最後の30行は次のとおりです:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- パイプライン pip インストールログ(末尾)---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Hub 電源管理用 LaunchAgent のインストールに失敗しました。上の出力を確認してください。"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="Hub 電源管理スクリプトが、想定されるバンドルパスに見つかりません。"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  インストーラの .app に vendor/hub_power/ が含まれていないようです"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  (Contents/Resources/hub-power/ 内)。バッテリーに応じた負荷制御はインストールされませんが、残りのインストールは続行します。"
MSG_WARN_ICAL_SERVER_FAILED="Assistant API を起動できませんでした。次回のインストール実行まで、iPhone の Ostler app のアクセスは制限されます。"
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - イメージの取得に失敗しました(ネットワーク、ディスク容量、またはレジストリのタイムアウト)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="iMessageのフルディスクアクセスのシグナルを pipeline_signals.json に書き込めませんでした。Doctorダッシュボードにフルディスクアクセスのカードが自動表示されない場合があります。"
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="IMAPホストが空です。もう一度お試しください。"
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="iMessageの「オートメーション」の権限: 許可されていません (-1743)。"
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="iMessageの「オートメーション」の権限: 確認結果が確定しませんでした。"
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="iMessageの履歴 (chat.db) を読み取れません。Ostlerデーモンにフルディスクアクセスがまだ許可されていません。システム設定 > プライバシーとセキュリティ > フルディスクアクセスで許可するまで、iMessageの履歴の読み取りはオフのままです。"
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="システム設定 > プライバシーとセキュリティ > オートメーション を開きます。iMessageの配信を設定するには、OstlerInstaller (またはターミナル) の「メッセージ」の行をオンにしてください。"
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="完全なメールアドレスではないため無視しました: %s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="完全なメールアドレスを1つ以上入力してください (例: you@example.com)。"
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessageには、許可する連絡先が少なくとも1件必要です。もう一度お試しいただくか、"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="インポートパイプラインは利用できません (非公開リポジトリ。ベータテスター専用)。"
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="インポートパイプラインがインストーラに含まれていません。エラーによる停止はスキップしました。"
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="インポートパイプラインがインストーラに含まれていません。これは製品版のインストール経路であり、contact_syncer のPythonパッケージは.appバンドル内に同梱されているはずです。"
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOXを指定すると、アシスタントは受信するすべてのメールを読み取ります。"
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - Wiki出力ボリュームのディスク容量が不足しています"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Intel Macを検出しました。性能が制限されます。Apple Siliconを推奨します。"
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s はクラウドプロバイダのホストです。"
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="%s のJWT_SECRETは使用禁止リストに含まれています。ナレッジグラフのサービスを読み込めるよう、再生成します。"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="%s のJWT_SECRETが短すぎます (%s < %s 文字)。再生成します。"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="ナレッジのリポジトリはクローンされましたが、pyproject.toml がありません。venvの設定をスキップしました。"
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="ナレッジサービスのインストールに失敗しました (クローン)。"
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="ライセンス: %s はApache 2.0ではなく、GoogleのGemma利用規約に基づいて提供されています。"
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="MacBookでの利用では、バッテリーとスリープの処理のためにこれが必要です。"
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="macOSの「連絡先」の権限が拒否されたか、まだ許可されていません。"
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOSはスクリプトからは許可を求めません。手動で許可する必要があります。"
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Mac miniでの利用には影響ありません。MacBookをお使いの場合は、もう一度お試しください。"
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="メールのデータは、手動で取り込むこともできます:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  手動で再試行: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  原因を解消したあとの手動での再試行:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Apple Mailもカスタム IMAPも選択されていないため、Apple Mailを使用します。"
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="パスキーが設定されていないため、データベースは暗号化されません。"
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="以前のインストールで復旧キーが作成されましたが、完了しなかったため、表示されませんでした。復旧キーはここを含め、どこにも保存されないため、取得できません。"
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="パスフレーズは引き続き使用でき、現時点でロックされているものはありません。ただし、パスフレーズを忘れた場合、現在は再びアクセスする手段がありません。"
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="サポートにご連絡のうえ、セキュリティを新たに設定してください。新しい復旧キーが表示されますので、大切に保管してください。"
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="パスフレーズが一致しません。もう一度お試しください。"
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="パスフレーズの設定に失敗しました。出力:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="入力が空です。パスフレーズをスキップしました。"
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="パスフレーズは12文字以上にしてください。もう一度お試しください。"
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="データを暗号化するには、パスフレーズが必要です。"
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="国際番号ではありません。先頭に + を付け、続けて国番号と残りの番号を入力してください (例: +447700900123)。もう一度お試しください。"
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollamaが応答しません"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s に失敗しました(%s/3回目)。%s秒後に再試行します..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="空き容量は %s GB のみです。少なくとも 35 GB を推奨します(Docker イメージ、AIモデル、データ用)。"
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="バッテリー駆動中は、Hubの電源用 LaunchAgent(ステップ 3.14)が一時停止する場合があります"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="または、インストーラを再実行して別のチャンネルを選択してください。"
# NEEDS REVIEW: The source is a fragment that continues on the next line. Japanese word order needs the next line's content, so the joined pair should be checked.
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="またはPhase Bのリリースパイプラインより先に実行されています。次の準備が整ってから、インストーラを再実行してください:"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor が %s 件のエラーを報告しました。"

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="Ostlerのインストールは完了しましたが、インストール中に %s 件のエラーが発生しました。"
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  詳細は ~/.ostler/logs/install.log をご覧ください。Ostlerはそのまま起動します。Doctorを開いて、確認が必要な項目を見てください。"
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="Ostlerのインストールは完了しましたが、%s 個のインストールステップが正常に完了しませんでした: %s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="Ostlerのインストールは完了しました。インストール中にエラーは発生しませんでした。"

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant は展開されましたが、--version の確認に失敗しました。"
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Ostlerアシスタントの LaunchAgent のインストールが3回試行しても失敗しました。診断出力は上下に表示されています。"
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Ostlerアシスタントの LaunchAgent のインストール(%s回目)に失敗しました。再試行します。"
MSG_WARN_ASSISTANT_ERR_LOG_PATH="デーモンの stderr 全文: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="stderr の最後の抜粋:"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s はApple Silicon専用です(検出: %s)。"
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  暗号化ストレージの依存関係を会話メモリの venv にインストールできませんでした。会話の拡充は実行されません。"
MSG_INFO_COACH_DB_READY="  Coaching database ready, encrypted: %s"
MSG_WARN_COACH_DB_NOT_CREATED="  Could not prepare the encrypted coaching database (it will be created on the first coaching note): %s"
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  暗号化ストレージの依存関係のソースが SCRIPT_DIR に見つかりません。会話メモリエンジンを読み込めず、会話の拡充は実行されません。"
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - ostler-wiki-compiler イメージはまだ取得できません(レジストリ未接続)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph が応答しません"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - この段階では Oxigraph がまだ正常ではありません(上のログを確認してください)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="パスワードが一致しないか、空でした。もう一度お試しください。"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="メインのインストールには通常45分から数時間かかります(Docker と Ollama のダウンロード、初回セットアップを含む)。回線が遅い場合や、長年の履歴があるMacではさらに長くなります。長く動きがないように見えるのは普通です。バックグラウンドでダウンロードとセットアップを行っており、止まってはいません。"
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  pip install に失敗しました。会話メモリエンジンは利用できません。"
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  pip install に失敗しました。email-ingest はシステムの python にフォールバックします(実行時に失敗する可能性もあります)。"
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  pip install に失敗しました。ostler-knowledge は利用できません。"
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  pip install に失敗しました。メール取り込みエンジンは利用できません。毎時の LaunchAgent は引き続き mbox ファイルを出力しますが、修復されるまでグラフに取り込めません。"
MSG_WARN_CM021_SOURCE_NOT_FOUND="メール取り込みエンジンのソースがアプリバンドル内に見つかりません。毎時のバックグラウンド処理は、メールファイルを取り込まずに保存します。"
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="ostler_fda のソースがアプリバンドル内に見つかりません。email-ingest LaunchAgent は実行時にシステムの python にフォールバックします。"
MSG_WARN_PIP_SAID="pip の出力:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="フルインストールを行うには、電源アダプタを接続してください。"
MSG_WARN_PORT_1_ALREADY_USE_PID="ポート %s は %s(PID %s)がすでに使用しています"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - ポート 3000 は別のサービスがすでに使用しています"
MSG_WARN_POWER_SOURCE="電源: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="sqlcipher3 のインストールに失敗しました。"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="sqlcipher3 のインストールに失敗しました。データベースは暗号化されません。"
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="Python 3 が見つかりません。Python 3.12 をインストールしています..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s は古すぎます(3.10以上が必要です)。Python 3.12 をインストールしています..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant が応答しません"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         商用利用の前に https://ai.google.dev/gemma/terms をお読みください。"
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="公開版は https://ostler.ai/licenses.html でお読みいただけます"
MSG_WARN_REDIS_NOT_RESPONDING="Redis が応答しません"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="リリースされるまでお待ちいただくか、バイナリを手動で配置してください:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="再実行しています – セルフホストのホストを入力するか、Ctrl-C を押して再度起動し、Apple Mail を選択してください。"
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="スキップするには、iMessage のチェックを外してインストーラをもう一度実行してください。"
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="--allow-plaintext で実行中: 暗号化は無効です。本番環境では使用しないでください。"
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  初回起動後に \`%s doctor\` を実行してください"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="サインインしたら 'tailscale ip --4' を実行し、そのアドレスを iOS アプリに追加してください。"
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Safari 機能拡張のコピーに失敗しました。後で手動でインストールできます"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="Safari 機能拡張はインストールされましたが、ペアリング用の機能拡張トークンがありませんでした。インストーラを再実行するまで、ブラウジングの取り込みはオフのままです"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="Safari 機能拡張をこの Hub とペアリングできませんでした。インストーラを再実行するまで、ブラウジングの取り込みはオフのままです"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="セキュリティモジュールが見つかりません。パスキーの設定はスキップされます。"
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  検索先: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  通常これは、インストーラの .app が次のものを含めずに"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  ビルドされたことを意味します: ベンダー版 ostler_security パッケージが"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/ に含まれていません。インストーラを再ダウンロードするか、"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  開発/CI 用のインストールの場合は --allow-plaintext を付けて再実行してください。"
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="セキュリティの設定に失敗しました。データベースの暗号化なしで続行します。"
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="セキュリティの設定に失敗しました。出力:"
MSG_WARN_SEE_STDERR_FRAGMENT="  stderr の一部は %s を参照してください。"
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="バイナリのインストールをスキップします。ウィザードが書き込んだ config.toml はそのまま残ります。"
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Doctor の LaunchAgent のインストールをスキップします。"
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="メール取り込みの LaunchAgent のインストールをスキップします。"
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="LaunchAgent のインストールをスキップします。Mac mini への導入には影響しません。"
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="LaunchAgent のインストールをスキップします。次を試してください: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="Wiki 再コンパイルの LaunchAgent のインストールをスキップします。"
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="使用中のポートがあります。Docker コンテナの起動に失敗する可能性があります。"
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="ポート %s はすでに %s(PID %s)に使用されています。これはこのアカウントに属するものです。終了してから、もう一度インストーラを実行してください。"
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="ポート %s は、この Mac の別のユーザアカウントに属するプログラムにすでに使用されています。Ostler はこのポートを共有できず、そのまま開始すると 2 つのアカウントのデータが混ざるおそれがあります。もう一方のアカウントをログアウトするか、このポートを使うアカウントが 1 つだけの Mac に Ostler をインストールしてください。"
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="必要なポートがすでに使用されているため、Ostler はデータベースを起動できません。"
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="上に表示されたポートを使用しているものを停止してから、もう一度インストーラを実行してください。"
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="ポート %s が空いているか確認できませんでした。これは、ポートが空いているという意味ではありません。"
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="一部のポート確認を実行できなかったため、他のプログラムとの競合がないとは言い切れません。"
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="この Mac で最も信頼できるポート確認を実行できなかったため、以下の確認はいつもより精度が低くなります。"
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="Ostler はそれらのポートが空いていることを確認できず、確認していないポートではデータベースを起動しません。インストールログを添えてサポートにお問い合わせください。"
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="古い Colima の起動項目を削除できませんでした。再起動後に Wiki が読み込まれない場合があります。サポートにお問い合わせください。"
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="競合しているサービスを停止するか、docker-compose.yml のポートを変更してください"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscaleに3分以内にサインインできませんでした。後で「設定」からやり直せます。"
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="Tailscale IPは.envに書き込まれましたが、その後の読み取りで確認できませんでした。iPhoneのOstlerアプリが取得できない場合は、install.sh --repair をもう一度実行してください。"
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="リモートアクセスの回答を保存できなかったため、次回の再インストール時にもう一度確認します。ほかの項目には影響ありません。"
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="Tailscaleのインストールに失敗しました。tailscale.com から後でインストールできます"
MSG_WARN_TAILSCALE_STATE_UNREADABLE="この Mac には読み取れない既存のTailscale設定があるため、ネットワークに接続されたままかどうか判断できません。下から選んでください。すでに接続されている場合は、もう一度設定しても問題ありません。"
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="デプロイ済みのサービスは、それらがないと起動しません。"
# NEEDS REVIEW: Source is a continuation fragment ("...until this is resolved"); proposed "解決済みです" inverted the meaning. Check how the preceding line joins in Japanese.
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  この問題が解決されるまで。対処方法は次のステップのバナーを参照してください。"
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  確認してください。cron-delivery / imessage-tcc がよくある原因です"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  次を試してください: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  次を試してください: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="「%s」は認識できない選択です。iMessageとメールを既定にします。"
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="認識できない選択です。おすすめを使用します。"
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  アップデートに失敗しました。既存のチェックアウトで続行します。"
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="そのアカウントには、上でおすすめしたApple Mailを使用してください。Ostlerがクラウドのパスワードを保存することはありません。"
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="INBOXを使用します。アシスタントは受信するすべてのメールを読みます。"
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="Vaneコンテナは起動しましたが、http://localhost:3000 が60秒以内に応答しませんでした。"
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane(ローカルWeb検索)を起動できませんでした。主な原因:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  Web検索は任意です。Ostlerのそれ以外の機能は、これがなくても動作します。"
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="代わりに専用のラベルまたはフォルダを使用することを強くおすすめします。"
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="ブリーフの配信にはWhatsAppの電話番号が必要です。もう一度入力してください、"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="Wikiはコンパイルされましたが、wiki-siteコンテナを起動できませんでした。"
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="Wikiの初回コンパイルに失敗しました。主な原因:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="初日のWikiキャッチアップ用LaunchAgentを読み込めませんでした。毎日のWiki再構築は引き続き実行されます。Wikiは1時間以内ではなく、翌日に更新されます。"
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="Wiki再コンパイル用LaunchAgentのインストールに失敗しました。上の出力を確認してください。"
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="Wikiは自動更新されません。手動での再構築は引き続き可能です:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="ウィザードの設定はそのまま残り、バイナリも配置されたままです。手動で再試行:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="アシスタントには名前が必要です。上の候補から選ぶか、お好きな名前を入力してください。"
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="「システム設定」>「プライバシーとセキュリティ」>「連絡先」で、もう一度許可できます。"
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="セキュリティ設定は後から実行できます: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="手動でインストールが必要な場合があります: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  実際の値:   %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="展開後、Ostler RemoteCaptureのバンドルが %s に見つかりませんでした。リリースのtarballが破損している可能性があります。"
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="%s を作成またはアクセスできなかったため、Ostler RemoteCaptureのインストール先がありません。これはダウンロードではなく、フォルダの権限の問題です。"
MSG_ERR_CM042_RENAME_FAILED="Ostler RemoteCaptureのダウンロードと展開は正常に完了しましたが、%s に移動できませんでした。展開されたAppは /Applications に残されています。署名の問題ではありません。"
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify の結果:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  公開されているチェックサムと一致しないバンドルは配置しません。"
MSG_ERR_CM042_SHA_256_MISMATCH="Ostler RemoteCaptureのtarballのSHA-256が一致しません。"
MSG_ERR_CM042_PIN_FAILED="OstlerはこのRemoteCaptureのダウンロードが正規のものか確認できなかったため、インストールしませんでした。"
MSG_ERR_CM042_VERSION_UNKNOWN="このRemoteCaptureのバージョンはOstlerが認識できないため、インストールしませんでした。"
MSG_ERR_CM042_SIDECAR_DISAGREES="このRemoteCaptureのダウンロードに付属して公開されているチェックサムがファイルと一致しないため、インストールしませんでした。"
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess の結果:"
MSG_ERR_CM042_VERIFY_FAILED="Ostler RemoteCapture の署名/公証の検証に失敗しました。"
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv の結果:"
MSG_ERR_EXPECTED="  期待値: %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief の結果: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="%s にある ostler-assistant のバイナリは Mach-O 実行ファイルではありません。"
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="ostler-assistant の tarball の SHA-256 が一致しません。"
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  公開されているチェックサムと一致しないバイナリは配置しません。"
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="隔離属性の削除と LaunchAgent の読み込みは行いません。"
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="配布元の tarball が修正されたら、インストーラをもう一度実行してください。"
MSG_ERR_URL="  url:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Intel搭載のMacには対応していません。OstlerにはApple Silicon (M1、M2、M3、M4) が必要です。"
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="RAMは16 GB以上が必要です。現在は %s GBです。24 GBを推奨します。"
MSG_FAIL_CM042_SIGNATURE_FAILED="Ostler RemoteCapture のインストールを中止しました。署名または公証の確認に失敗しました。サポート用にバンドルは /Applications に残してあります。support@ostler.ai にメールで連絡し、インストーラをもう一度実行してください。"
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="3回試しましたが %s を取得できませんでした。ネットワークを確認し、インストーラをもう一度実行してください。"
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="3回試しましたが nomic-embed-text を取得できませんでした。ネットワークを確認し、インストーラをもう一度実行してください。"
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker を利用できません。インストーラをもう一度実行して Colima をインストールしてください。"
MSG_FAIL_CONTAINER_CLIENT_MISSING="このMacに docker コマンドがないため、Ostler は必要なサービスを開始できません。インストーラをもう一度実行してください。それでも失敗する場合は、%s にあるログを送信してください。"
MSG_FAIL_CONTAINER_ENGINE_ABSENT="Ostler にはコンテナランタイムが必要ですが、このMacで応答しているものがありません。Wiki、ナレッジグラフ、検索インデックスはすべてコンテナ内で動作するため、これらが欠けたまま完了しないよう、ここでインストールを停止しました。対処方法: ターミナルを開いて 'colima start' を実行し、このインストーラをもう一度実行してください。代わりに Docker Desktop を使っている場合は、Docker Desktop を開き、クジラのアイコンが安定するまで待ってから再実行してください。完全なログは %s にあります。"
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="ナレッジグラフのデータベースを開始するための Docker の準備が時間内に完了しませんでした。Colima または Docker が実行中であることを確認し、インストーラをもう一度実行してください。"
MSG_FAIL_GRAPH_DB_PULL_FAILED="何度か試しましたが、ナレッジグラフのデータベースイメージをダウンロードできませんでした。多くの場合、ネットワークの問題です。インターネット接続を確認し、インストーラをもう一度実行してください。"
MSG_FAIL_GRAPH_DB_UP_FAILED="ナレッジグラフのデータベースはダウンロードされましたが、起動できませんでした。インストーラをもう一度実行してください。繰り返し発生する場合は、ターミナルを開いて次を実行してください: cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="Ostler はナレッジグラフのデータベースへの認証付きリクエストを完了できませんでした。2秒間隔で2回試しましたが、どちらも拒否されました。原因はまだ分かっていません。データベースがまだ起動中だったか、Ostler が保持している認証情報が想定されたものと異なる可能性があります。データには一切変更を加えていません。インストーラをもう一度実行すると成功することが多いです。成功した場合でも、ぜひお知らせください。この不具合の再現に取り組んでいますので、インストールログをお送りください。"
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="FDA 抽出モジュールがインストーラのバンドルに見つかりません。ostler.ai/install から .app をもう一度ダウンロードするか、開発/CI 用に --allow-plaintext を付けて再実行してください。"
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="データ抽出モジュールはインストールされましたが、読み込めないため、バックグラウンド更新は実行のたびに失敗します。完全な出力を %s に保存しました。インストーラをもう一度実行してください。サポートに連絡する場合は、そのファイルを添付してください (参照: ERR-10-FDA-DEPS-IMPORT)。"
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="内部エラー: データ抽出モジュールがアプリケーションバンドル内に配置されたため、署名が無効になります。これはビルド上の不具合で、お使いのMacの問題ではありません。ostler.ai/install から .app をもう一度ダウンロードしてください (参照: ERR-10-FDA-DEPS-UNSAFE-PATH)。"
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Doctor の依存関係のインストールに失敗しました。完全な出力を %s に保存しました。support@ostler.ai にメールする際に添付してください (参照: ERR-17-DOCTOR-PIP)。"
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="インポートパイプラインの依存関係のインストールに失敗しました。完全な出力を %s に保存しました。support@ostler.ai にメールする際に添付してください (参照: ERR-14-PIPELINE-PIP)。"
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Homebrew のインストールに失敗しました。完全な出力を %s に保存しました。support@ostler.ai にメールする際に添付してください。"
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="インポートパイプラインのインストールに失敗しました。製品版のインストールには contact_syncer バンドルが必要です。開発/CI 用に --allow-plaintext を付けて再実行するか、インストーラをもう一度ダウンロードしてやり直してください。"
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="スリープの無効化と Homebrew のインストールには sudo 権限が必要です。準備ができたら再実行してください。"
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Colima も Docker Desktop も起動できませんでした。Docker Desktop をインストールして再実行してください。"
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="ディスクの空き容量が足りません (%s GB)。空き容量を増やしてからもう一度お試しください。"
MSG_FAIL_MACOS_BELOW_FLOOR="macOS %s は Ostler の対応バージョンより古いです。Ostler には macOS %s 以降が必要です。インストーラアプリはそのバージョン向けに作られており、それより古い環境では開きません。macOS をアップデートしてから、インストーラをもう一度実行してください。"
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="パスキーが未設定で、既存のセキュリティ設定もありません。開発/CI 用に --allow-plaintext を付けて再実行するか、インストーラをもう一度実行して Touch ID の説明を確認してください。"
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="会話メモリエンジンが必要です。開発/CI 用に --allow-plaintext を付けて再実行するか、上記の不足しているバンドルを修正してやり直してください。"
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="同梱されている Ostler デーモン (v%s、%s) は、このインストーラがフルディスクアクセス経由で取り込みを行うために必要な 'run-source' コマンドに対応していません。これはインストーラバンドル内のバージョン不一致です。このままインストールすると、すべての取り込み元が気付かないうちに動作しなくなり、エラーも表示されないまま製品のデータが古くなります。ostler.ai/install から .app をもう一度ダウンロードしてやり直してください (参照: ERR-11-DAEMON-RUN-SOURCE-SKEW)。"
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="ostler_security のインストールに失敗しました。開発/CI 用に --allow-plaintext を付けて再実行するか、上記の pip のエラーを修正してやり直してください。"
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="パスキーの設定に失敗しました。開発/CI 用に --allow-plaintext を付けて再実行するか、上記のエラーを修正してやり直してください。"
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="暗号化データベースには sqlcipher3 が必要です。開発/CI 用に --allow-plaintext を付けて再実行するか、上記の pip のエラーを修正してやり直してください。"
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="このインストーラは macOS 専用です。"
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="Xcode Command Line Tools のインストールが15分以内に完了しませんでした。ターミナルを開いて 'xcode-select --install' を実行し、macOS のダイアログで「インストール」をクリックして完了するまで待ってから、このインストーラをもう一度実行してください。"

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="Homebrew のインストールは成功と報告されましたが、/opt/homebrew/bin/brew が見つかりません。詳しいログは %s を確認してください。対処方法: ターミナルを開いて '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' を実行し、インストーラをもう一度実行してください。"
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew は /opt/homebrew/bin/brew にインストールされていますが、shellenv の評価後も 'brew' コマンドが PATH にありません。新しいターミナルを開いて、インストーラをもう一度実行してください。"
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose' は成功と報告されましたが、colima が PATH にありません。Homebrew のエラーがないか %s を確認してください。対処方法: ターミナルを開いて 'brew install colima docker docker-compose' を手動で実行し、インストーラをもう一度実行してください。"
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose' は成功と報告されましたが、docker CLI が PATH にありません。%s を確認してください。対処方法: 'brew install docker' を手動で実行し、インストーラをもう一度実行してください。"
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="The Ollama install reported success but its binary is missing. Check %s, then re-run the installer."
MSG_FAIL_OLLAMA_PIN_DOWNLOAD="Could not download Ollama %s. Check your internet connection, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_PIN_SHA256="The Ollama %s download did not match its recorded fingerprint, so it was not installed. This can mean the download was damaged or altered. Re-run the installer; if it happens again, contact support. Details: %s"
MSG_FAIL_OLLAMA_PIN_UNPACK="Ollama %s downloaded but could not be unpacked. Check free disk space, then re-run the installer. Details: %s"
MSG_FAIL_OLLAMA_AGENT_NOT_PINNED="The local AI service is set to run %s instead of the copy of Ollama this installer verified (%s), so it would not stay on a tested version. The install has stopped. Re-run the installer; if this repeats, contact support. Details: %s"
MSG_FAIL_EMBED_HEALTHCHECK="Ollama は動作していますが、埋め込みモデルがベクトルを返しませんでした(HTTP が 200 以外、または結果が空)。このままでは「人物」カード、検索、閲覧がすべて空になります。%s を確認してください。対処方法: Ollama アプリ(Homebrew のフォーミュラではなく)がインストールされ、動作していることを確認してから、インストーラをもう一度実行してください。"
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher' は成功と報告されましたが、sqlcipher が PATH にありません。%s を確認してください。対処方法: 'brew install sqlcipher' を手動で実行し、インストーラをもう一度実行してください。"
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale' では /Applications/Tailscale.app が作成されませんでした。%s を確認してください。対処方法: https://tailscale.com/download/macos から Tailscale をダウンロードして /Applications にドラッグし、インストーラをもう一度実行してください。"
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11' は成功と報告されましたが、/opt/homebrew/opt/python@3.11/bin/python3.11 に python3.11 バイナリが見つかりません。%s を確認してください。対処方法: 'brew reinstall python@3.11' を実行し、インストーラをもう一度実行してください。"

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="以前の回答が見つかりました"
MSG_PROMPT_REUSE_SETTINGS_HELP="この Mac で以前のインストールが試みられた形跡が見つかりました。すでに回答した質問(名前、アシスタント名、タイムゾーン、国番号、チャンネルなど)は再利用されるため、もう一度入力する必要はありません。続きから進めるには「はい」、最初から質問をやり直すには「いいえ」を選択してください。"
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="見つかった以前の回答: 名前 = %s、アシスタント = %s、タイムゾーン = %s。"

MSG_PROMPT_PERMS_OK_TITLE="続けますか?"
MSG_PROMPT_PERMS_OK_HELP="macOS から「連絡先」と「ファイルとフォルダ」へのアクセスの確認が表示されます。「フルディスクアクセス」は任意で、あとから許可できます。"

MSG_PROMPT_USER_NAME_DETECTED_TITLE="氏名(連絡先に表示されているとおり)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="氏名(例: 山田 太郎)"

MSG_PROMPT_USER_ID_TITLE="アシスタントにどう呼んでほしいですか?"
MSG_PROMPT_USER_ID_HELP="アシスタントがあなたに呼びかけるときの短い名前です(例: 「太郎」、「山田さん」)。朝のブリーフやチャットの返信に表示されます。上の氏名とは別のものです。"

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
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="こちらがあなたのカレンダーです。内容は合っていますか?"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="それぞれ誰のものかを推測しました。ブリーフで誰の旅行かが混同されることはありません。"
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="自動的に除外され、ブリーフには使われません:"
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="自分"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="%s 件の予定"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="%s 件の予定"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="祝日"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="誕生日"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="Siri の提案"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="購読しているカレンダー"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="リマインダー"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="Include \"%s\" in your brief?"
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="This looks like %s rather than appointments, so we left it out. Switch on if it holds real plans."
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="「%s」は誰のカレンダーですか?"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="「%s」はどの種類のカレンダーですか?"
# NEEDS REVIEW: 'One of:' suggests the customer may type these values and the installer may compare them in English; kept English tokens with Japanese glosses. Confirm whether
MSG_CONFIRM_CALENDAR_TYPE_HELP="personal(個人)、work(仕事)、family(家族)、shared(共有)、other(その他)のいずれかです。予定をどの程度機密として扱うかが決まります。"
MSG_CONFIRM_CALENDARS_SAVED="カレンダーの所有者を保存しました"
MSG_CONFIRM_CALENDARS_FAILED="カレンダーの所有者を保存できませんでした(致命的ではありません。あとから設定できます)"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="これらのプロフィールはすべてあなた自身(%s)だと思われます。1つにまとめますか?"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="これらのプロフィールは、あなたと確実な識別情報(メールのドメイン、LinkedIn のプロフィール、勤務先)を共有しています。まとめると、アシスタントがあなた自身の履歴を複数の別人として扱うことがなくなります。あとで元に戻せます。"
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="あなたと同じ名前の人がいますが、別の人のようです(%s)。これはあなたですか、それとも別の人ですか?"
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="別の人として分けて保存するには「別人」を選んでください(アシスタントがその人をあなたに統合することはありません)。本当にあなた自身の場合のみ「自分」を選んでください。"
MSG_CONFIRM_IDENTITY_SAVED="本人の選択を保存しました"
MSG_CONFIRM_IDENTITY_FAILED="本人の選択を保存できませんでした(致命的ではありません。後で確認できます)"

# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="バックグラウンドでインストール中(約45分から数時間)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="+%sを使用しますか?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="国番号を入力してください(例:英国は44、米国は1)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="デフォルトの国番号"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="連絡先の読み込み時に電話番号を正規化するほか、法令遵守の初期設定のために地域(英国 / EU / 米国 / その他)を設定する目的で使用されます。"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="+%sを検出しました。あなたのHubでこれを使用しますか?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="上の電話番号から検出しました。使用する場合は「はい」、別の国番号を入力する場合は「いいえ」を選んでください。"

MSG_PROMPT_TZ_CONFIRM_TITLE="このタイムゾーンを使用しますか?"
MSG_PROMPT_TZ_CONFIRM_HELP="検出されたタイムゾーン:%s"
MSG_PROMPT_USER_TZ_TITLE="タイムゾーンを入力してください(例:Europe/London、Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="アシスタントにどんな名前を付けますか?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="入力欄の名前はランダムな候補です。好きな名前に自由に書き換えてください。Marvin、Samantha、Joshua、Friday、Athena、Sage、Rosieなどが人気です。" # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="好きな名前を自由に入力してください。候補はあくまで出発点です。"

MSG_PROMPT_CHANNEL_CHOICE_TITLE="アシスタントはどのように連絡しますか?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="アシスタントに使ってほしいメッセージのチャンネルを選んでください。後からアプリのDoctorセクションで変更できます。"

MSG_PROMPT_WHATSAPP_CONSENT_TITLE="Enable WhatsApp messaging for your assistant?"
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web is a third-party service. By enabling, you accept that your messages route through WhatsApp's own infrastructure before reaching your local Ostler instance, and that WhatsApp (Meta Platforms Ireland Ltd) may suspend, restrict, or terminate your WhatsApp account because of automated use. You can disable this later from Settings."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="あなたのWhatsApp電話番号"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="国番号を含む国際形式の番号(例:+447700900123)。数字と先頭の+のみ。スペース、かっこ、ハイフンは使わないでください。"
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="%sとして保存されました。WhatsAppでは、スペースやかっこのない番号が必要です。"

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Ostlerアシスタントにフルディスクアクセスを許可"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="システム設定でフルディスクアクセスが開いています。"
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
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="リストで「%s」を探し、フルディスクアクセスのスイッチをオンにしてください。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="リストにない場合は、Finderウインドウから「%s」をリストにドラッグし、スイッチをオンにしてください。順番は問いません。「完了」はスイッチをオンにする前でも後でもクリックできます。インストーラはスイッチが実際にオンになるまで待機します。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="リストにない場合:OstlerがFinderウインドウを開けませんでした。Finderで⌘⇧Gを押し、下のパスを入力して、「%s」をリストにドラッグし、スイッチをオンにしてください。順番は問いません。「完了」はスイッチをオンにする前でも後でもクリックできます。インストーラはスイッチが実際にオンになるまで待機します。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="アプリの場所:%s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="アプリの場所:%s – このパスはクリップボードにコピーされています。Finderで⌘⇧Gを押し、⌘Vを押してから、Returnを押してください。"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="完了"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="スイッチを切り替える前でも後でも「完了」をクリックできます。インストーラはスイッチが実際にオンになるまで待機します。"

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="OstlerにMacのデータの読み取りを許可"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="システム設定でフルディスクアクセスが開いています。"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="リストで「OstlerInstaller」を探し、オンにしてください。"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="終わったら「完了」をクリックしてください。OstlerがSafariの履歴、メモ、iMessage、メールを読み取ります。"
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="完了"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="次の手順:インストーラのフルディスクアクセス"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="次に、macOSからOstlerInstallerにフルディスクアクセスを許可するよう求められます。"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="スイッチをオンにすると、macOSが「終了して再度開く」か「後で」を選ぶダイアログを表示します。"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="「終了して再度開く」をクリックしてください。インストーラが自動的に再起動し、このステップから続行します。"
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="OK"
MSG_INFO_INSTALLER_FDA_PREWARN="フルディスクアクセスの許可手順をご案内しています..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="インストーラにフルディスクアクセスを許可できるよう、システム設定を開いています..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="インストーラにフルディスクアクセスが許可されました。次にSafari、メモ、iMessage、メールを読み込みます。"
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="フルディスクアクセスがまだ許可されていません。許可なしで続行します。Safari / メモ / iMessageの抽出は、後でインストーラを再実行すると行えます。"
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="インストーラのフルディスクアクセスの設定が完了しました。ここから時間のかかる工程が始まり、ほとんどは自動で進みます。ただし、macOSから開発者ツールのインストールを求めるダイアログが表示されることがあるのでご注意ください。また、終盤に数分間のセットアップがあるので、そのときは戻ってきてください。"
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="もう1つの許可(アシスタント用のメッセージ履歴)は、アシスタントのインストール後、終盤に必要になります。その際にご案内します。"
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="フルディスクアクセスが必要です"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostlerがこれからお使いのMacのデータを読み込みますが、OstlerInstallerのフルディスクアクセスがまだオフです。リストで「OstlerInstaller」を探し、オンにしてください。"
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="または「続行」をクリックして、少ないデータのままインストールを完了することもできます。後から許可して、抽出を再実行できます。"
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="続行"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="許可する連絡先"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="信頼する相手の電話番号とApple IDのメールアドレス(カンマ区切り)。%sはこのリストにいる相手にのみ返信し、それ以外の相手からのメッセージは無視します。1件以上の入力が必要です。

例:
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="Apple Mail経由でメールを読み込みますか?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="Apple Mailに追加済みのメールアカウント(iCloud、Gmail、Outlookなど)を、フルディスクアクセスを使って読み込みます。パスワードは保存されません。ほとんどの方におすすめです。"

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="Apple Mailにメールアカウントを追加しますか?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="このMacのApple Mailにはまだアカウントが接続されていないため、Ostlerが読み込むメールがありません。「はい」を選ぶと、システム設定の「インターネットアカウント」が開きます(iCloud、Gmail、Outlookを追加できます)。「いいえ」を選ぶとスキップします。後でアカウントを追加でき、24時間以内にメールが届かない場合はDoctorがお知らせします。"

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="Apple Mailの全履歴を取り込みますか?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="Ostlerは通常、Apple Mailの過去5年分を読み込みます。このMacにそれ以上のメールがあり、すべてをナレッジグラフに取り込みたい場合は「はい」を選んでください。ローカルの全履歴を今取り込みます(メールボックスが大きいと少し時間がかかります)。「いいえ」を選ぶと5年分のままになります。後でDoctorからいつでも期間を延ばせます。"

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="カスタムIMAP+SMTPサーバも設定しますか?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="セルフホストのメールボックス専用です。Gmail、iCloud、Outlookをお使いの場合は「いいえ」のままにしてください。上記のApple Mail経由のほうが適しています。"

MSG_PROMPT_IMAP_HOST_TITLE="IMAPホスト"
MSG_PROMPT_IMAP_HOST_HELP="セルフホストまたはカスタムIMAPサーバ専用です。Gmail / iCloud / Outlookには上記のApple Mailを使用してください。"
MSG_PROMPT_IMAP_PORT_TITLE="IMAPポート"

MSG_PROMPT_SMTP_HOST_TITLE="SMTPホスト"
MSG_PROMPT_SMTP_PORT_TITLE="SMTPポート"

MSG_PROMPT_EMAIL_USERNAME_TITLE="メールアドレス(IMAP/SMTPのユーザ名にも使用)"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="アシスタントにメールを送れる人"
MSG_PROMPT_EMAIL_ALLOWED_HELP="あなた自身のメールアドレスをカンマ区切りで入力してください。%sはこのリストにあるアドレスからのメールにのみ返信し、それ以外からのメールは無視します。1件以上のアドレスが必要です。あなたのアドレスは自動で入力されています。変更または追加できます。"

MSG_PROMPT_EMAIL_PASSWORD_TITLE="パスワード(非表示)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="Password for your self-hosted IMAP/SMTP server. Stored locally in ~/.ostler/secrets/, not in your settings file, and never sent to Creative Machines. It is saved in plain text: the only thing protecting it is the file's permissions, which allow your macOS account and nobody else. Nothing encrypts it later. Use an app password rather than your main account password."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="パスワードを確認"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="アシスタントに監視させるフォルダはどれですか?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="おすすめ:専用のラベルまたはフォルダ(例:Ostler)。そこにあるメッセージだけを読み込み、メインの受信トレイには触れません。"

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="確認のためもう一度INBOXと入力するか、「続行」を押して「Ostler」を使用します"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOXを指定すると、アシスタントは受信するすべてのメールを読み込みます。代わりに専用のラベル/フォルダを強くおすすめします。"

MSG_PROMPT_EXPORTS_ACK_TITLE="データのエクスポートはリクエストしましたか?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler imports 18 platform exports. The full list, with direct links to each provider's request page, is at docs.ostler.ai/data-exports.

Most archives take 1 to 3 days to arrive by email. When the ZIPs land, drop them in your Downloads folder and Ostler will find them automatically.

Skip any you do not use; you can always import more later."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="ディスクを暗号化しないまま続けますか?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="このMacではFileVaultがオフのため、ディスクは保存時に暗号化されていません。

続行した場合の影響:Ostlerが保存するすべてのデータ(~/Documents/Ostler 内の個人グラフ全体(Wiki、会話、ナレッジノート)、および ~/.ostler 内のサービスのシークレットとデータベース)が、暗号化されずにディスクへ書き込まれます。このドライブから起動できる人、ドライブを取り外せる人、ロック解除されたセッションにアクセスできる人は、そのすべてを読み取れます。Ostlerは最も機密性の高いデータベースをパスフレーズで常に暗号化しますが、それ以外のデータはディスク自体と同程度にしか保護されません。

FileVaultの使用を強くおすすめします。「システム設定」>「プライバシーとセキュリティ」>「FileVault」でいつでもオンにでき、再インストールせずにバックグラウンドで暗号化されます。

「はい」を選ぶと、ディスクを暗号化しないままこのまま続行します(これは意図的で、十分に理解したうえでの選択として記録されます)。
「いいえ」を選ぶと、ここで中止します。先にFileVaultをオンにしてから、インストーラをもう一度実行してください。どちらを選んでも問題は起きていません。"

MSG_PROMPT_PASSKEY_ACK_TITLE="ディスク暗号化の設定準備ができました"
MSG_PROMPT_PASSKEY_ACK_HELP="Ostlerの機密性の高いデータベースは、次の画面で選ぶパスフレーズを使ってSQLCipherで暗号化されます。Hub UIを起動するたびに、このパスフレーズを入力します。別のリカバリキーも生成され、インストールの最後に一度だけ表示されます。Mac上のすべてのデータを保存時に保護するには、macOSのFileVaultをオンのままにしてください。準備ができたら「続ける」を押してください。"

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="リカバリ用のパスフレーズも設定しますか?(推奨)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="パスフレーズを選択"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="このパスフレーズはナレッジグラフを暗号化し、起動のたびにHub UIのロックを解除します。12文字以上で入力してください。パスフレーズを復元することはできません。パスワードマネージャに保管することをおすすめします。"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="パスフレーズを確認"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="確認のため、同じパスフレーズをもう一度入力してください。"

MSG_PROMPT_IMPORT_CONFIRM_TITLE="インストール中にこれらを読み込みますか?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="見つかったGDPRエクスポートは、インストール中にナレッジグラフへ読み込まれます。"

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="Disney+エクスポートのパスワード"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="Disney+はGDPRエクスポートをパスワード保護されたスプレッドシートで提供します。これは通常の仕様で、ダウンロードに問題があるわけではありません。Disney+の視聴履歴を今すぐ読み込むにはパスワードを入力してください。空欄のままにするとスキップされ、それ以外のデータは引き続き読み込まれます。"

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="データのエクスポートは用意できましたか?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostlerは、ソーシャルメディアやプラットフォームのアーカイブ(友人や家族とのやり取り、場所、意見など、これまでの履歴すべて)を最初から読み込めます。初日にOstlerが知っていることが多いほど、初日から役に立ちます。あとから追加することもできるので、急ぐ必要はありません。

各プラットフォーム(Twitter / X、Facebook、Instagram、LinkedIn、WhatsAppなど)にデータのエクスポートをリクエストし、ZIPファイルをダウンロードして、「ダウンロード」フォルダに入れてください。

Ostlerは標準で ~/Downloads を探します。別のフォルダを使う場合は、下で選択してください。そうでなければ、スキップしてあとで読み込めます。"

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="このTakeoutからGmailのメッセージを読み込みますか?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="GmailのコンテンツをTakeoutファイルから直接読み取ります。GoogleにOstlerの存在が知られることはありません。"

MSG_PROMPT_FDA_PRESET_TITLE="OstlerにどのMacのデータソースを学習させますか?"
MSG_PROMPT_FDA_PRESET_HELP="3つのプリセットから選ぶか、1つずつ自分で選べます。機微なソース(顔認識)は、どのプリセットでも初期状態でオフです。使いたい場合は、よく考えて選択してください。"
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="おすすめ。Apple Mail、連絡先、カレンダー、メモ、メッセージ、リマインダー、Safariの履歴、Safariのブックマーク、写真のイベント(日付と場所のみ、顔認識なし)を含みます。WhatsApp Desktopの履歴とChromeの履歴は、アプリがインストールされていれば自動的に追加されます。写真の顔認識データと、サードパーティのエクスポートアーカイブは含まれません。"
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="すべて。OstlerがこのMacで読み取れるすべてのソースです。写真の顔認識は、自分でチェックを入れるまでオフのままです。"
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="カスタマイズ。次の画面でソースを1つずつ選びます。機微なソースは、チェックを入れるまでオフのままです。"

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="このデータソースのオン/オフを切り替えます。"

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
# English prevails over any translation. Legal text stays English in every locale.
MSG_TERMS_LANGUAGE="Language. These terms are written in English. Any translation is provided for convenience only. If a translation differs from the English version, the English version prevails."
MSG_PROMPT_TERMS_PERSONAL_USE_TITLE="Ostler is for personal use"
MSG_PROMPT_TERMS_PERSONAL_USE_HELP="Ostler is licensed for your own personal use on your own Mac. Please do not deploy it to staff or use it at work to capture colleagues, clients or patients. Do not record children without a parent agreeing, and do not record in places where people expect real privacy such as a doctor, solicitor or therapy appointment. Press Continue to accept these terms.

Language. These terms are written in English. Any translation is provided for convenience only. If a translation differs from the English version, the English version prevails."
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
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="話し言葉の文字起こしはオフのままになります。後から設定でオンにできます。"

MSG_PROMPT_CONSENT_INSTALL_TITLE="Ready to install?"
MSG_PROMPT_CONSENT_INSTALL_HELP="Please type INSTALL to confirm you accept the terms."
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="Type INSTALL"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Install Ostler"
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="Cancel"
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="Type INSTALL exactly (case does not matter) to confirm, or click Cancel to go back."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="iPhoneとApple Watchを接続"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscaleにより、このMacに固定のプライベートアドレスが割り当てられ、iPhoneやApple Watchからどこでも接続できます。通信は暗号化され、外部に公開されることはありません。"

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="復旧キーを「キーチェーン」に保存しますか?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="暗号化の復旧キーをmacOSの「キーチェーン」に保管します。"

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="グラフにデータを読み込み中"
MSG_HYDRATE_CONTACTS_STARTED="連絡先をグラフに読み込み中"
MSG_HYDRATE_CONTACTS_DONE="%s件の連絡先を読み込みました"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="連絡先の処理に%s秒以上かかったため、待機を終了して次に進みました。現在%s件の連絡先が読み込まれており、残りはOstlerがバックグラウンドで完了します。"
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="カレンダーの履歴を読み込み中(5年前から1年先まで)"
MSG_HYDRATE_CALENDAR_DONE="%s件のイベントを読み込みました"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  カレンダーを読み込み中です(これまでに%s秒)。長年の予定がある Mac では少し時間がかかります。"
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="会った場所から「場所」を作成しています"
MSG_HYDRATE_PLACES_DONE="「場所」セクションを作成しました"
MSG_HYDRATE_PLACES_SKIPPED="位置情報はまだ見つかっていません。カレンダーにデータが入ると「場所」が増えていきます"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="「場所」の作成中に問題が発生しました。位置情報はありますが、「場所」が作成されませんでした。「場所」ページが空のままになる可能性があります。詳細: %s"
MSG_HYDRATE_PLACES_ERROR_WARN="「場所」の作成が完了しませんでした(予期しないエラー)。「場所」ページが不完全な可能性があります。詳細: %s"
MSG_HYDRATE_WIKI_RECOMPILE="Wiki を作成しています。Ostler が、主要な人物、組織、トピックごとに短い要約を書いています。連絡先が多い場合は、数分から1時間ほどかかることがあります。この処理は一度だけで、すべて Mac 上で実行され、そのままにしておいても問題ありません。"

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="検索インデックスを確認しています(コレクションを%s件検出)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="閲覧履歴を検索インデックスに読み込んでいます"
MSG_INITIAL_HYDRATE_QDRANT_READY="検索インデックスの準備ができました(コレクション%s件)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="検索インデックスは、インストール完了後にバックグラウンドで作成されます"
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
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="検索ストアが起動しました。不足しているコレクションを作成しています: %s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="検索インデックスが不完全です。検索ストアは動作して応答していますが、%s を作成できませんでした。Ostler は引き続き動作し、Doctor にもこの不足が表示されますが、修正されるまで検索のこの部分は空のままになります。"
MSG_WARN_QDRANT_COLLECTIONS_MISSING="検索インデックスが不完全です。%s を作成できませんでした。Ostler は引き続き動作し、Doctor にもこの不足が表示されます。"
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="検索コレクションが存在するかどうかを確認できませんでした(%s)。コレクションが不足しているという報告ではありません。"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="検索インデックスは、インストール完了後にバックグラウンドで作成されます(待機中: %s)"
MSG_HYDRATE_DONE="グラフの準備ができました: 人物%s人、イベント%s件"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud で連絡先がまだ同期中の可能性があります。届いたばかりの内容を取り込むため、再度書き出しています。"
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="「連絡先」アプリ(ローカルまたは iCloud)に連絡先が見つかりません。「連絡先」に追加してから、設定で再実行してください。"
MSG_HYDRATE_SKIPPED_NO_CONTACTS="読み込む iCloud の連絡先がありません。後で設定から追加できます。"
MSG_HYDRATE_SKIPPED_NO_EVENTS="過去5年間にカレンダーのイベントはありません。後で設定から読み込めます。"

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="過去90日分のメールを読み込んでいます。メールはこの Mac の外には出ません(それ以前の履歴はバックグラウンドで読み込まれます)"
MSG_HYDRATE_EMAIL_DONE="最近のメールから%s人が見つかりました"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="読み込む最近のメールがありません。Apple Mail にメールアカウントを追加して、後で再実行できます。"
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="メールリーダーの準備がまだできていません。Apple Mail にメールアカウントを追加して、後で再実行できます。"
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="メールはバックグラウンドで読み込み中です。Wiki は進むにつれて内容が増え、現在の進行状況も表示されます。"
MSG_HYDRATE_EMAIL_HEARTBEAT="  メールを読み込み中です(これまでに%s秒)。長年の履歴がある Mac では時間がかかることがあります。"

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="Apple Mail を開いて同期を開始しますか?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="メールアカウントが%s件設定されていますが、Apple Mail はまだメッセージを取得していません。Mail.app を開き、同期が終わるまで待つことができます。"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="カレンダーを開いて同期を開始しますか?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="カレンダーアカウントが%s件設定されていますが、Calendar.app にはまだイベントが保存されていません。カレンダーを開き、iCloud から同期されるまで待つことができます。"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="連絡先を開いて同期を開始しますか?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="連絡先アカウントが%s件設定されていますが、Contacts.app にはまだ項目が保存されていません。連絡先を開き、iCloud から同期されるまで待つことができます。"

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="%s の同期開始を待っています(最大%s秒)。"
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="%s の同期をまだ待っています(経過%s秒、残り%s秒)。サインインしたばかりの場合、iCloud の最初の同期には数分かかることがあります。"
MSG_OK_APP_HAS_POPULATED="%s のローカルストアにデータが入りました。続行します。"
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="待機時間内に %s の同期を確認できませんでした。続行します。後で設定からデータの読み込みを再実行できます。"

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="確認できる Apple Mail アカウント: %s。メッセージの取得を始めるため、Mail.app を一度開いてください。"
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="確認できるカレンダーアカウント: %s。イベントを同期するため、Calendar.app を一度開いてください。"
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="確認できる連絡先アカウント: %s。アドレスブックを同期するため、Contacts.app を一度開いてください。"

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="連絡先を読み込めませんでした。Ostlerはフルディスクアクセスを通じて連絡先を読み込みます。「システム設定 > プライバシーとセキュリティ > フルディスクアクセス」で許可してから、設定でハイドレーションを再実行してください。バックグラウンドで再試行を続けます。"
MSG_HYDRATE_CONTACTS_PENDING="連絡先Appはまだ同期されていません。連絡先を一度開き、同期が完了するまで待ってから、設定でハイドレーションを再実行してください。"
MSG_HYDRATE_CONTACTS_READ_FAILED="このMacには連絡先がありますが、Ostlerが読み込めたのは0件でした。想定外の状態です。読み込みはバックグラウンドで自動的に再試行されます。改善しない場合は、設定でハイドレーションを再実行するか、インストールログを確認してください。"
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostlerはバックグラウンドで確認を続け、iCloudの同期が完了したら連絡先を自動的に読み込みます。"
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="電話番号のある連絡先を%s件読み込みましたが、メールアドレスがほとんどありません(電話%s件、メール%s件)。連絡先リーダーがメールアドレスを取りこぼした可能性があります。連絡先はそのままお使いいただけます。%sを確認し、解決したら設定でハイドレーションを再実行してください。"
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="新しい連絡先を読み込みました。バックグラウンドでwikiを再構築しています。"
MSG_HYDRATE_CALENDAR_PENDING="カレンダーAppはまだ予定を同期していません。カレンダーを一度開き、同期が完了するまで待ってから、設定でハイドレーションを再実行してください。"
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="今回はカレンダーを読み込めませんでした(カレンダーが空だったのではなく、抽出ツールがエラーを報告しました)。ほかのデータには影響ありません。%sを確認してから、設定でハイドレーションを再実行してください。"

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="WhatsApp の履歴を読み込んでいます。メッセージはこの Mac の外には出ません"
MSG_HYDRATE_WHATSAPP_DONE="WhatsAppのチャットで%s人が見つかりました"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="WhatsAppのチャットは読み込まれましたが、人物グラフに書き込まれませんでした(終了コード %s)。Ostlerは再試行します。詳細: %s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="読み込むWhatsAppのチャットがありません。あとで設定から再実行できます。"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktopがインストールされていません。Mac App Storeからインストールし、設定で再実行してください。"
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="WhatsAppリーダーの準備がまだできていません。あとで設定から再実行できます。"
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsAppはバックグラウンドで読み込み中です。wikiは進むにつれて内容が増え、現在の進行状況も表示されます。"

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
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="WhatsAppの連絡先はすでに人物グラフにあります(識別子%s件)。再度読み込む必要はありません。"
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="WhatsAppの連絡先は以前に読み込まれましたが、人物グラフには残っていません。もう一度読み込みます。"
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="WhatsAppの連絡先がまだ人物グラフにあるか確認できませんでした。あると決めつけず、もう一度読み込みます。"

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="AIチャットの履歴を読み込んでいます – 会話はこのMacの外に出ません"
MSG_HYDRATE_AICONV_DONE="AIの会話を%s件wikiに保存しました"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="AI会話リーダーの準備がまだできていません。あとで設定から再実行できます。"
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="読み込むAIチャット履歴がありません。あとで設定から再実行できます。"
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="AIチャットはバックグラウンドで読み込み中です。wikiは進むにつれて内容が増え、現在の進行状況も表示されます。"
MSG_HYDRATE_AICONV_HEARTBEAT="  AIチャット履歴を読み込み中です(これまで%s秒)。履歴が大きい場合は数分かかることがあります。"


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="閲覧履歴を取り込んでいます – 訪問したページはこのMacの外に出ません"
MSG_HYDRATE_BROWSING_DONE="閲覧履歴を%sページ取り込みました"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="機密性が高いと判断された%sページ(銀行、医療など)をスキップしました"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="取り込む閲覧履歴がありません。あとで設定から再実行できます。"
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="閲覧履歴リーダーの準備がまだできていません。あとで設定から再実行できます。"

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
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="閲覧履歴はすでに取り込み済みです(%sページ)。再度取り込む必要はありません。"
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="取り込めるエクスポート済みの閲覧履歴が見つかりません。あとで設定から再実行できます。"
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="閲覧履歴は以前に取り込まれましたが、検索インデックスには残っていません。もう一度取り込みます。"
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="閲覧履歴がまだ検索インデックスにあるか確認できませんでした。あると決めつけず、もう一度取り込みます。"
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="閲覧履歴が検索インデックスに届かなかったため、「閲覧履歴」ページは空になります。設定から再実行するか、Doctorを開いてください。"
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="閲覧履歴はバックグラウンドで読み込み中です。wikiは進むにつれて内容が増え、現在の進行状況も表示されます。"

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="メールの好みを読み込んでいます。データはこのMacの外に出ません。数分かかることがあります。"
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="メール履歴から好みを%s件読み込みました"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="メールの好みのファイルが設定されていません。読み込むものはありません。"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="%sにメールの好みのファイルが見つかりません。読み込むものはありません。"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="好みの処理パイプラインの準備がまだできていません。あとで設定から再実行できます。"
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="メールから得た好みデータはバックグラウンドで読み込み中です。ウィキは読み込みに合わせて更新され、進行状況も表示されます。"
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  メールから得た好みデータを読み込み中です(これまでに%s秒)。履歴が大量にある場合は数分かかることがあります。"

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="メールから得た好みデータはすでに読み込み済みです(%s件)。再読み込みは不要です。"
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="メールから得た好みデータは以前に読み込まれましたが、検索インデックスに残っていません。もう一度読み込みます。"
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="メールから得た好みデータが検索インデックスにまだあるか確認できませんでした。あると決めつけず、もう一度読み込みます。"

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
MSG_HYDRATE_PREFERENCES_DONE="%s件の好みデータを読み込みました"
MSG_HYDRATE_PREFERENCES_ENRICHED="そのうち%s件に公開の参照データを追加しました"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="%s件の好みデータを読み込みましたが、「食べ物」「音楽」「仕事」に分類されたものはありません。ウィキの食べ物と音楽のページは空になります。"
MSG_WARN_PREFS_HEADLINE_HINT="音楽や食べ物のエクスポート(Spotify、Apple Music、Uber Eats、Google Takeout)がなかったか、データが分類されていなかった可能性があります。それらのエクスポートを追加し、設定から再実行してから、ウィキを再構築してください。"
MSG_WARN_PREFS_UNCATEGORISED="好みデータ%s件(全%s件中、%s%%)にカテゴリがなく、どのトピックページにも表示されません。元のエクスポート形式を確認してください。"

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="好みデータの補完を準備中"
MSG_CM019_SETUP_DONE="好みデータの補完の準備ができました"
MSG_CM019_SETUP_FAILED="好みデータの補完の準備が完了しませんでした。問題が解決すると好みのページにデータが表示されます。Ostlerのそのほかの機能には影響ありません。"
MSG_CM019_SETUP_SKIPPED="好みデータの補完機能は同梱されていないため、今回はスキップします。"

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="iMessageの履歴を読み込み中 – メッセージはこのMacの外に出ません"
MSG_HYDRATE_IMESSAGE_DONE="iMessageの履歴から%s人が見つかりました"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="読み込めるiMessageの履歴がありません。あとで設定から再実行できます。"
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="iMessageの読み取り機能がまだ準備できていません。あとで設定から再実行できます。"
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessageはバックグラウンドで読み込み中です。ウィキは読み込みに合わせて更新され、進行状況も表示されます。"
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  iMessageの履歴を読み込み中です(これまでに%s秒)。メッセージの履歴が大量にある場合は数分かかることがあります。"

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="iMessageの連絡先はすでに人物グラフにあります(識別子%s件)。再読み込みは不要です。"
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="iMessageの連絡先は以前に読み込まれましたが、人物グラフに残っていません。もう一度読み込みます。"
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="iMessageの連絡先が人物グラフにまだあるか確認できませんでした。あると決めつけず、もう一度読み込みます。"

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="メモを読み込み中 - メモはこのMacの外に出ません"
MSG_HYDRATE_APPLE_NOTES_DONE="%s件のメモをナレッジベースに追加しました"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="読み込めるメモがありません。あとで設定から再実行できます。"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="メモはすでにナレッジベースにあります。スキップします。"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="メモはナレッジ検索でオフになっています。設定でオンにできます。"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="ナレッジのインポート機能がまだ準備できていません。あとで設定から再実行できます。"
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="メモはバックグラウンドで読み込み中です。ナレッジベースは読み込みに合わせて更新され、進行状況も表示されます。"
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  メモを読み込み中です(これまでに%s秒)。メモが大量にある場合は数分かかることがあります。"

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="メモはすでにナレッジベースにあります(%s件)。再読み込みは不要です。"
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="メモは以前に追加されましたが、ナレッジベースに残っていません。もう一度追加します。"
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="メモがナレッジベースにまだあるか確認できませんでした。あると決めつけず、もう一度追加します。"

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="リマインダーを読み込み中 - リマインダーはこのMacの外に出ません"
MSG_HYDRATE_REMINDERS_DONE="%s件のリマインダーをナレッジベースに追加しました"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="読み込めるリマインダーがありません。あとで設定から再実行できます。"
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="リマインダーはすでにナレッジベースにあります。スキップします。"
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="リマインダーはナレッジ検索でオフになっています。設定でオンにできます。"
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="ナレッジのインポート機能がまだ準備できていません。あとで設定から再実行できます。"
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="リマインダーはバックグラウンドで読み込み中です。ナレッジベースは順次更新され、進行状況も表示されます。"
MSG_HYDRATE_REMINDERS_HEARTBEAT="  リマインダーをまだ読み込んでいます(これまで%s秒)。リマインダーの数が多い場合は数分かかることがあります。"

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="リマインダーはすでにナレッジベースに登録されています(%s件)。再読み込みの必要はありません。"
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="リマインダーは以前に追加されましたが、ナレッジベースに見つかりません。もう一度追加します。"
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="リマインダーがナレッジベースにまだあるか確認できませんでした。あると決めつけず、もう一度追加します。"

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="連絡先を検索用にインデックス作成中"
MSG_HYDRATE_PEOPLE_DONE="%s人を検索用にインデックス作成しました"
MSG_HYDRATE_PEOPLE_PARTIAL="これまでに%s人/%s人を検索用にインデックス作成しました。残りはまだ検索できません。Ostlerが自動的に再試行します。"
MSG_HYDRATE_PEOPLE_FAILED="今回は連絡先を検索用にインデックス作成できませんでした(グラフストアが応答しませんでした)。Ostlerが自動的に再試行します。詳細: %s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="インデックス作成する連絡先はまだありません。後で設定から再実行できます。"
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="連絡先のインデックス作成機能はまだ準備できていません。後で設定から再実行できます。"
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="連絡先はバックグラウンドでインデックス作成中です。検索は順次使えるようになり、進行状況はWikiで確認できます。"

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="連絡先はすでに検索用にインデックス作成済みです(%s人)。再作成の必要はありません。"
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="連絡先は以前にインデックス作成されましたが、検索インデックスに見つかりません。もう一度インデックスを作成します。"
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="連絡先が検索インデックスにまだあるか確認できませんでした。あると決めつけず、もう一度インデックスを作成します。"

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="フォルダアクセスの確認が3回表示されます"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="コマンドラインツールのダイアログがこのウインドウの前面に表示されています。ダイアログの「インストール」をクリックしてから、ここに戻ってください(数秒待つと、このウインドウを自動的に前面へ戻します)。ツールはバックグラウンドでダウンロードされるので、その間も下の質問に答えられます。ここでは何も止まりません。"

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="許可が必要です: iMessageのオートメーション"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostlerは、メッセージアプリを操作する許可をmacOSに求めます。macOSに「“OstlerInstaller”が“メッセージ”を制御するためのアクセスを求めています」というポップアップが表示されたら、「許可」をクリックしてください。これにより、アシスタントがあなたに代わってiMessageを送受信できます。この許可がないと、iMessageのメッセージはこのMacから送信されず、通知もされません。許可は一度だけで、後からシステム設定 > プライバシーとセキュリティ > オートメーションで変更できます。"

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="リカバリキー"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="今すぐ書き留めるか印刷してください。パスフレーズを紛失し、さらにキーチェーンにアクセスできなくなった場合、これが再びアクセスする唯一の方法です。Ostlerはこのキーを復元できません。キーはこのMacの外に出ることはなく、サーバには保存されません。"
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="安全な場所に保存しました"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="クリップボードにコピー"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="PDFとして保存..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="プリント..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="続ける"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Ostlerリカバリキー.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Ostlerリカバリキー"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="リカバリキーをクリップボードにコピーしました"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="リカバリキーを%sに保存しました"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="iPhoneをペアリング"
MSG_INFO_PAIR_IPHONE_HELP="iPhoneでOstlerアプリを開き、このQRコードをスキャンして、このHubとリンクしてください。後からHubの設定メニューでペアリングすることもできます。"
MSG_INFO_PAIR_IPHONE_FETCHING="ペアリングコードを生成中..."
MSG_INFO_PAIR_REFRESH="コードを更新"
MSG_ERR_PAIR_FETCH_FAILED="Ostlerゲートウェイにまだ接続できません。起動中の可能性があります。「コードを更新」をクリックして再試行してください。"

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agentがインストーラに含まれていません。毎日のブリーフとWhatsAppのキープアライブ用LaunchAgentは読み込まれません。"

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="Wiki再コンパイル用スクリプトがインストーラに含まれていません。Wikiは自動更新されません。"

# F3 - legal package missing
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="legal package not bundled with installer. Article 9 / WhatsApp / voice consent gates will raise ModuleNotFoundError until re-installed."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%sを%sにインストールしました"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%sはすでにインストールされています。そのままにします"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Google Workspace CLI は、この CPU アーキテクチャーには対応していません。Gmail / Google カレンダーの機能が制限されます。"
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl が見つからないため、Google Workspace CLI のインストールをスキップしました。Gmail / Google カレンダーの機能が制限されます。"
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="Google Workspace CLI を %s からダウンロードできませんでした"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="Google Workspace CLI の SHA256 が一致しません（期待値: %s、実際: %s）。このバイナリのインストールを中止します。"
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="Google Workspace CLI のアーカイブを展開できませんでした。"
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI を %s にインストールしましたが、--version の確認に失敗しました。"

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="iCloud / CalDAV カレンダーブリッジを %s にインストールしました"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="%s の iCloud / CalDAV カレンダーブリッジは実行可能ではありません。カレンダーの予定は取得されません。"

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh がインストーラに含まれていません。次回ネットワークに接続したときのデバイス登録の再試行は無効です。"

MSG_WARN_EMBED_DIMS_UNREADABLE="ヘルスチェックから埋め込みの次元数を読み取れませんでした。メモリは 768 次元で設定されています。想起の動作がおかしい場合は、埋め込みモデルを確認してください。"
MSG_FAIL_EMBED_DIMS="埋め込みモデルは %s 次元のベクトルを返しましたが、Ostler は %s 次元で設定されています。このままでは、一致しないベクトルがメモリに保存されてしまいます。埋め込みモデルを確認して、再実行してください。"

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
MSG_PROGRESS_REBOOT_SELFHEAL="再起動時の自己復旧を設定中"
MSG_INFO_AUTOLOGIN_EXPLAIN="Ostler は常時稼働のハブなので、停電や再起動のあとも、キーボードの前に誰もいなくても復帰する必要があります。そのためにはこの Mac が自動でサインインできなければならず、macOS が自動でサインインするには、%s のログインパスワードをこの Mac に保存しておく必要があります。

保存すると、この Mac の安全性は下がります。パスワードは暗号化ではなくスクランブルされるだけなので、この Mac の管理者アカウントを使える人や、ディスクを取り出して別の場所で読み取れる人は、元のパスワードに戻せます。入力する前に、保存先を正確にお知らせします。

「いいえ」を選ぶと、何も保存されず、ほかも変わりません。停電後はいつものとおりサインインし、Ostler のサービスはセッションとともに開始します。この設定は、あとから システム設定 > ユーザとグループ > 自動ログイン で変更できます。"
MSG_PROMPT_AUTOLOGIN_CONSENT="Store your login password on this Mac so it can sign itself in after a restart? [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="Ostler は、このパスワードをこの Mac の /etc/kcpassword にあるファイルに書き込みます。ファイル内では、すべての Mac で共通かつ公開されている固定のパターンでスクランブルされるため、暗号化ではなく、元に戻すことができます。この Mac の管理者アカウントを使える人や、ディスクを取り出して別の場所で読み取れる人は、そのファイルから %s のログインパスワードを復元できます。

FileVault を使えばこれを防げます。起動時のパスワードなしではディスクをまったく読み取れないためです。同じ理由で FileVault は自動サインインも妨げるので、Ostler は FileVault がオフのときにのみこの設定を提案します。

インストーラが管理できる範囲は次のとおりです。入力中のパスワードは表示されず、インストールログにも書き込まれません。スクランブルされたファイルが、インストーラが作成する唯一のコピーです。

自動サインインをスキップするには、空欄のままにしてください。"
MSG_PROMPT_AUTOLOGIN_PASSWORD="%s のログインパスワード"
MSG_OK_AUTOLOGIN_CONFIGURED="%s の自動サインインがオンになり、そのログインパスワードがスクランブルされた状態でこの Mac の /etc/kcpassword に保存されました。再起動後、この Mac は自動でサインインし、Ostler のサービスもそのセッションとともに開始します。元に戻すには、システム設定 > ユーザとグループ で自動ログインをオフにしてください。"
MSG_INFO_AUTOLOGIN_ALREADY="%s の自動サインインはすでに設定されているため、この Mac にはそのログインパスワードが /etc/kcpassword にすでに保存されています。どちらもそのままにします。元に戻すには、システム設定 > ユーザとグループ で自動ログインをオフにしてください。"
MSG_INFO_AUTOLOGIN_DECLINED="自動サインインは有効にならず、パスワードも保存されませんでした。再起動や停電のあとは、いつものとおりサインインしてください。Ostler のサービスはセッションとともに開始します。"
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="自動サインインの設定をスキップします。ここではログインパスワードを尋ねる方法がなく、何も保存されませんでした。再起動後にこの Mac を無人で復帰させたい場合は、あとから システム設定 > ユーザとグループ で自動ログインをオンにできます。その場合、ログインパスワードがスクランブルされた元に戻せる形で Mac に保存されるため、事前によく調べておくことをおすすめします。"
MSG_WARN_AUTOLOGIN_NO_PASSWORD="パスワードが入力されなかったため、自動サインインは有効にならず、何も保存されませんでした。あとから必要になった場合は、システム設定 > ユーザとグループ で自動ログインをオンにしてください。"
MSG_WARN_AUTOLOGIN_FAILED="自動サインインを有効にできませんでした（%s）。再試行は行いません。この Mac に /etc/kcpassword がある場合、機能がオフでも、そのファイルにはログインパスワードがスクランブルされた状態で残っています。ターミナルから次のコマンドで削除できます: sudo rm /etc/kcpassword。もう一度試すには、システム設定 > ユーザとグループ で自動ログインをオンにしてください。"
MSG_WARN_AUTOLOGIN_FILEVAULT="FileVault がオンのため、この Mac は誰かがサインインする前に、起動画面でディスクのロックを解除するパスワードを求めます。自動サインインではこれに答えられないので、停電後は、誰かが入力するまで FileVault のロック解除画面で待機します。自動サインインは有効にならず、パスワードも保存されませんでした。これは2つの方法のうち、より安全なほうです。FileVault がオンの間は無人での再起動復帰はできませんが、その代わり、パスワードを知らない人にはディスクを読み取られません。"

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
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="Ostler は システム設定 を開けませんでした。システム設定 を手動で開き、プライバシーとセキュリティ > フルディスクアクセス に移動してください。"
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="Ostler は Wiki と検索をコンテナで実行するため、この Mac にコンテナエンジン（Colima）をインストールして管理します。このエンジンが削除または再構成されると、Wiki と検索が動作しなくなります。その場合、Ostler がお知らせし、再起動を試みます。"
MSG_INFO_ENGINE_ALREADY_PRESENT="この Mac にはコンテナエンジンがすでにインストールされています。Ostler は独自のエンジンをインストールせず、これを使用します。管理や変更は行いません。"

# OS003 #233: model weight pins (install.sh OSTLER_MODEL_PINS).
MSG_OK_MODEL_DIGEST_VERIFIED="%s verified against its pinned digest (%s)"
MSG_FAIL_MODEL_DIGEST_MISMATCH="The installed %s is not the model this installer ships: found %s, expected %s (%s). The download source may have changed, so the install has stopped before using it. Contact support with this message."
MSG_FAIL_MODEL_UNPINNED="%s has no pinned digest in this installer, so it cannot be verified and will not be used. This is an installer defect. Contact support with this message."
MSG_FAIL_MODEL_DIGEST_UNREADABLE="Could not verify the downloaded %s against its pinned digest (%s). The model will not be used unverified. Re-run the installer; if this repeats, contact support with this message."
