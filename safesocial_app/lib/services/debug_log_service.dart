import 'package:flutter/foundation.dart';

/// In-app debug log service. Captures log messages for display in a console screen.
class DebugLogService extends ChangeNotifier {
  static final DebugLogService _instance = DebugLogService._();
  factory DebugLogService() => _instance;
  DebugLogService._();

  final List<LogEntry> _logs = [];
  static const _maxLogs = 500;

  List<LogEntry> get logs => List.unmodifiable(_logs);

  void log(String tag, String message, {LogLevel level = LogLevel.info}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      tag: tag,
      message: message,
      level: level,
    );
    _logs.add(entry);
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
    debugPrint('[$tag] $message');
    notifyListeners();
  }

  void info(String tag, String message) => log(tag, message, level: LogLevel.info);
  void warn(String tag, String message) => log(tag, message, level: LogLevel.warning);
  void error(String tag, String message) => log(tag, message, level: LogLevel.error);
  void success(String tag, String message) => log(tag, message, level: LogLevel.success);

  void clear() {
    _logs.clear();
    notifyListeners();
  }
}

enum LogLevel { info, warning, error, success }

class LogEntry {
  final DateTime timestamp;
  final String tag;
  final String message;
  final LogLevel level;

  const LogEntry({
    required this.timestamp,
    required this.tag,
    required this.message,
    required this.level,
  });

  String get timeStr =>
      '${timestamp.hour.toString().padLeft(2, '0')}:'
      '${timestamp.minute.toString().padLeft(2, '0')}:'
      '${timestamp.second.toString().padLeft(2, '0')}';
}
