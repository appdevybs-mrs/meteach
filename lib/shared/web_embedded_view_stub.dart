import 'package:flutter/material.dart';

class WebEmbeddedContent extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Container(
      color: backgroundColor,
      alignment: Alignment.center,
      child: Text(
        title.trim().isEmpty ? 'Web content' : title.trim(),
        textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
    );
  }
}
