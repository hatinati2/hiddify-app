import 'dart:async';

import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/settings/data/config_option_data_providers.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// True while a profile is running in the desktop-only, proxy-only preview engine.
/// The connection repository uses this to keep preview separate from a real VPN session.
final proxyPreviewActiveProvider = StateProvider<bool>((ref) => false);
final proxyPreviewStartingProvider = StateProvider<bool>((ref) => false);
final proxyPreviewErrorProvider = StateProvider<String?>((ref) => null);

final proxyPreviewGroupProvider = StreamProvider<OutboundGroup?>((ref) {
  if (!ref.watch(proxyPreviewActiveProvider)) return Stream.value(null);
  return ref.watch(hiddifyCoreServiceProvider).watchGroup();
});

final proxyPreviewControllerProvider = Provider<ProxyPreviewController>((ref) {
  return ProxyPreviewController(ref);
});

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
    ref.read(proxyPreviewErrorProvider.notifier).state = null;
    ref.read(proxyPreviewStartingProvider.notifier).state = true;

    final core = ref.read(hiddifyCoreServiceProvider);
    try {
      if (!PlatformUtils.isWindows && !PlatformUtils.isLinux) {
        throw UnsupportedError('Server preview is currently available on Windows and Linux desktop.');
      }

      final setup = await core.setup().run();
      setup.match((error) => throw StateError(error), (_) {});

      // Never take over a connection the user already has running.
      if (core.currentState is! CoreStopped) {
        throw StateError('Disconnect the current connection before testing this profile.');
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
      try {
        await testAll();
      } catch (error) {
        ref.read(proxyPreviewErrorProvider.notifier).state = error.toString();
      }
    } catch (error) {
      ref.read(proxyPreviewErrorProvider.notifier).state = error.toString();
      await _stopAndRestore();
    } finally {
      ref.read(proxyPreviewStartingProvider.notifier).state = false;
    }
  }

  Future<void> testAll() async {
    if (!ref.read(proxyPreviewActiveProvider)) return;
    final result = await ref.read(hiddifyCoreServiceProvider).urlTest('select').run();
    result.match((error) => throw StateError(error), (_) {});
  }

  Future<void> testOne(String tag) async {
    if (!ref.read(proxyPreviewActiveProvider)) return;
    final result = await ref.read(hiddifyCoreServiceProvider).urlTest(tag).run();
    result.match((error) => throw StateError(error), (_) {});
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
        ref.read(proxyPreviewErrorProvider.notifier).state = 'Could not stop the preview engine: $stopError';
        return;
      }
    }

    final original = _originalOptions;
    if (original != null) {
      final restored = await core.changeOptions(original).run();
      final restoreError = restored.match((error) => error, (_) => null);
      if (restoreError != null) {
        ref.read(proxyPreviewErrorProvider.notifier).state =
            'The preview stopped, but the previous settings could not be restored: $restoreError';
        return;
      }
      _originalOptions = null;
    }

    ref.read(proxyPreviewActiveProvider.notifier).state = false;
  }
}
