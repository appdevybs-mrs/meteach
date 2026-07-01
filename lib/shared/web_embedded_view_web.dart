// ignore: deprecated_member_use
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class WebEmbeddedContent extends StatefulWidget {
  const WebEmbeddedContent({
    super.key,
    required this.url,
    this.title = '',
    this.backgroundColor = Colors.white,
  });

  final String url;
  final String title;
  final Color backgroundColor;

  @override
  State<WebEmbeddedContent> createState() => _WebEmbeddedContentState();
}

class _WebEmbeddedContentState extends State<WebEmbeddedContent> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType = 'web-embedded-${DateTime.now().microsecondsSinceEpoch}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      return html.IFrameElement()
        ..src = widget.url
        ..title = widget.title
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.backgroundColor = '#ffffff'
        ..allow = 'autoplay; fullscreen; clipboard-read; clipboard-write'
        ..allowFullscreen = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.backgroundColor,
      child: HtmlElementView(viewType: _viewType),
    );
  }
}
