import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../../../core/widgets/app_snack.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/di/injection.dart';
import '../../../core/services/cloudinary_service.dart';
import '../../../core/state/auth_service.dart';
import '../../../core/theme/app_colors.dart';

/// Dedicated full-screen sign-in / sign-up page.
///
/// Routed at `/auth`. Replaces the cramped bottom-sheet form that lived
/// inside Settings. Two modes share the same scaffold so the user can flip
/// between Sign In and Sign Up without losing context.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.initialMode = AuthMode.signIn});

  final AuthMode initialMode;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

enum AuthMode { signIn, signUp }

class _AuthScreenState extends State<AuthScreen> {
  late AuthMode _mode = widget.initialMode;
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _showPassword = false;
  bool _busy = false;
  String _busyLabel = '';
  // Picked image for sign-up avatar. Uploaded to Cloudinary at submit time
  // so a failed signUp doesn't leave orphaned uploads. Optional.
  File? _avatarFile;

  AuthService get _auth => sl<AuthService>();
  CloudinaryService get _cloudinary => sl<CloudinaryService>();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool _isValidEmail(String s) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s.trim());

  Future<void> _submit() async {
    final name = _name.text.trim();
    final email = _email.text.trim();
    final password = _password.text;
    final confirm = _confirm.text;
    final messenger = ScaffoldMessenger.of(context);
    final isSignUp = _mode == AuthMode.signUp;

    if (isSignUp && name.isEmpty) {
      messenger.showAppSnack(
        const SnackBar(content: Text('Please enter your name')),
      );
      return;
    }
    if (!_isValidEmail(email)) {
      messenger.showAppSnack(
        const SnackBar(content: Text('Enter a valid email address')),
      );
      return;
    }
    if (password.length < 6) {
      messenger.showAppSnack(
        const SnackBar(content: Text('Password must be at least 6 characters')),
      );
      return;
    }
    if (isSignUp && password != confirm) {
      messenger.showAppSnack(
        const SnackBar(content: Text('Passwords don\'t match')),
      );
      return;
    }
    setState(() {
      _busy = true;
      _busyLabel = isSignUp ? 'Creating account' : 'Signing in';
    });
    try {
      if (isSignUp) {
        // Upload the optional avatar first so we have a URL to attach to the
        // user_metadata at creation time. If upload fails the user keeps the
        // form populated and can try again or skip the picture.
        String? avatarUrl;
        if (_avatarFile != null) {
          if (mounted) setState(() => _busyLabel = 'Uploading photo');
          try {
            // Hard cap so a stalled network can't pin the spinner forever.
            avatarUrl = await _cloudinary
                .uploadAvatar(_avatarFile!)
                .timeout(const Duration(seconds: 30));
          } catch (e) {
            // ignore: avoid_print
            print('[auth-ui] cloudinary upload failed: $e');
            if (!mounted) return;
            messenger.showAppSnack(
              SnackBar(content: Text('Picture upload failed: $e')),
            );
            // Stop here — we want the user to retry or remove the image so
            // they don't end up with an account missing the avatar they
            // explicitly picked.
            return;
          }
        }
        if (mounted) setState(() => _busyLabel = 'Creating account');
        // ignore: avoid_print
        print('[auth-ui] calling Supabase signUp for "$email"');
        await _auth
            .signUp(
              email: email,
              password: password,
              displayName: name,
              avatarUrl: avatarUrl,
            )
            .timeout(const Duration(seconds: 25));
        // ignore: avoid_print
        print('[auth-ui] signUp returned ok; signedIn=${_auth.isSignedIn}');
        if (!mounted) return;
        // Email confirmation is disabled in our Supabase config, so signUp
        // returns a live session. Bounce the user straight in. The fallback
        // path (mode flip + "confirm" toast) is kept for the case where
        // confirmation is re-enabled later or signUp silently returns no
        // session.
        if (_auth.isSignedIn) {
          messenger.showAppSnack(
            SnackBar(content: Text('Welcome, ${name.split(' ').first}!')),
          );
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/settings');
          }
        } else {
          messenger.showAppSnack(
            const SnackBar(
              content: Text('Account created. You can sign in now.'),
              duration: Duration(seconds: 4),
            ),
          );
          setState(() {
            _mode = AuthMode.signIn;
            _password.clear();
            _confirm.clear();
            _avatarFile = null;
          });
        }
      } else {
        // ignore: avoid_print
        print('[auth-ui] calling Supabase signInWithPassword for "$email"');
        await _auth
            .signInWithPassword(email: email, password: password)
            .timeout(const Duration(seconds: 20));
        // ignore: avoid_print
        print('[auth-ui] signIn returned ok');
        if (!mounted) return;
        messenger.showAppSnack(const SnackBar(content: Text('Signed in.')));
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/settings');
        }
      }
    } on TimeoutException catch (_) {
      if (!mounted) return;
      messenger.showAppSnack(
        const SnackBar(
          content: Text(
            'This is taking too long. Check your connection and try again.',
          ),
        ),
      );
    } catch (e) {
      // ignore: avoid_print
      print('[auth-ui] submit failed: $e');
      if (!mounted) return;
      final msg = e.toString().replaceFirst('AuthApiException: ', '');
      messenger.showAppSnack(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = '';
        });
      }
    }
  }

  Future<void> _pickAvatar(ImageSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 88,
      );
      if (picked == null) return;
      if (!mounted) return;
      setState(() => _avatarFile = File(picked.path));
    } catch (e) {
      if (!mounted) return;
      messenger.showAppSnack(SnackBar(content: Text('Picker failed: $e')));
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
                _pickAvatar(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickAvatar(ImageSource.camera);
              },
            ),
            if (_avatarFile != null)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'Remove picture',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  setState(() => _avatarFile = null);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _sendReset() async {
    final email = _email.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    if (!_isValidEmail(email)) {
      messenger.showAppSnack(
        const SnackBar(content: Text('Enter your email first')),
      );
      return;
    }
    try {
      await _auth.sendPasswordReset(email);
      if (!mounted) return;
      messenger.showAppSnack(
        const SnackBar(content: Text('Password-reset email sent.')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showAppSnack(SnackBar(content: Text('Reset failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSignUp = _mode == AuthMode.signUp;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/settings');
            }
          },
        ),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Center(
                child: Image.asset(
                  'assets/branding/sozo_logo_red.png',
                  height: 72,
                  width: 72,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                isSignUp ? 'Create your account' : 'Welcome back',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                isSignUp
                    ? 'Sync your library across all your devices.'
                    : 'Sign in to pick up where you left off.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.textTheme.bodySmall?.color,
                ),
              ),
              const SizedBox(height: 28),
              // Mode toggle
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(child: _modeChip('Sign in', AuthMode.signIn)),
                    Expanded(child: _modeChip('Sign up', AuthMode.signUp)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (isSignUp) ...[
                Center(
                  child: GestureDetector(
                    onTap: _busy ? null : _showAvatarSheet,
                    child: _AvatarPicker(
                      file: _avatarFile,
                      primary: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: _busy ? null : _showAvatarSheet,
                    child: Text(
                      _avatarFile == null
                          ? 'Add a profile picture (optional)'
                          : 'Change picture',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _name,
                  textInputAction: TextInputAction.next,
                  textCapitalization: TextCapitalization.words,
                  decoration: _inputDecoration(
                    theme,
                    label: 'Your name',
                    icon: Icons.person_outline_rounded,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                enableSuggestions: false,
                decoration: _inputDecoration(
                  theme,
                  label: 'Email',
                  icon: Icons.mail_outline_rounded,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: !_showPassword,
                textInputAction:
                    isSignUp ? TextInputAction.next : TextInputAction.go,
                onSubmitted: (_) => _busy || isSignUp ? null : _submit(),
                decoration: _inputDecoration(
                  theme,
                  label: 'Password',
                  icon: Icons.lock_outline_rounded,
                  suffix: IconButton(
                    icon: Icon(_showPassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                ),
              ),
              if (isSignUp) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _confirm,
                  obscureText: !_showPassword,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _busy ? null : _submit(),
                  decoration: _inputDecoration(
                    theme,
                    label: 'Confirm password',
                    icon: Icons.lock_outline_rounded,
                  ),
                ),
              ],
              if (!isSignUp)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _busy ? null : _sendReset,
                    child: const Text('Forgot password?'),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: _busy
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _busyLabel.isEmpty
                                ? 'Working…'
                                : '$_busyLabel…',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        isSignUp ? 'Create account' : 'Sign in',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
              ),
              const SizedBox(height: 18),
              // Footer toggle for users who hit the wrong mode.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    isSignUp
                        ? 'Already have an account?'
                        : 'Don\'t have an account?',
                    style: theme.textTheme.bodySmall,
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _mode =
                            isSignUp ? AuthMode.signIn : AuthMode.signUp),
                    child:
                        Text(isSignUp ? 'Sign in' : 'Sign up'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(
    ThemeData theme, {
    required String label,
    required IconData icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      suffixIcon: suffix,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.6),
      ),
      contentPadding:
          const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
    );
  }

  Widget _modeChip(String label, AuthMode mode) {
    final selected = _mode == mode;
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: _busy ? null : () => setState(() => _mode = mode),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: selected
                  ? Colors.white
                  : theme.colorScheme.onSurfaceVariant,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({required this.file, required this.primary});

  final File? file;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    const size = 104.0;
    return Stack(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: primary.withValues(alpha: 0.14),
            border: Border.all(
              color: primary.withValues(alpha: 0.5),
              width: 1.6,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: file == null
              ? Center(
                  child: Icon(
                    Icons.add_a_photo_outlined,
                    color: primary,
                    size: 30,
                  ),
                )
              : Image.file(file!, fit: BoxFit.cover),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: primary,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: const Icon(
              Icons.edit_rounded,
              color: Colors.white,
              size: 14,
            ),
          ),
        ),
      ],
    );
  }
}
