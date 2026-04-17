// ✅ FULL REPLACEMENT: lib/admin/admin_contract_screen.dart
// Copy-paste بالكامل (replace your whole file)

import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';
import '../shared/app_feedback.dart';

class AdminContractScreen extends StatefulWidget {
  const AdminContractScreen({super.key});

  @override
  State<AdminContractScreen> createState() => _AdminContractScreenState();
}

class _AdminContractScreenState extends State<AdminContractScreen>
    with SingleTickerProviderStateMixin {
  // ===== Brand colors (match your admin theme) =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  late final TabController _tab;

  // RTDB roots (your structure)
  DatabaseReference get _teacherRoot =>
      FirebaseDatabase.instance.ref('contract/teacher');
  DatabaseReference get _learnerRoot =>
      FirebaseDatabase.instance.ref('contract/learner');

  bool _ensuring = true;

  @override
  void initState() {
    super.initState();

    _tab = TabController(length: 2, vsync: this);

    // ✅ IMPORTANT: make FAB label update when tab changes
    _tab.addListener(() {
      if (!mounted) return;
      setState(() {});
    });

    _ensureBaseNodes();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  // ✅ Create empty nodes if they don't exist yet
  Future<void> _ensureBaseNodes() async {
    setState(() => _ensuring = true);
    try {
      final t = await _teacherRoot.get();
      if (t.value == null) await _teacherRoot.set({});

      final l = await _learnerRoot.get();
      if (l.value == null) await _learnerRoot.set({});
    } catch (e) {
      if (mounted) {
        AppToast.fromSnackBar(
          context,
          SnackBar(
            content: Text(
              toHumanError(e, fallback: 'Could not initialize contract data.'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _ensuring = false);
    }
  }

  DatabaseReference _activeRoot() =>
      _tab.index == 0 ? _teacherRoot : _learnerRoot;
  String _activeLabel() => _tab.index == 0 ? 'Teachers' : 'Learners';

  static int? _toNullableInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  Future<int> _nextSortOrder(DatabaseReference root) async {
    final snap = await root.get();
    final raw = snap.value;
    if (raw is! Map) return 1;

    int maxOrder = 0;
    final map = raw.map((k, v) => MapEntry(k.toString(), v));
    for (final node in map.values) {
      if (node is! Map) continue;
      final m = node.map((k, v) => MapEntry(k.toString(), v));
      final order = _toNullableInt(m['sortOrder']) ?? 0;
      if (order > maxOrder) maxOrder = order;
    }
    return maxOrder + 1;
  }

  // ---------- UI actions ----------
  Future<void> _openAddDialog() async {
    await _openEditDialog(
      title: '',
      itemsText: '',
      existingId: null,
      root: _activeRoot(),
      kindLabel: _activeLabel(),
    );
  }

  Future<void> _openEditDialog({
    required String title,
    required String itemsText,
    required String? existingId,
    required DatabaseReference root,
    required String kindLabel,
  }) async {
    final titleC = TextEditingController(text: title);
    final itemsC = TextEditingController(text: itemsText);

    bool saving = false;

    Future<void> save() async {
      final t = titleC.text.trim();
      final raw = itemsC.text;

      final items = raw
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

      if (t.isEmpty) {
        AppToast.fromSnackBar(
          context,
          const SnackBar(content: Text('Title is required')),
        );
        return;
      }
      if (items.isEmpty) {
        AppToast.fromSnackBar(
          context,
          const SnackBar(content: Text('Add at least 1 item (one per line)')),
        );
        return;
      }

      if (saving) return;
      saving = true;

      try {
        final now = DateTime.now().millisecondsSinceEpoch;

        if (existingId == null) {
          final newRef = root.push();
          final sortOrder = await _nextSortOrder(root);
          await newRef.set({
            'title': t,
            'items': items,
            'updatedAt': now,
            'sortOrder': sortOrder,
          });
        } else {
          await root.child(existingId).update({
            'title': t,
            'items': items,
            'updatedAt': now,
          });
        }

        if (!mounted) return;
        Navigator.pop(context);
        AppToast.fromSnackBar(
          context,
          SnackBar(
            content: Text(
              existingId == null ? '$kindLabel contract added ✅' : 'Updated ✅',
            ),
          ),
        );
      } catch (e) {
        if (!mounted) return;
        AppToast.fromSnackBar(
          context,
          SnackBar(
            content: Text(
              toHumanError(e, fallback: 'Could not save contract settings.'),
            ),
          ),
        );
      } finally {
        saving = false;
      }
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        final bottom = MediaQuery.of(context).viewInsets.bottom;

        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 12 + bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: primaryBlue.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: primaryBlue.withValues(alpha: 0.12),
                        ),
                      ),
                      child: Icon(
                        existingId == null
                            ? Icons.add_rounded
                            : Icons.edit_rounded,
                        color: primaryBlue,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        existingId == null
                            ? 'Add $kindLabel Contract'
                            : 'Edit $kindLabel Contract',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: primaryBlue,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: titleC,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: 'Contract title',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: itemsC,
                  minLines: 6,
                  maxLines: 12,
                  decoration: InputDecoration(
                    labelText: 'Items (one per line)',
                    alignLabelWithHint: true,
                    hintText: 'Example:\nRule 1\nRule 2\nRule 3',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: appBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: uiBorder),
                  ),
                  child: const Text(
                    'Tip: Write each bullet on a new line.\nWe store them as a list.',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: primaryBlue,
                          side: BorderSide(
                            color: primaryBlue.withValues(alpha: 0.5),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: actionOrange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: save,
                        icon: Icon(
                          existingId == null
                              ? Icons.add_rounded
                              : Icons.save_rounded,
                        ),
                        label: Text(existingId == null ? 'Add' : 'Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    // ✅ IMPORTANT: we DO NOT dispose controllers here (prevents disposed-controller crash)
  }

  Future<bool> _confirmDelete(String title) async {
    return (await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete contract?'),
            content: Text('This will permanently delete:\n\n"$title"'),
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

  void _openContractActionsSheet({
    required DatabaseReference root,
    required String id,
    required String title,
    required List<String> items,
    required String kindLabel,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 46,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: actionOrange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: actionOrange.withValues(alpha: 0.2),
                      ),
                    ),
                    child: const Icon(
                      Icons.visibility_rounded,
                      color: actionOrange,
                    ),
                  ),
                  title: const Text(
                    'Preview',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: const Text('Preview learner popup cards'),
                  onTap: () {
                    Navigator.pop(context);
                    _openContractPreviewSheet(title: title, items: items);
                  },
                ),
                ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: primaryBlue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: primaryBlue.withValues(alpha: 0.12),
                      ),
                    ),
                    child: const Icon(Icons.edit_rounded, color: primaryBlue),
                  ),
                  title: const Text(
                    'Edit',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: const Text('Update title or items'),
                  onTap: () async {
                    Navigator.pop(context);
                    await _openEditDialog(
                      title: title,
                      itemsText: items.join('\n'),
                      existingId: id,
                      root: root,
                      kindLabel: kindLabel,
                    );
                  },
                ),
                ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.red.withValues(alpha: 0.12),
                      ),
                    ),
                    child: const Icon(
                      Icons.delete_outline_rounded,
                      color: Colors.red,
                    ),
                  ),
                  title: const Text(
                    'Delete',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: const Text('Remove this contract'),
                  onTap: () async {
                    Navigator.pop(context);
                    final ok = await _confirmDelete(title);
                    if (!ok) return;

                    try {
                      await root.child(id).remove();
                      if (!mounted) return;
                      AppToast.fromSnackBar(
                        context,
                        const SnackBar(content: Text('Deleted ✅')),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      AppToast.fromSnackBar(
                        context,
                        SnackBar(
                          content: Text(
                            toHumanError(e, fallback: 'Could not delete item.'),
                          ),
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openContractPreviewSheet({
    required String title,
    required List<String> items,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return _ContractPreviewSheet(title: title, items: items);
      },
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: primaryBlue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: primaryBlue.withValues(alpha: 0.12),
                  ),
                ),
                child: Icon(icon, color: primaryBlue, size: 26),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                  color: primaryBlue,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeLabel = _activeLabel();

    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Contract',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Reload',
            onPressed: _ensuring ? null : _ensureBaseNodes,
            icon: const Icon(Icons.refresh_rounded, color: primaryBlue),
          ),
          const SizedBox(width: 6),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(54),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Container(
              decoration: BoxDecoration(
                color: appBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: uiBorder),
              ),
              child: TabBar(
                controller: _tab,
                indicator: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: uiBorder.withValues(alpha: 0.9)),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                labelColor: primaryBlue,
                unselectedLabelColor: Colors.grey.shade700,
                labelStyle: const TextStyle(fontWeight: FontWeight.w900),
                tabs: const [
                  Tab(text: 'Teachers'),
                  Tab(text: 'Learners'),
                ],
              ),
            ),
          ),
        ),
      ),

      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: actionOrange,
        foregroundColor: Colors.white,
        onPressed: _ensuring ? null : _openAddDialog,
        icon: const Icon(Icons.add_rounded),
        label: Text('Add ($activeLabel)'),
      ),

      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1500,
        child: _ensuring
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                controller: _tab,
                children: [
                  _ContractsTab(
                    root: _teacherRoot,
                    kindLabel: 'Teachers',
                    emptyIcon: Icons.badge_rounded,
                    openActions: _openContractActionsSheet,
                    emptyState: _emptyState,
                  ),
                  _ContractsTab(
                    root: _learnerRoot,
                    kindLabel: 'Learners',
                    emptyIcon: Icons.school_rounded,
                    openActions: _openContractActionsSheet,
                    emptyState: _emptyState,
                  ),
                ],
              ),
      ),
    );
  }
}

class _ContractEntry {
  final String id;
  final String title;
  final List<String> items;
  final int updatedAt;
  final int? sortOrder;

  _ContractEntry({
    required this.id,
    required this.title,
    required this.items,
    required this.updatedAt,
    required this.sortOrder,
  });
}

class _ContractPreviewSheet extends StatelessWidget {
  const _ContractPreviewSheet({required this.title, required this.items});

  final String title;
  final List<String> items;

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      decoration: const BoxDecoration(
        color: appBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 12, 14, 10 + bottomPad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 48,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: uiBorder.withValues(alpha: 0.9)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: primaryBlue.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.rule_folder_rounded,
                        color: primaryBlue,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: primaryBlue,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: actionOrange.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: actionOrange.withValues(alpha: 0.22),
                              ),
                            ),
                            child: Text(
                              '${items.length} item${items.length == 1 ? '' : 's'}',
                              style: const TextStyle(
                                color: actionOrange,
                                fontWeight: FontWeight.w900,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    return TweenAnimationBuilder<double>(
                      duration: Duration(milliseconds: 260 + (i * 55)),
                      tween: Tween(begin: 0, end: 1),
                      curve: Curves.easeOutCubic,
                      builder: (context, t, child) {
                        return Opacity(
                          opacity: t,
                          child: Transform.translate(
                            offset: Offset(0, 12 * (1 - t)),
                            child: child,
                          ),
                        );
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: uiBorder.withValues(alpha: 0.85),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 8,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 30,
                              height: 30,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: actionOrange.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${i + 1}',
                                style: const TextStyle(
                                  color: actionOrange,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                items[i],
                                style: const TextStyle(
                                  color: Color(0xFF2D2D2D),
                                  fontWeight: FontWeight.w700,
                                  height: 1.45,
                                  fontSize: 13,
                                ),
                              ),
                            ),
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
      ),
    );
  }
}

/// ✅ A tab that stays alive when switching (fixes "loading forever")
class _ContractsTab extends StatefulWidget {
  final DatabaseReference root;
  final String kindLabel;
  final IconData emptyIcon;

  final void Function({
    required DatabaseReference root,
    required String id,
    required String title,
    required List<String> items,
    required String kindLabel,
  })
  openActions;

  final Widget Function({
    required IconData icon,
    required String title,
    required String subtitle,
  })
  emptyState;

  const _ContractsTab({
    required this.root,
    required this.kindLabel,
    required this.emptyIcon,
    required this.openActions,
    required this.emptyState,
  });

  @override
  State<_ContractsTab> createState() => _ContractsTabState();
}

class _ContractsTabState extends State<_ContractsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // ✅ create stream once per tab
  late final Stream<DatabaseEvent> _stream = widget.root.onValue
      .asBroadcastStream();

  static const primaryBlue = Color(0xFF1A2B48);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);
  bool _savingOrder = false;

  static Map<String, dynamic> _asMap(dynamic v) {
    if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
    return {};
  }

  static List<String> _asStringList(dynamic v) {
    if (v is List) {
      return v
          .map((e) => (e ?? '').toString())
          .where((s) => s.trim().isNotEmpty)
          .toList();
    }
    if (v is Map) {
      final m = v.map((k, val) => MapEntry(k.toString(), val));
      final keys = m.keys.toList()..sort();
      return keys
          .map((k) => (m[k] ?? '').toString())
          .where((s) => s.trim().isNotEmpty)
          .toList();
    }
    return [];
  }

  static int? _toNullableInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  int _compareByOrder(_ContractEntry a, _ContractEntry b) {
    final ao = a.sortOrder;
    final bo = b.sortOrder;
    final aHas = ao != null;
    final bHas = bo != null;

    if (aHas && bHas) {
      final byOrder = ao.compareTo(bo);
      if (byOrder != 0) return byOrder;
    } else if (aHas != bHas) {
      return aHas ? -1 : 1;
    }

    return b.updatedAt.compareTo(a.updatedAt);
  }

  Future<void> _persistSortOrder(List<_ContractEntry> ordered) async {
    if (_savingOrder) return;
    setState(() => _savingOrder = true);
    try {
      final updates = <String, Object?>{};
      for (int i = 0; i < ordered.length; i++) {
        updates['${ordered[i].id}/sortOrder'] = i + 1;
      }
      await widget.root.update(updates);
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Order saved ✅')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(toHumanError(e, fallback: 'Could not save order.')),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingOrder = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return StreamBuilder<DatabaseEvent>(
      stream: _stream,
      builder: (context, snap) {
        // ✅ loader only on first connect
        if (snap.connectionState == ConnectionState.waiting &&
            snap.data == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final v = snap.data?.snapshot.value;
        final map = _asMap(v);

        if (map.isEmpty) {
          return widget.emptyState(
            icon: widget.emptyIcon,
            title: 'No ${widget.kindLabel} contracts yet',
            subtitle: 'Tap the + button to add your first contract.',
          );
        }

        final entries = <_ContractEntry>[];
        map.forEach((id, raw) {
          if (id.isEmpty) return;
          final m = _asMap(raw);
          final title = (m['title'] ?? '').toString().trim();
          final items = _asStringList(m['items']);
          final updatedAt = (m['updatedAt'] is num)
              ? (m['updatedAt'] as num).toInt()
              : 0;
          final sortOrder = _toNullableInt(m['sortOrder']);
          if (title.isEmpty) return;

          entries.add(
            _ContractEntry(
              id: id,
              title: title,
              items: items,
              updatedAt: updatedAt,
              sortOrder: sortOrder,
            ),
          );
        });

        entries.sort(_compareByOrder);

        return ReorderableListView.builder(
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
          itemCount: entries.length,
          onReorder: (oldIndex, newIndex) async {
            if (_savingOrder) return;
            if (oldIndex == newIndex) return;
            if (oldIndex < newIndex) newIndex -= 1;

            final reordered = List<_ContractEntry>.from(entries);
            final moved = reordered.removeAt(oldIndex);
            reordered.insert(newIndex, moved);
            await _persistSortOrder(reordered);
          },
          proxyDecorator: (child, index, animation) {
            return AnimatedBuilder(
              animation: animation,
              builder: (context, _) {
                final t = Curves.easeOut.transform(animation.value);
                return Transform.scale(
                  scale: 1 + (0.02 * t),
                  child: Material(color: Colors.transparent, child: child),
                );
              },
            );
          },
          itemBuilder: (context, i) {
            final c = entries[i];

            return Padding(
              key: ValueKey(c.id),
              padding: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => widget.openActions(
                  root: widget.root,
                  id: c.id,
                  title: c.title,
                  items: c.items,
                  kindLabel: widget.kindLabel,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: uiBorder.withValues(alpha: 0.85)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 10,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: primaryBlue.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: primaryBlue.withValues(alpha: 0.12),
                            ),
                          ),
                          child: const Icon(
                            Icons.description_rounded,
                            color: primaryBlue,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                  color: primaryBlue,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: appBg,
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(color: uiBorder),
                                    ),
                                    child: Text(
                                      '${c.items.length} item${c.items.length == 1 ? '' : 's'}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 11,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _savingOrder
                                          ? 'Saving order...'
                                          : 'Drag to reorder / Tap for actions',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 11,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Actions',
                          onPressed: () => widget.openActions(
                            root: widget.root,
                            id: c.id,
                            title: c.title,
                            items: c.items,
                            kindLabel: widget.kindLabel,
                          ),
                          icon: Icon(
                            Icons.more_horiz_rounded,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Icon(
                              Icons.drag_indicator_rounded,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
