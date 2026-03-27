import 'package:flutter/material.dart';

enum GuideRole { admin, teacher }

class ScreenHelpGuide {
  static Future<void> show(
    BuildContext context, {
    required GuideRole role,
    required String screenId,
    required String screenTitle,
  }) async {
    final content = _buildContent(
      role: role,
      screenId: screenId,
      title: screenTitle,
    );
    bool ar = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setD) {
          final map = ar ? content.ar : content.en;
          return AlertDialog(
            title: Row(
              children: [
                Expanded(child: Text(ar ? 'دليل الاستخدام' : 'Usage Guide')),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment<bool>(value: false, label: Text('EN')),
                    ButtonSegment<bool>(value: true, label: Text('AR')),
                  ],
                  selected: {ar},
                  onSelectionChanged: (s) => setD(() => ar = s.first),
                ),
              ],
            ),
            content: SizedBox(
              width: 640,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _section(map['title']!, map['how']!),
                    const SizedBox(height: 10),
                    _section(map['stepsTitle']!, map['steps']!),
                    const SizedBox(height: 10),
                    _section(map['buttonsTitle']!, map['buttons']!),
                    const SizedBox(height: 10),
                    _section(map['dosTitle']!, map['dos']!),
                    const SizedBox(height: 10),
                    _section(map['dontsTitle']!, map['donts']!),
                    const SizedBox(height: 10),
                    _section(map['scenariosTitle']!, map['scenarios']!),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(ar ? 'إغلاق' : 'Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  static Widget _section(String title, String body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
        ),
        const SizedBox(height: 6),
        Text(body, style: const TextStyle(height: 1.35)),
      ],
    );
  }

  static _GuideContent _buildContent({
    required GuideRole role,
    required String screenId,
    required String title,
  }) {
    final id = screenId.toLowerCase();
    final roleNameEn = role == GuideRole.admin ? 'admin' : 'teacher';
    final roleNameAr = role == GuideRole.admin ? 'الإدارة' : 'المعلم';

    final profile = _profileForScreenId(id);

    return _GuideContent(
      en: {
        'title': '$title (${roleNameEn.toUpperCase()})',
        'how': profile.enHow,
        'stepsTitle': 'Step-by-Step Flow',
        'steps': profile.enSteps,
        'buttonsTitle': 'Buttons & Controls',
        'buttons': profile.enButtons,
        'dosTitle': 'Do',
        'dos': profile.enDos,
        'dontsTitle': "Don't",
        'donts': profile.enDonts,
        'scenariosTitle': 'Common Scenario',
        'scenarios': profile.enScenario,
      },
      ar: {
        'title': '$title ($roleNameAr)',
        'how': profile.arHow,
        'stepsTitle': 'خطوات العمل',
        'steps': profile.arSteps,
        'buttonsTitle': 'الأزرار وأدوات التحكم',
        'buttons': profile.arButtons,
        'dosTitle': 'افعل',
        'dos': profile.arDos,
        'dontsTitle': 'لا تفعل',
        'donts': profile.arDonts,
        'scenariosTitle': 'سيناريو شائع',
        'scenarios': profile.arScenario,
      },
    );
  }

  static _GuideProfile _profileForScreenId(String id) {
    if (_idHasAny(id, ['payment'])) {
      return const _GuideProfile(
        enHow:
            'Start with month, learner, course, and study type filters so you are reviewing exactly one payment lane at a time. Balances are cumulative per learner + course + study type, and consumption follows the rule of that study type (not one global rule).',
        enSteps:
            '1) Select learner first, then open the exact course row.\n2) Confirm the study type before changing any values.\n3) Review sessions paid, consumed, and remaining.\n4) Read warning cues separately: sessions-left cue and expiry-date cue.\n5) Add or edit payment details.\n6) Re-open the learner row and confirm status chips changed as expected.',
        enButtons:
            '- Add Payment: create a new payment record, then refresh summary numbers.\n- Edit: update amount, method, sessions, and reminder values safely.\n- Backup/Export: export the filtered period before monthly closing.\n- Refresh: reload latest data before approving or escalating due cases.',
        enDos:
            '- Record each payment on the exact learner-course-study type combination.\n- Keep reminder thresholds realistic so warnings are meaningful.\n- Re-check status immediately after add/edit/delete.',
        enDonts:
            '- Do not mix study types into one payment balance.\n- Do not skip refresh before a final payment decision.\n- Do not rely on stale cached totals while discussing dues.',
        enScenario:
            'Example by study type: In-Class counts present + absent held sessions; Private counts present only; Flexible counts teacher-confirmed online present sessions and also respects expiry date warnings.',
        arHow:
            'ابدأ دائماً بفلترة الشهر والطالب والمقرر ونوع الدراسة حتى تراجع مسار دفع واحد واضح. الرصيد تراكمي لكل (طالب + مقرر + نوع دراسة)، والاستهلاك يتبع قاعدة نوع الدراسة نفسه وليس قاعدة موحدة للجميع.',
        arSteps:
            '1) اختر الطالب ثم افتح صف المقرر المطلوب.\n2) تأكد من نوع الدراسة قبل أي تعديل.\n3) راجع المدفوع والمستهلك والمتبقي.\n4) اقرأ التنبيهين بشكل منفصل: تنبيه الحصص وتنبيه تاريخ الانتهاء.\n5) أضف أو عدّل الدفع.\n6) أعد فتح السجل وتأكد أن مؤشرات الحالة تغيّرت بشكل صحيح.',
        arButtons:
            '- إضافة دفع: إنشاء سجل دفع جديد ثم تحديث الأرقام.\n- تعديل: تعديل المبلغ والطريقة والحصص وحد التذكير بشكل آمن.\n- نسخ احتياطي/تصدير: استخراج البيانات المفلترة قبل إغلاق الشهر.\n- تحديث: جلب أحدث البيانات قبل اعتماد قرار الاستحقاق.',
        arDos:
            '- سجّل كل دفعة على الطالب والمقرر ونوع الدراسة الصحيح.\n- اضبط حدود التذكير بشكل منطقي حتى تكون التنبيهات مفيدة.\n- راجع الحالة مباشرة بعد الإضافة/التعديل/الحذف.',
        arDonts:
            '- لا تخلط أنواع الدراسة داخل نفس الرصيد.\n- لا تتخذ قراراً نهائياً قبل التحديث الأخير.\n- لا تعتمد على أرقام قديمة أثناء مراجعة الاستحقاق.',
        arScenario:
            'مثال حسب نوع الدراسة: الحضوري يحسب الجلسات المنفذة (حضور + غياب)، والخاص يحسب الحضور فقط، والمرن يحسب حضور الأونلاين المؤكد من المعلم مع مراعاة تنبيهات الانتهاء.',
      );
    }

    if (_idHasAny(id, ['class', 'schedule', 'timetable'])) {
      return const _GuideProfile(
        enHow:
            'Use filters (day, teacher, class state, study type) to isolate the exact class quickly. Apply actions from card controls, then verify updates in class details and related attendance/progress views.',
        enSteps:
            '1) Filter by teacher/day/status.\n2) Open target class card.\n3) Apply schedule or class updates.\n4) Save and reload.\n5) Validate in schedule + attendance entry points.',
        enButtons:
            '- Refresh: reload class list.\n- Filters: narrow records before editing.\n- Card actions: open details/edit/attendance/progress.\n- Save: commit class changes.',
        enDos:
            '- Confirm class ID and course before edits.\n- Keep schedule slots consistent (day/start/end).\n- Re-open class card after save to verify persistence.',
        enDonts:
            '- Do not edit wrong class with similar title.\n- Do not leave overlapping time slots unresolved.\n- Do not skip post-save verification.',
        enScenario:
            'Filter by teacher + day, edit one class slot, save, then verify same class in schedule and attendance entry points.',
        arHow:
            'استخدم الفلاتر (اليوم، المعلم، حالة الصف، النوع) لعزل الصف المطلوب. نفّذ الإجراء من بطاقة الصف ثم تحقق من النتيجة في التفاصيل وشاشات الحضور/التقدم المرتبطة.',
        arSteps:
            '1) فلتر حسب المعلم/اليوم/الحالة.\n2) افتح بطاقة الصف المطلوبة.\n3) عدّل الجدول أو بيانات الصف.\n4) احفظ ثم حدّث الصفحة.\n5) تحقّق في الجدول ونقطة إدخال الحضور.',
        arButtons:
            '- تحديث: إعادة تحميل القائمة.\n- الفلاتر: تضييق النتائج قبل التعديل.\n- أزرار البطاقة: تفاصيل/تعديل/حضور/تقدم.\n- حفظ: تثبيت التعديلات.',
        arDos:
            '- تأكد من معرف الصف والمقرر قبل التعديل.\n- حافظ على اتساق اليوم/البداية/النهاية.\n- أعد فتح البطاقة بعد الحفظ للتأكد من التخزين.',
        arDonts:
            '- لا تعدّل صفاً خاطئاً بسبب تشابه الاسم.\n- لا تترك تعارضات زمنية بدون حل.\n- لا تتجاوز التحقق بعد الحفظ.',
        arScenario:
            'فلتر حسب المعلم + اليوم، عدّل حصة واحدة، احفظ، ثم تحقق من نفس الصف في الجدول ونقاط إدخال الحضور.',
      );
    }

    if (_idHasAny(id, ['course', 'syllab'])) {
      return const _GuideProfile(
        enHow:
            'Manage course metadata first, then study type delivery config, then syllabus content. Keep study type names and fees aligned so classes and payments consume the correct branch.',
        enSteps:
            '1) Update course basics (title, level, duration).\n2) Configure each study type fee/access.\n3) Open syllabus editor for the intended study type.\n4) Save and verify on class/payment screens.',
        enButtons:
            '- Add/Edit Course: update course metadata.\n- Pricing/Bulk controls: set study type fee rules.\n- Syllabus button: edit lessons for chosen study type.\n- Refresh: pull latest course config.',
        enDos:
            '- Update duration and fee per study type carefully.\n- Keep syllabus inside the matching study type branch.\n- Use clear tags/requirements for searchability.',
        enDonts:
            '- Do not mix private/flexible/inclass settings.\n- Do not keep a study type enabled without fee/duration.\n- Do not publish inconsistent labels.',
        enScenario:
            'Edit Private study type fee and syllabus, save, then verify class creation and payment screens show the same behavior.',
        arHow:
            'ابدأ ببيانات المقرر الأساسية ثم إعدادات الأنواع ثم المنهج. حافظ على تطابق أسماء الأنواع والرسوم حتى تعمل الصفوف والمدفوعات على الفرع الصحيح.',
        arSteps:
            '1) حدّث أساسيات المقرر (الاسم/المستوى/المدة).\n2) اضبط رسوم وصلاحية كل نوع دراسة.\n3) افتح المنهج لنوع الدراسة المطلوب.\n4) احفظ وتحقق في الصفوف والمدفوعات.',
        arButtons:
            '- إضافة/تعديل مقرر: تحديث البيانات الأساسية.\n- أدوات التسعير: ضبط رسوم أنواع الدراسة.\n- زر المنهج: تعديل دروس النوع المحدد.\n- تحديث: جلب أحدث الإعدادات.',
        arDos:
            '- حدّث المدة/الرسوم لكل نوع بدقة.\n- احفظ المنهج في فرع النوع الصحيح.\n- استخدم متطلبات ووسوم واضحة للبحث.',
        arDonts:
            '- لا تخلط إعدادات الخاص/المرن/الحضوري.\n- لا تفعّل نوعاً بدون رسوم/مدة.\n- لا تنشر تسميات غير متطابقة.',
        arScenario:
            'عدّل رسوم ومنهج النوع الخاص، احفظ، ثم تحقق أن إنشاء الصف وشاشة الدفع يعرضان نفس سلوك النوع.',
      );
    }

    if (_idHasAny(id, ['mail', 'inbox', 'topic', 'thread'])) {
      return const _GuideProfile(
        enHow:
            'Use search and topic grouping to keep communication traceable. Set clear subject, send concise messages, and attach files only when needed. Use thread actions for cleanup.',
        enSteps:
            '1) Use search/filter to locate the right thread.\n2) Open one thread and read latest messages.\n3) Send concise response with correct attachment type.\n4) Use selection mode for bulk delete/copy when needed.',
        enButtons:
            '- New Topic/New Mail: start a fresh conversation.\n- Search: filter threads/messages quickly.\n- Attachment: image/file/audio upload.\n- Message menu or selection toolbar: delete/copy actions.',
        enDos:
            '- Keep one topic per issue.\n- Use class/learner identifiers in subject when relevant.\n- Review recipient role before sending.',
        enDonts:
            '- Do not send ambiguous subjects.\n- Do not split one issue across many topics.\n- Do not delete before confirming archive needs.',
        enScenario:
            'Create topic for one class issue, send details + attachment, then track all follow-ups inside same thread.',
        arHow:
            'استخدم البحث وتجميع المواضيع للحفاظ على تتبع المراسلات. ضع عنواناً واضحاً، أرسل رسائل مختصرة، وأرفق الملفات عند الحاجة فقط. استخدم إجراءات الموضوع للتنظيف.',
        arSteps:
            '1) استخدم البحث للوصول للمحادثة الصحيحة.\n2) افتح المحادثة واقرأ أحدث الرسائل.\n3) أرسل رداً مختصراً مع المرفق المناسب.\n4) استخدم وضع التحديد المتعدد للحذف/النسخ الجماعي.',
        arButtons:
            '- موضوع/رسالة جديدة: بدء محادثة جديدة.\n- بحث: فلترة سريعة للمواضيع والرسائل.\n- مرفق: رفع صورة/ملف/صوت.\n- قائمة الرسالة أو شريط التحديد: حذف ونسخ.',
        arDos:
            '- اجعل لكل مشكلة موضوعاً مستقلاً.\n- اذكر معرف الصف/الطالب في العنوان عند الحاجة.\n- راجع دور المستلم قبل الإرسال.',
        arDonts:
            '- لا ترسل عناوين مبهمة.\n- لا توزّع نفس المشكلة على مواضيع متعددة.\n- لا تحذف قبل التأكد من الحاجة للأرشفة.',
        arScenario:
            'أنشئ موضوعاً لمشكلة صف واحدة، أرسل التفاصيل والمرفق، ثم تابع كل الردود داخل نفس المحادثة.',
      );
    }

    if (_idHasAny(id, ['gallery', 'story', 'game', 'file', 'shared'])) {
      return const _GuideProfile(
        enHow:
            'Use this media/files screen to upload, review, and organize content. Validate file type and destination before upload. Use delete carefully with post-check.',
        enSteps:
            '1) Choose the target tab/folder.\n2) Upload file and wait for success toast.\n3) Open preview to validate media quality.\n4) Use download button for local copy when needed.\n5) Delete outdated items carefully.',
        enButtons:
            '- Upload: pick media/file and send to server.\n- Preview/Open: verify content.\n- Download: save a local copy.\n- Delete: remove selected item from gallery/file list.',
        enDos:
            '- Keep naming consistent and searchable.\n- Verify preview after upload.\n- Remove duplicates or outdated assets.',
        enDonts:
            '- Do not upload to wrong learner/class path.\n- Do not keep broken links.\n- Do not delete without checking dependencies.',
        enScenario:
            'Upload one file, confirm it opens in preview, then verify visibility in related learner/teacher view.',
        arHow:
            'استخدم شاشة الوسائط/الملفات للرفع والمراجعة والتنظيم. تحقق من نوع الملف ومسار الوجهة قبل الرفع. احذف بحذر مع تحقق لاحق.',
        arSteps:
            '1) اختر التبويب أو المجلد المستهدف.\n2) ارفع الملف وانتظر رسالة النجاح.\n3) افتح المعاينة وتأكد من الجودة.\n4) استخدم زر التحميل لحفظ نسخة محلية عند الحاجة.\n5) احذف العناصر القديمة بحذر.',
        arButtons:
            '- رفع: اختيار ملف وإرساله.\n- معاينة/فتح: التحقق من المحتوى.\n- تحميل: حفظ نسخة على الجهاز.\n- حذف: إزالة العنصر من القائمة.',
        arDos:
            '- استخدم تسمية موحدة وسهلة البحث.\n- تأكد من المعاينة بعد الرفع.\n- احذف التكرارات أو الملفات القديمة.',
        arDonts:
            '- لا ترفع في مسار طالب/صف خاطئ.\n- لا تترك روابط معطلة.\n- لا تحذف قبل فحص الاعتمادية.',
        arScenario:
            'ارفع ملفاً واحداً، تأكد من فتحه في المعاينة، ثم تحقق من ظهوره في شاشة العرض المرتبطة.',
      );
    }

    if (_idHasAny(id, ['attendance'])) {
      return const _GuideProfile(
        enHow:
            'Record attendance per session accurately, then save once after final review. Use history/stats screens to verify trend and fix mistaken sessions via edit flow.',
        enSteps:
            '1) Open the correct class/session date.\n2) Mark each learner attendance status.\n3) Confirm taught lesson and homework entries.\n4) Save once.\n5) Verify in history/stats; edit if needed.',
        enButtons:
            '- Present/Absent controls: mark attendance.\n- Add lesson/homework controls: session teaching data.\n- Save: submit final session record.\n- History/Stats actions: review and correction paths.',
        enDos:
            '- Mark present/absent carefully.\n- Confirm taught items and homework details.\n- Re-check class/date before save.',
        enDonts:
            '- Do not save partial attendance accidentally.\n- Do not mark attendance for wrong class/date.\n- Do not ignore correction flow for mistakes.',
        enScenario:
            'Take attendance for session, save, then open history to verify status and update one learner if needed.',
        arHow:
            'سجّل الحضور لكل حصة بدقة ثم احفظ بعد المراجعة النهائية. استخدم التاريخ/الإحصاءات للتحقق وتصحيح أي جلسة عبر مسار التعديل.',
        arSteps:
            '1) افتح الصف الصحيح وتاريخ الحصة الصحيح.\n2) حدّد حالة كل طالب.\n3) راجع الدرس المنفذ والواجب.\n4) احفظ مرة واحدة.\n5) تحقق من التاريخ/الإحصاءات وعدّل عند الحاجة.',
        arButtons:
            '- أزرار حاضر/غائب: تسجيل الحضور.\n- أزرار الدرس/الواجب: بيانات الحصة.\n- حفظ: اعتماد السجل النهائي.\n- التاريخ/الإحصاءات: مراجعة وتصحيح.',
        arDos:
            '- حدّد حاضر/غائب بدقة.\n- تأكد من الدروس المنفذة والواجب.\n- راجع الصف والتاريخ قبل الحفظ.',
        arDonts:
            '- لا تحفظ حضوراً غير مكتمل بالخطأ.\n- لا تسجّل لصف/تاريخ خاطئ.\n- لا تتجاهل مسار التصحيح عند الخطأ.',
        arScenario:
            'سجّل الحضور للحصة، احفظ، ثم افتح التاريخ للتحقق وعدّل حالة طالب واحد إذا لزم.',
      );
    }

    if (_idHasAny(id, [
      'reminder',
      'wage',
      'certificate',
      'subscription',
      'contract',
    ])) {
      return const _GuideProfile(
        enHow:
            'Use this operational screen with a review-first workflow: filter targets, apply action, then confirm status changes immediately in the list.',
        enSteps:
            '1) Apply relevant filters.\n2) Open target record details.\n3) Perform action (reminder/wage/subscription/certificate update).\n4) Save and verify status chip/count.',
        enButtons:
            '- Filters/Search: narrow target rows.\n- Add/Edit action buttons: execute operation.\n- Export/Download (if available): generate records.\n- Refresh: confirm final state.',
        enDos:
            '- Use precise filters.\n- Keep notes/status updates clear.\n- Validate final state after each action.',
        enDonts:
            '- Do not apply actions to unfiltered lists.\n- Do not leave stale statuses.\n- Do not skip final verification.',
        enScenario:
            'Filter target records, apply one action batch, then verify status chips/counts and details view.',
        arHow:
            'استخدم هذه الشاشة التشغيلية بمنهجية: فلترة الهدف ثم التنفيذ ثم التحقق الفوري من تغير الحالة في القائمة.',
        arSteps:
            '1) طبّق الفلاتر المناسبة.\n2) افتح تفاصيل السجل المطلوب.\n3) نفّذ الإجراء (تذكير/أجر/اشتراك/شهادة).\n4) احفظ وتحقق من المؤشر والعداد.',
        arButtons:
            '- الفلاتر/البحث: تضييق السجلات.\n- أزرار إضافة/تعديل: تنفيذ العملية.\n- تصدير/تحميل (إن وجد): إنشاء ملفات.\n- تحديث: تأكيد الحالة النهائية.',
        arDos:
            '- استخدم فلاتر دقيقة.\n- حافظ على وضوح الملاحظات والحالات.\n- تحقق من الحالة النهائية بعد كل إجراء.',
        arDonts:
            '- لا تطبق إجراءات على قوائم غير مفلترة.\n- لا تترك حالات قديمة بلا تحديث.\n- لا تتجاوز التحقق النهائي.',
        arScenario:
            'فلتر السجلات المطلوبة، نفّذ إجراءً واحداً، ثم راجع مؤشرات الحالة والعدادات والتفاصيل.',
      );
    }

    return const _GuideProfile(
      enHow:
          'Use filters/search first, then perform one clear action and verify the resulting status/record immediately.',
      enSteps:
          '1) Identify the correct record.\n2) Open details and review current values.\n3) Apply one action.\n4) Save and verify final state.',
      enButtons:
          '- Search/Filter: find target quickly.\n- Main action button: perform operation.\n- Refresh: verify updates from server.',
      enDos:
          '- Identify target record by ID/code.\n- Apply minimal safe change.\n- Re-check the saved result.',
      enDonts:
          '- Do not apply broad edits without filters.\n- Do not leave ambiguous values.\n- Do not skip verification.',
      enScenario:
          'Search target, update one field/action, save, then confirm status and values in list/details.',
      arHow:
          'ابدأ بالفلترة/البحث، ثم نفّذ إجراءً واضحاً واحداً، ثم تحقق مباشرة من النتيجة.',
      arSteps:
          '1) حدّد السجل الصحيح.\n2) افتح التفاصيل وراجع القيم.\n3) نفّذ إجراءً واحداً.\n4) احفظ وتحقق من الحالة النهائية.',
      arButtons:
          '- البحث/الفلترة: الوصول السريع للسجل.\n- زر الإجراء الرئيسي: تنفيذ العملية.\n- تحديث: تأكيد التغييرات من الخادم.',
      arDos:
          '- حدّد السجل الصحيح بالمعرف/الكود.\n- نفّذ أقل تعديل آمن.\n- راجع النتيجة بعد الحفظ.',
      arDonts:
          '- لا تطبق تعديلات واسعة بدون فلترة.\n- لا تترك قيماً مبهمة.\n- لا تتجاوز التحقق.',
      arScenario:
          'ابحث عن السجل، عدّل حقلاً واحداً، احفظ، ثم تحقق من القيم والحالة في القائمة والتفاصيل.',
    );
  }

  static bool _idHasAny(String id, List<String> needles) {
    for (final n in needles) {
      if (id.contains(n)) return true;
    }
    return false;
  }
}

class _GuideContent {
  const _GuideContent({required this.en, required this.ar});
  final Map<String, String> en;
  final Map<String, String> ar;
}

class _GuideProfile {
  const _GuideProfile({
    required this.enHow,
    required this.enSteps,
    required this.enButtons,
    required this.enDos,
    required this.enDonts,
    required this.enScenario,
    required this.arHow,
    required this.arSteps,
    required this.arButtons,
    required this.arDos,
    required this.arDonts,
    required this.arScenario,
  });

  final String enHow;
  final String enSteps;
  final String enButtons;
  final String enDos;
  final String enDonts;
  final String enScenario;
  final String arHow;
  final String arSteps;
  final String arButtons;
  final String arDos;
  final String arDonts;
  final String arScenario;
}
