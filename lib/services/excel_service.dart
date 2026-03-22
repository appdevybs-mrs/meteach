import 'dart:math';
import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../models/workbook_models.dart';

class ExcelService {
  WorkbookData parseWorkbook({
    required Uint8List bytes,
    required String fileName,
  }) {
    final excel = Excel.decodeBytes(bytes);
    final sheets = <SheetData>[];

    for (final name in excel.tables.keys) {
      final table = excel.tables[name];
      if (table == null) {
        continue;
      }
      final rows = <LearnerRow>[];
      for (var row = 8; row < table.maxRows; row++) {
        final values = table.rows.length > row ? table.rows[row] : <Data?>[];
        final identity = _cell(values, 0);
        final surname = _cell(values, 1);
        final learnerName = _cell(values, 2);
        final matricule = _cell(values, 3);
        final continuous = _number(values, 4);
        final test = _number(values, 5);
        final exam = _number(values, 6);
        final remark = _cell(values, 7);

        final hasData =
            [
              identity,
              surname,
              learnerName,
              matricule,
              remark,
            ].any((v) => v.trim().isNotEmpty) ||
            continuous != null ||
            test != null ||
            exam != null;

        if (!hasData) {
          continue;
        }

        rows.add(
          LearnerRow(
            sheetName: name,
            rowIndex: row,
            identity: identity,
            surname: surname,
            name: learnerName,
            matricule: matricule,
            continuous: continuous,
            test: test,
            exam: exam,
            remark: remark,
          ),
        );
      }
      sheets.add(SheetData(name: name, learners: rows));
    }

    return WorkbookData(
      fileName: fileName,
      originalBytes: bytes,
      sheets: sheets,
      loadedAt: DateTime.now(),
    );
  }

  ExportReport exportWorkbook({
    required WorkbookData workbook,
    required Map<String, String> changedCells,
  }) {
    final excel = Excel.decodeBytes(workbook.originalBytes);
    for (final entry in changedCells.entries) {
      final parts = entry.key.split('|');
      if (parts.length != 3) {
        continue;
      }
      final sheetName = parts[0];
      final row = int.tryParse(parts[1]);
      final col = int.tryParse(parts[2]);
      if (row == null || col == null) {
        continue;
      }
      final table = excel.tables[sheetName];
      if (table == null) {
        continue;
      }
      table
          .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row))
          .value = _cellValueForExport(
        col,
        entry.value,
      );
    }

    final encoded = excel.encode();
    final encodedBytes = Uint8List.fromList(encoded ?? workbook.originalBytes);

    final after = Excel.decodeBytes(encodedBytes);
    final originalNames = workbook.sheets.map((e) => e.name).toList()..sort();
    final afterNames = after.tables.keys.toList()..sort();
    final namesMatch = _equals(originalNames, afterNames);
    final countMatches = originalNames.length == afterNames.length;

    return ExportReport(
      encodedBytes: encodedBytes,
      sheetCountMatches: countMatches,
      sheetNamesMatch: namesMatch,
      message: countMatches && namesMatch
          ? 'Integrity checks passed'
          : 'Integrity checks report differences',
    );
  }

  String suggestRemark(double? score, List<RemarkRule> rules) {
    if (score == null) {
      return '';
    }
    for (final rule in rules) {
      if (rule.matches(score)) {
        return rule.remark;
      }
    }
    return '';
  }

  double randomBetween(double min, double max) {
    final random = Random();
    final range = max - min;
    return ((random.nextDouble() * range) + min);
  }

  String _cell(List<Data?> row, int column) {
    if (column >= row.length) {
      return '';
    }
    final value = row[column]?.value;
    if (value == null) {
      return '';
    }
    return value.toString().trim();
  }

  double? _number(List<Data?> row, int column) {
    if (column >= row.length) {
      return null;
    }
    final value = row[column]?.value;
    if (value == null) {
      return null;
    }
    return double.tryParse(value.toString().replaceAll(',', '.'));
  }

  bool _equals(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  CellValue _cellValueForExport(int columnIndex, String value) {
    if (columnIndex >= 4 && columnIndex <= 6) {
      if (value.trim().isEmpty) {
        return TextCellValue('');
      }
      final parsed = double.tryParse(value.replaceAll(',', '.'));
      if (parsed == null) {
        return TextCellValue(value);
      }
      if (parsed % 1 == 0) {
        return IntCellValue(parsed.toInt());
      }
      return DoubleCellValue(parsed);
    }
    return TextCellValue(value);
  }
}
