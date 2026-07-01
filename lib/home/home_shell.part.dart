part of '../main.dart';

enum _HomeSection { courses, gallery, world, games, stories }

enum _AppMode { courses, gallery, world, games, stories }

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final ScrollController _scrollController = ScrollController();
  final _coursesKey = GlobalKey();
  final _galleryKey = GlobalKey();
  final _worldKey = GlobalKey();
  final _gamesKey = GlobalKey();
  final _storiesKey = GlobalKey();
  final PageController _heroPageController = PageController();
  Timer? _heroTimer;
  bool _isArabic = false;
  _AppMode _appMode = _AppMode.gallery;

  String _tr(String en, String ar) => _isArabic ? ar : en;

  Future<void> _openLogin(BuildContext context) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  void initState() {
    super.initState();
    if (kIsWeb) _startHeroAutoSlide();
  }

  void _startHeroAutoSlide() {
    _heroTimer?.cancel();
    _heroTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_heroPageController.hasClients) {
        final next = _heroPageController.page!.round() + 1;
        _heroPageController.animateToPage(
          next,
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeInOutCubic,
        );
      }
    });
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    _heroPageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  GlobalKey _keyForSection(_HomeSection value) {
    switch (value) {
      case _HomeSection.courses:
        return _coursesKey;
      case _HomeSection.gallery:
        return _galleryKey;
      case _HomeSection.world:
        return _worldKey;
      case _HomeSection.games:
        return _gamesKey;
      case _HomeSection.stories:
        return _storiesKey;
    }
  }

  String _labelForSection(_HomeSection value) {
    switch (value) {
      case _HomeSection.courses:
        return _tr('Courses', 'الدورات');
      case _HomeSection.gallery:
        return _tr('Gallery', 'المعرض');
      case _HomeSection.world:
        return _tr('World', 'العالم');
      case _HomeSection.games:
        return _tr('Games', 'الألعاب');
      case _HomeSection.stories:
        return _tr('Stories', 'القصص');
    }
  }

  String _labelForAppMode(_AppMode value) {
    switch (value) {
      case _AppMode.courses:
        return 'Courses';
      case _AppMode.gallery:
        return 'Gallery';
      case _AppMode.world:
        return 'World';
      case _AppMode.games:
        return 'Games';
      case _AppMode.stories:
        return 'Stories';
    }
  }

  Widget _buildPhoneAppShell(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.appBg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: IndexedStack(
          index: _appMode.index,
          children: const [
            AssistantHome(),
            GalleryHome(),
            WorldGraduatesHome(),
            GamesHome(),
            StoriesHome(),
          ],
        ),
      ),
      floatingActionButton: _PulsingLoginFab(
        onPressed: () => _openLogin(context),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _appMode.index,
        onDestinationSelected: (i) =>
            setState(() => _appMode = _AppMode.values[i]),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.auto_stories_rounded),
            label: _labelForAppMode(_AppMode.courses),
          ),
          NavigationDestination(
            icon: const Icon(Icons.photo_library_rounded),
            label: _labelForAppMode(_AppMode.gallery),
          ),
          NavigationDestination(
            icon: const Icon(Icons.public_rounded),
            label: _labelForAppMode(_AppMode.world),
          ),
          NavigationDestination(
            icon: const Icon(Icons.sports_esports_rounded),
            label: _labelForAppMode(_AppMode.games),
          ),
          NavigationDestination(
            icon: const Icon(Icons.menu_book_rounded),
            label: _labelForAppMode(_AppMode.stories),
          ),
        ],
      ),
    );
  }

  Future<void> _scrollToSection(_HomeSection section) async {
    final context = _keyForSection(section).currentContext;
    if (context == null) return;
    await Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
      alignment: 0.04,
    );
  }

  void _openWebsiteExperience(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Widget _buildHeader(BuildContext context) {
    final isDesktop = context.isDesktopOrWider;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.97),
        border: Border(
          bottom: BorderSide(color: Brand.uiBorder.withValues(alpha: 0.72)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.responsive<double>(
              phone: 12,
              tablet: 18,
              desktop: 28,
              largeDesktop: 36,
            ),
            vertical: isDesktop ? 10 : 8,
          ),
          child: Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  _scrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 520),
                    curve: Curves.easeOutCubic,
                  );
                },
                child: _StaticBrandLogo(
                  size: context.responsive<double>(
                    phone: 34,
                    tablet: 38,
                    desktop: 42,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Text(
                  _isArabic ? 'EN' : 'AR',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                    color: Brand.primaryBlue,
                  ),
                ),
                tooltip: _isArabic ? 'English' : 'العربية',
                onPressed: () => setState(() => _isArabic = !_isArabic),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Brand.actionOrange,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(
                    horizontal: context.responsive<double>(
                      phone: 12,
                      tablet: 16,
                      desktop: 18,
                    ),
                    vertical: 11,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () => _openLogin(context),
                icon: const Icon(Icons.login_rounded, size: 18),
                label: Text(
                  _tr('Login', 'تسجيل الدخول'),
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHero(BuildContext context) {
    final isDesktop = context.isDesktopOrWider;
    return Container(
      height: context.responsive<double>(phone: 440, tablet: 520, desktop: 620),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(isDesktop ? 32 : 24),
        boxShadow: [
          BoxShadow(
            color: Brand.primaryBlue.withValues(alpha: 0.18),
            blurRadius: 28,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          StreamBuilder<DatabaseEvent>(
            stream: FirebaseDatabase.instance
                .ref()
                .child('public_gallery_teasers')
                .onValue,
            builder: (context, snap) {
              final photos = <String>[];
              if (snap.hasData && snap.data!.snapshot.value is Map) {
                (snap.data!.snapshot.value as Map).forEach((_, val) {
                  if (val is! Map) return;
                  final type = (val['type'] ?? '').toString().trim();
                  final url = (val['url'] ?? '').toString().trim();
                  if (type == 'photo' && url.isNotEmpty) photos.add(url);
                });
              }
              if (photos.isEmpty) {
                return _buildFallbackHero();
              }
              return PageView.builder(
                controller: _heroPageController,
                onPageChanged: (i) {
                  if (i >= photos.length - 1) {
                    _heroPageController.animateToPage(
                      0,
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.easeInOutCubic,
                    );
                  }
                },
                itemCount: photos.length,
                itemBuilder: (_, i) => Image.network(
                  photos[i],
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                  errorBuilder: (_, _, _) => _buildFallbackHero(),
                ),
              );
            },
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF10213D).withValues(alpha: 0.78),
                      const Color(0xFF1A2B48).withValues(alpha: 0.52),
                      Colors.black.withValues(alpha: 0.62),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                context.responsive<double>(phone: 18, tablet: 26, desktop: 42),
                0,
                context.responsive<double>(phone: 18, tablet: 26, desktop: 42),
                context.responsive<double>(phone: 28, tablet: 38, desktop: 56),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.22),
                      ),
                    ),
                    child: Text(
                      _tr(
                        'English skills for real life',
                        'مهارات إنجليزية للحياة الحقيقية',
                      ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _tr(
                      'Learn English with Your Bridge School',
                      'تعلم الإنجليزية مع أكاديمية دريم',
                    ),
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: context.responsive<double>(
                        phone: 34,
                        tablet: 46,
                        desktop: 58,
                        largeDesktop: 64,
                      ),
                      height: 0.98,
                      letterSpacing: -1.2,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _tr(
                      'Not for the certificate, for the skill.',
                      'ليس من أجل الشهادة، بل من أجل المهارة.',
                    ),
                    style: TextStyle(
                      color: Brand.actionOrange,
                      fontWeight: FontWeight.w900,
                      fontSize: context.responsiveFontSize(
                        phone: 18,
                        tablet: 21,
                        desktop: 24,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _tr(
                      'Practical English courses, teacher-led learning, and a global community.',
                      'دورات إنجليزية عملية، تعليم بإشراف معلمين، ومجتمع عالمي.',
                    ),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.82),
                      fontWeight: FontWeight.w600,
                      fontSize: context.responsiveFontSize(
                        phone: 15,
                        tablet: 16,
                        desktop: 17,
                      ),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _scrollToSection(_HomeSection.courses),
                        style: FilledButton.styleFrom(
                          backgroundColor: Brand.actionOrange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 15,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: const Icon(Icons.auto_stories_rounded),
                        label: Text(
                          _tr('Explore Courses', 'استعرض الدورات'),
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _openLogin(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 15,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: const Icon(Icons.login_rounded),
                        label: Text(
                          _tr('Student / Teacher Login', 'تسجيل دخول'),
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackHero() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF10213D), Color(0xFF1A2B48), Color(0xFF28466F)],
        ),
      ),
    );
  }

  Widget _buildDirectionality({required Widget child}) {
    if (!_isArabic) return child;
    return Directionality(textDirection: TextDirection.rtl, child: child);
  }

  Widget _buildWebsiteSection({
    required GlobalKey key,
    required String eyebrow,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      key: key,
      padding: EdgeInsets.only(
        top: context.responsive<double>(phone: 34, tablet: 44, desktop: 56),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _WebsiteSectionHeader(
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }

  Widget _buildCoursesSection() {
    return _buildWebsiteSection(
      key: _coursesKey,
      eyebrow: _tr('Courses', 'الدورات'),
      title: _tr(
        'Choose the English path that fits your life.',
        'اختر مسار الإنجليزية الذي يناسب حياتك.',
      ),
      subtitle: _tr(
        'Browse live, flexible, in-class, private, and recorded learning options.',
        'تصفح خيارات التعلم المباشر والمرن والمسجل والخاص.',
      ),
      child: const _CoursesByCategory(),
    );
  }

  Widget _buildGallerySection() {
    return _buildWebsiteSection(
      key: _galleryKey,
      eyebrow: _tr('Gallery', 'المعرض'),
      title: _tr(
        'See the learning community in action.',
        'شاهد مجتمع التعلم أثناء العمل.',
      ),
      subtitle: _tr(
        'Photos, videos, and teacher activity from the public YBS gallery.',
        'صور وفيديوهات وأنشطة المعلمين من معرض YBS العام.',
      ),
      child: SizedBox(
        height: context.responsive<double>(
          phone: 460,
          tablet: 560,
          desktop: 640,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Brand.uiBorder),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const _PublicGalleryShowcase(),
          ),
        ),
      ),
    );
  }

  Widget _buildWorldSection() {
    return _buildWebsiteSection(
      key: _worldKey,
      eyebrow: _tr('World', 'العالم'),
      title: _tr(
        'A school community beyond one classroom.',
        'مجتمع مدرسي يتجاوز الفصل الدراسي الواحد.',
      ),
      subtitle: _tr(
        'Explore public learner pins and graduates from the YBS family around the world.',
        'استكشف بطاقات المتعلمين والخريجين من عائلة YBS حول العالم.',
      ),
      child: SizedBox(
        height: context.responsive<double>(
          phone: 430,
          tablet: 520,
          desktop: 620,
        ),
        child: const _WebsiteWorldMapCard(),
      ),
    );
  }

  Widget _buildGamesAndStoriesSection() {
    return _buildWebsiteSection(
      key: _gamesKey,
      eyebrow: _tr('Practice', 'التدرب'),
      title: _tr(
        'Learn by practicing, reading, and playing.',
        'تعلم بالممارسة والقراءة واللعب.',
      ),
      subtitle: _tr(
        'Games and stories open on demand so the homepage stays fast and focused.',
        'الألعاب والقصص تُفتح عند الطلب لتبقى الصفحة الرئيسية سريعة ومركزة.',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final stack = constraints.maxWidth < 760;
              final cards = [
                Expanded(
                  child: _ExperienceLaunchCard(
                    icon: Icons.sports_esports_rounded,
                    title: _tr('Practice With Games', 'تدرب مع الألعاب'),
                    subtitle: _tr(
                      'Open the games area for interactive English practice.',
                      'افتح منطقة الألعاب للممارسة التفاعلية.',
                    ),
                    buttonLabel: _tr('Open Games', 'افتح الألعاب'),
                    color: const Color(0xFF5A6AE6),
                    onTap: () => _openWebsiteExperience(
                      const LearnerGamesScreen(showScaffold: true),
                    ),
                  ),
                ),
                Expanded(
                  child: _ExperienceLaunchCard(
                    icon: Icons.menu_book_rounded,
                    title: _tr('Read Stories', 'اقرأ القصص'),
                    subtitle: _tr(
                      'Open the stories area for reading and listening practice.',
                      'افتح منطقة القصص لممارسة القراءة والاستماع.',
                    ),
                    buttonLabel: _tr('Open Stories', 'افتح القصص'),
                    color: Brand.actionOrange,
                    onTap: () => _openWebsiteExperience(
                      const LearnerStoriesScreen(showAppBar: true),
                    ),
                  ),
                ),
              ];
              if (stack) {
                return Column(
                  children: [cards[0], const SizedBox(height: 14), cards[1]],
                );
              }
              return Row(
                children: [cards[0], const SizedBox(width: 16), cards[1]],
              );
            },
          ),
          Container(key: _storiesKey),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 56),
      padding: EdgeInsets.all(
        context.responsive<double>(phone: 20, tablet: 26, desktop: 32),
      ),
      decoration: BoxDecoration(
        color: Brand.primaryBlue,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: _buildDirectionality(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stack = constraints.maxWidth < 780;
            final brand = _FooterBrand(
              onLogin: () => _openLogin(context),
              isArabic: _isArabic,
            );
            final links = _FooterLinks(
              onCourses: () => _scrollToSection(_HomeSection.courses),
              onGallery: () => _scrollToSection(_HomeSection.gallery),
              onWorld: () => _scrollToSection(_HomeSection.world),
              onJobs: () => _openWebsiteExperience(const JobsHome()),
              onCertificate: () =>
                  _openWebsiteExperience(const VerifyCertificateScreen()),
              isArabic: _isArabic,
            );
            if (stack) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [brand, const SizedBox(height: 24), links],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 5, child: brand),
                const SizedBox(width: 28),
                Expanded(flex: 4, child: links),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return _buildPhoneAppShell(context);

    return Scaffold(
      backgroundColor: Brand.appBg,
      body: Column(
        children: [
          _buildHeader(context),
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController,
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1240),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      context.responsive<double>(
                        phone: 14,
                        tablet: 22,
                        desktop: 30,
                      ),
                      context.responsive<double>(
                        phone: 16,
                        tablet: 24,
                        desktop: 34,
                      ),
                      context.responsive<double>(
                        phone: 14,
                        tablet: 22,
                        desktop: 30,
                      ),
                      0,
                    ),
                    child: _buildDirectionality(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildHero(context),
                          _buildCoursesSection(),
                          _buildGallerySection(),
                          _buildWorldSection(),
                          _buildGamesAndStoriesSection(),
                          _buildFooter(context),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StaticBrandLogo extends StatelessWidget {
  const _StaticBrandLogo({required this.size, this.tint});

  final double size;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: Image.asset(
        'assets/images/ybs_logo.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
        color: tint,
        errorBuilder: (_, _, _) => Icon(
          Icons.school_rounded,
          size: size * 0.82,
          color: tint ?? Brand.primaryBlue,
        ),
      ),
    );
  }
}

class _WebsiteSectionHeader extends StatelessWidget {
  const _WebsiteSectionHeader({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
  });

  final String eyebrow;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow.toUpperCase(),
            style: const TextStyle(
              color: Brand.actionOrange,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.3,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(
              color: Brand.primaryBlue,
              fontWeight: FontWeight.w900,
              fontSize: context.responsive<double>(
                phone: 26,
                tablet: 34,
                desktop: 42,
              ),
              height: 1.06,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            style: TextStyle(
              color: Brand.mainText.withValues(alpha: 0.72),
              fontWeight: FontWeight.w600,
              fontSize: context.responsiveFontSize(
                phone: 14,
                tablet: 15,
                desktop: 16,
              ),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _WebsiteWorldMapCard extends StatelessWidget {
  const _WebsiteWorldMapCard();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Brand.uiBorder),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: StreamBuilder<DatabaseEvent>(
            stream: FirebaseDatabase.instance.ref('graduate_world_map').onValue,
            builder: (context, snapshot) {
              final graduates = _GraduateMapPerson.fromSnapshot(
                snapshot.data?.snapshot.value,
              );
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: YbsBusyLogo());
              }
              return StreamBuilder<DatabaseEvent>(
                stream: FirebaseDatabase.instance
                    .ref('public_learner_pins')
                    .onValue,
                builder: (context, pinsSnapshot) {
                  final pinsData = pinsSnapshot.data?.snapshot.value;
                  final learners = _parseLearnerPins(
                    pinsData is Map ? pinsData.cast<String, dynamic>() : null,
                  );
                  if (graduates.isEmpty && learners.isEmpty) {
                    return const _EmptyWorldGraduates();
                  }
                  return _GraduatesWorldMap(
                    graduates: graduates,
                    learners: learners,
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ExperienceLaunchCard extends StatelessWidget {
  const _ExperienceLaunchCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String buttonLabel;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Brand.uiBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Brand.primaryBlue,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              color: Brand.mainText.withValues(alpha: 0.72),
              fontWeight: FontWeight.w600,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(
              buttonLabel,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterBrand extends StatelessWidget {
  const _FooterBrand({required this.onLogin, required this.isArabic});

  final VoidCallback onLogin;
  final bool isArabic;

  String _tr(String en, String ar) => isArabic ? ar : en;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _StaticBrandLogo(size: 38),
            const SizedBox(width: 10),
            Text(
              _tr('Your Bridge School', 'أكاديمية دريم'),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          _tr(
            'Not for the certificate, for the skill. Learn, practice, verify, and grow with the YBS community.',
            'ليس من أجل الشهادة، بل من أجل المهارة. تعلم، تدرب، تحقق، وانمُ مع مجتمع YBS.',
          ),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.78),
            fontWeight: FontWeight.w600,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: onLogin,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: BorderSide(color: Colors.white.withValues(alpha: 0.36)),
          ),
          icon: const Icon(Icons.login_rounded),
          label: Text(_tr('Login', 'تسجيل الدخول')),
        ),
      ],
    );
  }
}

class _FooterLinks extends StatelessWidget {
  const _FooterLinks({
    required this.onCourses,
    required this.onGallery,
    required this.onWorld,
    required this.onJobs,
    required this.onCertificate,
    required this.isArabic,
  });

  final VoidCallback onCourses;
  final VoidCallback onGallery;
  final VoidCallback onWorld;
  final VoidCallback onJobs;
  final VoidCallback onCertificate;
  final bool isArabic;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _FooterLink(label: isArabic ? 'الدورات' : 'Courses', onTap: onCourses),
        _FooterLink(label: isArabic ? 'المعرض' : 'Gallery', onTap: onGallery),
        _FooterLink(label: isArabic ? 'العالم' : 'World', onTap: onWorld),
        _FooterLink(label: isArabic ? 'الوظائف' : 'Jobs', onTap: onJobs),
        _FooterLink(
          label: isArabic ? 'التحقق من الشهادة' : 'Verify Certificate',
          onTap: onCertificate,
        ),
      ],
    );
  }
}

class _FooterLink extends StatelessWidget {
  const _FooterLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: Colors.white.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}

class _PulsingLoginFab extends StatefulWidget {
  const _PulsingLoginFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_PulsingLoginFab> createState() => _PulsingLoginFabState();
}

class _PulsingLoginFabState extends State<_PulsingLoginFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    )..repeat(reverse: true);
    _scale = Tween<double>(
      begin: 1.0,
      end: 1.06,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: FloatingActionButton.extended(
        onPressed: widget.onPressed,
        backgroundColor: Brand.actionOrange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.login_rounded),
        label: const Text('Login'),
      ),
    );
  }
}

class WorldGraduatesHome extends StatelessWidget {
  const WorldGraduatesHome({super.key});

  @override
  Widget build(BuildContext context) {
    return SoftBackground(
      child: Column(
        children: [
          const SimpleTopBar(title: 'Your Bridge School'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: Row(
              children: [
                Icon(Icons.public_rounded, size: 20, color: Brand.primaryBlue),
                const SizedBox(width: 8),
                Text(
                  'YBS Family and Graduates',
                  style: const TextStyle(
                    color: Brand.primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<DatabaseEvent>(
              stream: FirebaseDatabase.instance
                  .ref('graduate_world_map')
                  .onValue,
              builder: (context, snapshot) {
                final graduates = _GraduateMapPerson.fromSnapshot(
                  snapshot.data?.snapshot.value,
                );

                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                return StreamBuilder<DatabaseEvent>(
                  stream: FirebaseDatabase.instance
                      .ref('public_learner_pins')
                      .onValue,
                  builder: (context, pinsSnapshot) {
                    final pinsData = pinsSnapshot.data?.snapshot.value;
                    final learners = _parseLearnerPins(
                      pinsData is Map ? pinsData.cast<String, dynamic>() : null,
                    );

                    if (graduates.isEmpty && learners.isEmpty) {
                      return const _EmptyWorldGraduates();
                    }

                    return _GraduatesWorldMap(
                      graduates: graduates,
                      learners: learners,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GraduateMapPerson {
  const _GraduateMapPerson({
    required this.id,
    required this.name,
    required this.photoUrl,
    required this.country,
    required this.city,
    required this.lat,
    required this.lng,
    this.blurPhoto = false,
  });

  final String id;
  final String name;
  final String photoUrl;
  final String country;
  final String city;
  final double lat;
  final double lng;
  final bool blurPhoto;

  _GraduateMapPerson copyWith({double? lat, double? lng}) => _GraduateMapPerson(
    id: id,
    name: name,
    photoUrl: photoUrl,
    country: country,
    city: city,
    lat: lat ?? this.lat,
    lng: lng ?? this.lng,
    blurPhoto: blurPhoto,
  );

  static List<_GraduateMapPerson> fromSnapshot(dynamic value) {
    if (value is! Map) return const <_GraduateMapPerson>[];
    final out = <_GraduateMapPerson>[];
    value.forEach((key, raw) {
      if (raw is! Map) return;
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
      if (m['active'] == false) return;
      final name = (m['name'] ?? '').toString().trim();
      final country = (m['country'] ?? '').toString().trim();
      final city = (m['city'] ?? '').toString().trim();
      final lat = _toDouble(m['lat']);
      final lng = _toDouble(m['lng']);
      if (name.isEmpty || country.isEmpty || city.isEmpty) return;
      if (lat == null || lng == null) return;
      if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return;
      out.add(
        _GraduateMapPerson(
          id: key.toString(),
          name: name,
          photoUrl: (m['photoUrl'] ?? '').toString().trim(),
          country: country,
          city: city,
          lat: lat,
          lng: lng,
          blurPhoto: m['blurPhoto'] == true,
        ),
      );
    });
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  static double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse((value ?? '').toString().trim());
  }
}

class _EmptyWorldGraduates extends StatelessWidget {
  const _EmptyWorldGraduates();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 320,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.public_rounded,
              size: 46,
              color: Brand.primaryBlue.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 10),
            Text(
              'No graduates on the map yet.',
              style: TextStyle(
                color: Brand.primaryBlue,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Admin can add them from Graduates Map.',
              style: TextStyle(
                color: Brand.mainText.withValues(alpha: 0.68),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LearnerMapEntry {
  const _LearnerMapEntry({
    required this.uid,
    required this.name,
    required this.photoUrl,
    required this.country,
    required this.city,
    required this.lat,
    required this.lng,
  });

  final String uid;
  final String name;
  final String photoUrl;
  final String country;
  final String city;
  final double lat;
  final double lng;
}

List<_LearnerMapEntry> _parseLearnerPins(Map<String, dynamic>? pins) {
  if (pins == null) return [];
  final learners = <_LearnerMapEntry>[];
  for (final entry in pins.entries) {
    final uid = entry.key;
    final data = entry.value;
    if (data is! Map) continue;
    final lat = _GraduateMapPerson._toDouble(data['lat']);
    final lng = _GraduateMapPerson._toDouble(data['lng']);
    if (lat == null || lng == null) continue;
    learners.add(
      _LearnerMapEntry(
        uid: uid,
        name: (data['name'] as String?) ?? '',
        photoUrl: (data['photoUrl'] as String?) ?? '',
        country: (data['country'] as String?) ?? '',
        city: (data['city'] as String?) ?? '',
        lat: lat,
        lng: lng,
      ),
    );
  }
  return learners;
}

class _GraduatesWorldMap extends StatefulWidget {
  const _GraduatesWorldMap({required this.graduates, this.learners = const []});

  final List<_GraduateMapPerson> graduates;
  final List<_LearnerMapEntry> learners;

  @override
  State<_GraduatesWorldMap> createState() => _GraduatesWorldMapState();
}

class _GraduatesWorldMapState extends State<_GraduatesWorldMap> {
  final _mapController = MapController();
  var _showClusters = true;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  void _onMapEvent(MapEvent event) {
    if (event is MapEventMoveEnd) {
      final zoom = _mapController.camera.zoom;
      if (!zoom.isFinite) return;
      final shouldCluster = zoom < 6;
      if (shouldCluster != _showClusters) {
        setState(() => _showClusters = shouldCluster);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<_GraduateMapPerson>>{};
    for (final g in widget.graduates) {
      final key = _showClusters
          ? '${g.city.toLowerCase().trim()}|${g.country.toLowerCase().trim()}'
          : '${g.lat},${g.lng}';
      groups.putIfAbsent(key, () => []).add(g);
    }

    final markers = <Marker>[];
    for (final group in groups.values) {
      if (_showClusters && group.length > 1) {
        markers.add(
          Marker(
            point: LatLng(group[0].lat, group[0].lng),
            width: 100,
            height: 125,
            child: _GraduateClusterPin(graduates: group),
          ),
        );
      } else if (group.length > 1) {
        markers.add(
          Marker(
            point: LatLng(group[0].lat, group[0].lng),
            width: 60,
            height: 80,
            child: _GraduateStackPin(graduates: group),
          ),
        );
      } else {
        final g = group[0];
        final point = LatLng(g.lat, g.lng);
        if (!point.latitude.isFinite || !point.longitude.isFinite) continue;
        markers.add(
          Marker(
            point: point,
            width: 60,
            height: 80,
            child: _GraduatePhotoPin(person: g),
          ),
        );
      }
    }

    final learnerGroups = <String, List<_LearnerMapEntry>>{};
    for (final l in widget.learners) {
      final key = '${l.lat},${l.lng}';
      learnerGroups.putIfAbsent(key, () => []).add(l);
    }
    for (final group in learnerGroups.values) {
      if (group.length > 1) {
        markers.add(
          Marker(
            point: LatLng(group[0].lat, group[0].lng),
            width: 50,
            height: 65,
            child: _LearnerStackPin(learners: group),
          ),
        );
      } else {
        final l = group[0];
        final point = LatLng(l.lat, l.lng);
        if (!point.latitude.isFinite || !point.longitude.isFinite) continue;
        markers.add(
          Marker(
            point: point,
            width: 50,
            height: 65,
            child: _LearnerMapPin(learner: l),
          ),
        );
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: const LatLng(20, 20),
          initialZoom: 2.0,
          minZoom: 2,
          maxZoom: 10,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
          onMapEvent: _onMapEvent,
        ),
        children: [
          TileLayer(
            urlTemplate:
                'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
            subdomains: const ['a', 'b', 'c', 'd'],
            userAgentPackageName: 'com.appdevybs.mycertenglish',
            maxZoom: 19,
          ),
          MarkerLayer(markers: markers),
        ],
      ),
    );
  }
}

class _GraduatePhotoPin extends StatelessWidget {
  const _GraduatePhotoPin({required this.person});

  final _GraduateMapPerson person;

  Widget _photoPin() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: _PublicCirclePhoto(
            photoUrl: person.photoUrl,
            radius: 20,
            backgroundColor: Brand.actionOrange,
            foregroundColor: Colors.white,
            iconSize: 24,
          ),
        ),
        Icon(Icons.arrow_drop_down_rounded, color: Brand.actionOrange),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _GraduateProfileDialog(person: person),
      ),
      child: person.blurPhoto
          ? ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: _photoPin(),
            )
          : _photoPin(),
    );
  }
}

class _LearnerMapPin extends StatelessWidget {
  const _LearnerMapPin({required this.learner});

  final _LearnerMapEntry learner;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _LearnerProfileDialog(learner: learner),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: _PublicCirclePhoto(
              photoUrl: learner.photoUrl,
              radius: 14,
              backgroundColor: Brand.primaryBlue,
              foregroundColor: Colors.white,
              iconSize: 18,
            ),
          ),
          const Icon(Icons.arrow_drop_down_rounded, color: Brand.primaryBlue),
        ],
      ),
    );
  }
}

class _LearnerProfileDialog extends StatelessWidget {
  const _LearnerProfileDialog({required this.learner});

  final _LearnerMapEntry learner;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 54),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Brand.primaryBlue, Brand.actionOrange],
                ),
              ),
              child: Row(
                children: [
                  Text(
                    _countryFlag(learner.country),
                    style: const TextStyle(fontSize: 28),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      learner.country,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Transform.translate(
              offset: const Offset(0, -42),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PublicCirclePhoto(
                      photoUrl: learner.photoUrl,
                      radius: 36,
                      backgroundColor: Brand.primaryBlue,
                      foregroundColor: Colors.white,
                      iconSize: 36,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      learner.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Brand.primaryBlue,
                        fontWeight: FontWeight.w900,
                        fontSize: 20,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Brand.primaryBlue.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.location_on_rounded,
                            size: 16,
                            color: Brand.actionOrange,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              '${learner.city.isNotEmpty ? '${learner.city}, ' : ''}${learner.country}',
                              style: TextStyle(
                                color: Brand.primaryBlue,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LearnerStackPin extends StatelessWidget {
  const _LearnerStackPin({required this.learners});

  final List<_LearnerMapEntry> learners;

  @override
  Widget build(BuildContext context) {
    final first = learners[0];
    final count = learners.length;

    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _LearnerClusterDialog(learners: learners),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 6,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: _PublicCirclePhoto(
                  photoUrl: first.photoUrl,
                  radius: 14,
                  backgroundColor: Brand.primaryBlue,
                  foregroundColor: Colors.white,
                  iconSize: 18,
                ),
              ),
              Positioned(
                right: -6,
                top: -6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Brand.primaryBlue,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 10,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const Icon(Icons.arrow_drop_down_rounded, color: Brand.primaryBlue),
        ],
      ),
    );
  }
}

class _LearnerClusterDialog extends StatelessWidget {
  const _LearnerClusterDialog({required this.learners});

  final List<_LearnerMapEntry> learners;

  @override
  Widget build(BuildContext context) {
    final first = learners[0];
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 390, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 16, 10, 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Brand.primaryBlue, Brand.actionOrange],
                ),
              ),
              child: Row(
                children: [
                  Text(
                    _countryFlag(first.country),
                    style: const TextStyle(fontSize: 26),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          first.city,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          first.country,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.82),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${learners.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                itemCount: learners.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final l = learners[index];
                  return Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Brand.primaryBlue.withValues(alpha: 0.035),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Brand.primaryBlue.withValues(alpha: 0.06),
                      ),
                    ),
                    child: Row(
                      children: [
                        _PublicCirclePhoto(
                          photoUrl: l.photoUrl,
                          radius: 20,
                          backgroundColor: Brand.primaryBlue,
                          foregroundColor: Colors.white,
                          iconSize: 24,
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Brand.primaryBlue,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${l.city}, ${l.country}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Brand.mainText.withValues(alpha: 0.64),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ],
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
      ),
    );
  }
}

class _GraduateProfileDialog extends StatelessWidget {
  const _GraduateProfileDialog({required this.person});

  final _GraduateMapPerson person;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 54),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Brand.primaryBlue, Brand.actionOrange],
                ),
              ),
              child: Row(
                children: [
                  Text(
                    _countryFlag(person.country),
                    style: const TextStyle(fontSize: 28),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      person.country,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Transform.translate(
              offset: const Offset(0, -42),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PrivacyPhoto(
                      photoUrl: person.photoUrl,
                      blur: person.blurPhoto,
                      radius: 48,
                      borderWidth: 4,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      person.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Brand.primaryBlue,
                        fontWeight: FontWeight.w900,
                        fontSize: 22,
                        height: 1.08,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Brand.primaryBlue.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.location_on_rounded,
                            size: 16,
                            color: Brand.actionOrange,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              '${person.city}, ${person.country}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Brand.mainText.withValues(alpha: 0.78),
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (person.blurPhoto) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          'Photo blurred for privacy',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Brand.mainText.withValues(alpha: 0.65),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'YBS Family and Graduates',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Brand.actionOrange,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacyPhoto extends StatelessWidget {
  const _PrivacyPhoto({
    required this.photoUrl,
    required this.blur,
    required this.radius,
    this.borderWidth = 3,
  });

  final String photoUrl;
  final bool blur;
  final double radius;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    Widget photo = _PublicCirclePhoto(
      photoUrl: photoUrl,
      radius: radius,
      backgroundColor: Brand.primaryBlue.withValues(alpha: 0.08),
      foregroundColor: Brand.primaryBlue,
      iconSize: radius,
    );
    if (blur) {
      photo = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: photo,
      );
    }
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: borderWidth),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: photo,
    );
  }
}

class _PublicCirclePhoto extends StatelessWidget {
  const _PublicCirclePhoto({
    required this.photoUrl,
    required this.radius,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.iconSize,
  });

  final String photoUrl;
  final double radius;
  final Color backgroundColor;
  final Color foregroundColor;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    Widget fallback() {
      return Container(
        width: size,
        height: size,
        color: backgroundColor,
        alignment: Alignment.center,
        child: Icon(
          Icons.person_rounded,
          color: foregroundColor,
          size: iconSize,
        ),
      );
    }

    final url = photoUrl.trim();
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? fallback()
            : Image.network(
                url,
                fit: BoxFit.cover,
                webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                errorBuilder: (_, _, _) => fallback(),
              ),
      ),
    );
  }
}

String _countryFlag(String country) {
  final code = _countryCodeByName[country.trim().toLowerCase()];
  if (code == null || code.length != 2) return '🌍';
  final upper = code.toUpperCase();
  return String.fromCharCodes(
    upper.codeUnits.map((unit) => 0x1F1E6 + unit - 0x41),
  );
}

const _countryCodeByName = <String, String>{
  'afghanistan': 'AF',
  'albania': 'AL',
  'algeria': 'DZ',
  'angola': 'AO',
  'argentina': 'AR',
  'australia': 'AU',
  'bahrain': 'BH',
  'bangladesh': 'BD',
  'belgium': 'BE',
  'benin': 'BJ',
  'botswana': 'BW',
  'brazil': 'BR',
  'burkina faso': 'BF',
  'burundi': 'BI',
  'cameroon': 'CM',
  'canada': 'CA',
  'cape verde': 'CV',
  'central african republic': 'CF',
  'chad': 'TD',
  'china': 'CN',
  'comoros': 'KM',
  'congo': 'CG',
  'dr congo': 'CD',
  'djibouti': 'DJ',
  'egypt': 'EG',
  'ethiopia': 'ET',
  'france': 'FR',
  'gabon': 'GA',
  'gambia': 'GM',
  'ghana': 'GH',
  'guinea': 'GN',
  'india': 'IN',
  'indonesia': 'ID',
  'ivory coast': 'CI',
  'japan': 'JP',
  'kenya': 'KE',
  'kuwait': 'KW',
  'libya': 'LY',
  'malaysia': 'MY',
  'mali': 'ML',
  'mauritania': 'MR',
  'morocco': 'MA',
  'mozambique': 'MZ',
  'nigeria': 'NG',
  'oman': 'OM',
  'pakistan': 'PK',
  'qatar': 'QA',
  'rwanda': 'RW',
  'saudi arabia': 'SA',
  'senegal': 'SN',
  'somalia': 'SO',
  'south africa': 'ZA',
  'sudan': 'SD',
  'tanzania': 'TZ',
  'thailand': 'TH',
  'tunisia': 'TN',
  'uganda': 'UG',
  'united arab emirates': 'AE',
  'united kingdom': 'GB',
  'united states': 'US',
  'vietnam': 'VN',
  'zambia': 'ZM',
  'zimbabwe': 'ZW',
};

class _GraduateClusterPin extends StatelessWidget {
  const _GraduateClusterPin({required this.graduates});

  final List<_GraduateMapPerson> graduates;

  static const int _cols = 3;
  static const double _gap = 3;
  static const double _radius = 14;

  @override
  Widget build(BuildContext context) {
    final count = graduates.length;
    final showOverflow = count > 9;
    final displayCount = showOverflow ? 9 : count;
    final rows = (displayCount + _cols - 1) ~/ _cols;

    Widget cell(int index) {
      if (showOverflow && index == 8) {
        return Container(
          width: _radius * 2,
          height: _radius * 2,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Brand.actionOrange,
          ),
          alignment: Alignment.center,
          child: Text(
            '+${count - 8}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 11,
            ),
          ),
        );
      }
      final g = graduates[index];
      Widget avatar = Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: _PublicCirclePhoto(
          photoUrl: g.photoUrl,
          radius: _radius,
          backgroundColor: Brand.actionOrange,
          foregroundColor: Colors.white,
          iconSize: 14,
        ),
      );
      if (g.blurPhoto) {
        avatar = ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: avatar,
        );
      }
      return avatar;
    }

    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _ClusterDialog(graduates: graduates),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...List.generate(rows, (r) {
            final cellsInRow = (r < rows - 1)
                ? _cols
                : displayCount - r * _cols;
            final children = <Widget>[];
            for (int c = 0; c < cellsInRow; c++) {
              if (c > 0) children.add(const SizedBox(width: _gap));
              children.add(cell(r * _cols + c));
            }
            return Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: children,
            );
          }),
          if (rows > 0) ...[
            const SizedBox(height: 4),
            const Icon(
              Icons.arrow_drop_down_rounded,
              color: Brand.actionOrange,
            ),
          ],
        ],
      ),
    );
  }
}

class _GraduateStackPin extends StatelessWidget {
  const _GraduateStackPin({required this.graduates});

  final List<_GraduateMapPerson> graduates;

  @override
  Widget build(BuildContext context) {
    final first = graduates[0];
    final count = graduates.length;

    Widget avatar = Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: _PublicCirclePhoto(
        photoUrl: first.photoUrl,
        radius: 20,
        backgroundColor: Brand.actionOrange,
        foregroundColor: Colors.white,
        iconSize: 24,
      ),
    );
    if (first.blurPhoto) {
      avatar = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: avatar,
      );
    }

    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _ClusterDialog(graduates: graduates),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              avatar,
              Positioned(
                right: -6,
                top: -6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Brand.actionOrange,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const Icon(Icons.arrow_drop_down_rounded, color: Brand.actionOrange),
        ],
      ),
    );
  }
}

class _ClusterDialog extends StatelessWidget {
  const _ClusterDialog({required this.graduates});

  final List<_GraduateMapPerson> graduates;

  @override
  Widget build(BuildContext context) {
    final first = graduates[0];
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 390, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 16, 10, 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Brand.primaryBlue, Brand.actionOrange],
                ),
              ),
              child: Row(
                children: [
                  Text(
                    _countryFlag(first.country),
                    style: const TextStyle(fontSize: 26),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          first.city,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          first.country,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.82),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${graduates.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                itemCount: graduates.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final g = graduates[index];
                  return Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Brand.primaryBlue.withValues(alpha: 0.035),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Brand.primaryBlue.withValues(alpha: 0.06),
                      ),
                    ),
                    child: Row(
                      children: [
                        _PrivacyPhoto(
                          photoUrl: g.photoUrl,
                          blur: g.blurPhoto,
                          radius: 23,
                          borderWidth: 2,
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                g.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Brand.primaryBlue,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${g.city}, ${g.country}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Brand.mainText.withValues(alpha: 0.64),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                              if (g.blurPhoto) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Photo blurred for privacy',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Brand.actionOrange,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ],
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
      ),
    );
  }
}

class JobsHome extends StatefulWidget {
  const JobsHome({super.key});

  @override
  State<JobsHome> createState() => _JobsHomeState();
}

class _JobsHomeState extends State<JobsHome> {
  Timer? _descTimer;
  int _descIndex = 0;

  static const List<String> _jobDescriptions = [
    'Submit your application anytime. We review applications continuously.',
    'Envoyez votre candidature a tout moment. Nous examinons les demandes en continu.',
    'يمكنك إرسال طلب التوظيف في أي وقت، ونقوم بمراجعة الطلبات بشكل مستمر.',
  ];

  @override
  void initState() {
    super.initState();
    _descTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      setState(() => _descIndex = (_descIndex + 1) % _jobDescriptions.length);
    });
  }

  @override
  void dispose() {
    _descTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: SoftBackground(
          child: Column(
            children: [
              const SimpleTopBar(title: 'Jobs'),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                  children: [
                    CardShell(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Work With Us',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  color: Brand.primaryBlue,
                                  fontWeight: FontWeight.w900,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _jobDescriptions[_descIndex],
                            style: TextStyle(
                              color: Brand.mainText.withValues(alpha: 0.8),
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    const CardShell(child: JobApplicationScreen()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuestJobApplyLimiter {
  static const Duration cooldown = Duration(hours: 24);
  static const String _key = 'guest_job_apply_last_ms';

  static Future<DateTime?> _last() async {
    final sp = await SharedPreferences.getInstance();
    final ms = sp.getInt(_key);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<bool> canApplyNow() async {
    final last = await _last();
    if (last == null) return true;
    return DateTime.now().difference(last) >= cooldown;
  }

  static Future<Duration> remaining() async {
    final last = await _last();
    if (last == null) return Duration.zero;
    final diff = DateTime.now().difference(last);
    if (diff >= cooldown) return Duration.zero;
    return cooldown - diff;
  }

  static Future<void> markNow() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_key, DateTime.now().millisecondsSinceEpoch);
  }
}

class JobApplicationScreen extends StatefulWidget {
  const JobApplicationScreen({super.key, this.onSubmitted});

  final VoidCallback? onSubmitted;

  @override
  State<JobApplicationScreen> createState() => _JobApplicationScreenState();
}

class _JobApplicationScreenState extends State<JobApplicationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _positionCtrl = TextEditingController();
  final _captchaCtrl = TextEditingController();

  PlatformFile? _cvPdf;
  bool _submitting = false;

  int _captchaA = 2;
  int _captchaB = 3;

  @override
  void initState() {
    super.initState();
    _refreshCaptcha();
  }

  @override
  void dispose() {
    _fullNameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _positionCtrl.dispose();
    _captchaCtrl.dispose();
    super.dispose();
  }

  void _refreshCaptcha() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _captchaA = (now % 8) + 1;
    _captchaB = ((now ~/ 7) % 8) + 1;
    _captchaCtrl.clear();
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) {
    if (d <= Duration.zero) return '0m';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h <= 0) return '${m}m';
    return '${h}h ${m}m';
  }

  String _fieldLabel(String en, String ar, bool forGuest) {
    if (!forGuest) return en;
    return '$en | $ar';
  }

  Future<void> _pickPdf() async {
    if (_submitting) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      allowMultiple: false,
      withData: true,
    );
    if (!mounted) return;
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final ext = file.extension?.toLowerCase().trim() ?? '';
    if (ext != 'pdf') {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Please select a PDF file only.')),
      );
      return;
    }

    setState(() => _cvPdf = file);
  }

  Future<String> _uploadCv(PlatformFile file) async {
    final request = http.MultipartRequest(
      'POST',
      BackendApi.uri('upload_job_cv.php'),
    );

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw Exception('Could not read selected file bytes.');
      }
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
    } else {
      final path = file.path;
      if (path == null || path.trim().isEmpty) {
        throw Exception('Could not read selected file path.');
      }
      request.files.add(await http.MultipartFile.fromPath('file', path));
    }

    final stream = await request.send();
    final response = await http.Response.fromStream(stream);
    final raw = response.body.trim();
    Map<String, dynamic>? data;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        data = decoded;
      }
    } catch (_) {
      final first = raw.indexOf('{');
      final last = raw.lastIndexOf('}');
      if (first >= 0 && last > first) {
        final candidate = raw.substring(first, last + 1);
        try {
          final decoded = jsonDecode(candidate);
          if (decoded is Map<String, dynamic>) {
            data = decoded;
          }
        } catch (_) {}
      }
    }

    if (data == null) {
      if (response.statusCode == 404) {
        throw Exception(
          'CV upload endpoint not found (upload_job_cv.php). Please deploy backend update.',
        );
      }
      throw Exception(
        'CV upload failed: server did not return valid JSON (HTTP ${response.statusCode}).',
      );
    }

    if (data['success'] != true) {
      final msg = (data['message'] ?? 'CV upload failed.').toString();
      throw Exception(msg);
    }

    final url = (data['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      throw Exception('CV upload URL is missing.');
    }
    return url;
  }

  bool _isEmail(String value) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);
  }

  String _sanitizeEventPart(String raw) {
    return raw
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  Future<void> _notifyAdminsJobApplication({
    required String appId,
    required bool isGuest,
  }) async {
    final actorUid = (FirebaseAuth.instance.currentUser?.uid ?? '').trim();
    if (actorUid.isEmpty) {
      return;
    }

    final safeAppId = _sanitizeEventPart(appId);
    if (safeAppId.isEmpty) return;

    final title = isGuest ? 'New guest job application' : 'New job application';
    final body = isGuest
        ? 'A new guest candidate submitted a job application.'
        : 'A new platform user submitted a job application.';

    try {
      await PushDispatchService.dispatchAdminTopic(
        intent: PushIntent.jobApplication,
        title: title,
        message: body,
        context: const PushDispatchContext(
          screen: 'home/job_application_screen',
          action: 'notify_admins_job_application',
        ),
        eventParts: ['job_application', safeAppId],
        route: 'job_applications',
        data: {
          'priority': 'high',
          'appId': appId,
          'isGuest': isGuest ? '1' : '0',
        },
      );
    } catch (_) {}
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_submitting) return;

    if (!(_formKey.currentState?.validate() ?? false)) return;

    final expected = (_captchaA + _captchaB).toString();
    if (_captchaCtrl.text.trim() != expected) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Captcha is incorrect. Try again.')),
      );
      _refreshCaptcha();
      return;
    }

    final currentUser = FirebaseAuth.instance.currentUser;
    final isGuest = currentUser == null;
    if (isGuest) {
      final canApply = await _GuestJobApplyLimiter.canApplyNow();
      if (!canApply) {
        final rem = await _GuestJobApplyLimiter.remaining();
        if (!mounted) return;
        AppToast.fromSnackBar(
          context,
          SnackBar(
            content: Text(
              'You can submit one application every 24 hours. Try again in ${_fmt(rem)}.',
            ),
          ),
        );
        return;
      }
    }

    if (_cvPdf == null) {
      final okWithoutCv = await _confirmSubmitWithoutCv();
      if (!okWithoutCv) return;
    }

    setState(() => _submitting = true);

    try {
      String? cvUrl;
      final cvFile = _cvPdf;
      if (cvFile != null) {
        cvUrl = await _uploadCv(cvFile);
      }

      final ref = FirebaseDatabase.instance.ref('job_applications').push();
      final payload = <String, dynamic>{
        'full_name': _fullNameCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim(),
        'email': _emailCtrl.text.trim().toLowerCase(),
        'position': _positionCtrl.text.trim(),
        'status': 'new',
        'submittedByUid': currentUser?.uid ?? '',
        'isGuest': isGuest,
        'createdAt': ServerValue.timestamp,
      };
      if (cvUrl != null && cvUrl.trim().isNotEmpty) {
        payload['cv_pdf_url'] = cvUrl.trim();
      }
      await ref.set(payload);

      await _notifyAdminsJobApplication(appId: ref.key ?? '', isGuest: isGuest);

      if (isGuest) {
        await _GuestJobApplyLimiter.markNow();
      }

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Application submitted successfully ✅')),
      );
      widget.onSubmitted?.call();
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(context, SnackBar(content: Text(toHumanError(e))));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<bool> _confirmSubmitWithoutCv() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Submit without CV? | إرسال بدون سيرة ذاتية؟'),
        content: const Text(
          'You are about to send your application without attaching a CV PDF. Continue?\n\n'
          'أنت على وشك إرسال طلبك بدون إرفاق ملف السيرة الذاتية PDF. هل تريد المتابعة؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel | إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send anyway | إرسال على أي حال'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isGuestViewer = FirebaseAuth.instance.currentUser == null;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Application Form',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Brand.primaryBlue,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _fullNameCtrl,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: _fieldLabel(
                'Full name',
                'الاسم الكامل',
                isGuestViewer,
              ),
            ),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Please enter your full name' : null,
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: _fieldLabel(
                'Phone number',
                'رقم الهاتف',
                isGuestViewer,
              ),
            ),
            validator: (v) {
              final value = (v ?? '').replaceAll(RegExp(r'\s+'), '');
              if (value.isEmpty) return 'Please enter your phone number';
              if (value.length < 8) return 'Phone number is too short';
              return null;
            },
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: _fieldLabel(
                'Email',
                'البريد الإلكتروني',
                isGuestViewer,
              ),
            ),
            validator: (v) {
              final value = (v ?? '').trim().toLowerCase();
              if (value.isEmpty) return 'Please enter your email';
              if (!_isEmail(value)) return 'Enter a valid email';
              return null;
            },
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _positionCtrl,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: _fieldLabel('Position', 'الوظيفة', isGuestViewer),
            ),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Please enter a position' : null,
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _submitting ? null : _pickPdf,
            icon: const Icon(Icons.picture_as_pdf_rounded),
            label: Text(
              _cvPdf == null
                  ? _fieldLabel(
                      'CV PDF (opt)',
                      'CV PDF (اختياري)',
                      isGuestViewer,
                    )
                  : 'CV selected: ${_cvPdf!.name}',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _captchaCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _fieldLabel(
                      'Captcha: $_captchaA + $_captchaB = ?',
                      'التحقق: $_captchaA + $_captchaB = ؟',
                      isGuestViewer,
                    ),
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'Please solve the captcha'
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _submitting ? null : _refreshCaptcha,
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'New captcha',
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Brand.actionOrange,
                foregroundColor: Colors.white,
              ),
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
              label: Text(
                _submitting
                    ? 'Submitting...'
                    : _fieldLabel('Submit', 'إرسال', isGuestViewer),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StoriesHome extends StatelessWidget {
  const StoriesHome({super.key});

  @override
  Widget build(BuildContext context) {
    return SoftBackground(
      child: Column(
        children: [
          const SimpleTopBar(title: 'Your Bridge School'),
          Expanded(child: LearnerStoriesScreen(showAppBar: false)),
        ],
      ),
    );
  }
}

class GamesHome extends StatelessWidget {
  const GamesHome({super.key});

  @override
  Widget build(BuildContext context) {
    return SoftBackground(
      child: Column(
        children: [
          const SimpleTopBar(title: 'Your Bridge School'),
          Expanded(child: const LearnerGamesScreen(showScaffold: false)),
        ],
      ),
    );
  }
}

class GalleryHome extends StatelessWidget {
  const GalleryHome({super.key});

  @override
  Widget build(BuildContext context) {
    return SoftBackground(
      child: Column(
        children: [
          const SimpleTopBar(title: 'Your Bridge School'),
          Expanded(child: const _PublicGalleryShowcase()),
        ],
      ),
    );
  }
}
