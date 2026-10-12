import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/wellbeing_service.dart';

/// Time on the app, the break reminder, a daily limit, quiet hours and the
/// pause. Every number here comes from this device and stays on it.
class WellbeingScreen extends StatelessWidget {
  const WellbeingScreen({super.key});

  static String _hm(int minuteOfDay) =>
      '${(minuteOfDay ~/ 60).toString().padLeft(2, '0')}:${(minuteOfDay % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final w = context.watch<WellbeingService>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final days = w.lastSevenDays;
    final peak = days.fold<int>(1, (m, d) => d.$2 > m ? d.$2 : m);
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Scaffold(
      appBar: AppBar(title: const Text('Your time here')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${w.minutesToday} min today', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          Text('Counted while Spheres is on screen. Nobody else sees this.', style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (d, m) in days)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text('$m', style: theme.textTheme.labelSmall),
                          Container(
                            height: 80 * (m / peak),
                            decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(4)),
                          ),
                          const SizedBox(height: 4),
                          Text(names[d.weekday - 1], style: theme.textTheme.labelSmall),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 32),
          SwitchListTile(
            title: const Text('Break every 20 minutes'),
            subtitle: const Text('After 20 minutes in a row the screen dims for 20 seconds and asks you to look away. Leaving the app for five minutes counts as a break.'),
            isThreeLine: true,
            value: w.breakReminders,
            onChanged: w.setBreakReminders,
          ),
          ListTile(
            title: const Text('Daily reminder'),
            subtitle: Text(w.dailyLimitMinutes == 0
                ? 'Off'
                : 'A note once you pass ${w.dailyLimitMinutes} minutes in a day'),
            trailing: DropdownButton<int>(
              value: w.dailyLimitMinutes,
              items: [for (final n in const [0, 15, 30, 60, 90, 120]) DropdownMenuItem(value: n, child: Text(n == 0 ? 'Off' : '$n min'))],
              onChanged: (v) => w.setDailyLimit(v ?? 0),
            ),
          ),
          ListTile(
            title: const Text('Quiet hours'),
            subtitle: Text(w.quietStart == null || w.quietEnd == null
                ? 'Off. Notifications arrive at any hour; calls always ring.'
                : 'No notifications from ${_hm(w.quietStart!)} to ${_hm(w.quietEnd!)}. Calls still ring.'),
            trailing: TextButton(
              onPressed: () async {
                final start = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(hour: (w.quietStart ?? 22 * 60) ~/ 60, minute: (w.quietStart ?? 0) % 60),
                    helpText: 'Quiet from');
                if (start == null || !context.mounted) return;
                final end = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(hour: (w.quietEnd ?? 7 * 60) ~/ 60, minute: (w.quietEnd ?? 0) % 60),
                    helpText: 'Quiet until');
                if (end == null) return;
                await w.setQuietHours(start.hour * 60 + start.minute, end.hour * 60 + end.minute);
              },
              child: const Text('Set'),
            ),
            onLongPress: () => w.setQuietHours(null, null),
          ),
          if (w.quietStart != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => w.setQuietHours(null, null), child: const Text('Turn quiet hours off')),
            ),
          const Divider(height: 32),
          ListTile(
            leading: Icon(w.paused ? Icons.play_circle_outline : Icons.pause_circle_outline, color: cs.primary),
            title: Text(w.paused ? 'Resume' : 'Pause Spheres'),
            subtitle: const Text(
                'Paused, the app sends and fetches nothing and no notification arrives. Your keys, contacts, spheres and messages stay exactly as they are; nobody is told. Resume whenever you like.'),
            isThreeLine: true,
            onTap: () => w.setPaused(!w.paused),
          ),
        ],
      ),
    );
  }
}

/// Dims everything for the length of a break, with a countdown.
class BreakOverlay extends StatelessWidget {
  final Widget child;
  const BreakOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final w = context.watch<WellbeingService>();
    if (!w.breakActive) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Material(
          color: Colors.black.withValues(alpha: 0.82),
          child: SafeArea(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.self_improvement, color: Colors.white70, size: 56),
                  const SizedBox(height: 16),
                  const Text('Time for a short break',
                      style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: Text('Twenty minutes have passed. Look at something far away for twenty seconds.',
                        textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(height: 24),
                  Text('${w.breakRemaining}',
                      style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.w300)),
                  const SizedBox(height: 24),
                  TextButton(
                    onPressed: w.skipBreak,
                    child: const Text('Skip this one', style: TextStyle(color: Colors.white54)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Covers the app while paused.
class PauseGate extends StatelessWidget {
  final Widget child;
  const PauseGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final w = context.watch<WellbeingService>();
    if (!w.paused) return child;
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.pause_circle_outline, size: 64, color: cs.primary),
                const SizedBox(height: 16),
                Text('Spheres is paused', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                const Text(
                  'Nothing is sent or fetched and no notification arrives. Everything you have is still here, encrypted, on this device.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => w.setPaused(false),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
