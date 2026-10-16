/*
 * flutter_bootstrap.js — avvio personalizzato dell'app web
 * ============================================================================
 *
 * Perche' esiste questo file
 * --------------------------
 * Flutter genera da solo un `flutter_bootstrap.js`, ma quello di default
 * registra anche `flutter_service_worker.js`: un service worker che Flutter ha
 * ormai DEPRECATO (il file generato non fa che disiscriversi e ricaricare le
 * pagine). Il problema e' che gira sullo stesso scope del nostro `sw.js`, e due
 * service worker sullo stesso scope sono lo stesso worker: si sovrascrivono a
 * vicenda e quello di Flutter finirebbe per cancellare anche il nostro.
 *
 * Qui si tiene solo la parte che serve — caricare Flutter — e si lascia la
 * registrazione del service worker a `index.html`, che registra `sw.js`.
 *
 * I segnaposto `{{...}}` li sostituisce Flutter durante `flutter build web`:
 * non vanno toccati.
 * ============================================================================
 */

{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load();
