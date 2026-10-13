import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/section_accent.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/section_header.dart';
import '../../../../core/ui/transitions.dart';
import '../../../auth/presentation/auth_controller.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../../watchlist/domain/watchlist.dart';
import '../../../watchlist/presentation/watchlist_controller.dart';
import '../../data/avatar_picker.dart';
import '../../domain/user_profile.dart';
import '../profile_controller.dart';
import '../widgets/avatar.dart';

/// Schermata profilo.
///
/// Mostra i dati pubblici, permette di modificarli e porta alle impostazioni.
/// Niente "cancella account" qui dentro il form: e' un'azione distruttiva e
/// sta in una schermata separata.
///
/// La pagina e' pensata come una pagina utente e non come un form: il nome, la
/// bio e l'iscrizione stanno in un banner in alto, i campi sono una sezione fra
/// le altre, e le azioni sono raccolte sotto. Un utente che apre il profilo
/// vuole vedere chi e', non compilare due text field.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final size = Breakpoints.fromContext(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profilo'),
        actions: [
          IconButton(
            tooltip: 'Impostazioni notifiche',
            onPressed: () => context.push('/profile/notifications'),
            icon: const Icon(Icons.notifications_outlined),
          ),
        ],
      ),
      body: profile.when(
        // Scheletro e non girone: il profilo sta in un banner in alto, e una
        // sola riga di contenuto che pulsa dice gia' "sto caricando" senza far
        // saltare il layout quando i dati arrivano.
        loading: () => const _ProfileSkeleton(),
        error: (error, _) => ErrorState(
          message: _failureMessage(error),
          onRetry: () => ref.read(profileProvider.notifier).refresh(),
        ),
        data: (data) => _Body(profile: data, size: size),
      ),
    );
  }

  /// Messaggio d'errore pronto per l'utente.
  ///
  /// `'$error'` stamperebbe a video la stringa dell'eccezione — "Exception:
  /// Bad state: ..." o un errore di Postgres in inglese — che non dice nulla a
  /// chi ha sbagliato a premere. I repository gia' traducono i propri codici in
  /// italiano dentro [AppFailure.message]: qui basta leggerlo, e il fallback
  /// serve solo per un errore che non e' passato dagli strati previsti.
  String _failureMessage(Object error) {
    if (error is AppFailure) return error.message;
    return 'Profilo non disponibile. Riprova.';
  }
}

/// Scheletro della pagina.
///
/// Rispecchia la struttura reale (banner, due sezioni) perche' uno scheletro
/// generico e' un rettangolo grigio che al caricamento lascia il vuoto: qui si
/// vede gia' dove andra' a finire ogni pezzo.
class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        ArSpace.page(context).left,
        ArSpace.lg,
        ArSpace.page(context).right,
        ArSpace.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: ArColors.containerLow,
              borderRadius: BorderRadius.circular(ArRadii.card),
            ),
            child: Padding(
              padding: const EdgeInsets.all(ArSpace.lg),
              child: Column(
                children: [
                  const SkeletonBox(height: 104, radius: 52),
                  const SizedBox(height: ArSpace.md),
                  const SkeletonBox(width: 160, height: 22),
                  const SizedBox(height: ArSpace.sm),
                  const SkeletonBox(height: 14),
                ],
              ),
            ),
          ),
          const SizedBox(height: ArSpace.xl),
          const SkeletonBox(width: 150, height: 20),
          const SizedBox(height: ArSpace.md),
          const SkeletonBox(height: 52, radius: ArRadii.control),
          const SizedBox(height: ArSpace.md),
          const SkeletonBox(height: 120, radius: ArRadii.control),
        ],
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.profile, required this.size});

  final UserProfile profile;
  final LayoutSize size;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  final _formKey = GlobalKey<FormState>();
  late final _username = TextEditingController(text: widget.profile.username);
  late final _bio = TextEditingController(text: widget.profile.bio ?? '');

  bool _busy = false;
  String? _error;
  bool _saved = false;

  /// Vero mentre la foto scelta sta venendo caricata.
  ///
  /// Separato da [_busy] perche' e' un'altra azione: salvare il nome mentre la
  /// foto sale non deve bloccare i campi, e viceversa.
  bool _avatarBusy = false;

  @override
  void dispose() {
    _username.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
      _saved = false;
    });

    try {
      await ref.read(profileProvider.notifier).save(
            username: _username.text,
            bio: _bio.text,
          );
      if (!mounted) return;
      setState(() => _saved = true);
    } on ProfileFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Sceglie e carica una nuova foto profilo.
  ///
  /// L'apertura della galleria e' un passo a se': puo' fallire (permesso
  /// negato, picker non disponibile) o essere annullata, e in entrambi i casi
  /// il profilo non va toccato. Solo dopo si passa all'upload.
  Future<void> _changeAvatar() async {
    final PickedAvatar? picked;
    try {
      picked = await ref.read(avatarPickerProvider).pick();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Non e stato possibile aprire le immagini.');
      return;
    }

    // Annullato dall'utente: nessun messaggio, non e' un errore.
    if (picked == null) return;

    if (picked.bytes.length > ProfileValidators.maxAvatarBytes) {
      setState(() => _error = 'Immagine troppo grande (max 2 MB).');
      return;
    }

    setState(() {
      _avatarBusy = true;
      _error = null;
      _saved = false;
    });

    try {
      await ref.read(profileProvider.notifier).setAvatar(
            bytes: picked.bytes,
            extension: picked.extension,
          );
      if (!mounted) return;
      setState(() => _saved = true);
    } on ProfileFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final page = ArSpace.page(context);

    final form = _card(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _username,
              enabled: !_busy,
              textInputAction: TextInputAction.next,
              // inputFormatters e non solo validazione: senza, il campo puo'
              // assumere valori che il CHECK del database rifiuterebbe e
              // l'utente scoprirebbe il problema solo salvando.
              inputFormatters: [
                LengthLimitingTextInputFormatter(ProfileValidators.maxUsernameLength),
                FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9_]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Nome utente',
                helperText: '3-24 caratteri: lettere, numeri e _',
                prefixIcon: Icon(Icons.alternate_email),
              ),
              validator: ProfileValidators.usernameError,
            ),
            const SizedBox(height: ArSpace.md),
            TextFormField(
              controller: _bio,
              enabled: !_busy,
              minLines: 3,
              maxLines: 6,
              maxLength: ProfileValidators.maxBioLength,
              decoration: const InputDecoration(
                labelText: 'Bio',
                hintText: 'Qualcosa su di te (facoltativo)',
                alignLabelWithHint: true,
              ),
              validator: ProfileValidators.bioError,
            ),
            const SizedBox(height: ArSpace.sm),
            _saveButton(context),
          ],
        ),
      ),
    );

    final hero = ArReveal(
      child: _ProfileHero(
        profile: profile,
        busy: _avatarBusy,
        onEditAvatar: _changeAvatar,
      ),
    );

    // Statistiche personali: subito sotto l'identita' e prima del resto, perche'
    // sono il ritratto di quello che l'utente ha fatto. Si caricano a parte, con
    // il loro provider: se non rispondono, nome e bio restano modificabili.
    const statsSection = _StatsSection();

    final editSection = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          title: 'Modifica profilo',
          // Il sottotitolo dice chi vede questi due campi: senza, "Bio" e' un
          // campo come tanti e non si capisce se sia pubblico.
          subtitle: 'Nome e bio sono pubblici: li vede chi legge le tue schede.',
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: ArSpace.sm),
        form,
      ],
    );

    // Quello che l'utente ha fatto, non quello che puo' modificare: preferiti e
    // cronologia stanno sopra le impostazioni perche' il profilo e' prima di
    // tutto una vetrina di se stessi. Le voci che cambiano qualcosa (notifiche,
    // obiettivi, sessione) stanno sotto.
    final activitySection = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          title: 'La tua attivita',
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: ArSpace.sm),
        _card(
          padding: const EdgeInsets.symmetric(vertical: ArSpace.xs),
          child: Column(
            children: [
              _ActionRow(
                icon: Icons.star_border,
                label: 'Preferiti',
                value: 'Le opere che hai segnato con la stella',
                onTap: () => context.push(AppRoutes.favorites),
              ),
              const Divider(height: 1, indent: ArSpace.md, endIndent: ArSpace.md),
              _ActionRow(
                icon: Icons.history,
                label: 'Cronologia',
                value: 'Gli episodi aperti, dal piu\' recente',
                onTap: () => context.push(AppRoutes.watchHistory),
              ),
            ],
          ),
        ),
      ],
    );

    final settingsSection = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          title: 'Impostazioni',
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: ArSpace.sm),
        _card(
          padding: const EdgeInsets.symmetric(vertical: ArSpace.xs),
          child: Column(
            children: [
              _ActionRow(
                icon: Icons.notifications_outlined,
                label: 'Notifiche',
                // Le preferenze stanno sulla stessa riga del database ma sono
                // un'altra cosa: una schermata separata evita di far salvare un
                // nome per errore mentre si sta toccando un interruttore.
                value: 'Push, voti, amici, tornei',
                onTap: () => context.push('/profile/notifications'),
              ),
              const Divider(height: 1, indent: ArSpace.md, endIndent: ArSpace.md),
              _ActionRow(
                icon: Icons.workspace_premium_outlined,
                label: 'Obiettivi',
                // I traguardi si vedono in una pagina propria: sono dodici righe
                // con una descrizione, e in una riga di impostazioni non ci
                // starebbero.
                value: 'Traguardi sbloccati',
                onTap: () => context.push('/profile/achievements'),
              ),
            ],
          ),
        ),
      ],
    );

    final sessionSection = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          title: 'Sessione',
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: ArSpace.sm),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => ref.read(authStatusProvider.notifier).signOut(),
                icon: const Icon(Icons.logout),
                label: const Text('Esci'),
              ),
              const SizedBox(height: ArSpace.sm),
              // Azione distruttiva: il pericolo e' detto dal tema, non da un
              // colore applicato a mano su icona e label. Il pulsante resta
              // sulla schermata di conferma, non parte da qui.
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.colors.error,
                  side: BorderSide(
                    color: context.colors.error.withValues(alpha: 0.45),
                  ),
                ),
                onPressed: () => context.push('/profile/delete'),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Elimina account'),
              ),
            ],
          ),
        ),
      ],
    );

    // Sopra i messaggi di esito e di errore, non dentro il form: un errore di
    // salvataggio che compare tre schermate piu' in basso, dentro la colonna
    // di sinistra, sembra un campo che non ha reagito.
    final feedback = <Widget>[
      if (_error != null) ...[
        AuthErrorBanner.error(_error!),
        const SizedBox(height: ArSpace.md),
      ],
      if (_saved) ...[
        AuthErrorBanner.notice('Profilo salvato.'),
        const SizedBox(height: ArSpace.md),
      ],
    ];

    // Da 900px in su due colonne vere: il banner profilo e la sessione a
    // sinistra, i campi a destra. Sotto, una colonna sola — a 700px due colonne
    // darebbero campi larghi 300px accanto a un banner di 250px, e nessuno dei
    // due avrebbe piu' spazio di quanto ne aveva nel layout a colonna singola.
    // Da 900px in su due colonne vere: il banner profilo e la sessione a
    // sinistra, i campi a destra. Sotto, una colonna sola — a 700px due colonne
    // darebbero campi larghi 300px accanto a un banner di 250px, e nessuno dei
    // due avrebbe piu' spazio di quanto ne aveva nel layout a colonna singola.
    //
    // Le due colonne stanno in una `Row` e non in una `Column`: `Expanded`
    // dentro una colonna distribuirebbe l'altezza, e dentro uno scroll
    // l'altezza e' infinita, quindi Flutter non saprebbe quanto spazio dare.
    // Su schermo largo la schermata restava nera per intero.
    final content = widget.size.isExpanded
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    hero,
                    const SizedBox(height: ArSpace.xl),
                    statsSection,
                    const SizedBox(height: ArSpace.xl),
                    activitySection,
                    const SizedBox(height: ArSpace.xl),
                    sessionSection,
                  ],
                ),
              ),
              const SizedBox(width: ArSpace.xl),
              Expanded(
                flex: 6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...feedback,
                    editSection,
                    const SizedBox(height: ArSpace.lg),
                    settingsSection,
                  ],
                ),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              hero,
              const SizedBox(height: ArSpace.xl),
              statsSection,
              const SizedBox(height: ArSpace.xl),
              activitySection,
              const SizedBox(height: ArSpace.xl),
              ...feedback,
              editSection,
              const SizedBox(height: ArSpace.lg),
              settingsSection,
              const SizedBox(height: ArSpace.lg),
              sessionSection,
            ],
          );

    // `SingleChildScrollView` e non `ListView`: con la tastiera aperta la
    // `ListView` dimensiona lo scroll sul viewport che vede, che con
    // `resizeToAvoidBottomInset` non coincide con quello reale, e il campo in
    // cui si scrive resta sotto la tastiera.
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        page.left,
        ArSpace.lg,
        page.right,
        ArSpace.xxl,
      ),
      child: content,
    );
  }

  /// Superficie tonale con bordo morbido: il contenitore delle sezioni.
  ///
  /// Senza questa cornice i campi galleggerebbero sul nero del fondo e la
  /// pagina sembrerebbe un elenco di moduli invece di un documento.
  Widget _card({required Widget child, EdgeInsets? padding}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ArColors.containerLow,
        borderRadius: BorderRadius.circular(ArRadii.card),
        border: Border.all(color: ArColors.borderSoft),
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.all(ArSpace.md),
        child: child,
      ),
    );
  }

  /// Pulsante di salvataggio.
  ///
  /// Il gradiente del tema e' l'azione principale della pagina, quindi e' il
  /// pulsante pieno e colorato: un `FilledButton` grigio in questa posizione
  /// sembrerebbe uno dei tre pulsanti equivalenti. Durante il salvataggio il
  /// gradiente sparisce e resta lo scheletro del pulsante, cosi' l'utente
  /// vede che l'azione e' partita e non che il pulsante sia sparito.
  Widget _saveButton(BuildContext context) {
    if (!_busy) {
      return ArGradientButton(
        label: 'Salva',
        icon: Icons.check,
        onPressed: _save,
        expand: true,
      );
    }

    return Container(
      height: 50,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ArColors.containerHighest,
        borderRadius: BorderRadius.circular(ArRadii.control),
      ),
      child: const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

/// Data in formato italiano leggibile.
///
/// Il mese in italiano viene da `intl`, che e' gia' una dipendenza del progetto:
/// la tabella dei mesi scritta a mano era una seconda copia di un dato che il
/// pacchetto sa gia' tradurre, e restava indietro se qualcuno non si ricordava
/// di aggiornarla. Il formato e' costruito una volta sola e tenuto in campo:
/// `DateFormat` non e' banale da costruire e questa funzione gira a ogni build.
final DateFormat _memberSinceFormat = _italianDateFormat();

DateFormat _italianDateFormat() {
  // Senza questa inizializzazione `intl` conosce solo l'inglese e chiama DateFormat
  // con una locale non caricata solleva: va fatta una volta sola, non a ogni build.
  initializeDateFormatting('it');
  return DateFormat('d MMMM y', 'it');
}

/// Data di iscrizione in chiaro, per il banner del profilo.
String _memberSince(DateTime date) => _memberSinceFormat.format(date);

/// Banner del profilo.
///
/// E' il pezzo che rende la schermata una pagina utente: il nome grande, la bio
/// e la data di iscrizione ci stanno sopra tutto il resto, e non accanto ai
/// campi di modifica come era prima.
class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.profile,
    required this.onEditAvatar,
    this.busy = false,
  });

  final UserProfile profile;

  /// Cambia la foto profilo.
  final VoidCallback onEditAvatar;

  /// Vero mentre la foto scelta sta venendo caricata.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        // Gradiente tenue e non il brand: il banner e' una superficie grande,
        // e il gradiente di firma su un'area cosi' estesa diventa una macchia
        // di colore che compete con l'avatar, che e' il punto focale.
        gradient: ArColors.subtle,
        borderRadius: BorderRadius.circular(ArRadii.card),
        border: Border.all(color: ArColors.border),
        boxShadow: ArShadows.card,
      ),
      child: Padding(
        padding: const EdgeInsets.all(ArSpace.lg),
        child: Column(
          children: [
            // L'avatar e il bottone di modifica stanno nello stesso `Stack`:
            // il bottone deve cadere sull'angolo della foto, non accanto, cosi'
            // si capisce che agisce proprio su quella.
            Stack(
              clipBehavior: Clip.none,
              children: [
                ProfileAvatar(
                  url: profile.avatarUrl,
                  fallbackText: profile.initial,
                  size: 104,
                ),
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: _AvatarEditButton(busy: busy, onPressed: onEditAvatar),
                ),
              ],
            ),
            const SizedBox(height: ArSpace.md),
            Text(
              profile.username,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            if (profile.hasBio) ...[
              const SizedBox(height: ArSpace.sm),
              Text(
                profile.bio!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: ArSpace.md),
            // Pastiglia invece del testo grigio: la data di iscrizione e' un
            // dato, e un dato dentro una pastiglia si legge come una scheda
            // piuttosto che come una frase da leggere. Non e' [ArChip] perche'
            // quello e' selezionabile e qui non c'e' nulla da selezionare.
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: ArSpace.sm,
                vertical: ArSpace.xs,
              ),
              decoration: BoxDecoration(
                color: ArColors.containerLow,
                borderRadius: BorderRadius.circular(ArRadii.chip),
                border: Border.all(color: ArColors.borderSoft),
              ),
              child: Text(
                'Membro dal ${_memberSince(profile.createdAt)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottone che cambia la foto profilo.
///
/// Sta appoggiato sull'angolo dell'avatar: e' li' che l'utente cerca la foto da
/// modificare, e un'azione secondaria dentro il form dei campi sembrerebbe un
/// salvataggio del nome. Durante il caricamento mostra un indicatore al posto
/// dell'icona, cosi' si vede che il tap e' partito.
class _AvatarEditButton extends StatelessWidget {
  const _AvatarEditButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Cambia foto profilo',
      child: Material(
        color: ArColors.containerHighest,
        shape: CircleBorder(side: BorderSide(color: ArColors.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onPressed,
          child: SizedBox.square(
            dimension: 36,
            child: Center(
              child: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(
                      Icons.photo_camera_outlined,
                      size: 18,
                      color: ArColors.textHigh,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Riga di impostazione.
///
/// Icona, etichetta, valore corrente e freccia: e' la riga che si sa riconoscere
/// perche' e' la stessa in tutto il resto dell'app.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
  });

  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // L'icona prende la tinta della sezione: nel profilo e' il viola chiaro
    // dell'account. Fuori da una shell resta il viola del marchio, che e' quello
    // di prima.
    final tint = SectionAccentScope.of(context).base;

    return ArPressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ArSpace.md,
          vertical: ArSpace.sm,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: tint),
            const SizedBox(width: ArSpace.md),
            Expanded(
              child: Text(label, style: theme.textTheme.titleMedium),
            ),
            if (value != null)
              Flexible(
                child: Text(
                  value!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(width: ArSpace.sm),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: context.colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// Statistiche personali del profilo.
///
/// Il quadro di tutto quello che l'utente ha guardato e votato — non di un
/// gruppo solo — preso da `personal_overview`, che conta una volta sola un'opera
/// presente in piu' liste. Si caricano a parte dal resto del profilo: un errore
/// qui non deve impedire di cambiare nome o bio.
class _StatsSection extends ConsumerWidget {
  const _StatsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(personalOverviewProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          title: 'Le tue statistiche',
          subtitle: 'Tutto quello che hai guardato e votato, in ogni gruppo.',
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: ArSpace.sm),
        DecoratedBox(
          decoration: BoxDecoration(
            color: ArColors.containerLow,
            borderRadius: BorderRadius.circular(ArRadii.card),
            border: Border.all(color: ArColors.borderSoft),
          ),
          child: Padding(
            padding: const EdgeInsets.all(ArSpace.md),
            child: overview.when(
              loading: () => const _OverviewSkeleton(),
              error: (_, _) => _OverviewError(
                onRetry: () => ref.invalidate(personalOverviewProvider),
              ),
              data: (totals) => _OverviewGrid(totals: totals),
            ),
          ),
        ),
      ],
    );
  }
}

/// Le cifre, in una griglia che va a capo da sola.
///
/// `Wrap` e non `Row`: su un telefono stretto le voci scendono su piu' righe
/// invece di stringersi fino a diventare illeggibili.
class _OverviewGrid extends StatelessWidget {
  const _OverviewGrid({required this.totals});

  final WatchlistTotals totals;

  @override
  Widget build(BuildContext context) {
    final genre = totals.topGenre;
    final studio = totals.topStudio;

    return Wrap(
      spacing: ArSpace.lg,
      runSpacing: ArSpace.md,
      children: [
        _OverviewStat(label: 'In watchlist', value: _thousands(totals.entries)),
        _OverviewStat(label: 'In visione', value: _thousands(totals.watching)),
        _OverviewStat(label: 'Completati', value: _thousands(totals.completed)),
        _OverviewStat(label: 'Episodi', value: _thousands(totals.episodes)),
        _OverviewStat(label: 'Ore stimate', value: _formatHours(totals.hours)),
        _OverviewStat(label: 'Voti', value: _thousands(totals.rated)),
        _OverviewStat(label: 'Voto medio', value: _score(totals.meanScore)),
        if (genre != null && genre.isNotEmpty)
          _OverviewStat(label: 'Genere top', value: genre),
        if (studio != null && studio.isNotEmpty)
          _OverviewStat(label: 'Studio top', value: studio),
      ],
    );
  }
}

/// Una cifra con la sua etichetta.
class _OverviewStat extends StatelessWidget {
  const _OverviewStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 104,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: ArColors.textHigh,
              fontVariations: const [FontVariation('wght', 700)],
            ),
          ),
          const SizedBox(height: ArSpace.xxs),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: ArColors.textLow,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewSkeleton extends StatelessWidget {
  const _OverviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: ArSpace.lg,
      runSpacing: ArSpace.md,
      children: const [
        SkeletonBox(width: 104, height: 40, radius: ArRadii.chip),
        SkeletonBox(width: 104, height: 40, radius: ArRadii.chip),
        SkeletonBox(width: 104, height: 40, radius: ArRadii.chip),
      ],
    );
  }
}

class _OverviewError extends StatelessWidget {
  const _OverviewError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        const Icon(Icons.cloud_off_rounded, size: 20, color: ArColors.textLow),
        const SizedBox(width: ArSpace.sm),
        Expanded(
          child: Text(
            'Statistiche non disponibili.',
            style: theme.textTheme.bodySmall?.copyWith(color: ArColors.textLow),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Riprova')),
      ],
    );
  }
}

/// Separatore delle migliaia col punto, come nella striscia della watchlist.
String _thousands(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Ore stimate: un decimale sotto le cento, zero sopra. La virgola e' quella
/// italiana, coerente col resto della pagina.
String _formatHours(double hours) {
  final rounded = hours < 100 ? hours.toStringAsFixed(1) : hours.toStringAsFixed(0);
  return rounded.replaceAll('.', ',');
}

/// Voto medio su 1-10, con un decimale. Trattino quando non c'e' nessun voto:
/// uno "0,0" sembrerebbe un giudizio, non un'assenza.
String _score(double score) =>
    score <= 0 ? '—' : score.toStringAsFixed(1).replaceAll('.', ',');