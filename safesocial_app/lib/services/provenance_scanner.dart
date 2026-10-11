import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/media_provenance.dart';

/// Reads what a picked image file says about itself and turns it into a
/// [MediaProvenance] score.
///
/// Nothing here looks at pixels. The evidence is the file's own metadata
/// (camera EXIF, editing software tags, XMP and Content Credentials
/// manifests, PNG text chunks), its name, its dimensions and, when a caller
/// can supply them, the folder it came from and its dates. That keeps the
/// check cheap, deterministic and honest about what it is: a reading of the
/// file's claims, not a judgement of the picture.
///
/// Pure Dart, no platform calls; every rule is covered by a test.
class ProvenanceScanner {
  const ProvenanceScanner._();

  /// Assess an image before it is re-encoded. [source] is `camera` when the
  /// bytes came straight from the camera intent and `gallery` otherwise.
  /// [relativePath], [dateTaken] and [dateModified] are optional extra
  /// evidence from a media store; the photo picker does not provide them.
  /// Whether the file says it is a full 360° picture (Google's GPano XMP,
  /// which every phone and 360 camera writes): the viewer then pans it
  /// around rather than showing a very wide strip.
  static bool looksEquirectangular(Uint8List bytes) {
    try {
      final text = _MetadataText.collect(bytes).lower;
      return text.contains('equirectangular') || text.contains('usepanoramaviewer="true"');
    } catch (_) {
      return false;
    }
  }

  static MediaProvenance assessImage(
    Uint8List bytes, {
    required String source,
    String? fileName,
    String? relativePath,
    DateTime? dateTaken,
    DateTime? dateModified,
  }) {
    if (source == 'camera') return MediaProvenance.liveCamera;

    final signals = <String>[];
    String? tool;

    // ── What the file says about itself ────────────────────────────────────
    final meta = _MetadataText.collect(bytes);
    final exif = _readExif(bytes);
    final make = _ascii(exif?.imageIfd['Make']);
    final model = _ascii(exif?.imageIfd['Model']);
    final software = _ascii(exif?.imageIfd['Software']);
    final dateTime = _exifDate(_ascii(exif?.imageIfd['DateTime']));
    final dateOriginal = _exifDate(_ascii(exif?.exifIfd['DateTimeOriginal']));

    final generator = meta.generatorMark(software);
    if (generator != null) {
      signals.add(ProvenanceSignal.generatorMarked);
      tool = generator;
    } else if (meta.aiEditMark()) {
      signals.add(ProvenanceSignal.aiEdited);
      tool = meta.namedGenerator(software);
    }

    final hasCamera = (make?.isNotEmpty ?? false) || (model?.isNotEmpty ?? false);
    if (hasCamera) signals.add(ProvenanceSignal.cameraExif);
    if (exif == null && !meta.hasAnyText) signals.add(ProvenanceSignal.noMetadata);
    if (meta.isPng) signals.add(ProvenanceSignal.pngFile);

    final editor = _editingSoftware(software) ?? meta.namedEditor();
    if (editor != null) {
      signals.add(ProvenanceSignal.editedBySoftware);
      tool ??= editor;
    }
    if (_datesDisagree(dateOriginal, dateTime) ||
        _datesDisagree(dateTaken, dateModified)) {
      signals.add(ProvenanceSignal.editedDates);
    }
    if (hasCamera &&
        !signals.contains(ProvenanceSignal.editedBySoftware) &&
        !signals.contains(ProvenanceSignal.editedDates)) {
      signals.add(ProvenanceSignal.unedited);
    }

    // ── Name and folder ────────────────────────────────────────────────────
    final name = (fileName ?? '').split('/').last.toLowerCase();
    if (name.isNotEmpty) {
      final genName = _generatorFileName(name);
      if (genName != null) {
        signals.add(ProvenanceSignal.generatorFileName);
        tool ??= genName;
      } else if (_screenshotName.hasMatch(name)) {
        signals.add(ProvenanceSignal.screenshot);
      } else if (_messagingName.hasMatch(name)) {
        signals.add(ProvenanceSignal.messagingFileName);
      } else if (_cameraName.hasMatch(name)) {
        signals.add(ProvenanceSignal.cameraFileName);
      }
    }
    final folder = (relativePath ?? '').toLowerCase().replaceAll('\\', '/');
    if (folder.contains('dcim/camera')) {
      signals.add(ProvenanceSignal.cameraFolder);
    } else if (folder.contains('download') ||
        folder.contains('screenshot') ||
        folder.contains('whatsapp') ||
        folder.contains('telegram')) {
      if (folder.contains('screenshot')) {
        if (!signals.contains(ProvenanceSignal.screenshot)) {
          signals.add(ProvenanceSignal.screenshot);
        }
      } else {
        signals.add(ProvenanceSignal.downloadFolder);
      }
    }

    // ── Dimensions ─────────────────────────────────────────────────────────
    final size = _dimensions(bytes);
    if (size != null) {
      final (w, h) = size;
      final pixels = w * h;
      if (pixels >= 3000000) signals.add(ProvenanceSignal.highResolution);
      if (!hasCamera) {
        final genLike = w >= 512 &&
            h >= 512 &&
            pixels <= 2600000 &&
            (w == h || (w % 64 == 0 && h % 64 == 0));
        if (genLike) signals.add(ProvenanceSignal.generatorDimensions);
        final long = w > h ? w : h;
        final short = w > h ? h : w;
        final ratio = long / short;
        final screenLike = ratio >= 1.9 &&
            ratio <= 2.4 &&
            pixels >= 700000 &&
            pixels <= 4500000 &&
            short % 2 == 0;
        if (screenLike && !signals.contains(ProvenanceSignal.screenshot)) {
          signals.add(ProvenanceSignal.screenshot);
        }
      }
    }

    return MediaProvenance(
      score: _score(signals),
      source: 'gallery',
      signals: signals,
      tool: MediaProvenance.sanitiseTool(tool),
    );
  }

  /// The band rules, in order of certainty. Marks the file carries about
  /// itself beat guesses from names and sizes.
  static int _score(List<String> s) {
    bool has(String x) => s.contains(x);
    if (has(ProvenanceSignal.cameraCapture)) return 10;
    if (has(ProvenanceSignal.generatorMarked)) return 0;
    if (has(ProvenanceSignal.generatorFileName)) return 1;
    if (has(ProvenanceSignal.aiEdited)) return 2;

    if (has(ProvenanceSignal.cameraExif)) {
      var score = 8;
      if (has(ProvenanceSignal.unedited)) {
        if (has(ProvenanceSignal.cameraFileName) ||
            has(ProvenanceSignal.cameraFolder) ||
            has(ProvenanceSignal.highResolution)) {
          score = 9;
        }
      } else if (has(ProvenanceSignal.editedBySoftware)) {
        score = 6;
      } else {
        score = 7;
      }
      if (has(ProvenanceSignal.messagingFileName) ||
          has(ProvenanceSignal.downloadFolder)) {
        score -= 1;
      }
      return score.clamp(0, 10);
    }

    // No camera data at all.
    if (has(ProvenanceSignal.screenshot)) return 2;
    if (has(ProvenanceSignal.generatorDimensions)) return 2;
    if (has(ProvenanceSignal.messagingFileName) ||
        has(ProvenanceSignal.downloadFolder)) {
      return 3;
    }
    if (has(ProvenanceSignal.pngFile)) return 3;
    if (has(ProvenanceSignal.cameraFileName)) return 5;
    return 4;
  }

  // ── EXIF ────────────────────────────────────────────────────────────────

  static img.ExifData? _readExif(Uint8List bytes) {
    try {
      // Cameras write JPEG; a PNG with an eXIf chunk is rare enough that its
      // text is scanned for marks but not parsed for camera tags.
      if (_isJpeg(bytes)) {
        final exif = img.decodeJpgExif(bytes);
        return exif == null || exif.isEmpty ? null : exif;
      }
    } catch (_) {}
    return null;
  }

  static String? _ascii(img.IfdValue? v) {
    if (v == null) return null;
    final s = v.toString().trim().replaceAll('\u0000', '');
    return s.isEmpty ? null : s;
  }

  /// EXIF dates look like `2026:10:11 14:03:22`.
  static DateTime? _exifDate(String? s) {
    if (s == null) return null;
    final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})').firstMatch(s);
    if (m == null) return null;
    try {
      return DateTime(
        int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!),
        int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!),
      );
    } catch (_) {
      return null;
    }
  }

  /// Two minutes of slack covers cameras that write the two tags a moment
  /// apart while still catching an edit saved later.
  static bool _datesDisagree(DateTime? original, DateTime? modified) {
    if (original == null || modified == null) return false;
    return modified.difference(original).abs() > const Duration(minutes: 2);
  }

  static const _editors = [
    'photoshop', 'lightroom', 'snapseed', 'gimp', 'picsart', 'vsco', 'canva',
    'affinity', 'pixelmator', 'facetune', 'luminar', 'capture one', 'darktable',
    'rawtherapee', 'polarr', 'photo editor', 'instagram', 'acdsee', 'paint.net',
    'photoscape', 'meitu', 'beautyplus', 'youcam', 'remini', 'lensa', 'prisma',
    'photoroom', 'pixlr', 'adobe', 'google photos',
  ];

  static String? _editingSoftware(String? software) {
    if (software == null) return null;
    final lower = software.toLowerCase();
    for (final e in _editors) {
      if (lower.contains(e)) return software;
    }
    return null;
  }

  // ── Names ───────────────────────────────────────────────────────────────

  static final _cameraName = RegExp(
      r'^((img|dsc|dscf|dscn|pxl|dcim|imag|pano|mvimg|portrait|burst)[_-]?\d{4,}|\d{8}[_-]\d{6}|photo[_-]\d{4,}|p\d{7,})');
  static final _screenshotName =
      RegExp(r'^(screenshot|screen[ _-]?shot|scrnshot|screen[ _-]?capture|capture[_-]?\d)');
  static final _messagingName = RegExp(
      r'(-wa\d{4}|^img-\d{8}-wa|^received_|^fb_img_|^telegram|^signal-|^snapchat-|^messenger_|^download|^unnamed|^image_\d+\b|^images?\s?\(\d+\)|^photo_\d{4}-\d{2}-\d{2}|^unknown|^file\b)');

  /// Names generators give their downloads. Prefixes only, so a holiday photo
  /// called `fireflies.jpg` is not caught.
  static const _generatorPrefixes = <String, String>{
    'chatgpt image': 'ChatGPT',
    'dall-e': 'DALL-E',
    'dall\u00b7e': 'DALL-E',
    'dalle': 'DALL-E',
    'midjourney': 'Midjourney',
    'imagine_': 'Meta AI',
    'leonardo_': 'Leonardo',
    'firefly ': 'Adobe Firefly',
    'firefly_': 'Adobe Firefly',
    'gemini_generated': 'Gemini',
    'ideogram_': 'Ideogram',
    'grok-image': 'Grok',
    'grok_image': 'Grok',
    'comfyui_': 'ComfyUI',
    'stablediffusion': 'Stable Diffusion',
    'stable_diffusion': 'Stable Diffusion',
  };
  static final _a1111Name = RegExp(r'^\d{5}-\d{6,}\.png$');

  static String? _generatorFileName(String name) {
    for (final e in _generatorPrefixes.entries) {
      if (name.startsWith(e.key)) return e.value;
    }
    if (_a1111Name.hasMatch(name)) return 'Stable Diffusion';
    return null;
  }

  // ── Dimensions ──────────────────────────────────────────────────────────

  static (int, int)? _dimensions(Uint8List bytes) {
    try {
      final decoder = img.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info == null || info.width <= 0 || info.height <= 0) return null;
      return (info.width, info.height);
    } catch (_) {
      return null;
    }
  }

  static bool _isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xFF && b[1] == 0xD8;
  static bool _isPng(Uint8List b) =>
      b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
}

/// The text-bearing metadata of a file, pulled from JPEG APP segments, PNG
/// text and C2PA chunks, and WebP metadata chunks. Pixel data is never
/// scanned, so a generator's name in a photo of a poster cannot match.
class _MetadataText {
  final String lower;
  final bool isPng;
  final bool hasAnyText;

  _MetadataText._(this.lower, this.isPng, this.hasAnyText);

  static _MetadataText collect(Uint8List bytes) {
    final parts = <String>[];
    var png = false;
    try {
      if (ProvenanceScanner._isJpeg(bytes)) {
        parts.addAll(_jpegSegments(bytes));
      } else if (ProvenanceScanner._isPng(bytes)) {
        png = true;
        parts.addAll(_pngChunks(bytes));
      } else if (bytes.length > 12 &&
          String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
          String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
        parts.addAll(_webpChunks(bytes));
      }
    } catch (_) {}
    final joined = parts.join('\n').toLowerCase();
    return _MetadataText._(joined, png, joined.trim().isNotEmpty);
  }

  static const _sourceTypePrefix = 'cv.iptc.org/newscodes/digitalsourcetype/';

  /// The generator the file names, when its metadata says it was generated.
  /// [software] is the EXIF Software tag, read separately.
  String? generatorMark(String? software) {
    if (lower.contains('${_sourceTypePrefix}trainedalgorithmicmedia')) {
      return namedGenerator(software) ?? 'AI, per Content Credentials';
    }
    // Stable Diffusion front-ends write their settings into PNG text.
    if (lower.contains('\nparameters:') && lower.contains('steps:')) {
      return 'Stable Diffusion';
    }
    if (lower.contains('\nworkflow:') && lower.contains('\nprompt:')) {
      return 'ComfyUI';
    }
    if (lower.contains('made with google ai')) return 'Google AI';
    return namedGenerator(software);
  }

  /// Whether the metadata says the picture is a real one changed with AI.
  bool aiEditMark() =>
      lower.contains('${_sourceTypePrefix}compositewithtrainedalgorithmicmedia') ||
      lower.contains('${_sourceTypePrefix}compositesynthetic') ||
      lower.contains('edited with google ai');

  static const _generators = <String, String>{
    'stable diffusion': 'Stable Diffusion',
    'stablediffusion': 'Stable Diffusion',
    'midjourney': 'Midjourney',
    'dall-e': 'DALL-E',
    'dall·e': 'DALL-E',
    'dalle': 'DALL-E',
    'openai': 'OpenAI',
    'chatgpt': 'ChatGPT',
    'adobe firefly': 'Adobe Firefly',
    'firefly': 'Adobe Firefly',
    'imagen': 'Google Imagen',
    'gemini': 'Gemini',
    'google ai': 'Google AI',
    'flux.1': 'Flux',
    'black forest labs': 'Flux',
    'leonardo.ai': 'Leonardo',
    'ideogram': 'Ideogram',
    'novelai': 'NovelAI',
    'comfyui': 'ComfyUI',
    'automatic1111': 'Stable Diffusion',
    'invokeai': 'InvokeAI',
    'bing image creator': 'Bing Image Creator',
    'grok': 'Grok',
    'nano banana': 'Gemini',
    'recraft': 'Recraft',
    'krea': 'Krea',
    'dreamstudio': 'DreamStudio',
    'nightcafe': 'NightCafe',
    'fooocus': 'Fooocus',
    'meta ai': 'Meta AI',
  };

  /// A generator named where tools name themselves: the EXIF Software tag,
  /// an XMP CreatorTool, or a Content Credentials claim generator. A caption
  /// that merely mentions a product does not count, so a description reading
  /// "imagen de la playa" cannot mark a photo as generated.
  String? namedGenerator(String? software) {
    final fields = <String>[
      if (software != null) software.toLowerCase(),
      ..._toolFields(),
    ];
    for (final field in fields) {
      for (final e in _generators.entries) {
        if (field.contains(e.key)) return e.value;
      }
    }
    return null;
  }

  /// The values of the fields where a tool names itself.
  List<String> _toolFields() {
    final out = <String>[];
    final field = RegExp(r'(creatortool|software|claim_generator|claim_generator_info|agent)[="\s:]*([^"<\n]{1,120})');
    for (final m in field.allMatches(lower)) {
      out.add(m[2]!);
    }
    return out;
  }

  String? namedEditor() {
    final m = RegExp(r'(creatortool|software)="?([^"<\n]{2,60})').firstMatch(lower);
    if (m == null) return null;
    final value = m[2]!.trim();
    for (final e in ProvenanceScanner._editors) {
      if (value.contains(e)) return value;
    }
    return null;
  }

  static List<String> _jpegSegments(Uint8List b) {
    final out = <String>[];
    var i = 2;
    while (i + 4 <= b.length) {
      if (b[i] != 0xFF) break;
      final marker = b[i + 1];
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      if (marker == 0xDA || marker == 0xD9) break; // image data begins
      final len = (b[i + 2] << 8) | b[i + 3];
      if (len < 2 || i + 2 + len > b.length) break;
      final payload = b.sublist(i + 4, i + 2 + len);
      // APP1 (Exif, XMP), APP11 (JUMBF / C2PA), APP13 (IPTC), COM. ICC
      // profiles (APP2) are binary and big, and never name a tool.
      if (marker == 0xE1 || marker == 0xEB || marker == 0xED || marker == 0xFE) {
        out.add(_printable(payload));
      }
      i += 2 + len;
    }
    return out;
  }

  static List<String> _pngChunks(Uint8List b) {
    final out = <String>[];
    var i = 8;
    final data = ByteData.sublistView(b);
    while (i + 8 <= b.length) {
      final len = data.getUint32(i);
      final type = String.fromCharCodes(b.sublist(i + 4, i + 8));
      if (i + 12 + len > b.length) break;
      final payload = b.sublist(i + 8, i + 8 + len);
      if (type == 'IDAT' || type == 'IEND') {
        if (type == 'IEND') break;
      } else if (type == 'tEXt' || type == 'iTXt' || type == 'zTXt') {
        final nul = payload.indexOf(0);
        final key = nul < 0 ? '' : _printable(payload.sublist(0, nul));
        var value = '';
        if (type == 'tEXt' && nul >= 0) {
          value = _printable(payload.sublist(nul + 1));
        } else if (type == 'iTXt' && nul >= 0) {
          // keyword \0 compression flag, method \0 language \0 translated \0 text
          var p = nul + 1;
          final compressed = payload.length > p && payload[p] == 1;
          p += 2;
          final lang = payload.indexOf(0, p);
          final translated = lang < 0 ? -1 : payload.indexOf(0, lang + 1);
          if (translated >= 0 && !compressed) {
            value = _printable(payload.sublist(translated + 1));
          }
        }
        out.add('\n$key:$value');
      } else if (type == 'caBX' || type == 'eXIf' || type == 'exIf') {
        out.add(_printable(payload));
      }
      i += 12 + len;
    }
    return out;
  }

  static List<String> _webpChunks(Uint8List b) {
    final out = <String>[];
    final data = ByteData.sublistView(b);
    var i = 12;
    while (i + 8 <= b.length) {
      final type = String.fromCharCodes(b.sublist(i, i + 4));
      final len = data.getUint32(i + 4, Endian.little);
      if (i + 8 + len > b.length) break;
      if (type == 'EXIF' || type == 'XMP ' || type == 'C2PA') {
        out.add(_printable(b.sublist(i + 8, i + 8 + len)));
      }
      i += 8 + len + (len.isOdd ? 1 : 0);
    }
    return out;
  }

  /// Decodes as UTF-8 where it can and drops control bytes, so CBOR and XML
  /// strings alike become searchable text.
  static String _printable(List<int> bytes) {
    final decoded = utf8.decode(bytes, allowMalformed: true);
    return decoded.replaceAll(RegExp(r'[^\x20-\x7E -￿\n]'), ' ');
  }
}
