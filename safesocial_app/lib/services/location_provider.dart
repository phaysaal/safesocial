import 'package:geolocator/geolocator.dart';

import 'debug_log_service.dart';

/// Where this device is, for live-location sharing.
///
/// Positions are read here and sealed into messages by ChatService; nothing
/// about them is ever sent to the relay in the clear or to any map provider.
class GeoLocationProvider {
  GeoLocationProvider._();

  /// A fix, or null when the user has not allowed it or the service is off.
  static Future<({double lat, double lng})?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      return (lat: pos.latitude, lng: pos.longitude);
    } catch (e) {
      DebugLogService().warn('Location', 'No fix: $e');
      return null;
    }
  }
}
