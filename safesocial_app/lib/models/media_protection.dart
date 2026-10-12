/// How a photo or video asks to be shown: only while held, never kept.
///
/// Travels in a post's or message's `payload['protected']`, so it rides the
/// existing sealed envelope and needs no new kind. On the receiving device it
/// means: the media is decrypted in memory only and never written to the
/// media cache; it is shown while two fingers are on the glass and for at
/// most ten seconds at a time, blurred otherwise; while it is shown the window
/// refuses screenshots where the platform can; save, share, forward and
/// reshare are refused; and the list thumbnail the sender attached is a
/// colour smear a few pixels wide.
///
/// Honesty: all of it runs on the viewer's phone and is enforced by this app.
/// A changed app, or a second camera, can still keep a copy. The composer says
/// so before anything is posted.
class MediaProtection {
  /// Draw the viewer's own name across the picture while it is shown, so a
  /// photo of the screen names who was looking. Off unless the sender asks.
  final bool watermark;

  const MediaProtection({this.watermark = false});

  /// Read from a payload; null when the media is not protected. A malformed
  /// value is read as protected without a watermark rather than ignored, so a
  /// sender who asked for protection is never shown the plain picture.
  static MediaProtection? fromPayload(Map<String, dynamic>? payload) {
    final raw = payload?['protected'];
    if (raw == null || raw == false) return null;
    if (raw is Map) return MediaProtection(watermark: raw['wm'] == true);
    return const MediaProtection();
  }

  Map<String, dynamic> toJson() => {if (watermark) 'wm': true};

  /// The viewer route's query flags, and back.
  String get query => '&protected=1${watermark ? '&wm=1' : ''}';

  static MediaProtection? fromQuery(Map<String, String> q) =>
      q['protected'] == '1' ? MediaProtection(watermark: q['wm'] == '1') : null;

  /// Shown wherever the sender turns it on, before anything travels.
  static const disclaimer =
      'Shown only while the other person holds it with two fingers, for ten '
      'seconds at a time. Screenshots are blocked where the phone allows it, '
      'and saving, sharing and forwarding are off. Their phone enforces this; '
      'a changed app or a second camera could still keep a copy.';

  @override
  bool operator ==(Object other) => other is MediaProtection && other.watermark == watermark;
  @override
  int get hashCode => watermark.hashCode;
}
