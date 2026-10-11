import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Il numero che gira intorno a uno slider.
///
/// Esiste perche' un `Slider` nudo e' il peggior controllo di un'interfaccia:
/// si vede *dove* e' il cursore ma non *quanto* vale, e l'utente deve
/// guardare la bolla che spunta solo mentre trascina. Qui il valore sta sempre
/// scritto sopra, grande, e le estremita' stanno ai due capi: si capisce il
/// dominio senza dover provare.
///
/// Il formato lo decide il chiamante ([format]) perche' i tre slider dell'app
/// hanno domini diversi — un voto va da 0 a 10 con un decimale, un episodio e'
/// un intero, una soglia e' una percentuale — e formattare "8.0" dove si
/// aspetta "8" e' il tipo di piccola incoerenza che fa sembrare una app
/// costruita a pezzi.
class ArSlider extends StatelessWidget {
  const ArSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.format,
    this.semanticFormatter,
    this.caption,
  });

  /// Valore corrente. Deve stare fra [min] e [max].
  final double value;

  final double min;
  final double max;

  /// Numero di posizioni discrete. `null` per un regolatore continuo.
  final int? divisions;

  final ValueChanged<double> onChanged;

  /// Come mostrare il valore. Di default una riga con la parte intera e, se
  /// c'e', un decimale — quindi "8" e non "8.0".
  final String Function(double)? format;

  /// Come annunciare il valore agli screen reader.
  ///
  /// "8.0" letto ad alta voce non dice niente; "8 su 10" sì. Il default
  /// riusa [format], che va bene per i numeri e male per le percentuali.
  final String Function(double)? semanticFormatter;

  /// Riga sotto ai capi: dice a cosa serve il regolatore.
  final String? caption;

  String _format(double v) {
    if (format != null) return format!(v);
    // Un numero senza parte frazionia non vuole il ".0": e' la differenza
    // fra un valore e una media aritmetica.
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = divisions == null || divisions! <= 1 ? null : (max - min) / divisions!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Il valore in grande, non nella bolla: la bolla sparisce appena il
        // dito si alza, e il numero che sparisce non serve a niente.
        Text(
          _format(value),
          style: theme.textTheme.headlineMedium?.copyWith(
            color: theme.colorScheme.primary,
            height: 1,
          ),
        ),
        const SizedBox(height: ArSpace.xs),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: _format(value),
          // La bolla segue il tema di default, quindi sparisce a meta' del
          // gesto. Il valore grande e' la lettura stabile.
          onChanged: onChanged,
        ),
        // Le due estremita' ai lati: dicono il dominio senza dover provare il
        // cursore in fondo per scoprire che il massimo e' 10 e non 100.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_format(min), style: theme.textTheme.labelMedium),
            if (step != null)
              Text(
                'passi da ${_format(step)}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: ArColors.textLow,
                ),
              ),
            Text(_format(max), style: theme.textTheme.labelMedium),
          ],
        ),
        if (caption != null) ...[
          const SizedBox(height: ArSpace.xs),
          Text(
            caption!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// Una scelta fra poche alternative, sempre visibili.
///
/// Serve al posto di un menu a tendina quando le opzioni sono due o tre e
/// hanno tutte un nome che si capisce da solo. Un menu nasconde le opzioni
/// dietro un tocco e fa imparare a memoria quante sono; qui si vedono tutte e
/// il costo di sbagliare e' nullo.
///
/// Non il `SegmentedButton` di Material per la stessa ragione che vale per
/// [ArChip]: quello perde il testo selezionato nel suo stato, e su sfondo
/// scuro la voce scelta smette di essere leggibile.
class ArSegmented<T> extends StatelessWidget {
  const ArSegmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.scrollable = false,
  });

  /// Opzione scelta, o `null` se lo stato corrente non corrisponde a nessuna
  /// delle opzioni.
  ///
  /// Serve per gli schemi a scelta rapida che possono stare in uno stato che
  /// nessuna voce descrive: un utente che ha acceso tre cose su cinque. Senza
  /// `null` la barra dovrebbe scegliere da sola quale voce accendere, e
  /// accetterebbe una risposta falsa. Meglio non accenderne nessuna e lasciare
  /// che l utente torni dalle sue scelte.
  final T? value;

  final List<ArSegmentedOption<T>> options;

  final ValueChanged<T> onChanged;

  /// Con piu' di tre voci le etichette non entrano piu': diventa una riga che
  /// scorre invece di comprimerle fino a farle illeggibili.
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final buttons = options
        .map(
          (o) => Expanded(
            child: _Segment(
              option: o,
              selected: o.value == value,
              // Un riquadro solo per la voce scelta e' il segnale che rende
              // immediata la posizione nella serie: le pastiglie tutte uguali
              // obbligano a leggerle una per una.
              onTap: () => onChanged(o.value),
            ),
          ),
        )
        .toList();

    final body = scrollable
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (i, o) in options.indexed) ...[
                  if (i > 0) const SizedBox(width: ArSpace.xs),
                  SizedBox(
                    width: 120,
                    child: _Segment(
                      option: o,
                      selected: o.value == value,
                      onTap: () => onChanged(o.value),
                    ),
                  ),
                ],
              ],
            ),
          )
        : Row(children: buttons);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: ArColors.containerLowest,
        borderRadius: BorderRadius.circular(ArRadii.control),
        border: Border.all(color: ArColors.borderSoft),
      ),
      // I 3px di padding fanno stare il riquadro della voce scelta dentro il
      // bordo esterno, invece di toccarlo: senza, la voce attiva sembra
      // sfondare il bordo invece di essere dentro.
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: body,
      ),
    );
  }
}

/// Una voce di [ArSegmented].
class ArSegmentedOption<T> {
  const ArSegmentedOption({
    required this.value,
    required this.label,
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;
}

class _Segment<T> extends StatelessWidget {
  const _Segment({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final ArSegmentedOption<T> option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Semantics(
      // Ruolo di pulsante premuto, non di semplice testo: e' una scelta fra
      // alternative e uno screen reader deve dirlo.
      button: true,
      selected: selected,
      label: option.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: ArMotion.fast,
          curve: ArMotion.enter,
          padding: const EdgeInsets.symmetric(horizontal: ArSpace.md, vertical: 11),
          decoration: BoxDecoration(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(ArRadii.control - 4),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (option.icon != null) ...[
                Icon(
                  option.icon,
                  size: 16,
                  color: selected ? theme.colorScheme.onPrimary : ArColors.textMid,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.bodyFont,
                    fontSize: 13,
                    fontVariations: [
                      FontVariation('wght', selected ? 700 : 500),
                    ],
                    color: selected ? theme.colorScheme.onPrimary : ArColors.textMid,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Una riga di impostazione: icona, cosa fa, e il controllo a destra.
///
/// Esiste perche' l'app aveva due modi diversi per la stessa cosa: lo
/// `SwitchListTile` di Material nelle notifiche e una `_ActionRow` scritta a
/// mano nel profilo, con spaziatura, raggio e colori propri. Diventando due
/// versioni della stessa cosa, due righe identiche in due schermate sembrano
/// due righe diverse.
///
/// Il controllo a destra e' un [Widget] e non un flag booleano perche' la
/// stessa riga regge sia un interruttore sia una freccia sia una barra: la
/// forma cambia, il filo che tiene insieme le righe resta.
class ArSettingRow extends StatelessWidget {
  const ArSettingRow({
    super.key,
    required this.icon,
    required this.label,
    required this.trailing,
    this.subtitle,
    this.onTap,
    this.tint,
  });

  final IconData icon;
  final String label;
  final String? subtitle;

  /// Il controllo. Per una riga con spunta: `Switch` o `ArSlider` compatto.
  /// Per una riga che apre qualcosa: l'icona `chevron_right` va nell'[onTap]
  /// e in `trailing` basta il testo del valore corrente.
  final Widget trailing;

  /// Se c'e', la riga intera e' premibile e si comporta come un pulsante.
  final VoidCallback? onTap;

  /// Colore dell'icona quando significa qualcosa (torneoi, pericolo).
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tint ?? ArColors.primary;

    return Semantics(
      button: onTap != null,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ArRadii.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ArSpace.md,
            vertical: ArSpace.sm,
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: ArSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: theme.textTheme.titleMedium),
                    if (subtitle != null) ...[
                      const SizedBox(height: 1),
                      Text(subtitle!, style: theme.textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: ArSpace.sm),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// Il riquadro che contiene una sezione di impostazioni.
///
/// Il bordo e' quello di tutto il resto dell'app ([ArRadii.control] su
/// [ArColors.containerLow]) invece del bordo morbido e del raggio grande
/// delle card di contenuto: dentro il riquadro ci sono controlli, e un
/// contenitore che sembra una card fa sembrare premibili cose che non lo sono.
class ArControlCard extends StatelessWidget {
  const ArControlCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ArColors.containerLow,
        borderRadius: BorderRadius.circular(ArRadii.control),
        border: Border.all(color: ArColors.borderSoft),
      ),
      child: ClipRRect(
        // Il ritaglio segue il raggio, altrimenti l'ultima riga affianca il
        // bordo con gli angoli sbagliati.
        borderRadius: BorderRadius.circular(ArRadii.control),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _withDividers(children),
        ),
      ),
    );
  }

  /// Mette un filo fra una riga e l'altra.
  ///
  /// Il filo parte da sinistra del contenuto e non dal bordo della card: se
  /// parte dal bordo sembra una divisione fra sezioni, mentre qui divide due
  /// voci della stessa sezione.
  static List<Widget> _withDividers(List<Widget> items) {
    if (items.isEmpty) return items;

    final out = <Widget>[items.first];
    for (final item in items.skip(1)) {
      out.add(
        const Padding(
          padding: EdgeInsets.only(left: ArSpace.xxl + ArSpace.md),
          child: Divider(height: 1),
        ),
      );
      out.add(item);
    }
    return out;
  }
}
