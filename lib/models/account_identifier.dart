/// Whether a typed identifier is an email address or a phone number.
enum IdentifierKind { email, phone, unknown }

/// Client-side reading of what the user typed into the identifier field.
///
/// The server is the authority — it re-parses and re-validates everything — but
/// deciding locally lets the form label itself, pick the right keyboard, and
/// reject an obvious mistake without a round trip.
///
/// The rules mirror `Identifier::parse` and `PhoneNumber` on the server. If one
/// side changes, the other has to change with it, or the app will accept
/// something the API then rejects.
class AccountIdentifier {
  const AccountIdentifier._(this.kind, this.value, this.error);

  final IdentifierKind kind;

  /// The normalised value, ready to send. Empty when [error] is set.
  final String value;

  /// Why the input was rejected, or null when it is usable.
  final String? error;

  bool get isValid => error == null && value.isNotEmpty;

  /// E.164 allows at most 15 digits after the `+`.
  static const int _maxPhoneDigits = 15;

  /// Shortest plausible international number.
  static const int _minPhoneDigits = 8;

  static const String _needsCountryCode =
      'Include the country code, like +84901234567';

  static AccountIdentifier parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const AccountIdentifier._(
        IdentifierKind.unknown,
        '',
        'Enter an email address or a phone number',
      );
    }

    return looksLikePhone(trimmed)
        ? _parsePhone(trimmed)
        : _parseEmail(trimmed);
  }

  /// Whether the input is phone-shaped.
  ///
  /// Decided before validating so a mistyped phone number reports a phone
  /// problem rather than a confusing "that is not a valid email".
  static bool looksLikePhone(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.contains('@')) return false;
    if (!(trimmed.startsWith('+') || trimmed.startsWith('0'))) return false;
    return RegExp(r'^[0-9+\s().-]+$').hasMatch(trimmed);
  }

  static AccountIdentifier _parsePhone(String raw) {
    String body;
    if (raw.startsWith('+')) {
      body = raw.substring(1);
    } else if (raw.startsWith('00')) {
      body = raw.substring(2);
    } else {
      // A bare national number like 0901234567 cannot be resolved without
      // knowing the country, and guessing would hand over someone else's
      // number.
      return const AccountIdentifier._(
        IdentifierKind.phone,
        '',
        _needsCountryCode,
      );
    }

    final digits = body.replaceAll(RegExp(r'[\s().\- ]'), '');
    if (!RegExp(r'^[0-9]+$').hasMatch(digits)) {
      return const AccountIdentifier._(
        IdentifierKind.phone,
        '',
        'A phone number can only contain digits',
      );
    }
    if (digits.startsWith('0')) {
      return const AccountIdentifier._(
        IdentifierKind.phone,
        '',
        _needsCountryCode,
      );
    }
    if (digits.length < _minPhoneDigits) {
      return const AccountIdentifier._(
        IdentifierKind.phone,
        '',
        'That phone number is too short',
      );
    }
    if (digits.length > _maxPhoneDigits) {
      return const AccountIdentifier._(
        IdentifierKind.phone,
        '',
        'That phone number is too long',
      );
    }

    return AccountIdentifier._(IdentifierKind.phone, '+$digits', null);
  }

  static AccountIdentifier _parseEmail(String raw) {
    final value = raw.toLowerCase();
    final parts = value.split('@');

    // Deliberately loose, matching the server: full RFC 5322 conformance is
    // not the goal, and delivery is the only real validator anyway.
    final looksReasonable =
        parts.length == 2 &&
        parts[0].isNotEmpty &&
        parts[1].contains('.') &&
        !parts[1].startsWith('.') &&
        !parts[1].endsWith('.') &&
        !value.contains(' ');

    if (!looksReasonable) {
      return const AccountIdentifier._(
        IdentifierKind.unknown,
        '',
        'That does not look like an email address or a phone number',
      );
    }
    if (value.length > 254) {
      return const AccountIdentifier._(
        IdentifierKind.email,
        '',
        'That email address is too long',
      );
    }

    return AccountIdentifier._(IdentifierKind.email, value, null);
  }

  /// Label for the field, so the user can see how their input was read.
  String get kindLabel => switch (kind) {
    IdentifierKind.email => 'EMAIL',
    IdentifierKind.phone => 'PHONE',
    IdentifierKind.unknown => 'EMAIL OR PHONE',
  };
}
