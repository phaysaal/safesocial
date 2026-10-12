import 'package:equatable/equatable.dart';

/// Everything that makes up a drawn avatar. Small integers into fixed lists,
/// so a spec is a few bytes and renders the same on every device.
class AvatarSpec with EquatableMixin {
  final int skin;
  final int hair;
  final int hairColor;
  final int eyes;
  final int mouth;
  final int glasses;
  final int extra;
  final int background;

  const AvatarSpec({
    this.skin = 2,
    this.hair = 1,
    this.hairColor = 0,
    this.eyes = 0,
    this.mouth = 0,
    this.glasses = 0,
    this.extra = 0,
    this.background = 0,
  });

  static const skins = 6;
  static const hairs = 7; // none, short, long, curly, bun, cap, mohawk
  static const hairColors = 6;
  static const eyeStyles = 3;
  static const mouths = 4; // smile, neutral, open, grin
  static const glassesStyles = 3; // none, round, square
  static const extras = 4; // none, earrings, beard, freckles
  static const backgrounds = 6;

  static int _n(Object? v, int max) {
    final i = v is int ? v : 0;
    return i < 0 || i >= max ? 0 : i;
  }

  factory AvatarSpec.fromJson(Map<String, dynamic> j) => AvatarSpec(
        skin: _n(j['skin'], skins),
        hair: _n(j['hair'], hairs),
        hairColor: _n(j['hairColor'], hairColors),
        eyes: _n(j['eyes'], eyeStyles),
        mouth: _n(j['mouth'], mouths),
        glasses: _n(j['glasses'], glassesStyles),
        extra: _n(j['extra'], extras),
        background: _n(j['background'], backgrounds),
      );

  Map<String, dynamic> toJson() => {
        'skin': skin,
        'hair': hair,
        'hairColor': hairColor,
        'eyes': eyes,
        'mouth': mouth,
        'glasses': glasses,
        'extra': extra,
        'background': background,
      };

  AvatarSpec copyWith({int? skin, int? hair, int? hairColor, int? eyes, int? mouth, int? glasses, int? extra, int? background}) =>
      AvatarSpec(
        skin: skin ?? this.skin,
        hair: hair ?? this.hair,
        hairColor: hairColor ?? this.hairColor,
        eyes: eyes ?? this.eyes,
        mouth: mouth ?? this.mouth,
        glasses: glasses ?? this.glasses,
        extra: extra ?? this.extra,
        background: background ?? this.background,
      );

  @override
  List<Object?> get props => [skin, hair, hairColor, eyes, mouth, glasses, extra, background];
}

/// Expressions a sticker can wear on top of a spec.
enum AvatarExpression { plain, wave, laugh, cry, love, thumbsUp, sleep }
