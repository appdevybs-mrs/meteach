import 'package:flutter/material.dart';

class WebAudioPlayer extends StatelessWidget {
  const WebAudioPlayer({
    super.key,
    required this.url,
    this.backgroundColor = Colors.white,
  });

  final String url;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: backgroundColor,
      alignment: Alignment.center,
      child: const Text(
        'Audio',
        textAlign: TextAlign.center,
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
    );
  }
}
