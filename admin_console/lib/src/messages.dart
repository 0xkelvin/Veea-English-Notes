import 'transport.dart';

/// Operator-facing text for every documented outcome (TRD 07 §6). Each says
/// what happened and what to do next. Server titles are never displayed.
class Messages {
  static const sessionEnded =
      'Your session ended or was revoked. Sign in again to continue.';
  static const accessRemoved =
      'Your admin access was removed, so the server refused this action. Ask a Super Admin if you still need access.';
  static const noAccess =
      'This account does not have admin access. Sign in with an Admin or Super Admin account.';
  static const steppedDown =
      'You stepped down to User. Admin access for this account has ended.';
  static const targetNotPermitted =
      'Your role does not allow this on this account. Its details were reloaded to show what you can still do.';
  static const notFound =
      'This account no longer exists. It may have been deleted. The list was refreshed.';
  static const changed =
      'This account changed while you were viewing it. The latest details are shown; review them and try again.';
  static const pendingDeletion =
      'This account is pending deletion. It cannot be suspended, reinstated or given a new role, and its data is being erased.';
  static const lastSuperAdmin =
      'At least one other active Super Admin must remain. Promote another Super Admin first, then try again.';
  static const rateLimited =
      'Too many admin requests. Wait a minute, then try again.';
  static const invalidRequest =
      'The server rejected the request. Check the search, reason and ticket reference.';
  static const offline =
      'Cannot reach the server. Check the connection and try again.';
  static const generic =
      'Something went wrong on the server. Try again; if it continues, report it.';

  static String statusConflict(String? status) => status == 'pending_deletion'
      ? pendingDeletion
      : 'This action is not allowed while the account is ${status ?? 'in its current state'}. The latest details are shown.';

  /// Text for an error that is shown in place (a list, detail or form).
  static String describe(Object e) {
    if (e is SessionEnded) return sessionEnded;
    if (e is Offline) return offline;
    if (e is! AdminApiException) return generic;
    return switch (e.code) {
      'unauthorized' => sessionEnded,
      'forbidden' => accessRemoved,
      'target_not_permitted' => targetNotPermitted,
      'not_found' => notFound,
      'lifecycle_conflict' || 'role_conflict' => changed,
      'status_conflict' => statusConflict(e.accountStatus),
      'last_super_admin' => lastSuperAdmin,
      'rate_limited' => rateLimited,
      'invalid_email' => 'Enter a valid email address.',
      'invalid_request' => invalidRequest,
      'invalid_credentials' => 'The email or password is incorrect.',
      'account_unavailable' => 'This account cannot sign in right now.',
      'invalid_code' =>
        'The code is wrong or expired. Check it, or request a new one.',
      'code_attempts_exceeded' => 'Too many wrong codes. Request a new code.',
      _ => generic,
    };
  }
}
