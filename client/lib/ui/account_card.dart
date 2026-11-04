import 'package:flutter/material.dart';
import '../core/document.dart';
import 'design.dart';

/// Used by both header and row so each table column has the same boundaries.
class AccountColumns extends StatelessWidget {
  final Widget identity, code, remaining, copy, menu;
  const AccountColumns({
    super.key,
    required this.identity,
    required this.code,
    required this.remaining,
    required this.copy,
    required this.menu,
  });
  static bool fits(BuildContext context, double width) =>
      width >= 620 && MediaQuery.textScalerOf(context).scale(16) <= 22;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(flex: 4, child: identity),
      const SizedBox(width: 16),
      Expanded(flex: 3, child: code),
      const SizedBox(width: 16),
      SizedBox(width: 64, child: remaining),
      const SizedBox(width: 16),
      SizedBox(width: 112, child: copy),
      const SizedBox(width: 4),
      SizedBox(width: 48, child: menu),
    ],
  );
}

class AccountCard extends StatelessWidget {
  final RecordView entry;
  final ValueNotifier<int> now;
  final bool copied;
  final VoidCallback onCopy, onFavorite, onConflict;
  final ValueChanged<String> onAction;
  final String Function(String, String) t;
  const AccountCard({
    super.key,
    required this.entry,
    required this.now,
    required this.copied,
    required this.onCopy,
    required this.onFavorite,
    required this.onConflict,
    required this.onAction,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme, otp = entry.otp;
    final favorite = entry.fields['favorite'] == true;
    final identity = Row(
      children: [
        ServiceAvatar(issuer: otp.issuer),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      otp.issuer,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (favorite)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Semantics(
                        label: t('已收藏', 'Favorite'),
                        child: Icon(
                          Icons.star_rounded,
                          color: cs.primary,
                          size: 20,
                        ),
                      ),
                    ),
                ],
              ),
              if (otp.account.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  otp.account,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    Widget menu(bool horizontal) => PopupMenuButton<String>(
      tooltip: t('更多操作', 'More actions'),
      icon: Icon(horizontal ? Icons.more_horiz : Icons.more_vert, size: 20),
      onSelected: (value) =>
          value == 'favorite' ? onFavorite() : onAction(value),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'favorite',
          child: Text(
            favorite
                ? t('取消收藏', 'Remove favorite')
                : t('收藏账号', 'Add to favorites'),
          ),
        ),
        PopupMenuItem(
          value: 'edit',
          child: Text(t('账号详情 / 编辑', 'Details / edit')),
        ),
        if (entry.conflicts.isNotEmpty)
          PopupMenuItem(
            value: 'resolve',
            child: Text(t('解决冲突', 'Resolve conflict')),
          ),
        PopupMenuItem(
          value: 'migrate',
          child: Text(t('迁移账号', 'Transfer account')),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Text(
            t('删除账号', 'Delete account'),
            style: TextStyle(color: cs.error),
          ),
        ),
      ],
    );
    Widget copyButton(bool compact) => Semantics(
      liveRegion: copied,
      child: OutlinedButton.icon(
        key: ValueKey('copy-button-${entry.id}'),
        onPressed: onCopy,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 12,
            vertical: 10,
          ),
          backgroundColor: copied ? cs.primaryContainer : cs.surface,
          foregroundColor: copied ? cs.primary : cs.onSurface,
          overlayColor: cs.primary.withValues(alpha: .04),
          side: BorderSide(
            color: copied ? Colors.transparent : cs.outlineVariant,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: compact ? 12 : 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        icon: Icon(
          copied ? Icons.check_rounded : Icons.copy_outlined,
          size: 19,
        ),
        label: Text(copied ? t('已复制', 'Copied') : t('复制', 'Copy'), maxLines: 1),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = AccountColumns.fits(
          context,
          constraints.maxWidth - 32,
        );
        return AnimatedContainer(
          key: ValueKey('account-surface-${entry.id}'),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: copied && !horizontal
                ? Color.lerp(cs.surface, cs.primaryContainer, .65)
                : cs.surface,
            border: Border.all(
              color: copied && !horizontal
                  ? Color.lerp(cs.outlineVariant, cs.primary, .15)!
                  : cs.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: horizontal ? 22 : 18,
              ),
              child: ValueListenableBuilder<int>(
                valueListenable: now,
                builder: (context, seconds, _) {
                  final value = otp.codeAt(seconds),
                      split = otp.digits ~/ 2,
                      left = otp.remaining(seconds);
                  final warning =
                      Theme.of(context).extension<SixTickTokens>()?.warning ??
                      cs.error;
                  final code = Semantics(
                    label:
                        '${t('复制验证码', 'Copy code')} ${value.split('').join(' ')}',
                    button: true,
                    onTap: onCopy,
                    excludeSemantics: true,
                    child: InkWell(
                      key: ValueKey('copy-code-${entry.id}'),
                      onTap: onCopy,
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${value.substring(0, split)} ${value.substring(split)}',
                              style: TextStyle(
                                color: left <= 5 ? warning : cs.onSurface,
                                fontSize: horizontal ? 36 : 32,
                                fontFamily: 'monospace',
                                height: 1.25,
                                fontWeight: FontWeight.w600,
                                letterSpacing: .3,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                  final timer = ExcludeSemantics(
                    child: SizedBox.square(
                      dimension: 44,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox.square(
                            dimension: 42,
                            child: CircularProgressIndicator(
                              value: left / otp.period,
                              strokeWidth: 3,
                              color: left <= 5 ? warning : cs.primary,
                              backgroundColor: cs.primary.withValues(alpha: .2),
                              strokeCap: StrokeCap.round,
                            ),
                          ),
                          Text(
                            '${left}s',
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: cs.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (horizontal)
                        AccountColumns(
                          identity: identity,
                          code: code,
                          remaining: Align(
                            alignment: Alignment.centerLeft,
                            child: timer,
                          ),
                          copy: copyButton(false),
                          menu: menu(true),
                        )
                      else ...[
                        Row(
                          children: [
                            Expanded(child: identity),
                            menu(false),
                          ],
                        ),
                        const SizedBox(height: 24),
                        if (MediaQuery.textScalerOf(context).scale(16) <= 24)
                          Row(
                            children: [
                              Expanded(child: code),
                              const SizedBox(width: 8),
                              timer,
                              const SizedBox(width: 10),
                              copyButton(true),
                            ],
                          )
                        else ...[
                          code,
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              timer,
                              const Spacer(),
                              Flexible(child: copyButton(true)),
                            ],
                          ),
                        ],
                      ],
                      if (left <= 5)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            t('即将更新', 'Refreshing soon'),
                            style: TextStyle(fontSize: 12, color: warning),
                          ),
                        ),
                      if (entry.conflicts.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: onConflict,
                          icon: const Icon(Icons.warning_amber_rounded),
                          label: Text(t('处理同步冲突', 'Resolve sync conflict')),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
