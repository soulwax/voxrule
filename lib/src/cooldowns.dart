import 'dart:math' as math;

final class _TimerCooldown {
  double remaining;
  double duration;
  _TimerCooldown(this.remaining, this.duration);
}

/// Multi-charge stock state for abilities with multiple uses before recharge lockout.
final class ChargePoolState {
  int currentCharges;
  final int maxCharges;
  final double rechargeDuration;
  double rechargeElapsed = 0.0;

  ChargePoolState({
    required this.maxCharges,
    required this.rechargeDuration,
    int? initialCharges,
  }) : currentCharges = initialCharges ?? maxCharges;

  double get rechargeProgress =>
      currentCharges >= maxCharges || rechargeDuration <= 0
          ? 1.0
          : (rechargeElapsed / rechargeDuration).clamp(0.0, 1.0);
}

/// Tracks ability cooldowns, Global Cooldown (GCD), cooldown reduction (CDR), and multi-charge skills.
final class CooldownTracker {
  final Map<String, _TimerCooldown> _timers = {};
  final Map<String, ChargePoolState> _charges = {};

  double _gcdRemaining = 0.0;
  double _gcdDuration = 0.0;

  double get gcdRemaining => _gcdRemaining;
  bool get isGcdActive => _gcdRemaining > 1e-9;
  double get gcdProgress =>
      _gcdDuration <= 0 ? 1.0 : (1.0 - (_gcdRemaining / _gcdDuration)).clamp(0.0, 1.0);

  void configureCharges(
    String abilityId, {
    required int maxCharges,
    required double rechargeDuration,
    int? initialCharges,
  }) {
    _charges[abilityId] = ChargePoolState(
      maxCharges: math.max(1, maxCharges),
      rechargeDuration: math.max(0.0, rechargeDuration),
      initialCharges: initialCharges,
    );
  }

  ChargePoolState? getChargeState(String abilityId) => _charges[abilityId];

  void triggerGcd(double duration) {
    if (duration <= 0) return;
    if (duration > _gcdRemaining) {
      _gcdRemaining = duration;
      _gcdDuration = duration;
    }
  }

  void start(String abilityId, double duration) {
    if (duration <= 0) {
      _timers.remove(abilityId);
      return;
    }
    _timers[abilityId] = _TimerCooldown(duration, duration);
  }

  bool isReady(String abilityId, {bool respectGcd = true}) {
    if (respectGcd && isGcdActive) return false;
    final cd = _timers[abilityId];
    if (cd != null && cd.remaining > 1e-9) return false;
    final pool = _charges[abilityId];
    if (pool != null && pool.currentCharges <= 0) return false;
    return true;
  }

  /// Atomically verifies readiness, consumes a charge (if configured), starts cooldown
  /// (for non-charge skills), and optionally triggers Global Cooldown.
  bool tryUse(
    String abilityId, {
    double cooldownDuration = 0.0,
    double gcdDuration = 0.0,
    bool respectGcd = true,
  }) {
    if (!isReady(abilityId, respectGcd: respectGcd)) return false;

    final pool = _charges[abilityId];
    if (pool != null) {
      pool.currentCharges--;
    } else if (cooldownDuration > 0.0) {
      start(abilityId, cooldownDuration);
    }

    if (gcdDuration > 0.0) {
      triggerGcd(gcdDuration);
    }
    return true;
  }

  double remaining(String abilityId) => _timers[abilityId]?.remaining ?? 0.0;

  double duration(String abilityId) => _timers[abilityId]?.duration ?? 0.0;

  /// Normalized completion `[0..1]`, where `1.0` means completely ready.
  double progress(String abilityId) {
    final cd = _timers[abilityId];
    if (cd == null || cd.duration <= 0) return 1.0;
    return (1.0 - (cd.remaining / cd.duration)).clamp(0.0, 1.0);
  }

  /// Reduces a specific active cooldown timer by [seconds] (CDR mechanic).
  void reduce(String abilityId, double seconds) {
    final cd = _timers[abilityId];
    if (cd != null) {
      cd.remaining = math.max(0.0, cd.remaining - seconds);
      if (cd.remaining <= 1e-9) _timers.remove(abilityId);
    }
  }

  void reduceAll(double seconds) {
    for (final k in _timers.keys.toList()) {
      reduce(k, seconds);
    }
  }

  void reset(String abilityId) {
    _timers.remove(abilityId);
    final pool = _charges[abilityId];
    if (pool != null) {
      pool.currentCharges = pool.maxCharges;
      pool.rechargeElapsed = 0.0;
    }
  }

  void resetAll() {
    _timers.clear();
    _gcdRemaining = 0.0;
    for (final pool in _charges.values) {
      pool.currentCharges = pool.maxCharges;
      pool.rechargeElapsed = 0.0;
    }
  }

  void step(double dt) {
    if (dt <= 0) return;

    if (_gcdRemaining > 0.0) {
      _gcdRemaining = math.max(0.0, _gcdRemaining - dt);
    }

    for (final k in _timers.keys.toList()) {
      final cd = _timers[k]!;
      cd.remaining -= dt;
      if (cd.remaining <= 1e-9) {
        _timers.remove(k);
      }
    }

    for (final pool in _charges.values) {
      if (pool.currentCharges >= pool.maxCharges) {
        pool.rechargeElapsed = 0.0;
        continue;
      }
      if (pool.rechargeDuration <= 0.0) {
        pool.currentCharges = pool.maxCharges;
        pool.rechargeElapsed = 0.0;
        continue;
      }
      pool.rechargeElapsed += dt;
      while (pool.rechargeElapsed + 1e-9 >= pool.rechargeDuration &&
          pool.currentCharges < pool.maxCharges) {
        pool.rechargeElapsed -= pool.rechargeDuration;
        pool.currentCharges++;
      }
      if (pool.currentCharges >= pool.maxCharges) {
        pool.rechargeElapsed = 0.0;
      }
    }
  }
}
