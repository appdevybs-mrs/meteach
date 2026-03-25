import 'package:url_launcher/url_launcher.dart';

Future<void> redirectToPublicSite([
  String url = 'https://www.yourbridgeschool.com',
]) async {
  final uri = Uri.parse(url);
  await launchUrl(uri, webOnlyWindowName: '_self');
}
