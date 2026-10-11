import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/models/media_provenance.dart';
import 'package:spheres_app/models/message.dart';
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/services/library_service.dart';
import 'package:spheres_app/services/media_service.dart';
import 'package:spheres_app/services/provenance_scanner.dart';
import 'package:spheres_app/services/secure_store.dart';

/// A JPEG with the EXIF a phone camera writes, and optional edits.
Uint8List cameraJpeg({
  int width = 4000,
  int height = 3000,
  String? software,
  String original = '2026:10:11 14:03:22',
  String? modified,
}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(90, 120, 200));
  image.exif.imageIfd['Make'] = 'Google';
  image.exif.imageIfd['Model'] = 'Pixel 9';
  image.exif.imageIfd['DateTime'] = modified ?? original;
  image.exif.exifIfd['DateTimeOriginal'] = original;
  if (software != null) image.exif.imageIfd['Software'] = software;
  return Uint8List.fromList(img.encodeJpg(image, quality: 50));
}

/// A JPEG with no metadata at all, as a messaging app or a generator saves.
Uint8List bareJpeg({int width = 1024, int height = 1024}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 90, 90));
  return Uint8List.fromList(img.encodeJpg(image, quality: 50));
}

Uint8List pngWithText(Map<String, String> text, {int width = 512, int height = 512}) {
  final image = img.Image(width: width, height: height);
  image.addTextData(text);
  return Uint8List.fromList(img.encodePng(image));
}

/// Insert an APPn segment right after SOI, as metadata writers do.
Uint8List withSegment(Uint8List jpeg, int marker, List<int> payload) {
  final len = payload.length + 2;
  return Uint8List.fromList([
    0xFF, 0xD8,
    0xFF, marker, (len >> 8) & 0xFF, len & 0xFF,
    ...payload,
    ...jpeg.sublist(2),
  ]);
}

Uint8List withXmp(Uint8List jpeg, String xml) => withSegment(
    jpeg, 0xE1, [...utf8.encode('http://ns.adobe.com/xap/1.0/'), 0, ...utf8.encode(xml)]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('scoring from the file itself', () {
    MediaProvenance scan(Uint8List bytes, {String? name, String source = 'gallery',
        String? folder}) =>
        ProvenanceScanner.assessImage(bytes, source: source, fileName: name, relativePath: folder);

    test('the camera button is the strongest claim, whatever the file says', () {
      final p = scan(bareJpeg(), source: 'camera');
      expect(p.score, 10);
      expect(p.source, 'camera');
      expect(p.has(ProvenanceSignal.cameraCapture), isTrue);
      expect(p.band, 'Live camera');
    });

    test('an unedited high-resolution camera photo scores 9', () {
      final p = scan(cameraJpeg(), name: 'PXL_20261011_140322123.jpg');
      expect(p.score, 9);
      expect(p.signals, containsAll([
        ProvenanceSignal.cameraExif,
        ProvenanceSignal.unedited,
        ProvenanceSignal.cameraFileName,
        ProvenanceSignal.highResolution,
      ]));
      expect(p.note, contains('no sign of editing'));
    });

    test('camera data without a camera name or high resolution scores 8', () {
      final p = scan(cameraJpeg(width: 1600, height: 1200), name: 'holiday.jpg');
      expect(p.score, 8);
    });

    test('a camera photo saved by editing software scores 6 and names the tool', () {
      final p = scan(cameraJpeg(software: 'Adobe Photoshop Lightroom 7.1'));
      expect(p.score, 6);
      expect(p.has(ProvenanceSignal.editedBySoftware), isTrue);
      expect(p.tool, 'Adobe Photoshop Lightroom 7.1');
      expect(p.note, contains('editing software'));
    });

    test('camera firmware in the Software tag is not an edit', () {
      final p = scan(cameraJpeg(software: 'HDR+ 1.0.540104767zd'));
      expect(p.has(ProvenanceSignal.editedBySoftware), isFalse);
      expect(p.score, greaterThanOrEqualTo(8));
    });

    test('a change date well after the original date scores 7', () {
      final p = scan(cameraJpeg(modified: '2026:10:12 09:00:00'));
      expect(p.score, 7);
      expect(p.has(ProvenanceSignal.editedDates), isTrue);
      expect(p.note, contains('changed after it was taken'));
    });

    test('two camera timestamps a few seconds apart still count as unedited', () {
      final p = scan(cameraJpeg(modified: '2026:10:11 14:03:25'));
      expect(p.has(ProvenanceSignal.unedited), isTrue);
    });

    test('a camera photo that came through a messaging app loses a point', () {
      final p = scan(cameraJpeg(), name: 'IMG-20261011-WA0012.jpg');
      expect(p.score, 8);
      expect(p.has(ProvenanceSignal.messagingFileName), isTrue);
    });

    test('no metadata and a messaging-app name scores 3', () {
      final p = scan(bareJpeg(width: 1600, height: 1200), name: 'IMG-20261011-WA0012.jpg');
      expect(p.score, 3);
      expect(p.note, contains('messaging app'));
    });

    test('a screenshot by name scores 2', () {
      final p = scan(bareJpeg(width: 1080, height: 2400), name: 'Screenshot_20261011-140322.png');
      expect(p.score, 2);
      expect(p.has(ProvenanceSignal.screenshot), isTrue);
    });

    test('a phone-screen-shaped image without camera data looks like a screenshot', () {
      final p = scan(bareJpeg(width: 1080, height: 2340), name: 'picture.jpg');
      expect(p.has(ProvenanceSignal.screenshot), isTrue);
      expect(p.score, 2);
    });

    test('a square multiple-of-64 image without metadata is generator-shaped', () {
      final p = scan(bareJpeg(width: 1024, height: 1024), name: 'picture.jpg');
      expect(p.has(ProvenanceSignal.generatorDimensions), isTrue);
      expect(p.score, 2);
      expect(p.note, contains('image generators'));
    });

    test('a large image with no metadata and an ordinary name is simply unknown', () {
      final p = scan(bareJpeg(width: 4000, height: 3000), name: 'picture.jpg');
      expect(p.score, 4);
      expect(p.band, 'Origin unknown');
      expect(p.has(ProvenanceSignal.noMetadata), isTrue);
    });

    test('a camera-style name with stripped metadata is a weak 5', () {
      final p = scan(bareJpeg(width: 4000, height: 3000), name: 'IMG_20261011_140322.jpg');
      expect(p.score, 5);
    });

    test('Content Credentials marking the image as generated score 0', () {
      final xmp = '<x:xmpmeta><rdf:Description '
          'Iptc4xmpExt:DigitalSourceType="http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia" '
          'xmp:CreatorTool="ChatGPT"/></x:xmpmeta>';
      final p = scan(withXmp(bareJpeg(), xmp), name: 'picture.jpg');
      expect(p.score, 0);
      expect(p.has(ProvenanceSignal.generatorMarked), isTrue);
      expect(p.tool, 'ChatGPT');
      expect(p.band, 'Marked as AI-generated');
      expect(p.note, contains('made with AI'));
    });

    test('a C2PA manifest naming a generator in APP11 scores 0', () {
      final manifest = utf8.encode('JP jumb c2pa.claim claim_generator "Adobe Firefly 3" '
          'http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia');
      final p = scan(withSegment(bareJpeg(), 0xEB, manifest));
      expect(p.score, 0);
      expect(p.tool, 'Adobe Firefly');
    });

    test('Stable Diffusion settings in a PNG text chunk score 0', () {
      final p = scan(pngWithText({
        'parameters': 'a cat in space\nNegative prompt: blurry\nSteps: 20, Sampler: Euler a, Seed: 1',
      }));
      expect(p.score, 0);
      expect(p.tool, 'Stable Diffusion');
    });

    test('a ComfyUI workflow in PNG text scores 0', () {
      final p = scan(pngWithText({'prompt': '{"3": {}}', 'workflow': '{"nodes": []}'}));
      expect(p.score, 0);
      expect(p.tool, 'ComfyUI');
    });

    test('an AI edit of a real photo scores 2', () {
      final xmp = '<x:xmpmeta Iptc4xmpExt:DigitalSourceType='
          '"http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"/>';
      final p = scan(withXmp(cameraJpeg(), xmp));
      expect(p.score, 2);
      expect(p.has(ProvenanceSignal.aiEdited), isTrue);
      expect(p.note, contains('edited with AI tools'));
    });

    test('a generator name in a caption does not mark a photo', () {
      // "imagen" is Spanish for picture; a description is not a tool field.
      final xmp = '<x:xmpmeta><dc:description>imagen de la playa con gemini mi perro</dc:description></x:xmpmeta>';
      final p = scan(withXmp(cameraJpeg(), xmp), name: 'IMG_0001.jpg');
      expect(p.has(ProvenanceSignal.generatorMarked), isFalse);
      expect(p.score, greaterThanOrEqualTo(8));
    });

    test('a generator-style download name scores 1 but a similar word does not', () {
      expect(scan(bareJpeg(), name: 'ChatGPT Image Oct 11, 2026, 02_30_15 PM.png').score, 1);
      expect(scan(pngWithText({}), name: '00012-1234567890.png').tool, 'Stable Diffusion');
      final fireflies = scan(cameraJpeg(), name: 'fireflies_at_night.jpg');
      expect(fireflies.has(ProvenanceSignal.generatorFileName), isFalse);
      expect(fireflies.score, greaterThanOrEqualTo(8));
    });

    test('a PNG without camera data scores 3, cameras do not write PNGs', () {
      // Not square and not a multiple of 64, so nothing else applies.
      final p = scan(pngWithText({}, width: 700, height: 500), name: 'drawing.png');
      expect(p.score, 3);
      expect(p.note, contains('PNG'));
    });

    test('folder evidence counts when a caller has it', () {
      expect(
        scan(cameraJpeg(width: 1600, height: 1200), name: 'x.jpg', folder: 'DCIM/Camera').score,
        9,
      );
      expect(
        scan(cameraJpeg(width: 1600, height: 1200), name: 'x.jpg', folder: 'Download').score,
        7,
      );
      expect(scan(bareJpeg(width: 1600, height: 1200), name: 'x.jpg', folder: 'Pictures/Screenshots')
          .has(ProvenanceSignal.screenshot), isTrue);
    });

    test('garbage bytes are assessed, not thrown on', () {
      final p = scan(Uint8List.fromList(List.generate(300, (i) => i % 251)), name: 'x.jpg');
      expect(p.score, 4);
    });
  });

  group('wire form', () {
    test('round-trips and survives in posts and messages', () {
      final p = ProvenanceScanner.assessImage(cameraJpeg(), source: 'gallery', fileName: 'IMG_1.jpg');
      expect(MediaProvenance.fromJson(jsonDecode(jsonEncode(p.toJson()))), p);

      final post = Post(
        id: 'p',
        authorId: 'a',
        content: '',
        mediaRefs: const ['x', 'y'],
        provenance: [p, null],
        createdAt: DateTime(2026),
        sphereId: 's',
      );
      final back = Post.fromJson(jsonDecode(jsonEncode(post.toJson())));
      expect(back.provenance, [p, null]);

      final msg = Message(
        id: 'm',
        senderId: 'a',
        recipientId: 'b',
        content: '',
        timestamp: DateTime(2026),
        mediaRefs: const ['x'],
        provenance: [MediaProvenance.liveCamera],
      );
      final msgBack = Message.fromJson(jsonDecode(jsonEncode(msg.toJson())));
      expect(msgBack.provenance.single, MediaProvenance.liveCamera);
    });

    test('nothing assessed means no field on the wire', () {
      final post = Post(
        id: 'p', authorId: 'a', content: '', mediaRefs: const ['x'], provenance: const [null],
        createdAt: DateTime(2026), sphereId: 's',
      );
      expect(post.toJson().containsKey('provenance'), isFalse);
      expect(Post.fromJson(post.toJson()).provenance, isEmpty);
    });

    test('a received claim is clamped and filtered, never trusted raw', () {
      final p = MediaProvenance.fromJson({
        's': 99,
        'src': 'teleport',
        'g': ['camera_exif', 'made_up', 42],
        'm': '<script>Evil Tool</script>' * 5,
      })!;
      expect(p.score, 10);
      expect(p.source, 'gallery');
      expect(p.signals, ['camera_exif']);
      expect(p.tool!.length, lessThanOrEqualTo(40));
      expect(p.tool, isNot(contains('<')));
      expect(MediaProvenance.fromJson({'s': 'high'}), isNull);
      expect(MediaProvenance.fromJson('nope'), isNull);
      expect(MediaProvenance.fromJson({'s': -3})!.score, 0);
    });

    test('the note is rendered on this device from codes, never from the sender', () {
      final p = MediaProvenance.fromJson({'s': 0, 'src': 'gallery', 'g': ['gen_marked'], 'm': 'Midjourney'})!;
      expect(p.note, 'Its own metadata says it was made with AI (Midjourney).');
      expect(MediaProvenance.fromJson({'s': 4, 'src': 'gallery'})!.note, 'Origin could not be determined.');
    });
  });

  group('stored beside the picked file', () {
    test('a picked image is re-encoded without metadata and keeps its score in a sidecar',
        () async {
      final dir = await Directory.systemTemp.createTemp('prov');
      addTearDown(() => dir.delete(recursive: true));
      final original = cameraJpeg(width: 3000, height: 2000);
      final claim = ProvenanceScanner.assessImage(original, source: 'gallery', fileName: 'IMG_1.jpg');

      final path = await MediaService.storePickedImage(original, provenance: claim, into: dir);
      final stored = await File(path).readAsBytes();
      final decoded = img.decodeImage(stored)!;
      expect(decoded.width, MediaService.pickedLongestSide);
      expect(decoded.height, (2000 * MediaService.pickedLongestSide / 3000).round());
      expect(img.decodeJpgExif(stored)?.isEmpty ?? true, isTrue, reason: 'EXIF must not survive');

      expect(MediaService.provenanceFor(path), claim);
      expect(MediaService.provenanceListFor([path, 'missing.jpg']), [claim, null]);

      await MediaService().deleteMedia(path);
      expect(File(MediaService.provenancePathFor(path)).existsSync(), isFalse);
    });

    test('bytes that are not an image are refused, not stored', () async {
      final dir = await Directory.systemTemp.createTemp('prov');
      addTearDown(() => dir.delete(recursive: true));
      expect(
        () => MediaService.storePickedImage(Uint8List.fromList([1, 2, 3]),
            provenance: MediaProvenance.liveCamera, into: dir),
        throwsA(isA<MediaRejectedException>()),
      );
    });
  });

  group('blur until tapped', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await SecureStore.instance.init();
    });

    test('is per chat or sphere, local, and survives a reload', () async {
      final library = LibraryService();
      await library.load();
      expect(library.isMediaBlurred('peer'), isFalse);
      await library.toggleBlurMedia('peer');
      await library.toggleBlurMedia('sphere-1');
      expect(library.isMediaBlurred('peer'), isTrue);
      expect(library.blursAnyOf({'other', 'sphere-1'}), isTrue);
      expect(library.blursAnyOf({'other'}), isFalse);

      final again = LibraryService();
      await again.load();
      expect(again.isMediaBlurred('peer'), isTrue);
      await again.toggleBlurMedia('peer');
      expect(again.isMediaBlurred('peer'), isFalse);
    });
  });
}
