// ignore: deprecated_member_use
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class WebAudioPlayer extends StatefulWidget {
  const WebAudioPlayer({
    super.key,
    required this.url,
    this.backgroundColor = const Color(0xFFF5F5F5),
  });

  final String url;
  final Color backgroundColor;

  @override
  State<WebAudioPlayer> createState() => _WebAudioPlayerState();
}

class _WebAudioPlayerState extends State<WebAudioPlayer> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType = 'web-audio-${DateTime.now().microsecondsSinceEpoch}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final audio = html.AudioElement()
        ..src = widget.url
        ..controls = true
        ..preload = 'auto'
        ..style.width = '100%'
        ..style.height = '54px'
        ..style.borderRadius = '8px'
        ..style.backgroundColor = '#ffffff';
      return audio;
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
