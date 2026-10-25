import 'dart:convert';
import 'dart:math' as math;

/// A look: colour and light as numbers, applied by every viewer at draw time
/// to the original pixels. See `docs/look_plan.md`.
///
/// The original is never changed and never lost; a look is a dozen numbers in
/// the payload beside the media, so changing it is an edit of numbers and an
/// older client simply shows the original. There is no field here that
/// changes a face, by decision.
class Look {
  final double exposure; // -2..2 stops
  final double temperature; // -1..1, blue..amber
  final double tint; // -1..1, green..magenta
  final double contrast; // -1..1
  final double highlights; // -1..1
  final double shadows; // -1..1
  final double saturation; // -1..1
  final double vibrance; // -1..1
  final double vignette; // 0..1
  final double grain; // 0..1

  /// The preset it started from, for the UI only.
  final String? preset;

  const Look({
    this.exposure = 0,
    this.temperature = 0,
    this.tint = 0,
    this.contrast = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.saturation = 0,
    this.vibrance = 0,
    this.vignette = 0,
    this.grain = 0,
    this.preset,
  });

  static const none = Look();

  bool get isNone =>
      exposure == 0 &&
      temperature == 0 &&
      tint == 0 &&
      contrast == 0 &&
      highlights == 0 &&
      shadows == 0 &&
      saturation == 0 &&
      vibrance == 0 &&
      vignette == 0 &&
      grain == 0;

  /// Whether the colour matrix is the identity, so nothing need be drawn
  /// but the overlays.
  bool get hasColour =>
      exposure != 0 ||
      temperature != 0 ||
      tint != 0 ||
      contrast != 0 ||
      highlights != 0 ||
      shadows != 0 ||
      saturation != 0 ||
      vibrance != 0;

  Look copyWith({
    double? exposure,
    double? temperature,
    double? tint,
    double? contrast,
    double? highlights,
    double? shadows,
    double? saturation,
    double? vibrance,
    double? vignette,
    double? grain,
    String? preset,
    bool clearPreset = false,
  }) =>
      Look(
        exposure: exposure ?? this.exposure,
        temperature: temperature ?? this.temperature,
        tint: tint ?? this.tint,
        contrast: contrast ?? this.contrast,
        highlights: highlights ?? this.highlights,
        shadows: shadows ?? this.shadows,
        saturation: saturation ?? this.saturation,
        vibrance: vibrance ?? this.vibrance,
        vignette: vignette ?? this.vignette,
        grain: grain ?? this.grain,
        preset: clearPreset ? null : (preset ?? this.preset),
      );

  /// A short name for the line under a picture.
  String get label => preset ?? (isNone ? 'None' : 'Adjusted');

  // ── Wire ───────────────────────────────────────────────────────────────────

  /// Only what is not zero travels; a look with nothing in it is nothing.
  Map<String, dynamic> toJson() => {
        if (exposure != 0) 'ex': _r(exposure),
        if (temperature != 0) 'te': _r(temperature),
        if (tint != 0) 'ti': _r(tint),
        if (contrast != 0) 'co': _r(contrast),
        if (highlights != 0) 'hi': _r(highlights),
        if (shadows != 0) 'sh': _r(shadows),
        if (saturation != 0) 'sa': _r(saturation),
        if (vibrance != 0) 'vi': _r(vibrance),
        if (vignette != 0) 'vg': _r(vignette),
        if (grain != 0) 'gr': _r(grain),
        if (preset != null) 'p': preset,
      };

  static double _r(double v) => (v * 1000).roundToDouble() / 1000;

  /// Every field clamped to its range; anything that is not a number is
  /// zero; anything that is not a map is no look.
  static Look? tryParse(Object? raw) {
    if (raw is! Map) return null;
    double f(String k, double lo, double hi) {
      final v = raw[k];
      if (v is! num || v.isNaN) return 0;
      return v.toDouble().clamp(lo, hi);
    }
    final p = raw['p'];
    return Look(
      exposure: f('ex', -2, 2),
      temperature: f('te', -1, 1),
      tint: f('ti', -1, 1),
      contrast: f('co', -1, 1),
      highlights: f('hi', -1, 1),
      shadows: f('sh', -1, 1),
      saturation: f('sa', -1, 1),
      vibrance: f('vi', -1, 1),
      vignette: f('vg', 0, 1),
      grain: f('gr', 0, 1),
      preset: p is String && p.isNotEmpty && p.length <= 40 ? p : null,
    );
  }

  /// The look for the [index]th picture of a post or message: the entry for
  /// that index, else the one for every picture ("*"), else none.
  static Look forIndex(Map<String, dynamic>? payload, int index) {
    final raw = payload?['look'];
    if (raw is! Map) return none;
    return tryParse(raw['$index']) ?? tryParse(raw['*']) ?? none;
  }

  /// The payload entry for a post: one look per index, or one for all when
  /// every picture has the same.
  static Map<String, dynamic>? payloadFor(List<Look> perIndex) {
    final set = <String, dynamic>{};
    for (var i = 0; i < perIndex.length; i++) {
      if (!perIndex[i].isNone) set['$i'] = perIndex[i].toJson();
    }
    if (set.isEmpty) return null;
    if (set.length == perIndex.length && perIndex.length > 1) {
      final first = jsonEncode(set['0']);
      if (set.values.every((v) => jsonEncode(v) == first)) return {'*': set['0']};
    }
    return set;
  }

  /// For the viewer's route, which carries only a reference.
  String toQuery() => Uri.encodeComponent(jsonEncode(toJson()));

  /// Takes the parameter as the router hands it (decoded) or as [toQuery]
  /// made it (encoded); anything else is no look.
  static Look fromQuery(String? q) {
    if (q == null || q.isEmpty) return none;
    for (final text in [q, Uri.decodeComponent(q)]) {
      try {
        return tryParse(jsonDecode(text)) ?? none;
      } catch (_) {
        // try the other form
      }
    }
    return none;
  }

  // ── True skin ──────────────────────────────────────────────────────────────

  /// The correction that makes skin read as it does in life, from the
  /// picture's own statistics: a grey-world white balance clipped to a sane
  /// range (phone cameras lean amber under bulbs and green under tubes, and
  /// lean unevenly across skin tones) and a lift when the midtones are sunk.
  /// No face is found and nothing is judged; a neutral, well-lit picture gets
  /// nothing at all.
  static Look trueSkin(ImageStats s) {
    final avg = (s.meanR + s.meanG + s.meanB) / 3;
    if (avg <= 0) return const Look(preset: 'True skin');
    final r = s.meanR / avg, g = s.meanG / avg, b = s.meanB / avg;
    // Warm cast (red over blue) is cooled; the reverse is warmed. A small
    // difference is the scene, not the camera, and is left alone.
    final cast = r - b;
    final temperature = cast.abs() < 0.04 ? 0.0 : (-cast * 1.2).clamp(-0.6, 0.6);
    final greenCast = g - 1;
    final tint = greenCast.abs() < 0.03 ? 0.0 : (greenCast * 2).clamp(-0.4, 0.4);
    final shadows = s.medianLuma < 100 ? ((100 - s.medianLuma) / 100).clamp(0.0, 0.5) : 0.0;
    final exposure = s.medianLuma < 70 ? 0.2 : 0.0;
    return Look(
      preset: 'True skin',
      temperature: _r(temperature),
      tint: _r(tint),
      shadows: _r(shadows),
      exposure: exposure,
    );
  }

  // ── Presets: numbers with names, not code ──────────────────────────────────

  static const presets = <Look>[
    Look(preset: 'Office light', temperature: -0.18, tint: 0.08, contrast: 0.08, shadows: 0.12, saturation: -0.05),
    Look(preset: 'Window', temperature: 0.1, exposure: 0.15, highlights: -0.1, vibrance: 0.1),
    Look(preset: 'Restaurant', temperature: -0.3, exposure: 0.25, shadows: 0.2, contrast: -0.05, vignette: 0.15),
    Look(preset: 'Noon', highlights: -0.25, shadows: 0.1, contrast: -0.08, vibrance: 0.12),
    Look(preset: 'Evening indoors', temperature: 0.12, exposure: 0.1, shadows: 0.15, grain: 0.08, vignette: 0.1),
    Look(preset: 'Mono', saturation: -1, contrast: 0.12, grain: 0.1),
    Look(preset: 'Fade', contrast: -0.2, saturation: -0.2, exposure: 0.08, grain: 0.05),
  ];

  // ── The colour matrix ──────────────────────────────────────────────────────

  /// The 4×5 matrix Flutter's `ColorFilter.matrix` takes (row-major, offsets
  /// in 0..255), composed from the colour fields. Vibrance, highlights and
  /// shadows are approximations inside the matrix, and good enough here.
  List<double> matrix() {
    var m = _identity();
    // Exposure, temperature, tint and highlights are channel gains.
    final gain = math.pow(2.0, exposure).toDouble() * (1 + 0.15 * highlights);
    m = _mul(_diag(
      gain * (1 + 0.25 * temperature),
      gain * (1 - 0.2 * tint),
      gain * (1 - 0.25 * temperature),
    ), m);
    // Shadows lift the floor; highlights pull the ceiling.
    final offset = 30.0 * shadows - 15.0 * highlights;
    if (offset != 0) m = _mul(_offset(offset), m);
    if (contrast != 0) {
      final f = 1 + 0.75 * contrast;
      m = _mul(_withOffset(_diag(f, f, f), 128 * (1 - f)), m);
    }
    if (saturation != 0) m = _mul(_saturation(1 + saturation), m);
    if (vibrance != 0) m = _mul(_saturation(1 + 0.5 * vibrance), m);
    return m;
  }

  /// Apply [matrix] to one pixel, 0..255 per channel, clamped. For tests
  /// and for baking a look into a saved file.
  static List<double> apply(List<double> matrix, double r, double g, double b) {
    double row(int i) =>
        (matrix[i * 5] * r + matrix[i * 5 + 1] * g + matrix[i * 5 + 2] * b + matrix[i * 5 + 4]).clamp(0, 255);
    return [row(0), row(1), row(2)];
  }

  static List<double> _identity() => [
        1, 0, 0, 0, 0, //
        0, 1, 0, 0, 0, //
        0, 0, 1, 0, 0, //
        0, 0, 0, 1, 0, //
      ];

  static List<double> _diag(double r, double g, double b) => [
        r, 0, 0, 0, 0, //
        0, g, 0, 0, 0, //
        0, 0, b, 0, 0, //
        0, 0, 0, 1, 0, //
      ];

  static List<double> _offset(double o) => _withOffset(_identity(), o);

  static List<double> _withOffset(List<double> m, double o) {
    final out = List<double>.from(m);
    out[4] += o;
    out[9] += o;
    out[14] += o;
    return out;
  }

  static List<double> _saturation(double s) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final a = 1 - s;
    return [
      lr * a + s, lg * a, lb * a, 0, 0, //
      lr * a, lg * a + s, lb * a, 0, 0, //
      lr * a, lg * a, lb * a + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// `a` after `b`: the 4×4 parts multiply, the offsets carry through.
  static List<double> _mul(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 5; j++) {
        var v = 0.0;
        for (var k = 0; k < 4; k++) {
          v += a[i * 5 + k] * b[k * 5 + j];
        }
        if (j == 4) v += a[i * 5 + 4];
        out[i * 5 + j] = v;
      }
    }
    return out;
  }
}

/// What [Look.trueSkin] reads: the mean of each channel and the median
/// brightness, 0..255, computed once on this phone from a small copy of the
/// picture. Pure; a service fills it from pixels.
class ImageStats {
  final double meanR, meanG, meanB;
  final double medianLuma;
  const ImageStats({required this.meanR, required this.meanG, required this.meanB, required this.medianLuma});

  /// From interleaved RGB samples, 0..255.
  static ImageStats fromSamples(List<int> rgb) {
    final n = rgb.length ~/ 3;
    if (n == 0) return const ImageStats(meanR: 0, meanG: 0, meanB: 0, medianLuma: 0);
    var r = 0.0, g = 0.0, b = 0.0;
    final luma = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final cr = rgb[i * 3], cg = rgb[i * 3 + 1], cb = rgb[i * 3 + 2];
      r += cr;
      g += cg;
      b += cb;
      luma[i] = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb;
    }
    luma.sort();
    return ImageStats(meanR: r / n, meanG: g / n, meanB: b / n, medianLuma: luma[n ~/ 2]);
  }
}
