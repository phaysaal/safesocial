import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/sphere.dart';
import '../../services/call_service.dart';

/// Ask whether to ring the whole sphere, as audio or video, then start the
/// mesh call. Shared by the sphere header and the sphere chat bar.
Future<void> startGroupCallFlow(BuildContext context, Sphere sphere) async {
  final calls = context.read<CallService>();
  final router = GoRouter.of(context);
  final messenger = ScaffoldMessenger.of(context);

  final type = await showDialog<CallType>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Call ${sphere.name}?'),
      content: Text(
        'Everyone in this sphere (${sphere.members.length - 1} other '
        '${sphere.members.length == 2 ? 'person' : 'people'}) will be rung.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, CallType.audio),
          child: const Text('Audio'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, CallType.video),
          child: const Text('Video'),
        ),
      ],
    ),
  );
  if (type == null) return;

  try {
    await calls.startGroupCall(
      sphere.id,
      sphere.members.map((m) => m.identityKey).toList(),
      type,
    );
    router.push('/call');
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not start call: $e')));
  }
}
