import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/backend_api.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';

class AdminGraduatesMapScreen extends StatefulWidget {
  const AdminGraduatesMapScreen({super.key});

  @override
  State<AdminGraduatesMapScreen> createState() =>
      _AdminGraduatesMapScreenState();
}

class _AdminGraduatesMapScreenState extends State<AdminGraduatesMapScreen> {
  static const _primaryBlue = Color(0xFF1A2B48);
  static const _actionOrange = Color(0xFFF98D28);
  static const _appBg = Color(0xFFF4F7F9);
  DatabaseReference get _ref =>
      FirebaseDatabase.instance.ref('graduate_world_map');

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
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1100,
        child: StreamBuilder<DatabaseEvent>(
          stream: _ref.onValue,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = _GraduateMapAdminItem.fromSnapshot(
              snapshot.data?.snapshot.value,
            );
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

            return ListView.separated(
              padding: const EdgeInsets.all(14),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final item = items[index];
                return Card(
                  color: Colors.white,
                  child: ListTile(
                    leading: CircleAvatar(
                      radius: 26,
                      backgroundColor: _primaryBlue.withValues(alpha: 0.08),
                      backgroundImage: item.photoUrl.isEmpty
                          ? null
                          : NetworkImage(item.photoUrl),
                      child: item.photoUrl.isEmpty
                          ? const Icon(Icons.person_rounded)
                          : null,
                    ),
                    title: Text(
                      item.name,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    subtitle: Text(
                      '${item.city}, ${item.country}\nLat: ${item.lat}, Lng: ${item.lng}',
                    ),
                    isThreeLine: true,
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        Chip(
                          label: Text(item.active ? 'Active' : 'Hidden'),
                          backgroundColor: item.active
                              ? Colors.green.withValues(alpha: 0.12)
                              : Colors.orange.withValues(alpha: 0.12),
                        ),
                        IconButton(
                          tooltip: 'Edit',
                          onPressed: () => _openEditor(item),
                          icon: const Icon(Icons.edit_rounded),
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          onPressed: () => _delete(item),
                          icon: const Icon(
                            Icons.delete_rounded,
                            color: Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _GraduateMapEditorDialog extends StatefulWidget {
  const _GraduateMapEditorDialog({this.item});

  final _GraduateMapAdminItem? item;

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
  bool _saving = false;
  bool _uploading = false;

  bool get _isEditing => widget.item != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _nameC = TextEditingController(text: item?.name ?? '');
    _countryC = TextEditingController(text: item?.country ?? '');
    _cityC = TextEditingController(text: item?.city ?? '');
    _latC = TextEditingController(text: item?.lat.toString() ?? '');
    _lngC = TextEditingController(text: item?.lng.toString() ?? '');
    _photoUrl = item?.photoUrl ?? '';
    _active = item?.active ?? true;
  }

  @override
  void dispose() {
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

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (_saving || _uploading) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final lat = double.parse(_latC.text.trim());
    final lng = double.parse(_lngC.text.trim());
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

  String? _required(String? value) {
    return (value ?? '').trim().isEmpty ? 'Required' : null;
  }

  String? _latValidator(String? value) {
    final n = double.tryParse((value ?? '').trim());
    if (n == null) return 'Enter a number';
    if (n < -90 || n > 90) return 'Latitude must be -90 to 90';
    return null;
  }

  String? _lngValidator(String? value) {
    final n = double.tryParse((value ?? '').trim());
    if (n == null) return 'Enter a number';
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
                TextFormField(
                  controller: _countryC,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'Country'),
                  validator: _required,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _cityC,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'City'),
                  validator: _required,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _latC,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Latitude',
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
  });

  final String id;
  final String name;
  final String photoUrl;
  final String country;
  final String city;
  final double lat;
  final double lng;
  final bool active;

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
