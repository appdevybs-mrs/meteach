import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import '../shared/human_error.dart';
import '../shared/admin_web_layout.dart';
import '../shared/name_formatting.dart';

import 'admin_learners.dart'; // LearnerEditorScreen, EditorMode, LearnerPrefill
import '../shared/app_feedback.dart';

const List<String> _genderOptions = ['Male', 'Female'];

// =======================================================
// ADMIN SUBSCRIPTIONS (FULL REPLACEMENT FILE)
// - Supports new enrollment fields:
//   fullName, phone, courseId, courseTitle, createdAt,
//   deliveryKey, deliveryLabel, studyMode, studyModeLabel,
//   selectedFee, originalFee, discountedFee, promoCode, discountAmount,
//   accessMode, accessDurationMonths, accessLabel,
//   dob/dateOfBirth, email, additionalInfo
// - Still supports old data:
//   firstName + lastName
// - Also tolerates snake_case variants if they ever exist
// - Phone is clickable in list + details
// - "Create Learner" splits fullName into first/last
// =======================================================

class AdminSubscriptionsScreen extends StatefulWidget {
  const AdminSubscriptionsScreen({super.key});

  @override
  State<AdminSubscriptionsScreen> createState() =>
      _AdminSubscriptionsScreenState();
}

class _AdminSubscriptionsScreenState extends State<AdminSubscriptionsScreen> {
  String _promoFilter = '';
  bool _promoUsageExpanded = true;

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  DatabaseReference get _subsRef =>
      FirebaseDatabase.instance.ref('subscriptions');
  DatabaseReference get _historyRef =>
      FirebaseDatabase.instance.ref('promo_usage_history');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Subscriptions',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Add subscription',
            icon: const Icon(Icons.add_circle_rounded, color: actionOrange),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SubscriptionCreateScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1380,
        child: StreamBuilder<DatabaseEvent>(
          stream: _subsRef.onValue,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Center(child: Text('Error loading subscriptions.'));
            }

            final v = snap.data?.snapshot.value;
            final allItems = parseSubscriptions(v);

            return StreamBuilder<DatabaseEvent>(
              stream: _historyRef.onValue,
              builder: (context, snap2) {
                final history = parsePromoHistory(snap2.data?.snapshot.value);
                final summaries = _promoSummaries(allItems, history);
                final items = _filterByPromo(allItems, _promoFilter);

                if (allItems.isEmpty && history.isEmpty) {
                  return const Center(child: Text('No subscriptions yet.'));
                }

                final webWide = isWebDesktop(context, minWidth: 1100);

                if (webWide) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    child: CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: _promoUsageCard(
                            summaries: summaries,
                            totalCount: allItems.length,
                            filteredCount: items.length,
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 10)),
                        if (items.isEmpty)
                          const SliverToBoxAdapter(
                            child: Center(
                              child: Text(
                                'No subscriptions match this filter.',
                              ),
                            ),
                          )
                        else
                          SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                  childAspectRatio: 3.4,
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (context, i) =>
                                  _buildSubscriptionTile(context, items[i]),
                              childCount: items.length,
                            ),
                          ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: items.isEmpty ? 2 : items.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return _promoUsageCard(
                        summaries: summaries,
                        totalCount: allItems.length,
                        filteredCount: items.length,
                      );
                    }
                    final itemIndex = i - 1;
                    if (items.isEmpty) {
                      return const Center(
                        child: Text('No subscriptions match this filter.'),
                      );
                    }
                    final s = items[itemIndex];
                    return _buildSubscriptionTile(context, s);
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  List<SubscriptionItem> _filterByPromo(
    List<SubscriptionItem> items,
    String filter,
  ) {
    if (filter.isEmpty) return items;
    if (filter == '__with_promo__') {
      return items.where((s) => s.promoCode.trim().isNotEmpty).toList();
    }
    return items.where((s) => s.promoCode == filter).toList();
  }

  List<_PromoUsageSummary> _promoSummaries(
    List<SubscriptionItem> items,
    List<_PromoHistoryEntry> history,
  ) {
    final byCode = <String, _PromoUsageSummary>{};

    void addToSummary(String code, double? finalFee, double? discount) {
      if (code.trim().isEmpty) return;
      final existing = byCode[code] ?? _PromoUsageSummary(code: code);
      existing.count += 1;
      existing.totalFinalFee += finalFee ?? 0;
      existing.totalDiscount += discount ?? 0;
      byCode[code] = existing;
    }

    for (final item in items) {
      addToSummary(
        item.promoCode,
        item.discountedFee ?? item.selectedFee ?? item.originalFee,
        item.discountAmount,
      );
    }
    for (final entry in history) {
      addToSummary(
        entry.promoCode,
        entry.selectedFee ?? entry.originalFee ?? entry.discountedFee,
        entry.discountAmount,
      );
    }

    final out = byCode.values.toList();
    out.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.code.compareTo(b.code);
    });
    return out;
  }

  Widget _promoUsageCard({
    required List<_PromoUsageSummary> summaries,
    required int totalCount,
    required int filteredCount,
  }) {
    final withPromoCount = summaries.fold<int>(0, (sum, s) => sum + s.count);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Promo usage',
                  style: TextStyle(
                    color: primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              Text(
                '$filteredCount / $totalCount shown',
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.62),
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
              IconButton(
                icon: Icon(
                  _promoUsageExpanded ? Icons.expand_less : Icons.expand_more,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    setState(() => _promoUsageExpanded = !_promoUsageExpanded),
              ),
            ],
          ),
          if (_promoUsageExpanded) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _filterChip('All', ''),
                _filterChip('With promo ($withPromoCount)', '__with_promo__'),
                for (final summary in summaries)
                  _filterChip(
                    '${summary.code} (${summary.count})',
                    summary.code,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (summaries.isEmpty)
              Text(
                'No promo codes have been used yet.',
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.65),
                  fontWeight: FontWeight.w700,
                ),
              )
            else ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 36,
                  dataRowMinHeight: 38,
                  dataRowMaxHeight: 44,
                  columns: const [
                    DataColumn(label: Text('Promo code')),
                    DataColumn(label: Text('Used'), numeric: true),
                    DataColumn(label: Text('Final total'), numeric: true),
                    DataColumn(label: Text('Discount'), numeric: true),
                  ],
                  rows: [
                    for (final summary in summaries)
                      DataRow(
                        selected: _promoFilter == summary.code,
                        onSelectChanged: (_) {
                          setState(() {
                            _promoFilter = _promoFilter == summary.code
                                ? ''
                                : summary.code;
                          });
                        },
                        cells: [
                          DataCell(Text(summary.code)),
                          DataCell(Text(summary.count.toString())),
                          DataCell(Text(_money(summary.totalFinalFee))),
                          DataCell(Text(_money(summary.totalDiscount))),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                  label: const Text('Clear history'),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Clear promo usage history?'),
                        content: const Text(
                          'This will permanently remove all promo code usage records.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.red,
                            ),
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await _historyRef.remove();
                    }
                  },
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _filterChip(String label, String value) {
    final selected = _promoFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _promoFilter = selected ? '' : value),
      selectedColor: actionOrange.withValues(alpha: 0.18),
      labelStyle: TextStyle(
        color: selected ? actionOrange : primaryBlue,
        fontWeight: FontWeight.w900,
      ),
      side: BorderSide(color: selected ? actionOrange : uiBorder),
      backgroundColor: Colors.white,
    );
  }

  static String _money(double value) => '${value.toStringAsFixed(0)} DA';

  Widget _buildSubscriptionTile(BuildContext context, SubscriptionItem s) {
    final deliveryText = s.studyTypeDisplay;

    final subtitleParts = <String>[
      if (s.courseTitle.trim().isNotEmpty) s.courseTitle,
      if (deliveryText.trim().isNotEmpty) deliveryText,
      if (s.phone.trim().isNotEmpty) s.phone,
    ];

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SubscriptionDetailsScreen(sub: s)),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: uiBorder),
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: appBg,
              child: Text(
                (s.displayName.isNotEmpty
                    ? s.displayName[0].toUpperCase()
                    : 'S'),
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: primaryBlue,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: primaryBlue,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitleParts.isEmpty ? '-' : subtitleParts.join('  •  '),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.black.withValues(alpha: 0.65),
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (s.selectedFee != null ||
                      s.promoCode.trim().isNotEmpty ||
                      s.accessLabel.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (s.selectedFee != null)
                          _pill(
                            label: '${s.selectedFee!.toStringAsFixed(0)} DA',
                            bg: actionOrange.withValues(alpha: 0.10),
                            fg: actionOrange,
                          ),
                        if (s.promoCode.trim().isNotEmpty)
                          _pill(
                            label: 'Promo ${s.promoCode}',
                            bg: const Color(0xFF059669).withValues(alpha: 0.10),
                            fg: const Color(0xFF059669),
                          ),
                        if (s.accessLabel.trim().isNotEmpty)
                          _pill(
                            label: s.accessLabel,
                            bg: primaryBlue.withValues(alpha: 0.08),
                            fg: primaryBlue,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: 'Call',
              icon: const Icon(Icons.call, color: actionOrange),
              onPressed: s.phone.trim().isEmpty
                  ? null
                  : () => callPhone(s.phone),
            ),
            const Icon(Icons.chevron_right_rounded, color: primaryBlue),
          ],
        ),
      ),
    );
  }

  static Widget _pill({
    required String label,
    required Color bg,
    required Color fg,
  }) {
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

// -------------------- DETAILS --------------------

class SubscriptionDetailsScreen extends StatelessWidget {
  const SubscriptionDetailsScreen({super.key, required this.sub});

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);
  static const green = Color(0xFF059669);

  final SubscriptionItem sub;

  DatabaseReference get _subsRef =>
      FirebaseDatabase.instance.ref('subscriptions');

  Future<bool> _confirmDelete(BuildContext context) async {
    return (await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete subscription?'),
            content: const Text('This cannot be undone.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        )) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final split = splitFullName(sub.fullName);

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Subscription Details',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_forever_rounded),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () async {
                    final ok = await _confirmDelete(context);
                    if (!ok) return;

                    await _subsRef.child(sub.id).remove();
                    if (context.mounted) Navigator.pop(context);
                  },
                  label: const Text('Delete'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  style: FilledButton.styleFrom(
                    backgroundColor: actionOrange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LearnerEditorScreen(
                          mode: EditorMode.create,
                          prefill: LearnerPrefill(
                            firstName: split.first,
                            lastName: split.last,
                            gender: sub.gender,
                            phone1: sub.phone,
                            dob: sub.dob,
                            email: sub.email,
                            selectedCourseIds: {
                              if (sub.courseId.trim().isNotEmpty) sub.courseId,
                            },
                            sourceSubscriptionId: sub.id,
                            courseId: sub.courseId,
                            courseTitle: sub.courseTitle,
                            variantKey: sub.deliveryKey,
                            variantLabel: sub.deliveryLabel,
                            studyMode: sub.studyMode,
                            studyModeLabel: sub.studyModeLabel,
                            selectedFee: sub.selectedFee,
                            originalFee: sub.originalFee,
                            discountedFee: sub.discountedFee,
                            promoCode: sub.promoCode,
                            promoType: sub.promoType,
                            promoValue: sub.promoValue,
                            discountAmount: sub.discountAmount,
                            promoUsageLimit: sub.promoUsageLimit,
                            promoMaxUsesPerUser: sub.promoMaxUsesPerUser,
                            promoExpiresAt: sub.promoExpiresAt,
                            promoUsedCountAfterApply:
                                sub.promoUsedCountAfterApply,
                            promoAppliedAt: sub.promoAppliedAt,
                            promoClaimKeys: sub.promoClaimKeys,
                          ),
                        ),
                      ),
                    );
                  },
                  label: const Text('Create Learner'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 980,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          children: [
            _headerCard(),
            const SizedBox(height: 12),
            _infoCard(
              icon: Icons.person_rounded,
              title: 'Personal Information',
              children: [
                _infoRow(Icons.people_alt_rounded, 'Gender', sub.gender),
                _infoRow(Icons.cake_rounded, 'Date of birth', sub.dob),
                if (sub.email.trim().isNotEmpty)
                  _infoRow(Icons.email_rounded, 'Email', sub.email),
              ],
            ),
            const SizedBox(height: 12),
            _infoCard(
              icon: Icons.school_rounded,
              title: 'Course Information',
              children: [
                _infoRow(Icons.book_rounded, 'Course', sub.courseTitle),
                if (sub.studyTypeDisplay.isNotEmpty)
                  _infoRow(
                    Icons.delivery_dining_rounded,
                    'Study type',
                    sub.studyTypeDisplay,
                  ),
                if (sub.studyModeLabel.isNotEmpty)
                  _infoRow(
                    Icons.laptop_rounded,
                    'Study mode',
                    sub.studyModeLabel,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _pricingCard(),
            if (sub.accessDurationMonths != null &&
                    sub.accessDurationMonths! > 0 ||
                sub.accessLabel.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              _infoCard(
                icon: Icons.vpn_key_rounded,
                title: 'Access',
                children: [
                  if (sub.accessDurationMonths != null &&
                      sub.accessDurationMonths! > 0)
                    _infoRow(
                      Icons.timer_rounded,
                      'Access months',
                      sub.accessDurationMonths.toString(),
                    ),
                  if (sub.accessLabel.trim().isNotEmpty)
                    _infoRow(
                      Icons.label_rounded,
                      'Access label',
                      sub.accessLabel,
                    ),
                ],
              ),
            ],
            if (sub.additionalInfo.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              _infoCard(
                icon: Icons.info_rounded,
                title: 'Additional Info',
                children: [
                  _infoRow(Icons.notes_rounded, 'Notes', sub.additionalInfo),
                  _infoRow(
                    Icons.calendar_month_rounded,
                    'Created',
                    formatTimestamp(sub.createdAt),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─── Header Card ───────────────────────────────────────────────

  Widget _headerCard() {
    final initial = sub.displayName.isNotEmpty
        ? sub.displayName[0].toUpperCase()
        : 'S';

    return _card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: primaryBlue.withValues(alpha: 0.08),
            child: Text(
              initial,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: primaryBlue,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sub.displayName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: primaryBlue,
                  ),
                ),
                const SizedBox(height: 4),
                if (sub.phone.trim().isNotEmpty)
                  InkWell(
                    onTap: () => callPhone(sub.phone),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.call, size: 15, color: actionOrange),
                          const SizedBox(width: 5),
                          Text(
                            sub.phone,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: actionOrange,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (sub.courseTitle.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    sub.courseTitle,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.black.withValues(alpha: 0.7),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (sub.studyTypeDisplay.isNotEmpty)
                      _pill(
                        label: sub.studyTypeDisplay,
                        bg: actionOrange.withValues(alpha: 0.1),
                        fg: actionOrange,
                      ),
                    if (sub.studyModeLabel.isNotEmpty &&
                        !sub.studyTypeDisplay.contains(sub.studyModeLabel))
                      _pill(
                        label: sub.studyModeLabel,
                        bg: primaryBlue.withValues(alpha: 0.06),
                        fg: primaryBlue,
                      ),
                    if (sub.promoCode.trim().isNotEmpty)
                      _pill(
                        label: 'Promo ${sub.promoCode}',
                        bg: green.withValues(alpha: 0.1),
                        fg: green,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Info Card (generic section) ───────────────────────────────

  Widget _infoCard({
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(icon, title),
          const Divider(height: 20),
          ...children,
        ],
      ),
    );
  }

  // ─── Pricing Card ──────────────────────────────────────────────

  Widget _pricingCard() {
    final hasOriginal = sub.originalFee != null && sub.originalFee! > 0;
    final hasDiscount = sub.discountAmount != null && sub.discountAmount! > 0;
    final hasSelected = sub.selectedFee != null && sub.selectedFee! > 0;
    final hasPromo = sub.promoCode.trim().isNotEmpty;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(Icons.payments_rounded, 'Pricing'),
          const Divider(height: 20),
          if (hasOriginal)
            _infoRow(
              Icons.money_off_rounded,
              'Original fee',
              '${sub.originalFee!.toStringAsFixed(0)} DA',
              valueStyle: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.black.withValues(alpha: 0.45),
                decoration: hasDiscount ? TextDecoration.lineThrough : null,
              ),
            ),
          if (hasDiscount)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const SizedBox(width: 24),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '-${sub.discountAmount!.toStringAsFixed(0)} DA',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: green,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (hasPromo) ...[
                    const SizedBox(width: 6),
                    Text(
                      sub.promoCode,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.black.withValues(alpha: 0.35),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (hasSelected)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const SizedBox(width: 24),
                  Text(
                    '${sub.selectedFee!.toStringAsFixed(0)} DA',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      color: actionOrange,
                    ),
                  ),
                  if (hasPromo &&
                      sub.promoValue != null &&
                      sub.promoValue! > 0) ...[
                    const SizedBox(width: 8),
                    _pill(
                      label: sub.promoType == 'percent'
                          ? '${sub.promoValue!.toStringAsFixed(0)}% OFF'
                          : '${sub.promoValue!.toStringAsFixed(0)} DA OFF',
                      bg: green.withValues(alpha: 0.12),
                      fg: green,
                    ),
                  ],
                ],
              ),
            ),
          if (hasPromo) ...[
            const Divider(height: 8),
            const SizedBox(height: 6),
            _infoRow(Icons.local_offer_rounded, 'Promo code', sub.promoCode),
            if (sub.promoType.isNotEmpty)
              _infoRow(Icons.category_rounded, 'Promo type', sub.promoType),
            _infoRow(
              Icons.sell_rounded,
              'Promo value',
              sub.promoValue == null
                  ? ''
                  : sub.promoType == 'percent'
                  ? '${sub.promoValue!.toStringAsFixed(0)}%'
                  : '${sub.promoValue!.toStringAsFixed(0)} DA',
            ),
            if (hasDiscount)
              _infoRow(
                Icons.discount_rounded,
                'Discount',
                '${sub.discountAmount!.toStringAsFixed(0)} DA',
              ),
          ],
        ],
      ),
    );
  }

  // ─── Shared Widget Builders ────────────────────────────────────

  Widget _card({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  Widget _sectionHeader(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, size: 18, color: primaryBlue),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w900,
            color: primaryBlue,
          ),
        ),
      ],
    );
  }

  Widget _infoRow(
    IconData icon,
    String label,
    String value, {
    TextStyle? valueStyle,
  }) {
    final displayValue = value.trim().isEmpty ? '-' : value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Icon(
              icon,
              size: 16,
              color: actionOrange.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: primaryBlue,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              displayValue,
              style:
                  valueStyle ??
                  TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.black.withValues(alpha: 0.7),
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill({required String label, required Color bg, required Color fg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: fg),
      ),
    );
  }
}

// -------------------- CREATE (ADD) --------------------

class SubscriptionCreateScreen extends StatefulWidget {
  const SubscriptionCreateScreen({super.key});

  @override
  State<SubscriptionCreateScreen> createState() =>
      _SubscriptionCreateScreenState();
}

class _SubscriptionCreateScreenState extends State<SubscriptionCreateScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final firstNameC = TextEditingController();
  final lastNameC = TextEditingController();
  final phoneC = TextEditingController();
  final dobC = TextEditingController();
  final emailC = TextEditingController();
  String? _gender;

  String? selectedCourseId;
  String selectedCourseTitle = '';

  bool saving = false;

  DatabaseReference get _subsRef =>
      FirebaseDatabase.instance.ref('subscriptions');
  DatabaseReference get _coursesRef => FirebaseDatabase.instance.ref('courses');

  @override
  void dispose() {
    firstNameC.dispose();
    lastNameC.dispose();
    phoneC.dispose();
    dobC.dispose();
    emailC.dispose();
    super.dispose();
  }

  Future<void> _pickCourse() async {
    final snap = await _coursesRef.get();
    final v = snap.value;

    final items = <Map<String, String>>[];
    if (v is Map) {
      v.forEach((k, val) {
        if (k == null || val == null) return;
        if (val is Map) {
          final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
          final title = (m['title'] ?? m['name'] ?? '').toString().trim();
          items.add({
            'id': k.toString(),
            'title': title.isEmpty ? k.toString() : title,
          });
        }
      });
    }

    items.sort((a, b) => a['title']!.compareTo(b['title']!));

    if (!mounted) return;
    final picked = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Pick a course'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: items.length,
            itemBuilder: (context, i) {
              final c = items[i];
              return ListTile(
                title: Text(c['title']!),
                subtitle: Text(
                  c['id']!,
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
                onTap: () => Navigator.pop(context, c),
              );
            },
          ),
        ),
      ),
    );

    if (picked == null) return;
    setState(() {
      selectedCourseId = picked['id'];
      selectedCourseTitle = picked['title'] ?? '';
    });
  }

  Future<void> _save() async {
    if (selectedCourseId == null || selectedCourseId!.trim().isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Pick a course first')),
      );
      return;
    }

    final fn = normalizePersonNamePart(firstNameC.text);
    final ln = normalizePersonNamePart(lastNameC.text);
    final ph = phoneC.text.trim();
    final dob = dobC.text.trim();
    final email = emailC.text.trim();
    final gender = (_gender ?? '').trim();

    if (fn.isEmpty || ln.isEmpty || ph.isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Fill first name, last name, phone')),
      );
      return;
    }

    if (!_genderOptions.contains(gender)) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Select gender')),
      );
      return;
    }

    setState(() => saving = true);

    try {
      final newRef = _subsRef.push();
      await newRef.set({
        'courseId': selectedCourseId,
        'courseTitle': selectedCourseTitle,
        'createdAt': ServerValue.timestamp,

        // compatible with old + new UI
        'firstName': fn,
        'lastName': ln,
        'fullName': '$fn $ln'.trim(),
        'phone': ph,
        'gender': gender,
        'dob': dob,
        'dateOfBirth': dob,
        'email': email,
      });

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not save subscription changes.'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Add Subscription',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: actionOrange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: saving ? null : _save,
            child: Text(saving ? 'Saving…' : 'Save Subscription'),
          ),
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 980,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: uiBorder),
            ),
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, c) {
                final twoCols =
                    isWebDesktop(context, minWidth: 900) && c.maxWidth >= 700;
                final fieldWidth = twoCols ? (c.maxWidth - 10) / 2 : c.maxWidth;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: firstNameC,
                        decoration: const InputDecoration(
                          labelText: 'First name',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: lastNameC,
                        decoration: const InputDecoration(
                          labelText: 'Last name',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: phoneC,
                        decoration: const InputDecoration(labelText: 'Phone'),
                        keyboardType: TextInputType.phone,
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: DropdownButtonFormField<String>(
                        initialValue: _gender,
                        decoration: const InputDecoration(labelText: 'Gender'),
                        items: _genderOptions
                            .map(
                              (value) => DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _gender = v),
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: dobC,
                        decoration: const InputDecoration(
                          labelText: 'Date of birth',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: emailC,
                        decoration: const InputDecoration(
                          labelText: 'Email (optional)',
                        ),
                        keyboardType: TextInputType.emailAddress,
                      ),
                    ),
                    SizedBox(
                      width: twoCols ? c.maxWidth : fieldWidth,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _pickCourse,
                          icon: const Icon(Icons.school_rounded),
                          label: Text(
                            selectedCourseId == null
                                ? 'Pick course'
                                : 'Course: $selectedCourseTitle',
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------- MODEL + HELPERS --------------------

String _normalizeDeliveryKey(String key) {
  final v = key.trim().toLowerCase();

  switch (v) {
    case 'online':
    case 'flexible':
      return 'flexible';

    case 'live':
    case 'private':
      return 'private';

    case 'recorded':
      return 'recorded';

    case 'inclass':
    case 'in-class':
    case 'in class':
    case 'in_class':
      return 'inclass';

    default:
      return v;
  }
}

String _canonicalDeliveryLabel(String key) {
  switch (_normalizeDeliveryKey(key)) {
    case 'inclass':
      return 'In-Class';
    case 'flexible':
      return 'Flexible';
    case 'private':
      return 'Private';
    case 'recorded':
      return 'Recorded';
    default:
      return key.trim();
  }
}

String _normalizeStudyMode(String key) {
  final v = key.trim().toLowerCase();

  switch (v) {
    case 'online':
      return 'online';
    case 'inclass':
    case 'in-class':
    case 'in class':
    case 'in_class':
      return 'inclass';
    default:
      return '';
  }
}

String _studyModeLabel(String key) {
  switch (_normalizeStudyMode(key)) {
    case 'online':
      return 'Online';
    case 'inclass':
      return 'In-Class';
    default:
      return '';
  }
}

class _PromoUsageSummary {
  _PromoUsageSummary({required this.code});

  final String code;
  int count = 0;
  double totalFinalFee = 0;
  double totalDiscount = 0;
}

class _PromoHistoryEntry {
  _PromoHistoryEntry({
    required this.promoCode,
    this.discountAmount,
    this.selectedFee,
    this.originalFee,
    this.discountedFee,
  });

  final String promoCode;
  final double? discountAmount;
  final double? selectedFee;
  final double? originalFee;
  final double? discountedFee;
}

List<_PromoHistoryEntry> parsePromoHistory(dynamic v) {
  if (v is! Map) return [];
  final out = <_PromoHistoryEntry>[];
  v.forEach((k, val) {
    if (k == null || val == null) return;
    if (val is! Map) return;
    final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
    final code = (m['promoCode'] ?? '').toString().trim();
    if (code.isEmpty) return;
    out.add(
      _PromoHistoryEntry(
        promoCode: code,
        discountAmount: _asDouble(m['discountAmount']),
        selectedFee: _asDouble(m['selectedFee']),
        originalFee: _asDouble(m['originalFee']),
        discountedFee: _asDouble(m['discountedFee']),
      ),
    );
  });
  return out;
}

double? _asDouble(dynamic x) {
  if (x == null) return null;
  if (x is double) return x;
  if (x is int) return x.toDouble();
  return double.tryParse(x.toString().trim());
}

class SubscriptionItem {
  SubscriptionItem({
    required this.id,
    required this.courseId,
    required this.courseTitle,
    required this.createdAt,
    required this.fullName,
    required this.phone,
    required this.gender,
    required this.deliveryKey,
    required this.deliveryLabel,
    required this.studyMode,
    required this.studyModeLabel,
    required this.selectedFee,
    required this.originalFee,
    required this.discountedFee,
    required this.promoCode,
    required this.promoType,
    required this.promoValue,
    required this.discountAmount,
    required this.promoUsageLimit,
    required this.promoMaxUsesPerUser,
    required this.promoExpiresAt,
    required this.promoUsedCountAfterApply,
    required this.promoAppliedAt,
    required this.promoClaimKeys,
    required this.accessMode,
    required this.accessDurationMonths,
    required this.accessLabel,
    required this.dob,
    required this.email,
    required this.additionalInfo,
  });

  final String id;
  final String courseId;
  final String courseTitle;
  final int createdAt;
  final String fullName;
  final String phone;
  final String gender;

  final String deliveryKey;
  final String deliveryLabel;
  final String studyMode;
  final String studyModeLabel;
  final double? selectedFee;
  final double? originalFee;
  final double? discountedFee;
  final String promoCode;
  final String promoType;
  final double? promoValue;
  final double? discountAmount;
  final int? promoUsageLimit;
  final int? promoMaxUsesPerUser;
  final int? promoExpiresAt;
  final int? promoUsedCountAfterApply;
  final int? promoAppliedAt;
  final Map<String, bool> promoClaimKeys;
  final String accessMode;
  final int? accessDurationMonths;
  final String accessLabel;
  final String dob;
  final String email;
  final String additionalInfo;

  String get displayName =>
      fullName.trim().isEmpty ? '(No name)' : fullName.trim();

  String get studyTypeDisplay {
    final delivery = deliveryLabel.trim();
    final mode = studyModeLabel.trim();

    if (delivery.isEmpty && mode.isEmpty) return '';
    if (_normalizeDeliveryKey(deliveryKey) == 'private' && mode.isNotEmpty) {
      return delivery.isEmpty ? mode : '$delivery • $mode';
    }
    return delivery;
  }
}

List<SubscriptionItem> parseSubscriptions(dynamic v) {
  if (v is! Map) return [];

  int asInt(dynamic x) {
    if (x is int) return x;
    if (x is num) return x.toInt();
    return int.tryParse(x?.toString() ?? '') ?? 0;
  }

  double? asDouble(dynamic x) {
    if (x == null) return null;
    if (x is double) return x;
    if (x is int) return x.toDouble();
    if (x is num) return x.toDouble();
    return double.tryParse(x.toString().trim());
  }

  String readString(Map<String, dynamic> m, List<String> keys) {
    for (final key in keys) {
      final value = m[key];
      if (value == null) continue;
      final s = value.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  Map<String, bool> readBoolMap(dynamic raw) {
    if (raw is! Map) return const <String, bool>{};
    final out = <String, bool>{};
    raw.forEach((key, value) {
      if (key == null) return;
      out[key.toString()] = value == true;
    });
    return out;
  }

  final out = <SubscriptionItem>[];

  v.forEach((k, val) {
    if (k == null || val == null) return;
    if (val is! Map) return;

    final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));

    final dbFullName = readString(m, ['fullName', 'full_name']);
    final fn = readString(m, ['firstName', 'first_name']);
    final ln = readString(m, ['lastName', 'last_name']);
    final computedName = dbFullName.isNotEmpty
        ? dbFullName
        : ('$fn $ln').trim();

    final rawDeliveryKey = readString(m, ['deliveryKey', 'delivery_key']);
    final normalizedDeliveryKey = _normalizeDeliveryKey(rawDeliveryKey);

    final rawDeliveryLabel = readString(m, [
      'deliveryLabel',
      'delivery_label',
      'delivery',
    ]);
    final normalizedDeliveryLabel = rawDeliveryLabel.isNotEmpty
        ? rawDeliveryLabel
        : _canonicalDeliveryLabel(normalizedDeliveryKey);

    final rawStudyMode = readString(m, ['studyMode', 'study_mode']);
    final normalizedStudyMode = _normalizeStudyMode(rawStudyMode);

    final rawStudyModeLabel = readString(m, [
      'studyModeLabel',
      'study_mode_label',
    ]);
    final normalizedStudyModeLabel = rawStudyModeLabel.isNotEmpty
        ? rawStudyModeLabel
        : _studyModeLabel(normalizedStudyMode);

    out.add(
      SubscriptionItem(
        id: k.toString(),
        courseId: readString(m, ['courseId', 'course_id']),
        courseTitle: readString(m, ['courseTitle', 'course_title']),
        createdAt: asInt(m['createdAt'] ?? m['created_at']),
        fullName: computedName,
        phone: readString(m, ['phone', 'phone1', 'phone_1']),
        gender: readString(m, ['gender']),
        deliveryKey: normalizedDeliveryKey,
        deliveryLabel: normalizedDeliveryLabel,
        studyMode: normalizedStudyMode,
        studyModeLabel: normalizedStudyModeLabel,
        selectedFee: asDouble(m['selectedFee'] ?? m['selected_fee']),
        originalFee: asDouble(m['originalFee'] ?? m['original_fee']),
        discountedFee: asDouble(m['discountedFee'] ?? m['discounted_fee']),
        promoCode: readString(m, ['promoCode', 'promo_code']),
        promoType: readString(m, ['promoType', 'promo_type']),
        promoValue: asDouble(m['promoValue'] ?? m['promo_value']),
        discountAmount: asDouble(m['discountAmount'] ?? m['discount_amount']),
        promoUsageLimit:
            (m['promoUsageLimit'] ?? m['promo_usage_limit']) == null
            ? null
            : asInt(m['promoUsageLimit'] ?? m['promo_usage_limit']),
        promoMaxUsesPerUser:
            (m['promoMaxUsesPerUser'] ?? m['promo_max_uses_per_user']) == null
            ? null
            : asInt(m['promoMaxUsesPerUser'] ?? m['promo_max_uses_per_user']),
        promoExpiresAt: (m['promoExpiresAt'] ?? m['promo_expires_at']) == null
            ? null
            : asInt(m['promoExpiresAt'] ?? m['promo_expires_at']),
        promoUsedCountAfterApply:
            (m['promoUsedCountAfterApply'] ??
                    m['promo_used_count_after_apply']) ==
                null
            ? null
            : asInt(
                m['promoUsedCountAfterApply'] ??
                    m['promo_used_count_after_apply'],
              ),
        promoAppliedAt: (m['promoAppliedAt'] ?? m['promo_applied_at']) == null
            ? null
            : asInt(m['promoAppliedAt'] ?? m['promo_applied_at']),
        promoClaimKeys: readBoolMap(m['promoClaimKeys']),
        accessMode: readString(m, ['accessMode', 'access_mode']),
        accessDurationMonths:
            (m['accessDurationMonths'] ?? m['access_duration_months']) == null
            ? null
            : asInt(m['accessDurationMonths'] ?? m['access_duration_months']),
        accessLabel: readString(m, ['accessLabel', 'access_label']),
        dob: readString(m, ['dob', 'dateOfBirth', 'date_of_birth']),
        email: readString(m, ['email', 'mail']),
        additionalInfo: readString(m, ['additionalInfo', 'additional_info']),
      ),
    );
  });

  out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return out;
}

({String first, String last}) splitFullName(String fullName) {
  final cleaned = fullName.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (cleaned.isEmpty) return (first: '', last: '');

  final parts = cleaned.split(' ');
  if (parts.length == 1) return (first: parts[0], last: '');

  return (first: parts.first, last: parts.sublist(1).join(' '));
}

String formatTimestamp(int value) {
  if (value <= 0) return '-';
  final dt = DateTime.fromMillisecondsSinceEpoch(value);
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm';
}

Future<void> callPhone(String phone) async {
  final cleaned = phone.trim();
  if (cleaned.isEmpty) return;

  final uri = Uri(scheme: 'tel', path: cleaned);
  await launchUrl(uri);
}
