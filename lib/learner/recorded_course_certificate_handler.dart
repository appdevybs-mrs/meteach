// ignore_for_file: use_build_context_synchronously

part of 'recorded_course_study_screen.dart';

class _CertificateHandler {
  _CertificateHandler({
    required CertificateService certificateService,
    required CertificatePdfService certificatePdfService,
    required String Function() getUid,
    required String Function() getCourseId,
    required String Function() getCourseKey,
    required String Function() getTitle,
    required String Function() getCachedCpdHours,
    required String Function() getCachedShortDescription,
    required List<_SessionRef> Function() getFlatSessions,
    required _RecordedProgress Function(String) progressOf,
    required bool Function(_RecordedSession) isSessionCompleted,
    required int Function(_RecordedProgress) sessionCompletionAt,
    required bool Function(List<_RecordedUnit>) isModuleCompleted,
    required String Function(String) sanitizeIdPart,
    required String Function(DateTime) fmtYmd,
    required String Function(String) oneYearAfter,
    required Future<Map<String, String>> Function() learnerIdentity,
    required Future<String> Function() resolveInstructorName,
    required void Function(String) snack,
  })  : _certificateService = certificateService,
        _certificatePdfService = certificatePdfService,
        _getUid = getUid,
        _getCourseId = getCourseId,
        _getCourseKey = getCourseKey,
        _getTitle = getTitle,
        _getCachedCpdHours = getCachedCpdHours,
        _getCachedShortDescription = getCachedShortDescription,
        _getFlatSessions = getFlatSessions,
        _progressOf = progressOf,
        _isSessionCompleted = isSessionCompleted,
        _sessionCompletionAt = sessionCompletionAt,
        _isModuleCompleted = isModuleCompleted,
        _sanitizeIdPart = sanitizeIdPart,
        _fmtYmd = fmtYmd,
        _oneYearAfter = oneYearAfter,
        _learnerIdentity = learnerIdentity,
        _resolveInstructorName = resolveInstructorName,
        _snack = snack;

  final CertificateService _certificateService;
  final CertificatePdfService _certificatePdfService;
  final Set<String> _generatingModuleCertificateKeys = <String>{};

  final String Function() _getUid;
  final String Function() _getCourseId;
  final String Function() _getCourseKey;
  final String Function() _getTitle;
  final String Function() _getCachedCpdHours;
  final String Function() _getCachedShortDescription;
  final List<_SessionRef> Function() _getFlatSessions;
  final _RecordedProgress Function(String) _progressOf;
  final bool Function(_RecordedSession) _isSessionCompleted;
  final int Function(_RecordedProgress) _sessionCompletionAt;
  final bool Function(List<_RecordedUnit>) _isModuleCompleted;
  final String Function(String) _sanitizeIdPart;
  final String Function(DateTime) _fmtYmd;
  final String Function(String) _oneYearAfter;
  final Future<Map<String, String>> Function() _learnerIdentity;
  final Future<String> Function() _resolveInstructorName;
  final void Function(String) _snack;

  String _courseCompletionDate() {
    int latest = 0;
    for (final ref in _getFlatSessions()) {
      if (!_isSessionCompleted(ref.session)) continue;
      final p = _progressOf(ref.session.id);
      latest = math.max(latest, _sessionCompletionAt(p));
    }
    if (latest <= 0) return _fmtYmd(DateTime.now());
    return _fmtYmd(DateTime.fromMillisecondsSinceEpoch(latest));
  }

  String _moduleCompletionDate(List<_RecordedUnit> moduleUnits) {
    int latest = 0;
    for (final unit in moduleUnits) {
      for (final session in unit.sessions) {
        if (!_isSessionCompleted(session)) continue;
        final p = _progressOf(session.id);
        latest = math.max(latest, _sessionCompletionAt(p));
      }
    }
    if (latest <= 0) return _fmtYmd(DateTime.now());
    return _fmtYmd(DateTime.fromMillisecondsSinceEpoch(latest));
  }

  Future<Certificate> _issueRecordedCertificate({
    required String certId,
    required String certificateTitle,
    required String trainingDate,
    required String kind,
    String? moduleKey,
    String cpdHours = '40',
    String shortDescription = '',
  }) async {
    final identity = await _learnerIdentity();
    final fullName = (identity['fullName'] ?? 'Learner').trim();
    final nationalId = (identity['nationalIdNumber'] ?? '').trim();
    final instructorName = await _resolveInstructorName();
    if (nationalId.length < 4) {
      throw Exception(
        'National ID is missing. Ask admin to add your National ID in your learner profile before issuing certificates.',
      );
    }

    return _certificateService.issueRecordedCertificate(
      learnerUid: _getUid(),
      certId: certId,
      fullName: fullName,
      nationalIdNumber: nationalId,
      certificateTitle: certificateTitle,
      trainingDate: trainingDate,
      expirationDate: _oneYearAfter(trainingDate),
      courseId: _getCourseId(),
      courseKey: _getCourseKey(),
      kind: kind,
      instructorName: instructorName,
      moduleKey: moduleKey,
      cpdHours: cpdHours,
      shortDescription: shortDescription,
    );
  }

  String _moduleCertificateActionKey(String moduleLabel, int moduleIndex) {
    final moduleKeyBase = _sanitizeIdPart(moduleLabel);
    return moduleKeyBase.isNotEmpty
        ? '${moduleKeyBase}_${moduleIndex + 1}'
        : 'm${moduleIndex + 1}';
  }

  Widget _buildCertificateLoadingDialog() {
    return PopScope(
      canPop: false,
      child: Material(
        color: Colors.black54,
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 36),
            padding: const EdgeInsets.fromLTRB(28, 36, 28, 32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(36),
                  ),
                  child: const Icon(
                    Icons.workspace_premium_rounded,
                    size: 36,
                    color: Color(0xFF2563EB),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Generating your certificate…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Please wait a moment',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: Color(0xFF64748B),
                  ),
                ),
                const SizedBox(height: 24),
                const LinearProgressIndicator(
                  backgroundColor: Color(0xFFE2E8F0),
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2563EB)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGeneratingCertificateDialog() {
    return PopScope(
      canPop: false,
      child: Material(
        color: Colors.black54,
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 36),
            padding: const EdgeInsets.fromLTRB(28, 36, 28, 32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(36),
                  ),
                  child: const Center(
                    child: Text(
                      '🎓',
                      style: TextStyle(fontSize: 36),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Generating Module Certificate',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '⏳ Please wait while we prepare your PDF…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: Color(0xFF64748B),
                  ),
                ),
                const SizedBox(height: 24),
                const LinearProgressIndicator(
                  backgroundColor: Color(0xFFE2E8F0),
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF2563EB)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showNationalIdRequiredDialog({
    required BuildContext context,
    required bool mounted,
  }) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        elevation: 0,
        backgroundColor: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(minHeight: 200),
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(32),
                ),
                child: const Icon(
                  Icons.badge_outlined,
                  size: 32,
                  color: Color(0xFFD97706),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'National ID Required',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1E293B),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'To download certificates, we need your National ID on file.\n\n'
                'Send us a photo of your ID (front & back) or passport via '
                'WhatsApp or the app\'s messaging, and we will add it to your profile.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF475569),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Got it'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onCertificateTap({
    required BuildContext context,
    required bool mounted,
    required void Function(void Function()) setState,
  }) async {
    if (AppConnectivity.instance.isOffline) {
      _snack('Certificate generation needs internet. Come back online to generate your certificate.');
      return;
    }
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _buildCertificateLoadingDialog(),
    );
    try {
      final certId = 'course_${_sanitizeIdPart(_getCourseId())}';
      final cpdHours = _getCachedCpdHours();
      final shortDescription = _getCachedShortDescription();
      final cert = await _issueRecordedCertificate(
        certId: certId,
        certificateTitle: _getTitle(),
        trainingDate: _courseCompletionDate(),
        kind: 'course',
        cpdHours: cpdHours,
        shortDescription: shortDescription,
      );
      final bytes = await _certificatePdfService.generateCertificatePdfBytes(
        cert,
      );
      if (mounted) Navigator.of(context).pop();
      await _presentCertificate(
        bytes: bytes,
        defaultFileName:
            'course_certificate_${_sanitizeIdPart(_getCourseKey())}.pdf',
        context: context,
        mounted: mounted,
      );
      unawaited(
        _certificateService.incrementRecordedDownloadCount(
          learnerUid: _getUid(),
          certId: certId,
        ),
      );
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      if (!mounted) return;
      if (e.toString().contains('National ID')) {
        _showNationalIdRequiredDialog(context: context, mounted: mounted);
      } else {
        AppToast.show(
          context,
          toHumanError(e, fallback: 'Could not generate certificate.'),
          type: AppToastType.error,
        );
      }
    }
  }

  Future<void> _onModuleCertificateTap({
    required BuildContext context,
    required bool mounted,
    required void Function(void Function()) setState,
    required String moduleLabel,
    required List<_RecordedUnit> moduleUnits,
    required int moduleIndex,
  }) async {
    final moduleKey = _moduleCertificateActionKey(moduleLabel, moduleIndex);
    if (_generatingModuleCertificateKeys.contains(moduleKey)) return;

    if (AppConnectivity.instance.isOffline) {
      _snack('Certificate generation needs internet. Come back online to generate your certificate.');
      return;
    }

    if (mounted) {
      setState(() {
        _generatingModuleCertificateKeys.add(moduleKey);
      });
    } else {
      _generatingModuleCertificateKeys.add(moduleKey);
    }

    BuildContext? loadingDialogContext;

    try {
      if (mounted) {
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) {
              loadingDialogContext = dialogContext;
              return _buildGeneratingCertificateDialog();
            },
          ),
        );
      }

      final certId = 'module_${_sanitizeIdPart(_getCourseId())}_$moduleKey';
      final cert = await _issueRecordedCertificate(
        certId: certId,
        certificateTitle: _getTitle(),
        trainingDate: _moduleCompletionDate(moduleUnits),
        kind: 'milestone',
        moduleKey: moduleKey,
      );
      final rawTitle = moduleUnits.first.otherTitle.trim();
      final displayModuleLabel = rawTitle.isEmpty
          ? 'Module ${moduleIndex + 1}'
          : 'Module ${moduleIndex + 1}: $rawTitle';
      final bytes = await _certificatePdfService
          .generateMilestoneCertificatePdfBytes(
        cert: cert,
        moduleLabel: displayModuleLabel,
      );

      if (loadingDialogContext != null && loadingDialogContext!.mounted) {
        Navigator.of(loadingDialogContext!).pop();
        loadingDialogContext = null;
      }

      await _presentCertificate(
        bytes: bytes,
        defaultFileName:
            'module_${moduleIndex + 1}_certificate_${_sanitizeIdPart(_getCourseKey())}.pdf',
        context: context,
        mounted: mounted,
      );
      unawaited(
        _certificateService.incrementRecordedDownloadCount(
          learnerUid: _getUid(),
          certId: certId,
        ),
      );
    } catch (e) {
      if (loadingDialogContext != null && loadingDialogContext!.mounted) {
        Navigator.of(loadingDialogContext!).pop();
        loadingDialogContext = null;
      }
      if (!mounted) return;
      if (e.toString().contains('National ID')) {
        _showNationalIdRequiredDialog(context: context, mounted: mounted);
      } else {
        AppToast.show(
          context,
          toHumanError(e, fallback: 'Could not generate milestone certificate.'),
          type: AppToastType.error,
        );
      }
    } finally {
      if (loadingDialogContext != null && loadingDialogContext!.mounted) {
        Navigator.of(loadingDialogContext!).pop();
      }
      if (mounted) {
        setState(() {
          _generatingModuleCertificateKeys.remove(moduleKey);
        });
      } else {
        _generatingModuleCertificateKeys.remove(moduleKey);
      }
    }
  }

  Future<void> _presentCertificate({
    required Uint8List bytes,
    required String defaultFileName,
    required BuildContext context,
    required bool mounted,
  }) async {
    if (!mounted) return;

    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        elevation: 0,
        backgroundColor: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(36),
                ),
                child: const Center(
                  child: Text(
                    '🌍',
                    style: TextStyle(fontSize: 36),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                '📜 Certificate Notice',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                  color: Color(0xFF1E293B),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Column(
                  children: [
                    Text(
                      'Depending on your country of origin, this certificate may require stamping by our office. Please contact us if you need this process.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFF475569),
                        height: 1.5,
                      ),
                    ),
                    SizedBox(height: 14),
                    Text(
                      'قد تتطلب هذه الشهادة ختمًا من مكتبنا حسب بلدك. يرجى التواصل معنا إذا كنت تحتاج إلى هذه الإجراءات.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFF475569),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('✅ Continue'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (proceed != true) return;

    final action = await showDialog<String>(
      context: context,
      builder: (_) => Dialog(
        elevation: 0,
        backgroundColor: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFFDCFCE7),
                  borderRadius: BorderRadius.circular(36),
                ),
                child: const Center(
                  child: Text(
                    '✅',
                    style: TextStyle(fontSize: 36),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Certificate Ready',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                  color: Color(0xFF1E293B),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your certificate is ready. Print it now or save/share it to your device.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF475569),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, 'print'),
                  icon: const Icon(Icons.print_rounded, size: 18),
                  label: const Text('🖨️ Print'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, 'share'),
                  icon: const Icon(Icons.share_rounded, size: 18),
                  label: const Text('💾 Save / Share'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (action == 'print') {
      await Printing.layoutPdf(onLayout: (_) async => bytes);
      if (!mounted) return;
      AppToast.show(
        context,
        'Certificate opened in print preview.',
        type: AppToastType.success,
      );
      return;
    }

    if (kIsWeb) {
      downloadBytes(bytes, defaultFileName);
      if (!mounted) return;
      AppToast.show(
        context,
        'Certificate downloaded.',
        type: AppToastType.success,
      );
    } else {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$defaultFileName',
      );
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([
        XFile(file.path, mimeType: 'application/pdf', name: defaultFileName),
      ]);

      if (!mounted) return;
      AppToast.show(
        context,
        'Certificate is ready to save or share.',
        type: AppToastType.success,
      );
    }
  }

  Widget _buildCompletionBanner({
    required bool certificateUnlocked,
    required int completedSessions,
    required int totalSessions,
    required VoidCallback onCertificateTap,
  }) {
    if (!certificateUnlocked) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF0FDF4), Color(0xFFDCFCE7)],
        ),
        border: Border.all(color: const Color(0xFF86EFAC)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFF22C55E),
              borderRadius: BorderRadius.circular(19),
            ),
            child: const Icon(Icons.check_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Course Complete!',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    color: Color(0xFF166534),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$completedSessions/$totalSessions lessons',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5,
                    color: Color(0xFF22C55E),
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: onCertificateTap,
            icon: const Icon(Icons.workspace_premium_rounded, size: 16),
            label: const Text('Certificate'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF166534),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              textStyle: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModuleMilestoneCard({
    required String moduleLabel,
    required List<_RecordedUnit> moduleUnits,
    required int moduleIndex,
    required Color deepOrange,
    required Color orangeTextStrong,
    required Color deepBlue,
    required Future<void> Function({
      required String moduleLabel,
      required List<_RecordedUnit> moduleUnits,
      required int moduleIndex,
    }) onModuleCertificateTap,
  }) {
    final completed = _isModuleCompleted(moduleUnits);
    if (!completed) return const SizedBox.shrink();
    final moduleActionKey = _moduleCertificateActionKey(
      moduleLabel,
      moduleIndex,
    );
    final generating = _generatingModuleCertificateKeys.contains(
      moduleActionKey,
    );

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: deepOrange,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Milestone • $moduleLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: _kYbsOrangeTextStrong,
                  fontSize: 13.5,
                ),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: completed && !generating
                  ? () => onModuleCertificateTap(
                      moduleLabel: moduleLabel,
                      moduleUnits: moduleUnits,
                      moduleIndex: moduleIndex,
                    )
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: deepBlue,
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFE5E7EB),
                disabledForegroundColor: const Color(0xFF94A3B8),
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              icon: generating
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.download_rounded, size: 15),
              label: Text(generating ? 'Preparing...' : 'Module certificate'),
            ),
          ],
        ),
      ),
    );
  }
}
