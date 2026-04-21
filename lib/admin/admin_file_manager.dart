import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../services/backend_api.dart';
import '../services/storage_existence.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';
import '../shared/material_webview_screen.dart';
import '../shared/app_feedback.dart';

class AdminFileManager extends StatefulWidget {
  const AdminFileManager({super.key});

  @override
  State<AdminFileManager> createState() => _AdminFileManagerState();
}

class _AdminFileManagerState extends State<AdminFileManager>
    with TickerProviderStateMixin {
  late TabController _tabs;
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  bool _globalCleanupRunning = false;
  final GlobalKey<_AdminGamesManagerState> _gamesKey =
      GlobalKey<_AdminGamesManagerState>();
  final GlobalKey<_AdminStoriesManagerState> _storiesKey =
      GlobalKey<_AdminStoriesManagerState>();
  int _activeTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() {
      if (!mounted) return;
      if (_activeTabIndex == _tabs.index) return;
      setState(() => _activeTabIndex = _tabs.index);
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _runGlobalCleanup() async {
    if (_globalCleanupRunning) return;
    setState(() => _globalCleanupRunning = true);

    var removedGames = 0;
    var clearedGameThumbs = 0;
    var removedStories = 0;

    try {
      final gamesSnap = await _db.child('games').get();
      if (gamesSnap.value is Map) {
        final games = Map<dynamic, dynamic>.from(gamesSnap.value as Map);
        final gameUpdates = <String, Object?>{};

        for (final entry in games.entries) {
          final gameId = entry.key.toString().trim();
          final raw = entry.value;
          if (gameId.isEmpty || raw is! Map) continue;
          final game = raw.map((k, v) => MapEntry(k.toString(), v));

          final link = (game['link'] ?? '').toString().trim();
          if (link.isNotEmpty) {
            final linkCheck =
                await StorageExistence.checkUrlExistsOnManagedStorage(
                  link,
                  expect: 'file',
                  allowedRoots: const {'games'},
                );
            if (linkCheck == StorageCheckResult.missing) {
              gameUpdates[gameId] = null;
              removedGames++;
              continue;
            }
          }

          final thumbnail = (game['thumbnail'] ?? '').toString().trim();
          if (thumbnail.isNotEmpty) {
            final thumbCheck =
                await StorageExistence.checkUrlExistsOnManagedStorage(
                  thumbnail,
                  expect: 'file',
                  allowedRoots: const {'games'},
                );
            if (thumbCheck == StorageCheckResult.missing) {
              gameUpdates['$gameId/thumbnail'] = '';
              clearedGameThumbs++;
            }
          }
        }

        if (gameUpdates.isNotEmpty) {
          await _db.child('games').update(gameUpdates);
        }
      }

      final storiesSnap = await _db.child('stories').get();
      if (storiesSnap.value is Map) {
        final stories = Map<dynamic, dynamic>.from(storiesSnap.value as Map);
        final storyUpdates = <String, Object?>{};

        for (final entry in stories.entries) {
          final storyId = entry.key.toString().trim();
          final raw = entry.value;
          if (storyId.isEmpty || raw is! Map) continue;
          final story = raw.map((k, v) => MapEntry(k.toString(), v));

          final folderPath = (story['serverFolderPath'] ?? '')
              .toString()
              .trim();
          if (folderPath.isEmpty) continue;

          final folderCheck = await StorageExistence.checkPathExists(
            root: 'stories',
            path: folderPath,
            expect: 'folder',
          );
          if (folderCheck == StorageCheckResult.missing) {
            storyUpdates[storyId] = null;
            removedStories++;
          }
        }

        if (storyUpdates.isNotEmpty) {
          await _db.child('stories').update(storyUpdates);
        }
      }

      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            'Cleanup done: deleted $removedGames games, cleared $clearedGameThumbs game thumbnails, removed $removedStories stories.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(toHumanError(e, fallback: 'Global cleanup failed.')),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _globalCleanupRunning = false);
      }
    }
  }

  bool get _bulkSupportedTab => _activeTabIndex == 1 || _activeTabIndex == 2;

  bool get _bulkModeEnabled {
    if (_activeTabIndex == 1) {
      return _gamesKey.currentState?.bulkModeEnabled ?? false;
    }
    if (_activeTabIndex == 2) {
      return _storiesKey.currentState?.bulkModeEnabled ?? false;
    }
    return false;
  }

  int get _selectedCount {
    if (_activeTabIndex == 1) {
      return _gamesKey.currentState?.selectedCount ?? 0;
    }
    if (_activeTabIndex == 2) {
      return _storiesKey.currentState?.selectedCount ?? 0;
    }
    return 0;
  }

  void _notifyBulkStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _toggleBulkMode() {
    if (_activeTabIndex == 1) {
      _gamesKey.currentState?.toggleBulkMode();
    } else if (_activeTabIndex == 2) {
      _storiesKey.currentState?.toggleBulkMode();
    }
    _notifyBulkStateChanged();
  }

  void _selectAll() {
    if (_activeTabIndex == 1) {
      _gamesKey.currentState?.selectAllVisible();
    } else if (_activeTabIndex == 2) {
      _storiesKey.currentState?.selectAllVisible();
    }
    _notifyBulkStateChanged();
  }

  void _clearSelection() {
    if (_activeTabIndex == 1) {
      _gamesKey.currentState?.clearSelection();
    } else if (_activeTabIndex == 2) {
      _storiesKey.currentState?.clearSelection();
    }
    _notifyBulkStateChanged();
  }

  Future<void> _deleteSelected() async {
    if (_activeTabIndex == 1) {
      await _gamesKey.currentState?.deleteSelected();
    } else if (_activeTabIndex == 2) {
      await _storiesKey.currentState?.deleteSelected();
    }
    _notifyBulkStateChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('File Manager'),
        actions: [
          IconButton(
            tooltip: 'Refresh and clean games/stories',
            onPressed: _globalCleanupRunning ? null : _runGlobalCleanup,
            icon: _globalCleanupRunning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
          if (_bulkSupportedTab) ...[
            IconButton(
              tooltip: _bulkModeEnabled ? 'Exit bulk select' : 'Bulk select',
              onPressed: _toggleBulkMode,
              icon: Icon(
                _bulkModeEnabled
                    ? Icons.checklist_rtl_rounded
                    : Icons.select_all_rounded,
              ),
            ),
            if (_bulkModeEnabled) ...[
              IconButton(
                tooltip: 'Select all',
                onPressed: _selectAll,
                icon: const Icon(Icons.done_all_rounded),
              ),
              IconButton(
                tooltip: 'Clear selection',
                onPressed: _clearSelection,
                icon: const Icon(Icons.deselect_rounded),
              ),
              IconButton(
                tooltip: 'Delete selected',
                onPressed: _selectedCount <= 0 ? null : _deleteSelected,
                icon: const Icon(Icons.delete_sweep_rounded),
              ),
            ],
          ],
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Courses'),
            Tab(text: 'Games'),
            Tab(text: 'Stories'),
          ],
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1650,
        child: TabBarView(
          controller: _tabs,
          children: [
            const _FileBrowser(
              key: PageStorageKey('courses_tab'),
              root: 'courses',
            ),
            _AdminGamesManager(
              key: _gamesKey,
              onBulkStateChanged: _notifyBulkStateChanged,
            ),
            _AdminStoriesManager(
              key: _storiesKey,
              onBulkStateChanged: _notifyBulkStateChanged,
            ),
          ],
        ),
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
  static final Uri listUrl = BackendApi.uri('list_items_secure.php');
  static final Uri createFolderUrl = BackendApi.uri('create_folder_secure.php');
  static final Uri uploadUrl = BackendApi.uri('upload_file_secure.php');
  static final Uri renameUrl = BackendApi.uri('rename_item_secure.php');
  static final Uri deleteUrl = BackendApi.uri('delete_item_secure.php');

  List<Map<String, dynamic>> items = [];
  String path = '';
  bool isLoading = false;
  bool isUploading = false;

  @override
  bool get wantKeepAlive => true;

  String _joinPath(String parent, String name) {
    if (parent.trim().isEmpty) return name;
    return '$parent/$name';
  }

  String _publicUrlForItem({required String itemName, required bool isFolder}) {
    final joined = _joinPath(path, itemName);
    final uri = BackendApi.mediaUri(root: widget.root, path: joined);
    return isFolder ? '${uri.toString()}/' : uri.toString();
  }

  Future<Map<String, dynamic>> _postForm({
    required Uri url,
    required Map<String, String> body,
  }) async {
    final authFields = await BackendApi.authFormFields();
    final postUri = await BackendApi.withAuthQuery(url);
    final headers = await BackendApi.authHeaders();
    final r = await http
        .post(postUri, body: {...body, ...authFields}, headers: headers)
        .timeout(const Duration(seconds: 60));

    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('HTTP ${r.statusCode}');
    }

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
        body: {'root': widget.root, 'path': path},
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
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    AppToast.fromSnackBar(
      context,
      SnackBar(content: Text(humanizeUiMessage(message))),
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
            decoration: const InputDecoration(hintText: 'Folder name'),
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
                    _showSnack((data['message'] ?? 'Rename failed').toString());
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

    final ok =
        await showDialog<bool>(
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
        body: {'root': widget.root, 'path': _joinPath(path, itemName)},
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
        _showSnack('Upload was cancelled.');
        return;
      }

      final picked = result.files.single;

      final uploadUri = await BackendApi.withAuthQuery(uploadUrl);
      final req = http.MultipartRequest('POST', uploadUri);
      await BackendApi.applyAuthToMultipart(req);
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
          http.MultipartFile.fromBytes('file', bytes, filename: picked.name),
        );
      }

      final streamed = await req.send().timeout(const Duration(seconds: 120));
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(seconds: 120));

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
      if (mounted) {
        setState(() {
          isUploading = false;
        });
      }
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
      title: Text(itemName, maxLines: 1, overflow: TextOverflow.ellipsis),
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
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1600,
        child: Column(
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
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) => _buildItemTile(items[i]),
                      ),
              ),
            ),
          ],
        ),
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
  const _AdminGamesManager({super.key, this.onBulkStateChanged});

  final VoidCallback? onBulkStateChanged;

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
  bool _bulkModeEnabled = false;
  final Set<String> _selectedGameIds = <String>{};
  List<String> _visibleGameIds = const <String>[];

  bool get bulkModeEnabled => _bulkModeEnabled;
  int get selectedCount => _selectedGameIds.length;

  static final Uri _uploadUrl = BackendApi.uri('upload_file_secure.php');

  DatabaseReference get _gamesRef => _db.child('games');

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void toggleBulkMode() {
    setState(() {
      _bulkModeEnabled = !_bulkModeEnabled;
      if (!_bulkModeEnabled) _selectedGameIds.clear();
    });
    widget.onBulkStateChanged?.call();
  }

  void selectAllVisible() {
    setState(() {
      _selectedGameIds
        ..clear()
        ..addAll(_visibleGameIds);
    });
    widget.onBulkStateChanged?.call();
  }

  void clearSelection() {
    setState(() => _selectedGameIds.clear());
    widget.onBulkStateChanged?.call();
  }

  Future<void> deleteSelected() async {
    if (_selectedGameIds.isEmpty) return;
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete selected games'),
            content: Text(
              'Delete ${_selectedGameIds.length} selected game${_selectedGameIds.length == 1 ? '' : 's'} from RTDB?',
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
          ),
        ) ??
        false;
    if (!ok) return;

    try {
      for (final id in _selectedGameIds) {
        await _gamesRef.child(id).remove();
      }
      if (!mounted) return;
      setState(() {
        _selectedGameIds.clear();
        _bulkModeEnabled = false;
      });
      widget.onBulkStateChanged?.call();
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Selected games deleted.')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(toHumanError(e, fallback: 'Bulk delete failed.')),
        ),
      );
    }
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
    final uploadUri = await BackendApi.withAuthQuery(_uploadUrl);
    final req = http.MultipartRequest('POST', uploadUri);
    await BackendApi.applyAuthToMultipart(req);

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
        http.MultipartFile.fromBytes('file', bytes, filename: picked.name),
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

      final game = Map<String, dynamic>.from(value);
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

      final game = Map<String, dynamic>.from(value);
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
      AppToast.fromSnackBar(
        context,
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
    final ok =
        await showDialog<bool>(
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
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Game deleted successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not delete game. Try again.'),
          ),
        ),
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
        String uploadedThumbnail = (existingGame?['thumbnail'] ?? '')
            .toString()
            .trim();
        String selectedStatus = (existingGame?['status'] ?? 'ready')
            .toString()
            .trim();

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
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Could not load admin details.'),
                  ),
                );
                return;
              }

              final gameName = nameController.text.trim();
              if (gameName.isEmpty) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
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

                  if (!context.mounted) return;
                  AppToast.fromSnackBar(
                    context,
                    const SnackBar(
                      content: Text('Game file uploaded successfully.'),
                    ),
                  );
                }
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not upload game file.'),
                    ),
                  ),
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
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Could not load admin details.'),
                  ),
                );
                return;
              }

              final gameName = nameController.text.trim();
              if (gameName.isEmpty) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text(
                      'Enter the game name before uploading thumbnail.',
                    ),
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

                  if (!context.mounted) return;
                  AppToast.fromSnackBar(
                    context,
                    const SnackBar(
                      content: Text('Thumbnail uploaded successfully.'),
                    ),
                  );
                }
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not upload thumbnail.'),
                    ),
                  ),
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
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Please enter the game name.')),
                );
                return;
              }

              if (description.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Please enter the game description.'),
                  ),
                );
                return;
              }

              if (link.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Please upload the game file first.'),
                  ),
                );
                return;
              }

              final currentUser = await _loadCurrentUserData();
              final uid = _myUid;

              if (currentUser == null || uid == null || uid.isEmpty) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Could not load admin details.'),
                  ),
                );
                return;
              }

              final firstName = (currentUser['first_name'] ?? '')
                  .toString()
                  .trim();
              final lastName = (currentUser['last_name'] ?? '')
                  .toString()
                  .trim();
              final email = (currentUser['email'] ?? '').toString().trim();
              final serial = (currentUser['serial'] ?? '').toString().trim();
              final now = ServerValue.timestamp;

              final tagsToSave =
                  chosenTags
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList()
                    ..sort(
                      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
                    );

              setLocalState(() => localSaving = true);
              if (mounted) {
                setState(() => _saving = true);
              }

              try {
                final ref = isEdit
                    ? _gamesRef.child(gameId)
                    : _gamesRef.child(draftGameUid);

                final oldTeacherUid = (existingGame?['teacherUid'] ?? '')
                    .toString()
                    .trim();
                final oldTeacherFirst =
                    (existingGame?['teacherFirstName'] ?? '').toString().trim();
                final oldTeacherLast = (existingGame?['teacherLastName'] ?? '')
                    .toString()
                    .trim();
                final oldTeacherEmail = (existingGame?['teacherEmail'] ?? '')
                    .toString()
                    .trim();
                final oldTeacherSerial = (existingGame?['teacherSerial'] ?? '')
                    .toString()
                    .trim();

                final data = <String, dynamic>{
                  'gameUid': ref.key ?? draftGameUid,
                  'teacherUid': oldTeacherUid.isNotEmpty ? oldTeacherUid : uid,
                  'teacherFirstName': oldTeacherFirst.isNotEmpty
                      ? oldTeacherFirst
                      : firstName,
                  'teacherLastName': oldTeacherLast.isNotEmpty
                      ? oldTeacherLast
                      : lastName,
                  'teacherEmail': oldTeacherEmail.isNotEmpty
                      ? oldTeacherEmail
                      : email,
                  'teacherSerial': oldTeacherSerial.isNotEmpty
                      ? oldTeacherSerial
                      : serial,
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
                      existingGame['createdAt'] ?? ServerValue.timestamp;
                }

                await ref.update(data);

                if (!ctx.mounted) return;
                Navigator.of(ctx).pop();

                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      isEdit
                          ? 'Game updated successfully.'
                          : 'Game added successfully.',
                    ),
                  ),
                );
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(
                        e,
                        fallback: 'Could not save game. Try again.',
                      ),
                    ),
                  ),
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
                        initialValue:
                            const [
                              'draft',
                              'ready',
                              'hidden',
                              'archived',
                            ].contains(selectedStatus)
                            ? selectedStatus
                            : 'ready',
                        decoration: const InputDecoration(
                          labelText: 'Status',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'draft',
                            child: Text('Draft'),
                          ),
                          DropdownMenuItem(
                            value: 'ready',
                            child: Text('Ready'),
                          ),
                          DropdownMenuItem(
                            value: 'hidden',
                            child: Text('Hidden'),
                          ),
                          DropdownMenuItem(
                            value: 'archived',
                            child: Text('Archived'),
                          ),
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
                                      if (!context.mounted) return;
                                      AppToast.fromSnackBar(
                                        context,
                                        const SnackBar(
                                          content: Text('Link copied'),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.link_rounded),
                                    label: const Text('Copy Link'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: localUploadingGame
                                        ? null
                                        : uploadGameFile,
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
                                onPressed: localUploadingGame
                                    ? null
                                    : uploadGameFile,
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
                                  errorBuilder: (_, _, _) => Container(
                                    height: 140,
                                    alignment: Alignment.center,
                                    color: Colors.grey.shade100,
                                    child: const Text(
                                      'Could not load thumbnail',
                                    ),
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
                                      if (!context.mounted) return;
                                      AppToast.fromSnackBar(
                                        context,
                                        const SnackBar(
                                          content: Text(
                                            'Thumbnail link copied',
                                          ),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.link_rounded),
                                    label: const Text('Copy Link'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: localUploadingThumb
                                        ? null
                                        : uploadThumbnail,
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
                                onPressed: localUploadingThumb
                                    ? null
                                    : uploadThumbnail,
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
    required bool selectionMode,
    required bool selected,
  }) {
    final name = (game['name'] ?? '').toString().trim();
    final description = (game['description'] ?? '').toString().trim();
    final thumbnail = (game['thumbnail'] ?? '').toString().trim();
    final category = (game['category'] ?? '').toString().trim();
    final level = (game['level'] ?? '').toString().trim();
    final status = (game['status'] ?? 'ready').toString().trim();
    final durationMinutes = _toInt(game['durationMinutes']);

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selectionMode && selected ? Colors.orange : Colors.transparent,
          width: selectionMode && selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: () {
          if (selectionMode) {
            setState(() {
              if (selected) {
                _selectedGameIds.remove(gameId);
              } else {
                _selectedGameIds.add(gameId);
              }
            });
            widget.onBulkStateChanged?.call();
            return;
          }
          _openGame(game);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                if (thumbnail.isNotEmpty)
                  Image.network(
                    thumbnail,
                    height: 110,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      height: 110,
                      color: Colors.grey.shade100,
                      alignment: Alignment.center,
                      child: const Icon(Icons.image_not_supported_rounded),
                    ),
                  )
                else
                  Container(
                    height: 110,
                    width: double.infinity,
                    color: Colors.grey.shade100,
                    alignment: Alignment.center,
                    child: const Icon(Icons.sports_esports_rounded, size: 36),
                  ),
                if (selectionMode)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.9),
                        shape: BoxShape.circle,
                      ),
                      child: Checkbox(
                        value: selected,
                        onChanged: (_) {
                          setState(() {
                            if (selected) {
                              _selectedGameIds.remove(gameId);
                            } else {
                              _selectedGameIds.add(gameId);
                            }
                          });
                          widget.onBulkStateChanged?.call();
                        },
                      ),
                    ),
                  ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? 'Untitled Game' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      description.isEmpty ? 'No description' : description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _statusColor(status).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            status,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: _statusColor(status),
                            ),
                          ),
                        ),
                        if (category.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              category,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        if (level.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              level,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                    const Spacer(),
                    if (durationMinutes > 0)
                      Text(
                        '$durationMinutes min',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    const SizedBox(height: 8),
                    if (selectionMode)
                      const SizedBox.shrink()
                    else
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _showGameForm(
                                gameId: gameId,
                                existingGame: game,
                                knownTags: knownTags,
                              ),
                              child: const Text('Edit'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: () => _deleteGame(gameId),
                            icon: const Icon(Icons.delete_rounded),
                            tooltip: 'Delete',
                          ),
                        ],
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

  List<MapEntry<String, Map<String, dynamic>>> _applyFiltersAndSort({
    required List<MapEntry<String, Map<String, dynamic>>> items,
  }) {
    var filtered = items.where((entry) {
      final game = entry.value;

      final name = (game['name'] ?? '').toString().toLowerCase().trim();
      final description = (game['description'] ?? '')
          .toString()
          .toLowerCase()
          .trim();
      final category = (game['category'] ?? '').toString().toLowerCase().trim();
      final level = (game['level'] ?? '').toString().toLowerCase().trim();
      final status = (game['status'] ?? 'ready')
          .toString()
          .toLowerCase()
          .trim();
      final tags = _tagsFromGame(game).map((e) => e.toLowerCase()).join(' ');

      final matchesSearch =
          _searchQuery.isEmpty ||
          name.contains(_searchQuery) ||
          description.contains(_searchQuery) ||
          category.contains(_searchQuery) ||
          level.contains(_searchQuery) ||
          tags.contains(_searchQuery);

      final matchesStatus =
          _statusFilter == 'all' || status == _statusFilter.toLowerCase();

      final matchesCategory =
          _categoryFilter == 'all' || category == _categoryFilter.toLowerCase();

      return matchesSearch && matchesStatus && matchesCategory;
    }).toList();

    filtered.sort((a, b) {
      switch (_sortBy) {
        case 'name_asc':
          return (a.value['name'] ?? '').toString().toLowerCase().compareTo(
            (b.value['name'] ?? '').toString().toLowerCase(),
          );
        case 'name_desc':
          return (b.value['name'] ?? '').toString().toLowerCase().compareTo(
            (a.value['name'] ?? '').toString().toLowerCase(),
          );
        case 'created_desc':
          return _toInt(
            b.value['createdAt'],
          ).compareTo(_toInt(a.value['createdAt']));
        case 'created_asc':
          return _toInt(
            a.value['createdAt'],
          ).compareTo(_toInt(b.value['createdAt']));
        case 'updated_asc':
          return _toInt(
            a.value['updatedAt'],
          ).compareTo(_toInt(b.value['updatedAt']));
        case 'updated_desc':
        default:
          return _toInt(
            b.value['updatedAt'],
          ).compareTo(_toInt(a.value['updatedAt']));
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
                  initialValue: _statusFilter,
                  decoration: const InputDecoration(
                    labelText: 'Status',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All')),
                    DropdownMenuItem(value: 'draft', child: Text('Draft')),
                    DropdownMenuItem(value: 'ready', child: Text('Ready')),
                    DropdownMenuItem(value: 'hidden', child: Text('Hidden')),
                    DropdownMenuItem(
                      value: 'archived',
                      child: Text('Archived'),
                    ),
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
                  initialValue: _categoryFilter,
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
            initialValue: _sortBy,
            decoration: const InputDecoration(
              labelText: 'Sort by',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: 'updated_desc',
                child: Text('Recently updated'),
              ),
              DropdownMenuItem(
                value: 'updated_asc',
                child: Text('Oldest updated'),
              ),
              DropdownMenuItem(
                value: 'created_desc',
                child: Text('Newest created'),
              ),
              DropdownMenuItem(
                value: 'created_asc',
                child: Text('Oldest created'),
              ),
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

  int _adminOwnedGamesCount(
    List<MapEntry<String, Map<String, dynamic>>> items,
  ) {
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
            : () => _showGameForm(knownTags: const <String>[]),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Game'),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1600,
        child: StreamBuilder<DatabaseEvent>(
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
                      const Icon(Icons.sports_esports_rounded, size: 48),
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
                  ? Map<String, dynamic>.from(gameValue)
                  : <String, dynamic>{};

              return MapEntry(gameId, game);
            }).toList();

            final visibleItems = _applyFiltersAndSort(items: items);
            _visibleGameIds = visibleItems.map((e) => e.key).toList();
            _selectedGameIds.removeWhere((id) => !_visibleGameIds.contains(id));

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
                        : GridView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                  childAspectRatio: 0.56,
                                ),
                            itemCount: visibleItems.length,

                            itemBuilder: (context, index) {
                              final item = visibleItems[index];
                              return _buildGameCard(
                                gameId: item.key,
                                game: item.value,
                                knownTags: knownTags,
                                selectionMode: _bulkModeEnabled,
                                selected: _selectedGameIds.contains(item.key),
                              );
                            },
                          ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _AdminStoriesManager extends StatefulWidget {
  const _AdminStoriesManager({super.key, this.onBulkStateChanged});

  final VoidCallback? onBulkStateChanged;

  @override
  State<_AdminStoriesManager> createState() => _AdminStoriesManagerState();
}

class _AdminStoriesManagerState extends State<_AdminStoriesManager>
    with AutomaticKeepAliveClientMixin {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final TextEditingController _searchController = TextEditingController();
  final String? _myUid = FirebaseAuth.instance.currentUser?.uid;

  static final Uri _uploadUrl = BackendApi.uri('upload_file_secure.php');

  String _searchQuery = '';
  bool _bulkModeEnabled = false;
  final Set<String> _selectedStoryIds = <String>{};
  List<String> _visibleStoryIds = const <String>[];

  DatabaseReference get _storiesRef => _db.child('stories');

  bool get bulkModeEnabled => _bulkModeEnabled;
  int get selectedCount => _selectedStoryIds.length;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _safeFolderName(String value) {
    final cleaned = value
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (cleaned.isEmpty) return 'story';
    return cleaned;
  }

  String _buildServerFolderPath({
    required String ownerUid,
    required String storyUid,
    required String storyName,
  }) {
    return 'admin/$ownerUid/$storyUid-${_safeFolderName(storyName)}';
  }

  Future<String?> _uploadStoryAsset({
    required String folderPath,
    required bool imageOnly,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: true,
      type: imageOnly ? FileType.image : FileType.any,
    );
    if (result == null || result.files.isEmpty) return null;

    final picked = result.files.single;
    final uploadUri = await BackendApi.withAuthQuery(_uploadUrl);
    final req = http.MultipartRequest('POST', uploadUri);
    await BackendApi.applyAuthToMultipart(req);

    req.fields['root'] = 'stories';
    req.fields['path'] = folderPath;

    if (picked.path != null && picked.path!.isNotEmpty) {
      req.files.add(
        await http.MultipartFile.fromPath(
          'file',
          picked.path!,
          filename: picked.name,
        ),
      );
    } else {
      final bytes = picked.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected file');
      }
      req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: picked.name),
      );
    }

    final streamed = await req.send();
    final response = await http.Response.fromStream(streamed);
    final raw = response.body.trim();
    if (!raw.startsWith('{')) {
      throw Exception('Server did not return JSON.');
    }

    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> || data['success'] != true) {
      throw Exception(
        (data is Map ? data['message'] : 'Upload failed').toString(),
      );
    }

    final url = (data['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      throw Exception('Upload succeeded but no URL was returned');
    }
    return url;
  }

  Future<void> _showAddStorySheet() async {
    final uid = _myUid;
    if (uid == null || uid.isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Please sign in again.')),
      );
      return;
    }

    final ref = _storiesRef.push();
    final storyId = ref.key ?? '';
    if (storyId.isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Could not prepare story id.')),
      );
      return;
    }

    final nameController = TextEditingController();
    final descController = TextEditingController();
    final genreController = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        var uploadingStory = false;
        var uploadingThumb = false;
        var saving = false;
        String storyUrl = '';
        String thumbnailUrl = '';

        return StatefulBuilder(
          builder: (context, setLocalState) {
            final storyName = nameController.text.trim();
            final folderPath = _buildServerFolderPath(
              ownerUid: uid,
              storyUid: storyId,
              storyName: storyName.isEmpty ? 'story' : storyName,
            );

            Future<void> uploadStoryFile() async {
              setLocalState(() => uploadingStory = true);
              try {
                final uploaded = await _uploadStoryAsset(
                  folderPath: folderPath,
                  imageOnly: false,
                );
                if (uploaded != null) {
                  setLocalState(() => storyUrl = uploaded);
                }
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not upload story file.'),
                    ),
                  ),
                );
              } finally {
                setLocalState(() => uploadingStory = false);
              }
            }

            Future<void> uploadThumbnail() async {
              setLocalState(() => uploadingThumb = true);
              try {
                final uploaded = await _uploadStoryAsset(
                  folderPath: folderPath,
                  imageOnly: true,
                );
                if (uploaded != null) {
                  setLocalState(() => thumbnailUrl = uploaded);
                }
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not upload thumbnail.'),
                    ),
                  ),
                );
              } finally {
                setLocalState(() => uploadingThumb = false);
              }
            }

            Future<void> saveStory() async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Please enter story title.')),
                );
                return;
              }
              if (storyUrl.trim().isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Please upload story file.')),
                );
                return;
              }

              setLocalState(() => saving = true);
              try {
                await ref.update({
                  'storyId': storyId,
                  'storyUid': storyId,
                  'teacherUid': uid,
                  'adminUid': uid,
                  'name': name,
                  'description': descController.text.trim(),
                  'genre': genreController.text.trim(),
                  'link': storyUrl.trim(),
                  'thumbnail': thumbnailUrl.trim(),
                  'status': 'ready',
                  'serverFolderPath': folderPath,
                  'createdAt': ServerValue.timestamp,
                  'updatedAt': ServerValue.timestamp,
                });

                if (!ctx.mounted) return;
                Navigator.of(ctx).pop();
                if (!mounted) return;
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Story added successfully.')),
                );
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not save story.'),
                    ),
                  ),
                );
              } finally {
                setLocalState(() => saving = false);
              }
            }

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
                      const Text(
                        'Add Story',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Title',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setLocalState(() {}),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: descController,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: genreController,
                        decoration: const InputDecoration(
                          labelText: 'Genre',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: uploadingStory
                                  ? null
                                  : uploadStoryFile,
                              icon: uploadingStory
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.upload_file_rounded),
                              label: Text(
                                storyUrl.isEmpty
                                    ? 'Upload Story File'
                                    : 'Replace Story File',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (storyUrl.isNotEmpty)
                        Text(
                          storyUrl,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: uploadingThumb
                                  ? null
                                  : uploadThumbnail,
                              icon: uploadingThumb
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.image_rounded),
                              label: Text(
                                thumbnailUrl.isEmpty
                                    ? 'Upload Thumbnail'
                                    : 'Replace Thumbnail',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (thumbnailUrl.isNotEmpty)
                        Text(
                          thumbnailUrl,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: saving
                                  ? null
                                  : () => Navigator.of(ctx).pop(),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: saving ? null : saveStory,
                              child: Text(saving ? 'Saving...' : 'Save Story'),
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

    nameController.dispose();
    descController.dispose();
    genreController.dispose();
  }

  void toggleBulkMode() {
    setState(() {
      _bulkModeEnabled = !_bulkModeEnabled;
      if (!_bulkModeEnabled) _selectedStoryIds.clear();
    });
    widget.onBulkStateChanged?.call();
  }

  void selectAllVisible() {
    setState(() {
      _selectedStoryIds
        ..clear()
        ..addAll(_visibleStoryIds);
    });
    widget.onBulkStateChanged?.call();
  }

  void clearSelection() {
    setState(() => _selectedStoryIds.clear());
    widget.onBulkStateChanged?.call();
  }

  Future<void> deleteSelected() async {
    if (_selectedStoryIds.isEmpty) return;
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete selected stories'),
            content: Text(
              'Delete ${_selectedStoryIds.length} selected stor${_selectedStoryIds.length == 1 ? 'y' : 'ies'} from RTDB?',
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
          ),
        ) ??
        false;
    if (!ok) return;

    try {
      for (final id in _selectedStoryIds) {
        await _storiesRef.child(id).remove();
      }
      if (!mounted) return;
      setState(() {
        _selectedStoryIds.clear();
        _bulkModeEnabled = false;
      });
      widget.onBulkStateChanged?.call();
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Selected stories deleted.')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(toHumanError(e, fallback: 'Bulk delete failed.')),
        ),
      );
    }
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  List<MapEntry<String, Map<String, dynamic>>> _applyFilters(
    List<MapEntry<String, Map<String, dynamic>>> items,
  ) {
    var filtered = items.where((entry) {
      final story = entry.value;
      final name = (story['name'] ?? '').toString().toLowerCase().trim();
      final desc = (story['description'] ?? '').toString().toLowerCase().trim();
      final genre = (story['genre'] ?? '').toString().toLowerCase().trim();
      final status = (story['status'] ?? '').toString().toLowerCase().trim();
      final q = _searchQuery;
      return q.isEmpty ||
          name.contains(q) ||
          desc.contains(q) ||
          genre.contains(q) ||
          status.contains(q);
    }).toList();

    filtered.sort((a, b) {
      final aTs = _toInt(a.value['updatedAt']);
      final bTs = _toInt(b.value['updatedAt']);
      return bTs.compareTo(aTs);
    });
    return filtered;
  }

  Widget _buildStoryCard(String storyId, Map<String, dynamic> story) {
    final name = (story['name'] ?? '').toString().trim();
    final status = (story['status'] ?? 'ready').toString().trim();
    final genre = (story['genre'] ?? '').toString().trim();
    final thumbnail = (story['thumbnail'] ?? '').toString().trim();
    final selected = _selectedStoryIds.contains(storyId);

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: _bulkModeEnabled && selected
              ? Colors.orange
              : Colors.transparent,
          width: _bulkModeEnabled && selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: () {
          if (!_bulkModeEnabled) return;
          setState(() {
            if (selected) {
              _selectedStoryIds.remove(storyId);
            } else {
              _selectedStoryIds.add(storyId);
            }
          });
          widget.onBulkStateChanged?.call();
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                if (thumbnail.isNotEmpty)
                  Image.network(
                    thumbnail,
                    height: 110,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      height: 110,
                      color: Colors.grey.shade100,
                      alignment: Alignment.center,
                      child: const Icon(Icons.image_not_supported_rounded),
                    ),
                  )
                else
                  Container(
                    height: 110,
                    width: double.infinity,
                    color: Colors.grey.shade100,
                    alignment: Alignment.center,
                    child: const Icon(Icons.menu_book_rounded, size: 36),
                  ),
                if (_bulkModeEnabled)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.9),
                        shape: BoxShape.circle,
                      ),
                      child: Checkbox(
                        value: selected,
                        onChanged: (_) {
                          setState(() {
                            if (selected) {
                              _selectedStoryIds.remove(storyId);
                            } else {
                              _selectedStoryIds.add(storyId);
                            }
                          });
                          widget.onBulkStateChanged?.call();
                        },
                      ),
                    ),
                  ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? 'Untitled Story' : name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        Chip(
                          label: Text(status),
                          visualDensity: VisualDensity.compact,
                        ),
                        if (genre.isNotEmpty)
                          Chip(
                            label: Text(genre),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      'ID: $storyId',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
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

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddStorySheet,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Story'),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1600,
        child: StreamBuilder<DatabaseEvent>(
          stream: _storiesRef.onValue,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                snap.data == null) {
              return const Center(child: CircularProgressIndicator());
            }

            final value = snap.data?.snapshot.value;
            if (value == null || value is! Map) {
              return const Center(
                child: Text(
                  'No stories found.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              );
            }

            final raw = Map<dynamic, dynamic>.from(value);
            final items = raw.entries.map((entry) {
              final id = entry.key.toString();
              final map = entry.value is Map
                  ? Map<String, dynamic>.from(entry.value)
                  : <String, dynamic>{};
              return MapEntry(id, map);
            }).toList();

            final visible = _applyFilters(items);
            _visibleStoryIds = visible.map((e) => e.key).toList();
            _selectedStoryIds.removeWhere(
              (id) => !_visibleStoryIds.contains(id),
            );

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) =>
                        setState(() => _searchQuery = v.trim().toLowerCase()),
                    decoration: InputDecoration(
                      hintText: 'Search stories...',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                              icon: const Icon(Icons.clear_rounded),
                            ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Total stories: ${visible.length}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: visible.isEmpty
                      ? const Center(
                          child: Text(
                            'No stories match your search.',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        )
                      : GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                                childAspectRatio: 0.72,
                              ),
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final item = visible[index];
                            return _buildStoryCard(item.key, item.value);
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
