import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

class AdminFinanceLedgerScreen extends StatefulWidget {
  const AdminFinanceLedgerScreen({super.key});

  @override
  State<AdminFinanceLedgerScreen> createState() =>
      _AdminFinanceLedgerScreenState();
}

class _AdminFinanceLedgerScreenState extends State<AdminFinanceLedgerScreen> {
  final DatabaseReference _ledgerRef = FirebaseDatabase.instance.ref(
    'finance_ledger',
  );

  static const List<Color> _cardPalette = [
    Color(0xFFEAF2FF),
    Color(0xFFE9F7F1),
    Color(0xFFFFF2DF),
    Color(0xFFFFE9EC),
    Color(0xFFF1EEFF),
    Color(0xFFEAF7FF),
    Color(0xFFF6F5F2),
    Color(0xFFEFF5D9),
  ];
  static const Color _defaultCardColor = Color(0xFFEAF2FF);

  @override
  void dispose() {
    super.dispose();
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    final raw = v.toString().trim();
    if (raw.isEmpty) return 0;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9-]'), '');
    if (cleaned.isEmpty || cleaned == '-') return 0;
    return int.tryParse(cleaned) ?? 0;
  }

  String _money(int amount) {
    final neg = amount < 0;
    final s = (neg ? -amount : amount).toString();
    final out = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final posFromEnd = s.length - i;
      out.write(s[i]);
      if (posFromEnd > 1 && posFromEnd % 3 == 1) out.write(' ');
    }
    return '${neg ? '-' : ''}${out.toString()} DA';
  }

  String _fmtDate(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _colorToHex(Color color) {
    final rgb = color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2);
    return '#${rgb.toUpperCase()}';
  }

  static Color _parseCardColor(dynamic raw) {
    if (raw == null) return _defaultCardColor;
    final text = raw.toString().trim();
    if (text.isEmpty) return _defaultCardColor;
    var cleaned = text.replaceFirst('#', '');
    if (cleaned.length == 6) cleaned = 'FF$cleaned';
    if (cleaned.length != 8) return _defaultCardColor;
    final value = int.tryParse(cleaned, radix: 16);
    if (value == null) return _defaultCardColor;
    return Color(value);
  }

  static Color _onCardColor(Color bg) {
    return bg.computeLuminance() > 0.58
        ? const Color(0xFF1A2B48)
        : Colors.white;
  }

  Map<String, dynamic> _buildLedgerEntryPayload({
    required String title,
    required String amountText,
    required String note,
    required Color selectedColor,
  }) {
    return <String, dynamic>{
      'title': title,
      'amount': _asInt(amountText),
      'note': note,
      'cardColor': _colorToHex(selectedColor),
      'createdAt': ServerValue.timestamp,
      'updatedAt': ServerValue.timestamp,
      'createdBy': 'admin',
    };
  }

  Future<void> _openAddEntryDialog() async {
    final titleCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    var selectedColor = _defaultCardColor;

    try {
      final payload = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (dialogCtx) {
          return StatefulBuilder(
            builder: (context, setD) {
              return AlertDialog(
                title: const Text('Add ledger card'),
                scrollable: true,
                content: SizedBox(
                  width: 430,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: titleCtrl,
                        decoration: const InputDecoration(labelText: 'Title'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: amountCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Amount'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: noteCtrl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Note (optional)',
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Card color',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _cardPalette
                            .map(
                              (c) => _LedgerColorDot(
                                color: c,
                                selected:
                                    c.toARGB32() == selectedColor.toARGB32(),
                                onTap: () => setD(() => selectedColor = c),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton.icon(
                    onPressed: () {
                      final title = titleCtrl.text.trim();
                      if (title.isEmpty) return;
                      Navigator.of(dialogCtx).pop(
                        _buildLedgerEntryPayload(
                          title: title,
                          amountText: amountCtrl.text,
                          note: noteCtrl.text.trim(),
                          selectedColor: selectedColor,
                        ),
                      );
                    },
                    icon: const Icon(Icons.add_card_rounded),
                    label: const Text('Add card'),
                  ),
                ],
              );
            },
          );
        },
      );

      if (payload == null) return;
      final ref = _ledgerRef.push();
      await ref.set(payload);
    } finally {
      titleCtrl.dispose();
      amountCtrl.dispose();
      noteCtrl.dispose();
    }
  }

  Future<void> _editEntry({
    required String entryId,
    required Map<String, dynamic> row,
  }) async {
    final titleCtrl = TextEditingController(
      text: (row['title'] ?? '').toString().trim(),
    );
    final amountCtrl = TextEditingController(
      text: _asInt(row['amount']).toString(),
    );
    final noteCtrl = TextEditingController(
      text: (row['note'] ?? '').toString().trim(),
    );
    var selectedColor = _parseCardColor(row['cardColor']);

    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) {
          return StatefulBuilder(
            builder: (context, setD) => AlertDialog(
              title: const Text('Edit ledger card'),
              scrollable: true,
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(labelText: 'Title'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: amountCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Amount'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: noteCtrl,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Note (optional)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Card color',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _cardPalette
                          .map(
                            (c) => _LedgerColorDot(
                              color: c,
                              selected:
                                  c.toARGB32() == selectedColor.toARGB32(),
                              onTap: () => setD(() => selectedColor = c),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    if (titleCtrl.text.trim().isEmpty) return;
                    Navigator.of(dialogCtx).pop(true);
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          );
        },
      );

      if (ok != true) return;

      await _ledgerRef.child(entryId).update({
        'title': titleCtrl.text.trim(),
        'amount': _asInt(amountCtrl.text),
        'note': noteCtrl.text.trim(),
        'cardColor': _colorToHex(selectedColor),
        'updatedAt': ServerValue.timestamp,
      });
    } finally {
      titleCtrl.dispose();
      amountCtrl.dispose();
      noteCtrl.dispose();
    }
  }

  Future<void> _openNoteDialog({
    required String title,
    required String note,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: Text(title.isEmpty ? 'Ledger note' : title),
          content: Text(note.isEmpty ? 'No note for this card.' : note),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteEntry(String entryId) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: const Text('Delete note?'),
          content: const Text('This will permanently delete this ledger note.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (yes != true) return;
    await _ledgerRef.child(entryId).remove();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: Color(0xFF1A2B48)),
        title: const Text(
          'Finance Ledger',
          style: TextStyle(
            color: Color(0xFF1A2B48),
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Add ledger card',
            onPressed: _openAddEntryDialog,
            icon: const Icon(Icons.add_card_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _ledgerRef.orderByChild('createdAt').limitToLast(5000).onValue,
        builder: (context, snapshot) {
          final rows = <Map<String, dynamic>>[];
          final raw = snapshot.data?.snapshot.value;
          if (raw is Map) {
            raw.forEach((k, v) {
              if (v is! Map) return;
              final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
              m['entryId'] = k.toString();
              rows.add(m.cast<String, dynamic>());
            });
          }
          rows.sort(
            (a, b) => _asInt(b['createdAt']).compareTo(_asInt(a['createdAt'])),
          );

          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final crossAxisCount = width < 560
                  ? 2
                  : width < 900
                  ? 3
                  : width < 1250
                  ? 4
                  : 5;

              if (rows.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: Colors.black.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'No ledger cards yet.',
                              style: TextStyle(
                                color: Color(0xFF1A2B48),
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              onPressed: _openAddEntryDialog,
                              icon: const Icon(Icons.add_card_rounded),
                              label: const Text('Add first card'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }

              return GridView.builder(
                padding: EdgeInsets.fromLTRB(
                  12,
                  12,
                  12,
                  20 + MediaQuery.of(context).padding.bottom,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.06,
                ),
                itemCount: rows.length,
                itemBuilder: (context, i) {
                  final row = rows[i];
                  final entryId = (row['entryId'] ?? '').toString().trim();
                  final title = (row['title'] ?? '').toString().trim();
                  final amount = _asInt(row['amount']);
                  final note = (row['note'] ?? '').toString().trim();
                  final date = _fmtDate(_asInt(row['createdAt']));
                  final bg = _parseCardColor(row['cardColor']);
                  final fg = _onCardColor(bg);
                  final border = fg.withValues(alpha: 0.24);

                  return Container(
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title.isEmpty ? '(No title)' : title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: fg,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 14,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: note.isEmpty ? 'No note' : 'Open note',
                                onPressed: () =>
                                    _openNoteDialog(title: title, note: note),
                                icon: Text(
                                  '!',
                                  style: TextStyle(
                                    color: fg,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 18,
                                  ),
                                ),
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 28,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _money(amount),
                            style: TextStyle(
                              color: fg,
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            date,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: fg.withValues(alpha: 0.86),
                              fontWeight: FontWeight.w700,
                              fontSize: 11.8,
                            ),
                          ),
                          const Spacer(),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  note.isEmpty ? 'No note' : 'Has note',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: fg.withValues(alpha: 0.78),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Edit card',
                                onPressed: entryId.isEmpty
                                    ? null
                                    : () => _editEntry(
                                        entryId: entryId,
                                        row: row,
                                      ),
                                icon: Icon(Icons.edit_rounded, color: fg),
                                visualDensity: VisualDensity.compact,
                              ),
                              IconButton(
                                tooltip: 'Delete card',
                                onPressed: entryId.isEmpty
                                    ? null
                                    : () => _deleteEntry(entryId),
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  color: fg.withValues(alpha: 0.92),
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddEntryDialog,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add card'),
      ),
    );
  }
}

class _LedgerColorDot extends StatelessWidget {
  const _LedgerColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? const Color(0xFF1A2B48) : Colors.black26,
            width: selected ? 2.2 : 1,
          ),
        ),
        child: selected
            ? const Icon(
                Icons.check_rounded,
                size: 16,
                color: Color(0xFF1A2B48),
              )
            : null,
      ),
    );
  }
}
