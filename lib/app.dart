import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'l10n/app_localizations.dart';
import 'models/workbook_models.dart';
import 'services/version_check_service.dart';
import 'state/app_state.dart';
import 'theme/theme_palettes.dart';
import 'widgets/meteach_logo.dart';

Widget _logoWatermark(BuildContext context, {double opacity = 0.06}) {
  return IgnorePointer(
    child: Center(
      child: Opacity(
        opacity: opacity,
        child: const MarkaGlyph(size: 260, showShadow: false),
      ),
    ),
  );
}

Future<void> showProcessDoneLogoAnimation(BuildContext context) async {
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'done-animation',
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, _) {
      final l10n = AppLocalizations.of(context);
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      });
      return Center(
        child: TweenAnimationBuilder<double>(
          duration: const Duration(milliseconds: 500),
          tween: Tween<double>(begin: 0.6, end: 1),
          curve: Curves.easeOutBack,
          builder: (context, value, child) {
            return Opacity(
              opacity: value.clamp(0, 1),
              child: Transform.scale(scale: value, child: child),
            );
          },
          child: Container(
            width: 210,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 12,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const MarkaGlyph(size: 82),
                const SizedBox(height: 10),
                Text(
                  l10n.t('done'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<bool> showConfirmDialog(
  BuildContext context,
  String title,
  String message,
  AppLocalizations l10n,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.t('no')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.t('yes')),
        ),
      ],
    ),
  );
  return result ?? false;
}

void _goToWorkspace(BuildContext context) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const WorkspaceScreen()));
}

Widget _processingOverlay(BuildContext context, String message) {
  return ColoredBox(
    color: Colors.black.withValues(alpha: 0.4),
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              duration: const Duration(milliseconds: 900),
              tween: Tween<double>(begin: 0.9, end: 1.0),
              curve: Curves.easeInOut,
              builder: (context, value, child) {
                return Transform.scale(scale: value, child: child);
              },
              child: const MarkaGlyph(size: 64),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _launchExternalUrl(BuildContext context, String url) async {
  final trimmed = url.trim();
  if (trimmed.isEmpty) {
    return;
  }
  final ok = await launchUrlString(
    trimmed,
    mode: LaunchMode.externalApplication,
  );
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).t('openLinkFailed'))),
    );
  }
}

Future<void> _launchEmail(BuildContext context, String email) async {
  final normalized = email.trim().replaceAll(',', '.');
  if (normalized.isEmpty) {
    return;
  }
  final uri = 'mailto:$normalized';
  final ok = await launchUrlString(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).t('openLinkFailed'))),
    );
  }
}

Widget _aboutUsCard(
  BuildContext context,
  MeTeachState state,
  AppLocalizations l10n,
) {
  final about = state.aboutUs;
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  'assets/intilak_logo.png',
                  width: 44,
                  height: 44,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.t('aboutUs'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.t('refresh'),
                onPressed: state.aboutUsLoading ? null : state.refreshAboutUs,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (state.aboutUsLoading)
            const LinearProgressIndicator(minHeight: 2)
          else
            Text(
              about.hasDescription ? about.description : l10n.t('aboutUsEmpty'),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (about.hasFacebook)
                OutlinedButton.icon(
                  onPressed: () =>
                      _launchExternalUrl(context, about.facebookUrl),
                  icon: const Icon(Icons.facebook_rounded),
                  label: Text(l10n.t('facebook')),
                ),
              if (about.hasInstagram)
                OutlinedButton.icon(
                  onPressed: () =>
                      _launchExternalUrl(context, about.instagramUrl),
                  icon: const Icon(Icons.camera_alt_rounded),
                  label: Text(l10n.t('instagram')),
                ),
              if (about.hasEmail)
                OutlinedButton.icon(
                  onPressed: () => _launchEmail(context, about.email),
                  icon: const Icon(Icons.mail_outline_rounded),
                  label: Text(l10n.t('email')),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

Future<void> showGuidePopup(BuildContext context, MeTeachState state) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          final l10n = AppLocalizations.of(context);
          final scheme = Theme.of(context).colorScheme;
          final brand = Theme.of(context).extension<BrandColors>()!;

          Widget guideCard(Color color, IconData icon, String text) {
            return Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: color, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      text,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            );
          }

          return AlertDialog(
            title: Row(
              children: [
                Expanded(child: Text(l10n.t('guideTitle'))),
                PopupMenuButton<Locale>(
                  tooltip: l10n.t('language'),
                  icon: Icon(Icons.language_rounded, color: scheme.secondary),
                  onSelected: (locale) {
                    state.setLocale(locale);
                    setState(() {});
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: Locale('en'),
                      child: Text('English'),
                    ),
                    const PopupMenuItem(
                      value: Locale('fr'),
                      child: Text('Français'),
                    ),
                    const PopupMenuItem(
                      value: Locale('ar'),
                      child: Text('العربية'),
                    ),
                    const PopupMenuItem(
                      value: Locale('de'),
                      child: Text('Deutsch'),
                    ),
                    const PopupMenuItem(
                      value: Locale('es'),
                      child: Text('Español'),
                    ),
                    const PopupMenuItem(
                      value: Locale('it'),
                      child: Text('Italiano'),
                    ),
                  ],
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                guideCard(
                  scheme.primary,
                  Icons.upload_file_rounded,
                  l10n.t('guideStep1'),
                ),
                guideCard(
                  scheme.tertiary,
                  Icons.rule_folder_rounded,
                  l10n.t('guideStep2'),
                ),
                guideCard(
                  brand.gold,
                  Icons.verified_rounded,
                  l10n.t('guideStep3'),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.t('guideHint'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l10n.t('close')),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> showThemePicker(BuildContext context, MeTeachState state) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final l10n = AppLocalizations.of(sheetContext);
      final scheme = Theme.of(sheetContext).colorScheme;
      final height = MediaQuery.of(sheetContext).size.height * 0.75;
      return SafeArea(
        child: SizedBox(
          height: height,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.t('themeTitle'),
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.t('chooseTheme'),
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: List.generate(themePalettes.length, (index) {
                    final palette = themePalettes[index];
                    final selected = index == state.themeIndex;
                    return InkWell(
                      onTap: () {
                        state.setThemeIndex(index);
                        Navigator.pop(sheetContext);
                      },
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        width: 140,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: palette.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: selected
                                ? scheme.secondary
                                : scheme.primary.withValues(alpha: 0.12),
                            width: selected ? 2 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.08),
                              blurRadius: 10,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                _ThemeSwatch(color: palette.primary),
                                const SizedBox(width: 6),
                                _ThemeSwatch(color: palette.secondary),
                                const SizedBox(width: 6),
                                _ThemeSwatch(color: palette.tertiary),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              palette.name,
                              style: Theme.of(sheetContext).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<void> showVersionPopup(
  BuildContext context, {
  VersionInfo? preloadedInfo,
}) async {
  final info = preloadedInfo ?? await VersionCheckService().fetch();
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final minVersion = info.minVersion ?? l10n.t('versionUnavailable');
      return AlertDialog(
        title: Text(l10n.t('versionCheckTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: _VersionChip(
                    label: l10n.t('currentVersion'),
                    value: info.appVersion,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _VersionChip(
                    label: l10n.t('minVersion'),
                    value: minVersion,
                    color: scheme.secondary,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.t('close')),
          ),
        ],
      );
    },
  );
}

Future<void> showAboutUsPopup(
  BuildContext context,
  MeTeachState state, {
  bool refreshFirst = true,
}) async {
  if (refreshFirst) {
    await state.refreshAboutUs();
    if (!context.mounted) {
      return;
    }
  }
  final l10n = AppLocalizations.of(context);
  final about = state.aboutUs;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(l10n.t('aboutUs')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'assets/intilak_logo.png',
                      width: 96,
                      height: 96,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  about.hasDescription
                      ? about.description
                      : l10n.t('aboutUsEmpty'),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (about.hasFacebook)
                      OutlinedButton.icon(
                        onPressed: () => _launchExternalUrl(
                          dialogContext,
                          about.facebookUrl,
                        ),
                        icon: const Icon(Icons.facebook_rounded),
                        label: Text(l10n.t('facebook')),
                      ),
                    if (about.hasInstagram)
                      OutlinedButton.icon(
                        onPressed: () => _launchExternalUrl(
                          dialogContext,
                          about.instagramUrl,
                        ),
                        icon: const Icon(Icons.camera_alt_rounded),
                        label: Text(l10n.t('instagram')),
                      ),
                    if (about.hasEmail)
                      OutlinedButton.icon(
                        onPressed: () =>
                            _launchEmail(dialogContext, about.email),
                        icon: const Icon(Icons.mail_outline_rounded),
                        label: Text(l10n.t('email')),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.t('close')),
          ),
        ],
      );
    },
  );
}

Future<void> showForceUpdateDialog(
  BuildContext context, {
  required String minVersion,
  required String? updateUrl,
}) async {
  final l10n = AppLocalizations.of(context);
  var openingStore = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(l10n.t('forceUpdateTitle')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.t('forceUpdateMessage')),
                  const SizedBox(height: 10),
                  _VersionChip(
                    label: l10n.t('minVersion'),
                    value: minVersion,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ],
              ),
              actions: [
                FilledButton.icon(
                  onPressed: openingStore
                      ? null
                      : () async {
                          final url = VersionCheckService.normalizeStoreUrl(
                            updateUrl,
                          );
                          if (url.isEmpty) {
                            return;
                          }
                          setDialogState(() => openingStore = true);
                          final launched = await launchUrlString(
                            url,
                            mode: LaunchMode.externalApplication,
                          );
                          if (!launched && dialogContext.mounted) {
                            ScaffoldMessenger.of(dialogContext).showSnackBar(
                              SnackBar(
                                content: Text(
                                  AppLocalizations.of(
                                    dialogContext,
                                  ).t('openLinkFailed'),
                                ),
                              ),
                            );
                          }
                          if (dialogContext.mounted) {
                            setDialogState(() => openingStore = false);
                          }
                        },
                  icon: openingStore
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.system_update_alt_rounded),
                  label: Text(l10n.t('updateNow')),
                ),
              ],
            );
          },
        ),
      );
    },
  );
}

Future<void> showValidationPopup(
  BuildContext context,
  AppLocalizations l10n,
  Map<String, int> summary,
  VoidCallback onViewDetails,
) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(l10n.t('validationComplete')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.format('validationSummary', {
                'errors': '${summary['errors'] ?? 0}',
                'warnings': '${summary['warnings'] ?? 0}',
              }),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.t('close')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              onViewDetails();
            },
            child: Text(l10n.t('viewValidation')),
          ),
        ],
      );
    },
  );
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _VersionChip extends StatelessWidget {
  const _VersionChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class MeTeachApp extends StatelessWidget {
  const MeTeachApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<MeTeachState>(
      create: (_) => MeTeachState(),
      child: Consumer<MeTeachState>(
        builder: (context, state, _) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            onGenerateTitle: (context) =>
                AppLocalizations.of(context).t('appTitle'),
            locale: state.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) {
              final l10n = AppLocalizations.of(context);
              return Directionality(
                textDirection: l10n.textDirection,
                child: child ?? const SizedBox.shrink(),
              );
            },
            theme: buildMarkaTheme(themePalettes[state.themeIndex]),
            home: const SplashScreen(),
          );
        },
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  bool _animateLogoIn = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 40), () {
      if (mounted) {
        setState(() => _animateLogoIn = true);
      }
    });
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        color: scheme.surface.withValues(alpha: 0.9),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _logoWatermark(context, opacity: 0.11),
            Center(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 520),
                opacity: _animateLogoIn ? 1 : 0,
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 520),
                  scale: _animateLogoIn ? 1 : 0.82,
                  curve: Curves.easeOutBack,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 98,
                        height: 98,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.15),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: const MarkaGlyph(size: 72, showShadow: false),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.t('appTitle'),
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.t('welcome'),
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  DateTime? _lastBackPress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkVersionAndPrompt();
    });
  }

  Future<void> _checkVersionAndPrompt() async {
    final state = context.read<MeTeachState>();
    final info = await VersionCheckService().fetch();
    if (!mounted) {
      return;
    }

    final cachedMin = state.forcedUpdateMinVersion;
    final cachedUrl = state.forcedUpdateUrl;
    final remoteMin = info.minVersion?.trim() ?? '';
    final hasRemoteMin = remoteMin.isNotEmpty;

    if (hasRemoteMin) {
      if (info.needsUpdate) {
        await state.saveForcedUpdateRequirement(
          minVersion: remoteMin,
          updateUrl: info.storeUrl,
        );
        if (!mounted) {
          return;
        }
        await showForceUpdateDialog(
          context,
          minVersion: remoteMin,
          updateUrl: info.storeUrl,
        );
        return;
      }

      if (cachedMin != null || (cachedUrl ?? '').isNotEmpty) {
        await state.clearForcedUpdateRequirement();
        if (!mounted) {
          return;
        }
      }
    } else if (cachedMin != null &&
        VersionCheckService.isUpdateRequired(info.appVersion, cachedMin)) {
      await showForceUpdateDialog(
        context,
        minVersion: cachedMin,
        updateUrl: cachedUrl?.trim().isNotEmpty == true
            ? cachedUrl
            : info.storeUrl,
      );
      return;
    }

    if (!state.versionPopupShown) {
      state.markVersionPopupShown();
      await showVersionPopup(context, preloadedInfo: info);
      if (!mounted) {
        return;
      }
      await showAboutUsPopup(context, state);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = context.watch<MeTeachState>();
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastBackPress == null ||
            now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
          _lastBackPress = now;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.t('pressBackAgain')),
              duration: const Duration(seconds: 2),
            ),
          );
          return;
        }
        SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(l10n.t('appTitle')),
          actions: [
            IconButton(
              tooltip: l10n.t('guideTitle'),
              onPressed: () => showGuidePopup(context, state),
              icon: Icon(Icons.help_outline_rounded, color: scheme.secondary),
            ),
            IconButton(
              tooltip: l10n.t('themeTitle'),
              onPressed: () => showThemePicker(context, state),
              icon: Icon(Icons.palette_rounded, color: scheme.secondary),
            ),
            IconButton(
              tooltip: l10n.t('aboutUs'),
              onPressed: () => showAboutUsPopup(context, state),
              icon: Icon(Icons.info_outline_rounded, color: scheme.secondary),
            ),
            PopupMenuButton<Locale>(
              icon: const Icon(Icons.language_rounded),
              onSelected: state.setLocale,
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: const Locale('en'),
                  child: const Text('English'),
                ),
                PopupMenuItem(
                  value: const Locale('fr'),
                  child: const Text('Français'),
                ),
                PopupMenuItem(
                  value: const Locale('ar'),
                  child: const Text('العربية'),
                ),
                PopupMenuItem(
                  value: const Locale('de'),
                  child: const Text('Deutsch'),
                ),
                PopupMenuItem(
                  value: const Locale('es'),
                  child: const Text('Español'),
                ),
                PopupMenuItem(
                  value: const Locale('it'),
                  child: const Text('Italiano'),
                ),
              ],
            ),
          ],
        ),
        body: Container(
          color: scheme.surface.withValues(alpha: 0.92),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _logoWatermark(context, opacity: 0.055),
                  ListView(
                    padding: const EdgeInsets.all(22),
                    children: [
                      Center(
                        child: Column(
                          children: [
                            const MarkaGlyph(size: 132),
                            const SizedBox(height: 10),
                            Text(
                              l10n.t('welcome'),
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              alignment: WrapAlignment.center,
                              children: [
                                FilledButton.icon(
                                  onPressed: state.busy
                                      ? null
                                      : () async {
                                          final ok = await state
                                              .importWorkbookFromPicker();
                                          if (!context.mounted) {
                                            return;
                                          }
                                          if (ok) {
                                            final createCopy =
                                                await showConfirmDialog(
                                                  context,
                                                  l10n.t('copyTitle'),
                                                  l10n.t('copyMessage'),
                                                  l10n,
                                                );
                                            if (createCopy) {
                                              state.createEditableBackupCopy();
                                            }
                                            if (!context.mounted) {
                                              return;
                                            }
                                            _goToWorkspace(context);
                                          }
                                        },
                                  icon: state.busy
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.upload_file_rounded),
                                  label: Text(l10n.t('uploadWorkbook')),
                                ),
                                if (state.recentWorkbooks.isNotEmpty)
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      final ok = state.reopenRecentWorkbook(0);
                                      if (ok) {
                                        if (!context.mounted) {
                                          return;
                                        }
                                        _goToWorkspace(context);
                                      }
                                    },
                                    icon: const Icon(Icons.history_rounded),
                                    label: Text(l10n.t('reopen')),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () => showAboutUsPopup(context, state),
                              icon: const Icon(Icons.info_outline_rounded),
                              label: Text(l10n.t('aboutUs')),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.folder_copy_rounded,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    l10n.t('recentFiles'),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const Spacer(),
                                  Text('${state.recentWorkbooks.length}'),
                                ],
                              ),
                              const SizedBox(height: 8),
                              if (state.recentWorkbooks.isEmpty)
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    color: scheme.surface,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: scheme.primary.withValues(
                                        alpha: 0.12,
                                      ),
                                    ),
                                  ),
                                  child: Column(
                                    children: [
                                      Icon(
                                        Icons.auto_stories_rounded,
                                        size: 30,
                                        color: scheme.tertiary,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(l10n.t('noWorkbook')),
                                    ],
                                  ),
                                )
                              else
                                ...state.recentWorkbooks.asMap().entries.map((
                                  entry,
                                ) {
                                  final item = entry.value;
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: scheme.surface,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: scheme.primary.withValues(
                                          alpha: 0.08,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Icon(
                                              Icons.description_outlined,
                                              color: scheme.primary,
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    item.displayName,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  Text(
                                                    '${l10n.t('openedAt')}: ${item.openedAt.toLocal().toString().replaceFirst('.000', '')}',
                                                    style: Theme.of(
                                                      context,
                                                    ).textTheme.bodySmall,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 6,
                                          runSpacing: 6,
                                          children: [
                                            OutlinedButton(
                                              onPressed: () async {
                                                final ok = state
                                                    .reopenRecentWorkbook(
                                                      entry.key,
                                                    );
                                                if (ok) {
                                                  if (!context.mounted) {
                                                    return;
                                                  }
                                                  _goToWorkspace(context);
                                                }
                                              },
                                              child: Text(l10n.t('reopen')),
                                            ),
                                            IconButton.filledTonal(
                                              icon: const Icon(
                                                Icons.drive_file_rename_outline,
                                              ),
                                              onPressed: () {
                                                final controller =
                                                    TextEditingController(
                                                      text: item.displayName,
                                                    );
                                                showDialog<void>(
                                                  context: context,
                                                  builder: (context) => AlertDialog(
                                                    title: Text(
                                                      l10n.t('rename'),
                                                    ),
                                                    content: TextField(
                                                      controller: controller,
                                                      autofocus: true,
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () =>
                                                            Navigator.pop(
                                                              context,
                                                            ),
                                                        child: Text(
                                                          l10n.t('cancel'),
                                                        ),
                                                      ),
                                                      FilledButton(
                                                        onPressed: () {
                                                          state
                                                              .renameRecentWorkbook(
                                                                entry.key,
                                                                controller.text,
                                                              );
                                                          Navigator.pop(
                                                            context,
                                                          );
                                                        },
                                                        child: Text(
                                                          l10n.t(
                                                            'saveSettings',
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              },
                                            ),
                                            IconButton.filledTonal(
                                              icon: const Icon(
                                                Icons.delete_outline_rounded,
                                              ),
                                              onPressed: () =>
                                                  state.deleteRecentWorkbook(
                                                    entry.key,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (state.processingKey != null)
                    Positioned.fill(
                      child: _processingOverlay(
                        context,
                        l10n.t(state.processingKey!),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  late final TextEditingController _searchController;
  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: _sheetSearch);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final state = context.read<MeTeachState>();
      if (state.justOpenedWorkbook) {
        state.consumeJustOpened();
        await showProcessDoneLogoAnimation(context);
      }
    });
  }

  int _navIndex = 0;
  bool _isGlobalSearch = false;
  String _sheetSearch = '';
  String _globalSearch = '';
  static const List<int> _primaryPageIndexes = <int>[0, 1, 2, 6];
  final TextEditingController _ruleMinController = TextEditingController();
  final TextEditingController _ruleMaxController = TextEditingController();
  final TextEditingController _ruleRemarkController = TextEditingController();
  ScoreSource _selectedScoreSource = ScoreSource.exam;
  int? _editingRuleIndex;
  bool _pageLoading = false;

  @override
  void dispose() {
    _searchController.dispose();
    _ruleMinController.dispose();
    _ruleMaxController.dispose();
    _ruleRemarkController.dispose();
    super.dispose();
  }

  Future<bool> _confirmDialog(
    BuildContext context,
    String title,
    String message,
    AppLocalizations l10n,
  ) async {
    return showConfirmDialog(context, title, message, l10n);
  }

  Future<void> _confirmExit(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) async {
    if (state.editedRowsCount == 0) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
        (route) => false,
      );
      return;
    }
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t('unsavedTitle')),
        content: Text(l10n.t('unsavedMessage')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text(l10n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: Text(l10n.t('discard')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: Text(l10n.t('saveAndExit')),
          ),
        ],
      ),
    );
    if (!context.mounted) {
      return;
    }
    if (result == 'save') {
      state.saveProgressCheckpoint('Exit save');
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    } else if (result == 'discard') {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    }
  }

  Widget _historyPage(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) {
    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.t('historyTitle'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(l10n.t('historyHint')),
                const SizedBox(height: 12),
                if (state.snapshots.isEmpty)
                  Text(l10n.t('noHistory'))
                else
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: state.snapshots.length,
                    itemBuilder: (context, index) {
                      final item = state.snapshots[index];
                      return ListTile(
                        title: Text(item.label),
                        subtitle: Text(
                          item.createdAt.toLocal().toString().replaceFirst(
                            '.000',
                            '',
                          ),
                        ),
                        trailing: OutlinedButton(
                          onPressed: () => state.restoreSnapshot(index),
                          child: Text(l10n.t('restoreSnapshot')),
                        ),
                      );
                    },
                  ),
                if (state.logs.isNotEmpty) const Divider(height: 24),
                if (state.logs.isNotEmpty)
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: state.logs.length,
                    itemBuilder: (context, index) {
                      final log = state.logs[index];
                      return ListTile(
                        leading: const Icon(Icons.history_rounded),
                        title: Text(l10n.format(log.key, log.values)),
                        subtitle: Text(
                          log.timestamp.toLocal().toString().replaceFirst(
                            '.000',
                            '',
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MeTeachState>();
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (!state.hasWorkbook) {
      return const HomeScreen();
    }

    final pages = [
      _overviewPage(context, state, l10n),
      _sheetEditorPage(context, state, l10n),
      _historyPage(context, state, l10n),
      _validationPage(context, state, l10n),
      _rulesPage(context, state, l10n),
      _settingsPage(context, state, l10n),
      _exportPage(context, state, l10n),
    ];

    final labels = [
      l10n.t('overview'),
      l10n.t('sheetEditor'),
      l10n.t('historyTitle'),
      l10n.t('validation'),
      l10n.t('rulesPresets'),
      l10n.t('settings'),
      l10n.t('export'),
    ];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_navIndex != 1) {
          setState(() => _navIndex = 1);
          return;
        }
        _confirmExit(context, state, l10n);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > 980;
          final selectedPrimary = _primaryPageIndexes.indexOf(_navIndex);
          return Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              title: Text(labels[_navIndex]),
              actions: [
                if (_navIndex == 0) ...[
                  IconButton(
                    tooltip: l10n.t('guideTitle'),
                    onPressed: () => showGuidePopup(context, state),
                    icon: Icon(
                      Icons.help_outline_rounded,
                      color: scheme.secondary,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.t('themeTitle'),
                    onPressed: () => showThemePicker(context, state),
                    icon: Icon(Icons.palette_rounded, color: scheme.secondary),
                  ),
                ],
                PopupMenuButton<Locale>(
                  icon: const Icon(Icons.language_rounded),
                  onSelected: state.setLocale,
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: const Locale('en'),
                      child: const Text('English'),
                    ),
                    PopupMenuItem(
                      value: const Locale('fr'),
                      child: const Text('Français'),
                    ),
                    PopupMenuItem(
                      value: const Locale('ar'),
                      child: const Text('العربية'),
                    ),
                    PopupMenuItem(
                      value: const Locale('de'),
                      child: const Text('Deutsch'),
                    ),
                    PopupMenuItem(
                      value: const Locale('es'),
                      child: const Text('Español'),
                    ),
                    PopupMenuItem(
                      value: const Locale('it'),
                      child: const Text('Italiano'),
                    ),
                  ],
                ),
                IconButton(
                  onPressed: state.undoLast,
                  icon: const Icon(Icons.undo_rounded),
                  tooltip: l10n.t('undoLast'),
                ),
              ],
            ),
            floatingActionButton: _navIndex == 1
                ? FloatingActionButton.extended(
                    onPressed: () => showBulkActionsPopup(context, state, l10n),
                    icon: const Icon(Icons.bolt_rounded),
                    label: Text(l10n.t('bulkActions')),
                  )
                : null,
            body: Stack(
              children: [
                Container(color: scheme.surface.withValues(alpha: 0.92)),
                _logoWatermark(context, opacity: 0.05),
                Row(
                  children: [
                    if (wide)
                      NavigationRail(
                        selectedIndex: selectedPrimary < 0
                            ? 0
                            : selectedPrimary,
                        onDestinationSelected: (value) => setState(
                          () => _navIndex = _primaryPageIndexes[value],
                        ),
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          NavigationRailDestination(
                            icon: const Icon(Icons.dashboard_outlined),
                            selectedIcon: const Icon(Icons.dashboard_rounded),
                            label: Text(l10n.t('overview')),
                          ),
                          NavigationRailDestination(
                            icon: const Icon(Icons.table_chart_outlined),
                            selectedIcon: const Icon(Icons.table_chart),
                            label: Text(l10n.t('sheetEditor')),
                          ),
                          NavigationRailDestination(
                            icon: const Icon(Icons.history_outlined),
                            selectedIcon: const Icon(Icons.history_rounded),
                            label: Text(l10n.t('historyTitle')),
                          ),
                          NavigationRailDestination(
                            icon: const Icon(Icons.upload_outlined),
                            selectedIcon: const Icon(Icons.upload),
                            label: Text(l10n.t('export')),
                          ),
                        ],
                      ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: Padding(
                          key: ValueKey<int>(_navIndex),
                          padding: const EdgeInsets.all(12),
                          child: pages[_navIndex],
                        ),
                      ),
                    ),
                  ],
                ),
                if (_pageLoading)
                  Positioned.fill(
                    child: ColoredBox(
                      color: const Color(0x88000000),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(l10n.t('processing')),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (state.processingKey != null)
                  Positioned.fill(
                    child: _processingOverlay(
                      context,
                      l10n.t(state.processingKey!),
                    ),
                  ),
              ],
            ),
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: selectedPrimary < 0 ? 0 : selectedPrimary,
                    onDestinationSelected: (value) =>
                        setState(() => _navIndex = _primaryPageIndexes[value]),
                    destinations: [
                      NavigationDestination(
                        icon: const Icon(Icons.dashboard_outlined),
                        label: l10n.t('overview'),
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.table_chart_outlined),
                        label: l10n.t('sheetEditor'),
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.history_outlined),
                        label: l10n.t('historyTitle'),
                      ),
                      NavigationDestination(
                        icon: const Icon(Icons.upload_outlined),
                        label: l10n.t('export'),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _overviewPage(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final brand = Theme.of(context).extension<BrandColors>()!;
    final summary = state.workbookSummary;
    final workbook = state.workbook;
    final current = state.currentSheet;
    return ListView(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _statCard(
                context,
                l10n.t('totalSheets'),
                '${summary['sheets']}',
                scheme.primary.withValues(alpha: 0.08),
              ),
              _statCard(
                context,
                l10n.t('totalLearners'),
                '${summary['learners']}',
                scheme.tertiary.withValues(alpha: 0.15),
              ),
              _statCard(
                context,
                l10n.t('errors'),
                '${summary['errors']}',
                scheme.secondary.withValues(alpha: 0.14),
              ),
              _statCard(
                context,
                l10n.t('warnings'),
                '${summary['warnings']}',
                brand.gold.withValues(alpha: 0.18),
              ),
              _statCard(
                context,
                l10n.t('exportReady'),
                summary['errors'] == 0 ? l10n.t('safe') : l10n.t('risky'),
                summary['errors'] == 0
                    ? scheme.tertiary.withValues(alpha: 0.15)
                    : scheme.secondary.withValues(alpha: 0.14),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            title: Text(workbook?.fileName ?? ''),
            subtitle: Text('${l10n.t('editedCells')}: ${state.totalEdits}'),
            trailing: FilledButton.icon(
              onPressed: () {
                state.runValidation();
                showValidationPopup(
                  context,
                  l10n,
                  state.workbookSummary,
                  () => setState(() => _navIndex = 3),
                );
              },
              icon: const Icon(Icons.rule_rounded),
              label: Text(l10n.t('runValidation')),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  current?.name ?? '-',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ...?workbook?.sheets.map(
                (sheet) => ListTile(
                  title: Text(sheet.name),
                  subtitle: Text(
                    '${l10n.t('learnersCount')}: ${sheet.learnerCount}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
                    onPressed: () {
                      state.setSelectedSheet(workbook.sheets.indexOf(sheet));
                      setState(() => _navIndex = 1);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _aboutUsCard(context, state, l10n),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _sheetEditorPage(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final brand = Theme.of(context).extension<BrandColors>()!;
    final workbook = state.workbook;
    final sheet = state.currentSheet;
    final identityWidth = _adaptiveIdentityWidth(state.filteredRows);
    if (workbook == null || sheet == null) {
      return Center(child: Text(l10n.t('noWorkbook')));
    }

    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 760;
            final sheetDropdown = DropdownButton<int>(
              value: state.selectedSheet,
              onChanged: (v) {
                if (v != null) {
                  state.setSelectedSheet(v);
                }
              },
              items: List<DropdownMenuItem<int>>.generate(
                workbook.sheets.length,
                (index) => DropdownMenuItem<int>(
                  value: index,
                  child: Text(workbook.sheets[index].name),
                ),
              ),
            );
            final searchField = TextField(
              controller: _searchController,
              onChanged: (value) {
                if (_isGlobalSearch) {
                  setState(() => _globalSearch = value);
                } else {
                  _sheetSearch = value;
                  state.setQuery(value);
                }
              },
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                labelText: l10n.t('search'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            );
            final scopeToggle = SegmentedButton<bool>(
              segments: [
                ButtonSegment<bool>(
                  value: false,
                  label: Text(l10n.t('sheetSearch')),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text(l10n.t('globalSearch')),
                ),
              ],
              selected: {_isGlobalSearch},
              onSelectionChanged: (values) {
                setState(() {
                  _isGlobalSearch = values.first;
                  _searchController.text = _isGlobalSearch
                      ? _globalSearch
                      : _sheetSearch;
                  if (!_isGlobalSearch) {
                    state.setQuery(_sheetSearch);
                  }
                });
              },
            );
            final filterDropdown = DropdownButton<LearnerFilter>(
              value: state.activeFilter,
              onChanged: (v) {
                if (v != null) {
                  state.setFilter(v);
                }
              },
              items: [
                _filterItem(LearnerFilter.all, l10n.t('all')),
                _filterItem(LearnerFilter.emptyScore, l10n.t('emptyScore')),
                _filterItem(LearnerFilter.zeroScore, l10n.t('zeroScore')),
                _filterItem(LearnerFilter.invalidScore, l10n.t('invalidScore')),
                _filterItem(
                  LearnerFilter.missingRemark,
                  l10n.t('missingRemark'),
                ),
                _filterItem(LearnerFilter.editedOnly, l10n.t('editedOnly')),
                _filterItem(LearnerFilter.problemsOnly, l10n.t('problemsOnly')),
              ],
            );

            return Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                sheetDropdown,
                SizedBox(
                  width: isWide ? 320 : constraints.maxWidth,
                  child: searchField,
                ),
                scopeToggle,
                filterDropdown,
                IconButton(
                  tooltip: l10n.t('bulkActions'),
                  onPressed: () => showBulkActionsPopup(context, state, l10n),
                  icon: Icon(Icons.bolt_rounded, color: scheme.secondary),
                ),
              ],
            );
          },
        ),
        if (_isGlobalSearch && _globalSearch.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Text(
                  l10n.format('searchResults', {
                    'count': '${state.globalSearch(_globalSearch).length}',
                  }),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () =>
                      _showSearchResultsSheet(context, state, l10n),
                  icon: const Icon(Icons.open_in_full_rounded),
                  label: Text(l10n.t('viewResults')),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            _legendDot(
              brand.gold.withValues(alpha: 0.22),
              l10n.t('needsAttention'),
            ),
            const SizedBox(width: 10),
            _legendDot(
              scheme.tertiary.withValues(alpha: 0.15),
              l10n.t('ready'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: 1200,
              child: ListView.builder(
                itemCount: state.filteredRows.length,
                itemBuilder: (context, index) {
                  final row = state.filteredRows[index];
                  final hasIssue = state.issues.any(
                    (i) =>
                        i.sheetName == row.sheetName &&
                        i.rowIndex == row.rowIndex,
                  );
                  return Card(
                    color: hasIssue
                        ? brand.gold.withValues(alpha: 0.22)
                        : scheme.tertiary.withValues(alpha: 0.15),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 44,
                            child: Text('${row.rowIndex + 1}'),
                          ),
                          SizedBox(
                            width: identityWidth,
                            child: Text(
                              row.identity,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                            ),
                          ),
                          SizedBox(width: 140, child: Text(row.surname)),
                          SizedBox(width: 140, child: Text(row.name)),
                          SizedBox(width: 120, child: Text(row.matricule)),
                          SizedBox(
                            width: 90,
                            child: _scoreField(
                              initial: row.continuous,
                              onSubmit: (v) => state.updateScore(
                                sheetName: row.sheetName,
                                rowIndex: row.rowIndex,
                                column: ScoreColumn.continuous,
                                value: v,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 90,
                            child: _scoreField(
                              initial: row.test,
                              onSubmit: (v) => state.updateScore(
                                sheetName: row.sheetName,
                                rowIndex: row.rowIndex,
                                column: ScoreColumn.test,
                                value: v,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 90,
                            child: _scoreField(
                              initial: row.exam,
                              onSubmit: (v) => state.updateScore(
                                sheetName: row.sheetName,
                                rowIndex: row.rowIndex,
                                column: ScoreColumn.exam,
                                value: v,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextFormField(
                              initialValue: row.remark,
                              onFieldSubmitted: (v) => state.updateRemark(
                                sheetName: row.sheetName,
                                rowIndex: row.rowIndex,
                                remark: v,
                              ),
                              decoration: InputDecoration(
                                labelText: l10n.t('remark'),
                                border: const OutlineInputBorder(),
                                isDense: true,
                                suffixIcon: PopupMenuButton<String>(
                                  icon: const Icon(
                                    Icons.lightbulb_outline_rounded,
                                  ),
                                  onSelected: (value) => state.updateRemark(
                                    sheetName: row.sheetName,
                                    rowIndex: row.rowIndex,
                                    remark: value,
                                  ),
                                  itemBuilder: (context) => state
                                      .favoriteRemarks
                                      .map(
                                        (e) => PopupMenuItem<String>(
                                          value: e,
                                          child: Text(e),
                                        ),
                                      )
                                      .toList(),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () =>
                                state.resetRow(row.sheetName, row.rowIndex),
                            icon: Icon(
                              Icons.refresh_rounded,
                              color: scheme.secondary,
                            ),
                            tooltip: l10n.t('resetRow'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Future<void> _showSearchResultsSheet(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) async {
    final results = state.globalSearch(_globalSearch);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.75,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.search_rounded, color: scheme.secondary),
                      const SizedBox(width: 8),
                      Text(
                        l10n.t('globalSearch'),
                        style: Theme.of(sheetContext).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      Text(
                        l10n.format('searchResults', {
                          'count': '${results.length}',
                        }),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: results.isEmpty
                      ? Center(child: Text(l10n.t('noResults')))
                      : ListView.builder(
                          itemCount: results.length,
                          itemBuilder: (context, index) {
                            final result = results[index];
                            return ListTile(
                              title: Text(
                                '${result.learner.surname} ${result.learner.name}',
                              ),
                              subtitle: Text(
                                '${result.sheetName} | ${l10n.t('row')} ${result.rowIndex + 1}',
                              ),
                              trailing: FilledButton(
                                onPressed: () {
                                  state.setSelectedSheet(result.sheetIndex);
                                  setState(() {
                                    _navIndex = 1;
                                    state.setQuery(
                                      result.learner.matricule.isNotEmpty
                                          ? result.learner.matricule
                                          : result.learner.name,
                                    );
                                  });
                                  Navigator.pop(sheetContext);
                                },
                                child: Text(l10n.t('jump')),
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
  }

  Future<void> showBulkActionsPopup(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) async {
    final fillController = TextEditingController(text: '10');
    bool localBusy = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.t('bulkActions'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(l10n.t('bulkHowStep1')),
                      Text(l10n.t('bulkHowStep2')),
                      Text(l10n.t('bulkHowStep3')),
                      const SizedBox(height: 12),
                      Text(
                        l10n.t('buildRemarkRules'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(l10n.t('rulesHelp')),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          SizedBox(
                            width: 100,
                            child: TextField(
                              controller: _ruleMinController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                labelText: l10n.t('from'),
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 100,
                            child: TextField(
                              controller: _ruleMaxController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                labelText: l10n.t('to'),
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 260,
                            child: TextField(
                              controller: _ruleRemarkController,
                              decoration: InputDecoration(
                                labelText: l10n.t('remark'),
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: () {
                              final min =
                                  double.tryParse(
                                    _ruleMinController.text.trim(),
                                  ) ??
                                  0;
                              final max =
                                  double.tryParse(
                                    _ruleMaxController.text.trim(),
                                  ) ??
                                  0;
                              final remark = _ruleRemarkController.text.trim();
                              if (remark.isEmpty || max < min) {
                                return;
                              }
                              final rule = RemarkRule(
                                min: min,
                                max: max,
                                remark: remark,
                              );
                              if (_editingRuleIndex == null) {
                                state.addRemarkRule(rule);
                              } else {
                                state.updateRemarkRule(
                                  _editingRuleIndex!,
                                  rule,
                                );
                              }
                              setModalState(() {
                                _editingRuleIndex = null;
                                _ruleMinController.clear();
                                _ruleMaxController.clear();
                                _ruleRemarkController.clear();
                              });
                            },
                            icon: const Icon(Icons.add_task_rounded),
                            label: Text(
                              _editingRuleIndex == null
                                  ? l10n.t('addRule')
                                  : l10n.t('updateRule'),
                            ),
                          ),
                          if (_editingRuleIndex != null)
                            OutlinedButton(
                              onPressed: () {
                                setModalState(() {
                                  _editingRuleIndex = null;
                                  _ruleMinController.clear();
                                  _ruleMaxController.clear();
                                  _ruleRemarkController.clear();
                                });
                              },
                              child: Text(l10n.t('cancelEdit')),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...List<Widget>.generate(state.remarkRules.length, (
                        index,
                      ) {
                        final rule = state.remarkRules[index];
                        return Card(
                          color: const Color(0xFFF9FBFF),
                          child: ListTile(
                            title: Text(
                              '${rule.min} - ${rule.max}  ->  ${rule.remark}',
                            ),
                            trailing: Wrap(
                              spacing: 4,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_rounded),
                                  onPressed: () {
                                    setModalState(() {
                                      _editingRuleIndex = index;
                                      _ruleMinController.text = rule.min
                                          .toString();
                                      _ruleMaxController.text = rule.max
                                          .toString();
                                      _ruleRemarkController.text = rule.remark;
                                    });
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                  ),
                                  onPressed: () {
                                    state.deleteRemarkRule(index);
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: 320,
                            child: DropdownButton<ScoreSource>(
                              value: _selectedScoreSource,
                              isExpanded: true,
                              onChanged: (value) {
                                if (value != null) {
                                  setModalState(
                                    () => _selectedScoreSource = value,
                                  );
                                }
                              },
                              items: [
                                DropdownMenuItem(
                                  value: ScoreSource.exam,
                                  child: Text(l10n.t('useExamScore')),
                                ),
                                DropdownMenuItem(
                                  value: ScoreSource.test,
                                  child: Text(l10n.t('useTestScore')),
                                ),
                                DropdownMenuItem(
                                  value: ScoreSource.continuous,
                                  child: Text(l10n.t('useContinuousScore')),
                                ),
                                DropdownMenuItem(
                                  value: ScoreSource.average,
                                  child: Text(l10n.t('useAverageScore')),
                                ),
                              ],
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: localBusy
                                ? null
                                : () async {
                                    final preview = state
                                        .previewRemarkRulesAffected(
                                          scope: ApplyScope.currentSheet,
                                          scoreSource: _selectedScoreSource,
                                        );
                                    final confirm = await _confirmDialog(
                                      context,
                                      l10n.t('confirmAction'),
                                      '${l10n.t('confirmApplyRules')}\n${l10n.t('affectedLearners')}: $preview',
                                      l10n,
                                    );
                                    if (!confirm) return;
                                    setModalState(() => localBusy = true);
                                    final affected = state.applyRemarkRules(
                                      scope: ApplyScope.currentSheet,
                                      scoreSource: _selectedScoreSource,
                                    );
                                    if (context.mounted) {
                                      setModalState(() => localBusy = false);
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            '${l10n.t('done')}: ${l10n.t('affectedLearners')} $affected',
                                          ),
                                        ),
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: Text(l10n.t('applyRulesNow')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(l10n.t('quickFillOptional')),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: fillController,
                              decoration: InputDecoration(
                                labelText: l10n.t('emptyScore'),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ),
                          FilledButton(
                            onPressed: () => state.fillEmptyScores(
                              double.tryParse(fillController.text.trim()) ?? 0,
                            ),
                            child: Text(l10n.t('fillEmptyScores')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(l10n.t('advancedScoreTools')),
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: () async {
                                  var clearContinuous = false;
                                  var clearTest = false;
                                  var clearExam = false;
                                  var clearRemark = false;
                                  final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => StatefulBuilder(
                                      builder: (context, setDialogState) {
                                        return AlertDialog(
                                          title: Text(
                                            l10n.t('confirmClearCells'),
                                          ),
                                          content: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              CheckboxListTile(
                                                value: clearContinuous,
                                                title: Text(
                                                  l10n.t('clearContinuous'),
                                                ),
                                                onChanged: (v) =>
                                                    setDialogState(
                                                      () => clearContinuous =
                                                          v ?? false,
                                                    ),
                                              ),
                                              CheckboxListTile(
                                                value: clearTest,
                                                title: Text(
                                                  l10n.t('clearTest'),
                                                ),
                                                onChanged: (v) =>
                                                    setDialogState(
                                                      () => clearTest =
                                                          v ?? false,
                                                    ),
                                              ),
                                              CheckboxListTile(
                                                value: clearExam,
                                                title: Text(
                                                  l10n.t('clearExam'),
                                                ),
                                                onChanged: (v) =>
                                                    setDialogState(
                                                      () => clearExam =
                                                          v ?? false,
                                                    ),
                                              ),
                                              CheckboxListTile(
                                                value: clearRemark,
                                                title: Text(
                                                  l10n.t('clearRemark'),
                                                ),
                                                onChanged: (v) =>
                                                    setDialogState(
                                                      () => clearRemark =
                                                          v ?? false,
                                                    ),
                                              ),
                                            ],
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context, false),
                                              child: Text(l10n.t('cancel')),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(context, true),
                                              child: Text(l10n.t('confirm')),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  );
                                  if (confirmed != true) return;
                                  if (!clearContinuous &&
                                      !clearTest &&
                                      !clearExam &&
                                      !clearRemark) {
                                    return;
                                  }
                                  state
                                      .clearSelectedEditableCellsForCurrentSheet(
                                        clearContinuous: clearContinuous,
                                        clearTest: clearTest,
                                        clearExam: clearExam,
                                        clearRemark: clearRemark,
                                      );
                                },
                                child: Text(l10n.t('clearEditableCells')),
                              ),
                              OutlinedButton(
                                onPressed: () =>
                                    state.setScoreValueForFiltered(10),
                                child: Text(l10n.t('setFilteredTo10')),
                              ),
                              OutlinedButton(
                                onPressed: () =>
                                    state.randomizeScoresForFiltered(8, 15),
                                child: Text(l10n.t('randomize8to15')),
                              ),
                            ],
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
    );
    fillController.dispose();
  }

  Widget _validationPage(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) {
    return Column(
      children: [
        Row(
          children: [
            FilledButton.icon(
              onPressed: () {
                state.runValidation();
                showValidationPopup(
                  context,
                  l10n,
                  state.workbookSummary,
                  () => setState(() => _navIndex = 3),
                );
              },
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(l10n.t('runValidation')),
            ),
            const SizedBox(width: 8),
            Text('${l10n.t('issuesCount')}: ${state.issues.length}'),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: state.issues.length,
            itemBuilder: (context, index) {
              final issue = state.issues[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.warning_amber_rounded),
                  title: Text(issue.message),
                  subtitle: Text(
                    '${issue.sheetName} | ${l10n.t('row')} ${issue.rowIndex + 1}',
                  ),
                  trailing: Text(_issueTypeLabel(issue.type, l10n)),
                  onTap: () {
                    final wb = state.workbook;
                    if (wb == null) {
                      return;
                    }
                    final sheetIndex = wb.sheets.indexWhere(
                      (s) => s.name == issue.sheetName,
                    );
                    if (sheetIndex != -1) {
                      state.setSelectedSheet(sheetIndex);
                      setState(() => _navIndex = 1);
                    }
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _rulesPage(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) {
    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.t('rulesAndPresets'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(l10n.t('rulesPresetsHint')),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: state.favoriteRemarks
                      .map((e) => Chip(label: Text(e)))
                      .toList(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _settingsPage(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) {
    final minController = TextEditingController(
      text: state.validationSettings.minScore.toString(),
    );
    final maxController = TextEditingController(
      text: state.validationSettings.maxScore.toString(),
    );
    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.t('settings'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                DropdownButton<Locale>(
                  value: state.locale,
                  onChanged: (value) {
                    if (value != null) {
                      state.setLocale(value);
                    }
                  },
                  items: [
                    DropdownMenuItem(
                      value: const Locale('en'),
                      child: const Text('English'),
                    ),
                    DropdownMenuItem(
                      value: const Locale('fr'),
                      child: const Text('Français'),
                    ),
                    DropdownMenuItem(
                      value: const Locale('ar'),
                      child: const Text('العربية'),
                    ),
                    DropdownMenuItem(
                      value: const Locale('de'),
                      child: const Text('Deutsch'),
                    ),
                    DropdownMenuItem(
                      value: const Locale('es'),
                      child: const Text('Español'),
                    ),
                    DropdownMenuItem(
                      value: const Locale('it'),
                      child: const Text('Italiano'),
                    ),
                  ],
                ),
                SwitchListTile(
                  value: state.autoRemark,
                  onChanged: state.setAutoRemark,
                  title: Text(l10n.t('autoRemark')),
                ),
                SwitchListTile(
                  value: state.validationSettings.zeroValid,
                  onChanged: (v) => state.updateValidationSettings(
                    state.validationSettings.copyWith(zeroValid: v),
                  ),
                  title: Text(l10n.t('zeroValid')),
                ),
                SwitchListTile(
                  value: state.validationSettings.remarkRequired,
                  onChanged: (v) => state.updateValidationSettings(
                    state.validationSettings.copyWith(remarkRequired: v),
                  ),
                  title: Text(l10n.t('remarkRequired')),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: minController,
                        decoration: InputDecoration(
                          labelText: l10n.t('minScore'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: maxController,
                        decoration: InputDecoration(
                          labelText: l10n.t('maxScore'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: () => state.updateValidationSettings(
                        state.validationSettings.copyWith(
                          minScore:
                              double.tryParse(minController.text.trim()) ?? 0,
                          maxScore:
                              double.tryParse(maxController.text.trim()) ?? 20,
                        ),
                      ),
                      child: Text(l10n.t('saveSettings')),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(l10n.t('advancedResetTools')),
                  children: [
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: () async {
                            final confirmed = await _confirmDialog(
                              context,
                              l10n.t('confirmAction'),
                              l10n.t('resetSheet'),
                              l10n,
                            );
                            if (!confirmed) {
                              return;
                            }
                            setState(() => _pageLoading = true);
                            await Future<void>.delayed(
                              const Duration(milliseconds: 150),
                            );
                            state.resetCurrentSheet();
                            if (mounted) {
                              setState(() => _pageLoading = false);
                              await showProcessDoneLogoAnimation(this.context);
                            }
                          },
                          child: Text(l10n.t('resetSheet')),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            final confirmed = await _confirmDialog(
                              context,
                              l10n.t('confirmAction'),
                              l10n.t('restoreAll'),
                              l10n,
                            );
                            if (!confirmed) {
                              return;
                            }
                            setState(() => _pageLoading = true);
                            await Future<void>.delayed(
                              const Duration(milliseconds: 150),
                            );
                            state.restoreWorkbook();
                            if (mounted) {
                              setState(() => _pageLoading = false);
                              await showProcessDoneLogoAnimation(this.context);
                            }
                          },
                          child: Text(l10n.t('restoreAll')),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _aboutUsCard(context, state, l10n),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _exportPage(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) {
    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.t('exportWorkbook'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text('${l10n.t('errors')}: ${state.workbookSummary['errors']}'),
                Text(
                  '${l10n.t('warnings')}: ${state.workbookSummary['warnings']}',
                ),
                Text('${l10n.t('backups')}: ${state.snapshots.length}'),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () async {
                    final confirmed = await _confirmDialog(
                      context,
                      l10n.t('confirmAction'),
                      l10n.t('exportWorkbook'),
                      l10n,
                    );
                    if (!confirmed) {
                      return;
                    }
                    setState(() => _pageLoading = true);
                    final report = await state.exportWorkbook();
                    if (!context.mounted || report == null) {
                      if (mounted) {
                        setState(() => _pageLoading = false);
                      }
                      return;
                    }
                    setState(() => _pageLoading = false);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '${l10n.t('integrityCheck')}: '
                          '${report.isSafe ? l10n.t('pass') : l10n.t('fail')} - '
                          '${report.isSafe ? l10n.t('integrityPassed') : l10n.t('integrityDifferences')}',
                        ),
                      ),
                    );
                    await showProcessDoneLogoAnimation(context);
                    if (!context.mounted) {
                      return;
                    }
                    await _showExportSavedDialog(context, l10n, report);
                  },
                  icon: const Icon(Icons.download_rounded, color: Colors.green),
                  label: Text(l10n.t('exportWorkbook')),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    state.createEditableBackupCopy();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.t('createBackup'))),
                    );
                    await showProcessDoneLogoAnimation(context);
                  },
                  icon: const Icon(Icons.backup_rounded, color: Colors.orange),
                  label: Text(l10n.t('createBackup')),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.t('backups'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                ...state.snapshots.reversed.map(
                  (snap) => ListTile(
                    dense: true,
                    title: Text(snap.label),
                    subtitle: Text(snap.createdAt.toIso8601String()),
                    trailing: Text(
                      '${snap.changedCells.length} ${l10n.t('edits')}',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _scoreField({
    required double? initial,
    required ValueChanged<String> onSubmit,
  }) {
    return TextFormField(
      initialValue: initial?.toStringAsFixed(1) ?? '',
      onFieldSubmitted: onSubmit,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  double _adaptiveIdentityWidth(List<LearnerRow> rows) {
    if (rows.isEmpty) {
      return 120;
    }
    var longest = 10;
    for (final row in rows) {
      final length = row.identity.trim().length;
      if (length > longest) {
        longest = length;
      }
    }
    final estimated = 16 + (longest * 7.0);
    return estimated.clamp(120.0, 320.0);
  }

  Widget _statCard(
    BuildContext context,
    String label,
    String value,
    Color background,
  ) {
    return Container(
      margin: const EdgeInsets.only(right: 10),
      child: Card(
        color: background,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF99A1AE)),
          ),
        ),
        const SizedBox(width: 6),
        Text(text),
      ],
    );
  }

  DropdownMenuItem<LearnerFilter> _filterItem(
    LearnerFilter value,
    String label,
  ) {
    return DropdownMenuItem<LearnerFilter>(value: value, child: Text(label));
  }

  String _issueTypeLabel(RowIssueType type, AppLocalizations l10n) {
    switch (type) {
      case RowIssueType.emptyScore:
        return l10n.t('emptyScore');
      case RowIssueType.zeroScore:
        return l10n.t('zeroScore');
      case RowIssueType.invalidScore:
        return l10n.t('invalidScore');
      case RowIssueType.outOfRange:
        return l10n.t('outOfRange');
      case RowIssueType.missingRemark:
        return l10n.t('missingRemark');
      case RowIssueType.inconsistentRemark:
        return l10n.t('inconsistentRemark');
      case RowIssueType.incompleteRow:
        return l10n.t('incompleteRow');
    }
  }

  Future<void> _showExportSavedDialog(
    BuildContext context,
    AppLocalizations l10n,
    ExportReport report,
  ) async {
    final location = report.savedPath.trim().isEmpty
        ? l10n.t('downloadsFolder')
        : report.savedPath;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.t('exportDone')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${l10n.t('savedAs')}: ${report.exportedFileName}'),
            const SizedBox(height: 8),
            Text('${l10n.t('savedAt')}: $location'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.t('cancel')),
          ),
          OutlinedButton(
            onPressed: report.savedPath.trim().isEmpty
                ? null
                : () async {
                    final result = await OpenFilex.open(report.savedPath);
                    if (!context.mounted) {
                      return;
                    }
                    if (result.type != ResultType.done) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(result.message)));
                    }
                  },
            child: Text(l10n.t('openFile')),
          ),
          FilledButton(
            onPressed: () async {
              final xlsxMime =
                  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
              final xfile = report.savedPath.trim().isEmpty
                  ? XFile.fromData(
                      report.encodedBytes,
                      mimeType: xlsxMime,
                      name: report.exportedFileName,
                    )
                  : XFile(
                      report.savedPath,
                      mimeType: xlsxMime,
                      name: report.exportedFileName,
                    );
              await SharePlus.instance.share(
                ShareParams(files: [xfile], subject: report.exportedFileName),
              );
            },
            child: Text(l10n.t('shareFile')),
          ),
        ],
      ),
    );
  }
}
