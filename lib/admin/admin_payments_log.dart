import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/admin_web_layout.dart';
import '../shared/admin_tour_guide.dart';
import '../shared/screen_help_guide.dart';

class AdminPaymentsLogScreen extends StatefulWidget {
  const AdminPaymentsLogScreen({super.key});

  static const primaryBlue = Color(0xFF1A2B48);
  static const appBg = Color(0xFFF4F7F9);

  @override
  State<AdminPaymentsLogScreen> createState() => _AdminPaymentsLogScreenState();
}

class _AdminPaymentsLogScreenState extends State<AdminPaymentsLogScreen> {
  final _db = FirebaseDatabase.instance;
  static const int _paymentsWindowSize = 3000;
  String _search = '';

  DatabaseReference get _paymentsRef => _db.ref('payments');

  @override
  Widget build(BuildContext context) {
    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_payments_log',
      title: 'سجل المدفوعات',
      line: 'يعرض هذا القسم سجل العمليات المالية للمتابعة والمراجعة.',
    );

    return Scaffold(
      backgroundColor: AdminPaymentsLogScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(
          color: AdminPaymentsLogScreen.primaryBlue,
        ),
        title: const Text(
          'Payments Log',
          style: TextStyle(
            color: AdminPaymentsLogScreen.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [const SizedBox.shrink()],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1650,
        child: Column(
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                decoration: InputDecoration(
                  hintText: 'Search (learner uid / course code / title)…',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: AdminPaymentsLogScreen.appBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<DatabaseEvent>(
                stream: _paymentsRef
                    .orderByChild('paidAt')
                    .limitToLast(_paymentsWindowSize)
                    .onValue,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(child: Text('Error loading payments.'));
                  }
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final v = snapshot.data?.snapshot.value;
                  final list = <Map<String, dynamic>>[];

                  if (v is Map) {
                    v.forEach((k, val) {
                      if (val is Map) {
                        final m = val.map(
                          (kk, vv) => MapEntry(kk.toString(), vv),
                        );
                        m['paymentId'] = k.toString();
                        list.add(m.cast<String, dynamic>());
                      }
                    });
                  }

                  // Sort newest first
                  list.sort(
                    (a, b) => (b['paidAt'] as int? ?? 0).compareTo(
                      a['paidAt'] as int? ?? 0,
                    ),
                  );

                  final s = _search.trim().toLowerCase();
                  final filtered = s.isEmpty
                      ? list
                      : list.where((p) {
                          final uid = (p['uid'] ?? '').toString().toLowerCase();
                          final code = (p['course_code'] ?? '')
                              .toString()
                              .toLowerCase();
                          final title = (p['course_title'] ?? '')
                              .toString()
                              .toLowerCase();
                          return uid.contains(s) ||
                              code.contains(s) ||
                              title.contains(s);
                        }).toList();

                  if (filtered.isEmpty) {
                    return const Center(child: Text('No payments found.'));
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final p = filtered[i];
                      final amount = p['amount'];
                      final sessionsPaid = p['sessionsPaid'];
                      final code = (p['course_code'] ?? '').toString();
                      final title = (p['course_title'] ?? '').toString();
                      final uid = (p['uid'] ?? '').toString();
                      final variantKey = (p['variantKey'] ?? '')
                          .toString()
                          .trim();
                      final studyTypeText = _studyTypeText(p);
                      final usesSessions = _variantUsesSessions(variantKey);
                      return Card(
                        elevation: 0,
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '$code — $title',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: AdminPaymentsLogScreen.primaryBlue,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Learner UID: $uid',
                                style: TextStyle(
                                  color: Colors.black.withValues(alpha: 0.7),
                                ),
                              ),
                              if (studyTypeText.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  'Study type: $studyTypeText',
                                  style: TextStyle(
                                    color: Colors.black.withValues(alpha: 0.7),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _pill('Amount: $amount'),
                                  if (usesSessions)
                                    _pill('Sessions paid: $sessionsPaid'),
                                  if ((p['method'] ?? '')
                                      .toString()
                                      .trim()
                                      .isNotEmpty)
                                    _pill('Method: ${p['method']}'),
                                ],
                              ),
                              if ((p['notes'] ?? '')
                                  .toString()
                                  .trim()
                                  .isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Text(
                                  'Notes: ${p['notes']}',
                                  style: TextStyle(
                                    color: Colors.black.withValues(alpha: 0.7),
                                  ),
                                ),
                              ],
                            ],
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

  static String _normalizeVariantKey(String raw) {
    final v = raw.trim().toLowerCase();

    switch (v) {
      case 'inclass':
      case 'in_class':
      case 'in-class':
      case 'in class':
        return 'inclass';

      case 'flexible':
      case 'online':
        return 'flexible';

      case 'private':
      case 'vip':
      case 'live':
        return 'private';

      case 'recorded':
        return 'recorded';

      default:
        return v;
    }
  }

  static bool _variantUsesSessions(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private' || v == 'flexible';
  }

  static String _studyTypeText(Map<String, dynamic> p) {
    final variantLabel = (p['variantLabel'] ?? '').toString().trim();
    if (variantLabel.isNotEmpty) return variantLabel;

    final studyModeLabel = (p['studyModeLabel'] ?? '').toString().trim();
    final studyMode = (p['studyMode'] ?? '').toString().trim();
    final variantKey = (p['variantKey'] ?? '').toString().trim();

    if (studyModeLabel.isNotEmpty) return studyModeLabel;
    if (studyMode.isNotEmpty) return studyMode;
    return variantKey;
  }

  static Widget _pill(String t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AdminPaymentsLogScreen.appBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        t,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AdminPaymentsLogScreen.primaryBlue,
        ),
      ),
    );
  }
}
