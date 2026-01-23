import 'package:flutter/material.dart';

/// ===== Shared UI (self-contained) =====

class SoftBackground extends StatelessWidget {
  final Widget child;
  const SoftBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFF7FAFF),
                Color(0xFFEFF3FF),
                Color(0xFFF7F8FF),
              ],
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.045,
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
  const CardShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white.withOpacity(0.86),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
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
      drawer: const _LearnerDrawer(),
      body: SafeArea(
        child: SoftBackground(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _TopBar(title: 'A0 Beginners'),
              ),

              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
                sliver: SliverToBoxAdapter(
                  child: CardShell(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Map/progress row
                        Row(
                          children: [
                            _PillIcon(icon: Icons.flag_rounded, label: 'Start'),
                            const SizedBox(width: 10),
                            Expanded(child: _ProgressPath(value: pct)),
                            const SizedBox(width: 10),
                            _PillIcon(icon: Icons.emoji_events_rounded, label: 'Finish'),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // KPI chips (Wrap prevents overflow on small screens)
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _KpiChip(
                              icon: Icons.check_circle_rounded,
                              label: 'Done',
                              value: '$done',
                            ),
                            _KpiChip(
                              icon: Icons.insights_rounded,
                              label: 'Progress',
                              value: '${(pct * 100).round()}%',
                            ),
                            _KpiChip(
                              icon: Icons.lock_rounded,
                              label: 'Left',
                              value: '${total - done}',
                            ),
                          ],
                        ),

                        const SizedBox(height: 12),

                        // Legend row (compact, safe)
                        Row(
                          children: [
                            Text(
                              'Skills',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: cs.onSurface.withOpacity(0.70),
                              ),
                            ),
                            const SizedBox(width: 10),
                            _LegendDot(color: _skillColor(SkillType.listening), icon: _skillIcon(SkillType.listening)),
                            const SizedBox(width: 8),
                            _LegendDot(color: _skillColor(SkillType.vocabulary), icon: _skillIcon(SkillType.vocabulary)),
                            const SizedBox(width: 8),
                            _LegendDot(color: _skillColor(SkillType.grammar), icon: _skillIcon(SkillType.grammar)),
                            const Spacer(),
                            Icon(Icons.circle, size: 10, color: cs.primary),
                            const SizedBox(width: 6),
                            Icon(Icons.circle, size: 10, color: const Color(0xFFF26B3A)),
                            const SizedBox(width: 6),
                            Icon(Icons.circle, size: 10, color: cs.onSurface.withOpacity(0.40)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Units grid like a modern app
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
                        // Use mainAxisExtent so height is stable (prevents overflow)
                        mainAxisExtent: 230,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        childCount: units.length,
                            (context, index) {
                          return _UnitCard(
                            unit: units[index],
                            onTapLesson: (lesson) {
                              _showSkillSheet(context, unit: units[index], lesson: lesson);
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

  static void _showSkillSheet(BuildContext context, {required UnitProgress unit, required LessonProgress lesson}) {
    final cs = Theme.of(context).colorScheme;

    final statusLabel = switch (lesson.status) {
      LessonStatus.completed => 'Completed',
      LessonStatus.inProgress => 'In progress',
      LessonStatus.locked => 'Locked',
    };

    final statusColor = switch (lesson.status) {
      LessonStatus.completed => cs.primary,
      LessonStatus.inProgress => const Color(0xFFF26B3A),
      LessonStatus.locked => cs.onSurface.withOpacity(0.50),
    };

    final dateText = (lesson.status == LessonStatus.completed && lesson.completedAt != null)
        ? _fmtDate(lesson.completedAt!)
        : null;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          child: CardShell(
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
                        '${unit.title} • ${_skillShort(lesson.skill)}',
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
                          Text(
                            statusLabel,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: cs.onSurface.withOpacity(0.75),
                            ),
                          ),
                          if (dateText != null) ...[
                            const SizedBox(width: 10),
                            Text(
                              '• $dateText',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: cs.onSurface.withOpacity(0.60),
                                fontWeight: FontWeight.w700,
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
        );
      },
    );
  }
}

/// ===== Top Bar =====

class _TopBar extends StatelessWidget {
  final String title;
  const _TopBar({required this.title});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Builder(
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Back',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: cs.onSurface,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Profile',
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Profile (next)')),
                );
              },
              icon: Icon(Icons.account_circle_rounded, color: cs.primary),
            ),
            IconButton(
              tooltip: 'Menu',
              onPressed: () => Scaffold.of(ctx).openDrawer(),
              icon: Icon(Icons.menu_rounded, color: cs.onSurface.withOpacity(0.72)),
            ),
          ],
        ),
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
    final cs = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 22,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: value.clamp(0, 1),
                  minHeight: 12,
                  backgroundColor: cs.onSurface.withOpacity(0.08),
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
                        color: active ? cs.primary.withOpacity(0.85) : cs.onSurface.withOpacity(0.18),
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: cs.primary.withOpacity(0.12),
              border: Border.all(color: cs.primary.withOpacity(0.25)),
            ),
            child: Text(
              '${(value * 100).round()}%',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w900,
                color: cs.primary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PillIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  const _PillIcon({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: cs.onSurface.withOpacity(0.05),
        border: Border.all(color: cs.onSurface.withOpacity(0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: cs.onSurface.withOpacity(0.75)),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w900,
              color: cs.onSurface.withOpacity(0.75),
            ),
          ),
        ],
      ),
    );
  }
}

/// KPI chip that never overflows (Wrap + FittedBox-safe)
class _KpiChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _KpiChip({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: cs.onSurface.withOpacity(0.04),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: cs.onSurface.withOpacity(0.65),
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final IconData icon;
  const _LegendDot({required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 28,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withOpacity(0.12),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Center(
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}

/// ===== Unit Card =====

class _UnitCard extends StatelessWidget {
  final UnitProgress unit;
  final void Function(LessonProgress lesson) onTapLesson;

  const _UnitCard({required this.unit, required this.onTapLesson});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return CardShell(
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
                ),
              ),
              const Spacer(),
              Text(
                '${(unit.percent * 100).round()}%',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: cs.primary,
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
              backgroundColor: cs.onSurface.withOpacity(0.08),
            ),
          ),

          const SizedBox(height: 10),

          // Unit “strip” (6 dots representing the 6 items)
          _UnitStrip(items: unit.items),

          const SizedBox(height: 10),

          // Skill grid (fixed safe height)
          SizedBox(
            height: 110,
            child: GridView.builder(
              itemCount: unit.items.length,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 1.15,
              ),
              itemBuilder: (context, i) {
                final l = unit.items[i];
                return _MiniTile(
                  lesson: l,
                  onTap: () => onTapLesson(l),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _UnitStrip extends StatelessWidget {
  final List<LessonProgress> items;
  const _UnitStrip({required this.items});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Color statusColor(LessonStatus s) => switch (s) {
      LessonStatus.completed => cs.primary,
      LessonStatus.inProgress => const Color(0xFFF26B3A),
      LessonStatus.locked => cs.onSurface.withOpacity(0.35),
    };

    return Row(
      children: List.generate(items.length, (i) {
        final it = items[i];
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i == items.length - 1 ? 0 : 6),
            child: Container(
              height: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: _skillColor(it.skill).withOpacity(0.12),
                border: Border.all(color: _skillColor(it.skill).withOpacity(0.22)),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: it.status == LessonStatus.completed
                      ? 1
                      : it.status == LessonStatus.inProgress
                      ? 0.55
                      : 0.18,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: statusColor(it.status),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// Tile: center skill icon + status dot (tap opens sheet)
class _MiniTile extends StatelessWidget {
  final LessonProgress lesson;
  final VoidCallback onTap;

  const _MiniTile({required this.lesson, required this.onTap});

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
      LessonStatus.completed => cs.primary,
      LessonStatus.inProgress => const Color(0xFFF26B3A),
      LessonStatus.locked => cs.onSurface.withOpacity(0.45),
    };

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
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
      ),
    );
  }
}

/// ===== Drawer =====

class _LearnerDrawer extends StatelessWidget {
  const _LearnerDrawer();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget item(IconData icon, String label) {
      return ListTile(
        leading: Icon(icon, color: cs.primary),
        title: Text(
          label,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w800,
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
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.menu_book_rounded, color: cs.primary, size: 28),
                  const SizedBox(width: 10),
                  Text(
                    'Menu',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: cs.onSurface.withOpacity(0.08)),
            Expanded(
              child: ListView(
                children: [
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

/// ===== Skill visuals (red/blue/green) =====

Color _skillColor(SkillType s) {
  const blue = Color(0xFF2E7AF0);
  const green = Color(0xFF2CB67D);
  const red = Color(0xFFE63946);
  const orange = Color(0xFFF26B3A);

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

String _skillShort(SkillType s) {
  return switch (s) {
    SkillType.listening => 'Listening',
    SkillType.vocabulary => 'Vocabulary',
    SkillType.grammar => 'Grammar',
    SkillType.reading => 'Reading',
    SkillType.writing => 'Writing',
    SkillType.mock => 'Mock Exam',
  };
}
