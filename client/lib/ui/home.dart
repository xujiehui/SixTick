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
import 'security_page.dart';

class HomeScreen extends StatefulWidget {
  final AppController app;
  final int initialPage;
  const HomeScreen({super.key, required this.app, this.initialPage = 0});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final search = TextEditingController(),
      searchFocus = FocusNode(),
      listFocus = FocusNode();
  final now = ValueNotifier<int>(DateTime.now().millisecondsSinceEpoch ~/ 1000);
  Timer? clock;
  int page = 0, selected = 0;
  String filter = 'all';
  AppController get app => widget.app;
  String t(String zh, String en) => tr(app, zh, en);
  @override
  void initState() {
    super.initState();
    page = widget.initialPage;
    clock = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => now.value = DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    search.addListener(() {
      if (mounted) setState(() => selected = 0);
    });
  }

  @override
  void dispose() {
    clock?.cancel();
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
    final entries = app.document!.entries.where((entry) {
      final otp = entry.otp;
      return (filter == 'all' ||
              filter == 'favorites' && entry.fields['favorite'] == true ||
              entry.fields['group'] == filter) &&
          ('${otp.issuer} ${otp.account}').toLowerCase().contains(query);
    }).toList();
    entries.sort((a, b) {
      final fav =
          (b.fields['favorite'] == true ? 1 : 0) -
          (a.fields['favorite'] == true ? 1 : 0);
      return fav != 0
          ? fav
          : a.otp.issuer.toLowerCase().compareTo(b.otp.issuer.toLowerCase());
    });
    return entries;
  }

  Future<void> copy(RecordView entry) async {
    if (app.locked || app.privacyHidden) return;
    final code = entry.otp.codeAt(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(t('验证码已复制', 'Code copied')),
        ),
      );
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
        builder: (context, state) => AlertDialog(
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
                const SizedBox(height: 14),
                TextField(
                  controller: account,
                  decoration: InputDecoration(
                    labelText: t('账号标识', 'Account label'),
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
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
                const SizedBox(height: 14),
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
      builder: (context) => AlertDialog(
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

  Widget entryTile(RecordView entry, int index) {
    final otp = entry.otp, cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          setState(() => selected = index);
          listFocus.requestFocus();
          run(() => edit(entry));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  otp.issuer.characters.first.toUpperCase(),
                  style: TextStyle(
                    color: cs.onPrimaryContainer,
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (entry.conflicts.isNotEmpty)
                          IconButton(
                            icon: Icon(
                              Icons.warning_amber_rounded,
                              color: cs.error,
                            ),
                            tooltip: t('处理同步冲突', 'Resolve sync conflict'),
                            onPressed: () => run(() => resolve(entry)),
                          ),
                      ],
                    ),
                    if (otp.account.isNotEmpty)
                      Text(
                        otp.account,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    const SizedBox(height: 12),
                    ValueListenableBuilder<int>(
                      valueListenable: now,
                      builder: (context, seconds, _) {
                        final code = otp.codeAt(seconds),
                            split = otp.digits ~/ 2,
                            left = otp.remaining(seconds);
                        return Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 6,
                          children: [
                            Semantics(
                              label:
                                  '${t('验证码', 'Code')} ${code.split('').join(' ')}',
                              excludeSemantics: true,
                              child: Text(
                                '${code.substring(0, split)} ${code.substring(split)}',
                                style: TextStyle(
                                  fontSize: 29,
                                  fontWeight: FontWeight.w500,
                                  fontFamily: 'monospace',
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                  color: left <= 5 ? cs.error : cs.primary,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ),
                            ExcludeSemantics(
                              child: SizedBox(
                                width: 25,
                                height: 25,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    CircularProgressIndicator(
                                      value: left / otp.period,
                                      strokeWidth: 2,
                                      color: left <= 5
                                          ? cs.error
                                          : cs.primary.withValues(alpha: .6),
                                      backgroundColor:
                                          cs.surfaceContainerHighest,
                                    ),
                                    Text(
                                      '$left',
                                      style: const TextStyle(fontSize: 9),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (left <= 5)
                              Text(
                                t('即将更新', 'Refreshing soon'),
                                style: TextStyle(fontSize: 11, color: cs.error),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  IconButton(
                    tooltip: t('复制验证码', 'Copy code'),
                    onPressed: () => run(() => copy(entry)),
                    icon: const Icon(Icons.copy_rounded, size: 20),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: t('收藏 / 取消收藏', 'Toggle favorite'),
                        onPressed: () => run(
                          () => app.edit(entry, {
                            'favorite': entry.fields['favorite'] != true,
                          }),
                        ),
                        icon: Icon(
                          entry.fields['favorite'] == true
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          size: 20,
                          color: cs.primary,
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: t('更多操作', 'More actions'),
                        onSelected: (value) => run(() => menu(entry, value)),
                        itemBuilder: (_) => [
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
                            child: Text(t('删除账号', 'Delete account')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget accounts() {
    final entries = visible, cs = Theme.of(context).colorScheme;
    return DropTarget(
      onDragDone: (details) {
        if (details.files.isNotEmpty) {
          run(() => importQr(context, app, file: details.files.first));
        }
      },
      child: Padding(
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 600 ? 18 : 32,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t('验证码', 'Your codes'),
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t('随时可用，即使没有网络。', 'Ready when you are. Even offline.'),
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: t('添加账号', 'Add account'),
                  onSelected: (value) => run(() async {
                    if (value == 'manual') {
                      await showDialog<void>(
                        context: context,
                        builder: (_) => AddAccountDialog(app: app),
                      );
                    }
                    if (value == 'image' && mounted) {
                      await importQr(context, app);
                    }
                    if (value == 'scan' && mounted) await scanQr(context, app);
                  }),
                  itemBuilder: (_) => [
                    if (Platform.isIOS || Platform.isAndroid)
                      PopupMenuItem(
                        value: 'scan',
                        child: Text(t('扫描二维码', 'Scan QR code')),
                      ),
                    PopupMenuItem(
                      value: 'image',
                      child: Text(t('导入二维码图片', 'Import QR image')),
                    ),
                    PopupMenuItem(
                      value: 'manual',
                      child: Text(t('手动输入 / 链接', 'Secret / URI')),
                    ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.add, color: cs.onPrimary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            TextField(
              controller: search,
              focusNode: searchFocus,
              decoration: InputDecoration(
                hintText: t('搜索服务或账号', 'Search services or accounts'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: search.text.isNotEmpty
                    ? IconButton(
                        onPressed: search.clear,
                        icon: const Icon(Icons.close),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: Text(
                      '${t('全部', 'All')} ${app.document!.entries.length}',
                    ),
                    selected: filter == 'all',
                    onSelected: (_) => setState(() => filter = 'all'),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(t('收藏', 'Favorites')),
                    selected: filter == 'favorites',
                    onSelected: (_) => setState(() => filter = 'favorites'),
                  ),
                  ...app.document!.groups.map(
                    (g) => Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ChoiceChip(
                        label: Text(g.fields['name'] as String),
                        selected: filter == g.id,
                        onSelected: (_) => setState(() => filter = g.id),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: t('管理分组', 'Manage groups'),
                    onPressed: () => run(groupMenu),
                    icon: const Icon(Icons.folder_open_outlined),
                  ),
                ],
              ),
            ),
            if (app.document!.conflictCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  t(
                    '有并发修改需要确认，所有版本均已保留。',
                    'Concurrent edits need your review. Every version is preserved.',
                  ),
                  style: TextStyle(color: cs.error),
                ),
              ),
            const SizedBox(height: 16),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            search.text.isEmpty
                                ? Icons.key_outlined
                                : Icons.search_off,
                            size: 58,
                            color: cs.primary,
                          ),
                          const SizedBox(height: 18),
                          Text(
                            t(
                              search.text.isEmpty ? '添加你的第一个账号' : '没有找到匹配的账号',
                              search.text.isEmpty
                                  ? 'Add your first account'
                                  : 'No matching accounts',
                            ),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            t(
                              '从网站的两步验证设置中获取二维码或密钥。',
                              'Find the QR code or secret in your website’s two-step verification settings.',
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : Focus(
                      focusNode: listFocus,
                      onKeyEvent: (_, event) {
                        if (event is! KeyDownEvent) {
                          return KeyEventResult.ignored;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
                            event.logicalKey == LogicalKeyboardKey.arrowUp) {
                          setState(
                            () => selected =
                                (selected +
                                        (event.logicalKey ==
                                                LogicalKeyboardKey.arrowDown
                                            ? 1
                                            : -1))
                                    .clamp(0, entries.length - 1),
                          );
                          return KeyEventResult.handled;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.enter) {
                          run(
                            () => copy(
                              entries[selected.clamp(0, entries.length - 1)],
                            ),
                          );
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (_, index) => DecoratedBox(
                          decoration: BoxDecoration(
                            border: selected == index && listFocus.hasFocus
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
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.lock_outline, size: 13, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    t('密钥在本机加密保存', 'Your secrets are encrypted on this device'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Text('RFC 6238', style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final labels = [
      t('验证码', 'Codes'),
      t('同步与设备', 'Sync & devices'),
      t('安全与备份', 'Security & backup'),
      t('设置与帮助', 'Settings & help'),
    ];
    final icons = [
      Icons.grid_view_rounded,
      Icons.sync_outlined,
      Icons.shield_outlined,
      Icons.tune_rounded,
    ];
    final content = switch (page) {
      1 => CloudPage(app: app),
      2 => SecurityPage(app: app),
      3 => SettingsPage(app: app),
      _ => accounts(),
    };
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          setState(() => page = 0);
          searchFocus.requestFocus();
        },
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
          setState(() => page = 0);
          searchFocus.requestFocus();
        },
      },
      child: Scaffold(
        appBar: wide
            ? null
            : AppBar(
                title: const Text('Six Tick'),
                actions: [
                  IconButton(
                    onPressed: app.lock,
                    tooltip: t('锁定', 'Lock'),
                    icon: const Icon(Icons.lock_outline),
                  ),
                ],
              ),
        body: SafeArea(
          child: Row(
            children: [
              if (wide)
                Container(
                  width: 244,
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 32, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.shield_outlined,
                              size: 30,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Six Tick',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 25,
                                    letterSpacing: -1,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          t('你的私密验证器', 'Your private authenticator'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 40),
                        ...List.generate(
                          labels.length,
                          (i) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              selected: page == i,
                              selectedTileColor: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer
                                  .withValues(alpha: .5),
                              leading: Icon(icons[i]),
                              title: Text(labels[i]),
                              onTap: () => setState(() => page = i),
                            ),
                          ),
                        ),
                        const Spacer(),
                        ListTile(
                          leading: Icon(
                            app.cloud?.enabled == true
                                ? Icons.cloud_done_outlined
                                : Icons.wifi_off,
                          ),
                          title: Text(
                            app.cloud?.enabled == true
                                ? t('加密同步', 'Encrypted sync')
                                : t('本地模式', 'Local mode'),
                          ),
                          subtitle: Text(
                            t('安全，从你的设备开始', 'Security starts on your device'),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: app.lock,
                          icon: const Icon(Icons.lock_outline, size: 18),
                          label: Text(t('锁定验证器', 'Lock authenticator')),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(child: content),
            ],
          ),
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: page,
                onDestinationSelected: (index) => setState(() => page = index),
                destinations: List.generate(
                  labels.length,
                  (i) => NavigationDestination(
                    icon: Icon(icons[i]),
                    label: labels[i],
                  ),
                ),
              ),
      ),
    );
  }
}
