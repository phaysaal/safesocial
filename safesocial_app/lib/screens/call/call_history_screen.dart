import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/call_service.dart';
import '../../services/contact_service.dart';

/// Calls made, taken and missed, kept on this device only.
class CallHistoryScreen extends StatelessWidget {
  const CallHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final calls = context.watch<CallService>();
    final contacts = context.watch<ContactService>();
    final log = calls.callLog;

    return Scaffold(
      appBar: AppBar(title: const Text('Calls')),
      body: log.isEmpty
          ? const Center(child: Text('No calls yet.'))
          : ListView.separated(
              itemCount: log.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final e = log[i];
                final peer = e['peer'] as String;
                final name = contacts.getContact(peer)?.displayName ?? '${peer.substring(0, 8)}…';
                final incoming = e['incoming'] == true;
                final answered = e['answered'] == true;
                final video = e['video'] == true;
                final at = DateTime.tryParse(e['at'] as String? ?? '')?.toLocal();
                final seconds = e['seconds'] as int? ?? 0;
                final missed = incoming && !answered;
                final cs = Theme.of(context).colorScheme;
                return ListTile(
                  leading: Icon(
                    missed
                        ? Icons.call_missed
                        : (incoming ? Icons.call_received : Icons.call_made),
                    color: missed ? cs.error : cs.primary,
                  ),
                  title: Text(name, style: TextStyle(color: missed ? cs.error : null)),
                  subtitle: Text(
                    '${video ? 'Video' : 'Voice'} · '
                    '${missed ? 'Missed' : (seconds > 0 ? '${seconds ~/ 60}m ${seconds % 60}s' : 'Not connected')}'
                    '${at == null ? '' : ' · ${at.toString().substring(0, 16)}'}',
                  ),
                  trailing: IconButton(
                    icon: Icon(video ? Icons.videocam_outlined : Icons.call_outlined),
                    onPressed: () async {
                      await calls.startCall(peer, name, video ? CallType.video : CallType.audio);
                      if (context.mounted) context.push('/call');
                    },
                  ),
                  onTap: () => context.push('/chat/$peer'),
                );
              },
            ),
    );
  }
}
