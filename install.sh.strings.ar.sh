#!/usr/bin/env bash
# install.sh.strings.en-GB.sh translated to ar by l10n/ostler_l10n.py.
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

MSG_STEP_CHECKING_PREREQUISITES="جارٍ التحقق من المتطلبات الأساسية"
MSG_STEP_RUNNING_HEALTH_CHECK="جارٍ إجراء فحص السلامة"
# F2: the end-of-install step that holds the Tailscale browser sign-in.
MSG_STEP_TAILSCALE_SIGNIN="اربط iPhone وApple Watch"
# NEEDS REVIEW: source asks for human translation of this key
MSG_STEP_SETUP_ANSWER_FEW_QUESTIONS_THEN_WALK="الإعداد (بضعة أسئلة سريعة، ثم يواصل العمل من تلقاء نفسه)"
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
MSG_STEP_SETUP_COMPLETE_WRAP_UP="انتهت الأسئلة. يتم الآن تثبيت Ostler في الخلفية، ويستغرق ذلك من 45 دقيقة تقريبًا إلى بضع ساعات. ستحتاج إليك ثلاثة أمور: إذا طلب macOS تثبيت أدوات المطوّر فانقر على تثبيت؛ وقرب النهاية هناك دقيقة من الإعداد (تفعيل الوصول الكامل إلى القرص)؛ وفي النهاية تمامًا، بعد فحص السلامة، تسجّل الدخول إلى Tailscale وتسمح للمساعد باستخدام التذكيرات. وفيما بينها يمكنك تركه يعمل."
# #613: the line above names a Tailscale sign-in that a customer who answered
# "skip" to the remote-access question will never be asked for. Promising a step
# we then do not perform is the same defect class as claiming success we did not
# have: the customer plans their time around a sentence that is not true. This
# variant is emitted on the declined branch and names only what is left.
# Kept as a separate string rather than a printf substitution so the shipped
# copy of BOTH branches is readable in this file and gets its own review.
MSG_STEP_SETUP_COMPLETE_WRAP_UP_NO_REMOTE="انتهت الأسئلة. يتم الآن تثبيت Ostler في الخلفية، ويستغرق ذلك من 45 دقيقة تقريبًا إلى بضع ساعات. ستحتاج إليك ثلاثة أمور: إذا طلب macOS تثبيت أدوات المطوّر فانقر على تثبيت؛ وقرب النهاية هناك دقيقة من الإعداد (تفعيل الوصول الكامل إلى القرص)؛ وفي النهاية تمامًا تسمح للمساعد باستخدام التذكيرات. وفيما بينها يمكنك تركه يعمل."

# ── Info messages (progress, context) ──

MSG_INFO_AND_RE_RUN_OSTLER_FDA="وأعد التشغيل: ostler-fda"
MSG_INFO_ASSISTANT_FINAL_RESTART_FDA="جارٍ إعادة تشغيل المساعد ليتمكن من استخدام الوصول الكامل إلى القرص لقراءة سجل الرسائل. إعادة التشغيل هي ما يجعل الإذن الذي مُنح للتو ساري المفعول؛ وإن لم تمنحه بعد، فستواصل لوحة Doctor إرشادك."
MSG_OK_ASSISTANT_RUNNING_WITH_FDA="المساعد قيد التشغيل ولديه الوصول الكامل إلى القرص، ولذلك يمكنه قراءة الملفات التي يحتاج إليها."
MSG_WARN_ASSISTANT_RUNNING_WITHOUT_FDA="المساعد قيد التشغيل، لكنه لا يملك الوصول الكامل إلى القرص بعد. وإلى أن تفعّله، لن يتمكن Ostler من إبقاء الرسائل والبريد والتقويم والتذكيرات والملاحظات والصور وSafari وجهات الاتصال وWhatsApp محدّثة، ولن يستطيع قراءة مجلد المستندات. وما قرأه من قبل يبقى كما هو. سترشدك لوحة Doctor خلال تفعيله."
MSG_INFO_ASSISTANT_FDA_UNVERIFIED="المساعد قيد التشغيل. لم نتمكن من التحقق مما إذا كان لديه الوصول الكامل إلى القرص على هذا الـ Mac، لذا فهذا ليس تأكيدًا في أي من الاتجاهين. ستخبرك لوحة Doctor حالما تتمكن من الفحص."
MSG_INFO_APPLE_MAIL_ACCOUNTS_VISIBLE_INFORMATIONAL="حسابات Apple Mail الظاهرة: %s (للعلم)"
MSG_INFO_APPLE_MAIL_DOES_NOT_APPEAR_HOLD="لا يبدو أن Apple Mail يحتوي على أي رسائل محلية بعد. ستعرض Doctor متابعة إذا لم يصل أي بريد خلال 24 ساعة."
MSG_INFO_APPLE_MAIL_HAS_CACHED_MESSAGES_INGEST="يحتوي Apple Mail على رسائل مخزّنة مؤقتًا. سيلتقطها الاستيعاب في الدورة الساعية التالية."
MSG_INFO_APPLE_MAIL_NO_CONTENT_CONNECT_ACCOUNT="تم اختيار Apple Mail، لكن لا توجد رسائل محلية لقراءتها على هذا الـ Mac بعد. افتح Apple Mail وأضف حسابًا (إعدادات النظام > حسابات الإنترنت، ثم فعّل البريد)، واترك المزامنة الأولى تكتمل."
MSG_INFO_APPLE_MAIL_NO_CONTENT_RERUN="بعد وصول البريد، أعد التشغيل: ostler-fda. سيلتقطه Ostler تلقائيًا؛ ولا حاجة إلى أي شيء آخر."
MSG_INFO_APPLE_NOTARISATION_WILL_VERIFIED_GATEKEEPER_FIRST="سيتحقق Gatekeeper من توثيق Apple عند أول تشغيل."
MSG_INFO_AVAILABLE_INSTALLER_WILL_SKIP_THIS_STEP="سيتخطى المثبّت هذه الخطوة تلقائيًا عند التوفر."
MSG_INFO_BASH_INSTALL_SNIPPET_SH="    bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BASH_INSTALL_SNIPPET_SH_2="  bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET="يمكن لمختبري النسخة التجريبية الذين لديهم صلاحية الوصول تعيين PWG_PIPELINE_REPO=<url> ثم إعادة التشغيل."
MSG_INFO_BETA_TESTERS_WITH_ACCESS_CAN_SET_2="يمكن لمختبري النسخة التجريبية الذين لديهم صلاحية الوصول تعيين PWG_KNOWLEDGE_REPO=<url> ثم إعادة التشغيل."
MSG_INFO_BROWSER_EXTENSIONS_SKIPPED_NO_EXTENSIONS="تم تخطي إضافات المتصفح (--no-extensions)"
MSG_INFO_CD="  cd %s"
MSG_INFO_CLONED="  تم الاستنساخ إلى %s."
MSG_INFO_CM042_INTEL_NOT_SUPPORTED_SKIPPING="Ostler RemoteCapture يعمل على Apple Silicon فقط. سيتم تخطي التثبيت على هذا الجهاز."
MSG_INFO_CM042_LOGS_AT="سجلات RemoteCapture: %s/ostler-remotecapture.log (و.err)"
MSG_INFO_CM042_PRIOR_LAUNCHAGENT_REMOVED="كان تثبيت سابق قد ضبط Ostler RemoteCapture ليبدأ عند تسجيل الدخول. تم إيقافه ولن يبدأ مرة أخرى."
MSG_INFO_CM042_SKIPPED_TRANSCRIPTION_OFF="لم يتم تثبيت Ostler RemoteCapture: اخترت إبقاء النسخ الصوتي للكلام متوقفًا. فعّله في الإعدادات وشغّل المثبّت مرة أخرى إذا غيّرت رأيك."
MSG_INFO_CM042_TCC_PRE_PROMPT="عند أول تشغيل، سيطلب Ostler RemoteCapture من macOS إذن تسجيل الشاشة والميكروفون. امنح الإذنين ليمكن نسخ المكالمات والاجتماعات محليًا. لا يظهر مؤشر تسجيل أرجواني في شريط القوائم – فالتقاط الصوت صامت بحسب التصميم."
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
MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT="يحفظ Ostler ويكيك الشخصي وسجلات محادثاتك ضمن Documents/Ostler على هذا الـ Mac. هي ملكك وتبقى على هذا الجهاز. ولكتابتها يحتاج Ostler إلى الوصول إلى مجلد المستندات، لذا قد يطلب macOS ذلك أثناء الإعداد، ومرة أخرى لاحقًا اليوم عندما ينظّم Ostler ويكيك للمرة الأولى. قد يظهر الطلب وكأنه صادر من python3.11، وهي الأداة المضمّنة التي يستخدمها Ostler لكتابة ملفاتك. يُرجى النقر على السماح كلما ظهر. وإن فاتك أو رفضته، يمكنك تفعيله في أي وقت من إعدادات النظام، ضمن الخصوصية والأمن، ثم الملفات والمجلدات، وستُكتب ويكيك وسجلات محادثاتك من ذلك الحين فصاعدًا."
MSG_INFO_CM048_PIPELINE_INSTALLED_VENV="  تم تثبيت محرك ذاكرة المحادثات في venv."
MSG_INFO_HUB_APP_VERIFYING="جارٍ التحقق من Ostler.app في %s"
MSG_INFO_HUB_APP_STAGING="جارٍ نقل Ostler.app إلى /Applications من %s"
MSG_INFO_HUB_APP_DRAG_HINT="افتح DMG الخاص بالمثبّت واسحب Ostler.app وOstlerInstaller.app إلى اختصار التطبيقات، ثم أعد تشغيل المثبّت."
MSG_OK_HUB_APP_PRESENT="Ostler.app موجود بالفعل في %s؛ تم التحقق من التوقيع."
MSG_OK_HUB_APP_STAGED="تم تثبيت Ostler.app في %s"
MSG_WARN_HUB_APP_NOT_FOUND="لم يتم العثور على Ostler.app في /Applications ولا تتوفر نسخة مضمّنة."
MSG_WARN_HUB_APP_VERIFY_FAILED="فشل التحقق من توقيع Ostler.app أو توثيقه. سيتم ترك الحزمة في مكانها ليتمكن الدعم من فحصها."
MSG_OK_UNINSTALLER_APP_STAGED="تم تثبيت Ostler Uninstaller.app في %s"
MSG_WARN_UNINSTALLER_APP_STAGE_FAILED="تعذّر وضع Ostler Uninstaller.app في /Applications. لا يزال بإمكانك إلغاء التثبيت بتشغيل: ~/.ostler/bin/ostler-uninstall"
MSG_INFO_CLONING_DOCTOR_AGENT="جارٍ نسخ وكيل Doctor..."
MSG_INFO_CLONING_EMAIL_INGEST_SCRIPTS="جارٍ نسخ سكربتات استيعاب البريد الإلكتروني..."
MSG_INFO_CLONING_HUB_POWER_SCRIPTS="جارٍ نسخ سكربتات طاقة Hub..."
MSG_INFO_CLONING_IMPORT_PIPELINE="جارٍ نسخ مسار الاستيراد..."
MSG_INFO_CLONING_WIKI_RECOMPILE_SCRIPTS="جارٍ نسخ سكربتات إعادة تجميع الويكي..."
MSG_INFO_COLIMA_INSTALLED_BUT_NOT_RUNNING_WILL="Colima مثبّت لكنه لا يعمل. سيتم تشغيله."
MSG_INFO_COLIMA_START_ATTEMPT="جارٍ تشغيل Colima (المحاولة %s من %s)..."
MSG_INFO_COULD_NOT_EXPORT_CONTACTS_YOU_CAN="تعذّر تصدير جهات الاتصال. يمكنك استيرادها يدويًا لاحقًا."
MSG_INFO_COULD_NOT_READ_CONTACT_CARD_NO="تعذّرت قراءة بطاقة جهة الاتصال. لا بأس – سنسألك بدلًا من ذلك."
MSG_INFO_CONTACT_CARD_WILL_ASK="سنسألك عن اسمك وبلدك بعد قليل. تُقرأ جهات اتصالك لاحقًا عبر صلاحية الوصول إلى القرص بالكامل التي تمنحها، ولا يغادر أي شيء هذا الـ Mac."
MSG_INFO_CP_R_TMP_DOCTOR_SRC_DOCTOR="  cp -R /tmp/doctor-src/doctor/agent/* %s/"
MSG_INFO_CREATING_PYTHON_VENV="  جارٍ إنشاء بيئة Python الافتراضية في %s..."
MSG_INFO_CREATING_USER_FACING_CONTENT_TREE="جارٍ إنشاء شجرة المحتوى الموجّهة للمستخدم في %s/"
MSG_INFO_CURL_FL_O_TMP_OSTLER_TGZ="  curl -fL -o /tmp/ostler.tgz %s"
MSG_INFO_DAILY_TICK_MANUAL_RUN_BASH_BIN="تشغيل يومي. للتشغيل اليدوي: bash %s/bin/wiki-recompile-tick.sh"
MSG_INFO_DESKTOP_HUB_NO_BATTERY_DETECTED_DISABLING="تم اكتشاف Hub مكتبي (بلا بطارية): جارٍ تعطيل السكون على مستوى النظام"
MSG_INFO_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_INFO_DOCKER_NOT_INSTALLED_WILL_INSTALL_COLIMA="Docker غير مثبّت. سيتم تثبيت Colima وواجهة Docker CLI وإضافة docker-compose (خفيفة، ولا تحتاج إلى Docker Desktop)."
MSG_INFO_DOCTOR_AGENT_FILES_NOT_BUNDLED_WITH="ملفات وكيل Doctor غير مضمّنة في المثبّت."
MSG_INFO_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_WITH="سكربتات استيعاب البريد الإلكتروني غير مضمّنة في المثبّت."
MSG_FAIL_EMAIL_INGEST_VENDOR_MISSING_RE_RUN="سكربتات استيعاب البريد الإلكتروني مفقودة من حزمة المثبّت. أعد تنزيل ملف .app من ostler.ai/install وحاول مرة أخرى."
MSG_WARN_EMAIL_INGEST_SCRIPTS_NOT_BUNDLED_PLAINTEXT="سكربتات استيعاب البريد الإلكتروني غير مضمّنة وتم تمرير --allow-plaintext، لذا سيتم تخطي تثبيت LaunchAgent. لن يتم سحب رسائل البريد المستقبلية."
MSG_INFO_EXISTING_CHECKOUT_UPDATING="  توجد نسخة مسحوبة سابقًا في %s، جارٍ التحديث..."
MSG_INFO_EXTRACTING_GMAIL_MBOX_FROM_TAKEOUT_ZIP="جارٍ استخراج mbox الخاص بـ Gmail من ملف Takeout المضغوط (قد يستغرق ذلك دقيقة للأرشيفات الكبيرة)..."
MSG_INFO_FDA_EXTRACTION_MODULE_NOT_BUNDLED_SKIPPING="وحدة استخراج FDA غير مضمّنة. سيتم تخطي الاستخراج الفوري للبيانات."
MSG_INFO_FIRST_MONTH_FREE_ACTIVATING="جارٍ تفعيل أول 30 يومًا من Ostler Pro..."
MSG_INFO_SUBSCRIPTION_PRICING_HINT="يبلغ سعر Ostler Pro \$9.99 USD شهريًا بعد الفترة التجريبية. اشترك من تطبيق Ostler على iPhone."
MSG_INFO_FOUND_GMAIL_MBOX_MB="تم العثور على mbox الخاص بـ Gmail في %s (%s MB)"
MSG_INFO_FOUND_GOOGLE_TAKEOUT_ZIP_MB="تم العثور على ملف Google Takeout المضغوط في %s (%s MB)"
MSG_INFO_FULL_DISK_ACCESS_DETECTED_FULL_EXTRACTION="تم اكتشاف صلاحية الوصول إلى القرص بالكامل – الاستخراج الكامل متاح."
MSG_INFO_GDPR_EXPORTS_DETECTED_BUT_IMPORT_PIPELINE="تم اكتشاف صادرات GDPR لكن مسار الاستيراد غير متاح بعد."
MSG_INFO_GDPR_EXPORT_IMPORT_WILL_AVAILABLE_WHEN="سيتوفر استيراد صادرات GDPR عند إطلاق المسار."
MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING="سنفحص الآن مجلدات التنزيلات وسطح المكتب والمستندات بحثًا عن صادرات الذكاء الاصطناعي (Google Takeout وتنزيلات Meta وLinkedIn وغيرها) التي ربما حفظتها. سيعرض macOS ثلاث رسائل للوصول إلى المجلدات – يُرجى السماح بكل واحدة منها. يستغرق ذلك نحو 5-10 ثوانٍ في المجموع. لا يتم نقل أو نسخ أي شيء أثناء الفحص، نكتفي بالتحقق مما هو موجود."
MSG_INFO_CALENDAR_PERMISSION_PREWARM="قد يطلب macOS إذنًا لقراءة التقويم. اسمح بذلك ليتمكن Ostler من بناء جزء الاجتماعات والفعاليات في الرسم المعرفي الخاص بك. (تبقى بيانات التقويم على هذا الجهاز.)"
MSG_INFO_FOLDER_PREWARM_DOWNLOADS="يطلب macOS إذنًا للوصول إلى التنزيلات. انقر على موافق."
MSG_INFO_FOLDER_PREWARM_DESKTOP="يطلب macOS إذنًا للوصول إلى سطح المكتب. انقر على موافق."
MSG_INFO_FOLDER_PREWARM_DOCUMENTS="يطلب macOS إذنًا للوصول إلى المستندات. انقر على موافق."
MSG_INFO_IMESSAGE_AUTOMATION_TRANSITION="تم منح صلاحية الوصول إلى القرص بالكامل. جارٍ تجهيز رسالة macOS التالية (أتمتة الرسائل)..."
# #664: the Automation prompt went unanswered and we stopped waiting. Says what
# was missed, what it costs, and that it is recoverable -- the install carries on
# and Ostler asks again later, so this is a "not yet", not a failure.
MSG_WARN_IMESSAGE_AUTOMATION_PROBE_TIMEOUT="لم يتم الرد على طلب إذن الرسائل، فتابعنا الإعداد. لن تُقرأ رسائلك إلى أن يتم السماح بذلك. سيطلب Ostler الإذن مرة أخرى، أو يمكنك منحه من إعدادات النظام > الخصوصية والأمن > الأتمتة."
MSG_INFO_GIT_CLONE="  git clone %s %s"
MSG_INFO_GIT_CLONE_2="  git clone %s %s"
MSG_INFO_GIT_CLONE_TMP_DOCTOR_SRC="  git clone %s /tmp/doctor-src"
MSG_INFO_GIT_CLONE_TMP_HUB_POWER_SRC="  git clone %s /tmp/hub-power-src"
MSG_INFO_GIT_CLONE_TMP_HUB_SRC="  git clone %s /tmp/hub-src"
MSG_INFO_GIT_NOT_FOUND_INSTALLING_XCODE_COMMAND="أدوات سطر أوامر Xcode مطلوبة. سيطلب macOS إذنًا للتثبيت – ابحث عن مربع حوار رمادي صغير (إن لم تره، اضغط Cmd+Tab أو تحقق من Dock). انقر على تثبيت. تُنزَّل الأدوات في الخلفية أثناء إجابتك عن الأسئلة أدناه."
MSG_INFO_CLT_STILL_INSTALLING_ELAPSED="  لا يزال إعداد أدوات سطر الأوامر جاريًا (%ss). إذا كان مربع حوار رمادي صغير من macOS يطلب تثبيت أدوات المطوّر، فانقر على تثبيت فيه – هذه الخطوة تنتظر ذلك. (اضغط Cmd+Tab أو تحقق من Dock إن لم تره.)"
MSG_INFO_WAITING_FOR_CLT_TO_FINISH="في انتظار اكتمال تثبيت أدوات سطر الأوامر (اقتربنا من الانتهاء)..."
MSG_INFO_HOURLY_TICK_FIRST_RUN_CLAMPED_LAST="تحديث كل ساعة. أول تشغيل يجلب بريد آخر 5 سنوات."
MSG_INFO_IMESSAGE_BRIDGE_STARTED="جارٍ تعطيل LaunchAgent القديم لجسر iMessage (جهاز واحد، الإصدار 1.0)"
MSG_INFO_HUB_POWER_AC_ONLY_HUB_SKIPPING_LAUNCHAGENT="Hub يعمل بالتيار الكهربائي فقط (لم تُكتشف أي بطارية)، لذا سيتم تخطي LaunchAgent الخاص بطاقة Hub."
MSG_INFO_HUB_POWER_SCRIPTS_NOT_BUNDLED_WITH="لم تُضمَّن سكربتات طاقة Hub مع برنامج التثبيت."
# Laptop-Hub recap lines (task #339). Kept to one whole sentence per key so a
# translator gets sentences rather than fragments, and each one short enough to
# sit inside the recap's five-space indent on an 80-column terminal.
MSG_INFO_HUB_RECAP_LAPTOP_AWAKE="Hub محمول. يواصل العمل ما دام الغطاء مفتوحًا والجهاز موصولًا بالتيار الكهربائي."
MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS="عند إغلاق الغطاء، أو ترك الجهاز خاملًا على البطارية، يضعه macOS في وضع السكون."
MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING="أثناء السكون لا يتلقى المساعد أي شيء."
MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED="الرسائل التي تصل خلال هذه الفترة لا تُلتقط عند استيقاظه."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY="يمكن إبقاء الغطاء مغلقًا في وضع الشاشة المغلقة."
MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS="يتطلب ذلك تيارًا كهربائيًا وشاشة خارجية ولوحة مفاتيح وفأرة."
MSG_INFO_HUB_RECAP_LAPTOP_PAUSES="يتوقف Docker وOllama مؤقتًا على البطارية ويستأنفان عند توفر التيار الكهربائي."
MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN="بعد إعادة التشغيل، يُبقي FileVault هذا الـ Mac عند شاشة تسجيل الدخول."
MSG_INFO_HUB_RECAP_FILEVAULT_STARTS="يبدأ Ostler بمجرد تسجيل دخولك."
MSG_INFO_ICAL_SERVER_BUNDLED_WITH_INSTALLER="واجهة API الخاصة بالمساعد مضمّنة مع برنامج التثبيت؛ سيتم استخدام المصدر المرفق."
MSG_INFO_ICAL_SERVER_SOURCE_NOT_BUNDLED="مصدر واجهة API الخاصة بالمساعد غير مضمّن؛ سيكون وصول تطبيق Ostler على iPhone محدودًا."
MSG_INFO_ICAL_SERVER_DEPS_INSTALLING="جارٍ تثبيت اعتماديات تشغيل واجهة API الخاصة بالمساعد (phonenumbers, httpx)..."
MSG_WARN_ICAL_SERVER_DEPS_FAILED="تعذّر تثبيت اعتماديات تشغيل واجهة API الخاصة بالمساعد (phonenumbers/httpx)؛ قد يبقى قسما الأشخاص والجدول الزمني فارغين حتى التشغيل التالي للتثبيت."
MSG_INFO_IF_TAILSCALE_WINDOW_APPEARS_SIGN_WITH="عند ظهور نافذة Tailscale، سجّل الدخول باستخدام Apple أو Google أو Microsoft."
MSG_INFO_OPENING_TAILSCALE_FOR_SIGNIN="جارٍ فتح Tailscale لتتمكن من تسجيل الدخول..."
# WALK-1 (Wave 2.1): pre-announce the one late, optional Tailscale sign-in
# step so the unattended middle holds no surprise prompts. TODO(i18n):
# de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: called the Tailscale step "optional", but the installer then
# waits up to three minutes for it and re-opens the browser (Andy's log,
# 13:04:20 and 13:04:51). Optional-but-blocking is the worst of both. It also
# named only that step, while Full Disk Access and the developer-tools dialog
# were the two that actually surprised him.
MSG_INFO_TAILSCALE_SIGNIN_LATER_PREANNOUNCE="حسنًا – يتولى Ostler معظم التثبيت بنفسه من هنا. قرب النهاية سيحتاج إليك لمدة دقيقتين تقريبًا: لتفعيل الوصول الكامل إلى القرص، ثم تسجيل الدخول إلى Tailscale كي يصل iPhone وWatch إلى هذا الـ Mac من أي مكان. سنفتح المتصفح لتسجيل الدخول."
MSG_INFO_TAILSCALE_SKIPPED="تم تخطي Tailscale – سيعمل تطبيق Ostler على iPhone على شبكة Wi-Fi المنزلية فقط. يمكنك إعداد ذلك لاحقًا من الإعدادات."
MSG_INFO_TAILSCALE_STILL_WAITING="لا يزال تسجيل الدخول إلى Tailscale قيد الانتظار (انقضت %ss) – يُرجى إكمال تسجيل الدخول في نافذة Tailscale."
MSG_INFO_IMESSAGE_FDA_ASSIST_GRANTED="تم منح الوصول الكامل إلى القرص؛ جارٍ إعادة تشغيل المساعد لتفعيل الإذن الجديد."
MSG_INFO_IMESSAGE_FDA_ASSIST_OPENING="جارٍ فتح إعدادات النظام وFinder لإرشادك خلال منح المساعد الوصول الكامل إلى القرص..."
MSG_INFO_IMESSAGE_FDA_REGISTER_NUDGE="جارٍ تسجيل مساعد Ostler في macOS ليظهر كمفتاح تبديل ضمن الوصول الكامل إلى القرص..."
MSG_INFO_IMESSAGE_FDA_ASSIST_STILL_NEEDED="لا يزال الوصول الكامل إلى القرص معلّقًا. ستُبقي لوحة Doctor البطاقة ظاهرة إلى أن يُمنح الوصول."
MSG_INFO_IMESSAGE_FDA_DAEMON_TCC_GRANTED="ostler-assistant لديه الوصول الكامل إلى القرص بالفعل؛ لا حاجة إلى أي إجراء آخر."
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE="يحتاج هذا الجزء إليك لمدة دقيقتين تقريبًا: فعّل الوصول الكامل إلى القرص للمساعد الآن، ثم سجّل الدخول إلى Tailscale في الخطوة التالية. بعد ذلك يمكنك ترك Ostler يُكمل بمفرده."
# #613: the declined-remote-access variant of the line above. On the v1.0.60
# walk this was the SECOND time a customer who had answered "skip" was told a
# Tailscale sign-in was coming. Emitted only when the answer is known to be
# skip; an unknown answer keeps the original wording, because the late-ask path
# means the question genuinely is still to come.
MSG_INFO_IMESSAGE_FDA_INTERACTION_GATE_NO_REMOTE="يحتاج هذا الجزء إليك لمدة دقيقة تقريبًا: فعّل الوصول الكامل إلى القرص للمساعد. بعد ذلك يمكنك ترك Ostler يُكمل بمفرده."
# WALK-874(b): %s is the Full Disk Access row name, DERIVED from the
# assistant .app bundle (install.sh: _ostler_fda_entry_name). It read
# "Ostler is already listed" while the row said OstlerAssistant, so the
# customer went hunting in Finder for a row this line says is there.
MSG_INFO_IMESSAGE_FDA_ALREADY_LISTED="\"%s\" مدرج بالفعل في الوصول الكامل إلى القرص، لذا يكفي تفعيله. لا حاجة إلى سحب أي شيء من Finder."
MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN="جارٍ التحقق مما إذا كان مساعد Ostler لديه الوصول الكامل إلى القرص..."
MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED="يستطيع المساعد قراءة سجل الرسائل؛ ستعمل قناة iMessage."
MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT="لا يملك مساعد Ostler حتى الآن صلاحية الوصول الكامل إلى القرص. يحتاج إليها لإبقاء تطبيقات Mac الخاصة بك محدّثة، سواء استخدمت الرسائل أم لا. إذا تخطيت هذه الخطوة الآن، فستوجّهك لوحة Doctor عبر إعدادات النظام."
MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON="لم يتم تحميل LaunchAgent الخاص بالمساعد؛ سيتم تخطي فحص الوصول الكامل إلى القرص لـ iMessage."
MSG_INFO_IMPORT_EVERNOTE_UI_DOCTOR_WILL_SURFACE="ستعرض واجهة استيراد Evernote في Doctor رسالة \"الخدمة غير متاحة\""
MSG_INFO_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="مسار الاستيراد غير مضمّن مع المثبّت."
MSG_INFO_INSTALLING_CM042="جارٍ تثبيت Ostler RemoteCapture v%s (تحويل المكالمات والاجتماعات إلى نص)..."
MSG_INFO_INSTALLING_CM048_PIPELINE_FROM="جارٍ تثبيت محرك ذاكرة المحادثات من %s..."
MSG_INFO_INSTALLING_CM048_PIPELINE_INTO_VENV="  جارٍ تثبيت محرك ذاكرة المحادثات في venv..."
MSG_INFO_INSTALLING_COLIMA_DOCKER_CLI="جارٍ تثبيت Colima وأداة Docker CLI..."
MSG_INFO_INSTALLING_COREUTILS_GTIMEOUT="جارٍ تثبيت GNU coreutils (لتحديد مهلة الخطوات الطويلة)..."
MSG_INFO_INSTALLING_HOMEBREW="جارٍ تثبيت Homebrew..."
MSG_INFO_INSTALLING_KNOWLEDGE_SERVICE_FROM="جارٍ تثبيت خدمة المعرفة من %s..."
MSG_INFO_INSTALLING_OLLAMA="جارٍ تثبيت Ollama..."
MSG_INFO_INSTALLING_FDA_DEPENDENCIES="  جارٍ تثبيت تبعيات وحدة استخراج البيانات..."
MSG_INFO_INSTALLING_OSTLER_FDA_INTO_VENV="  جارٍ تثبيت قارئ Apple Mail في venv مخصصة..."
MSG_INFO_INSTALLING_OSTLER_KNOWLEDGE_INTO_VENV="  جارٍ تثبيت ostler-knowledge في venv..."
MSG_INFO_INSTALLING_OSTLER_SECURITY_INTO_CM048_VENV="  جارٍ تثبيت تبعية التخزين المشفّر في venv الخاصة بذاكرة المحادثات..."
MSG_INFO_INSTALLING_SAFARI_EXTENSION_APPLICATIONS="جارٍ تثبيت امتداد Safari في /Applications"
MSG_INFO_INSTALLING_SECURITY_PYTHON_DEPENDENCIES="جارٍ تثبيت تبعيات Python الأمنية..."
MSG_INFO_INSTALLING_SQLCIPHER="جارٍ تثبيت SQLCipher..."
MSG_INFO_INSTALLING_TAILSCALE="جارٍ تثبيت Tailscale..."
MSG_INFO_INTEL_SUPPORT_NOT_ROADMAP_RAISE_REQUEST="دعم Intel ليس ضمن خارطة الطريق؛ يمكنك تقديم طلب إذا لزم الأمر."
MSG_INFO_KNOWLEDGE_SERVICE_BUNDLED_WITH_INSTALLER="خدمة المعرفة مضمّنة مع المثبّت؛ سيتم استخدام المصدر المضمّن."
MSG_INFO_KNOWLEDGE_SERVICE_NOT_INSTALLED_PWG_KNOWLEDGE="لم يتم تثبيت خدمة المعرفة: PWG_KNOWLEDGE_REPO فارغ."
# Laptop-Hub posture, stated in Phase 1 while changing your mind is still cheap
# (task #339). Fires on every laptop, on mains power or not; a desktop Mac never
# sees these lines.
MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS="هذا الـ Mac هو حاسوب محمول. وبصفته الـ Hub الخاص بك، يواصل العمل ما دام الغطاء مفتوحًا وجهاز Mac موصولًا بالتيار الكهربائي."
MSG_INFO_LAPTOP_HUB_SLEEP_COST="إذا أغلقت الغطاء، أو تركته دون استخدام على البطارية، يضعه macOS في وضع السكون. لا يتلقى المساعد أي شيء أثناء السكون، ولا تُلتقط الرسائل التي تصل خلال ذلك عند الاستيقاظ."
MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY="يمكن أن يبقى الغطاء مغلقًا في وضع الشاشة المغلقة، الذي يتطلب التيار الكهربائي مع شاشة خارجية ولوحة مفاتيح وفأرة."
MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE="يبقى Hub على Mac Mini أو Mac Studio مستيقظًا من تلقاء نفسه، إن كنت تفضّل التثبيت على أحدهما."
MSG_INFO_LATER_SYSTEM_SETTINGS_PRIVACY_SECURITY_FULL="لاحقًا في إعدادات النظام > الخصوصية والأمن > الوصول الكامل إلى القرص"
MSG_INFO_LAUNCH_VERIFY_CRON_DELIVERY_IMESSAGE_TCC="  عند التشغيل للتحقق من وضع cron-delivery و imessage-tcc)."
MSG_INFO_LICENCE_APACHE_2_0_FULL_TEXT="الترخيص: %s ضمن Apache 2.0. النص الكامل: %s/LICENSES/Apache-2.0.txt"
MSG_INFO_LICENCE_CHECK_UPSTREAM_TERMS_BEFORE_COMMERCIAL="الترخيص: %s – تحقق من شروط المصدر الأصلي قبل الاستخدام التجاري."
MSG_INFO_LOCAL_STORE_GOOGLE_NEVER_SEES_THAT="مخزن محلي – لا تعرف Google أبدًا بوجود Ostler."
MSG_INFO_LOGS_EMAIL_INGEST_LOG_ERR="السجلات: %s/email-ingest.log (و .err)"
MSG_INFO_LOGS_OSTLER_ASSISTANT_LOG_ERR="السجلات: %s/ostler-assistant.log (و .err)"
MSG_INFO_LOGS_WIKI_RECOMPILE_LOG_ERR="السجلات: %s/wiki-recompile.log (و .err)"
MSG_INFO_MACBOOK_HUBS_SET_PWG_HUB_POWER="أجهزة Hub من نوع MacBook: عيّن PWG_HUB_POWER_REPO=<url> ثم أعد التشغيل."
MSG_INFO_MACBOOK_HUB_DETECTED_SETTING_NEVER_SLEEP="تم اكتشاف Hub من نوع MacBook: سيتم ضبط عدم السكون عند التيار الكهربائي فقط (تتولى hub-power معالجة الانتقال إلى البطارية)"
MSG_INFO_MAC_MINI_STUDIO_DEPLOYMENTS_ARE_UNAFFECTED="لا تتأثر عمليات النشر على Mac Mini / Studio (موصولة دائمًا بالتيار الكهربائي)."
MSG_INFO_MAC_SIDE_DATA_IMESSAGE_SAFARI_ETC="تم استخراج بيانات Mac (iMessage وSafari وغيرها) أعلاه."
MSG_INFO_MANUAL_RESTART_LAUNCHCTL_KICKSTART_K_GUI="إعادة التشغيل يدويًا: launchctl kickstart -k gui/\$(id -u)/com.creativemachines.ostler.assistant"
MSG_INFO_MANUAL_RUN_BASH_BIN_EMAIL_INGEST="التشغيل اليدوي: bash %s/bin/email-ingest-tick.sh"
MSG_INFO_MEETING_BRIEF_AGENT_SKIPPED="يتم تخطي تثبيت com.ostler.meeting-brief-sender (ميزة الإصدار v1.0.1؛ نقاط الاتصال لم تصدر بعد)."
MSG_INFO_MEMORY_HYGIENE_SKIPPED_NOT_STAGED="يتم تخطي مرحلة تنظيف الذاكرة (غير مضمّنة في هذا المثبّت)؛ لن يتم تخفيض وزن أي شيء تلقائياً إلى أن تتوفر."
MSG_INFO_MESSAGE_WHEN_FEATURE_FLAG_LATER_FLIPPED="رسالة عند تفعيل علامة الميزة لاحقاً."
MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI="هل تحتاج إلى مساعدة؟ راسلنا على support@ostler.ai. نسعى إلى الرد خلال يومي عمل."
MSG_INFO_MKDIR_P_CP_R_TMP_HUB="  mkdir -p %s && cp -R /tmp/hub-power-src/hub-power/* %s/"
MSG_INFO_MKDIR_P_CP_R_TMP_HUB_2="  mkdir -p %s && cp -R /tmp/hub-src/email-ingest/* %s/"
MSG_INFO_NO_CHANNELS_CONFIGURED_RUN_LATER_BIN="لم يتم إعداد أي قنوات. شغّل لاحقاً: %s/bin/ostler-assistant setup channels --interactive"
MSG_INFO_REMOVED_LEGACY_ROOT_CONFIG_TOML="تمت إزالة ملف config.toml قديم وغير مستخدم من جذر مساحة العمل؛ يوجد إعداد المساعد الفعلي ضمن assistant-config/."
MSG_INFO_NO_FDA_SOURCES_AVAILABLE_RIGHT_NOW="لا توجد مصادر FDA متاحة حالياً. يمكنك منح الوصول الكامل إلى القرص"
MSG_INFO_NO_GDPR_EXPORTS_FOUND_DOWNLOADS_DESKTOP="لم يتم العثور على عمليات تصدير GDPR في التنزيلات أو سطح المكتب أو المستندات."
MSG_WARN_FOLDER_ACCESS_DENIED_SCAN="تعذرت قراءة %s للبحث عن عمليات تصدير البيانات. يمنع macOS الوصول إلى هذا المجلد."
MSG_INFO_FOLDER_ACCESS_DENIED_GUIDANCE="امنح الوصول في إعدادات النظام > الخصوصية والأمن > الملفات والمجلدات (أو الوصول الكامل إلى القرص) ثم أعد التشغيل، أو وجّه Ostler إلى مجلد عمليات التصدير لديك يدوياً أدناه."
MSG_INFO_GDPR_SCAN_BLOCKED_BY_PERMISSIONS="تعذر فحص مجلد واحد أو أكثر بحثاً عن عمليات تصدير البيانات لأن macOS منع الوصول. امنح الوصول وأعد التشغيل، أو حدّد لي مجلد عمليات التصدير يدوياً."
MSG_INFO_OPENING_CHROME_WEB_STORE="جارٍ فتح سوق Chrome الإلكتروني: %s"
MSG_INFO_OSTLER_ASSISTANT_BINARY_NOT_INSTALLED_SKIPPING="الملف التنفيذي ostler-assistant غير مثبّت؛ يتم تخطي فحص doctor"
MSG_INFO_OSTLER_ASSISTANT_DOCTOR_DEFERRED_DAEMON_MAY="ostler-assistant doctor: تم التأجيل (قد تكون الخدمة الخلفية لا تزال"
MSG_INFO_OSTLER_ASSISTANT_USING_BUNDLED_BINARY="استخدام الملف التنفيذي ostler-assistant المضمّن في ملف DMG هذا (مسار تثبيت يعمل دون اتصال)."
MSG_INFO_OSTLER_INSTALL_ROOT_BASH_INSTALL_SNIPPET="  OSTLER_INSTALL_ROOT=%s bash %s/INSTALL_SNIPPET.sh"
MSG_INFO_OSTLER_INSTALL_ROOT_OSTLER_DIR_LOGS="  OSTLER_INSTALL_ROOT=%s OSTLER_DIR=%s LOGS_DIR=%s \\\\"
MSG_INFO_OSTLER_KNOWLEDGE_INSTALLED_VENV="  تم تثبيت ostler-knowledge في البيئة الافتراضية venv."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_OSTLER_WILL_SHOW_EXTRA_CONSENT_SCREEN="      سيعرض Ostler شاشة موافقة إضافية قبل التثبيت"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_CM048="  يمكنك تجاوز مستودع المصدر لمحرك ذاكرة المحادثات عبر متغير البيئة الموضّح في ./install.sh --help."
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_DOCTOR="  يمكنك تجاوز مستودع المصدر باستخدام PWG_DOCTOR_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_HUB="  يمكنك تجاوز مستودع المصدر باستخدام PWG_HUB_POWER_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_KNOWLEDGE="  يمكنك تجاوز مستودع المصدر باستخدام PWG_KNOWLEDGE_REPO=<url> ./install.sh"
MSG_INFO_OVERRIDE_SOURCE_REPO_WITH_PWG_PIPELINE="  يمكنك تجاوز مستودع المصدر باستخدام PWG_PIPELINE_REPO=<url> ./install.sh"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION="جارٍ حفظ سجلات الموافقة والمنطقة..."
MSG_INFO_PHASE_3_BATTERY_WATCHER_ARMED_PID="تم تفعيل مراقب البطارية للمرحلة 3 (PID %s)"
MSG_INFO_PLEASE_WAIT_READING_CONTACTS="جارٍ قراءة دفتر العناوين (قد تستغرق المكتبات الكبيرة بضع دقائق – يُرجى عدم إغلاق المثبّت)..."
MSG_INFO_POLICY_OVERRIDE_EDIT_OSTLER_POWER_CONF="تجاوز السياسة: عدّل ~/.ostler/power.conf (normal / aggressive / eco)"
MSG_INFO_PROBING_IMESSAGE_AUTOMATION_PERMISSION_READ_ONLY="جارٍ فحص إذن الأتمتة لـ iMessage (للقراءة فقط)..."
MSG_INFO_PULLING_GRAPH_DB_IMAGES="جارٍ تنزيل قواعد بيانات الرسم المعرفي (عند أول تشغيل فقط). قد يستغرق ذلك دقيقة عند التثبيت الجديد..."
MSG_INFO_PULLING_NOMIC_EMBED_TEXT_274_MB="جارٍ سحب nomic-embed-text (274 MB)..."
MSG_INFO_PULLING_THIS_MAY_TAKE_FEW_MINUTES="جارٍ سحب %s (%s)... قد يستغرق ذلك بضع دقائق."
MSG_INFO_QUARANTINE_XATTR_CLEARED_ONCE_DEVELOPER_ID="تمت إزالة سمة الحجر الصحي xattr. بمجرد أن يصبح إصدار Developer-ID"
MSG_INFO_READING_SAFARI_IMESSAGE_NOTES_CALENDAR_PHOTOS="جارٍ قراءة Safari وiMessage والملاحظات والتقويم والصور والتذكيرات والبريد..."
MSG_INFO_READING_YOUR_CONTACT_CARD_PRE_FILL="جارٍ قراءة بطاقة جهة الاتصال الخاصة بك لتعبئة بياناتك مسبقاً..."
MSG_INFO_REGION_EU_EEA_SOURCE="المنطقة: الاتحاد الأوروبي/المنطقة الاقتصادية الأوروبية (%s، المصدر: %s)"
MSG_INFO_REGION_SOURCE="المنطقة: %s (المصدر: %s)"
MSG_INFO_REGION_UNITED_KINGDOM_SOURCE="المنطقة: المملكة المتحدة (المصدر: %s)"
MSG_INFO_REGION_UNITED_STATES_SOURCE="المنطقة: الولايات المتحدة (المصدر: %s)"
MSG_INFO_REPO_URL="عنوان URL للمستودع: %s"
MSG_INFO_REPO_URL_2="عنوان URL للمستودع: %s"
MSG_INFO_REPO_URL_3="عنوان URL للمستودع: %s"
MSG_INFO_RECOVERY_PASSPHRASE_INTRO="اختر الآن عبارة المرور التي ستفتح Hub. ستكتبها في كل مرة تشغّل فيها واجهة Hub."
MSG_INFO_RECOVERY_PASSPHRASE_SKIPPED_BIP39_ONLY="تم تخطي عبارة مرور الاسترداد. (مُهمَل: يتطلب الإصدار v1.0 عبارة مرور دائمًا.)"
MSG_INFO_REUSING_EXISTING_DOCTOR_AGENT_INSTALL="إعادة استخدام تثبيت وكيل Doctor الموجود في %s"
MSG_INFO_REUSING_EXISTING_EMAIL_INGEST_INSTALL="إعادة استخدام تثبيت email-ingest الموجود في %s"
MSG_INFO_REUSING_EXISTING_HUB_POWER_INSTALL="إعادة استخدام تثبيت hub-power الموجود في %s"
MSG_INFO_REUSING_EXISTING_EXTENSION_TOKEN="إعادة استخدام مفتاح امتداد المتصفح الموجود في %s"
MSG_INFO_CHROME_EXTENSION_NOT_IN_THIS_RELEASE="امتداد Ostler لمتصفح Chrome ليس جزءًا من هذا الإصدار."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_EMAIL_SKIPPED_CONSENT="محادثات البريد الإلكتروني: لم يتم إعدادها، لأنك لم توافق على أن يقرأ Ostler رسائل الآخرين."
MSG_INFO_FEED_EMAIL_SKIPPED_NO_MAIL="محادثات البريد الإلكتروني: لم يتم إعدادها، لأن Apple Mail غير مُعدّ على هذا الـ Mac."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_IMESSAGE_SKIPPED_CONSENT="محادثات الرسائل: لم يتم إعدادها، لأنك لم توافق على أن يقرأ Ostler رسائل الآخرين."
MSG_INFO_FEED_IMESSAGE_SKIPPED_NO_DB="محادثات الرسائل: لم يتم إعدادها، لأنه لا يوجد سجل رسائل على هذا الـ Mac."
MSG_INFO_FEED_SPOKEN_SKIPPED_HOW="  فرّغ مكالمة نصيًا باستخدام Ostler وسيعمل هذا تلقائيًا."
MSG_INFO_FEED_SPOKEN_SKIPPED_NO_TRANSCRIPTS="المحادثات المنطوقة: لم يتم إعدادها بعد، لأنه لا توجد نصوص مفرّغة لقراءتها."
MSG_WARN_FEED_SPOKEN_TRANSCRIPTS_REMOVED="المحادثات المنطوقة: متوقفة، لأن مجلد Transcripts أُزيل منذ تثبيت Ostler."
MSG_INFO_FEED_SPOKEN_TRANSCRIPTS_REMOVED_HOW="  أعد إنشاء %s لإعادة تشغيلها. لن يعيد Ostler إنشاءه نيابةً عنك."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_INFO_FEED_WHATSAPP_SKIPPED_CONSENT="محادثات WhatsApp: لم يتم إعدادها، لأنك لم توافق على أن يقرأ Ostler رسائل الآخرين."
MSG_INFO_FEED_WHATSAPP_SKIPPED_OFF="محادثات WhatsApp: لم يتم إعدادها، لأن WhatsApp متوقف."
MSG_INFO_CHROME_HISTORY_STILL_READ="  لا يزال Ostler يقرأ سجل Chrome لديك، لذا تُحفظ الصفحات التي زرتها. الالتقاط المباشر أثناء التصفح متاح في Safari فقط حاليًا."
MSG_INFO_REUSING_EXISTING_JWT_SECRET="إعادة استخدام JWT_SECRET الموجود في %s"
MSG_INFO_REUSING_EXISTING_PWG_SERVICE_TOKEN="إعادة استخدام رمز خدمة PWG الموجود في %s"
MSG_INFO_REUSING_EXISTING_WIKI_RECOMPILE_INSTALL="إعادة استخدام تثبيت wiki-recompile الموجود في %s"
MSG_INFO_SAFARI_EXTENSION_BUNDLE_NOT_PRESENT_THIS="حزمة امتداد Safari غير موجودة في هذا الإصدار من المثبّت (يتم التخطي)"
MSG_INFO_SAFARI_EXTENSION_ENABLE_GUIDANCE="تبقّت خطوة يدوية واحدة: افتح Safari، ثم اختر Safari > الإعدادات > الامتدادات، وحدّد Ostler لتفعيله."
MSG_INFO_SCANNING_GDPR_DATA_EXPORTS="جارٍ البحث عن ملفات تصدير بيانات GDPR..."
MSG_INFO_SET_PWG_DOCTOR_REPO_URL_RE="عيّن PWG_DOCTOR_REPO=<url> وأعد التشغيل للتثبيت."
MSG_INFO_SET_PWG_HUB_POWER_REPO_HR015="عيّن PWG_HUB_POWER_REPO=<HR015 url> وأعد التشغيل للتثبيت."
MSG_INFO_SKIPPED_CONVERSATION_MODEL_PULL_LATER_OLLAMA="تم تخطي نموذج المحادثة. نزّله لاحقًا: ollama pull %s"
MSG_INFO_STARTING_COLIMA_LIGHTWEIGHT_DOCKER_RUNTIME="جارٍ تشغيل Colima (بيئة Docker خفيفة)..."
MSG_INFO_STARTING_DOCKER_DESKTOP="جارٍ تشغيل Docker Desktop..."
MSG_INFO_STARTING_OLLAMA="جارٍ تشغيل Ollama..."
MSG_INFO_REMOVING_STALE_COLIMA_LAUNCHAGENT="جارٍ إزالة عنصر بدء تشغيل Colima قديم تركه إصدار أقدم..."
MSG_INFO_REMOVING_BROKEN_OLLAMA_FORMULA="جارٍ إزالة صيغة Ollama القديمة (بدون llama-server)، والتحويل إلى تطبيق Ollama..."
MSG_INFO_VERIFYING_EMBEDDINGS="جارٍ التحقق من أن محرك التضمين يُنتج متجهات..."
MSG_INFO_OLLAMA_MANUAL_START_HINT="تعذّر تشغيل Ollama تلقائيًا. حمّله بالأمر: launchctl bootstrap gui/\$(id -u) %s – ثم أعد تشغيل المثبّت."
MSG_WARN_OLLAMA_BOOTSTRAP_FALLBACK_DIRECT="لم يعمل Ollama عبر خدمة الخلفية؛ جارٍ تشغيله مباشرةً لهذه الجلسة..."
# NEEDS REVIEW: Source is a line cut mid-sentence ('after first' continues on the next line). 'بعد ذلك أولاً' distorted the meaning. A human should check the next line so the f
MSG_INFO_STARTING_RUN_OSTLER_ASSISTANT_DOCTOR_AFTER="  جارٍ البدء؛ شغّل \`ostler-assistant doctor\` بعد أول"
MSG_INFO_SYMLINKING="  إنشاء رابط رمزي %s -> %s"
# NEEDS REVIEW: Continuation fragment: 'Mail's' is completed by the next line. Check that the join reads naturally in Arabic.
MSG_INFO_SYSTEM_SETTINGS_INTERNET_ACCOUNTS_OSTLER_READS="(إعدادات النظام > حسابات الإنترنت). يقرأ Ostler من بريد"
MSG_INFO_TAR_XZF_TMP_OSTLER_TGZ_C="  tar xzf /tmp/ostler.tgz -C %s/bin"
MSG_INFO_THE_REST_OSTLER_RUNS_WITHOUT_DOCTOR="(يعمل باقي Ostler دون لوحة Doctor.)"
MSG_INFO_THIS_EXPECTED_NOW_GDPR_IMPORT_WILL="هذا متوقع في الوقت الحالي. سيتوفر استيراد GDPR في تحديث قادم."
# NEEDS REVIEW: source asks for human translation of this key
MSG_INFO_THIS_MAY_TAKE_5_15_MINUTES="يستغرق هذا عادةً من 15 إلى 45 دقيقة، وقد يطول إذا كان لديك سجل كبير أو جهاز Mac أبطأ. هذا أمر طبيعي – فالعملية تعمل ولم تتوقف، فلا بأس بتركها تعمل..."
MSG_INFO_THIS_READS_MACOS_DATABASES_DIRECTLY_NO="يقرأ هذا قواعد بيانات macOS مباشرةً – دون الحاجة إلى تصدير."
MSG_INFO_TIP_INCLUDE_YOUR_GMAIL_ADD_IT="نصيحة: لتضمين حساب Gmail الخاص بك، أضفه أولاً إلى بريد Mac"
MSG_INFO_TO_INSTALL_LATER_ONCE_YOU_HAVE="للتثبيت لاحقاً بعد حصولك على الوصول:"
MSG_INFO_TRIGGERING_ICLOUD_SYNC_SILENT_FIRST_RUN="جارٍ تشغيل مزامنة iCloud لـ %s (بصمت، عند التشغيل الأول فقط)..."
MSG_INFO_UK_GDPR_ARTICLE_9_REQUIRED_SPECIAL="      (المادة 9 من UK GDPR - مطلوبة للبيانات ذات الفئة الخاصة)."
MSG_INFO_UPDATING_EXISTING_PIPELINE="جارٍ تحديث المسار الحالي..."
MSG_INFO_USER_FACING_TREE_ALREADY_ANNOUNCED_SENTINEL="الشجرة الموجهة للمستخدم أُعلن عنها مسبقاً (العلامة موجودة)؛ سيتم التخطي"
MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS="جارٍ تنزيل محرك البحث المحلي على الويب (نحو 3.5 GB). هذه أطول خطوة عند التثبيت الأول وقد تستغرق حتى ساعة. لا يوجد شريط تقدم لها، لذا فالصمت الطويل هنا متوقع ولا يعني أن التثبيت توقف."
MSG_INFO_VANE_NOT_RESPONDING_OPTIONAL_SEE_PHASE="Vane لا يستجيب (اختياري؛ راجع تحذيرات المرحلة 3.8b)"
MSG_INFO_VIEW_ANY_TIME_WITH_BASH_INSTALL="للعرض في أي وقت: bash install.sh --licenses"
MSG_INFO_VOICE_RECOGNITION_WILL_STAY_OFF_YOU="سيبقى التعرف على الصوت متوقفاً. يمكنك تفعيله لاحقاً من الإعدادات."
MSG_INFO_WAITING_YOU_SIGN_TAILSCALE_UP_3="في انتظار تسجيل دخولك إلى Tailscale (حتى 3 دقائق)..."
MSG_INFO_TAILSCALE_SETUP_LATER_FROM_SETTINGS="لم يتم إعداد الوصول عن بُعد عبر Tailscale. سيعمل تطبيق Ostler على iPhone عبر شبكة Wi-Fi المنزلية؛ ويمكنك إعداد الوصول عن بُعد لاحقاً من الإعدادات."
MSG_INFO_TAILSCALE_ALREADY_CONFIGURED="جهاز Mac هذا متصل بالفعل بشبكة Tailscale الخاصة بك، فلا حاجة إلى أي إعداد. سيتم الإبقاء على اتصالك الحالي."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SKIP="الوصول عن بُعد: يتم الإبقاء على إجابتك السابقة، وهي التخطي. سيعمل تطبيق iOS عبر شبكة Wi-Fi المنزلية، ويمكنك إعداد الوصول عن بُعد لاحقاً من الإعدادات."
MSG_INFO_TAILSCALE_REUSED_ANSWER_SETUP="الوصول عن بُعد: يتم الإبقاء على إجابتك السابقة، وهي الإعداد."
MSG_INFO_WHATSAPP_CONNECTOR_LEFT_OFF_YOU_CAN="تم ترك موصّل WhatsApp متوقفاً. يمكنك تفعيله لاحقاً من الإعدادات."
MSG_INFO_WHATSAPP_KEEPALIVE_SCHEDULED_08_50_17="تمت جدولة WhatsApp keepalive عند 08:50 + 17:50 (التسمية com.creativemachines.ostler.whatsapp-keepalive)"
MSG_INFO_WIKI_RECOMPILE_CATCHUP_SKIPPED_NO_TICK="تخطي مزامنة الويكي لليوم الأول: مهمة إعادة تجميع الويكي غير مثبّتة. ولا تزال إعادة بناء الويكي اليومية تعمل إن كانت مثبّتة."
MSG_INFO_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED_WITH="نصوص إعادة تجميع الويكي غير مضمّنة في المثبّت."
MSG_INFO_WIKI_WILL_NOT_AUTO_UPDATE_YOU="لن يتحدث الويكي تلقائياً؛ يمكنك إعادة تشغيل التجميع الأول يدوياً:"
MSG_INFO_WROTE_POSTURE_MARKER_INSTALL_JSON="تمت كتابة علامة الوضع: %s/install.json"
MSG_INFO_YOUR_EXPORTS_ARE_SAFE_IMPORT_THEM="ملفاتك المُصدَّرة في أمان. استوردها لاحقاً باستخدام: ostler-import %s"
MSG_INFO_YOUR_MAC_DATA_IMESSAGE_SAFARI_ETC="تم استخراج بيانات Mac الخاصة بك (iMessage وSafari وغيرها) مسبقاً أعلاه."
MSG_INFO_YOU_CAN_ADD_IT_LATER_INSTANT="يمكنك إضافته لاحقاً للإعداد الفوري من Safari وiMessage وغيرهما."

# ── Success messages ──

MSG_OK_AI_MODEL_SELECTED_YOUR_GB_RAM="نموذج الذكاء الاصطناعي: %s (%s) – تم اختياره لذاكرة RAM بسعة %s GB لديك"

# ── Hardware-fit model picker (REUSE-4) ──
# Pills shown against each candidate model.
MSG_MODELFIT_PILL_FITS="مناسب"
MSG_MODELFIT_PILL_SLOW="قد يكون بطيئاً"
MSG_MODELFIT_PILL_NOFIT="غير مناسب"
# Header for the per-model fit assessment block. Args: chip, RAM GB, num_ctx.
MSG_MODELFIT_HEADER="مطابقة نموذج المساعد مع جهاز Mac لديك (%s، ذاكرة RAM بسعة %s GB، سياق المساعد %s رمز):"
# One row per candidate. Args: pill, model tag, size label, quant tier.
MSG_MODELFIT_ROW="  %s  %s (%s, %s)"
# Suffix appended to the recommended row.
MSG_MODELFIT_RECOMMENDED_TAG="  <- موصى به"
# Final selection line. Args: model tag, size label, RAM GB.
MSG_MODELFIT_SELECTED="نموذج الذكاء الاصطناعي: %s (%s) – الأنسب لذاكرة RAM بسعة %s GB عند نافذة السياق التي يتطلبها المساعد"
MSG_OK_ALL_SOURCES_SELECTED_FACE_RECOGNITION_STILL="تم تحديد جميع المصادر (التعرف على الوجوه لا يزال متوقفاً)"
MSG_OK_ALREADY_AVAILABLE="%s متاح بالفعل"
MSG_OK_APPLE_SILICON_DETECTED="تم اكتشاف Apple Silicon"
MSG_OK_APPS_LAUNCHED_TRIGGER_ICLOUD_SYNC="تم تشغيل التطبيقات لبدء مزامنة iCloud"
MSG_OK_APP_DATABASES_ALREADY_PRESENT_SKIPPING_PRE="قواعد بيانات التطبيقات موجودة بالفعل (تخطي التشغيل المسبق)"
MSG_OK_ASSISTANT_CONFIG_SAVED_MODE_0600="تم حفظ إعدادات المساعد في %s (الوضع 0600)"
MSG_OK_BACKED_UP_CONTACTS="تم نسخ %s من جهات الاتصال احتياطيًا إلى %s"
MSG_OK_CM042_INSTALLED="تم تثبيت Ostler RemoteCapture v%s في %s"
MSG_OK_CM042_LAUNCHAGENT_LOADED="تم تحميل LaunchAgent الخاص بـ Ostler RemoteCapture (التسمية %s)"
MSG_OK_COLIMA_DOCKER_CLI_INSTALLED="تم تثبيت Colima وأداة Docker CLI"
# v1.0.38 walk (2026-08-23): the container engine was killed by macOS
# mid-life and nothing checked again for a day, because the only thing that
# could restart it ran once at daemon startup. These cover the agent that
# supplies the missing cadence.
MSG_OK_ENGINE_SUPERVISOR_INSTALLED="تم تثبيت مشرف بيئة الحاويات (يفحص كل 5 دقائق ويعيد تشغيل البيئة إذا توقفت)"
MSG_WARN_ENGINE_SUPERVISOR_NOT_LOADED="تعذرت جدولة مشرف بيئة الحاويات. سيتم تثبيت Ostler مع ذلك، لكن إذا توقفت البيئة لاحقًا فلن يعيدها شيء تلقائيًا، وسيبقى الويكي الخاص بك متوقفًا إلى أن تعيد تشغيل المثبّت."
MSG_WARN_ENGINE_SUPERVISOR_NOT_STAGED="ملفات مشرف بيئة الحاويات مفقودة من هذا المثبّت، لذلك لم تتم جدولته. سيتم تثبيت Ostler مع ذلك، لكن الاسترداد التلقائي للبيئة غير مفعّل."
# v1.0.44 walk (2026-08-24), #876 and the #800 class behind it. Five
# background helpers used to announce themselves as running with no way for
# the code to be wrong: `launchctl … || true` and then an unconditional `ok`.
# On Andy's walk the Doctor line printed while com.ostler.doctor was not
# loaded at all. These are the sentences the installer now says when launchd
# does NOT report the agent registered. Each names what the customer loses,
# not what failed internally, and none of them claims the install is ruined:
# these are helpers, and the machine still works without them.
MSG_WARN_OSTLER_DOCTOR_NOT_LOADED="تعذر تشغيل لوحة Doctor في Ostler، لذلك لن يستجيب http://localhost:8089. ستظهر صفحات التطبيق التي تقرأ منها، وهي الأشخاص والجدول الزمني والحاكم وحالة القنوات، على أنها غير متاحة إلى أن تعمل. أعد تشغيل المثبّت للمحاولة مرة أخرى."
MSG_WARN_STAY_AWAKE_AGENT_NOT_LOADED="تعذرت جدولة أداة إبقاء الجهاز مستيقظًا. يعمل Ostler مع ذلك، لكن قد يدخل هذا الـ Mac في وضع السكون أثناء المهام الطويلة في الخلفية، وستُستأنف عند استيقاظه بدلًا من أن تنتهي خلال الليل."
MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="تعذرت جدولة أداة التحديث في الخلفية، لذلك لن يتم التقاط الرسائل والبريد وأحداث التقويم الجديدة تلقائيًا. أعد تشغيل المثبّت لاستعادتها."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED="لم يتم إعداد %s: لا يملك Ostler أي سجل لإجابتك عن السؤال الذي يتحكم به، لذلك لم يفترض أي إجابة."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_UNKNOWN_FEATURE_SKIPPED_WHY="  أعد تشغيل Ostler واختر الإجابة عن الأسئلة مرة أخرى لتفعيله. (سجل الموافقة: %s)"
MSG_WARN_MEETING_BRIEF_SENDER_NOT_LOADED="تعذرت جدولة الملخص اليومي، لذلك لن تتلقى ملخص الصباح. كل شيء آخر يعمل؛ أعد تشغيل المثبّت لاستعادته."
MSG_WARN_MEMORY_HYGIENE_NOT_LOADED="تعذرت جدولة عملية تنظيف الذاكرة، لذلك لن يتم تقليل وزن المعلومات القديمة أو المستبدلة تلقائيًا. كل شيء آخر يعمل؛ أعد تشغيل المثبّت لاستعادتها."
MSG_WARN_EXPORT_SCAN_NOT_LOADED="تعذر تشغيل مراقب التنزيلات، لذلك لن يتم التقاط الملفات التي تضعها في التنزيلات تلقائيًا. كل ما تم استيراده سابقًا لا يتأثر، ويمكنك إضافة الملفات من داخل التطبيق. أعد تشغيل المثبّت لاستعادته."
MSG_WARN_DEFERRED_DEVICE_REGISTRATION_NOT_LOADED="تعذرت جدولة أداة إعادة المحاولة لتسجيل الجهاز. إذا تم تسجيل iPhone أثناء الإعداد فلن يتغير شيء؛ وإن لم يتم، فستحتاج إلى الاقتران مرة أخرى من التطبيق بدلًا من أن يكتمل تلقائيًا."
# v1.0.38 walk (2026-08-23): a green install finished on a Mac with the
# Docker CLI present and no engine behind it. On macOS `docker` is a client;
# these strings keep the two apart in everything the customer reads.
MSG_OK_CONTAINER_ENGINE_ANSWERED="بيئة الحاويات تستجيب"
MSG_OK_STALE_COLIMA_LAUNCHAGENT_REMOVED="تمت إزالة عنصر بدء تشغيل Colima قديم تركه إصدار أقدم"
MSG_OK_CONFIG_SAVED_ENV="تم حفظ الإعدادات في %s/.env"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE="تم حفظ سجلات الموافقة والمنطقة في ~/.ostler/posture/"
MSG_OK_AT_REST_EXCLUDED="مستثنى من Spotlight وTime Machine (تم التحقق): %s"
MSG_WARN_AT_REST_NOT_EXCLUDED="%s غير مستثنى من Time Machine أو Spotlight: %s. قد يتم نسخ محتوياته، بما فيها أسرار Ostler، إلى قرص النسخ الاحتياطي. ستواصل لوحة Doctor عرض هذا التنبيه إلى أن تتم معالجته."
MSG_INFO_AT_REST_FOLDER_ABSENT="%s غير موجود بعد، لذلك لا يوجد ما يُستثنى من النسخ الاحتياطي."
MSG_WARN_DB_KEY_NOT_EXCLUDED="ملف مفتاح قاعدة البيانات %s غير مستثنى من Time Machine، لذلك قد يتم نسخه إلى قرص النسخ الاحتياطي."
MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED="تعذر حفظ اختيارك الخاص بالإثراء في الخلفية في ~/.ostler/posture/. لا يزال اختيارك مطبقًا على هذا التثبيت، لكنه لن يظهر في تقرير الدعم."
# The old text read "Databases encrypted. Passphrase required at each
# startup." Both halves were false. Nothing delivered the key to the
# services, so the databases were plaintext; and no service, agent or UI
# has ever asked for the passphrase at startup, so nothing was required
# at any startup. The key ID is left alone: renaming it would churn every
# translation catalogue for a copy fix.
MSG_OK_DATABASES_ENCRYPTED_PASSPHRASE_REQUIRED_EACH_STARTUP="تم تشفير قواعد البيانات. تقرأ خدمات Hub المفتاح من ملف محمي في مجلدك الرئيسي، لذلك تبدأ دون أن تطلب منك شيئًا."
MSG_OK_DB_KEY_DELIVERED="تم تسليم مفتاح قاعدة البيانات إلى خدمات Hub (%s، ولا يقرأه سواك)."
MSG_WARN_DB_KEY_NOT_DELIVERED="تعذر تسليم مفتاح قاعدة البيانات إلى خدمات Hub. ستفتح قواعد البيانات دون تشفير إلى أن تتم المعالجة."
MSG_INFO_DB_KEY_RECOVER_HINT="شغّل هذا الأمر لاستعادته وتسليمه: %s/.venv/bin/ostler-unlock --install-key-file"
MSG_INFO_DB_MIGRATION_RUNNING="جارٍ تشفير أي قواعد بيانات متبقية من تثبيت سابق"
MSG_WARN_DB_MIGRATION_FAILED="تعذر تشفير بعض قواعد البيانات الموجودة. ما زالت قابلة للقراءة على القرص."
MSG_WARN_DB_KEY_MISSING_ON_RERUN="لا يحتوي هذا التثبيت على ملف مفتاح لقاعدة البيانات، لذلك تفتح خدمات Hub قواعد البيانات دون تشفير."
MSG_WARN_DB_PLAINTEXT_COUNT="%s من قواعد البيانات على هذا الـ Mac قابلة للقراءة على القرص الآن."
MSG_INFO_DB_MIGRATE_HINT="ثم شفّر ما هو موجود بالفعل: %s/.venv/bin/ostler-migrate-dbs"
MSG_OK_DEFERRED_DEVICE_REGISTRATION_RETRY_INSTALLED_RUNS="تم تثبيت إعادة المحاولة المؤجلة لتسجيل الجهاز (تعمل كل ساعة إلى أن تفرغ قائمة الانتظار)"
MSG_OK_DOCKER_RUNNING="Docker قيد التشغيل"
MSG_OK_DOCKER_RUNNING_TOOK_S="Docker قيد التشغيل (استغرق %s ثانية)"
MSG_OK_DOCTOR_AGENT_CLONED_FROM="تم نسخ وكيل Doctor من %s"
MSG_OK_DOCTOR_AGENT_FILES_BUNDLED_WITH_INSTALLER="ملفات وكيل Doctor مضمّنة مع المثبّت"
MSG_OK_DOCTOR_DEPENDENCIES_INSTALLED="تم تثبيت تبعيات Doctor"
MSG_OK_EMAIL_CHANNEL_FOLDER="قناة البريد الإلكتروني: %s (المجلد: %s)"
MSG_OK_EMAIL_INGEST_LAUNCHAGENT_LOADED_LABEL_COM="تم تحميل LaunchAgent لاستيعاب البريد الإلكتروني (التسمية com.creativemachines.ostler.email-ingest)"
MSG_OK_EMAIL_INGEST_SCRIPTS_BUNDLED_WITH_INSTALLER="نصوص استيعاب البريد الإلكتروني مضمّنة مع المثبّت"
MSG_OK_EMAIL_INGEST_SCRIPTS_CLONED_FROM="تم نسخ نصوص استيعاب البريد الإلكتروني من %s"
# Conversation-memory body feeds (4-artefact). One MSG_* set per feed,
# keyed by the uppercased feed name so _install_conversation_feed can
# derive them. WhatsApp copy keeps the locked depth framing ("about the
# last year"); never "full history" or "every message".
MSG_PROGRESS_WHATSAPP_BUNDLE="جارٍ إعداد ذاكرة محادثات WhatsApp"
MSG_OK_WHATSAPP_SOURCE_INSTALLED="  تم تثبيت قارئ محادثات WhatsApp."
MSG_WARN_WHATSAPP_SOURCE_FAILED="فشل تثبيت قارئ محادثات WhatsApp؛ لن يعمل مصدر محادثات WhatsApp. راجع المخرجات أعلاه."
MSG_WARN_WHATSAPP_SOURCE_SRC_NOT_FOUND="لم يتم العثور على مصدر قارئ محادثات WhatsApp؛ سيتم تخطي مصدر محادثات WhatsApp."
MSG_WARN_WHATSAPP_BUNDLE_VENDOR_MISSING="لم يتم العثور على حزمة مصدر محادثات WhatsApp في هذا المثبّت؛ سيتم التخطي. سجل رسائل WhatsApp (من راسلتَ ومتى) لا يتأثر."
MSG_OK_WHATSAPP_BUNDLE_LOADED="تم تحميل LaunchAgent لمصدر محادثات WhatsApp (التسمية com.creativemachines.ostler.whatsapp-bundle)"
MSG_INFO_WHATSAPP_BUNDLE_TICK="  تقرأ الدفعة الأولى محادثات WhatsApp الحديثة التي زامنها جهاز Mac لديك (نحو آخر سنة)، وتبقى على Mac لديك."
MSG_INFO_WHATSAPP_BUNDLE_LOGS="  السجلات: %s/whatsapp-bundle.log و whatsapp-bundle.err"
MSG_WARN_WHATSAPP_BUNDLE_FAILED="فشل تثبيت LaunchAgent لمصدر محادثات WhatsApp. راجع المخرجات أعلاه؛ لا يتأثر باقي التثبيت."
# Shared by all four conversation feeds: the refusal that keeps a LaunchAgent
# from being started against a program that is not on disk yet. It names the
# exact path it looked for, because a refusal that does not say what was
# missing sends the reader hunting.
MSG_WARN_BUNDLE_DAEMON_BINARY_MISSING="  لم يبدأ بعد: برنامج المساعد الذي يشغّله هذا الوكيل غير موجود على القرص. تم البحث عن: %s"
# Email body feed (Apple Mail). Reads recent threads (about the last month).
MSG_PROGRESS_EMAIL_BUNDLE="جارٍ إعداد ذاكرة محادثات البريد الإلكتروني"
MSG_OK_EMAIL_SOURCE_INSTALLED="  تم تثبيت قارئ محادثات البريد الإلكتروني."
MSG_WARN_EMAIL_SOURCE_FAILED="فشل تثبيت قارئ محادثات البريد الإلكتروني؛ لن يعمل مصدر محادثات البريد الإلكتروني. راجع المخرجات أعلاه."
MSG_WARN_EMAIL_SOURCE_SRC_NOT_FOUND="لم يتم العثور على مصدر قارئ محادثات البريد الإلكتروني؛ سيتم تخطي مصدر محادثات البريد الإلكتروني."
MSG_WARN_EMAIL_BUNDLE_VENDOR_MISSING="لم يتم العثور على حزمة مصدر محادثات البريد الإلكتروني في هذا المثبّت؛ سيتم التخطي. استيعاب البريد الإلكتروني كل ساعة لا يتأثر."
MSG_OK_EMAIL_BUNDLE_LOADED="تم تحميل LaunchAgent لمصدر محادثات البريد الإلكتروني (التسمية com.creativemachines.ostler.email-bundle)"
MSG_INFO_EMAIL_BUNDLE_TICK="  يقرأ سلاسل بريدك الإلكتروني الحديثة من المخزن المحلي لتطبيق Apple Mail؛ كل شيء يبقى على Mac لديك."
MSG_INFO_EMAIL_BUNDLE_LOGS="  السجلات: %s/email-bundle.log و email-bundle.err"
MSG_WARN_EMAIL_BUNDLE_FAILED="فشل تثبيت LaunchAgent لمصدر محادثات البريد الإلكتروني. راجع المخرجات أعلاه؛ لا يتأثر باقي التثبيت."
# Meeting / voice body feed (your own CM042 recordings).
MSG_PROGRESS_SPOKEN_BUNDLE="جارٍ إعداد ذاكرة محادثات الاجتماعات والصوت"
MSG_OK_SPOKEN_SOURCE_INSTALLED="  تم تثبيت قارئ محادثات الاجتماعات والصوت."
MSG_WARN_SPOKEN_SOURCE_FAILED="فشل تثبيت قارئ محادثات الاجتماعات والصوت؛ لن يعمل المصدر. راجع المخرجات أعلاه."
MSG_WARN_SPOKEN_SOURCE_SRC_NOT_FOUND="لم يتم العثور على مصدر قارئ محادثات الاجتماعات والصوت؛ سيتم تخطي المصدر."
MSG_WARN_SPOKEN_BUNDLE_VENDOR_MISSING="لم يتم العثور على حزمة مصدر محادثات الاجتماعات والصوت في هذا المثبّت؛ سيتم التخطي."
MSG_OK_SPOKEN_BUNDLE_LOADED="تم تحميل LaunchAgent لمصدر محادثات الاجتماعات والصوت (التسمية com.creativemachines.ostler.spoken-bundle)"
MSG_INFO_SPOKEN_BUNDLE_TICK="  يحوّل اجتماعاتك وملاحظاتك الصوتية إلى نصوص محادثات قابلة للبحث؛ كل شيء يبقى على Mac لديك."
MSG_INFO_SPOKEN_BUNDLE_LOGS="  السجلات: %s/spoken-bundle.log و spoken-bundle.err"
MSG_WARN_SPOKEN_BUNDLE_FAILED="فشل تثبيت LaunchAgent لمصدر محادثات الاجتماعات والصوت. راجع المخرجات أعلاه؛ لا يتأثر باقي التثبيت."
# iMessage body feed (Messages chat.db). Reads recent threads (about the last month).
MSG_PROGRESS_IMESSAGE_BUNDLE="جارٍ إعداد ذاكرة محادثات iMessage"
MSG_OK_IMESSAGE_SOURCE_INSTALLED="  تم تثبيت قارئ محادثات iMessage."
MSG_WARN_IMESSAGE_SOURCE_FAILED="فشل تثبيت قارئ محادثات iMessage؛ لن يعمل مصدر محادثات iMessage. راجع المخرجات أعلاه."
MSG_WARN_IMESSAGE_SOURCE_SRC_NOT_FOUND="لم يتم العثور على مصدر قارئ محادثات iMessage، وسيتم تخطي خلاصة محادثات iMessage."
MSG_WARN_IMESSAGE_BUNDLE_VENDOR_MISSING="لم يتم العثور على حزمة خلاصة محادثات iMessage في هذا المثبّت، وسيتم التخطي."
MSG_OK_IMESSAGE_BUNDLE_LOADED="تم تحميل LaunchAgent لخلاصة محادثات iMessage (التسمية com.creativemachines.ostler.imessage-bundle)"
MSG_INFO_IMESSAGE_BUNDLE_TICK="  يقرأ محادثات iMessage الأخيرة من مخزن الرسائل في جهاز Mac هذا، وتبقى جميع البيانات على جهاز Mac لديك."
MSG_INFO_IMESSAGE_BUNDLE_LOGS="  السجلات: %s/imessage-bundle.log و imessage-bundle.err"
MSG_WARN_IMESSAGE_BUNDLE_FAILED="فشل تثبيت LaunchAgent لخلاصة محادثات iMessage. راجع المخرجات أعلاه، أما بقية التثبيت فلم تتأثر."
MSG_OK_EMBEDDING_MODEL_READY="نموذج التضمين جاهز"
MSG_OK_EXPORTED_CONTACTS_WILL_IMPORT_AUTOMATICALLY="تم تصدير %s من جهات الاتصال (سيتم استيرادها تلقائياً)"
MSG_OK_EXPORT_WATCHER_INSTALLED_SCANS_DOWNLOADS_EVERY="تم تثبيت مراقب التصدير (يفحص مجلد التنزيلات كل 4 ساعات)"
# The export watcher's refusal names the exact path it looked for, so the
# install log does not send the reader hunting for what was missing.
MSG_WARN_EXPORT_SCAN_DAEMON_BINARY_MISSING="  لم يبدأ مراقب التصدير بعد: برنامج المساعد الذي يشغّله غير موجود على القرص. تم البحث في: %s"
MSG_OK_MEETING_BRIEF_SENDER_INSTALLED="تم تثبيت مرسل الملخص قبل الاجتماعات (يتحقق كل 10 دقائق خلال ساعات اليقظة)"
MSG_OK_MEMORY_HYGIENE_INSTALLED="تمت جدولة تنظيف الذاكرة (يعمل يومياً لمنع الحقائق القديمة من مزاحمة الحالية)"
MSG_OK_STAY_AWAKE_AGENT_INSTALLED="سيبقى جهاز Mac لديك مستيقظاً عند توصيله بالكهرباء كي يواصل Ostler عمله (وينام عند العمل على البطارية)"
MSG_OK_EXTRACTED="تم الاستخراج إلى %s"
MSG_OK_EXTRACTED_FROM_SOURCE_S_DATA_SAVED="تم الاستخراج من %s مصدر. تم حفظ البيانات في %s/imports/fda/"
MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="تمت جدولة إعادة تشغيل FDA كل %s دقيقة (لالتقاط مزامنات iCloud البطيئة وإكمال جلب بيانات التقويم السابقة)"
MSG_OK_FIRST_MONTH_FREE_ACTIVATED="Ostler Pro مفعّل لمدة 30 يوماً. اشترك في تطبيق Ostler على iPhone للتمديد بعد انتهاء الفترة التجريبية."
MSG_OK_FOUND="تم العثور على: %s"
MSG_OK_FOUND_EXPORTS="تم العثور على ملفات التصدير في %s"
MSG_OK_FOUND_GDPR_EXPORT_S="تم العثور على %s من ملفات تصدير GDPR:"
MSG_OK_GB_FREE_DISK_SPACE="%s غيغابايت من المساحة المتاحة على القرص"
MSG_OK_GB_RAM_DETECTED="تم اكتشاف %s غيغابايت من الذاكرة RAM"
MSG_OK_GDPR_IMPORT_COMPLETE="اكتمل استيراد GDPR"
MSG_OK_GIT_AVAILABLE="Git متاح"
MSG_OK_GIT_CLT_INSTALL_TRIGGERED_BACKGROUND="تم بدء تثبيت أدوات سطر الأوامر (يجري التنزيل في الخلفية أثناء إجابتك عن الأسئلة أدناه)."
MSG_OK_COREUTILS_GTIMEOUT_INSTALLED="تم تثبيت GNU coreutils (أصبح للخطوات الطويلة الآن حد زمني)"
MSG_OK_HOMEBREW_INSTALLED="تم تثبيت Homebrew"
MSG_OK_HUB_POWER_LAUNCHAGENT_LOADED_LABEL_COM="تم تحميل LaunchAgent لطاقة Hub (التسمية com.creativemachines.ostler.hub-power)"
MSG_OK_HUB_POWER_SCRIPTS_BUNDLED_WITH_INSTALLER="نصوص طاقة Hub مضمّنة مع المثبّت"
MSG_OK_HUB_POWER_SCRIPTS_CLONED_FROM="تم استنساخ نصوص طاقة Hub من %s"
MSG_OK_ICAL_SERVER_INSTALLED="تم تثبيت واجهة برمجة المساعد (loopback 127.0.0.1:8090، عبر وسيط Doctor)"
MSG_OK_IMESSAGE_AUTOMATION_PERMISSION_GRANTED="iMessage Automation permission: granted"
MSG_OK_IMESSAGE_BRIDGE_INSTALLED="تم تحميل LaunchAgent لجسر iMessage (التسمية com.ostler.imessage-bridge)"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_BUNDLED_WITH_INSTALLER="نصوص جسر iMessage مضمّنة مع المثبّت"
MSG_OK_IMESSAGE_BRIDGE_SCRIPTS_CLONED_FROM="تم استنساخ نصوص جسر iMessage من %s"
MSG_OK_IMESSAGE_CHANNEL="قناة iMessage: %s"
MSG_OK_IMPORT_PIPELINE_BUNDLED_WITH_INSTALLER="مسار الاستيراد مضمّن مع المثبّت"
MSG_OK_IMPORT_PIPELINE_READY="مسار الاستيراد جاهز"
MSG_OK_CM048_PIPELINE_READY="محرك ذاكرة المحادثات جاهز."
MSG_INFO_CM048_SETTINGS_WRITTEN="  تم ضبط نماذج المحادثة على %s (بما يلائم %s غيغابايت من ذاكرتك)"
MSG_INFO_CM048_SETTINGS_KEPT="  سيتم الإبقاء على إعدادات المحادثة الحالية (%s)"
MSG_OK_KNOWLEDGE_SERVICE_READY="خدمة المعرفة جاهزة: %s"
MSG_OK_LICENCE_TEXTS_INSTALLED_SOURCE="تم تثبيت نصوص التراخيص في %s/ (المصدر: %s)"
MSG_OK_MACOS_DETECTED="تم اكتشاف macOS %s"
MSG_OK_MAIL_OPENING_INTERNET_ACCOUNTS="جارٍ فتح إعدادات النظام > حسابات الإنترنت لتتمكن من إضافة حساب بريد. عد إلى هذه النافذة بعد تسجيل الدخول إلى حسابك الأول."
MSG_OK_MAIL_SKIPPING_INTERNET_ACCOUNTS="تم تخطي خطوة حسابات الإنترنت. يمكنك إضافة حساب بريد لاحقًا من إعدادات النظام؛ وسيعرض Doctor متابعة إذا لم يصل أي بريد خلال 24 ساعة."
MSG_OK_MAIL_EXTENDING_FULL_HISTORY="جارٍ سحب سجل Apple Mail الكامل الآن. قد يستغرق ذلك وقتًا أطول قليلًا مع صندوق بريد كبير."
MSG_OK_MAIL_KEEPING_DEFAULT_HISTORY="سيتم الإبقاء على الفترة القياسية للبريد البالغة خمس سنوات. يمكنك سحب المزيد لاحقًا من Doctor."
MSG_OK_NOMIC_EMBED_TEXT_ALREADY_AVAILABLE="nomic-embed-text متوفر بالفعل"
MSG_OK_OLLAMA_HEALTHY="Ollama healthy"
MSG_OK_OLLAMA_INSTALLED="تم تثبيت Ollama"
MSG_OK_OLLAMA_INSTALLED_CLI_ONLY_MAY_NEED="تم تثبيت Ollama (واجهة الأوامر فقط – قد يلزم تشغيله يدويًا بعد إعادة التشغيل)"
MSG_OK_OLLAMA_INSTALLED_DESKTOP_APP="تم تثبيت Ollama (تطبيق سطح المكتب)"
MSG_OK_OLLAMA_RUNNING="Ollama قيد التشغيل"
MSG_OK_EMBEDDINGS_VERIFIED="تم التحقق من محرك التضمين (متجهات من 768 بُعدًا)"
MSG_OK_OSTLER_ASSISTANT_DOCTOR_NO_ERRORS_DETECTED="ostler-assistant doctor: 0 أخطاء في فحوصات بدء التشغيل الخاصة به"
MSG_OK_OSTLER_ASSISTANT_LAUNCHAGENT_LOADED_LABEL_COM="تم تحميل LaunchAgent الخاص بمساعد Ostler (التسمية com.creativemachines.ostler.assistant)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_SIGNED="تم تجهيز ostler-assistant v%s في %s (موقّع)"
MSG_OK_OSTLER_ASSISTANT_V_STAGED_UNSIGNED="تم تجهيز ostler-assistant v%s في %s (غير موقّع)"
MSG_OK_OSTLER_DOCTOR_RUNNING_HTTP_LOCALHOST_8089="Ostler Doctor قيد التشغيل على http://localhost:8089/doctor"
MSG_OK_FDA_DEPENDENCIES_IMPORTABLE="  وحدة استخراج البيانات تُحمَّل بشكل صحيح."
MSG_OK_OSTLER_FDA_INSTALLED_VENV="  تم تثبيت قارئ Apple Mail."
MSG_OK_PWG_EMAIL_INGEST_INSTALLED="  تم تثبيت محرك استيعاب البريد الإلكتروني."
MSG_OK_OSTLER_IMPORT_OSTLER_FDA_OSTLER_UNINSTALL="تم تثبيت الأوامر ostler-import وostler-fda وostler-uninstall"
MSG_OK_OXIGRAPH_HEALTHY="Oxigraph healthy"
MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3="تم تسجيل عبارة المرور. ستُستخدم لتشفير قواعد بياناتك خلال المرحلة 3."
MSG_OK_RECOVERY_PASSPHRASE_CONFIGURED="تم إعداد عبارة مرور الاسترداد."
MSG_OK_PASSPHRASE_BRIEFING_ACKNOWLEDGED="تم تأكيد الاطلاع على إرشادات عبارة المرور."
MSG_OK_DISNEY_XLSX_PASSWORD_CAPTURED="تم تسجيل كلمة مرور تصدير Disney+. ستُستخدم أثناء الاستيراد."
MSG_INFO_DISNEY_XLSX_PASSWORD_SKIPPED="تم تخطي تصدير Disney+: لم تُدخل كلمة مرور. لا يتأثر أي شيء آخر."
MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO="مصدر الطاقة: تيار متردد (Mac مكتبي، بلا بطارية)"
# NEEDS REVIEW: source asks for human translation of this key
MSG_OK_POWER_SOURCE_AC_GOOD_10_15="مصدر الطاقة: تيار متردد (جيد – قد يستغرق التثبيت من 45 دقيقة إلى عدة ساعات، والتيار الكهربائي يبقيه مستقرًا)"
MSG_OK_PREVIOUS_INSTALLATION_DETECTED_LOADING_CONFIG="تم اكتشاف تثبيت سابق. جارٍ تحميل الإعدادات..."
MSG_OK_PYTHON="Python %s"
MSG_OK_PYTHON_BUNDLED="استخدام Python %s المضمّن (لا حاجة إلى تثبيت على النظام)"
MSG_OK_PYTHON_INSTALLED="تم تثبيت Python %s"
MSG_OK_QDRANT_HEALTHY="Qdrant healthy"
# v1.0.10 P1: loopback control-plane liveness (pairing + data tab).
MSG_OK_GATEWAY_HEALTHY="خدمة الإقران تعمل بشكل سليم"
MSG_WARN_GATEWAY_NOT_RESPONDING="خدمة الإقران لا تستجيب (127.0.0.1:8000) - قد لا يعمل إقران الهاتف أو المتصفح ولا مساعد الدردشة بعد"
MSG_OK_DOCTOR_HEALTHY="Doctor يعمل بشكل سليم"
MSG_WARN_DOCTOR_NOT_RESPONDING="Doctor لا يستجيب (127.0.0.1:8089) - يصل التطبيق والمتصفح إلى Ostler عبره، لذا قد تكون البيانات والإقران غير متاحين"
MSG_OK_WIKI_HEALTHY="الويكي الخاص بك يعمل بشكل سليم"
MSG_OK_ICAL_SERVER_HEALTHY="واجهة برمجة المساعد تعمل بشكل سليم"
MSG_WARN_ICAL_SERVER_NOT_RESPONDING="واجهة برمجة المساعد لا تستجيب (127.0.0.1:8090) - قد تكون أقسام الأشخاص والاجتماعات والجدول الزمني فارغة إلى أن تبدأ"
MSG_OK_READY="%s جاهز"
MSG_OK_RECOMMENDED_SOURCES_SELECTED="تم اختيار المصادر الموصى بها"
MSG_OK_RECOVERY_KEY_SAVED_KEYCHAIN_SEARCH_OSTLER="تم حفظ مفتاح الاسترداد في سلسلة المفاتيح (ابحث عن 'Ostler' في تطبيق كلمات السر)"
MSG_OK_REDIS_HEALTHY="Redis healthy"
MSG_OK_SAFARI_EXTENSION_INSTALLED="تم تثبيت امتداد Safari في %s"
MSG_OK_SAFARI_EXTENSION_PAIRED="تم اقتران امتداد Safari بهذا الـ Hub"
MSG_OK_SECURITY_ALREADY_CONFIGURED_PREVIOUS_RUN="تم إعداد الأمان مسبقًا في تشغيل سابق."
MSG_OK_SECURITY_MODULE_INSTALLED_INTO_VENV="تم تثبيت وحدة الأمان في venv"
MSG_OK_SEEDED_FRESH_JWT_SECRET="تم إنشاء JWT_SECRET جديد في %s"
MSG_OK_SEEDED_PWG_SERVICE_TOKEN="تم إنشاء رمز خدمة PWG في %s"
MSG_OK_SEEDED_EXTENSION_TOKEN="تم إنشاء مفتاح امتداد المتصفح في %s"
MSG_OK_SERVICES_STARTED_QDRANT_6333_OXIGRAPH_7878="تم تشغيل الخدمات (Qdrant :6333، Oxigraph :7878، Redis :6379)"
# ── Qdrant collection pre-create + import gate (#606 / v1061-D003) ──
MSG_INFO_QDRANT_COLLECTION_PRECREATED="  تم تجهيز مجموعة البحث: %s"
MSG_WARN_QDRANT_COLLECTION_PRECREATE_FAILED="تعذر تجهيز مجموعة البحث %s حتى الآن؛ ستعيد عملية استيراد البيانات أدناه المحاولة، وستتوقف بدل التخلص من بياناتك إذا تعذر ذلك أيضًا."
MSG_WARN_QDRANT_NOT_READY_COLLECTIONS_SKIPPED="فهرس البحث ليس جاهزًا في الوقت المناسب بعد؛ ستنتظره عملية استيراد البيانات أدناه وتجهّز المجموعات، وستتوقف بدل التخلص من بياناتك إذا ظل المخزن غير جاهز."
MSG_FAIL_QDRANT_IMPORT_REFUSED_MISSING_COLLECTIONS="لم يتم استيراد بياناتك. تعذر تجهيز مخزن البحث لاستيعابها (المفقود: %s)، وكان الاستيراد رغم ذلك سيتخلص منها بصمت. لم يُفقد شيء. أعد تشغيل المثبّت عندما يكون الجهاز خاملًا، أو اضبط OSTLER_QDRANT_READY_WAIT_S لانتظار مدة أطول."
MSG_FAIL_IMPORT_ATTEMPTED_BUT_STORED_NOTHING="عالجت عملية استيراد بياناتك %s من السجلات لكنها لم تخزّن أيًا منها؛ فقد رفض مخزن البحث كل سجل، وكانت النتيجة ستكون رسمًا معرفيًا فارغًا يُعرض على أنه مكتمل. تم الإيقاف بدل عرض ذلك عليك. أعد تشغيل المثبّت عندما يكون الجهاز خاملًا."
MSG_WARN_IMPORT_YIELD_UNMEASURABLE="تعذرت قراءة سجل الاستيراد نفسه، لذا لم يمكن تشغيل التحقق من وصول بياناتك فعليًا. هذا ليس إبلاغًا بفشل الاستيراد، وليس إبلاغًا بنجاحه."
MSG_OK_SLEEP_DISABLED_AC_BATTERY_SLEEP_PRESERVED="تم تعطيل السكون عند التوصيل بالكهرباء، والإبقاء على السكون عند استخدام البطارية، وتمكين الاستيقاظ عبر الشبكة"
MSG_OK_SLEEP_DISABLED_WAKE_NETWORK_ENABLED="تم تعطيل السكون وتمكين الاستيقاظ عبر الشبكة"
MSG_OK_TAILSCALE_ALREADY_INSTALLED="Tailscale مثبّت مسبقًا"
MSG_OK_TAILSCALE_INSTALLED="تم تثبيت Tailscale"
MSG_OK_TAILSCALE_ENV_PERSISTED="تم حفظ عنوان IP الخاص بـ Tailscale في .env – سيستخدمه تطبيق Ostler على iPhone عند أول تشغيل."
MSG_OK_TAILSCALE_IP="عنوان IP الخاص بـ Tailscale: %s"
# ── Tailscale userspace formula path (#604) ──
MSG_OK_TAILSCALED_USERSPACE_STARTED="تم تشغيل خدمة Tailscale في الخلفية (وضع مساحة المستخدم، دون امتداد نظام)"
MSG_WARN_TAILSCALED_USERSPACE_START_FAILED="تعذر تشغيل خدمة Tailscale في الخلفية. يمكنك إعادة تشغيل الإعداد لاحقًا من الإعدادات."
MSG_INFO_TAILSCALE_SIGN_IN_URL="جارٍ فتح المتصفح لتسجيل الدخول إلى Tailscale: %s"
MSG_INFO_TAILSCALE_SERVE_PORT="تمت إتاحة منفذ Hub %s على tailnet الخاصة بك"
MSG_WARN_TAILSCALE_SERVE_PORT_FAILED="تعذرت إتاحة منفذ Hub %s على tailnet الخاصة بك؛ قد يكون الوصول من خارج الشبكة المحلية محدودًا"
# ── Wiki on the tailnet, owner-gated (v1.0.17) ──
MSG_OK_WIKI_TAILNET_SERVED="يمكن الآن قراءة الويكي الخاص بك من أجهزتك على %s – بتسجيل الدخول باسمك أنت وحدك."
MSG_INFO_WIKI_TAILNET_OWNER="الوصول إلى الويكي مقصور على حسابك في Tailscale (%s). يحصل الآخرون على tailnet الخاصة بك على الخطأ 403."
MSG_INFO_WIKI_TAILNET_LOCAL_ONLY="يبقى الويكي الخاص بك على هذا الـ Mac فقط. افتح Ostler واختر الويكي في الشريط الجانبي لقراءته."
MSG_INFO_WIKI_TAILNET_BANNER="%s  (من أجهزتك، عبر Tailscale. هذا هو المسار الوحيد الذي يطلب منك تسجيل الدخول أعلاه.)"
# CM051 #1980. Where the wiki actually opens. :8044 answers an
# uncredentialled browser with a signpost and no challenge (see the
# `listen 8044` server block in install.sh), so the address is named for
# what it is rather than offered as a destination.
MSG_INFO_WIKI_IN_THE_APP="في تطبيق Ostler. افتح Ostler واختر الويكي في الشريط الجانبي؛ صفحاتك هناك، وقد سُجّل دخولك بالفعل."
MSG_INFO_WIKI_INTERNAL_ADDRESS="يجلب Ostler تلك الصفحات من http://localhost:8044 على هذا الـ Mac. هذا العنوان داخلي وليس فيه ما تسجّل الدخول إليه."
MSG_INFO_WIKI_SIGN_IN="تسجيل دخولك إلى الويكي هو %s وكلمة السر %s. يقدّمها Ostler نيابةً عنك، فلا شيء تكتبه على هذا الـ Mac؛ ولا تحتاج إليها إلا عند فتح الويكي من جهاز آخر لك عبر Tailscale."
MSG_INFO_WIKI_SIGN_IN_WITHHELD="تسجيل دخولك إلى الويكي هو %s. كلمة السر غير مكتوبة في هذا السجل؛ هي في الحافظة وفي الملف المذكور أدناه. يقدّمها Ostler نيابةً عنك، فلا شيء تكتبه على هذا الـ Mac."
MSG_INFO_WIKI_PORT_LAST_STATUS="آخر حالة HTTP من منفذ الويكي: %s (000 تعني أنه لم يستجب شيء؛ و403 تعني أنه استجاب ورفض بيانات الاعتماد)."
# HR015 #943. The four lines below are the readiness half of the wiki handover.
# They exist because the credential half is no longer gated on them: a customer
# whose first build is merely slow still gets their address and sign-in, and
# only this line changes. None of them may name a cause the run did not
# measure, which is what "first compile failed" did on every one of the three
# non-failure paths into that branch.
MSG_INFO_WIKI_PASSWORD_ON_DISK="كلمة السر محفوظة أيضًا في %s، فالحافظة ليست النسخة الوحيدة."
MSG_INFO_WIKI_STILL_BUILDING="لا يزال البناء جاريًا. هناك %s صفحة على القرص بالفعل، وكان آخر رد من عنوان الويكي HTTP %s. سيظهر في تطبيق Ostler من تلقاء نفسه. لا شيء عليك فعله."
MSG_WARN_WIKI_FIRST_COMPILE_PRODUCED_NO_PAGES="لم ينتج البناء الأول أي صفحات بعد (راجع التحذيرات أعلاه). سيُفتح الويكي الخاص بك في تطبيق Ostler بمجرد اكتمال بنائه، ويبقى تسجيل الدخول أعلاه لك."
MSG_INFO_WIKI_READINESS_NOT_MEASURED="لم تقس هذه العملية ما إذا كانت الويكي تعمل حاليًا، لذلك لا تقدّم أي ادعاء في هذا الشأن. تُفتح الويكي في تطبيق Ostler في كل الأحوال، ويبقى تسجيل الدخول أعلاه خاصًا بك."
MSG_WARN_WIKI_TAILNET_OWNER_UNRESOLVED="تعذّر التأكد من حساب Tailscale الذي يملك هذا الـ Mac، لذلك لم يتم إتاحة الويكي على شبكة tailnet الخاصة بك. وهي لا تزال متاحة على هذا الـ Mac، في تطبيق Ostler ضمن Wiki."
MSG_WARN_WIKI_TAILNET_SERVE_FAILED="تعذّر نشر الويكي على شبكة tailnet الخاصة بك؛ وهي لا تزال متاحة على هذا الـ Mac، في تطبيق Ostler ضمن Wiki."
MSG_WARN_WIKI_TAILNET_GATE_RELOAD_FAILED="تعذّرت إعادة تحميل بوابة الوصول إلى الويكي، لذلك لم تتم إتاحة الويكي على شبكة tailnet الخاصة بك."
MSG_WARN_WIKI_TAILNET_FUNNEL_ON="ميزة Tailscale Funnel مفعّلة على %s. تنشر Funnel المحتوى على الإنترنت المفتوح. لا يفعّل Ostler ميزة Funnel أبدًا، وترفض الويكي الخاصة بك حركة Funnel، لذا لا شيء من Ostler متاح للعامة – ولكن إن لم تقصد تفعيلها، فأوقفها من وحدة إدارة Tailscale لهذا الجهاز."
MSG_OK_THIRD_PARTY_ATTRIBUTIONS_INSTALLED_SOURCE="تم تثبيت إشعارات الجهات الخارجية (المصدر: %s)"
MSG_OK_USER_FACING_TREE_READY="شجرة الملفات الموجّهة للمستخدم جاهزة"
MSG_OK_USING_OSTLER_FOLDER_LABEL_INSTEAD="سيتم استخدام المجلد/التسمية 'Ostler' بدلًا من ذلك."
MSG_OK_VANE_HEALTHY_LOCAL_WEB_SEARCH="Vane يعمل بشكل سليم (بحث ويب محلي)"
MSG_OK_VANE_RUNNING_HTTP_LOCALHOST_3000_TALKS="Vane يعمل على http://localhost:3000 (ويتصل بـ Ollama المحلي لديك)"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_OK_WHATSAPP_CONNECTOR_WILL_ENABLED_CONSENT_RECORDED="سيتم تفعيل موصّل WhatsApp (تم تسجيل الموافقة)"
MSG_OK_WIKI_RECOMPILE_CATCHUP_LOADED="تم تحميل LaunchAgent للّحاق بالويكي في اليوم الأول (يعيد بناء الويكي كل 30 دقيقة خلال الساعات الأولى، ثم يتوقف)"
# ── Deferred whole-graph dedupe converge (v1.0.2) ──
MSG_INFO_DEDUPE_STILL_MERGING="لا يزال دمج جهات الاتصال المكررة جاريًا – قد تستغرق دفاتر العناوين الكبيرة عدة دقائق (انقضت %s ث)"
MSG_INFO_DEDUPE_MERGED="تم دمج جهات الاتصال المكررة"
MSG_INFO_DEDUPE_DEFERRED_BACKGROUND="يستغرق دمج جهات الاتصال المكررة وقتًا طويلًا في دفتر عناوين بهذا الحجم. سيستمر في الخلفية بعد التثبيت – وتتحدّث الويكي تلقائيًا عند انتهائه."
MSG_WARN_DEDUPE_INCOMPLETE="لم تكتمل عملية إزالة التكرار على كامل الرسم البياني بشكل سليم (راجع %s)؛ جارٍ المتابعة"
MSG_INFO_DEDUPE_COMPLETE_NO_CATCHUP="تم دمج جهات الاتصال المكررة بالكامل أثناء التثبيت؛ لا حاجة إلى لحاق في الخلفية"
MSG_OK_DEDUPE_CATCHUP_LOADED="تم تحميل LaunchAgent لإزالة تكرار جهات الاتصال في الخلفية (يُنهي دمج المكررات بعد التثبيت، ثم يتوقف)"
MSG_WARN_DEDUPE_CATCHUP_LOAD_FAILED="تعذّر تحميل LaunchAgent لإزالة تكرار جهات الاتصال في الخلفية. سيستمر دمج المكررات عبر الصيانة اليومية، لكن الأمر سيستغرق وقتًا أطول ليستقر."
MSG_OK_ENRICH_AGENT_LOADED="تم تحميل LaunchAgent للإثراء في الخلفية (يضيف تفاصيل عن أفلامك وأماكنك وكتبك وروابطك؛ ويعمل على دفعات خلال اليوم التالي تقريبًا)"
MSG_WARN_ENRICH_AGENT_LOAD_FAILED="تعذّر تحميل LaunchAgent للإثراء في الخلفية. تفضيلاتك محفوظة وقابلة للبحث، لكن ستفتقر إلى تفاصيل مرجعية إضافية (المخرجون، الممثلون، المواقع) إلى حين تشغيله."
MSG_OK_WIKI_RECOMPILE_LAUNCHAGENT_LOADED_LABEL_COM="تم تحميل LaunchAgent لإعادة تجميع الويكي (التسمية com.creativemachines.ostler.wiki-recompile)"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_BUNDLED_WITH_INSTALLER="سكربتات إعادة تجميع الويكي مضمّنة مع المثبّت"
MSG_OK_WIKI_RECOMPILE_SCRIPTS_CLONED_FROM="تم استنساخ سكربتات إعادة تجميع الويكي من %s"
# The Editor -- Front Page refresh LaunchAgent (produces ~/.ostler/editor/front_page.json)
MSG_PROGRESS_EDITOR_FRONTPAGE="جارٍ إعداد صفحتك الأولى (تحديث كل ساعة)"
MSG_OK_EDITOR_FRONTPAGE_BUNDLED="مُنتِج الصفحة الأولى مضمّن مع المثبّت"
MSG_OK_EDITOR_FRONTPAGE_LOADED="تم تحميل LaunchAgent للصفحة الأولى (التسمية com.creativemachines.ostler.editor-frontpage)"
MSG_INFO_EDITOR_FRONTPAGE_FIRST_EMIT="  يعمل التحديث الأول الآن؛ وتكتمل الصفحة الأولى في لوحة المعلومات مع قراءة Ostler لتفضيلاتك."
MSG_INFO_EDITOR_FRONTPAGE_LOGS="  السجلات: %s/editor-frontpage.log و editor-frontpage.err"
MSG_WARN_EDITOR_FRONTPAGE_VENDOR_MISSING="لم يُعثر على مُنتِج الصفحة الأولى في هذا المثبّت؛ لن يتم تحديث الصفحة الأولى في لوحة المعلومات."
MSG_WARN_EDITOR_FRONTPAGE_FAILED="فشل تثبيت LaunchAgent للصفحة الأولى. راجع المخرجات أعلاه؛ ولا يتأثر باقي التثبيت."
MSG_PROGRESS_EDITOR_FRONTPAGE_CATCHUP="جارٍ إعداد اللحاق بالصفحة الأولى"
MSG_OK_EDITOR_FRONTPAGE_CATCHUP_LOADED="تم تحميل LaunchAgent للّحاق بالصفحة الأولى (يتحقق كل 5 دقائق حتى تتم قراءة اهتماماتك، ثم يتوقف)"
MSG_WARN_EDITOR_FRONTPAGE_CATCHUP_LOAD_FAILED="تعذّر تحميل LaunchAgent للّحاق بالصفحة الأولى. ستكتمل صفحتك الأولى وما يعرفه Ostler عن اهتماماتك عند التحديث التالي الذي يجري كل ساعة بدلًا من ذلك."
MSG_INFO_EDITOR_FRONTPAGE_CATCHUP_SKIPPED_NO_TICK="تم تخطي اللحاق بالصفحة الأولى: تحديث الصفحة الأولى غير مثبّت، فلا شيء لإعادة تشغيله."
MSG_OK_WIKI_RUNNING_HTTP_LOCALHOST_8044="الويكي تعمل على http://localhost:8044"
MSG_INFO_WIKI_BACKGROUND_SUMMARIES_STARTED="الويكي جاهزة للتصفح. يكتب Ostler الآن ملخصات الصفحات في الخلفية، وستكتمل خلال وقت قصير. يمكنك البدء باستخدام الويكي فورًا."
MSG_OK_YOUR_ASSISTANT_CALLED="اسم مساعدك هو %s"

# ── Personal-context digest refresh (#608) ──
MSG_OK_CONTEXT_REFRESH_SCRIPTS_BUNDLED="سكربتات الملخص السياقي الشخصي مضمّنة مع المثبّت"
MSG_OK_CONTEXT_REFRESH_LAUNCHAGENT_LOADED="تم تحميل LaunchAgent للملخص السياقي الشخصي (التسمية com.creativemachines.ostler.context-refresh)"
MSG_INFO_CONTEXT_REFRESH_LOGS="  السجلات: %s/context-refresh.log + .err"
MSG_INFO_REUSING_EXISTING_CONTEXT_REFRESH="إعادة استخدام تثبيت context-refresh الموجود في %s"
MSG_WARN_CONTEXT_REFRESH_NOT_BUNDLED="لم يتم تضمين نصوص ملخّص السياق الشخصي البرمجية. سيعتمد المساعد على البحث المباشر فقط (من دون ملخّص سياق دائم التشغيل)"
MSG_WARN_CONTEXT_REFRESH_LAUNCHAGENT_FAILED="تعذّر تحميل LaunchAgent الخاص بملخّص السياق الشخصي، راجع context-refresh.err. لا يزال المساعد يجيب عبر البحث المباشر"

# ── Warnings (non-fatal) ──

MSG_WARN_BASH_INSTALL_SNIPPET_SH="  bash %s/INSTALL_SNIPPET.sh"
MSG_WARN_BLOCK_3_1_CM024_PRODUCTISATION_STACK="المصدر المنسوخ لخدمة المعرفة تنقصه إعدادات التحزيم، لذا لم تُهيّأ بيئته."
MSG_WARN_BUNDLE="  الحزمة: %s"
MSG_WARN_CD="  cd %s"
MSG_WARN_CD_2="    cd %s"
MSG_WARN_CM042_APPLE_SILICON_ONLY="يعمل Ostler RemoteCapture v%s على Apple Silicon فقط (تم الاكتشاف: %s)."
MSG_WARN_CM042_DOWNLOAD_FAILED="تعذّر تنزيل Ostler RemoteCapture v%s من %s"
MSG_WARN_CM042_DOWNLOAD_NEXT_STEPS="الأسباب الشائعة: لم يُنشر وسم الإصدار بعد، أو لا يوجد اتصال بالشبكة، أو أن التوثيق (notarisation) لدى المصدر لم يكتمل. أعد تشغيل المثبّت عند إتاحة الإصدار."
MSG_WARN_CM042_EXTRACT_FAILED="تعذّر استخراج أرشيف Ostler RemoteCapture. سيتم تخطي LaunchAgent."
MSG_WARN_CM042_LAUNCHAGENT_LOAD_FAILED="فشل تحميل LaunchAgent الخاص بـ Ostler RemoteCapture. راجع المخرجات أعلاه و ~/Library/LaunchAgents/."
MSG_WARN_CM048_PIPELINE_CONVERSATION_ENRICHMENT_UNAVAILABLE="  لن يتوفر إثراء المحادثات. يُثبَّت باقي Ostler بشكل طبيعي. أعد التشغيل من دون --allow-plaintext لتفعيل محرّك ذاكرة المحادثات."
MSG_WARN_CM048_PIPELINE_INSTALL_FAILED_CLONE="فشل تثبيت محرّك ذاكرة المحادثات (الاستنساخ)."
MSG_WARN_CM048_PIPELINE_LOOKED_FOR_PATH="  تم البحث عن: %s/cm048_pipeline/pyproject.toml"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE="  يعني هذا عادةً أن تطبيق المثبّت .app بُني من دون"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_2="  تضمين حزمة cm048_pipeline المرفقة داخل"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. أعد تنزيل المثبّت أو"
MSG_WARN_CM048_PIPELINE_MISSING_FROM_APP_BUNDLE_4="  أعد التشغيل مع --allow-plaintext لتثبيت التطوير/CI."
MSG_WARN_CM048_PIPELINE_NOT_FOUND="لم يتم العثور على محرّك ذاكرة المحادثات. لا يمكن تشغيل إثراء المحادثات بدونه."
MSG_WARN_CM048_PIPELINE_SKIPPED_ALLOW_PLAINTEXT="تم تخطي إعداد محرّك ذاكرة المحادثات (--allow-plaintext)."
MSG_WARN_CM048_REPO_RESOLVED_BUT_PYPROJECT_TOML="تم تحديد مصدر محرّك ذاكرة المحادثات لكن pyproject.toml مفقود. تم تخطي إعداد venv."
MSG_WARN_COLIMA_FAILED_START_TRYING_DOCKER_DESKTOP="فشل تشغيل Colima. جارٍ تجربة Docker Desktop كبديل..."
MSG_WARN_COREUTILS_GTIMEOUT_NOT_AVAILABLE="تعذّر تثبيت GNU coreutils. ستعمل الخطوات الطويلة من دون حد زمني (سيظهر سطر تقدّم يوضح أنها تعمل)."
MSG_WARN_COLIMA_START_RETRY="لم يعمل Colima بشكل سليم (مقبس Docker لم يكن جاهزًا). إعادة المحاولة بعد %s ثانية..."
MSG_WARN_COMMON_CAUSES_TAG_V_NOT_YET="الأسباب الشائعة: الوسم v%s لم يُنشر بعد، أو لا يوجد اتصال بالشبكة،"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS="  مخرجات الخطأ من consent_cli (أول 400 حرف):"
MSG_WARN_CONSOLE_SCRIPT_NOT_CREATED_PYPROJECT_TOML="  لم يتم إنشاء نص وحدة التحكم في %s. ربما يخلو pyproject.toml من إدخال [project.scripts]."
MSG_WARN_CONTINUING_BECAUSE_ALLOW_PLAINTEXT_WAS_PASSED="المتابعة لأنه تم تمرير --allow-plaintext."
MSG_WARN_CONTINUING_INSTALL_RE_RUN_OSTLER_FDA="متابعة التثبيت. أعد تشغيل \`ostler-fda\` بعد تشخيص الخطأ أعلاه."
MSG_WARN_CONTINUING_WITHOUT_CONTACT_CARD_AUTO_FILL="المتابعة من دون الملء التلقائي من بطاقة جهة الاتصال – سيسألك Ostler بدلًا من ذلك."
MSG_WARN_CONVERSATIONS_SENT_IMESSAGE_WILL_SILENTLY_FAIL="  ستفشل المحادثات المرسلة إلى iMessage بصمت إلى أن"
# NEEDS REVIEW: Option label left in English; Arabic macOS shows a localised label. Verify exact Arabic macOS wording for the option and the Energy pane.
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE="تعذّر تغيير إعدادات السكون. فعّل \"منع السكون التلقائي عند توصيل الطاقة\" في إعدادات النظام > الطاقة."
# NEEDS REVIEW: Option label left in English; verify exact Arabic macOS wording for the option and the Energy pane.
MSG_WARN_COULD_NOT_CHANGE_SLEEP_SETTINGS_ENABLE_2="تعذّر تغيير إعدادات السكون. فعّل \"منع السكون التلقائي\" في إعدادات النظام > الطاقة."
MSG_WARN_COULD_NOT_DOWNLOAD_OSTLER_ASSISTANT_V="تعذّر تنزيل ostler-assistant v%s من %s"
MSG_WARN_COULD_NOT_EXTRACT_GMAIL_MBOX_FROM="تعذّر استخراج mbox الخاص بـ Gmail من ملف Takeout المضغوط – سيتم التخطي."
MSG_WARN_COULD_NOT_EXTRACT_OSTLER_ASSISTANT_TARBALL="تعذّر استخراج أرشيف ostler-assistant. سيتم تخطي LaunchAgent."
MSG_WARN_COULD_NOT_FIND_TAILSCALE_CLI_YOU="تعذّر العثور على واجهة سطر أوامر Tailscale. يمكنك إعدادها يدويًا لاحقًا."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_COULD_NOT_INSTALL_LEGAL_CONSENT_STRINGS="تعذّر تثبيت حزمة legal/ consent-strings؛ سيستمر التثبيت"
MSG_WARN_COULD_NOT_INSTALL_LICENSES_DIRECTORY_NON="تعذّر تثبيت المجلد LICENSES/ (غير حرج)."
MSG_WARN_COULD_NOT_INSTALL_OSTLER_SECURITY_INTO="تعذّر تثبيت ostler_security في البيئة الافتراضية venv الخاصة بـ Hub."
MSG_WARN_COULD_NOT_INSTALL_THIRD_PARTY_NOTICES="تعذّر تثبيت THIRD_PARTY_NOTICES.md (غير حرج)."
MSG_WARN_COULD_NOT_OBTAIN_DOCTOR_AGENT_BUNDLED="تعذّر الحصول على وكيل Doctor (فشل كل من النسخة المضمّنة والنسخ من المستودع)."
MSG_WARN_DOCTOR_NOT_BUNDLED_HARD_FAIL="ملفات Ostler Doctor غير موجودة. وهي مطلوبة لعملية الاقتران مع iOS (يعرض Ostler.app الصفحة :8089/pair-ios في إطار iframe)."
MSG_WARN_DOCTOR_LOOKED_FOR_PATH="  تم البحث في: %s/doctor/agent/"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE="  يعني هذا عادةً أن تطبيق المثبّت .app بُني من دون"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_2="  مصدر doctor/agent/ المضمّن ضمن"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. أعد تنزيل المثبّت أو"
MSG_WARN_DOCTOR_MISSING_FROM_APP_BUNDLE_4="  أعد التشغيل مع --allow-plaintext لتثبيت التطوير/CI."
MSG_FAIL_DOCTOR_INSTALL_REQUIRED="أُلغي تثبيت Doctor: فهو مطلوب لعملية الاقتران مع iOS. أعد تنزيل المثبّت أو مرّر --allow-plaintext لتثبيت التطوير/CI."
MSG_WARN_COULD_NOT_OBTAIN_EMAIL_INGEST_SCRIPTS="تعذّر الحصول على سكربتات استيعاب البريد الإلكتروني (فشل كل من النسخة المضمّنة والنسخ من المستودع)."
MSG_WARN_COULD_NOT_OBTAIN_HUB_POWER_SCRIPTS="تعذّر الحصول على سكربتات hub-power (فشل كل من النسخة المضمّنة والنسخ من المستودع)."
MSG_WARN_COULD_NOT_OBTAIN_WIKI_RECOMPILE_SCRIPTS="تعذّر الحصول على سكربتات wiki-recompile (فشل كل من النسخة المضمّنة والنسخ من المستودع)."
MSG_WARN_COULD_NOT_OPEN_CHROME_WEB_STORE="تعذّر فتح رابط Chrome Web Store تلقائيًا: %s"
MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="تعذّر حفظ region.json (سيستمر التثبيت، وسيعرض Doctor المشكلة)"
MSG_WARN_COULD_NOT_RECORD_RECOVERY_KEY_DELIVERY="تعذّر تسجيل أن مفتاح الاسترداد قد سُلِّم. ملخص هذه الجلسة لا يزال صحيحًا، لكن قد لا تتمكن جلسة لاحقة من معرفة ذلك وقد تعرض تحذيرًا مرة أخرى، وهذا هو الجانب الآمن إن كان لا بد من الإخفاق."
MSG_WARN_COULD_NOT_SAVE_KEYCHAIN_PLEASE_WRITE="تعذّر الحفظ في سلسلة المفاتيح. يرجى تدوينه."
MSG_WARN_COULD_NOT_START_OLLAMA_AUTOMATICALLY="تعذّر تشغيل Ollama تلقائيًا."
MSG_FAIL_OLLAMA_PORT_IN_USE="هناك برنامج آخر يستخدم المنفذ 11434 بالفعل، وهو المنفذ الذي يحتاجه Ostler لذكائه الاصطناعي المحلي. لم يتمكن Ostler من تشغيل نسخته الخاصة، لذا توقف التثبيت هنا بدلًا من إنهائه جزئيًا.

  ما الذي يشغل المنفذ: %s
  الخطأ بالتفصيل في: %s

يكون السبب عادةً نسخة من Ollama كانت لديك أصلًا، أو نسخة تُركت قيد التشغيل من تثبيت سابق لـ Ostler. أغلقها (أو أعد تشغيل هذا الـ Mac) ثم شغّل المثبّت مرة أخرى."
MSG_WARN_COULD_NOT_UPDATE_PIPELINE_OFFLINE="تعذّر تحديث خط المعالجة (هل أنت غير متصل؟)"
MSG_WARN_COULD_NOT_WRITE_PIPELINE_SIGNALS_JSON="تعذّرت كتابة pipeline_signals.json. سيعود تشخيص Doctor لصندوق البريد الفارغ إلى الإعدادات الافتراضية الآمنة حتى التثبيت التالي أو الدورة التالية."
MSG_WARN_CURL_SAID="ردّ curl:"
MSG_WARN_DIRECTORY_NOT_FOUND_SKIPPING_IMPORT="المجلد غير موجود: %s – سيتم تخطي الاستيراد."
MSG_WARN_DOCKER_COMPOSE_F_DOCKER_COMPOSE_YML="       docker compose -f %s/docker-compose.yml restart vane"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM="  docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_PROFILE_COMPILE_RUN_RM_2="    docker compose --profile compile run --rm wiki-compiler"
MSG_WARN_DOCKER_COMPOSE_UP_D_WIKI_SITE="    docker compose up -d wiki-site"
MSG_WARN_DOCKER_DID_NOT_START_WITHIN_SECONDS="لم يبدأ Docker خلال %s ثانية."
MSG_WARN_DOCKER_INSTALLED_BUT_NOT_RUNNING_WILL="Docker مثبّت لكنه لا يعمل. سيلزم تشغيله."
MSG_WARN_DOCKER_CLIENT_WITHOUT_ENGINE="أمر Docker موجود على هذا الـ Mac لكن لا شيء يعمل خلفه. في macOS أمر Docker ليس سوى عميل، ويحتاج إلى محرّك مثل Colima أو Docker Desktop لتشغيل أي شيء فعليًا. سيقوم المثبّت بإعداد واحد منهما."
MSG_WARN_CONTAINER_ENGINE_DIAGNOSTIC="تشخيص بيئة تشغيل الحاويات - عميل docker: %s | colima: %s | Docker Desktop: %s"
MSG_WARN_WIKI_PORT_NOT_ANSWERING="بدأت حاوية الويكي لكن لم يستجب شيء على http://localhost:8044 خلال 60 ثانية. اعتبر الويكي غير قيد التشغيل، فرمز الخروج لأمر البدء ليس دليلًا على أن الصفحة تُحمَّل."
MSG_WARN_WIKI_NOT_RESPONDING="الويكي لا يستجيب (127.0.0.1:8044). يعمل الويكي داخل حاوية، لذا يعني هذا عادةً أن بيئة تشغيل الحاويات توقفت. افتح Ostler Doctor على http://localhost:8089/doctor لمعرفة السبب."
MSG_WARN_DOCKER_OLLAMA_MID_INSTALL_HANG_READINESS="Docker / Ollama أثناء التثبيت وتعطّل فحوصات الجاهزية."
MSG_WARN_EARLY_MARKERS_CHANNELS_STILL_CONNECTING_APPLE="  مؤشرات مبكرة (القنوات لا تزال قيد الاتصال + Apple"
MSG_WARN_EMAIL_INGEST_LAUNCHAGENT_INSTALL_FAILED_SEE="فشل تثبيت LaunchAgent لاستيعاب البريد الإلكتروني. راجع المخرجات أعلاه."
MSG_WARN_IMESSAGE_BRIDGE_FAILED="فشل تثبيت LaunchAgent لجسر iMessage. لن تعمل ردود iMessage الخاصة بمستخدم المساعد حتى تعيد تشغيل المثبّت أو تشغّل INSTALL_SNIPPET.sh يدويًا."
MSG_WARN_IMESSAGE_BRIDGE_SCRIPTS_NOT_BUNDLED_PLAINTEXT="سكربتات جسر iMessage غير مضمّنة وتم تمرير --allow-plaintext؛ سيتم تخطي تثبيت LaunchAgent. لن تعمل ردود iMessage الخاصة بمستخدم المساعد."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK="لن يعمل التشفير."
MSG_WARN_ENCRYPTION_PASSPHRASE_VALIDATION_WILL_NOT_WORK_2="لن يعمل التشفير، و"
MSG_WARN_ENSURE_PINNED_PWG_KNOWLEDGE_REPO_TAG="تأكد من أن وسم PWG_KNOWLEDGE_REPO المثبّت يتضمنه."
MSG_WARN_EVENTS_PERMISSION_MESSAGES_APP="  إذن الأحداث لتطبيق Messages.app)."
MSG_WARN_FDA_EXTRACTOR_EXITED_NON_ZERO_LAST="انتهى مستخرج FDA برمز غير صفري (%s). آخر 20 سطرًا من المخرجات:"
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_1="وحدة استخراج FDA غير مضمّنة في هذا المثبّت."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_2="المسار المتوقع: Contents/Resources/ostler_fda/ (داخل ملف .app)."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_LINE_3="السبب الأرجح: أدى خلل في البناء إلى إسقاط نسخة المورّد. أعد تنزيل ملف .app من ostler.ai/install."
MSG_WARN_FDA_MODULE_NOT_BUNDLED_PLAINTEXT="وحدة استخراج FDA غير مضمّنة. سيستمر التثبيت لأنه تم تمرير --allow-plaintext – سيتم تخطي الاستخراج الفوري للبيانات."
MSG_WARN_FDA_DEPENDENCIES_NOT_IMPORTABLE="وحدة استخراج البيانات موجودة على القرص لكن تعذّر تثبيت اعتماداتها، لذا لا يمكن تحميلها:"
MSG_WARN_FDA_DEPENDENCIES_CONTINUING_PLAINTEXT="سيستمر التثبيت لأنه تم تمرير --allow-plaintext – سيفشل التحديث المجدول للبيانات في كل مرة."
MSG_WARN_FILEVAULT_NOT_ENABLED="FileVault غير مفعّل."
MSG_WARN_FIRST_MONTH_FREE_FAILED_NONFATAL="تعذّر تفعيل الشهر الأول المجاني في الوقت الحالي، وسيستمر التثبيت. افتح تطبيق Ostler على iPhone بعد الاقتران لحل ذلك."
MSG_WARN_FULL_DISK_ACCESS_NOT_GRANTED_TERMINAL="لم يتم منح «الوصول الكامل إلى القرص» لتطبيق «الطرفية»."
MSG_WARN_GB_RAM_DETECTED_WORKS_BUT_LIMITS="تم رصد %s GB من الذاكرة RAM. ستحصل على المساعد المدمج (gemma4:e2b) – موثوق ودقيق وسريع في أقل من ثانية على الأسئلة القصيرة، مع استدعاء الأدوات وقول «لا أعرف» بصدق عندما لا يعرف. للحصول على إجابات أغنى عن الأسئلة الأطول، تتيح ذاكرة بحجم 24 GB أو أكثر المساعد القياسي (qwen3.5:9b). يمكنك تغيير جهاز Mac لاحقًا بإعادة التثبيت."
MSG_WARN_GDPR_IMPORT_HAD_ERRORS_YOU_CAN="حدثت أخطاء في استيراد GDPR. يمكنك إعادة التشغيل باستخدام:"
MSG_WARN_GRAPH_DB_PULL_RETRY="لم يكتمل تنزيل قاعدة البيانات (المحاولة %s من %s). ستتم إعادة المحاولة بعد %s ثانية..."
MSG_WARN_GRAPH_DB_UP_RETRY="لم تبدأ قواعد بيانات الرسم المعرفي (المحاولة %s من %s). ستتم إعادة المحاولة..."
MSG_WARN_GDPR_IMPORT_REQUIRED_FOR_PRODUCTISED_INSTALL="استيراد GDPR جزء من التثبيت الكامل للمنتج. بدونه، لا يمكن استيراد شبكتك الاجتماعية (LinkedIn وFacebook وInstagram وWhatsApp وTwitter وGoogle Calendar)."
MSG_WARN_GDPR_IMPORT_WILL_BE_UNAVAILABLE_THIS_INSTANCE="لن يتوفر استيراد GDPR على هذه النسخة إلى أن تتم إعادة تثبيت مسار الاستيراد."
MSG_WARN_GIT_SAID="رسالة Git:"
MSG_WARN_HEALTH_CHECK_FAILED_OSTLER_KNOWLEDGE_VERSION="  فشل فحص السلامة: لم يُنتج الأمر ostler-knowledge --version أي مخرجات."
MSG_WARN_HEALTH_CHECK_FAILED_PWG_CONVO_HELP="  فشل فحص السلامة: تعذّر تحميل محرك ذاكرة المحادثات (لم يكتمل pwg-convo أو استيراد مساره بشكل سليم)."
MSG_WARN_HOMEBREW_INSTALL_FAILED_EXIT="انتهى مثبّت Homebrew برمز %s. فيما يلي آخر 30 سطرًا من %s:"
MSG_WARN_HOMEBREW_INSTALL_LOG_LAST_LINES="--- سجل تثبيت Homebrew (النهاية) ---"
MSG_WARN_DOCTOR_PIP_INSTALL_FAILED_EXIT="انتهى تثبيت pip لـ Doctor برمز %s. فيما يلي آخر 30 سطرًا من %s:"
MSG_WARN_DOCTOR_PIP_LOG_LAST_LINES="--- سجل تثبيت pip لـ Doctor (النهاية) ---"
MSG_WARN_PIPELINE_PIP_INSTALL_FAILED_EXIT="انتهى تثبيت pip للمسار البرمجي برمز %s. فيما يلي آخر 30 سطرًا من %s:"
MSG_WARN_PIPELINE_PIP_LOG_LAST_LINES="--- سجل تثبيت pip للمسار البرمجي (النهاية) ---"
MSG_WARN_HUB_POWER_LAUNCHAGENT_INSTALL_FAILED_SEE="فشل تثبيت LaunchAgent لإدارة طاقة Hub. راجع المخرجات أعلاه."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE="لم يتم العثور على سكربتات طاقة Hub في مسار الحزمة المتوقع."
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_2="  يبدو أن ملف المثبّت .app يفتقد المجلد vendor/hub_power/"
MSG_WARN_HUB_POWER_SCRIPTS_MISSING_FROM_APP_BUNDLE_3="  في Contents/Resources/hub-power/. لن يتم تثبيت خاصية خفض الأداء المراعية للبطارية، وسيستمر باقي التثبيت."
MSG_WARN_ICAL_SERVER_FAILED="تعذّر تشغيل واجهة API الخاصة بالمساعد، وسيكون وصول تطبيق Ostler على iPhone محدودًا حتى تشغيل التثبيت التالي."
MSG_WARN_IMAGE_PULL_FAILED_NETWORK_DISK_SPACE="  - فشل سحب الصورة (الشبكة أو مساحة القرص أو انتهاء مهلة السجل)"
MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED="تعذّرت كتابة إشارة FDA الخاصة بـ iMessage في pipeline_signals.json. قد لا تعرض لوحة Doctor بطاقة «الوصول الكامل إلى القرص» تلقائيًا."
MSG_WARN_IMAP_HOST_EMPTY_TRY_AGAIN="مضيف IMAP فارغ – حاول مرة أخرى."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_NOT_GRANTED_1743="إذن الأتمتة لـ iMessage: غير ممنوح (-1743)."
MSG_WARN_IMESSAGE_AUTOMATION_PERMISSION_PROBE_INCONCLUSIVE="إذن الأتمتة لـ iMessage: نتيجة الفحص غير حاسمة."
MSG_WARN_IMESSAGE_CHAT_DB_FDA_DENIED="سجل iMessage (chat.db) غير قابل للقراءة: لم يتم بعد منح «الوصول الكامل إلى القرص» لخدمة Ostler الخلفية. تبقى قراءة سجل iMessage متوقفة إلى أن تمنحه في إعدادات النظام > الخصوصية والأمن > الوصول الكامل إلى القرص."
MSG_INFO_IMESSAGE_TCC_REMEDIATION_OPENED="جارٍ فتح إعدادات النظام > الخصوصية والأمن > الأتمتة. حدّد صف «الرسائل» الخاص بـ OstlerInstaller (أو Terminal) لإعداد التسليم عبر iMessage."
MSG_WARN_EMAIL_ALLOWED_ENTRY_IGNORED="ليس عنوان بريد إلكتروني كاملاً، لذا تم تجاهله: %s"
MSG_WARN_EMAIL_NEEDS_AT_LEAST_ONE_ALLOWED_ADDRESS="يُرجى إدخال عنوان بريد إلكتروني كامل واحد على الأقل (مثل you@example.com)."
MSG_WARN_IMESSAGE_NEEDS_LEAST_ONE_ALLOWED_CONTACT="يحتاج iMessage إلى جهة اتصال مسموح بها واحدة على الأقل. حاول مرة أخرى أو"
MSG_WARN_IMPORT_PIPELINE_NOT_AVAILABLE_PRIVATE_REPO="مسار الاستيراد غير متاح (مستودع خاص، لمختبِري النسخة التجريبية فقط)."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_HARD_FAIL_BYPASSED="مسار الاستيراد غير مضمّن في المثبّت. تم تجاوز الإخفاق الحتمي."
MSG_WARN_IMPORT_PIPELINE_NOT_BUNDLED_WITH_INSTALLER="مسار الاستيراد غير مضمّن في المثبّت. هذا هو مسار التثبيت الجاهز للمنتج؛ يجب أن تكون حزمة Python المسماة contact_syncer مضمّنة داخل حزمة .app."
MSG_WARN_INBOX_MEANS_ASSISTANT_WILL_READ_EVERY="INBOX يعني أن المساعد سيقرأ كل رسالة بريد إلكتروني تتلقاها."
MSG_WARN_INSUFFICIENT_DISK_WIKI_OUTPUT_VOLUME="  - مساحة القرص غير كافية لحجم مخرجات الويكي"
MSG_WARN_INTEL_MAC_DETECTED_PERFORMANCE_WILL_LIMITED="تم اكتشاف Mac بمعالج Intel – سيكون الأداء محدوداً. يُوصى بمعالج Apple Silicon."
MSG_WARN_IS_CLOUD_PROVIDER_HOST="%s هو مضيف لمزوّد خدمة سحابية."
MSG_WARN_JWT_SECRET_BANLIST_REGENERATING_KEEP_CM019="JWT_SECRET في %s موجود في قائمة الحظر؛ تجري إعادة إنشائه للحفاظ على قابلية استيراد خدمات الرسم البياني المعرفي"
MSG_WARN_JWT_SECRET_TOO_SHORT_CHARS_REGENERATING="JWT_SECRET في %s قصير جداً (%s < %s حرفاً)؛ تجري إعادة إنشائه"
MSG_WARN_KNOWLEDGE_REPO_CLONED_BUT_PYPROJECT_TOML="تم استنساخ مستودع المعرفة لكن ملف pyproject.toml مفقود؛ تم تخطي إعداد venv."
MSG_WARN_KNOWLEDGE_SERVICE_INSTALL_FAILED_CLONE="فشل تثبيت خدمة المعرفة (الاستنساخ)."
MSG_WARN_LICENCE_SHIPS_UNDER_GOOGLE_S_GEMMA="الترخيص: يُوزَّع %s بموجب شروط استخدام Gemma من Google، وليس Apache 2.0."
MSG_WARN_MACBOOK_DEPLOYMENTS_NEED_THIS_BATTERY_SLEEP="تحتاج أجهزة MacBook إلى هذا لإدارة البطارية والسكون."
MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED_NOT="تم رفض إذن جهات الاتصال في macOS أو لم يُمنح بعد."
MSG_WARN_MACOS_WILL_NOT_PROMPT_IT_FROM="لن يطلب macOS هذا الإذن من خلال سكربت – يجب أن تمنحه يدوياً."
MSG_WARN_MAC_MINI_DEPLOYMENTS_ARE_UNAFFECTED_MACBOOK="لا تتأثر أجهزة Mac Mini؛ على مستخدمي MacBook إعادة المحاولة."
MSG_WARN_MAIL_DATA_STILL_INGESTIBLE_MANUALLY="لا يزال بالإمكان استيعاب بيانات البريد يدوياً:"
MSG_WARN_MANUAL_RETRY_CD_DOCKER_COMPOSE_UP="  إعادة المحاولة يدوياً: cd %s && docker compose up -d vane"
MSG_WARN_MANUAL_RETRY_ONCE_CAUSE_RESOLVED="  إعادة المحاولة يدوياً بعد حل السبب:"
MSG_WARN_NEITHER_APPLE_MAIL_NOR_CUSTOM_IMAP="لم يتم اختيار Apple Mail ولا IMAP مخصص – سيتم اعتماد Apple Mail افتراضياً."
MSG_WARN_NO_PASSKEY_SET_DATABASES_WILL_NOT="لم يتم تعيين مفتاح مرور؛ لن تكون قواعد البيانات مشفّرة."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_1="أنشأ تثبيت سابق مفتاح الاسترداد الخاص بك لكنه لم يكتمل، لذا لم يُعرض عليك قط. لا يمكن استرجاعه – فهو لا يُخزَّن في أي مكان، بما في ذلك هنا."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_2="عبارة المرور الخاصة بك لا تزال تعمل ولا شيء مقفل اليوم. لكن لا توجد حالياً أي وسيلة للدخول مجدداً إذا نسيتها."
MSG_WARN_RECOVERY_KEY_NEVER_DELIVERED_LINE_3="تواصل مع الدعم لإعداد الأمان من جديد، وسيعرض عليك ذلك مفتاح استرداد جديداً لتحتفظ به."
MSG_WARN_RECOVERY_PASSPHRASES_DON_T_MATCH_TRY_AGAIN="عبارتا المرور غير متطابقتين. حاول مرة أخرى."
MSG_WARN_RECOVERY_PASSPHRASE_SETUP_FAILED="فشل إعداد عبارة المرور. المخرجات:"
MSG_WARN_RECOVERY_PASSPHRASE_SKIPPED="الإدخال فارغ. تم تخطي عبارة المرور."
MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT="يجب ألا تقل عبارة المرور عن 12 حرفاً. حاول مرة أخرى."
MSG_WARN_RECOVERY_PASSPHRASE_REQUIRED="عبارة المرور مطلوبة لتشفير بياناتك."
MSG_WARN_NUMBER_MUST_START_WITH_TRY_AGAIN="هذا ليس رقماً دولياً. ابدأ بعلامة + ثم رمز الدولة وبقية الرقم، مثل +447700900123. حاول مرة أخرى."
MSG_WARN_OLLAMA_NOT_RESPONDING="Ollama لا يستجيب"
MSG_WARN_OLLAMA_PULL_FAILED_ATTEMPT_3_RETRYING="فشل ollama pull %s (المحاولة %s/3). إعادة المحاولة خلال %s ث..."
MSG_WARN_ONLY_GB_FREE_WE_RECOMMEND_LEAST="المتاح %s غيغابايت فقط. نوصي بما لا يقل عن 35 غيغابايت (صور Docker ونموذج الذكاء الاصطناعي والبيانات)."
MSG_WARN_ON_BATTERY_HUB_POWER_LAUNCHAGENT_STEP="عند التشغيل على البطارية، قد يتوقف LaunchAgent الخاص بإدارة طاقة الـ Hub (الخطوة 3.14) مؤقتاً"
MSG_WARN_OR_RE_RUN_INSTALLER_PICK_DIFFERENT="أو أعد تشغيل المثبّت واختر قناة مختلفة."
MSG_WARN_OR_RUNNING_AHEAD_PHASE_B_S="أو أنه يسبق مسار الإصدار في المرحلة B. أعد تشغيل المثبّت بمجرد أن"
MSG_WARN_OSTLER_ASSISTANT_DOCTOR_REPORTED_ERROR_S="أبلغ ostler-assistant doctor عن %s من الأخطاء."

# The whole-run closing verdict (#270, step-failure line added #616).
# Deliberately NOT phrased as a doctor result: the doctor string above is scoped
# to the assistant doctor and is true; this set is the verdict for the install as
# a whole, which nothing stated before. Wording is plain because a customer reads
# it at the moment they decide whether the thing worked. The FAILED_STEPS line
# exists because a step killed by its timeout cap raises no err(), so the
# error-count line alone would print "no errors raised" over a failed step; its
# second %s is the space-separated ids of the steps that did not complete.
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS="اكتمل تثبيت Ostler، لكن حدثت %s من الأخطاء أثناء التثبيت."
MSG_WARN_INSTALL_FINISHED_WITH_ERRORS_WHERE="  التفاصيل الكاملة في ~/.ostler/logs/install.log. سيبدأ Ostler مع ذلك؛ افتح Doctor لمعرفة ما يحتاج إلى انتباه."
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS="اكتمل تثبيت Ostler، لكن %s من خطوات التثبيت لم تكتمل بشكل سليم: %s"
MSG_OK_INSTALL_FINISHED_NO_ERRORS_RAISED="اكتمل تثبيت Ostler دون أي أخطاء."

MSG_WARN_OSTLER_ASSISTANT_EXTRACTED_BUT_VERSION_CHECK="تم استخراج ostler-assistant لكن فحص --version فشل."
MSG_WARN_OSTLER_ASSISTANT_LAUNCHAGENT_INSTALL_FAILED_SEE="فشل تثبيت LaunchAgent لمساعد Ostler بعد 3 محاولات. مخرجات التشخيص أعلاه وأدناه."
MSG_INFO_ASSISTANT_SNIPPET_ATTEMPT_FAILED="فشلت محاولة تثبيت LaunchAgent لمساعد Ostler رقم %s؛ جارٍ إعادة المحاولة."
MSG_WARN_ASSISTANT_ERR_LOG_PATH="مخرجات stderr الكاملة للخدمة في: %s"
MSG_WARN_ASSISTANT_SNIPPET_LAST_STDERR="آخر مقتطف من stderr:"
MSG_WARN_OSTLER_ASSISTANT_V_APPLE_SILICON_ONLY="الإصدار v%s من ostler-assistant يعمل على Apple Silicon فقط (تم اكتشاف: %s)."
MSG_WARN_OSTLER_IMPORT_USER_NAME_VERBOSE="  ostler-import %s --user-name \"%s\" --verbose"
MSG_WARN_OSTLER_SECURITY_INSTALL_FAILED_CM048="  تعذّر تثبيت اعتمادية التخزين المشفّر في البيئة الافتراضية لذاكرة المحادثات؛ لن يعمل إثراء المحادثات."
MSG_WARN_OSTLER_SECURITY_SOURCE_MISSING_CM048="  لم يُعثر على مصدر اعتمادية التخزين المشفّر في SCRIPT_DIR؛ لا يمكن تحميل محرك ذاكرة المحادثات ولن يعمل إثراء المحادثات."
MSG_WARN_OSTLER_WIKI_COMPILER_IMAGE_NOT_YET="  - صورة ostler-wiki-compiler غير متاحة للسحب بعد (السجل غير مهيأ)"
MSG_WARN_OXIGRAPH_NOT_RESPONDING="Oxigraph لا يستجيب"
MSG_WARN_OXIGRAPH_NOT_YET_HEALTHY_THIS_PHASE="  - Oxigraph ليس سليمًا بعد في هذه المرحلة (راجع السجلات أعلاه)"
MSG_WARN_PASSWORDS_DID_NOT_MATCH_WERE_EMPTY="كلمتا المرور غير متطابقتين (أو فارغتان). حاول مرة أخرى."
# NEEDS REVIEW: source asks for human translation of this key
MSG_WARN_PHASE_3_TAKES_10_15_MINUTES="يستغرق التثبيت الرئيسي عادةً من 45 دقيقة إلى بضع ساعات (تنزيلات Docker وOllama والإعداد لأول مرة)، وأكثر مع اتصال أبطأ أو جهاز Mac يحتوي على بيانات سنوات عديدة. من الطبيعي أن تمر فترات طويلة هادئة – فالتنزيل والإعداد يجريان في الخلفية، ولم يتوقف التثبيت."
MSG_WARN_PIP_INSTALL_FAILED_CM048_PIPELINE_WILL="  فشل pip install؛ لن يتوفر محرك ذاكرة المحادثات."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_FDA_WILL="  فشل pip install؛ سيعود email-ingest إلى استخدام Python الخاص بالنظام (وقد يفشل أيضًا أثناء التشغيل)."
MSG_WARN_PIP_INSTALL_FAILED_OSTLER_KNOWLEDGE_WILL="  فشل pip install؛ لن يتوفر ostler-knowledge."
MSG_WARN_PIP_INSTALL_FAILED_PWG_EMAIL_INGEST="  فشل pip install؛ محرك استيعاب البريد الإلكتروني غير متاح. سيواصل LaunchAgent الساعي إنشاء ملفات mbox لكنه لن يستطيع استيعابها في الرسم البياني المعرفي إلى أن يُصلح ذلك."
MSG_WARN_CM021_SOURCE_NOT_FOUND="لم يُعثر على مصدر محرك استيعاب البريد الإلكتروني في حزمة التطبيق؛ ستحفظ المهمة الساعية في الخلفية ملفات البريد دون استيعابها."
MSG_WARN_OSTLER_FDA_SOURCE_NOT_FOUND_EMAIL_INGEST="لم يُعثر على مصدر ostler_fda في حزمة التطبيق؛ سيعود email-ingest LaunchAgent إلى استخدام Python الخاص بالنظام أثناء التشغيل."
MSG_WARN_PIP_SAID="ردّ pip:"
MSG_WARN_PLUG_INTO_AC_POWER_FULL_INSTALL="صِل الجهاز بمصدر الطاقة الكهربائية لإكمال التثبيت."
MSG_WARN_PORT_1_ALREADY_USE_PID="المنفذ %s مستخدم بالفعل من قبل %s (PID %s)"
MSG_WARN_PORT_3000_ALREADY_USE_ANOTHER_SERVICE="  - المنفذ 3000 مستخدم بالفعل من قبل خدمة أخرى"
MSG_WARN_POWER_SOURCE="مصدر الطاقة: %s"
MSG_WARN_PWG_EMAIL_INGEST_MBOX_TMP_MANUAL="  pwg-email-ingest mbox /tmp/manual.mbox.txt"
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED="فشل تثبيت sqlcipher3."
MSG_WARN_PYSQLCIPHER3_INSTALL_FAILED_DATABASES_WILL_NOT="فشل تثبيت sqlcipher3. لن تكون قواعد البيانات مشفّرة."
MSG_WARN_PYTHON3_M_OSTLER_FDA_APPLE_MAIL="  python3 -m ostler_fda.apple_mail_mbox --emit-mbox /tmp/manual.mbox.txt"
MSG_WARN_PYTHON_3_NOT_FOUND_INSTALLING_PYTHON="لم يُعثر على Python 3. جارٍ تثبيت Python 3.12..."
MSG_WARN_PYTHON_TOO_OLD_NEED_3_10="إصدار Python %s قديم جدًا (المطلوب 3.10 أو أحدث). جارٍ تثبيت Python 3.12..."
MSG_WARN_QDRANT_NOT_RESPONDING="Qdrant لا يستجيب"
MSG_WARN_READ_HTTPS_AI_GOOGLE_DEV_GEMMA="         اقرأ https://ai.google.dev/gemma/terms قبل الاستخدام التجاري."
MSG_WARN_READ_PUBLIC_VERSION_HTTPS_OSTLER_AI="اقرأ النسخة العامة على https://ostler.ai/licenses.html"
MSG_WARN_REDIS_NOT_RESPONDING="Redis لا يستجيب"
MSG_WARN_RELEASE_LANDS_STAGE_BINARY_MANUALLY="عند صدور الإصدار، أو انقل الملف التنفيذي يدويًا:"
MSG_WARN_RE_RUNNING_TYPE_SELF_HOSTED_HOST="إعادة التشغيل – اكتب مضيفًا مستضافًا ذاتيًا، أو اضغط Ctrl-C وأعد التشغيل مع اختيار Apple Mail."
MSG_WARN_RE_RUN_INSTALLER_WITH_IMESSAGE_UNTICKED="أعد تشغيل المثبّت مع إلغاء تحديد iMessage لتخطيه."
MSG_WARN_RUNNING_WITH_ALLOW_PLAINTEXT_ENCRYPTION_DISABLED="التشغيل مع --allow-plaintext: التشفير معطّل. غير مخصص للإنتاج."
MSG_WARN_RUN_DOCTOR_AFTER_FIRST_LAUNCH="  شغّل \`%s doctor\` بعد أول تشغيل"
MSG_WARN_RUN_TAILSCALE_IP_4_ONCE_SIGNED="شغّل 'tailscale ip --4' بعد تسجيل الدخول، ثم أضف العنوان إلى تطبيق iOS."
MSG_WARN_SAFARI_EXTENSION_COPY_FAILED_YOU_CAN="تعذّر نسخ امتداد Safari؛ يمكنك تثبيته يدويًا لاحقًا"
MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="تم تثبيت امتداد Safari لكن لم يتوفر رمز امتداد لإقرانه؛ سيظل التقاط التصفح متوقفًا حتى تعيد تشغيل المثبّت"
MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="تعذّر إقران امتداد Safari بهذا الـ Hub؛ سيظل التقاط التصفح متوقفًا حتى تعيد تشغيل المثبّت"
MSG_WARN_SECURITY_MODULE_NOT_FOUND_PASSKEY_SETUP="لم يُعثر على وحدة الأمان. سيتم تخطي إعداد مفتاح المرور."
MSG_WARN_SECURITY_MODULE_LOOKED_FOR_PATH="  تم البحث في: %s/ostler_security/pyproject.toml"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE="  يعني هذا عادةً أن تطبيق المثبّت .app بُني من دون"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_2="  حزمة ostler_security المضمّنة داخل"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_3="  Contents/Resources/. أعد تنزيل المثبّت أو"
MSG_WARN_SECURITY_MODULE_MISSING_FROM_APP_BUNDLE_4="  أعد التشغيل مع --allow-plaintext لتثبيت التطوير/CI."
MSG_WARN_SECURITY_SETUP_FAILED_CONTINUING_WITHOUT_DATABASE="فشل إعداد الأمان. سيتم المتابعة من دون تشفير قاعدة البيانات."
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="فشل إعداد الأمان. المخرجات:"
MSG_WARN_SEE_STDERR_FRAGMENT="  راجع %s للاطلاع على جزء stderr."
MSG_WARN_SKIPPING_BINARY_INSTALL_WIZARD_WRITTEN_CONFIG="تخطي تثبيت الملف التنفيذي. يبقى ملف config.toml الذي كتبه المعالج في مكانه."
MSG_WARN_SKIPPING_DOCTOR_LAUNCHAGENT_INSTALL="تخطي تثبيت Doctor LaunchAgent."
MSG_WARN_SKIPPING_EMAIL_INGEST_LAUNCHAGENT_INSTALL="تخطي تثبيت email-ingest LaunchAgent."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_MAC_MINI_DEPLOYMENTS="تخطي تثبيت LaunchAgent. عمليات نشر Mac Mini غير متأثرة."
MSG_WARN_SKIPPING_LAUNCHAGENT_INSTALL_TRY_VERSION="تخطي تثبيت LaunchAgent. جرّب: %s --version"
MSG_WARN_SKIPPING_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL="تخطي تثبيت wiki-recompile LaunchAgent."
MSG_WARN_SOME_PORTS_ARE_USE_DOCKER_CONTAINERS="بعض المنافذ قيد الاستخدام. قد تفشل حاويات Docker في البدء."
# #1208 port preflight. MSG_WARN_PORT_1_ALREADY_USE_PID above is RETIRED,
# not reused: it declares three %s but every call site only ever passed
# two, so it rendered the process name in the port's slot and left the
# PID blank. The replacements below name their arguments in order.
MSG_ERR_PORT_HELD_BY_OUR_PROCESS="المنفذ %s قيد الاستخدام بالفعل من قبل %s (PID %s) وهو يتبع هذا الحساب. أغلقه وشغّل المثبّت مرة أخرى."
MSG_ERR_PORT_HELD_BY_ANOTHER_ACCOUNT="المنفذ %s قيد الاستخدام بالفعل من قبل برنامج يتبع حساب مستخدم مختلفًا على هذا الـ Mac. لا يمكن لـ Ostler مشاركته، وقد يؤدي البدء رغم ذلك إلى اختلاط بيانات الحسابين. سجّل خروج الحساب الآخر، أو ثبّت Ostler على Mac يكون فيه الحساب الوحيد الذي يستخدم هذا المنفذ."
MSG_ERR_SOME_PORTS_ARE_HELD_CANNOT_START="لا يستطيع Ostler تشغيل قواعد بياناته لأن المنافذ التي يحتاجها مشغولة بالفعل."
MSG_ERR_STOP_CONFLICTING_SERVICES_OR_USE_ONE_ACCOUNT="أوقف ما يستخدم المنافذ المذكورة أعلاه، ثم شغّل المثبّت مرة أخرى."
MSG_WARN_PORT_CHECK_COULD_NOT_RUN="تعذّر التحقق مما إذا كان المنفذ %s متاحًا. وهذا لا يعني أن المنفذ متاح."
MSG_WARN_PORT_PREFLIGHT_INCOMPLETE="تعذّر تشغيل فحص منفذ واحد أو أكثر، لذا لا يمكن استبعاد وجود تعارض مع برنامج آخر."
MSG_WARN_PORT_BIND_PROBE_UNAVAILABLE="تعذّر تشغيل أكثر فحوص المنافذ موثوقية على هذا الـ Mac، لذا فإن الفحوص أدناه أقل دقة من المعتاد."
MSG_ERR_PORT_PREFLIGHT_CANNOT_RUN_ABORT="لم يتمكن Ostler من التأكد من أن تلك المنافذ متاحة، ولن يشغّل قواعد بياناته على منفذ لم يفحصه. يرجى التواصل مع الدعم مع إرفاق سجل التثبيت."
MSG_WARN_STALE_COLIMA_LAUNCHAGENT_NOT_REMOVED="تعذّرت إزالة عنصر بدء تشغيل Colima قديم. قد لا يُحمَّل الويكي الخاص بك بعد إعادة التشغيل؛ تواصل مع الدعم."
MSG_WARN_STOP_CONFLICTING_SERVICES_CHANGE_PORTS_DOCKER="أوقف الخدمات المتعارضة أو غيّر المنافذ في docker-compose.yml"
MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN="لم يسجّل Tailscale الدخول خلال 3 دقائق. يمكنك العودة إلى هذا لاحقًا من الإعدادات."
MSG_WARN_TAILSCALE_ENV_PERSIST_VERIFY_FAILED="كُتب عنوان IP الخاص بـ Tailscale في .env لكن القراءة اللاحقة لم تتمكن من رؤيته. قد لا يلتقطه تطبيق Ostler على iPhone – أعد تشغيل install.sh --repair إذا حدث ذلك."
MSG_WARN_TAILSCALE_ANSWER_NOT_REMEMBERED="تعذّر حفظ إجابتك بشأن الوصول عن بُعد، لذا سيسألك التثبيت التالي مرة أخرى. كل شيء آخر غير متأثر."
MSG_WARN_TAILSCALE_INSTALL_FAILED_YOU_CAN_INSTALL="فشل تثبيت Tailscale – يمكنك تثبيته لاحقًا من tailscale.com"
MSG_WARN_TAILSCALE_STATE_UNREADABLE="يحتوي هذا الـ Mac على إعدادات Tailscale موجودة تعذّرت قراءتها، لذا لا يمكننا معرفة ما إذا كان لا يزال متصلًا بشبكتك. يرجى الاختيار أدناه – إذا كان متصلًا بالفعل، فلا ضرر من إعداده مرة أخرى."
MSG_WARN_THE_DEPLOYED_SERVICES_REFUSE_START_WITHOUT="لن تبدأ الخدمات المنشورة بالعمل من دونها."
MSG_WARN_THIS_RESOLVED_SEE_NEXT_STEPS_BANNER="  تُحل هذه المشكلة. راجع لافتة الخطوات التالية لمعرفة طريقة المعالجة."
MSG_WARN_TO_INSPECT_CRON_DELIVERY_IMESSAGE_TCC="  للفحص. cron-delivery / imessage-tcc من الأسباب الشائعة"
MSG_WARN_TRY_DOCKER_COMPOSE_F_DOCKER_COMPOSE="  جرّب: docker compose -f %s/docker-compose.yml up -d wiki-site"
MSG_WARN_TRY_DOCKER_LOGS_OSTLER_VANE="  جرّب: docker logs ostler-vane"
MSG_WARN_UNRECOGNISED_CHOICE_DEFAULTING_IMESSAGE_EMAIL="خيار غير معروف '%s'؛ سيتم استخدام iMessage والبريد الإلكتروني افتراضيًا."
MSG_WARN_UNRECOGNISED_CHOICE_USING_RECOMMENDED="خيار غير معروف. سيتم استخدام الخيار الموصى به."
MSG_WARN_UPDATE_FAILED_CONTINUING_WITH_EXISTING_CHECKOUT="  فشل التحديث؛ ستتم المتابعة بالنسخة الحالية."
MSG_WARN_USE_APPLE_MAIL_RECOMMENDED_ABOVE_THAT="استخدم Apple Mail (الموصى به أعلاه) لهذا الحساب – لا يخزّن Ostler كلمات مرور الحسابات السحابية أبدًا."
MSG_WARN_USING_INBOX_ASSISTANT_WILL_READ_EVERY="سيتم استخدام INBOX. سيقرأ المساعد كل رسالة بريد واردة."
MSG_WARN_VANE_CONTAINER_STARTED_BUT_HTTP_LOCALHOST="بدأت حاوية Vane لكن http://localhost:3000 لم يستجب خلال 60 ثانية."
MSG_WARN_VANE_LOCAL_WEB_SEARCH_FAILED_START="تعذّر بدء Vane (البحث المحلي على الويب). الأسباب الشائعة:"
MSG_WARN_WEB_SEARCH_OPTIONAL_REST_OSTLER_WORKS="  البحث على الويب اختياري؛ ويعمل باقي Ostler من دونه."
MSG_WARN_WE_STRONGLY_RECOMMEND_DEDICATED_LABEL_FOLDER="نوصي بشدة باستخدام تسمية/مجلد مخصص بدلًا من ذلك."
MSG_WARN_WHATSAPP_NEEDS_PHONE_NUMBER_BRIEF_DELIVERY="يحتاج WhatsApp إلى رقم هاتف لتسليم الموجز. حاول مرة أخرى،"
MSG_WARN_WIKI_COMPILED_BUT_WIKI_SITE_CONTAINER="تم تجميع الويكي لكن تعذّر بدء حاوية wiki-site."
MSG_WARN_WIKI_FIRST_COMPILE_FAILED_COMMON_CAUSES="فشل التجميع الأول للويكي. الأسباب الشائعة:"
MSG_WARN_WIKI_RECOMPILE_CATCHUP_LOAD_FAILED="تعذّر تحميل LaunchAgent الخاص باللحاق بالويكي في اليوم الأول. ما زالت إعادة بناء الويكي اليومية تعمل؛ سيتم تحديث الويكي في اليوم التالي بدلًا من خلال ساعة."
MSG_WARN_WIKI_RECOMPILE_LAUNCHAGENT_INSTALL_FAILED_SEE="فشل تثبيت LaunchAgent لإعادة تجميع الويكي. راجع المخرجات أعلاه."
MSG_WARN_WIKI_WILL_NOT_AUTO_UPDATE_MANUAL="لن يتحدّث الويكي تلقائيًا؛ تبقى إعادة البناء اليدوية متاحة:"
MSG_WARN_WIZARD_CONFIG_STAYS_PLACE_BINARY_STAYS="تبقى إعدادات المعالج كما هي؛ ويبقى الملف التنفيذي مجهّزًا. إعادة المحاولة يدويًا:"
MSG_WARN_YOUR_ASSISTANT_NEEDS_NAME_PICK_FROM="يحتاج مساعدك إلى اسم. اختر من الاقتراحات أعلاه أو اكتب اسمًا من اختيارك."
MSG_WARN_YOU_CAN_RE_GRANT_IT_SYSTEM="يمكنك منح الإذن مجددًا في إعدادات النظام > الخصوصية والأمن > جهات الاتصال."
MSG_WARN_YOU_CAN_RUN_SECURITY_SETUP_LATER="يمكنك تشغيل إعداد الأمان لاحقًا: python3 -m ostler_security.setup_wizard"
MSG_WARN_YOU_MAY_NEED_INSTALL_MANUALLY_INSTALL="قد تحتاج إلى التثبيت يدويًا: %s install sqlcipher3"

# ── Error messages (security / integrity, hard-fail context) ──

MSG_ERR_ACTUAL="  الفعلي:   %s"
MSG_ERR_CM042_BUNDLE_NOT_FOUND_POST_EXTRACT="لم تكن حزمة Ostler RemoteCapture موجودة في %s بعد الاستخراج. قد يكون أرشيف الإصدار تالفًا."
# Added 2026-09-24 after ERR-24-CM042-EXTRACT took a whole install down on a
# console walk. The two causes below were previously indistinguishable from a
# signing failure, because the ONLY message this limb could reach said
# "signature or notarisation check failed" -- for a bundle nothing had signed,
# checked or even found.
MSG_ERR_CM042_APPS_DIR_UNAVAILABLE="تعذّر إنشاء %s أو الوصول إليه، لذلك لا يوجد مكان لتثبيت Ostler RemoteCapture. هذه مشكلة في أذونات المجلد وليست مشكلة في التنزيل."
MSG_ERR_CM042_RENAME_FAILED="تم تنزيل Ostler RemoteCapture وفك ضغطه بشكل صحيح، لكن تعذّر نقله إلى %s. تُرك التطبيق الذي تم فك ضغطه في /Applications. هذه ليست مشكلة في التوقيع."
MSG_ERR_CM042_CODESIGN_OUTPUT="  أبلغ codesign --verify عن:"
MSG_ERR_CM042_REFUSING_STAGE_BUNDLE="  يتم رفض تجهيز حزمة لا تطابق المجموع الاختباري المنشور."
MSG_ERR_CM042_SHA_256_MISMATCH="عدم تطابق SHA-256 لأرشيف Ostler RemoteCapture."
MSG_ERR_CM042_PIN_FAILED="لم يتمكن Ostler من التأكد من أصالة تنزيل RemoteCapture هذا، لذلك لم يتم تثبيته."
MSG_ERR_CM042_VERSION_UNKNOWN="إصدار RemoteCapture هذا ليس من الإصدارات التي يتعرّف عليها Ostler، لذلك لم يتم تثبيته."
MSG_ERR_CM042_SIDECAR_DISAGREES="المجموع الاختباري المنشور مع تنزيل RemoteCapture هذا لا يطابق الملف، لذلك لم يتم تثبيته."
MSG_ERR_CM042_SPCTL_OUTPUT="  أبلغ spctl --assess عن:"
MSG_ERR_CM042_VERIFY_FAILED="فشل التحقق من توقيع Ostler RemoteCapture / توثيقه."
MSG_ERR_CODESIGN_DV_REPORTED="  أبلغ codesign -dv عن:"
MSG_ERR_EXPECTED="  المتوقع: %s"
MSG_ERR_FILE_BRIEF_REPORTED="  أبلغ file --brief عن: %s"
MSG_ERR_OSTLER_ASSISTANT_BINARY_NOT_MACH_O="الملف التنفيذي ostler-assistant في %s ليس ملفًا تنفيذيًا بصيغة Mach-O."
MSG_ERR_OSTLER_ASSISTANT_TARBALL_SHA_256_MISMATCH="عدم تطابق SHA-256 لأرشيف ostler-assistant."
MSG_ERR_REFUSING_STAGE_BINARY_THAT_DOES_NOT="  تم رفض تجهيز ملف تنفيذي لا يطابق المجموع الاختباري المنشور."
MSG_ERR_REFUSING_STRIP_QUARANTINE_LOAD_LAUNCHAGENT="تم رفض إزالة الحجر أو تحميل LaunchAgent."
MSG_ERR_RE_RUN_INSTALLER_ONCE_UPSTREAM_TARBALL="أعد تشغيل المثبّت بعد إصلاح الأرشيف المصدر."
MSG_ERR_URL="  الرابط:      %s"

# ── Fail messages (terminal -- the installer exits after) ──

MSG_FAIL_ARCH_INTEL_NOT_SUPPORTED_V1_0="أجهزة Mac بمعالج Intel غير مدعومة. يتطلب Ostler معالج Apple Silicon (M1 أو M2 أو M3 أو M4)."
MSG_FAIL_AT_LEAST_16_GB_RAM_REQUIRED="يلزم ما لا يقل عن 16 GB من الذاكرة. لديك %s GB. يُنصح بسعة 24 GB."
MSG_FAIL_CM042_SIGNATURE_FAILED="تم إيقاف تثبيت Ostler RemoteCapture: فشل التحقق من التوقيع أو التوثيق. تُركت الحزمة في /Applications لأغراض الدعم. راسل support@ostler.ai ثم أعد تشغيل المثبّت."
MSG_FAIL_COULD_NOT_PULL_AFTER_3_ATTEMPTS="تعذّر سحب %s بعد 3 محاولات. تحقق من الشبكة ثم أعد تشغيل المثبّت."
MSG_FAIL_COULD_NOT_PULL_NOMIC_EMBED_TEXT="تعذّر سحب nomic-embed-text بعد 3 محاولات. تحقق من الشبكة ثم أعد تشغيل المثبّت."
MSG_FAIL_DOCKER_NOT_AVAILABLE_RE_RUN_INSTALLER="Docker غير متاح. أعد تشغيل المثبّت لتثبيت Colima."
MSG_FAIL_CONTAINER_CLIENT_MISSING="الأمر docker غير موجود على هذا الـ Mac، لذلك لا يستطيع Ostler تشغيل الخدمات التي يحتاج إليها. أعد تشغيل المثبّت، وإذا فشل مجددًا فأرسل إلينا السجل في %s."
MSG_FAIL_CONTAINER_ENGINE_ABSENT="يحتاج Ostler إلى بيئة تشغيل للحاويات ولا توجد أي بيئة تستجيب على هذا الـ Mac. تعمل الويكي ورسم المعرفة وفهرس البحث لديك داخل حاويات، ولذلك توقف التثبيت هنا بدل أن يكتمل وتبقى هذه المكوّنات مفقودة. للإصلاح: افتح Terminal ونفّذ 'colima start'، ثم شغّل هذا المثبّت مرة أخرى. إذا كنت تستخدم Docker Desktop، فافتحه وانتظر حتى يستقر رمز الحوت، ثم أعد التشغيل. السجل الكامل في %s."
MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY="لم يصبح Docker جاهزًا في الوقت المناسب لتشغيل قواعد بيانات رسم المعرفة. تأكد من أن Colima أو Docker قيد التشغيل، ثم أعد تشغيل المثبّت."
MSG_FAIL_GRAPH_DB_PULL_FAILED="تعذّر تنزيل صور قواعد بيانات رسم المعرفة بعد عدة محاولات. غالبًا ما تكون المشكلة في الشبكة. تحقق من اتصالك بالإنترنت ثم أعد تشغيل المثبّت."
MSG_FAIL_GRAPH_DB_UP_FAILED="تم تنزيل قواعد بيانات رسم المعرفة لكن تعذّر تشغيلها. أعد تشغيل المثبّت، وإذا تكرر ذلك فافتح Terminal ونفّذ: cd ~/.ostler && docker compose up -d qdrant oxigraph redis"
MSG_FAIL_STORE_AUTH_LEAK="تعذّر على Ostler إكمال طلب موثّق إلى قاعدة بيانات رسم المعرفة. حاول مرتين بفاصل ثانيتين، ورُفضت المحاولتان. لا نعرف السبب بعد: قد تكون قاعدة البيانات ما زالت تبدأ التشغيل، أو قد لا تكون بيانات الاعتماد التي يحتفظ بها Ostler هي المتوقعة. لم تُمسّ بياناتك. كثيرًا ما ينجح تشغيل المثبّت مرة أخرى، وحتى في هذه الحالة نرغب في معرفة ما حدث – أرسل إلينا سجل التثبيت، فهذا خلل نحاول حاليًا إعادة إنتاجه."
MSG_FAIL_FDA_MODULE_MISSING_RE_RUN="وحدة استخراج FDA مفقودة من حزمة المثبّت. أعد تنزيل ملف .app من ostler.ai/install، أو أعد التشغيل باستخدام --allow-plaintext لأغراض التطوير/CI."
MSG_FAIL_FDA_DEPENDENCIES_IMPORT_RE_RUN="تم تثبيت وحدة استخراج البيانات لكن تعذّر تحميلها، لذلك سيفشل التحديث في الخلفية في كل مرة. حُفظ الإخراج الكامل في %s – أعد تشغيل المثبّت، وأرفق هذا الملف إذا تواصلت مع الدعم (المرجع: ERR-10-FDA-DEPS-IMPORT)."
MSG_FAIL_FDA_DEPS_UNSAFE_PATH="خطأ داخلي: جُهّزت وحدة استخراج البيانات داخل حزمة التطبيق، مما يُبطل توقيعها. هذا خلل في البناء وليس مشكلة في جهاز Mac لديك. أعد تنزيل ملف .app من ostler.ai/install (المرجع: ERR-10-FDA-DEPS-UNSAFE-PATH)."
MSG_FAIL_DOCTOR_PIP_INSTALL_FAILED_LOG_SAVED="فشل تثبيت تبعيات Doctor. حُفظ الإخراج الكامل في %s – أرفقه عند مراسلة support@ostler.ai (المرجع: ERR-17-DOCTOR-PIP)."
MSG_FAIL_PIPELINE_PIP_INSTALL_FAILED_LOG_SAVED="فشل تثبيت تبعيات مسار الاستيراد. حُفظ الإخراج الكامل في %s – أرفقه عند مراسلة support@ostler.ai (المرجع: ERR-14-PIPELINE-PIP)."
MSG_FAIL_HOMEBREW_INSTALL_FAILED_LOG_SAVED="فشل تثبيت Homebrew. حُفظ الإخراج الكامل في %s – أرفقه عند مراسلة support@ostler.ai."
MSG_FAIL_IMPORT_PIPELINE_INSTALL_FAILED_RE_RUN_INSTALLER="فشل تثبيت مسار الاستيراد. حزمة contact_syncer مطلوبة للتثبيت الاعتيادي. أعد التشغيل باستخدام --allow-plaintext لأغراض التطوير/CI، أو أعد تنزيل المثبّت وحاول مرة أخرى."
MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="يلزم الوصول بصلاحية sudo لتعطيل السكون وتثبيت Homebrew. أعد التشغيل عندما تكون جاهزًا."
MSG_FAIL_NEITHER_COLIMA_NOR_DOCKER_DESKTOP_COULD="تعذّر تشغيل Colima وDocker Desktop. ثبّت Docker Desktop ثم أعد التشغيل."
MSG_FAIL_NOT_ENOUGH_DISK_SPACE_GB_FREE="مساحة القرص غير كافية (%s GB). حرّر بعض المساحة وحاول مرة أخرى."
MSG_FAIL_MACOS_BELOW_FLOOR="إصدار macOS %s أقدم مما يدعمه Ostler. يتطلب Ostler الإصدار macOS %s أو أحدث: تطبيق المثبّت مبني له ولن يفتح على أي إصدار أقدم. حدّث macOS ثم شغّل المثبّت مرة أخرى."
MSG_FAIL_NO_PASSKEY_SET_NO_EXISTING_SECURITY="لم يتم تعيين مفتاح مرور ولا توجد إعدادات أمان حالية. أعد التشغيل باستخدام --allow-plaintext لأغراض التطوير/CI، أو أعد تشغيل المثبّت وأقرّ بإرشادات Touch ID."
MSG_FAIL_CM048_PIPELINE_REQUIRED_RE_RUN="محرك ذاكرة المحادثات مطلوب. أعد التشغيل باستخدام --allow-plaintext لأغراض التطوير/CI، أو أصلح الحزمة المفقودة المذكورة أعلاه وأعد المحاولة."
MSG_FAIL_DAEMON_RUN_SOURCE_UNSUPPORTED_SKEW="لا يدعم برنامج Ostler الخلفي المضمّن (الإصدار %s في %s) الأمر 'run-source' الذي يحتاج إليه هذا المثبّت لتمرير الاستيعاب عبر الوصول الكامل إلى القرص. هذا عدم توافق في الإصدارات داخل حزمة المثبّت: سيؤدي تثبيته إلى تعطل كل مصادر الاستيعاب بصمت، وسيصبح المنتج قديمًا دون أي خطأ ظاهر. أعد تنزيل ملف .app من ostler.ai/install وحاول مرة أخرى (المرجع: ERR-11-DAEMON-RUN-SOURCE-SKEW)."
MSG_FAIL_OSTLER_SECURITY_INSTALL_FAILED_RE_RUN="فشل تثبيت ostler_security. أعد التشغيل باستخدام --allow-plaintext لأغراض التطوير/CI، أو أصلح خطأ pip المذكور أعلاه وأعد المحاولة."
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="فشل إعداد مفتاح المرور. أعد التشغيل باستخدام --allow-plaintext لأغراض التطوير/CI، أو أصلح الخطأ المذكور أعلاه وأعد المحاولة."
MSG_FAIL_PYSQLCIPHER3_REQUIRED_ENCRYPTED_DATABASES_RE_RUN="مكتبة sqlcipher3 مطلوبة لقواعد البيانات المشفّرة. أعد التشغيل باستخدام --allow-plaintext لأغراض التطوير/CI، أو أصلح خطأ pip المذكور أعلاه وأعد المحاولة."
MSG_FAIL_THIS_INSTALLER_MACOS_ONLY_LINUX_SUPPORT="هذا المثبّت مخصص لنظام macOS فقط."
MSG_FAIL_XCODE_COMMAND_LINE_TOOLS_INSTALL_DID="لم يكتمل تثبيت Xcode Command Line Tools خلال 15 دقيقة. افتح Terminal ونفّذ 'xcode-select --install'، وانقر على «تثبيت» في نافذة macOS وانتظر حتى ينتهي، ثم أعد تشغيل هذا المثبّت."

# ── DMG #48 (2026-05-27) silent-bail hardening (PR 2 of TNM brief
#    `launch/TNM_BRIEF_dmg48_three_blockers_2026-05-27.md` in the
#    HR015 repo):
#    each "brew install X" step now verifies the post-condition (X is on
#    PATH or the expected binary exists) and fail_with_code's loudly if
#    not. Studio retest of DMG #47 silently dropped brew/colima/tailscale
#    despite the GUI flowing to "end". The strings below back the new
#    fail_with_code callsites. Reference codes use ERR-NN-DMG48-PKG-MISSING
#    so they sort next to each other in the support catalogue. ──
MSG_FAIL_HOMEBREW_MISSING_AFTER_INSTALL="أبلغ تثبيت Homebrew عن نجاحه لكن /opt/homebrew/bin/brew مفقود. راجع %s للاطلاع على السجل الكامل. للاسترداد: افتح Terminal ونفّذ '/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"' ثم أعد تشغيل المثبّت."
MSG_FAIL_HOMEBREW_NOT_ON_PATH="Homebrew مثبّت في /opt/homebrew/bin/brew لكن الأمر 'brew' ليس في PATH بعد تنفيذ shellenv. افتح نافذة Terminal جديدة وأعد تشغيل المثبّت."
MSG_FAIL_COLIMA_MISSING_AFTER_BREW="أبلغ الأمر 'brew install colima docker docker-compose' عن نجاحه لكن colima ليس في PATH. راجع %s بحثًا عن أخطاء Homebrew. للاسترداد: افتح Terminal ونفّذ 'brew install colima docker docker-compose' يدويًا، ثم أعد تشغيل المثبّت."
MSG_FAIL_DOCKER_CLI_MISSING_AFTER_BREW="أبلغ الأمر 'brew install colima docker docker-compose' عن نجاح التثبيت، لكن أداة docker CLI غير موجودة في PATH. تحقق من %s. الحل: نفّذ 'brew install docker' يدويًا ثم أعد تشغيل المثبّت."
MSG_FAIL_OLLAMA_MISSING_AFTER_BREW="أبلغ تثبيت تطبيق Ollama عن نجاح العملية، لكن الملف التنفيذي مفقود في /Applications/Ollama.app. تحقق من %s. الحل: نفّذ 'brew install --cask ollama-app' يدويًا ثم أعد تشغيل المثبّت."
MSG_FAIL_EMBED_HEALTHCHECK="Ollama قيد التشغيل لكن نموذج التضمين لم يُرجع أي متجه (استجابة HTTP ليست 200، أو نتيجة فارغة). ستكون بطاقة الأشخاص والبحث والتصفح فارغة جميعًا. تحقق من %s. الحل: تأكد من تثبيت تطبيق Ollama (وليس حزمة Homebrew) وأنه يعمل، ثم أعد تشغيل المثبّت."
MSG_FAIL_SQLCIPHER_MISSING_AFTER_BREW="أبلغ الأمر 'brew install sqlcipher' عن نجاح التثبيت، لكن sqlcipher غير موجود في PATH. تحقق من %s. الحل: نفّذ 'brew install sqlcipher' يدويًا ثم أعد تشغيل المثبّت."
MSG_FAIL_TAILSCALE_INSTALL_FAILED="لم ينتج الأمر 'brew install --cask tailscale' الملف /Applications/Tailscale.app. تحقق من %s. الحل: نزّل Tailscale من https://tailscale.com/download/macos واسحبه إلى /Applications، ثم أعد تشغيل المثبّت."
MSG_FAIL_PYTHON311_MISSING_AFTER_BREW="أبلغ الأمر 'brew install python@3.11' عن نجاح التثبيت، لكن الملف التنفيذي python3.11 مفقود في /opt/homebrew/opt/python@3.11/bin/python3.11. تحقق من %s. الحل: نفّذ 'brew reinstall python@3.11' ثم أعد تشغيل المثبّت."

# ── Prompts (gui_read titles + help text) ──
#
# Customer-facing questions the user reads during setup. Each prompt
# id (e.g. "assistant_name") gets a MSG_PROMPT_<UPPER>_TITLE entry,
# and -- where the prompt carries non-empty help / sub-line copy --
# a matching MSG_PROMPT_<UPPER>_HELP entry. Format-string entries
# use printf %s placeholders for runtime values (e.g. detected
# country code, detected timezone).

MSG_PROMPT_REUSE_SETTINGS_TITLE="عثرنا على إجاباتك السابقة"
MSG_PROMPT_REUSE_SETTINGS_HELP="اكتشفنا محاولة تثبيت سابقة على هذا الـ Mac. ستُستخدم إجاباتك السابقة عن الأسئلة (الاسم، واسم المساعد، والمنطقة الزمنية، ورمز الدولة، والقنوات، وغيرها) حتى لا تضطر إلى إدخالها من جديد. اختر نعم للمتابعة من حيث توقفت، أو لا لإعادة الأسئلة من البداية."
MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT="الإجابات السابقة التي عثرنا عليها: الاسم = %s، المساعد = %s، المنطقة الزمنية = %s."

MSG_PROMPT_PERMS_OK_TITLE="هل أنت مستعد للمتابعة؟"
MSG_PROMPT_PERMS_OK_HELP="سيطلب macOS إذن الوصول إلى جهات الاتصال والملفات والمجلدات. يمكن منح الوصول الكامل إلى القرص لاحقًا، وهو اختياري."

MSG_PROMPT_USER_NAME_DETECTED_TITLE="الاسم الكامل (كما يظهر في جهات الاتصال)"
MSG_PROMPT_USER_NAME_FALLBACK_TITLE="الاسم الكامل (مثال: Tom Harrison)"

MSG_PROMPT_USER_ID_TITLE="بماذا يناديك مساعدك؟"
MSG_PROMPT_USER_ID_HELP="اسم قصير يستخدمه مساعدك لمخاطبتك (مثال: 'Andy' أو 'Andrew' أو 'Mrs Smith'). هذا هو الاسم الذي يظهر في موجزاتك الصباحية وردود المحادثة. وهو مختلف عن اسمك الكامل أعلاه."

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
MSG_CONFIRM_CALENDARS_REVIEW_TITLE="هذه هي تقويماتك. هل تبدو صحيحة؟"
MSG_CONFIRM_CALENDARS_REVIEW_INTRO="خمّنا صاحب كل تقويم، حتى لا يخلط موجزك بين رحلتك ورحلة غيرك."
MSG_CONFIRM_CALENDARS_SET_ASIDE_HEADING="تم استبعادها تلقائيًا ولن تُستخدم في موجزك:"
MSG_CONFIRM_CALENDAR_ROW="%s: %s, %s (%s)"
MSG_CONFIRM_CALENDAR_SET_ASIDE_ROW="%s: %s (%s)"
MSG_CONFIRM_CALENDAR_OWNER_YOU="خاص بك"
MSG_CONFIRM_CALENDAR_EVENTS_ONE="%s حدث"
MSG_CONFIRM_CALENDAR_EVENTS_MANY="%s أحداث"
MSG_CONFIRM_CALENDAR_KIND_HOLIDAY="العطلات الرسمية"
MSG_CONFIRM_CALENDAR_KIND_BIRTHDAY="أعياد الميلاد"
MSG_CONFIRM_CALENDAR_KIND_SUGGESTION="اقتراحات Siri"
MSG_CONFIRM_CALENDAR_KIND_SUBSCRIBED="تقويم تشترك فيه"
MSG_CONFIRM_CALENDAR_KIND_REMINDERS="التذكيرات"
MSG_CONFIRM_CALENDAR_INCLUDE_TITLE="هل تريد استخدام \"%s\" في موجزك؟"
MSG_CONFIRM_CALENDAR_INCLUDE_HELP="استبعدنا هذا التقويم لأنه يبدو كأنه %s. أجب بنعم إذا كان فعلًا مفكرة شخص ما."
MSG_CONFIRM_CALENDAR_HELP="%s, e.g. %s"
MSG_CONFIRM_CALENDAR_OWNER_TITLE="لمن التقويم \"%s\"؟"
MSG_CONFIRM_CALENDAR_TYPE_TITLE="ما نوع التقويم \"%s\"؟"
# NEEDS REVIEW: If personal/work/family/shared/other are typed answers compared by the installer, they must stay in English; verify.
MSG_CONFIRM_CALENDAR_TYPE_HELP="اختر واحدًا من: شخصي، عمل، عائلي، مشترك، آخر. يحدد هذا مدى حساسية التعامل مع أحداثه."
MSG_CONFIRM_CALENDARS_SAVED="تم حفظ أصحاب التقويمات"
MSG_CONFIRM_CALENDARS_FAILED="تعذّر حفظ أصحاب التقويمات (غير حرج؛ يمكنك تعيينهم لاحقًا)"
MSG_CONFIRM_IDENTITY_COLLAPSE_TITLE="نعتقد أن هذه الملفات الشخصية كلها لك (%s). هل تريد دمجها في ملف واحد؟"
MSG_CONFIRM_IDENTITY_COLLAPSE_HELP="تشترك هذه الملفات الشخصية معك في إشارة هوية قوية (نطاق بريد إلكتروني أو ملف LinkedIn أو جهة عمل). يمنع دمجها مساعدك من اعتبار سجلك الشخصي عدة أشخاص مختلفين. يمكنك التراجع عن ذلك لاحقًا."
MSG_CONFIRM_IDENTITY_NAMESAKE_TITLE="شخص يشاركك اسمك لكنه يبدو شخصًا مختلفًا (%s). هل هذا أنت أم شخص آخر؟"
# NEEDS REVIEW: Verify whether 'different'/'me' are typed tokens (kept English) or menu labels that should be translated; keep consistent with s870.
MSG_CONFIRM_IDENTITY_NAMESAKE_HELP="اختر 'different' للإبقاء عليه شخصًا منفصلًا (لن يدمجه مساعدك معك أبدًا). اختر 'me' فقط إذا كان هذا أنت فعلًا."
MSG_CONFIRM_IDENTITY_SAVED="تم حفظ هويتك"
MSG_CONFIRM_IDENTITY_FAILED="تعذّر حفظ خيارات الهوية (غير حرج؛ يمكنك التأكيد لاحقًا)"

# NEEDS REVIEW: source asks for human translation of this key
MSG_STEP_INSTALLING_THIS_TAKES_A_WHILE="جارٍ التثبيت في الخلفية (من نحو 45 دقيقة إلى بضع ساعات)"

MSG_PROMPT_COUNTRY_CODE_CONFIRM_TITLE="هل تريد استخدام +%s؟"
MSG_PROMPT_COUNTRY_CODE_ENTER_TITLE="أدخل رمز الدولة (مثال: 44 للمملكة المتحدة، 1 للولايات المتحدة)"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_TITLE="رمز الدولة الافتراضي"
MSG_PROMPT_COUNTRY_CODE_DEFAULT_HELP="يُستخدم لتوحيد صيغة أرقام الهواتف عند استيراد جهات الاتصال ولتحديد منطقتك (المملكة المتحدة / الاتحاد الأوروبي / الولايات المتحدة / أخرى) للإعدادات الافتراضية المتعلقة بالامتثال القانوني."
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE="تم رصد +%s. هل تريد استخدامه لـ Hub الخاص بك؟"
MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_HELP="تم الرصد من رقم هاتفك أعلاه. اختر نعم لاستخدامه، أو لا لإدخال رمز دولة مختلف."

MSG_PROMPT_TZ_CONFIRM_TITLE="هل تريد استخدام هذه المنطقة الزمنية؟"
MSG_PROMPT_TZ_CONFIRM_HELP="المنطقة الزمنية المرصودة: %s"
MSG_PROMPT_USER_TZ_TITLE="أدخل المنطقة الزمنية (مثال: Europe/London، Asia/Hong_Kong)"

MSG_PROMPT_ASSISTANT_NAME_TITLE="ماذا تود أن تسمّي مساعدك؟"
MSG_PROMPT_ASSISTANT_NAME_HELP_FULL="الاسم في الحقل اقتراح عشوائي، اكتب فوقه أي اسم تشاء. Marvin وSamantha وJoshua وFriday وAthena وSage وRosie كلها خيارات شائعة." # assistant-name-exempt: F6.1 suggestion-pool exemplar
MSG_PROMPT_ASSISTANT_NAME_HELP_SHORT="اكتب أي اسم تشاء، فالاقتراح مجرد نقطة بداية."

MSG_PROMPT_CHANNEL_CHOICE_TITLE="كيف سيتواصل معك مساعدك؟"
MSG_PROMPT_CHANNEL_CHOICE_HELP="اختر قنوات المراسلة التي تود أن يستخدمها مساعدك. يمكنك تغيير ذلك لاحقًا من قسم Doctor في التطبيق."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_WHATSAPP_CONSENT_TITLE="هل تريد تفعيل المراسلة عبر WhatsApp لمساعدك؟"
# NEEDS REVIEW: Consent/legal wording; translation looks accurate but a lawyer should confirm its legal force.
MSG_PROMPT_WHATSAPP_CONSENT_HELP="WhatsApp Web خدمة تابعة لجهة خارجية. بالتفعيل، فإنك توافق على أن رسائلك تمر عبر البنية التحتية الخاصة بـ WhatsApp قبل وصولها إلى نسخة Ostler المحلية لديك، وأن WhatsApp (شركة Meta Platforms Ireland Ltd) قد تعلّق حسابك على WhatsApp أو تقيّده أو تنهيه بسبب الاستخدام الآلي. يمكنك إيقاف ذلك لاحقًا من الإعدادات."

MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE="رقم هاتفك على WhatsApp"
# The example used to read "+44 7700 900123" – spaces – in the same sentence as
# "no spaces". A customer copying the shape they were shown got a number the
# inbound allowlist and the brief delivery address could not use, while pairing
# still worked because that one field strips non-digits. Example and rule now
# agree, and install.sh normalises whatever is typed either way.
MSG_PROMPT_WHATSAPP_RECIPIENT_HELP="رقم دولي مع رمز الدولة، مثال: +447700900123. أرقام وعلامة + في البداية فقط، دون مسافات أو أقواس أو شرطات."
MSG_INFO_WHATSAPP_NUMBER_NORMALISED="تم الحفظ بالصيغة %s. يتطلب WhatsApp الرقم دون مسافات أو أقواس."

MSG_PROMPT_IMESSAGE_FDA_ASSIST_TITLE="فعّل «الوصول الكامل إلى القرص» لمساعد Ostler"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE1="إعدادات النظام مفتوحة على «الوصول الكامل إلى القرص»."
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
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE2="ابحث عن \"%s\" في القائمة وفعّل مفتاح «الوصول الكامل إلى القرص» الخاص به."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3="غير موجود في القائمة؟ اسحب \"%s\" من نافذة Finder إلى القائمة، ثم فعّل مفتاحه. الترتيب لا يهم، يمكنك النقر على تم قبل ذلك أو بعده، فالمثبّت ينتظر حتى يصبح المفتاح مفعّلًا فعلًا."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_LINE3_NO_FINDER="غير موجود في القائمة؟ تعذّر على Ostler فتح نافذة Finder لك. في Finder اضغط ⌘⇧G، وأدخل المسار أدناه، ثم اسحب \"%s\" إلى القائمة وفعّل مفتاحه. الترتيب لا يهم، يمكنك النقر على تم قبل ذلك أو بعده، فالمثبّت ينتظر حتى يصبح المفتاح مفعّلًا فعلًا."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH="موقع التطبيق: %s"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_PATH_ON_CLIPBOARD="موقع التطبيق: %s، وقد نُسخ هذا المسار إلى الحافظة، لذا في Finder اضغط ⌘⇧G، ثم ⌘V، ثم Return."
MSG_PROMPT_IMESSAGE_FDA_ASSIST_BUTTON="تم"
MSG_PROMPT_IMESSAGE_FDA_ASSIST_DONE_HINT="يمكنك النقر على تم قبل تفعيل المفتاح أو بعده، فالمثبّت ينتظر حتى يصبح مفعّلًا فعلًا."

MSG_PROMPT_INSTALLER_FDA_ASSIST_TITLE="السماح لـ Ostler بقراءة بيانات Mac لديك"
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE1="إعدادات النظام مفتوحة على «الوصول الكامل إلى القرص»."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE2="ابحث عن \"OstlerInstaller\" في القائمة وفعّله."
MSG_PROMPT_INSTALLER_FDA_ASSIST_LINE3="انقر على تم عند الانتهاء وسيقرأ Ostler سجل Safari والملاحظات ورسائل iMessage والبريد."
MSG_PROMPT_INSTALLER_FDA_ASSIST_BUTTON="تم"

# CX-87 (DMG #48g, 2026-05-29): pre-warn before the FDA grant flow.
# Matches the shape of the CX-47 (Downloads/Desktop/Documents) and
# CX-55 (iMessage Automation) pre-warns. The crucial guidance is the
# "Quit & Reopen" hint -- without it the customer reads the macOS
# dialog as a choice and clicks Later, which silently breaks the FDA
# grant for OstlerInstaller.app and lands the install at the
# extraction step with no Safari / Mail / iMessage access.
MSG_PROMPT_INSTALLER_FDA_PREWARN_TITLE="التالي: الوصول الكامل إلى القرص للمثبّت"
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE1="بعد ذلك سيطلب منك macOS منح OstlerInstaller «الوصول الكامل إلى القرص»."
# NEEDS REVIEW: macOS dialog button labels should match Apple's Arabic localisation; verify exact Arabic labels on an Arabic macOS.
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE2="بعد تفعيل المفتاح، ستظهر نافذة من macOS تطلب منك اختيار «إنهاء وإعادة الفتح» أو «لاحقًا»."
# NEEDS REVIEW: Button label should match Apple's Arabic 'Quit & Reopen'; verify exact wording on an Arabic macOS.
MSG_PROMPT_INSTALLER_FDA_PREWARN_LINE3="انقر على «إنهاء وإعادة الفتح». سيعيد المثبّت تشغيل نفسه ويتابع من هذه الخطوة تلقائيًا."
MSG_PROMPT_INSTALLER_FDA_PREWARN_BUTTON="حسنًا"
MSG_INFO_INSTALLER_FDA_PREWARN="جارٍ إطلاعك على خطوات منح «الوصول الكامل إلى القرص»..."
MSG_INFO_INSTALLER_FDA_ASSIST_OPENING="جارٍ فتح إعدادات النظام لتتمكن من منح المثبّت «الوصول الكامل إلى القرص»..."
MSG_INFO_INSTALLER_FDA_ASSIST_GRANTED="تم منح المثبّت إذن الوصول الكامل إلى القرص. سيقرأ الآن Safari والملاحظات ورسائل iMessage والبريد."
MSG_INFO_INSTALLER_FDA_ASSIST_STILL_NEEDED="لم يُمنح الوصول الكامل إلى القرص بعد. سنتابع من دونه، ويمكنك إعادة تشغيل المثبّت لاحقًا لاستخراج بيانات Safari والملاحظات ورسائل iMessage."
# WALK-1 (Wave 2.1): the installer Full Disk Access grant is now asked
# upfront in Phase 2. These two lines reassure the customer that the long
# middle is unattended, and pre-announce the one permission we cannot
# front-load: the daemon's Messages-history grant (its binary does not
# exist until late Phase 3). Mirrors the Tailscale sign-in pre-announce.
# TODO(i18n): de/fr/es/it translations needed -- do NOT machine-translate.
# 2026-08-20: "runs on its own – you can walk away" was the earliest of the
# three false unattended promises (Andy's log, 12:39:51). Same fix: say what
# is still wanted rather than promising none of it.
MSG_INFO_INSTALLER_FDA_WALKAWAY_PREANNOUNCE="اكتمل إعداد الوصول الكامل إلى القرص للمثبّت. يبدأ الآن الجزء الأطول، ويعمل في معظمه من تلقاء نفسه – لكن انتبه إلى نافذة macOS قد تطلب تثبيت أدوات المطوّر، وعد إلينا لبضع دقائق من الإعداد قرب النهاية."
MSG_INFO_DAEMON_FDA_LATER_PREANNOUNCE="يأتي إذن واحد إضافي (سجل الرسائل لمساعدك) قرب النهاية، بعد تثبيت مساعدك – وسنرشدك إليه حينها."
# WALK-1 (Wave 2.1): the single late recovery modal. It fires ONLY for a
# customer who saw the upfront FDA ask but did not grant it, just before
# extraction. Granting now, or continuing with less data, both let the
# install complete. TODO(i18n): de/fr/es/it needed -- do NOT machine-translate.
MSG_PROMPT_INSTALLER_FDA_RECOVER_TITLE="ما زال الوصول الكامل إلى القرص مطلوبًا"
# WALK-874(a): the parenthetical "(now open at Full Disk Access)" was
# the same untrue assertion as the two ASSIST_LINE1 keys, buried
# mid-sentence in a third one. The pane state is now stated by the
# verified line the modal opens with, so this line only has to name the
# row and the switch.
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE1="أوشك Ostler على قراءة بيانات الـ Mac الخاص بك، لكن الوصول الكامل إلى القرص لـ OstlerInstaller ما زال متوقفًا. ابحث عن \"OstlerInstaller\" في القائمة وشغّله."
MSG_PROMPT_INSTALLER_FDA_RECOVER_LINE2="أو انقر على متابعة لإنهاء التثبيت ببيانات أقل – يمكنك منح الإذن وإعادة تشغيل أداة الاستخراج لاحقًا."
MSG_PROMPT_INSTALLER_FDA_RECOVER_BUTTON="متابعة"

MSG_PROMPT_IMESSAGE_ALLOWED_TITLE="جهات الاتصال المسموح بها"
MSG_PROMPT_IMESSAGE_ALLOWED_HELP="أشخاص موثوقون: أرقام الهواتف وعناوين البريد الإلكتروني لمعرّف Apple (مفصولة بفواصل). يردّ %s فقط على الأشخاص في هذه القائمة، وتُتجاهل الرسائل من أي شخص آخر. مطلوب إدخال واحد على الأقل.

على سبيل المثال:
+447700900000, you@example.com"

MSG_PROMPT_EMAIL_APPLE_MAIL_TITLE="قراءة البريد عبر Apple Mail؟"
MSG_PROMPT_EMAIL_APPLE_MAIL_HELP="يقرأ أي حساب بريد إلكتروني أضفته إلى Apple Mail (iCloud وGmail وOutlook وغيرها) باستخدام الوصول الكامل إلى القرص. لا تُخزَّن كلمات مرور. يوصى به لجميع المستخدمين تقريبًا."

MSG_PROMPT_MAIL_NOT_CONNECTED_TITLE="إضافة حساب بريد إلى Apple Mail؟"
MSG_PROMPT_MAIL_NOT_CONNECTED_HELP="لا توجد حسابات متصلة بـ Apple Mail على هذا الـ Mac بعد، لذا لن يجد Ostler بريدًا لقراءته. اختر نعم لفتح إعدادات النظام > حسابات الإنترنت الآن (يمكنك إضافة iCloud أو Gmail أو Outlook هناك). اختر لا للتخطي، ويمكنك إضافة حساب لاحقًا وسيعرض Doctor تنبيه متابعة إن لم يصل بريد خلال 24 ساعة."

MSG_PROMPT_MAIL_EXTEND_HISTORY_TITLE="جلب سجل Apple Mail الكامل؟"
MSG_PROMPT_MAIL_EXTEND_HISTORY_HELP="يقرأ Ostler افتراضيًا آخر خمس سنوات من Apple Mail. إن كنت تحتفظ بأكثر من ذلك على هذا الـ Mac وتريد إضافته كله إلى مخطط معرفتك، فاختر نعم لجلب السجل المحلي الكامل الآن (قد يستغرق ذلك وقتًا أطول قليلًا لصندوق بريد كبير). اختر لا للإبقاء على نطاق السنوات الخمس، ويمكنك توسيعه لاحقًا من Doctor."

MSG_PROMPT_EMAIL_CUSTOM_IMAP_TITLE="هل تريد أيضًا ضبط خادم IMAP+SMTP مخصص؟"
MSG_PROMPT_EMAIL_CUSTOM_IMAP_HELP="لصناديق البريد المستضافة ذاتيًا فقط. أبقِ الخيار على لا إن كانت حساباتك لدى Gmail أو iCloud أو Outlook – فهي تعمل بشكل أفضل عبر Apple Mail أعلاه."

MSG_PROMPT_IMAP_HOST_TITLE="مضيف IMAP"
MSG_PROMPT_IMAP_HOST_HELP="لخادم IMAP المستضاف ذاتيًا أو المخصص فقط. استخدم Apple Mail (أعلاه) لحسابات Gmail / iCloud / Outlook."
MSG_PROMPT_IMAP_PORT_TITLE="منفذ IMAP"

MSG_PROMPT_SMTP_HOST_TITLE="مضيف SMTP"
MSG_PROMPT_SMTP_PORT_TITLE="منفذ SMTP"

MSG_PROMPT_EMAIL_USERNAME_TITLE="عنوان البريد الإلكتروني (يُستخدم أيضًا كاسم مستخدم IMAP/SMTP)"

MSG_PROMPT_EMAIL_ALLOWED_TITLE="من يمكنه مراسلة مساعدك بالبريد الإلكتروني؟"
MSG_PROMPT_EMAIL_ALLOWED_HELP="عناوين بريدك الإلكتروني الخاصة، مفصولة بفواصل. يردّ %s فقط على البريد الوارد من العناوين في هذه القائمة، ويُتجاهل البريد من أي شخص آخر. مطلوب عنوان واحد على الأقل. تمت تعبئة عنوانك نيابةً عنك: يمكنك تغييره أو إضافة عنوان آخر."

MSG_PROMPT_EMAIL_PASSWORD_TITLE="كلمة المرور (مخفية)"
MSG_PROMPT_EMAIL_PASSWORD_HELP="كلمة مرور خادم IMAP/SMTP المستضاف ذاتيًا. تُخزَّن محليًا ضمن ~/.ostler/ ولا تُرسل أبدًا إلى Creative Machines. تُحفظ كنص عادي: الحماية الوحيدة لها هي أذونات الملف، التي تسمح لحساب macOS الخاص بك فقط دون سواه. ولا شيء يشفّرها لاحقًا. استخدم كلمة مرور تطبيق بدلًا من كلمة مرور حسابك الرئيسية."
MSG_PROMPT_EMAIL_PASSWORD_CONFIRM_TITLE="تأكيد كلمة المرور"

MSG_PROMPT_EMAIL_IMAP_FOLDER_TITLE="أي مجلد يجب أن يراقبه المساعد؟"
MSG_PROMPT_EMAIL_IMAP_FOLDER_HELP="يوصى باستخدام تسمية أو مجلد مخصص (مثل Ostler). سنقرأ الرسائل الموجودة هناك فقط، ونترك صندوق الوارد الرئيسي دون مساس."

MSG_PROMPT_EMAIL_INBOX_CONFIRM_TITLE="اكتب INBOX مرة أخرى للتأكيد، أو اضغط متابعة لاستخدام 'Ostler'"
MSG_PROMPT_EMAIL_INBOX_CONFIRM_HELP="يعني INBOX أن المساعد سيقرأ كل بريد إلكتروني تتلقاه. نوصي بشدة باستخدام تسمية/مجلد مخصص بدلًا من ذلك."

MSG_PROMPT_EXPORTS_ACK_TITLE="هل طلبت تصدير بياناتك؟"
MSG_PROMPT_EXPORTS_ACK_HELP="يستورد Ostler من نحو 20 منصة. القائمة الكاملة مع روابط مباشرة إلى صفحة الطلب لدى كل مزوّد موجودة في docs.ostler.ai/data-exports.

يصل معظم الأرشيفات عبر البريد الإلكتروني خلال يوم إلى 3 أيام. عندما تصل ملفات ZIP، ضعها في مجلد التنزيلات وسيعثر عليها Ostler تلقائيًا.

تخطَّ ما لا تستخدمه، ويمكنك دائمًا استيراد المزيد لاحقًا."

MSG_PROMPT_FILEVAULT_SKIP_TITLE="المتابعة مع قرص غير مشفّر أثناء التخزين؟"
# NEEDS REVIEW: Apple Arabic uses 'الخصوصية والأمن'; informed-consent/recorded choice wording should be checked by a lawyer.
MSG_PROMPT_FILEVAULT_SKIP_HELP="FileVault متوقف على هذا الـ Mac، لذا فالقرص غير مشفّر أثناء التخزين.

ماذا يعني ذلك إن تابعت: كل ما يخزّنه Ostler -- مخطط بياناتك الشخصي بالكامل (الويكي والمحادثات وملاحظات المعرفة) ضمن ~/Documents/Ostler، إضافةً إلى أسرار الخدمات وقواعد البيانات ضمن ~/.ostler -- يُكتب على القرص دون تشفير. يستطيع أي شخص يمكنه الإقلاع من هذا القرص أو إخراجه أو الوصول إلى جلسة مفتوحة أن يقرأ كل ذلك. يشفّر Ostler أكثر قواعد بياناته حساسية بعبارة مرور في كل الأحوال، لكن باقي بياناتك محمية بقدر حماية القرص نفسه فقط.

يوصى بشدة بتشغيل FileVault. يمكنك تشغيله في أي وقت من إعدادات النظام > الخصوصية والأمن > FileVault -- فهو يشفّر في الخلفية دون إعادة التثبيت.

اختر نعم للمتابعة الآن مع القرص غير المشفّر أثناء التخزين (هذا خيار متعمّد ومستنير -- وسيُسجَّل).
اختر لا للتوقف هنا لتشغيل FileVault أولًا، ثم أعد تشغيل المثبّت. لم يحدث أي خطأ في الحالتين."

MSG_PROMPT_PASSKEY_ACK_TITLE="جاهز لإعداد تشفير القرص"
MSG_PROMPT_PASSKEY_ACK_HELP="تُشفَّر قواعد بيانات Ostler الحساسة باستخدام SQLCipher بعبارة مرور تختارها في الشاشة التالية. ستكتب عبارة المرور هذه في كل مرة تشغّل فيها واجهة Hub. يُنشأ أيضًا مفتاح استرداد منفصل يُعرض مرة واحدة في نهاية التثبيت. للحصول على حماية كاملة لكل ما على Mac أثناء التخزين، أبقِ FileVault في macOS قيد التشغيل. اضغط متابعة عندما تكون جاهزًا."

MSG_PROMPT_RECOVERY_PASSPHRASE_OPT_IN_TITLE="هل تريد تعيين عبارة مرور للاسترداد أيضًا؟ (موصى به)"
MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE="اختر عبارة المرور"
MSG_PROMPT_RECOVERY_PASSPHRASE_HELP="تشفّر عبارة المرور هذه الرسم المعرفي الخاص بك وتفتح واجهة Hub عند كل بدء تشغيل. 12 حرفًا على الأقل. لا يمكننا استرجاعها لك. يُنصح بحفظها في مدير كلمات المرور."
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_TITLE="أكّد عبارة المرور"
MSG_PROMPT_RECOVERY_PASSPHRASE_CONFIRM_HELP="أعد إدخال عبارة المرور نفسها للتأكيد."

MSG_PROMPT_IMPORT_CONFIRM_TITLE="هل تريد استيراد هذه أثناء التثبيت؟"
MSG_PROMPT_IMPORT_CONFIRM_HELP="سيتم استيراد ملفات تصدير GDPR التي تم العثور عليها إلى رسمك المعرفي أثناء التثبيت."

MSG_PROMPT_DISNEY_XLSX_PASSWORD_TITLE="كلمة مرور تصدير Disney+"
MSG_PROMPT_DISNEY_XLSX_PASSWORD_HELP="تقدّم Disney+ ملف تصدير GDPR كجدول بيانات محمي بكلمة مرور، وهذا أمر طبيعي وليس مشكلة في التنزيل. أدخل كلمة المرور لاستيراد سجل مشاهدات Disney+ الآن، أو اتركها فارغة لتخطيه؛ وسيتم استيراد كل شيء آخر كالمعتاد."

MSG_PROMPT_MANUAL_EXPORTS_PATH_TITLE="هل لديك ملفات تصدير بيانات جاهزة؟"
MSG_PROMPT_MANUAL_EXPORTS_PATH_HELP="يمكن لـ Ostler استيراد أرشيفات وسائل التواصل الاجتماعي والمنصات – سجلك الكامل مع الأصدقاء والعائلة والأماكن والآراء – منذ البداية. كلما عرف Ostler أكثر في اليوم الأول، كان أكثر فائدة في اليوم الأول. يمكنك أيضًا إضافتها لاحقًا؛ لا داعي للعجلة.

اطلب تصدير بياناتك من كل منصة (Twitter / X وFacebook وInstagram وLinkedIn وWhatsApp وغيرها)، ونزّل ملفات ZIP، وضعها في مجلد التنزيلات.

سيبحث Ostler في ~/Downloads افتراضيًا. هل تريد مجلدًا آخر؟ اختر واحدًا أدناه. وإلا فتخطَّ الآن واستورد لاحقًا."

MSG_PROMPT_TAKEOUT_CONFIRM_TITLE="هل تريد استيراد رسائل Gmail من ملف Takeout هذا؟"
MSG_PROMPT_TAKEOUT_CONFIRM_HELP="يقرأ محتوى Gmail من ملف Takeout مباشرة. لا ترى Google أي شيء من Ostler."

MSG_PROMPT_FDA_PRESET_TITLE="من أي مصادر على Mac يجب أن يتعلم Ostler؟"
MSG_PROMPT_FDA_PRESET_HELP="ثلاثة إعدادات جاهزة، أو اختر كل مصدر بنفسك. المصادر الحساسة (التعرف على الوجوه) متوقفة افتراضيًا في كل إعداد – اختر بتأنٍّ إن أردتها."
MSG_PROMPT_FDA_PRESET_CHOICE_RECOMMENDED="موصى به. يشمل Apple Mail وجهات الاتصال والتقويم والملاحظات والرسائل والتذكيرات وسجل Safari وإشارات Safari المرجعية وأحداث الصور (التواريخ والأماكن، دون التعرف على الوجوه). تُضاف تلقائيًا سجلات WhatsApp Desktop وChrome عند تثبيت التطبيق. يستثني بيانات التعرف على الوجوه في الصور وأي أرشيفات تصدير من جهات خارجية."
MSG_PROMPT_FDA_PRESET_CHOICE_EVERYTHING="الكل. كل مصدر يستطيع Ostler قراءته على هذا Mac. يبقى التعرف على الوجوه في الصور متوقفًا حتى تفعّله بنفسك عن قصد."
MSG_PROMPT_FDA_PRESET_CHOICE_CUSTOMISE="تخصيص. اختر كل مصدر في الشاشة التالية. تبقى المصادر الحساسة متوقفة حتى تحددها."

MSG_PROMPT_FDA_SOURCE_TOGGLE_HELP="فعّل مصدر البيانات هذا أو أوقفه."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_ARTICLE_9_TITLE="قرارك (Y / N)"
# NEEDS REVIEW: Legal consent wording; lawyer should verify
MSG_PROMPT_CONSENT_ARTICLE_9_HELP="موافقة الفئة الخاصة بموجب المادة 9 (UK GDPR). مطلوبة للأساس القانوني للمعالجة."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_VOICE_EU_TITLE="هل تريد التعرف على الأصوات في المكالمات التي تلتقطها؟"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_VOICE_EU_HELP="يبقى التعرف على المتحدثين على هذا Mac. لا تتلقى Creative Machines البصمات الصوتية أبدًا."

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
MSG_PROMPT_CONSENT_ENRICHMENT_TITLE="هل تريد البحث عن حقائق عامة حول ما تحفظه؟"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_ENRICHMENT_HELP="يمكن لـ Ostler إضافة تفاصيل مرجعية عامة إلى ما يعثر عليه – كتاب أو فيلم أو ألبوم أو مكان. ولفعل ذلك يرسل اسم ذلك الشيء وحده إلى خدمات مرجعية عامة مثل Wikidata وMusicBrainz وOpenLibrary، ويخزّن الإجابة على هذا Mac.

ما الذي يغادر جهاز Mac: اسم الشيء الذي يُبحث عنه. لا شيء غيره. لا رسائلك ولا جهات اتصالك ولا ملفاتك، ولا من ذكره.

ما الذي تستطيع الخدمة في الطرف الآخر رؤيته: عنوان IP الخاص بك، وأن الطلب جاء من Ostler. يذهب الطلب مباشرة من Mac إلى تلك الخدمات – لا يمر شيء عبر خوادمنا – لذا لا توجد طريقة للسؤال دون أن يعرفوا أن أحدًا سأل.

إذا اخترت لا: لن تُجرى أي عمليات بحث، ولن تُثبَّت مهمة الإثراء في الخلفية إطلاقًا. يعمل كل شيء آخر تمامًا كما هو. وستحتوي مكتبتك فقط على ما أضفته أنت، لا على ما يضيفه فهرس عام.

يمكنك اختيار لا الآن ثم تغيير رأيك لاحقًا بإعادة تشغيل المثبّت."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_THIRD_PARTY_TITLE="أمر أخير: كيف تعمل بيانات الجهات الخارجية"
# NEEDS REVIEW: Legal agreement text; lawyer should verify
MSG_PROMPT_CONSENT_THIRD_PARTY_HELP="تبقى أي بيانات تستوردها من جهات خارجية (Google Takeout وتنزيلات Meta وملفات LinkedIn المصدَّرة وغيرها) على هذا Mac. يخزّنها Ostler في رسمك المعرفي المحلي؛ ولا يغادر شيء جهازك.

بمتابعتك، تفهم وتوافق على أنك المسؤول وحدك عن معالجة هذه البيانات والاحتفاظ بها على جهازك، تمامًا مثل رسائل البريد الإلكتروني الموجودة أصلًا على قرصك الصلب.

ملاحظة قانونية: بالنسبة إلى السجلات التي تستوردها إلى هذا Mac، أنت المتحكم في البيانات والمعالج لها بموجب قانون المملكة المتحدة والاتحاد الأوروبي (UK GDPR المادة 4(7) و4(8)). لا تتلقى Creative Machines هذه البيانات أبدًا وليست المتحكم. تندرج معالجتك للأغراض الشخصية والمنزلية ضمن المادة 2(2)(c) من UK/EU GDPR.

اقرأ المزيد على docs.ostler.ai/privacy/third-party-data."

# Spoken-capture recording-consent acknowledgement (every region). Shown
# in the Phase-2 consent batch. The HELP string is the substantive text
# GUI installer users read on the decision sheet, so it is self-contained.
# ── Personal-use-only terms (vendor/legal/consent_strings.py PERSONAL_USE_ONLY) ──
# A LICENCE TERM, not an optional consent, which is why it acknowledges rather
# than offering a decline that leaves a half-licensed install. Wording verbatim
# from the versioned ConsentString so the Doctor can flag drift.
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_TERMS_PERSONAL_USE_HEADING="الغرض من Ostler"
MSG_TERMS_PERSONAL_USE_INTRO="صُمّم Ostler لشخص واحد، على جهاز Mac الخاص به، ليفهم حياته. هذا هو التصميم كله، ولهذا لا تغادر بياناتك هذا الجهاز أبدًا."
# NEEDS REVIEW: Licence term; lawyer should verify
MSG_TERMS_PERSONAL_USE_BUSINESS="لم يُصمَّم للاستخدام التجاري. يُرجى عدم نشر Ostler لدى الموظفين، أو استخدامه في سياق عملك لالتقاط بيانات الزملاء أو العملاء أو المرضى أو الزبائن. إذا فعلت مؤسسة ذلك، تصبح المؤسسة مسؤولة عن كل من تجمع معلوماته، وOstler غير مصمم لتحمّل ذلك."
# NEEDS REVIEW: Legal licence text using 'recording' in the legal sense; lawyer should verify
MSG_TERMS_PERSONAL_USE_RECORDER="أنت من يقوم بالتسجيل. Ostler مجرد أداة. وحيثما يشترط قانونك المحلي الحصول على موافقة قبل تسجيل محادثة، فإن الحصول عليها يقع عليك، ولا يمكننا أن نعرف من هنا ما إذا كان أي تسجيل بعينه قانونيًا في مكانك."
MSG_TERMS_PERSONAL_USE_ASK_HEADING="ثلاثة أمور نرجو ألا تفعلها:"
# NEEDS REVIEW: Legal licence term; lawyer should verify
MSG_TERMS_PERSONAL_USE_ASK_1="لا تسجّل الأطفال دون موافقة أحد الوالدين أو الوصي. لا يستطيع الطفل أن يعطي هذه الموافقة بنفسه، ولا يحل تأكيدك الشخصي محل موافقتهم."
# NEEDS REVIEW: Legal licence term; lawyer should verify
MSG_TERMS_PERSONAL_USE_ASK_2="لا تسجّل في أماكن يتوقع فيها الناس خصوصية حقيقية: موعد طبي، أو اجتماع مع محامٍ، أو جلسة علاج نفسي، أو اعتراف ديني، أو حمّام أو غرفة تبديل ملابس."
# NEEDS REVIEW: Legal licence term; lawyer should verify
MSG_TERMS_PERSONAL_USE_ASK_3="لا تستخدم Ostler لتسجيل أي شخص سرًّا حيث لا يسمح القانون في مكانك بذلك."
# NEEDS REVIEW: Licence/warranty text; lawyer should verify
MSG_TERMS_PERSONAL_USE_LEGAL="Ostler مرخّص للاستخدام الشخصي غير التجاري من قبل شخص طبيعي. وCreative Machines ليست متحكمة في البيانات ولا معالجة للمعلومات التي تحتفظ بها على جهاز Mac، ولا تتلقى شيئًا منها، ولا تقدم أي ضمان بأن أي تسجيل أو التقاط بعينه قانوني في نطاقك القضائي."
MSG_PROMPT_TERMS_PERSONAL_USE_TITLE="Ostler للاستخدام الشخصي"
# NEEDS REVIEW: Licence acceptance text; lawyer should verify, and 'متابعة' must match the localised Continue button
MSG_PROMPT_TERMS_PERSONAL_USE_HELP="Ostler مرخّص لاستخدامك الشخصي على جهاز Mac الخاص بك. يُرجى عدم نشره لدى الموظفين أو استخدامه في العمل لالتقاط بيانات الزملاء أو العملاء أو المرضى. لا تسجّل الأطفال دون موافقة أحد الوالدين، ولا تسجّل في أماكن يتوقع فيها الناس خصوصية حقيقية مثل موعد عند طبيب أو محامٍ أو جلسة علاج. اضغط متابعة لقبول هذه الشروط."
MSG_INFO_TERMS_PERSONAL_USE_DECLINED="لا مشكلة. لم يتم تثبيت أي شيء."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_HEADING="تحويل المحادثات المنطوقة إلى نص"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_INTRO="باختصار: عندما تلتقط صوتًا منطوقًا لتحويله إلى نص، فإن الحصول على أي موافقة يتطلبها القانون هو مسؤوليتك أنت، وليس مسؤوليتنا. الكتابة والمراسلة النصية غير متأثرتين."
# NEEDS REVIEW: Legal/consent wording; a lawyer should check.
MSG_CONSENT_SPOKEN_CAPTURE_LAW="يمكن لـ Ostler تحويل المحادثات المنطوقة التي تلتقطها، مثل المكالمات والاجتماعات، إلى نص قابل للبحث. هذا يخص فقط الصوت الذي تختار تحويله إلى نص. تختلف القواعد المتعلقة بتسجيل كلام الأشخاص من بلد إلى آخر، ففي بعض الأماكن (ألمانيا وفرنسا مثلًا) يجب أن يوافق جميع المشاركين أولًا."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_LOCAL="إن إبقاء الصوت الملتقط على جهاز Mac الخاص بك لا يلغي هذا الواجب. فـ Ostler لا يرسله إلى أي مكان، لكنك ما زلت بحاجة إلى الموافقة حيثما يشترطها قانون بلدك."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_HEADING="ما نطلبه منك:"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_1="احصل على أي موافقة يشترطها قانون بلدك قبل التقاط محادثة منطوقة."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_2="أوضح للأشخاص الذين معك أنه يجري التقاط الصوت، مثلًا بأن تذكر ذلك في البداية أو تُبقي مؤشرًا ظاهرًا قيد التشغيل."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_ASK_3="إذا كنت في شك، فأبقِ تحويل الكلام المنطوق إلى نص متوقفًا. محادثاتك النصية تعمل في الحالتين."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_LABEL="قرارك:"
# NEEDS REVIEW: Consent acknowledgement with legal force; a lawyer should check.
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_Y="[Y] أفهم ذلك، وسأحصل على أي موافقة يشترطها قانون بلدي."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_CONSENT_SPOKEN_CAPTURE_DECISION_N="[N] ليس الآن، أبقِ تحويل الكلام المنطوق إلى نص متوقفًا. (يمكنك تشغيله لاحقًا من الإعدادات.)"
# NEEDS REVIEW: Legal note; a lawyer should check the legal force.
MSG_CONSENT_SPOKEN_CAPTURE_LEGAL="ملاحظة قانونية: قد يخضع تسجيل الكلام المنطوق لقوانين وطنية، مثل المادة 201 من قانون العقوبات الألماني (Verletzung der Vertraulichkeit des Wortes) أو المادة 226-1 من قانون العقوبات الفرنسي، وذلك بمعزل عن قانون حماية البيانات. بصفتك الشخص الذي يجري التسجيل على جهاز Mac هذا، فأنت المسؤول عن الالتزام بالقانون. لا تتلقى Creative Machines تسجيلاتك إطلاقًا وليست طرفًا فيها."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_TITLE="هل تريد تحويل المحادثات المنطوقة إلى نص؟"
# NEEDS REVIEW: Legal/consent text; a lawyer should check.
MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_HELP="باختصار: عندما تلتقط صوتًا منطوقًا لتحويله إلى نص، فإن الحصول على أي موافقة يتطلبها القانون هو مسؤوليتك. الكتابة والمراسلة النصية غير متأثرتين.

يمكن لـ Ostler تحويل المحادثات المنطوقة التي تلتقطها، مثل المكالمات والاجتماعات، إلى نص قابل للبحث. هذا يخص فقط الصوت الذي تختار تحويله إلى نص.

ما نطلبه منك:
• احصل على أي موافقة يشترطها قانون بلدك قبل التقاط الصوت.
• أوضح أنه يجري التقاط الصوت، بأن تذكر ذلك أو تُبقي مؤشرًا ظاهرًا قيد التشغيل.
• إذا كنت في شك، فأبقِ هذا الخيار متوقفًا. محادثاتك النصية تعمل في الحالتين، ويمكنك تشغيله لاحقًا من الإعدادات.

ملاحظة قانونية: قد يخضع تسجيل الكلام المنطوق لقوانين وطنية بمعزل عن قانون حماية البيانات، مثل المادة 201 من قانون العقوبات الألماني أو المادة 226-1 من قانون العقوبات الفرنسي. بصفتك الشخص الذي يجري التسجيل، فأنت المسؤول عن الالتزام بالقانون. لا تتلقى Creative Machines تسجيلاتك إطلاقًا."
MSG_INFO_SPOKEN_CAPTURE_WILL_STAY_OFF="سيبقى تحويل الكلام المنطوق إلى نص متوقفًا. يمكنك تفعيله لاحقًا من الإعدادات."

# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_TITLE="هل أنت جاهز للتثبيت؟"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_HELP="يُرجى كتابة INSTALL لتأكيد موافقتك على الشروط."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_TYPED_PLACEHOLDER="اكتب INSTALL"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_BUTTON_PRIMARY="تثبيت Ostler"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_CONSENT_INSTALL_BUTTON_CANCEL="إلغاء"
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_CONSENT_INSTALL_TYPED_MISMATCH="اكتب INSTALL كما هي تمامًا (حالة الأحرف غير مهمة) للتأكيد، أو انقر على إلغاء للرجوع."

MSG_PROMPT_TAILSCALE_CONFIRM_TITLE="ربط iPhone وApple Watch"
MSG_PROMPT_TAILSCALE_CONFIRM_HELP="يمنح Tailscale جهاز Mac هذا عنوانًا خاصًا ثابتًا يمكن لجهازي iPhone وApple Watch الوصول إليه من أي مكان، مع التشفير ودون أي كشف علني."

MSG_PROMPT_SAVE_KEYCHAIN_TITLE="هل تريد حفظ مفتاح الاسترداد في سلسلة المفاتيح؟"
MSG_PROMPT_SAVE_KEYCHAIN_HELP="يخزّن مفتاح استرداد التشفير الخاص بك في سلسلة مفاتيح macOS للحفاظ عليه."

# Hydration phase strings (CX-81 B1)
# Used by install.sh's hydrate_graph sub-phase (immediately before
# wiki_compile). Customer-facing counts come from the syncers' own
# JSON output, never from a fixed founder-instance number.
MSG_HYDRATE_TITLE="جارٍ تهيئة الرسم البياني الخاص بك"
MSG_HYDRATE_CONTACTS_STARTED="جارٍ استيراد جهات الاتصال إلى الرسم البياني"
MSG_HYDRATE_CONTACTS_DONE="تم استيراد %s من جهات الاتصال"
# %s = the cap in seconds, %s = contacts imported before the cap was hit.
# Says WHAT WAS MEASURED and what happens next, rather than blaming the step:
# a partial import is a real result and the retry is what completes it.
MSG_HYDRATE_CONTACTS_TIMED_OUT="استغرقت جهات الاتصال وقتًا أطول من %s ثانية، لذا توقفنا عن الانتظار وتابعنا. تم حتى الآن إدخال %s من جهات الاتصال، وسيُكمل Ostler الباقي في الخلفية."
# CX-92 (DMG #48g, 2026-05-29): calendar backfill window changed from 90
# days to 5 years -- customer copy updated to match the new behaviour.
MSG_HYDRATE_CALENDAR_STARTED="جارٍ تحميل سجل التقويم (خمس سنوات إلى الوراء وسنة إلى الأمام)"
MSG_HYDRATE_CALENDAR_DONE="تم استيراد %s من الأحداث"
MSG_HYDRATE_CALENDAR_HEARTBEAT="  لا يزال التقويم قيد التحميل (%s ثانية حتى الآن). يحتاج جهاز Mac الذي يحتوي على سنوات من الاجتماعات إلى بعض الوقت."
# Places ingest (2026-06-19): aggregate meeting/photo location signals into
# browsable Places for the wiki. British English, no em-dashes.
MSG_HYDRATE_PLACES_STARTED="جارٍ إنشاء أماكنك من المواقع التي تلتقي فيها"
MSG_HYDRATE_PLACES_DONE="تم إنشاء قسم الأماكن الخاص بك"
MSG_HYDRATE_PLACES_SKIPPED="لم يُعثر على إشارات موقع بعد، وستمتلئ الأماكن مع امتلاء التقويم"
# Loud, VISIBLE failure surface: the places module's own guard fired (location
# signals exist in the graph but 0 Place points were produced/written), or the
# ingester errored unexpectedly. NOT the benign "no signals yet" case.
MSG_HYDRATE_PLACES_GUARD_WARN="واجه إنشاء الأماكن مشكلة: توجد إشارات موقع لكن لم يتم إنتاج أي أماكن. قد تبقى صفحة الأماكن فارغة. راجع %s"
MSG_HYDRATE_PLACES_ERROR_WARN="لم يكتمل إنشاء الأماكن (خطأ غير متوقع). قد تكون صفحة الأماكن غير مكتملة. راجع %s"
MSG_HYDRATE_WIKI_RECOMPILE="جارٍ إنشاء الويكي الخاص بك. يكتب Ostler ملخصًا قصيرًا لكل شخص ومؤسسة وموضوع رئيسي لديك، لذا قد يستغرق ذلك مع دفتر عناوين كبير من بضع دقائق إلى نحو ساعة. يحدث ذلك مرة واحدة فقط، ويعمل بالكامل على جهاز Mac الخاص بك، ويمكنك تركه بأمان."

# CX-106 (DMG #48l, 2026-05-29): initial_hydrate step strings.
# Synchronous Qdrant-readiness gate between hydrate_* and wiki_compile
# so the customer sees real wiki content at install completion.
MSG_INITIAL_HYDRATE_QDRANT_BEFORE="جارٍ فحص فهرس البحث الخاص بك (تم اكتشاف %s من المجموعات)"
MSG_INITIAL_HYDRATE_BROWSER_RETRY="جارٍ تحميل سجل التصفح إلى فهرس البحث"
MSG_INITIAL_HYDRATE_QDRANT_READY="فهرس البحث جاهز (%s من المجموعات)"
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED="سيتم ملء فهرس البحث في الخلفية بعد اكتمال التثبيت"
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
MSG_INFO_QDRANT_CREATING_AT_PROVEN_READY="مخزن البحث يعمل الآن، وجارٍ إنشاء المجموعات التي لا تزال مفقودة: %s"
MSG_ERR_QDRANT_COLLECTIONS_UNCREATABLE="فهرس البحث غير مكتمل: تعذّر إنشاء %s مع أن مخزن البحث يعمل ويستجيب. سيواصل Ostler العمل وستعرض لوحة Doctor هذه الفجوة، لكن هذا الجزء من البحث سيبقى فارغًا إلى أن تُعالَج المشكلة."
MSG_WARN_QDRANT_COLLECTIONS_MISSING="فهرس البحث غير مكتمل: تعذّر إنشاء %s. سيواصل Ostler العمل وستعرض لوحة Doctor هذه الفجوة."
MSG_WARN_QDRANT_MEMBERSHIP_UNMEASURED="تعذّر التحقق من مجموعات البحث الموجودة (%s). هذا لا يعني أنها مفقودة."
MSG_INITIAL_HYDRATE_QDRANT_EMPTY_DEFERRED_AWAITING="سيتم ملء فهرس البحث في الخلفية بعد اكتمال التثبيت (في انتظار: %s)"
MSG_HYDRATE_DONE="الرسم البياني جاهز: %s شخصًا، %s حدثًا"
# CX-93 (DMG #48g, 2026-05-29): split the "no contacts" copy. The old
# string blamed iCloud, which was misleading on a local-AB-only Mac.
# REEXPORT covers the hydrate-time re-attempt; EMPTY_LOCAL_AND_ICLOUD
# is what surfaces when both the Phase-2 me-card export and the
# hydrate-time re-export came back empty (no iCloud + empty local AB).
MSG_HYDRATE_CONTACTS_REEXPORT="قد تكون iCloud لا تزال تزامن جهات الاتصال لديك – جارٍ التصدير مجددًا لالتقاط أي شيء وصل للتو."
MSG_HYDRATE_CONTACTS_EMPTY_LOCAL_AND_ICLOUD="لم يتم العثور على جهات اتصال في تطبيق جهات الاتصال (محلية أو في iCloud). أضف بعضها إلى جهات الاتصال ثم أعد التشغيل من الإعدادات."
MSG_HYDRATE_SKIPPED_NO_CONTACTS="لا توجد جهات اتصال في iCloud لاستيرادها. يمكنك إضافة ذلك لاحقًا من الإعدادات."
MSG_HYDRATE_SKIPPED_NO_EVENTS="لا توجد أحداث تقويم في آخر 5 سنوات. يمكنك استيراد السجل لاحقًا من الإعدادات."

# Email hydration strings (CX-81 B2 + CX-83)
# Used by install.sh's hydrate_email step, inserted inside the
# hydrate_graph sub-phase between the calendar block and the wiki
# recompile message. Counts come from pwg-email-ingest's --json
# output, never from a fixed founder-instance number.
MSG_HYDRATE_EMAIL_STARTED="جارٍ قراءة بريدك الإلكتروني لآخر 90 يومًا – تبقى رسائلك على هذا الـ Mac (يُستورد السجل الأقدم في الخلفية)"
MSG_HYDRATE_EMAIL_DONE="تم العثور على %s شخصًا في بريدك الإلكتروني الأخير"
MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT="لا يوجد بريد حديث للقراءة. يمكنك إضافة حساب بريد في Apple Mail وإعادة التشغيل لاحقًا."
MSG_HYDRATE_EMAIL_SKIPPED_FDA_PENDING="قارئ البريد الإلكتروني غير جاهز بعد. يمكنك إضافة حساب بريد في Apple Mail وإعادة التشغيل لاحقًا."
MSG_HYDRATE_EMAIL_BACKGROUND_CONTINUES="لا يزال البريد الإلكتروني قيد التحميل في الخلفية. يمتلئ الويكي تدريجيًا ويُظهر لك مدى تقدمه."
MSG_HYDRATE_EMAIL_HEARTBEAT="  لا تزال قراءة بريدك الإلكتروني جارية (%s ث حتى الآن). قد يستغرق ذلك بعض الوقت على Mac يحتوي على سجل يمتد لسنوات."

# Three-state data-source UX strings (CX-100, CX-101)
# Per launch/DESIGN_three_state_data_source_ux_2026-05-29.md.
# Each Apple-app-backed source has three states: not configured at all,
# configured but the local store has not populated yet, and configured
# + populated. The installer detects which state the customer is in
# and surfaces the right copy.

# State 2 prompts -- "open the app and we will wait" -- per source.
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_TITLE="هل تريد فتح Apple Mail ليبدأ المزامنة؟"
MSG_PROMPT_OPEN_MAIL_TO_POPULATE_HELP="لديك %s من حسابات البريد المُعدّة، لكن Apple Mail لم يجلب أي رسائل بعد. يمكننا فتح Mail.app الآن والانتظار أثناء المزامنة."
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_TITLE="هل تريد فتح التقويم ليبدأ المزامنة؟"
MSG_PROMPT_OPEN_CALENDAR_TO_POPULATE_HELP="لديك %s من حسابات التقويم المُعدّة، لكن Calendar.app لا يحتوي على أي أحداث مخزّنة بعد. يمكننا فتح التقويم الآن والانتظار أثناء المزامنة من iCloud."
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_TITLE="هل تريد فتح جهات الاتصال ليبدأ المزامنة؟"
MSG_PROMPT_OPEN_CONTACTS_TO_POPULATE_HELP="لديك %s من حسابات جهات الاتصال المُعدّة، لكن Contacts.app لا يحتوي على أي إدخالات مخزّنة بعد. يمكننا فتح جهات الاتصال الآن والانتظار أثناء المزامنة من iCloud."

# Wait + populate poll-loop strings
MSG_INFO_WAITING_FOR_APP_TO_POPULATE="في انتظار بدء مزامنة %s (حتى %s ثانية)."
MSG_INFO_WAITING_FOR_APP_HEARTBEAT="لا يزال الانتظار جاريًا لمزامنة %s (انقضت %s ث، وتبقّى %s ث). قد تستغرق المزامنة الأولى في iCloud بضع دقائق بعد تسجيل دخول جديد."
MSG_OK_APP_HAS_POPULATED="قام %s بملء مخزنه المحلي. جارٍ المتابعة."
MSG_INFO_APP_POPULATE_TIMEOUT_CONTINUING="لم نرصد مزامنة %s خلال مهلة الانتظار. جارٍ المتابعة، ويمكنك إعادة تشغيل الاستيراد من الإعدادات لاحقًا."

# Three-state-aware copy for the three sources. These replace the
# old binary "no data" copy that conflated states 1 and 2.
MSG_INFO_MAIL_CONFIGURED_BUT_NOT_FETCHED="حسابات Apple Mail الظاهرة: %s. افتح Mail.app مرة واحدة ليبدأ جلب الرسائل."
MSG_INFO_CALENDAR_CONFIGURED_BUT_NOT_FETCHED="حسابات التقويم الظاهرة: %s. افتح Calendar.app مرة واحدة ليزامن أحداثك."
MSG_INFO_CONTACTS_CONFIGURED_BUT_NOT_FETCHED="حسابات جهات الاتصال الظاهرة: %s. افتح Contacts.app مرة واحدة ليزامن دفتر عناوينك."

# Account-detection denial / sync-pending split for hydrate copy
MSG_HYDRATE_CONTACTS_DENIED="تعذّرت قراءة جهات الاتصال. يقرؤها Ostler عبر «الوصول الكامل إلى القرص»، فامنحه هذا الإذن في إعدادات النظام > الخصوصية والأمن > الوصول الكامل إلى القرص، ثم أعد تشغيل الاستيراد من الإعدادات. سنواصل إعادة المحاولة في الخلفية."
MSG_HYDRATE_CONTACTS_PENDING="لم يتم تزامن تطبيق جهات الاتصال بعد. افتح جهات الاتصال مرة واحدة وانتظر اكتمال المزامنة، ثم أعد تشغيل الاستيراد من الإعدادات."
MSG_HYDRATE_CONTACTS_READ_FAILED="جهات اتصالك موجودة على هذا الـ Mac لكن Ostler استورد 0 منها، وهذا غير متوقع. ستُعاد محاولة الاستيراد تلقائيًا في الخلفية. إذا استمر ذلك، فأعد تشغيل الاستيراد من الإعدادات أو راجع سجل التثبيت."
MSG_HYDRATE_CONTACTS_RESYNC_SCHEDULED="سيواصل Ostler الفحص في الخلفية ويستورد جهات اتصالك تلقائيًا بمجرد أن تنتهي iCloud من المزامنة."
MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="تم استيراد %s من جهات الاتصال التي لها أرقام هاتف ولكن تكاد تخلو من عناوين البريد الإلكتروني (%s هاتف مقابل %s بريد إلكتروني). يعني هذا عادةً أن قارئ جهات الاتصال أسقط عناوين البريد. لا تزال جهات اتصالك قابلة للاستخدام؛ راجع %s وأعد تشغيل الاستيراد من الإعدادات بعد الحل."
MSG_HYDRATE_CONTACTS_RESYNC_REBUILDING_WIKI="تم استيراد جهات اتصال جديدة، وجارٍ إعادة بناء الويكي في الخلفية."
MSG_HYDRATE_CALENDAR_PENDING="لم يزامن تطبيق التقويم الأحداث بعد. افتح التقويم مرة واحدة وانتظر اكتمال المزامنة، ثم أعد تشغيل الاستيراد من الإعدادات."
MSG_HYDRATE_CALENDAR_EXTRACTOR_FAILED="تعذّرت قراءة التقويم هذه المرة (أبلغ المستخرِج عن خطأ، وليس عن تقويم فارغ). لم تتأثر بقية بياناتك؛ راجع %s ثم أعد تشغيل الاستيراد من الإعدادات."

# WhatsApp hydration strings (CX-85)
# Used by install.sh's hydrate_whatsapp step, inserted inside the
# hydrate_graph sub-phase between the email block and the wiki
# recompile message. Counts come from pwg-whatsapp-history's --json
# output (people_added). Three-tier model: T1 DM + T2 intimate +
# T2 active are ingested; T3 large + passive is skipped invisibly.
MSG_HYDRATE_WHATSAPP_STARTED="جارٍ قراءة سجل WhatsApp – تبقى رسائلك على هذا الـ Mac"
MSG_HYDRATE_WHATSAPP_DONE="تم العثور على %s شخصًا في محادثات WhatsApp"
MSG_HYDRATE_WHATSAPP_GRAPH_WRITE_FAILED="تمت قراءة محادثات WhatsApp لكن لم تُكتب في مخطط الأشخاص الخاص بك (رمز الخروج %s). سيعيد Ostler المحاولة. التفاصيل: %s"
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_CHATS="لا توجد محادثات WhatsApp لقراءتها. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_WHATSAPP_SKIPPED_NO_APP="WhatsApp Desktop غير مثبّت. ثبّته من Mac App Store ثم أعد التشغيل من الإعدادات."
MSG_HYDRATE_WHATSAPP_SKIPPED_FDA_PENDING="قارئ WhatsApp ليس جاهزًا بعد. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_WHATSAPP_BACKGROUND_CONTINUES="لا يزال WhatsApp قيد التحميل في الخلفية. تمتلئ الويكي تدريجيًا وتعرض لك مدى التقدم."

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
MSG_HYDRATE_WHATSAPP_ALREADY_IMPORTED="جهات اتصال WhatsApp موجودة بالفعل في مخطط الأشخاص الخاص بك (%s معرّفًا). لا حاجة لإعادة القراءة."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_STORE_EMPTY="سبقت قراءة جهات اتصال WhatsApp، لكن مخطط الأشخاص الخاص بك لم يعد يحتويها. تجري قراءتها مرة أخرى."
MSG_WARN_HYDRATE_WHATSAPP_REIMPORT_UNVERIFIED="تعذر التحقق مما إذا كانت جهات اتصال WhatsApp لا تزال في مخطط الأشخاص الخاص بك. تجري قراءتها مرة أخرى بدلًا من افتراض وجودها."

# AI Conversations hydration strings (#553 / #613)
# Used by install.sh's AI Conversations leg (after the first-month-free
# activation -- the CM052 subscription gate must be open before the
# drain). GATED OFF for v1.0.x: OSTLER_AI_CONVERSATIONS_ENABLED
# defaults to false and none of these strings are shown; the disabled
# path is deliberately silent. Counts come from pwg-ai-convo's --json
# output (written) -- counts only, no transcript text or titles.
MSG_HYDRATE_AICONV_STARTED="جارٍ قراءة سجل محادثات الذكاء الاصطناعي – تبقى محادثاتك على هذا الـ Mac"
MSG_HYDRATE_AICONV_DONE="تم حفظ %s من محادثات الذكاء الاصطناعي في الويكي الخاصة بك"
MSG_HYDRATE_AICONV_SKIPPED_NOT_READY="قارئ محادثات الذكاء الاصطناعي ليس جاهزًا بعد. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_AICONV_SKIPPED_NO_DATA="لا يوجد سجل محادثات ذكاء اصطناعي لقراءته. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_AICONV_BACKGROUND_CONTINUES="لا تزال محادثات الذكاء الاصطناعي قيد التحميل في الخلفية. تمتلئ الويكي تدريجيًا وتعرض لك مدى التقدم."
MSG_HYDRATE_AICONV_HEARTBEAT="  لا تزال قراءة سجل محادثات الذكاء الاصطناعي جارية (%s ثانية حتى الآن). قد يستغرق السجل الكبير عدة دقائق."


# Browser history hydration strings (CX-86 Gap A + Gap C)
# Used by install.sh's hydrate_browsing step. The progress call
# is a SEPARATE STEP_BEGIN (id = hydrate_browsing) that sits
# between hydrate_graph and wiki_compile. Counts come from
# ingest_browser_history's --json output (sent, skipped_sensitive).
# Privacy: no URLs / titles / domains in any string here -- the
# customer sees counts and the gateway blocklist's "skipped" tally.
MSG_HYDRATE_BROWSING_STARTED="جارٍ استيراد سجل التصفح – تبقى زياراتك على هذا الـ Mac"
MSG_HYDRATE_BROWSING_DONE="تم استيراد %s من صفحات سجل التصفح"
MSG_HYDRATE_BROWSING_SKIPPED_SENSITIVE="تم تخطي %s من الصفحات المصنّفة حساسة (مصرفية، طبية، وغيرها)"
MSG_HYDRATE_BROWSING_SKIPPED_NO_DATA="لا يوجد سجل تصفح لاستيراده. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_BROWSING_SKIPPED_FDA_PENDING="قارئ سجل التصفح ليس جاهزًا بعد. يمكنك إعادة التشغيل لاحقًا من الإعدادات."

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
MSG_HYDRATE_BROWSING_ALREADY_IMPORTED="سجل التصفح مستورد بالفعل (%s صفحة). لا حاجة لإعادة الاستيراد."
MSG_HYDRATE_BROWSING_SKIPPED_NO_EXPORT="لم يُعثر على سجل تصفح مُصدَّر لاستيراده. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_STORE_EMPTY="سبق استيراد سجل التصفح، لكن فهرس البحث الخاص بك لم يعد يحتويه. يجري استيراده مرة أخرى."
MSG_WARN_HYDRATE_BROWSING_REIMPORT_UNVERIFIED="تعذر التحقق مما إذا كان سجل التصفح لا يزال في فهرس البحث الخاص بك. يجري استيراده مرة أخرى بدلًا من افتراض وجوده."
MSG_WARN_HYDRATE_BROWSING_NOTHING_STORED="لم يصل سجل التصفح إلى فهرس البحث الخاص بك، لذا ستكون صفحة التصفح فارغة. أعد التشغيل من الإعدادات أو افتح Doctor."
MSG_HYDRATE_BROWSING_BACKGROUND_CONTINUES="لا يزال سجل التصفح قيد التحميل في الخلفية. تمتلئ الويكي تدريجيًا وتعرض لك مدى التقدم."

# Email-preferences hydration strings (v1.0.3)
# Used by install.sh's hydrate_email_preferences step. It ingests a
# pre-extracted ParsedPreference JSONL file (CM021 email intelligence
# output) into the preferences collection via the vendored CM019 ingest
# CLI, so a wipe and reinstall regenerates it from the source file.
# Counts come from the ingest CLI's "Preferences created" tally; no
# brand, person, or subject names cross the install.sh process boundary.
# The file is opt-in via OSTLER_EMAIL_PREFERENCES_FILE or
# OSTLER_SOCIAL_ARCHIVES_DIR, so customers without it skip cleanly.
MSG_HYDRATE_EMAIL_PREFERENCES_STARTED="جارٍ تحميل تفضيلات بريدك الإلكتروني. يبقى هذا على هذا الـ Mac وقد يستغرق بضع دقائق."
MSG_HYDRATE_EMAIL_PREFERENCES_DONE="تم تحميل %s من التفضيلات من سجل بريدك الإلكتروني"
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE="لم يتم إعداد ملف تفضيلات البريد الإلكتروني. لا شيء للتحميل."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_NO_FILE_AT="لم يُعثر على ملف تفضيلات البريد الإلكتروني في %s. لا شيء للتحميل."
MSG_HYDRATE_EMAIL_PREFERENCES_SKIPPED_PIPELINE_PENDING="مسار معالجة التفضيلات ليس جاهزًا بعد. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_EMAIL_PREFERENCES_BACKGROUND_CONTINUES="لا تزال تفضيلات البريد الإلكتروني قيد التحميل في الخلفية. تمتلئ الويكي تدريجيًا وتعرض لك مدى التقدم."
MSG_HYDRATE_EMAIL_PREFERENCES_HEARTBEAT="  لا يزال تحميل تفضيلات بريدك الإلكتروني جاريًا (%s ثانية حتى الآن). قد يستغرق السجل الكبير بضع دقائق."

MSG_HYDRATE_EMAIL_PREFERENCES_ALREADY_IMPORTED="تفضيلات بريدك الإلكتروني محمّلة بالفعل (%s عنصرًا). لا حاجة لإعادة التحميل."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_STORE_EMPTY="سبق تحميل تفضيلات بريدك الإلكتروني، لكن فهرس البحث الخاص بك لم يعد يحتويها. يجري تحميلها مرة أخرى."
MSG_WARN_HYDRATE_EMAIL_PREFERENCES_REIMPORT_UNVERIFIED="تعذر التحقق مما إذا كانت تفضيلات بريدك الإلكتروني لا تزال في فهرس البحث الخاص بك. يجري تحميلها مرة أخرى بدلًا من افتراض وجودها."

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
MSG_HYDRATE_PREFERENCES_DONE="تم استيراد %s من التفضيلات"
MSG_HYDRATE_PREFERENCES_ENRICHED="تم إثراء %s منها ببيانات مرجعية عامة"

# Category-coverage guard (CX: silently-blank Food / Music pages). Warned
# when preferences landed but none carry a headline category, or when a
# large share carry no category at all -- so the operator sees it at
# install time rather than discovering empty wiki pages later. Counts only.
MSG_WARN_PREFS_NO_HEADLINE_CATEGORIES="تم استيراد %s من التفضيلات، لكن لم يندرج أي منها ضمن الطعام أو الموسيقى أو المهنة. ستكون صفحتا الطعام والموسيقى في الويكي فارغتين."
MSG_WARN_PREFS_HEADLINE_HINT="يعني هذا عادةً أنه لم يكن هناك تصدير للموسيقى أو الطعام (Spotify أو Apple Music أو Uber Eats أو Google Takeout)، أو أن البيانات لم تُصنَّف. أضف هذه الملفات المُصدَّرة وأعد التشغيل من الإعدادات، ثم أعد بناء الويكي."
MSG_WARN_PREFS_UNCATEGORISED="%s من أصل %s من التفضيلات (%s%%) بلا تصنيف ولن تظهر في أي صفحة موضوع. تحقق من تنسيق ملف التصدير المصدر."

# Preference enrichment pipeline setup (CM019, own venv at
# ~/.ostler/services/cm019). Idempotent + non-fatal; see install.sh 3.11b.
MSG_CM019_SETUP_STARTED="جارٍ إعداد إثراء التفضيلات"
MSG_CM019_SETUP_DONE="إثراء التفضيلات جاهز"
MSG_CM019_SETUP_FAILED="لم يكتمل إعداد إثراء التفضيلات. ستمتلئ صفحات تفضيلاتك بعد إصلاحه، ولا يتأثر باقي Ostler."
MSG_CM019_SETUP_SKIPPED="مسار إثراء التفضيلات غير مضمّن، وسيتم تخطيه الآن."

# CX-84: iMessage hydration. Fires as a separate progress emission
# between hydrate_browsing and wiki_compile. Counts come from
# ingest_imessage's return dict (people_created + people_enriched).
# Privacy: no phone numbers / handles / message text in any string
# here -- the customer sees people-count totals only.
MSG_HYDRATE_IMESSAGE_STARTED="جارٍ قراءة سجل iMessage الخاص بك – تبقى رسائلك على هذا الـ Mac"
MSG_HYDRATE_IMESSAGE_DONE="تم العثور على %s شخصًا في سجل iMessage الخاص بك"
MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA="لا يوجد سجل iMessage لقراءته. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_IMESSAGE_SKIPPED_FDA_PENDING="قارئ iMessage ليس جاهزًا بعد. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES="لا يزال iMessage قيد التحميل في الخلفية. تمتلئ الويكي لديك تدريجيًا وتعرض لك مدى التقدم."
MSG_HYDRATE_IMESSAGE_HEARTBEAT="  لا تزال قراءة سجل iMessage الخاص بك جارية (%s ثانية حتى الآن). قد يستغرق سجل الرسائل الكبير عدة دقائق."

MSG_HYDRATE_IMESSAGE_ALREADY_IMPORTED="جهات اتصال iMessage الخاصة بك موجودة بالفعل في مخطط الأشخاص لديك (%s معرّفًا). لا حاجة لإعادة القراءة."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_STORE_EMPTY="سبقت قراءة جهات اتصال iMessage الخاصة بك، لكن مخطط الأشخاص لديك لم يعد يحتويها. تجري قراءتها مرة أخرى."
MSG_WARN_HYDRATE_IMESSAGE_REIMPORT_UNVERIFIED="تعذّر التحقق مما إذا كانت جهات اتصال iMessage الخاصة بك لا تزال في مخطط الأشخاص لديك. تجري قراءتها مرة أخرى بدلًا من افتراض وجودها."

# Apple Notes knowledge hydration (CM024 apple_notes adapter). Notes are
# converted to markdown + embedded locally; only note-count totals are
# shown to the customer -- no note titles or bodies leave the process.
# Copy is dash-clean (plain hyphens only) per the hydrate-phase convention.
MSG_HYDRATE_APPLE_NOTES_STARTED="جارٍ قراءة ملاحظات Apple الخاصة بك - تبقى على هذا الـ Mac"
MSG_HYDRATE_APPLE_NOTES_DONE="تمت إضافة %s ملاحظة إلى قاعدة معرفتك"
MSG_HYDRATE_APPLE_NOTES_SKIPPED_NO_DATA="لا توجد ملاحظات Apple لقراءتها. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_ALREADY_EMBEDDED="ملاحظات Apple الخاصة بك موجودة بالفعل في قاعدة معرفتك. يتم التخطي."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_OPTED_OUT="ملاحظات Apple معطّلة في البحث في المعرفة. يمكنك تفعيلها من الإعدادات."
MSG_HYDRATE_APPLE_NOTES_SKIPPED_PIPELINE_PENDING="مستورد المعرفة ليس جاهزًا بعد. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_APPLE_NOTES_BACKGROUND_CONTINUES="لا تزال ملاحظات Apple قيد التحميل في الخلفية. تمتلئ قاعدة معرفتك تدريجيًا وتعرض لك مدى التقدم."
MSG_HYDRATE_APPLE_NOTES_HEARTBEAT="  لا تزال قراءة ملاحظات Apple الخاصة بك جارية (%s ثانية حتى الآن). قد تستغرق مكتبة الملاحظات الكبيرة بضع دقائق."

MSG_HYDRATE_APPLE_NOTES_ALREADY_IMPORTED="ملاحظات Apple الخاصة بك موجودة بالفعل في قاعدة معرفتك (%s إدخالًا). لا حاجة لإعادة القراءة."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_STORE_EMPTY="سبقت إضافة ملاحظات Apple الخاصة بك، لكن قاعدة معرفتك لم تعد تحتويها. تجري إضافتها مرة أخرى."
MSG_WARN_HYDRATE_APPLE_NOTES_REIMPORT_UNVERIFIED="تعذّر التحقق مما إذا كانت ملاحظات Apple الخاصة بك لا تزال في قاعدة معرفتك. تجري إضافتها مرة أخرى بدلًا من افتراض وجودها."

# Reminders knowledge hydration (CM024 reminders adapter, same pattern as
# Apple Notes above). Reminders are converted to markdown + embedded
# locally; only reminder-count totals are shown to the customer -- no
# reminder titles or notes leave the process.
MSG_HYDRATE_REMINDERS_STARTED="جارٍ قراءة التذكيرات الخاصة بك - تبقى على هذا الـ Mac"
MSG_HYDRATE_REMINDERS_DONE="تمت إضافة %s تذكيرًا إلى قاعدة معرفتك"
MSG_HYDRATE_REMINDERS_SKIPPED_NO_DATA="لا توجد تذكيرات لقراءتها. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
# THREE CAUSES NEEDED THREE STRINGS (#775). Until v1.0.101 the line above was
# emitted for all three, so a customer whose 2369 reminders were skipped by a
# stale sentinel was told there were none to read. A message that cannot
# distinguish "already done" from "none exist" is not a message, it is a
# guess the reader has to make.
MSG_HYDRATE_REMINDERS_SKIPPED_ALREADY_EMBEDDED="التذكيرات الخاصة بك موجودة بالفعل في قاعدة معرفتك. يتم التخطي."
MSG_HYDRATE_REMINDERS_SKIPPED_OPTED_OUT="التذكيرات معطّلة في البحث في المعرفة. يمكنك تفعيلها من الإعدادات."
MSG_HYDRATE_REMINDERS_SKIPPED_PIPELINE_PENDING="مستورد المعرفة ليس جاهزًا بعد. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_REMINDERS_BACKGROUND_CONTINUES="لا تزال التذكيرات قيد التحميل في الخلفية. تمتلئ قاعدة معرفتك تدريجيًا وتعرض لك مدى التقدم."
MSG_HYDRATE_REMINDERS_HEARTBEAT="  لا تزال قراءة التذكيرات الخاصة بك جارية (%s ثانية حتى الآن). قد تستغرق قائمة التذكيرات الكبيرة بضع دقائق."

MSG_HYDRATE_REMINDERS_ALREADY_IMPORTED="التذكيرات الخاصة بك موجودة بالفعل في قاعدة معرفتك (%s إدخالًا). لا حاجة لإعادة القراءة."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_STORE_EMPTY="سبقت إضافة التذكيرات الخاصة بك، لكن قاعدة معرفتك لم تعد تحتويها. تجري إضافتها مرة أخرى."
MSG_WARN_HYDRATE_REMINDERS_REIMPORT_UNVERIFIED="تعذّر التحقق مما إذا كانت التذكيرات الخاصة بك لا تزال في قاعدة معرفتك. تجري إضافتها مرة أخرى بدلًا من افتراض وجودها."

# People search index (#600)
MSG_HYDRATE_PEOPLE_STARTED="جارٍ فهرسة الأشخاص لديك للبحث"
MSG_HYDRATE_PEOPLE_DONE="تمت فهرسة %s شخصًا للبحث"
MSG_HYDRATE_PEOPLE_PARTIAL="تمت فهرسة %s من %s شخصًا للبحث حتى الآن. لم يكن بالإمكان البحث عن الباقين بعد، وسيعيد Ostler المحاولة تلقائيًا."
MSG_HYDRATE_PEOPLE_FAILED="تعذّرت فهرسة الأشخاص لديك للبحث هذه المرة (لم يستجب مخزن المخطط). سيعيد Ostler المحاولة تلقائيًا. التفاصيل: %s"
MSG_HYDRATE_PEOPLE_SKIPPED_NO_DATA="لا يوجد أشخاص لفهرستهم بعد. يمكنك إعادة التشغيل لاحقًا من الإعدادات."
MSG_HYDRATE_PEOPLE_SKIPPED_FDA_PENDING="فهرسة الأشخاص ليست جاهزة بعد. يمكنك إعادة تشغيلها لاحقًا من الإعدادات."
MSG_HYDRATE_PEOPLE_BACKGROUND_CONTINUES="لا تزال فهرسة الأشخاص جارية في الخلفية. تكتمل نتائج البحث تدريجيًا، ويعرض لك الويكي مدى التقدم."

MSG_HYDRATE_PEOPLE_ALREADY_IMPORTED="تمت فهرسة الأشخاص للبحث بالفعل (%s شخصًا). لا حاجة لإعادة الفهرسة."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_STORE_EMPTY="سبقت فهرسة الأشخاص، لكن فهرس البحث لم يعد يحتويهم. تتم فهرستهم مرة أخرى."
MSG_WARN_HYDRATE_PEOPLE_REIMPORT_UNVERIFIED="تعذّر التحقق مما إذا كان الأشخاص لا يزالون في فهرس البحث. تتم فهرستهم مرة أخرى بدل افتراض وجودهم."

# CX-47 (DMG #30, 2026-05-24): elevated pre-warn banner for the three
# folder-access TCC prompts triggered by the GDPR-export scan.
MSG_PROMPT_GDPR_SCAN_INCOMING_TITLE="ثلاث رسائل طلب إذن للوصول إلى المجلدات ستظهر قريبًا"

# CX-54 (DMG #30, 2026-05-24): in-window hint surfaced after macOS's
# Command Line Tools install dialog steals focus. Customers consistently
# miss that the questions phase continues in the background.
MSG_INFO_CLT_KEEP_ANSWERING_BACKGROUND="ظهر مربع حوار أدوات سطر الأوامر أمام هذه النافذة – انقر على \"تثبيت\" فيه، ثم عد إلى هنا (أو انتظر بضع ثوانٍ وسنعيد هذه النافذة إلى الأمام). تُنزَّل الأدوات في الخلفية بينما تواصل الإجابة عن الأسئلة أدناه؛ لا شيء هنا متوقف."

# CX-55 (DMG #30, 2026-05-24): pre-warn for the iMessage Automation
# permission prompt that macOS shows when we probe Messages.app for
# the install-time TCC posture snapshot.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_TITLE="إذن مطلوب: أتمتة iMessage"
# NEEDS REVIEW: Fixed ungrammatical "الإعدادات النظام" and used Apple Arabic terms; a human should verify the exact Arabic macOS popup wording.
MSG_PROMPT_IMESSAGE_AUTOMATION_INCOMING_HELP="سيطلب Ostler الآن من macOS إذنًا للتواصل مع تطبيق الرسائل. سيعرض macOS نافذة منبثقة تفيد بأن \"OstlerInstaller\" يريد الوصول للتحكم في \"الرسائل\" – انقر على \"السماح\" ليتمكن المساعد من إرسال رسائل iMessage واستقبالها نيابةً عنك. من دون هذا الإذن لن تغادر رسائل iMessage الجهاز دون أي تنبيه. هذا الإذن يُمنح مرة واحدة، ويمكنك تغييره لاحقًا في إعدادات النظام > الخصوصية والأمن > الأتمتة."

# CX-53 (DMG ship, 2026-05-24): recovery-key reveal sheet shown in the
# main GUI window after install completes. The TTY path already echoes
# the key in YELLOW BOLD at install.sh:7580; the GUI path needs the
# same surface so customers don't end up locked out if their Keychain
# ever wobbles. install.sh emits a structured RECOVERY_KEY marker that
# the Swift coordinator parses into a dedicated @Published property
# (not into logLines, where it would leak into the Log drawer). The
# RecoveryKeyView renders the value in monospace with Copy / Save PDF /
# Print buttons + a confirm checkbox + Continue.
MSG_INFO_RECOVERY_KEY_REVEALED_TITLE="مفتاح الاسترداد"
MSG_INFO_RECOVERY_KEY_REVEALED_BODY="دوّنه أو اطبعه الآن. إنه السبيل الوحيد للدخول إذا فقدت عبارة المرور وتعذّر الوصول إلى سلسلة المفاتيح معًا. لا يستطيع Ostler استعادته لك – فالمفتاح لا يغادر هذا الـ Mac ولا يُخزَّن على أي خادم."
MSG_INFO_RECOVERY_KEY_REVEALED_CONFIRM="حفظته في مكان آمن"
MSG_INFO_RECOVERY_KEY_REVEALED_COPY="نسخ إلى الحافظة"
MSG_INFO_RECOVERY_KEY_REVEALED_SAVE_PDF="حفظ بصيغة PDF..."
MSG_INFO_RECOVERY_KEY_REVEALED_PRINT="طباعة..."
MSG_INFO_RECOVERY_KEY_REVEALED_CONTINUE="متابعة"
MSG_INFO_RECOVERY_KEY_PDF_DEFAULT_FILENAME="Ostler Recovery Key.pdf"
MSG_INFO_RECOVERY_KEY_PRINT_JOB_TITLE="مفتاح استرداد Ostler"
MSG_OK_RECOVERY_KEY_COPIED_TO_CLIPBOARD="تم نسخ مفتاح الاسترداد إلى الحافظة"
MSG_OK_RECOVERY_KEY_SAVED_AS_PDF="تم حفظ مفتاح الاسترداد في %s"

# CX-56 (DMG ship, 2026-05-24): iOS Companion pairing QR shown on the
# install-complete screen. The Hub gateway exposes a §3.3 pair-code
# envelope at POST http://localhost:8000/admin/paircode (no auth
# needed on localhost). The GUI fetches the envelope, renders it as
# a 256x256 QR with an oxblood border, and offers a Refresh button.
# CM031 iOS app scans the QR + decodes the envelope.
MSG_INFO_PAIR_IPHONE_TITLE="اقتران iPhone"
MSG_INFO_PAIR_IPHONE_HELP="افتح تطبيق Ostler على iPhone وامسح رمز QR هذا لربطه بهذا الـ Hub. يمكنك أيضًا الاقتران لاحقًا من قائمة الإعدادات في الـ Hub."
MSG_INFO_PAIR_IPHONE_FETCHING="جارٍ إنشاء رمز الاقتران..."
MSG_INFO_PAIR_REFRESH="تحديث الرمز"
MSG_ERR_PAIR_FETCH_FAILED="تعذّر الوصول إلى بوابة Ostler حتى الآن. قد تكون لا تزال قيد التشغيل – انقر على تحديث للمحاولة مرة أخرى."

# ── Deep-dive audit fixes (CM051_INSTALLER_DEEP_DIVE_FINDINGS_2026-05-22) ──

# F1 - assistant-agent bundle missing
MSG_WARN_ASSISTANT_AGENT_NOT_BUNDLED_LAUNCHAGENT_SKIPPED="assistant-agent غير مضمَّن مع المثبّت. لن يتم تحميل الملخصات اليومية وLaunchAgent الخاص بإبقاء WhatsApp متصلًا."

# F2 - wiki-recompile bundle missing (replaces silent info-log fall-through)
MSG_WARN_WIKI_RECOMPILE_SCRIPTS_NOT_BUNDLED="نصوص إعادة تجميع الويكي غير مضمَّنة مع المثبّت. لن يتم تحديث الويكي تلقائيًا."

# F3 - legal package missing
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_WARN_LEGAL_PACKAGE_NOT_BUNDLED_CONSENT_DEGRADED="الحزمة legal غير مضمَّنة مع المثبّت. ستُصدر بوابات الموافقة الخاصة بالمادة 9 وWhatsApp والصوت الخطأ ModuleNotFoundError إلى أن تتم إعادة التثبيت."

# F4 - gws (Google Workspace CLI) install
MSG_OK_GWS_INSTALLED_AT_VERSION_DEST="تم تثبيت Google Workspace CLI الإصدار %s في %s"
MSG_OK_GWS_ALREADY_INSTALLED_AT_VERSION="Google Workspace CLI الإصدار %s مثبّت بالفعل، وسيُترك كما هو"
MSG_WARN_GWS_UNSUPPORTED_ARCHITECTURE_GMAIL_DEGRADED="بنية المعالج غير مدعومة لـ Google Workspace CLI؛ ميزات Gmail وGoogle Calendar محدودة."
MSG_WARN_CURL_NOT_AVAILABLE_GWS_INSTALL_SKIPPED="curl غير متاح؛ تم تخطي تثبيت Google Workspace CLI. ميزات Gmail وGoogle Calendar محدودة."
MSG_WARN_GWS_DOWNLOAD_FAILED_URL="تعذّر تنزيل Google Workspace CLI من %s"
MSG_WARN_GWS_SHA256_MISMATCH_EXPECTED_GOT="عدم تطابق SHA256 في Google Workspace CLI (المتوقع %s، الفعلي %s). يتم إلغاء تثبيت هذا الملف التنفيذي."
MSG_WARN_GWS_ARCHIVE_EXTRACT_FAILED="تعذّر استخراج أرشيف Google Workspace CLI."
MSG_WARN_GWS_INSTALLED_BUT_VERSION_PROBE_FAILED="تم تثبيت Google Workspace CLI في %s لكن فحص --version فشل."

# F5 - ical-query.sh wrapper
MSG_OK_ICAL_QUERY_WRAPPER_INSTALLED_AT="تم تثبيت جسر تقويم iCloud / CalDAV في %s"
MSG_WARN_ICAL_QUERY_WRAPPER_NOT_EXECUTABLE_AT="جسر تقويم iCloud / CalDAV في %s غير قابل للتنفيذ. لن يعرض التقويم أي أحداث."

# F9 - deferred-register-device script missing
MSG_WARN_DEFERRED_REGISTER_SCRIPT_NOT_BUNDLED_RETRY_DISABLED="scripts/deferred-register-device.sh غير مضمَّن مع المثبّت. إعادة محاولة تسجيل الجهاز عند الاتصال التالي بالشبكة معطّلة."

MSG_WARN_EMBED_DIMS_UNREADABLE="تعذّرت قراءة عرض التضمين من فحص الحالة. الذاكرة مهيأة على 768 بُعدًا؛ إذا بدا الاستدعاء غريبًا، فتحقق من نموذج التضمين."
MSG_FAIL_EMBED_DIMS="أعاد نموذج التضمين متجهات بأبعاد %s، بينما تم إعداد Ostler لأبعاد %s. ستخزّن الذاكرة متجهات لا يمكن مطابقتها أبدًا. تحقق من نموذج التضمين ثم أعد التشغيل."

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
MSG_PROGRESS_REBOOT_SELFHEAL="جارٍ إعداد الإصلاح الذاتي عند إعادة التشغيل"
MSG_INFO_AUTOLOGIN_EXPLAIN="Ostler هو Hub يعمل دائمًا، لذا يحتاج بعد انقطاع الكهرباء أو إعادة التشغيل إلى العودة للعمل دون وجود أحد أمام لوحة المفاتيح. ولا ينجح ذلك إلا إذا سجّل هذا الـ Mac الدخول بنفسه، ولا يستطيع macOS ذلك إلا إذا كانت كلمة مرور تسجيل الدخول الخاصة بـ %s محفوظة على هذا الـ Mac.

حفظها يُضعف أمان هذا الـ Mac. كلمة المرور تُشوَّش ولا تُشفَّر، لذا يمكن لأي شخص يستطيع استخدام حساب مسؤول هنا، أو يستطيع نزع القرص وقراءته في مكان آخر، أن يستعيد كلمة مرورك. سترى بالضبط مكان حفظها قبل أن تكتب أي شيء.

إذا اخترت لا، فلن يُحفظ شيء ولن يتغير أي شيء آخر. بعد انقطاع الكهرباء تسجّل الدخول كالمعتاد، وتبدأ خدمات Ostler مع جلستك. يمكنك تغيير ذلك لاحقًا في إعدادات النظام > المستخدمون والمجموعات > تسجيل الدخول التلقائي."
# NEEDS REVIEW: legal/consent wording: needs a qualified human check
MSG_PROMPT_AUTOLOGIN_CONSENT="هل تريد حفظ كلمة مرور تسجيل الدخول على هذا الـ Mac ليتمكن من تسجيل الدخول بنفسه بعد إعادة التشغيل؟ [y/N]"
MSG_INFO_AUTOLOGIN_PROMPT_REASON="يكتب Ostler كلمة المرور هذه في ملف على هذا الـ Mac في /etc/kcpassword. وهي مشوَّشة هناك بنمط ثابت هو نفسه على كل جهاز Mac وموثّق علنًا، لذا فهو ليس تشفيرًا ويمكن عكسه. يمكن لأي شخص يستطيع استخدام حساب مسؤول على هذا الـ Mac، أو يستطيع نزع القرص وقراءته في مكان آخر، أن يحوّل هذا الملف إلى كلمة مرور تسجيل الدخول الخاصة بـ %s.

كان FileVault سيمنع ذلك، لأن القرص لا يمكن قراءته إطلاقًا دون كلمة مرور بدء التشغيل. كما يمنع FileVault تسجيل الدخول التلقائي للسبب نفسه، ولهذا لا يعرض Ostler هذا الخيار إلا عندما يكون FileVault متوقفًا.

ما يتحكم به المثبّت: لا يعرض كلمة المرور أثناء كتابتها، ولا يكتبها في سجل التثبيت. الملف المشوَّش هو النسخة الوحيدة التي ينشئها المثبّت.

اترك الحقل فارغًا لتخطي تسجيل الدخول التلقائي."
MSG_PROMPT_AUTOLOGIN_PASSWORD="كلمة مرور تسجيل الدخول لـ %s"
MSG_OK_AUTOLOGIN_CONFIGURED="تسجيل الدخول التلقائي مفعّل لـ %s، وكلمة مرور تسجيل الدخول هذه محفوظة الآن على هذا الـ Mac في /etc/kcpassword بصيغة مشوَّشة. بعد إعادة التشغيل يسجّل هذا الـ Mac الدخول بنفسه، وتبدأ خدمات Ostler مع تلك الجلسة. للتراجع، أوقف تسجيل الدخول تلقائيًا في إعدادات النظام > المستخدمون والمجموعات."
MSG_INFO_AUTOLOGIN_ALREADY="تسجيل الدخول التلقائي مُعدّ مسبقًا لـ %s، لذا فكلمة مرور تسجيل الدخول هذه محفوظة أصلًا على هذا الـ Mac في /etc/kcpassword. سيُترك كلاهما كما هو. للتراجع، أوقف تسجيل الدخول تلقائيًا في إعدادات النظام > المستخدمون والمجموعات."
MSG_INFO_AUTOLOGIN_DECLINED="لم يُفعَّل تسجيل الدخول التلقائي ولم تُحفظ أي كلمة مرور. بعد إعادة التشغيل أو انقطاع الكهرباء، سجّل الدخول كالمعتاد وستبدأ خدمات Ostler مع جلستك."
MSG_INFO_AUTOLOGIN_SKIPPED_NONINTERACTIVE="يتم تخطي إعداد تسجيل الدخول التلقائي: لا توجد طريقة لطلب كلمة مرور تسجيل الدخول هنا، ولم يُحفظ شيء. يمكنك تفعيل تسجيل الدخول تلقائيًا لاحقًا في إعدادات النظام > المستخدمون والمجموعات إذا أردت أن يتعافى هذا الـ Mac من إعادة التشغيل دون تدخل. فهو يحفظ كلمة مرور تسجيل الدخول على الـ Mac بصيغة مشوَّشة قابلة للعكس، لذا من الأفضل أن تطّلع على ذلك قبل أن تفعله."
MSG_WARN_AUTOLOGIN_NO_PASSWORD="لم تُدخل كلمة مرور، لذا لم يُفعَّل تسجيل الدخول التلقائي ولم يُحفظ شيء. إذا أردته لاحقًا، فعّل تسجيل الدخول تلقائيًا في إعدادات النظام > المستخدمون والمجموعات."
MSG_WARN_AUTOLOGIN_FAILED="تعذّر تفعيل تسجيل الدخول التلقائي (%s). لن تتم إعادة المحاولة. إذا كان الملف /etc/kcpassword موجودًا على هذا الـ Mac فهو يحتوي كلمة مرور تسجيل الدخول تلك بصيغة مشوَّشة رغم أن الميزة متوقفة؛ يمكنك حذفه من Terminal بالأمر: sudo rm /etc/kcpassword. للمحاولة مرة أخرى، فعّل تسجيل الدخول تلقائيًا في إعدادات النظام > المستخدمون والمجموعات."
MSG_WARN_AUTOLOGIN_FILEVAULT="FileVault مفعّل، لذا يطلب هذا الـ Mac كلمة مرور في شاشة الإقلاع لفتح القرص قبل أن يتمكن أي شخص من تسجيل الدخول. لا يستطيع تسجيل الدخول التلقائي الإجابة عن ذلك، فبعد انقطاع الكهرباء ينتظر هذا الـ Mac عند شاشة فتح FileVault حتى يدخلها أحد. لم يُفعَّل تسجيل الدخول التلقائي ولم تُحفظ أي كلمة مرور. وهذا هو الترتيب الأقوى من الاثنين: التعافي دون تدخل بعد إعادة التشغيل غير ممكن ما دام FileVault مفعّلًا، وفي المقابل يبقى القرص غير قابل للقراءة لمن لا يملك كلمة المرور تلك."

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
MSG_PROMPT_FDA_PANE_OPEN_FAILED_LINE1="تعذّر على Ostler فتح إعدادات النظام نيابةً عنك. يُرجى فتح إعدادات النظام بنفسك والانتقال إلى الخصوصية والأمن > الوصول الكامل إلى القرص."
# ── Container-engine ownership disclosure ─────────────────────────────────
# DISCLOSURE, NOT DISCLAIMER. Andy asked (2026-08-24) whether we could write
# something to absolve us if a customer disrupts what we install. A clause
# does not do that job -- to a customer it is our product that stopped
# working. What does the job is saying plainly, up front, what we install and
# what depends on it, and then DETECTING and SAYING SO when it breaks.
# Deliberately says "will tell you and try to restart it" because both halves
# are now true (periodic liveness + a real restart path); do not weaken either
# sentence without removing the corresponding capability.
MSG_INFO_ENGINE_OWNERSHIP_DISCLOSURE="يشغّل Ostler الويكي والبحث لديك داخل حاويات، لذا يثبّت ويدير محرك حاويات (Colima) على هذا الـ Mac. إذا أُزيل هذا المحرك أو أُعيد إعداده، فسيتوقف الويكي والبحث عن العمل – وسيُبلغك Ostler بذلك ويحاول إعادة تشغيله."
MSG_INFO_ENGINE_ALREADY_PRESENT="يوجد محرك حاويات مثبّت بالفعل على هذا الـ Mac. سيستخدمه Ostler بدلًا من تثبيت محرك خاص به، ولن يديره أو يعدّله."

