part of '../main.dart';

enum AppMode { courses, gallery, world, games, stories }

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppMode mode = AppMode.gallery;

  static const double _desktopShellMinWidth = 1100;

  Future<void> _openLogin(BuildContext context) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  bool _isDesktopShell(BuildContext context) {
    return kIsWeb && MediaQuery.sizeOf(context).width >= _desktopShellMinWidth;
  }

  String _labelForMode(AppMode value) {
    switch (value) {
      case AppMode.courses:
        return 'Courses';
      case AppMode.gallery:
        return 'Gallery';
      case AppMode.world:
        return 'World';
      case AppMode.games:
        return 'Games';
      case AppMode.stories:
        return 'Stories';
    }
  }

  Widget _buildDesktopShell(BuildContext context) {
    final pages = const <Widget>[
      AssistantHome(),
      GalleryHome(),
      WorldGraduatesHome(),
      GamesHome(),
      StoriesHome(),
    ];
    return SafeArea(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 10, 18),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Brand.uiBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: NavigationRail(
                extended: true,
                minExtendedWidth: 208,
                backgroundColor: Colors.transparent,
                selectedIndex: mode.index,
                useIndicator: true,
                labelType: NavigationRailLabelType.none,
                onDestinationSelected: (i) =>
                    setState(() => mode = AppMode.values[i]),
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.auto_stories_rounded),
                    label: Text('Courses'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.photo_library_rounded),
                    label: Text('Gallery'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.public_rounded),
                    label: Text('World'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.sports_esports_rounded),
                    label: Text('Games'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.menu_book_rounded),
                    label: Text('Stories'),
                  ),
                ],
                leading: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const YbsBusyLogo(size: 42),
                      const SizedBox(height: 12),
                      Text(
                        'Your Bridge School',
                        style: TextStyle(
                          color: Brand.primaryBlue,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Browse the public app with a desktop-ready shell.',
                        style: TextStyle(
                          color: Brand.mainText.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 18, 18, 18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.56),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: Brand.uiBorder.withValues(alpha: 0.9),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(27),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _labelForMode(mode),
                                    style: TextStyle(
                                      color: Brand.primaryBlue,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 24,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Desktop navigation keeps the current design while using larger screens intentionally.',
                                    style: TextStyle(
                                      color: Brand.mainText.withValues(
                                        alpha: 0.72,
                                      ),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => _openLogin(context),
                              icon: const Icon(Icons.login_rounded),
                              label: const Text('Login'),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: IndexedStack(index: mode.index, children: pages),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.appBg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: IndexedStack(
          index: mode.index,
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
        selectedIndex: mode.index,
        onDestinationSelected: (i) => setState(() => mode = AppMode.values[i]),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.auto_stories_rounded),
            label: 'Courses',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_library_rounded),
            label: 'Gallery',
          ),
          NavigationDestination(
            icon: Icon(Icons.public_rounded),
            label: 'World',
          ),
          NavigationDestination(
            icon: Icon(Icons.sports_esports_rounded),
            label: 'Games',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_rounded),
            label: 'Stories',
          ),
        ],
      ),
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
                  'YBS Graduates Around The World',
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
                if (graduates.isEmpty) {
                  return const _EmptyWorldGraduates();
                }
                return _GraduatesWorldMap(graduates: graduates);
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

  _GraduateMapPerson copyWith({
    double? lat,
    double? lng,
  }) =>
      _GraduateMapPerson(
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

class _GraduatesWorldMap extends StatefulWidget {
  const _GraduatesWorldMap({required this.graduates});

  final List<_GraduateMapPerson> graduates;

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
      if (group.length == 1 || !_showClusters) {
        for (int i = 0; i < group.length; i++) {
          final g = group[i];
          final point = group.length == 1
              ? LatLng(g.lat, g.lng)
              : LatLng(
                  g.lat + ((i ~/ 3) - 1) * 0.0002,
                  g.lng + ((i % 3) - 1) * 0.0002,
                );
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
      } else {
        markers.add(
          Marker(
            point: LatLng(group[0].lat, group[0].lng),
            width: 100,
            height: 125,
            child: _GraduateClusterPin(graduates: group),
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
          child: CircleAvatar(
            radius: 20,
            backgroundColor: Brand.actionOrange,
            backgroundImage: person.photoUrl.isEmpty
                ? null
                : NetworkImage(person.photoUrl),
            child: person.photoUrl.isEmpty
                ? const Icon(Icons.person_rounded, color: Colors.white)
                : null,
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
        builder: (_) => AlertDialog(
          title: Text(
            person.name,
            overflow: TextOverflow.ellipsis,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              () {
                Widget photo = CircleAvatar(
                  radius: 42,
                  backgroundColor: Brand.primaryBlue.withValues(alpha: 0.08),
                  backgroundImage: person.photoUrl.isEmpty
                      ? null
                      : NetworkImage(person.photoUrl),
                  child: person.photoUrl.isEmpty
                      ? const Icon(Icons.person_rounded, size: 42)
                      : null,
                );
                if (person.blurPhoto) {
                  photo = ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                    child: photo,
                  );
                }
                return photo;
              }(),
              const SizedBox(height: 12),
              Text(
                '${person.city}, ${person.country}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              if (person.blurPhoto) ...[
                const SizedBox(height: 6),
                Text(
                  'Due to privacy, photo is blurred',
                  style: TextStyle(
                    fontSize: 12,
                    color: Brand.mainText.withValues(alpha: 0.55),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
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
        child: CircleAvatar(
          radius: _radius,
          backgroundColor: Brand.actionOrange,
          backgroundImage:
              g.photoUrl.isEmpty ? null : NetworkImage(g.photoUrl),
          child: g.photoUrl.isEmpty
              ? const Icon(Icons.person_rounded, size: 14, color: Colors.white)
              : null,
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

class _ClusterDialog extends StatelessWidget {
  const _ClusterDialog({required this.graduates});

  final List<_GraduateMapPerson> graduates;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        '${graduates.length} graduates in ${graduates[0].city}',
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 320,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: graduates.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final g = graduates[index];
            Widget avatar = CircleAvatar(
              radius: 20,
              backgroundColor: Brand.primaryBlue.withValues(alpha: 0.08),
              backgroundImage: g.photoUrl.isEmpty
                  ? null
                  : NetworkImage(g.photoUrl),
              child: g.photoUrl.isEmpty
                  ? const Icon(Icons.person_rounded)
                  : null,
            );
            if (g.blurPhoto) {
              avatar = ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: avatar,
              );
            }
            return ListTile(
              leading: avatar,
              title: Text(
                g.name,
                style: const TextStyle(fontWeight: FontWeight.w900),
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                g.blurPhoto ? '${g.city}, ${g.country} (blurred)' : '${g.city}, ${g.country}',
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
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
