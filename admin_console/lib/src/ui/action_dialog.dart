import 'package:flutter/material.dart';

import '../models.dart';

/// What an operator confirmed in [ActionDialog].
class ActionRequest {
  const ActionRequest({required this.reason, this.ticketRef, this.role});
  final String reason;
  final String? ticketRef;
  final String? role;
}

/// Confirmation for every mutation (TRD 07 §5.4): it names the target, states
/// the effect, and requires one of the API's fixed reason codes. A ticket
/// reference is optional and checked with the server's rule before sending.
class ActionDialog extends StatefulWidget {
  const ActionDialog({
    super.key,
    required this.title,
    required this.target,
    required this.reasonKind,
    required this.confirmLabel,
    this.effect,
    this.roles,
    this.effectForRole,
    this.destructive = false,
  });

  final String title, target, reasonKind, confirmLabel;
  final String? effect;
  final List<String>? roles;
  final String Function(String role)? effectForRole;
  final bool destructive;

  @override
  State<ActionDialog> createState() => _ActionDialogState();
}

class _ActionDialogState extends State<ActionDialog> {
  String? _reason, _role;
  final _ticket = TextEditingController();

  @override
  void initState() {
    super.initState();
    final roles = widget.roles;
    if (roles != null && roles.length == 1) _role = roles.first;
  }

  @override
  void dispose() {
    _ticket.dispose();
    super.dispose();
  }

  String? get _ticketError {
    final t = _ticket.text.trim();
    if (t.isEmpty || validTicketRef(t)) return null;
    return 'Use up to 40 letters, digits, ".", "_" or "-", starting with a letter or digit.';
  }

  bool get _ready =>
      _reason != null &&
      (widget.roles == null || _role != null) &&
      _ticketError == null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effect = _role != null && widget.effectForRole != null
        ? widget.effectForRole!(_role!)
        : widget.effect;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Account: ${widget.target}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              if (widget.roles != null) ...[
                DropdownButtonFormField<String>(
                  key: const Key('dialog-role'),
                  initialValue: _role,
                  decoration: const InputDecoration(
                    labelText: 'New role',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final r in widget.roles!)
                      DropdownMenuItem(
                        value: r,
                        child: Text(roleLabels[r] ?? r),
                      ),
                  ],
                  onChanged: (v) => setState(() => _role = v),
                ),
                const SizedBox(height: 12),
              ],
              if (effect != null)
                Container(
                  key: const Key('dialog-effect'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: widget.destructive
                        ? scheme.errorContainer
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(effect),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('dialog-reason'),
                initialValue: _reason,
                decoration: const InputDecoration(
                  labelText: 'Reason (required)',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final c in reasonCodes[widget.reasonKind]!)
                    DropdownMenuItem(
                      value: c,
                      child: Text(reasonLabels[c] ?? c),
                    ),
                ],
                onChanged: (v) => setState(() => _reason = v),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('dialog-ticket'),
                controller: _ticket,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Ticket reference (optional)',
                  hintText: 'for example SUP-1042',
                  border: const OutlineInputBorder(),
                  errorText: _ticketError,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('dialog-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('dialog-confirm'),
          style: widget.destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          onPressed: _ready
              ? () => Navigator.of(context).pop(
                  ActionRequest(
                    reason: _reason!,
                    ticketRef: _ticket.text.trim().isEmpty
                        ? null
                        : _ticket.text.trim(),
                    role: _role,
                  ),
                )
              : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
