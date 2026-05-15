import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/learner_notification_settings_service.dart';
import '../services/notification_service.dart';
import '../shared/app_theme.dart';

class LearnerSettingsSheet extends StatefulWidget {
  const LearnerSettingsSheet({super.key, this.onChanged});

  final Future<void> Function()? onChanged;

  @override
  State<LearnerSettingsSheet> createState() => _LearnerSettingsSheetState();
}

class _LearnerSettingsSheetState extends State<LearnerSettingsSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  LearnerNotificationSettings _settings =
      LearnerNotificationSettings.defaults();
  bool _loading = true;
  bool _saving = false;
  bool _notifPermissionGranted = true;
  bool _exactAlarmGranted = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  AppPalette get palette => appThemeController.palette;

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isNotEmpty) {
      _settings = await LearnerNotificationSettingsService.load(uid);
      await LearnerNotificationSettingsService.save(uid, _settings);
    }

    await _refreshPermissionState();

    if (mounted) {
      setState(() => _loading = false);
    }

    if (uid.isNotEmpty && !_settings.masterEnabled) {
      unawaited(NotificationService.I.cancelAll());
    }
  }

  Future<void> _refreshPermissionState() async {
    try {
      await NotificationService.I.init();
      _notifPermissionGranted = await NotificationService.I
          .areNotificationsEnabled();
      _exactAlarmGranted = await NotificationService.I.canScheduleExactAlarms();
    } catch (_) {
      _notifPermissionGranted = true;
      _exactAlarmGranted = true;
    }
  }

  Future<void> _saveSettings({bool cancelIfDisabled = false}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;

    setState(() => _saving = true);
    try {
      await LearnerNotificationSettingsService.save(uid, _settings);
      if (cancelIfDisabled && !_settings.masterEnabled) {
        await NotificationService.I.cancelAll();
      }
      await widget.onChanged?.call();
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _requestNotifications() async {
    await NotificationService.I.init();
    await NotificationService.I.requestPermissions();
    await _refreshPermissionState();
    if (mounted) setState(() {});
  }

  Future<void> _requestExactAlarms() async {
    await NotificationService.I.init();
    await NotificationService.I.requestExactAlarmsPermissionIfNeeded();
    await _refreshPermissionState();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;

    return DefaultTabController(
      length: 2,
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.92,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Settings',
                        style: TextStyle(
                          color: p.primary,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    if (_saving)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TabBar(
                  controller: _tabController,
                  labelColor: p.primary,
                  unselectedLabelColor: p.text.withValues(alpha: 0.6),
                  indicatorColor: p.accent,
                  tabs: const [
                    Tab(text: 'Theme'),
                    Tab(text: 'Notifications'),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [_buildThemeTab(p), _buildNotificationsTab(p)],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThemeTab(AppPalette p) {
    final modes = AppThemeMode.values;

    return ListView.separated(
      itemCount: modes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final mode = modes[index];
        final preview = appThemeController.paletteForMode(mode);

        return Material(
          color: p.cardBg,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () async {
              await appThemeController.setTheme(mode);
              if (mounted) setState(() {});
              await widget.onChanged?.call();
            },
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: p.border.withValues(alpha: 0.85)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: preview.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.settings_rounded, color: preview.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          appThemeController.themeTitle(mode),
                          style: TextStyle(
                            color: p.primary,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          appThemeController.themeSubtitle(mode),
                          style: TextStyle(
                            color: p.text.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    appThemeController.mode == mode
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: appThemeController.mode == mode
                        ? p.accent
                        : p.border,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildNotificationsTab(AppPalette p) {
    final enabled = _settings.masterEnabled;

    return ListView(
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          _noticeCard(
            p,
            title: _notifPermissionGranted
                ? 'Notifications allowed'
                : 'Notifications blocked',
            body: _notifPermissionGranted
                ? 'Learner notifications can be delivered.'
                : 'Allow notifications to receive mail, homework, reminders, and class alerts.',
            icon: _notifPermissionGranted
                ? Icons.notifications_active_rounded
                : Icons.notifications_off_rounded,
            actionLabel: _notifPermissionGranted
                ? null
                : 'Enable notifications',
            onAction: _notifPermissionGranted ? null : _requestNotifications,
          ),
          const SizedBox(height: 12),
          _noticeCard(
            p,
            title: _exactAlarmGranted
                ? 'Exact alarms allowed'
                : 'Exact alarms needed',
            body: _exactAlarmGranted
                ? 'Class reminders can fire on time.'
                : 'Allow exact alarms for the most reliable upcoming-class notifications.',
            icon: _exactAlarmGranted
                ? Icons.schedule_rounded
                : Icons.alarm_off_rounded,
            actionLabel: _exactAlarmGranted ? null : 'Allow exact alarms',
            onAction: _exactAlarmGranted ? null : _requestExactAlarms,
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            value: _settings.masterEnabled,
            onChanged: (v) async {
              setState(() {
                _settings = _settings.copyWith(masterEnabled: v);
              });
              await _saveSettings(cancelIfDisabled: true);
            },
            title: Text(
              'Enable notifications',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
            ),
            subtitle: Text(
              'Default is on. Turn it off to pause all learner notifications.',
              style: TextStyle(color: p.text.withValues(alpha: 0.7)),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _settings.appEnabled,
            onChanged: enabled
                ? (v) async {
                    setState(() {
                      _settings = _settings.copyWith(appEnabled: v);
                    });
                    await _saveSettings();
                  }
                : null,
            title: Text(
              'Mail, homework, reminders',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
            ),
            subtitle: Text(
              'Controls app messages and reminder alerts.',
              style: TextStyle(color: p.text.withValues(alpha: 0.7)),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _settings.classEnabled,
            onChanged: enabled
                ? (v) async {
                    setState(() {
                      _settings = _settings.copyWith(classEnabled: v);
                    });
                    await _saveSettings();
                  }
                : null,
            title: Text(
              'Upcoming class alerts',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
            ),
            subtitle: Text(
              'Learns from class schedule and booking records.',
              style: TextStyle(color: p.text.withValues(alpha: 0.7)),
            ),
          ),
          const SizedBox(height: 12),
          IgnorePointer(
            ignoring: !enabled,
            child: Opacity(
              opacity: enabled ? 1 : 0.55,
              child: DropdownButtonFormField<int>(
                initialValue: _settings.classLeadMinutes,
                decoration: InputDecoration(
                  labelText: 'Class reminder before',
                  labelStyle: TextStyle(color: p.primary),
                  border: const OutlineInputBorder(),
                ),
                items: LearnerNotificationSettingsService.leadOptions
                    .map(
                      (m) => DropdownMenuItem<int>(
                        value: m,
                        child: Text('$m min before'),
                      ),
                    )
                    .toList(),
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() {
                    _settings = _settings.copyWith(classLeadMinutes: v);
                  });
                  await _saveSettings();
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.soft.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: p.border.withValues(alpha: 0.85)),
            ),
            child: Text(
              'Class alerts are synced from the server, then scheduled locally for the selected lead time. This is the most reliable way to fire on time.',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.78),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _noticeCard(
    AppPalette p, {
    required String title,
    required String body,
    required IconData icon,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: p.soft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: p.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    color: p.text.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 10),
                  TextButton(onPressed: onAction, child: Text(actionLabel)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
