import 'package:flutter/material.dart';

import 'app_connectivity.dart';

class OfflineNoticeBanner extends StatelessWidget {
  const OfflineNoticeBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppConnectivity.instance.isOfflineListenable,
      builder: (context, isOffline, _) {
        if (!isOffline) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFFECACA)),
          ),
          child: const Row(
            children: [
              Icon(Icons.wifi_off_rounded, color: Color(0xFFB91C1C), size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  "You're offline. Some actions are unavailable.",
                  style: TextStyle(
                    color: Color(0xFFB91C1C),
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
