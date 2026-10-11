import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';

import '../../services/identity_service.dart';
import '../../services/media_service.dart';
import '../../widgets/avatar.dart';

import '../../services/relay_service.dart';

/// Screen to edit user display name and bio.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _nameController = TextEditingController();
  final _bioController = TextEditingController();
  bool _isSaving = false;
  String? _birthday;

  @override
  void initState() {
    super.initState();
    _birthday = context.read<IdentityService>().currentIdentity?.birthday;
    final profile = context.read<IdentityService>().currentIdentity;
    _nameController.text = profile?.displayName ?? '';
    _bioController.text = profile?.bio ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() => _isSaving = true);
    try {
      final idService = context.read<IdentityService>();
      await idService.updateProfile(
        displayName: name,
        bio: _bioController.text.trim(),
        birthday: _birthday,
      );
      
      // Sync to relay
      if (mounted) {
        final relay = context.read<RelayService>();
        await idService.publishProfileToRelay(relay);
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update profile: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _changeAvatar() async {
    final mediaService = context.read<MediaService>();
    final picked = await mediaService.pickAndStoreImage();
    if (picked != null && mounted) {
      final idService = context.read<IdentityService>();
      await idService.updateAvatar(picked);
      
      if (mounted) {
        final relay = context.read<RelayService>();
        await idService.publishProfileToRelay(relay);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final profile = context.watch<IdentityService>().currentIdentity;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Profile'),
        actions: [
          if (_isSaving)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          else
            TextButton(
              onPressed: _saveProfile,
              child: const Text('Save'),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Center(
              child: Stack(
                children: [
                  UserAvatar(displayName: profile?.displayName ?? '?', size: AvatarSize.large),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: CircleAvatar(
                      backgroundColor: cs.primary,
                      radius: 18,
                      child: IconButton(
                        icon: const Icon(Icons.camera_alt, size: 18, color: Colors.white),
                        onPressed: _changeAvatar,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Display Name',
                prefixIcon: Icon(Icons.person_outline),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _bioController,
              decoration: const InputDecoration(
                labelText: 'Bio',
                prefixIcon: Icon(Icons.info_outline),
                hintText: 'Tell your friends about yourself',
              ),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 20),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cake_outlined),
              title: Text(_birthday == null ? 'Birthday (optional)' : 'Birthday · ${_birthday!}'),
              subtitle: const Text('Shared with your contacts only, so they get a reminder. Year is not stored.'),
              trailing: _birthday == null
                  ? null
                  : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _birthday = null)),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime(2000, 6, 15),
                  firstDate: DateTime(1900),
                  lastDate: DateTime.now(),
                );
                if (picked != null) {
                  setState(() => _birthday =
                      '${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
