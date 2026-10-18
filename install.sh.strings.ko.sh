#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to ko by l10n/ostler_l10n.py.
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

MSG_STEP_CHECKING_PREREQUISITES="사전 요구 사항 확인 중"
MSG_STEP_RUNNING_HEALTH_CHECK="상태 점검 실행 중"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="iPhone 및 Apple Watch 연결"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="설정(간단한 질문 몇 가지 후에는 자동으로 계속 진행됩니다)"
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
MSG_STEP_SETUP_COMPLETE_WRAP_UP="질문이 끝났습니다. 이제 Ostler가 백그라운드에서 설치를 진행합니다. 약 45분에서 몇 시간이 걸립니다. 그래도 세 가지는 직접 해 주셔야 합니다. macOS에서 개발자 도구 설치를 요청하면 설치를 클릭하세요. 설치가 끝나갈 무렵 1분 정도의 설정(전체 디스크 접근 권한 켜기)이 있습니다. 그리고 맨 마지막에 상태 점검이 끝나면 Tailscale에 로그인하고 어시스턴트가 미리 알림을 사용하도록 허용합니다. 그 사이에는 그대로 두셔도 됩니다."
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="질문이 끝났습니다. 이제 Ostler가 백그라운드에서 설치를 진행합니다. 약 45분에서 몇 시간이 걸립니다. 그래도 세 가지는 직접 해 주셔야 합니다. macOS에서 개발자 도구 설치를 요청하면 설치를 클릭하세요. 설치가 끝나갈 무렵 1분 정도의 설정(전체 디스크 접근 권한 켜기)이 있습니다. 그리고 맨 마지막에 어시스턴트가 미리 알림을 사용하도록 허용합니다. 그 사이에는 그대로 두셔도 됩니다."

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="그런 다음 다시 실행하세요: ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="어시스턴트가 전체 디스크 접근 권한으로 메시지 기록을 읽을 수 있도록 다시 시작하는 중입니다. 방금 허용한 권한은 다시 시작해야 적용됩니다. 아직 허용하지 않았다면 Doctor 대시보드에서 계속 안내해 드립니다."
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="어시스턴트가 실행 중이며 전체 디스크 접근 권한이 있어 필요한 파일을 읽을 수 있습니다."
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="어시스턴트가 실행 중이지만 아직 전체 디스크 접근 권한이 없습니다. 권한을 켜기 전까지 Ostler는 메시지, 메일, 캘린더, 미리 알림, 메모, 사진, Safari, 연락처, WhatsApp를 최신 상태로 유지할 수 없고 문서 폴더도 읽을 수 없습니다. 이미 읽은 내용은 그대로 유지됩니다. 권한을 켜는 방법은 Doctor 대시보드에서 안내해 드립니다."
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="어시스턴트가 실행 중입니다. 이 Mac에서 전체 디스크 접근 권한이 있는지 확인하지 못했으므로 어느 쪽인지 확정할 수 없습니다. 확인할 수 있게 되면 Doctor 대시보드에서 알려 드립니다."
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="확인된 Apple Mail 계정: %s (참고용)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="Apple Mail에 아직 로컬 메시지가 없는 것 같습니다. 24시간 안에 메일이 도착하지 않으면 Doctor에서 후속 안내를 표시합니다."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="Apple Mail에 캐시된 메시지가 있습니다. 매시간 실행되는 다음 가져오기 때 이 메시지를 불러옵니다."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="Apple Mail이 선택되어 있지만 이 Mac에는 아직 읽을 로컬 메시지가 없습니다. Apple Mail을 열고 계정을 추가한 다음(시스템 설정 > 인터넷 계정에서 메일 선택) 첫 동기화가 끝날 때까지 기다리세요."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="메일이 도착한 후 다시 실행하세요: ostler-fda. Ostler가 자동으로 가져오며 다른 작업은 필요하지 않습니다."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="Apple 공증은 처음 실행할 때 Gatekeeper가 확인합니다."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="사용할 수 있으면 설치 프로그램이 이 단계를 자동으로 건너뜁니다."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="접근 권한이 있는 베타 테스터는 PWG_PIPELINE_REPO=<url>을 설정한 후 다시 실행할 수 있습니다."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="접근 권한이 있는 베타 테스터는 PWG_KNOWLEDGE_REPO=<url>을 설정한 후 다시 실행할 수 있습니다."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="브라우저 확장 프로그램을 건너뜀 (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  %s에 복제했습니다."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture는 Apple 실리콘 전용입니다. 이 Mac에서는 설치를 건너뜁니다."
MSG_INFO_CM042_LOGS_AT="RemoteCapture 로그: %s/ostler-remotecapture.log (및 .err)"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="이전 설치에서 Ostler RemoteCapture가 로그인 시 시작되도록 설정되어 있었습니다. 이를 중지했으며 다시 시작되지 않습니다."
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="Ostler RemoteCapture가 설치되지 않았습니다. 음성 받아쓰기를 끈 상태로 두기로 선택하셨습니다. 마음이 바뀌면 설정에서 켠 다음 설치 프로그램을 다시 실행하세요."
MSG_INFO_CM042_TCC_PRE_PROMPT="처음 실행하면 Ostler RemoteCapture가 macOS에 화면 기록 및 마이크 권한을 요청합니다. 통화와 회의를 이 Mac에서 텍스트로 변환할 수 있도록 두 가지 모두 허용하세요. 메뉴 막대에 보라색 기록 표시는 나타나지 않습니다. 오디오 캡처는 의도적으로 조용히 이루어집니다."
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
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="Ostler는 개인 위키와 대화 기록을 이 Mac의 Documents/Ostler에 저장합니다. 이 파일은 사용자의 것이며 이 기기에만 보관됩니다. 파일을 쓰려면 Ostler가 문서 폴더에 접근해야 하므로 설정 중에, 그리고 오늘 나중에 Ostler가 위키를 처음 정리할 때 macOS가 다시 허용을 요청할 수 있습니다. 요청은 Ostler가 파일을 쓰는 데 사용하는 번들 도우미인 python3.11에서 온 것으로 표시될 수 있습니다. 요청이 나타나면 항상 허용을 클릭해 주세요. 놓치거나 허용하지 않은 경우에도 시스템 설정의 개인정보 보호 및 보안, 파일 및 폴더에서 언제든 켤 수 있으며, 그 후부터 위키와 대화 기록이 저장됩니다."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  대화 메모리 엔진이 venv에 설치되었습니다."
MSG_INFO_HUB_APP_VERIFYING="%s의 Ostler.app 확인 중"
MSG_INFO_HUB_APP_STAGING="%s에서 Ostler.app을 /Applications로 준비하는 중"
MSG_INFO_HUB_APP_DRAG_HINT="설치 프로그램 DMG를 열고 Ostler.app과 OstlerInstaller.app을 모두 Applications 바로가기로 드래그한 다음 설치 프로그램을 다시 실행하세요."
MSG_OK_HUB_APP_PRESENT="Ostler.app이 이미 %s에 있습니다. 서명을 확인했습니다."
MSG_OK_HUB_APP_STAGED="Ostler.app을 %s에 설치했습니다."
MSG_WARN_HUB_APP_NOT_FOUND="/Applications에서 Ostler.app을 찾을 수 없으며 사용할 수 있는 번들 사본도 없습니다."
MSG_WARN_HUB_APP_VERIFY_FAILED="Ostler.app 서명 또는 공증 확인에 실패했습니다. 지원팀이 점검할 수 있도록 번들을 그대로 둡니다."
MSG_OK_UNINSTALLER_APP_STAGED="Ostler Uninstaller.app을 %s에 설치했습니다."
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="Ostler Uninstaller.app을 /Applications에 넣을 수 없습니다. 다음 명령을 실행하여 제거할 수 있습니다: ~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="Doctor 에이전트 복제 중..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="이메일 가져오기 스크립트 복제 중..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="Hub 전원 스크립트 복제 중..."
MSG_INFO_CLONING_IMPORT_PIPELINE="가져오기 파이프라인 복제 중..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="위키 재컴파일 스크립트 복제 중..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima가 설치되어 있지만 실행 중이 아닙니다. 시작합니다."
MSG_INFO_COLIMA_START_ATTEMPT="Colima 시작 중(시도 %s/%s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="연락처를 내보낼 수 없습니다. 나중에 직접 가져올 수 있습니다."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="연락처 카드를 읽을 수 없습니다. 괜찮습니다. 대신 직접 여쭤보겠습니다."
MSG_INFO_CONTACT_CARD_WILL_ASK="잠시 후 이름과 국가를 여쭤보겠습니다. 연락처는 나중에 허용하신 전체 디스크 접근 권한으로 읽으며, 어떤 정보도 이 Mac 밖으로 나가지 않습니다."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  %s에 Python venv 생성 중..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="%s/에 사용자용 콘텐츠 트리 생성 중"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="매일 실행됩니다. 수동 실행: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="데스크탑 Hub(배터리 없음)가 감지되었습니다. 시스템 전체의 잠자기를 끕니다"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker가 설치되어 있지 않습니다. Colima + Docker CLI + docker-compose 플러그인을 설치합니다(가볍고 Docker Desktop이 필요 없음)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="Doctor 에이전트 파일이 설치 프로그램에 포함되어 있지 않습니다."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="이메일 가져오기 스크립트가 설치 프로그램에 포함되어 있지 않습니다."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="설치 프로그램 번들에 이메일 가져오기 스크립트가 없습니다. ostler.ai/install에서 .app을 다시 다운로드한 후 다시 시도하세요."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="이메일 가져오기 스크립트가 포함되어 있지 않고 --allow-plaintext가 전달되어 LaunchAgent 설치를 건너뜁니다. 앞으로의 이메일은 처리되지 않습니다."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  %s에 기존 체크아웃이 있습니다. 업데이트 중..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="Takeout zip에서 Gmail mbox 추출 중(대용량 보관함은 1분 정도 걸릴 수 있습니다)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="FDA 추출 모듈이 포함되어 있지 않습니다. 즉시 데이터 추출을 건너뜁니다."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="Ostler Pro 첫 30일을 활성화하는 중..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="체험 기간 이후 Ostler Pro는 월 \$9.99 USD입니다. iPhone의 Ostler app에서 구독하세요."
MSG_INFO_FOUND_GMAIL_MBOX_MB="%s에서 Gmail mbox를 찾았습니다(%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="%s에서 Google Takeout zip을 찾았습니다(%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="전체 디스크 접근 권한이 확인되었습니다. 전체 추출을 사용할 수 있습니다."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="GDPR 내보내기 파일이 감지되었지만 가져오기 파이프라인을 아직 사용할 수 없습니다."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="GDPR 내보내기 가져오기는 파이프라인이 출시되면 사용할 수 있습니다."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="저장해 두셨을 수 있는 AI 내보내기 파일(Google Takeout, Meta 다운로드, LinkedIn 등)을 찾기 위해 다운로드, 데스크탑, 문서 폴더를 검색하려고 합니다. macOS에서 폴더 접근 요청이 세 번 표시되며, 각각 허용해 주세요. 총 5~10초 정도 걸립니다. 검색 중에는 아무것도 이동하거나 복사하지 않으며, 어떤 파일이 있는지만 확인합니다."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="macOS에서 캘린더 읽기 권한을 요청할 수 있습니다. Ostler가 지식 그래프의 회의 및 일정 부분을 만들 수 있도록 허용해 주세요. (캘린더 데이터는 이 Mac에만 있습니다.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="macOS에서 다운로드 폴더 접근 권한을 요청하고 있습니다. 승인을 클릭하세요."
MSG_INFO_FOLDER_PREWARM_DESKTOP="macOS에서 데스크탑 폴더 접근 권한을 요청하고 있습니다. 승인을 클릭하세요."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="macOS에서 문서 폴더 접근 권한을 요청하고 있습니다. 승인을 클릭하세요."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="전체 디스크 접근 권한이 허용되었습니다. 다음 macOS 요청(메시지 자동화)을 준비하는 중..."
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="메시지 권한 요청에 응답이 없어 다음 단계로 넘어갔습니다. 허용하기 전에는 메시지를 읽지 않습니다. Ostler가 다시 요청하며, 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 직접 허용할 수도 있습니다."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="Xcode 명령어 라인 도구가 필요합니다. macOS가 설치 권한을 요청합니다. 작은 회색 대화상자를 찾아보세요. 보이지 않으면 Cmd+Tab을 누르거나 Dock을 확인하세요. 설치를 클릭하세요. 아래 질문에 답하는 동안 도구가 백그라운드에서 다운로드됩니다."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  명령어 라인 도구를 아직 설정하는 중입니다(%s초). 개발자 도구 설치를 묻는 작은 회색 macOS 대화상자가 있다면 설치를 클릭하세요. 이 단계는 그 응답을 기다리고 있습니다. (보이지 않으면 Cmd+Tab을 누르거나 Dock을 확인하세요.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="명령어 라인 도구 설치가 끝나기를 기다리는 중입니다(거의 완료)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="매시간 실행됩니다. 처음 실행할 때는 최근 5년간의 메일을 가져옵니다."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="기존 iMessage 브리지 LaunchAgent를 비활성화하는 중 (단일 기기 v1.0)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="전원 연결 전용 Hub입니다(배터리가 감지되지 않음). hub-power LaunchAgent를 건너뜁니다."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="Hub 전원 스크립트가 설치 프로그램에 포함되어 있지 않습니다."
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="노트북 Hub입니다. 덮개를 열어 두고 전원에 연결되어 있는 동안 계속 작동합니다."
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="덮개를 닫거나 배터리 상태로 사용하지 않고 두면 macOS가 잠자기 상태로 전환합니다."
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="잠자기 상태인 동안 어시스턴트는 아무것도 받지 못합니다."
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="그 사이에 도착한 메시지는 깨어난 뒤에도 가져오지 않습니다."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="닫힌 디스플레이 모드에서는 덮개를 닫아 둘 수 있습니다."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="전원 연결과 함께 외장 디스플레이, 키보드, 마우스가 필요합니다."
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="Docker와 Ollama는 배터리 사용 중에는 일시 중지되고 전원에 연결하면 다시 시작됩니다."
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="다시 시작한 후에는 FileVault 때문에 이 Mac이 로그인 화면에서 대기합니다."
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="Ostler는 로그인하면 시작됩니다."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="어시스턴트 API가 설치 프로그램에 포함되어 있어 번들된 소스를 사용합니다."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="어시스턴트 API 소스가 포함되어 있지 않습니다. iPhone의 Ostler 앱은 접근이 제한됩니다."
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="어시스턴트 API 런타임 종속 항목(phonenumbers, httpx)을 설치하는 중..."
MSG_WARN_ICAL_SERVER_DEPS_FAILED="어시스턴트 API 런타임 종속 항목(phonenumbers/httpx)을 설치하지 못했습니다. 다음 설치를 실행할 때까지 사람과 타임라인이 비어 있을 수 있습니다."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="Tailscale 창이 나타나면 Apple / Google / Microsoft 계정으로 로그인하세요."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="로그인할 수 있도록 Tailscale을 여는 중..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="알겠습니다. 지금부터는 Ostler가 대부분 알아서 설치합니다. 끝날 무렵 약 2분 동안 다시 와 주셔야 합니다. 전체 디스크 접근 권한을 켜고, iPhone과 Watch가 어디서나 이 Mac에 연결할 수 있도록 Tailscale에 로그인합니다. 로그인을 위해 브라우저를 열어 드립니다."
MSG_INFO_TAILSCALE_SKIPPED="Tailscale을 건너뛰었습니다. iPhone의 Ostler 앱은 집 Wi-Fi에서만 작동합니다. 나중에 설정에서 구성할 수 있습니다."
MSG_INFO_TAILSCALE_STILL_WAITING="Tailscale 로그인을 계속 기다리는 중입니다(%s초 경과). Tailscale 창에서 로그인을 완료하세요."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="전체 디스크 접근 권한이 허용되었습니다. 새 권한을 적용하기 위해 어시스턴트를 다시 시작합니다."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="어시스턴트에 전체 디스크 접근 권한을 허용하는 과정을 안내하기 위해 시스템 설정과 Finder를 여는 중..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="전체 디스크 접근 목록에 토글로 표시되도록 Ostler 어시스턴트를 macOS에 등록하는 중..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="전체 디스크 접근 권한이 아직 대기 중입니다. 권한이 허용될 때까지 Doctor 대시보드에 카드가 계속 표시됩니다."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant에는 이미 전체 디스크 접근 권한이 있습니다. 더 할 일은 없습니다."
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="이 부분은 약 2분 동안 직접 해 주셔야 합니다. 지금 어시스턴트의 전체 디스크 접근 권한을 켜고, 다음 단계에서 Tailscale에 로그인하세요. 그 후에는 Ostler가 알아서 마무리하도록 두셔도 됩니다."
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="이 부분은 약 1분 동안 직접 해 주셔야 합니다. 어시스턴트의 전체 디스크 접근 권한을 켜세요. 그 후에는 Ostler가 알아서 마무리하도록 두셔도 됩니다."
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="\"%s\"은(는) 이미 전체 디스크 접근 목록에 있으므로 켜기만 하면 됩니다. Finder에서 끌어다 놓을 필요가 없습니다."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="Ostler 어시스턴트에 전체 디스크 접근 권한이 있는지 확인하는 중..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="어시스턴트가 메시지 기록을 읽을 수 있습니다. iMessage 채널이 작동합니다."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="Ostler 어시스턴트에게 아직 전체 디스크 접근 권한이 없습니다. 메시지 앱 사용 여부와 관계없이, Mac의 기본 앱을 최신 상태로 유지하려면 이 권한이 필요합니다. 지금 건너뛰면 Doctor 대시보드에서 시스템 설정으로 안내해 드립니다."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="어시스턴트 LaunchAgent가 로드되지 않았습니다. iMessage 전체 디스크 접근 권한 확인을 건너뜁니다."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="Doctor의 Evernote 가져오기 화면에 '서비스를 사용할 수 없음'이 표시됩니다"
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="가져오기 파이프라인이 설치 프로그램에 포함되어 있지 않습니다."
MSG_INFO_INSTALLING_CM042="Ostler RemoteCapture v%s 설치 중 (통화 및 회의 텍스트 변환)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="%s에서 대화 메모리 엔진 설치 중..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  대화 메모리 엔진을 venv에 설치 중..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="Colima + Docker CLI 설치 중..."
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="GNU coreutils 설치 중 (오래 걸리는 단계의 시간 제한용)..."
MSG_INFO_INSTALLING_HOMEBREW="Homebrew 설치 중..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="%s에서 Knowledge 서비스 설치 중..."
MSG_INFO_INSTALLING_OLLAMA="Ollama 설치 중..."
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  데이터 추출 모듈의 종속 항목 설치 중..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  Apple Mail 리더를 전용 venv에 설치 중..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  ostler-knowledge를 venv에 설치 중..."
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  암호화 저장소 종속 항목을 대화 메모리 venv에 설치 중..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="Safari 확장 프로그램을 /Applications에 설치 중"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="보안용 Python 종속 항목 설치 중..."
MSG_INFO_INSTALLING_SQLCIPHER="SQLCipher 설치 중..."
MSG_INFO_INSTALLING_TAILSCALE="Tailscale 설치 중..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="Intel 지원은 로드맵에 없습니다. 필요하시면 요청해 주세요."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="Knowledge 서비스가 설치 프로그램에 포함되어 있어 번들된 소스를 사용합니다."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="Knowledge 서비스가 설치되지 않았습니다: PWG_KNOWLEDGE_REPO가 비어 있습니다."
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="이 Mac은 노트북입니다. Hub로 사용하면 덮개를 연 상태에서 전원에 연결되어 있는 동안 계속 작동합니다."
MSG_INFO_LAPTOP_HUB_SLEEP_COST="덮개를 닫거나 배터리 사용 중에 유휴 상태로 두면 macOS가 잠자기 상태로 전환합니다. 잠자는 동안 어시스턴트는 아무것도 받지 못하며, 그사이 도착한 메시지는 깨어난 뒤에도 가져오지 않습니다."
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="닫힌 디스플레이 모드를 사용하면 덮개를 닫은 상태로 둘 수 있으며, 이 모드에는 전원 연결과 외장 디스플레이, 키보드, 마우스가 필요합니다."
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="Mac mini 또는 Mac Studio Hub는 별도 설정 없이 계속 켜져 있으므로, 둘 중 하나에 설치하셔도 좋습니다."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="나중에 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한에서"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  실행하여 cron 전달 및 imessage-tcc 상태를 확인합니다)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="라이선스: %s는 Apache 2.0입니다. 전문: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="라이선스: %s – 상업적으로 사용하기 전에 원저작자의 약관을 확인하세요."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="로컬 저장소 – Google은 Ostler의 존재를 전혀 알지 못합니다."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="로그: %s/email-ingest.log (및 .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="로그: %s/ostler-assistant.log (및 .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="로그: %s/wiki-recompile.log (및 .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="MacBook Hub: PWG_HUB_POWER_REPO=<url>을 설정한 뒤 다시 실행하세요."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="MacBook Hub 감지됨: 전원 어댑터 연결 시에만 잠자기 안 함으로 설정합니다 (배터리 전환은 hub-power가 처리합니다)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="Mac mini / Studio 배포에는 영향이 없습니다 (항상 전원 연결)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="Mac 쪽 데이터(iMessage, Safari 등)는 위에서 추출되었습니다."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="수동 재시작: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="수동 실행: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="com.ostler.meeting-brief-sender 설치를 건너뜁니다 (v1.0.1 기능, 엔드포인트가 아직 제공되지 않음)."
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="메모리 정리 단계를 건너뜁니다 (이 설치 프로그램에 포함되지 않음). 포함되기 전까지는 자동으로 가중치가 낮아지는 항목이 없습니다."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="나중에 기능 플래그가 켜지면 표시되는 메시지입니다."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="도움이 필요하신가요? support@ostler.ai로 이메일을 보내 주세요. 영업일 기준 2일 이내 답변을 목표로 합니다."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="설정된 채널이 없습니다. 나중에 실행하세요: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="작업 공간 루트에 남아 있던 오래된 기존 config.toml을 삭제했습니다. 실제 어시스턴트 설정은 assistant-config/ 아래에 있습니다."
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="지금은 사용할 수 있는 FDA 소스가 없습니다. 전체 디스크 접근 권한을 허용할 수 있습니다"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="다운로드, 데스크탑 또는 문서 폴더에서 GDPR 내보내기 파일을 찾지 못했습니다."
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="데이터 내보내기 파일을 찾기 위해 %s을(를) 읽을 수 없습니다. macOS에서 해당 폴더에 대한 접근을 차단하고 있습니다."
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="시스템 설정 > 개인정보 보호 및 보안 > 파일 및 폴더(또는 전체 디스크 접근 권한)에서 접근을 허용한 후 다시 실행하거나, 아래에서 내보내기 폴더를 Ostler에 직접 지정하세요."
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="macOS에서 접근을 차단하여 데이터 내보내기 파일을 찾기 위한 폴더를 하나 이상 검색하지 못했습니다. 접근을 허용한 후 다시 실행하거나, 내보내기 폴더를 직접 지정해 주세요."
MSG_INFO_OPENING_CHROME_WEB_STORE="Chrome 웹 스토어 열기: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="ostler-assistant 바이너리가 설치되지 않아 doctor 점검을 건너뜁니다"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: 보류됨 (데몬이 아직"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="이 DMG에 포함된 ostler-assistant 바이너리를 사용합니다 (오프라인 설치 경로)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  ostler-knowledge가 venv에 설치되었습니다."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      Ostler는 설치하기 전에 추가 동의 화면을 표시합니다"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  대화 메모리 엔진의 소스 저장소는 ./install.sh --help에 설명된 환경 변수로 변경할 수 있습니다."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  소스 저장소를 변경하려면: PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  소스 저장소를 변경하려면: PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  소스 저장소를 변경하려면: PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  소스 저장소를 변경하려면: PWG_PIPELINE_REPO=<url> ./install.sh"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="동의 기록과 지역을 저장하는 중..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="3단계 배터리 감시기가 작동 중입니다 (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="주소록을 읽는 중입니다 (라이브러리가 크면 몇 분 걸릴 수 있습니다 – 설치 프로그램을 닫지 마세요)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="정책 변경: ~/.ostler/power.conf를 편집하세요 (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="iMessage 자동화 권한을 확인하는 중 (읽기 전용)..."
MSG_INFO_PULLING_GRAPH_DB_IMAGES="지식 그래프 데이터베이스를 다운로드하는 중입니다 (처음 한 번만). 새로 설치하는 경우 1분 정도 걸릴 수 있습니다..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="nomic-embed-text를 가져오는 중 (274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="%s을(를) 가져오는 중 (%s)... 몇 분 걸릴 수 있습니다."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="격리 xattr를 해제했습니다. Developer-ID 빌드가"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="Safari, iMessage, 메모, 캘린더, 사진, 미리 알림, 메일을 읽는 중..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="내 연락처 카드를 읽어 세부 정보를 미리 채우는 중..."
MSG_INFO_REGION_EU_EEA_SOURCE="지역: EU/EEA (%s, 출처: %s)"
MSG_INFO_REGION_SOURCE="지역: %s (출처: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="지역: 영국 (출처: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="지역: 미국 (출처: %s)"
MSG_INFO_REPO_URL="저장소 URL: %s"
MSG_INFO_REPO_URL_2="저장소 URL: %s"
MSG_INFO_REPO_URL_3="저장소 URL: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="이제 Hub를 잠금 해제할 암호를 선택하세요. Hub UI를 시작할 때마다 이 암호를 입력하게 됩니다."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="복구 암호를 건너뛰었습니다. (더 이상 사용되지 않음: v1.0은 항상 암호가 필요합니다.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="%s에 있는 기존 Doctor 에이전트 설치를 재사용합니다"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="%s에 있는 기존 이메일 수집 설치를 재사용합니다"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="%s에 있는 기존 hub-power 설치를 재사용합니다"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="%s에 있는 기존 브라우저 확장 프로그램 키를 재사용합니다"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="Chrome용 Ostler 확장 프로그램은 이번 릴리스에 포함되어 있지 않습니다."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="이메일 대화: 설정되지 않음. Ostler가 다른 사람의 메시지를 읽는 것에 동의하지 않으셨습니다."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="이메일 대화: 설정되지 않음. 이 Mac에 Apple Mail이 설정되어 있지 않습니다."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="메시지 대화: 설정되지 않음. Ostler가 다른 사람의 메시지를 읽는 것에 동의하지 않으셨습니다."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="메시지 대화: 설정되지 않음. 이 Mac에 메시지 기록이 없습니다."
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  Ostler로 통화를 받아쓰면 이 기능이 자동으로 켜집니다."
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="음성 대화: 아직 설정되지 않음. 읽을 전사본이 없습니다."
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="음성 대화: 꺼짐. Ostler를 설치한 후 Transcripts 폴더가 삭제되었습니다."
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  다시 켜려면 %s을(를) 다시 만드세요. Ostler는 이를 자동으로 다시 만들지 않습니다."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="WhatsApp 대화: 설정되지 않음. Ostler가 다른 사람의 메시지를 읽는 것에 동의하지 않으셨습니다."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="WhatsApp 대화: 설정되지 않음. WhatsApp이 꺼져 있습니다."
MSG_INFO_CHROME_HISTORY_STILL_READ="  Ostler는 여전히 Chrome 방문 기록을 읽으므로 방문한 페이지는 기억됩니다. 탐색 중 실시간 캡처는 현재 Safari에서만 지원됩니다."
MSG_INFO_REUSING_EXISTING_JWT_SECRET="%s에 있는 기존 JWT_SECRET을 재사용합니다"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="%s에 있는 기존 PWG 서비스 토큰을 재사용합니다"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="%s에 있는 기존 wiki-recompile 설치를 재사용합니다"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="이 설치 프로그램 빌드에는 Safari 확장 프로그램 번들이 없습니다 (건너뜀)"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="수동 단계가 하나 남았습니다. Safari를 열고 Safari > 설정 > 확장 프로그램을 선택한 다음 Ostler를 체크하여 켜세요."
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="GDPR 데이터 내보내기 파일을 검색하는 중..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="PWG_DOCTOR_REPO=<url>을 설정한 후 다시 실행하여 설치하세요."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="PWG_HUB_POWER_REPO=<HR015 url>을 설정한 후 다시 실행하여 설치하세요."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="대화 모델을 건너뛰었습니다. 나중에 받기: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="Colima(경량 Docker 런타임)를 시작하는 중..."
MSG_INFO_STARTING_DOCKER_DESKTOP="Docker Desktop을 시작하는 중..."
MSG_INFO_STARTING_OLLAMA="Ollama를 시작하는 중..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="이전 버전에서 남은 오래된 Colima 시작 항목을 제거하는 중..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="이전 Ollama formula(llama-server 없음)를 제거하고 Ollama 앱으로 전환하는 중..."
MSG_INFO_VERIFYING_EMBEDDINGS="임베딩 엔진이 벡터를 반환하는지 확인하는 중..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="Ollama를 자동으로 시작할 수 없습니다. 다음 명령으로 로드하세요: launchctl bootstrap gui/\$(id -u) %s – 그런 다음 설치 프로그램을 다시 실행하세요."
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="Ollama가 백그라운드 서비스로 시작되지 않았습니다. 이번 실행에서는 직접 시작하는 중..."
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  시작 중입니다. 처음 시작한 후 \`ostler-assistant doctor\`를 실행하세요"
MSG_INFO_SYMLINKING="  %s -> %s 심볼릭 링크 생성 중"
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(시스템 설정 > 인터넷 계정). Ostler는 메일의"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(Ostler의 나머지 기능은 Doctor 대시보드 없이도 실행됩니다.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="현재는 정상적인 상태입니다. GDPR 가져오기는 향후 업데이트에서 제공될 예정입니다."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="보통 15분에서 45분 정도 걸리며, 기록이 많거나 Mac이 느리면 더 오래 걸릴 수 있습니다. 이는 정상입니다. 멈춘 것이 아니라 작업 중이니 그대로 두셔도 됩니다..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="macOS 데이터베이스를 직접 읽으므로 내보내기가 필요 없습니다."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="팁: Gmail을 포함하려면 먼저 Mac의 메일에 추가하세요"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="접근 권한이 생긴 후 나중에 설치하려면:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="%s의 iCloud 동기화를 시작하는 중입니다(알림 없음, 첫 실행 시에만)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (UK GDPR 제9조 - 특수 범주 데이터에 필요합니다)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="기존 파이프라인을 업데이트하는 중..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="사용자용 트리가 이미 안내되었습니다(sentinel 있음). 건너뜁니다"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="로컬 웹 검색 엔진을 다운로드하는 중입니다(약 3.5 GB). 처음 설치할 때 가장 오래 걸리는 단계로, 최대 1시간까지 걸릴 수 있습니다. 진행률 표시줄이 없으므로 한동안 아무 변화가 없어도 정상이며, 설치가 멈춘 것이 아닙니다."
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane이 응답하지 않습니다(선택 사항, Phase 3.8b 경고 참조)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="언제든지 다음 명령으로 볼 수 있습니다: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="음성 인식은 꺼진 상태로 유지됩니다. 나중에 설정에서 켤 수 있습니다."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="Tailscale에 로그인하기를 기다리는 중입니다(최대 3분)..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="Tailscale 원격 접근이 설정되지 않았습니다. iPhone의 Ostler 앱은 집 Wi-Fi에서 작동하며, 원격 접근은 나중에 설정에서 설정할 수 있습니다."
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="이 Mac은 이미 Tailscale 네트워크에 연결되어 있어 따로 설정할 것이 없습니다. 기존 연결을 유지합니다."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="원격 접근: 지난번에 건너뛰기로 선택하신 응답을 유지합니다. iOS 앱은 집 Wi-Fi에서 작동하며, 원격 접근은 나중에 설정에서 설정할 수 있습니다."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="원격 접근: 지난번에 설정하기로 선택하신 응답을 유지합니다."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="WhatsApp 커넥터를 꺼 둔 상태입니다. 나중에 설정에서 켤 수 있습니다."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="WhatsApp keepalive가 08:50 + 17:50에 예약되었습니다(label com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="첫날 위키 따라잡기를 건너뜁니다. wiki-recompile tick이 설치되어 있지 않습니다. 매일 위키 재구성이 설치되어 있다면 계속 실행됩니다."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="wiki-recompile 스크립트가 설치 프로그램에 포함되어 있지 않습니다."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="위키가 자동으로 업데이트되지 않습니다. 첫 컴파일을 수동으로 다시 실행할 수 있습니다:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="posture 마커를 기록했습니다: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="내보낸 파일은 안전합니다. 나중에 다음 명령으로 가져오세요: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="Mac 데이터(iMessage, Safari 등)는 위에서 이미 추출되었습니다."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="나중에 추가하면 Safari, iMessage 등에서 바로 온보딩할 수 있습니다."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="AI 모델: %s (%s) – RAM %s GB에 맞게 선택됨"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="적합"
MSG_MODELFIT_PILL_SLOW="느릴 수 있음"
MSG_MODELFIT_PILL_NOFIT="맞지 않음"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="어시스턴트 모델을 Mac에 맞추는 중(%s, RAM %s GB, 어시스턴트 컨텍스트 %s 토큰):"
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- 추천"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="AI 모델: %s (%s) – 어시스턴트에 필요한 컨텍스트 윈도우에서 RAM %s GB에 가장 적합"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="모든 소스가 선택되었습니다(얼굴 인식은 여전히 꺼짐)"
MSG_OK_ALREADY_AVAILABLE="%s은(는) 이미 사용할 수 있습니다"
MSG_OK_APPLE_SILICON_DETECTED="Apple 실리콘이 감지되었습니다"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="iCloud 동기화를 시작하기 위해 앱을 실행했습니다"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="앱 데이터베이스가 이미 있습니다(사전 실행 건너뜀)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="어시스턴트 설정을 %s에 저장했습니다(모드 0600)"
MSG_OK_BACKED_UP_CONTACTS="연락처 %s개를 %s에 백업했습니다"
MSG_OK_CM042_INSTALLED="Ostler RemoteCapture v%s을(를) %s에 설치했습니다"
MSG_OK_CM042_LAUNCHAGENT_LOADED="Ostler RemoteCapture LaunchAgent를 불러왔습니다(레이블 %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="Colima 및 Docker CLI를 설치했습니다"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="컨테이너 런타임 감독 도구를 설치했습니다(5분마다 확인하며 런타임이 중지되면 다시 시작합니다)"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="컨테이너 런타임 감독 도구를 예약하지 못했습니다. Ostler는 계속 설치되지만, 나중에 런타임이 중지되면 자동으로 복구되지 않습니다. 설치 프로그램을 다시 실행하기 전까지 위키가 중단된 상태로 유지됩니다."
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="이 설치 프로그램에 컨테이너 런타임 감독 도구 파일이 없어 예약하지 않았습니다. Ostler는 계속 설치되지만, 런타임 자동 복구는 활성화되지 않습니다."
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="Ostler Doctor 대시보드를 시작하지 못해 http://localhost:8089에서 응답하지 않습니다. 여기에서 데이터를 읽는 앱의 페이지(사람, 타임라인, Governor, 채널 상태)는 대시보드가 실행될 때까지 사용할 수 없다고 표시됩니다. 설치 프로그램을 다시 실행해 다시 시도하세요."
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="절전 방지 도우미를 예약하지 못했습니다. Ostler는 계속 작동하지만, 긴 백그라운드 작업 중에 이 Mac이 잠자기 상태가 될 수 있으며, 작업은 밤새 끝나지 않고 깨어난 뒤에 이어서 진행됩니다."
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="백그라운드 보충 도우미를 예약하지 못해 새 메시지, 메일, 캘린더 항목을 자동으로 가져오지 않습니다. 설치 프로그램을 다시 실행해 복원하세요."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="%s이(가) 설정되지 않았습니다. 이를 결정하는 질문에 대한 답변 기록이 Ostler에 없어서 임의로 가정하지 않았습니다."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  Ostler를 다시 실행하고 질문에 다시 답하도록 선택하면 켤 수 있습니다. (동의 기록: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="데일리 브리프를 예약하지 못해 아침 요약을 받을 수 없습니다. 다른 기능은 모두 정상 작동합니다. 설치 프로그램을 다시 실행해 복원하세요."
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="메모리 정리 작업을 예약하지 못해 오래되었거나 대체된 정보의 가중치가 자동으로 낮아지지 않습니다. 다른 기능은 모두 정상 작동합니다. 설치 프로그램을 다시 실행해 복원하세요."
MSG_WARN_EXPORT_SCAN_NOT_LOADED="다운로드 감시 기능을 시작하지 못해 다운로드 폴더에 넣은 파일을 자동으로 가져오지 않습니다. 이미 가져온 항목에는 영향이 없으며, 앱 안에서 파일을 직접 추가할 수 있습니다. 설치 프로그램을 다시 실행해 복원하세요."
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="기기 등록 재시도 도우미를 예약하지 못했습니다. 설정 중에 iPhone이 등록되었다면 달라지는 것은 없습니다. 등록되지 않았다면 자동으로 완료되지 않으므로 앱에서 다시 페어링해야 합니다."
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="컨테이너 런타임 응답 중"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="이전 버전이 남긴 오래된 Colima 시작 항목을 제거했습니다"
MSG_OK_CONFIG_SAVED_ENV="설정을 %s/.env에 저장했습니다"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="동의 기록과 지역 정보를 ~/.ostler/posture/에 저장했습니다"
MSG_OK_AT_REST_EXCLUDED="Spotlight와 Time Machine에서 제외됨(확인 완료): %s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s은(는) Time Machine 또는 Spotlight에서 제외되지 않았습니다: %s. Ostler의 비밀 정보를 포함한 내용이 백업 디스크에 복사될 수 있습니다. 문제가 해결될 때까지 Doctor에 계속 표시됩니다."
MSG_INFO_AT_REST_FOLDER_ABSENT="%s이(가) 아직 없으므로 백업에서 제외할 항목이 없습니다."
MSG_WARN_DB_KEY_NOT_EXCLUDED="데이터베이스 키 파일 %s이(가) Time Machine에서 제외되지 않아 백업 디스크에 복사될 수 있습니다."
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="백그라운드 보강 선택을 ~/.ostler/posture/에 저장하지 못했습니다. 선택 사항은 이 설치에 계속 적용되며, 지원 보고서에만 표시되지 않습니다."
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="데이터베이스가 암호화되었습니다. Hub 서비스는 홈 폴더의 보호된 파일에서 키를 읽으므로 묻지 않고 시작됩니다."
MSG_OK_DB_KEY_DELIVERED="데이터베이스 키를 Hub 서비스에 전달했습니다(%s, 나만 읽을 수 있음)."
MSG_WARN_DB_KEY_NOT_DELIVERED="데이터베이스 키를 Hub 서비스에 전달하지 못했습니다. 문제가 해결될 때까지 데이터베이스가 암호화되지 않은 상태로 열립니다."
MSG_INFO_DB_KEY_RECOVER_HINT="다음을 실행해 키를 복구하고 전달하세요: %s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="이전 설치에서 남은 데이터베이스를 암호화하는 중"
MSG_WARN_DB_MIGRATION_FAILED="기존 데이터베이스 일부를 암호화하지 못했습니다. 디스크에서 계속 읽을 수 있는 상태입니다."
MSG_WARN_DB_KEY_MISSING_ON_RERUN="이 설치에는 데이터베이스 키 파일이 없어 Hub 서비스가 데이터베이스를 암호화하지 않은 상태로 열고 있습니다."
MSG_WARN_DB_PLAINTEXT_COUNT="이 Mac의 데이터베이스 %s개를 지금 디스크에서 읽을 수 있습니다."
MSG_INFO_DB_MIGRATE_HINT="그런 다음 이미 있는 데이터베이스를 암호화하세요: %s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="보류된 기기 등록 재시도를 설치했습니다(대기열이 비워질 때까지 매시간 실행)"
MSG_OK_DOCKER_RUNNING="Docker 실행 중"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker 실행 중(%s초 소요)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="%s에서 Doctor 에이전트를 복제했습니다"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="Doctor 에이전트 파일이 설치 프로그램에 포함되었습니다"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="Doctor 종속 항목을 설치했습니다"
MSG_OK_EMAIL_CHANNEL_FOLDER="이메일 채널: %s(폴더: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="이메일 수집 LaunchAgent를 불러왔습니다(레이블 com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="이메일 수집 스크립트가 설치 프로그램에 포함되었습니다"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="%s에서 이메일 수집 스크립트를 복제했습니다"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="WhatsApp 대화 기억 설정 중"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  WhatsApp 대화 리더를 설치했습니다."
MSG_WARN_WHATSAPP_SOURCE_FAILED="WhatsApp 대화 리더 설치에 실패하여 WhatsApp 대화 피드가 실행되지 않습니다. 위의 출력을 확인하세요."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="WhatsApp 대화 리더 소스를 찾을 수 없어 WhatsApp 대화 피드를 건너뜁니다."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="이 설치 프로그램에서 WhatsApp 대화 피드 패키지를 찾을 수 없어 건너뜁니다. WhatsApp 메시지 기록(누구와 언제 메시지를 주고받았는지)에는 영향이 없습니다."
MSG_OK_WHATSAPP_BUNDLE_LOADED="WhatsApp 대화 피드 LaunchAgent를 불러왔습니다(레이블 com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  첫 실행에서는 Mac에 동기화된 최근 WhatsApp 대화(약 1년치)를 읽습니다. 데이터는 Mac에만 남습니다."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  로그: %s/whatsapp-bundle.log 및 whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="WhatsApp 대화 피드 LaunchAgent 설치에 실패했습니다. 위의 출력을 확인하세요. 나머지 설치에는 영향이 없습니다."
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  아직 시작되지 않았습니다. 이 에이전트가 실행할 어시스턴트 프로그램이 디스크에 없습니다. 확인한 위치: %s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="이메일 대화 기억 설정 중"
MSG_OK_EMAIL_SOURCE_INSTALLED="  이메일 대화 리더를 설치했습니다."
MSG_WARN_EMAIL_SOURCE_FAILED="이메일 대화 리더 설치에 실패하여 이메일 대화 피드가 실행되지 않습니다. 위의 출력을 확인하세요."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="이메일 대화 리더 소스를 찾을 수 없어 이메일 대화 피드를 건너뜁니다."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="이 설치 프로그램에서 이메일 대화 피드 패키지를 찾을 수 없어 건너뜁니다. 매시간 실행되는 이메일 수집에는 영향이 없습니다."
MSG_OK_EMAIL_BUNDLE_LOADED="이메일 대화 피드 LaunchAgent를 불러왔습니다(레이블 com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  Apple Mail의 로컬 저장소에서 최근 이메일 스레드를 읽습니다. 모든 데이터는 Mac에만 남습니다."
MSG_INFO_EMAIL_BUNDLE_LOGS="  로그: %s/email-bundle.log 및 email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="이메일 대화 피드 LaunchAgent 설치에 실패했습니다. 위의 출력을 확인하세요. 나머지 설치에는 영향이 없습니다."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="회의 및 음성 대화 기억 설정 중"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  회의 및 음성 대화 리더를 설치했습니다."
MSG_WARN_SPOKEN_SOURCE_FAILED="회의 및 음성 대화 리더 설치에 실패하여 피드가 실행되지 않습니다. 위의 출력을 확인하세요."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="회의 및 음성 대화 리더 소스를 찾을 수 없어 피드를 건너뜁니다."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="이 설치 프로그램에서 회의 및 음성 대화 피드 패키지를 찾을 수 없어 건너뜁니다."
MSG_OK_SPOKEN_BUNDLE_LOADED="회의 및 음성 대화 피드 LaunchAgent를 불러왔습니다(레이블 com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  내 회의와 음성 메모를 텍스트로 변환해 검색 가능한 대화로 만듭니다. 모든 데이터는 Mac에만 남습니다."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  로그: %s/spoken-bundle.log 및 spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="회의 및 음성 대화 피드 LaunchAgent 설치에 실패했습니다. 위의 출력을 확인하세요. 나머지 설치에는 영향이 없습니다."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="iMessage 대화 기억 설정 중"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  iMessage 대화 리더를 설치했습니다."
MSG_WARN_IMESSAGE_SOURCE_FAILED="iMessage 대화 리더 설치에 실패하여 iMessage 대화 피드가 실행되지 않습니다. 위의 출력을 확인하세요."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="iMessage 대화 리더 소스를 찾을 수 없습니다. iMessage 대화 피드를 건너뜁니다."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="이 설치 프로그램에서 iMessage 대화 피드 패키지를 찾을 수 없습니다. 건너뜁니다."
MSG_OK_IMESSAGE_BUNDLE_LOADED="iMessage 대화 피드 LaunchAgent 로드됨 (레이블 com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  이 Mac의 메시지 저장소에서 최근 iMessage 대화를 읽습니다. 모든 데이터는 사용자의 Mac에만 보관됩니다."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  로그: %s/imessage-bundle.log 및 imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="iMessage 대화 피드 LaunchAgent 설치에 실패했습니다. 위의 출력을 확인하세요. 나머지 설치에는 영향이 없습니다."
MSG_OK_EMBEDDING_MODEL_READY="임베딩 모델 준비 완료"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="연락처 %s개를 내보냈습니다 (자동으로 가져옵니다)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="내보내기 감시 기능 설치됨 (4시간마다 다운로드 폴더를 검사합니다)"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  내보내기 감시 기능을 아직 시작하지 못했습니다. 실행할 어시스턴트 프로그램이 디스크에 없습니다. 확인한 위치: %s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="회의 전 브리핑 발송 기능 설치됨 (활동 시간대에 10분마다 확인합니다)"
MSG_OK_MEMORY_HYGIENE_INSTALLED="메모리 정리 작업 예약됨 (오래된 정보가 최신 정보를 밀어내지 않도록 매일 실행됩니다)"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="Ostler가 계속 작동하도록 전원에 연결된 동안 Mac이 잠자기 상태가 되지 않습니다 (배터리 사용 중에는 잠자기 상태로 전환됩니다)"
MSG_OK_EXTRACTED="%s에 추출했습니다"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="소스 %s개에서 추출했습니다. 데이터는 %s/imports/fda/에 저장되었습니다"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="FDA 재실행이 %s분마다 예약되었습니다 (느린 iCloud 동기화를 반영하고 캘린더 보충 작업을 마무리합니다)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro가 30일 동안 활성화됩니다. 체험 기간 이후에도 이용하려면 iPhone의 Ostler app에서 구독하세요."
MSG_OK_FOUND="찾음: %s"
MSG_OK_FOUND_EXPORTS="%s에서 내보내기 파일을 찾았습니다"
MSG_OK_FOUND_GDPR_EXPORT_S="GDPR 내보내기 파일 %s개를 찾았습니다:"
MSG_OK_GB_FREE_DISK_SPACE="여유 디스크 공간 %s GB"
MSG_OK_GB_RAM_DETECTED="RAM %s GB 감지됨"
MSG_OK_GDPR_IMPORT_COMPLETE="GDPR 가져오기 완료"
MSG_OK_GIT_AVAILABLE="Git 사용 가능"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="명령줄 도구 설치가 시작되었습니다 (아래 질문에 답하는 동안 백그라운드에서 다운로드됩니다)."
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="GNU coreutils 설치됨 (오래 걸리는 단계에 시간 제한이 적용됩니다)"
MSG_OK_HOMEBREW_INSTALLED="Homebrew 설치됨"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="Hub 전원 LaunchAgent 로드됨 (레이블 com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="Hub 전원 스크립트가 설치 프로그램에 포함되어 있습니다"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="%s에서 Hub 전원 스크립트를 복제했습니다"
MSG_OK_ICAL_SERVER_INSTALLED="어시스턴트 API 설치됨 (루프백 127.0.0.1:8090, Doctor가 프록시)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="iMessage 브리지 LaunchAgent 로드됨 (레이블 com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="iMessage 브리지 스크립트가 설치 프로그램에 포함되어 있습니다"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="%s에서 iMessage 브리지 스크립트를 복제했습니다"
MSG_OK_IMESSAGE_CHANNEL="iMessage 채널: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="가져오기 파이프라인이 설치 프로그램에 포함되어 있습니다"
MSG_OK_IMPORT_PIPELINE_READY="가져오기 파이프라인 준비 완료"
MSG_OK_CM048_PIPELINE_READY="대화 메모리 엔진 준비 완료."
MSG_INFO_CM048_SETTINGS_WRITTEN="  대화 모델을 %s(으)로 설정했습니다 (사용자의 메모리 %s GB에 맞춤)"
MSG_INFO_CM048_SETTINGS_KEPT="  기존 대화 설정을 유지합니다(%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="지식 서비스 준비 완료: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="라이선스 문서가 %s/에 설치되었습니다(출처: %s)"
MSG_OK_MACOS_DETECTED="macOS %s 감지됨"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="메일 계정을 추가할 수 있도록 시스템 설정 > 인터넷 계정을 엽니다. 첫 번째 계정에 로그인한 후 이 창으로 돌아오세요."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="인터넷 계정 단계를 건너뜁니다. 나중에 시스템 설정에서 메일 계정을 추가할 수 있으며, 24시간 이내에 메일이 도착하지 않으면 Doctor가 후속 안내를 표시합니다."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="Apple Mail의 전체 기록을 가져오는 중입니다. 메일함이 크면 시간이 조금 더 걸릴 수 있습니다."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="기본 5년 메일 범위를 유지합니다. 나중에 Doctor에서 더 가져올 수 있습니다."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text를 이미 사용할 수 있습니다"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="Ollama 설치됨"
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="Ollama 설치됨(CLI만 해당 – 재부팅 후 수동으로 시작해야 할 수 있음)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="Ollama 설치됨(데스크탑 앱)"
MSG_OK_OLLAMA_RUNNING="Ollama 실행 중"
MSG_OK_EMBEDDINGS_VERIFIED="임베딩 엔진 확인됨(768차원 벡터)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: 자체 시작 점검에서 오류 0건"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="Ostler 어시스턴트 LaunchAgent 로드됨(레이블 com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="ostler-assistant v%s을(를) %s에 준비함(서명됨)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="ostler-assistant v%s을(를) %s에 준비함(서명되지 않음)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor가 http://localhost:8089/doctor 에서 실행 중입니다"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  데이터 추출 모듈이 올바르게 로드되었습니다."
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  Apple Mail 리더가 설치되었습니다."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  이메일 수집 엔진이 설치되었습니다."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="ostler-import, ostler-fda, ostler-uninstall 명령이 설치되었습니다"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="암호를 확인했습니다. 3단계에서 데이터베이스를 암호화하는 데 사용됩니다."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="복구 암호가 설정되었습니다."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="암호 안내를 확인했습니다."
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="Disney+ 내보내기 비밀번호를 확인했습니다. 가져오기 중에 사용됩니다."
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="Disney+ 내보내기를 건너뜁니다. 비밀번호가 입력되지 않았습니다. 다른 항목에는 영향이 없습니다."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="전원: AC(데스크탑 Mac, 배터리 없음)"
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="전원: AC(좋음 – 설치에는 45분에서 몇 시간이 걸릴 수 있으므로 전원에 연결되어 있으면 안정적으로 진행됩니다)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="이전 설치가 감지되었습니다. 설정을 불러오는 중..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="번들 Python %s 사용 중(시스템 설치 불필요)"
MSG_OK_PYTHON_INSTALLED="Python %s 설치됨"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="페어링 서비스 정상"
MSG_WARN_GATEWAY_NOT_RESPONDING="페어링 서비스가 응답하지 않습니다(127.0.0.1:8000) - 휴대폰/브라우저 페어링과 채팅 어시스턴트가 아직 작동하지 않을 수 있습니다"
MSG_OK_DOCTOR_HEALTHY="Doctor 정상"
MSG_WARN_DOCTOR_NOT_RESPONDING="Doctor가 응답하지 않습니다(127.0.0.1:8089) - 앱과 브라우저가 이를 통해 Ostler에 연결하므로 데이터와 페어링을 사용하지 못할 수 있습니다"
MSG_OK_WIKI_HEALTHY="내 위키 정상"
MSG_OK_ICAL_SERVER_HEALTHY="어시스턴트 API 정상"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="어시스턴트 API가 응답하지 않습니다(127.0.0.1:8090) - 시작될 때까지 사람, 미팅, 타임라인이 비어 있을 수 있습니다"
MSG_OK_READY="%s 준비 완료"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="권장 소스를 선택했습니다"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="복구 키를 키체인에 저장했습니다(암호 앱에서 'Ostler' 검색)"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="Safari 확장 프로그램이 %s에 설치되었습니다"
MSG_OK_SAFARI_EXTENSION_PAIRED="Safari 확장 프로그램이 이 Hub와 페어링되었습니다"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="이전 실행에서 보안이 이미 구성되었습니다."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="보안 모듈을 venv에 설치했습니다"
MSG_OK_SEEDED_FRESH_JWT_SECRET="%s에 새 JWT_SECRET을 생성했습니다"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="%s에 PWG 서비스 토큰을 생성했습니다"
MSG_OK_SEEDED_EXTENSION_TOKEN="%s에 브라우저 확장 프로그램 키를 생성했습니다"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="서비스를 시작했습니다(Qdrant :6333, Oxigraph :7878, Redis :6379)"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  준비된 검색 컬렉션: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="%s 검색 컬렉션을 아직 준비하지 못했습니다. 아래 데이터 가져오기에서 다시 시도하며, 그래도 준비되지 않으면 데이터를 버리지 않고 중단합니다."
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="검색 색인이 아직 제때 준비되지 않았습니다. 아래 데이터 가져오기에서 준비될 때까지 기다리고 컬렉션을 준비하며, 저장소가 여전히 준비되지 않으면 데이터를 버리지 않고 중단합니다."
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="데이터를 가져오지 않았습니다. 검색 저장소를 데이터를 담을 수 있게 준비하지 못했고(누락: %s), 그대로 가져오면 데이터가 조용히 버려졌을 것입니다. 손실된 것은 없습니다. Mac이 유휴 상태일 때 설치 프로그램을 다시 실행하거나, OSTLER_QDRANT_READY_WAIT_S를 설정해 더 오래 기다리세요."
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="데이터 가져오기에서 %s개의 레코드를 처리했지만 하나도 저장되지 않았습니다. 검색 저장소가 모든 레코드를 거부했으며, 그대로 두면 비어 있는 지식 그래프가 완료된 것처럼 표시됩니다. 그런 결과를 보여드리지 않도록 중단합니다. Mac이 유휴 상태일 때 설치 프로그램을 다시 실행하세요."
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="가져오기 자체의 로그를 읽지 못해 데이터가 실제로 저장되었는지 확인하는 검사를 실행하지 못했습니다. 가져오기가 실패했다는 뜻도, 성공했다는 뜻도 아닙니다."
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="전원 연결 시 잠자기 비활성화, 배터리 잠자기 유지, 네트워크 깨우기 활성화"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="잠자기 비활성화, 네트워크 깨우기 활성화"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale이 이미 설치되어 있습니다"
MSG_OK_TAILSCALE_INSTALLED="Tailscale을 설치했습니다"
MSG_OK_TAILSCALE_ENV_PERSISTED="Tailscale IP를 .env에 저장했습니다 – iPhone의 Ostler 앱이 처음 실행할 때 이를 사용합니다."
MSG_OK_TAILSCALE_IP="Tailscale IP: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="Tailscale 백그라운드 서비스를 시작했습니다(사용자 공간 모드, 시스템 확장 프로그램 없음)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="Tailscale 백그라운드 서비스를 시작하지 못했습니다. 나중에 설정에서 설정 과정을 다시 실행할 수 있습니다."
MSG_INFO_TAILSCALE_SIGN_IN_URL="Tailscale에 로그인하기 위해 브라우저를 여는 중: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="Hub 포트 %s을(를) tailnet에 노출했습니다"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="Hub 포트 %s을(를) tailnet에 노출하지 못했습니다. 외부 네트워크에서의 접속이 제한될 수 있습니다"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="이제 내 기기에서 %s 주소로 위키를 읽을 수 있습니다 – 본인 계정으로 로그인되며, 본인만 접근할 수 있습니다."
MSG_INFO_WIKI_TAILNET_OWNER="위키 접근은 내 Tailscale 계정(%s)으로 제한됩니다. tailnet의 다른 사람은 403을 받습니다."
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="위키는 이 Mac에만 보관됩니다. Ostler를 열고 사이드바에서 위키를 선택하여 읽으세요."
MSG_INFO_WIKI_TAILNET_BANNER="%s  (내 기기에서 Tailscale을 통해 접속. 위의 로그인을 요구하는 유일한 경로입니다.)"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="Ostler 앱에서 확인합니다. Ostler를 열고 사이드바에서 위키를 선택하세요. 페이지가 이미 로그인된 상태로 열립니다."
MSG_INFO_WIKI_INTERNAL_ADDRESS="Ostler는 이 Mac의 http://localhost:8044에서 해당 페이지를 가져옵니다. 이 주소는 내부용이며 로그인할 항목이 없습니다."
MSG_INFO_WIKI_SIGN_IN="위키 로그인 ID는 %s이며 비밀번호는 %s입니다. Ostler가 대신 입력하므로 이 Mac에서는 입력할 것이 없습니다. Tailscale을 통해 다른 기기에서 위키를 열 때만 직접 알고 있으면 됩니다."
MSG_INFO_WIKI_SIGN_IN_WITHHELD="위키 로그인 정보는 %s입니다. 비밀번호는 이 로그에 기록되지 않으며, 클립보드와 아래에 표시된 파일에 있습니다. Ostler가 대신 입력해 주므로 이 Mac에서 직접 입력할 필요는 없습니다."
MSG_INFO_WIKI_PORT_LAST_STATUS="위키 포트의 마지막 HTTP 상태: %s (000은 응답이 없다는 뜻이고, 403은 응답했지만 자격 증명을 거부했다는 뜻입니다.)"
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="비밀번호는 %s에도 보관되어 있으므로 클립보드가 유일한 사본은 아닙니다."
MSG_INFO_WIKI_STILL_BUILDING="아직 빌드 중입니다. 페이지 %s개가 이미 디스크에 있으며, 위키 주소의 마지막 응답은 HTTP %s였습니다. 완료되면 Ostler 앱에 자동으로 나타납니다. 따로 하실 일은 없습니다."
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="첫 빌드에서 아직 생성된 페이지가 없습니다(위의 경고 참조). 빌드가 끝나면 위키는 Ostler 앱에서 열리며, 위의 로그인 정보는 그대로 사용하실 수 있습니다."
MSG_INFO_WIKI_READINESS_NOT_MEASURED="이번 실행에서는 위키가 아직 서비스 중인지 확인하지 않았으므로 어느 쪽으로도 단정하지 않습니다. 위키는 어떤 경우에도 Ostler 앱에서 열리며, 위의 로그인 정보는 그대로 사용하실 수 있습니다."
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="이 Mac을 소유한 Tailscale 계정을 확인할 수 없어 위키를 tailnet에 공개하지 않았습니다. 위키는 이 Mac의 Ostler 앱 > 위키에서 계속 사용하실 수 있습니다."
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="위키를 tailnet에 게시할 수 없었습니다. 위키는 이 Mac의 Ostler 앱 > 위키에서 계속 사용하실 수 있습니다."
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="위키 접근 게이트를 다시 불러올 수 없어 위키를 tailnet에 공개하지 않았습니다."
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="%s에서 Tailscale Funnel이 켜져 있습니다. Funnel은 공개 인터넷에 게시합니다. Ostler는 Funnel을 켜지 않으며 위키도 Funnel 트래픽을 거부하므로 Ostler의 어떤 것도 공개되지 않습니다. 다만 의도하지 않으셨다면 이 기기의 Tailscale 관리 콘솔에서 끄세요."
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="서드파티 저작자 표시를 설치했습니다(출처: %s)"
MSG_OK_USER_FACING_TREE_READY="사용자용 폴더 구조가 준비되었습니다"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="대신 'Ostler' 폴더/레이블을 사용합니다."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane 정상 작동 중(로컬 웹 검색)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane이 http://localhost:3000에서 실행 중입니다(로컬 Ollama와 연결됨)"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="WhatsApp 커넥터가 활성화됩니다(동의 기록됨)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="첫날 위키 따라잡기 LaunchAgent를 불러왔습니다(처음 몇 시간 동안 30분마다 위키를 다시 빌드한 후 중지됩니다)"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="중복 연락처를 계속 병합하는 중입니다. 주소록이 크면 몇 분 걸릴 수 있습니다(%ss 경과)"
MSG_INFO_DEDUPE_MERGED="중복 연락처를 병합했습니다"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="이 정도 크기의 주소록은 중복 연락처 병합에 시간이 걸립니다. 설치 후에도 백그라운드에서 계속 진행되며, 끝나면 위키가 자동으로 업데이트됩니다."
MSG_WARN_DEDUPE_INCOMPLETE="전체 그래프 중복 제거 작업이 정상적으로 완료되지 않았습니다(%s 참조). 계속 진행합니다"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="설치 중에 중복 연락처를 모두 병합했습니다. 백그라운드 후속 작업은 필요하지 않습니다"
MSG_OK_DEDUPE_CATCHUP_LOADED="백그라운드 연락처 중복 제거 LaunchAgent를 불러왔습니다(설치 후 중복 병합을 마무리한 다음 중지됩니다)"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="백그라운드 연락처 중복 제거 LaunchAgent를 불러올 수 없었습니다. 중복 항목은 매일 실행되는 유지 관리 작업에서 계속 병합되지만, 정리되기까지 더 오래 걸립니다."
MSG_OK_ENRICH_AGENT_LOADED="백그라운드 보강 LaunchAgent를 불러왔습니다(영화, 장소, 도서, 링크의 세부 정보를 채우며 하루 정도에 걸쳐 나눠서 실행됩니다)"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="백그라운드 보강 LaunchAgent를 불러올 수 없었습니다. 환경설정은 저장되어 검색할 수 있지만, 실행되기 전까지는 감독, 출연진, 장소 같은 추가 참고 정보가 빠져 있습니다."
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="위키 재컴파일 LaunchAgent를 불러왔습니다(레이블 com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="위키 재컴파일 스크립트가 설치 프로그램에 포함되어 있습니다"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="위키 재컴파일 스크립트를 %s에서 복제했습니다"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="프론트 페이지 설정 중(매시간 새로 고침)"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="프론트 페이지 생성기가 설치 프로그램에 포함되어 있습니다"
MSG_OK_EDITOR_FRONTPAGE_LOADED="프론트 페이지 LaunchAgent를 불러왔습니다(레이블 com.creativemachines.ostler.editor-frontpage)"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  첫 새로 고침을 지금 실행합니다. Ostler가 환경설정을 읽어 들이면 대시보드 프론트 페이지가 채워집니다."
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  로그: %s/editor-frontpage.log 및 editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="이 설치 프로그램에서 프론트 페이지 생성기를 찾을 수 없습니다. 대시보드 프론트 페이지는 새로 고쳐지지 않습니다."
MSG_WARN_EDITOR_FRONTPAGE_FAILED="프론트 페이지 LaunchAgent 설치에 실패했습니다. 위의 출력을 확인하세요. 나머지 설치에는 영향이 없습니다."
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="프론트 페이지 따라잡기 설정 중"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="프론트 페이지 따라잡기 LaunchAgent를 불러왔습니다(관심사를 모두 읽어 들일 때까지 5분마다 확인한 후 중지됩니다)"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="프론트 페이지 따라잡기 LaunchAgent를 불러올 수 없었습니다. 프론트 페이지와 Ostler가 파악한 관심사는 대신 다음 매시간 새로 고침 때 채워집니다."
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="프론트 페이지 따라잡기를 건너뜁니다. 프론트 페이지 새로 고침이 설치되어 있지 않아 다시 실행할 대상이 없습니다."
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="위키가 http://localhost:8044에서 실행 중입니다"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="위키를 둘러볼 준비가 되었습니다. Ostler가 백그라운드에서 페이지 요약을 작성하고 있으며, 잠시 후 차례로 채워집니다. 지금 바로 위키를 사용할 수 있습니다."
MSG_OK_YOUR_ASSISTANT_CALLED="어시스턴트 이름은 %s입니다"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="설치 프로그램에 포함된 개인 컨텍스트 요약 스크립트"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="개인 컨텍스트 요약 LaunchAgent를 불러왔습니다(레이블 com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  로그: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="%s에 있는 기존 context-refresh 설치를 재사용합니다"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="개인 컨텍스트 요약 스크립트가 포함되어 있지 않습니다. 어시스턴트는 실시간 조회만 사용합니다(상시 컨텍스트 요약 없음)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="개인 컨텍스트 요약 LaunchAgent를 불러오지 못했습니다. context-refresh.err를 확인하세요. 어시스턴트는 계속 실시간 조회로 답변합니다"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="복제한 Knowledge 서비스 소스에 패키징 구성이 없어 환경을 설정하지 못했습니다."
MSG_WARN_BUNDLE="  번들: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="Ostler RemoteCapture v%s는 Apple Silicon에서만 사용할 수 있습니다(감지됨: %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="Ostler RemoteCapture v%s를 %s에서 다운로드하지 못했습니다"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="흔한 원인: 릴리스 태그가 아직 게시되지 않았거나, 네트워크가 오프라인이거나, 상위 공증이 아직 진행 중일 수 있습니다. 릴리스가 공개된 후 설치 프로그램을 다시 실행하세요."
MSG_WARN_CM042_EXTRACT_FAILED="Ostler RemoteCapture tarball을 추출하지 못했습니다. LaunchAgent를 건너뜁니다."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="Ostler RemoteCapture LaunchAgent를 불러오지 못했습니다. 위의 출력과 ~/Library/LaunchAgents/를 확인하세요."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  대화 보강 기능을 사용할 수 없습니다. 나머지 Ostler는 정상적으로 설치됩니다. 대화 메모리 엔진을 연결하려면 --allow-plaintext 없이 다시 실행하세요."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="대화 메모리 엔진 설치에 실패했습니다(clone)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  확인한 경로: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  설치 프로그램 .app이 다음 항목 없이 빌드되었을 수 있습니다:"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  Contents/Resources/에 포함되어야 하는"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  vendored cm048_pipeline 패키지입니다. 설치 프로그램을 다시 다운로드하거나"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  개발/CI 설치라면 --allow-plaintext로 다시 실행하세요."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="대화 메모리 엔진을 찾을 수 없습니다. 이 엔진 없이는 대화 보강을 실행할 수 없습니다."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="대화 메모리 엔진 설정을 건너뛰었습니다(--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="대화 메모리 엔진 소스는 확인했지만 pyproject.toml이 없어 venv 설정을 건너뛰었습니다."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="Colima를 시작하지 못했습니다. 대체 수단으로 Docker Desktop을 시도합니다..."
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="GNU coreutils를 설치하지 못했습니다. 긴 단계는 시간 제한 없이 실행됩니다(작동 중임을 알리는 진행 표시는 계속 나타납니다)."
MSG_WARN_COLIMA_START_RETRY="Colima가 정상적으로 시작되지 않았습니다(Docker 소켓이 준비되지 않음). %s초 후 다시 시도합니다..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="흔한 원인: 태그 v%s가 아직 게시되지 않았거나, 네트워크가 오프라인이거나,"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  consent_cli stderr(처음 400자):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  %s에 콘솔 스크립트가 생성되지 않았습니다. pyproject.toml에 [project.scripts] 항목이 없을 수 있습니다."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="--allow-plaintext가 전달되었으므로 계속합니다."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="설치를 계속합니다. 위 오류를 진단한 후 \`ostler-fda\`를 다시 실행하세요."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="연락처 카드 자동 입력 없이 계속합니다. 대신 Ostler가 직접 물어봅니다."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  iMessage로 보낸 대화는 다음이 될 때까지 조용히 실패합니다:"
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="잠자기 설정을 변경하지 못했습니다. 시스템 설정 > 에너지에서 '전원 어댑터 연결 시 자동 잠자기 방지'를 켜세요."
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="절전 설정을 변경할 수 없습니다. 시스템 설정 > 에너지에서 '자동 잠자기 방지'를 켜 주세요."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="ostler-assistant v%s을(를) %s에서 다운로드할 수 없습니다"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="Takeout zip에서 Gmail mbox를 추출할 수 없습니다. 건너뜁니다."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="ostler-assistant tarball을 추출할 수 없습니다. LaunchAgent를 건너뜁니다."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="Tailscale CLI를 찾을 수 없습니다. 나중에 직접 설정할 수 있습니다."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="legal/ 동의 문구 패키지를 설치할 수 없습니다. 계속 진행합니다."
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="LICENSES/ 디렉토리를 설치할 수 없습니다(치명적이지 않음)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="Hub venv에 ostler_security를 설치할 수 없습니다."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="THIRD_PARTY_NOTICES.md를 설치할 수 없습니다(치명적이지 않음)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="Doctor 에이전트를 가져올 수 없습니다(번들 및 클론 모두 실패)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="Ostler Doctor 파일을 찾을 수 없습니다. iOS 페어링 과정에 필요합니다(Ostler.app이 :8089/pair-ios를 iframe으로 표시)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  확인한 위치: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  이는 보통 설치 프로그램 .app을 빌드할 때"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  벤더링된 doctor/agent/ 소스가"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/에 포함되지 않았다는 뜻입니다. 설치 프로그램을 다시 다운로드하거나"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  개발/CI 설치라면 --allow-plaintext로 다시 실행하세요."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="Doctor 설치가 중단되었습니다. iOS 페어링 과정에 필요합니다. 설치 프로그램을 다시 다운로드하거나 개발/CI 설치라면 --allow-plaintext를 사용하세요."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="이메일 가져오기 스크립트를 가져올 수 없습니다(번들 및 클론 모두 실패)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="hub-power 스크립트를 가져올 수 없습니다(번들 및 클론 모두 실패)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="wiki-recompile 스크립트를 가져올 수 없습니다(번들 및 클론 모두 실패)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="Chrome 웹 스토어 URL을 자동으로 열 수 없습니다: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="region.json을 저장할 수 없습니다(계속 진행, Doctor에 표시됩니다)"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="복구 키가 전달되었다는 기록을 남기지 못했습니다. 이번 실행의 요약은 여전히 정확하지만, 이후 실행에서 이를 알 수 없어 경고가 다시 표시될 수 있습니다. 실패하더라도 안전한 방향입니다."
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="키체인에 저장할 수 없습니다. 직접 적어 두세요."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="Ollama를 자동으로 시작할 수 없습니다."
MSG_FAIL_OLLAMA_PORT_IN_USE="다른 프로그램이 이미 포트 11434를 사용하고 있습니다. Ostler는 로컬 AI를 위해 이 포트가 필요합니다. Ostler가 자체 사본을 시작할 수 없어, 설치를 반쯤 끝내지 않고 여기서 중단했습니다.

  포트를 사용 중인 항목: %s
  정확한 오류 위치: %s

이미 설치되어 있던 Ollama이거나 이전 Ostler 설치에서 계속 실행 중인 사본일 수 있습니다. 해당 프로그램을 종료하거나 이 Mac을 재시동한 후 설치 프로그램을 다시 실행하세요."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="파이프라인을 업데이트할 수 없습니다(오프라인인가요?)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="pipeline_signals.json을 쓸 수 없습니다. 다음 설치 또는 틱까지 Doctor의 빈 Mail 진단은 안전한 기본값을 사용합니다."
MSG_WARN_CURL_SAID="Curl 응답:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="디렉토리를 찾을 수 없습니다: %s – 가져오기를 건너뜁니다."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="Docker가 %s초 내에 시작되지 않았습니다."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker가 설치되어 있지만 실행 중이 아닙니다. 시작해야 합니다."
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="이 Mac에 Docker 명령은 있지만 그 뒤에서 실행 중인 것이 없습니다. macOS에서 Docker 명령은 클라이언트일 뿐이며, 실제로 실행하려면 Colima나 Docker Desktop 같은 엔진이 필요합니다. 설치 프로그램이 하나를 설정합니다."
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="컨테이너 런타임 진단 - docker 클라이언트: %s | colima: %s | Docker Desktop: %s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="위키 컨테이너는 시작되었지만 60초 내에 http://localhost:8044에서 응답이 없었습니다. 위키가 실행 중이 아닌 것으로 간주하세요. 시작 명령의 종료 코드는 페이지가 로드된다는 증거가 아닙니다."
MSG_WARN_WIKI_NOT_RESPONDING="위키가 응답하지 않습니다(127.0.0.1:8044). 위키는 컨테이너에서 실행되므로 보통 컨테이너 런타임이 중지되었다는 뜻입니다. http://localhost:8089/doctor에서 Ostler Doctor를 열어 원인을 확인하세요."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama 설치 도중에 준비 상태 점검이 멈춥니다."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  초기 표시 (채널이 아직 연결 중이며 Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="이메일 수집 LaunchAgent 설치에 실패했습니다. 위의 출력을 확인하세요."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="iMessage 브리지 LaunchAgent 설치에 실패했습니다. 설치 프로그램을 다시 실행하거나 INSTALL_SNIPPET.sh를 직접 실행하기 전까지 어시스턴트 사용자의 iMessage 답장이 작동하지 않습니다."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="iMessage 브리지 스크립트가 포함되지 않았고 --allow-plaintext가 지정되어 LaunchAgent 설치를 건너뜁니다. 어시스턴트 사용자의 iMessage 답장이 작동하지 않습니다."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="암호화가 작동하지 않습니다."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="암호화가 작동하지 않으며,"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="고정된 PWG_KNOWLEDGE_REPO 태그에 포함되어 있는지 확인하세요."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  메시지 앱의 이벤트 권한)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="FDA 추출기가 0이 아닌 값(%s)으로 종료되었습니다. 출력의 마지막 20줄:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="FDA 추출 모듈이 이 설치 프로그램에 포함되어 있지 않습니다."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="예상 위치: Contents/Resources/ostler_fda/ (.app 내부)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="가장 가능성이 높은 원인: 빌드 회귀로 vendor 사본이 누락되었습니다. ostler.ai/install에서 .app을 다시 다운로드하세요."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="FDA 추출 모듈이 포함되어 있지 않습니다. --allow-plaintext가 지정되어 계속 진행하며, 즉시 데이터 추출은 건너뜁니다."
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="데이터 추출 모듈은 디스크에 있지만 종속 항목이 설치되지 않아 불러올 수 없습니다:"
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="--allow-plaintext가 지정되어 계속 진행하지만, 예약된 데이터 새로고침은 실행할 때마다 실패합니다."
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault가 켜져 있지 않습니다."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="지금은 첫 달 무료를 활성화할 수 없습니다. 설치는 계속됩니다. 페어링한 후 iPhone의 Ostler 앱을 열어 해결하세요."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="터미널에 전체 디스크 접근 권한이 부여되지 않았습니다."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="RAM %s GB가 감지되었습니다. 컴팩트 어시스턴트(gemma4:e2b)를 사용하게 됩니다. 안정적이고 정확하며, 짧은 질문에는 1초 이내로 답하고, 도구 호출을 지원하며, 모를 때는 솔직하게 '모르겠습니다'라고 말합니다. 긴 질문에 더 풍부한 답변을 원하면 24 GB 이상에서 표준 어시스턴트(qwen3.5:9b)를 사용할 수 있습니다. 나중에 다시 설치하여 Mac을 바꿀 수 있습니다."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="GDPR 가져오기에 오류가 있었습니다. 다음 명령으로 다시 실행할 수 있습니다:"
MSG_WARN_GRAPH_DB_PULL_RETRY="데이터베이스 다운로드가 완료되지 않았습니다(%s/%s번째 시도). %s초 후 다시 시도합니다..."
MSG_WARN_GRAPH_DB_UP_RETRY="지식 그래프 데이터베이스가 시작되지 않았습니다(%s/%s번째 시도). 다시 시도합니다..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="GDPR 가져오기는 제품 설치의 일부입니다. 이것이 없으면 소셜 그래프(LinkedIn, Facebook, Instagram, WhatsApp, Twitter, Google 캘린더)를 가져올 수 없습니다."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="가져오기 파이프라인을 다시 설치하기 전까지 이 인스턴스에서는 GDPR 가져오기를 사용할 수 없습니다."
MSG_WARN_GIT_SAID="Git 메시지:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  상태 점검 실패: ostler-knowledge --version이 출력을 생성하지 않았습니다."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  상태 점검 실패: 대화 메모리 엔진을 불러올 수 없습니다(pwg-convo 또는 해당 파이프라인 가져오기가 정상적으로 반환되지 않았습니다)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="Homebrew 설치 프로그램이 %s(으)로 종료되었습니다. 다음은 %s의 마지막 30줄입니다:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- Homebrew 설치 로그 (끝부분) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="Doctor pip 설치가 %s(으)로 종료되었습니다. 다음은 %s의 마지막 30줄입니다:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- Doctor pip 설치 로그 (끝부분) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="파이프라인 pip 설치가 %s(으)로 종료되었습니다. 다음은 %s의 마지막 30줄입니다:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- 파이프라인 pip 설치 로그 (끝부분) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="Hub 전원 LaunchAgent 설치에 실패했습니다. 위의 출력을 확인하세요."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="예상 번들 경로에서 Hub 전원 스크립트를 찾을 수 없습니다."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  설치 프로그램 .app에서 vendor/hub_power/가 누락된 것 같습니다"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  (위치: Contents/Resources/hub-power/). 배터리 상태를 고려한 속도 조절은 설치되지 않으며, 나머지 설치는 계속됩니다."
MSG_WARN_ICAL_SERVER_FAILED="어시스턴트 API를 시작할 수 없습니다. 다음 설치를 실행하기 전까지 iPhone의 Ostler 앱 접근이 제한됩니다."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - 이미지 가져오기 실패(네트워크, 디스크 공간 또는 레지스트리 시간 초과)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="iMessage 전체 디스크 접근 권한 신호를 pipeline_signals.json에 쓸 수 없습니다. Doctor 대시보드에 전체 디스크 접근 권한 카드가 자동으로 표시되지 않을 수 있습니다."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="IMAP 호스트가 비어 있습니다. 다시 시도하세요."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="iMessage 자동화 권한: 허용되지 않음 (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="iMessage 자동화 권한: 확인 결과가 불확실합니다."
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="iMessage 기록(chat.db)을 읽을 수 없습니다. Ostler 데몬에 전체 디스크 접근 권한이 아직 허용되지 않았습니다. 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한에서 허용하기 전까지 iMessage 기록 읽기는 꺼진 상태로 유지됩니다."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="시스템 설정 > 개인정보 보호 및 보안 > 자동화를 엽니다. iMessage 전송을 연결하려면 OstlerInstaller(또는 터미널)의 메시지 항목을 체크하세요."
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="전체 이메일 주소가 아니므로 무시됨: %s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="전체 이메일 주소를 하나 이상 입력하세요(예: you@example.com)."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="iMessage에는 허용된 연락처가 하나 이상 필요합니다. 다시 시도하거나"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="가져오기 파이프라인을 사용할 수 없습니다(비공개 저장소, 베타 테스터 전용)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="가져오기 파이프라인이 설치 프로그램에 포함되어 있지 않습니다. 강제 실패를 건너뛰었습니다."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="가져오기 파이프라인이 설치 프로그램에 포함되어 있지 않습니다. 이는 제품용 설치 경로이며, contact_syncer Python 패키지가 .app 번들 안에 포함되어야 합니다."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX를 선택하면 수신하는 모든 이메일을 어시스턴트가 읽게 됩니다."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - 위키 출력 볼륨에 필요한 디스크 공간이 부족합니다"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="Intel Mac이 감지되었습니다. 성능이 제한됩니다. Apple Silicon을 권장합니다."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s은(는) 클라우드 제공업체 호스트입니다."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="%s의 JWT_SECRET이 금지 목록에 있습니다. 지식 그래프 서비스를 불러올 수 있도록 다시 생성합니다"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="%s의 JWT_SECRET이 너무 짧습니다(%s < %s자). 다시 생성합니다"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="지식 저장소를 복제했지만 pyproject.toml이 없어 venv 설정을 건너뛰었습니다."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="지식 서비스 설치에 실패했습니다(복제)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="라이선스: %s은(는) Apache 2.0이 아닌 Google의 Gemma 이용 약관에 따라 배포됩니다."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="MacBook에서는 배터리 및 잠자기 처리를 위해 이 설정이 필요합니다."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="macOS 연락처 권한이 거부되었거나 아직 허용되지 않았습니다."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="macOS는 스크립트에서 이 권한을 요청하지 않습니다. 직접 허용해야 합니다."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="Mac mini에는 영향이 없습니다. MacBook 사용자는 다시 시도하세요."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="메일 데이터는 여전히 수동으로 가져올 수 있습니다:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  수동 재시도: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  원인을 해결한 후 수동으로 재시도:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="Apple Mail과 사용자 지정 IMAP 모두 선택되지 않아 Apple Mail을 기본값으로 사용합니다."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="패스키가 설정되지 않았습니다. 데이터베이스가 암호화되지 않습니다."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="이전 설치에서 복구 키를 생성했지만 설치가 완료되지 않아 키가 표시되지 않았습니다. 복구 키는 어디에도 저장되지 않으므로, 여기서도 다시 확인할 수 없습니다."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="암호는 계속 사용할 수 있으며 현재 잠긴 항목은 없습니다. 하지만 암호를 잊어버리면 다시 접근할 방법이 없습니다."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="보안을 새로 설정하려면 지원팀에 문의하세요. 새 설정 시 보관할 새 복구 키가 표시됩니다."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="암호가 일치하지 않습니다. 다시 시도하세요."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="암호 설정에 실패했습니다. 출력:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="입력이 비어 있습니다. 암호 설정을 건너뛰었습니다."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="암호는 12자 이상이어야 합니다. 다시 시도하세요."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="데이터를 암호화하려면 암호가 필요합니다."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="국제 번호 형식이 아닙니다. 맨 앞에 +를 붙이고 국가 번호와 나머지 번호를 입력하세요(예: +447700900123). 다시 시도하세요."
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama가 응답하지 않습니다"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="ollama pull %s 실패 (시도 %s/3). %s초 후 다시 시도합니다..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="여유 공간이 %s GB뿐입니다. 최소 35 GB를 권장합니다 (Docker 이미지 + AI 모델 + 데이터)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="배터리 사용 중에는 Hub 전원 LaunchAgent(3.14단계)가 일시 중지될 수 있습니다"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="또는 설치 프로그램을 다시 실행하여 다른 채널을 선택하세요."
# NEEDS REVIEW: Source is a fragment continuing on the next line ("once the ..."); Korean word order cannot follow the split. A human should check how it joins with the followi
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="또는 Phase B의 릴리스 파이프라인보다 앞서 실행 중입니다. 다음이 준비되면 설치 프로그램을 다시 실행하세요."
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="ostler-assistant doctor에서 오류 %s개를 보고했습니다."

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="Ostler 설치가 끝났지만 설치 중 오류 %s개가 발생했습니다."
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  자세한 내용은 ~/.ostler/logs/install.log에 있습니다. 그래도 Ostler는 시작됩니다. Doctor를 열어 확인이 필요한 항목을 살펴보세요."
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="Ostler 설치가 끝났지만 설치 단계 %s개가 정상적으로 완료되지 않았습니다: %s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="Ostler 설치가 끝났으며 설치 중 발생한 오류는 없습니다."

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="ostler-assistant를 압축 해제했지만 --version 확인에 실패했습니다."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="Ostler 어시스턴트 LaunchAgent 설치가 3번 시도 후 실패했습니다. 진단 출력은 위와 아래를 참고하세요."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="Ostler 어시스턴트 LaunchAgent 설치 %s번째 시도가 실패했습니다. 다시 시도합니다."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="데몬 stderr 전체 위치: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="stderr 마지막 부분:"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="ostler-assistant v%s은(는) Apple Silicon에서만 사용할 수 있습니다 (감지됨: %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  암호화 저장소 종속 항목을 대화 메모리 venv에 설치하지 못했습니다. 대화 보강이 실행되지 않습니다."
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  SCRIPT_DIR에서 암호화 저장소 종속 항목 소스를 찾을 수 없습니다. 대화 메모리 엔진을 불러올 수 없으며 대화 보강이 실행되지 않습니다."
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - ostler-wiki-compiler 이미지를 아직 가져올 수 없습니다 (레지스트리 미연결)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph가 응답하지 않습니다"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - 이 단계에서 Oxigraph가 아직 정상 상태가 아닙니다 (위의 로그를 확인하세요)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="비밀번호가 일치하지 않거나 비어 있습니다. 다시 시도하세요."
# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="주요 설치에는 보통 45분에서 몇 시간이 걸립니다 (Docker + Ollama 다운로드 + 최초 설정). 연결 속도가 느리거나 Mac에 수년간의 기록이 있으면 더 오래 걸립니다. 한동안 아무 변화가 없는 것은 정상입니다. 멈춘 것이 아니라 백그라운드에서 다운로드하고 설정하는 중입니다."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  pip 설치에 실패했습니다. 대화 메모리 엔진을 사용할 수 없습니다."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  pip 설치에 실패했습니다. email-ingest는 시스템 python으로 대체됩니다 (실행 중에도 실패할 수 있습니다)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  pip 설치에 실패했습니다. ostler-knowledge를 사용할 수 없습니다."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  pip 설치에 실패했습니다. 이메일 수집 엔진을 사용할 수 없습니다. 매시간 실행되는 LaunchAgent는 계속 mbox 파일을 만들지만, 문제가 해결될 때까지 그래프로 수집할 수 없습니다."
MSG_WARN_CM021_SOURCE_NOT_FOUND="앱 번들에서 이메일 수집 엔진 소스를 찾을 수 없습니다. 매시간 실행되는 백그라운드 작업은 메일 파일을 수집하지 않고 저장만 합니다."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="앱 번들에서 ostler_fda 소스를 찾을 수 없습니다. email-ingest LaunchAgent는 실행 시 시스템 python으로 대체됩니다."
MSG_WARN_PIP_SAID="pip 출력:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="전체 설치를 위해 전원 어댑터를 연결하세요."
MSG_WARN_PORT_1_ALREADY_USE_PID="포트 %s은(는) 이미 %s(PID %s)에서 사용 중입니다"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - 포트 3000을 다른 서비스가 이미 사용 중입니다"
MSG_WARN_POWER_SOURCE="전원: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="sqlcipher3 설치에 실패했습니다."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="sqlcipher3 설치에 실패했습니다. 데이터베이스가 암호화되지 않습니다."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="Python 3을 찾을 수 없습니다. Python 3.12를 설치합니다..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="Python %s 버전이 너무 오래되었습니다(3.10 이상 필요). Python 3.12를 설치하는 중..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant가 응답하지 않습니다"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         상업적으로 사용하기 전에 https://ai.google.dev/gemma/terms 를 읽어 보세요."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="공개 버전은 https://ostler.ai/licenses.html 에서 읽을 수 있습니다"
MSG_WARN_REDIS_NOT_RESPONDING="Redis가 응답하지 않습니다"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="릴리스가 제공될 때까지 기다리거나, 바이너리를 수동으로 배치하세요:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="다시 실행하는 중 – 자체 호스팅 호스트를 입력하거나, Ctrl-C를 눌러 종료한 뒤 Apple Mail을 선택하여 다시 실행하세요."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="iMessage 선택을 해제한 상태로 설치 프로그램을 다시 실행하면 건너뛸 수 있습니다."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="--allow-plaintext 옵션으로 실행 중: 암호화가 꺼져 있습니다. 프로덕션 환경에서는 사용하지 마세요."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  처음 실행한 후 \`%s doctor\`를 실행하세요"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="로그인한 후 'tailscale ip --4'를 실행하고, 표시된 주소를 iOS 앱에 추가하세요."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="Safari 확장 프로그램을 복사하지 못했습니다. 나중에 수동으로 설치할 수 있습니다"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="Safari 확장 프로그램은 설치되었지만 페어링에 사용할 확장 프로그램 토큰이 없습니다. 설치 프로그램을 다시 실행할 때까지 탐색 기록 수집이 꺼진 상태로 유지됩니다"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="Safari 확장 프로그램을 이 Hub와 페어링하지 못했습니다. 설치 프로그램을 다시 실행할 때까지 탐색 기록 수집이 꺼진 상태로 유지됩니다"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="보안 모듈을 찾을 수 없습니다. 패스키 설정을 건너뜁니다."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  확인한 위치: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  이는 대개 설치 프로그램 .app이 다음 항목 없이 빌드되었음을 의미합니다:"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  Contents/Resources/ 안에 포함되어야 하는"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  벤더링된 ostler_security 패키지입니다. 설치 프로그램을 다시 다운로드하거나"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  개발/CI 설치라면 --allow-plaintext 옵션으로 다시 실행하세요."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="보안 설정에 실패했습니다. 데이터베이스 암호화 없이 계속합니다."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="보안 설정에 실패했습니다. 출력:"
MSG_WARN_SEE_STDERR_FRAGMENT="  stderr 일부는 %s에서 확인하세요."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="바이너리 설치를 건너뜁니다. 마법사가 작성한 config.toml은 그대로 유지됩니다."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="Doctor LaunchAgent 설치를 건너뜁니다."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="이메일 수집 LaunchAgent 설치를 건너뜁니다."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="LaunchAgent 설치를 건너뜁니다. Mac mini 배포에는 영향이 없습니다."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="LaunchAgent 설치를 건너뜁니다. 다음을 시도하세요: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="위키 재컴파일 LaunchAgent 설치를 건너뜁니다."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="일부 포트가 사용 중입니다. Docker 컨테이너가 시작되지 않을 수 있습니다."
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="포트 %s은(는) 이 계정에 속한 %s(PID %s)이(가) 이미 사용 중입니다. 해당 프로그램을 종료하고 설치 프로그램을 다시 실행하세요."
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="포트 %s은(는) 이 Mac의 다른 사용자 계정에 속한 프로그램이 이미 사용 중입니다. Ostler는 이 포트를 공유할 수 없으며, 그대로 시작하면 두 계정의 데이터가 섞일 수 있습니다. 다른 계정을 로그아웃하거나, 이 포트를 사용하는 계정이 하나뿐인 Mac에 Ostler를 설치하세요."
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="필요한 포트가 이미 사용 중이어서 Ostler가 데이터베이스를 시작할 수 없습니다."
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="위에 나열된 포트를 사용하는 프로그램을 종료한 다음 설치 프로그램을 다시 실행하세요."
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="포트 %s이(가) 사용 가능한지 확인하지 못했습니다. 확인하지 못한 것은 포트가 비어 있다는 뜻이 아닙니다."
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="하나 이상의 포트 검사를 실행하지 못해 다른 프로그램과의 충돌 가능성을 배제할 수 없습니다."
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="이 Mac에서 가장 신뢰할 수 있는 포트 검사를 실행하지 못해, 아래 검사는 평소보다 덜 철저합니다."
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="Ostler가 해당 포트가 사용 가능한지 확인하지 못했으며, 확인하지 않은 포트에서는 데이터베이스를 시작하지 않습니다. 설치 로그와 함께 지원팀에 문의하세요."
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="오래된 Colima 시작 항목을 제거하지 못했습니다. 재시작 후 위키가 로드되지 않을 수 있습니다. 지원팀에 문의하세요."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="충돌하는 서비스를 중지하거나 docker-compose.yml에서 포트를 변경하세요"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="Tailscale에 3분 안에 로그인되지 않았습니다. 나중에 설정에서 다시 진행할 수 있습니다."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="Tailscale IP가 .env에 기록되었지만 이후 읽기에서 확인되지 않았습니다. iPhone의 Ostler app이 이를 인식하지 못할 수 있습니다. 그럴 경우 install.sh --repair를 다시 실행하세요."
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="원격 접근에 대한 답변을 저장하지 못해 다음 재설치 때 다시 묻습니다. 그 외에는 영향이 없습니다."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="Tailscale 설치에 실패했습니다. 나중에 tailscale.com에서 설치할 수 있습니다."
MSG_WARN_TAILSCALE_STATE_UNREADABLE="이 Mac에 읽을 수 없는 기존 Tailscale 설정이 있어 아직 네트워크에 연결되어 있는지 확인할 수 없습니다. 아래에서 선택하세요. 이미 연결되어 있어도 다시 설정하는 데는 문제가 없습니다."
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="배포된 서비스는 이것들이 없으면 시작되지 않습니다."
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  이 문제가 해결될 때까지입니다. 조치 방법은 다음 단계 배너를 참조하세요."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  확인해 보세요. cron-delivery / imessage-tcc가 흔한 원인입니다"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  다음을 시도하세요: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  다음을 시도하세요: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="'%s'은(는) 알 수 없는 선택입니다. iMessage + 이메일을 기본값으로 사용합니다."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="알 수 없는 선택입니다. 권장 설정을 사용합니다."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  업데이트에 실패했습니다. 기존 체크아웃으로 계속합니다."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="해당 계정에는 위에서 권장한 Apple Mail을 사용하세요. Ostler는 클라우드 비밀번호를 저장하지 않습니다."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="INBOX를 사용합니다. 어시스턴트가 수신되는 모든 이메일을 읽습니다."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="Vane 컨테이너가 시작되었지만 http://localhost:3000이 60초 안에 응답하지 않았습니다."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="Vane(로컬 웹 검색)을 시작하지 못했습니다. 흔한 원인:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  웹 검색은 선택 사항이며, 없어도 Ostler의 나머지 기능은 작동합니다."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="전용 레이블/폴더를 사용하시길 강력히 권장합니다."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="WhatsApp으로 브리핑을 전달하려면 전화번호가 필요합니다. 다시 시도하세요,"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="위키는 컴파일되었지만 wiki-site 컨테이너를 시작하지 못했습니다."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="위키 첫 컴파일에 실패했습니다. 흔한 원인:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="첫날 위키 따라잡기 LaunchAgent를 불러오지 못했습니다. 매일 실행되는 위키 재빌드는 계속 작동하며, 위키는 1시간 이내가 아니라 다음 날 새로 고쳐집니다."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="위키 재컴파일 LaunchAgent 설치에 실패했습니다. 위의 출력을 참조하세요."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="위키가 자동으로 업데이트되지 않습니다. 수동 재빌드는 계속 사용할 수 있습니다:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="마법사 설정은 그대로 유지되며 바이너리도 준비된 상태로 남아 있습니다. 수동으로 다시 시도:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="어시스턴트에게 이름이 필요합니다. 위의 추천에서 고르거나 직접 입력하세요."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="시스템 설정 > 개인정보 보호 및 보안 > 연락처에서 다시 허용할 수 있습니다."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="보안 설정은 나중에 실행할 수 있습니다: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="직접 설치해야 할 수 있습니다: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  실제 값:   %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="압축을 푼 후 %s에 Ostler RemoteCapture 번들이 없었습니다. 릴리스 tarball이 손상되었을 수 있습니다."
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="%s을(를) 만들거나 접근할 수 없어 Ostler RemoteCapture를 설치할 곳이 없습니다. 다운로드 문제가 아니라 폴더 권한 문제입니다."
MSG_ERR_CM042_RENAME_FAILED="Ostler RemoteCapture를 정상적으로 다운로드하고 압축을 풀었지만 %s(으)로 옮기지 못했습니다. 압축을 푼 앱은 /Applications에 남아 있습니다. 서명 문제는 아닙니다."
MSG_ERR_CM042_CODESIGN_OUTPUT="  codesign --verify 보고 내용:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  게시된 체크섬과 일치하지 않는 번들은 준비하지 않습니다."
MSG_ERR_CM042_SHA_256_MISMATCH="Ostler RemoteCapture tarball의 SHA-256이 일치하지 않습니다."
MSG_ERR_CM042_PIN_FAILED="Ostler가 이 RemoteCapture 다운로드가 정상인지 확인하지 못해 설치하지 않았습니다."
MSG_ERR_CM042_VERSION_UNKNOWN="Ostler가 인식하지 못하는 RemoteCapture 버전이어서 설치하지 않았습니다."
MSG_ERR_CM042_SIDECAR_DISAGREES="이 RemoteCapture 다운로드와 함께 게시된 체크섬이 파일과 일치하지 않아 설치하지 않았습니다."
MSG_ERR_CM042_SPCTL_OUTPUT="  spctl --assess 보고 내용:"
MSG_ERR_CM042_VERIFY_FAILED="Ostler RemoteCapture 서명 및 공증 확인에 실패했습니다."
MSG_ERR_CODESIGN_DV_REPORTED="  codesign -dv 보고 내용:"
MSG_ERR_EXPECTED="  예상 값: %s"
MSG_ERR_FILE_BRIEF_REPORTED="  file --brief 보고 내용: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="%s에 있는 ostler-assistant 바이너리가 Mach-O 실행 파일이 아닙니다."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="ostler-assistant tarball의 SHA-256이 일치하지 않습니다."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  게시된 체크섬과 일치하지 않는 바이너리는 준비하지 않습니다."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="격리 속성을 제거하거나 LaunchAgent를 불러오지 않습니다."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="원본 tarball이 수정된 후 설치 프로그램을 다시 실행하세요."
MSG_ERR_URL="  url:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="Intel Mac은 지원되지 않습니다. Ostler에는 Apple Silicon(M1, M2, M3 또는 M4)이 필요합니다."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="RAM이 최소 16GB 필요합니다. 현재 %sGB입니다. 24GB를 권장합니다."
MSG_FAIL_CM042_SIGNATURE_FAILED="Ostler RemoteCapture 설치가 중단되었습니다. 서명 또는 공증 확인에 실패했습니다. 지원을 위해 번들은 /Applications에 그대로 두었습니다. support@ostler.ai로 이메일을 보내 주시고 설치 프로그램을 다시 실행하세요."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="3번 시도했지만 %s을(를) 가져오지 못했습니다. 네트워크를 확인하고 설치 프로그램을 다시 실행하세요."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="3번 시도했지만 nomic-embed-text를 가져오지 못했습니다. 네트워크를 확인하고 설치 프로그램을 다시 실행하세요."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker를 사용할 수 없습니다. 설치 프로그램을 다시 실행하여 Colima를 설치하세요."
MSG_FAIL_CONTAINER_CLIENT_MISSING="이 Mac에 docker 명령이 없어 Ostler가 필요한 서비스를 시작할 수 없습니다. 설치 프로그램을 다시 실행하세요. 다시 실패하면 %s에 있는 로그를 보내 주세요."
MSG_FAIL_CONTAINER_ENGINE_ABSENT="Ostler에는 컨테이너 런타임이 필요한데, 이 Mac에서 응답하는 런타임이 없습니다. 위키, 지식 그래프, 검색 인덱스는 모두 컨테이너 안에서 실행되므로, 설치를 끝내고 이들이 없는 상태로 두는 대신 여기서 중단했습니다. 해결 방법: 터미널을 열고 'colima start'를 실행한 다음 이 설치 프로그램을 다시 실행하세요. Docker Desktop을 사용한다면 앱을 열고 고래 아이콘이 안정될 때까지 기다린 후 다시 실행하세요. 전체 로그는 %s에 있습니다."
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="Docker가 제때 준비되지 않아 지식 그래프 데이터베이스를 시작하지 못했습니다. Colima 또는 Docker가 실행 중인지 확인한 후 설치 프로그램을 다시 실행하세요."
MSG_FAIL_GRAPH_DB_PULL_FAILED="여러 번 시도했지만 지식 그래프 데이터베이스 이미지를 다운로드하지 못했습니다. 대개 네트워크 문제입니다. 인터넷 연결을 확인하고 설치 프로그램을 다시 실행하세요."
MSG_FAIL_GRAPH_DB_UP_FAILED="지식 그래프 데이터베이스를 다운로드했지만 시작하지 못했습니다. 설치 프로그램을 다시 실행하세요. 계속 발생하면 터미널을 열고 다음을 실행하세요: cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="Ostler가 지식 그래프 데이터베이스에 대한 인증된 요청을 완료하지 못했습니다. 2초 간격으로 두 번 시도했지만 모두 거부되었습니다. 아직 원인은 알 수 없습니다. 데이터베이스가 아직 시작 중이었거나, Ostler가 가진 자격 증명이 예상과 다를 수 있습니다. 데이터는 변경되지 않았습니다. 설치 프로그램을 다시 실행하면 대개 해결됩니다. 해결되더라도 알려 주시기 바랍니다. 설치 로그를 보내 주세요. 현재 재현을 위해 적극적으로 조사 중인 오류입니다."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="설치 프로그램 번들에 FDA 추출 모듈이 없습니다. ostler.ai/install에서 .app을 다시 다운로드하거나, 개발/CI용으로 --allow-plaintext를 사용하여 다시 실행하세요."
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="데이터 추출 모듈이 설치되었지만 불러올 수 없어, 백그라운드 새로 고침이 실행될 때마다 실패하게 됩니다. 전체 출력은 %s에 저장되었습니다. 설치 프로그램을 다시 실행하고, 지원팀에 문의할 때 해당 파일을 첨부하세요(참조: ERR-10-FDA-DEPS-IMPORT)."
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="내부 오류: 데이터 추출 모듈이 애플리케이션 번들 안에 준비되어 서명이 손상될 수 있습니다. 이는 빌드 결함이며 Mac의 문제가 아닙니다. ostler.ai/install에서 .app을 다시 다운로드하세요(참조: ERR-10-FDA-DEPS-UNSAFE-PATH)."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="Doctor 종속 항목 설치에 실패했습니다. 전체 출력은 %s에 저장되었습니다. support@ostler.ai로 이메일을 보낼 때 첨부하세요(참조: ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="가져오기 파이프라인 종속 항목 설치에 실패했습니다. 전체 출력은 %s에 저장되었습니다. support@ostler.ai로 이메일을 보낼 때 첨부하세요(참조: ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="Homebrew 설치에 실패했습니다. 전체 출력은 %s에 저장되었습니다. support@ostler.ai로 이메일을 보낼 때 첨부하세요."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="가져오기 파이프라인 설치에 실패했습니다. 제품 설치에는 contact_syncer 번들이 필요합니다. 개발/CI용으로 --allow-plaintext를 사용하여 다시 실행하거나, 설치 프로그램을 다시 다운로드하여 시도하세요."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="잠자기를 해제하고 Homebrew를 설치하려면 sudo 권한이 필요합니다. 준비되면 다시 실행하세요."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="Colima와 Docker Desktop 모두 시작할 수 없습니다. Docker Desktop을 설치한 후 다시 실행하세요."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="디스크 공간이 부족합니다(%sGB). 공간을 확보한 후 다시 시도하세요."
MSG_FAIL_MACOS_BELOW_FLOOR="macOS %s은(는) Ostler가 지원하는 버전보다 오래되었습니다. Ostler에는 macOS %s 이상이 필요합니다. 설치 프로그램 앱이 해당 버전용으로 만들어져 그보다 오래된 버전에서는 열리지 않습니다. macOS를 업데이트한 후 설치 프로그램을 다시 실행하세요."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="패스키가 설정되지 않았고 기존 보안 구성도 없습니다. 개발/CI용으로 --allow-plaintext를 사용하여 다시 실행하거나, 설치 프로그램을 다시 실행하고 Touch ID 안내를 확인하세요."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="대화 메모리 엔진이 필요합니다. 개발/CI용으로 --allow-plaintext를 사용하여 다시 실행하거나, 위에서 누락된 번들을 해결한 후 다시 시도하세요."
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="번들에 포함된 Ostler 데몬(v%s, %s)이 이 설치 프로그램이 전체 디스크 접근 권한을 통해 수집을 연결하는 데 필요한 'run-source' 명령을 지원하지 않습니다. 설치 프로그램 번들 내부의 버전 불일치입니다. 이대로 설치하면 모든 수집 소스가 조용히 작동하지 않고, 눈에 보이는 오류 없이 제품이 최신 상태를 유지하지 못하게 됩니다. ostler.ai/install에서 .app을 다시 다운로드하여 시도하세요(참조: ERR-11-DAEMON-RUN-SOURCE-SKEW)."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="ostler_security 설치에 실패했습니다. 개발/CI용으로 --allow-plaintext를 사용하여 다시 실행하거나, 위의 pip 오류를 해결한 후 다시 시도하세요."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="패스키 설정에 실패했습니다. 개발/CI용으로 --allow-plaintext를 사용하여 다시 실행하거나, 위의 오류를 해결한 후 다시 시도하세요."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="암호화된 데이터베이스에는 sqlcipher3가 필요합니다. 개발/CI용으로 --allow-plaintext를 사용하여 다시 실행하거나, 위의 pip 오류를 해결한 후 다시 시도하세요."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="이 설치 프로그램은 macOS 전용입니다."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="Xcode Command Line Tools 설치가 15분 안에 완료되지 않았습니다. 터미널을 열고 'xcode-select --install'을 실행한 다음, macOS 대화상자에서 설치를 클릭하고 완료될 때까지 기다린 후 이 설치 프로그램을 다시 실행하세요."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="Homebrew 설치가 성공했다고 보고되었지만 /opt/homebrew/bin/brew를 찾을 수 없습니다. 전체 기록은 %s에서 확인하세요. 복구 방법: 터미널을 열고 '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"'를 실행한 다음 설치 프로그램을 다시 실행하세요."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew가 /opt/homebrew/bin/brew에 설치되어 있지만 shellenv 평가 후에도 'brew' 명령이 PATH에 없습니다. 새 터미널 창을 열고 설치 프로그램을 다시 실행하세요."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="'brew install colima docker docker-compose'가 성공했다고 보고되었지만 colima가 PATH에 없습니다. Homebrew 오류는 %s에서 확인하세요. 복구 방법: 터미널을 열고 'brew install colima docker docker-compose'를 직접 실행한 다음 설치 프로그램을 다시 실행하세요."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="'brew install colima docker docker-compose'가 성공했다고 보고되었지만 docker CLI가 PATH에 없습니다. %s을(를) 확인하세요. 복구 방법: 'brew install docker'를 직접 실행한 다음 설치 프로그램을 다시 실행하세요."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="Ollama 앱 설치가 성공했다고 보고되었지만 /Applications/Ollama.app에서 실행 파일을 찾을 수 없습니다. %s을(를) 확인하세요. 복구 방법: 'brew install --cask ollama-app'을 직접 실행한 다음 설치 프로그램을 다시 실행하세요."
MSG_FAIL_EMBED_HEALTHCHECK="Ollama가 실행 중이지만 임베딩 모델이 벡터를 반환하지 않았습니다(HTTP 200이 아니거나 결과가 비어 있음). 이 경우 사람 카드, 검색, 탐색이 모두 비어 있게 됩니다. %s을(를) 확인하세요. 복구 방법: Homebrew 포뮬러가 아닌 Ollama 앱이 설치되어 실행 중인지 확인한 다음 설치 프로그램을 다시 실행하세요."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="'brew install sqlcipher'가 성공했다고 보고되었지만 sqlcipher가 PATH에 없습니다. %s을(를) 확인하세요. 복구 방법: 'brew install sqlcipher'를 직접 실행한 다음 설치 프로그램을 다시 실행하세요."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="'brew install --cask tailscale'이 /Applications/Tailscale.app을 만들지 못했습니다. %s을(를) 확인하세요. 복구 방법: https://tailscale.com/download/macos에서 Tailscale을 내려받아 /Applications로 드래그한 다음 설치 프로그램을 다시 실행하세요."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="'brew install python@3.11'이 성공했다고 보고되었지만 /opt/homebrew/opt/python@3.11/bin/python3.11에서 python3.11 실행 파일을 찾을 수 없습니다. %s을(를) 확인하세요. 복구 방법: 'brew reinstall python@3.11'을 실행한 다음 설치 프로그램을 다시 실행하세요."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="이전 답변을 찾았습니다"
MSG_PROMPT_REUSE_SETTINGS_HELP="이 Mac에서 이전 설치 시도를 발견했습니다. 이미 답하신 질문(이름, 어시스턴트 이름, 시간대, 국가 코드, 채널 등)은 다시 입력하지 않도록 그대로 사용됩니다. 중단한 곳에서 이어서 진행하려면 예를, 처음부터 질문에 다시 답하려면 아니요를 선택하세요."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="찾은 이전 답변: 이름 = %s, 어시스턴트 = %s, 시간대 = %s."

MSG_PROMPT_PERMS_OK_TITLE="계속할까요?"
MSG_PROMPT_PERMS_OK_HELP="macOS에서 연락처와 파일 및 폴더 접근 권한을 요청합니다. 전체 디스크 접근 권한은 선택 사항이며 나중에 허용할 수 있습니다."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="전체 이름(연락처에 표시되는 이름)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="전체 이름(예: Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="어시스턴트가 어떻게 불러 드리면 좋을까요?"
MSG_PROMPT_USER_ID_HELP="어시스턴트가 사용자를 부를 때 사용할 짧은 이름입니다(예: 'Andy', 'Andrew', 'Mrs Smith'). 아침 브리핑과 채팅 답장에 이 이름이 표시됩니다. 위의 전체 이름과는 다릅니다."

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
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="캘린더 목록입니다. 맞게 표시되었나요?"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="브리핑에서 누구의 여행인지 헷갈리지 않도록 각 캘린더의 주인을 추측해 두었습니다."
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="자동으로 제외되어 브리핑에 사용되지 않음:"
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="내 캘린더"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="일정 %s개"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="일정 %s개"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="공휴일"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="생일"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="Siri 제안"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="구독 중인 캘린더"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="미리 알림"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="\"%s\"을(를) 브리핑에 사용할까요?"
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="%s(으)로 보여서 이 항목은 제외했습니다. 실제로 누군가의 일정표라면 예라고 답하세요."
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="\"%s\"은(는) 누구의 캘린더인가요?"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="\"%s\"은(는) 어떤 종류의 캘린더인가요?"
MSG_CONFIRM_CALENDAR_TYPE_HELP="개인, 업무, 가족, 공유, 기타 중 하나를 입력하세요. 이에 따라 일정이 얼마나 민감하게 다뤄지는지가 정해집니다."
MSG_CONFIRM_CALENDARS_SAVED="캘린더 소유자를 저장했습니다"
MSG_CONFIRM_CALENDARS_FAILED="캘린더 소유자를 저장하지 못했습니다(치명적이지 않으며 나중에 설정할 수 있습니다)"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="이 프로필들은 모두 본인(%s)으로 보입니다. 하나로 합칠까요?"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="이 프로필들은 본인과 확실한 신원 정보(이메일 도메인, LinkedIn 프로필 또는 직장)를 공유합니다. 하나로 합치면 어시스턴트가 본인의 기록을 여러 사람의 것으로 여기지 않게 됩니다. 나중에 되돌릴 수 있습니다."
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="이름은 같지만 다른 사람으로 보이는 사람이 있습니다(%s). 본인인가요, 다른 사람인가요?"
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="'다른 사람'을 선택하면 별개의 사람으로 유지됩니다(어시스턴트가 이 사람을 본인과 절대 병합하지 않습니다). 정말 본인인 경우에만 '나'를 선택하세요."
MSG_CONFIRM_IDENTITY_SAVED="본인 확인 내용을 저장했습니다"
MSG_CONFIRM_IDENTITY_FAILED="본인 정보 선택을 저장하지 못했습니다(치명적인 오류는 아니며 나중에 확인할 수 있습니다)"

# NEEDS REVIEW: en-GB header asks for human translation of this key
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="백그라운드에서 설치 중(약 45분에서 몇 시간)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="+%s을(를) 사용할까요?"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="국가 코드를 입력하세요(예: 영국은 44, 미국은 1)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="기본 국가 코드"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="연락처를 가져올 때 전화번호를 표준 형식으로 바꾸고, 법규 준수 기본값에 쓸 지역(영국 / EU / 미국 / 기타)을 설정하는 데 사용됩니다."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="+%s이(가) 감지되었습니다. Hub에 이 코드를 사용할까요?"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="위에 입력한 전화번호에서 감지했습니다. 사용하려면 '예'를, 다른 국가 코드를 입력하려면 '아니요'를 선택하세요."

MSG_PROMPT_TZ_CONFIRM_TITLE="이 시간대를 사용할까요?"
MSG_PROMPT_TZ_CONFIRM_HELP="감지된 시간대: %s"
MSG_PROMPT_USER_TZ_TITLE="시간대를 입력하세요(예: Europe/London, Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="어시스턴트를 뭐라고 부르시겠어요?"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="입력란의 이름은 무작위 추천입니다. 원하는 이름으로 자유롭게 바꿔 입력하세요. Marvin, Samantha, Joshua, Friday, Athena, Sage, Rosie가 인기 있는 이름입니다." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="원하는 이름을 자유롭게 입력하세요. 추천 이름은 시작점일 뿐입니다."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="어시스턴트가 어떻게 연락할까요?"
MSG_PROMPT_CHANNEL_CHOICE_HELP="어시스턴트가 사용할 메시지 채널을 선택하세요. 나중에 앱의 Doctor 섹션에서 변경할 수 있습니다."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_WHATSAPP_CONSENT_TITLE="어시스턴트의 WhatsApp 메시지를 활성화할까요?"
# NEEDS REVIEW: Legal/consent wording; lawyer should check.
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web은 제3자 서비스입니다. 활성화하면 메시지가 로컬 Ostler로 전달되기 전에 WhatsApp 자체 인프라를 거치며, 자동화된 사용을 이유로 WhatsApp(Meta Platforms Ireland Ltd)이 WhatsApp 계정을 정지, 제한 또는 종료할 수 있음에 동의하는 것입니다. 나중에 설정에서 비활성화할 수 있습니다."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="WhatsApp 전화번호"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="국가 코드를 포함한 국제 번호입니다(예: +447700900123). 숫자와 맨 앞의 +만 입력하세요. 공백, 괄호, 하이픈은 쓰지 않습니다."
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="%s(으)로 저장되었습니다. WhatsApp에는 공백이나 괄호가 없는 번호가 필요합니다."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="Ostler 어시스턴트에 대해 전체 디스크 접근 권한 켜기"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="시스템 설정이 전체 디스크 접근 권한 화면으로 열려 있습니다."
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
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="목록에서 \"%s\"을(를) 찾아 전체 디스크 접근 권한 스위치를 켜세요."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="목록에 없나요? Finder 윈도우에서 \"%s\"을(를) 목록으로 드래그한 다음 스위치를 켜세요. 순서는 상관없습니다. 완료를 먼저 눌러도 되고 나중에 눌러도 되며, 설치 프로그램은 스위치가 실제로 켜질 때까지 기다립니다."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="목록에 없나요? Ostler가 Finder 윈도우를 열지 못했습니다. Finder에서 ⌘⇧G를 누르고 아래 경로를 입력한 다음 \"%s\"을(를) 목록으로 드래그하고 스위치를 켜세요. 순서는 상관없습니다. 완료를 먼저 눌러도 되고 나중에 눌러도 되며, 설치 프로그램은 스위치가 실제로 켜질 때까지 기다립니다."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="앱 위치: %s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="앱 위치: %s – 이 경로가 클립보드에 복사되었습니다. Finder에서 ⌘⇧G, ⌘V, Return 순서로 누르세요."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="완료"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="스위치를 켜기 전이나 후에 완료를 눌러도 됩니다. 설치 프로그램은 스위치가 실제로 켜질 때까지 기다립니다."

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="Ostler가 Mac 데이터를 읽도록 허용"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="시스템 설정이 전체 디스크 접근 권한 화면으로 열려 있습니다."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="목록에서 \"OstlerInstaller\"를 찾아 켜세요."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="끝나면 완료를 클릭하세요. 그러면 Ostler가 Safari 방문 기록, 메모, iMessage, 메일을 읽습니다."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="완료"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="다음: 설치 프로그램의 전체 디스크 접근 권한"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="다음으로 macOS가 OstlerInstaller에 전체 디스크 접근 권한을 허용할지 묻습니다."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="스위치를 켜면 macOS에서 '종료 후 다시 열기' 또는 '나중에'를 선택하라는 대화상자가 나타납니다."
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="'종료 후 다시 열기'를 클릭하세요. 설치 프로그램이 스스로 다시 실행되고 이 단계부터 자동으로 이어집니다."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="확인"
MSG_INFO_INSTALLER_FDA_PREWARN="전체 디스크 접근 권한 허용 과정을 안내하는 중..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="설치 프로그램에 전체 디스크 접근 권한을 허용할 수 있도록 시스템 설정을 여는 중..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="설치 프로그램에 전체 디스크 접근 권한이 허용되었습니다. 다음으로 Safari, 메모, iMessage, 메일을 읽습니다."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="전체 디스크 접근 권한이 아직 허용되지 않았습니다. 허용 없이 계속합니다. 나중에 설치 프로그램을 다시 실행하여 Safari / 메모 / iMessage를 추출할 수 있습니다."
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="설치 프로그램의 전체 디스크 접근 권한 설정이 끝났습니다. 이제 긴 단계가 시작되며 대부분 자동으로 진행됩니다. 다만 개발자 도구 설치를 묻는 macOS 대화상자가 나타나는지 지켜봐 주시고, 끝날 무렵 몇 분간의 설정을 위해 다시 돌아와 주세요."
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="권한이 하나 더(어시스턴트의 메시지 기록 접근) 필요하며, 어시스턴트가 설치된 후 마지막 즈음에 요청됩니다. 그때 안내해 드리겠습니다."
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="전체 디스크 접근 권한 필요"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="Ostler가 Mac의 데이터를 읽으려 하지만 OstlerInstaller의 전체 디스크 접근 권한이 아직 꺼져 있습니다. 목록에서 \"OstlerInstaller\"를 찾아 켜 주세요."
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="또는 계속을 클릭하여 더 적은 데이터로 설치를 마칠 수 있습니다. 나중에 권한을 허용한 뒤 추출기를 다시 실행하면 됩니다."
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="계속"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="허용된 연락처"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="신뢰하는 사람들: 전화번호와 Apple ID 이메일(쉼표로 구분). %s은(는) 이 목록에 있는 사람에게만 답장하며, 그 외 사람의 메시지는 무시됩니다. 최소 한 개 항목이 필요합니다.

예:
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="Apple Mail로 메일을 읽을까요?"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="전체 디스크 접근 권한을 사용하여 Apple Mail에 추가한 모든 이메일 계정(iCloud, Gmail, Outlook 등)을 읽습니다. 암호는 저장되지 않습니다. 거의 모든 분께 권장합니다."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="Apple Mail에 메일 계정을 추가할까요?"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="이 Mac의 Apple Mail에 연결된 계정이 아직 없어 Ostler가 읽을 이메일이 없습니다. 예를 선택하면 지금 시스템 설정 > 인터넷 계정이 열립니다(iCloud, Gmail, Outlook을 추가할 수 있습니다). 아니요를 선택하면 건너뜁니다. 나중에 계정을 추가할 수 있으며, 24시간 내에 메일이 도착하지 않으면 Doctor가 후속 안내를 표시합니다."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="Apple Mail의 전체 기록을 가져올까요?"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="기본적으로 Ostler는 Apple Mail의 최근 5년간 메일을 읽습니다. 이 Mac에 그보다 많은 메일이 있고 모두 지식 그래프에 넣고 싶다면 예를 선택하여 로컬 전체 기록을 지금 가져오세요(메일함이 크면 시간이 조금 더 걸릴 수 있습니다). 아니요를 선택하면 5년 범위를 유지하며, 나중에 Doctor에서 언제든 늘릴 수 있습니다."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="사용자 지정 IMAP+SMTP 서버도 설정할까요?"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="자체 호스팅 메일함 전용입니다. Gmail, iCloud, Outlook 계정이라면 아니요로 두세요. 위의 Apple Mail을 통하는 편이 더 잘 작동합니다."

MSG_PROMPT_IMAP_HOST_TITLE="IMAP 호스트"
MSG_PROMPT_IMAP_HOST_HELP="자체 호스팅 또는 사용자 지정 IMAP 서버 전용입니다. Gmail / iCloud / Outlook은 위의 Apple Mail을 사용하세요."
MSG_PROMPT_IMAP_PORT_TITLE="IMAP 포트"

MSG_PROMPT_SMTP_HOST_TITLE="SMTP 호스트"
MSG_PROMPT_SMTP_PORT_TITLE="SMTP 포트"

MSG_PROMPT_EMAIL_USERNAME_TITLE="이메일 주소(IMAP/SMTP 사용자 이름으로도 사용)"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="누가 어시스턴트에게 이메일을 보낼 수 있나요?"
MSG_PROMPT_EMAIL_ALLOWED_HELP="본인의 이메일 주소를 쉼표로 구분하여 입력하세요. %s은(는) 이 목록에 있는 주소에서 온 이메일에만 답하며, 그 외 사람의 메일은 무시됩니다. 최소 한 개의 주소가 필요합니다. 본인 주소가 미리 입력되어 있으니 변경하거나 다른 주소를 추가하세요."

MSG_PROMPT_EMAIL_PASSWORD_TITLE="암호(숨김)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="자체 호스팅 IMAP/SMTP 서버의 암호입니다. ~/.ostler/ 아래에 로컬로 저장되며 Creative Machines로 전송되지 않습니다. 암호는 일반 텍스트로 저장되며, 이를 보호하는 것은 파일 권한뿐으로 사용자의 macOS 계정만 접근할 수 있습니다. 이후에도 암호화되지 않습니다. 주 계정 암호 대신 앱 암호를 사용하세요."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="암호 확인"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="어시스턴트가 어떤 폴더를 확인해야 하나요?"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="권장: 전용 레이블 또는 폴더(예: Ostler). 해당 위치의 메시지만 읽으며 기본 받은 편지함은 그대로 둡니다."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="확인하려면 INBOX를 다시 입력하거나, 계속을 눌러 'Ostler'를 사용하세요"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="INBOX를 선택하면 어시스턴트가 받는 모든 이메일을 읽게 됩니다. 대신 전용 레이블/폴더를 사용하길 강력히 권장합니다."

MSG_PROMPT_EXPORTS_ACK_TITLE="데이터 내보내기를 요청하셨나요?"
MSG_PROMPT_EXPORTS_ACK_HELP="Ostler는 약 20개 플랫폼에서 가져올 수 있습니다. 각 제공업체의 요청 페이지로 바로 연결되는 전체 목록은 docs.ostler.ai/data-exports에 있습니다.

대부분의 아카이브는 이메일로 도착하기까지 1~3일이 걸립니다. ZIP 파일이 도착하면 다운로드 폴더에 넣어 두세요. Ostler가 자동으로 찾습니다.

사용하지 않는 항목은 건너뛰세요. 나중에 언제든 더 가져올 수 있습니다."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="디스크를 암호화하지 않은 상태로 계속하시겠습니까?"
MSG_PROMPT_FILEVAULT_SKIP_HELP="이 Mac에서는 FileVault가 꺼져 있어 디스크가 암호화되어 있지 않습니다.

계속할 경우: Ostler가 저장하는 모든 것, 즉 ~/Documents/Ostler 아래의 개인 그래프 전체(위키, 대화, 지식 노트)와 ~/.ostler 아래의 서비스 비밀 정보 및 데이터베이스가 암호화되지 않은 상태로 디스크에 기록됩니다. 이 드라이브로 부팅하거나, 드라이브를 분리하거나, 잠금 해제된 세션에 접근할 수 있는 사람은 누구나 모든 내용을 읽을 수 있습니다. Ostler는 가장 민감한 데이터베이스를 항상 암호문으로 암호화하지만, 나머지 데이터는 디스크 자체만큼만 보호됩니다.

FileVault 사용을 강력히 권장합니다. 시스템 설정 > 개인정보 보호 및 보안 > FileVault에서 언제든지 켤 수 있으며, 다시 설치하지 않아도 백그라운드에서 암호화됩니다.

예를 선택하면 디스크를 암호화하지 않은 상태로 지금 계속합니다(신중하게 알고 내리는 선택이며 기록됩니다).
아니요를 선택하면 여기서 멈추므로, 먼저 FileVault를 켠 다음 설치 프로그램을 다시 실행할 수 있습니다. 어느 쪽을 선택해도 문제가 생긴 것은 아닙니다."

MSG_PROMPT_PASSKEY_ACK_TITLE="디스크 암호화 설정 준비 완료"
MSG_PROMPT_PASSKEY_ACK_HELP="Ostler의 민감한 데이터베이스는 다음 화면에서 직접 정하는 암호문을 사용해 SQLCipher로 암호화됩니다. Hub UI를 시작할 때마다 이 암호문을 입력해야 합니다. 별도의 복구 키도 생성되어 설치가 끝날 때 한 번만 표시됩니다. Mac의 모든 데이터를 저장 시 완전히 보호하려면 macOS FileVault를 계속 켜 두세요. 준비되면 계속을 누르세요."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="복구용 암호문도 설정하시겠습니까? (권장)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="암호문 선택"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="이 암호문은 지식 그래프를 암호화하고 시작할 때마다 Hub UI의 잠금을 해제합니다. 12자 이상이어야 합니다. 분실하면 복구해 드릴 수 없습니다. 암호 관리자에 보관하는 것을 권장합니다."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="암호문 확인"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="확인을 위해 같은 암호문을 다시 입력하세요."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="설치하는 동안 이 항목을 가져오시겠습니까?"
MSG_PROMPT_IMPORT_CONFIRM_HELP="발견된 GDPR 내보내기 파일은 설치하는 동안 지식 그래프로 가져옵니다."

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="Disney+ 내보내기 암호"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="Disney+는 GDPR 내보내기 파일을 암호로 보호된 스프레드시트로 제공합니다. 이는 정상이며 다운로드에 문제가 있는 것이 아닙니다. Disney+ 시청 기록을 지금 가져오려면 암호를 입력하고, 건너뛰려면 비워 두세요. 나머지 항목은 그대로 가져옵니다."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="내보낸 데이터가 준비되어 있나요?"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="Ostler는 소셜 미디어와 플랫폼 보관 파일을 처음부터 가져올 수 있습니다. 친구, 가족, 장소, 의견 등 지금까지의 전체 기록입니다. 첫날 Ostler가 더 많이 알수록 첫날부터 더 유용합니다. 나중에 추가해도 되니 서두르지 않으셔도 됩니다.

각 플랫폼(Twitter / X, Facebook, Instagram, LinkedIn, WhatsApp 등)에서 데이터 내보내기를 요청하고 ZIP 파일을 내려받아 다운로드 폴더에 넣어 두세요.

Ostler는 기본적으로 ~/Downloads에서 찾습니다. 다른 폴더를 사용하려면 아래에서 선택하세요. 그렇지 않으면 건너뛰고 나중에 가져오세요."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="이 Takeout에서 Gmail 메시지를 가져오시겠습니까?"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="Takeout 파일에서 Gmail 내용을 직접 읽습니다. Google은 Ostler를 알 수 없습니다."

MSG_PROMPT_FDA_PRESET_TITLE="Ostler가 이 Mac의 어떤 소스를 학습하도록 할까요?"
MSG_PROMPT_FDA_PRESET_HELP="세 가지 프리셋 중에서 고르거나 각 항목을 직접 선택하세요. 민감한 소스(얼굴 인식)는 모든 프리셋에서 기본적으로 꺼져 있으니, 원할 때만 신중하게 선택하세요."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="권장. Apple Mail, 연락처, 캘린더, 메모, 메시지, 미리 알림, Safari 방문 기록, Safari 북마크, 사진 이벤트(날짜와 장소만, 얼굴 인식 제외)를 포함합니다. WhatsApp 데스크톱 기록과 Chrome 기록은 앱이 설치되어 있으면 자동으로 추가됩니다. 사진의 얼굴 인식 데이터와 모든 외부 서비스 내보내기 보관 파일은 제외됩니다."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="모두. Ostler가 이 Mac에서 읽을 수 있는 모든 소스입니다. 사진 얼굴 인식은 직접 선택하기 전까지 꺼져 있습니다."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="사용자 지정. 다음 화면에서 각 소스를 선택합니다. 민감한 소스는 선택하기 전까지 꺼져 있습니다."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="이 데이터 소스를 켜거나 끕니다."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_ARTICLE_9_TITLE="결정 (Y / N)"
# NEEDS REVIEW: Legal consent wording; lawyer should confirm Korean GDPR terminology.
MSG_PROMPT_CONSENT_ARTICLE_9_HELP="제9조 특수 범주 동의(영국 GDPR). 처리의 적법한 근거를 위해 필요합니다."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_VOICE_EU_TITLE="캡처한 통화에서 음성을 인식하시겠습니까?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_VOICE_EU_HELP="화자 인식은 이 Mac에서만 이루어집니다. Creative Machines는 음성 특징 데이터를 받지 않습니다."

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
MSG_PROMPT_CONSENT_ENRICHMENT_TITLE="저장한 항목의 공개 정보를 조회하시겠습니까?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_ENRICHMENT_HELP="Ostler는 책, 영화, 앨범, 장소처럼 찾아낸 항목에 공개 참고 정보를 추가할 수 있습니다. 이를 위해 해당 항목 하나의 이름을 Wikidata, MusicBrainz, OpenLibrary 같은 공개 참고 서비스로 보내고, 받은 답변을 이 Mac에 저장합니다.

Mac에서 나가는 정보: 조회하는 항목의 이름뿐입니다. 그 외에는 아무것도 나가지 않습니다. 메시지, 연락처, 파일, 그 항목을 누가 언급했는지도 나가지 않습니다.

상대 서비스가 볼 수 있는 정보: 사용자의 IP 주소와 요청이 Ostler에서 왔다는 사실입니다. 조회는 Mac에서 해당 서비스로 직접 전달되며 저희 서버를 거치지 않으므로, 누군가 요청했다는 사실이 알려지지 않게 할 방법은 없습니다.

아니요를 선택하면: 조회가 이루어지지 않으며 백그라운드 보강 작업도 아예 설치되지 않습니다. 그 외의 모든 기능은 똑같이 작동합니다. 라이브러리에는 공개 카탈로그가 더하는 정보 없이 직접 넣은 정보만 담깁니다.

지금은 아니요를 선택하고, 나중에 설치 프로그램을 다시 실행하여 마음을 바꿀 수도 있습니다."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE="마지막으로, 외부 데이터의 처리 방식"
# NEEDS REVIEW: Legal text; adjusted article citation style to Korean convention (호/항), lawyer should verify.
MSG_PROMPT_CONSENT_THIRD_PARTY_HELP="외부 서비스에서 가져오는 모든 데이터(Google Takeout, Meta 다운로드, LinkedIn 내보내기 등)는 이 Mac에 남습니다. Ostler는 이를 로컬 지식 그래프에 저장하며 어떤 것도 기기 밖으로 나가지 않습니다.

계속하면, 이미 하드 드라이브에 있는 이메일 메시지와 마찬가지로 이 데이터를 사용자의 기기에서 처리하고 보관하는 책임이 전적으로 본인에게 있음을 이해하고 동의하는 것으로 간주합니다.

법적 고지: 이 Mac으로 가져오는 기록에 대해 사용자는 영국 및 EU 법에 따른 데이터 컨트롤러이자 프로세서입니다(영국 GDPR 제4조 제7호 및 제8호). Creative Machines는 이 데이터를 받지 않으며 컨트롤러가 아닙니다. 개인 및 가정 목적의 처리는 영국/EU GDPR 제2조 제2항 (c)호에 해당합니다.

자세한 내용은 docs.ostler.ai/privacy/third-party-data에서 확인하세요."

# Spoken-capture recording-consent acknowledgement (every region). Shown
# in the Phase-2 consent batch. The HELP string is the substantive text
# GUI installer users read on the decision sheet, so it is self-contained.
# ── Personal-use-only terms (vendor/legal/consent_strings.py PERSONAL_USE_ONLY) ──
# A LICENCE TERM, not an optional consent, which is why it acknowledges rather
# than offering a decline that leaves a half-licensed install. Wording verbatim
# from the versioned ConsentString so the Doctor can flag drift.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TERMS_PERSONAL_USE_HEADING="Ostler의 용도"
MSG_TERMS_PERSONAL_USE_INTRO="Ostler는 한 사람이 자신의 Mac에서 자신의 삶을 이해하도록 만들어졌습니다. 이것이 설계의 전부이며, 데이터가 이 기기 밖으로 나가지 않는 이유입니다."
# NEEDS REVIEW: Licence term wording; legal review advised.
MSG_TERMS_PERSONAL_USE_BUSINESS="업무용으로는 만들어지지 않았습니다. 직원에게 Ostler를 배포하거나, 업무 중에 동료, 고객, 환자, 거래처의 정보를 수집하는 데 사용하지 마세요. 조직이 그렇게 하면 그 조직이 수집한 모든 사람의 정보에 대한 책임을 지게 되며, Ostler는 그 책임을 감당하도록 설계되지 않았습니다."
# NEEDS REVIEW: Replaced awkward '당신' with '사용자' for consistency; legal responsibility wording needs lawyer review.
MSG_TERMS_PERSONAL_USE_RECORDER="녹음하는 주체는 사용자입니다. Ostler는 도구일 뿐입니다. 대화를 녹음하기 전에 현지 법률이 동의를 요구하는 경우, 동의를 받는 것은 사용자의 몫이며, 특정 녹음이 사용자가 계신 곳에서 적법한지는 저희가 알 수 없습니다."
MSG_TERMS_PERSONAL_USE_ASK_HEADING="다음 세 가지는 하지 않도록 부탁드립니다."
MSG_TERMS_PERSONAL_USE_ASK_1="부모나 보호자의 동의 없이 아이를 녹음하지 마세요. 아이는 스스로 동의할 수 없으며, 사용자 본인의 확인이 그 동의를 대신할 수 없습니다."
MSG_TERMS_PERSONAL_USE_ASK_2="진료실, 변호사 상담, 심리 상담, 종교적 고해, 화장실이나 탈의실처럼 사생활이 실제로 보장되어야 하는 장소에서는 녹음하지 마세요."
MSG_TERMS_PERSONAL_USE_ASK_3="현지 법률이 허용하지 않는 경우, Ostler로 다른 사람을 몰래 녹음하지 마세요."
# NEEDS REVIEW: Restored 'natural person' (자연인); licence/liability wording needs lawyer review.
MSG_TERMS_PERSONAL_USE_LEGAL="Ostler는 자연인이 개인적, 비상업적 용도로 사용하도록 허가된 소프트웨어입니다. Creative Machines는 사용자가 Mac에 보관한 정보의 데이터 컨트롤러나 처리자가 아니며, 그 정보를 전혀 수신하지 않고, 특정 녹음이나 캡처가 사용자의 관할권에서 적법하다고 보증하지 않습니다."
MSG_PROMPT_TERMS_PERSONAL_USE_TITLE="Ostler는 개인용입니다"
# NEEDS REVIEW: Terms acceptance text; lawyer should check.
MSG_PROMPT_TERMS_PERSONAL_USE_HELP="Ostler는 사용자 본인의 Mac에서 개인적으로 사용하도록 허가되어 있습니다. 직원에게 배포하거나 직장에서 동료, 고객, 환자를 캡처하는 데 사용하지 마세요. 부모의 동의 없이 아이를 녹음하지 말고, 진료, 변호사 상담, 심리 상담처럼 사생활이 실제로 보장되어야 하는 장소에서는 녹음하지 마세요. 이 약관에 동의하려면 계속을 누르세요."
MSG_INFO_TERMS_PERSONAL_USE_DECLINED="괜찮습니다. 아무것도 설치되지 않았습니다."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_HEADING="음성 대화를 텍스트로 변환"
# NEEDS REVIEW: Legal responsibility statement; lawyer should check.
MSG_CONSENT_SPOKEN_CAPTURE_INTRO="요약: 음성을 캡처하여 텍스트로 변환할 때 법률이 요구하는 동의를 받는 책임은 저희가 아닌 사용자에게 있습니다. 입력과 메시지는 해당되지 않습니다."
# NEEDS REVIEW: Legal statement about recording law; lawyer should check.
MSG_CONSENT_SPOKEN_CAPTURE_LAW="Ostler는 사용자가 캡처한 음성 대화(통화와 회의)를 검색 가능한 텍스트로 변환할 수 있습니다. 이는 사용자가 직접 텍스트로 변환하기로 선택한 음성에만 해당합니다. 사람의 말을 녹음하는 것에 관한 규정은 나라마다 다르며, 독일과 프랑스처럼 참여자 모두가 먼저 동의해야 하는 곳도 있습니다."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_LOCAL="캡처한 음성을 사용자의 Mac에만 보관하더라도 이 의무가 없어지지는 않습니다. Ostler는 음성을 어디로도 보내지 않지만, 현지 법률이 요구하는 경우에는 여전히 동의를 받아야 합니다."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_HEADING="부탁드리는 사항:"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_1="음성 대화를 캡처하기 전에 현지 법률이 요구하는 동의를 받으세요."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_2="함께 있는 사람들에게 음성이 캡처되고 있음을 분명히 알리세요. 예를 들어 시작할 때 미리 알리거나 눈에 보이는 표시등을 계속 켜 두세요."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_3="확실하지 않다면 음성 텍스트 변환을 끄세요. 텍스트 대화는 어느 쪽이든 정상적으로 작동합니다."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_LABEL="사용자의 결정:"
# NEEDS REVIEW: Consent undertaking; lawyer should check legal force.
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_Y="[Y] 이해했으며, 현지 법률이 요구하는 동의를 받겠습니다."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_N="[N] 지금은 안 함 – 음성 텍스트 변환을 끈 상태로 둡니다. (나중에 설정에서 켤 수 있습니다.)"
# NEEDS REVIEW: Legal note citing statutes; lawyer should check.
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL="법적 고지: 말을 녹음하는 행위는 개인정보 보호법과는 별개로 각국 법률의 규제를 받을 수 있습니다. 예를 들어 독일 형법 제201조(Verletzung der Vertraulichkeit des Wortes)나 프랑스 형법 제226-1조가 있습니다. 이 Mac에서 녹음하는 사람으로서 법규 준수는 사용자의 책임입니다. Creative Machines는 사용자의 녹음을 수신하지 않으며 그 당사자도 아닙니다."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_TITLE="음성 대화를 텍스트로 변환할까요?"
# NEEDS REVIEW: Fixed self-honorific '말씀하시거나'; legal text needs lawyer review.
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_HELP="요약: 음성을 캡처하여 텍스트로 변환할 때 법률이 요구하는 동의를 받는 책임은 사용자에게 있습니다. 입력과 메시지는 해당되지 않습니다.

Ostler는 사용자가 캡처한 음성 대화(통화와 회의)를 검색 가능한 텍스트로 변환할 수 있습니다. 이는 사용자가 직접 텍스트로 변환하기로 선택한 음성에만 해당합니다.

부탁드리는 사항:
• 음성을 캡처하기 전에 현지 법률이 요구하는 동의를 받으세요.
• 음성이 캡처되고 있음을 분명히 알리세요. 말로 알리거나 눈에 보이는 표시등을 계속 켜 두세요.
• 확실하지 않다면 끄세요. 텍스트 대화는 어느 쪽이든 정상적으로 작동하며, 나중에 설정에서 켤 수 있습니다.

법적 고지: 말을 녹음하는 행위는 개인정보 보호법과는 별개로 각국 법률의 규제를 받을 수 있습니다. 예를 들어 독일 형법 제201조나 프랑스 형법 제226-1조가 있습니다. 녹음하는 사람으로서 법규 준수는 사용자의 책임입니다. Creative Machines는 사용자의 녹음을 수신하지 않습니다."
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="음성 텍스트 변환은 꺼진 상태로 유지됩니다. 나중에 설정에서 켤 수 있습니다."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_TITLE="설치할 준비가 되셨나요?"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_HELP="약관에 동의하시면 INSTALL을 입력해 확인해 주세요."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="INSTALL 입력"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="Ostler 설치"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="취소"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="확인하려면 INSTALL을 그대로 입력하세요(대소문자는 구분하지 않습니다). 돌아가려면 취소를 클릭하세요."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="iPhone과 Watch 연결"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="Tailscale은 이 Mac에 고정된 비공개 주소를 부여하여, iPhone과 Watch가 어디서든 접속할 수 있게 합니다. 암호화되며 외부에 공개되지 않습니다."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="복구 키를 키체인에 저장할까요?"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="암호화 복구 키를 macOS 키체인에 안전하게 보관합니다."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="그래프 채우는 중"
MSG_HYDRATE_CONTACTS_STARTED="연락처를 그래프로 가져오는 중"
MSG_HYDRATE_CONTACTS_DONE="연락처 %s개를 가져왔습니다"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="연락처 작업이 %s초보다 오래 걸려 기다리기를 멈추고 다음으로 넘어갔습니다. 지금까지 연락처 %s개를 가져왔으며, 나머지는 Ostler가 백그라운드에서 마저 처리합니다."
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="캘린더 기록을 불러오는 중(5년 전부터 1년 후까지)"
MSG_HYDRATE_CALENDAR_DONE="일정 %s개를 가져왔습니다"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  아직 캘린더를 불러오는 중입니다(현재 %s초 경과). 수년간의 일정이 있는 Mac은 시간이 조금 걸립니다."
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="만난 장소를 바탕으로 장소 목록을 만드는 중"
MSG_HYDRATE_PLACES_DONE="장소 섹션을 만들었습니다"
MSG_HYDRATE_PLACES_SKIPPED="아직 위치 정보가 없습니다. 캘린더가 채워지면 장소도 함께 채워집니다"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="장소 생성 중 문제가 발생했습니다. 위치 정보는 있지만 생성된 장소가 없습니다. 장소 페이지가 비어 있을 수 있습니다. %s을(를) 확인하세요"
MSG_HYDRATE_PLACES_ERROR_WARN="장소 생성이 완료되지 않았습니다(예기치 않은 오류). 장소 페이지가 불완전할 수 있습니다. %s을(를) 확인하세요"
MSG_HYDRATE_WIKI_RECOMPILE="위키를 만드는 중입니다. Ostler가 주요 인물, 조직, 주제별로 짧은 요약을 작성하고 있어서, 주소록이 크면 몇 분에서 최대 1시간 정도 걸릴 수 있습니다. 이 작업은 한 번만 진행되며 전부 사용자의 Mac에서 실행되므로 그대로 두셔도 됩니다."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="검색 색인을 확인하는 중(컬렉션 %s개 감지됨)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="탐색 기록을 검색 색인에 불러오는 중"
MSG_INITIAL_HYDRATE_QDRANT_READY="검색 색인 준비 완료(컬렉션 %s개)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="검색 색인은 설치가 끝난 후 백그라운드에서 채워집니다"
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
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="검색 저장소가 실행되었습니다. 아직 없는 컬렉션을 만드는 중: %s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="검색 색인이 불완전합니다. 검색 저장소가 실행 중이고 응답하는데도 %s을(를) 만들 수 없었습니다. Ostler는 계속 작동하며 Doctor에 이 누락이 표시되지만, 문제가 해결될 때까지 검색의 이 부분은 비어 있습니다."
MSG_WARN_QDRANT_COLLECTIONS_MISSING="검색 색인이 불완전합니다. %s을(를) 만들 수 없었습니다. Ostler는 계속 작동하며 Doctor에 이 누락이 표시됩니다."
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="어떤 검색 컬렉션이 있는지 확인할 수 없었습니다(%s). 컬렉션이 없다는 뜻은 아닙니다."
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="검색 색인은 설치가 끝난 후 백그라운드에서 채워집니다(대기 중: %s)"
MSG_HYDRATE_DONE="그래프가 준비되었습니다: 사람 %s명, 이벤트 %s건"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="iCloud가 아직 연락처를 동기화하고 있을 수 있습니다 – 방금 들어온 항목을 가져오기 위해 지금 다시 내보내는 중입니다."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="연락처 앱에서 연락처를 찾을 수 없습니다(로컬 또는 iCloud). 연락처에 항목을 추가한 후 설정에서 다시 실행하세요."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="가져올 iCloud 연락처가 없습니다. 나중에 설정에서 추가할 수 있습니다."
MSG_HYDRATE_SKIPPED_NO_EVENTS="최근 5년간 캘린더 이벤트가 없습니다. 나중에 설정에서 채울 수 있습니다."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="최근 90일간의 이메일을 읽는 중 – 이메일은 이 Mac에만 보관됩니다(이전 기록은 백그라운드에서 채워집니다)"
MSG_HYDRATE_EMAIL_DONE="최근 이메일에서 %s명을 찾았습니다"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="읽을 최근 이메일이 없습니다. Apple Mail에 메일 계정을 추가한 후 나중에 다시 실행할 수 있습니다."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="이메일 리더가 아직 준비되지 않았습니다. Apple Mail에 메일 계정을 추가한 후 나중에 다시 실행할 수 있습니다."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="이메일을 백그라운드에서 계속 불러오는 중입니다. 진행되는 대로 위키가 채워지며, 어디까지 진행되었는지 표시됩니다."
MSG_HYDRATE_EMAIL_HEARTBEAT="  아직 이메일을 읽는 중입니다(현재 %s초 경과). 수년간의 기록이 있는 Mac은 시간이 걸릴 수 있습니다."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="동기화를 시작하도록 Apple Mail을 열까요?"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="메일 계정이 %s개 설정되어 있지만 Apple Mail이 아직 메시지를 가져오지 않았습니다. 지금 메일 앱을 열고 동기화되는 동안 기다릴 수 있습니다."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="동기화를 시작하도록 캘린더를 열까요?"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="캘린더 계정이 %s개 설정되어 있지만 캘린더 앱에 저장된 이벤트가 아직 없습니다. 지금 캘린더를 열고 iCloud에서 동기화되는 동안 기다릴 수 있습니다."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="동기화를 시작하도록 연락처를 열까요?"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="연락처 계정이 %s개 설정되어 있지만 연락처 앱에 저장된 항목이 아직 없습니다. 지금 연락처를 열고 iCloud에서 동기화되는 동안 기다릴 수 있습니다."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="%s 동기화가 시작되기를 기다리는 중(최대 %s초)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="%s 동기화를 계속 기다리는 중(%s초 경과, %s초 남음). 새로 로그인한 경우 iCloud의 첫 동기화에 몇 분이 걸릴 수 있습니다."
MSG_OK_APP_HAS_POPULATED="%s의 로컬 저장소가 채워졌습니다. 계속 진행합니다."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="대기 시간 내에 %s 동기화를 확인하지 못했습니다. 계속 진행합니다. 나중에 설정에서 데이터 가져오기를 다시 실행할 수 있습니다."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="확인된 Apple Mail 계정: %s. 메시지를 가져오기 시작하도록 메일 앱을 한 번 열어 주세요."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="확인된 캘린더 계정: %s. 이벤트가 동기화되도록 캘린더 앱을 한 번 열어 주세요."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="확인된 연락처 계정: %s. 주소록이 동기화되도록 연락처 앱을 한 번 열어 주세요."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="연락처를 읽을 수 없습니다. Ostler는 전체 디스크 접근 권한을 통해 연락처를 읽습니다. 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한에서 허용한 다음, 설정에서 하이드레이션을 다시 실행하세요. 백그라운드에서 계속 다시 시도합니다."
MSG_HYDRATE_CONTACTS_PENDING="연락처 앱이 아직 동기화되지 않았습니다. 연락처를 한 번 열고 동기화가 끝날 때까지 기다린 다음, 설정에서 하이드레이션을 다시 실행하세요."
MSG_HYDRATE_CONTACTS_READ_FAILED="연락처가 이 Mac에 있지만 Ostler가 가져온 연락처는 0개입니다. 예상하지 못한 결과입니다. 가져오기는 백그라운드에서 자동으로 다시 시도합니다. 계속 같은 상태라면 설정에서 하이드레이션을 다시 실행하거나 설치 로그를 확인하세요."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="Ostler가 백그라운드에서 계속 확인하며, iCloud 동기화가 끝나면 연락처를 자동으로 가져옵니다."
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="전화번호가 있는 연락처 %s개를 가져왔지만 이메일 주소는 거의 없습니다(전화번호 %s개, 이메일 %s개). 보통 연락처 리더가 이메일을 누락했을 때 나타나는 현상입니다. 연락처는 계속 사용할 수 있습니다. %s을(를) 확인하고 문제가 해결되면 설정에서 하이드레이션을 다시 실행하세요."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="새 연락처를 가져왔습니다. 백그라운드에서 위키를 다시 구성하는 중입니다."
MSG_HYDRATE_CALENDAR_PENDING="캘린더 앱이 아직 일정을 동기화하지 않았습니다. 캘린더를 한 번 열고 동기화가 끝날 때까지 기다린 다음, 설정에서 하이드레이션을 다시 실행하세요."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="이번에는 캘린더를 읽을 수 없었습니다(캘린더가 비어 있는 것이 아니라 추출기에서 오류가 보고되었습니다). 다른 데이터에는 영향이 없습니다. %s을(를) 확인한 다음, 설정에서 하이드레이션을 다시 실행하세요."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="WhatsApp 기록을 읽는 중 – 메시지는 이 Mac에만 보관됩니다"
MSG_HYDRATE_WHATSAPP_DONE="WhatsApp 대화에서 %s명을 찾았습니다"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="WhatsApp 대화를 읽었지만 인물 그래프에 기록하지 못했습니다(종료 코드 %s). Ostler가 다시 시도합니다. 상세 정보: %s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="읽을 WhatsApp 대화가 없습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktop이 설치되어 있지 않습니다. Mac App Store에서 설치한 다음 설정에서 다시 실행하세요."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="WhatsApp 리더가 아직 준비되지 않았습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="WhatsApp을 백그라운드에서 계속 불러오는 중입니다. 위키는 진행에 따라 채워지며 진행 상황도 함께 표시됩니다."

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
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="WhatsApp 연락처가 이미 인물 그래프에 있습니다(식별자 %s개). 다시 읽을 항목이 없습니다."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="WhatsApp 연락처를 이전에 읽었지만 인물 그래프에 더 이상 남아 있지 않습니다. 다시 읽는 중입니다."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="WhatsApp 연락처가 아직 인물 그래프에 있는지 확인하지 못했습니다. 있다고 가정하지 않고 다시 읽는 중입니다."

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="AI 채팅 기록을 읽는 중 – 대화는 이 Mac에만 보관됩니다"
MSG_HYDRATE_AICONV_DONE="AI 대화 %s개를 위키에 저장했습니다"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="AI 대화 리더가 아직 준비되지 않았습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="읽을 AI 채팅 기록이 없습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="AI 채팅을 백그라운드에서 계속 불러오는 중입니다. 위키는 진행에 따라 채워지며 진행 상황도 함께 표시됩니다."
MSG_HYDRATE_AICONV_HEARTBEAT="  AI 채팅 기록을 계속 읽는 중입니다(지금까지 %s초). 기록이 많으면 몇 분 걸릴 수 있습니다."


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="인터넷 사용 기록을 가져오는 중 – 방문 기록은 이 Mac에만 보관됩니다"
MSG_HYDRATE_BROWSING_DONE="인터넷 사용 기록 %s페이지를 가져왔습니다"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="민감한 페이지(은행, 의료 등)로 분류된 %s페이지를 건너뛰었습니다"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="가져올 인터넷 사용 기록이 없습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="인터넷 사용 기록 리더가 아직 준비되지 않았습니다. 나중에 설정에서 다시 실행할 수 있습니다."

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
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="인터넷 사용 기록을 이미 가져왔습니다(%s페이지). 다시 가져올 항목이 없습니다."
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="가져올 인터넷 사용 기록 내보내기 파일을 찾을 수 없습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="인터넷 사용 기록을 이전에 가져왔지만 검색 색인에 더 이상 남아 있지 않습니다. 다시 가져오는 중입니다."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="인터넷 사용 기록이 아직 검색 색인에 있는지 확인하지 못했습니다. 있다고 가정하지 않고 다시 가져오는 중입니다."
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="인터넷 사용 기록이 검색 색인에 반영되지 않아 방문 기록 페이지가 비어 있게 됩니다. 설정에서 다시 실행하거나 Doctor를 여세요."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="인터넷 사용 기록을 백그라운드에서 계속 불러오는 중입니다. 위키는 진행에 따라 채워지며 진행 상황도 함께 표시됩니다."

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="이메일 선호도를 불러오는 중입니다. 이 작업은 이 Mac에서만 이루어지며 몇 분 걸릴 수 있습니다."
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="이메일 기록에서 선호도 %s개를 불러왔습니다"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="설정된 이메일 선호도 파일이 없습니다. 불러올 항목이 없습니다."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="%s에 이메일 선호도 파일이 없습니다. 불러올 항목이 없습니다."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="선호도 파이프라인이 아직 준비되지 않았습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="이메일 환경설정을 백그라운드에서 계속 불러오는 중입니다. 위키는 진행되는 대로 채워지며, 어디까지 진행되었는지 보여 드립니다."
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  이메일 환경설정을 계속 불러오는 중입니다(지금까지 %s초). 기록이 많으면 몇 분 걸릴 수 있습니다."

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="이메일 환경설정을 이미 불러왔습니다(항목 %s개). 다시 불러올 필요가 없습니다."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="이메일 환경설정을 이전에 불러왔지만 검색 색인에 더 이상 남아 있지 않습니다. 다시 불러옵니다."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="이메일 환경설정이 검색 색인에 아직 있는지 확인하지 못했습니다. 있다고 가정하지 않고 다시 불러옵니다."

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
MSG_HYDRATE_PREFERENCES_DONE="환경설정 %s개를 가져왔습니다"
MSG_HYDRATE_PREFERENCES_ENRICHED="그중 %s개를 공개 참조 데이터로 보강했습니다"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="환경설정 %s개를 가져왔지만 음식, 음악, 직업 분류에 들어간 항목이 없습니다. 음식 및 음악 위키 페이지가 비어 있게 됩니다."
MSG_WARN_PREFS_HEADLINE_HINT="음악/음식 내보내기 파일(Spotify, Apple Music, Uber Eats, Google Takeout)이 없었거나 데이터가 분류되지 않았을 가능성이 큽니다. 해당 내보내기 파일을 추가하고 설정에서 다시 실행한 다음 위키를 다시 빌드하세요."
MSG_WARN_PREFS_UNCATEGORISED="환경설정 %s개(전체 %s개 중 %s%%)에 카테고리가 없어 어떤 주제 페이지에도 표시되지 않습니다. 원본 내보내기 형식을 확인하세요."

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="환경설정 보강 기능 설정 중"
MSG_CM019_SETUP_DONE="환경설정 보강 준비 완료"
MSG_CM019_SETUP_FAILED="환경설정 보강 설정을 완료하지 못했습니다. 문제가 해결되면 환경설정 페이지가 채워지며, Ostler의 나머지 기능에는 영향이 없습니다."
MSG_CM019_SETUP_SKIPPED="환경설정 보강 파이프라인이 포함되어 있지 않아 지금은 건너뜁니다."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="iMessage 기록을 읽는 중 – 메시지는 이 Mac에만 남아 있습니다"
MSG_HYDRATE_IMESSAGE_DONE="iMessage 기록에서 %s명을 찾았습니다"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="읽을 iMessage 기록이 없습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="iMessage 리더가 아직 준비되지 않았습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="iMessage를 백그라운드에서 계속 불러오는 중입니다. 위키는 진행되는 대로 채워지며, 어디까지 진행되었는지 보여 드립니다."
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  iMessage 기록을 계속 읽는 중입니다(지금까지 %s초). 메시지 기록이 많으면 몇 분 걸릴 수 있습니다."

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="iMessage 연락처가 이미 인물 그래프에 있습니다(식별자 %s개). 다시 읽을 필요가 없습니다."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="iMessage 연락처를 이전에 읽었지만 인물 그래프에 더 이상 남아 있지 않습니다. 다시 읽습니다."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="iMessage 연락처가 인물 그래프에 아직 있는지 확인하지 못했습니다. 있다고 가정하지 않고 다시 읽습니다."

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="Apple 메모를 읽는 중 - 메모는 이 Mac에만 남아 있습니다"
MSG_HYDRATE_APPLE_NOTES_DONE="메모 %s개를 지식 베이스에 추가했습니다"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="읽을 Apple 메모가 없습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="Apple 메모가 이미 지식 베이스에 있습니다. 건너뜁니다."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="지식 검색에서 Apple 메모가 꺼져 있습니다. 설정에서 켤 수 있습니다."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="지식 가져오기 기능이 아직 준비되지 않았습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="Apple 메모를 백그라운드에서 계속 불러오는 중입니다. 지식 베이스는 진행되는 대로 채워지며, 어디까지 진행되었는지 보여 드립니다."
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  Apple 메모를 계속 읽는 중입니다(지금까지 %s초). 메모가 많으면 몇 분 걸릴 수 있습니다."

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="Apple 메모가 이미 지식 베이스에 있습니다(항목 %s개). 다시 읽을 필요가 없습니다."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="Apple 메모를 이전에 추가했지만 지식 베이스에 더 이상 남아 있지 않습니다. 다시 추가합니다."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="Apple 메모가 지식 베이스에 아직 있는지 확인하지 못했습니다. 있다고 가정하지 않고 다시 추가합니다."

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="미리 알림을 읽는 중 - 미리 알림은 이 Mac에만 남아 있습니다"
MSG_HYDRATE_REMINDERS_DONE="미리 알림 %s개를 지식 베이스에 추가했습니다"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="읽을 미리 알림이 없습니다. 나중에 설정에서 다시 실행할 수 있습니다."
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="미리 알림이 이미 지식 베이스에 있습니다. 건너뜁니다."
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="지식 검색에서 미리 알림이 꺼져 있습니다. 설정에서 켤 수 있습니다."
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="지식 가져오기 기능이 아직 준비되지 않았습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="미리 알림을 백그라운드에서 계속 불러오는 중입니다. 지식 베이스는 진행되는 대로 채워지며, 어디까지 진행됐는지 보여 줍니다."
MSG_HYDRATE_REMINDERS_HEARTBEAT="  미리 알림을 계속 읽는 중입니다(지금까지 %s초). 미리 알림 목록이 크면 몇 분 걸릴 수 있습니다."

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="미리 알림이 이미 지식 베이스에 있습니다(항목 %s개). 다시 읽을 필요가 없습니다."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="미리 알림이 이전에 추가되었지만 지식 베이스에 더 이상 없습니다. 다시 추가합니다."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="미리 알림이 아직 지식 베이스에 있는지 확인할 수 없었습니다. 있다고 가정하지 않고 다시 추가합니다."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="검색을 위해 사람 목록 색인 중"
MSG_HYDRATE_PEOPLE_DONE="검색을 위해 %s명을 색인했습니다"
MSG_HYDRATE_PEOPLE_PARTIAL="지금까지 %s/%s명을 검색용으로 색인했습니다. 나머지는 아직 검색할 수 없으며, Ostler가 자동으로 다시 시도합니다."
MSG_HYDRATE_PEOPLE_FAILED="이번에는 사람 목록을 검색용으로 색인하지 못했습니다(그래프 저장소가 응답하지 않음). Ostler가 자동으로 다시 시도합니다. 세부 정보: %s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="아직 색인할 사람이 없습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="사람 색인기가 아직 준비되지 않았습니다. 나중에 설정에서 다시 실행할 수 있습니다."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="사람 목록을 백그라운드에서 계속 색인하는 중입니다. 검색은 진행되는 대로 채워지며, 위키에서 어디까지 진행됐는지 볼 수 있습니다."

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="사람 목록이 이미 검색용으로 색인되어 있습니다(%s명). 다시 색인할 필요가 없습니다."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="사람 목록이 이전에 색인되었지만 검색 색인에 더 이상 없습니다. 다시 색인합니다."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="사람 목록이 아직 검색 색인에 있는지 확인할 수 없었습니다. 있다고 가정하지 않고 다시 색인합니다."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="폴더 접근 요청이 세 번 표시됩니다"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="명령어 줄 도구 대화상자가 이 윈도우 앞에 나타났습니다. 대화상자에서 설치를 클릭한 다음 여기로 돌아오세요(몇 초 기다리면 이 윈도우를 다시 앞으로 가져옵니다). 아래 질문에 답하는 동안 도구는 백그라운드에서 다운로드되며, 진행이 막히는 것은 없습니다."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="권한 필요: iMessage 자동화"
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="Ostler가 이제 Messages.app과 통신할 권한을 macOS에 요청합니다. macOS에 \"'OstlerInstaller'이(가) '메시지'을(를) 제어하기 위해 접근하려고 합니다\"라는 팝업이 표시되면 허용을 클릭하세요. 그래야 어시스턴트가 대신 iMessage를 보내고 받을 수 있습니다. 이 권한이 없으면 iMessage 메시지가 아무 알림 없이 전송되지 않습니다. 한 번만 허용하면 되며, 나중에 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 변경할 수 있습니다."

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="복구 키"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="지금 적어 두거나 인쇄하세요. 암호를 잃어버리고 키체인에도 접근할 수 없게 되었을 때 다시 들어올 수 있는 유일한 방법입니다. Ostler는 이 키를 대신 복구해 드릴 수 없습니다. 키는 이 Mac을 벗어나지 않으며 어떤 서버에도 저장되지 않습니다."
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="안전한 곳에 저장했습니다"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="클립보드에 복사"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="PDF로 저장..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="프린트..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="계속"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Ostler 복구 키.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="Ostler 복구 키"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="복구 키를 클립보드에 복사했습니다"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="복구 키를 %s에 저장했습니다"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="iPhone 페어링"
MSG_INFO_PAIR_IPHONE_HELP="iPhone에서 Ostler 앱을 열고 이 QR 코드를 스캔하여 이 Hub에 연결하세요. 나중에 Hub의 설정 메뉴에서 페어링할 수도 있습니다."
MSG_INFO_PAIR_IPHONE_FETCHING="페어링 코드 생성 중..."
MSG_INFO_PAIR_REFRESH="코드 새로 고침"
MSG_ERR_PAIR_FETCH_FAILED="아직 Ostler 게이트웨이에 연결할 수 없습니다. 시작하는 중일 수 있습니다. 새로 고침을 클릭하여 다시 시도하세요."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agent가 설치 프로그램에 포함되어 있지 않습니다. 일일 브리핑과 WhatsApp 연결 유지 LaunchAgent가 로드되지 않습니다."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="위키 재컴파일 스크립트가 설치 프로그램에 포함되어 있지 않습니다. 위키가 자동으로 업데이트되지 않습니다."

# F3 - legal package missing
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="legal 패키지가 설치 프로그램에 포함되어 있지 않습니다. 다시 설치하기 전까지 Article 9 / WhatsApp / 음성 동의 확인 단계에서 ModuleNotFoundError가 발생합니다."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="Google Workspace CLI v%s을(를) %s에 설치했습니다"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI v%s이(가) 이미 설치되어 있어 그대로 둡니다"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="Google Workspace CLI를 지원하지 않는 CPU 아키텍처입니다. Gmail / Google Calendar 기능이 제한됩니다."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl을 사용할 수 없어 Google Workspace CLI 설치를 건너뛰었습니다. Gmail / Google Calendar 기능이 제한됩니다."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="%s에서 Google Workspace CLI를 다운로드할 수 없습니다."
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="Google Workspace CLI SHA256이 일치하지 않습니다(예상값 %s, 실제값 %s). 이 바이너리 설치를 중단합니다."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="Google Workspace CLI 압축 파일을 풀 수 없습니다."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="Google Workspace CLI가 %s에 설치되었지만 --version 확인에 실패했습니다."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="iCloud / CalDAV 캘린더 브리지가 %s에 설치되었습니다."
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="%s의 iCloud / CalDAV 캘린더 브리지를 실행할 수 없습니다. 캘린더에서 일정이 표시되지 않습니다."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh가 설치 프로그램에 포함되어 있지 않습니다. 다음 네트워크 연결 시 기기 등록을 다시 시도하는 기능이 비활성화됩니다."

MSG_WARN_EMBED_DIMS_UNREADABLE="상태 점검에서 임베딩 차원 수를 읽을 수 없습니다. 메모리는 768차원으로 설정되어 있습니다. 기억 검색이 이상하게 동작하면 임베딩 모델을 확인하세요."
MSG_FAIL_EMBED_DIMS="임베딩 모델이 %s차원 벡터를 반환했지만 Ostler는 %s차원으로 설정되어 있습니다. 메모리에 일치할 수 없는 벡터가 저장됩니다. 임베딩 모델을 확인한 후 다시 실행하세요."

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
MSG_PROGRESS_REBOOT_SELFHEAL="재부팅 자동 복구 설정 중"
MSG_INFO_AUTOLOGIN_EXPLAIN="Ostler는 항상 켜져 있는 Hub이므로 정전이나 재시동 후에도 키보드 앞에 아무도 없이 다시 시작되어야 합니다. 이를 위해서는 이 Mac이 스스로 로그인해야 하며, macOS가 스스로 로그인하려면 %s의 로그인 암호가 이 Mac에 저장되어 있어야 합니다.

암호를 저장하면 이 Mac의 보안이 약해집니다. 암호는 암호화되는 것이 아니라 뒤섞여 저장되므로, 이 Mac의 관리자 계정을 사용할 수 있거나 디스크를 꺼내 다른 곳에서 읽을 수 있는 사람은 이를 원래 암호로 되돌릴 수 있습니다. 입력하기 전에 저장 위치를 정확히 보여 드립니다.

허용하지 않으면 아무것도 저장되지 않으며 다른 변경도 없습니다. 정전 후에는 평소처럼 로그인하면 되고, Ostler 서비스는 세션과 함께 시작됩니다. 나중에 시스템 설정 > 사용자 및 그룹 > 자동 로그인에서 변경할 수 있습니다."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_AUTOLOGIN_CONSENT="재시동 후 스스로 로그인할 수 있도록 로그인 암호를 이 Mac에 저장할까요? [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="Ostler는 이 암호를 이 Mac의 /etc/kcpassword 파일에 기록합니다. 암호는 모든 Mac에서 동일하고 공개적으로 문서화된 고정 패턴으로 뒤섞이므로 암호화가 아니며 원래대로 되돌릴 수 있습니다. 이 Mac의 관리자 계정을 사용할 수 있거나 디스크를 꺼내 다른 곳에서 읽을 수 있는 사람은 해당 파일을 %s의 로그인 암호로 되돌릴 수 있습니다.

FileVault를 사용하면 시동 암호 없이는 디스크를 전혀 읽을 수 없으므로 이를 막을 수 있습니다. 같은 이유로 FileVault는 자동 로그인도 막기 때문에, Ostler는 FileVault가 꺼져 있을 때만 이 기능을 제공합니다.

설치 프로그램이 직접 제어하는 부분: 암호를 입력할 때 화면에 표시하지 않으며 설치 로그에도 기록하지 않습니다. 뒤섞인 파일이 설치 프로그램이 만드는 유일한 사본입니다.

자동 로그인을 건너뛰려면 비워 두세요."
MSG_PROMPT_AUTOLOGIN_PASSWORD="%s의 로그인 암호"
MSG_OK_AUTOLOGIN_CONFIGURED="%s의 자동 로그인이 켜졌으며, 해당 로그인 암호는 이제 이 Mac의 /etc/kcpassword에 뒤섞인 형태로 저장되어 있습니다. 재시동 후 이 Mac은 스스로 로그인하고 Ostler 서비스가 해당 세션과 함께 시작됩니다. 되돌리려면 시스템 설정 > 사용자 및 그룹에서 자동 로그인을 끄세요."
MSG_INFO_AUTOLOGIN_ALREADY="%s의 자동 로그인이 이미 설정되어 있어, 이 Mac에는 해당 로그인 암호가 /etc/kcpassword에 이미 저장되어 있습니다. 둘 다 그대로 둡니다. 되돌리려면 시스템 설정 > 사용자 및 그룹에서 자동 로그인을 끄세요."
MSG_INFO_AUTOLOGIN_DECLINED="자동 로그인이 켜지지 않았으며 암호도 저장되지 않았습니다. 재시동이나 정전 후에는 평소처럼 로그인하면 Ostler 서비스가 세션과 함께 시작됩니다."
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="자동 로그인 설정을 건너뜁니다. 여기서는 로그인 암호를 요청할 방법이 없으며 아무것도 저장되지 않았습니다. 사람이 없어도 이 Mac이 재시동 후 복구되길 원하면 나중에 시스템 설정 > 사용자 및 그룹에서 자동 로그인을 켤 수 있습니다. 이 경우 로그인 암호가 되돌릴 수 있는 뒤섞인 형태로 Mac에 저장되므로, 켜기 전에 내용을 충분히 읽어 보세요."
MSG_WARN_AUTOLOGIN_NO_PASSWORD="암호가 입력되지 않아 자동 로그인이 켜지지 않았으며 아무것도 저장되지 않았습니다. 나중에 사용하려면 시스템 설정 > 사용자 및 그룹에서 자동 로그인을 켜세요."
MSG_WARN_AUTOLOGIN_FAILED="자동 로그인을 켤 수 없습니다(%s). 다시 시도하지 않습니다. 이 Mac에 /etc/kcpassword가 있다면 기능이 꺼져 있어도 해당 로그인 암호가 뒤섞인 형태로 들어 있습니다. 터미널에서 sudo rm /etc/kcpassword 명령으로 삭제할 수 있습니다. 다시 시도하려면 시스템 설정 > 사용자 및 그룹에서 자동 로그인을 켜세요."
MSG_WARN_AUTOLOGIN_FILEVAULT="FileVault가 켜져 있어, 이 Mac은 누군가 로그인하기 전에 부팅 화면에서 암호를 요구해 디스크를 잠금 해제합니다. 자동 로그인은 이에 응답할 수 없으므로, 정전 후 이 Mac은 누군가 암호를 입력할 때까지 FileVault 잠금 해제 화면에서 대기합니다. 자동 로그인은 켜지지 않았으며 암호도 저장되지 않았습니다. 이는 두 방식 중 더 안전한 쪽입니다. FileVault가 켜져 있는 동안은 무인 재시동 복구가 불가능하지만, 그 대신 암호를 모르는 사람은 디스크를 읽을 수 없습니다."

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
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="Ostler가 시스템 설정을 열 수 없습니다. 시스템 설정을 직접 열고 개인정보 보호 및 보안 > 전체 디스크 접근 권한으로 이동하세요."
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="Ostler는 위키와 검색을 컨테이너에서 실행하므로 이 Mac에 컨테이너 엔진(Colima)을 설치하고 관리합니다. 이 엔진이 제거되거나 설정이 바뀌면 위키와 검색이 작동하지 않습니다. Ostler가 알려 드리고 다시 시작을 시도합니다."
MSG_INFO_ENGINE_ALREADY_PRESENT="이 Mac에는 컨테이너 엔진이 이미 설치되어 있습니다. Ostler는 자체 엔진을 설치하지 않고 기존 엔진을 사용하며, 이를 관리하거나 수정하지 않습니다."

# ── Consent screens, terminal/log path (lifted from inline echo, l10n) ──
# Printed by _ostler_tty in install.sh: each value is a printf format whose
# %s pairs switch bold/dim on and off. Keep every %s, every line break and
# the [Y]/[N] answer tokens. Legal wording: translations ship needs_review.

# install.sh consent screen (TTY/log path), lifted from install.sh:11865. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_EU_01="
%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s

  %s마지막으로 – Ostler가 Mac에서 살펴볼 항목%s

  Ostler는 개인 비서이므로, 이 Mac에 보관된 여러분 생활의
  일부를 살펴보며 작동합니다. 그중에는 민감한 정보도
  있습니다. 영국과 EU의 개인정보 보호법에 따라, 어떤 정보든
  다루기 전에 쉬운 말로 먼저 여러분께 동의를 구해야 합니다.

  %s데이터가 있는 곳.%s Ostler가 읽는 모든 내용은 여러분만 열 수 있는
  암호화된 폴더에 담겨 이 Mac에만 남습니다. 저희는 사본을 받지 않습니다.
  여러분의 데이터에는 \"클라우드\" 버전이 없습니다.

  %s처리 대상.%s 켜는 커넥터에 따라 Ostler는 법에서
  \"특수 범주\" 데이터로 보는 다음과 같은 정보를
  처리할 수 있습니다.

    - 이메일, 메시지, 캘린더 항목 또는 텍스트로 옮긴 대화에
      언급된 건강 정보
    - 종교적 또는 철학적 신념
    - 성적 지향
    - 노동조합 가입 여부
    - 통화에서 *누가* 말하는지 표시하는 용도(화자 식별)로만
      쓰는 음성 캡처. 음성으로 기분, 감정, 정서, 스트레스 또는
      거짓말 여부를 추측하지 않습니다.
    - 범죄 행위에 관한 언급 – 본인 또는 다른 사람의 것

  저희는 감정 인식을 하지 않습니다. 이 방침이 바뀌는 경우에는
  새로운 동의 화면에서 별도로 다시 여쭙겠습니다.

  이 모든 정보는 여러분의 Mac에만 남습니다. ostler.ai/privacy의
  개인정보 처리방침에 명시된 특정한 경우를 제외하고는, 어느 것도
  Creative Machines나 제3자에게 전송되지 않습니다.

  %s언제든 마음을 바꾸실 수 있습니다.%s 설정에서 커넥터를 개별로
  끄거나, \"Ostler 재설정\"으로 모든 것을 삭제하거나, 터미널에서
  ostler-uninstall을 실행해 완전히 제거할 수 있습니다.

  동의를 철회하면 그 시점부터 처리가 중단됩니다. 이전 동의에
  따라 Ostler가 이미 수행한 작업이 취소되지는 않습니다.

  결정해 주세요:

    [Y] Ostler가 개인 비서를 실행할 목적으로, 위의 개인정보
        범주를 이 Mac에서 로컬로 처리하는 데 동의합니다.
        (설치를 계속합니다)

    [N] 동의하지 않습니다. (설치 프로그램을 취소하고 제거합니다.
        이 Mac에는 아무것도 저장되지 않습니다)

  %s법적 고지: 여러분은 Ostler가 이 Mac에서 처리하는 모든
  특수 범주 데이터의 개인정보 처리자(data controller)입니다
  (영국 GDPR 제4조(7)). Creative Machines는 이 데이터를 전혀
  받지 않습니다. 위에서 하신 명시적 동의(영국 GDPR 제9조(2)(a))가
  처리의 적법한 근거입니다. 개인적 용도 및 가정 내 용도의 경우
  제2조(2)(c)에 따라 적용 범위가 추가로 제한됩니다. 이 동의는
  언제든 철회할 수 있으며, 철회하더라도 이미 이루어진
  처리에는 영향을 주지 않습니다.%s
"
# install.sh consent screen (TTY/log path), lifted from install.sh:11973. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_EU_02="  괜찮습니다. 설정을 중단했으며 기존 Ostler 데이터는
  그대로 두었습니다."
# install.sh consent screen (TTY/log path), lifted from install.sh:11976. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_EU_03="  괜찮습니다. 아무것도 설치되지 않았고 Mac에는
  아무것도 기록되지 않았습니다."
# install.sh consent screen (TTY/log path), lifted from install.sh:11979. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_EU_04="
  마음이 바뀌면 설치 프로그램을 다시 실행하세요."
# install.sh consent screen (TTY/log path), lifted from install.sh:11985. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_EU_05="  Y 또는 N으로 답해 주세요."
# install.sh consent screen (TTY/log path), lifted from install.sh:12031. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_01="  %s통화 중 음성 인식(Ostler iPhone 앱)%s

  Ostler iPhone Companion 앱은 각 음성의 숫자 지문을
  iPhone의 암호화된 저장소에 보관하여, 텍스트로 옮긴 대화에
  누가 말하는지를 \"Sam\", \"Alex\"처럼 표시할 수 있습니다.
  이 지문은 iPhone을 벗어나지 않으며 이 Mac이나 저희에게
  전송되지 않습니다. Mac은 텍스트 표시(이름)만 받고 지문은
  받지 않습니다. 영국과 EU의 개인정보 보호법상 음성 지문은
  생체 정보이므로, Companion이 음성을 등록하기 전에
  먼저 동의를 구합니다.

  %s하는 일.%s 여러분이 캡처한 통화에서 *누가* 말하는지 식별합니다.
  %s하지 않는 일.%s 음성으로 기분, 감정, 정서, 스트레스 등
  추측되는 심리 상태를 감지하지 않습니다.

  지문은 iPhone에만 남습니다. 저희도, 이 Mac도
  지문을 받지 않습니다. iPhone 앱의
  설정 -> 음성 인식에서 언제든 끌 수 있으며,
  끄면 휴대폰에 이미 저장된 지문이 모두 삭제됩니다.
  iPhone Companion을 설치하지 않으면 음성 지문은
  만들어지지 않습니다.

  %s법적 고지: Ostler Companion 앱이 iPhone에 저장하는
  음성 지문은 영국 GDPR 제9조(1)에 따른 생체 정보입니다.
  위에서 하신 명시적 동의(제9조(2)(a))가 처리의 적법한
  근거입니다. 여러분은 개인정보 처리자(제4조(7))이며,
  Creative Machines는 지문을 전혀 받지 않고, 지문은
  이 Mac으로도 전송되지 않습니다. 개인적 용도 및
  가정 내 용도의 경우 제2조(2)(c)에 따라 적용 범위가
  추가로 제한됩니다. iPhone 앱에서 동의를 철회하면
  저장된 지문이 삭제됩니다.%s
"
# install.sh consent screen (TTY/log path), lifted from install.sh:12102. %s pairs are bold/dim on and off.
# NEEDS REVIEW: Consent and GDPR legal wording; a lawyer should check (e.g. '데이터 컨트롤러' vs Korean legal term '개인정보처리자'). Placeholders and tokens intact.
MSG_TTY_CONSENT_MORE_02="
%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s

  %sMac에 있는, 나만의 것이 아닌 데이터에 관하여%s

  Ostler는 다른 사람에 관한 정보가 담긴 당신 삶의 일부를
  읽습니다. 그들이 보낸 이메일, 그들이 쓴 메시지, 사진 속
  얼굴, 연락처 정보, 캘린더 참석자 등입니다. 이는 자연스러운
  일입니다. 받은 편지함도, 연락처도, 있는 그대로의 당신의
  삶이기 때문입니다.

  모든 것은 이 Mac에만 저장됩니다. Creative Machines는 그 어떤
  것도 받지 않습니다. 이를 보관하는 클라우드 계정도 없습니다.

  %s계속하기 전에 다음 내용을 이해해 주세요.%s

    - 당신은 개인 주소록, 개인 일기, 일지처럼 이 기록을 스스로를
      위해 보관합니다. Ostler는 이미 가지고 있는 정보를 정리하고
      검색하도록 돕는 도구입니다. 무엇을 보관하고 무엇을 삭제할지는
      당신이 결정합니다.

    - 삭제 요청. 기록이 있는 사람이 삭제를 요청하면 Ostler에서 그
      사람을 완전히 삭제할 수 있습니다(설정 -> 사람 -> 사람 삭제).
      삭제하면 위키, 그래프, 검색 색인, 어시스턴트의 기억에서 그
      사람의 데이터가 제거됩니다.

    - 어떤 것도 Mac 밖으로 나가지 않습니다. 저희에게도, 클라우드에도,
      제3자에게도 전송되지 않습니다. 단, ostler.ai/privacy의
      개인정보 처리방침에 명시된 특정 경우는 예외입니다(주로 개인
      정보가 아닌 질문의 선택적 클라우드 라우팅, 소프트웨어 업데이트
      확인, 공개 메타데이터 보강).

  자세한 내용은 docs.ostler.ai/privacy/third-party-data에서
  확인하세요.

  결정해 주세요.

    [Y] 이해했습니다. 계속합니다.
    [N] 동의하지 않습니다. (취소하고 설치 프로그램을 제거하며,
        이 Mac에는 아무것도 저장되지 않습니다)

  %s법적 고지: 이 Mac에 보관하는 기록에 대해 당신은 영국 및 EU
  법에 따른 데이터 컨트롤러입니다(UK GDPR 제4조 7항).
  Creative Machines는 이 데이터를 전혀 받지 않으며 컨트롤러가
  아닙니다. 개인 및 가사 목적의 처리는 UK/EU GDPR 제2조 2항
  (c)호에 해당합니다.%s
"
# install.sh consent screen (TTY/log path), lifted from install.sh:12175. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_03="  괜찮습니다. 설치가 중단되었으며 기존 Ostler 데이터는
  그대로 유지되었습니다."
# install.sh consent screen (TTY/log path), lifted from install.sh:12178. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_04="  괜찮습니다. 아무것도 설치되지 않았으며 Mac에
  아무것도 기록되지 않았습니다."
# install.sh consent screen (TTY/log path), lifted from install.sh:12181. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_05="
  마음이 바뀌면 설치 프로그램을 다시 실행하세요."
# install.sh consent screen (TTY/log path), lifted from install.sh:12187. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_06="  Y 또는 N으로 답해 주세요."
# install.sh consent screen (TTY/log path), lifted from install.sh:12214. %s pairs are bold/dim on and off.
MSG_TTY_CONSENT_MORE_07="
%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s
"
# install.sh consent screen (TTY/log path), lifted from install.sh:12253. %s pairs are bold/dim on and off.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TTY_CONSENT_MORE_08="  Y 또는 N으로 답해 주세요."
# install.sh consent screen (TTY/log path), lifted from install.sh:12293. %s pairs are bold/dim on and off.
MSG_TTY_CONSENT_MORE_09="
%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s
"
