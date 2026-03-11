import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../shared/material_webview_screen.dart';

class AdminFileManager extends StatefulWidget {
  const AdminFileManager({super.key});

  @override
  State<AdminFileManager> createState() => _AdminFileManagerState();
}

class _AdminFileManagerState extends State<AdminFileManager>
    with TickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('File Manager'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Courses'),
            Tab(text: 'Games'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _FileBrowser(
            key: PageStorageKey('courses_tab'),
            root: 'courses',
          ),
          _AdminGamesManager(
            key: PageStorageKey('games_tab'),
          ),
        ],
      ),
    );
  }
}

// ======================= COURSES TAB (UNCHANGED LOGIC) =======================

class _FileBrowser extends StatefulWidget {
  final String root;
  const _FileBrowser({super.key, required this.root});

  @override
  State<_FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<_FileBrowser>
    with AutomaticKeepAliveClientMixin {
  static const String secret = 'my_super_secret_key';
  static const String baseDomain = 'https://www.yourbridgeschool.com';
  static const String listUrl =
      'https://www.yourbridgeschool.com/api/admin/list_items.php';
  static const String createFolderUrl =
      'https://www.yourbridgeschool.com/api/admin/create_folder.php';
  static const String uploadUrl =
      'https://www.yourbridgeschool.com/api/admin/upload_file.php';
  static const String renameUrl =
      'https://www.yourbridgeschool.com/api/admin/rename_item.php';
  static const String deleteUrl =
      'https://www.yourbridgeschool.com/api/admin/delete_item.php';

  List<Map<String, dynamic>> items = [];
  String path = '';
  bool isLoading = false;
  bool isUploading = false;

  @override
  bool get wantKeepAlive => true;

  String sha1(String s) {
    final bytes = utf8.encode(s);
    return crypto.sha1.convert(bytes).toString();
  }

  String _joinPath(String parent, String name) {
    if (parent.trim().isEmpty) return name;
    return '$parent/$name';
  }

  String _publicUrlForItem({
    required String itemName,
    required bool isFolder,
  }) {
    final joined = _joinPath(path, itemName);
    final encodedSegments = joined
        .split('/')
        .where((e) => e.trim().isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');

    final suffix = isFolder ? '/' : '';
    return '$baseDomain/${widget.root}/$encodedSegments$suffix';
  }

  Future<Map<String, dynamic>> _postForm({
    required String url,
    required Map<String, String> body,
  }) async {
    final r = await http.post(Uri.parse(url), body: body);

    final raw = r.body.trim();
    if (!raw.startsWith('{')) {
      throw Exception('Server did not return JSON.\n$raw');
    }

    final data = json.decode(raw);
    if (data is! Map<String, dynamic>) {
      throw Exception('Invalid server response.');
    }

    return data;
  }

  Future<void> load({bool silent = false}) async {
    if (!mounted) return;

    if (!silent) {
      setState(() {
        isLoading = true;
      });
    }

    try {
      final data = await _postForm(
        url: listUrl,
        body: {
          'key': sha1(secret),
          'root': widget.root,
          'path': path,
        },
      );

      if (!mounted) return;

      if (data['success'] == true) {
        final rawItems = data['items'];
        final nextItems = <Map<String, dynamic>>[];

        if (rawItems is List) {
          for (final e in rawItems) {
            if (e is Map) {
              nextItems.add(Map<String, dynamic>.from(e));
            }
          }
        }

        nextItems.sort((a, b) {
          final aType = (a['type'] ?? '').toString();
          final bType = (b['type'] ?? '').toString();

          if (aType == 'folder' && bType != 'folder') return -1;
          if (aType != 'folder' && bType == 'folder') return 1;

          final aName = (a['name'] ?? '').toString().toLowerCase();
          final bName = (b['name'] ?? '').toString().toLowerCase();
          return aName.compareTo(bName);
        });

        setState(() {
          items = nextItems;
        });
      } else {
        _showSnack((data['message'] ?? 'Failed to load items').toString());
      }
    } catch (e) {
      _showSnack('Load failed: $e');
    } finally {
      if (!mounted) return;
      setState(() {
        isLoading = false;
      });
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    _showSnack('$label copied');
  }

  Future<void> _createFolderDialog() async {
    final c = TextEditingController();

    await showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('Create Folder'),
          content: TextField(
            controller: c,
            decoration: const InputDecoration(
              hintText: 'Folder name',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final folderName = c.text.trim();
                if (folderName.isEmpty) {
                  _showSnack('Folder name is empty');
                  return;
                }

                try {
                  final data = await _postForm(
                    url: createFolderUrl,
                    body: {
                      'key': sha1(secret),
                      'root': widget.root,
                      'parent': path,
                      'folder': folderName,
                    },
                  );

                  if (!mounted) return;
                  Navigator.pop(context);

                  if (data['success'] == true) {
                    await load(silent: true);
                    _showSnack('Folder created');
                  } else {
                    _showSnack(
                      (data['message'] ?? 'Create folder failed').toString(),
                    );
                  }
                } catch (e) {
                  if (!mounted) return;
                  Navigator.pop(context);
                  _showSnack('Create folder failed: $e');
                }
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _renameItemDialog(Map<String, dynamic> item) async {
    final oldName = (item['name'] ?? '').toString();
    final isFolder = (item['type'] ?? '') == 'folder';
    final c = TextEditingController(text: oldName);

    await showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: Text(isFolder ? 'Rename Folder' : 'Rename File'),
          content: TextField(
            controller: c,
            decoration: InputDecoration(
              hintText: isFolder ? 'New folder name' : 'New file name',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final newName = c.text.trim();
                if (newName.isEmpty) {
                  _showSnack('Name is empty');
                  return;
                }

                try {
                  final data = await _postForm(
                    url: renameUrl,
                    body: {
                      'key': sha1(secret),
                      'root': widget.root,
                      'path': _joinPath(path, oldName),
                      'new_name': newName,
                    },
                  );

                  if (!mounted) return;
                  Navigator.pop(context);

                  if (data['success'] == true) {
                    await load(silent: true);
                    _showSnack('Renamed successfully');
                  } else {
                    _showSnack(
                      (data['message'] ?? 'Rename failed').toString(),
                    );
                  }
                } catch (e) {
                  if (!mounted) return;
                  Navigator.pop(context);
                  _showSnack('Rename failed: $e');
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final itemName = (item['name'] ?? '').toString();
    final isFolder = (item['type'] ?? '') == 'folder';

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: Text(isFolder ? 'Delete Folder?' : 'Delete File?'),
          content: Text(
            isFolder
                ? 'Delete "$itemName" and everything inside it?'
                : 'Delete "$itemName"?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    ) ??
        false;

    if (!ok) return;

    try {
      final data = await _postForm(
        url: deleteUrl,
        body: {
          'key': sha1(secret),
          'root': widget.root,
          'path': _joinPath(path, itemName),
        },
      );

      if (data['success'] == true) {
        await load(silent: true);
        _showSnack('Deleted successfully');
      } else {
        _showSnack((data['message'] ?? 'Delete failed').toString());
      }
    } catch (e) {
      _showSnack('Delete failed: $e');
    }
  }

  Future<void> _uploadFile() async {
    if (isUploading) return;

    try {
      setState(() {
        isUploading = true;
      });

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final picked = result.files.single;

      final req = http.MultipartRequest('POST', Uri.parse(uploadUrl));
      req.fields['key'] = sha1(secret);
      req.fields['root'] = widget.root;
      req.fields['path'] = path;

      if (picked.path != null && picked.path!.isNotEmpty) {
        req.files.add(
          await http.MultipartFile.fromPath(
            'file',
            picked.path!,
            filename: picked.name,
          ),
        );
      } else {
        final Uint8List? bytes = picked.bytes;
        if (bytes == null) {
          _showSnack('Could not read selected file');
          return;
        }

        req.files.add(
          http.MultipartFile.fromBytes(
            'file',
            bytes,
            filename: picked.name,
          ),
        );
      }

      final streamed = await req.send();
      final response = await http.Response.fromStream(streamed);

      final raw = response.body.trim();
      if (!raw.startsWith('{')) {
        throw Exception('Server did not return JSON.\n$raw');
      }

      final data = json.decode(raw);
      if (data is! Map<String, dynamic>) {
        throw Exception('Invalid upload response');
      }

      if (data['success'] == true) {
        await load(silent: true);
        _showSnack('Upload successful');
      } else {
        _showSnack((data['message'] ?? 'Upload failed').toString());
      }
    } catch (e) {
      _showSnack('Upload failed: $e');
    } finally {
      if (!mounted) return;
      setState(() {
        isUploading = false;
      });
    }
  }

  void _openFolder(String name) {
    setState(() {
      path = _joinPath(path, name);
    });
    load(silent: true);
  }

  void _goToRoot() {
    setState(() {
      path = '';
    });
    load(silent: true);
  }

  void _goUp() {
    if (path.trim().isEmpty) return;

    final parts = path.split('/')..removeWhere((e) => e.trim().isEmpty);
    if (parts.isNotEmpty) {
      parts.removeLast();
    }

    setState(() {
      path = parts.join('/');
    });
    load(silent: true);
  }

  Widget _buildPathBar() {
    final parts = path.split('/')..removeWhere((e) => e.trim().isEmpty);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      color: Colors.white,
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: path.isEmpty ? null : _goUp,
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Back folder',
              ),
              const SizedBox(width: 4),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    children: [
                      ActionChip(
                        label: Text(widget.root),
                        onPressed: _goToRoot,
                      ),
                      for (int i = 0; i < parts.length; i++)
                        ActionChip(
                          label: Text(parts[i]),
                          onPressed: () {
                            final newPath = parts.take(i + 1).join('/');
                            setState(() {
                              path = newPath;
                            });
                            load(silent: true);
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  path.isEmpty ? '/${widget.root}' : '/${widget.root}/$path',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.black54,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => load(),
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Refresh',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildItemTile(Map<String, dynamic> item) {
    final itemName = (item['name'] ?? '').toString();
    final isFolder = (item['type'] ?? '') == 'folder';
    final link = _publicUrlForItem(itemName: itemName, isFolder: isFolder);

    return ListTile(
      leading: Icon(
        isFolder ? Icons.folder_rounded : Icons.insert_drive_file_rounded,
        color: isFolder ? Colors.amber[700] : Colors.blueGrey,
      ),
      title: Text(
        itemName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        isFolder ? 'Folder' : 'File',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        if (isFolder) {
          _openFolder(itemName);
        }
      },
      trailing: PopupMenuButton<String>(
        onSelected: (value) async {
          if (value == 'copy_link') {
            await _copyText(link, 'Link');
          } else if (value == 'rename') {
            await _renameItemDialog(item);
          } else if (value == 'delete') {
            await _deleteItem(item);
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'copy_link',
            child: ListTile(
              leading: Icon(Icons.link_rounded),
              title: Text('Copy link'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'rename',
            child: ListTile(
              leading: Icon(Icons.edit_rounded),
              title: Text('Rename'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_rounded, color: Colors.red),
              title: Text('Delete'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scaffold(
      body: Column(
        children: [
          _buildPathBar(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => load(),
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : items.isEmpty
                  ? ListView(
                children: const [
                  SizedBox(height: 120),
                  Center(
                    child: Text(
                      'No files or folders here',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                ],
              )
                  : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _buildItemTile(items[i]),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _createFolderDialog,
                  icon: const Icon(Icons.create_new_folder_rounded),
                  label: const Text('Create Folder'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isUploading ? null : _uploadFile,
                  icon: isUploading
                      ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Icon(Icons.upload_file_rounded),
                  label: Text(isUploading ? 'Uploading...' : 'Upload File'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================= GAMES TAB (ADMIN POWERS) =======================

class _AdminGamesManager extends StatefulWidget {
  const _AdminGamesManager({super.key});

  @override
  State<_AdminGamesManager> createState() => _AdminGamesManagerState();
}

class _AdminGamesManagerState extends State<_AdminGamesManager>
    with AutomaticKeepAliveClientMixin {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final String? _myUid = FirebaseAuth.instance.currentUser?.uid;

  bool _saving = false;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _statusFilter = 'all';
  String _categoryFilter = 'all';
  String _sortBy = 'updated_desc';

  static const String _secret = 'my_super_secret_key';
  static const String _uploadUrl =
      'https://www.yourbridgeschool.com/api/admin/upload_file.php';

  DatabaseReference get _gamesRef => _db.child('games');

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _sha1(String s) {
    final bytes = utf8.encode(s);
    return crypto.sha1.convert(bytes).toString();
  }

  String _safeFolderName(String value) {
    final cleaned = value
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');

    if (cleaned.isEmpty) return 'game';
    return cleaned;
  }

  Future<String?> _uploadToServer({
    required String ownerUid,
    required String gameUid,
    required String gameName,
    required bool isThumbnail,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: true,
      type: isThumbnail ? FileType.image : FileType.any,
    );

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final picked = result.files.single;
    final req = http.MultipartRequest('POST', Uri.parse(_uploadUrl));

    req.fields['key'] = _sha1(_secret);
    req.fields['root'] = 'games';
    req.fields['path'] =
    'library/$ownerUid/$gameUid-${_safeFolderName(gameName)}';

    if (picked.path != null && picked.path!.isNotEmpty) {
      req.files.add(
        await http.MultipartFile.fromPath(
          'file',
          picked.path!,
          filename: picked.name,
        ),
      );
    } else {
      final Uint8List? bytes = picked.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected file');
      }

      req.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: picked.name,
        ),
      );
    }

    final streamed = await req.send();
    final response = await http.Response.fromStream(streamed);

    final raw = response.body.trim();
    if (!raw.startsWith('{')) {
      throw Exception('Server did not return JSON.\n$raw');
    }

    final data = json.decode(raw);
    if (data is! Map<String, dynamic>) {
      throw Exception('Invalid upload response');
    }

    if (data['success'] == true) {
      final url = (data['url'] ?? '').toString().trim();
      if (url.isEmpty) {
        throw Exception('Upload succeeded but no URL was returned');
      }
      return url;
    }

    throw Exception((data['message'] ?? 'Upload failed').toString());
  }

  Future<Map<String, dynamic>?> _loadCurrentUserData() async {
    final uid = _myUid;
    if (uid == null || uid.isEmpty) return null;

    try {
      final snap = await _db.child('users/$uid').get();
      if (!snap.exists || snap.value is! Map) return null;

      return Map<String, dynamic>.from(snap.value as Map);
    } catch (_) {
      return null;
    }
  }

  List<String> _extractAllKnownTags(dynamic gamesValue) {
    final out = <String>{};

    if (gamesValue is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(gamesValue);

    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;

      final game = Map<String, dynamic>.from(value as Map);
      final tags = game['tags'];

      if (tags is List) {
        for (final item in tags) {
          final v = item.toString().trim();
          if (v.isNotEmpty) out.add(v);
        }
      } else if (tags is Map) {
        final tagMap = Map<dynamic, dynamic>.from(tags);
        for (final item in tagMap.values) {
          final v = item.toString().trim();
          if (v.isNotEmpty) out.add(v);
        }
      } else if (tags is String) {
        final v = tags.trim();
        if (v.isNotEmpty) out.add(v);
      }
    }

    final list = out.toList();
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<String> _extractAllCategories(dynamic gamesValue) {
    final out = <String>{};

    if (gamesValue is! Map) return [];

    final raw = Map<dynamic, dynamic>.from(gamesValue);

    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;

      final game = Map<String, dynamic>.from(value as Map);
      final category = (game['category'] ?? '').toString().trim();
      if (category.isNotEmpty) out.add(category);
    }

    final list = out.toList();
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  Future<void> _openGame(Map<String, dynamic> game) async {
    final link = (game['link'] ?? '').toString().trim();
    final name = (game['name'] ?? 'Game').toString().trim();

    if (link.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This game has no link.')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MaterialWebViewScreen.fromUrl(
          title: name.isEmpty ? 'Game' : name,
          url: link,
        ),
      ),
    );
  }

  Future<void> _deleteGame(String gameId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Delete game'),
          content: const Text(
            'Are you sure you want to delete this game from the games node?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    ) ??
        false;

    if (!ok) return;

    try {
      await _gamesRef.child(gameId).remove();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Game deleted successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete game: $e')),
      );
    }
  }

  Future<void> _duplicateGame({
    required Map<String, dynamic> existingGame,
  }) async {
    try {
      final ref = _gamesRef.push();
      final now = ServerValue.timestamp;

      final cloned = <String, dynamic>{
        ...existingGame,
        'gameUid': ref.key ?? '',
        'name': '${(existingGame['name'] ?? 'Game').toString().trim()} Copy',
        'createdAt': now,
        'updatedAt': now,
        'status': 'draft',
      };

      await ref.set(cloned);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Game duplicated successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to duplicate game: $e')),
      );
    }
  }

  Future<void> _toggleArchive({
    required String gameId,
    required Map<String, dynamic> game,
  }) async {
    final currentStatus = (game['status'] ?? 'ready').toString().trim();
    final nextStatus = currentStatus == 'archived' ? 'ready' : 'archived';

    try {
      await _gamesRef.child(gameId).update({
        'status': nextStatus,
        'updatedAt': ServerValue.timestamp,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            nextStatus == 'archived'
                ? 'Game archived successfully.'
                : 'Game restored successfully.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update game: $e')),
      );
    }
  }

  Future<void> _showGameForm({
    String? gameId,
    Map<String, dynamic>? existingGame,
    List<String> knownTags = const <String>[],
  }) async {
    final isEdit = gameId != null && existingGame != null;
    final draftGameUid = gameId ?? _gamesRef.push().key ?? '';

    final nameController = TextEditingController(
      text: (existingGame?['name'] ?? '').toString(),
    );
    final descriptionController = TextEditingController(
      text: (existingGame?['description'] ?? '').toString(),
    );
    final rulesController = TextEditingController(
      text: (existingGame?['rules'] ?? '').toString(),
    );
    final categoryController = TextEditingController(
      text: (existingGame?['category'] ?? '').toString(),
    );
    final levelController = TextEditingController(
      text: (existingGame?['level'] ?? '').toString(),
    );
    final durationController = TextEditingController(
      text: (existingGame?['durationMinutes'] ?? '').toString(),
    );
    final teacherNotesController = TextEditingController(
      text: (existingGame?['teacherNotes'] ?? '').toString(),
    );
    final tagInputController = TextEditingController();

    final selectedTags = <String>{
      ...knownTags.where((e) => e.trim().isNotEmpty).map((e) => e.trim()),
    };

    final existingTagsValue = existingGame?['tags'];
    if (existingTagsValue is List) {
      for (final item in existingTagsValue) {
        final v = item.toString().trim();
        if (v.isNotEmpty) selectedTags.add(v);
      }
    } else if (existingTagsValue is Map) {
      final tagMap = Map<dynamic, dynamic>.from(existingTagsValue);
      for (final item in tagMap.values) {
        final v = item.toString().trim();
        if (v.isNotEmpty) selectedTags.add(v);
      }
    } else if (existingTagsValue is String) {
      final v = existingTagsValue.trim();
      if (v.isNotEmpty) selectedTags.add(v);
    }

    final chosenTags = <String>{
      if (isEdit)
        ...selectedTags.where((e) => e.trim().isNotEmpty).map((e) => e.trim()),
    };

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        bool localSaving = false;
        bool localUploadingGame = false;
        bool localUploadingThumb = false;

        String uploadedUrl = (existingGame?['link'] ?? '').toString().trim();
        String uploadedThumbnail =
        (existingGame?['thumbnail'] ?? '').toString().trim();
        String selectedStatus =
        (existingGame?['status'] ?? 'ready').toString().trim();

        return StatefulBuilder(
          builder: (context, setLocalState) {
            void addTag(String raw) {
              final tag = raw.trim();
              if (tag.isEmpty) return;

              setLocalState(() {
                selectedTags.add(tag);
                chosenTags.add(tag);
                tagInputController.clear();
              });
            }

            Future<void> uploadGameFile() async {
              final user = await _loadCurrentUserData();
              final uid = _myUid;

              if (uid == null || uid.isEmpty || user == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Could not load admin details.')),
                );
                return;
              }

              final gameName = nameController.text.trim();
              if (gameName.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Enter the game name before uploading.'),
                  ),
                );
                return;
              }

              setLocalState(() {
                localUploadingGame = true;
              });

              try {
                final url = await _uploadToServer(
                  ownerUid: uid,
                  gameUid: draftGameUid,
                  gameName: gameName,
                  isThumbnail: false,
                );

                if (url != null && url.trim().isNotEmpty) {
                  setLocalState(() {
                    uploadedUrl = url.trim();
                  });

                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Game file uploaded successfully.'),
                    ),
                  );
                }
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Upload failed: $e')),
                );
              } finally {
                setLocalState(() {
                  localUploadingGame = false;
                });
              }
            }

            Future<void> uploadThumbnail() async {
              final user = await _loadCurrentUserData();
              final uid = _myUid;

              if (uid == null || uid.isEmpty || user == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Could not load admin details.')),
                );
                return;
              }

              final gameName = nameController.text.trim();
              if (gameName.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Enter the game name before uploading thumbnail.'),
                  ),
                );
                return;
              }

              setLocalState(() {
                localUploadingThumb = true;
              });

              try {
                final url = await _uploadToServer(
                  ownerUid: uid,
                  gameUid: draftGameUid,
                  gameName: gameName,
                  isThumbnail: true,
                );

                if (url != null && url.trim().isNotEmpty) {
                  setLocalState(() {
                    uploadedThumbnail = url.trim();
                  });

                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Thumbnail uploaded successfully.'),
                    ),
                  );
                }
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Thumbnail upload failed: $e')),
                );
              } finally {
                setLocalState(() {
                  localUploadingThumb = false;
                });
              }
            }

            Future<void> saveGame() async {
              final name = nameController.text.trim();
              final description = descriptionController.text.trim();
              final rules = rulesController.text.trim();
              final category = categoryController.text.trim();
              final level = levelController.text.trim();
              final teacherNotes = teacherNotesController.text.trim();
              final link = uploadedUrl.trim();
              final thumbnail = uploadedThumbnail.trim();
              final durationMinutes =
                  int.tryParse(durationController.text.trim()) ?? 0;

              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter the game name.')),
                );
                return;
              }

              if (description.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please enter the game description.'),
                  ),
                );
                return;
              }

              if (link.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please upload the game file first.'),
                  ),
                );
                return;
              }

              final currentUser = await _loadCurrentUserData();
              final uid = _myUid;

              if (currentUser == null || uid == null || uid.isEmpty) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Could not load admin details.')),
                );
                return;
              }

              final firstName =
              (currentUser['first_name'] ?? '').toString().trim();
              final lastName =
              (currentUser['last_name'] ?? '').toString().trim();
              final email = (currentUser['email'] ?? '').toString().trim();
              final serial = (currentUser['serial'] ?? '').toString().trim();
              final now = ServerValue.timestamp;

              final tagsToSave = chosenTags
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList()
                ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

              setLocalState(() => localSaving = true);
              if (mounted) {
                setState(() => _saving = true);
              }

              try {
                final ref =
                isEdit ? _gamesRef.child(gameId!) : _gamesRef.child(draftGameUid);

                final oldTeacherUid =
                (existingGame?['teacherUid'] ?? '').toString().trim();
                final oldTeacherFirst =
                (existingGame?['teacherFirstName'] ?? '').toString().trim();
                final oldTeacherLast =
                (existingGame?['teacherLastName'] ?? '').toString().trim();
                final oldTeacherEmail =
                (existingGame?['teacherEmail'] ?? '').toString().trim();
                final oldTeacherSerial =
                (existingGame?['teacherSerial'] ?? '').toString().trim();

                final data = <String, dynamic>{
                  'gameUid': ref.key ?? draftGameUid,
                  'teacherUid': oldTeacherUid.isNotEmpty ? oldTeacherUid : uid,
                  'teacherFirstName':
                  oldTeacherFirst.isNotEmpty ? oldTeacherFirst : firstName,
                  'teacherLastName':
                  oldTeacherLast.isNotEmpty ? oldTeacherLast : lastName,
                  'teacherEmail':
                  oldTeacherEmail.isNotEmpty ? oldTeacherEmail : email,
                  'teacherSerial':
                  oldTeacherSerial.isNotEmpty ? oldTeacherSerial : serial,
                  'adminUid': uid,
                  'adminFirstName': firstName,
                  'adminLastName': lastName,
                  'adminEmail': email,
                  'name': name,
                  'description': description,
                  'rules': rules,
                  'link': link,
                  'thumbnail': thumbnail,
                  'tags': tagsToSave,
                  'category': category,
                  'level': level,
                  'durationMinutes': durationMinutes,
                  'teacherNotes': teacherNotes,
                  'status': selectedStatus,
                  'updatedAt': now,
                };

                if (!isEdit) {
                  data['createdAt'] = now;
                } else {
                  data['createdAt'] =
                      existingGame?['createdAt'] ?? ServerValue.timestamp;
                }

                await ref.update(data);

                if (!mounted) return;
                Navigator.of(ctx).pop();

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      isEdit
                          ? 'Game updated successfully.'
                          : 'Game added successfully.',
                    ),
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to save game: $e')),
                );
              } finally {
                if (mounted) {
                  setState(() => _saving = false);
                }
              }
            }

            final sortedTags = selectedTags.toList()
              ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  MediaQuery.of(context).viewInsets.bottom + 16,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isEdit ? 'Edit Game' : 'Add Game',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: nameController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: descriptionController,
                        minLines: 3,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: rulesController,
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'Rules (if any)',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: categoryController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Category',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: levelController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Level',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: durationController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Duration in minutes',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: const ['draft', 'ready', 'hidden', 'archived']
                            .contains(selectedStatus)
                            ? selectedStatus
                            : 'ready',
                        decoration: const InputDecoration(
                          labelText: 'Status',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'draft', child: Text('Draft')),
                          DropdownMenuItem(value: 'ready', child: Text('Ready')),
                          DropdownMenuItem(value: 'hidden', child: Text('Hidden')),
                          DropdownMenuItem(value: 'archived', child: Text('Archived')),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setLocalState(() {
                            selectedStatus = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: teacherNotesController,
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'Notes',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Game File',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (uploadedUrl.isNotEmpty) ...[
                              Text(
                                uploadedUrl,
                                style: TextStyle(
                                  color: Colors.blue.shade700,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      await Clipboard.setData(
                                        ClipboardData(text: uploadedUrl),
                                      );
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Link copied'),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.link_rounded),
                                    label: const Text('Copy Link'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed:
                                    localUploadingGame ? null : uploadGameFile,
                                    icon: const Icon(Icons.sync_rounded),
                                    label: const Text('Replace File'),
                                  ),
                                ],
                              ),
                            ] else ...[
                              const Text(
                                'No game file uploaded yet.',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.icon(
                                onPressed:
                                localUploadingGame ? null : uploadGameFile,
                                icon: localUploadingGame
                                    ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                    : const Icon(Icons.upload_file_rounded),
                                label: Text(
                                  localUploadingGame
                                      ? 'Uploading...'
                                      : 'Upload Game File',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Thumbnail',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (uploadedThumbnail.isNotEmpty) ...[
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.network(
                                  uploadedThumbnail,
                                  height: 140,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    height: 140,
                                    alignment: Alignment.center,
                                    color: Colors.grey.shade100,
                                    child: const Text('Could not load thumbnail'),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      await Clipboard.setData(
                                        ClipboardData(text: uploadedThumbnail),
                                      );
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Thumbnail link copied'),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.link_rounded),
                                    label: const Text('Copy Link'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed:
                                    localUploadingThumb ? null : uploadThumbnail,
                                    icon: const Icon(Icons.image_rounded),
                                    label: const Text('Replace Thumbnail'),
                                  ),
                                ],
                              ),
                            ] else ...[
                              const Text(
                                'No thumbnail uploaded yet.',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.icon(
                                onPressed:
                                localUploadingThumb ? null : uploadThumbnail,
                                icon: localUploadingThumb
                                    ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                    : const Icon(Icons.upload_rounded),
                                label: Text(
                                  localUploadingThumb
                                      ? 'Uploading...'
                                      : 'Upload Thumbnail',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Tags',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: tagInputController,
                              onSubmitted: addTag,
                              decoration: const InputDecoration(
                                labelText: 'Add tag',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: localSaving
                                ? null
                                : () => addTag(tagInputController.text),
                            child: const Text('Add'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (sortedTags.isNotEmpty)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: sortedTags.map((tag) {
                            final selected = chosenTags.contains(tag);

                            return FilterChip(
                              label: Text(tag),
                              selected: selected,
                              onSelected: localSaving
                                  ? null
                                  : (value) {
                                setLocalState(() {
                                  if (value) {
                                    chosenTags.add(tag);
                                  } else {
                                    chosenTags.remove(tag);
                                  }
                                });
                              },
                              onDeleted: localSaving
                                  ? null
                                  : () {
                                setLocalState(() {
                                  selectedTags.remove(tag);
                                  chosenTags.remove(tag);
                                });
                              },
                            );
                          }).toList(),
                        )
                      else
                        const Text(
                          'No tags yet. Add the first one.',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: localSaving
                                  ? null
                                  : () => Navigator.of(ctx).pop(),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: localSaving ? null : saveGame,
                              child: Text(localSaving ? 'Saving...' : 'Save'),
                            ),
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
  }

  String _ownerName(Map<String, dynamic> game) {
    final first = (game['teacherFirstName'] ?? '').toString().trim();
    final last = (game['teacherLastName'] ?? '').toString().trim();
    final full = ('$first $last').trim();

    if (full.isNotEmpty) return full;

    final adminFirst = (game['adminFirstName'] ?? '').toString().trim();
    final adminLast = (game['adminLastName'] ?? '').toString().trim();
    final adminFull = ('$adminFirst $adminLast').trim();
    if (adminFull.isNotEmpty) return adminFull;

    final email = (game['teacherEmail'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;

    final adminEmail = (game['adminEmail'] ?? '').toString().trim();
    if (adminEmail.isNotEmpty) return adminEmail;

    return 'Unknown';
  }

  List<String> _tagsFromGame(Map<String, dynamic> game) {
    final out = <String>[];
    final tags = game['tags'];

    if (tags is List) {
      for (final item in tags) {
        final v = item.toString().trim();
        if (v.isNotEmpty) out.add(v);
      }
    } else if (tags is Map) {
      final tagMap = Map<dynamic, dynamic>.from(tags);
      for (final item in tagMap.values) {
        final v = item.toString().trim();
        if (v.isNotEmpty) out.add(v);
      }
    } else if (tags is String) {
      final v = tags.trim();
      if (v.isNotEmpty) out.add(v);
    }

    return out;
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'draft':
        return Colors.orange;
      case 'hidden':
        return Colors.grey;
      case 'archived':
        return Colors.blueGrey;
      case 'ready':
      default:
        return Colors.green;
    }
  }

  Widget _buildGameCard({
    required String gameId,
    required Map<String, dynamic> game,
    required List<String> knownTags,
  }) {
    final tags = _tagsFromGame(game);
    final name = (game['name'] ?? '').toString().trim();
    final description = (game['description'] ?? '').toString().trim();
    final rules = (game['rules'] ?? '').toString().trim();
    final link = (game['link'] ?? '').toString().trim();
    final thumbnail = (game['thumbnail'] ?? '').toString().trim();
    final ownerName = _ownerName(game);
    final category = (game['category'] ?? '').toString().trim();
    final level = (game['level'] ?? '').toString().trim();
    final status = (game['status'] ?? 'ready').toString().trim();
    final notes = (game['teacherNotes'] ?? '').toString().trim();
    final durationMinutes = _toInt(game['durationMinutes']);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (thumbnail.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  thumbnail,
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    height: 160,
                    color: Colors.grey.shade100,
                    alignment: Alignment.center,
                    child: const Text('Thumbnail failed to load'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    name.isEmpty ? 'Untitled Game' : name,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Chip(
                  label: Text(status),
                  backgroundColor: _statusColor(status).withOpacity(0.12),
                  side: BorderSide(color: _statusColor(status)),
                  labelStyle: TextStyle(
                    color: _statusColor(status),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Owner: $ownerName',
              style: TextStyle(
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (category.isNotEmpty) Chip(label: Text(category)),
                if (level.isNotEmpty) Chip(label: Text(level)),
                if (durationMinutes > 0) Chip(label: Text('$durationMinutes min')),
              ],
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                description,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ],
            if (rules.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Rules',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              Text(
                rules,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ],
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Notes',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              Text(
                notes,
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ],
            if (link.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                link,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.blue.shade700,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: tags.map((tag) => Chip(label: Text(tag))).toList(),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _openGame(game),
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: const Text('Open'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showGameForm(
                    gameId: gameId,
                    existingGame: game,
                    knownTags: knownTags,
                  ),
                  icon: const Icon(Icons.edit_rounded),
                  label: const Text('Edit'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _duplicateGame(existingGame: game),
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Duplicate'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _toggleArchive(gameId: gameId, game: game),
                  icon: Icon(
                    status == 'archived'
                        ? Icons.unarchive_rounded
                        : Icons.archive_rounded,
                  ),
                  label: Text(status == 'archived' ? 'Restore' : 'Archive'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _deleteGame(gameId),
                  icon: const Icon(Icons.delete_rounded),
                  label: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<MapEntry<String, Map<String, dynamic>>> _applyFiltersAndSort({
    required List<MapEntry<String, Map<String, dynamic>>> items,
  }) {
    var filtered = items.where((entry) {
      final game = entry.value;

      final name = (game['name'] ?? '').toString().toLowerCase().trim();
      final description =
      (game['description'] ?? '').toString().toLowerCase().trim();
      final category = (game['category'] ?? '').toString().toLowerCase().trim();
      final level = (game['level'] ?? '').toString().toLowerCase().trim();
      final status = (game['status'] ?? 'ready').toString().toLowerCase().trim();
      final tags = _tagsFromGame(game).map((e) => e.toLowerCase()).join(' ');

      final matchesSearch = _searchQuery.isEmpty ||
          name.contains(_searchQuery) ||
          description.contains(_searchQuery) ||
          category.contains(_searchQuery) ||
          level.contains(_searchQuery) ||
          tags.contains(_searchQuery);

      final matchesStatus =
          _statusFilter == 'all' || status == _statusFilter.toLowerCase();

      final matchesCategory = _categoryFilter == 'all' ||
          category == _categoryFilter.toLowerCase();

      return matchesSearch && matchesStatus && matchesCategory;
    }).toList();

    filtered.sort((a, b) {
      switch (_sortBy) {
        case 'name_asc':
          return (a.value['name'] ?? '')
              .toString()
              .toLowerCase()
              .compareTo((b.value['name'] ?? '').toString().toLowerCase());
        case 'name_desc':
          return (b.value['name'] ?? '')
              .toString()
              .toLowerCase()
              .compareTo((a.value['name'] ?? '').toString().toLowerCase());
        case 'created_desc':
          return _toInt(b.value['createdAt']).compareTo(_toInt(a.value['createdAt']));
        case 'created_asc':
          return _toInt(a.value['createdAt']).compareTo(_toInt(b.value['createdAt']));
        case 'updated_asc':
          return _toInt(a.value['updatedAt']).compareTo(_toInt(b.value['updatedAt']));
        case 'updated_desc':
        default:
          return _toInt(b.value['updatedAt']).compareTo(_toInt(a.value['updatedAt']));
      }
    });

    return filtered;
  }

  Widget _buildFilterBar(List<String> categories) {
    final categoryItems = ['all', ...categories];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            onChanged: (value) {
              setState(() {
                _searchQuery = value.trim().toLowerCase();
              });
            },
            decoration: InputDecoration(
              hintText: 'Search games...',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                onPressed: () {
                  _searchController.clear();
                  setState(() {
                    _searchQuery = '';
                  });
                },
                icon: const Icon(Icons.clear_rounded),
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _statusFilter,
                  decoration: const InputDecoration(
                    labelText: 'Status',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All')),
                    DropdownMenuItem(value: 'draft', child: Text('Draft')),
                    DropdownMenuItem(value: 'ready', child: Text('Ready')),
                    DropdownMenuItem(value: 'hidden', child: Text('Hidden')),
                    DropdownMenuItem(value: 'archived', child: Text('Archived')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _statusFilter = value;
                    });
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _categoryFilter,
                  decoration: const InputDecoration(
                    labelText: 'Category',
                    border: OutlineInputBorder(),
                  ),
                  items: categoryItems
                      .map(
                        (e) => DropdownMenuItem(
                      value: e,
                      child: Text(e == 'all' ? 'All' : e),
                    ),
                  )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _categoryFilter = value;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: _sortBy,
            decoration: const InputDecoration(
              labelText: 'Sort by',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'updated_desc', child: Text('Recently updated')),
              DropdownMenuItem(value: 'updated_asc', child: Text('Oldest updated')),
              DropdownMenuItem(value: 'created_desc', child: Text('Newest created')),
              DropdownMenuItem(value: 'created_asc', child: Text('Oldest created')),
              DropdownMenuItem(value: 'name_asc', child: Text('Name A-Z')),
              DropdownMenuItem(value: 'name_desc', child: Text('Name Z-A')),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _sortBy = value;
              });
            },
          ),
        ],
      ),
    );
  }

  int _adminOwnedGamesCount(List<MapEntry<String, Map<String, dynamic>>> items) {
    final uid = _myUid;
    if (uid == null || uid.isEmpty) return 0;

    return items.where((e) {
      final teacherUid = (e.value['teacherUid'] ?? '').toString().trim();
      final adminUid = (e.value['adminUid'] ?? '').toString().trim();
      return teacherUid == uid || adminUid == uid;
    }).length;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving
            ? null
            : () => _showGameForm(
          knownTags: const <String>[],
        ),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Game'),
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _gamesRef.onValue,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              snap.data == null) {
            return const Center(child: CircularProgressIndicator());
          }

          final value = snap.data?.snapshot.value;
          final knownTags = _extractAllKnownTags(value);
          final categories = _extractAllCategories(value);

          if (value == null || value is! Map) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.sports_esports_rounded,
                      size: 48,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'No games added yet.',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Tap "Add Game" to create the first game.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _saving
                          ? null
                          : () => _showGameForm(knownTags: knownTags),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add Game'),
                    ),
                  ],
                ),
              ),
            );
          }

          final raw = Map<dynamic, dynamic>.from(value);
          final items = raw.entries.map((entry) {
            final gameId = entry.key.toString();
            final gameValue = entry.value;

            final game = gameValue is Map
                ? Map<String, dynamic>.from(gameValue as Map)
                : <String, dynamic>{};

            return MapEntry(gameId, game);
          }).toList();

          final visibleItems = _applyFiltersAndSort(items: items);

          return Column(
            children: [
              _buildFilterBar(categories),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Total games: ${visibleItems.length} • Uploaded by this admin: ${_adminOwnedGamesCount(items)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Colors.black54,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    await _gamesRef.get();
                  },
                  child: visibleItems.isEmpty
                      ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 40, 16, 100),
                    children: const [
                      Center(
                        child: Text(
                          'No games match your filters.',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                    ],
                  )
                      : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    itemCount: visibleItems.length,
                    itemBuilder: (context, index) {
                      final item = visibleItems[index];
                      return _buildGameCard(
                        gameId: item.key,
                        game: item.value,
                        knownTags: knownTags,
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
