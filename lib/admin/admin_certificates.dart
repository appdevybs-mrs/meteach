import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import '../models/certificate_model.dart';
import '../services/certificate_service.dart';
import '../shared/app_feedback.dart' show AppToast, AppToastType;
import '../shared/screen_help_guide.dart';

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
  final _searchController = TextEditingController();

  List<Certificate> _certificates = [];
  List<Certificate> _filteredCertificates = [];
  bool _loading = true;

  String _searchQuery = '';
  CertificateStatus? _statusFilter;
  String? _titleFilter;
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
    _loadCertificates();
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
      _applyFilters();
    });
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

  void _setSort(String field, {bool? ascending}) {
    setState(() {
      if (_sortBy == field && ascending == null) {
        _sortAscending = !_sortAscending;
      } else {
        _sortBy = field;
        if (ascending != null) _sortAscending = ascending;
      }
      _applyFilters();
    });
  }

  void _clearFilters() {
    setState(() {
      _searchQuery = '';
      _statusFilter = null;
      _titleFilter = null;
      _trainingDateFrom = null;
      _trainingDateTo = null;
      _expirationDateFrom = null;
      _expirationDateTo = null;
      _searchController.clear();
      _applyFilters();
    });
  }

  bool get _hasActiveFilters {
    return _statusFilter != null ||
        (_titleFilter != null && _titleFilter!.isNotEmpty) ||
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

    if (result != null && mounted) {
      await _loadCertificates();
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

    if (result != null && mounted) {
      await _loadCertificates();
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
    AppToast.show(
      context,
      'Print functionality coming soon',
      type: AppToastType.info,
    );
  }

  Future<void> _selectDate(bool isFrom, bool isTrainingDate) async {
    final initialDate = isTrainingDate
        ? (isFrom
              ? (_trainingDateFrom != null
                    ? DateTime.parse(_trainingDateFrom!)
                    : DateTime.now())
              : (_trainingDateTo != null
                    ? DateTime.parse(_trainingDateTo!)
                    : DateTime.now()))
        : (isFrom
              ? (_expirationDateFrom != null
                    ? DateTime.parse(_expirationDateFrom!)
                    : DateTime.now())
              : (_expirationDateTo != null
                    ? DateTime.parse(_expirationDateTo!)
                    : DateTime.now()));

    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );

    if (picked != null) {
      final dateStr = DateFormat('yyyy-MM-dd').format(picked);
      if (isTrainingDate) {
        _setDateFilter(
          isFrom ? dateStr : _trainingDateFrom,
          isFrom ? _trainingDateTo : dateStr,
          true,
        );
      } else {
        _setDateFilter(
          isFrom ? dateStr : _expirationDateFrom,
          isFrom ? _expirationDateTo : dateStr,
          false,
        );
      }
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
          IconButton(
            tooltip: 'Help / Instructions',
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: () => ScreenHelpGuide.show(
              context,
              role: GuideRole.admin,
              screenId: 'admin_certificates',
              screenTitle: 'Certificates',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: _actionOrange),
            onPressed: _showAddCertificateForm,
            tooltip: 'Add Certificate',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchAndFilters(),
          Expanded(child: _buildCertificatesList()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddCertificateForm,
        backgroundColor: _actionOrange,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text(
          'Add Certificate',
          style: TextStyle(color: Colors.white),
        ),
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

  const _CertificateListItem({
    required this.certificate,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
    required this.onPrint,
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
                        case 'delete':
                          onDelete();
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'view', child: Text('View')),
                      const PopupMenuItem(value: 'edit', child: Text('Edit')),
                      const PopupMenuItem(value: 'print', child: Text('Print')),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                    ],
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
              Row(
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: _softText),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: _softText, fontSize: 12)),
      ],
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
  final _notesController = TextEditingController();

  String? _cvn;
  String _trainingDate = '';
  String _expirationDate = '';
  int _durationYears = 1;
  CertificateStatus _status = CertificateStatus.valid;
  bool _loading = false;
  bool _cvnGenerated = false;

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
      _trainingDate = cert.trainingDate;
      _expirationDate = cert.expirationDate;
      _calculateDurationFromDates();
      _status = cert.status;
      _notesController.text = cert.notes ?? '';
      _cvnGenerated = true;
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
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _generateCVN() async {
    try {
      final cvn = await widget.service.generateCVN();
      if (mounted) {
        setState(() {
          _cvn = cvn;
          _cvnGenerated = true;
        });
      }
    } on CertificateServiceException catch (e) {
      if (mounted) {
        AppToast.show(context, e.message, type: AppToastType.error);
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(
          context,
          'Error generating CVN',
          type: AppToastType.error,
        );
      }
    }
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
        cvn: _cvn!,
        fullName: _fullNameController.text.trim(),
        nationalIdNumber: _nationalIdController.text.trim(),
        certificateTitle: _titleController.text.trim(),
        trainingDate: _trainingDate,
        expirationDate: _expirationDate,
        status: _status,
        createdAt: widget.certificate?.createdAt ?? now,
        updatedAt: now,
        issuedBy: FirebaseAuth.instance.currentUser?.uid,
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      );

      if (_isEditing) {
        await widget.service.updateCertificate(widget.certificate!.key!, cert);
      } else {
        await widget.service.createCertificate(cert);
      }

      if (mounted) Navigator.pop(context, cert);
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
                        Expanded(
                          child: _cvnGenerated && _cvn != null
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Certificate Validation Number (CVN)',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12,
                                        color: _softText,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _cvn!,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 16,
                                        color: _primaryBlue,
                                      ),
                                    ),
                                  ],
                                )
                              : const Text(
                                  'Generate a unique CVN for this certificate',
                                  style: TextStyle(color: _softText),
                                ),
                        ),
                        if (!_cvnGenerated)
                          ElevatedButton(
                            onPressed: _generateCVN,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primaryBlue,
                            ),
                            child: const Text(
                              'Generate',
                              style: TextStyle(color: Colors.white),
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
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _loading || (!_isEditing && !_cvnGenerated)
                      ? null
                      : _save,
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

  const _CertificateViewSheet({required this.certificate});

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
              _DetailRow(
                label: 'Training Date',
                value: certificate.trainingDate,
              ),
              _DetailRow(
                label: 'Expiration Date',
                value: certificate.expirationDate,
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
