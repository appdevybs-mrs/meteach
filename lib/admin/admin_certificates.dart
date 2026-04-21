import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import '../models/certificate_model.dart';
import '../services/certificate_pdf_service.dart';
import '../services/certificate_service.dart';
import '../shared/admin_web_layout.dart';
import '../shared/app_feedback.dart' show AppToast, AppToastType;

const _primaryBlue = Color(0xFF1A2B48);
const _actionOrange = Color(0xFFF98D28);
const _appBg = Color(0xFFF4F7F9);
const _softText = Color(0xFF6E7B8C);
const _uiBorder = Color(0xFFE3EAF2);

class AdminCertificatesScreen extends StatefulWidget {
  const AdminCertificatesScreen({super.key});

  @override
  State<AdminCertificatesScreen> createState() =>
      _AdminCertificatesScreenState();
}

class _AdminCertificatesScreenState extends State<AdminCertificatesScreen> {
  final CertificateService _service = CertificateService();
  final CertificatePdfService _pdfService = CertificatePdfService();
  final _searchController = TextEditingController();

  List<Certificate> _certificates = [];
  List<Certificate> _filteredCertificates = [];
  List<RecordedCertificateEntry> _recordedCertificates = [];
  List<RecordedCertificateEntry> _filteredRecordedCertificates = [];
  bool _loading = true;
  int _activeTab = 0;

  String _searchQuery = '';
  CertificateStatus? _statusFilter;
  String? _titleFilter;
  String? _examCourseFilter;
  String? _trainingDateFrom;
  String? _trainingDateTo;
  String? _expirationDateFrom;
  String? _expirationDateTo;

  List<String> _availableTitles = [];
  String _sortBy = 'createdAt';
  bool _sortAscending = false;

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

  Future<void> _loadCertificates() async {
    setState(() => _loading = true);

    try {
      final certs = await _service.getAllCertificates();
      final titles = await _service.getUniqueCertificateTitles();

      setState(() {
        _certificates = certs;
        _availableTitles = titles;
        _applyFilters();
        _loading = false;
      });
    } on CertificateServiceException catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        AppToast.show(context, e.message, type: AppToastType.error);
      }
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        AppToast.show(
          context,
          'Error loading certificates',
          type: AppToastType.error,
        );
      }
    }
  }

  Future<void> _loadAll() async {
    await Future.wait([_loadCertificates(), _loadRecordedCertificates()]);
  }

  Future<void> _loadRecordedCertificates() async {
    setState(() => _loading = true);
    try {
      final rows = await _service.getAllRecordedCertificates();
      setState(() {
        _recordedCertificates = rows;
        _applyRecordedFilters();
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _applyFilters() {
    _filteredCertificates = _certificates.where((cert) {
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchesName = cert.fullName.toLowerCase().contains(q);
        final matchesCVN = cert.cvn.toLowerCase().contains(q);
        final matchesTitle = cert.certificateTitle.toLowerCase().contains(q);
        final matchesNationalId = cert.nationalIdNumber.contains(q);
        if (!matchesName &&
            !matchesCVN &&
            !matchesTitle &&
            !matchesNationalId) {
          return false;
        }
      }

      if (_statusFilter != null) {
        if (cert.effectiveStatus != _statusFilter) return false;
      }

      if (_titleFilter != null && _titleFilter!.isNotEmpty) {
        if (cert.certificateTitle != _titleFilter) return false;
      }

      if (_examCourseFilter != null && _examCourseFilter!.isNotEmpty) {
        if (cert.examCourse != _examCourseFilter) return false;
      }

      if (_trainingDateFrom != null && _trainingDateFrom!.isNotEmpty) {
        if (cert.trainingDate.compareTo(_trainingDateFrom!) < 0) return false;
      }

      if (_trainingDateTo != null && _trainingDateTo!.isNotEmpty) {
        if (cert.trainingDate.compareTo(_trainingDateTo!) > 0) return false;
      }

      if (_expirationDateFrom != null && _expirationDateFrom!.isNotEmpty) {
        if (cert.expirationDate.compareTo(_expirationDateFrom!) < 0)
          return false;
      }

      if (_expirationDateTo != null && _expirationDateTo!.isNotEmpty) {
        if (cert.expirationDate.compareTo(_expirationDateTo!) > 0) return false;
      }

      return true;
    }).toList();

    _filteredCertificates.sort((a, b) {
      int result;
      switch (_sortBy) {
        case 'fullName':
          result = a.fullName.compareTo(b.fullName);
          break;
        case 'cvn':
          result = a.cvn.compareTo(b.cvn);
          break;
        case 'certificateTitle':
          result = a.certificateTitle.compareTo(b.certificateTitle);
          break;
        case 'trainingDate':
          result = a.trainingDate.compareTo(b.trainingDate);
          break;
        case 'expirationDate':
          result = a.expirationDate.compareTo(b.expirationDate);
          break;
        case 'status':
          result = a.status.index.compareTo(b.status.index);
          break;
        case 'createdAt':
        default:
          result = a.createdAt.compareTo(b.createdAt);
      }
      return _sortAscending ? result : -result;
    });
  }

  void _onSearchChanged(String value) {
    setState(() {
      _searchQuery = value;
      if (_activeTab == 0) {
        _applyFilters();
      } else {
        _applyRecordedFilters();
      }
    });
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

  void _setStatusFilter(CertificateStatus? status) {
    setState(() {
      _statusFilter = status;
      _applyFilters();
    });
  }

  void _setTitleFilter(String? title) {
    setState(() {
      _titleFilter = title;
      _applyFilters();
    });
  }

  void _setExamCourseFilter(String? examCourse) {
    setState(() {
      _examCourseFilter = examCourse;
      _applyFilters();
    });
  }

  void _setDateFilter(String? from, String? to, bool isTrainingDate) {
    setState(() {
      if (isTrainingDate) {
        _trainingDateFrom = from;
        _trainingDateTo = to;
      } else {
        _expirationDateFrom = from;
        _expirationDateTo = to;
      }
      _applyFilters();
    });
  }

  void _clearFilters() {
    setState(() {
      _searchQuery = '';
      _statusFilter = null;
      _titleFilter = null;
      _examCourseFilter = null;
      _trainingDateFrom = null;
      _trainingDateTo = null;
      _expirationDateFrom = null;
      _expirationDateTo = null;
      _searchController.clear();
      if (_activeTab == 0) {
        _applyFilters();
      } else {
        _applyRecordedFilters();
      }
    });
  }

  bool get _hasActiveFilters {
    return _statusFilter != null ||
        (_titleFilter != null && _titleFilter!.isNotEmpty) ||
        (_examCourseFilter != null && _examCourseFilter!.isNotEmpty) ||
        _trainingDateFrom != null ||
        _trainingDateTo != null ||
        _expirationDateFrom != null ||
        _expirationDateTo != null;
  }

  Future<void> _showAddCertificateForm() async {
    final result = await showModalBottomSheet<Certificate>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CertificateFormSheet(service: _service),
    );

    if (!mounted) return;
    await _loadCertificates();
    if (!mounted) return;
    if (result != null) {
      AppToast.show(
        context,
        'Certificate created successfully',
        type: AppToastType.success,
      );
    }
  }

  Future<void> _showEditCertificateForm(Certificate cert) async {
    final result = await showModalBottomSheet<Certificate>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _CertificateFormSheet(service: _service, certificate: cert),
    );

    if (!mounted) return;
    await _loadCertificates();
    if (!mounted) return;
    if (result != null) {
      AppToast.show(
        context,
        'Certificate updated successfully',
        type: AppToastType.success,
      );
    }
  }

  Future<void> _showViewCertificate(Certificate cert) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CertificateViewSheet(certificate: cert),
    );
  }

  Future<void> _deleteCertificate(Certificate cert) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Certificate'),
        content: Text(
          'Are you sure you want to delete the certificate for "${cert.fullName}"?',
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
        await _service.deleteCertificate(cert.key!);
        await _loadCertificates();
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

  Future<void> _printCertificate(Certificate cert) async {
    try {
      final bytes = await _pdfService.generateCertificatePdfBytes(cert);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: IconThemeData(color: _primaryBlue),
        title: const Text(
          'Certificates',
          style: TextStyle(color: _primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          const SizedBox.shrink(),
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
            if (_activeTab == 0)
              _buildSearchAndFilters()
            else
              _buildRecordedSearch(),
            Expanded(
              child: _activeTab == 0
                  ? _buildCertificatesList()
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
            setState(() {
              _activeTab = idx;
              if (_activeTab == 0) {
                _applyFilters();
              } else {
                _applyRecordedFilters();
              }
            });
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
            tab(0, 'Manual Certificates'),
            const SizedBox(width: 6),
            tab(1, 'Recorded Achievements'),
          ],
        ),
      ),
    );
  }

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

  Widget _buildSearchAndFilters() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Search by name, CVN, title, or National ID...',
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
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FilterChip(
                  label: 'Status',
                  value: _statusFilter?.label ?? 'All',
                  isActive: _statusFilter != null,
                  onTap: () => _showStatusFilterMenu(),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Title',
                  value: _titleFilter ?? 'All',
                  isActive: _titleFilter != null,
                  onTap: () => _showTitleFilterMenu(),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'exam_course',
                  value: _examCourseFilter ?? 'All',
                  isActive: _examCourseFilter != null,
                  onTap: () => _showExamCourseFilterMenu(),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Training Date',
                  value: _trainingDateFrom != null || _trainingDateTo != null
                      ? '${_trainingDateFrom ?? '...'} - ${_trainingDateTo ?? '...'}'
                      : 'All',
                  isActive:
                      _trainingDateFrom != null || _trainingDateTo != null,
                  onTap: () => _showDateFilterDialog(true),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: 'Expiration',
                  value:
                      _expirationDateFrom != null || _expirationDateTo != null
                      ? '${_expirationDateFrom ?? '...'} - ${_expirationDateTo ?? '...'}'
                      : 'All',
                  isActive:
                      _expirationDateFrom != null || _expirationDateTo != null,
                  onTap: () => _showDateFilterDialog(false),
                ),
                if (_hasActiveFilters) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _clearFilters,
                    icon: const Icon(Icons.clear_all, size: 18),
                    label: const Text('Clear Filters'),
                    style: TextButton.styleFrom(foregroundColor: _softText),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showStatusFilterMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('All Statuses'),
              leading: Radio<CertificateStatus?>(
                value: null,
                groupValue: _statusFilter,
                onChanged: (v) {
                  _setStatusFilter(null);
                  Navigator.pop(context);
                },
              ),
            ),
            ...CertificateStatus.values.map(
              (status) => ListTile(
                title: Text(status.label),
                leading: Radio<CertificateStatus?>(
                  value: status,
                  groupValue: _statusFilter,
                  onChanged: (v) {
                    _setStatusFilter(v);
                    Navigator.pop(context);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTitleFilterMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('All Titles'),
              leading: Radio<String?>(
                value: null,
                groupValue: _titleFilter,
                onChanged: (v) {
                  _setTitleFilter(null);
                  Navigator.pop(context);
                },
              ),
            ),
            ...(_availableTitles.map(
              (title) => ListTile(
                title: Text(title),
                leading: Radio<String?>(
                  value: title,
                  groupValue: _titleFilter,
                  onChanged: (v) {
                    _setTitleFilter(v);
                    Navigator.pop(context);
                  },
                ),
              ),
            )),
          ],
        ),
      ),
    );
  }

  void _showExamCourseFilterMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('All'),
              leading: Radio<String?>(
                value: null,
                groupValue: _examCourseFilter,
                onChanged: (v) {
                  _setExamCourseFilter(null);
                  Navigator.pop(context);
                },
              ),
            ),
            ListTile(
              title: const Text('course'),
              leading: Radio<String?>(
                value: 'course',
                groupValue: _examCourseFilter,
                onChanged: (v) {
                  _setExamCourseFilter(v);
                  Navigator.pop(context);
                },
              ),
            ),
            ListTile(
              title: const Text('exam'),
              leading: Radio<String?>(
                value: 'exam',
                groupValue: _examCourseFilter,
                onChanged: (v) {
                  _setExamCourseFilter(v);
                  Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDateFilterDialog(bool isTrainingDate) {
    final fromController = TextEditingController(
      text: isTrainingDate ? _trainingDateFrom : _expirationDateFrom,
    );
    final toController = TextEditingController(
      text: isTrainingDate ? _trainingDateTo : _expirationDateTo,
    );

    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          '${isTrainingDate ? 'Training' : 'Expiration'} Date Filter',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: fromController,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'From Date',
                border: OutlineInputBorder(),
              ),
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: fromController.text.isNotEmpty
                      ? DateTime.parse(fromController.text)
                      : DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                );
                if (date != null) {
                  fromController.text = DateFormat('yyyy-MM-dd').format(date);
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: toController,
              readOnly: true,
              decoration: const InputDecoration(
                labelText: 'To Date',
                border: OutlineInputBorder(),
              ),
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: toController.text.isNotEmpty
                      ? DateTime.parse(toController.text)
                      : DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                );
                if (date != null) {
                  toController.text = DateFormat('yyyy-MM-dd').format(date);
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _setDateFilter(null, null, isTrainingDate);
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () {
              _setDateFilter(
                fromController.text.isEmpty ? null : fromController.text,
                toController.text.isEmpty ? null : toController.text,
                isTrainingDate,
              );
              Navigator.pop(context);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  Widget _buildCertificatesList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_filteredCertificates.isEmpty) {
      return Center(
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
              _certificates.isEmpty
                  ? 'No certificates yet'
                  : 'No certificates match your filters',
              style: TextStyle(color: _softText, fontSize: 16),
            ),
            if (_certificates.isEmpty) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _showAddCertificateForm,
                icon: const Icon(Icons.add),
                label: const Text('Add your first certificate'),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
      itemCount: _filteredCertificates.length,
      itemBuilder: (context, index) {
        final cert = _filteredCertificates[index];
        return _CertificateListItem(
          certificate: cert,
          onView: () => _showViewCertificate(cert),
          onEdit: () => _showEditCertificateForm(cert),
          onDelete: () => _deleteCertificate(cert),
          onPrint: () => _printCertificate(cert),
        );
      },
    );
  }

  Widget _buildRecordedCertificatesList() {
    if (_loading) {
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
          onView: () => _showViewCertificate(cert),
          onEdit: () => _showEditRecordedCertificateForm(entry),
          onDelete: () => _deleteRecordedCertificateEntry(entry),
          onPrint: () => _printCertificate(cert),
          onToggleDownloads: () => _toggleRecordedDownloads(entry),
          toggleDownloadsLabel: cert.downloadsEnabled
              ? 'Disable download'
              : 'Enable download',
        );
      },
    );
  }

  Future<void> _toggleRecordedDownloads(RecordedCertificateEntry entry) async {
    final cert = entry.certificate;
    final next = !cert.downloadsEnabled;
    await _service.updateRecordedCertificate(
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
          await _service.deleteRecordedCertificate(
            learnerUid: entry.learnerUid,
            certId: entry.certId,
            cvn: entry.certificate.cvn,
          );
          changed++;
        } else {
          if (!entry.certificate.downloadsEnabled) continue;
          await _service.updateRecordedCertificate(
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

    await _service.deleteRecordedCertificate(
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
      await _service.updateRecordedCertificate(
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
                  decoration: const InputDecoration(labelText: 'Training Date'),
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
                  value: durationYears,
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
                      expirationDate = DateFormat(
                        'yyyy-MM-dd',
                      ).format(t.add(Duration(days: durationYears * 365)));
                    });
                  },
                ),
                const SizedBox(height: 10),
                TextFormField(
                  readOnly: true,
                  controller: TextEditingController(text: expirationDate),
                  decoration: const InputDecoration(
                    labelText: 'Expiration Date',
                  ),
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
}

class _FilterChip extends StatelessWidget {
  final String label;
  final String value;
  final bool isActive;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.value,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isActive
          ? _primaryBlue.withValues(alpha: 0.1)
          : const Color(0xFFF4F7F9),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isActive ? _primaryBlue : const Color(0xFFE3EAF2),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$label: ',
                style: TextStyle(
                  color: isActive ? _primaryBlue : _softText,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: isActive ? _primaryBlue : Colors.black87,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_drop_down,
                size: 18,
                color: isActive ? _primaryBlue : _softText,
              ),
            ],
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
  final VoidCallback? onToggleDownloads;
  final String? toggleDownloadsLabel;

  const _CertificateListItem({
    required this.certificate,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
    required this.onPrint,
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
                  const SizedBox(width: 8),
                  _InfoChip(
                    icon: Icons.event,
                    label: 'Expires: ${certificate.expirationDate}',
                  ),
                  const SizedBox(width: 8),
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

class _CertificateFormSheet extends StatefulWidget {
  final CertificateService service;
  final Certificate? certificate;

  const _CertificateFormSheet({required this.service, this.certificate});

  @override
  State<_CertificateFormSheet> createState() => _CertificateFormSheetState();
}

class _CertificateFormSheetState extends State<_CertificateFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _nationalIdController = TextEditingController();
  final _titleController = TextEditingController();
  final _instructorController = TextEditingController();
  final _notesController = TextEditingController();

  String? _cvn;
  String _trainingDate = '';
  String _expirationDate = '';
  int _durationYears = 1;
  String _examCourse = 'course';
  CertificateStatus _status = CertificateStatus.valid;
  bool _downloadsEnabled = true;
  bool _loading = false;

  bool get _isEditing => widget.certificate != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      final cert = widget.certificate!;
      _cvn = cert.cvn;
      _fullNameController.text = cert.fullName;
      _nationalIdController.text = cert.nationalIdNumber;
      _titleController.text = cert.certificateTitle;
      _instructorController.text = cert.instructorName ?? '';
      _examCourse = cert.examCourse;
      _trainingDate = cert.trainingDate;
      _expirationDate = cert.expirationDate;
      _calculateDurationFromDates();
      _status = cert.status;
      _downloadsEnabled = cert.downloadsEnabled;
      _notesController.text = cert.notes ?? '';
    }
  }

  void _calculateDurationFromDates() {
    if (_trainingDate.isNotEmpty && _expirationDate.isNotEmpty) {
      try {
        final training = DateTime.parse(_trainingDate);
        final expiration = DateTime.parse(_expirationDate);
        final diff = expiration.difference(training).inDays;
        _durationYears = (diff / 365).round();
        if (_durationYears < 1) _durationYears = 1;
        if (_durationYears > 10) _durationYears = 10;
      } catch (_) {
        _durationYears = 1;
      }
    }
  }

  void _calculateExpirationDate() {
    if (_trainingDate.isNotEmpty) {
      try {
        final training = DateTime.parse(_trainingDate);
        final expiration = training.add(Duration(days: _durationYears * 365));
        _expirationDate = DateFormat('yyyy-MM-dd').format(expiration);
      } catch (_) {
        _expirationDate = '';
      }
    }
  }

  @override
  void dispose() {
    _fullNameController.dispose();
    _nationalIdController.dispose();
    _titleController.dispose();
    _instructorController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _selectDate() async {
    final initialDate = _trainingDate.isNotEmpty
        ? DateTime.parse(_trainingDate)
        : DateTime.now();

    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );

    if (picked != null) {
      setState(() {
        _trainingDate = DateFormat('yyyy-MM-dd').format(picked);
        _calculateExpirationDate();
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    if (_trainingDate.isEmpty) {
      AppToast.show(
        context,
        'Training date is required',
        type: AppToastType.error,
      );
      return;
    }

    if (_expirationDate.isEmpty) {
      AppToast.show(
        context,
        'Expiration date will be calculated automatically',
        type: AppToastType.error,
      );
      return;
    }

    setState(() => _loading = true);

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final cert = Certificate(
        key: widget.certificate?.key,
        cvn: _cvn ?? '',
        fullName: _fullNameController.text.trim(),
        nationalIdNumber: _nationalIdController.text.trim(),
        certificateTitle: _titleController.text.trim(),
        instructorName: _examCourse == 'exam'
            ? null
            : (_instructorController.text.trim().isEmpty
                  ? 'Seddik. B'
                  : _instructorController.text.trim()),
        examCourse: _examCourse,
        trainingDate: _trainingDate,
        expirationDate: _expirationDate,
        status: _status,
        createdAt: widget.certificate?.createdAt ?? now,
        updatedAt: now,
        issuedBy: FirebaseAuth.instance.currentUser?.uid,
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        downloadCount: widget.certificate?.downloadCount ?? 0,
        lastDownloadedAt: widget.certificate?.lastDownloadedAt,
        downloadsEnabled: _downloadsEnabled,
      );

      if (_isEditing) {
        final key = widget.certificate!.key!;
        await widget.service.updateCertificate(key, cert);
        if (mounted) Navigator.pop(context, cert.copyWith(key: key));
      } else {
        final created = await widget.service.createCertificateWithPdf(cert);
        if (mounted) Navigator.pop(context, created);
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, e.toString(), type: AppToastType.error);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
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
        initialChildSize: 0.85,
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
                if (!_isEditing) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _appBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _uiBorder),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.auto_awesome_rounded,
                          color: _primaryBlue,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'CVN is generated automatically when the certificate is saved.',
                            style: TextStyle(color: _softText),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _primaryBlue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.tag, color: _primaryBlue),
                        const SizedBox(width: 8),
                        Text(
                          'CVN: $_cvn',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: _primaryBlue,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                TextFormField(
                  controller: _fullNameController,
                  decoration: const InputDecoration(
                    labelText: 'Full Name *',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => v?.trim().isEmpty == true
                      ? 'Full name is required'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _nationalIdController,
                  decoration: const InputDecoration(
                    labelText: 'National ID Number *',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => v?.trim().isEmpty == true
                      ? 'National ID is required'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: 'Certificate Title *',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => v?.trim().isEmpty == true
                      ? 'Certificate title is required'
                      : null,
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('exam_course'),
                  subtitle: Text(_examCourse),
                  value: _examCourse == 'exam',
                  onChanged: (v) {
                    setState(() {
                      _examCourse = v ? 'exam' : 'course';
                      if (v) {
                        _instructorController.clear();
                      }
                    });
                  },
                ),
                const SizedBox(height: 16),
                if (_examCourse != 'exam') ...[
                  TextFormField(
                    controller: _instructorController,
                    decoration: const InputDecoration(
                      labelText: 'Instructor Name',
                      hintText: 'Defaults to Seddik. B',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: _selectDate,
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Training Date *',
                            border: OutlineInputBorder(),
                          ),
                          child: Text(
                            _trainingDate.isEmpty
                                ? 'Select date'
                                : _trainingDate,
                            style: TextStyle(
                              color: _trainingDate.isEmpty
                                  ? _softText
                                  : Colors.black,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Duration *',
                          border: OutlineInputBorder(),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed:
                                  _trainingDate.isEmpty || _durationYears <= 1
                                  ? null
                                  : () {
                                      setState(() {
                                        _durationYears--;
                                        _calculateExpirationDate();
                                      });
                                    },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                            Expanded(
                              child: Center(
                                child: Text(
                                  '$_durationYears year${_durationYears > 1 ? 's' : ''}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed:
                                  _trainingDate.isEmpty || _durationYears >= 10
                                  ? null
                                  : () {
                                      setState(() {
                                        _durationYears++;
                                        _calculateExpirationDate();
                                      });
                                    },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (_expirationDate.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.event_available,
                          color: Colors.green.shade700,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Expires on: $_expirationDate',
                          style: TextStyle(
                            color: Colors.green.shade700,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                TextFormField(
                  controller: _notesController,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  activeColor: _actionOrange,
                  title: const Text(
                    'Allow learner PDF downloads',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: _primaryBlue,
                    ),
                  ),
                  subtitle: Text(
                    _downloadsEnabled
                        ? 'Learners can download certificate PDF from CVN verification.'
                        : 'Download button is hidden for learners.',
                    style: const TextStyle(color: _softText, fontSize: 12),
                  ),
                  value: _downloadsEnabled,
                  onChanged: _loading
                      ? null
                      : (v) => setState(() => _downloadsEnabled = v),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _loading ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: _actionOrange,
                    minimumSize: const Size(double.infinity, 50),
                  ),
                  child: _loading
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
              ],
            ),
          ),
        ),
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
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_${certificate.cvn}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([
        XFile(
          file.path,
          mimeType: 'application/pdf',
          name: '${certificate.cvn}.pdf',
        ),
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
      await Printing.layoutPdf(onLayout: (_) async => bytes);
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
