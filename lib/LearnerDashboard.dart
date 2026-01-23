import 'package:flutter/material.dart';

/// ===== Brand (logo) colors =====
const _brandBlue = Color(0xFF0B2A4A);
const _brandOrange = Color(0xFFF26B3A);

/// ===== Shared UI (self-contained) =====

class SoftBackground extends StatelessWidget {
  final Widget child;
  const SoftBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Brighter, brand-aligned background (blue + orange warmth)
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFF6FAFF),
                Color(0xFFEFF4FF),
                Color(0xFFFFF5EE),
              ],
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.055,
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: 0.78,
                  child: Image.asset(
                    'assets/images/ybs_logo.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class CardShell extends StatelessWidget {
  final Widget child;
  final Color? borderColor;
  const CardShell({super.key, required this.child, this.borderColor});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final b = borderColor ?? cs.onSurface.withOpacity(0.08);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white.withOpacity(0.90),
        border: Border.all(color: b, width: 1.25),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 22,
            offset: const Offset(0, 12),
          )
        ],
      ),
      child: child,
    );
  }
}

/// ===== Model =====

enum LessonStatus { locked, inProgress, completed }
enum SkillType { listening, vocabulary, grammar, reading, writing, mock }

class LessonProgress {
  final SkillType skill;
  final LessonStatus status;
  final DateTime? completedAt;

  const LessonProgress({
    required this.skill,
    required this.status,
    this.completedAt,
  });
}

class UnitProgress {
  final String title;
  final List<LessonProgress> items;

  const UnitProgress({required this.title, required this.items});

  int get total => items.length;
  int get done => items.where((l) => l.status == LessonStatus.completed).length;
  double get percent => total == 0 ? 0 : done / total;
}

/// ===== Learner Dashboard =====

class LearnerDashboard extends StatelessWidget {
  const LearnerDashboard({super.key});

  List<UnitProgress> _demoCourse() {
    DateTime d(int y, int m, int day) => DateTime(y, m, day);

    LessonProgress L(SkillType s, LessonStatus st, [DateTime? at]) =>
        LessonProgress(skill: s, status: st, completedAt: at);

    List<LessonProgress> pack({
      required LessonStatus listening,
      required LessonStatus vocab,
      required LessonStatus grammar,
      required LessonStatus reading,
      required LessonStatus writing,
      required LessonStatus mock,
      DateTime? dl,
      DateTime? dv,
      DateTime? dg,
      DateTime? dr,
      DateTime? dw,
      DateTime? dm,
    }) {
      return [
        L(SkillType.listening, listening, dl),
        L(SkillType.vocabulary, vocab, dv),
        L(SkillType.grammar, grammar, dg),
        L(SkillType.reading, reading, dr),
        L(SkillType.writing, writing, dw),
        L(SkillType.mock, mock, dm),
      ];
    }

    return [
      UnitProgress(
        title: 'Unit 1',
        items: pack(
          listening: LessonStatus.completed,
          vocab: LessonStatus.completed,
          grammar: LessonStatus.completed,
          reading: LessonStatus.inProgress,
          writing: LessonStatus.locked,
          mock: LessonStatus.locked,
          dl: d(2026, 1, 10),
          dv: d(2026, 1, 12),
          dg: d(2026, 1, 14),
        ),
      ),
      UnitProgress(
        title: 'Unit 2',
        items: pack(
          listening: LessonStatus.locked,
          vocab: LessonStatus.locked,
          grammar: LessonStatus.locked,
          reading: LessonStatus.locked,
          writing: LessonStatus.locked,
          mock: LessonStatus.locked,
        ),
      ),
      UnitProgress(
        title: 'Unit 3',
        items: pack(
          listening: LessonStatus.locked,
          vocab: LessonStatus.locked,
          grammar: LessonStatus.locked,
          reading: LessonStatus.locked,
          writing: LessonStatus.locked,
          mock: LessonStatus.locked,
        ),
      ),
      UnitProgress(
        title: 'Unit 4',
        items: pack(
          listening: LessonStatus.locked,
          vocab: LessonStatus.locked,
          grammar: LessonStatus.locked,
          reading: LessonStatus.locked,
          writing: LessonStatus.locked,
          mock: LessonStatus.locked,
        ),
      ),
    ];
  }

  static String _fmtDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final units = _demoCourse();

    final total = units.fold<int>(0, (a, u) => a + u.total);
    final done = units.fold<int>(0, (a, u) => a + u.done);
    final pct = total == 0 ? 0.0 : done / total;

    return Scaffold(
      // ✅ menu should come from the RIGHT since profile icon is on the RIGHT
      endDrawer: const _LearnerDrawer(),
      body: SafeArea(
        child: SoftBackground(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Builder(
                  builder: (ctx) => _TopBar(
                    title: 'Learner Dashboard',
                    onOpenMenu: () => Scaffold.of(ctx).openEndDrawer(),
                  ),
                ),
              ),

              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
                sliver: SliverToBoxAdapter(
                  child: CardShell(
                    borderColor: _brandBlue.withOpacity(0.22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Start -> finish progress (DETERMINATE)
                        Row(
                          children: [
                            const _PillIcon(icon: Icons.flag_rounded, label: 'Start'),
                            const SizedBox(width: 10),
                            Expanded(child: _ProgressPath(value: pct)),
                            const SizedBox(width: 10),
                            const _PillIcon(icon: Icons.emoji_events_rounded, label: 'Finish'),
                          ],
                        ),

                        const SizedBox(height: 12),

                        // SINGLE KPI: Done 3/24 + Progress %
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _KpiChip(
                              icon: Icons.check_circle_rounded,
                              label: 'Done',
                              value: '$done/$total',
                              accent: _brandOrange,
                            ),
                            _KpiChip(
                              icon: Icons.insights_rounded,
                              label: 'Progress',
                              value: '${(pct * 100).round()}%',
                              accent: _brandBlue,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Units grid (cards + colored borders per unit)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final w = constraints.crossAxisExtent;
                    final crossAxisCount = w >= 760 ? 3 : 2;

                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        mainAxisExtent: 272,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        childCount: units.length,
                            (context, index) {
                          return _UnitCard(
                            unit: units[index],
                            borderColor: _unitBorder(index),
                            onTapLesson: (lesson) {
                              _showUnitSheet(
                                context,
                                unitTitle: units[index].title,
                                lesson: lesson,
                              );
                            },
                          );
                        },
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

  static Color _unitBorder(int index) {
    // stronger + more cheerful borders (logo-aligned)
    const colors = [
      Color(0xFF0B2A4A), // deep blue
      Color(0xFFF26B3A), // orange
      Color(0xFF2E7AF0), // bright blue
      Color(0xFF2CB67D), // green
    ];
    return colors[index % colors.length].withOpacity(0.65);
  }

  static void _showUnitSheet(
      BuildContext context, {
        required String unitTitle,
        required LessonProgress lesson,
      }) {
    final cs = Theme.of(context).colorScheme;

    final statusLabel = switch (lesson.status) {
      LessonStatus.completed => 'Completed',
      LessonStatus.inProgress => 'In progress',
      LessonStatus.locked => 'Locked',
    };

    final statusColor = switch (lesson.status) {
      LessonStatus.completed => _brandBlue,
      LessonStatus.inProgress => _brandOrange,
      LessonStatus.locked => cs.onSurface.withOpacity(0.50),
    };

    final dateText = (lesson.status == LessonStatus.completed && lesson.completedAt != null)
        ? _fmtDate(lesson.completedAt!)
        : null;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return SafeArea(
          top: false,
          child: Padding(
            // ✅ lifted so it won't be covered by system navigation buttons
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 42),
            child: CardShell(
              borderColor: _skillColor(lesson.skill).withOpacity(0.35),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: _skillColor(lesson.skill).withOpacity(0.14),
                      border: Border.all(color: _skillColor(lesson.skill).withOpacity(0.35)),
                    ),
                    child: Icon(_skillIcon(lesson.skill), color: _skillColor(lesson.skill), size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          unitTitle,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                statusLabel,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: cs.onSurface.withOpacity(0.75),
                                ),
                              ),
                            ),
                            if (dateText != null) ...[
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  '• $dateText',
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: cs.onSurface.withOpacity(0.60),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ]
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: cs.onSurface.withOpacity(0.70)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// ===== Top Bar (profile opens RIGHT drawer) =====

class _TopBar extends StatelessWidget {
  final String title;
  final VoidCallback onOpenMenu;

  const _TopBar({required this.title, required this.onOpenMenu});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: _brandBlue,
              ),
            ),
          ),

          // Profile avatar opens menu
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onOpenMenu,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(-0.25, -0.35),
                  radius: 1.2,
                  colors: [
                    _brandOrange.withOpacity(0.95),
                    _brandBlue.withOpacity(0.92),
                    Colors.white.withOpacity(0.10),
                  ],
                  stops: const [0.0, 0.66, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: _brandBlue.withOpacity(0.16),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
                ],
                border: Border.all(color: _brandOrange.withOpacity(0.40)),
              ),
              child: const Icon(Icons.person_rounded, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// ===== Progress + KPI =====

class _ProgressPath extends StatelessWidget {
  final double value;
  const _ProgressPath({required this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: value.clamp(0, 1),
              backgroundColor: _brandBlue.withOpacity(0.12),
              valueColor: const AlwaysStoppedAnimation(_brandOrange),
              minHeight: 12,
            ),
          ),
          Positioned.fill(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(7, (idx) {
                final t = idx / 6;
                final active = value >= t;
                return Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active ? _brandOrange.withOpacity(0.95) : _brandBlue.withOpacity(0.18),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _PillIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  const _PillIcon({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: Colors.white.withOpacity(0.75),
        border: Border.all(color: _brandBlue.withOpacity(0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: _brandBlue.withOpacity(0.78)),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w900,
              color: _brandBlue.withOpacity(0.78),
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  const _KpiChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: accent.withOpacity(0.08),
        border: Border.all(color: accent.withOpacity(0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 10),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: _brandBlue,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: _brandBlue.withOpacity(0.70),
            ),
          ),
        ],
      ),
    );
  }
}

/// ===== Unit Card =====

class _UnitCard extends StatelessWidget {
  final UnitProgress unit;
  final Color borderColor;
  final void Function(LessonProgress lesson) onTapLesson;

  const _UnitCard({
    required this.unit,
    required this.borderColor,
    required this.onTapLesson,
  });

  @override
  Widget build(BuildContext context) {
    return CardShell(
      borderColor: borderColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Text(
                unit.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: _brandBlue,
                ),
              ),
              const Spacer(),
              Text(
                '${(unit.percent * 100).round()}%',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: _brandOrange,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: unit.percent.clamp(0, 1),
              minHeight: 8,
              backgroundColor: _brandBlue.withOpacity(0.10),
              valueColor: AlwaysStoppedAnimation(borderColor.withOpacity(0.95)),
            ),
          ),

          const SizedBox(height: 10),

          // Compact skill grid WITH SMALL LABELS
          SizedBox(
            height: 148,
            child: GridView.builder(
              itemCount: unit.items.length,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 1.02,
              ),
              itemBuilder: (context, i) {
                final l = unit.items[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => onTapLesson(l),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(child: _MiniTile(lesson: l)),
                      const SizedBox(height: 4),
                      Text(
                        _skillTiny(l.skill),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: _brandBlue.withOpacity(0.68),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Tile: center skill icon + status dot
class _MiniTile extends StatelessWidget {
  final LessonProgress lesson;
  const _MiniTile({required this.lesson});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final skillColor = _skillColor(lesson.skill);

    final bg = lesson.status == LessonStatus.locked
        ? cs.onSurface.withOpacity(0.05)
        : skillColor.withOpacity(0.14);

    final border = lesson.status == LessonStatus.locked
        ? cs.onSurface.withOpacity(0.10)
        : skillColor.withOpacity(0.35);

    final statusDotColor = switch (lesson.status) {
      LessonStatus.completed => _brandBlue,
      LessonStatus.inProgress => _brandOrange,
      LessonStatus.locked => cs.onSurface.withOpacity(0.45),
    };

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Stack(
        children: [
          Center(
            child: Icon(
              _skillIcon(lesson.skill),
              size: 22,
              color: lesson.status == LessonStatus.locked
                  ? cs.onSurface.withOpacity(0.45)
                  : skillColor.withOpacity(0.95),
            ),
          ),
          Positioned(
            top: 5,
            right: 5,
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: statusDotColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ===== Drawer (opened by profile icon) =====

class _LearnerDrawer extends StatelessWidget {
  const _LearnerDrawer();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget item(IconData icon, String label) {
      return ListTile(
        leading: Icon(icon, color: _brandOrange),
        title: Text(
          label,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: _brandBlue,
          ),
        ),
        onTap: () {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$label (next)')),
          );
        },
      );
    }

    return Drawer(
      // RIGHT drawer feel: lighter background, brand accent
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.account_circle_rounded, color: _brandOrange, size: 28),
                  const SizedBox(width: 10),
                  Text(
                    'Account',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: _brandBlue,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: cs.onSurface.withOpacity(0.08)),
            Expanded(
              child: ListView(
                children: [
                  item(Icons.person_rounded, 'Profile'),

                  // ✅ requested: Attendance item in menu
                  item(Icons.how_to_reg_rounded, 'Attendance'),

                  item(Icons.support_agent_rounded, 'Contact Support (Administration)'),
                  item(Icons.people_alt_rounded, 'Text Teachers'),
                  item(Icons.forum_rounded, 'Chat Rooms'),
                  item(Icons.payments_rounded, 'Fees'),
                  const SizedBox(height: 8),
                  Divider(height: 1, color: cs.onSurface.withOpacity(0.08)),
                  item(Icons.logout_rounded, 'Logout'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ===== Skill visuals (keep yours, but align to logo mood) =====

Color _skillColor(SkillType s) {
  // keeping your multi-color skills, but slightly tuned to match brand (not depressing)
  const blue = Color(0xFF2E7AF0);
  const green = Color(0xFF2CB67D);
  const red = Color(0xFFE63946);
  const orange = _brandOrange;

  return switch (s) {
    SkillType.listening => blue,
    SkillType.reading => blue,
    SkillType.vocabulary => green,
    SkillType.writing => green,
    SkillType.grammar => red,
    SkillType.mock => orange,
  };
}

IconData _skillIcon(SkillType s) {
  return switch (s) {
    SkillType.listening => Icons.headphones_rounded,
    SkillType.vocabulary => Icons.auto_awesome_rounded,
    SkillType.grammar => Icons.rule_rounded,
    SkillType.reading => Icons.chrome_reader_mode_rounded,
    SkillType.writing => Icons.edit_note_rounded,
    SkillType.mock => Icons.fact_check_rounded,
  };
}

String _skillTiny(SkillType s) {
  return switch (s) {
    SkillType.listening => 'Listen',
    SkillType.vocabulary => 'Vocab',
    SkillType.grammar => 'Grammar',
    SkillType.reading => 'Read',
    SkillType.writing => 'Write',
    SkillType.mock => 'Mock',
  };
}
