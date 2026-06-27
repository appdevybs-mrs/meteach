import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../services/backend_api.dart';
import '../shared/human_error.dart';
import '../shared/material_webview_screen.dart';
import '../shared/app_feedback.dart';

class AdminInstructionsScreen extends StatefulWidget {
  const AdminInstructionsScreen({super.key});

  @override
  State<AdminInstructionsScreen> createState() =>
      _AdminInstructionsScreenState();
}

class _AdminInstructionsScreenState extends State<AdminInstructionsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  int _activeTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Instructions',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'For Teachers'),
            Tab(text: 'For Learners'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _InstructionsTab(targetRole: 'teacher'),
          _InstructionsTab(targetRole: 'learner'),
        ],
      ),
    );
  }
}

class _InstructionsTab extends StatefulWidget {
  final String targetRole;
  const _InstructionsTab({required this.targetRole});

  @override
  State<_InstructionsTab> createState() => _InstructionsTabState();
}

class _InstructionsTabState extends State<_InstructionsTab>
    with AutomaticKeepAliveClientMixin {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final String? _myUid = FirebaseAuth.instance.currentUser?.uid;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _statusFilter = 'all';
  String _sortBy = 'updated_desc';

  static final Uri _uploadUrl = BackendApi.uri('upload_file_secure.php');

  DatabaseReference get _instructionsRef => _db.child('instructions');

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
    if (cleaned.isEmpty) return 'instruction';
    return cleaned;
  }

  Future<String?> _uploadToServer({
    required String ownerUid,
    required String instructionUid,
    required String instructionName,
    required bool isThumbnail,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: true,
      type: isThumbnail ? FileType.image : FileType.custom,
      allowedExtensions: isThumbnail ? null : const ['html', 'htm'],
    );

    if (result == null || result.files.isEmpty) return null;

    final picked = result.files.single;
    final uploadUri = await BackendApi.withAuthQuery(_uploadUrl);
    final req = http.MultipartRequest('POST', uploadUri);
    await BackendApi.applyAuthToMultipart(req);

    req.fields['root'] = 'instructions';
    req.fields['path'] =
        'library/$ownerUid/$instructionUid-${_safeFolderName(instructionName)}';

    if (!kIsWeb && picked.path != null && picked.path!.isNotEmpty) {
      req.files.add(
        await http.MultipartFile.fromPath(
          'file',
          picked.path!,
          filename: picked.name,
        ),
      );
    } else {
      final Uint8List? bytes = picked.bytes;
      if (bytes == null) throw Exception('Could not read selected file');
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
      if (url.isEmpty) throw Exception('Upload succeeded but no URL returned');
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

  bool _matchesSearch(Map<String, dynamic> item) {
    if (_searchQuery.isEmpty) return true;
    final q = _searchQuery.toLowerCase();
    final name = (item['name'] ?? '').toString().toLowerCase();
    final desc = (item['description'] ?? '').toString().toLowerCase();
    return name.contains(q) || desc.contains(q);
  }

  bool _matchesStatus(Map<String, dynamic> item) {
    if (_statusFilter == 'all') return true;
    final status = (item['status'] ?? '').toString().trim().toLowerCase();
    return status == _statusFilter;
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  String _itemName(Map<String, dynamic> item) {
    return (item['name'] ?? '').toString().trim();
  }

  Future<void> _openInstruction(Map<String, dynamic> item) async {
    final link = (item['link'] ?? '').toString().trim();
    final name = (item['name'] ?? 'Instruction').toString().trim();
    if (link.isEmpty) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MaterialWebViewScreen.fromUrl(
          title: name.isEmpty ? 'Instruction' : name,
          url: link,
          viewerMode: MaterialViewerMode.document,
        ),
      ),
    );
  }

  Future<void> _deleteInstruction(String id, Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete instruction'),
        content: const Text(
          'Are you sure you want to delete this instruction?',
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
    );

    if (ok != true) return;

    try {
      await _instructionsRef.child(id).remove();
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Instruction deleted.')),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(content: Text(toHumanError(e, fallback: 'Could not delete.'))),
      );
    }
  }

  Future<void> _toggleArchive(String id, Map<String, dynamic> item) async {
    final currentStatus = (item['status'] ?? 'ready').toString().trim();
    final nextStatus = currentStatus == 'archived' ? 'ready' : 'archived';
    try {
      await _instructionsRef.child(id).update({
        'status': nextStatus,
        'updatedAt': ServerValue.timestamp,
      });
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            nextStatus == 'archived'
                ? 'Instruction archived.'
                : 'Instruction restored.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(toHumanError(e, fallback: 'Could not update status.')),
        ),
      );
    }
  }

  Future<void> _showInstructionForm({
    String? itemId,
    Map<String, dynamic>? existing,
  }) async {
    final isEdit = itemId != null && existing != null;
    final draftUid = itemId ?? _instructionsRef.push().key ?? '';

    final nameController = TextEditingController(
      text: (existing?['name'] ?? '').toString(),
    );
    final descriptionController = TextEditingController(
      text: (existing?['description'] ?? '').toString(),
    );

    bool localSaving = false;
    bool localUploadingFile = false;
    bool localUploadingThumb = false;
    double localFileProgress = 0;
    double localThumbProgress = 0;

    String uploadedUrl = (existing?['link'] ?? '').toString().trim();
    String uploadedThumbnail = (existing?['thumbnail'] ?? '').toString().trim();
    String uploadedFileName = _fileNameFromUrl(uploadedUrl);
    String uploadedThumbFileName = _fileNameFromUrl(uploadedThumbnail);
    String selectedStatus = (existing?['status'] ?? 'ready').toString().trim();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            Future<void> uploadHtmlFile() async {
              final uid = _myUid;
              if (uid == null || uid.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('No logged-in user found.')),
                );
                return;
              }
              final instrName = nameController.text.trim();
              if (instrName.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Enter the title before uploading.'),
                  ),
                );
                return;
              }
              try {
                final url = await _uploadToServer(
                  ownerUid: uid,
                  instructionUid: draftUid,
                  instructionName: instrName,
                  isThumbnail: false,
                );
                if (url != null && url.trim().isNotEmpty) {
                  setLocalState(() {
                    uploadedUrl = url.trim();
                    uploadedFileName = _fileNameFromUrl(uploadedUrl);
                  });
                  if (!context.mounted) return;
                  AppToast.fromSnackBar(
                    context,
                    const SnackBar(content: Text('HTML file uploaded.')),
                  );
                }
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(content: Text(_uploadErrorText(e))),
                );
              } finally {
                setLocalState(() {
                  localUploadingFile = false;
                  localFileProgress = 0;
                });
              }
            }

            Future<void> uploadThumbnail() async {
              final uid = _myUid;
              if (uid == null || uid.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('No logged-in user found.')),
                );
                return;
              }
              final instrName = nameController.text.trim();
              if (instrName.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(
                    content: Text('Enter the title before uploading.'),
                  ),
                );
                return;
              }
              try {
                final url = await _uploadToServer(
                  ownerUid: uid,
                  instructionUid: draftUid,
                  instructionName: instrName,
                  isThumbnail: true,
                );
                if (url != null && url.trim().isNotEmpty) {
                  setLocalState(() {
                    uploadedThumbnail = url.trim();
                    uploadedThumbFileName = _fileNameFromUrl(uploadedThumbnail);
                  });
                  if (!context.mounted) return;
                  AppToast.fromSnackBar(
                    context,
                    const SnackBar(content: Text('Thumbnail uploaded.')),
                  );
                }
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(content: Text(_uploadErrorText(e))),
                );
              } finally {
                setLocalState(() {
                  localUploadingThumb = false;
                  localThumbProgress = 0;
                });
              }
            }

            Future<void> saveInstruction() async {
              final name = nameController.text.trim();
              final description = descriptionController.text.trim();
              final link = uploadedUrl.trim();
              final thumbnail = uploadedThumbnail.trim();

              if (name.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Please enter a title.')),
                );
                return;
              }
              if (description.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Please enter a description.')),
                );
                return;
              }
              if (link.isEmpty) {
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Please upload the HTML file.')),
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

              setLocalState(() => localSaving = true);

              try {
                final ref = isEdit
                    ? _instructionsRef.child(itemId)
                    : _instructionsRef.child(draftUid);

                final data = <String, dynamic>{
                  'instructionUid': ref.key ?? draftUid,
                  'teacherUid': uid,
                  'teacherFirstName': firstName,
                  'teacherLastName': lastName,
                  'teacherEmail': email,
                  'teacherSerial': serial,
                  'name': name,
                  'description': description,
                  'link': link,
                  'thumbnail': thumbnail,
                  'targetRole': widget.targetRole,
                  'status': selectedStatus,
                  'updatedAt': now,
                };

                if (!isEdit) {
                  data['createdAt'] = now;
                } else {
                  final existingData = existing!;
                  data['createdAt'] =
                      existingData['createdAt'] ?? ServerValue.timestamp;
                }

                await ref.update(data);

                if (!ctx.mounted) return;
                Navigator.of(ctx).pop();

                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      isEdit ? 'Instruction updated.' : 'Instruction added.',
                    ),
                  ),
                );
              } catch (e) {
                if (!context.mounted) return;
                AppToast.fromSnackBar(
                  context,
                  SnackBar(
                    content: Text(
                      toHumanError(e, fallback: 'Could not save instruction.'),
                    ),
                  ),
                );
              } finally {
                setLocalState(() => localSaving = false);
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
                      Text(
                        isEdit ? 'Edit Instruction' : 'Add Instruction',
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
                          labelText: 'Title',
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
                          setLocalState(() => selectedStatus = value);
                        },
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'HTML File',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildFileBox(
                        context: context,
                        uploaded: uploadedUrl.isNotEmpty,
                        fileName: uploadedFileName,
                        uploading: localUploadingFile,
                        progress: localFileProgress,
                        onUpload: localUploadingFile ? null : uploadHtmlFile,
                        onReplace: localUploadingFile ? null : uploadHtmlFile,
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
                      _buildFileBox(
                        context: context,
                        uploaded: uploadedThumbnail.isNotEmpty,
                        fileName: uploadedThumbFileName,
                        uploading: localUploadingThumb,
                        progress: localThumbProgress,
                        onUpload: localUploadingThumb ? null : uploadThumbnail,
                        onReplace: localUploadingThumb ? null : uploadThumbnail,
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: localSaving ? null : saveInstruction,
                          child: localSaving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(isEdit ? 'Update' : 'Save'),
                        ),
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

  Widget _buildFileBox({
    required BuildContext context,
    required bool uploaded,
    required String fileName,
    required bool uploading,
    required double progress,
    required VoidCallback? onUpload,
    required VoidCallback? onReplace,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (uploaded) ...[
            Text(
              fileName,
              style: TextStyle(
                color: Colors.blue.shade700,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: onReplace,
              icon: const Icon(Icons.sync_rounded),
              label: const Text('Replace'),
            ),
          ] else ...[
            const Text(
              'No file uploaded yet.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: onUpload,
              icon: uploading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file_rounded),
              label: Text(
                uploading
                    ? 'Uploading ${(progress * 100).round()}%'
                    : 'Upload File',
              ),
            ),
          ],
          if (uploading) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress.clamp(0.0, 1.0)),
          ],
        ],
      ),
    );
  }

  String _fileNameFromUrl(String url) {
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return 'Uploaded file';
    try {
      final path = Uri.parse(cleanUrl).path;
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) return cleanUrl;
      final last = segments.last;
      return last.length <= 48
          ? last
          : '${last.substring(0, 32)}...${last.substring(last.length - 12)}';
    } catch (_) {
      return cleanUrl;
    }
  }

  String _uploadErrorText(Object error) {
    final human = toHumanError(error, fallback: '');
    if (human.isNotEmpty) return human;

    final raw = error
        .toString()
        .replaceFirst(RegExp(r'^Exception:\s*'), '')
        .trim();
    if (raw.isNotEmpty && raw.length <= 160) return raw;
    return 'Could not upload file.';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return StreamBuilder<DatabaseEvent>(
      stream: _instructionsRef.onValue,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting &&
            snap.data == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final value = snap.data?.snapshot.value;
        if (value == null || value is! Map) {
          return _buildListWithToolbar(
            const [],
            emptyState: _buildEmptyState(),
          );
        }

        final raw = Map<dynamic, dynamic>.from(value);
        final items = <MapEntry<String, Map<String, dynamic>>>[];

        for (final entry in raw.entries) {
          final rawValue = entry.value;
          if (rawValue is! Map) continue;
          final item = Map<String, dynamic>.from(rawValue);

          final targetRole = (item['targetRole'] ?? '').toString().trim();
          if (targetRole != widget.targetRole) continue;

          item['instructionId'] = entry.key.toString();
          items.add(MapEntry(entry.key.toString(), item));
        }

        items.sort((a, b) {
          switch (_sortBy) {
            case 'name_asc':
              return _itemName(
                a.value,
              ).toLowerCase().compareTo(_itemName(b.value).toLowerCase());
            case 'name_desc':
              return _itemName(
                b.value,
              ).toLowerCase().compareTo(_itemName(a.value).toLowerCase());
            case 'created_desc':
              return _toInt(
                b.value['createdAt'],
              ).compareTo(_toInt(a.value['createdAt']));
            case 'updated_desc':
            default:
              return _toInt(
                b.value['updatedAt'],
              ).compareTo(_toInt(a.value['updatedAt']));
          }
        });

        final filtered = items.where((entry) {
          return _matchesSearch(entry.value) && _matchesStatus(entry.value);
        }).toList();

        if (filtered.isEmpty) {
          return _buildListWithToolbar(
            const [],
            emptyState: _buildEmptyState(
              searching: _searchQuery.isNotEmpty || _statusFilter != 'all',
            ),
          );
        }

        return _buildListWithToolbar(filtered);
      },
    );
  }

  Widget _buildListWithToolbar(
    List<MapEntry<String, Map<String, dynamic>>> items, {
    Widget? emptyState,
  }) {
    return Column(
      children: [
        _buildToolbar(items.length),
        Expanded(
          child:
              emptyState ??
              ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index].value;
                  final id = items[index].key;
                  return _buildInstructionCard(id, item);
                },
              ),
        ),
      ],
    );
  }

  Widget _buildToolbar(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v.trim()),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search instructions...',
                prefixIcon: const Icon(Icons.search_rounded, size: 19),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            icon: Icon(
              Icons.filter_alt_outlined,
              color: _statusFilter != 'all' ? Colors.orange : null,
            ),
            onSelected: (v) => setState(() => _statusFilter = v),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'all', child: Text('All Status')),
              const PopupMenuItem(value: 'ready', child: Text('Ready')),
              const PopupMenuItem(value: 'draft', child: Text('Draft')),
              const PopupMenuItem(value: 'hidden', child: Text('Hidden')),
              const PopupMenuItem(value: 'archived', child: Text('Archived')),
            ],
          ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort_rounded),
            onSelected: (v) => setState(() => _sortBy = v),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'updated_desc',
                child: Text('Recently Updated'),
              ),
              const PopupMenuItem(
                value: 'created_desc',
                child: Text('Newest First'),
              ),
              const PopupMenuItem(value: 'name_asc', child: Text('Name A-Z')),
              const PopupMenuItem(value: 'name_desc', child: Text('Name Z-A')),
            ],
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: () => _showInstructionForm(),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionCard(String id, Map<String, dynamic> item) {
    final name = (item['name'] ?? 'Untitled').toString().trim();
    final description = (item['description'] ?? '').toString().trim();
    final status = (item['status'] ?? 'ready').toString().trim();
    final thumbnail = (item['thumbnail'] ?? '').toString().trim();
    final createdAt = _toInt(item['createdAt']);

    Color statusColor;
    switch (status) {
      case 'ready':
        statusColor = Colors.green;
        break;
      case 'draft':
        statusColor = Colors.orange;
        break;
      case 'hidden':
        statusColor = Colors.grey;
        break;
      case 'archived':
        statusColor = Colors.red;
        break;
      default:
        statusColor = Colors.blue;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openInstruction(item),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: thumbnail.isNotEmpty
                      ? Image.network(
                          thumbnail,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: Colors.blue.shade50,
                            child: Icon(
                              Icons.menu_book_rounded,
                              color: Colors.blue.shade200,
                            ),
                          ),
                        )
                      : Container(
                          color: Colors.blue.shade50,
                          child: Icon(
                            Icons.menu_book_rounded,
                            color: Colors.blue.shade200,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            status.toUpperCase(),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: statusColor,
                            ),
                          ),
                        ),
                        if (createdAt > 0) ...[
                          const SizedBox(width: 8),
                          Text(
                            DateTime.fromMillisecondsSinceEpoch(
                              createdAt,
                            ).toString().substring(0, 10),
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (action) {
                  switch (action) {
                    case 'edit':
                      _showInstructionForm(itemId: id, existing: item);
                      break;
                    case 'archive':
                      _toggleArchive(id, item);
                      break;
                    case 'delete':
                      _deleteInstruction(id, item);
                      break;
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(
                    value: 'archive',
                    child: Text(status == 'archived' ? 'Restore' : 'Archive'),
                  ),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState({bool searching = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_rounded,
              size: 48,
              color: Colors.grey.shade300,
            ),
            const SizedBox(height: 16),
            Text(
              searching
                  ? 'No instructions match your filters.'
                  : 'No instructions yet.',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              searching
                  ? 'Try different search or filters.'
                  : 'Tap "Add" to create the first instruction.',
              style: TextStyle(color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }
}
