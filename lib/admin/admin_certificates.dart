import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import '../models/certificate_model.dart';
import '../models/admin_certificate_model.dart';
import '../services/certificate_pdf_service.dart';
import '../services/certificate_service.dart';
import '../services/admin_certificate_service.dart';
import '../shared/admin_web_layout.dart';
import '../shared/app_feedback.dart' show AppToast, AppToastType;

const _primaryBlue = Color(0xFF1A2B48);
const _actionOrange = Color(0xFFF98D28);
const _appBg = Color(0xFFF4F7F9);
const _softText = Color(0xFF6E7B8C);
const _uiBorder = Color(0xFFE3EAF2);

// =============================================================================
// AdminCertificatesScreen — main screen with two tabs
// =============================================================================

class AdminCertificatesScreen extends StatefulWidget {
  const AdminCertificatesScreen({super.key});

  @override
  State<AdminCertificatesScreen> createState() =>
      _AdminCertificatesScreenState();
}

class _AdminCertificatesScreenState extends State<AdminCertificatesScreen> {
  final AdminCertificateService _adminService = AdminCertificateService();
  final CertificateService _certService = CertificateService();
  final CertificatePdfService _pdfService = CertificatePdfService();
  final _searchController = TextEditingController();

  // --- Tab 0: Admin Certificates (new) ---
  List<AdminCertificate> _adminCerts = [];
  List<AdminCertificate> _filteredAdminCerts = [];
  bool _loadingAdmin = true;

  // --- Tab 1: Recorded Achievements (existing) ---
  List<RecordedCertificateEntry> _recordedCertificates = [];
  List<RecordedCertificateEntry> _filteredRecordedCertificates = [];
  bool _loadingRecorded = true;

  int _activeTab = 0;
  String _searchQuery = '';



  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    await Future.wait([_loadAdminCerts(), _loadRecordedCertificates()]);
  }

  // ---------------------------------------------------------------------------
  // Tab 0: Admin Certificates
  // ---------------------------------------------------------------------------

  Future<void> _loadAdminCerts() async {
    setState(() => _loadingAdmin = true);
    try {
      final certs = await _adminService.getAll();
      setState(() {
        _adminCerts = certs;
        _applyAdminFilter();
        _loadingAdmin = false;
      });
    } catch (e) {
      setState(() => _loadingAdmin = false);
      if (mounted) {
        AppToast.show(
          context,
          'Error loading certificates: $e',
          type: AppToastType.error,
        );
      }
    }
  }

  void _applyAdminFilter() {
    final q = _searchQuery.trim().toLowerCase();
    setState(() {
      _filteredAdminCerts = _adminCerts.where((c) {
        if (q.isEmpty) return true;
        return c.fullName.toLowerCase().contains(q) ||
            c.certificateName.toLowerCase().contains(q) ||
            c.nationalIdNumber.contains(q);
      }).toList();
    });
  }

  Future<void> _showAddCertificateForm() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AdminCertFormSheet(service: _adminService),
    );
    if (result == true && mounted) {
      await _loadAdminCerts();
    }
  }

  Future<void> _showEditCertificateForm(AdminCertificate cert) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AdminCertFormSheet(
        service: _adminService,
        certificate: cert,
      ),
    );
    if (result == true && mounted) {
      await _loadAdminCerts();
    }
  }

  Future<void> _showViewCertificate(AdminCertificate cert) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AdminCertViewSheet(
        certificate: cert,
        service: _adminService,
        onDeleted: () {
          Navigator.pop(context);
          _loadAdminCerts();
        },
        onEdited: () {
          Navigator.pop(context);
          _loadAdminCerts();
        },
      ),
    );
  }

  Future<void> _deleteCertificate(AdminCertificate cert) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Certificate'),
        content: Text(
          'Delete certificate for "${cert.fullName}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      try {
        await _adminService.delete(cert.key!);
        await _loadAdminCerts();
        if (!mounted) return;
        AppToast.show(
          context,
          'Certificate deleted',
          type: AppToastType.success,
        );
      } catch (e) {
        if (mounted) {
          AppToast.show(
            context,
            'Error deleting certificate',
            type: AppToastType.error,
          );
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Tab 1: Recorded Achievements (existing, unchanged)
  // ---------------------------------------------------------------------------

  Future<void> _loadRecordedCertificates() async {
    setState(() => _loadingRecorded = true);
    try {
      final rows = await _certService.getAllRecordedCertificates();
      setState(() {
        _recordedCertificates = rows;
        _applyRecordedFilters();
        _loadingRecorded = false;
      });
    } catch (_) {
      setState(() => _loadingRecorded = false);
    }
  }

  void _applyRecordedFilters() {
    final q = _searchQuery.trim().toLowerCase();
    _filteredRecordedCertificates = _recordedCertificates.where((entry) {
      if (q.isEmpty) return true;
      final cert = entry.certificate;
      return cert.fullName.toLowerCase().contains(q) ||
          cert.cvn.toLowerCase().contains(q) ||
          cert.certificateTitle.toLowerCase().contains(q) ||
          cert.nationalIdNumber.toLowerCase().contains(q);
    }).toList();
  }

  void _onSearchChanged(String value) {
    setState(() {
      _searchQuery = value;
      if (_activeTab == 0) {
        _applyAdminFilter();
      } else {
        _applyRecordedFilters();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: _primaryBlue),
        title: const Text(
          'Certificates',
          style: TextStyle(color: _primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          if (_activeTab == 0)
            IconButton(
              icon: const Icon(Icons.add_circle_outline, color: _actionOrange),
              onPressed: _showAddCertificateForm,
              tooltip: 'Add Certificate',
            ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1660,
        child: Column(
          children: [
            _buildTabSwitch(),
            if (_activeTab == 1) _buildRecordedSearch(),
            Expanded(
              child: _activeTab == 0
                  ? _buildAdminCertificatesList()
                  : _buildRecordedCertificatesList(),
            ),
          ],
        ),
      ),
      floatingActionButton: _activeTab == 0
          ? FloatingActionButton.extended(
              onPressed: _showAddCertificateForm,
              backgroundColor: _actionOrange,
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text(
                'Add Certificate',
                style: TextStyle(color: Colors.white),
              ),
            )
          : null,
    );
  }

  Widget _buildTabSwitch() {
    Widget tab(int idx, String label) {
      final selected = _activeTab == idx;
      return Expanded(
        child: InkWell(
          onTap: () {
            if (_activeTab == idx) return;
            setState(() => _activeTab = idx);
          },
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? _primaryBlue : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : _primaryBlue,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            tab(0, 'Certificates'),
            const SizedBox(width: 6),
            tab(1, 'Recorded Achievements'),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 0: Admin Certificates list
  // ---------------------------------------------------------------------------

  Widget _buildAdminCertificatesList() {
    return Column(
      children: [
        _buildAdminSearch(),
        Expanded(
          child: _loadingAdmin
              ? const Center(child: CircularProgressIndicator())
              : _filteredAdminCerts.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.assignment_outlined,
                            size: 64,
                            color: _softText.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _adminCerts.isEmpty
                                ? 'No certificates yet'
                                : 'No certificates match your search',
                            style:
                                const TextStyle(color: _softText, fontSize: 16),
                          ),
                          if (_adminCerts.isEmpty) ...[
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _showAddCertificateForm,
                              icon: const Icon(Icons.add),
                              label: const Text('Add your first certificate'),
                            ),
                          ],
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                      itemCount: _filteredAdminCerts.length,
                      itemBuilder: (context, index) {
                        final cert = _filteredAdminCerts[index];
                        return _AdminCertCard(
                          certificate: cert,
                          onTap: () => _showViewCertificate(cert),
                          onEdit: () => _showEditCertificateForm(cert),
                          onDelete: () => _deleteCertificate(cert),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildAdminSearch() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        decoration: InputDecoration(
          hintText: 'Search by name, certificate name, or National ID...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _uiBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _uiBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: _primaryBlue, width: 2),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 1: Recorded Certificates list (unchanged)
  // ---------------------------------------------------------------------------

  Widget _buildRecordedSearch() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText:
                  'Search recorded by name, CVN, title, or National ID...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        _onSearchChanged('');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _uiBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _uiBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: _primaryBlue, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'disable_before_date') {
                  _runRecordedQuickAction(deleteBeforeDate: false);
                } else if (value == 'delete_before_date') {
                  _runRecordedQuickAction(deleteBeforeDate: true);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'disable_before_date',
                  child: Text('Disable downloads before date'),
                ),
                PopupMenuItem(
                  value: 'delete_before_date',
                  child: Text('Delete certificates before date'),
                ),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: _uiBorder),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bolt_rounded, size: 18, color: _primaryBlue),
                    SizedBox(width: 6),
                    Text('Quick actions (filtered)'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordedCertificatesList() {
    if (_loadingRecorded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_filteredRecordedCertificates.isEmpty) {
      return Center(
        child: Text(
          _recordedCertificates.isEmpty
              ? 'No recorded achievement certificates yet'
              : 'No recorded certificates match your search',
          style: const TextStyle(color: _softText, fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _filteredRecordedCertificates.length,
      itemBuilder: (context, index) {
        final entry = _filteredRecordedCertificates[index];
        final cert = entry.certificate;
        return _CertificateListItem(
          certificate: cert,
          onView: () => _showViewRecordedCertificate(cert),
          onEdit: () => _showEditRecordedCertificateForm(entry),
          onDelete: () => _deleteRecordedCertificateEntry(entry),
          onPrint: () => _printCertificate(cert),
          onHardcopy: () => _printHardcopyCertificate(cert),
          onToggleDownloads: () => _toggleRecordedDownloads(entry),
          toggleDownloadsLabel: cert.downloadsEnabled
              ? 'Disable download'
              : 'Enable download',
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 1: CRUD operations (unchanged)
  // ---------------------------------------------------------------------------

  Future<void> _toggleRecordedDownloads(RecordedCertificateEntry entry) async {
    final cert = entry.certificate;
    final next = !cert.downloadsEnabled;
    await _certService.updateRecordedCertificate(
      learnerUid: entry.learnerUid,
      certId: entry.certId,
      cert: cert.copyWith(
        downloadsEnabled: next,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await _loadRecordedCertificates();
    if (!mounted) return;
    AppToast.show(
      context,
      next
          ? 'Recorded certificate download enabled'
          : 'Recorded certificate download disabled',
      type: AppToastType.success,
    );
  }

  Future<void> _runRecordedQuickAction({required bool deleteBeforeDate}) async {
    if (_filteredRecordedCertificates.isEmpty) {
      AppToast.show(
        context,
        'No filtered recorded certificates to process.',
        type: AppToastType.info,
      );
      return;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked == null) return;

    final cutoff = DateTime(
      picked.year,
      picked.month,
      picked.day,
      23,
      59,
      59,
      999,
    ).millisecondsSinceEpoch;
    final targets = _filteredRecordedCertificates
        .where(
          (e) =>
              e.certificate.createdAt > 0 && e.certificate.createdAt <= cutoff,
        )
        .toList();

    if (targets.isEmpty) {
      if (!mounted) return;
      AppToast.show(
        context,
        'No recorded certificates issued on or before ${DateFormat('yyyy-MM-dd').format(picked)} in current filters.',
        type: AppToastType.info,
      );
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          deleteBeforeDate ? 'Delete Certificates' : 'Disable Downloads',
        ),
        content: Text(
          deleteBeforeDate
              ? 'Delete ${targets.length} recorded certificate(s) issued on or before ${DateFormat('yyyy-MM-dd').format(picked)} from current filters?'
              : 'Disable learner downloads for ${targets.length} recorded certificate(s) issued on or before ${DateFormat('yyyy-MM-dd').format(picked)} from current filters?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: deleteBeforeDate ? Colors.red : _actionOrange,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(deleteBeforeDate ? 'Delete' : 'Disable'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    var changed = 0;
    for (final entry in targets) {
      try {
        if (deleteBeforeDate) {
          await _certService.deleteRecordedCertificate(
            learnerUid: entry.learnerUid,
            certId: entry.certId,
            cvn: entry.certificate.cvn,
          );
          changed++;
        } else {
          if (!entry.certificate.downloadsEnabled) continue;
          await _certService.updateRecordedCertificate(
            learnerUid: entry.learnerUid,
            certId: entry.certId,
            cert: entry.certificate.copyWith(
              downloadsEnabled: false,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          changed++;
        }
      } catch (_) {}
    }

    await _loadRecordedCertificates();
    if (!mounted) return;
    AppToast.show(
      context,
      deleteBeforeDate
          ? 'Deleted $changed recorded certificate(s).'
          : 'Disabled downloads on $changed recorded certificate(s).',
      type: AppToastType.success,
    );
  }

  Future<void> _deleteRecordedCertificateEntry(
    RecordedCertificateEntry entry,
  ) async {
    final cert = entry.certificate;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Recorded Certificate'),
        content: Text('Delete recorded certificate for "${cert.fullName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _certService.deleteRecordedCertificate(
      learnerUid: entry.learnerUid,
      certId: entry.certId,
      cvn: cert.cvn,
    );
    await _loadRecordedCertificates();
    if (!mounted) return;
    AppToast.show(
      context,
      'Recorded certificate deleted',
      type: AppToastType.success,
    );
  }

  Future<void> _showViewRecordedCertificate(Certificate cert) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CertificateViewSheet(certificate: cert),
    );
  }

  Future<void> _showEditRecordedCertificateForm(
    RecordedCertificateEntry entry,
  ) async {
    final cert = entry.certificate;
    final fullNameC = TextEditingController(text: cert.fullName);
    final nationalIdC = TextEditingController(text: cert.nationalIdNumber);
    final titleC = TextEditingController(text: cert.certificateTitle);
    final instructorC = TextEditingController(text: cert.instructorName ?? '');
    final notesC = TextEditingController(text: cert.notes ?? '');
    String examCourse = cert.examCourse;
    String trainingDate = cert.trainingDate;
    String expirationDate = cert.expirationDate;
    bool downloadsEnabled = cert.downloadsEnabled;

    int durationYears = 1;
    try {
      final t = DateTime.parse(trainingDate);
      final e = DateTime.parse(expirationDate);
      durationYears = (e.difference(t).inDays / 365).round().clamp(1, 10);
    } catch (_) {}

    Future<void> save(StateSetter setSheetState) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final updated = cert.copyWith(
        fullName: fullNameC.text.trim(),
        nationalIdNumber: nationalIdC.text.trim(),
        certificateTitle: titleC.text.trim(),
        instructorName: examCourse == 'exam'
            ? null
            : (instructorC.text.trim().isEmpty
                    ? 'Seddik. B'
                    : instructorC.text.trim()),
        examCourse: examCourse,
        trainingDate: trainingDate,
        expirationDate: expirationDate,
        updatedAt: now,
        notes: notesC.text.trim().isEmpty ? null : notesC.text.trim(),
        downloadsEnabled: downloadsEnabled,
      );
      await _certService.updateRecordedCertificate(
        learnerUid: entry.learnerUid,
        certId: entry.certId,
        cert: updated,
      );
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => AlertDialog(
          title: const Text('Edit Recorded Certificate'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: fullNameC,
                  decoration: const InputDecoration(labelText: 'Full Name'),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: nationalIdC,
                  decoration: const InputDecoration(labelText: 'National ID'),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: titleC,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  value: examCourse == 'exam',
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('exam_course'),
                  subtitle: Text(examCourse),
                  onChanged: (v) => setSheetState(() {
                    examCourse = v ? 'exam' : 'course';
                    if (v) instructorC.clear();
                  }),
                ),
                const SizedBox(height: 10),
                if (examCourse != 'exam') ...[
                  TextFormField(
                    controller: instructorC,
                    decoration: const InputDecoration(
                      labelText: 'Instructor Name',
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                TextFormField(
                  readOnly: true,
                  controller: TextEditingController(text: trainingDate),
                  decoration:
                      const InputDecoration(labelText: 'Training Date'),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: ctx,
                      initialDate:
                          DateTime.tryParse(trainingDate) ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2035),
                    );
                    if (d == null) return;
                    setSheetState(() {
                      trainingDate = DateFormat('yyyy-MM-dd').format(d);
                      expirationDate = DateFormat(
                        'yyyy-MM-dd',
                      ).format(d.add(Duration(days: durationYears * 365)));
                    });
                  },
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: durationYears,
                  decoration: const InputDecoration(labelText: 'Duration'),
                  items: List.generate(
                    10,
                    (i) => DropdownMenuItem(
                      value: i + 1,
                      child: Text('${i + 1} year${i == 0 ? '' : 's'}'),
                    ),
                  ),
                  onChanged: (v) {
                    if (v == null) return;
                    setSheetState(() {
                      durationYears = v;
                      final t =
                          DateTime.tryParse(trainingDate) ?? DateTime.now();
                      expirationDate = DateFormat('yyyy-MM-dd').format(
                        t.add(Duration(days: durationYears * 365)),
                      );
                    });
                  },
                ),
                const SizedBox(height: 10),
                TextFormField(
                  readOnly: true,
                  controller: TextEditingController(text: expirationDate),
                  decoration:
                      const InputDecoration(labelText: 'Expiration Date'),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: notesC,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: downloadsEnabled,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Downloads enabled'),
                  onChanged: (v) => setSheetState(() => downloadsEnabled = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                await save(setSheetState);
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                await _loadRecordedCertificates();
                if (!mounted) return;
                AppToast.show(
                  context,
                  'Recorded certificate updated',
                  type: AppToastType.success,
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    fullNameC.dispose();
    nationalIdC.dispose();
    titleC.dispose();
    instructorC.dispose();
    notesC.dispose();
  }

  Future<void> _printCertificate(Certificate cert) async {
    try {
      final bytes = await _pdfService.generateCertificatePdfBytes(cert);
      final fileName = CertificatePdfService.buildPdfFileName(cert);
      await Printing.layoutPdf(name: fileName, onLayout: (_) async => bytes);
      if (!mounted) return;
      AppToast.show(
        context,
        'Certificate opened in print preview.',
        type: AppToastType.success,
      );
    } catch (_) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Could not generate certificate PDF.',
        type: AppToastType.error,
      );
    }
  }

  Future<void> _printHardcopyCertificate(Certificate cert) async {
    final input = await _showHardcopyInputDialog(context);
    if (input == null) return;

    try {
      final bytes = await _pdfService.generateHardcopyCertificatePdfBytes(
        cert: cert,
        input: HardcopyCertificateInput(
          directorName: input.directorName,
          examinationDate: input.examinationDate,
          grade: input.grade,
          councilLevel: input.councilLevel,
          overallScore: input.overallScore,
        ),
      );
      final fileName = CertificatePdfService.buildHardcopyPdfFileName(cert);
      await Printing.layoutPdf(name: fileName, onLayout: (_) async => bytes);
      if (!mounted) return;
      AppToast.show(
        context,
        'Hardcopy certificate opened in print preview.',
        type: AppToastType.success,
      );
    } catch (_) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Could not generate hardcopy certificate PDF.',
        type: AppToastType.error,
      );
    }
  }
}

// =============================================================================
// Tab 0: New Certificate Form Sheet
// =============================================================================

class _AdminCertFormSheet extends StatefulWidget {
  final AdminCertificateService service;
  final AdminCertificate? certificate;

  const _AdminCertFormSheet({required this.service, this.certificate});

  @override
  State<_AdminCertFormSheet> createState() => _AdminCertFormSheetState();
}

class _AdminCertFormSheetState extends State<_AdminCertFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameC = TextEditingController();
  final _nationalIdC = TextEditingController();
  final _certNameC = TextEditingController();
  final _sublineC = TextEditingController();
  final _descriptionC = TextEditingController();

  DateTime? _dateOfBirth;
  DateTime? _issueDate;
  String _idType = 'national_id'; // 'national_id' or 'passport'

  PlatformFile? _frontIdFile;
  PlatformFile? _backIdFile;
  PlatformFile? _passportFile;

  bool _saving = false;
  bool _uploading = false;

  List<String> _suggestedNames = [];
  List<String> _suggestedSublines = [];
  bool _namesLoaded = false;
  bool _sublinesLoaded = false;

  bool get _isEditing => widget.certificate != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      final cert = widget.certificate!;
      _fullNameC.text = cert.fullName;
      _nationalIdC.text = cert.nationalIdNumber;
      _certNameC.text = cert.certificateName;
      _sublineC.text = cert.subline;
      _descriptionC.text = cert.description;
      _idType = cert.idType;
      _dateOfBirth = _tryParseDate(cert.dateOfBirth);
      _issueDate = _tryParseDate(cert.issueDate);
    }
    _loadSuggestions();
  }

  DateTime? _tryParseDate(String v) {
    try {
      return DateFormat('yyyy-MM-dd').parse(v);
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadSuggestions() async {
    if (!_namesLoaded) {
      final names = await widget.service.getSuggestedNames();
      if (mounted) setState(() => _suggestedNames = names);
      _namesLoaded = true;
    }
    if (!_sublinesLoaded) {
      final sublines = await widget.service.getSuggestedSublines();
      if (mounted) setState(() => _suggestedSublines = sublines);
      _sublinesLoaded = true;
    }
  }

  @override
  void dispose() {
    _fullNameC.dispose();
    _nationalIdC.dispose();
    _certNameC.dispose();
    _sublineC.dispose();
    _descriptionC.dispose();
    super.dispose();
  }

  Future<void> _pickFile({required bool isFront, required bool isBack}) async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
    );
    if (result == null || result.files.isEmpty) return;
    if (isFront) {
      setState(() => _frontIdFile = result.files.first);
    } else if (isBack) {
      setState(() => _backIdFile = result.files.first);
    } else {
      setState(() => _passportFile = result.files.first);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_dateOfBirth == null) {
      AppToast.show(context, 'Date of birth is required',
          type: AppToastType.error);
      return;
    }
    if (_issueDate == null) {
      AppToast.show(context, 'Issue date is required',
          type: AppToastType.error);
      return;
    }

    setState(() => _saving = true);

    try {
      final certName = _certNameC.text.trim().isNotEmpty
          ? _certNameC.text.trim()
          : 'Certificate';
      final subline = _sublineC.text.trim().isNotEmpty
          ? _sublineC.text.trim()
          : '';

      String? frontIdUrl;
      String? backIdUrl;
      String? passportUrl;
      String? profilePicUrl;

      // Upload images
      setState(() => _uploading = true);

      if (_idType == 'national_id') {
        if (_frontIdFile != null) {
          frontIdUrl = await widget.service.uploadIdImage(
            file: _frontIdFile!,
            certificateName: certName,
          );
          profilePicUrl = frontIdUrl;
        } else if (_isEditing && widget.certificate!.frontIdUrl != null) {
          frontIdUrl = widget.certificate!.frontIdUrl;
          profilePicUrl = frontIdUrl;
        }
        if (_backIdFile != null) {
          backIdUrl = await widget.service.uploadIdImage(
            file: _backIdFile!,
            certificateName: certName,
          );
        } else if (_isEditing) {
          backIdUrl = widget.certificate!.backIdUrl;
        }
      } else {
        if (_passportFile != null) {
          passportUrl = await widget.service.uploadIdImage(
            file: _passportFile!,
            certificateName: certName,
          );
          profilePicUrl = passportUrl;
        } else if (_isEditing && widget.certificate!.passportUrl != null) {
          passportUrl = widget.certificate!.passportUrl;
          profilePicUrl = passportUrl;
        }
      }

      setState(() => _uploading = false);

      final dobStr = DateFormat('yyyy-MM-dd').format(_dateOfBirth!);
      final issueStr = DateFormat('yyyy-MM-dd').format(_issueDate!);

      final cert = AdminCertificate(
        key: widget.certificate?.key,
        fullName: _fullNameC.text.trim(),
        dateOfBirth: dobStr,
        nationalIdNumber: _nationalIdC.text.trim(),
        idType: _idType,
        certificateName: certName,
        subline: subline,
        description: _descriptionC.text.trim(),
        issueDate: issueStr,
        frontIdUrl: frontIdUrl,
        backIdUrl: backIdUrl,
        passportUrl: passportUrl,
        profilePicUrl: profilePicUrl,
      );

      if (_isEditing) {
        await widget.service.update(widget.certificate!.key!, cert);
      } else {
        await widget.service.save(cert);
      }

      // Save suggestions
      if (certName.isNotEmpty) {
        await widget.service.addSuggestedName(certName);
      }
      if (subline.isNotEmpty) {
        await widget.service.addSuggestedSubline(subline);
      }

      if (mounted) {
        AppToast.show(
          context,
          _isEditing
              ? 'Certificate updated successfully'
              : 'Certificate created successfully',
          type: AppToastType.success,
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, 'Error: $e', type: AppToastType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Form(
            key: _formKey,
            child: ListView(
              controller: scrollController,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: _uiBorder,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _isEditing ? 'Edit Certificate' : 'Add Certificate',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: _primaryBlue,
                  ),
                ),
                const SizedBox(height: 24),

                // Full Name
                TextFormField(
                  controller: _fullNameC,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Full Name *',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      v?.trim().isEmpty == true ? 'Required' : null,
                ),
                const SizedBox(height: 14),

                // Date of Birth
                InkWell(
                  onTap: _pickDateOfBirth,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Date of Birth *',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.calendar_today),
                    ),
                    child: Text(
                      _dateOfBirth != null
                          ? DateFormat('yyyy-MM-dd').format(_dateOfBirth!)
                          : 'Select date',
                      style: TextStyle(
                        color: _dateOfBirth != null
                            ? Colors.black87
                            : _softText,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // National ID
                TextFormField(
                  controller: _nationalIdC,
                  decoration: const InputDecoration(
                    labelText: 'National ID Number *',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      v?.trim().isEmpty == true ? 'Required' : null,
                ),
                const SizedBox(height: 14),

                // ID Type Toggle
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _appBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _uiBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ID Document Type',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: _primaryBlue,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _IdTypeOption(
                              selected: _idType == 'national_id',
                              label: 'National ID\n(Front + Back)',
                              icon: Icons.badge_outlined,
                              onTap: () =>
                                  setState(() => _idType = 'national_id'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _IdTypeOption(
                              selected: _idType == 'passport',
                              label: 'Passport\n(Single)',
                              icon: Icons.menu_book_outlined,
                              onTap: () =>
                                  setState(() => _idType = 'passport'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // File pickers based on type
                      if (_idType == 'national_id') ...[
                        _buildFilePickerTile(
                          label: 'Front ID *',
                          fileName: _frontIdFile?.name ??
                              (_isEditing && widget.certificate!.frontIdUrl != null
                                  ? 'Uploaded'
                                  : null),
                          onPick: () => _pickFile(isFront: true, isBack: false),
                        ),
                        const SizedBox(height: 8),
                        _buildFilePickerTile(
                          label: 'Back ID',
                          fileName: _backIdFile?.name ??
                              (_isEditing && widget.certificate!.backIdUrl != null
                                  ? 'Uploaded'
                                  : null),
                          onPick: () => _pickFile(isFront: false, isBack: true),
                        ),
                      ] else ...[
                        _buildFilePickerTile(
                          label: 'Passport *',
                          fileName: _passportFile?.name ??
                              (_isEditing && widget.certificate!.passportUrl != null
                                  ? 'Uploaded'
                                  : null),
                          onPick: () =>
                              _pickFile(isFront: false, isBack: false),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // Certificate Name
                _SuggestionField(
                  label: 'Certificate Name *',
                  controller: _certNameC,
                  suggestions: _suggestedNames,
                  validator: (v) =>
                      v?.trim().isEmpty == true ? 'Required' : null,
                ),
                const SizedBox(height: 14),

                // Subline
                _SuggestionField(
                  label: 'Subline',
                  controller: _sublineC,
                  suggestions: _suggestedSublines,
                ),
                const SizedBox(height: 14),

                // Description
                TextFormField(
                  controller: _descriptionC,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),

                // Issue Date
                InkWell(
                  onTap: _pickIssueDate,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Issue Date *',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.calendar_today),
                    ),
                    child: Text(
                      _issueDate != null
                          ? DateFormat('yyyy-MM-dd').format(_issueDate!)
                          : 'Select date',
                      style: TextStyle(
                        color: _issueDate != null ? Colors.black87 : _softText,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Save Button
                FilledButton(
                  onPressed: (_saving || _uploading) ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: _actionOrange,
                    minimumSize: const Size(double.infinity, 50),
                  ),
                  child: (_saving || _uploading)
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          _isEditing
                              ? 'Update Certificate'
                              : 'Create Certificate',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilePickerTile({
    required String label,
    String? fileName,
    required VoidCallback onPick,
  }) {
    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _uiBorder),
        ),
        child: Row(
          children: [
            Icon(
              fileName != null
                  ? Icons.check_circle_outline
                  : Icons.image_outlined,
              size: 20,
              color: fileName != null ? Colors.green : _softText,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                fileName != null ? '$label: $fileName' : 'Tap to pick $label',
                style: TextStyle(
                  color: fileName != null ? Colors.black87 : _softText,
                  fontSize: 13,
                ),
              ),
            ),
            const Icon(Icons.upload_file, size: 18, color: _softText),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDateOfBirth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dateOfBirth ?? DateTime(2000),
      firstDate: DateTime(1950),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _dateOfBirth = picked);
  }

  Future<void> _pickIssueDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _issueDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked != null) setState(() => _issueDate = picked);
  }
}

class _IdTypeOption extends StatelessWidget {
  final bool selected;
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _IdTypeOption({
    required this.selected,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? _primaryBlue.withValues(alpha: 0.1)
              : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? _primaryBlue : _uiBorder,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: selected ? _primaryBlue : _softText,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: selected ? _primaryBlue : _softText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final List<String> suggestions;
  final String? Function(String?)? validator;

  const _SuggestionField({
    required this.label,
    required this.controller,
    required this.suggestions,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
      optionsBuilder: (textEditingValue) {
        if (textEditingValue.text.isEmpty) {
          return suggestions;
        }
        return suggestions.where((s) => s
            .toLowerCase()
            .contains(textEditingValue.text.toLowerCase()));
      },
      initialValue: TextEditingValue(text: controller.text),
      onSelected: (value) => controller.text = value,
      fieldViewBuilder: (context, textEditingController, focusNode, onSubmitted) {
        // Sync controllers
        textEditingController.text = controller.text;
        textEditingController.addListener(() {
          controller.text = textEditingController.text;
        });
        return TextFormField(
          controller: textEditingController,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          validator: validator,
          onFieldSubmitted: (_) => onSubmitted(),
        );
      },
    );
  }
}

// =============================================================================
// Tab 0: Admin Certificate Card
// =============================================================================

class _AdminCertCard extends StatelessWidget {
  final AdminCertificate certificate;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _AdminCertCard({
    required this.certificate,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _uiBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: _appBg,
                backgroundImage: certificate.effectivePicUrl.isNotEmpty
                    ? NetworkImage(certificate.effectivePicUrl)
                    : null,
                child: certificate.effectivePicUrl.isEmpty
                    ? const Icon(Icons.person, color: _softText)
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      certificate.fullName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: _primaryBlue,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      certificate.certificateName,
                      style: const TextStyle(
                        color: _actionOrange,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (certificate.subline.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        certificate.subline,
                        style:
                            const TextStyle(color: _softText, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _MiniChip(
                          icon: Icons.calendar_today,
                          label: certificate.issueDate,
                        ),
                        const SizedBox(width: 8),
                        _MiniChip(
                          icon: Icons.badge_outlined,
                          label: certificate.idType == 'passport'
                              ? 'Passport'
                              : 'National ID',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: _softText),
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      onEdit();
                      break;
                    case 'delete':
                      onDelete();
                      break;
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MiniChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: _appBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: _softText),
          const SizedBox(width: 3),
          Text(
            label,
            style: const TextStyle(color: _softText, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Tab 0: Admin Certificate View Sheet
// =============================================================================

class _AdminCertViewSheet extends StatelessWidget {
  final AdminCertificate certificate;
  final AdminCertificateService service;
  final VoidCallback onDeleted;
  final VoidCallback onEdited;

  const _AdminCertViewSheet({
    required this.certificate,
    required this.service,
    required this.onDeleted,
    required this.onEdited,
  });

  String _formatDate(String v) {
    if (v.isEmpty) return '-';
    try {
      return DateFormat('yyyy-MM-dd').format(DateFormat('yyyy-MM-dd').parse(v));
    } catch (_) {
      return v;
    }
  }

  @override
  Widget build(BuildContext context) {
    final picUrl = certificate.effectivePicUrl;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _uiBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Center(
                child: CircleAvatar(
                  radius: 48,
                  backgroundColor: _appBg,
                  backgroundImage:
                      picUrl.isNotEmpty ? NetworkImage(picUrl) : null,
                  child: picUrl.isEmpty
                      ? const Icon(Icons.person, size: 48, color: _softText)
                      : null,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  certificate.fullName,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: _primaryBlue,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  certificate.certificateName,
                  style: const TextStyle(
                    color: _actionOrange,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (certificate.subline.isNotEmpty) ...[
                const SizedBox(height: 2),
                Center(
                  child: Text(
                    certificate.subline,
                    style: const TextStyle(color: _softText, fontSize: 14),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              _adminDetailRow('Date of Birth', _formatDate(certificate.dateOfBirth)),
              _adminDetailRow('National ID', certificate.nationalIdNumber),
              _adminDetailRow(
                'ID Type',
                certificate.idType == 'passport' ? 'Passport' : 'National ID',
              ),
              if (certificate.description.isNotEmpty)
                _adminDetailRow('Description', certificate.description),
              _adminDetailRow('Issue Date', _formatDate(certificate.issueDate)),
              if (certificate.createdAt > 0)
                _adminDetailRow(
                  'Created',
                  DateFormat('yyyy-MM-dd HH:mm').format(
                    DateTime.fromMillisecondsSinceEpoch(certificate.createdAt),
                  ),
                ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        onEdited();
                      },
                      icon: const Icon(Icons.edit, size: 18),
                      label: const Text('Edit'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                      ),
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('Delete Certificate'),
                            content: Text(
                              'Delete certificate for "${certificate.fullName}"?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red,
                                ),
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          try {
                            await service.delete(certificate.key!);
                            if (context.mounted) {
                              AppToast.show(
                                context,
                                'Certificate deleted',
                                type: AppToastType.success,
                              );
                            }
                            onDeleted();
                          } catch (e) {
                            if (context.mounted) {
                              AppToast.show(
                                context,
                                'Error deleting',
                                type: AppToastType.error,
                              );
                            }
                          }
                        }
                      },
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _adminDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: _softText,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: _primaryBlue,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Tab 1: Existing widgets (unchanged)
// =============================================================================

class _HardcopyDialogResult {
  final String directorName;
  final DateTime examinationDate;
  final String grade;
  final String councilLevel;
  final int overallScore;

  const _HardcopyDialogResult({
    required this.directorName,
    required this.examinationDate,
    required this.grade,
    required this.councilLevel,
    required this.overallScore,
  });
}

Future<_HardcopyDialogResult?> _showHardcopyInputDialog(
  BuildContext context,
) async {
  final formKey = GlobalKey<FormState>();
  final directorController = TextEditingController();
  final examDateController = TextEditingController();
  final councilLevelController = TextEditingController();
  final overallScoreController = TextEditingController();

  DateTime? examDate;
  String? grade;

  final result = await showModalBottomSheet<_HardcopyDialogResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (dialogContext) {
      return _HardcopyFormSheet(
        dialogContext: dialogContext,
        formKey: formKey,
        directorController: directorController,
        examDateController: examDateController,
        councilLevelController: councilLevelController,
        overallScoreController: overallScoreController,
        examDate: examDate,
        grade: grade,
      );
    },
  );

  directorController.dispose();
  examDateController.dispose();
  councilLevelController.dispose();
  overallScoreController.dispose();
  return result;
}

class _HardcopyFormSheet extends StatefulWidget {
  final BuildContext dialogContext;
  final GlobalKey<FormState> formKey;
  final TextEditingController directorController;
  final TextEditingController examDateController;
  final TextEditingController councilLevelController;
  final TextEditingController overallScoreController;
  final DateTime? examDate;
  final String? grade;

  const _HardcopyFormSheet({
    required this.dialogContext,
    required this.formKey,
    required this.directorController,
    required this.examDateController,
    required this.councilLevelController,
    required this.overallScoreController,
    this.examDate,
    this.grade,
  });

  @override
  State<_HardcopyFormSheet> createState() => _HardcopyFormSheetState();
}

class _HardcopyFormSheetState extends State<_HardcopyFormSheet> {
  late DateTime? examDate;
  late String? grade;

  @override
  void initState() {
    super.initState();
    examDate = widget.examDate;
    grade = widget.grade;
  }

  Future<void> _pickExamDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: examDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      examDate = DateTime(picked.year, picked.month, picked.day);
      widget.examDateController.text = DateFormat(
        'yyyy-MM-dd',
      ).format(examDate!);
    });
  }

  void _submit() {
    if (!widget.formKey.currentState!.validate() || examDate == null) {
      return;
    }
    Navigator.pop(
      context,
      _HardcopyDialogResult(
        directorName: widget.directorController.text.trim(),
        examinationDate: examDate!,
        grade: grade!.trim().toUpperCase(),
        councilLevel: widget.councilLevelController.text.trim(),
        overallScore: int.parse(widget.overallScoreController.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: DraggableScrollableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.5,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) => SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.all(20),
            child: Form(
              key: widget.formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: _uiBorder,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Hardcopy Certificate',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: _primaryBlue,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: widget.directorController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Director name',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Director name is required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: widget.examDateController,
                    readOnly: true,
                    onTap: _pickExamDate,
                    decoration: InputDecoration(
                      labelText: 'Date of examination',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: _pickExamDate,
                        icon: const Icon(Icons.calendar_today),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Date of examination is required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: grade,
                    decoration: const InputDecoration(
                      labelText: 'Grade',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'A', child: Text('A')),
                      DropdownMenuItem(value: 'B', child: Text('B')),
                      DropdownMenuItem(value: 'C', child: Text('C')),
                    ],
                    onChanged: (value) {
                      setState(() => grade = value);
                    },
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Grade is required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: widget.councilLevelController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Council of Europe level',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Council level is required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: widget.overallScoreController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Overall score (0-100)',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Overall score is required';
                      }
                      final parsed = int.tryParse(value.trim());
                      if (parsed == null || parsed < 0 || parsed > 100) {
                        return 'Enter a number between 0 and 100';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _submit,
                          child: const Text('Print Hardcopy'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CertificateListItem extends StatelessWidget {
  final Certificate certificate;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onPrint;
  final VoidCallback onHardcopy;
  final VoidCallback? onToggleDownloads;
  final String? toggleDownloadsLabel;

  const _CertificateListItem({
    required this.certificate,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
    required this.onPrint,
    required this.onHardcopy,
    this.onToggleDownloads,
    this.toggleDownloadsLabel,
  });

  Color _getStatusColor() {
    switch (certificate.effectiveStatus) {
      case CertificateStatus.valid:
        return Colors.green;
      case CertificateStatus.expired:
        return Colors.orange;
      case CertificateStatus.revoked:
        return Colors.red;
    }
  }

  String _getStatusLabel() {
    if (certificate.effectiveStatus == CertificateStatus.expired &&
        certificate.status == CertificateStatus.valid) {
      return 'Expired (auto)';
    }
    return certificate.effectiveStatus.label;
  }

  @override
  Widget build(BuildContext context) {
    final isAutoExpired =
        certificate.effectiveStatus == CertificateStatus.expired &&
        certificate.status == CertificateStatus.valid;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isAutoExpired ? Colors.orange.shade200 : _uiBorder,
          width: isAutoExpired ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onView,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  InkWell(
                    onTap: () => _copyToClipboard(context, certificate.cvn),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _primaryBlue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            certificate.cvn,
                            style: const TextStyle(
                              color: _primaryBlue,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.copy,
                            size: 14,
                            color: _primaryBlue.withValues(alpha: 0.7),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _getStatusColor().withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _getStatusLabel(),
                          style: TextStyle(
                            color: _getStatusColor(),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                        if (isAutoExpired)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Tooltip(
                              message: 'Auto-expired based on expiration date',
                              child: Icon(
                                Icons.schedule,
                                size: 14,
                                color: Colors.orange.shade600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, color: _softText),
                    onSelected: (value) {
                      switch (value) {
                        case 'view':
                          onView();
                          break;
                        case 'edit':
                          onEdit();
                          break;
                        case 'print':
                          onPrint();
                          break;
                        case 'hardcopy':
                          onHardcopy();
                          break;
                        case 'toggle_download':
                          onToggleDownloads?.call();
                          break;
                        case 'delete':
                          onDelete();
                          break;
                      }
                    },
                    itemBuilder: (_) {
                      final items = <PopupMenuEntry<String>>[
                        const PopupMenuItem(value: 'view', child: Text('View')),
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        const PopupMenuItem(
                          value: 'print',
                          child: Text('Print'),
                        ),
                        const PopupMenuItem(
                          value: 'hardcopy',
                          child: Text('Hardcopy'),
                        ),
                      ];
                      if (onToggleDownloads != null) {
                        items.add(
                          PopupMenuItem(
                            value: 'toggle_download',
                            child: Text(
                              toggleDownloadsLabel ?? 'Toggle download',
                            ),
                          ),
                        );
                      }
                      items.add(
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      );
                      return items;
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                certificate.fullName,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: _primaryBlue,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                certificate.certificateTitle,
                style: const TextStyle(color: _softText, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _InfoChip(
                    icon: Icons.calendar_today,
                    label: 'Training: ${certificate.trainingDate}',
                  ),
                  _InfoChip(
                    icon: Icons.event,
                    label: 'Expires: ${certificate.expirationDate}',
                  ),
                  _InfoChip(
                    icon: Icons.download_rounded,
                    label: 'Downloads: ${certificate.downloadCount}',
                  ),
                  _InfoChip(
                    icon: certificate.downloadsEnabled
                        ? Icons.lock_open_rounded
                        : Icons.lock_outline_rounded,
                    label: certificate.downloadsEnabled
                        ? 'Download ON'
                        : 'Download OFF',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    AppToast.show(
      context,
      'CVN copied to clipboard',
      type: AppToastType.success,
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: _softText),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: _softText, fontSize: 12)),
        ],
      ),
    );
  }
}

class _CertificateViewSheet extends StatelessWidget {
  final Certificate certificate;
  final CertificatePdfService _pdfService = CertificatePdfService();

  _CertificateViewSheet({required this.certificate});

  String _formatLocalTimestamp(int ms) {
    if (ms <= 0) return '-';
    return DateFormat(
      'yyyy-MM-dd HH:mm:ss',
    ).format(DateTime.fromMillisecondsSinceEpoch(ms).toLocal());
  }

  Future<void> _sharePdf(BuildContext context) async {
    try {
      final bytes = await _pdfService.generateCertificatePdfBytes(certificate);
      final fileName = CertificatePdfService.buildPdfFileName(certificate);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([
        XFile(file.path, mimeType: 'application/pdf', name: fileName),
      ]);
      if (!context.mounted) return;
      AppToast.show(
        context,
        'Certificate PDF is ready to save or share.',
        type: AppToastType.success,
      );
    } catch (_) {
      if (!context.mounted) return;
      AppToast.show(
        context,
        'Could not generate certificate PDF.',
        type: AppToastType.error,
      );
    }
  }

  Future<void> _printPdf(BuildContext context) async {
    try {
      final bytes = await _pdfService.generateCertificatePdfBytes(certificate);
      final fileName = CertificatePdfService.buildPdfFileName(certificate);
      await Printing.layoutPdf(name: fileName, onLayout: (_) async => bytes);
      if (!context.mounted) return;
      AppToast.show(
        context,
        'Certificate opened in print preview.',
        type: AppToastType.success,
      );
    } catch (_) {
      if (!context.mounted) return;
      AppToast.show(
        context,
        'Could not generate certificate PDF.',
        type: AppToastType.error,
      );
    }
  }

  Future<void> _printHardcopyPdf(BuildContext context) async {
    final input = await _showHardcopyInputDialog(context);
    if (input == null) return;

    try {
      final bytes = await _pdfService.generateHardcopyCertificatePdfBytes(
        cert: certificate,
        input: HardcopyCertificateInput(
          directorName: input.directorName,
          examinationDate: input.examinationDate,
          grade: input.grade,
          councilLevel: input.councilLevel,
          overallScore: input.overallScore,
        ),
      );
      final fileName = CertificatePdfService.buildHardcopyPdfFileName(
        certificate,
      );
      await Printing.layoutPdf(name: fileName, onLayout: (_) async => bytes);
      if (!context.mounted) return;
      AppToast.show(
        context,
        'Hardcopy certificate opened in print preview.',
        type: AppToastType.success,
      );
    } catch (_) {
      if (!context.mounted) return;
      AppToast.show(
        context,
        'Could not generate hardcopy certificate PDF.',
        type: AppToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _uiBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Icon(Icons.verified, color: _primaryBlue, size: 32),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Certificate Details',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: _primaryBlue,
                      ),
                    ),
                  ),
                  _StatusBadge(status: certificate.effectiveStatus),
                ],
              ),
              const SizedBox(height: 24),
              _DetailRow(label: 'CVN', value: certificate.cvn, copyable: true),
              _DetailRow(label: 'Full Name', value: certificate.fullName),
              _DetailRow(
                label: 'National ID',
                value: certificate.nationalIdNumber,
              ),
              _DetailRow(
                label: 'Certificate Title',
                value: certificate.certificateTitle,
              ),
              _DetailRow(label: 'exam_course', value: certificate.examCourse),
              if (certificate.examCourse != 'exam')
                _DetailRow(
                  label: 'Instructor',
                  value: (certificate.instructorName ?? '').trim().isEmpty
                      ? 'Seddik. B'
                      : certificate.instructorName!,
                ),
              _DetailRow(
                label: 'Training Date',
                value: certificate.trainingDate,
              ),
              _DetailRow(
                label: 'Issued At',
                value: _formatLocalTimestamp(certificate.createdAt),
              ),
              _DetailRow(
                label: 'Expiration Date',
                value: certificate.expirationDate,
              ),
              _DetailRow(
                label: 'PDF Downloads',
                value: '${certificate.downloadCount}',
              ),
              _DetailRow(
                label: 'Learner Download Access',
                value: certificate.downloadsEnabled ? 'Enabled' : 'Disabled',
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _sharePdf(context),
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('Generate PDF'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _printPdf(context),
                      icon: const Icon(Icons.print_rounded, size: 18),
                      label: const Text('Print'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _printHardcopyPdf(context),
                      icon: const Icon(Icons.description_outlined, size: 18),
                      label: const Text('Hardcopy'),
                    ),
                  ],
                ),
              ),
              if (certificate.notes != null && certificate.notes!.isNotEmpty)
                _DetailRow(label: 'Notes', value: certificate.notes!),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final CertificateStatus status;

  const _StatusBadge({required this.status});

  Color get _color {
    switch (status) {
      case CertificateStatus.valid:
        return Colors.green;
      case CertificateStatus.expired:
        return Colors.orange;
      case CertificateStatus.revoked:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _color),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          color: _color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool copyable;

  const _DetailRow({
    required this.label,
    required this.value,
    this.copyable = false,
  });

  void _copyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: value));
    AppToast.show(
      context,
      '$label copied to clipboard',
      type: AppToastType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: _softText,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  style: const TextStyle(
                    color: _primaryBlue,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (copyable)
                InkWell(
                  onTap: () => _copyToClipboard(context),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.copy, size: 18, color: _softText),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
