import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/di/injection.dart';
import '../../../core/services/cloudinary_service.dart';
import '../../../core/state/auth_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/avatar_palette.dart';

/// Account / profile page. Shown when the user is signed in.
///
/// Lets the user edit their display name and upload a profile picture
/// (Cloudinary, unsigned preset). Sign-out lives here too — no more nested
/// bottom-sheet for a destructive action.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  AuthService get _auth => sl<AuthService>();
  CloudinaryService get _cloudinary => sl<CloudinaryService>();

  bool _uploading = false;
  bool _savingName = false;
  late TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: _auth.displayName ?? '');
    // Rebuild whenever auth state changes (e.g. after updateProfile fires
    // an AuthChangeEvent.userUpdated).
    _auth.authStream.listen((_) {
      if (!mounted) return;
      setState(() {
        // Re-sync the text field if the live value diverged from local edits.
        final live = _auth.displayName ?? '';
        if (live != _nameCtrl.text && !_savingName) {
          _nameCtrl.text = live;
        }
      });
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAndUpload(ImageSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    final picker = ImagePicker();
    final XFile? picked = await picker.pickImage(
      source: source,
      // Pre-shrink on the client so we don't waste Cloudinary bandwidth on
      // 50 MB phone photos. Cloudinary's incoming-transform will trim further.
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 88,
    );
    if (picked == null) return;
    setState(() => _uploading = true);
    try {
      // Namespace by user ID so re-uploading replaces the previous file
      // (saves on storage and keeps URLs stable).
      final userId = _auth.currentUser?.id;
      final url = await _cloudinary.uploadAvatar(
        File(picked.path),
        publicId: userId == null ? null : 'sozoread/avatars/$userId',
      );
      await _auth.updateProfile(avatarUrl: url);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Profile picture updated.')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _saveName() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    if (name == (_auth.displayName ?? '')) return;
    setState(() => _savingName = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _auth.updateProfile(displayName: name);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Name updated.')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  void _showAvatarSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickAndUpload(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickAndUpload(ImageSource.camera);
              },
            ),
            if ((_auth.avatarUrl ?? '').isNotEmpty)
              ListTile(
                leading: const Icon(Icons.delete_outline,
                    color: Colors.redAccent),
                title: const Text(
                  'Remove current picture',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  try {
                    await _auth.updateProfile(avatarUrl: '');
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Removed.')),
                    );
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Remove failed: $e')),
                    );
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmSignOut() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Your saved library on this device will be cleared. Sign back in '
          'to restore it from the cloud.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await _auth.signOut();
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/settings');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Sign-out failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<AuthChangeEvent>(
      stream: _auth.authStream,
      builder: (context, _) {
        final email = _auth.cachedEmail ?? '';
        final avatar = _auth.avatarUrl ?? '';
        final initials = AvatarPalette.initialsFor(
          name: _auth.displayName,
          email: email,
        );
        // Seed by user.id when available (most stable across email changes),
        // falling back to email so the color is still deterministic during
        // the brief window before Supabase hydrates the session.
        final seedColor =
            AvatarPalette.colorFor(_auth.currentUser?.id ?? email);
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.background,
            elevation: 0,
            scrolledUnderElevation: 0,
            title: const Text('Profile'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/settings');
                }
              },
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Center(
                  child: Stack(
                    children: [
                      _Avatar(
                        url: avatar,
                        initials: initials,
                        size: 124,
                        uploading: _uploading,
                        color: seedColor,
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Material(
                          color: theme.colorScheme.primary,
                          shape: const CircleBorder(),
                          elevation: 2,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: _uploading ? null : _showAvatarSheet,
                            child: const Padding(
                              padding: EdgeInsets.all(10),
                              child: Icon(
                                Icons.camera_alt_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Center(
                  child: Text(
                    email,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  'DISPLAY NAME',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w700,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nameCtrl,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _saveName(),
                  decoration: InputDecoration(
                    hintText: 'How should we show your name?',
                    prefixIcon: const Icon(Icons.person_outline_rounded),
                    suffixIcon: _savingName
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.check_rounded),
                            onPressed: _saveName,
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: theme.colorScheme.primary,
                        width: 1.6,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                OutlinedButton.icon(
                  onPressed: _confirmSignOut,
                  icon: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                  label: const Text(
                    'Sign out',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: Colors.redAccent),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.url,
    required this.initials,
    required this.size,
    required this.color,
    this.uploading = false,
  });

  final String url;
  final String initials;
  final double size;
  final Color color;
  final bool uploading;

  @override
  Widget build(BuildContext context) {
    final hasImage = url.isNotEmpty;
    // The colored ring is meant to frame the initials fallback. Around a
    // real photo it reads as an accidental yellow/teal halo, so drop it
    // (and the tinted bg) when the image is loaded.
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hasImage ? Colors.transparent : color.withValues(alpha: 0.18),
        border: hasImage
            ? null
            : Border.all(color: color.withValues(alpha: 0.5), width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasImage)
            CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 180),
              errorWidget: (_, _, _) => _initialsView(),
            )
          else
            _initialsView(),
          if (uploading)
            Container(
              color: Colors.black.withValues(alpha: 0.45),
              alignment: Alignment.center,
              child: const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _initialsView() {
    return Center(
      child: Text(
        initials,
        style: TextStyle(
          color: color,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
