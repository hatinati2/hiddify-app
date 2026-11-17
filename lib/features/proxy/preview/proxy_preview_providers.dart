import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// True while a profile is running in the desktop-only, proxy-only preview engine.
/// The connection repository uses this to keep preview separate from a real VPN session.
final proxyPreviewActiveProvider = StateProvider<bool>((ref) => false);
final proxyPreviewStartingProvider = StateProvider<bool>((ref) => false);
final proxyPreviewErrorProvider = StateProvider<String?>((ref) => null);

/// A server chosen during preview; applied after the matching profile connects normally.
typedef ProxyPreviewSelection = ({String profileId, String groupTag, String outboundTag});

final proxyPreviewSelectionProvider = StateProvider<ProxyPreviewSelection?>((ref) => null);

final proxyPreviewGroupProvider = StreamProvider<OutboundGroup?>((ref) {
  // The managed desktop core can switch from the foreground library to its isolated engine.
  ref.watch(coreRestartSignalProvider);
  if (!ref.watch(proxyPreviewActiveProvider)) return Stream.value(null);
  return ref.watch(hiddifyCoreServiceProvider).watchGroup();
});
