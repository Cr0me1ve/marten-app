import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/profile/notifier/active_profile_notifier.dart';

const _idleBorder = Color(0xFFE3A766);
const _connectedBorder = Color(0xFFBA8048);

class ConnectionButton extends HookConsumerWidget {
  const ConnectionButton({super.key, this.size = 220});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final connectionStatus = ref.watch(connectionNotifierProvider);
    // Startup route readiness is reduced into connectionNotifierProvider.
    // Keeping an additional widget-local gate here could retain a stale
    // Connecting after the current generation has already been verified.
    final status = connectionButtonStatus(connectionStatus);

    final label = switch (status) {
      Connected() => t.connection.connected,
      Connecting() => t.connection.connecting,
      Disconnecting() => t.connection.disconnecting,
      Disconnected() => t.connection.connect,
    };
    final manualCommand = manualConnectionCommandForStatus(status);

    final onTap = switch (status) {
      // A visible active/transient session is always actionable, including
      // AsyncLoading with a retained value while the provider is rebuilding.
      // The captured command is a stop intent and can never become Connect.
      Connecting() || Connected() => () async {
        await ref.read(connectionNotifierProvider.notifier).executeManualCommand(manualCommand);
      },
      Disconnected() when connectionStatus.isLoading => null,
      Disconnected() => () async {
        if (ref.read(activeProfileProvider).valueOrNull == null) {
          ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile();
          return;
        }
        await ref.read(connectionNotifierProvider.notifier).executeManualCommand(manualCommand);
      },
      Disconnecting() => null,
    };

    return _ConnectionCircle(size: size, label: label, status: status, onTap: onTap);
  }
}

ConnectionStatus connectionButtonStatus(AsyncValue<ConnectionStatus> state) {
  // AsyncError may retain the previous AsyncData value. Treat an error as a
  // terminal idle state instead of rendering a stale Connecting indefinitely.
  if (state.hasError) return const Disconnected();
  return state.valueOrNull ?? const Disconnected();
}

class _ConnectionCircle extends HookWidget {
  const _ConnectionCircle({required this.size, required this.label, required this.status, required this.onTap});

  final double size;
  final String label;
  final ConnectionStatus status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final controller = useAnimationController(duration: const Duration(milliseconds: 1400));

    final isSwitching = status.isSwitching;

    useEffect(() {
      if (isSwitching) {
        controller.repeat();
      } else {
        controller.stop();
        controller.value = 0;
      }
      return null;
    }, [isSwitching]);

    final borderColor = switch (status) {
      Connected() => _connectedBorder,
      Disconnected() => _idleBorder,
      _ => _idleBorder,
    };

    final glowOpacity = switch (status) {
      Connected() => 0.55,
      Disconnected() => 0.45,
      _ => 0.35,
    };

    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _CircleGlowPainter(color: borderColor, glowOpacity: glowOpacity),
                  ),
                ),
                RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: controller,
                    builder: (context, _) => CustomPaint(
                      painter: _CircleStrokePainter(
                        color: borderColor,
                        progress: controller.value,
                        splitting: isSwitching,
                      ),
                    ),
                  ),
                ),
                Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: size * 0.16),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontSize: size * 0.13,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CircleGlowPainter extends CustomPainter {
  _CircleGlowPainter({required this.color, required this.glowOpacity});

  final Color color;
  final double glowOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final stroke = size.shortestSide * 0.012;
    final radius = size.shortestSide / 2 - stroke;

    // soft outer glow
    final glow = Paint()
      ..color = color.withValues(alpha: glowOpacity * 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 4
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawCircle(center, radius, glow);
  }

  @override
  bool shouldRepaint(covariant _CircleGlowPainter old) => old.color != color || old.glowOpacity != glowOpacity;
}

class _CircleStrokePainter extends CustomPainter {
  _CircleStrokePainter({required this.color, required this.progress, required this.splitting});

  final Color color;
  final double progress;
  final bool splitting;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final stroke = size.shortestSide * 0.012;
    final radius = size.shortestSide / 2 - stroke;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    if (!splitting) {
      canvas.drawCircle(center, radius, paint);
      return;
    }

    const arcCount = 4;
    const gap = 0.18; // radians gap between segments
    const totalGap = gap * arcCount;
    const sweepEach = (2 * math.pi - totalGap) / arcCount;
    final rotation = progress * 2 * math.pi;
    final rect = Rect.fromCircle(center: center, radius: radius);

    for (var i = 0; i < arcCount; i++) {
      final start = rotation + i * (sweepEach + gap);
      canvas.drawArc(rect, start, sweepEach, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CircleStrokePainter old) =>
      old.color != color || old.progress != progress || old.splitting != splitting;
}
