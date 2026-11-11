import 'package:test/test.dart';
import 'package:voxrule/voxrule.dart';

void main() {
  group('StatusContainer effects, stacking, ticks, immunity & shields', () {
    test('handles stackIntensity, periodic DoT ticks, immunity & tag dispel', () {
      const poison = StatusEffectDef(
        id: 'poison',
        name: 'Poison',
        duration: 4.0,
        tickInterval: 1.0,
        maxStacks: 3,
        stackPolicy: StatusStackPolicy.stackIntensity,
        tags: {'debuff', 'poison'},
        damagePerTick: 5.0,
        damageType: DamageTypes.poison,
      );
      const purifyWard = StatusEffectDef(
        id: 'ward',
        name: 'Purify Ward',
        duration: 5.0,
        tags: {'buff'},
        grantsImmunityToTags: {'poison'},
      );
      const shieldDef = StatusEffectDef(
        id: 'arcane_barrier',
        name: 'Arcane Barrier',
        duration: 10.0,
        absorbShieldAmount: 40.0,
        statBonuses: {'armor': StatBonusSpec(flat: 20.0)},
      );

      final container = StatusContainer();
      var totalTickDmg = 0.0;
      var expiredCount = 0;
      container.onTick = (t) => totalTickDmg += t.damage;
      container.onExpired = (_) => expiredCount++;

      // Apply 2 stacks -> 10 dmg/tick
      container.apply(poison);
      container.apply(poison);
      expect(container.getStacks('poison'), 2);
      expect(container.hasTag('poison'), isTrue);

      container.step(2.0);
      expect(totalTickDmg, closeTo(20.0, 1e-6));

      // Dispel removes debuff cleanly
      expect(container.dispelByTag('debuff'), 1);
      expect(container.hasStatus('poison'), isFalse);

      // Apply immunity ward -> blocks poison
      container.apply(purifyWard);
      expect(container.apply(poison), isNull);

      // Shield absorption & stat aggregation
      container.apply(shieldDef);
      expect(container.totalShield, closeTo(40.0, 1e-6));
      final bonuses = container.aggregateStatBonuses();
      expect(bonuses['armor']!.flat, closeTo(20.0, 1e-6));

      expect(container.absorbDamage(25.0), closeTo(0.0, 1e-6));
      expect(container.totalShield, closeTo(15.0, 1e-6));
      expect(container.absorbDamage(30.0), closeTo(15.0, 1e-6));

      container.step(11.0);
      expect(expiredCount, greaterThanOrEqualTo(2));
    });

    test('supports rejectIfPresent and independentInstances policies cleanly', () {
      const lock = StatusEffectDef(
        id: 'first_strike',
        name: 'First Strike Lock',
        duration: 3.0,
        stackPolicy: StatusStackPolicy.rejectIfPresent,
      );
      const regen = StatusEffectDef(
        id: 'regen_hot',
        name: 'Regen',
        duration: 2.0,
        tickInterval: 1.0,
        stackPolicy: StatusStackPolicy.independentInstances,
        healPerTick: 8.0,
      );

      final c = StatusContainer();
      var healed = 0.0;
      c.onTick = (t) => healed += t.heal;

      expect(c.apply(lock), isNotNull);
      expect(c.apply(lock), isNull);

      c.apply(regen);
      c.apply(regen);
      expect(c.active.where((s) => s.def.id == 'regen_hot').length, 2);
      c.step(1.0);
      expect(healed, closeTo(16.0, 1e-6));
    });
  });

  group('CooldownTracker, TurnScheduler & CombatResolver', () {
    test('tracks standard cooldowns, CDR, GCD, and recharging multi-charge abilities', () {
      final cd = CooldownTracker();
      cd.configureCharges('dash', maxCharges: 2, rechargeDuration: 3.0);

      expect(cd.tryUse('dash', gcdDuration: 0.5), isTrue);
      expect(cd.getChargeState('dash')!.currentCharges, 1);
      expect(cd.isGcdActive, isTrue);
      expect(cd.tryUse('dash'), isFalse); // blocked by GCD

      cd.step(0.5);
      expect(cd.isGcdActive, isFalse);
      expect(cd.tryUse('dash'), isTrue);
      expect(cd.getChargeState('dash')!.currentCharges, 0);
      expect(cd.tryUse('dash'), isFalse);

      // Recharges 1 charge after 2.5s more (total 3.0s since first use!)
      cd.step(2.5);
      expect(cd.getChargeState('dash')!.currentCharges, 1);

      // Standard skill + CDR
      cd.start('ultimate', 20.0);
      expect(cd.isReady('ultimate'), isFalse);
      cd.reduce('ultimate', 12.0);
      expect(cd.remaining('ultimate'), closeTo(8.0, 1e-6));
      cd.step(8.0);
      expect(cd.isReady('ultimate'), isTrue);
    });

    test('schedules ATB speed gauges and round-based initiative fairly', () {
      final atb = TurnScheduler(mode: TurnMode.speedGauge);
      final rogue = CombatantSlot(id: 'rogue', name: 'Rogue', speed: 20.0);
      final knight = CombatantSlot(id: 'knight', name: 'Knight', speed: 10.0);
      atb.addCombatant(rogue);
      atb.addCombatant(knight);

      final preview = atb.previewOrder(3);
      expect(preview.map((s) => s.id).toList(), ['rogue', 'rogue', 'knight']);

      expect(atb.advanceNext()!.id, 'rogue');
      expect(atb.advanceNext()!.id, 'rogue');
      expect(atb.advanceNext()!.id, 'knight');

      // Stunned knight gets skipped cleanly
      knight.canAct = false;
      expect(atb.advanceNext()!.id, 'rogue');

      // Round initiative mode
      final dnd = TurnScheduler(mode: TurnMode.roundInitiative, seed: 42);
      dnd.addCombatant(CombatantSlot(id: 'a', name: 'A', initiativeBonus: 10));
      dnd.addCombatant(CombatantSlot(id: 'b', name: 'B', initiativeBonus: 0));
      final first = dnd.advanceNext();
      final second = dnd.advanceNext();
      expect(dnd.roundNumber, 1);
      expect({first!.id, second!.id}, {'a', 'b'});
      dnd.advanceNext();
      expect(dnd.roundNumber, 2);
    });

    test('resolves physical armor, pen, elemental weakness, crit, block & shield absorb', () {
      final sc = StatusContainer();
      sc.apply(const StatusEffectDef(
        id: 'barrier',
        name: 'Barrier',
        duration: 10.0,
        absorbShieldAmount: 15.0,
      ));

      final defender = CombatDefenseProfile(
        armor: 100.0, // 50% mitigation on physical (with 0 pen)
        resistances: {'fire': -0.5}, // +50% fire weakness!
        blockReduction: 0.5,
        statusContainer: sc,
      );

      // 100 physical * 1.5 crit = 150 -> / (1 + 100/100) = 75 -> blocked (* 0.5) = 37.5 -> 15 shield = 22.5 HP!
      final phys = CombatResolver.resolve(
        const DamagePacket(baseAmount: 100.0, critMultiplier: 1.5),
        defender,
        forceCrit: true,
        forceDodge: false,
        forceBlock: true,
      );
      expect(phys.postCritDamage, closeTo(150.0, 1e-6));
      expect(phys.mitigatedDamage, closeTo(37.5, 1e-6));
      expect(phys.absorbedByShield, closeTo(15.0, 1e-6));
      expect(phys.finalDamage, closeTo(22.5, 1e-6));

      // Fire attack exploits -0.5 weakness -> 50 * 1.5 = 75
      final fire = CombatResolver.resolve(
        const DamagePacket(baseAmount: 50.0, damageType: DamageTypes.fire),
        defender,
        forceCrit: false,
        forceDodge: false,
        forceBlock: false,
      );
      expect(fire.finalDamage, closeTo(75.0, 1e-6));
    });
  });
}
