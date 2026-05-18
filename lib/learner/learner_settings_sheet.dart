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

class _LearnerSettingsSheetState extends State<LearnerSettingsSheet> {
  LearnerNotificationSettings _settings =
      LearnerNotificationSettings.defaults();
  bool _loading = true;
  bool _saving = false;
  bool _notifPermissionGranted = true;
  bool _exactAlarmGranted = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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

    return SafeArea(
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
              Expanded(child: _buildNotificationsTab(p)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotificationsTab(AppPalette p) {
    final enabled = _settings.masterEnabled;

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          _statusCard(
            p,
            title: _notifPermissionGranted
                ? 'Notifications allowed'
                : 'Notifications blocked',
            icon: _notifPermissionGranted
                ? Icons.notifications_active_rounded
                : Icons.notifications_off_rounded,
            actionLabel: _notifPermissionGranted
                ? null
                : 'Enable notifications',
            onAction: _notifPermissionGranted ? null : _requestNotifications,
          ),
          const SizedBox(height: 12),
          _statusCard(
            p,
            title: _exactAlarmGranted
                ? 'Exact alarms allowed'
                : 'Exact alarms needed',
            icon: _exactAlarmGranted
                ? Icons.schedule_rounded
                : Icons.alarm_off_rounded,
            actionLabel: _exactAlarmGranted ? null : 'Allow exact alarms',
            onAction: _exactAlarmGranted ? null : _requestExactAlarms,
          ),
          const SizedBox(height: 12),
          _toggleCard(
            p,
            title: 'Enable notifications',
            value: _settings.masterEnabled,
            onChanged: (v) async {
              setState(() {
                _settings = _settings.copyWith(masterEnabled: v);
              });
              await _saveSettings(cancelIfDisabled: true);
            },
          ),
          const SizedBox(height: 10),
          _toggleCard(
            p,
            title: 'Mail, homework, reminders',
            value: _settings.appEnabled,
            onChanged: enabled
                ? (v) async {
                    setState(() {
                      _settings = _settings.copyWith(appEnabled: v);
                    });
                    await _saveSettings();
                  }
                : null,
          ),
          const SizedBox(height: 10),
          _toggleCard(
            p,
            title: 'Upcoming class alerts',
            value: _settings.classEnabled,
            onChanged: enabled
                ? (v) async {
                    setState(() {
                      _settings = _settings.copyWith(classEnabled: v);
                    });
                    await _saveSettings();
                  }
                : null,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.cardBg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: p.border.withValues(alpha: 0.85)),
            ),
            child: DropdownButtonFormField<int>(
              initialValue: _settings.classLeadMinutes,
              decoration: InputDecoration(
                labelText: 'Class reminder before',
                labelStyle: TextStyle(color: p.primary),
                filled: true,
                fillColor: p.soft.withValues(alpha: 0.35),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: p.border.withValues(alpha: 0.7),
                  ),
                ),
              ),
              items: LearnerNotificationSettingsService.leadOptions
                  .map(
                    (m) => DropdownMenuItem<int>(
                      value: m,
                      child: Text('$m min before'),
                    ),
                  )
                  .toList(),
              onChanged: enabled
                  ? (v) async {
                      if (v == null) return;
                      setState(() {
                        _settings = _settings.copyWith(classLeadMinutes: v);
                      });
                      await _saveSettings();
                    }
                  : null,
            ),
          ),
        ],
      ],
    );
  }

  Widget _statusCard(
    AppPalette p, {
    required String title,
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
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 10),
                  FilledButton.tonal(
                    onPressed: onAction,
                    child: Text(actionLabel),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggleCard(
    AppPalette p, {
    required String title,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
            ),
          ),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
