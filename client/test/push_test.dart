import 'package:animerank/core/router/app_router.dart';
import 'package:animerank/features/auth/presentation/auth_controller.dart';
import 'package:animerank/features/notifications/data/device_token_repository.dart';
import 'package:animerank/features/notifications/data/push_messaging.dart';
import 'package:animerank/features/notifications/presentation/push_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers/fake_auth.dart';
import 'helpers/fake_push.dart';

/// Registro dei token: segna le chiamate invece di parlare con Supabase.
class FakeDeviceTokenRepository implements DeviceTokenRepository {
  final List<String> registered = [];
  final List<String> removed = [];
  String? lastPlatform;

  @override
  Future<void> register({
    required String token,
    required String platform,
  }) async {
    registered.add(token);
    lastPlatform = platform;
  }

  @override
  Future<void> remove({required String token}) async {
    removed.add(token);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Lascia girare i microtask delle operazioni asincrone del controller.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  /// Un container con i soli pezzi che servono al push.
  ProviderContainer containerWith({
    required FakePushMessaging messaging,
    required FakeDeviceTokenRepository tokens,
    required FakeAuthRepository auth,
    GoRouter? router,
  }) {
    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        pushMessagingProvider.overrideWithValue(messaging),
        deviceTokenRepositoryProvider.overrideWithValue(tokens),
        if (router != null) appRouterProvider.overrideWithValue(router),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('al primo accesso registra il token del dispositivo', () async {
    final messaging = FakePushMessaging();
    final tokens = FakeDeviceTokenRepository();
    final auth = FakeAuthRepository(session: buildSession());
    addTearDown(messaging.dispose);
    addTearDown(auth.dispose);

    containerWith(messaging: messaging, tokens: tokens, auth: auth)
        .read(pushControllerProvider);
    await settle();

    expect(tokens.registered, ['token-di-prova']);
    expect(tokens.lastPlatform, 'android');
    expect(tokens.removed, isEmpty);
  });

  test('senza il permesso non registra niente', () async {
    final messaging = FakePushMessaging(granted: false);
    final tokens = FakeDeviceTokenRepository();
    final auth = FakeAuthRepository(session: buildSession());
    addTearDown(messaging.dispose);
    addTearDown(auth.dispose);

    containerWith(messaging: messaging, tokens: tokens, auth: auth)
        .read(pushControllerProvider);
    await settle();

    expect(tokens.registered, isEmpty);
    expect(messaging.permissionRequests, 1);
  });

  test('al logout rimuove il token', () async {
    final messaging = FakePushMessaging();
    final tokens = FakeDeviceTokenRepository();
    final auth = FakeAuthRepository(session: buildSession());
    addTearDown(messaging.dispose);
    addTearDown(auth.dispose);

    containerWith(messaging: messaging, tokens: tokens, auth: auth)
        .read(pushControllerProvider);
    await settle();
    expect(tokens.registered, isNotEmpty);

    auth.emit(null);
    await settle();

    expect(tokens.removed, ['token-di-prova']);
  });

  test('il rinnovo del token viene riscritto', () async {
    final messaging = FakePushMessaging();
    final tokens = FakeDeviceTokenRepository();
    final auth = FakeAuthRepository(session: buildSession());
    addTearDown(messaging.dispose);
    addTearDown(auth.dispose);

    containerWith(messaging: messaging, tokens: tokens, auth: auth)
        .read(pushControllerProvider);
    await settle();

    messaging.emitTokenRefresh('token-nuovo');
    await settle();

    expect(tokens.registered, ['token-di-prova', 'token-nuovo']);
  });

  test('il tocco su un consiglio apre la watchlist del gruppo', () async {
    final messaging = FakePushMessaging();
    final tokens = FakeDeviceTokenRepository();
    final auth = FakeAuthRepository(session: buildSession());
    addTearDown(messaging.dispose);
    addTearDown(auth.dispose);

    final router = GoRouter(
      initialLocation: '/altro',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const SizedBox()),
        GoRoute(path: '/altro', builder: (_, _) => const SizedBox()),
        GoRoute(
          path: '/watchlist/:groupId',
          builder: (_, _) => const SizedBox(),
        ),
      ],
    );
    addTearDown(router.dispose);

    containerWith(messaging: messaging, tokens: tokens, auth: auth, router: router)
        .read(pushControllerProvider);
    await settle();

    messaging.emitOpened(
      const PushMessage(
        title: 'Consiglio',
        body: '',
        data: {'group_id': 'g-1'},
      ),
    );
    await settle();

    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/watchlist/g-1',
    );
  });

  test('un consiglio senza gruppo porta alla home', () async {
    final messaging = FakePushMessaging();
    final tokens = FakeDeviceTokenRepository();
    final auth = FakeAuthRepository(session: buildSession());
    addTearDown(messaging.dispose);
    addTearDown(auth.dispose);

    final router = GoRouter(
      initialLocation: '/altro',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const SizedBox()),
        GoRoute(path: '/altro', builder: (_, _) => const SizedBox()),
      ],
    );
    addTearDown(router.dispose);

    containerWith(messaging: messaging, tokens: tokens, auth: auth, router: router)
        .read(pushControllerProvider);
    await settle();

    messaging.emitOpened(const PushMessage(title: 'x', body: '', data: {}));
    await settle();

    expect(router.routeInformationProvider.value.uri.toString(), '/');
  });
}
