import 'dart:math' as math;

import 'effects.dart';

/// Standard semantic damage channel names.
abstract final class DamageTypes {
  static const physical = 'physical';
  static const fire = 'fire';
  static const ice = 'ice';
  static const lightning = 'lightning';
  static const poison = 'poison';
  static const arcane = 'arcane';
  static const trueDamage = 'true';
}

/// Outgoing attack payload resolved against a defender's [CombatDefenseProfile].
final class DamagePacket {
  final double baseAmount;
  final String damageType;
  final Object? sourceId;
  final Object? targetId;
  final double critChance;
  final double critMultiplier;
  final double armorPenetration;
  final bool canDodge;
  final bool canBlock;
  final bool ignoreShields;

  const DamagePacket({
    required this.baseAmount,
    this.damageType = DamageTypes.physical,
    this.sourceId,
    this.targetId,
    this.critChance = 0.0,
    this.critMultiplier = 1.5,
    this.armorPenetration = 0.0,
    this.canDodge = true,
    this.canBlock = true,
    this.ignoreShields = false,
  });
}

/// Defender mitigation stats and optional shield-bearing [StatusContainer].
final class CombatDefenseProfile {
  double armor;
  final Map<String, double> resistances;
  double dodgeChance;
  double blockChance;
  double blockReduction;
  StatusContainer? statusContainer;

  CombatDefenseProfile({
    this.armor = 0.0,
    Map<String, double>? resistances,
    this.dodgeChance = 0.0,
    this.blockChance = 0.0,
    this.blockReduction = 0.5,
    this.statusContainer,
  }) : resistances = resistances ?? {};
}

/// Detailed breakdown produced by [CombatResolver.resolve].
final class CombatResult {
  final double rawDamage;
  final double postCritDamage;
  final double mitigatedDamage;
  final double absorbedByShield;
  final double finalDamage;
  final bool wasCrit;
  final bool wasDodged;
  final bool wasBlocked;
  final String damageType;

  const CombatResult({
    required this.rawDamage,
    required this.postCritDamage,
    required this.mitigatedDamage,
    required this.absorbedByShield,
    required this.finalDamage,
    required this.wasCrit,
    required this.wasDodged,
    required this.wasBlocked,
    required this.damageType,
  });
}

/// Deterministic damage mitigation pipeline supporting dodge, crit, armor,
/// elemental resistances (including weaknesses), blocking, and absorb shields.
abstract final class CombatResolver {
  static final _defaultRng = math.Random();

  static CombatResult resolve(
    DamagePacket packet,
    CombatDefenseProfile defense, {
    math.Random? rng,
    bool? forceCrit,
    bool? forceDodge,
    bool? forceBlock,
  }) {
    final random = rng ?? _defaultRng;
    final isTrue = packet.damageType == DamageTypes.trueDamage;

    // 1. Dodge check
    final dodged = !isTrue &&
        packet.canDodge &&
        (forceDodge ?? (defense.dodgeChance > 0.0 && random.nextDouble() < defense.dodgeChance));
    if (dodged) {
      return CombatResult(
        rawDamage: packet.baseAmount,
        postCritDamage: 0.0,
        mitigatedDamage: 0.0,
        absorbedByShield: 0.0,
        finalDamage: 0.0,
        wasCrit: false,
        wasDodged: true,
        wasBlocked: false,
        damageType: packet.damageType,
      );
    }

    // 2. Critical hit roll
    final crit = forceCrit ?? (packet.critChance > 0.0 && random.nextDouble() < packet.critChance);
    var dmg = math.max(0.0, packet.baseAmount) * (crit ? packet.critMultiplier : 1.0);
    final postCrit = dmg;

    if (!isTrue) {
      // 3. Armor diminishing-returns mitigation (physical only)
      if (packet.damageType == DamageTypes.physical && defense.armor > 0.0) {
        final effectiveArmor =
            math.max(0.0, defense.armor * (1.0 - packet.armorPenetration.clamp(0.0, 1.0)));
        dmg *= 100.0 / (100.0 + effectiveArmor);
      }

      // 4. Elemental / channel resistance (supports negative weakness values!)
      final res = defense.resistances[packet.damageType] ?? 0.0;
      dmg *= math.max(0.0, 1.0 - res.clamp(-2.0, 0.95));
    }

    // 5. Block reduction
    final blocked = !isTrue &&
        packet.canBlock &&
        (forceBlock ?? (defense.blockChance > 0.0 && random.nextDouble() < defense.blockChance));
    if (blocked) {
      dmg *= (1.0 - defense.blockReduction.clamp(0.0, 1.0));
    }

    final mitigated = dmg;

    // 6. Status absorb shields
    var absorbed = 0.0;
    var finalDmg = mitigated;
    if (!packet.ignoreShields && defense.statusContainer != null && mitigated > 0.0) {
      finalDmg = defense.statusContainer!.absorbDamage(mitigated);
      absorbed = mitigated - finalDmg;
    }

    return CombatResult(
      rawDamage: packet.baseAmount,
      postCritDamage: postCrit,
      mitigatedDamage: mitigated,
      absorbedByShield: absorbed,
      finalDamage: finalDmg,
      wasCrit: crit,
      wasDodged: false,
      wasBlocked: blocked,
      damageType: packet.damageType,
    );
  }
}
