import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import 'app_theme.dart';

class SharedPdfReaderScreen extends StatefulWidget {
  const SharedPdfReaderScreen({
    super.key,
    required this.title,
    required this.pdfUrl,
  });

  final String title;
  final String pdfUrl;

  @override
  State<SharedPdfReaderScreen> createState() => _SharedPdfReaderScreenState();
}

class _SharedPdfReaderScreenState extends State<SharedPdfReaderScreen> {
  final PdfViewerController _pdfController = PdfViewerController();

  bool _loading = true;
  String? _error;
  int _pageNumber = 0;
  int _pageCount = 0;
  double _zoomLevel = 1.0;

  _PdfPalette get palette => _toPdfPalette(appThemeController.palette);

  _PdfPalette _toPdfPalette(AppPalette p) {
    return _PdfPalette(
      primary: p.primary,
      accent: p.accent,
      text: p.text,
      appBg: p.appBg,
      cardBg: p.cardBg,
      border: p.border,
      soft: p.soft,
    );
  }

  bool get _hasDocument => _pageCount > 0 && _error == null;

  Future<void> _showJumpToPageDialog() async {
    if (!_hasDocument) return;

    final controller = TextEditingController(
      text: _pageNumber > 0 ? '$_pageNumber' : '',
    );

    final result = await showDialog<int>(
      context: context,
      builder: (ctx) {
        final p = palette;
        return AlertDialog(
          backgroundColor: p.cardBg,
          title: Text(
            'Go to page',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
            ),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Enter page number',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: p.text.withOpacity(0.75),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            FilledButton(
              onPressed: () {
                final raw = controller.text.trim();
                final page = int.tryParse(raw);
                Navigator.of(ctx).pop(page);
              },
              child: const Text('Go'),
            ),
          ],
        );
      },
    );

    if (result == null) return;
    if (result < 1 || result > _pageCount) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Enter a page between 1 and $_pageCount'),
        ),
      );
      return;
    }

    _pdfController.jumpToPage(result);
  }

  void _goToPreviousPage() {
    if (!_hasDocument || _pageNumber <= 1) return;
    _pdfController.previousPage();
  }

  void _goToNextPage() {
    if (!_hasDocument || _pageNumber >= _pageCount) return;
    _pdfController.nextPage();
  }

  void _goToFirstPage() {
    if (!_hasDocument) return;
    _pdfController.jumpToPage(1);
  }

  void _goToLastPage() {
    if (!_hasDocument) return;
    _pdfController.jumpToPage(_pageCount);
  }

  void _zoomIn() {
    if (!_hasDocument) return;
    final next = (_zoomLevel + 0.25).clamp(1.0, 3.0);
    _pdfController.zoomLevel = next;
    setState(() {
      _zoomLevel = next;
    });
  }

  void _zoomOut() {
    if (!_hasDocument) return;
    final next = (_zoomLevel - 0.25).clamp(1.0, 3.0);
    _pdfController.zoomLevel = next;
    setState(() {
      _zoomLevel = next;
    });
  }

  void _resetZoom() {
    if (!_hasDocument) return;
    _pdfController.zoomLevel = 1.0;
    setState(() {
      _zoomLevel = 1.0;
    });
  }

  void _reloadPdf() {
    setState(() {
      _loading = true;
      _error = null;
      _pageNumber = 0;
      _pageCount = 0;
      _zoomLevel = 1.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        surfaceTintColor: p.cardBg,
        elevation: 0,
        titleSpacing: 12,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title.trim().isEmpty ? 'Read Story' : widget.title.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _pageCount > 0
                  ? 'Page $_pageNumber of $_pageCount'
                  : 'PDF Reader',
              style: TextStyle(
                color: p.text.withOpacity(0.62),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reloadPdf,
            icon: Icon(Icons.refresh_rounded, color: p.primary),
          ),
          IconButton(
            tooltip: 'Go to page',
            onPressed: _hasDocument ? _showJumpToPageDialog : null,
            icon: Icon(Icons.find_in_page_rounded, color: p.primary),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: p.cardBg,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _TopActionChip(
                    icon: Icons.first_page_rounded,
                    label: 'First',
                    onTap: _hasDocument ? _goToFirstPage : null,
                  ),
                  const SizedBox(width: 8),
                  _TopActionChip(
                    icon: Icons.chevron_left_rounded,
                    label: 'Prev',
                    onTap: _hasDocument ? _goToPreviousPage : null,
                  ),
                  const SizedBox(width: 8),
                  _TopActionChip(
                    icon: Icons.chevron_right_rounded,
                    label: 'Next',
                    onTap: _hasDocument ? _goToNextPage : null,
                  ),
                  const SizedBox(width: 8),
                  _TopActionChip(
                    icon: Icons.last_page_rounded,
                    label: 'Last',
                    onTap: _hasDocument ? _goToLastPage : null,
                  ),
                  const SizedBox(width: 12),
                  _TopActionChip(
                    icon: Icons.zoom_out_rounded,
                    label: 'Zoom -',
                    onTap: _hasDocument ? _zoomOut : null,
                  ),
                  const SizedBox(width: 8),
                  _TopActionChip(
                    icon: Icons.center_focus_strong_rounded,
                    label: '${_zoomLevel.toStringAsFixed(2)}x',
                    onTap: _hasDocument ? _resetZoom : null,
                  ),
                  const SizedBox(width: 8),
                  _TopActionChip(
                    icon: Icons.zoom_in_rounded,
                    label: 'Zoom +',
                    onTap: _hasDocument ? _zoomIn : null,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    color: p.soft.withOpacity(0.35),
                    child: SfPdfViewer.network(
                      widget.pdfUrl,
                      controller: _pdfController,
                      canShowPaginationDialog: true,
                      canShowScrollHead: true,
                      canShowScrollStatus: true,
                      enableDoubleTapZooming: true,
                      onZoomLevelChanged: (details) {
                        if (!mounted) return;
                        setState(() {
                          _zoomLevel = details.newZoomLevel;
                        });
                      },
                      onDocumentLoaded: (details) {
                        if (!mounted) return;
                        setState(() {
                          _loading = false;
                          _pageCount = details.document.pages.count;
                          _pageNumber = 1;
                          _error = null;
                          _zoomLevel = 1.0;
                        });
                      },
                      onDocumentLoadFailed: (details) {
                        if (!mounted) return;
                        setState(() {
                          _loading = false;
                          _error = details.description;
                        });
                      },
                      onPageChanged: (details) {
                        if (!mounted) return;
                        setState(() {
                          _pageNumber = details.newPageNumber;
                        });
                      },
                    ),
                  ),
                ),
                if (_loading)
                  Positioned.fill(
                    child: Container(
                      color: p.appBg.withOpacity(0.78),
                      alignment: Alignment.center,
                      child: Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: p.cardBg,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: p.border.withOpacity(0.85)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 16,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: p.primary),
                            const SizedBox(height: 14),
                            Text(
                              'Opening story...',
                              style: TextStyle(
                                color: p.primary,
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Please wait while the PDF loads',
                              style: TextStyle(
                                color: p.text.withOpacity(0.68),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_error != null)
                  Positioned.fill(
                    child: Container(
                      color: p.appBg.withOpacity(0.88),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.all(20),
                      child: Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxWidth: 520),
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: p.cardBg,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: p.border.withOpacity(0.85)),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              size: 42,
                              color: p.accent,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Could not open PDF',
                              style: TextStyle(
                                color: p.primary,
                                fontWeight: FontWeight.w900,
                                fontSize: 18,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: p.text,
                                fontWeight: FontWeight.w700,
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _reloadPdf,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('Try Again'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        color: p.cardBg,
        padding: EdgeInsets.fromLTRB(
          14,
          10,
          14,
          10 + MediaQuery.of(context).padding.bottom,
        ),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _hasDocument && _pageNumber > 1 ? _goToPreviousPage : null,
                icon: const Icon(Icons.chevron_left_rounded),
                label: const Text('Previous'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _hasDocument && _pageNumber < _pageCount ? _goToNextPage : null,
                icon: const Icon(Icons.chevron_right_rounded),
                label: const Text('Next'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopActionChip extends StatelessWidget {
  const _TopActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = _paletteFromTheme();

    return Material(
      color: p.soft,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? 0.45 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: p.border.withOpacity(0.85)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: p.primary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
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

class _PdfPalette {
  const _PdfPalette({
    required this.primary,
    required this.accent,
    required this.text,
    required this.appBg,
    required this.cardBg,
    required this.border,
    required this.soft,
  });

  final Color primary;
  final Color accent;
  final Color text;
  final Color appBg;
  final Color cardBg;
  final Color border;
  final Color soft;
}

_PdfPalette _paletteFromTheme() {
  final p = appThemeController.palette;
  return _PdfPalette(
    primary: p.primary,
    accent: p.accent,
    text: p.text,
    appBg: p.appBg,
    cardBg: p.cardBg,
    border: p.border,
    soft: p.soft,
  );
}