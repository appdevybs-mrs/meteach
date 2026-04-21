import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/admin_web_layout.dart';

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
  static const String _viewCurrent = 'current';
  static const String _viewArchive = 'archive';
  static const String _legacyArchivePrefix = '__legacy_month__:';

  String _search = '';
  String _selectedView = _viewCurrent;
  String? _selectedArchiveBucketId;

  DatabaseReference get _paymentsRef => _db.ref('payments');
  DatabaseReference get _paymentPeriodsRef => _db.ref('payment_periods');

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DatabaseEvent>(
      stream: _paymentPeriodsRef.onValue,
      builder: (context, periodsSnap) {
        if (periodsSnap.hasError) {
          return const Scaffold(
            body: Center(child: Text('Error loading payment periods.')),
          );
        }

        final periods = <_PaymentPeriodRecord>[];
        final rawPeriods = periodsSnap.data?.snapshot.value;
        if (rawPeriods is Map) {
          rawPeriods.forEach((k, value) {
            if (value is! Map) return;
            final m = value.map((kk, vv) => MapEntry(kk.toString(), vv));
            periods.add(
              _PaymentPeriodRecord.fromMap(
                id: k.toString(),
                map: m.cast<String, dynamic>(),
              ),
            );
          });
        }
        periods.sort((a, b) => b.startAtMs.compareTo(a.startAtMs));

        _PaymentPeriodRecord? activePeriod;
        final closedPeriods = <_PaymentPeriodRecord>[];
        for (final period in periods) {
          if (period.isActive && activePeriod == null) {
            activePeriod = period;
          } else {
            closedPeriods.add(period);
          }
        }

        return StreamBuilder<DatabaseEvent>(
          stream: _paymentsRef
              .orderByChild('paidAt')
              .limitToLast(_paymentsWindowSize)
              .onValue,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Scaffold(
                body: Center(child: Text('Error loading payments.')),
              );
            }
            if ((periodsSnap.connectionState == ConnectionState.waiting &&
                    !periodsSnap.hasData) ||
                (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData)) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            final raw = snapshot.data?.snapshot.value;
            final list = <Map<String, dynamic>>[];
            if (raw is Map) {
              raw.forEach((k, val) {
                if (val is Map) {
                  final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
                  m['paymentId'] = k.toString();
                  list.add(m.cast<String, dynamic>());
                }
              });
            }

            list.sort(
              (a, b) => _asInt(b['paidAt']).compareTo(_asInt(a['paidAt'])),
            );

            final legacyMonths = <String>{};
            for (final p in list) {
              if (_paymentPeriodId(p).isNotEmpty) continue;
              final monthKey = _monthKeyFromPayment(p);
              if (monthKey.isNotEmpty) legacyMonths.add(monthKey);
            }

            final sortedLegacyMonths = legacyMonths.toList()
              ..sort((a, b) => b.compareTo(a));
            final archiveBuckets = <_ArchiveBucket>[
              ...closedPeriods.map(
                (period) =>
                    _ArchiveBucket(id: period.id, label: period.displayLabel),
              ),
              ...sortedLegacyMonths.map(
                (monthKey) => _ArchiveBucket(
                  id: '$_legacyArchivePrefix$monthKey',
                  label: monthKey.isEmpty
                      ? 'Legacy payments'
                      : 'Legacy $monthKey',
                ),
              ),
            ];

            final archiveBucketIds = archiveBuckets.map((e) => e.id).toSet();
            if (_selectedArchiveBucketId != null &&
                !archiveBucketIds.contains(_selectedArchiveBucketId)) {
              _selectedArchiveBucketId = null;
            }
            if (_selectedView == _viewArchive &&
                _selectedArchiveBucketId == null &&
                archiveBuckets.isNotEmpty) {
              _selectedArchiveBucketId = archiveBuckets.first.id;
            }

            Iterable<Map<String, dynamic>> filtered;
            if (_selectedView == _viewCurrent) {
              filtered = activePeriod == null
                  ? const <Map<String, dynamic>>[]
                  : list.where((p) => _paymentPeriodId(p) == activePeriod!.id);
            } else {
              final bucketId = _selectedArchiveBucketId;
              filtered = bucketId == null
                  ? const <Map<String, dynamic>>[]
                  : list.where(
                      (p) => _archiveBucketIdForPayment(p) == bucketId,
                    );
            }

            final s = _search.trim().toLowerCase();
            if (s.isNotEmpty) {
              filtered = filtered.where((p) {
                final uid = (p['uid'] ?? '').toString().toLowerCase();
                final code = (p['course_code'] ?? '').toString().toLowerCase();
                final title = (p['course_title'] ?? '')
                    .toString()
                    .toLowerCase();
                final learnerName = (p['learner_name'] ?? '')
                    .toString()
                    .toLowerCase();
                return uid.contains(s) ||
                    code.contains(s) ||
                    title.contains(s) ||
                    learnerName.contains(s);
              });
            }

            final visible = filtered.toList();
            String scopeLabel =
                activePeriod?.displayLabel ?? 'No active period';
            if (_selectedView == _viewArchive) {
              scopeLabel = 'Archive';
              for (final bucket in archiveBuckets) {
                if (bucket.id == _selectedArchiveBucketId) {
                  scopeLabel = bucket.label;
                  break;
                }
              }
            }

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
              ),
              body: adminWebBodyFrame(
                context: context,
                maxWidth: 1650,
                child: Column(
                  children: [
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                      child: Column(
                        children: [
                          TextField(
                            onChanged: (v) => setState(() => _search = v),
                            decoration: InputDecoration(
                              hintText:
                                  'Search (learner / uid / course code / title)…',
                              prefixIcon: const Icon(Icons.search),
                              filled: true,
                              fillColor: AdminPaymentsLogScreen.appBg,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                ChoiceChip(
                                  label: const Text('Current'),
                                  selected: _selectedView == _viewCurrent,
                                  onSelected: (_) {
                                    setState(() {
                                      _selectedView = _viewCurrent;
                                    });
                                  },
                                ),
                                const SizedBox(width: 8),
                                ChoiceChip(
                                  label: const Text('Archive'),
                                  selected: _selectedView == _viewArchive,
                                  onSelected: (_) {
                                    setState(() {
                                      _selectedView = _viewArchive;
                                      _selectedArchiveBucketId ??=
                                          archiveBuckets.isEmpty
                                          ? null
                                          : archiveBuckets.first.id;
                                    });
                                  },
                                ),
                                const SizedBox(width: 10),
                                if (_selectedView == _viewArchive)
                                  _SmallDropdown<String?>(
                                    label: 'Archive',
                                    value: _selectedArchiveBucketId,
                                    items: [
                                      if (archiveBuckets.isEmpty)
                                        const DropdownMenuItem<String?>(
                                          value: null,
                                          child: Text('No archive'),
                                        ),
                                      ...archiveBuckets.map(
                                        (bucket) => DropdownMenuItem<String?>(
                                          value: bucket.id,
                                          child: Text(bucket.label),
                                        ),
                                      ),
                                    ],
                                    onChanged: (v) => setState(() {
                                      _selectedArchiveBucketId = v;
                                    }),
                                  ),
                                if (_selectedView == _viewArchive)
                                  const SizedBox(width: 10),
                                _Pill(
                                  icon: _selectedView == _viewCurrent
                                      ? Icons.calendar_today_rounded
                                      : Icons.inventory_2_outlined,
                                  text: scopeLabel,
                                ),
                                const SizedBox(width: 8),
                                _Pill(
                                  icon: Icons.receipt_long_rounded,
                                  text: 'Rows: ${visible.length}',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: visible.isEmpty
                          ? Center(
                              child: Text(
                                _selectedView == _viewCurrent
                                    ? (activePeriod == null
                                          ? 'No active payment period yet.'
                                          : 'No payments in the current period.')
                                    : (archiveBuckets.isEmpty
                                          ? 'No archived payments yet.'
                                          : 'No payments found in this archive period.'),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                12,
                                12,
                                24,
                              ),
                              itemCount: visible.length,
                              itemBuilder: (context, i) {
                                final p = visible[i];
                                final amount = p['amount'];
                                final sessionsPaid = p['sessionsPaid'];
                                final code = (p['course_code'] ?? '')
                                    .toString();
                                final title = (p['course_title'] ?? '')
                                    .toString();
                                final uid = (p['uid'] ?? '').toString();
                                final learnerName = (p['learner_name'] ?? '')
                                    .toString()
                                    .trim();
                                final variantKey = (p['variantKey'] ?? '')
                                    .toString()
                                    .trim();
                                final studyTypeText = _studyTypeText(p);
                                final usesSessions = _variantUsesSessions(
                                  variantKey,
                                );
                                final periodLabel = (p['periodLabel'] ?? '')
                                    .toString()
                                    .trim();
                                final paidDate = _fmtDateFromMs(p['paidAt']);
                                return Card(
                                  elevation: 0,
                                  color: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '$code — $title',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: AdminPaymentsLogScreen
                                                .primaryBlue,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        if (learnerName.isNotEmpty)
                                          Text(
                                            learnerName,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              color: AdminPaymentsLogScreen
                                                  .primaryBlue,
                                            ),
                                          ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Learner UID: $uid',
                                          style: TextStyle(
                                            color: Colors.black.withValues(
                                              alpha: 0.7,
                                            ),
                                          ),
                                        ),
                                        if (studyTypeText.isNotEmpty) ...[
                                          const SizedBox(height: 6),
                                          Text(
                                            'Study type: $studyTypeText',
                                            style: TextStyle(
                                              color: Colors.black.withValues(
                                                alpha: 0.7,
                                              ),
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            if (paidDate.isNotEmpty)
                                              _pill('Paid: $paidDate'),
                                            _pill('Amount: $amount'),
                                            if (usesSessions)
                                              _pill(
                                                'Sessions paid: $sessionsPaid',
                                              ),
                                            if ((p['method'] ?? '')
                                                .toString()
                                                .trim()
                                                .isNotEmpty)
                                              _pill('Method: ${p['method']}'),
                                            if (periodLabel.isNotEmpty)
                                              _pill('Period: $periodLabel')
                                            else if (_paymentPeriodId(
                                              p,
                                            ).isEmpty)
                                              _pill(
                                                'Archive: ${_legacyLabelForPayment(p)}',
                                              ),
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
                                              color: Colors.black.withValues(
                                                alpha: 0.7,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse((v ?? '').toString()) ?? 0;
  }

  static String _fmtDateFromMs(dynamic ms) {
    final t = _asInt(ms);
    if (t <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static String _monthKeyFromPayment(Map<String, dynamic> p) {
    final monthKey = (p['monthKey'] ?? '').toString().trim();
    if (monthKey.isNotEmpty) return monthKey;
    final paidAt = _asInt(p['paidAt']);
    if (paidAt <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(paidAt);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}';
  }

  static String _paymentPeriodId(Map<String, dynamic> p) {
    return (p['periodId'] ?? '').toString().trim();
  }

  static String _archiveBucketIdForPayment(Map<String, dynamic> p) {
    final periodId = _paymentPeriodId(p);
    if (periodId.isNotEmpty) return periodId;
    final monthKey = _monthKeyFromPayment(p);
    return '$_legacyArchivePrefix$monthKey';
  }

  static String _legacyLabelForPayment(Map<String, dynamic> p) {
    final monthKey = _monthKeyFromPayment(p);
    return monthKey.isEmpty ? 'Legacy payments' : 'Legacy $monthKey';
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

class _PaymentPeriodRecord {
  const _PaymentPeriodRecord({
    required this.id,
    required this.label,
    required this.startDate,
    required this.startAtMs,
    required this.endDate,
    required this.isActive,
  });

  final String id;
  final String label;
  final String startDate;
  final int startAtMs;
  final String endDate;
  final bool isActive;

  factory _PaymentPeriodRecord.fromMap({
    required String id,
    required Map<String, dynamic> map,
  }) {
    return _PaymentPeriodRecord(
      id: id,
      label: (map['label'] ?? '').toString().trim(),
      startDate: (map['startDate'] ?? '').toString().trim(),
      startAtMs: _AdminPaymentsLogScreenState._asInt(map['startAtMs']),
      endDate: (map['endDate'] ?? '').toString().trim(),
      isActive: map['isActive'] == true,
    );
  }

  String get displayLabel {
    if (label.isNotEmpty) return label;
    if (startDate.isEmpty) return 'Payment period';
    if (endDate.isNotEmpty) return '$startDate -> $endDate';
    return 'From $startDate';
  }
}

class _ArchiveBucket {
  const _ArchiveBucket({required this.id, required this.label});

  final String id;
  final String label;
}

class _SmallDropdown<T> extends StatelessWidget {
  const _SmallDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: AdminPaymentsLogScreen.appBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label:',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: AdminPaymentsLogScreen.primaryBlue.withValues(alpha: 0.85),
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              items: items,
              onChanged: onChanged,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: AdminPaymentsLogScreen.primaryBlue.withValues(
                  alpha: 0.92,
                ),
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AdminPaymentsLogScreen.appBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AdminPaymentsLogScreen.primaryBlue),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: AdminPaymentsLogScreen.primaryBlue,
            ),
          ),
        ],
      ),
    );
  }
}
