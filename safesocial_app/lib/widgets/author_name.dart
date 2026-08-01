import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../services/contact_service.dart';
import '../services/identity_service.dart';

/// What to call whoever wrote something.
///
/// Resolved by the reader rather than taken from the wire. "You" is the
/// reader's word for themselves, so only they can decide when it applies —
/// comments used to travel with the literal string 'You' baked in as the
/// author name, and everyone saw it against everybody else's comments.
///
/// A contact's own name for someone beats the name that travelled with the
/// content: the latter is whatever the author typed at the time, is not
/// verified by anything, and may since have changed.
String authorNameFor(
  BuildContext context, {
  required String authorId,
  String carried = '',
}) {
  if (authorId.isEmpty) return 'Someone';

  final myKey = context.watch<IdentityService>().publicKey;
  if (authorId == myKey) return 'You';

  for (final contact in context.watch<ContactService>().contacts) {
    if (contact.publicKey == authorId) return contact.displayName;
  }

  if (carried.trim().isNotEmpty) return carried;
  return authorId.length > 8 ? '${authorId.substring(0, 8)}…' : authorId;
}
