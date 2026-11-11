import 'dart:math' as math;

enum TurnMode {
  /// Final Fantasy / Tactics style Charge Time gauge (fast units act more often).
  speedGauge,

  /// D&D / Classic RPG round-based initiative queue where every unit acts once per round.
  roundInitiative,
}

/// Participant entry scheduled inside a [TurnScheduler].
final class CombatantSlot {
  final String id;
  final String name;
  final int team;
  double speed;
  int initiativeBonus;
  double ct;
  int lastRoll = 0;
  bool isAlive;
  bool canAct;

  CombatantSlot({
    required this.id,
    required this.name,
    this.team = 0,
    this.speed = 10.0,
    this.initiativeBonus = 0,
    this.ct = 0.0,
    this.isAlive = true,
    this.canAct = true,
  });

  bool get isEligible => isAlive && canAct;

  CombatantSlot clone() => CombatantSlot(
        id: id,
        name: name,
        team: team,
        speed: speed,
        initiativeBonus: initiativeBonus,
        ct: ct,
        isAlive: isAlive,
        canAct: canAct,
      )..lastRoll = lastRoll;
}

/// Manages turn sequencing in either ATB/Speed Gauge or Initiative Round-Robin mode.
final class TurnScheduler {
  final TurnMode mode;
  final double ctThreshold;
  final int initiativeDie;
  final math.Random _rng;

  final List<CombatantSlot> _slots = [];
  int _roundNumber = 0;
  int _turnNumber = 0;
  CombatantSlot? _currentActor;
  int _roundCursor = -1;
  List<CombatantSlot> _roundOrder = [];

  TurnScheduler({
    this.mode = TurnMode.speedGauge,
    this.ctThreshold = 100.0,
    this.initiativeDie = 20,
    int? seed,
  }) : _rng = math.Random(seed);

  int get roundNumber => _roundNumber;
  int get turnNumber => _turnNumber;
  CombatantSlot? get currentActor => _currentActor;
  List<CombatantSlot> get combatants => List.unmodifiable(_slots);

  void addCombatant(CombatantSlot slot) {
    _slots.add(slot);
  }

  bool removeCombatant(String id) {
    final before = _slots.length;
    _slots.removeWhere((s) => s.id == id);
    _roundOrder.removeWhere((s) => s.id == id);
    if (_currentActor?.id == id) _currentActor = null;
    return _slots.length != before;
  }

  CombatantSlot? getCombatant(String id) {
    for (final s in _slots) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Advances scheduling to the next eligible actor and returns them, or `null` when
  /// no combatant is alive & able to act.
  CombatantSlot? advanceNext() {
    final eligible = _slots.where((s) => s.isEligible).toList();
    if (eligible.isEmpty) {
      _currentActor = null;
      return null;
    }

    if (mode == TurnMode.roundInitiative) {
      return _advanceRoundInitiative();
    }
    return _advanceSpeedGauge();
  }

  CombatantSlot? _advanceRoundInitiative() {
    while (true) {
      _roundCursor++;
      if (_roundOrder.isEmpty || _roundCursor >= _roundOrder.length) {
        _roundNumber++;
        for (final s in _slots) {
          s.lastRoll = (_rng.nextInt(initiativeDie) + 1) + s.initiativeBonus;
        }
        _roundOrder = _slots.where((s) => s.isAlive).toList()
          ..sort((a, b) {
            final cmp = b.lastRoll.compareTo(a.lastRoll);
            return cmp != 0 ? cmp : b.speed.compareTo(a.speed);
          });
        _roundCursor = 0;
        if (_roundOrder.isEmpty) return null;
      }

      final candidate = _roundOrder[_roundCursor];
      if (candidate.isEligible) {
        _currentActor = candidate;
        _turnNumber++;
        return candidate;
      }
      if (!_roundOrder.any((s) => s.isEligible)) return null;
    }
  }

  CombatantSlot? _advanceSpeedGauge() {
    // Advance gauges until at least one eligible actor hits ctThreshold
    for (int iter = 0; iter < 10000; iter++) {
      CombatantSlot? best;
      for (final s in _slots) {
        if (!s.isEligible) continue;
        if (s.ct >= ctThreshold - 1e-9) {
          if (best == null ||
              s.ct > best.ct + 1e-9 ||
              ((s.ct - best.ct).abs() <= 1e-9 && s.speed > best.speed)) {
            best = s;
          }
        }
      }

      if (best != null) {
        best.ct = math.max(0.0, best.ct - ctThreshold);
        _currentActor = best;
        _turnNumber++;
        return best;
      }

      var anyPositiveSpeed = false;
      for (final s in _slots) {
        if (s.isEligible && s.speed > 0) {
          s.ct += s.speed;
          anyPositiveSpeed = true;
        }
      }
      if (!anyPositiveSpeed) return null;
    }
    return null;
  }

  /// Non-mutating lookahead returning the next [count] projected turn actors (ideal for turn-bar UI).
  List<CombatantSlot> previewOrder(int count) {
    if (count <= 0) return const [];
    if (mode == TurnMode.roundInitiative) {
      final res = <CombatantSlot>[];
      if (_roundOrder.isEmpty) return const [];
      for (int i = math.max(0, _roundCursor + 1); i < _roundOrder.length && res.length < count; i++) {
        if (_roundOrder[i].isEligible) res.add(_roundOrder[i]);
      }
      return res;
    }

    final sim = TurnScheduler(
      mode: TurnMode.speedGauge,
      ctThreshold: ctThreshold,
    );
    for (final s in _slots) {
      sim.addCombatant(s.clone());
    }
    final projected = <CombatantSlot>[];
    for (int i = 0; i < count; i++) {
      final actor = sim.advanceNext();
      if (actor == null) break;
      projected.add(getCombatant(actor.id) ?? actor);
    }
    return projected;
  }
}
