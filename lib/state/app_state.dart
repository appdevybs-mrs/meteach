import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/workbook_models.dart';
import '../services/excel_service.dart';
import '../services/validation_service.dart';
import '../theme/theme_palettes.dart';

class MeTeachState extends ChangeNotifier {
  MeTeachState({
    ExcelService? excelService,
    ValidationService? validationService,
  }) : _excelService = excelService ?? ExcelService(),
       _validationService = validationService ?? ValidationService() {
    _remarkRules.addAll(_defaultRemarkRulesForLocale(_locale));
    _favoriteRemarks.addAll(_defaultFavoriteRemarksForLocale(_locale));
    _loadPersistedRecentWorkbooks();
    _loadUiPrefs();
  }

  final ExcelService _excelService;
  final ValidationService _validationService;

  Locale _locale = const Locale('en');
  WorkbookData? _workbook;
  final List<RecentWorkbookEntry> _recentWorkbooks = <RecentWorkbookEntry>[];
  int _selectedSheet = 0;
  LearnerFilter _activeFilter = LearnerFilter.all;
  String _query = '';
  bool _autoRemark = false;
  ValidationSettings _validationSettings = const ValidationSettings();
  final List<RemarkRule> _remarkRules = <RemarkRule>[];
  final List<String> _favoriteRemarks = <String>[];
  bool _hasCustomRemarkRules = false;

  final Map<String, String> _changedCells = <String, String>{};
  final List<Map<String, String>> _changeHistory = <Map<String, String>>[];
  final List<WorkbookSnapshot> _snapshots = <WorkbookSnapshot>[];
  List<RowIssue> _issues = <RowIssue>[];
  bool _busy = false;
  String _lastOperationFeedback = '';
  static const String _recentStorageKey = 'meteach_recent_workbooks_v1';
  static const String _showGuideStorageKey = 'meteach_show_guide_v1';
  static const String _themeStorageKey = 'meteach_theme_v1';
  bool _showGuide = true;
  int _themeIndex = 0;
  bool _versionPopupShown = false;
  String? _processingKey;
  bool _suspendSnapshots = false;
  bool _justOpenedWorkbook = false;
  final List<LogEntry> _logs = <LogEntry>[];
  DateTime? _lastSavedAt;

  Locale get locale => _locale;
  WorkbookData? get workbook => _workbook;
  int get selectedSheet => _selectedSheet;
  LearnerFilter get activeFilter => _activeFilter;
  String get query => _query;
  bool get autoRemark => _autoRemark;
  ValidationSettings get validationSettings => _validationSettings;
  List<RemarkRule> get remarkRules => List.unmodifiable(_remarkRules);
  List<String> get favoriteRemarks => List.unmodifiable(_favoriteRemarks);
  List<RowIssue> get issues => List.unmodifiable(_issues);
  List<WorkbookSnapshot> get snapshots => List.unmodifiable(_snapshots);
  List<RecentWorkbookEntry> get recentWorkbooks =>
      List.unmodifiable(_recentWorkbooks);
  bool get busy => _busy;
  String get lastOperationFeedback => _lastOperationFeedback;
  bool get showGuide => _showGuide;
  int get themeIndex => _themeIndex;
  bool get versionPopupShown => _versionPopupShown;
  String? get processingKey => _processingKey;
  bool get justOpenedWorkbook => _justOpenedWorkbook;
  List<LogEntry> get logs => List.unmodifiable(_logs);
  DateTime? get lastSavedAt => _lastSavedAt;

  bool get hasWorkbook => _workbook != null;

  SheetData? get currentSheet {
    final wb = _workbook;
    if (wb == null || wb.sheets.isEmpty) {
      return null;
    }
    final index = _selectedSheet.clamp(0, wb.sheets.length - 1);
    return wb.sheets[index];
  }

  int get totalEdits => _changedCells.length;

  int get editedRowsCount {
    final rows = _changedCells.keys
        .map((k) => k.split('|'))
        .where((p) => p.length >= 2)
        .map((p) => '${p[0]}|${p[1]}')
        .toSet();
    return rows.length;
  }

  List<LearnerRow> get filteredRows {
    final sheet = currentSheet;
    if (sheet == null) {
      return <LearnerRow>[];
    }
    final q = _query.trim().toLowerCase();
    return sheet.learners.where((row) {
      if (q.isNotEmpty) {
        final matches = [
          row.name,
          row.surname,
          row.matricule,
          row.identity,
          row.remark,
        ].any((v) => v.toLowerCase().contains(q));
        if (!matches) {
          return false;
        }
      }

      switch (_activeFilter) {
        case LearnerFilter.all:
          return true;
        case LearnerFilter.emptyScore:
          return [row.continuous, row.test, row.exam].any((e) => e == null);
        case LearnerFilter.zeroScore:
          return [row.continuous, row.test, row.exam].any((e) => e == 0);
        case LearnerFilter.invalidScore:
          return [row.continuous, row.test, row.exam].whereType<double>().any(
            (e) =>
                e < _validationSettings.minScore ||
                e > _validationSettings.maxScore,
          );
        case LearnerFilter.missingRemark:
          return row.remark.trim().isEmpty;
        case LearnerFilter.editedOnly:
          return _changedCells.keys.any(
            (key) => key.startsWith('${row.sheetName}|${row.rowIndex}|'),
          );
        case LearnerFilter.problemsOnly:
          return _issues.any(
            (issue) =>
                issue.sheetName == row.sheetName &&
                issue.rowIndex == row.rowIndex,
          );
      }
    }).toList();
  }

  Map<String, int> get workbookSummary {
    final wb = _workbook;
    if (wb == null) {
      return {'sheets': 0, 'learners': 0, 'errors': 0, 'warnings': 0};
    }
    final errors = _issues
        .where((i) => i.type != RowIssueType.zeroScore)
        .length;
    final warnings = _issues
        .where((i) => i.type == RowIssueType.zeroScore)
        .length;
    return {
      'sheets': wb.sheets.length,
      'learners': wb.totalLearners,
      'errors': errors,
      'warnings': warnings,
    };
  }

  List<SearchResult> globalSearch(String term) {
    final wb = _workbook;
    if (wb == null || term.trim().isEmpty) {
      return <SearchResult>[];
    }
    final query = term.toLowerCase();
    final results = <SearchResult>[];
    for (var i = 0; i < wb.sheets.length; i++) {
      final sheet = wb.sheets[i];
      for (final row in sheet.learners) {
        final matches = [
          row.identity,
          row.name,
          row.surname,
          row.matricule,
          row.remark,
        ].any((v) => v.toLowerCase().contains(query));
        if (matches) {
          results.add(
            SearchResult(
              sheetIndex: i,
              rowIndex: row.rowIndex,
              sheetName: sheet.name,
              learner: row,
            ),
          );
        }
      }
    }
    return results;
  }

  Future<bool> importWorkbookFromPicker() async {
    _startProcessing('processingImport');
    _busy = true;
    notifyListeners();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['xlsx'],
        withData: false,
      );
      if (result == null || result.files.isEmpty) {
        return false;
      }
      final picked = result.files.first;
      Uint8List? bytes = picked.bytes;
      if (bytes == null || bytes.isEmpty) {
        final path = picked.path;
        if (path == null || path.isEmpty) {
          return false;
        }
        bytes = await File(path).readAsBytes();
      }
      if (bytes.isEmpty) {
        return false;
      }
      final parsed = _excelService.parseWorkbook(
        bytes: Uint8List.fromList(bytes),
        fileName: picked.name,
      );

      _workbook = parsed;
      _selectedSheet = 0;
      _query = '';
      _activeFilter = LearnerFilter.all;
      _changedCells.clear();
      _changeHistory.clear();
      _snapshots.clear();
      _issues = _validationService.validateWorkbook(
        parsed,
        _validationSettings,
        _locale.languageCode,
      );
      _recentWorkbooks.removeWhere((entry) => entry.fileName == picked.name);
      _recentWorkbooks.insert(
        0,
        RecentWorkbookEntry(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          fileName: picked.name,
          displayName: picked.name,
          bytes: Uint8List.fromList(bytes),
          openedAt: DateTime.now(),
        ),
      );
      if (_recentWorkbooks.length > 8) {
        _recentWorkbooks.removeLast();
      }
      _persistRecentWorkbooks();
      _createSnapshot('Original import');
      _addLog('logImport');
      _justOpenedWorkbook = true;
      return true;
    } finally {
      _busy = false;
      _stopProcessing();
      notifyListeners();
    }
  }

  bool reopenRecentWorkbook(int index) {
    _startProcessing('processingReopen');
    if (index < 0 || index >= _recentWorkbooks.length) {
      _stopProcessing();
      return false;
    }
    final recent = _recentWorkbooks
        .removeAt(index)
        .copyWith(openedAt: DateTime.now());
    _recentWorkbooks.insert(0, recent);
    final parsed = _excelService.parseWorkbook(
      bytes: recent.bytes,
      fileName: recent.displayName,
    );
    _workbook = parsed;
    _selectedSheet = 0;
    _query = '';
    _activeFilter = LearnerFilter.all;
    _changedCells.clear();
    _changeHistory.clear();
    _snapshots.clear();
    _issues = _validationService.validateWorkbook(
      parsed,
      _validationSettings,
      _locale.languageCode,
    );
    _createSnapshot('Reopened ${recent.displayName}');
    _addLog('logReopen');
    _justOpenedWorkbook = true;
    _persistRecentWorkbooks();
    notifyListeners();
    _stopProcessing();
    return true;
  }

  void setLocale(Locale locale) {
    _locale = locale;
    if (!_hasCustomRemarkRules) {
      _remarkRules
        ..clear()
        ..addAll(_defaultRemarkRulesForLocale(locale));
      _favoriteRemarks
        ..clear()
        ..addAll(_defaultFavoriteRemarksForLocale(locale));
    }
    runValidation();
  }

  void renameRecentWorkbook(int index, String name) {
    if (index < 0 || index >= _recentWorkbooks.length) {
      return;
    }
    final normalized = name.trim();
    if (normalized.isEmpty) {
      return;
    }
    _recentWorkbooks[index] = _recentWorkbooks[index].copyWith(
      displayName: normalized,
      openedAt: DateTime.now(),
    );
    _persistRecentWorkbooks();
    notifyListeners();
  }

  void deleteRecentWorkbook(int index) {
    if (index < 0 || index >= _recentWorkbooks.length) {
      return;
    }
    _recentWorkbooks.removeAt(index);
    _persistRecentWorkbooks();
    notifyListeners();
  }

  void setSelectedSheet(int index) {
    _selectedSheet = index;
    notifyListeners();
  }

  void setQuery(String query) {
    _query = query;
    notifyListeners();
  }

  void setFilter(LearnerFilter filter) {
    _activeFilter = filter;
    notifyListeners();
  }

  void setAutoRemark(bool enabled) {
    _autoRemark = enabled;
    notifyListeners();
  }

  void updateValidationSettings(ValidationSettings settings) {
    _validationSettings = settings;
    runValidation();
  }

  void runValidation() {
    _startProcessing('processingValidate');
    final wb = _workbook;
    if (wb == null) {
      _issues = <RowIssue>[];
    } else {
      _issues = _validationService.validateWorkbook(
        wb,
        _validationSettings,
        _locale.languageCode,
      );
    }
    _stopProcessing();
    notifyListeners();
  }

  void updateScore({
    required String sheetName,
    required int rowIndex,
    required ScoreColumn column,
    required String value,
  }) {
    final wb = _workbook;
    if (wb == null) {
      return;
    }
    final number = value.trim().isEmpty
        ? null
        : double.tryParse(value.trim().replaceAll(',', '.'));
    final sheet = wb.sheets.firstWhere((s) => s.name == sheetName);
    final pos = sheet.learners.indexWhere((r) => r.rowIndex == rowIndex);
    if (pos == -1) {
      return;
    }
    final current = sheet.learners[pos];
    var updated = current;
    var colIndex = 4;
    if (column == ScoreColumn.continuous) {
      colIndex = 4;
      updated = number == null
          ? updated.copyWith(clearContinuous: true)
          : updated.copyWith(continuous: number);
    } else if (column == ScoreColumn.test) {
      colIndex = 5;
      updated = number == null
          ? updated.copyWith(clearTest: true)
          : updated.copyWith(test: number);
    } else {
      colIndex = 6;
      updated = number == null
          ? updated.copyWith(clearExam: true)
          : updated.copyWith(exam: number);
    }

    if (_autoRemark) {
      final base = updated.scoreFor(column);
      final suggested = _excelService.suggestRemark(base, _remarkRules);
      if (suggested.isNotEmpty) {
        updated = updated.copyWith(remark: suggested);
        _setChangedCell(sheetName, rowIndex, 7, suggested);
      }
    }

    sheet.learners[pos] = updated;
    _setChangedCell(sheetName, rowIndex, colIndex, value.trim());
    runValidation();
  }

  void updateRemark({
    required String sheetName,
    required int rowIndex,
    required String remark,
  }) {
    final wb = _workbook;
    if (wb == null) {
      return;
    }
    final sheet = wb.sheets.firstWhere((s) => s.name == sheetName);
    final pos = sheet.learners.indexWhere((r) => r.rowIndex == rowIndex);
    if (pos == -1) {
      return;
    }
    sheet.learners[pos] = sheet.learners[pos].copyWith(remark: remark);
    _setChangedCell(sheetName, rowIndex, 7, remark);
    runValidation();
  }

  void applyBulkRemark({
    required String remark,
    required bool onlyFiltered,
    ApplyScope scope = ApplyScope.currentSheet,
  }) {
    _startProcessing('processingApply');
    final wb = _workbook;
    if (wb == null || remark.trim().isEmpty) {
      _stopProcessing();
      return;
    }
    final rows = onlyFiltered ? filteredRows : _rowsForScope(scope);
    _withSnapshotSuspended(() {
      for (final row in rows) {
        updateRemark(
          sheetName: row.sheetName,
          rowIndex: row.rowIndex,
          remark: remark,
        );
      }
    });
    _lastOperationFeedback = 'Applied remark to ${rows.length} learners';
    _createSnapshot('Bulk remark');
    _addLog('logBulkRemark');
    _stopProcessing();
  }

  int applyRemarkRules({
    required ApplyScope scope,
    required ScoreSource scoreSource,
  }) {
    _startProcessing('processingApply');
    final rows = _rowsForScope(scope);
    var applied = 0;
    _withSnapshotSuspended(() {
      for (final row in rows) {
        final score = _scoreForSource(row, scoreSource);
        if (score == null) {
          continue;
        }
        final suggestion = _excelService.suggestRemark(score, _remarkRules);
        if (suggestion.isNotEmpty) {
          updateRemark(
            sheetName: row.sheetName,
            rowIndex: row.rowIndex,
            remark: suggestion,
          );
          applied++;
        }
      }
    });
    _lastOperationFeedback = 'Applied rule-based remarks to $applied learners';
    _createSnapshot('Apply remark rules');
    _addLog('logApplyRules');
    _stopProcessing();
    return applied;
  }

  int previewRemarkRulesAffected({
    required ApplyScope scope,
    required ScoreSource scoreSource,
  }) {
    final rows = _rowsForScope(scope);
    var affected = 0;
    for (final row in rows) {
      final score = _scoreForSource(row, scoreSource);
      if (score == null) {
        continue;
      }
      final suggestion = _excelService.suggestRemark(score, _remarkRules);
      if (suggestion.isNotEmpty) {
        affected++;
      }
    }
    return affected;
  }

  void fillEmptyScores(double value) {
    _startProcessing('processingApply');
    final rows = currentSheet?.learners ?? <LearnerRow>[];
    _withSnapshotSuspended(() {
      for (final row in rows) {
        if (row.continuous == null) {
          updateScore(
            sheetName: row.sheetName,
            rowIndex: row.rowIndex,
            column: ScoreColumn.continuous,
            value: value.toStringAsFixed(1),
          );
        }
        if (row.test == null) {
          updateScore(
            sheetName: row.sheetName,
            rowIndex: row.rowIndex,
            column: ScoreColumn.test,
            value: value.toStringAsFixed(1),
          );
        }
        if (row.exam == null) {
          updateScore(
            sheetName: row.sheetName,
            rowIndex: row.rowIndex,
            column: ScoreColumn.exam,
            value: value.toStringAsFixed(1),
          );
        }
      }
    });
    _createSnapshot('Fill empty scores');
    _addLog('logFillEmpty');
    _stopProcessing();
  }

  void setScoreValueForFiltered(double value) {
    _startProcessing('processingApply');
    _withSnapshotSuspended(() {
      for (final row in filteredRows) {
        updateScore(
          sheetName: row.sheetName,
          rowIndex: row.rowIndex,
          column: ScoreColumn.continuous,
          value: value.toStringAsFixed(1),
        );
        updateScore(
          sheetName: row.sheetName,
          rowIndex: row.rowIndex,
          column: ScoreColumn.test,
          value: value.toStringAsFixed(1),
        );
        updateScore(
          sheetName: row.sheetName,
          rowIndex: row.rowIndex,
          column: ScoreColumn.exam,
          value: value.toStringAsFixed(1),
        );
      }
    });
    _createSnapshot('Set score value');
    _addLog('logSetScore');
    _stopProcessing();
  }

  void randomizeScoresForFiltered(double min, double max) {
    _startProcessing('processingApply');
    final random = Random();
    _withSnapshotSuspended(() {
      for (final row in filteredRows) {
        final a = min + random.nextDouble() * (max - min);
        final b = min + random.nextDouble() * (max - min);
        final c = min + random.nextDouble() * (max - min);
        updateScore(
          sheetName: row.sheetName,
          rowIndex: row.rowIndex,
          column: ScoreColumn.continuous,
          value: a.toStringAsFixed(1),
        );
        updateScore(
          sheetName: row.sheetName,
          rowIndex: row.rowIndex,
          column: ScoreColumn.test,
          value: b.toStringAsFixed(1),
        );
        updateScore(
          sheetName: row.sheetName,
          rowIndex: row.rowIndex,
          column: ScoreColumn.exam,
          value: c.toStringAsFixed(1),
        );
      }
    });
    _createSnapshot('Randomize scores');
    _addLog('logRandomize');
    _stopProcessing();
  }

  void clearEditableCellsForCurrentSheet() {
    clearSelectedEditableCellsForCurrentSheet(
      clearContinuous: true,
      clearTest: true,
      clearExam: true,
      clearRemark: true,
    );
  }

  void clearSelectedEditableCellsForCurrentSheet({
    required bool clearContinuous,
    required bool clearTest,
    required bool clearExam,
    required bool clearRemark,
  }) {
    final rows = currentSheet?.learners ?? <LearnerRow>[];
    for (final row in rows) {
      if (clearContinuous) {
        updateScore(
          sheetName: row.sheetName,
          rowIndex: row.rowIndex,
          column: ScoreColumn.continuous,
          value: '',
        );
      }
      if (clearTest) {
        updateScore(
          sheetName: row.sheetName,
          rowIndex: row.rowIndex,
          column: ScoreColumn.test,
          value: '',
        );
      }
      if (clearExam) {
        updateScore(
          sheetName: row.sheetName,
          rowIndex: row.rowIndex,
          column: ScoreColumn.exam,
          value: '',
        );
      }
      if (clearRemark) {
        updateRemark(
          sheetName: row.sheetName,
          rowIndex: row.rowIndex,
          remark: '',
        );
      }
    }
    _createSnapshot('Clear editable cells');
  }

  void resetRow(String sheetName, int rowIndex) {
    _startProcessing('processingReset');
    final wb = _workbook;
    if (wb == null) {
      _stopProcessing();
      return;
    }
    final original = _excelService.parseWorkbook(
      bytes: wb.originalBytes,
      fileName: wb.fileName,
    );
    final sourceSheet = original.sheets.firstWhere((s) => s.name == sheetName);
    final source = sourceSheet.learners.firstWhere(
      (r) => r.rowIndex == rowIndex,
    );
    final targetSheet = wb.sheets.firstWhere((s) => s.name == sheetName);
    final i = targetSheet.learners.indexWhere((r) => r.rowIndex == rowIndex);
    if (i != -1) {
      targetSheet.learners[i] = source;
      _changedCells.remove('$sheetName|$rowIndex|4');
      _changedCells.remove('$sheetName|$rowIndex|5');
      _changedCells.remove('$sheetName|$rowIndex|6');
      _changedCells.remove('$sheetName|$rowIndex|7');
      runValidation();
    }
    _addLog('logResetRow');
    _stopProcessing();
  }

  void resetCurrentSheet() {
    _startProcessing('processingReset');
    final sheet = currentSheet;
    if (sheet == null) {
      _stopProcessing();
      return;
    }
    _withSnapshotSuspended(() {
      for (final row in List<LearnerRow>.from(sheet.learners)) {
        resetRow(sheet.name, row.rowIndex);
      }
    });
    _createSnapshot('Reset sheet');
    _addLog('logResetSheet');
    _stopProcessing();
  }

  void restoreWorkbook() {
    _startProcessing('processingRestore');
    final wb = _workbook;
    if (wb == null) {
      _stopProcessing();
      return;
    }
    _workbook = _excelService.parseWorkbook(
      bytes: wb.originalBytes,
      fileName: wb.fileName,
    );
    _changedCells.clear();
    _changeHistory.clear();
    runValidation();
    _createSnapshot('Restore workbook');
    _addLog('logRestore');
    _stopProcessing();
  }

  void undoLast() {
    if (_changeHistory.isEmpty) {
      return;
    }
    final last = _changeHistory.removeLast();
    for (final entry in last.entries) {
      if (entry.value.isEmpty) {
        _changedCells.remove(entry.key);
      } else {
        _changedCells[entry.key] = entry.value;
      }

      final parts = entry.key.split('|');
      if (parts.length != 3) {
        continue;
      }
      final sheetName = parts[0];
      final rowIndex = int.tryParse(parts[1]);
      final col = int.tryParse(parts[2]);
      if (rowIndex == null || col == null) {
        continue;
      }
      final wb = _workbook;
      if (wb == null) {
        continue;
      }
      final sheet = wb.sheets.firstWhere((s) => s.name == sheetName);
      final idx = sheet.learners.indexWhere((row) => row.rowIndex == rowIndex);
      if (idx == -1) {
        continue;
      }
      var row = sheet.learners[idx];
      if (col == 4) {
        row = entry.value.isEmpty
            ? row.copyWith(clearContinuous: true)
            : row.copyWith(continuous: double.tryParse(entry.value));
      } else if (col == 5) {
        row = entry.value.isEmpty
            ? row.copyWith(clearTest: true)
            : row.copyWith(test: double.tryParse(entry.value));
      } else if (col == 6) {
        row = entry.value.isEmpty
            ? row.copyWith(clearExam: true)
            : row.copyWith(exam: double.tryParse(entry.value));
      } else if (col == 7) {
        row = row.copyWith(remark: entry.value);
      }
      sheet.learners[idx] = row;
    }
    runValidation();
    _addLog('logUndo');
  }

  void addFavoriteRemark(String remark) {
    final normalized = remark.trim();
    if (normalized.isEmpty) {
      return;
    }
    _favoriteRemarks.remove(normalized);
    _favoriteRemarks.insert(0, normalized);
    notifyListeners();
  }

  void addRemarkRule(RemarkRule rule) {
    _remarkRules.add(rule);
    _remarkRules.sort((a, b) => a.min.compareTo(b.min));
    _hasCustomRemarkRules = true;
    notifyListeners();
  }

  void updateRemarkRule(int index, RemarkRule rule) {
    if (index < 0 || index >= _remarkRules.length) {
      return;
    }
    _remarkRules[index] = rule;
    _remarkRules.sort((a, b) => a.min.compareTo(b.min));
    _hasCustomRemarkRules = true;
    notifyListeners();
  }

  void deleteRemarkRule(int index) {
    if (index < 0 || index >= _remarkRules.length) {
      return;
    }
    _remarkRules.removeAt(index);
    _hasCustomRemarkRules = true;
    notifyListeners();
  }

  void saveProgressCheckpoint([String label = 'Manual save']) {
    _startProcessing('processingSave');
    _lastOperationFeedback = 'Progress saved';
    _createSnapshot(label);
    createEditableBackupCopy();
    _addLog('logSave');
    _stopProcessing();
  }

  void createEditableBackupCopy() {
    final wb = _workbook;
    if (wb == null) {
      return;
    }
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    final backupName = '${wb.fileName}_backup_$ts';
    final report = _excelService.exportWorkbook(
      workbook: wb,
      changedCells: _changedCells,
    );
    _recentWorkbooks.insert(
      0,
      RecentWorkbookEntry(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        fileName: wb.fileName,
        displayName: backupName,
        bytes: report.encodedBytes,
        openedAt: DateTime.now(),
      ),
    );
    if (_recentWorkbooks.length > 8) {
      _recentWorkbooks.removeLast();
    }
    _persistRecentWorkbooks();
    notifyListeners();
  }

  Future<ExportReport?> exportWorkbook() async {
    _startProcessing('processingExport');
    final wb = _workbook;
    if (wb == null) {
      _stopProcessing();
      return null;
    }
    final report = _excelService.exportWorkbook(
      workbook: wb,
      changedCells: _changedCells,
    );
    final exportName = _normalizeXlsxFileName(wb.fileName);
    final baseName = exportName.substring(0, exportName.length - 5);
    final savedPath = await FileSaver.instance.saveFile(
      name: baseName,
      bytes: report.encodedBytes,
      fileExtension: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );
    _createSnapshot('Exported $exportName');
    createEditableBackupCopy();
    _addLog('logExport');
    _stopProcessing();
    return ExportReport(
      encodedBytes: report.encodedBytes,
      sheetCountMatches: report.sheetCountMatches,
      sheetNamesMatch: report.sheetNamesMatch,
      message: report.message,
      savedPath: savedPath,
      exportedFileName: exportName,
    );
  }

  String _normalizeXlsxFileName(String fileName) {
    final normalized = fileName.trim().isEmpty
        ? 'workbook.xlsx'
        : fileName.trim();
    if (normalized.toLowerCase().endsWith('.xlsx')) {
      return normalized;
    }
    return '$normalized.xlsx';
  }

  Future<void> _loadPersistedRecentWorkbooks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recentStorageKey);
    if (raw == null || raw.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        return;
      }
      final loaded = <RecentWorkbookEntry>[];
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) {
          continue;
        }
        final bytesStr = item['bytes'] as String?;
        if (bytesStr == null) {
          continue;
        }
        loaded.add(
          RecentWorkbookEntry(
            id:
                (item['id'] as String?) ??
                DateTime.now().microsecondsSinceEpoch.toString(),
            fileName: (item['fileName'] as String?) ?? 'workbook.xlsx',
            displayName:
                (item['displayName'] as String?) ??
                (item['fileName'] as String?) ??
                'workbook.xlsx',
            bytes: base64Decode(bytesStr),
            openedAt:
                DateTime.tryParse((item['openedAt'] as String?) ?? '') ??
                DateTime.now(),
          ),
        );
      }
      _recentWorkbooks
        ..clear()
        ..addAll(loaded);
      notifyListeners();
    } catch (_) {
      return;
    }
  }

  Future<void> _persistRecentWorkbooks() async {
    final prefs = await SharedPreferences.getInstance();
    final capped = _recentWorkbooks.take(6).toList();
    final encoded = capped
        .map(
          (entry) => <String, dynamic>{
            'id': entry.id,
            'fileName': entry.fileName,
            'displayName': entry.displayName,
            'openedAt': entry.openedAt.toIso8601String(),
            'bytes': base64Encode(entry.bytes),
          },
        )
        .toList();
    await prefs.setString(_recentStorageKey, jsonEncode(encoded));
  }

  Future<void> _loadUiPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _showGuide = prefs.getBool(_showGuideStorageKey) ?? true;
    final storedTheme = prefs.getInt(_themeStorageKey) ?? 0;
    _themeIndex = storedTheme.clamp(0, themePalettes.length - 1);
    notifyListeners();
  }

  Future<void> setShowGuide(bool value) async {
    _showGuide = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showGuideStorageKey, value);
  }

  Future<void> setThemeIndex(int index) async {
    final safeIndex = index.clamp(0, themePalettes.length - 1);
    if (safeIndex == _themeIndex) {
      return;
    }
    _themeIndex = safeIndex;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_themeStorageKey, _themeIndex);
  }

  void markVersionPopupShown() {
    _versionPopupShown = true;
  }

  void consumeJustOpened() {
    _justOpenedWorkbook = false;
  }

  List<RemarkRule> _defaultRemarkRulesForLocale(Locale locale) {
    switch (locale.languageCode) {
      case 'fr':
        return const [
          RemarkRule(min: 0, max: 4, remark: 'Insuffisant'),
          RemarkRule(min: 5, max: 10, remark: 'Peut mieux faire'),
          RemarkRule(min: 11, max: 15, remark: 'Bien'),
          RemarkRule(min: 16, max: 20, remark: 'Excellent'),
        ];
      case 'ar':
        return const [
          RemarkRule(min: 0, max: 4, remark: 'ضعيف'),
          RemarkRule(min: 5, max: 10, remark: 'يمكنك التحسن'),
          RemarkRule(min: 11, max: 15, remark: 'جيد'),
          RemarkRule(min: 16, max: 20, remark: 'ممتاز'),
        ];
      case 'de':
        return const [
          RemarkRule(min: 0, max: 4, remark: 'Schwach'),
          RemarkRule(min: 5, max: 10, remark: 'Kann besser werden'),
          RemarkRule(min: 11, max: 15, remark: 'Gut'),
          RemarkRule(min: 16, max: 20, remark: 'Ausgezeichnet'),
        ];
      case 'es':
        return const [
          RemarkRule(min: 0, max: 4, remark: 'Insuficiente'),
          RemarkRule(min: 5, max: 10, remark: 'Puede mejorar'),
          RemarkRule(min: 11, max: 15, remark: 'Bien'),
          RemarkRule(min: 16, max: 20, remark: 'Excelente'),
        ];
      case 'it':
        return const [
          RemarkRule(min: 0, max: 4, remark: 'Insufficiente'),
          RemarkRule(min: 5, max: 10, remark: 'Puo migliorare'),
          RemarkRule(min: 11, max: 15, remark: 'Buono'),
          RemarkRule(min: 16, max: 20, remark: 'Eccellente'),
        ];
      default:
        return const [
          RemarkRule(min: 0, max: 4, remark: 'Bad'),
          RemarkRule(min: 5, max: 10, remark: 'Can do better'),
          RemarkRule(min: 11, max: 15, remark: 'Good'),
          RemarkRule(min: 16, max: 20, remark: 'Excellent'),
        ];
    }
  }

  List<String> _defaultFavoriteRemarksForLocale(Locale locale) {
    switch (locale.languageCode) {
      case 'fr':
        return const [
          'Excellent travail',
          'Bon effort',
          'A ameliorer',
          'Absent',
        ];
      case 'ar':
        return const ['عمل ممتاز', 'مجهود جيد', 'يحتاج تحسين', 'غائب'];
      case 'de':
        return const [
          'Ausgezeichnete Arbeit',
          'Gute Leistung',
          'Verbesserung notig',
          'Abwesend',
        ];
      case 'es':
        return const [
          'Excelente trabajo',
          'Buen esfuerzo',
          'Necesita mejorar',
          'Ausente',
        ];
      case 'it':
        return const [
          'Lavoro eccellente',
          'Buon impegno',
          'Da migliorare',
          'Assente',
        ];
      default:
        return const [
          'Excellent work',
          'Good effort',
          'Needs improvement',
          'Absent',
        ];
    }
  }

  double? _avgScore(LearnerRow row) {
    final values = [
      row.continuous,
      row.test,
      row.exam,
    ].whereType<double>().toList();
    if (values.isEmpty) {
      return null;
    }
    return values.reduce((a, b) => a + b) / values.length;
  }

  List<LearnerRow> _rowsForScope(ApplyScope scope) {
    final wb = _workbook;
    if (wb == null) {
      return <LearnerRow>[];
    }
    switch (scope) {
      case ApplyScope.filteredRows:
        return filteredRows;
      case ApplyScope.currentSheet:
        return currentSheet?.learners ?? <LearnerRow>[];
      case ApplyScope.allSheets:
        return wb.sheets.expand((s) => s.learners).toList();
    }
  }

  double? _scoreForSource(LearnerRow row, ScoreSource source) {
    switch (source) {
      case ScoreSource.continuous:
        return row.continuous;
      case ScoreSource.test:
        return row.test;
      case ScoreSource.exam:
        return row.exam;
      case ScoreSource.average:
        return _avgScore(row);
    }
  }

  void _setChangedCell(
    String sheetName,
    int rowIndex,
    int colIndex,
    String value,
  ) {
    final key = '$sheetName|$rowIndex|$colIndex';
    final previous = _changedCells[key] ?? '';
    _changeHistory.add(<String, String>{key: previous});
    _changedCells[key] = value;
    if (!_suspendSnapshots) {
      _createSnapshot('Edit $sheetName #${rowIndex + 1}');
      _addLog('logEditCell', {'sheet': sheetName, 'row': '${rowIndex + 1}'});
    }
    notifyListeners();
  }

  void _withSnapshotSuspended(VoidCallback action) {
    final previous = _suspendSnapshots;
    _suspendSnapshots = true;
    action();
    _suspendSnapshots = previous;
  }

  void _createSnapshot(String label) {
    _lastSavedAt = DateTime.now();
    _snapshots.add(
      WorkbookSnapshot(
        label: label,
        createdAt: _lastSavedAt!,
        changedCells: Map<String, String>.from(_changedCells),
      ),
    );
    notifyListeners();
  }

  void restoreSnapshot(int index) {
    if (index < 0 || index >= _snapshots.length) {
      return;
    }
    final wb = _workbook;
    if (wb == null) {
      return;
    }
    _startProcessing('processingRestore');
    final snapshot = _snapshots[index];
    final restored = _excelService.parseWorkbook(
      bytes: wb.originalBytes,
      fileName: wb.fileName,
    );
    _workbook = restored;
    _changedCells
      ..clear()
      ..addAll(snapshot.changedCells);
    _applyChangedCells(snapshot.changedCells);
    runValidation();
    _createSnapshot('Restore to ${snapshot.label}');
    _addLog('logRestoreSnapshot', {'label': snapshot.label});
    _stopProcessing();
    notifyListeners();
  }

  void _applyChangedCells(Map<String, String> changes) {
    final wb = _workbook;
    if (wb == null) {
      return;
    }
    for (final entry in changes.entries) {
      final parts = entry.key.split('|');
      if (parts.length != 3) {
        continue;
      }
      final sheetName = parts[0];
      final rowIndex = int.tryParse(parts[1]);
      final colIndex = int.tryParse(parts[2]);
      if (rowIndex == null || colIndex == null) {
        continue;
      }
      final sheet = wb.sheets.firstWhere((s) => s.name == sheetName);
      final pos = sheet.learners.indexWhere((r) => r.rowIndex == rowIndex);
      if (pos == -1) {
        continue;
      }
      final row = sheet.learners[pos];
      final value = entry.value;
      if (colIndex == 4) {
        sheet.learners[pos] = value.trim().isEmpty
            ? row.copyWith(clearContinuous: true)
            : row.copyWith(continuous: double.tryParse(value));
      } else if (colIndex == 5) {
        sheet.learners[pos] = value.trim().isEmpty
            ? row.copyWith(clearTest: true)
            : row.copyWith(test: double.tryParse(value));
      } else if (colIndex == 6) {
        sheet.learners[pos] = value.trim().isEmpty
            ? row.copyWith(clearExam: true)
            : row.copyWith(exam: double.tryParse(value));
      } else if (colIndex == 7) {
        sheet.learners[pos] = row.copyWith(remark: value);
      }
    }
  }

  void _startProcessing(String key) {
    if (_processingKey != null) {
      return;
    }
    _processingKey = key;
    notifyListeners();
  }

  void _stopProcessing() {
    _processingKey = null;
    notifyListeners();
  }

  void _addLog(String key, [Map<String, String> values = const {}]) {
    _logs.insert(
      0,
      LogEntry(key: key, timestamp: DateTime.now(), values: values),
    );
  }
}

class LogEntry {
  LogEntry({
    required this.key,
    required this.timestamp,
    this.values = const {},
  });

  final String key;
  final DateTime timestamp;
  final Map<String, String> values;
}
