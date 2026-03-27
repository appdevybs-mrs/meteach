import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import '../shared/screen_help_guide.dart';

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
  String _statusFilter = 'all';
  String _priorityFilter = 'all';

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

      out.add(
        _JobApplicationItem(
          id: key.toString(),
          fullName: (m['full_name'] ?? '').toString().trim(),
          phone: (m['phone'] ?? '').toString().trim(),
          email: (m['email'] ?? '').toString().trim(),
          position: (m['position'] ?? '').toString().trim(),
          cvPdfUrl: (m['cv_pdf_url'] ?? '').toString().trim(),
          status: _normStatus((m['status'] ?? '').toString()),
          priority: _normPriority((m['priority'] ?? '').toString()),
          createdAt: _toInt(m['createdAt']),
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
      if (_statusFilter != 'all' && item.status != _statusFilter) return false;
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

  Future<void> _setStatus(_JobApplicationItem item, String status) async {
    await _ref.child(item.id).update({
      'status': _normStatus(status),
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _setPriority(_JobApplicationItem item, String priority) async {
    await _ref.child(item.id).update({
      'priority': _normPriority(priority),
      'updatedAt': ServerValue.timestamp,
    });
  }

  Future<void> _delete(_JobApplicationItem item) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete application?'),
            content: Text(
              'Delete ${item.fullName.isEmpty ? item.id : item.fullName}?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
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
          IconButton(
            tooltip: 'Help / Instructions',
            onPressed: () => ScreenHelpGuide.show(
              context,
              role: GuideRole.admin,
              screenId: 'admin_job_applications',
              screenTitle: 'Job Applications',
            ),
            icon: const Icon(Icons.help_outline_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Column(
              children: [
                TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
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
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _statusFilter,
                        decoration: InputDecoration(
                          labelText: 'Status',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          fillColor: Colors.white,
                        ),
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('All')),
                          DropdownMenuItem(value: 'new', child: Text('New')),
                          DropdownMenuItem(
                            value: 'reviewed',
                            child: Text('Reviewed'),
                          ),
                          DropdownMenuItem(
                            value: 'shortlisted',
                            child: Text('Shortlisted'),
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
                          setState(() => _statusFilter = v);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _priorityFilter,
                        decoration: InputDecoration(
                          labelText: 'Priority',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          fillColor: Colors.white,
                        ),
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('All')),
                          DropdownMenuItem(value: 'high', child: Text('High')),
                          DropdownMenuItem(
                            value: 'medium',
                            child: Text('Medium'),
                          ),
                          DropdownMenuItem(value: 'low', child: Text('Low')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _priorityFilter = v);
                        },
                      ),
                    ),
                  ],
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

                final items = _filtered(_parseItems(snap.data?.snapshot.value));
                if (items.isEmpty) {
                  return const Center(
                    child: Text('No job applications found.'),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
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
                        onLongPress: () => _copy(item.cvPdfUrl, 'CV URL'),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: _uiBorder),
                          ),
                          padding: const EdgeInsets.all(12),
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
                                    onSelected: (v) async {
                                      try {
                                        switch (v) {
                                          case 'copy_name':
                                            await _copy(item.fullName, 'Name');
                                          case 'copy_phone':
                                            await _copy(item.phone, 'Phone');
                                          case 'copy_email':
                                            await _copy(item.email, 'Email');
                                          case 'copy_position':
                                            await _copy(
                                              item.position,
                                              'Position',
                                            );
                                          case 'copy_cv':
                                            await _copy(
                                              item.cvPdfUrl,
                                              'CV URL',
                                            );
                                          case 'delete':
                                            await _delete(item);
                                        }
                                      } catch (e) {
                                        if (!mounted) return;
                                        AppToast.fromSnackBar(
                                          context,
                                          SnackBar(
                                            content: Text(toHumanError(e)),
                                          ),
                                        );
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'copy_name',
                                        child: Text('Copy Name'),
                                      ),
                                      PopupMenuItem(
                                        value: 'copy_phone',
                                        child: Text('Copy Phone'),
                                      ),
                                      PopupMenuItem(
                                        value: 'copy_email',
                                        child: Text('Copy Email'),
                                      ),
                                      PopupMenuItem(
                                        value: 'copy_position',
                                        child: Text('Copy Position'),
                                      ),
                                      PopupMenuItem(
                                        value: 'copy_cv',
                                        child: Text('Copy CV URL'),
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
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _pill(
                                    '${item.status[0].toUpperCase()}${item.status.substring(1)}',
                                    bg: _primaryBlue.withValues(alpha: 0.10),
                                    fg: _primaryBlue,
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
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
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
                              Row(
                                children: [
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      initialValue: item.status,
                                      decoration: const InputDecoration(
                                        labelText: 'Status',
                                        isDense: true,
                                      ),
                                      items: const [
                                        DropdownMenuItem(
                                          value: 'new',
                                          child: Text('New'),
                                        ),
                                        DropdownMenuItem(
                                          value: 'reviewed',
                                          child: Text('Reviewed'),
                                        ),
                                        DropdownMenuItem(
                                          value: 'shortlisted',
                                          child: Text('Shortlisted'),
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
                                      onChanged: (v) async {
                                        if (v == null) return;
                                        try {
                                          await _setStatus(item, v);
                                        } catch (e) {
                                          if (!mounted) return;
                                          AppToast.fromSnackBar(
                                            context,
                                            SnackBar(
                                              content: Text(toHumanError(e)),
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      initialValue: item.priority,
                                      decoration: const InputDecoration(
                                        labelText: 'Priority',
                                        isDense: true,
                                      ),
                                      items: const [
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
                                      onChanged: (v) async {
                                        if (v == null) return;
                                        try {
                                          await _setPriority(item, v);
                                        } catch (e) {
                                          if (!mounted) return;
                                          AppToast.fromSnackBar(
                                            context,
                                            SnackBar(
                                              content: Text(toHumanError(e)),
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                  ),
                                ],
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
    required this.status,
    required this.priority,
    required this.createdAt,
    required this.isGuest,
    required this.submittedByUid,
  });

  final String id;
  final String fullName;
  final String phone;
  final String email;
  final String position;
  final String cvPdfUrl;
  final String status;
  final String priority;
  final int createdAt;
  final bool isGuest;
  final String submittedByUid;
}
