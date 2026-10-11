import 'package:animerank/core/theme/section_accent.dart';
import 'package:animerank/core/ui/ar_badge.dart';
import 'package:animerank/core/ui/section_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Accenti di sezione e come scendono ai widget.
///
/// Il colore di una sezione e' l'unico elemento che dice "sei qui" senza
/// leggere il titolo, quindi vale la pena fissarne il contratto: ogni sezione
/// una tinta, un gradiente sempre a due colori, e uno scope che non mente
/// quando l'accento non c'e'.
void main() {
  test('ogni sezione ha un accento', () {
    expect(ArAccent.values.length, 8);
    for (final accent in ArAccent.values) {
      expect(accent.gradient.colors, hasLength(2));
      expect(ArAccent.home.gradient.colors.length, 2);
    }
  });

  test('il gradiente parte dal colore base', () {
    for (final accent in ArAccent.values) {
      expect(accent.gradient.colors.first, accent.base);
    }
  });

  test('la tinta tenue e appena visibile', () {
    expect(ArAccent.ranking.soft.a, closeTo(0.14, 0.001));
    expect(ArAccent.ranking.faint.a, closeTo(0.08, 0.001));
  });

  testWidgets('senza scope l accento e quello della home', (tester) async {
    ArAccent? maybe;
    late ArAccent seen;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            seen = SectionAccentScope.of(context);
            maybe = SectionAccentScope.maybeOf(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(seen, ArAccent.home);
    expect(maybe, isNull);
  });

  testWidgets('lo scope fornisce l accento ai discendenti', (tester) async {
    late ArAccent seen;

    await tester.pumpWidget(
      MaterialApp(
        home: SectionAccentScope(
          accent: ArAccent.groups,
          child: Builder(
            builder: (context) {
              seen = SectionAccentScope.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    expect(seen, ArAccent.groups);
  });

  testWidgets('il filtro selezionato prende la tinta della sezione',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SectionAccentScope(
          accent: ArAccent.ranking,
          child: ArChip(label: 'Tutti', selected: true, onTap: () {}),
        ),
      ),
    );

    final decoration = tester
        .widget<AnimatedContainer>(find.byType(AnimatedContainer))
        .decoration! as BoxDecoration;

    expect(
      decoration.color,
      ArAccent.ranking.base.withValues(alpha: 0.18),
    );
    expect(
      (decoration.border! as Border).top.color,
      ArAccent.ranking.base,
    );
  });

  testWidgets('il badge senza colore prende l accento della sezione', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SectionAccentScope(
          accent: ArAccent.groups,
          child: const ArBadge(icon: Icons.groups_outlined),
        ),
      ),
    );

    final container = tester.widget<Container>(
      find.descendant(of: find.byType(ArBadge), matching: find.byType(Container)),
    );
    final decoration = container.decoration! as BoxDecoration;

    expect(decoration.color, ArAccent.groups.soft);
    expect(tester.widget<Icon>(find.byType(Icon)).color, ArAccent.groups.base);
  });

  testWidgets('il bordo c e solo quando lo si chiede', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ArBadge(icon: Icons.star)),
    );
    expect(_border(tester), isNull);

    await tester.pumpWidget(
      const MaterialApp(home: ArBadge(icon: Icons.star, outline: true)),
    );
    expect(_border(tester), isNotNull);
  });
}

/// Bordo del [Container] disegnato dentro l'[ArBadge].
BoxBorder? _border(WidgetTester tester) {
  final container = tester.widget<Container>(
    find.descendant(
      of: find.byType(ArBadge),
      matching: find.byType(Container),
    ),
  );
  return (container.decoration! as BoxDecoration).border;
}

