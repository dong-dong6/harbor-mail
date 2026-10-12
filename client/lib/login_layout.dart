import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Keeps authentication controls readable while giving optional download/help
/// content its own space on a wide screen. Both panes remain scrollable together
/// on short screens and when the keyboard reduces the available height.
class ResponsiveLoginLayout extends StatelessWidget {
  static const double wideBreakpoint = 960;
  static const double contentMaxWidth = 980;
  static const double paneMaxWidth = 410;

  final Widget login;
  final Widget? download;

  const ResponsiveLoginLayout({super.key, required this.login, this.download});

  Widget _loginPane() => SizedBox(
    key: const Key('login-form-pane'),
    width: paneMaxWidth,
    child: login,
  );

  Widget _downloadPane() => SizedBox(
    key: const Key('login-download-pane'),
    width: paneMaxWidth,
    child: download,
  );

  @override
  Widget build(BuildContext context) => SafeArea(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final wide = download != null && constraints.maxWidth >= wideBreakpoint;
        return SingleChildScrollView(
          key: const Key('login-scroll'),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0, constraints.maxHeight - 64),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: wide ? contentMaxWidth : paneMaxWidth,
                ),
                child: wide
                    ? Stack(
                        key: const Key('login-wide-layout'),
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [_loginPane(), _downloadPane()],
                          ),
                          const Positioned.fill(
                            child: IgnorePointer(
                              child: Center(
                                child: VerticalDivider(
                                  key: Key('login-pane-divider'),
                                  width: 1,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        key: const Key('login-stacked-layout'),
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _loginPane(),
                          if (download != null) ...[
                            const SizedBox(height: 32),
                            _downloadPane(),
                          ],
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
