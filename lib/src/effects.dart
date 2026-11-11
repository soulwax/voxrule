import 'dart:math' as math;

/// How reapplying an existing [StatusEffectDef] behaves on a [StatusContainer].
enum StatusStackPolicy {
  /// Resets duration to the full duration without increasing stacks.
  refreshDuration,

  /// Increments stacks up to [StatusEffectDef.maxStacks] and refreshes duration.
  stackIntensity,

  /// Creates an independent concurrent instance with its own timer and shield pool.
  independentInstances,

  /// Ignores the new application if already present.
  rejectIfPresent,
}

/// Stat modification metadata carried by an aura/buff/debuff.
final class StatBonusSpec {
  final double flat;
  final double percentAdd;
  final double percentMult;

  const StatBonusSpec({
    this.flat = 0.0,
    this.percentAdd = 0.0,
    this.percentMult = 1.0,
  });
}

/// Immutable blueprint describing a buff, debuff, DoT, HoT, crowd control, or absorb shield.
final class StatusEffectDef {
  final String id;
  final String name;
  final double duration;
  final double tickInterval;
  final int maxStacks;
  final StatusStackPolicy stackPolicy;
  final Set<String> tags;
  final Set<String> grantsImmunityToTags;
  final Set<String> grantsImmunityToIds;
  final Map<String, StatBonusSpec> statBonuses;
  final double absorbShieldAmount;
  final double damagePerTick;
  final double healPerTick;
  final String damageType;
  final bool scalesTickWithStacks;
  final bool scalesStatsWithStacks;
  final bool stopsTurnAction;

  const StatusEffectDef({
    required this.id,
    required this.name,
    this.duration = 5.0,
    this.tickInterval = 0.0,
    this.maxStacks = 1,
    this.stackPolicy = StatusStackPolicy.refreshDuration,
    this.tags = const {},
    this.grantsImmunityToTags = const {},
    this.grantsImmunityToIds = const {},
    this.statBonuses = const {},
    this.absorbShieldAmount = 0.0,
    this.damagePerTick = 0.0,
    this.healPerTick = 0.0,
    this.damageType = 'physical',
    this.scalesTickWithStacks = true,
    this.scalesStatsWithStacks = true,
    this.stopsTurnAction = false,
  });
}

/// Emitted whenever a periodic DoT/HoT status effect ticks.
final class StatusTickEvent {
  final ActiveStatus status;
  final double damage;
  final double heal;
  final String damageType;

  const StatusTickEvent({
    required this.status,
    required this.damage,
    required this.heal,
    required this.damageType,
  });
}

/// Live status effect instance tracked inside a [StatusContainer].
final class ActiveStatus {
  final int instanceId;
  final StatusEffectDef def;
  final Object? sourceId;

  int stacks;
  double remainingDuration;
  double elapsed = 0.0;
  double tickAccumulator = 0.0;
  double remainingShield;

  ActiveStatus({
    required this.instanceId,
    required this.def,
    required this.stacks,
    required this.remainingDuration,
    required this.remainingShield,
    this.sourceId,
  });

  bool get isPermanent => def.duration.isInfinite;
  double get normalizedRemaining =>
      isPermanent || def.duration <= 0 ? 1.0 : (remainingDuration / def.duration).clamp(0.0, 1.0);
}

/// Manages active buffs, debuffs, periodic ticks, dispels, tag immunities, and shields.
final class StatusContainer {
  final List<ActiveStatus> _active = [];
  int _nextInstanceId = 1;

  void Function(ActiveStatus status)? onApplied;
  void Function(StatusTickEvent tick)? onTick;
  void Function(ActiveStatus status)? onExpired;
  void Function(ActiveStatus status)? onRemoved;
  void Function(StatusEffectDef blockedDef)? onImmuneBlocked;
  void Function()? onChanged;

  List<ActiveStatus> get active => List.unmodifiable(_active);
  bool get isEmpty => _active.isEmpty;
  bool get isStunned => _active.any((e) => e.def.stopsTurnAction);

  bool hasStatus(String effectId) => _active.any((e) => e.def.id == effectId);
  bool hasTag(String tag) => _active.any((e) => e.def.tags.contains(tag));

  int getStacks(String effectId) {
    var total = 0;
    for (final s in _active) {
      if (s.def.id == effectId) total += s.stacks;
    }
    return total;
  }

  double get totalShield {
    var sum = 0.0;
    for (final s in _active) {
      sum += s.remainingShield;
    }
    return sum;
  }

  bool isImmuneTo(StatusEffectDef def) {
    for (final active in _active) {
      if (active.def.grantsImmunityToIds.contains(def.id)) return true;
      for (final tag in def.tags) {
        if (active.def.grantsImmunityToTags.contains(tag)) return true;
      }
    }
    return false;
  }

  /// Attempts to apply [def]. Returns the affected [ActiveStatus], or `null` if blocked
  /// by immunity or [StatusStackPolicy.rejectIfPresent].
  ActiveStatus? apply(
    StatusEffectDef def, {
    Object? sourceId,
    int initialStacks = 1,
  }) {
    if (isImmuneTo(def)) {
      onImmuneBlocked?.call(def);
      return null;
    }

    final clampedInit = math.max(1, math.min(def.maxStacks, initialStacks));

    if (def.stackPolicy != StatusStackPolicy.independentInstances) {
      for (final existing in _active) {
        if (existing.def.id == def.id) {
          switch (def.stackPolicy) {
            case StatusStackPolicy.rejectIfPresent:
              return null;
            case StatusStackPolicy.refreshDuration:
              existing.remainingDuration = def.duration;
              existing.remainingShield =
                  math.max(existing.remainingShield, def.absorbShieldAmount);
              onChanged?.call();
              return existing;
            case StatusStackPolicy.stackIntensity:
              existing.stacks = math.min(def.maxStacks, existing.stacks + clampedInit);
              existing.remainingDuration = def.duration;
              existing.remainingShield += def.absorbShieldAmount * clampedInit;
              onChanged?.call();
              return existing;
            case StatusStackPolicy.independentInstances:
              break;
          }
        }
      }
    }

    final inst = ActiveStatus(
      instanceId: _nextInstanceId++,
      def: def,
      stacks: clampedInit,
      remainingDuration: def.duration,
      remainingShield: def.absorbShieldAmount * clampedInit,
      sourceId: sourceId,
    );
    _active.add(inst);
    onApplied?.call(inst);
    onChanged?.call();
    return inst;
  }

  /// Advances active timers, fires DoT/HoT tick events cleanly, and expires finished effects.
  void step(double dt) {
    if (dt <= 0 || _active.isEmpty) return;

    final expired = <ActiveStatus>[];
    for (final inst in List<ActiveStatus>.of(_active)) {
      inst.elapsed += dt;

      if (inst.def.tickInterval > 0) {
        final effectiveDt = inst.isPermanent ? dt : math.min(dt, math.max(0.0, inst.remainingDuration));
        inst.tickAccumulator += effectiveDt;
        while (inst.tickAccumulator + 1e-9 >= inst.def.tickInterval) {
          inst.tickAccumulator -= inst.def.tickInterval;
          final mult = inst.def.scalesTickWithStacks ? inst.stacks : 1;
          final dmg = inst.def.damagePerTick * mult;
          final heal = inst.def.healPerTick * mult;
          if (dmg != 0.0 || heal != 0.0) {
            onTick?.call(StatusTickEvent(
              status: inst,
              damage: dmg,
              heal: heal,
              damageType: inst.def.damageType,
            ));
          }
        }
      }

      if (!inst.isPermanent) {
        inst.remainingDuration -= dt;
        if (inst.remainingDuration <= 1e-9) {
          inst.remainingDuration = 0.0;
          expired.add(inst);
        }
      }
    }

    if (expired.isNotEmpty) {
      for (final inst in expired) {
        _active.remove(inst);
        onExpired?.call(inst);
      }
      onChanged?.call();
    }
  }

  /// Removes up to [maxCount] effects carrying [tag] (or all matching when `maxCount == null`).
  int dispelByTag(String tag, {int? maxCount}) {
    var removed = 0;
    final toRemove = <ActiveStatus>[];
    for (final inst in _active) {
      if (inst.def.tags.contains(tag)) {
        toRemove.add(inst);
        removed++;
        if (maxCount != null && removed >= maxCount) break;
      }
    }
    if (toRemove.isNotEmpty) {
      for (final inst in toRemove) {
        _active.remove(inst);
        onRemoved?.call(inst);
      }
      onChanged?.call();
    }
    return removed;
  }

  int removeById(String effectId) {
    final removedList = _active.where((s) => s.def.id == effectId).toList();
    if (removedList.isEmpty) return 0;
    for (final inst in removedList) {
      _active.remove(inst);
      onRemoved?.call(inst);
    }
    onChanged?.call();
    return removedList.length;
  }

  void clear() {
    if (_active.isEmpty) return;
    final copy = List<ActiveStatus>.of(_active);
    _active.clear();
    for (final inst in copy) {
      onRemoved?.call(inst);
    }
    onChanged?.call();
  }

  /// Consumes incoming damage against active absorb shields (shortest duration first) and
  /// returns unabsorbed damage remaining.
  double absorbDamage(double incomingDamage) {
    if (incomingDamage <= 0.0) return 0.0;
    final shields = _active.where((s) => s.remainingShield > 0.0).toList()
      ..sort((a, b) => a.remainingDuration.compareTo(b.remainingDuration));

    var remaining = incomingDamage;
    var changed = false;
    for (final shield in shields) {
      if (remaining <= 0.0) break;
      final absorbed = math.min(remaining, shield.remainingShield);
      shield.remainingShield -= absorbed;
      remaining -= absorbed;
      changed = true;
    }

    if (changed) {
      onChanged?.call();
    }
    return remaining;
  }

  /// Aggregates flat, percentAdd, and percentMult bonuses across all active statuses per stat key.
  Map<String, ({double flat, double percentAdd, double percentMult})> aggregateStatBonuses() {
    final flats = <String, double>{};
    final adds = <String, double>{};
    final mults = <String, double>{};

    for (final inst in _active) {
      final stackMult = inst.def.scalesStatsWithStacks ? inst.stacks : 1;
      for (final e in inst.def.statBonuses.entries) {
        final key = e.key;
        final spec = e.value;
        flats[key] = (flats[key] ?? 0.0) + spec.flat * stackMult;
        adds[key] = (adds[key] ?? 0.0) + spec.percentAdd * stackMult;
        final stackPowMult = math.pow(spec.percentMult, stackMult).toDouble();
        mults[key] = (mults[key] ?? 1.0) * stackPowMult;
      }
    }

    final keys = {...flats.keys, ...adds.keys, ...mults.keys};
    return {
      for (final k in keys)
        k: (
          flat: flats[k] ?? 0.0,
          percentAdd: adds[k] ?? 0.0,
          percentMult: mults[k] ?? 1.0,
        ),
    };
  }
}
