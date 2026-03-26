import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/debug_log_service.dart';

/// Debug console showing in-app logs for troubleshooting P2P connectivity.
class DebugConsoleScreen extends StatelessWidget {
  const DebugConsoleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final logService = context.watch<DebugLogService>();
    final logs = logService.logs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Console'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy all logs',
            onPressed: () {
              final text = logs.map((l) => '${l.timeStr} [${l.tag}] ${l.message}').join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs copied to clipboard')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear logs',
            onPressed: () => logService.clear(),
          ),
        ],
      ),
      body: logs.isEmpty
          ? Center(
              child: Text('No logs yet', style: theme.textTheme.bodySmall),
            )
          : ListView.builder(
              reverse: true,
              padding: const EdgeInsets.all(8),
              itemCount: logs.length,
              itemBuilder: (context, index) {
                final log = logs[logs.length - 1 - index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Timestamp
                      Text(
                        log.timeStr,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 4),
                      // Level indicator
                      Container(
                        width: 4,
                        height: 4,
                        margin: const EdgeInsets.only(top: 5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _levelColor(log.level),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // Tag
                      Text(
                        '[${log.tag}]',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _levelColor(log.level),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // Message
                      Expanded(
                        child: Text(
                          log.message,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Color _levelColor(LogLevel level) => switch (level) {
        LogLevel.info => Colors.blue,
        LogLevel.warning => Colors.orange,
        LogLevel.error => Colors.red,
        LogLevel.success => Colors.green,
      };
}
