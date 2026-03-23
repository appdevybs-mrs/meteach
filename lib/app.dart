import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'l10n/app_localizations.dart';
import 'models/workbook_models.dart';
import 'state/app_state.dart';
import 'widgets/meteach_logo.dart';

Widget _logoWatermark({double opacity = 0.06}) {
  return IgnorePointer(
    child: Center(
      child: Opacity(
        opacity: opacity,
        child: Image.asset('assets/logo.png', width: 380, fit: BoxFit.contain),
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
                Image.asset(
                  'assets/logo.png',
                  width: 82,
                  height: 82,
                  fit: BoxFit.contain,
                ),
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
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF0D6E6E),
                brightness: Brightness.light,
              ),
              scaffoldBackgroundColor: const Color(0xFFEFF4FF),
              iconTheme: const IconThemeData(color: Color(0xFF0D6E6E)),
              appBarTheme: const AppBarTheme(
                backgroundColor: Color(0xFFDDEBFF),
                foregroundColor: Color(0xFF114B5F),
              ),
              cardTheme: const CardThemeData(
                color: Colors.white,
                elevation: 0.8,
              ),
              inputDecorationTheme: const InputDecorationTheme(
                filled: true,
                fillColor: Color(0xFFFAFCFF),
                border: OutlineInputBorder(),
              ),
            ),
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
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF114B5F), Color(0xFF1A936F), Color(0xFFF3E9D2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _logoWatermark(opacity: 0.11),
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
                        ),
                        alignment: Alignment.center,
                        child: Image.asset(
                          'assets/logo.png',
                          width: 72,
                          height: 72,
                          fit: BoxFit.contain,
                        ),
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

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Widget _guideStep(
    BuildContext context,
    Color color,
    IconData icon,
    String text,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = context.watch<MeTeachState>();
    return Scaffold(
      appBar: AppBar(
        title: const MeTeachLogo(size: 36, showLabel: true),
        actions: [
          IconButton(
            tooltip: l10n.t('showGuide'),
            onPressed: () => state.setShowGuide(!state.showGuide),
            icon: Icon(
              state.showGuide
                  ? Icons.visibility_off_rounded
                  : Icons.help_rounded,
              color: const Color(0xFF1976D2),
            ),
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
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFDCEBFF), Color(0xFFF3FBFF), Color(0xFFE2F8F0)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _logoWatermark(opacity: 0.055),
                ListView(
                  padding: const EdgeInsets.all(22),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF114B5F), Color(0xFF1A936F)],
                        ),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          const MeTeachLogo(size: 60),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.t('welcome'),
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [
                                    FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.white,
                                        foregroundColor: const Color(
                                          0xFF114B5F,
                                        ),
                                      ),
                                      onPressed: state.busy
                                          ? null
                                          : () async {
                                              final ok = await state
                                                  .importWorkbookFromPicker();
                                              if (!context.mounted) {
                                                return;
                                              }
                                              if (ok) {
                                                await showProcessDoneLogoAnimation(
                                                  context,
                                                );
                                                if (!context.mounted) {
                                                  return;
                                                }
                                                Navigator.of(context).push(
                                                  MaterialPageRoute<void>(
                                                    builder: (_) =>
                                                        const WorkspaceScreen(),
                                                  ),
                                                );
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
                                          : const Icon(
                                              Icons.upload_file_rounded,
                                            ),
                                      label: Text(l10n.t('uploadWorkbook')),
                                    ),
                                    if (state.recentWorkbooks.isNotEmpty)
                                      OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          side: const BorderSide(
                                            color: Colors.white,
                                          ),
                                          foregroundColor: Colors.white,
                                        ),
                                        onPressed: () async {
                                          final ok = state.reopenRecentWorkbook(
                                            0,
                                          );
                                          if (ok) {
                                            await showProcessDoneLogoAnimation(
                                              context,
                                            );
                                            if (!context.mounted) {
                                              return;
                                            }
                                            Navigator.of(context).push(
                                              MaterialPageRoute<void>(
                                                builder: (_) =>
                                                    const WorkspaceScreen(),
                                              ),
                                            );
                                          }
                                        },
                                        icon: const Icon(Icons.history_rounded),
                                        label: Text(l10n.t('reopen')),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (state.showGuide)
                      Card(
                        color: const Color(0xFFF0F7FF),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.tips_and_updates_rounded,
                                    color: Color(0xFF1976D2),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    l10n.t('guideTitle'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const Spacer(),
                                  TextButton(
                                    onPressed: () => state.setShowGuide(false),
                                    child: Text(l10n.t('skipGuide')),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              _guideStep(
                                context,
                                const Color(0xFF1E88E5),
                                Icons.upload_file_rounded,
                                l10n.t('guideStep1'),
                              ),
                              _guideStep(
                                context,
                                const Color(0xFF43A047),
                                Icons.rule_folder_rounded,
                                l10n.t('guideStep2'),
                              ),
                              _guideStep(
                                context,
                                const Color(0xFFF57C00),
                                Icons.verified_rounded,
                                l10n.t('guideStep3'),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                l10n.t('guideHint'),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (state.showGuide) const SizedBox(height: 14),
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
                                  color: Color(0xFF1976D2),
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
                                  color: const Color(0xFFF7FAFF),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(0xFFD8E6FF),
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    const Icon(
                                      Icons.auto_stories_rounded,
                                      size: 30,
                                      color: Color(0xFF42A5F5),
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
                                    color: const Color(0xFFF8FBFF),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.description_outlined,
                                        color: Color(0xFF1976D2),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(item.displayName),
                                            Text(
                                              '${l10n.t('openedAt')}: ${item.openedAt.toLocal().toString().replaceFirst('.000', '')}',
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                            ),
                                          ],
                                        ),
                                      ),
                                      OutlinedButton(
                                        onPressed: () async {
                                          final ok = state.reopenRecentWorkbook(
                                            entry.key,
                                          );
                                          if (ok) {
                                            await showProcessDoneLogoAnimation(
                                              context,
                                            );
                                            if (!context.mounted) {
                                              return;
                                            }
                                            Navigator.of(context).push(
                                              MaterialPageRoute<void>(
                                                builder: (_) =>
                                                    const WorkspaceScreen(),
                                              ),
                                            );
                                          }
                                        },
                                        child: Text(l10n.t('reopen')),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.drive_file_rename_outline,
                                          color: Color(0xFF8E24AA),
                                        ),
                                        onPressed: () {
                                          final controller =
                                              TextEditingController(
                                                text: item.displayName,
                                              );
                                          showDialog<void>(
                                            context: context,
                                            builder: (context) => AlertDialog(
                                              title: Text(l10n.t('rename')),
                                              content: TextField(
                                                controller: controller,
                                                autofocus: true,
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(context),
                                                  child: Text(l10n.t('cancel')),
                                                ),
                                                FilledButton(
                                                  onPressed: () {
                                                    state.renameRecentWorkbook(
                                                      entry.key,
                                                      controller.text,
                                                    );
                                                    Navigator.pop(context);
                                                  },
                                                  child: Text(
                                                    l10n.t('saveSettings'),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          color: Color(0xFFE53935),
                                        ),
                                        onPressed: () => state
                                            .deleteRecentWorkbook(entry.key),
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
              ],
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
  int _navIndex = 0;
  String _globalSearch = '';
  static const List<int> _primaryPageIndexes = <int>[0, 1, 2, 3, 7];
  final TextEditingController _ruleMinController = TextEditingController();
  final TextEditingController _ruleMaxController = TextEditingController();
  final TextEditingController _ruleRemarkController = TextEditingController();
  ApplyScope _selectedScope = ApplyScope.allSheets;
  ScoreSource _selectedScoreSource = ScoreSource.exam;
  int? _editingRuleIndex;
  bool _bulkProcessing = false;
  String _bulkFeedback = '';
  bool _pageLoading = false;

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MeTeachState>();
    final l10n = AppLocalizations.of(context);
    if (!state.hasWorkbook) {
      return const HomeScreen();
    }

    final pages = [
      _overviewPage(context, state, l10n),
      _sheetEditorPage(context, state, l10n),
      _globalSearchPage(context, state, l10n),
      _bulkPage(context, state, l10n),
      _validationPage(context, state, l10n),
      _rulesPage(context, state, l10n),
      _settingsPage(context, state, l10n),
      _exportPage(context, state, l10n),
    ];

    final labels = [
      l10n.t('overview'),
      l10n.t('sheetEditor'),
      l10n.t('globalSearch'),
      l10n.t('bulkActions'),
      l10n.t('validation'),
      l10n.t('rulesPresets'),
      l10n.t('settings'),
      l10n.t('export'),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 980;
        final selectedPrimary = _primaryPageIndexes.indexOf(_navIndex);
        return Scaffold(
          appBar: AppBar(
            title: Text('${l10n.t('appTitle')} - ${labels[_navIndex]}'),
            actions: [
              IconButton(
                onPressed: state.undoLast,
                icon: const Icon(Icons.undo_rounded),
                tooltip: l10n.t('undoLast'),
              ),
            ],
          ),
          body: Stack(
            children: [
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0xFFEAF3FF),
                      Color(0xFFF6FBFF),
                      Color(0xFFE5F7F2),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
              _logoWatermark(opacity: 0.05),
              Row(
                children: [
                  if (wide)
                    NavigationRail(
                      selectedIndex: selectedPrimary < 0 ? 0 : selectedPrimary,
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
                          icon: const Icon(Icons.search_outlined),
                          selectedIcon: const Icon(Icons.search),
                          label: Text(l10n.t('globalSearch')),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.bolt_outlined),
                          selectedIcon: const Icon(Icons.bolt),
                          label: Text(l10n.t('bulkActions')),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.upload_outlined),
                          selectedIcon: const Icon(Icons.upload),
                          label: Text(l10n.t('export')),
                        ),
                      ],
                    ),
                  Expanded(
                    child: Column(
                      children: [
                        Container(
                          margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.88),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFD4E4FF)),
                          ),
                          child: Wrap(
                            spacing: 16,
                            runSpacing: 6,
                            children: [
                              Text(
                                '${l10n.t('lastSaved')}: '
                                '${state.lastSavedAt?.toLocal().toString().replaceFirst('.000', '') ?? '-'}',
                              ),
                              Text(
                                '${l10n.t('rowsEdited')}: ${state.editedRowsCount}',
                              ),
                              Text(
                                '${l10n.t('exportSafety')}: '
                                '${state.workbookSummary['errors'] == 0 ? l10n.t('safe') : l10n.t('risky')}',
                              ),
                            ],
                          ),
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
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 10),
                            Text(l10n.t('processing')),
                          ],
                        ),
                      ),
                    ),
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
                      icon: const Icon(Icons.search_outlined),
                      label: l10n.t('globalSearch'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.bolt_outlined),
                      label: l10n.t('bulkActions'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.upload_outlined),
                      label: l10n.t('export'),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _overviewPage(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) {
    final summary = state.workbookSummary;
    final workbook = state.workbook;
    final current = state.currentSheet;
    return ListView(
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _statCard(
              context,
              l10n.t('totalSheets'),
              '${summary['sheets']}',
              const Color(0xFFE3F2FD),
            ),
            _statCard(
              context,
              l10n.t('totalLearners'),
              '${summary['learners']}',
              const Color(0xFFE8F5E9),
            ),
            _statCard(
              context,
              l10n.t('errors'),
              '${summary['errors']}',
              const Color(0xFFFFEBEE),
            ),
            _statCard(
              context,
              l10n.t('warnings'),
              '${summary['warnings']}',
              const Color(0xFFFFF8E1),
            ),
            _statCard(
              context,
              l10n.t('exportReady'),
              summary['errors'] == 0 ? l10n.t('safe') : l10n.t('risky'),
              summary['errors'] == 0
                  ? const Color(0xFFE8F5E9)
                  : const Color(0xFFFFEBEE),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            title: Text(workbook?.fileName ?? ''),
            subtitle: Text('${l10n.t('editedCells')}: ${state.totalEdits}'),
            trailing: FilledButton.icon(
              onPressed: state.runValidation,
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
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  avatar: const Icon(Icons.table_chart_rounded, size: 16),
                  label: Text(l10n.t('sheetEditor')),
                ),
                Chip(
                  avatar: const Icon(Icons.search_rounded, size: 16),
                  label: Text(l10n.t('globalSearch')),
                ),
                Chip(
                  avatar: const Icon(Icons.tune_rounded, size: 16),
                  label: Text(l10n.t('advancedToolsHint')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sheetEditorPage(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) {
    final workbook = state.workbook;
    final sheet = state.currentSheet;
    if (workbook == null || sheet == null) {
      return Center(child: Text(l10n.t('noWorkbook')));
    }

    return Column(
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<int>(
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
            ),
            SizedBox(
              width: 260,
              child: TextField(
                onChanged: state.setQuery,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  labelText: l10n.t('search'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            DropdownButton<LearnerFilter>(
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
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _legendDot(const Color(0xFFFFF6E5), l10n.t('needsAttention')),
            const SizedBox(width: 10),
            _legendDot(const Color(0xFFE8F5E9), l10n.t('ready')),
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
                        ? const Color(0xFFFFF6E5)
                        : const Color(0xFFE8F5E9),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 44,
                            child: Text('${row.rowIndex + 1}'),
                          ),
                          SizedBox(width: 100, child: Text(row.identity)),
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
                            icon: const Icon(
                              Icons.refresh_rounded,
                              color: Color(0xFFF57C00),
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
      ],
    );
  }

  Widget _globalSearchPage(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) {
    final results = state.globalSearch(_globalSearch);
    return Column(
      children: [
        TextField(
          onChanged: (v) => setState(() => _globalSearch = v),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            border: const OutlineInputBorder(),
            labelText: l10n.t('search'),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: results.isEmpty
              ? Center(child: Text(l10n.t('noResults')))
              : ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    final result = results[index];
                    return Card(
                      child: ListTile(
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
                          },
                          child: Text(l10n.t('jump')),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _bulkPage(
    BuildContext context,
    MeTeachState state,
    AppLocalizations l10n,
  ) {
    final fillController = TextEditingController(text: '10');
    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(labelText: l10n.t('from')),
                      ),
                    ),
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _ruleMaxController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(labelText: l10n.t('to')),
                      ),
                    ),
                    SizedBox(
                      width: 280,
                      child: TextField(
                        controller: _ruleRemarkController,
                        decoration: InputDecoration(
                          labelText: l10n.t('remark'),
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: () {
                        final min =
                            double.tryParse(_ruleMinController.text.trim()) ??
                            0;
                        final max =
                            double.tryParse(_ruleMaxController.text.trim()) ??
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
                          state.updateRemarkRule(_editingRuleIndex!, rule);
                        }
                        setState(() {
                          _editingRuleIndex = null;
                          _ruleMinController.clear();
                          _ruleMaxController.clear();
                          _ruleRemarkController.clear();
                          _bulkFeedback = l10n.t('ruleSaved');
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
                          setState(() {
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
                ...List<Widget>.generate(state.remarkRules.length, (index) {
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
                              setState(() {
                                _editingRuleIndex = index;
                                _ruleMinController.text = rule.min.toString();
                                _ruleMaxController.text = rule.max.toString();
                                _ruleRemarkController.text = rule.remark;
                              });
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: () {
                              state.deleteRemarkRule(index);
                              setState(
                                () => _bulkFeedback = l10n.t('ruleDeleted'),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                }),
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
                  l10n.t('chooseScopeApply'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DropdownButton<ScoreSource>(
                      value: _selectedScoreSource,
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _selectedScoreSource = value);
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
                    DropdownButton<ApplyScope>(
                      value: _selectedScope,
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _selectedScope = value);
                        }
                      },
                      items: [
                        DropdownMenuItem(
                          value: ApplyScope.allSheets,
                          child: Text(l10n.t('applyAllSheets')),
                        ),
                        DropdownMenuItem(
                          value: ApplyScope.currentSheet,
                          child: Text(l10n.t('applyCurrentSheet')),
                        ),
                        DropdownMenuItem(
                          value: ApplyScope.filteredRows,
                          child: Text(l10n.t('applyFilteredRows')),
                        ),
                      ],
                    ),
                    FilledButton.icon(
                      onPressed: _bulkProcessing
                          ? null
                          : () async {
                              final preview = state.previewRemarkRulesAffected(
                                scope: _selectedScope,
                                scoreSource: _selectedScoreSource,
                              );
                              final confirm = await _confirmDialog(
                                context,
                                l10n.t('confirmAction'),
                                '${l10n.t('confirmApplyRules')}\n${l10n.t('affectedLearners')}: $preview',
                                l10n,
                              );
                              if (!confirm) {
                                return;
                              }
                              setState(() => _bulkProcessing = true);
                              setState(() => _pageLoading = true);
                              await Future<void>.delayed(
                                const Duration(milliseconds: 250),
                              );
                              final affected = state.applyRemarkRules(
                                scope: _selectedScope,
                                scoreSource: _selectedScoreSource,
                              );
                              if (!context.mounted) {
                                return;
                              }
                              setState(() {
                                _bulkProcessing = false;
                                _pageLoading = false;
                                _bulkFeedback =
                                    '${l10n.t('done')}: ${l10n.t('affectedLearners')} $affected';
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(_bulkFeedback)),
                              );
                              await showProcessDoneLogoAnimation(context);
                            },
                      icon: _bulkProcessing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow_rounded),
                      label: Text(l10n.t('applyRulesNow')),
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        state.saveProgressCheckpoint('Manual save from bulk');
                        setState(() => _bulkFeedback = l10n.t('saveProgress'));
                      },
                      icon: const Icon(Icons.save_rounded),
                      label: Text(l10n.t('saveProgress')),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_bulkFeedback.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFA5D6A7)),
                    ),
                    child: Text(_bulkFeedback),
                  ),
                const SizedBox(height: 12),
                Text(l10n.t('quickFillOptional')),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      width: 100,
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
                const SizedBox(height: 6),
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
                                    title: Text(l10n.t('confirmClearCells')),
                                    content: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        CheckboxListTile(
                                          value: clearContinuous,
                                          title: Text(
                                            l10n.t('clearContinuous'),
                                          ),
                                          onChanged: (v) => setDialogState(
                                            () => clearContinuous = v ?? false,
                                          ),
                                        ),
                                        CheckboxListTile(
                                          value: clearTest,
                                          title: Text(l10n.t('clearTest')),
                                          onChanged: (v) => setDialogState(
                                            () => clearTest = v ?? false,
                                          ),
                                        ),
                                        CheckboxListTile(
                                          value: clearExam,
                                          title: Text(l10n.t('clearExam')),
                                          onChanged: (v) => setDialogState(
                                            () => clearExam = v ?? false,
                                          ),
                                        ),
                                        CheckboxListTile(
                                          value: clearRemark,
                                          title: Text(l10n.t('clearRemark')),
                                          onChanged: (v) => setDialogState(
                                            () => clearRemark = v ?? false,
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
                            if (confirmed != true) {
                              return;
                            }
                            if (!clearContinuous &&
                                !clearTest &&
                                !clearExam &&
                                !clearRemark) {
                              return;
                            }
                            setState(() => _pageLoading = true);
                            await Future<void>.delayed(
                              const Duration(milliseconds: 200),
                            );
                            state.clearSelectedEditableCellsForCurrentSheet(
                              clearContinuous: clearContinuous,
                              clearTest: clearTest,
                              clearExam: clearExam,
                              clearRemark: clearRemark,
                            );
                            if (mounted) {
                              setState(() => _pageLoading = false);
                              await showProcessDoneLogoAnimation(this.context);
                            }
                          },
                          child: Text(l10n.t('clearEditableCells')),
                        ),
                        OutlinedButton(
                          onPressed: () => state.setScoreValueForFiltered(10),
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
      ],
    );
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
              onPressed: state.runValidation,
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

  Widget _statCard(
    BuildContext context,
    String label,
    String value,
    Color background,
  ) {
    return SizedBox(
      width: 160,
      child: Card(
        color: background,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label),
              const SizedBox(height: 8),
              Text(value, style: Theme.of(context).textTheme.headlineSmall),
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
