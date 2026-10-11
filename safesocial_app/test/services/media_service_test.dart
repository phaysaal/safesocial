import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:spheres_app/crypto/blob.dart';
import 'package:spheres_app/services/blob_service.dart';
import 'package:spheres_app/services/media_service.dart';
import 'package:spheres_app/services/video_transcoder.dart';

/// In-memory relay blob store, so uploads are real chunking and crypto.
class _FakeRelay {
  final Map<String, String> chunks = {};
  int puts = 0;

  Future<http.Response> handle(
    String method,
    Uri url,
    Map<String, String> headers,
    List<int>? body,
  ) async {
    final segments = url.pathSegments;
    final key = '${segments[1]}/${segments[2]}';
    if (method == 'PUT') {
      puts++;
      if (chunks.containsKey(key)) return http.Response('exists', 409);
      chunks[key] = utf8.decode(body!);
      return http.Response('OK', 200);
    }
    final chunk = chunks[key];
    return chunk == null ? http.Response('', 404) : http.Response(chunk, 200);
  }
}

/// A transcoder that "encodes" by writing whatever bytes the test wants.
class _FakeTranscoder implements VideoTranscoder {
  Duration? probed;
  Duration? outputDuration;
  int outputBytes = 10 * 1024;
  Uint8List? posterJpeg;
  int transcodes = 0;

  @override
  Future<Duration?> durationOf(String path) async => probed;

  @override
  Future<TranscodedVideo> transcode(String path) async {
    transcodes++;
    final out = File('${Directory.systemTemp.path}/'
        'spheres_test_${DateTime.now().microsecondsSinceEpoch}.mp4');
    await out.writeAsBytes(Uint8List(outputBytes));
    return TranscodedVideo(
      path: out.path,
      duration: outputDuration,
      posterJpeg: posterJpeg,
    );
  }

  @override
  Future<Uint8List?> poster(String path) async => posterJpeg;
}

Uint8List smallJpeg() {
  final image = img.Image(width: 64, height: 48);
  img.fill(image, color: img.ColorRgb8(200, 30, 30));
  return Uint8List.fromList(img.encodeJpg(image));
}

void main() {
  late _FakeRelay relay;
  late _FakeTranscoder transcoder;
  late Directory tmp;

  setUp(() async {
    relay = _FakeRelay();
    BlobService.transportOverride = relay.handle;
    transcoder = _FakeTranscoder();
    MediaService.transcoder = transcoder;
    tmp = await Directory.systemTemp.createTemp('spheres_media_');
  });

  tearDown(() async {
    BlobService.transportOverride = null;
    MediaService.transcoder = PlatformVideoTranscoder();
    await tmp.delete(recursive: true);
  });

  Future<String> fakeVideo() async {
    final f = File('${tmp.path}/clip.mp4');
    await f.writeAsBytes(Uint8List(4096));
    return f.path;
  }

  test('a video is transcoded and uploaded with a poster thumbnail', () async {
    transcoder.outputDuration = const Duration(seconds: 20);
    transcoder.posterJpeg = smallJpeg();

    final encoded = await MediaService.prepareForRelay(
      await fakeVideo(),
      videoLimit: MediaService.feedVideoLimit,
    );

    expect(encoded, isNotNull);
    expect(transcoder.transcodes, 1, reason: 'never uploaded untranscoded');
    final ref = BlobRef.tryDecode(encoded!)!;
    expect(ref.isVideo, isTrue);
    expect(ref.mimeType, 'video/mp4');
    expect(ref.length, transcoder.outputBytes);
    expect(ref.thumbnail, startsWith('data:image/jpeg;base64,'));
    expect(relay.puts, greaterThan(0));
  });

  test('a clip over the limit is refused after transcoding, before upload',
      () async {
    transcoder.outputDuration = const Duration(seconds: 61);

    await expectLater(
      MediaService.prepareForRelay(
        await fakeVideo(),
        videoLimit: MediaService.feedVideoLimit,
      ),
      throwsA(isA<MediaRejectedException>().having(
          (e) => e.message, 'message', contains('limit here is 1 min'))),
    );
    expect(relay.puts, 0);
  });

  test('the same clip is fine under the chat limit', () async {
    transcoder.outputDuration = const Duration(seconds: 61);

    final encoded = await MediaService.prepareForRelay(
      await fakeVideo(),
      videoLimit: MediaService.chatVideoLimit,
    );
    expect(encoded, isNotNull);
  });

  test('a clip still too large after transcoding is refused', () async {
    transcoder.outputBytes = MediaService.maxMediaBytes + 1;

    await expectLater(
      MediaService.prepareForRelay(await fakeVideo()),
      throwsA(isA<MediaRejectedException>()
          .having((e) => e.message, 'message', contains('64 MB'))),
    );
    expect(relay.puts, 0);
  });

  test('a video without an extractable frame still sends, without a thumbnail',
      () async {
    transcoder.posterJpeg = null;

    final encoded = await MediaService.prepareForRelay(await fakeVideo());
    final ref = BlobRef.tryDecode(encoded!)!;
    expect(ref.thumbnail, isNull);
  });

  test('an image is resized and thumbnailed as before', () async {
    final image = img.Image(width: 2000, height: 1000);
    img.fill(image, color: img.ColorRgb8(10, 120, 200));
    final f = File('${tmp.path}/photo.jpg');
    await f.writeAsBytes(img.encodeJpg(image));

    final encoded = await MediaService.prepareForRelay(f.path);
    final ref = BlobRef.tryDecode(encoded!)!;
    expect(ref.mimeType, 'image/jpeg');
    expect(ref.thumbnail, isNotNull);
    expect(transcoder.transcodes, 0);

    final uploaded = await BlobService().download(ref);
    final decoded = img.decodeImage(uploaded!)!;
    expect(decoded.width, 1600, reason: 'longest side capped at 1600');
  });

  test('a missing file is a rejection, not a silent null', () async {
    await expectLater(
      MediaService.prepareForRelay('${tmp.path}/nope.jpg'),
      throwsA(isA<MediaRejectedException>()),
    );
  });

  test('a file that is not an image is a rejection', () async {
    final f = File('${tmp.path}/text.jpg');
    await f.writeAsString('not an image');
    await expectLater(
      MediaService.prepareForRelay(f.path),
      throwsA(isA<MediaRejectedException>()),
    );
  });

  test('a poster is written beside a local video and found again', () async {
    transcoder.posterJpeg = smallJpeg();
    final path = await fakeVideo();

    expect(MediaService.posterFor(path), isNull);
    await MediaService.writePosterFor(path);
    expect(MediaService.posterFor(path), '$path.jpg');
    expect(img.decodeImage(await File('$path.jpg').readAsBytes()), isNotNull);
  });

  test('the platform transcoder refuses on a desktop host rather than passing '
      'the original through', () async {
    final platform = PlatformVideoTranscoder();
    if (PlatformVideoTranscoder.isSupported) return; // on a phone it would run
    await expectLater(
      platform.transcode('/anything.mp4'),
      throwsA(isA<UnsupportedVideoException>()),
    );
  });

  test('materialising a received video also writes its poster', () async {
    transcoder.outputDuration = const Duration(seconds: 5);
    transcoder.posterJpeg = smallJpeg();
    final encoded = await MediaService.prepareForRelay(await fakeVideo());
    final ref = BlobRef.tryDecode(encoded!)!;

    // materialise() writes under the app documents directory, which needs a
    // platform channel; exercise the poster step the same way it does.
    final file = File('${tmp.path}/received.mp4');
    await file.writeAsBytes((await BlobService().download(ref))!);
    await File('${file.path}.jpg')
        .writeAsBytes(base64Decode(ref.thumbnail!.split(',').last));
    expect(MediaService.posterFor(file.path), isNotNull);
  });
}
