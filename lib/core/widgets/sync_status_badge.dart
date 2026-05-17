import 'package:flutter/material.dart';

import '../di/injection.dart';
import '../state/auth_service.dart';
import '../sync/library_sync_service.dart';

/// Small inline indicator of the [LibrarySyncService]'s current state.
///
/// Behavior:
/// * Hidden entirely when the user is signed out (no cloud to sync with).
/// * Hidden when status is `idle` and there's no recent activity — keeps the
///   AppBar clean during the steady state.
/// * Shows a spinner during `syncing`.
/// * Shows a red error glyph (tap → SnackBar with the last error) when
///   status is `error`.
class SyncStatusBadge extends StatefulWidget {
  const SyncStatusBadge({super.key});

  @override
  State<SyncStatusBadge> createState() => _SyncStatusBadgeState();
}

class _SyncStatusBadgeState extends State<SyncStatusBadge> {
  late final LibrarySyncService _sync = sl<LibrarySyncService>();
  late final AuthService _auth = sl<AuthService>();

  @override
  Widget build(BuildContext context) {
    if (!_auth.isSignedIn) return const SizedBox.shrink();
    return StreamBuilder<LibrarySyncStatus>(
      stream: _sync.statusStream,
      initialData: _sync.status,
      builder: (context, snapshot) {
        final status = snapshot.data ?? LibrarySyncStatus.idle;
        switch (status) {
          case LibrarySyncStatus.idle:
            return const SizedBox.shrink();
          case LibrarySyncStatus.syncing:
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Tooltip(
                message: 'Syncing your library…',
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            );
          case LibrarySyncStatus.error:
            return IconButton(
              tooltip: 'Sync error — tap for details',
              icon: const Icon(
                Icons.cloud_off_rounded,
                color: Color(0xFFE57373),
                size: 20,
              ),
              onPressed: () {
                final err = _sync.lastError ?? 'Unknown error';
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Sync failed: $err'),
                    action: SnackBarAction(
                      label: 'Retry',
                      onPressed: () => _sync.refresh(),
                    ),
                  ),
                );
              },
            );
        }
      },
    );
  }
}
