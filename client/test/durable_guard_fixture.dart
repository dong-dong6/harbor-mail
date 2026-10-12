import 'package:harbor_mail/api.dart';

/// Synthetic session identity only; cannot mint or persist any credentials.
class DurableGuardFixture implements ApiSessionCoordinator {
  @override
  bool durable = true;
  @override
  bool get canUseAccess => durable;
  @override
  int epoch = 0;
  @override
  Future<void> ensureAccess({
    String? rejectedBearer,
    bool force = false,
  }) async {}
  @override
  Future<void> rejectAccess({
    required String? requestBearer,
    required String code,
  }) async {}
  @override
  void invalidate() {
    epoch++;
    durable = false;
  }
}
