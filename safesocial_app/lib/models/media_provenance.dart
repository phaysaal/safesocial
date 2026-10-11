/// Where a picture came from, as judged by the sender's device from the file
/// itself, before the picture was re-encoded for sending.
///
/// This is a *claim by the sender's device*, carried inside the sealed
/// message next to the media. It is not a verdict: the file's own data can be
/// stripped by forwarding or faked by a determined sender, so the UI always
/// shows it with [disclaimer]. Only codes travel on the wire; the wording is
/// rendered on the receiving device, so a sender cannot put text in the badge.
class MediaProvenance {
  /// 0 (its maker marked it as AI-generated) to 10 (taken with the camera
  /// from inside the app).
  final int score;

  /// `camera` when captured through the app, `gallery` when picked from the
  /// library.
  final String source;

  /// Codes from [ProvenanceSignal] that led to the score.
  final List<String> signals;

  /// A short, sanitised name of the tool the file names as its maker or
  /// editor, when the metadata gives one.
  final String? tool;

  const MediaProvenance({
    required this.score,
    required this.source,
    this.signals = const [],
    this.tool,
  });

  /// The claim attached to anything captured through the app's own camera
  /// button.
  static const MediaProvenance liveCamera = MediaProvenance(
    score: 10,
    source: 'camera',
    signals: [ProvenanceSignal.cameraCapture],
  );

  static const String disclaimer =
      'An estimate made on the sender\'s device from the file\'s own data, not '
      'a verdict. A real photo can score low after editing or forwarding, and '
      'a made-up one can score high if its data was faked.';

  bool has(String signal) => signals.contains(signal);

  /// A two-to-four word label for the score band.
  String get band {
    if (score >= 10) return 'Live camera';
    if (score >= 8) return 'Camera photo, unedited';
    if (score >= 6) return 'Camera photo, edited';
    if (score >= 4) return 'Origin unknown';
    if (score >= 1) return 'Probably not an original photo';
    return 'Marked as AI-generated';
  }

  /// One sentence saying why, built from the codes on this device.
  String get note {
    final t = tool == null ? '' : ' ($tool)';
    if (has(ProvenanceSignal.cameraCapture)) {
      return 'Taken with the camera from inside Spheres.';
    }
    if (has(ProvenanceSignal.generatorMarked)) {
      return 'Its own metadata says it was made with AI$t.';
    }
    if (has(ProvenanceSignal.aiEdited)) {
      return 'Its own metadata says it was edited with AI tools$t.';
    }
    if (has(ProvenanceSignal.generatorFileName)) {
      return 'Its file name is the kind an image generator gives$t.';
    }
    if (has(ProvenanceSignal.cameraExif)) {
      if (has(ProvenanceSignal.editedBySoftware)) {
        return 'Carries camera data but was saved by editing software$t.';
      }
      if (has(ProvenanceSignal.editedDates)) {
        return 'Carries camera data but was changed after it was taken.';
      }
      if (has(ProvenanceSignal.messagingFileName) ||
          has(ProvenanceSignal.downloadFolder)) {
        return 'Carries camera data, but arrived through a messaging app or download.';
      }
      return 'Carries camera data (make, model, time) and shows no sign of editing.';
    }
    if (has(ProvenanceSignal.screenshot)) return 'Looks like a screenshot.';
    if (has(ProvenanceSignal.messagingFileName) ||
        has(ProvenanceSignal.downloadFolder)) {
      return 'Came through a messaging app or a download, which strips origin data.';
    }
    if (has(ProvenanceSignal.generatorDimensions)) {
      return 'No origin data, and its size is typical of image generators.';
    }
    if (has(ProvenanceSignal.pngFile)) {
      return 'A PNG without camera data; cameras do not produce PNGs.';
    }
    if (has(ProvenanceSignal.noMetadata)) {
      return 'No camera data in the file. It may have been edited, received, or saved from an app.';
    }
    return 'Origin could not be determined.';
  }

  Map<String, dynamic> toJson() => {
        's': score,
        'src': source,
        if (signals.isNotEmpty) 'g': signals,
        if (tool != null) 'm': tool,
      };

  /// Parses a received claim, clamping and filtering everything: the score to
  /// 0–10, the source to the two known values, the signals to known codes and
  /// the tool name to 40 plain characters. Anything unparseable is null.
  static MediaProvenance? fromJson(dynamic json) {
    if (json is! Map) return null;
    final rawScore = json['s'];
    if (rawScore is! num) return null;
    final score = rawScore.round().clamp(0, 10);
    final source = json['src'] == 'camera' ? 'camera' : 'gallery';
    final signals = (json['g'] is List)
        ? (json['g'] as List)
            .whereType<String>()
            .where(ProvenanceSignal.all.contains)
            .take(12)
            .toList()
        : const <String>[];
    return MediaProvenance(
      score: score,
      source: source,
      signals: signals,
      tool: sanitiseTool(json['m']),
    );
  }

  /// Keeps letters, digits, spaces and a few punctuation marks, at most 40
  /// characters, or returns null.
  static String? sanitiseTool(dynamic raw) {
    if (raw is! String) return null;
    final cleaned = raw
        .replaceAll(RegExp(r'[^A-Za-z0-9 .\-+_()]'), '')
        .trim();
    if (cleaned.isEmpty) return null;
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }

  /// One entry per media reference, null where nothing was assessed.
  static List<MediaProvenance?> listFromJson(dynamic json) {
    if (json is! List) return const [];
    return json.map(fromJson).toList();
  }

  /// The wire form of a per-media list, or null when nothing was assessed so
  /// the field is left out entirely.
  static List<Map<String, dynamic>?>? listToJson(List<MediaProvenance?> list) {
    if (list.every((p) => p == null)) return null;
    return list.map((p) => p?.toJson()).toList();
  }

  /// The entry for media [index], when the list has one.
  static MediaProvenance? at(List<MediaProvenance?> list, int index) =>
      index >= 0 && index < list.length ? list[index] : null;

  @override
  bool operator ==(Object other) =>
      other is MediaProvenance &&
      other.score == score &&
      other.source == source &&
      other.tool == tool &&
      other.signals.join(',') == signals.join(',');

  @override
  int get hashCode => Object.hash(score, source, tool, signals.join(','));

  @override
  String toString() => 'MediaProvenance($score, $source, $signals)';
}

/// The codes a scorer may attach. The receiving device turns these into
/// words, so adding one means adding a sentence to [MediaProvenance.note].
abstract final class ProvenanceSignal {
  static const cameraCapture = 'camera_capture';
  static const cameraExif = 'camera_exif';
  static const unedited = 'unedited';
  static const editedBySoftware = 'edited_software';
  static const editedDates = 'edited_dates';
  static const cameraFileName = 'camera_name';
  static const cameraFolder = 'camera_folder';
  static const highResolution = 'high_res';
  static const generatorMarked = 'gen_marked';
  static const aiEdited = 'ai_edited';
  static const generatorFileName = 'gen_name';
  static const generatorDimensions = 'gen_dims';
  static const messagingFileName = 'msg_app_name';
  static const downloadFolder = 'download_folder';
  static const screenshot = 'screenshot';
  static const noMetadata = 'no_metadata';
  static const pngFile = 'png';

  static const Set<String> all = {
    cameraCapture,
    cameraExif,
    unedited,
    editedBySoftware,
    editedDates,
    cameraFileName,
    cameraFolder,
    highResolution,
    generatorMarked,
    aiEdited,
    generatorFileName,
    generatorDimensions,
    messagingFileName,
    downloadFolder,
    screenshot,
    noMetadata,
    pngFile,
  };
}
