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

  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _noteCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _amountCtrl.dispose();
    _noteCtrl.dispose();
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

  Future<void> _saveEntry() async {
    final title = _titleCtrl.text.trim();
    final amount = _asInt(_amountCtrl.text);
    final note = _noteCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Title is required.')));
      return;
    }

    setState(() => _saving = true);
    try {
      final ref = _ledgerRef.push();
      await ref.set({
        'title': title,
        'amount': amount,
        'note': note,
        'createdAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
        'createdBy': 'admin',
      });
      if (!mounted) return;
      _titleCtrl.clear();
      _amountCtrl.clear();
      _noteCtrl.clear();
      FocusScope.of(context).unfocus();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Ledger note saved.')));
    } finally {
      if (mounted) setState(() => _saving = false);
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

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        final insets = MediaQuery.of(dialogCtx).viewInsets;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: insets.bottom),
          child: AlertDialog(
            title: const Text('Edit ledger note'),
            scrollable: true,
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
      'updatedAt': ServerValue.timestamp,
    });
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

          return ListView(
            padding: EdgeInsets.fromLTRB(
              12,
              12,
              12,
              20 + MediaQuery.of(context).padding.bottom,
            ),
            children: [
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Quick note',
                        style: TextStyle(
                          color: Color(0xFF1A2B48),
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _titleCtrl,
                        decoration: const InputDecoration(labelText: 'Title'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _amountCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Amount'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _noteCtrl,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Note (optional)',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _saveEntry,
                          icon: const Icon(Icons.save_rounded),
                          label: Text(_saving ? 'Saving...' : 'Save note'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (rows.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No notes yet.'),
                  ),
                )
              else
                ...rows.map((row) {
                  final entryId = (row['entryId'] ?? '').toString().trim();
                  final title = (row['title'] ?? '').toString().trim();
                  final amount = _asInt(row['amount']);
                  final note = (row['note'] ?? '').toString().trim();
                  final date = _fmtDate(_asInt(row['createdAt']));
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: Colors.black.withValues(alpha: 0.08),
                        ),
                      ),
                      child: ListTile(
                        title: Text(
                          title.isEmpty ? '(No title)' : title,
                          style: const TextStyle(
                            color: Color(0xFF1A2B48),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        subtitle: Text(
                          '${_money(amount)} · $date${note.isEmpty ? '' : '\n$note'}',
                          style: const TextStyle(
                            color: Color(0xFF1A2B48),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        isThreeLine: note.isNotEmpty,
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              tooltip: 'Edit',
                              onPressed: entryId.isEmpty
                                  ? null
                                  : () =>
                                        _editEntry(entryId: entryId, row: row),
                              icon: const Icon(Icons.edit_rounded),
                            ),
                            IconButton(
                              tooltip: 'Delete',
                              onPressed: entryId.isEmpty
                                  ? null
                                  : () => _deleteEntry(entryId),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
            ],
          );
        },
      ),
    );
  }
}
