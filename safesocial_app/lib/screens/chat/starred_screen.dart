import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/message.dart';
import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';
import '../../services/library_service.dart';
import '../../services/sphere_chat_service.dart';
import '../../services/sphere_service.dart';

/// Messages the user starred, across every chat and sphere. Local only.
class StarredScreen extends StatelessWidget {
  const StarredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryService>();
    final chat = context.watch<ChatService>();
    final sphereChat = context.watch<SphereChatService>();
    final spheres = context.watch<SphereService>();
    final contacts = context.watch<ContactService>();
    final me = context.watch<IdentityService>().publicKey;

    String nameFor(String key) {
      if (key == me) return 'You';
      return contacts.getContact(key)?.displayName ?? '${key.substring(0, 8)}…';
    }

    final rows = <({Message message, String where, String route})>[];
    for (final entry in library.starred) {
      final chatKey = entry.key;
      final id = entry.value;
      final sphere = spheres.sphere(chatKey);
      final list = sphere != null ? sphereChat.messagesIn(chatKey) : (chat.conversations[chatKey] ?? const []);
      for (final m in list) {
        if (m.id == id) {
          rows.add((
            message: m,
            where: sphere?.name ?? nameFor(chatKey),
            route: sphere != null ? '/sphere/$chatKey/chat' : '/chat/$chatKey',
          ));
        }
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Starred messages')),
      body: rows.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Long-press a message and choose Star to keep it here.',
                    textAlign: TextAlign.center),
              ),
            )
          : ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final row = rows[i];
                final m = row.message;
                return ListTile(
                  leading: const Icon(Icons.star, color: Colors.amber),
                  title: Text(m.content.isNotEmpty ? m.content : ChatService.describeMessage(m),
                      maxLines: 3, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${nameFor(m.senderId)} · ${row.where} · '
                      '${m.timestamp.toLocal().toString().substring(0, 16)}'),
                  onTap: () => context.push(row.route),
                  trailing: IconButton(
                    icon: const Icon(Icons.star_border),
                    tooltip: 'Unstar',
                    onPressed: () => library.toggleStar(m.recipientId == me ? m.senderId : m.recipientId, m.id),
                  ),
                );
              },
            ),
    );
  }
}
