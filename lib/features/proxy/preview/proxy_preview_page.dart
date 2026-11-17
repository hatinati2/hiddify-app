import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/features/proxy/preview/proxy_preview_controller.dart';
import 'package:hiddify/features/proxy/preview/proxy_preview_providers.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProxyPreviewPage extends ConsumerStatefulWidget {
  const ProxyPreviewPage({super.key, required this.profileId});

  final String profileId;

  @override
  ConsumerState<ProxyPreviewPage> createState() => _ProxyPreviewPageState();
}

class _ProxyPreviewPageState extends ConsumerState<ProxyPreviewPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(proxyPreviewControllerProvider).start(widget.profileId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final group = ref.watch(proxyPreviewGroupProvider);
    final starting = ref.watch(proxyPreviewStartingProvider);
    final active = ref.watch(proxyPreviewActiveProvider);
    final error = ref.watch(proxyPreviewErrorProvider);
    final selection = ref.watch(proxyPreviewSelectionProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.pages.proxyPreview.title),
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: [
          TextButton(
            onPressed: active
                ? () async {
                    await ref.read(proxyPreviewControllerProvider).stop();
                    if (context.mounted && !ref.read(proxyPreviewActiveProvider)) context.pop();
                  }
                : null,
            child: Text(t.pages.proxyPreview.finish),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(t.pages.proxyPreview.safetyNote)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: Text(t.pages.proxyPreview.subtitle, style: theme.textTheme.bodyMedium)),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: active && !starting ? () => ref.read(proxyPreviewControllerProvider).testAll() : null,
                  icon: const Icon(Icons.speed_rounded),
                  label: Text(t.pages.proxyPreview.testAll),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(t.pages.proxyPreview.selectionHint, style: theme.textTheme.bodySmall),
            ),
          ),
          if (starting) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Material(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline_rounded, color: theme.colorScheme.onErrorContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(error, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                      ),
                      if (!active)
                        IconButton(
                          tooltip: t.pages.proxyPreview.retry,
                          onPressed: () => ref.read(proxyPreviewControllerProvider).start(widget.profileId),
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: group.when(
              loading: () => Center(
                child: starting
                    ? const CircularProgressIndicator()
                    : Text(t.pages.proxyPreview.loading),
              ),
              error: (_, _) => Center(child: Text(t.pages.proxies.loadFailed)),
              data: (value) {
                final proxies = value?.items
                        .where((proxy) => !proxy.isGroup && !proxy.tag.contains('§hide§'))
                        .toList() ??
                    <OutboundInfo>[];
                proxies.sort((a, b) {
                  final aValid = ConnectionConst.isValidDelay(a.urlTestDelay);
                  final bValid = ConnectionConst.isValidDelay(b.urlTestDelay);
                  if (aValid != bValid) return aValid ? -1 : 1;
                  if (!aValid) return a.tagDisplay.compareTo(b.tagDisplay);
                  return a.urlTestDelay.compareTo(b.urlTestDelay);
                });
                if (proxies.isEmpty) {
                  return Center(
                    child: Text(active ? t.pages.proxyPreview.noServers : t.pages.proxyPreview.loading),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  itemCount: proxies.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, index) {
                    final proxy = proxies[index];
                    final delay = proxy.urlTestDelay;
                    final reachable = ConnectionConst.isValidDelay(delay);
                    final testing = !reachable &&
                        (proxy.status == Status.CONNECTING ||
                            proxy.status == Status.REGISTERING ||
                            proxy.status == Status.SEARCHING ||
                            proxy.status == Status.RECONNECTING);
                    final label = reachable
                        ? t.pages.proxies.delay.result(delay: delay)
                        : testing
                        ? t.pages.proxyPreview.testing
                        : proxy.status == Status.FAILED || delay < 0
                        ? t.pages.proxyPreview.unavailable
                        : t.pages.proxyPreview.untested;
                    final selected = selection?.profileId == widget.profileId &&
                        selection?.outboundTag == proxy.tag;
                    final color = reachable
                        ? theme.colorScheme.primary
                        : proxy.status == Status.FAILED || delay < 0
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant;

                    return ListTile(
                      selected: selected,
                      onTap: reachable && active && !starting
                          ? () {
                              ref.read(proxyPreviewSelectionProvider.notifier).state = (
                                profileId: widget.profileId,
                                groupTag: value!.tag,
                                outboundTag: proxy.tag,
                              );
                            }
                          : null,
                      title: Text(proxy.tagDisplay.isEmpty ? proxy.name : proxy.tagDisplay),
                      subtitle: Text(proxy.typeWithoutStatus, maxLines: 1, overflow: TextOverflow.ellipsis),
                      leading: Icon(
                        reachable
                            ? Icons.check_circle_outline_rounded
                            : testing
                            ? Icons.sync_rounded
                            : proxy.status == Status.FAILED || delay < 0
                            ? Icons.cancel_outlined
                            : Icons.radio_button_unchecked,
                        color: color,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (selected) ...[
                            Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary, size: 20),
                            const SizedBox(width: 6),
                          ],
                          Text(label, style: theme.textTheme.labelLarge?.copyWith(color: color)),
                          IconButton(
                            tooltip: t.pages.proxies.testDelay,
                            onPressed: active && !starting ? () => ref.read(proxyPreviewControllerProvider).testOne(proxy.tag) : null,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
