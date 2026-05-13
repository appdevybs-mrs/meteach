import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:url_launcher/url_launcher.dart';

import '../shared/app_feedback.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';

class AdminJobApplicationsScreen extends StatefulWidget {
  const AdminJobApplicationsScreen({super.key});

  @override
  State<AdminJobApplicationsScreen> createState() =>
      _AdminJobApplicationsScreenState();
}

class _AdminJobApplicationsScreenState
    extends State<AdminJobApplicationsScreen> {
  static const Color _primaryBlue = Color(0xFF1A2B48);
  static const Color _actionOrange = Color(0xFFF98D28);
  static const Color _appBg = Color(0xFFF4F7F9);
  static const Color _uiBorder = Color(0xFFD1D9E0);

  final DatabaseReference _ref = FirebaseDatabase.instance.ref(
    'job_applications',
  );
  final TextEditingController _searchCtrl = TextEditingController();

  String _query = '';
  String _stageFilter = 'all';
  String _priorityFilter = 'all';
  bool _filtersExpanded = false;
  bool _exporting = false;
  List<_JobApplicationItem> _lastAllItems = const [];
  List<_JobApplicationItem> _lastFilteredItems = const [];

  Future<T?> _showSettledRootDialog<T>({required WidgetBuilder builder}) async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return null;

    return showDialog<T>(
      context: context,
      useRootNavigator: true,
      builder: builder,
    );
  }

  static const List<MapEntry<String, String>> _stageChoices = [
    MapEntry('new', 'New'),
    MapEntry('called_reached', 'Called (Reached)'),
    MapEntry('called_no_answer', 'Called (No Answer)'),
    MapEntry('callback_requested', 'Call Back Requested'),
    MapEntry('interview_scheduled', 'Interview Scheduled'),
    MapEntry('interview_done', 'Interview Done'),
    MapEntry('rejected', 'Rejected'),
    MapEntry('hired', 'Hired'),
  ];

  static const List<MapEntry<String, String>> _priorityChoices = [
    MapEntry('high', 'High'),
    MapEntry('medium', 'Medium'),
    MapEntry('low', 'Low'),
  ];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<_JobApplicationItem> _parseItems(dynamic value) {
    if (value is! Map) return const [];

    final raw = Map<dynamic, dynamic>.from(value);
    final out = <_JobApplicationItem>[];

    raw.forEach((key, val) {
      if (val is! Map) return;
      final m = val.map((k, v) => MapEntry(k.toString(), v));

      final status = _normStatus((m['status'] ?? '').toString());
      final stage = _normStage(
        (m['stage'] ?? _stageFromLegacyStatus(status)).toString(),
      );
      out.add(
        _JobApplicationItem(
          id: key.toString(),
          fullName: (m['full_name'] ?? '').toString().trim(),
          phone: (m['phone'] ?? '').toString().trim(),
          email: (m['email'] ?? '').toString().trim(),
          position: (m['position'] ?? '').toString().trim(),
          cvPdfUrl: (m['cv_pdf_url'] ?? '').toString().trim(),
          stage: stage,
          status: status,
          priority: _normPriority((m['priority'] ?? '').toString()),
          createdAt: _toInt(m['createdAt']),
          updatedAt: _toInt(m['updatedAt']),
          updatedBy: (m['updatedBy'] ?? '').toString().trim(),
          interviewAt: _toInt(m['interviewAt']),
          timeline: _parseTimeline(m['timeline']),
          isGuest: m['isGuest'] == true,
          submittedByUid: (m['submittedByUid'] ?? '').toString().trim(),
        ),
      );
    });

    out.sort((a, b) {
      final p = _priorityRank(a.priority).compareTo(_priorityRank(b.priority));
      if (p != 0) return p;
      return b.createdAt.compareTo(a.createdAt);
    });
    return out;
  }

  List<_JobApplicationItem> _filtered(List<_JobApplicationItem> items) {
    final q = _query.trim().toLowerCase();
    return items.where((item) {
      if (_stageFilter != 'all' && item.stage != _stageFilter) return false;
      if (_priorityFilter != 'all' && item.priority != _priorityFilter) {
        return false;
      }

      if (q.isEmpty) return true;
      return item.fullName.toLowerCase().contains(q) ||
          item.email.toLowerCase().contains(q) ||
          item.phone.toLowerCase().contains(q) ||
          item.position.toLowerCase().contains(q) ||
          item.id.toLowerCase().contains(q);
    }).toList();
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _normStatus(String raw) {
    final v = raw.trim().toLowerCase();
    switch (v) {
      case 'new':
      case 'reviewed':
      case 'shortlisted':
      case 'rejected':
      case 'hired':
        return v;
      default:
        return 'new';
    }
  }

  static String _normStage(String raw) {
    final v = raw.trim().toLowerCase();
    switch (v) {
      case 'new':
      case 'called_reached':
      case 'called_no_answer':
      case 'callback_requested':
      case 'interview_scheduled':
      case 'interview_done':
      case 'rejected':
      case 'hired':
        return v;
      default:
        return 'new';
    }
  }

  static String _stageFromLegacyStatus(String status) {
    switch (_normStatus(status)) {
      case 'reviewed':
        return 'called_reached';
      case 'shortlisted':
        return 'interview_scheduled';
      case 'rejected':
        return 'rejected';
      case 'hired':
        return 'hired';
      case 'new':
      default:
        return 'new';
    }
  }

  static String _legacyStatusFromStage(String stage) {
    switch (_normStage(stage)) {
      case 'called_reached':
      case 'called_no_answer':
      case 'callback_requested':
        return 'reviewed';
      case 'interview_scheduled':
      case 'interview_done':
        return 'shortlisted';
      case 'rejected':
        return 'rejected';
      case 'hired':
        return 'hired';
      case 'new':
      default:
        return 'new';
    }
  }

  static String _stageLabel(String stage) {
    switch (_normStage(stage)) {
      case 'new':
        return 'New';
      case 'called_reached':
        return 'Called (Reached)';
      case 'called_no_answer':
        return 'Called (No Answer)';
      case 'callback_requested':
        return 'Call Back Requested';
      case 'interview_scheduled':
        return 'Interview Scheduled';
      case 'interview_done':
        return 'Interview Done';
      case 'rejected':
        return 'Rejected';
      case 'hired':
        return 'Hired';
      default:
        return 'New';
    }
  }

  static List<_TimelineEvent> _parseTimeline(dynamic value) {
    if (value is! Map) return const [];
    final out = <_TimelineEvent>[];
    value.forEach((k, v) {
      if (v is! Map) return;
      final m = v.map((mk, mv) => MapEntry(mk.toString(), mv));
      final payloadRaw = m['payload'];
      final payload = payloadRaw is Map
          ? payloadRaw.map((pk, pv) => MapEntry(pk.toString(), pv))
          : const <String, dynamic>{};
      out.add(
        _TimelineEvent(
          id: k.toString(),
          type: (m['type'] ?? '').toString().trim(),
          at: _toInt(m['at']),
          byUid: (m['byUid'] ?? '').toString().trim(),
          byName: (m['byName'] ?? '').toString().trim(),
          payload: payload,
        ),
      );
    });
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  static String _normPriority(String raw) {
    final v = raw.trim().toLowerCase();
    switch (v) {
      case 'high':
      case 'medium':
      case 'low':
        return v;
      default:
        return 'medium';
    }
  }

  static int _priorityRank(String priority) {
    switch (priority) {
      case 'high':
        return 0;
      case 'medium':
        return 1;
      case 'low':
        return 2;
      default:
        return 1;
    }
  }

  Future<void> _callPhone(String phone) async {
    final cleaned = phone.replaceAll(RegExp(r'\s+'), '');
    final uri = Uri.parse('tel:$cleaned');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Could not open phone dialer.')),
      );
    }
  }

  Future<void> _sendEmail(String email) async {
    final uri = Uri.parse('mailto:$email');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Could not open email app.')),
      );
    }
  }

  Future<void> _openPdf(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Invalid PDF URL.')),
      );
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Could not open CV PDF.')),
      );
    }
  }

  Future<void> _copy(String text, String label) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: clean));
    if (!mounted) return;
    AppToast.fromSnackBar(
      context,
      SnackBar(content: Text('$label copied to clipboard.')),
    );
  }

  String get _adminUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  String get _adminName {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 'Admin';
    final name = (user.displayName ?? '').trim();
    if (name.isNotEmpty) return name;
    final email = (user.email ?? '').trim();
    if (email.isNotEmpty) return email;
    return user.uid;
  }

  Future<void> _appendTimelineEvent(
    _JobApplicationItem item, {
    required String type,
    required String stage,
    Map<String, dynamic> payload = const <String, dynamic>{},
    int? interviewAtMs,
  }) async {
    final stageValue = _normStage(stage);
    final eventRef = _ref.child(item.id).child('timeline').push();
    final updates = <String, dynamic>{
      'stage': stageValue,
      'status': _legacyStatusFromStage(stageValue),
      'updatedAt': ServerValue.timestamp,
      'updatedBy': _adminUid,
      'timeline/${eventRef.key}': {
        'type': type,
        'at': ServerValue.timestamp,
        'byUid': _adminUid,
        'byName': _adminName,
        'payload': payload,
      },
    };
    if (interviewAtMs != null) {
      updates['interviewAt'] = interviewAtMs;
    }
    await _ref.child(item.id).update(updates);
  }

  Future<void> _updateTimelineNote(
    _JobApplicationItem item,
    _TimelineEvent event,
    String note,
  ) async {
    await _ref.child(item.id).child('timeline').child(event.id).update({
      'payload/note': note,
      'at': ServerValue.timestamp,
      'byUid': _adminUid,
      'byName': _adminName,
    });
    await _ref.child(item.id).update({
      'updatedAt': ServerValue.timestamp,
      'updatedBy': _adminUid,
    });
  }

  Future<void> _clearTimelineNote(
    _JobApplicationItem item,
    _TimelineEvent event,
  ) async {
    await _ref.child(item.id).child('timeline').child(event.id).update({
      'payload/note': null,
      'at': ServerValue.timestamp,
      'byUid': _adminUid,
      'byName': _adminName,
    });
    await _ref.child(item.id).update({
      'updatedAt': ServerValue.timestamp,
      'updatedBy': _adminUid,
    });
  }

  Future<String?> _promptText({
    required String title,
    required String hint,
    bool requiredText = false,
    String initialValue = '',
  }) async {
    return _showSettledRootDialog<String>(
      builder: (dialogContext) => _JobApplicationTextPromptDialog(
        title: title,
        hint: hint,
        requiredText: requiredText,
        initialValue: initialValue,
      ),
    );
  }

  Future<void> _editTimelineNote(
    _JobApplicationItem item,
    _TimelineEvent event,
  ) async {
    final currentNote = (event.payload['note'] ?? '').toString().trim();
    final nextNote = await _promptText(
      title: 'Edit note',
      hint: 'Update note',
      requiredText: true,
      initialValue: currentNote,
    );
    if (!mounted || nextNote == null || nextNote == currentNote) return;
    await _updateTimelineNote(item, event, nextNote);
  }

  Future<void> _deleteTimelineNote(
    _JobApplicationItem item,
    _TimelineEvent event,
  ) async {
    final ok =
        await _showSettledRootDialog<bool>(
          builder: (dialogContext) => AlertDialog(
            title: const Text('Delete note?'),
            content: const Text(
              'This removes the note text and keeps the timeline event.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  FocusScope.of(dialogContext).unfocus();
                  Navigator.of(dialogContext, rootNavigator: true).pop(false);
                },
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  FocusScope.of(dialogContext).unfocus();
                  Navigator.of(dialogContext, rootNavigator: true).pop(true);
                },
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    await _clearTimelineNote(item, event);
  }

  Future<int?> _pickInterviewAtMs() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
      initialDate: now,
    );
    if (date == null) return null;
    if (!mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null) return null;
    return DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    ).millisecondsSinceEpoch;
  }

  Future<void> _setCallOutcome(
    _JobApplicationItem item, {
    required String outcome,
    required String stage,
  }) async {
    final note = await _promptText(
      title: 'Call note',
      hint: 'Optional note about this call',
    );
    if (!mounted) return;
    await _appendTimelineEvent(
      item,
      type: 'call_outcome',
      stage: stage,
      payload: {
        'outcome': outcome,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );
  }

  Future<void> _scheduleInterview(_JobApplicationItem item) async {
    final whenMs = await _pickInterviewAtMs();
    if (whenMs == null || !mounted) return;
    final note = await _promptText(
      title: 'Interview note',
      hint: 'Optional interview details',
    );
    if (!mounted) return;
    await _appendTimelineEvent(
      item,
      type: 'interview_scheduled',
      stage: 'interview_scheduled',
      interviewAtMs: whenMs,
      payload: {
        'interviewAt': whenMs,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );
  }

  Future<void> _markInterviewDone(_JobApplicationItem item) async {
    final outcome = await _showSettledRootDialog<_InterviewResultDialogValue>(
      builder: (dialogContext) => const _InterviewResultDialog(),
    );
    if (outcome == null || !mounted) return;

    await _appendTimelineEvent(
      item,
      type: 'interview_done',
      stage: 'interview_done',
      payload: {
        'result': outcome.result,
        if (outcome.note.isNotEmpty) 'note': outcome.note,
      },
    );
  }

  Future<void> _reject(_JobApplicationItem item) async {
    final reason = await _promptText(
      title: 'Reject application',
      hint: 'Reason for rejection',
      requiredText: true,
    );
    if (!mounted || reason == null || reason.trim().isEmpty) return;
    await _appendTimelineEvent(
      item,
      type: 'rejected',
      stage: 'rejected',
      payload: {'reason': reason.trim()},
    );
  }

  Future<void> _hire(_JobApplicationItem item) async {
    final note = await _promptText(
      title: 'Hire note',
      hint: 'Optional onboarding note',
    );
    if (!mounted) return;
    await _appendTimelineEvent(
      item,
      type: 'hired',
      stage: 'hired',
      payload: {if (note != null && note.isNotEmpty) 'note': note},
    );
  }

  Future<void> _setStage(_JobApplicationItem item, String stage) async {
    await _appendTimelineEvent(
      item,
      type: 'stage_changed',
      stage: stage,
      payload: {'from': item.stage, 'to': _normStage(stage)},
      interviewAtMs: stage == 'interview_scheduled'
          ? (item.interviewAt > 0 ? item.interviewAt : null)
          : null,
    );
  }

  Future<void> _setPriority(_JobApplicationItem item, String priority) async {
    await _ref.child(item.id).update({
      'priority': _normPriority(priority),
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _delete(_JobApplicationItem item) async {
    final ok =
        await _showSettledRootDialog<bool>(
          builder: (dialogContext) => AlertDialog(
            title: const Text('Delete application?'),
            content: Text(
              'Delete ${item.fullName.isEmpty ? item.id : item.fullName}?',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  FocusScope.of(dialogContext).unfocus();
                  Navigator.of(dialogContext, rootNavigator: true).pop(false);
                },
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  FocusScope.of(dialogContext).unfocus();
                  Navigator.of(dialogContext, rootNavigator: true).pop(true);
                },
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    await _ref.child(item.id).remove();
    if (!mounted) return;
    AppToast.fromSnackBar(
      context,
      const SnackBar(content: Text('Application deleted.')),
    );
  }

  Future<String?> _pickFromSheet({
    required String title,
    required String current,
    required List<MapEntry<String, String>> options,
  }) async {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _primaryBlue,
                  ),
                ),
              ),
            ),
            ...options.map((option) {
              final selected = option.key == current;
              return ListTile(
                dense: true,
                leading: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected ? _primaryBlue : Colors.black45,
                ),
                title: Text(option.value),
                onTap: () => Navigator.of(sheetContext).pop(option.key),
              );
            }),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Future<void> _showCopyShortcuts(_JobApplicationItem item) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Copy applicant details',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _primaryBlue,
                  ),
                ),
              ),
            ),
            ListTile(
              dense: true,
              enabled: item.fullName.trim().isNotEmpty,
              leading: const Icon(Icons.person_outline_rounded),
              title: const Text('Copy name'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _copy(item.fullName, 'Name');
              },
            ),
            ListTile(
              dense: true,
              enabled: item.phone.trim().isNotEmpty,
              leading: const Icon(Icons.call_rounded),
              title: const Text('Copy phone'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _copy(item.phone, 'Phone');
              },
            ),
            ListTile(
              dense: true,
              enabled: item.email.trim().isNotEmpty,
              leading: const Icon(Icons.email_outlined),
              title: const Text('Copy email'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _copy(item.email, 'Email');
              },
            ),
            ListTile(
              dense: true,
              enabled: item.position.trim().isNotEmpty,
              leading: const Icon(Icons.work_outline_rounded),
              title: const Text('Copy position'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _copy(item.position, 'Position');
              },
            ),
            ListTile(
              dense: true,
              enabled: item.cvPdfUrl.trim().isNotEmpty,
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('Copy CV URL'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _copy(item.cvPdfUrl, 'CV URL');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _cvKind(String url) {
    final low = url.trim().toLowerCase();
    if (low.isEmpty) return 'none';
    if (low.contains('.pdf') || low.contains('application/pdf')) return 'pdf';
    if (low.contains('.png') ||
        low.contains('.jpg') ||
        low.contains('.jpeg') ||
        low.contains('.webp') ||
        low.contains('image/')) {
      return 'image';
    }
    return 'unknown';
  }

  String _latestNote(_JobApplicationItem item) {
    for (final event in item.timeline) {
      final note = (event.payload['note'] ?? '').toString().trim();
      if (note.isNotEmpty) return note;
    }
    return '';
  }

  String _timelineNotesCompact(_JobApplicationItem item) {
    final out = <String>[];
    for (final event in item.timeline) {
      final note = (event.payload['note'] ?? '').toString().trim();
      if (note.isEmpty) continue;
      out.add('${event.type.replaceAll('_', ' ')}: $note');
      if (out.length >= 3) break;
    }
    return out.join(' | ');
  }

  String _compactExportNote(_JobApplicationItem item) {
    String clip(String text) {
      final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (clean.isEmpty) return '';
      if (clean.length <= 72) return clean;
      return '${clean.substring(0, 72)}...';
    }

    final latest = clip(_latestNote(item));
    if (latest.isNotEmpty) return latest;
    final compact = clip(_timelineNotesCompact(item));
    return compact.isEmpty ? '-' : compact;
  }

  Future<void> _showApplicationDetails(_JobApplicationItem item) async {
    await _showSettledRootDialog<void>(
      builder: (dialogContext) => _JobApplicationDetailsDialog(
        item: item,
        stageLabel: _stageLabel(item.stage),
        stageColor: _stageColor(item.stage),
        fmtDate: _fmtDate,
        copy: _copy,
        callPhone: _callPhone,
        sendEmail: _sendEmail,
        openCv: _openPdf,
        latestNote: _latestNote(item),
        timelineNotes: _timelineNotesCompact(item),
        cvKind: _cvKind(item.cvPdfUrl),
      ),
    );
  }

  Future<String?> _pickExportScope() async {
    return _showSettledRootDialog<String>(
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export applications PDF'),
        content: const Text('Choose what to export.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext, rootNavigator: true).pop();
            },
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.of(dialogContext, rootNavigator: true).pop('all');
            },
            child: const Text('All applications'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext, rootNavigator: true).pop('filtered');
            },
            child: const Text('Filtered (Recommended)'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportApplicationsPdf() async {
    if (_exporting) return;
    final scope = await _pickExportScope();
    if (scope == null || !mounted) return;

    final source = scope == 'all' ? _lastAllItems : _lastFilteredItems;
    if (source.isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('No applications to export.')),
      );
      return;
    }

    setState(() => _exporting = true);
    try {
      final doc = pw.Document();
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp =
          '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}';
      final stageCounts = <String, int>{
        'new': 0,
        'called_reached': 0,
        'called_no_answer': 0,
        'callback_requested': 0,
        'interview_scheduled': 0,
        'interview_done': 0,
        'hired': 0,
        'rejected': 0,
      };
      for (final item in source) {
        final key = _normStage(item.stage);
        stageCounts[key] = (stageCounts[key] ?? 0) + 1;
      }

      final baseFont = await PdfGoogleFonts.notoSansRegular();
      final boldFont = await PdfGoogleFonts.notoSansBold();
      final arabicFont = await PdfGoogleFonts.notoNaskhArabicRegular();
      final arabicBoldFont = await PdfGoogleFonts.notoNaskhArabicBold();

      String safe(String value) {
        final v = value.trim();
        return v.isEmpty ? '-' : v;
      }

      final tableHeaders = <String>[
        '#',
        'Full Name',
        'Phone',
        'Email',
        'Position',
        'Stage',
        'Status',
        'Priority',
        'Submitted',
        'Interview',
        'Notes',
      ];

      final tableRows = <List<String>>[];
      for (var i = 0; i < source.length; i++) {
        final item = source[i];
        tableRows.add([
          '${i + 1}',
          safe(item.fullName.isEmpty ? 'Unnamed Applicant' : item.fullName),
          safe(item.phone),
          safe(item.email),
          safe(item.position),
          _stageLabel(item.stage),
          safe(item.status),
          safe(item.priority),
          _fmtDate(item.createdAt),
          item.interviewAt > 0 ? _fmtDate(item.interviewAt) : '-',
          _compactExportNote(item),
        ]);
      }

      bool hasArabic(String text) {
        return RegExp(
          r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]',
        ).hasMatch(text);
      }

      pw.Widget buildCell(
        String text, {
        bool isHeader = false,
        bool center = false,
        bool isName = false,
      }) {
        final arabicName = isName && hasArabic(text);
        final align = center
            ? pw.Alignment.center
            : (arabicName ? pw.Alignment.centerRight : pw.Alignment.centerLeft);
        final dir = arabicName ? pw.TextDirection.rtl : pw.TextDirection.ltr;
        return pw.Container(
          alignment: align,
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: pw.Directionality(
            textDirection: dir,
            child: pw.Text(
              text,
              style: pw.TextStyle(
                fontSize: isHeader ? 9 : 8,
                fontWeight: isHeader
                    ? pw.FontWeight.bold
                    : pw.FontWeight.normal,
                color: isHeader ? PdfColors.white : PdfColors.black,
              ),
            ),
          ),
        );
      }

      doc.addPage(
        pw.MultiPage(
          pageTheme: pw.PageTheme(
            pageFormat: PdfPageFormat.a4.landscape,
            margin: const pw.EdgeInsets.fromLTRB(24, 24, 24, 24),
            theme: pw.ThemeData.withFont(
              base: baseFont,
              bold: boldFont,
              fontFallback: [arabicFont, arabicBoldFont],
            ),
          ),
          build: (context) => [
            pw.Text(
              'Job Applications Export',
              style: pw.TextStyle(
                fontSize: 20,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.blue900,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'Generated: $stamp',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
            pw.Text(
              'Scope: ${scope == 'all' ? 'All applications' : 'Filtered applications'}',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 8),
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: PdfColors.blue50,
                borderRadius: pw.BorderRadius.circular(6),
                border: pw.Border.all(color: PdfColors.blue100),
              ),
              child: pw.Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  pw.Text(
                    'Total: ${source.length}',
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                  pw.Text('New: ${stageCounts['new'] ?? 0}'),
                  pw.Text(
                    'Called (Reached): ${stageCounts['called_reached'] ?? 0}',
                  ),
                  pw.Text(
                    'Called (No Answer): ${stageCounts['called_no_answer'] ?? 0}',
                  ),
                  pw.Text(
                    'Callback Requested: ${stageCounts['callback_requested'] ?? 0}',
                  ),
                  pw.Text(
                    'Interview Scheduled: ${stageCounts['interview_scheduled'] ?? 0}',
                  ),
                  pw.Text(
                    'Interview Done: ${stageCounts['interview_done'] ?? 0}',
                  ),
                  pw.Text('Hired: ${stageCounts['hired'] ?? 0}'),
                  pw.Text('Rejected: ${stageCounts['rejected'] ?? 0}'),
                ],
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.black, width: 0.6),
              columnWidths: {
                0: const pw.FixedColumnWidth(20),
                1: const pw.FlexColumnWidth(1.4),
                2: const pw.FlexColumnWidth(0.9),
                3: const pw.FlexColumnWidth(1.4),
                4: const pw.FlexColumnWidth(1.3),
                5: const pw.FlexColumnWidth(0.9),
                6: const pw.FlexColumnWidth(0.7),
                7: const pw.FlexColumnWidth(0.7),
                8: const pw.FlexColumnWidth(1.0),
                9: const pw.FlexColumnWidth(1.0),
                10: const pw.FlexColumnWidth(1.4),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.blue700),
                  children: [
                    for (var i = 0; i < tableHeaders.length; i++)
                      buildCell(
                        tableHeaders[i],
                        isHeader: true,
                        center: i == 0 || i == 6 || i == 7,
                      ),
                  ],
                ),
                ...List.generate(tableRows.length, (rowIndex) {
                  final row = tableRows[rowIndex];
                  return pw.TableRow(
                    decoration: pw.BoxDecoration(
                      color: rowIndex.isOdd
                          ? PdfColors.grey50
                          : PdfColors.white,
                    ),
                    children: [
                      for (var col = 0; col < row.length; col++)
                        buildCell(
                          row[col],
                          center: col == 0 || col == 6 || col == 7,
                          isName: col == 1,
                        ),
                    ],
                  );
                }),
              ],
            ),
          ],
        ),
      );

      final bytes = await doc.save();
      final fileName =
          'job_applications_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}.pdf';
      await Printing.layoutPdf(name: fileName, onLayout: (_) async => bytes);
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(context, SnackBar(content: Text(toHumanError(e))));
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  Future<void> _handleOverflowAction(
    String action,
    _JobApplicationItem item,
  ) async {
    switch (action) {
      case 'called_reached':
        await _setCallOutcome(
          item,
          outcome: 'reached',
          stage: 'called_reached',
        );
        break;
      case 'called_no_answer':
        await _setCallOutcome(
          item,
          outcome: 'no_answer',
          stage: 'called_no_answer',
        );
        break;
      case 'callback_requested':
        await _setCallOutcome(
          item,
          outcome: 'callback',
          stage: 'callback_requested',
        );
        break;
      case 'schedule_interview':
        await _scheduleInterview(item);
        break;
      case 'interview_done':
        await _markInterviewDone(item);
        break;
      case 'set_stage':
        final stage = await _pickFromSheet(
          title: 'Set stage',
          current: item.stage,
          options: _stageChoices,
        );
        if (stage != null && stage != item.stage) {
          await _setStage(item, stage);
        }
        break;
      case 'set_priority':
        final priority = await _pickFromSheet(
          title: 'Set priority',
          current: item.priority,
          options: _priorityChoices,
        );
        if (priority != null && priority != item.priority) {
          await _setPriority(item, priority);
        }
        break;
      case 'reject':
        await _reject(item);
        break;
      case 'hire':
        await _hire(item);
        break;
      case 'delete':
        await _delete(item);
        break;
    }
  }

  void _handleOverflowActionDeferred(String action, _JobApplicationItem item) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await _handleOverflowAction(action, item);
      } catch (e) {
        if (!mounted) return;
        AppToast.fromSnackBar(
          context,
          SnackBar(content: Text(toHumanError(e))),
        );
      }
    });
  }

  String _fmtDate(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Color _priorityColor(String p) {
    switch (p) {
      case 'high':
        return Colors.red;
      case 'medium':
        return _actionOrange;
      case 'low':
        return Colors.green;
      default:
        return _actionOrange;
    }
  }

  Color _stageColor(String stage) {
    switch (_normStage(stage)) {
      case 'new':
        return _primaryBlue;
      case 'called_reached':
        return Colors.green.shade700;
      case 'called_no_answer':
        return Colors.orange.shade800;
      case 'callback_requested':
        return Colors.deepOrange;
      case 'interview_scheduled':
        return Colors.blue.shade700;
      case 'interview_done':
        return Colors.teal.shade700;
      case 'rejected':
        return Colors.red.shade700;
      case 'hired':
        return Colors.green.shade900;
      default:
        return _primaryBlue;
    }
  }

  ButtonStyle _compactActionButtonStyle() {
    return OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    );
  }

  int get _activeFilterCount {
    var count = 0;
    if (_stageFilter != 'all') count++;
    if (_priorityFilter != 'all') count++;
    return count;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _appBg,
      appBar: AppBar(
        title: const Text('Job Applications'),
        backgroundColor: Colors.white,
        foregroundColor: _primaryBlue,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _exporting ? null : _exportApplicationsPdf,
              icon: _exporting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.picture_as_pdf_rounded, size: 18),
              label: Text(_exporting ? 'Exporting...' : 'Export PDF'),
            ),
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1660,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: Column(
                children: [
                  TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      hintText: 'Search by name, phone, email, position, id',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _query.trim().isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        setState(() => _filtersExpanded = !_filtersExpanded);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _uiBorder),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.tune_rounded,
                              size: 18,
                              color: _primaryBlue,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'Filters',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: _primaryBlue,
                              ),
                            ),
                            const Spacer(),
                            if (_activeFilterCount > 0)
                              GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _stageFilter = 'all';
                                    _priorityFilter = 'all';
                                  });
                                },
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Text(
                                    'Clear',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.blue.shade700,
                                    ),
                                  ),
                                ),
                              ),
                            if (_activeFilterCount > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: _actionOrange.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '$_activeFilterCount active',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: _actionOrange,
                                  ),
                                ),
                              ),
                            const SizedBox(width: 8),
                            Icon(
                              _filtersExpanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              color: Colors.black54,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  AnimatedCrossFade(
                    firstChild: const SizedBox.shrink(),
                    secondChild: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 700;
                          if (compact) {
                            return Column(
                              children: [
                                DropdownButtonFormField<String>(
                                  initialValue: _stageFilter,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: 'Stage',
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'all',
                                      child: Text('All'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'new',
                                      child: Text('New'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'called_reached',
                                      child: Text('Called (Reached)'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'called_no_answer',
                                      child: Text('Called (No Answer)'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'callback_requested',
                                      child: Text('Call Back Requested'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'interview_scheduled',
                                      child: Text('Interview Scheduled'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'interview_done',
                                      child: Text('Interview Done'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'rejected',
                                      child: Text('Rejected'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'hired',
                                      child: Text('Hired'),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    if (v == null) return;
                                    setState(() => _stageFilter = v);
                                  },
                                ),
                                const SizedBox(height: 6),
                                DropdownButtonFormField<String>(
                                  initialValue: _priorityFilter,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: 'Priority',
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'all',
                                      child: Text('All'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'high',
                                      child: Text('High'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'medium',
                                      child: Text('Medium'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'low',
                                      child: Text('Low'),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    if (v == null) return;
                                    setState(() => _priorityFilter = v);
                                  },
                                ),
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: _stageFilter,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: 'Stage',
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'all',
                                      child: Text('All'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'new',
                                      child: Text('New'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'called_reached',
                                      child: Text('Called (Reached)'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'called_no_answer',
                                      child: Text('Called (No Answer)'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'callback_requested',
                                      child: Text('Call Back Requested'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'interview_scheduled',
                                      child: Text('Interview Scheduled'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'interview_done',
                                      child: Text('Interview Done'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'rejected',
                                      child: Text('Rejected'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'hired',
                                      child: Text('Hired'),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    if (v == null) return;
                                    setState(() => _stageFilter = v);
                                  },
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: _priorityFilter,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText: 'Priority',
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'all',
                                      child: Text('All'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'high',
                                      child: Text('High'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'medium',
                                      child: Text('Medium'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'low',
                                      child: Text('Low'),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    if (v == null) return;
                                    setState(() => _priorityFilter = v);
                                  },
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    crossFadeState: _filtersExpanded
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    duration: const Duration(milliseconds: 170),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<DatabaseEvent>(
                stream: _ref.onValue,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(
                      child: Text(
                        toHumanError(
                          snap.error ?? Exception('Stream error'),
                          fallback: 'Could not load job applications.',
                        ),
                      ),
                    );
                  }

                  final allItems = _parseItems(snap.data?.snapshot.value);
                  final items = _filtered(allItems);
                  _lastAllItems = allItems;
                  _lastFilteredItems = items;
                  if (items.isEmpty) {
                    return const Center(
                      child: Text('No job applications found.'),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final displayName = item.fullName.isEmpty
                          ? 'Unnamed Applicant'
                          : item.fullName;

                      return Material(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _showApplicationDetails(item),
                          onLongPress: () => _showCopyShortcuts(item),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: _uiBorder),
                            ),
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: _primaryBlue,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: 'Actions',
                                      icon: const Icon(Icons.more_vert_rounded),
                                      onSelected: (v) {
                                        _handleOverflowActionDeferred(v, item);
                                      },
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'called_reached',
                                          child: Text('Called: Reached'),
                                        ),
                                        PopupMenuItem(
                                          value: 'called_no_answer',
                                          child: Text('Called: No Answer'),
                                        ),
                                        PopupMenuItem(
                                          value: 'callback_requested',
                                          child: Text('Call Back Requested'),
                                        ),
                                        PopupMenuItem(
                                          value: 'schedule_interview',
                                          child: Text('Schedule Interview'),
                                        ),
                                        PopupMenuItem(
                                          value: 'interview_done',
                                          child: Text('Interview Done'),
                                        ),
                                        PopupMenuDivider(),
                                        PopupMenuItem(
                                          value: 'set_stage',
                                          child: Text('Set Stage'),
                                        ),
                                        PopupMenuItem(
                                          value: 'set_priority',
                                          child: Text('Set Priority'),
                                        ),
                                        PopupMenuDivider(),
                                        PopupMenuItem(
                                          value: 'reject',
                                          child: Text('Reject'),
                                        ),
                                        PopupMenuItem(
                                          value: 'hire',
                                          child: Text('Hire'),
                                        ),
                                        PopupMenuDivider(),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Delete'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    _pill(
                                      _stageLabel(item.stage),
                                      bg: _stageColor(
                                        item.stage,
                                      ).withValues(alpha: 0.14),
                                      fg: _stageColor(item.stage),
                                    ),
                                    _pill(
                                      'Priority: ${item.priority}',
                                      bg: _priorityColor(
                                        item.priority,
                                      ).withValues(alpha: 0.12),
                                      fg: _priorityColor(item.priority),
                                    ),
                                    _pill(
                                      item.isGuest ? 'Guest' : 'User',
                                      bg: _actionOrange.withValues(alpha: 0.10),
                                      fg: _actionOrange,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  item.position.isEmpty
                                      ? 'Position: -'
                                      : 'Position: ${item.position}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Submitted: ${_fmtDate(item.createdAt)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black54,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  item.interviewAt > 0
                                      ? 'Interview: ${_fmtDate(item.interviewAt)}'
                                      : 'Interview: -',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black54,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    OutlinedButton.icon(
                                      style: _compactActionButtonStyle(),
                                      onPressed: item.phone.isEmpty
                                          ? null
                                          : () => _callPhone(item.phone),
                                      icon: const Icon(
                                        Icons.call_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('Call'),
                                    ),
                                    OutlinedButton.icon(
                                      style: _compactActionButtonStyle(),
                                      onPressed: item.email.isEmpty
                                          ? null
                                          : () => _sendEmail(item.email),
                                      icon: const Icon(
                                        Icons.email_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('Email'),
                                    ),
                                    OutlinedButton.icon(
                                      style: _compactActionButtonStyle(),
                                      onPressed: item.cvPdfUrl.isEmpty
                                          ? null
                                          : () => _openPdf(item.cvPdfUrl),
                                      icon: const Icon(
                                        Icons.picture_as_pdf_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('Open CV'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                ExpansionTile(
                                  dense: true,
                                  initiallyExpanded: false,
                                  maintainState: false,
                                  tilePadding: EdgeInsets.zero,
                                  childrenPadding: const EdgeInsets.only(
                                    left: 2,
                                    right: 2,
                                    bottom: 2,
                                  ),
                                  title: Text(
                                    'Timeline (${item.timeline.length})',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                  children: item.timeline.isEmpty
                                      ? const [
                                          Align(
                                            alignment: Alignment.centerLeft,
                                            child: Padding(
                                              padding: EdgeInsets.only(
                                                bottom: 8,
                                              ),
                                              child: Text(
                                                'No timeline events yet.',
                                              ),
                                            ),
                                          ),
                                        ]
                                      : item.timeline.map((event) {
                                          final note =
                                              (event.payload['note'] ?? '')
                                                  .toString()
                                                  .trim();
                                          final outcome =
                                              (event.payload['outcome'] ?? '')
                                                  .toString()
                                                  .trim();
                                          final result =
                                              (event.payload['result'] ?? '')
                                                  .toString()
                                                  .trim();
                                          final reason =
                                              (event.payload['reason'] ?? '')
                                                  .toString()
                                                  .trim();
                                          final interviewAt = _toInt(
                                            event.payload['interviewAt'],
                                          );

                                          String details = '';
                                          if (outcome.isNotEmpty) {
                                            details = 'Outcome: $outcome';
                                          }
                                          if (result.isNotEmpty) {
                                            details = details.isEmpty
                                                ? 'Result: $result'
                                                : '$details • Result: $result';
                                          }
                                          if (interviewAt > 0) {
                                            details = details.isEmpty
                                                ? 'Interview: ${_fmtDate(interviewAt)}'
                                                : '$details • Interview: ${_fmtDate(interviewAt)}';
                                          }
                                          if (reason.isNotEmpty) {
                                            details = details.isEmpty
                                                ? 'Reason: $reason'
                                                : '$details • Reason: $reason';
                                          }
                                          if (note.isNotEmpty) {
                                            details = details.isEmpty
                                                ? note
                                                : '$details • $note';
                                          }

                                          final actor = event.byName.isNotEmpty
                                              ? event.byName
                                              : (event.byUid.isNotEmpty
                                                    ? event.byUid
                                                    : 'Admin');
                                          final hasNote = note.isNotEmpty;

                                          return ListTile(
                                            dense: true,
                                            contentPadding: EdgeInsets.zero,
                                            title: Text(
                                              event.type.replaceAll('_', ' '),
                                            ),
                                            subtitle: Text(
                                              '${_fmtDate(event.at)} • $actor${details.isEmpty ? '' : '\n$details'}',
                                            ),
                                            trailing: hasNote
                                                ? Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      IconButton(
                                                        tooltip: 'Edit note',
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                        onPressed: () =>
                                                            _editTimelineNote(
                                                              item,
                                                              event,
                                                            ),
                                                        icon: const Icon(
                                                          Icons.edit_rounded,
                                                          size: 20,
                                                        ),
                                                      ),
                                                      IconButton(
                                                        tooltip: 'Delete note',
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                        onPressed: () =>
                                                            _deleteTimelineNote(
                                                              item,
                                                              event,
                                                            ),
                                                        icon: const Icon(
                                                          Icons
                                                              .delete_outline_rounded,
                                                          size: 20,
                                                        ),
                                                      ),
                                                    ],
                                                  )
                                                : null,
                                          );
                                        }).toList(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _pill(String label, {required Color bg, required Color fg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: fg),
      ),
    );
  }
}

class _JobApplicationItem {
  const _JobApplicationItem({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.email,
    required this.position,
    required this.cvPdfUrl,
    required this.stage,
    required this.status,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
    required this.updatedBy,
    required this.interviewAt,
    required this.timeline,
    required this.isGuest,
    required this.submittedByUid,
  });

  final String id;
  final String fullName;
  final String phone;
  final String email;
  final String position;
  final String cvPdfUrl;
  final String stage;
  final String status;
  final String priority;
  final int createdAt;
  final int updatedAt;
  final String updatedBy;
  final int interviewAt;
  final List<_TimelineEvent> timeline;
  final bool isGuest;
  final String submittedByUid;
}

class _JobApplicationTextPromptDialog extends StatefulWidget {
  const _JobApplicationTextPromptDialog({
    required this.title,
    required this.hint,
    required this.requiredText,
    required this.initialValue,
  });

  final String title;
  final String hint;
  final bool requiredText;
  final String initialValue;

  @override
  State<_JobApplicationTextPromptDialog> createState() =>
      _JobApplicationTextPromptDialogState();
}

class _JobApplicationTextPromptDialogState
    extends State<_JobApplicationTextPromptDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        maxLines: 3,
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            FocusScope.of(context).unfocus();
            await Future<void>.delayed(Duration.zero);
            if (!context.mounted) return;
            Navigator.of(context, rootNavigator: true).pop(null);
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            FocusScope.of(context).unfocus();
            final text = _controller.text.trim();
            if (widget.requiredText && text.isEmpty) return;
            await Future<void>.delayed(Duration.zero);
            if (!context.mounted) return;
            Navigator.of(context, rootNavigator: true).pop(text);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _InterviewResultDialogValue {
  const _InterviewResultDialogValue({required this.result, required this.note});

  final String result;
  final String note;
}

class _InterviewResultDialog extends StatefulWidget {
  const _InterviewResultDialog();

  @override
  State<_InterviewResultDialog> createState() => _InterviewResultDialogState();
}

class _InterviewResultDialogState extends State<_InterviewResultDialog> {
  String _result = 'pass';
  late final TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Interview result'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _result,
            decoration: const InputDecoration(labelText: 'Result'),
            items: const [
              DropdownMenuItem(value: 'pass', child: Text('Pass')),
              DropdownMenuItem(value: 'fail', child: Text('Fail')),
              DropdownMenuItem(value: 'hold', child: Text('Hold')),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _result = v);
            },
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _noteController,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Optional note'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            FocusScope.of(context).unfocus();
            await Future<void>.delayed(Duration.zero);
            if (!context.mounted) return;
            Navigator.of(context, rootNavigator: true).pop();
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            FocusScope.of(context).unfocus();
            await Future<void>.delayed(Duration.zero);
            if (!context.mounted) return;
            Navigator.of(context, rootNavigator: true).pop(
              _InterviewResultDialogValue(
                result: _result,
                note: _noteController.text.trim(),
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _TimelineEvent {
  const _TimelineEvent({
    required this.id,
    required this.type,
    required this.at,
    required this.byUid,
    required this.byName,
    required this.payload,
  });

  final String id;
  final String type;
  final int at;
  final String byUid;
  final String byName;
  final Map<String, dynamic> payload;
}

class _JobApplicationDetailsDialog extends StatelessWidget {
  const _JobApplicationDetailsDialog({
    required this.item,
    required this.stageLabel,
    required this.stageColor,
    required this.fmtDate,
    required this.copy,
    required this.callPhone,
    required this.sendEmail,
    required this.openCv,
    required this.latestNote,
    required this.timelineNotes,
    required this.cvKind,
  });

  final _JobApplicationItem item;
  final String stageLabel;
  final Color stageColor;
  final String Function(int) fmtDate;
  final Future<void> Function(String, String) copy;
  final Future<void> Function(String) callPhone;
  final Future<void> Function(String) sendEmail;
  final Future<void> Function(String) openCv;
  final String latestNote;
  final String timelineNotes;
  final String cvKind;

  Widget _copyTile({
    required String label,
    required String value,
    IconData? icon,
  }) {
    final clean = value.trim();
    return ListTile(
      dense: true,
      enabled: clean.isNotEmpty,
      leading: Icon(icon ?? Icons.copy_rounded),
      title: Text(label),
      subtitle: Text(clean.isEmpty ? '-' : clean),
      trailing: clean.isEmpty ? null : const Icon(Icons.content_copy_rounded),
      onTap: clean.isEmpty ? null : () => copy(clean, label),
    );
  }

  Widget _buildCvPreview() {
    final cvUrl = item.cvPdfUrl.trim();
    if (cvUrl.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(10),
        child: Text('No CV uploaded.'),
      );
    }

    if (cvKind == 'pdf') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 300,
          child: SfPdfViewer.network(
            cvUrl,
            canShowScrollHead: true,
            canShowPaginationDialog: true,
          ),
        ),
      );
    }

    if (cvKind == 'image' || cvKind == 'unknown') {
      return SizedBox(
        height: 300,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: InteractiveViewer(
            maxScale: 5,
            child: Image.network(
              cvUrl,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Container(
                color: Colors.black12,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(12),
                child: const Text(
                  'Could not preview this file inline. Use Open Externally.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return const Padding(
      padding: EdgeInsets.all(10),
      child: Text('Preview not available for this file type.'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(item.fullName.isEmpty ? 'Unnamed Applicant' : item.fullName),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _copyTile(
                label: 'Application ID',
                value: item.id,
                icon: Icons.badge_outlined,
              ),
              _copyTile(
                label: 'Phone',
                value: item.phone,
                icon: Icons.call_rounded,
              ),
              _copyTile(
                label: 'Email',
                value: item.email,
                icon: Icons.email_outlined,
              ),
              _copyTile(
                label: 'Position',
                value: item.position,
                icon: Icons.work_outline_rounded,
              ),
              _copyTile(
                label: 'Stage',
                value: stageLabel,
                icon: Icons.flag_rounded,
              ),
              _copyTile(
                label: 'Status',
                value: item.status,
                icon: Icons.info_outline_rounded,
              ),
              _copyTile(
                label: 'Priority',
                value: item.priority,
                icon: Icons.priority_high_rounded,
              ),
              _copyTile(
                label: 'Latest Note',
                value: latestNote,
                icon: Icons.notes_rounded,
              ),
              _copyTile(
                label: 'Timeline Notes',
                value: timelineNotes,
                icon: Icons.history_rounded,
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.calendar_today_rounded),
                title: const Text('Submitted'),
                subtitle: Text(fmtDate(item.createdAt)),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.event_available_rounded),
                title: const Text('Interview'),
                subtitle: Text(
                  item.interviewAt > 0 ? fmtDate(item.interviewAt) : '-',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: stageColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      stageLabel,
                      style: TextStyle(
                        color: stageColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'CV Preview',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              _buildCvPreview(),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: item.cvPdfUrl.trim().isEmpty
                        ? null
                        : () => copy(item.cvPdfUrl, 'CV URL'),
                    icon: const Icon(Icons.content_copy_rounded),
                    label: const Text('Copy CV URL'),
                  ),
                  OutlinedButton.icon(
                    onPressed: item.cvPdfUrl.trim().isEmpty
                        ? null
                        : () => openCv(item.cvPdfUrl),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Open Externally'),
                  ),
                  OutlinedButton.icon(
                    onPressed: item.phone.trim().isEmpty
                        ? null
                        : () => callPhone(item.phone),
                    icon: const Icon(Icons.call_rounded),
                    label: const Text('Call'),
                  ),
                  OutlinedButton.icon(
                    onPressed: item.email.trim().isEmpty
                        ? null
                        : () => sendEmail(item.email),
                    icon: const Icon(Icons.email_rounded),
                    label: const Text('Email'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop();
          },
          child: const Text('Close'),
        ),
      ],
    );
  }
}
