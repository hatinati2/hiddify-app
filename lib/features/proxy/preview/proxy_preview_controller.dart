import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/proxy/preview/proxy_preview_providers.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/features/settings/data/config_option_data_providers.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:meta/meta.dart';

/// A copy of the profile's effective options that can test outbounds without changing
/// the operating system's routing, tunnel, or proxy settings.
@visibleForTesting
SingboxConfigOption proxyPreviewOptions(SingboxConfigOption options) => options.copyWith(
  enableTun: false,
  routerMode: false,
  setSystemProxy: false,
  enableMixedPort: false,
  enableTproxyPort: false,
  enableDirectPort: false,
  enableRedirectPort: false,
  enableClashApi: false,
  allowConnectionFromLan: false,
  localProxyAuth: false,
  localProxyInVpn: false,
);

final proxyPreviewControllerProvider = Provider<ProxyPreviewController>((ref) => ProxyPreviewController(ref));

class ProxyPreviewController {
  ProxyPreviewController(this.ref);

  final Ref ref;
  Future<void>? _startFuture;
  SingboxConfigOption? _originalOptions;
  bool _stopping = false;

  Future<void> start(String profileId) async {
    final pending = _startFuture;
    if (pending != null) return pending;
    if (ref.read(proxyPreviewActiveProvider)) return;

    final task = _start(profileId);
    _startFuture = task;
    try {
      await task;
    } finally {
      if (identical(_startFuture, task)) _startFuture = null;
    }
  }

  Future<void> _start(String profileId) async {
    ref.read(proxyPreviewSelectionProvider.notifier).state = null;
    ref.read(proxyPreviewErrorProvider.notifier).state = null;
    ref.read(proxyPreviewStartingProvider.notifier).state = true;

    final core = ref.read(hiddifyCoreServiceProvider);
    try {
      final t = await ref.read(translationsProvider.future);
      if (!PlatformUtils.isWindows && !PlatformUtils.isLinux) {
        ref.read(proxyPreviewErrorProvider.notifier).state = t.pages.proxyPreview.desktopOnly;
        return;
      }

      final setup = await core.setup().run();
      setup.match((error) => throw StateError(error), (_) {});

      // Never take over a connection the user already has running.
      if (core.currentState is! CoreStopped) {
        ref.read(proxyPreviewErrorProvider.notifier).state = t.pages.proxyPreview.disconnectFirst;
        return;
      }

      final profiles = await ref.read(profileRepositoryProvider.future);
      final profileResult = await profiles.getById(profileId).run();
      final profile = profileResult.getOrElse((error) => throw error);
      if (profile == null) throw StateError('This profile no longer exists.');

      final paths = ref.read(profilePathResolverProvider);
      final configFile = paths.file(profile.id);
      if (!await configFile.exists() && profile is RemoteProfileEntity) {
        final update = await profiles.upsertRemote(profile.url).run();
        update.match((error) => throw error, (_) {});
      }
      if (!await configFile.exists()) {
        throw StateError('The configuration file for this profile is missing. Update the profile and try again.');
      }

      final optionsResult = ref
          .read(configOptionRepositoryProvider)
          .fullOptionsOverrided(profile.profileOverride());
      final original = optionsResult.getOrElse((error) => throw error);
      _originalOptions = original;

      // Set this before starting the engine so its STARTED status is never presented as a VPN connection.
      ref.read(proxyPreviewActiveProvider.notifier).state = true;

      final changed = await core.changeOptions(proxyPreviewOptions(original)).run();
      changed.match((error) => throw StateError(error), (_) {});

      final started = await core
          .start(configFile.path, profile.name, ref.read(Preferences.disableMemoryLimit))
          .run();
      started.match((error) => throw error, (_) {});

      // Start with a full scan, as v2rayNG does; the stream updates each row as results arrive.
      await testAll();
    } catch (error) {
      final message = (await ref.read(translationsProvider.future)).pages.proxyPreview.startFailed;
      ref.read(proxyPreviewErrorProvider.notifier).state = message;
      await _stopAndRestore();
    } finally {
      ref.read(proxyPreviewStartingProvider.notifier).state = false;
    }
  }

  Future<void> testAll() async {
    if (!ref.read(proxyPreviewActiveProvider)) return;
    try {
      final result = await ref.read(hiddifyCoreServiceProvider).urlTest('select').run();
      result.match((error) => throw StateError(error), (_) {});
    } catch (_) {
      ref.read(proxyPreviewErrorProvider.notifier).state =
          (await ref.read(translationsProvider.future)).pages.proxyPreview.testFailed;
    }
  }

  Future<void> testOne(String tag) async {
    if (!ref.read(proxyPreviewActiveProvider)) return;
    try {
      final result = await ref.read(hiddifyCoreServiceProvider).urlTest(tag).run();
      result.match((error) => throw StateError(error), (_) {});
    } catch (_) {
      ref.read(proxyPreviewErrorProvider.notifier).state =
          (await ref.read(translationsProvider.future)).pages.proxyPreview.testFailed;
    }
  }

  /// Stops the temporary engine and restores the user's normal options before leaving the page.
  /// The preview flag stays set if teardown fails, preventing a real connect from racing it.
  Future<void> stop() async {
    final pending = _startFuture;
    if (pending != null) await pending;
    if (_stopping) return;
    if (!ref.read(proxyPreviewActiveProvider) && _originalOptions == null) return;

    _stopping = true;
    try {
      await _stopAndRestore();
    } finally {
      _stopping = false;
    }
  }

  Future<void> _stopAndRestore() async {
    final core = ref.read(hiddifyCoreServiceProvider);
    if (ref.read(proxyPreviewActiveProvider)) {
      final stopped = await core.stop().run();
      final stopError = stopped.match((error) => error, (_) => null);
      if (stopError != null) {
        ref.read(proxyPreviewErrorProvider.notifier).state =
            (await ref.read(translationsProvider.future)).pages.proxyPreview.stopFailed;
        return;
      }
    }

    final original = _originalOptions;
    if (original != null) {
      final restored = await core.changeOptions(original).run();
      final restoreError = restored.match((error) => error, (_) => null);
      if (restoreError != null) {
        ref.read(proxyPreviewErrorProvider.notifier).state =
            (await ref.read(translationsProvider.future)).pages.proxyPreview.restoreFailed;
        return;
      }
      _originalOptions = null;
    }

    ref.read(proxyPreviewActiveProvider.notifier).state = false;
  }
}
