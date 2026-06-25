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
      _notifPermissionGranted =
          await NotificationService.I.areNotificationsEnabled();
      _exactAlarmGranted =
          await NotificationService.I.canScheduleExactAlarms();
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
    final primary = p.primary;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [primary, primary.withValues(alpha: 0.85)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: primary.withValues(alpha: 0.25),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.settings_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Notification Settings',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Control how we notify you',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_saving)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Expanded(child: _buildContent(p)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(AppPalette p) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          _sectionHeader(p, 'Notifications'),
          const SizedBox(height: 8),
          _toggleCard(
            p,
            icon: Icons.notifications_active_rounded,
            title: 'Turn on notifications',
            subtitle: 'Get alerts for everything important',
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
            icon: Icons.mail_rounded,
            title: 'Updates & reminders',
            subtitle: 'Mail, homework, and other updates',
            value: _settings.appEnabled,
            onChanged: _settings.masterEnabled
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
            icon: Icons.school_rounded,
            title: 'Class reminders',
            subtitle: 'Get notified before your class starts',
            value: _settings.classEnabled,
            onChanged: _settings.masterEnabled
                ? (v) async {
                    setState(() {
                      _settings = _settings.copyWith(classEnabled: v);
                    });
                    await _saveSettings();
                  }
                : null,
          ),
          const SizedBox(height: 14),
          _sectionHeader(p, 'Reminder timing'),
          const SizedBox(height: 8),
          _leadTimeCard(p),
          const SizedBox(height: 18),
          _sectionHeader(p, 'Phone permissions'),
          const SizedBox(height: 8),
          _permissionCard(
            p,
            icon: _notifPermissionGranted
                ? Icons.check_circle_rounded
                : Icons.warning_amber_rounded,
            iconColor: _notifPermissionGranted
                ? const Color(0xFF16A34A)
                : const Color(0xFFEA580C),
            title: _notifPermissionGranted
                ? 'Notifications allowed'
                : 'Notifications blocked',
            subtitle: _notifPermissionGranted
                ? 'We can send you alerts'
                : 'Please enable notifications in your phone settings',
            actionLabel: _notifPermissionGranted ? null : 'Enable',
            onAction: _notifPermissionGranted ? null : _requestNotifications,
          ),
          const SizedBox(height: 8),
          _permissionCard(
            p,
            icon: _exactAlarmGranted
                ? Icons.check_circle_rounded
                : Icons.warning_amber_rounded,
            iconColor: _exactAlarmGranted
                ? const Color(0xFF16A34A)
                : const Color(0xFFEA580C),
            title: _exactAlarmGranted
                ? 'Alarm permission granted'
                : 'Alarm permission needed',
            subtitle: _exactAlarmGranted
                ? 'Timely class reminders are set'
                : 'Required for on-time class reminders',
            actionLabel: _exactAlarmGranted ? null : 'Grant',
            onAction: _exactAlarmGranted ? null : _requestExactAlarms,
          ),
        ],
      ],
    );
  }

  Widget _sectionHeader(AppPalette p, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: TextStyle(
          color: p.primary.withValues(alpha: 0.7),
          fontSize: 13,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _toggleCard(
    AppPalette p, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final enabled = onChanged != null;
    final opacity = enabled ? 1.0 : 0.45;

    return Opacity(
      opacity: opacity,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: p.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: p.border.withValues(alpha: enabled ? 0.85 : 0.4),
          ),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: p.primary.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: value
                    ? p.primary.withValues(alpha: 0.15)
                    : p.soft.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                icon,
                color: value ? p.primary : p.text.withValues(alpha: 0.4),
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: value ? p.text : p.text.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: p.text.withValues(alpha: 0.5),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeTrackColor: p.primary.withValues(alpha: 0.6),
              activeThumbColor: p.primary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _leadTimeCard(AppPalette p) {
    final enabled = _settings.masterEnabled;
    final opacity = enabled ? 1.0 : 0.45;

    return Opacity(
      opacity: opacity,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: p.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: p.border.withValues(alpha: enabled ? 0.85 : 0.4),
          ),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: p.primary.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: p.soft.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                Icons.timer_rounded,
                color: p.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Remind me before class',
                    style: TextStyle(
                      color: p.text,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Choose how early to alert you',
                    style: TextStyle(
                      color: p.text.withValues(alpha: 0.5),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: p.soft.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: p.border.withValues(alpha: 0.5),
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _settings.classLeadMinutes,
                  isDense: true,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                  items: LearnerNotificationSettingsService.leadOptions
                      .map(
                        (m) => DropdownMenuItem<int>(
                          value: m,
                          child: Text('$m min'),
                        ),
                      )
                      .toList(),
                  onChanged: enabled
                      ? (v) async {
                          if (v == null) return;
                          setState(() {
                            _settings =
                                _settings.copyWith(classLeadMinutes: v);
                          });
                          await _saveSettings();
                        }
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionCard(
    AppPalette p, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: p.text,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: p.text.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                backgroundColor: p.primary.withValues(alpha: 0.12),
                foregroundColor: p.primary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: onAction,
              child: Text(
                actionLabel,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
