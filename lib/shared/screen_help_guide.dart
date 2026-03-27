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
            'Use month/learner/variant filters first. Balances are cumulative per learner + course + variant. For session variants, consumed sessions are PRESENT only. Due is triggered only when paid sessions are fully consumed.',
        enDos:
            '- Record payment on correct learner-course-variant.\n- Keep reminder threshold realistic (warning only).\n- Re-check status after add/edit/delete payment.',
        enDonts:
            '- Do not count absences as consumed.\n- Do not mix variants in one balance.\n- Do not validate totals before refresh.',
        enScenario:
            'Paid 8, present 6, absent 2 => not due. After 2 more present => due. Add another 8 => returns to not due (cumulative).',
        arHow:
            'ابدأ بفلاتر الشهر/الطالب/النوع. الرصيد تراكمي لكل طالب + مقرر + نوع. في الأنواع المعتمدة على الحصص يتم احتساب الحضور فقط، ويصبح مستحقاً عند استهلاك كل الحصص المدفوعة.',
        arDos:
            '- سجّل الدفع على الطالب-المقرر-النوع الصحيح.\n- اضبط حد التذكير للتنبيه فقط.\n- راجع الحالة بعد أي إضافة أو تعديل أو حذف.',
        arDonts:
            '- لا تحتسب الغياب كاستهلاك.\n- لا تخلط الأنواع في نفس الرصيد.\n- لا تعتمد على أرقام قبل التحديث.',
        arScenario:
            'دفع 8، حضور 6، غياب 2 => غير مستحق. بعد حضور حصتين إضافيتين => مستحق. بعد دفع 8 جديدة => يعود غير مستحق (تراكمي).',
      );
    }

    if (_idHasAny(id, ['class', 'schedule', 'timetable'])) {
      return const _GuideProfile(
        enHow:
            'Use filters (day, teacher, class state, variant) to isolate the target class. Apply actions from card controls, then verify updates in class details and related attendance/progress views.',
        enDos:
            '- Confirm class ID and course before edits.\n- Keep schedule slots consistent (day/start/end).\n- Re-open class card after save to verify persistence.',
        enDonts:
            '- Do not edit wrong class with similar title.\n- Do not leave overlapping time slots unresolved.\n- Do not skip post-save verification.',
        enScenario:
            'Filter by teacher + day, edit one class slot, save, then verify same class in schedule and attendance entry points.',
        arHow:
            'استخدم الفلاتر (اليوم، المعلم، حالة الصف، النوع) لعزل الصف المطلوب. نفّذ الإجراء من بطاقة الصف ثم تحقق من النتيجة في التفاصيل وشاشات الحضور/التقدم المرتبطة.',
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
            'Manage course metadata first, then variant delivery config, then syllabus. Keep variant naming and fees aligned so classes and payments consume the correct branch.',
        enDos:
            '- Update duration/fee per variant carefully.\n- Keep syllabus in the matching variant branch.\n- Use clear tags/requirements for searchability.',
        enDonts:
            '- Do not mix private/flexible/inclass settings.\n- Do not leave variant enabled without fee/duration.\n- Do not publish inconsistent labels.',
        enScenario:
            'Edit Private variant fee and syllabus, save, then verify class creation and payment screens show same variant behavior.',
        arHow:
            'ابدأ ببيانات المقرر الأساسية ثم إعدادات الأنواع ثم المنهج. حافظ على تطابق أسماء الأنواع والرسوم حتى تعمل الصفوف والمدفوعات على الفرع الصحيح.',
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
        enDos:
            '- Keep one topic per issue.\n- Use class/learner identifiers in subject when relevant.\n- Review recipient role before sending.',
        enDonts:
            '- Do not send ambiguous subjects.\n- Do not split one issue across many topics.\n- Do not delete before confirming archive needs.',
        enScenario:
            'Create topic for one class issue, send details + attachment, then track all follow-ups inside same thread.',
        arHow:
            'استخدم البحث وتجميع المواضيع للحفاظ على تتبع المراسلات. ضع عنواناً واضحاً، أرسل رسائل مختصرة، وأرفق الملفات عند الحاجة فقط. استخدم إجراءات الموضوع للتنظيف.',
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
        enDos:
            '- Keep naming consistent and searchable.\n- Verify preview after upload.\n- Remove duplicates or outdated assets.',
        enDonts:
            '- Do not upload to wrong learner/class path.\n- Do not keep broken links.\n- Do not delete without checking dependencies.',
        enScenario:
            'Upload one file, confirm it opens in preview, then verify visibility in related learner/teacher view.',
        arHow:
            'استخدم شاشة الوسائط/الملفات للرفع والمراجعة والتنظيم. تحقق من نوع الملف ومسار الوجهة قبل الرفع. احذف بحذر مع تحقق لاحق.',
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
        enDos:
            '- Mark present/absent carefully.\n- Confirm taught items and homework details.\n- Re-check class/date before save.',
        enDonts:
            '- Do not save partial attendance accidentally.\n- Do not mark attendance for wrong class/date.\n- Do not ignore correction flow for mistakes.',
        enScenario:
            'Take attendance for session, save, then open history to verify status and update one learner if needed.',
        arHow:
            'سجّل الحضور لكل حصة بدقة ثم احفظ بعد المراجعة النهائية. استخدم التاريخ/الإحصاءات للتحقق وتصحيح أي جلسة عبر مسار التعديل.',
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
        enDos:
            '- Use precise filters.\n- Keep notes/status updates clear.\n- Validate final state after each action.',
        enDonts:
            '- Do not apply actions to unfiltered lists.\n- Do not leave stale statuses.\n- Do not skip final verification.',
        enScenario:
            'Filter target records, apply one action batch, then verify status chips/counts and details view.',
        arHow:
            'استخدم هذه الشاشة التشغيلية بمنهجية: فلترة الهدف ثم التنفيذ ثم التحقق الفوري من تغير الحالة في القائمة.',
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
      enDos:
          '- Identify target record by ID/code.\n- Apply minimal safe change.\n- Re-check the saved result.',
      enDonts:
          '- Do not apply broad edits without filters.\n- Do not leave ambiguous values.\n- Do not skip verification.',
      enScenario:
          'Search target, update one field/action, save, then confirm status and values in list/details.',
      arHow:
          'ابدأ بالفلترة/البحث، ثم نفّذ إجراءً واضحاً واحداً، ثم تحقق مباشرة من النتيجة.',
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
    required this.enDos,
    required this.enDonts,
    required this.enScenario,
    required this.arHow,
    required this.arDos,
    required this.arDonts,
    required this.arScenario,
  });

  final String enHow;
  final String enDos;
  final String enDonts;
  final String enScenario;
  final String arHow;
  final String arDos;
  final String arDonts;
  final String arScenario;
}
