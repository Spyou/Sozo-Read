import 'package:flutter/material.dart';

/// Drop-in replacement for [ScaffoldMessengerState.showSnackBar] that:
///
///   1. **Clears the snackbar queue first** — Flutter's default behavior
///      is to enqueue new snackbars behind the current one, so a user
///      who taps several actions in a row has to swipe down through a
///      stack of stale messages. We kill the queue + currently-visible
///      snackbar so the newest message always wins.
///   2. **Caps duration at 2 seconds** when the caller didn't override
///      it — the framework default is 4 seconds, which is annoyingly
///      long for transient confirmations like "Bookmarked".
///
/// Callers that want a longer duration (e.g. an Undo snackbar) should
/// pass an explicit `duration:` on the SnackBar and that value wins.
extension AppSnack on ScaffoldMessengerState {
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showAppSnack(
    SnackBar snack,
  ) {
    clearSnackBars();
    // The framework's default duration is exactly 4 seconds. If the
    // caller didn't customize it, swap in 2s. Custom durations (e.g.
    // an Undo snackbar that wants 3s+) pass through unchanged.
    final snackToShow = snack.duration == const Duration(milliseconds: 4000)
        ? _withDuration(snack, const Duration(milliseconds: 2000))
        : snack;
    return showSnackBar(snackToShow);
  }

  /// Convenience for the common "just show this text" case.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showAppSnackText(
    String message, {
    Duration? duration,
  }) {
    return showAppSnack(SnackBar(
      content: Text(message),
      duration: duration ?? const Duration(milliseconds: 2000),
    ));
  }

  SnackBar _withDuration(SnackBar original, Duration d) {
    return SnackBar(
      key: original.key,
      content: original.content,
      backgroundColor: original.backgroundColor,
      elevation: original.elevation,
      margin: original.margin,
      padding: original.padding,
      width: original.width,
      shape: original.shape,
      hitTestBehavior: original.hitTestBehavior,
      behavior: original.behavior,
      action: original.action,
      actionOverflowThreshold: original.actionOverflowThreshold,
      showCloseIcon: original.showCloseIcon,
      closeIconColor: original.closeIconColor,
      duration: d,
      animation: original.animation,
      onVisible: original.onVisible,
      dismissDirection: original.dismissDirection,
      clipBehavior: original.clipBehavior,
    );
  }
}
