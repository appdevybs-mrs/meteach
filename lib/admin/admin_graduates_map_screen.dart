import 'dart:convert';
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../services/backend_api.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';
import '../shared/city_data.dart';

class AdminGraduatesMapScreen extends StatefulWidget {
  const AdminGraduatesMapScreen({super.key});

  @override
  State<AdminGraduatesMapScreen> createState() =>
      _AdminGraduatesMapScreenState();
}

class _AdminGraduatesMapScreenState extends State<AdminGraduatesMapScreen>
    with SingleTickerProviderStateMixin {
  static const _primaryBlue = Color(0xFF1A2B48);
  static const _actionOrange = Color(0xFFF98D28);
  static const _appBg = Color(0xFFF4F7F9);
  DatabaseReference get _ref =>
      FirebaseDatabase.instance.ref('graduate_world_map');

  late final TabController _tabController;
  bool _showSearch = false;
  final _searchController = TextEditingController();

  String get _searchQuery => _searchController.text.trim().toLowerCase();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openEditor([_GraduateMapAdminItem? item]) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _GraduateMapEditorDialog(item: item),
    );
  }

  Future<void> _delete(_GraduateMapAdminItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete graduate?'),
        content: Text('Delete ${item.name} from the world map?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await _ref.child(item.id).remove();
      if (item.learnerUid.isNotEmpty) {
        await FirebaseDatabase.instance
            .ref('public_learner_pins')
            .child(item.learnerUid)
            .remove();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Graduate deleted.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(toHumanError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text(
          'Graduates Map',
          style: TextStyle(color: _primaryBlue, fontWeight: FontWeight.w900),
        ),
        iconTheme: const IconThemeData(color: _primaryBlue),
        actions: [
          if (_tabController.index == 0) ...[
            IconButton(
              icon: Icon(_showSearch ? Icons.close_rounded : Icons.search_rounded),
              onPressed: () {
                setState(() {
                  _showSearch = !_showSearch;
                  if (!_showSearch) _searchController.clear();
                });
              },
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _actionOrange,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => _openEditor(),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add'),
              ),
            ),
          ],
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: _actionOrange,
          labelColor: _primaryBlue,
          unselectedLabelColor: _primaryBlue.withValues(alpha: 0.55),
          tabs: const [
            Tab(text: 'Graduates'),
            Tab(text: 'Learners'),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: TabBarView(
          controller: _tabController,
          children: [
            adminWebBodyFrame(
              context: context,
              maxWidth: 1100,
              child: _buildGraduatesTab(),
            ),
            adminWebBodyFrame(
              context: context,
              maxWidth: 1100,
              child: const _LearnersMapTab(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGraduatesTab() {
    return StreamBuilder<DatabaseEvent>(
      stream: _ref.onValue,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final allItems = _GraduateMapAdminItem.fromSnapshot(
          snapshot.data?.snapshot.value,
        );
        final items =
            allItems.where((item) => item.learnerUid.isEmpty).toList();
        final filtered = _searchQuery.isEmpty
            ? items
            : items
                .where(
                  (item) =>
                      item.name.toLowerCase().contains(_searchQuery) ||
                      item.country.toLowerCase().contains(_searchQuery) ||
                      item.city.toLowerCase().contains(_searchQuery),
                )
                .toList();
        if (items.isEmpty) {
          return Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.public_rounded,
                      size: 48,
                      color: _primaryBlue,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'No graduates yet.',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Add the first graduate to show on the public World tab.',
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => _openEditor(),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add Graduate'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Column(
          children: [
            if (_showSearch)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Search by name, country, or city...',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No results match "$_searchQuery".',
                        style: TextStyle(
                          color: _primaryBlue.withValues(alpha: 0.55),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(14),
                      itemCount: filtered.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final item = filtered[index];
            return Card(
              color: Colors.white,
              elevation: 0.5,
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: _primaryBlue.withValues(alpha: 0.08),
                      backgroundImage: item.photoUrl.isEmpty
                          ? null
                          : NetworkImage(item.photoUrl),
                      child: item.photoUrl.isEmpty
                          ? const Icon(Icons.person_rounded, size: 22)
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            '${item.city}, ${item.country}',
                            style: TextStyle(
                              fontSize: 12,
                              color: _primaryBlue.withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            'Lat: ${item.lat}, Lng: ${item.lng}',
                            style: TextStyle(
                              fontSize: 11,
                              color: _primaryBlue.withValues(alpha: 0.45),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              _CompactChip(
                                label: item.active ? 'Active' : 'Hidden',
                                color: item.active
                                    ? Colors.green
                                    : Colors.orange,
                              ),
                              if (item.blurPhoto)
                                const Padding(
                                  padding: EdgeInsets.only(left: 4),
                                  child: _CompactChip(
                                    label: 'Blurred',
                                    color: Colors.grey,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Edit',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _openEditor(item),
                          icon: const Icon(Icons.edit_rounded, size: 18),
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _delete(item),
                          icon: const Icon(
                            Icons.delete_rounded,
                            size: 18,
                            color: Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
      },
    );
  }
}

class _GraduateMapEditorDialog extends StatefulWidget {
  final _GraduateMapAdminItem? item;
  const _GraduateMapEditorDialog({this.item});

  @override
  State<_GraduateMapEditorDialog> createState() =>
      _GraduateMapEditorDialogState();
}

class _GraduateMapEditorDialogState extends State<_GraduateMapEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameC;
  late final TextEditingController _countryC;
  late final TextEditingController _cityC;
  late final TextEditingController _latC;
  late final TextEditingController _lngC;
  String _photoUrl = '';
  bool _active = true;
  bool _blurPhoto = false;
  bool _saving = false;
  bool _uploading = false;
  bool _geocoding = false;

  Timer? _geocodeTimer;

  Map<String, CityAssetMeta> _cityIndex = const {};
  List<CityOption> _countryCities = const [];
  Map<String, CityOption> _cityByNameLookup = const {};
  bool _loadingCities = false;

  Map<String, List<String>> _worldData = const {};
  String _selectedCountry = '';

  static double? _parseCoord(String raw) {
    var clean = raw
        .replaceAll('°', '')
        .replaceAll(RegExp(r'[NSEW]', caseSensitive: false), '')
        .trim();
    final dirUp = raw.toUpperCase().trim();
    final isSouth = dirUp.contains('S') || dirUp.contains('جنوب');
    final isWest = dirUp.contains('W') || dirUp.contains('غرب');
    final n = double.tryParse(clean);
    if (n == null) return null;
    var result = n;
    if (isSouth || isWest) result = -result;
    return result;
  }

  bool get _isEditing => widget.item != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _nameC = TextEditingController(text: item?.name ?? '');
    _countryC = TextEditingController(text: item?.country ?? '');
    _cityC = TextEditingController(text: item?.city ?? '');
    _latC = TextEditingController(
      text: item != null ? item.lat.toString() : '',
    );
    _lngC = TextEditingController(
      text: item != null ? item.lng.toString() : '',
    );
    _photoUrl = item?.photoUrl ?? '';
    _active = item?.active ?? true;
    _blurPhoto = item?.blurPhoto ?? false;
    _selectedCountry = item?.country ?? '';
    _loadWorldData();
  }

  Future<void> _loadWorldData() async {
    try {
      final data = await rootBundle.loadString('assets/world_data.json');
      final cityIndexData = await rootBundle.loadString(
        'assets/cities_index.json',
      );
      final parsed = jsonDecode(data) as Map;
      final raw = parsed['countries'] as Map;
      final map = <String, List<String>>{};
      raw.forEach((k, v) {
        map[k.toString()] = (v as List).map((e) => e.toString()).toList();
      });
      final indexRaw = jsonDecode(cityIndexData) as Map;
      final index = <String, CityAssetMeta>{};
      indexRaw.forEach((k, v) {
        if (v is Map) {
          index[k.toString()] = CityAssetMeta.fromJson(v);
        }
      });
      if (!mounted) return;
      setState(() {
        _worldData = map;
        _cityIndex = index;
      });
      if (_selectedCountry.trim().isNotEmpty) {
        await _loadCitiesForCountry(_selectedCountry);
      }
    } catch (_) {}
  }

  Future<void> _loadCitiesForCountry(String country) async {
    final normalizedCountry = country.trim();
    final meta = _cityIndex[normalizedCountry];
    _geocodeTimer?.cancel();
    if (meta == null) {
      if (!mounted) return;
      setState(() {
        _countryCities = const [];
        _cityByNameLookup = const {};
        _loadingCities = false;
      });
      return;
    }

    setState(() {
      _loadingCities = true;
      _countryCities = const [];
      _cityByNameLookup = const {};
    });
    try {
      final raw = await rootBundle.loadString(meta.file);
      final decoded = jsonDecode(raw) as List;
      final cities = decoded
          .whereType<Map>()
          .map(CityOption.fromJson)
          .where((c) => c.name.isNotEmpty)
          .toList();
      if (!mounted || _selectedCountry.trim() != normalizedCountry) return;
      setState(() {
        _countryCities = cities;
        _cityByNameLookup = {for (final city in cities) city.name: city};
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _countryCities = const [];
        _cityByNameLookup = const {};
      });
    } finally {
      if (mounted && _selectedCountry.trim() == normalizedCountry) {
        setState(() => _loadingCities = false);
      }
    }
  }

  List<String> get _countrySuggestions {
    if (_countryC.text.trim().isEmpty) return _worldData.keys.toList()..sort();
    final q = _countryC.text.trim().toLowerCase();
    return _worldData.keys
        .where((c) => c.toLowerCase().contains(q))
        .take(10)
        .toList()
      ..sort();
  }

  @override
  void dispose() {
    _geocodeTimer?.cancel();
    _nameC.dispose();
    _countryC.dispose();
    _cityC.dispose();
    _latC.dispose();
    _lngC.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadPhoto() async {
    if (_uploading || _saving) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) return;

    setState(() => _uploading = true);
    try {
      final url = await _uploadPlatformFile(result.files.first);
      if (!mounted) return;
      setState(() => _photoUrl = url);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(toHumanError(e))));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<String> _uploadPlatformFile(PlatformFile file) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not logged in.');

    final uploadUri = await BackendApi.withAuthQuery(
      BackendApi.uri('upload_secure.php'),
    );
    final request = http.MultipartRequest('POST', uploadUri)
      ..headers['X-Requested-With'] = 'XMLHttpRequest'
      ..fields['app_id'] = 'graduate_world_map_${user.uid}';
    await BackendApi.applyAuthToMultipart(request);

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw Exception('Could not read image bytes.');
      }
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
    } else {
      final path = file.path;
      if (path == null || path.trim().isEmpty) {
        throw Exception('Could not read image path.');
      }
      request.files.add(
        await http.MultipartFile.fromPath('file', path, filename: file.name),
      );
    }

    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw Exception('Upload failed: HTTP ${streamed.statusCode}');
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['success'] != true) {
      throw Exception(
        decoded is Map
            ? (decoded['message'] ?? 'Upload failed')
            : 'Upload failed',
      );
    }
    final url = (decoded['url'] ?? '').toString().trim();
    if (url.isEmpty) throw Exception('Upload succeeded but URL is missing.');
    return url;
  }

  Future<void> _geocode() async {
    final city = _cityC.text.trim();
    final country = _countryC.text.trim();
    if (city.isEmpty || country.isEmpty) return;

    setState(() => _geocoding = true);
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=$city,$country&format=json&limit=1',
      );
      final res = await http.get(
        uri,
        headers: {'User-Agent': 'com.appdevybs.mycertenglish'},
      );
      if (!mounted) return;
      final data = jsonDecode(res.body) as List;
      if (data.isEmpty) return;
      final first = data[0] as Map;
      final lat = first['lat'];
      final lon = first['lon'];
      if (lat != null) _latC.text = lat.toString();
      if (lon != null) _lngC.text = lon.toString();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _geocoding = false);
    }
  }

  void _scheduleGeocode() {
    _geocodeTimer?.cancel();
    _geocodeTimer = Timer(const Duration(milliseconds: 1200), _geocode);
  }

  void _onCountrySelected(String country) {
    _countryC.text = country;
    _countryC.selection = TextSelection.fromPosition(
      TextPosition(offset: country.length),
    );
    if (country == _selectedCountry) return;
    setState(() {
      _selectedCountry = country;
      _cityC.clear();
      _latC.clear();
      _lngC.clear();
    });
    unawaited(_loadCitiesForCountry(country));
  }

  void _onCityChanged(String value) {
    _cityC.text = value;
    _cityC.selection = TextSelection.fromPosition(
      TextPosition(offset: value.length),
    );
    _geocodeTimer?.cancel();
    if (value.trim().length < 2) {
      return;
    }
    _scheduleGeocode();
  }

  void _onCitySelected(CityOption city) {
    _cityC.text = city.name;
    _cityC.selection = TextSelection.fromPosition(
      TextPosition(offset: city.name.length),
    );
    _latC.text = city.lat.toString();
    _lngC.text = city.lng.toString();
    _geocodeTimer?.cancel();
  }

  Iterable<String> _cityOptionsFor(String rawQuery) {
    if (_countryCities.isEmpty) return const <String>[];
    final q = CityOption.normalize(rawQuery);
    if (q.isEmpty) {
      return _countryCities.map((c) => c.name).toList(growable: false);
    }
    return _countryCities
        .where((c) => c.matches(q))
        .map((c) => c.name)
        .toList(growable: false);
  }

  CityOption? _cityByName(String name) => _cityByNameLookup[name];

  Future<void> _save() async {
    if (_saving || _uploading) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final latRaw = _latC.text.trim();
    final lngRaw = _lngC.text.trim();
    final lat = _parseCoord(latRaw);
    final lng = _parseCoord(lngRaw);
    if (lat == null || lng == null) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _saving = true);
    try {
      final ref = FirebaseDatabase.instance.ref('graduate_world_map');
      final itemRef = _isEditing ? ref.child(widget.item!.id) : ref.push();
      final nowPayload = <String, dynamic>{
        'name': _nameC.text.trim(),
        'photoUrl': _photoUrl.trim(),
        'country': _countryC.text.trim(),
        'city': _cityC.text.trim(),
        'lat': lat,
        'lng': lng,
        'active': _active,
        'blurPhoto': _blurPhoto,
        'updatedAt': ServerValue.timestamp,
        'updatedByUid': user.uid,
      };
      if (!_isEditing) {
        nowPayload['createdAt'] = ServerValue.timestamp;
        nowPayload['createdByUid'] = user.uid;
      }
      await itemRef.update(nowPayload);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isEditing ? 'Graduate updated.' : 'Graduate added.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(toHumanError(e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _required(String? value) =>
      (value ?? '').trim().isEmpty ? 'Required' : null;

  String? _latValidator(String? value) {
    final n = _parseCoord((value ?? '').trim());
    if (n == null) return 'Enter a number (e.g. 21.0285 or 21.0285° N)';
    if (n < -90 || n > 90) return 'Latitude must be -90 to 90';
    return null;
  }

  String? _lngValidator(String? value) {
    final n = _parseCoord((value ?? '').trim());
    if (n == null) return 'Enter a number (e.g. 105.8 or 105.8° E)';
    if (n < -180 || n > 180) return 'Longitude must be -180 to 180';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? 'Edit Graduate' : 'Add Graduate'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 42,
                  backgroundColor: const Color(
                    0xFF1A2B48,
                  ).withValues(alpha: 0.08),
                  backgroundImage: _photoUrl.isEmpty
                      ? null
                      : NetworkImage(_photoUrl),
                  child: _photoUrl.isEmpty
                      ? const Icon(Icons.person_rounded, size: 40)
                      : null,
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _uploading ? null : _pickAndUploadPhoto,
                  icon: _uploading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_rounded),
                  label: Text(
                    _uploading ? 'Uploading...' : 'Upload profile photo',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _nameC,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: _required,
                ),
                const SizedBox(height: 10),
                Autocomplete<String>(
                  optionsBuilder: (_) => _countrySuggestions,
                  initialValue: TextEditingValue(text: _countryC.text),
                  fieldViewBuilder: (ctx, controller, focusNode, onSubmit) {
                    _countryC.addListener(() {});
                    return TextFormField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: const InputDecoration(labelText: 'Country'),
                      validator: _required,
                      onChanged: (v) {
                        if (v != _selectedCountry &&
                            _worldData.containsKey(v)) {
                          _onCountrySelected(v);
                        } else {
                          _countryC.text = v;
                          _countryC.selection = TextSelection.fromPosition(
                            TextPosition(offset: v.length),
                          );
                        }
                      },
                    );
                  },
                  onSelected: (v) {
                    _onCountrySelected(v);
                  },
                ),
                const SizedBox(height: 10),
                Autocomplete<String>(
                  key: ValueKey(_selectedCountry),
                  optionsBuilder: (value) => _cityOptionsFor(value.text),
                  optionsViewBuilder: (ctx, onSelected, options) {
                    return Material(
                      elevation: 8,
                      borderRadius: BorderRadius.circular(6),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: 240,
                          maxWidth: 400,
                        ),
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: options.length,
                          itemBuilder: (ctx, i) {
                            final name = options.elementAt(i);
                            final city = _cityByName(name);
                            final subtitle = city == null
                                ? ''
                                : city.ascii != city.name
                                ? '${city.ascii} • ${city.lat}, ${city.lng}'
                                : '${city.lat}, ${city.lng}';
                            return ListTile(
                              dense: true,
                              title: Text(
                                name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              subtitle: subtitle.isNotEmpty
                                  ? Text(
                                      subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: const Color(
                                          0xFF1A2B48,
                                        ).withValues(alpha: 0.55),
                                      ),
                                    )
                                  : null,
                              onTap: () => onSelected(name),
                            );
                          },
                        ),
                      ),
                    );
                  },
                  initialValue: TextEditingValue(text: _cityC.text),
                  fieldViewBuilder: (ctx, controller, focusNode, onSubmit) {
                    return TextFormField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        labelText: 'City',
                        hintText: _cityIndex.containsKey(_selectedCountry)
                            ? 'Select or type city'
                            : 'Type city (fallback geocode)',
                        suffixIcon: _loadingCities
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : null,
                      ),
                      validator: _required,
                      onChanged: _onCityChanged,
                    );
                  },
                  onSelected: (v) {
                    final city = _cityByName(v);
                    if (city != null) _onCitySelected(city);
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (_geocoding)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Expanded(
                      child: TextFormField(
                        controller: _latC,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Latitude',
                          hintText: '21.0285 or 21.0285° N',
                        ),
                        validator: _latValidator,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _lngC,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Longitude',
                          hintText: '105.8 or 105.8° E',
                        ),
                        validator: _lngValidator,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                  title: const Text('Show on public World tab'),
                ),
                SwitchListTile(
                  value: _blurPhoto,
                  onChanged: (v) => setState(() => _blurPhoto = v),
                  title: const Text('Blur photo for privacy'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _saving || _uploading ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_rounded),
          label: Text(_saving ? 'Saving...' : 'Save'),
        ),
      ],
    );
  }
}

class _CompactChip extends StatelessWidget {
  const _CompactChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

class _GraduateMapAdminItem {
  const _GraduateMapAdminItem({
    required this.id,
    required this.name,
    required this.photoUrl,
    required this.country,
    required this.city,
    required this.lat,
    required this.lng,
    required this.active,
    this.blurPhoto = false,
    this.learnerUid = '',
  });

  final String id;
  final String name;
  final String photoUrl;
  final String country;
  final String city;
  final double lat;
  final double lng;
  final bool active;
  final bool blurPhoto;
  final String learnerUid;

  static List<_GraduateMapAdminItem> fromSnapshot(dynamic value) {
    if (value is! Map) return const <_GraduateMapAdminItem>[];
    final out = <_GraduateMapAdminItem>[];
    value.forEach((key, raw) {
      if (raw is! Map) return;
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
      out.add(
        _GraduateMapAdminItem(
          id: key.toString(),
          name: (m['name'] ?? '').toString().trim(),
          photoUrl: (m['photoUrl'] ?? '').toString().trim(),
          country: (m['country'] ?? '').toString().trim(),
          city: (m['city'] ?? '').toString().trim(),
          lat: _toDouble(m['lat']) ?? 0,
          lng: _toDouble(m['lng']) ?? 0,
          active: m['active'] != false,
          blurPhoto: m['blurPhoto'] == true,
          learnerUid: (m['learnerUid'] ?? '').toString().trim(),
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

// ---------------------------------------------------------------------------
// Learners Map Tab
// ---------------------------------------------------------------------------

class _LearnersMapTab extends StatefulWidget {
  const _LearnersMapTab();

  @override
  State<_LearnersMapTab> createState() => _LearnersMapTabState();
}

class _LearnersMapTabState extends State<_LearnersMapTab> {
  static const _primaryBlue = Color(0xFF1A2B48);
  static const _actionOrange = Color(0xFFF98D28);

  final _usersRef = FirebaseDatabase.instance.ref('users');
  final _mapRef = FirebaseDatabase.instance.ref('graduate_world_map');
  final _publicPinsRef = FirebaseDatabase.instance.ref('public_learner_pins');

  final List<_LearnerMapItem> _learners = [];
  final Set<String> _learnerUidsOnMap = {};
  final Set<String> _adminRemovedUids = {};
  bool _loading = true;

  StreamSubscription<DatabaseEvent>? _usersSub;
  StreamSubscription<DatabaseEvent>? _mapSub;

  @override
  void initState() {
    super.initState();
    _usersSub = _usersRef.onValue.listen(_onUsersChanged);
    _mapSub = _mapRef.onValue.listen(_onMapChanged);
  }

  @override
  void dispose() {
    _usersSub?.cancel();
    _mapSub?.cancel();
    super.dispose();
  }

  void _onUsersChanged(DatabaseEvent event) {
    final rows = <_LearnerMapItem>[];
    final data = event.snapshot.value;
    if (data is Map) {
      data.forEach((key, value) {
        if (key == null || value == null) return;
        if (value is Map) {
          final uid = key.toString();
          final m = value.map((k, v) => MapEntry(k.toString(), v));
          final role = (m['role'] ?? '').toString().trim().toLowerCase();
          if (role == 'learner') {
            rows.add(
              _LearnerMapItem(
                uid: uid,
                firstName: (m['first_name'] ?? m['firstName'] ?? '')
                    .toString()
                    .trim(),
                lastName: (m['last_name'] ?? m['lastName'] ?? '')
                    .toString()
                    .trim(),
                photoUrl: _resolvePhoto(m),
                country: (m['country'] ?? '').toString().trim(),
                city: (m['city'] ?? '').toString().trim(),
                lat: _parseDouble(m['lat']),
                lng: _parseDouble(m['lng']),
              ),
            );
          }
        }
      });
    }
    rows.sort(
      (a, b) => a.firstName.toLowerCase().compareTo(b.firstName.toLowerCase()),
    );
    if (!mounted) return;
    setState(() {
      _learners
        ..clear()
        ..addAll(rows);
      _loading = false;
    });
    _autoAddNewLearners();
  }

  void _onMapChanged(DatabaseEvent event) {
    final uids = <String>{};
    final data = event.snapshot.value;
    if (data is Map) {
      data.forEach((key, value) {
        if (value is Map) {
          final lu = value['learnerUid']?.toString().trim() ?? '';
          if (lu.isNotEmpty) uids.add(lu);
        }
      });
    }
    if (!mounted) return;
    setState(
      () => _learnerUidsOnMap
        ..clear()
        ..addAll(uids),
    );
    _autoAddNewLearners();
  }

  void _autoAddNewLearners() {
    for (final learner in _learners) {
      if (learner.lat == null || learner.lng == null) continue;
      if (_learnerUidsOnMap.contains(learner.uid)) continue;
      if (_adminRemovedUids.contains(learner.uid)) continue;
      _addToMap(learner);
    }
  }

  String _resolvePhoto(Map<String, dynamic> m) {
    final direct = (m['profile_photo'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;
    final photos = m['profile_photos'];
    if (photos is List) {
      for (final item in photos) {
        final p = item.toString().trim();
        if (p.isNotEmpty) return p;
      }
    }
    if (photos is Map) {
      final entries = photos.entries.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a.key.toString()) ?? 999999;
          final bi = int.tryParse(b.key.toString()) ?? 999999;
          return ai.compareTo(bi);
        });
      for (final e in entries) {
        final p = e.value.toString().trim();
        if (p.isNotEmpty) return p;
      }
    }
    return '';
  }

  static double? _parseDouble(dynamic raw) {
    if (raw is num) return raw.toDouble();
    final s = (raw ?? '').toString().trim();
    if (s.isEmpty) return null;
    return double.tryParse(s);
  }

  String _mapName(_LearnerMapItem l) {
    final f = l.firstName.trim();
    final ln = l.lastName.trim();
    if (ln.isEmpty) return f;
    return '$f ${ln[0].toUpperCase()}';
  }

  Future<void> _addToMap(_LearnerMapItem learner) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final country = learner.country.isNotEmpty ? learner.country : 'Algeria';
    final city = learner.city.isNotEmpty ? learner.city : 'Djelfa';
    final lat = learner.lat ?? 34.6708;
    final lng = learner.lng ?? 3.2632;

    try {
      final ref = FirebaseDatabase.instance.ref('graduate_world_map').push();
      await ref.set({
        'name': _mapName(learner),
        'photoUrl': learner.photoUrl,
        'country': country,
        'city': city,
        'lat': lat,
        'lng': lng,
        'active': true,
        'blurPhoto': false,
        'learnerUid': learner.uid,
        'createdAt': ServerValue.timestamp,
        'createdByUid': user.uid,
        'updatedAt': ServerValue.timestamp,
        'updatedByUid': user.uid,
      });
      await _publicPinsRef.child(learner.uid).set({
        'name': _mapName(learner),
        'photoUrl': learner.photoUrl,
        'country': country,
        'city': city,
        'lat': lat,
        'lng': lng,
        'blurPhoto': false,
      });
      if (!mounted) return;
      setState(() => _adminRemovedUids.remove(learner.uid));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Learner added to map.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(toHumanError(e))));
    }
  }

  Future<void> _removeFromMap(_LearnerMapItem learner) async {
    try {
      final mapSnapshot = await _mapRef.get();
      if (mapSnapshot.value is Map) {
        final data = mapSnapshot.value as Map;
        for (final entry in data.entries) {
          final val = entry.value;
          if (val is Map &&
              val['learnerUid']?.toString().trim() == learner.uid) {
            await _mapRef.child(entry.key.toString()).remove();
          }
        }
      }
      await _publicPinsRef.child(learner.uid).remove();
      if (!mounted) return;
      setState(() => _adminRemovedUids.add(learner.uid));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Learner removed from map.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(toHumanError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_learners.isEmpty) {
      return Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.people_rounded, size: 48, color: _primaryBlue),
                const SizedBox(height: 12),
                const Text(
                  'No learners found.',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                const Text('Create learners in the Learners section first.'),
              ],
            ),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: _learners.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final learner = _learners[index];
        final onMap = _learnerUidsOnMap.contains(learner.uid);
        final location = [
          if (learner.city.isNotEmpty) learner.city,
          if (learner.country.isNotEmpty) learner.country,
        ].join(', ');

        return Card(
          color: Colors.white,
          elevation: 0.5,
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: _primaryBlue.withValues(alpha: 0.08),
                  backgroundImage: learner.photoUrl.isEmpty
                      ? null
                      : NetworkImage(learner.photoUrl),
                  child: learner.photoUrl.isEmpty
                      ? const Icon(Icons.person_rounded, size: 22)
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${learner.firstName} ${learner.lastName}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                        ),
                      ),
                      if (location.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(
                          location,
                          style: TextStyle(
                            fontSize: 12,
                            color: _primaryBlue.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                      if (learner.lat != null && learner.lng != null) ...[
                        const SizedBox(height: 1),
                        Text(
                          'Lat: ${learner.lat}, Lng: ${learner.lng}',
                          style: TextStyle(
                            fontSize: 11,
                            color: _primaryBlue.withValues(alpha: 0.45),
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      if (onMap)
                        const _CompactChip(
                          label: 'On Map',
                          color: Colors.green,
                        ),
                    ],
                  ),
                ),
                if (onMap)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade600,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _removeFromMap(learner),
                    icon: const Icon(
                      Icons.remove_circle_outline_rounded,
                      size: 16,
                    ),
                    label: const Text('Remove', style: TextStyle(fontSize: 12)),
                  )
                else
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _actionOrange,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _addToMap(learner),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('Add', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LearnerMapItem {
  const _LearnerMapItem({
    required this.uid,
    required this.firstName,
    required this.lastName,
    required this.photoUrl,
    required this.country,
    required this.city,
    this.lat,
    this.lng,
  });

  final String uid;
  final String firstName;
  final String lastName;
  final String photoUrl;
  final String country;
  final String city;
  final double? lat;
  final double? lng;
}
