import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/certificate_model.dart';
import '../services/certificate_pdf_service.dart';
import '../services/certificate_service.dart';
import '../shared/app_feedback.dart';

class _CvnInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final formatted = CertificateService.formatCvnInput(newValue.text);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

class VerifyCertificateScreen extends StatefulWidget {
  const VerifyCertificateScreen({super.key});

  @override
  State<VerifyCertificateScreen> createState() =>
      _VerifyCertificateScreenState();
}

class _VerifyCertificateScreenState extends State<VerifyCertificateScreen> {
  static const _primaryBlue = Color(0xFF1A2B48);
  static const _actionOrange = Color(0xFFF98D28);
  static const _appBg = Color(0xFFF4F7F9);
  static const _softText = Color(0xFF6E7B8C);
  static const _uiBorder = Color(0xFFE3EAF2);
  static const _green = Color(0xFF22C55E);
  static const _red = Color(0xFFEF4444);

  final CertificateService _service = CertificateService();
  final CertificatePdfService _pdfService = CertificatePdfService();
  final _cvnController = TextEditingController();
  final _fullNameController = TextEditingController();
  final _trainingDateController = TextEditingController();
  final _last4Controller = TextEditingController();

  int _currentStep = 1;
  bool _loading = false;
  String? _error;
  Certificate? _foundCertificate;
  int _attemptCount = 0;
  DateTime? _lockedUntil;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _cvnController.dispose();
    _fullNameController.dispose();
    _trainingDateController.dispose();
    _last4Controller.dispose();
    super.dispose();
  }

  bool get _isLocked {
    if (_lockedUntil == null) return false;
    if (DateTime.now().isAfter(_lockedUntil!)) {
      _lockedUntil = null;
      _attemptCount = 0;
      return false;
    }
    return true;
  }

  static const int _maxAttempts = 3;
  static const Duration _lockDuration = Duration(hours: 1);

  String get _remainingLockTime {
    if (_lockedUntil == null) return '';
    final remaining = _lockedUntil!.difference(DateTime.now());
    if (remaining.inHours > 0) {
      return '${remaining.inHours} hour${remaining.inHours > 1 ? 's' : ''} ${remaining.inMinutes % 60} min';
    }
    return '${remaining.inMinutes} min ${remaining.inSeconds % 60} sec';
  }

  Future<void> _step1Lookup() async {
    if (_isLocked) {
      setState(() {
        _error = 'Too many attempts. Please wait $_remainingLockTime.';
      });
      return;
    }

    final cvn = _cvnController.text.trim();
    if (cvn.isEmpty) {
      setState(() {
        _error = 'Please enter a CVN';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await _service.verifyCertificate(cvn);

      if (!result.found) {
        _attemptCount++;
        if (_attemptCount >= _maxAttempts) {
          setState(() {
            _lockedUntil = DateTime.now().add(_lockDuration);
            _error = 'Too many failed attempts. Please try again in 1 hour.';
          });
        } else {
          setState(() {
            _error =
                'Certificate not found. ${_maxAttempts - _attemptCount} attempt${_maxAttempts - _attemptCount > 1 ? 's' : ''} remaining.';
          });
        }
        setState(() {
          _currentStep = 3;
          _loading = false;
        });
      } else {
        setState(() {
          _foundCertificate = result.certificate;
          _currentStep = 2;
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Verification service unavailable. Please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _step2Verify() async {
    if (_isLocked) {
      setState(() {
        _error = 'Too many attempts. Please wait $_remainingLockTime.';
      });
      return;
    }

    final enteredLast4 = _last4Controller.text.trim();

    if (enteredLast4.length != 4) {
      setState(() {
        _error = 'Please enter exactly 4 digits';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await Future.delayed(const Duration(milliseconds: 800));

      final cert = _foundCertificate!;
      final storedLast4 = cert.nationalIdNumber.substring(
        cert.nationalIdNumber.length - 4,
      );

      final last4Match = enteredLast4 == storedLast4;

      if (last4Match) {
        setState(() {
          _currentStep = 3;
          _loading = false;
        });
      } else {
        _attemptCount++;
        if (_attemptCount >= _maxAttempts) {
          setState(() {
            _lockedUntil = DateTime.now().add(_lockDuration);
            _error = 'Too many failed attempts. Please try again in 1 hour.';
            _loading = false;
          });
        } else {
          setState(() {
            _currentStep = 3;
            _loading = false;
          });
        }
      }
    } catch (e) {
      setState(() {
        _error = 'Verification failed. Please try again.';
        _loading = false;
      });
    }
  }

  void _reset() {
    setState(() {
      _currentStep = 1;
      _cvnController.clear();
      _fullNameController.clear();
      _trainingDateController.clear();
      _last4Controller.clear();
      _foundCertificate = null;
      _error = null;
      _attemptCount = 0;
      _lockedUntil = null;
    });
  }

  void _goBack() {
    if (_currentStep == 2) {
      setState(() {
        _currentStep = 1;
        _fullNameController.clear();
        _trainingDateController.clear();
        _last4Controller.clear();
        _error = null;
      });
    } else if (_currentStep == 3) {
      _reset();
    }
  }

  Future<void> _downloadCertificatePdf(Certificate cert) async {
    if (!cert.downloadsEnabled) {
      AppToast.show(
        context,
        'Downloads are disabled for this certificate.',
        type: AppToastType.info,
      );
      return;
    }

    try {
      final bytes = await _pdfService.generateCertificatePdfBytes(cert);
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_${cert.cvn}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([
        XFile(file.path, mimeType: 'application/pdf', name: '${cert.cvn}.pdf'),
      ]);
    } catch (_) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Could not generate certificate PDF.',
        type: AppToastType.error,
      );
      return;
    }

    if (!mounted) return;
    AppToast.show(
      context,
      'Certificate PDF is ready to save or share.',
      type: AppToastType.success,
    );

    try {
      if (cert.source == 'recorded' &&
          (cert.learnerUid ?? '').trim().isNotEmpty &&
          (cert.recordedCertId ?? '').trim().isNotEmpty) {
        await _service.incrementRecordedDownloadCount(
          learnerUid: cert.learnerUid!.trim(),
          certId: cert.recordedCertId!.trim(),
        );
      } else {
        final key = cert.key?.trim() ?? '';
        if (key.isEmpty) return;
        await _service.incrementDownloadCount(key, cvn: cert.cvn);
      }
    } catch (_) {}
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
        title: Text(
          'Verify Certificate',
          style: TextStyle(color: _primaryBlue, fontWeight: FontWeight.w900),
        ),
        leading: _currentStep > 1
            ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goBack)
            : null,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStepIndicator(),
            const SizedBox(height: 24),
            if (_currentStep == 1) _buildStep1(),
            if (_currentStep == 2) _buildStep2(),
            if (_currentStep == 3) _buildStep3(),
          ],
        ),
      ),
    );
  }

  Widget _buildStepIndicator() {
    return Row(
      children: [
        _buildStepDot(1),
        Expanded(
          child: Container(
            height: 2,
            color: _currentStep >= 2 ? _actionOrange : _uiBorder,
          ),
        ),
        _buildStepDot(2),
        Expanded(
          child: Container(
            height: 2,
            color: _currentStep >= 3 ? _actionOrange : _uiBorder,
          ),
        ),
        _buildStepDot(3),
      ],
    );
  }

  Widget _buildStepDot(int step) {
    final isActive = _currentStep >= step;
    final isCompleted = _currentStep > step;

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isCompleted ? _green : (isActive ? _actionOrange : _uiBorder),
      ),
      child: Center(
        child: isCompleted
            ? const Icon(Icons.check, color: Colors.white, size: 18)
            : Text(
                '$step',
                style: TextStyle(
                  color: isActive ? Colors.white : _softText,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );
  }

  Widget _buildStep1() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _uiBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _primaryBlue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.tag, color: _primaryBlue, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Step 1: Enter Certificate Number',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          color: _primaryBlue,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Enter the CVN found on the certificate',
                        style: TextStyle(fontSize: 12, color: _softText),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _cvnController,
              inputFormatters: [_CvnInputFormatter()],
              decoration: InputDecoration(
                hintText: 'e.g., DZ01SB-2026-00001',
                prefixIcon: const Icon(Icons.badge),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _uiBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _primaryBlue, width: 2),
                ),
              ),
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _step1Lookup(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: Colors.red.shade700,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading || _isLocked ? null : _step1Lookup,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _actionOrange,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
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
                    : const Text(
                        'Look Up Certificate',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep2() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: _uiBorder),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _primaryBlue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.verified_user,
                        color: _primaryBlue,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Step 2: Verify Ownership',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: _primaryBlue,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Enter last 4 digits of your National ID',
                            style: TextStyle(fontSize: 12, color: _softText),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _last4Controller,
                  maxLength: 4,
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Last 4 Digits of National ID',
                    hintText: '1234',
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: _uiBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: _primaryBlue, width: 2),
                    ),
                  ),
                  onSubmitted: (_) => _step2Verify(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Colors.red.shade700,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Colors.red.shade700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _loading || _isLocked ? null : _step2Verify,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _actionOrange,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
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
                        : const Text(
                            'Verify Certificate',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStep3() {
    if (_foundCertificate == null) {
      return _buildNotFoundResult();
    }

    final cert = _foundCertificate!;
    final effectiveStatus = cert.effectiveStatus;

    if (effectiveStatus != CertificateStatus.valid) {
      if (effectiveStatus == CertificateStatus.revoked) {
        return _buildFailedResult(
          title: 'Certificate Revoked',
          message: 'This certificate has been revoked and is no longer valid.',
        );
      } else {
        return _buildFailedResult(
          title: 'Certificate Expired',
          message: 'This certificate expired on ${cert.expirationDate}.',
        );
      }
    }

    return _buildSuccessResult(cert);
  }

  Widget _buildSuccessResult(Certificate cert) {
    final maskedId = cert.maskedNationalId;
    final today = DateTime.now();

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: _green.withValues(alpha: 0.1),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            border: Border.all(color: _green.withValues(alpha: 0.3), width: 2),
          ),
          child: Column(
            children: [
              Icon(Icons.check_circle, size: 64, color: _green),
              const SizedBox(height: 12),
              const Text(
                'Verification Successful',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF15803D),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This certificate is authentic and verified.',
                style: TextStyle(color: _softText, fontSize: 13),
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(16),
            ),
            border: Border.all(color: _green.withValues(alpha: 0.3), width: 2),
          ),
          child: Column(
            children: [
              _buildDetailRow('Certificate Holder', cert.fullName),
              _buildDetailRow('Certificate Title', cert.certificateTitle),
              _buildDetailRow('Training Date', cert.trainingDate),
              _buildDetailRow('Expiration Date', cert.expirationDate),
              _buildDetailRow('National ID', maskedId),
              _buildDetailRow(
                'Status',
                cert.effectiveStatus.label,
                valueColor: _green,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Verification conducted on ${today.day}/${today.month}/${today.year}',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _softText,
            fontSize: 11,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 16),
        if (cert.downloadsEnabled)
          FilledButton.icon(
            onPressed: () => _downloadCertificatePdf(cert),
            icon: const Icon(Icons.download_rounded),
            label: const Text('Download Certificate PDF'),
            style: FilledButton.styleFrom(
              backgroundColor: _actionOrange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        if (cert.downloadsEnabled) const SizedBox(height: 10),
        if (!cert.downloadsEnabled)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Text(
              'Your certificate PDF is on its way. Please check back shortly.',
              style: TextStyle(
                color: Colors.orange.shade800,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        if (!cert.downloadsEnabled) const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _reset,
          icon: const Icon(Icons.refresh),
          label: const Text('New Verification'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _primaryBlue,
            side: BorderSide(color: _uiBorder),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildFailedResult({required String title, required String message}) {
    final today = DateTime.now();

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: _red.withValues(alpha: 0.1),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            border: Border.all(color: _red.withValues(alpha: 0.3), width: 2),
          ),
          child: Column(
            children: [
              Icon(Icons.cancel, size: 64, color: _red),
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: _red,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: _softText, fontSize: 13),
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(16),
            ),
            border: Border.all(color: _red.withValues(alpha: 0.3), width: 2),
          ),
          child: Text(
            'The details provided do not match our records.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _softText, fontSize: 13),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Verification conducted on ${today.day}/${today.month}/${today.year}',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _softText,
            fontSize: 11,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _reset,
          icon: const Icon(Icons.refresh),
          label: const Text('Try Again'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _primaryBlue,
            side: BorderSide(color: _uiBorder),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildNotFoundResult() {
    final today = DateTime.now();

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.orange.shade50,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            border: Border.all(color: Colors.orange.shade200, width: 2),
          ),
          child: Column(
            children: [
              Icon(Icons.search_off, size: 64, color: Colors.orange.shade400),
              const SizedBox(height: 12),
              Text(
                'Certificate Not Found',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: Colors.orange.shade700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'No certificate found with this CVN.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _softText, fontSize: 13),
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(16),
            ),
            border: Border.all(color: Colors.orange.shade200, width: 2),
          ),
          child: Text(
            'Please check the CVN and try again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _softText, fontSize: 13),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Verification conducted on ${today.day}/${today.month}/${today.year}',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _softText,
            fontSize: 11,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _reset,
          icon: const Icon(Icons.refresh),
          label: const Text('Try Again'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _primaryBlue,
            side: BorderSide(color: _uiBorder),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildDetailRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: _softText,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? _primaryBlue,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
