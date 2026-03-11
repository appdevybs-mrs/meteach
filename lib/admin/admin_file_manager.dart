import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

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
          _FileBrowser(
            key: PageStorageKey('games_tab'),
            root: 'games',
          ),
        ],
      ),
    );
  }
}

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