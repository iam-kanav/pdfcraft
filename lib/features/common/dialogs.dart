import 'package:flutter/material.dart';

Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  String confirmLabel = 'Save',
  bool obscure = false,
  bool selectBaseName = false,
  String? Function(String)? validator,
  int maxLines = 1,
}) {
  final controller = TextEditingController(text: initial);
  if (selectBaseName && initial.contains('.')) {
    controller.selection = TextSelection(baseOffset: 0, extentOffset: initial.lastIndexOf('.'));
  } else {
    controller.selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  }
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        void submit() {
          final v = controller.text;
          final e = validator?.call(v);
          if (e != null) {
            setState(() => error = e);
            return;
          }
          Navigator.pop(ctx, v);
        }

        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: obscure,
            maxLines: obscure ? 1 : maxLines,
            minLines: 1,
            decoration: InputDecoration(hintText: hint, errorText: error),
            onSubmitted: maxLines == 1 ? (_) => submit() : null,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: Text(confirmLabel)),
          ],
        );
      },
    ),
  );
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'OK',
  bool destructive = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return r ?? false;
}

void showSnack(BuildContext context, String message, {SnackBarAction? action, bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      action: action,
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ),
  );
}

/// Runs [task] while showing a blocking progress dialog. Errors are shown as a snackbar and rethrown as null.
Future<T?> runWithProgress<T>(BuildContext context, String label, Future<T> Function() task, {bool showErrors = true}) async {
  final nav = Navigator.of(context, rootNavigator: true);
  var open = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 20),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    ),
  ).then((_) => open = false);
  try {
    final r = await task();
    return r;
  } catch (e) {
    if (showErrors && context.mounted) showSnack(context, friendlyError(e), error: true);
    return null;
  } finally {
    if (open) nav.pop();
  }
}

String friendlyError(Object e) {
  final s = e.toString();
  return s.replaceFirst(RegExp(r'^(Exception|FileSystemException|StateError|Bad state|FormatException):\s*'), '');
}

/// Prompts for a document password.
Future<String?> askPassword(BuildContext context, {String? fileName, bool wrong = false}) => showTextInputDialog(
  context,
  title: wrong ? 'Incorrect password' : 'Password required',
  hint: fileName == null ? 'Enter password' : 'Enter the password for $fileName',
  obscure: true,
  confirmLabel: 'Open',
);
