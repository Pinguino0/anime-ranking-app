import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/controls.dart';
import '../../../../core/ui/section_header.dart';
import '../../domain/user_profile.dart';
import '../profile_controller.dart';

/// Preferenze di notifica.
///
/// La scelta qui non e' "un interruttore per riga", che era comodo e non diceva
/// niente: cinque righe identiche, tutte accese o tutte spente, con la stessa
/// importanza ai occhi di chi le legge. In realta gli avvisi non hanno lo
/// stesso peso — una richiesta di amicizia arriva una volta, un cambio di
/// posizione in classifica arriva cento volte — e un utente che vuole
/// silenziare solo il rumore non poteva dirlo.
///
/// Per questo l'alto c'e' una scelta fra tre ("tutte", "le importanti",
/// "nessuna") e sotto stanno le voci, raggruppate per quando arrivano.
/// Quando si sceglie una delle due modalita' fisse le spunte si aggiornano
/// tutte insieme e diventano grigie: non serve cambiare una per una e non si
/// puo' creare senza accorgersene una combinazione che non esiste.
///
/// Nota sul "perche' non uno slider": le preferenze sono booleani nel
/// database. Uno slider a tre posizioni mostrerebbe "a volte" per una scelta
/// che il backend non puo' salvare, e uno a due posizioni sarebbe uno switch
/// con un gavettone in piu'. Il gradino si usa dove il dato e' continuo (il
/// voto, l'episodio, la soglia della classifica), non qui.
class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(notificationPreferencesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Notifiche')),
      body: prefs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AuthErrorBanner.error('$error'),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () => ref.invalidate(notificationPreferencesProvider),
                  child: const Text('Riprova'),
                ),
              ],
            ),
          ),
        ),
        data: (data) => _List(prefs: data),
      ),
    );
  }
}

/// Le tre modalita' del comando in alto.
///
/// Non c'e' un valore "personalizzato" perche' non e' una modalita' che si
/// sceglie: e' quello che resta quando l'utente muove una spunta a mano, e il
/// comando in alto semplicemente non ha piu' niente da dire. Sarebbe stato
/// possibile mostrare una quarta voce "Personalizzate", ma proporre "Tutte"
/// mentre due voci sono spente e' peggio che non proporre niente.
enum _Mode {
  /// Tutte le voci accese.
  all,

  /// Solo quelle che non si ripetono da sole: amici e push.
  important,

  /// Tutte spente.
  none,
}

/// Quale modalita' descrive la combinazione corrente, o `null` se e' mista.
///
/// Il `null` e' un risultato e non una dimenticanza: e' il caso in cui
/// l'utente ha toccato le spunte a mano e nessuna delle tre modalita'
/// descrive quello che c'e'. Restituirgli comunque [\_Mode.all] farebbe dire
/// alla barra una cosa che non e' vera, e l'utente leggerebbe "Tutte" sopra
/// un paio di voci spente.
_Mode? _modeOf(NotificationPreferences p) {
  if (p.allOff) return _Mode.none;
  if (p.push &&
      p.friends &&
      p.recommendations &&
      !p.votes &&
      !p.tournaments &&
      !p.rankChanges) {
    return _Mode.important;
  }
  final every = p.push &&
      p.votes &&
      p.friends &&
      p.tournaments &&
      p.rankChanges &&
      p.recommendations;
  return every ? _Mode.all : null;
}

class _List extends ConsumerStatefulWidget {
  const _List({required this.prefs});

  final NotificationPreferences prefs;

  @override
  ConsumerState<_List> createState() => _ListState();
}

class _ListState extends ConsumerState<_List> {
  String? _error;

  /// Le voci considerate importanti: le uniche che non arrivano da sole a
  /// raffica, quindi quelle che si possono tenere senzache diventi rumore.
  static const bool _importantPush = true;
  static const bool _importantFriends = true;
  static const bool _importantRecommendations = true;

  /// Salvataggio di un interruttore.
  ///
  /// L'errore viene riportato qui invece che far fallire il provider: se
  /// l'errore finisse nello stato, l'interruttore tornerebbe indietro da solo
  /// senza spiegare perche'.
  Future<void> _set({bool? push, bool? votes, bool? friends,
      bool? tournaments, bool? rankChanges, bool? recommendations}) async {
    setState(() => _error = null);

    try {
      await ref.read(notificationPreferencesProvider.notifier).set(
            push: push,
            votes: votes,
            friends: friends,
            tournaments: tournaments,
            rankChanges: rankChanges,
            recommendations: recommendations,
          );
    } on ProfileFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  /// Applica una modalita' a tutte le voci.
  Future<void> _applyMode(_Mode mode) async {
    switch (mode) {
      case _Mode.all:
        await _set(
          push: true,
          votes: true,
          friends: true,
          tournaments: true,
          rankChanges: true,
          recommendations: true,
        );
      case _Mode.important:
        await _set(
          push: _importantPush,
          votes: false,
          friends: _importantFriends,
          tournaments: false,
          rankChanges: false,
          recommendations: _importantRecommendations,
        );
      case _Mode.none:
        await _set(
          push: false,
          votes: false,
          friends: false,
          tournaments: false,
          rankChanges: false,
          recommendations: false,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = widget.prefs;
    final page = ArSpace.page(context);
    final mode = _modeOf(prefs);

    // Sotto una modalita' fissa le spunte non sono piu' sue: premere una riga
    // dovrebbe poter cambiare la modalita' e non viceversa, quindi si
    // disattivano e si spiega perche'.
    final locked = mode != _Mode.all;

    return ListView(
      padding: EdgeInsets.fromLTRB(page.left, ArSpace.lg, page.right, ArSpace.xxl),
      children: [
        if (_error != null) ...[
          AuthErrorBanner.error(_error!),
          const SizedBox(height: ArSpace.md),
        ],

        ArSegmented<_Mode>(
          value: mode,
          onChanged: _applyMode,
          options: const [
            ArSegmentedOption(value: _Mode.all, label: 'Tutte'),
            ArSegmentedOption(
              value: _Mode.important,
              label: 'Solo importanti',
              icon: Icons.priority_high,
            ),
            ArSegmentedOption(value: _Mode.none, label: 'Nessuna'),
          ],
        ),
        const SizedBox(height: ArSpace.xs),
        Text(
          locked
              ? 'Stai in una modalita\' fissa: le spunte sotto sono grigie e non si toccano. Scegli "Tutte" per modificarle a una.'
              : 'Scegli tu cosa ricevere: ogni riga si accende e si spegne.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),

        const SizedBox(height: ArSpace.lg),
        const SectionHeader(
          title: 'Persona',
          subtitle: 'Arrivano una volta e sono tu.',
        ),
        ArControlCard(
          children: [
            ArSettingRow(
              icon: Icons.notifications_active_outlined,
              label: 'Notifiche push',
              subtitle: 'Avvisi sul dispositivo.',
              onTap: locked ? null : () => _set(push: !prefs.push),
              trailing: _Switch(
                value: prefs.push,
                enabled: !locked,
                onChanged: (v) => _set(push: v),
              ),
            ),
            ArSettingRow(
              icon: Icons.people_alt_outlined,
              label: 'Amici',
              subtitle: 'Richieste e attivita dei contatti.',
              onTap: locked ? null : () => _set(friends: !prefs.friends),
              trailing: _Switch(
                value: prefs.friends,
                enabled: !locked,
                onChanged: (v) => _set(friends: v),
              ),
            ),
            ArSettingRow(
              icon: Icons.recommend_outlined,
              label: 'Consigli',
              subtitle: 'Quando qualcuno ti consiglia un anime.',
              onTap: locked
                  ? null
                  : () => _set(recommendations: !prefs.recommendations),
              trailing: _Switch(
                value: prefs.recommendations,
                enabled: !locked,
                onChanged: (v) => _set(recommendations: v),
              ),
            ),
          ],
        ),

        const SizedBox(height: ArSpace.lg),
        const SectionHeader(
          title: 'Attivita\'',
          subtitle: 'Arrivano spesso: e\' quello che genera rumore.',
        ),
        ArControlCard(
          children: [
            ArSettingRow(
              icon: Icons.how_to_vote_outlined,
              label: 'Nuove votazioni',
              subtitle: 'Quando qualcuno vota un anime che guardi.',
              onTap: locked ? null : () => _set(votes: !prefs.votes),
              trailing: _Switch(
                value: prefs.votes,
                enabled: !locked,
                onChanged: (v) => _set(votes: v),
              ),
            ),
            ArSettingRow(
              icon: Icons.emoji_events_outlined,
              label: 'Tornei',
              subtitle: 'Inizio, fasi e risultati.',
              onTap: locked ? null : () => _set(tournaments: !prefs.tournaments),
              trailing: _Switch(
                value: prefs.tournaments,
                enabled: !locked,
                onChanged: (v) => _set(tournaments: v),
              ),
            ),
            ArSettingRow(
              icon: Icons.trending_up,
              label: 'Cambiamenti di classifica',
              subtitle: 'Quando la posizione di un anime si muove.',
              onTap: locked ? null : () => _set(rankChanges: !prefs.rankChanges),
              trailing: _Switch(
                value: prefs.rankChanges,
                enabled: !locked,
                onChanged: (v) => _set(rankChanges: v),
              ),
            ),
          ],
        ),

        if (prefs.allOff) ...[
          const SizedBox(height: ArSpace.lg),
          Row(
            children: [
              const Icon(
                Icons.notifications_off_outlined,
                size: 20,
                color: ArColors.textMid,
              ),
              const SizedBox(width: ArSpace.sm),
              Expanded(
                child: Text(
                  'Non riceverai piu\' nulla. Puoi cambiare idea quando vuoi.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// L'interruttore, dentro [ArSettingRow].
///
/// Serve perche' `ArSettingRow` accetta il controllo come [Widget] e non un
/// flag: cosi' la stessa riga regge un interruttore, una freccia o una barra.
/// Qui c'e' solo la parte "spento" che uno `Switch` di Material non fa — il
/// grigio quando e' bloccato — perche' un interruttore disattivato che sembra
/// ancora normale fa pensare che si possa premere.
class _Switch extends StatelessWidget {
  const _Switch({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !enabled,
      child: AnimatedOpacity(
        duration: ArMotion.fast,
        opacity: enabled ? 1 : 0.4,
        child: Switch.adaptive(value: value, onChanged: onChanged),
      ),
    );
  }
}

// La scelta del tema (colonna `profiles.theme`) e' volutamente fuori da qui:
// richiede di scrivere il tema scelto su Supabase e di applicarlo al
// MaterialApp, quindi tocca `app.dart`. Viene aggiunta con il resto del
// materiale di profilo, non con un interruttore finto.
