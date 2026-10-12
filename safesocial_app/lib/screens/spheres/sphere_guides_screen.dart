import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/sphere_info_service.dart';
import '../../services/sphere_service.dart';

/// A sphere's guides: ordered sets of its posts, made by admins.
class SphereGuidesScreen extends StatelessWidget {
  final String sphereId;
  const SphereGuidesScreen({super.key, required this.sphereId});

  @override
  Widget build(BuildContext context) {
    final info = context.watch<SphereInfoService>();
    final feed = context.watch<FeedService>();
    final sphere = context.watch<SphereService>().sphere(sphereId);
    final me = context.read<IdentityService>().publicKey;
    final admin = me != null && (sphere?.isAdmin(me) ?? false);
    final units = info.infoFor(sphereId).units;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(sphere == null ? 'Guides' : '${sphere.name} · guides')),
      body: units.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  admin
                      ? 'No guides yet. Open a post\'s menu and choose "Add to a guide" to start one.'
                      : 'No guides yet. An admin can gather posts into guides here.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            )
          : ListView(
              children: [
                for (final u in units)
                  ExpansionTile(
                    leading: const Icon(Icons.menu_book_outlined),
                    title: Text(u.title),
                    subtitle: Text('${u.postIds.length} post${u.postIds.length == 1 ? '' : 's'}'),
                    trailing: admin
                        ? IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Remove this guide',
                            onPressed: () => info.update(sphereId, (c) => c.copyWith(units: c.units.where((x) => x.id != u.id).toList())),
                          )
                        : null,
                    children: [
                      for (final (i, id) in u.postIds.indexed)
                        Builder(builder: (context) {
                          final post = feed.posts.where((p) => p.id == id).firstOrNull;
                          return ListTile(
                            leading: CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                            title: Text(post == null ? 'A post this device does not have' : (post.content.isEmpty ? '(media)' : post.content),
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: post == null ? null : Text(post.authorName),
                            onTap: post == null ? null : () => context.push('/post/$id'),
                            trailing: admin
                                ? IconButton(
                                    icon: const Icon(Icons.close, size: 18),
                                    onPressed: () => info.update(
                                        sphereId,
                                        (c) => c.copyWith(units: [
                                              for (final x in c.units)
                                                x.id == u.id ? x.copyWith(postIds: x.postIds.where((p) => p != id).toList()) : x
                                            ])),
                                  )
                                : null,
                          );
                        }),
                    ],
                  ),
              ],
            ),
    );
  }
}
