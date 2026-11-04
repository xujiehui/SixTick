import 'dart:async';
import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/document.dart';
import '../services/controller.dart';
import 'add_account.dart';
import 'cloud_page.dart';
import 'common.dart';
import 'design.dart';
import 'account_card.dart';
import 'account_order.dart';
import 'security_page.dart';

class HomeScreen extends StatefulWidget {
  final AppController app;
  final int initialPage;

  /// Optional clock for deterministic rendering and rollover tests.
  final int Function()? epochSeconds;
  const HomeScreen({
    super.key,
    required this.app,
    this.initialPage = 0,
    this.epochSeconds,
  });
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final search = TextEditingController(),
      searchFocus = FocusNode(),
      listFocus = FocusNode();
  late final ValueNotifier<int> now;
  int get currentSeconds =>
      widget.epochSeconds?.call() ??
      DateTime.now().millisecondsSinceEpoch ~/ 1000;
  Timer? clock, copiedTimer;
  String? copiedId;
  bool keyboardSelection = false;
  final entryKeys = <String, GlobalKey>{};
  int page = 0, selected = 0;
  String filter = 'all';
  AppController get app => widget.app;
  String t(String zh, String en) => tr(app, zh, en);
  @override
  void initState() {
    super.initState();
    page = widget.initialPage;
    now = ValueNotifier<int>(currentSeconds);
    clock = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => now.value = currentSeconds,
    );
    search.addListener(() {
      if (mounted) setState(() => selected = 0);
    });
  }

  @override
  void dispose() {
    clock?.cancel();
    copiedTimer?.cancel();
    now.dispose();
    search.dispose();
    searchFocus.dispose();
    listFocus.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, app, e);
    }
  }

  List<RecordView> get visible {
    final query = search.text.trim().toLowerCase();
    return ordered.where((entry) {
      final otp = entry.otp;
      return (activeFilter == 'all' ||
              activeFilter == 'favorites' && entry.fields['favorite'] == true ||
              entry.fields['group'] == activeFilter) &&
          '${otp.issuer} ${otp.account}'.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> copy(RecordView entry) async {
    if (app.locked || app.privacyHidden) return;
    final code = entry.otp.codeAt(currentSeconds);
    final clear = app.settings['clearClipboard'] == true;
    if (Platform.isAndroid || Platform.isIOS) {
      await const MethodChannel(
        'six_tick/privacy',
      ).invokeMethod('copyCode', {'code': code, 'clear': clear});
    } else {
      await Clipboard.setData(ClipboardData(text: code));
      if (clear) {
        Timer(const Duration(seconds: 30), () async {
          try {
            if ((await Clipboard.getData(Clipboard.kTextPlain))?.text == code) {
              await Clipboard.setData(const ClipboardData(text: ''));
            }
          } catch (_) {
            /* OS clipboard may be unavailable in a background process. */
          }
        });
      }
    }
    if (mounted && !app.locked) {
      copiedTimer?.cancel();
      setState(() => copiedId = entry.id);
      copiedTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => copiedId = null);
      });
    }
  }

  Future<void> edit(RecordView entry) async {
    final issuer = TextEditingController(text: entry.otp.issuer),
        account = TextEditingController(text: entry.otp.account);
    final groups = app.document!.groups;
    String? group = groups.any((g) => g.id == entry.fields['group'])
        ? entry.fields['group'] as String?
        : null;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, state) => AppDialog(
          title: Text(t('编辑账号', 'Edit account')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: issuer,
                  decoration: InputDecoration(
                    labelText: t('服务名称', 'Service name'),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: account,
                  decoration: InputDecoration(
                    labelText: t('账号标识', 'Account label'),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: group,
                  decoration: InputDecoration(labelText: t('分组', 'Group')),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(t('未分组', 'Ungrouped')),
                    ),
                    ...groups.map(
                      (g) => DropdownMenuItem(
                        value: g.id,
                        child: Text(g.fields['name'] as String),
                      ),
                    ),
                  ],
                  onChanged: (v) => state(() => group = v),
                ),
                const SizedBox(height: 16),
                Text(
                  t(
                    '密钥与生成参数无法直接修改。更换密钥请重新添加账号。',
                    'Secret and generation parameters are immutable. Add a new account to replace a secret.',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (issuer.text.trim().isNotEmpty) {
                  Navigator.pop(context, {
                    'issuer': issuer.text.trim(),
                    'account': account.text.trim(),
                    'group': group,
                  });
                }
              },
              child: Text(t('保存', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (result != null && !app.locked) await app.edit(entry, result);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    issuer.dispose();
    account.dispose();
  }

  Future<void> migrate(RecordView entry) async {
    if (!await reauthenticate(context, app) || !mounted) return;
    if (!await confirm(
          context,
          t('导出此账号密钥', 'Export this secret'),
          t(
            '获得二维码或密钥的人可以生成验证码。请仅在可信设备间迁移。',
            'Anyone with this QR code or secret can generate codes. Only transfer between trusted devices.',
          ),
          t('显示迁移二维码', 'Show transfer QR'),
        ) ||
        !mounted ||
        app.locked) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        title: Text(entry.otp.issuer),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ColoredBox(
                  color: Colors.white,
                  child: QrImageView(
                    data: entry.otp.toUri(),
                    size: 280,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  entry.otp.secret,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 12),
                Text(
                  t(
                    '退出页面后密钥会立即隐藏。',
                    'The secret is hidden when you leave this page.',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('完成', 'Done')),
          ),
        ],
      ),
    );
  }

  Future<void> resolve(RecordView record) async {
    for (final conflict in record.conflicts.entries) {
      if (!mounted || app.locked) return;
      final selected = await showDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(t('选择要保留的版本', 'Choose a version')),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(conflict.key),
            ),
            ...conflict.value.indexed.map(
              (item) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, item.$1),
                child: Text('${item.$2 ?? t('未分组', 'Ungrouped')}'),
              ),
            ),
          ],
        ),
      );
      if (selected == null) return;
      await app.edit(record, {conflict.key: conflict.value[selected]});
    }
  }

  Future<void> groupMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: Text(t('新建分组', 'New group')),
                onTap: () => Navigator.pop(context, 'new'),
              ),
              ...app.document!.groups.map(
                (g) => ListTile(
                  title: Text(g.fields['name'] as String),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => Navigator.pop(context, g.id),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted || app.locked) return;
    if (choice == 'new') {
      final name = await askText(
        context,
        t('新建分组', 'New group'),
        t('分组名称', 'Group name'),
        t('创建', 'Create'),
      );
      if (name != null && name.trim().isNotEmpty) await app.addGroup(name);
    } else {
      final group = app.document!.groups.firstWhere((g) => g.id == choice);
      final action = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(group.fields['name'] as String),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'rename'),
              child: Text(t('重命名', 'Rename')),
            ),
            if (group.conflicts.isNotEmpty)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, 'resolve'),
                child: Text(t('解决冲突', 'Resolve conflict')),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'delete'),
              child: Text(t('删除分组（保留账号）', 'Delete group (keep accounts)')),
            ),
          ],
        ),
      );
      if (!mounted || app.locked) return;
      if (action == 'rename') {
        final name = await askText(
          context,
          t('重命名分组', 'Rename group'),
          t('名称', 'Name'),
          t('保存', 'Save'),
          initial: group.fields['name'] as String,
        );
        if (name != null && name.trim().isNotEmpty) {
          await app.edit(group, {'name': name.trim()});
        }
      } else if (action == 'delete') {
        await app.delete(group);
        setState(() => filter = 'all');
      } else if (action == 'resolve') {
        await resolve(group);
      }
    }
  }

  Future<void> menu(RecordView entry, String action) async {
    if (action == 'edit') await edit(entry);
    if (action == 'migrate') await migrate(entry);
    if (action == 'resolve') await resolve(entry);
    if (!mounted || app.locked) return;
    if (action == 'delete' &&
        await confirm(
          context,
          t('删除账号？', 'Delete account?'),
          t(
            '此操作不会关闭对应网站的两步验证。首版无回收站，请确认已保留备份或其他登录方式。',
            'This does not disable two-step verification on the website. There is no trash. Keep a backup or another sign-in method.',
          ),
          t('删除账号', 'Delete account'),
          danger: true,
        )) {
      await app.delete(entry);
    }
  }

  Widget entryTile(RecordView entry, int index) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: AccountCard(
      key: entryKeys.putIfAbsent(entry.id, () => GlobalKey()),
      entry: entry,
      now: now,
      copied: copiedId == entry.id,
      t: t,
      onCopy: () {
        setState(() {
          selected = index;
          keyboardSelection = false;
        });
        listFocus.requestFocus();
        run(() => copy(entry));
      },
      onFavorite: () => run(
        () => app.edit(entry, {'favorite': entry.fields['favorite'] != true}),
      ),
      onConflict: () => run(() => resolve(entry)),
      onAction: (value) => run(() => menu(entry, value)),
    ),
  );

  Future<void> addAccount() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              MediaQuery.sizeOf(context).width < 600 ? 16 : 32,
              0,
              MediaQuery.sizeOf(context).width < 600 ? 16 : 32,
              24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  t('添加账号', 'Add account'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                if (Platform.isIOS || Platform.isAndroid)
                  ListTile(
                    leading: const Icon(Icons.qr_code_scanner),
                    title: Text(t('扫描二维码', 'Scan QR code')),
                    onTap: () => Navigator.pop(context, 'scan'),
                  ),
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: Text(t('导入二维码图片', 'Import QR image')),
                  onTap: () => Navigator.pop(context, 'image'),
                ),
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: Text(t('手动输入 / 链接', 'Secret / URI')),
                  onTap: () => Navigator.pop(context, 'manual'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || app.locked) return;
    if (action == 'manual') {
      await showDialog<void>(
        context: context,
        builder: (_) => AddAccountDialog(app: app),
      );
    } else if (action == 'image') {
      await importQr(context, app);
    } else if (action == 'scan') {
      await scanQr(context, app);
    }
  }

  String get sortMode => app.settings['accountSort'] as String? ?? 'custom';
  List<String> get savedOrder => (app.settings['accountOrder'] as List? ?? [])
      .whereType<String>()
      .toList();
  List<RecordView> get ordered =>
      orderAccounts(app.document!.entries, sortMode, savedOrder);
  String get activeFilter =>
      filter == 'all' ||
          filter == 'favorites' ||
          app.document!.groups.any((g) => g.id == filter)
      ? filter
      : 'all';
  void selectFilter(String value) => setState(() {
    page = 0;
    filter = value;
    selected = 0;
  });
  String get sortLabel => switch (sortMode) {
    'name' => t('名称排序', 'By name'),
    'favorites' => t('收藏优先', 'Favorites first'),
    _ => t('自定义排序', 'Custom order'),
  };

  Future<void> chooseSort(String mode) async {
    if (mode == 'custom') {
      final entries = orderAccounts(
        app.document!.entries,
        'custom',
        savedOrder,
      );
      final result = await showDialog<List<String>>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AppDialog(
            title: Text(t('自定义排序', 'Custom order')),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    t(
                      '拖动账号或使用箭头调整顺序，仅保存在这台设备。',
                      'Drag accounts or use the arrows to reorder. Saved on this device.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: MediaQuery.sizeOf(context).height * .4,
                    child: ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: entries.length,
                      onReorder: (oldIndex, newIndex) => update(() {
                        if (newIndex > oldIndex) newIndex--;
                        entries.insert(newIndex, entries.removeAt(oldIndex));
                      }),
                      itemBuilder: (context, index) => Padding(
                        key: ValueKey(entries[index].id),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            ReorderableDragStartListener(
                              index: index,
                              child: const Padding(
                                padding: EdgeInsets.all(12),
                                child: Icon(Icons.drag_handle),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                entries[index].otp.issuer,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              tooltip: t('上移', 'Move up'),
                              onPressed: index == 0
                                  ? null
                                  : () => update(
                                      () => entries.insert(
                                        index - 1,
                                        entries.removeAt(index),
                                      ),
                                    ),
                              icon: const Icon(Icons.arrow_upward, size: 20),
                            ),
                            IconButton(
                              tooltip: t('下移', 'Move down'),
                              onPressed: index == entries.length - 1
                                  ? null
                                  : () => update(
                                      () => entries.insert(
                                        index + 1,
                                        entries.removeAt(index),
                                      ),
                                    ),
                              icon: const Icon(Icons.arrow_downward, size: 20),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t('取消', 'Cancel')),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, entries.map((e) => e.id).toList()),
                child: Text(t('保存排序', 'Save order')),
              ),
            ],
          ),
        ),
      );
      if (result == null || app.locked) return;
      await app.preferences({'accountSort': 'custom', 'accountOrder': result});
    } else {
      await app.preferences({'accountSort': mode});
    }
    if (mounted && !app.locked) setState(() => selected = 0);
  }

  Widget sortControl({bool compact = false}) => PopupMenuButton<String>(
    tooltip: t('账号排序', 'Sort accounts'),
    onSelected: (value) => run(() => chooseSort(value)),
    itemBuilder: (_) => [
      for (final mode in ['custom', 'name', 'favorites'])
        CheckedPopupMenuItem(
          value: mode,
          checked: sortMode == mode,
          child: Text(switch (mode) {
            'custom' => t('自定义排序', 'Custom order'),
            'name' => t('名称排序', 'By name'),
            _ => t('收藏优先', 'Favorites first'),
          }),
        ),
    ],
    child: compact
        ? const SizedBox.square(
            dimension: 48,
            child: Icon(Icons.sort, size: 20),
          )
        : Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sort, size: 20),
                const SizedBox(width: 8),
                Text(sortLabel, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(width: 8),
                const Icon(Icons.expand_more, size: 18),
              ],
            ),
          ),
  );

  Widget filterChip(String id, String label, IconData icon) {
    final cs = Theme.of(context).colorScheme;
    final selected = activeFilter == id;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        avatar: Icon(
          icon,
          size: id == 'all' ? 10 : 18,
          color: selected ? cs.primary : cs.onSurface,
        ),
        labelStyle: TextStyle(
          fontSize: 13,
          color: selected ? cs.primary : cs.onSurface,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
        side: BorderSide.none,
        backgroundColor: Theme.of(context).brightness == Brightness.dark
            ? cs.surface
            : const Color(0xfff7fbff),
        onSelected: (_) => selectFilter(id),
      ),
    );
  }

  Widget emptyAccounts() {
    final emptyVault = app.document!.entries.isEmpty;
    final searching = search.text.trim().isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandMark(size: 64),
            const SizedBox(height: 24),
            Text(
              searching
                  ? t('没有找到匹配的账号', 'No matching accounts')
                  : emptyVault
                  ? t('添加你的第一个账号', 'Add your first account')
                  : activeFilter == 'favorites'
                  ? t('还没有收藏的账号', 'No favorites yet')
                  : t('这个分组还没有账号', 'No accounts in this group'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              searching
                  ? t('试试其他服务名或账号。', 'Try another service or account name.')
                  : emptyVault
                  ? t(
                      '从网站的两步验证设置中获取二维码或密钥。',
                      'Find the QR code or secret in your website’s two-step verification settings.',
                    )
                  : activeFilter == 'favorites'
                  ? t('在账号菜单中收藏常用账号。', 'Add favorites from an account’s menu.')
                  : t(
                      '在账号编辑中选择这个分组。',
                      'Choose this group when editing an account.',
                    ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (searching)
              OutlinedButton(
                onPressed: search.clear,
                child: Text(t('清除搜索', 'Clear search')),
              )
            else if (emptyVault)
              FilledButton.icon(
                onPressed: () => run(addAccount),
                icon: const Icon(Icons.add),
                label: Text(t('添加账号', 'Add account')),
              )
            else
              TextButton(
                onPressed: () => selectFilter('all'),
                child: Text(t('查看全部账号', 'View all accounts')),
              ),
          ],
        ),
      ),
    );
  }

  KeyEventResult accountKey(FocusNode _, KeyEvent event) {
    final entries = visible;
    if (!listFocus.hasPrimaryFocus ||
        event is! KeyDownEvent ||
        entries.isEmpty) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      keyboardSelection = true;
      setState(
        () => selected =
            (selected +
                    (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1))
                .clamp(0, entries.length - 1),
      );
      final id = entries[selected].id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final cardContext = entryKeys[id]?.currentContext;
        if (cardContext != null) {
          Scrollable.ensureVisible(
            cardContext,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          );
        }
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      run(() => copy(entries[selected.clamp(0, entries.length - 1)]));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget accounts(bool wide) {
    final entries = visible, cs = Theme.of(context).colorScheme;
    final padding = wide ? 32.0 : 16.0;
    final title = activeFilter == 'all'
        ? t('验证码', 'Codes')
        : activeFilter == 'favorites'
        ? t('收藏', 'Favorites')
        : app.document!.groups
                  .firstWhere((g) => g.id == activeFilter)
                  .fields['name']
              as String;
    return DropTarget(
      onDragDone: (details) {
        if (details.files.isNotEmpty) {
          run(() => importQr(context, app, file: details.files.first));
        }
      },
      child: Column(
        children: [
          Expanded(
            child: Focus(
              focusNode: listFocus,
              onFocusChange: (_) => setState(() {}),
              onKeyEvent: accountKey,
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(padding, 24, padding, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            title,
                                            style: wide
                                                ? Theme.of(
                                                    context,
                                                  ).textTheme.headlineLarge
                                                : Theme.of(
                                                    context,
                                                  ).textTheme.headlineSmall,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (!wide) ...[
                                          const SizedBox(width: 10),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: cs.primaryContainer,
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                            ),
                                            child: Text(
                                              '${entries.length}',
                                              style: const TextStyle(
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (wide) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        t(
                                          '${entries.length} 个账户',
                                          '${entries.length} accounts',
                                        ),
                                        style: TextStyle(
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              FilledButton.icon(
                                onPressed: () => run(addAccount),
                                icon: const Icon(Icons.add, size: 22),
                                style: FilledButton.styleFrom(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: wide ? 24 : 16,
                                    vertical: 12,
                                  ),
                                ),
                                label: Text(
                                  wide
                                      ? t('添加账户', 'Add account')
                                      : t('添加', 'Add'),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: wide ? 32 : 16),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: search,
                                  focusNode: searchFocus,
                                  onSubmitted: (_) => listFocus.requestFocus(),
                                  decoration: InputDecoration(
                                    hintText: t(
                                      '搜索服务或账户',
                                      'Search services or accounts',
                                    ),
                                    prefixIcon: const Icon(
                                      Icons.search,
                                      size: 22,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    fillColor: cs.surface,
                                    suffixIcon: search.text.isEmpty
                                        ? null
                                        : IconButton(
                                            tooltip: t('清除搜索', 'Clear search'),
                                            onPressed: search.clear,
                                            icon: const Icon(
                                              Icons.close,
                                              size: 18,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                              if (wide) ...[
                                const SizedBox(width: 12),
                                sortControl(),
                              ],
                            ],
                          ),
                          if (!wide) ...[
                            const SizedBox(height: 12),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  filterChip(
                                    'all',
                                    t(
                                      '全部 ${app.document!.entries.length}',
                                      'All ${app.document!.entries.length}',
                                    ),
                                    Icons.circle,
                                  ),
                                  filterChip(
                                    'favorites',
                                    t('收藏', 'Favorites'),
                                    Icons.star_outline_rounded,
                                  ),
                                  ...app.document!.groups.map(
                                    (g) => filterChip(
                                      g.id,
                                      g.fields['name'] as String,
                                      ['个人', 'personal'].contains(
                                            (g.fields['name'] as String)
                                                .toLowerCase(),
                                          )
                                          ? Icons.person_outline
                                          : Icons.folder_outlined,
                                    ),
                                  ),
                                  sortControl(compact: true),
                                  IconButton(
                                    tooltip: t('管理分组', 'Manage groups'),
                                    onPressed: () => run(groupMenu),
                                    icon: const Icon(
                                      Icons.create_new_folder_outlined,
                                      size: 20,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (app.document!.conflictCount > 0) ...[
                            const SizedBox(height: 12),
                            StatusNotice(
                              text: t(
                                '有并发修改需要确认，所有版本均已保留。',
                                'Concurrent edits need your review. Every version is preserved.',
                              ),
                              icon: Icons.warning_amber_rounded,
                              tone: NoticeTone.warning,
                            ),
                          ],
                          SizedBox(height: wide ? 32 : 20),
                          if (wide)
                            LayoutBuilder(
                              builder: (context, constraints) =>
                                  AccountColumns.fits(
                                    context,
                                    constraints.maxWidth - 32,
                                  )
                                  ? Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        0,
                                        16,
                                        12,
                                      ),
                                      child: DefaultTextStyle.merge(
                                        style: TextStyle(
                                          color: cs.onSurfaceVariant,
                                          fontSize: 12,
                                        ),
                                        child: AccountColumns(
                                          identity: Text(t('账户', 'Account')),
                                          code: Text(t('验证码', 'Code')),
                                          remaining: Text(
                                            t('剩余时间', 'Time left'),
                                          ),
                                          copy: const SizedBox(),
                                          menu: const SizedBox(),
                                        ),
                                      ),
                                    )
                                  : const SizedBox(),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (entries.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: emptyAccounts(),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(padding, 0, padding, 16),
                      sliver: SliverList.builder(
                        itemCount: entries.length,
                        itemBuilder: (_, index) => DecoratedBox(
                          decoration: BoxDecoration(
                            border:
                                selected == index &&
                                    listFocus.hasPrimaryFocus &&
                                    keyboardSelection
                                ? Border(
                                    left: BorderSide(
                                      color: cs.primary,
                                      width: 3,
                                    ),
                                  )
                                : null,
                          ),
                          child: entryTile(entries[index], index),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (wide)
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 12, padding, 24),
              child: Row(
                children: [
                  Icon(
                    Icons.wifi_off_outlined,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    t('离线可用', 'Available offline'),
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget sidebar() {
    final cs = Theme.of(context).colorScheme;
    Widget destination(
      String label,
      IconData icon,
      bool selected,
      VoidCallback onTap,
    ) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? cs.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: Icon(icon, size: 23),
          title: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          selected: selected,
          selectedColor: cs.primary,
          onTap: onTap,
        ),
      ),
    );
    final top = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            BrandMark(size: 36),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Six Tick',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        destination(
          t('验证码', 'Codes'),
          Icons.grid_view_rounded,
          page == 0 && activeFilter == 'all',
          () => selectFilter('all'),
        ),
        destination(
          t('收藏', 'Favorites'),
          Icons.star_outline_rounded,
          page == 0 && activeFilter == 'favorites',
          () => selectFilter('favorites'),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  t('分组', 'Groups'),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            ),
            IconButton(
              tooltip: t('管理分组', 'Manage groups'),
              onPressed: () => run(groupMenu),
              icon: const Icon(Icons.add, size: 18),
            ),
          ],
        ),
        for (final group in app.document!.groups)
          destination(
            group.fields['name'] as String,
            Icons.folder_outlined,
            page == 0 && activeFilter == group.id,
            () => selectFilter(group.id),
          ),
        if (app.document!.groups.isEmpty)
          TextButton(
            onPressed: () => run(groupMenu),
            child: Text(t('添加分组', 'Add a group')),
          ),
      ],
    );
    final bottom = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 32),
        destination(
          t('同步', 'Sync'),
          Icons.sync_outlined,
          page == 1,
          () => setState(() => page = 1),
        ),
        destination(
          t('设置', 'Settings'),
          Icons.settings_outlined,
          page == 2 || page == 3,
          () => setState(() => page = 3),
        ),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                app.cloud?.enabled == true
                    ? Icons.cloud_done_outlined
                    : Icons.wifi_off_outlined,
                size: 20,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      app.cloud?.enabled == true
                          ? t('加密同步', 'Encrypted sync')
                          : app.cloud == null
                          ? t('本地模式', 'Local mode')
                          : t('同步已暂停', 'Sync paused'),
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      app.cloud != null
                          ? t('离线仍可取码。', 'Codes work offline.')
                          : t(
                              '离线可用，数据仅存储在本地。',
                              'Offline. Data stays on this device.',
                            ),
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: app.lock,
          icon: const Icon(Icons.lock_outline, size: 18),
          label: Text(t('锁定', 'Lock')),
        ),
      ],
    );
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xff101b2c)
            : const Color(0xfff7fbff),
        border: Border(right: BorderSide(color: cs.outlineVariant)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [top, bottom],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final content = switch (page) {
      1 => CloudPage(app: app),
      2 => Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, top: 8),
              child: TextButton.icon(
                onPressed: () => setState(() => page = 3),
                icon: const Icon(Icons.arrow_back, size: 18),
                label: Text(t('设置', 'Settings')),
              ),
            ),
          ),
          Expanded(child: SecurityPage(app: app)),
        ],
      ),
      3 => SettingsPage(app: app, onSecurity: () => setState(() => page = 2)),
      _ => accounts(wide),
    };
    void focusSearch() {
      setState(() => page = 0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) searchFocus.requestFocus();
      });
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): focusSearch,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: wide
              ? null
              : AppBar(
                  toolbarHeight: 64,
                  title: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      BrandMark(size: 30),
                      SizedBox(width: 10),
                      Text('Six Tick', style: TextStyle(fontSize: 20)),
                    ],
                  ),
                  actions: [
                    IconButton(
                      onPressed: app.lock,
                      tooltip: t('锁定', 'Lock'),
                      icon: const Icon(Icons.lock_outline, size: 21),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
          body: SafeArea(
            child: Row(
              children: [
                if (wide) sidebar(),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1120),
                      child: content,
                    ),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  animationDuration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  selectedIndex: page == 0
                      ? 0
                      : page == 1
                      ? 1
                      : 2,
                  onDestinationSelected: (index) =>
                      setState(() => page = [0, 1, 3][index]),
                  destinations: [
                    NavigationDestination(
                      icon: const Icon(Icons.grid_view_rounded),
                      label: t('验证码', 'Codes'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.sync_outlined),
                      label: t('同步', 'Sync'),
                    ),
                    NavigationDestination(
                      icon: const Icon(Icons.settings_outlined),
                      label: t('设置', 'Settings'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
