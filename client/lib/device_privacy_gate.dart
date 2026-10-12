import 'package:flutter/material.dart';

/// Covers the entire Navigator, including dialogs, without disposing private
/// editors. Offstage, focus, input and semantics all share the same boundary.
class DevicePrivacyGate extends StatefulWidget {
  const DevicePrivacyGate({
    super.key,
    required this.locked,
    required this.child,
    required this.shield,
  });
  final bool locked;
  final Widget child, shield;
  @override
  State<DevicePrivacyGate> createState() => _DevicePrivacyGateState();
}

class _DevicePrivacyGateState extends State<DevicePrivacyGate> {
  final _focus = FocusScopeNode();
  @override
  void didUpdateWidget(covariant DevicePrivacyGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.locked && !oldWidget.locked) _focus.unfocus();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Offstage(
        offstage: widget.locked,
        child: ExcludeSemantics(
          excluding: widget.locked,
          child: ExcludeFocus(
            excluding: widget.locked,
            child: IgnorePointer(
              ignoring: widget.locked,
              child: TickerMode(
                enabled: !widget.locked,
                child: FocusScope(node: _focus, child: widget.child),
              ),
            ),
          ),
        ),
      ),
      if (widget.locked) PopScope(canPop: false, child: widget.shield),
    ],
  );
}
