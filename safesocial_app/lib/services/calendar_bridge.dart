import 'dart:io';

import 'package:flutter/services.dart';

/// The device's own calendar and share sheet, through a small platform
/// channel. Built for Android; elsewhere it says so rather than pretending.
class CalendarBridge {
  CalendarBridge._();

  static const _channel = MethodChannel('spheres/calendar');

  /// Open the calendar app's "new event" form, filled in. The user still
  /// chooses which calendar and whether to save.
  static Future<void> insert({
    required String title,
    required DateTime starts,
    DateTime? ends,
    String place = '',
    String description = '',
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Adding to the calendar is only built for Android so far.');
    }
    await _channel.invokeMethod<void>('insert', {
      'title': title,
      'begin': starts.millisecondsSinceEpoch,
      if (ends != null) 'end': ends.millisecondsSinceEpoch,
      'location': place,
      'description': description,
    });
  }

  /// Hand an .ics file to the share sheet.
  static Future<void> shareIcs({required String fileName, required String contents}) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Exporting a calendar file is only built for Android so far.');
    }
    await _channel.invokeMethod<void>('shareIcs', {'name': fileName, 'contents': contents});
  }
}
