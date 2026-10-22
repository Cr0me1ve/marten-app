import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/captcha/widget/captcha_listener.dart';

void main() {
  testWidgets('iOS CAPTCHA paints across the viewport behind an opaque app layer', (tester) async {
    const boundaryKey = ValueKey('captcha-layer-boundary');
    const surfaceColor = Color(0xff17634b);
    final paintSizes = <Size>[];
    var captchaTaps = 0;
    var appTaps = 0;
    var captchaDisposed = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: const ColorScheme.light(surface: surfaceColor)),
        home: _ToggleLayerHost(
          child: RepaintBoundary(
            key: boundaryKey,
            child: IosCaptchaBackgroundLayer(
              captcha: _DisposeProbe(
                onDispose: () => captchaDisposed = true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => captchaTaps++,
                  child: Semantics(
                    container: true,
                    label: 'hidden captcha content',
                    child: SizedBox.expand(child: CustomPaint(painter: _PaintProbe((size) => paintSizes.add(size)))),
                  ),
                ),
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => appTaps++,
                child: Semantics(container: true, label: 'visible Marten application', child: SizedBox.expand()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final logicalViewport = Size(
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
      tester.view.physicalSize.height / tester.view.devicePixelRatio,
    );
    expect(tester.getRect(find.byKey(boundaryKey)).size, logicalViewport);
    expect(paintSizes, isNotEmpty, reason: 'the background WebView subtree must remain in the paint pass');
    expect(paintSizes.last, logicalViewport);

    final stack = tester.widget<Stack>(
      find.descendant(of: find.byType(IosCaptchaBackgroundLayer), matching: find.byType(Stack)),
    );
    expect(stack.fit, StackFit.expand);
    final topLayer = stack.children.last as Positioned;
    final surface = topLayer.child as ColoredBox;
    expect(surface.color, surfaceColor);
    expect(surface.color.a, 1, reason: 'the covering app surface must be fully opaque');

    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('hidden captcha content'), findsNothing);
    expect(find.bySemanticsLabel('visible Marten application'), findsOneWidget);

    await tester.tapAt(Offset(logicalViewport.width / 2, logicalViewport.height / 2));
    expect(appTaps, 1);
    expect(captchaTaps, 0, reason: 'the app surface must receive input instead of the live WebView');

    semantics.dispose();
    tester.state<_ToggleLayerHostState>(find.byType(_ToggleLayerHost)).removeLayer();
    await tester.pump();
    expect(captchaDisposed, isTrue, reason: 'removing the background challenge must tear down its subtree');
  });
}

class _PaintProbe extends CustomPainter {
  _PaintProbe(this.onPaint);

  final ValueChanged<Size> onPaint;

  @override
  void paint(Canvas canvas, Size size) {
    onPaint(size);
    canvas.drawColor(const Color(0xffd71967), BlendMode.srcOver);
  }

  @override
  bool shouldRepaint(covariant _PaintProbe oldDelegate) => false;
}

class _DisposeProbe extends StatefulWidget {
  const _DisposeProbe({required this.onDispose, required this.child});

  final VoidCallback onDispose;
  final Widget child;

  @override
  State<_DisposeProbe> createState() => _DisposeProbeState();
}

class _DisposeProbeState extends State<_DisposeProbe> {
  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }
}

class _ToggleLayerHost extends StatefulWidget {
  const _ToggleLayerHost({required this.child});

  final Widget child;

  @override
  State<_ToggleLayerHost> createState() => _ToggleLayerHostState();
}

class _ToggleLayerHostState extends State<_ToggleLayerHost> {
  var _showLayer = true;

  void removeLayer() => setState(() => _showLayer = false);

  @override
  Widget build(BuildContext context) => _showLayer ? widget.child : const SizedBox.shrink();
}
