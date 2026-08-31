import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/sdk_setup_manager.dart';
import 'package:androidstudiowinhelper/pages/shared_widgets.dart';

class SdkSetupTab extends StatefulWidget {
  const SdkSetupTab({super.key});

  @override
  State<SdkSetupTab> createState() => _SdkSetupTabState();
}

class _SdkSetupTabState extends State<SdkSetupTab> {
  final _sdkSetupManager = SdkSetupManager();
  final _sdkProxyController = TextEditingController();

  bool _loading = false;
  int _percent = 0;
  String _message = '';
  String _mirror = 'flutter';
  SdkPackageInfo? _packageInfo;
  SdkActionResult? _actionResult;
  SdkStatus? _sdkStatus;
  final Set<String> _selectedPackages = {};

  @override
  void initState() {
    super.initState();
    _detectSdkStatus();
  }

  @override
  void dispose() {
    _sdkProxyController.dispose();
    super.dispose();
  }

  void _detectSdkStatus() {
    final status = SdkSetupManager.quickStatus();
    setState(() => _sdkStatus = status);
    _loadPackages();
  }

  Future<void> _loadPackages() async {
    setState(() {
      _loading = true;
      _message = '正在查询包列表...';
    });
    try {
      final info = await _sdkSetupManager.listPackages(
        sdkDir: _sdkStatus?.sdkDir,
        mirror: _mirror,
        proxy: _sdkProxyController.text.trim().isEmpty
            ? null
            : _sdkProxyController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _packageInfo = info;
        _sdkStatus = SdkSetupManager.quickStatus();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '查询失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runAction(String action, List<String> pkgs) async {
    if (pkgs.isEmpty) return;
    setState(() {
      _loading = true;
      _percent = 0;
      _message = action == 'install' ? '正在安装...' : '正在卸载...';
      _actionResult = null;
    });
    try {
      final result = action == 'install'
          ? await _sdkSetupManager.install(
              packages: pkgs,
              sdkDir: _sdkStatus?.sdkDir,
              mirror: _mirror,
              proxy: _sdkProxyController.text.trim().isEmpty
                  ? null
                  : _sdkProxyController.text.trim(),
              onProgress: (pct, msg) {
                if (!mounted) return;
                setState(() {
                  _percent = pct;
                  _message = msg;
                });
              },
            )
          : await _sdkSetupManager.uninstall(
              packages: pkgs,
              sdkDir: _sdkStatus?.sdkDir,
              onProgress: (pct, msg) {
                if (!mounted) return;
                setState(() {
                  _percent = pct;
                  _message = msg;
                });
              },
            );
      if (!mounted) return;
      setState(() {
        _actionResult = result;
        _message = result.message;
      });
      await _loadPackages();
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '操作失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _sdkStatus;
    final info = _packageInfo;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            icon: Icons.build_outlined,
            title: 'SDK 管理',
            trailing: status != null ? status.sdkDir : null,
            action: ActionButton(
              label: '刷新',
              icon: Icons.refresh,
              loading: _loading,
              onPressed: _loading ? null : _detectSdkStatus,
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: _percent > 0 ? _percent / 100 : null,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '$_percent% — $_message',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          if (_actionResult != null)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              color: _actionResult!.success
                  ? Colors.green.withValues(alpha: 0.1)
                  : Colors.red.withValues(alpha: 0.1),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _actionResult!.message,
                  style: TextStyle(
                    color: _actionResult!.success
                        ? Colors.green.shade800
                        : Colors.red.shade800,
                  ),
                ),
              ),
            ),
          if (info != null) _buildPackageManager(info, status),
        ],
      ),
    );
  }

  Widget _buildPackageManager(SdkPackageInfo info, SdkStatus? status) {
    final categories = <String, List<String>>{};
    for (final pkg in info.available) {
      final cat = pkg.split(';').first;
      categories.putIfAbsent(cat, () => []);
      categories[cat]!.add(pkg);
    }
    final installedPaths = info.installed.map((p) => p.path).toList();

    return Expanded(
      child: ListView(
        children: [
          _buildSdkInfoCard(status),
          const SizedBox(height: 10),
          if (info.installed.isNotEmpty) ...[
            _sectionTitle('已安装 (${info.installed.length})'),
            for (final pkg in info.installed)
              _InstalledPackageTile(
                package: pkg,
                onUninstall: () => _runAction('uninstall', [pkg.path]),
              ),
            const SizedBox(height: 16),
          ],
          _sectionTitle('可用包（勾选后安装）'),
          const SizedBox(height: 8),
          _buildNetworkConfigCard(),
          const SizedBox(height: 10),
          _buildQuickInstallCard(info),
          const SizedBox(height: 10),
          for (final entry in categories.entries)
            _PackageCategoryCard(
              category: entry.key,
              packages: entry.value,
              installed: installedPaths,
              selected: _selectedPackages,
              onToggle: (pkg, sel) {
                setState(() {
                  if (sel) {
                    _selectedPackages.add(pkg);
                  } else {
                    _selectedPackages.remove(pkg);
                  }
                });
              },
            ),
          if (_selectedPackages.isNotEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: ElevatedButton.icon(
                onPressed: () =>
                    _runAction('install', _selectedPackages.toList()),
                icon: const Icon(Icons.download),
                label: Text('安装选中 (${_selectedPackages.length})'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSdkInfoCard(SdkStatus? status) {
    if (status == null) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    status.sdkDir,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'Consolas'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  status.hasJava ? Icons.check_circle : Icons.error_outline,
                  size: 18,
                  color: status.hasJava ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Text(
                  status.hasJava ? 'Java: 已安装' : 'Java: 未检测到',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleSmall),
    );
  }

  Widget _buildNetworkConfigCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('下载源', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _mirror,
              isDense: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'flutter',
                  child: Text('Flutter CDN (推荐)'),
                ),
                DropdownMenuItem(value: 'tencent', child: Text('腾讯云')),
                DropdownMenuItem(value: 'bfsu', child: Text('北外镜像')),
                DropdownMenuItem(value: 'official', child: Text('Google 官方')),
              ],
              onChanged: (v) => setState(() => _mirror = v ?? 'flutter'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sdkProxyController,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontFamily: 'Consolas'),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(),
                hintText: '留空不使用代理',
                labelText: '代理地址（可选）',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickInstallCard(SdkPackageInfo info) {
    final quickPkgs = [
      ('platform-tools', 'ADB'),
      ('emulator', '模拟器'),
      ('build-tools;36.0.0', 'Build Tools'),
      ('platforms;android-36', 'Platform 36'),
      ('sources;android-36', 'Sources'),
      ('extras;google;Android_Emulator_Hypervisor_Driver', 'AEHD'),
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('快速安装核心包', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (key, label) in quickPkgs)
                  FilterChip(
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    selected: _selectedPackages.contains(key),
                    onSelected: (sel) {
                      setState(() {
                        if (sel) {
                          _selectedPackages.add(key);
                        } else {
                          _selectedPackages.remove(key);
                        }
                      });
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InstalledPackageTile extends StatelessWidget {
  final InstalledPackage package;
  final VoidCallback onUninstall;

  const _InstalledPackageTile({
    required this.package,
    required this.onUninstall,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Tooltip(
                message: package.path.isNotEmpty
                    ? '${package.path}  ${package.version}'
                    : package.displayTitle,
                excludeFromSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      package.displayTitle,
                      style: const TextStyle(fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (package.path.isNotEmpty)
                      Text(
                        '${package.path}  ${package.version}',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'Consolas',
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                size: 18,
                color: Colors.red,
              ),
              tooltip: '卸载',
              onPressed: onUninstall,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ),
      ),
    );
  }
}

class _PackageCategoryCard extends StatelessWidget {
  final String category;
  final List<String> packages;
  final List<String> installed;
  final Set<String> selected;
  final void Function(String pkg, bool selected) onToggle;

  const _PackageCategoryCard({
    required this.category,
    required this.packages,
    required this.installed,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Row(
          children: [
            Expanded(
              child: Text(
                category,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              '${packages.length} 项',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: packages.map((pkg) {
          final isInstalled = installed.contains(pkg);
          final isSelected = selected.contains(pkg);
          return InkWell(
            onTap: isInstalled ? null : () => onToggle(pkg, !isSelected),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: isInstalled
                        ? const Icon(
                            Icons.check_circle,
                            color: Colors.green,
                            size: 18,
                          )
                        : Checkbox(
                            value: isSelected,
                            onChanged: (v) => onToggle(pkg, v ?? false),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      pkg,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'Consolas',
                        color: isInstalled ? Colors.green : null,
                      ),
                      softWrap: true,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
