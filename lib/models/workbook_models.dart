import 'dart:typed_data';

enum ScoreColumn { continuous, test, exam }

enum ScoreSource { continuous, test, exam, average }

enum ApplyScope { filteredRows, currentSheet, allSheets }

enum RowIssueType {
  emptyScore,
  zeroScore,
  invalidScore,
  outOfRange,
  missingRemark,
  inconsistentRemark,
  incompleteRow,
}

enum LearnerFilter {
  all,
  emptyScore,
  zeroScore,
  invalidScore,
  missingRemark,
  editedOnly,
  problemsOnly,
}

class LearnerRow {
  LearnerRow({
    required this.sheetName,
    required this.rowIndex,
    required this.identity,
    required this.surname,
    required this.name,
    required this.matricule,
    required this.continuous,
    required this.test,
    required this.exam,
    required this.remark,
  });

  final String sheetName;
  final int rowIndex;
  final String identity;
  final String surname;
  final String name;
  final String matricule;
  final double? continuous;
  final double? test;
  final double? exam;
  final String remark;

  double? scoreFor(ScoreColumn column) {
    switch (column) {
      case ScoreColumn.continuous:
        return continuous;
      case ScoreColumn.test:
        return test;
      case ScoreColumn.exam:
        return exam;
    }
  }

  LearnerRow copyWith({
    String? identity,
    String? surname,
    String? name,
    String? matricule,
    double? continuous,
    bool clearContinuous = false,
    double? test,
    bool clearTest = false,
    double? exam,
    bool clearExam = false,
    String? remark,
  }) {
    return LearnerRow(
      sheetName: sheetName,
      rowIndex: rowIndex,
      identity: identity ?? this.identity,
      surname: surname ?? this.surname,
      name: name ?? this.name,
      matricule: matricule ?? this.matricule,
      continuous: clearContinuous ? null : (continuous ?? this.continuous),
      test: clearTest ? null : (test ?? this.test),
      exam: clearExam ? null : (exam ?? this.exam),
      remark: remark ?? this.remark,
    );
  }

  bool get hasAnyScore => continuous != null || test != null || exam != null;
}

class SheetData {
  SheetData({required this.name, required this.learners});

  final String name;
  final List<LearnerRow> learners;

  int get learnerCount => learners.length;
}

class WorkbookData {
  WorkbookData({
    required this.fileName,
    required this.originalBytes,
    required this.sheets,
    required this.loadedAt,
  });

  final String fileName;
  final Uint8List originalBytes;
  final List<SheetData> sheets;
  final DateTime loadedAt;

  int get totalLearners =>
      sheets.fold<int>(0, (sum, sheet) => sum + sheet.learners.length);
}

class RemarkRule {
  const RemarkRule({
    required this.min,
    required this.max,
    required this.remark,
  });

  final double min;
  final double max;
  final String remark;

  bool matches(double score) => score >= min && score <= max;
}

class ValidationSettings {
  const ValidationSettings({
    this.minScore = 0,
    this.maxScore = 20,
    this.zeroValid = true,
    this.remarkRequired = false,
  });

  final double minScore;
  final double maxScore;
  final bool zeroValid;
  final bool remarkRequired;

  ValidationSettings copyWith({
    double? minScore,
    double? maxScore,
    bool? zeroValid,
    bool? remarkRequired,
  }) {
    return ValidationSettings(
      minScore: minScore ?? this.minScore,
      maxScore: maxScore ?? this.maxScore,
      zeroValid: zeroValid ?? this.zeroValid,
      remarkRequired: remarkRequired ?? this.remarkRequired,
    );
  }
}

class RowIssue {
  const RowIssue({
    required this.sheetName,
    required this.rowIndex,
    required this.type,
    required this.message,
  });

  final String sheetName;
  final int rowIndex;
  final RowIssueType type;
  final String message;
}

class SearchResult {
  const SearchResult({
    required this.sheetIndex,
    required this.rowIndex,
    required this.sheetName,
    required this.learner,
  });

  final int sheetIndex;
  final int rowIndex;
  final String sheetName;
  final LearnerRow learner;
}

class ExportReport {
  const ExportReport({
    required this.encodedBytes,
    required this.sheetCountMatches,
    required this.sheetNamesMatch,
    required this.message,
    this.savedPath = '',
    this.exportedFileName = 'workbook.xlsx',
  });

  final Uint8List encodedBytes;
  final bool sheetCountMatches;
  final bool sheetNamesMatch;
  final String message;
  final String savedPath;
  final String exportedFileName;

  bool get isSafe => sheetCountMatches && sheetNamesMatch;
}

class WorkbookSnapshot {
  const WorkbookSnapshot({
    required this.label,
    required this.createdAt,
    required this.changedCells,
  });

  final String label;
  final DateTime createdAt;
  final Map<String, String> changedCells;
}

class RecentWorkbookEntry {
  const RecentWorkbookEntry({
    required this.id,
    required this.fileName,
    required this.displayName,
    required this.bytes,
    required this.openedAt,
  });

  final String id;
  final String fileName;
  final String displayName;
  final Uint8List bytes;
  final DateTime openedAt;

  RecentWorkbookEntry copyWith({String? displayName, DateTime? openedAt}) {
    return RecentWorkbookEntry(
      id: id,
      fileName: fileName,
      displayName: displayName ?? this.displayName,
      bytes: bytes,
      openedAt: openedAt ?? this.openedAt,
    );
  }
}
