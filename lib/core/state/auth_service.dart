import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../di/injection.dart';
import '../repository/categories_repository.dart';
import '../repository/chapter_bookmarks_repository.dart';
import '../repository/library_categories_repository.dart';
import '../repository/library_repository.dart';
import '../repository/page_bookmarks_repository.dart';
import '../repository/read_chapters_repository.dart';
import '../sync/library_sync_service.dart';

/// Optional sign-in wrapper around Supabase auth.
///
/// The app is fully usable offline; this service is only consulted by the
/// Account section in Settings and (later) the cloud-sync layer. If Supabase
/// failed to initialize at boot (missing env vars, network down, etc.) the
/// service degrades gracefully — [isSignedIn] returns false and operations
/// throw a [StateError] that the UI surfaces as a SnackBar.
class AuthService {
  AuthService() {
    // Re-broadcast Supabase's auth state changes through our own controller so
    // consumers don't need to know about Supabase's stream shape.
    try {
      _sub = Supabase.instance.client.auth.onAuthStateChange.listen((data) {
        _controller.add(data.event);
        // Cache the user's email locally so the UI can render a "signed in
        // as ..." label without re-fetching from Supabase.
        final user = data.session?.user;
        final email = user?.email;
        final meta = user?.userMetadata;
        final box = _settingsBox;
        if (box != null) {
          if (data.event == AuthChangeEvent.signedOut) {
            box.delete(_emailKey);
            box.delete(_avatarKey);
            box.delete(_nameKey);
          } else {
            if (email != null && email.isNotEmpty) {
              box.put(_emailKey, email);
            }
            final avatar = meta?['avatar_url'] as String?;
            final name = meta?['display_name'] as String?;
            if (avatar != null && avatar.isNotEmpty) {
              box.put(_avatarKey, avatar);
            }
            if (name != null && name.isNotEmpty) {
              box.put(_nameKey, name);
            }
          }
        }
      });
    } catch (e) {
      // Supabase wasn't initialised — keep the service inert. Calls to
      // sendMagicLink/signOut will throw with a friendly message.
      debugPrint('[AuthService] Supabase not initialised: $e');
    }
  }

  static const String _emailKey = 'auth.email';
  static const String _avatarKey = 'auth.avatarUrl';
  static const String _nameKey = 'auth.displayName';
  static const String _boxName = 'settings';

  final StreamController<AuthChangeEvent> _controller =
      StreamController<AuthChangeEvent>.broadcast();
  StreamSubscription<AuthState>? _sub;

  Stream<AuthChangeEvent> get authStream => _controller.stream;

  GoTrueClient? get _auth {
    try {
      return Supabase.instance.client.auth;
    } catch (_) {
      return null;
    }
  }

  Box? get _settingsBox =>
      Hive.isBoxOpen(_boxName) ? Hive.box(_boxName) : null;

  User? get currentUser => _auth?.currentUser;

  bool get isSignedIn => currentUser != null;

  /// Returns the cached email from Hive (survives cold starts before Supabase
  /// has hydrated its session).
  String? get cachedEmail =>
      _settingsBox?.get(_emailKey) as String? ?? currentUser?.email;

  /// Cached avatar URL (Cloudinary). Falls back to live user_metadata once
  /// Supabase has hydrated.
  String? get avatarUrl {
    final live = currentUser?.userMetadata?['avatar_url'] as String?;
    if (live != null && live.isNotEmpty) return live;
    return _settingsBox?.get(_avatarKey) as String?;
  }

  /// Cached display name. Defaults to the email's local-part when unset.
  String? get displayName {
    final live = currentUser?.userMetadata?['display_name'] as String?;
    if (live != null && live.isNotEmpty) return live;
    final cached = _settingsBox?.get(_nameKey) as String?;
    if (cached != null && cached.isNotEmpty) return cached;
    final email = cachedEmail;
    if (email == null) return null;
    final at = email.indexOf('@');
    return at > 0 ? email.substring(0, at) : email;
  }

  Future<void> sendMagicLink(String email) async {
    final auth = _auth;
    if (auth == null) {
      throw StateError('Sign-in is unavailable right now. Try again later.');
    }
    final cleaned = email.trim();
    // ignore: avoid_print
    print('[auth] sending magic link to "$cleaned"');
    try {
      await auth.signInWithOtp(
        email: cleaned,
        emailRedirectTo: 'sozoread://login-callback',
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('[auth] magic link FAILED: $e\n$st');
      rethrow;
    }
  }

  /// Classic email + password sign-up. Sends a confirmation email to the
  /// address; the user must tap the `sozoread://login-callback` link before
  /// they're considered signed in.
  ///
  /// [displayName] / [avatarUrl] are written to `user_metadata` at creation
  /// time so the user's name + picture exist from the very first session
  /// (no second round-trip after sign-in).
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    String? displayName,
    String? avatarUrl,
  }) async {
    final auth = _auth;
    if (auth == null) {
      throw StateError('Sign-up is unavailable right now. Try again later.');
    }
    final meta = <String, dynamic>{};
    if (displayName != null && displayName.isNotEmpty) {
      meta['display_name'] = displayName;
    }
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      meta['avatar_url'] = avatarUrl;
    }
    try {
      return await auth.signUp(
        email: email.trim(),
        password: password,
        emailRedirectTo: 'sozoread://login-callback',
        data: meta.isEmpty ? null : meta,
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('[auth] sign-up FAILED: $e\n$st');
      rethrow;
    }
  }

  /// Classic email + password sign-in. Returns immediately on success; the
  /// auth-state stream emits a `signedIn` event in the same tick.
  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) async {
    final auth = _auth;
    if (auth == null) {
      throw StateError('Sign-in is unavailable right now. Try again later.');
    }
    try {
      return await auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('[auth] sign-in FAILED: $e\n$st');
      rethrow;
    }
  }

  /// Sends a password-reset email containing a `sozoread://login-callback`
  /// recovery link. Returns silently on success.
  Future<void> sendPasswordReset(String email) async {
    final auth = _auth;
    if (auth == null) {
      throw StateError('Reset unavailable right now. Try again later.');
    }
    try {
      await auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: 'sozoread://login-callback',
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('[auth] password reset FAILED: $e\n$st');
      rethrow;
    }
  }

  /// Patches Supabase user_metadata with the given fields. Pass null to leave
  /// a field unchanged; pass an empty string to clear it. Returns the updated
  /// user. Also caches the new values in Hive so the UI doesn't flash on
  /// next launch before Supabase rehydrates.
  Future<User> updateProfile({String? avatarUrl, String? displayName}) async {
    final auth = _auth;
    if (auth == null) {
      throw StateError('Profile update unavailable. Sign in first.');
    }
    final data = <String, dynamic>{};
    if (avatarUrl != null) data['avatar_url'] = avatarUrl;
    if (displayName != null) data['display_name'] = displayName;
    if (data.isEmpty) {
      // Nothing to do — return the current user instead of round-tripping.
      final u = currentUser;
      if (u == null) throw StateError('Not signed in.');
      return u;
    }
    final resp = await auth.updateUser(UserAttributes(data: data));
    final user = resp.user;
    if (user == null) throw StateError('Profile update returned no user.');
    final box = _settingsBox;
    if (box != null) {
      if (avatarUrl != null) box.put(_avatarKey, avatarUrl);
      if (displayName != null) box.put(_nameKey, displayName);
    }
    // Push a synthetic event so listeners (e.g. the profile screen) rebuild.
    _controller.add(AuthChangeEvent.userUpdated);
    return user;
  }

  Future<void> signOut() async {
    final auth = _auth;
    if (auth == null) {
      throw StateError('Sign-out failed: auth not initialised.');
    }
    // Stop the sync engine BEFORE wiping local state, otherwise the
    // box-watcher would interpret the bulk-clear as user deletions and
    // try to push them under whatever session is still active.
    try {
      await sl<LibrarySyncService>().stop();
    } catch (e) {
      debugPrint('[auth] sync stop on sign-out failed: $e');
    }
    // Disassociate this device from the previous account: wipe the saved
    // library + reading history + any queued sync state so they don't
    // leak into the next sign-in. Downloads are kept (concrete files the
    // user explicitly chose to keep offline).
    try {
      await sl<LibraryRepository>().clear(forSignOut: true);
    } catch (e) {
      debugPrint('[auth] library clear on sign-out failed: $e');
    }
    try {
      await sl<ReadChaptersRepository>().clear(forSignOut: true);
    } catch (e) {
      debugPrint('[auth] read_chapters clear on sign-out failed: $e');
    }
    try {
      await sl<ChapterBookmarksRepository>().clear(forSignOut: true);
    } catch (e) {
      debugPrint('[auth] chapter_bookmarks clear on sign-out failed: $e');
    }
    try {
      await sl<PageBookmarksRepository>().clear(forSignOut: true);
    } catch (e) {
      debugPrint('[auth] page_bookmarks clear on sign-out failed: $e');
    }
    try {
      await sl<CategoriesRepository>().clear(forSignOut: true);
    } catch (e) {
      debugPrint('[auth] categories clear on sign-out failed: $e');
    }
    try {
      await sl<LibraryCategoriesRepository>().clear(forSignOut: true);
    } catch (e) {
      debugPrint('[auth] library_entry_categories clear on sign-out failed: $e');
    }
    await auth.signOut();
    await _settingsBox?.delete(_emailKey);
    // Re-arm the sync service so a subsequent sign-in (without restarting
    // the app) still gets pull/push wired up.
    try {
      // ignore: unawaited_futures
      sl<LibrarySyncService>().start();
    } catch (e) {
      debugPrint('[auth] sync restart after sign-out failed: $e');
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
