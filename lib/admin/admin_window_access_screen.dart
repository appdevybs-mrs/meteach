import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/window_access_service.dart';
import '../shared/window_access_dialogs.dart';

class AdminWindowAccessScreen extends StatefulWidget {
  const AdminWindowAccessScreen({super.key});

  @override
  State<AdminWindowAccessScreen> createState() =>
      _AdminWindowAccessScreenState();
}

class _AdminWindowAccessScreenState extends State<AdminWindowAccessScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _loading = true;
  final Map<String, List<AppWindowState>> _statesByRole = {
    AppWindowRole.learner: const [],
    AppWindowRole.teacher: const [],
    AppWindowRole.admin: const [],
  };

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final service = WindowAccessService.instance;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'admin';

    await service.seedDefaultsIfMissing(updatedBy: uid);

    final learner = await service.loadStatesForRole(AppWindowRole.learner);
    final teacher = await service.loadStatesForRole(AppWindowRole.teacher);
    final admin = await service.loadStatesForRole(AppWindowRole.admin);

    if (!mounted) return;
    setState(() {
      _statesByRole[AppWindowRole.learner] = learner;
      _statesByRole[AppWindowRole.teacher] = teacher;
      _statesByRole[AppWindowRole.admin] = admin;
      _loading = false;
    });
  }

  Future<void> _onToggle({
    required String role,
    required AppWindowState state,
    required bool nextEnabled,
  }) async {
    if (!state.definition.canClose) return;

    final confirmed = await showWindowToggleConfirmDialog(
      context,
      nextEnabled: nextEnabled,
      labelEn: state.definition.labelEn,
      labelAr: state.definition.labelAr,
    );
    if (!confirmed || !mounted) return;

    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'admin';
    await WindowAccessService.instance.setWindowEnabled(
      role: role,
      windowKey: state.definition.key,
      enabled: nextEnabled,
      updatedBy: uid,
    );

    final list = (_statesByRole[role] ?? const <AppWindowState>[]).toList();
    final idx = list.indexWhere(
      (e) => e.definition.key == state.definition.key,
    );
    if (idx >= 0) {
      list[idx] = list[idx].copyWith(enabled: nextEnabled);
      if (!mounted) return;
      setState(() => _statesByRole[role] = list);
    }
  }

  Widget _buildRoleTab(String role) {
    final states = _statesByRole[role] ?? const <AppWindowState>[];
    if (states.isEmpty) {
      return const Center(child: Text('No windows found.'));
    }

    final grouped = <String, List<AppWindowState>>{};
    for (final item in states) {
      grouped.putIfAbsent(item.definition.tab, () => []).add(item);
    }

    final tabs = grouped.keys.toList()..sort();
    final tiles = <Widget>[];
    for (final tab in tabs) {
      tiles.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Text(
            tab,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
          ),
        ),
      );

      final entries = grouped[tab]!
        ..sort((a, b) => a.definition.labelEn.compareTo(b.definition.labelEn));
      for (final item in entries) {
        final locked = !item.definition.canClose;
        tiles.add(
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: ListTile(
              title: Text(
                '${item.definition.labelEn} • ${item.definition.labelAr}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                locked
                    ? 'Always open • يبقى مفتوحاً'
                    : (item.enabled ? 'Open • مفتوح' : 'Closed • مغلق'),
              ),
              trailing: Switch(
                value: item.enabled,
                onChanged: locked
                    ? null
                    : (v) => _onToggle(role: role, state: item, nextEnabled: v),
              ),
            ),
          ),
        );
      }
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: tiles,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Window Access Manager'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Learner'),
            Tab(text: 'Teacher'),
            Tab(text: 'Admin'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildRoleTab(AppWindowRole.learner),
                _buildRoleTab(AppWindowRole.teacher),
                _buildRoleTab(AppWindowRole.admin),
              ],
            ),
    );
  }
}
