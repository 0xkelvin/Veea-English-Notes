import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/native_gate_status.dart';

/// Keep underlying native views hidden until a departing route is fully gone,
/// including the reverse animation (isCurrent alone becomes true too early).
class NativeApplicationLabelObserver extends NavigatorObserver
    with ChangeNotifier {
  Route<dynamic>? _top;
  final Set<TransitionRoute<dynamic>> _departing = {};

  bool shows(ModalRoute<dynamic>? route) {
    if (route == null) return true;
    if (route.navigator != navigator) return route.isCurrent;
    return route == _top && _departing.isEmpty;
  }

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    _top = topRoute;
    notifyListeners();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is TransitionRoute<dynamic>) {
      _departing.add(route);
      route.completed.then((_) {
        _departing.remove(route);
        notifyListeners();
      });
    }
    notifyListeners();
  }
}

final nativeApplicationLabelObserver = NativeApplicationLabelObserver();

/// Screen Time names and icons stay inside Apple's private token renderer.
class NativeApplicationLabel extends StatelessWidget {
  const NativeApplicationLabel({super.key, required this.application});
  final NativeGateApplication application;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(17) / 17;
    final route = ModalRoute.of(context);
    return ListenableBuilder(
      listenable: nativeApplicationLabelObserver,
      builder: (context, _) {
        if (!nativeApplicationLabelObserver.shows(route)) {
          return SizedBox(height: 52 * scale);
        }
        return _label(context, scale);
      },
    );
  }

  Widget _label(BuildContext context, double scale) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return SizedBox(
        height: 52 * scale,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            application.label,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 52 * scale,
      child: ClipRect(
        child: UiKitView(
          key: ValueKey('${application.id}:$dark:$scale'),
          viewType: 'app.veea.english/application_label',
          creationParams: {
            'targetApp': application.id,
            'dark': dark,
            'textScale': scale,
          },
          creationParamsCodec: const StandardMessageCodec(),
        ),
      ),
    );
  }
}
