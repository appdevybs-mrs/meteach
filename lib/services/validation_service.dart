import '../models/workbook_models.dart';

class ValidationService {
  List<RowIssue> validateWorkbook(
    WorkbookData workbook,
    ValidationSettings settings,
  ) {
    final issues = <RowIssue>[];
    for (final sheet in workbook.sheets) {
      for (final row in sheet.learners) {
        final scores = [row.continuous, row.test, row.exam];
        for (final score in scores) {
          if (score == null) {
            issues.add(
              RowIssue(
                sheetName: sheet.name,
                rowIndex: row.rowIndex,
                type: RowIssueType.emptyScore,
                message: 'Missing score',
              ),
            );
            continue;
          }
          if (!settings.zeroValid && score == 0) {
            issues.add(
              RowIssue(
                sheetName: sheet.name,
                rowIndex: row.rowIndex,
                type: RowIssueType.zeroScore,
                message: 'Zero score is not allowed',
              ),
            );
          }
          if (score < settings.minScore || score > settings.maxScore) {
            issues.add(
              RowIssue(
                sheetName: sheet.name,
                rowIndex: row.rowIndex,
                type: RowIssueType.outOfRange,
                message:
                    'Score $score outside ${settings.minScore}-${settings.maxScore}',
              ),
            );
          }
        }

        if (settings.remarkRequired && row.remark.trim().isEmpty) {
          issues.add(
            RowIssue(
              sheetName: sheet.name,
              rowIndex: row.rowIndex,
              type: RowIssueType.missingRemark,
              message: 'Missing remark',
            ),
          );
        }

        if (_looksInconsistent(row)) {
          issues.add(
            RowIssue(
              sheetName: sheet.name,
              rowIndex: row.rowIndex,
              type: RowIssueType.inconsistentRemark,
              message: 'Score and remark look inconsistent',
            ),
          );
        }

        if (row.name.trim().isEmpty && row.surname.trim().isEmpty) {
          issues.add(
            RowIssue(
              sheetName: sheet.name,
              rowIndex: row.rowIndex,
              type: RowIssueType.incompleteRow,
              message: 'Missing learner identity',
            ),
          );
        }
      }
    }

    return issues;
  }

  bool _looksInconsistent(LearnerRow row) {
    final score = [
      row.continuous,
      row.test,
      row.exam,
    ].whereType<double>().fold<double>(0, (a, b) => a + b);
    final count = [
      row.continuous,
      row.test,
      row.exam,
    ].whereType<double>().length;
    if (count == 0) {
      return false;
    }
    final avg = score / count;
    final text = row.remark.toLowerCase();
    final negative = ['bad', 'poor', 'weak', 'insuffisant', 'ضعيف'];
    final positive = ['excellent', 'good', 'great', 'bravo', 'ممتاز'];
    final hasNegative = negative.any(text.contains);
    final hasPositive = positive.any(text.contains);

    if (avg >= 16 && hasNegative) {
      return true;
    }
    if (avg <= 5 && hasPositive) {
      return true;
    }
    return false;
  }
}
