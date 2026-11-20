import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'data/app_settings.dart';
import 'data/database_helper.dart';
import 'data/expiry_notification_service.dart';
import 'data/google_drive_backup_service.dart';
import 'data/local_data_service.dart';
import 'data/vault_stats.dart';
import 'models/purchase.dart';

const navy = Color(0xFF10213A);
const blue = Color(0xFF2457D6);
const teal = Color(0xFF10B8A6);
const canvas = Color(0xFFF3F7FC);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await AppSettings.instance.load();
  } catch (_) {
    // Fall back to the built-in defaults if saved settings cannot be read.
  }
  runApp(const WarrantyVaultApp());
}

class WarrantyVaultApp extends StatelessWidget {
  const WarrantyVaultApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'WarrantyVault',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(seedColor: blue, primary: blue, secondary: teal, surface: Colors.white),
      navigationBarTheme: const NavigationBarThemeData(backgroundColor: Colors.white, indicatorColor: Color(0xFFDCE6FF)),
      appBarTheme: const AppBarTheme(backgroundColor: canvas, foregroundColor: navy, elevation: 0, centerTitle: false, scrolledUnderElevation: 0),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: blue, foregroundColor: Colors.white, elevation: 4),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: blue, width: 1.5)),
      ),
    ),
    home: const StartupGate(),
  );
}

String prettyDate(String raw) {
  try { return DateFormat('dd MMM yyyy').format(parseDbDate(raw)); } catch (_) { return raw; }
}

Color statusColor(String status) => status == 'Active' ? const Color(0xFF059669) : status == 'Expiring Soon' ? const Color(0xFFD97706) : const Color(0xFFDC2626);
Color statusBg(String status) => status == 'Active' ? const Color(0xFFECFDF5) : status == 'Expiring Soon' ? const Color(0xFFFFFBEB) : const Color(0xFFFEF2F2);

class StartupGate extends StatefulWidget {
  const StartupGate({super.key});
  @override State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool _checking = true;
  bool _unlocked = false;
  final LocalAuthentication _auth = LocalAuthentication();
  @override void initState() { super.initState(); _checkLock(); }
  Future<void> _checkLock() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('biometric_lock_enabled') != true) { if (mounted) setState(() { _unlocked = true; _checking = false; }); return; }
    await _authenticate();
  }
  Future<void> _authenticate() async {
    if (mounted) setState(() => _checking = true);
    try {
      final supported = await _auth.isDeviceSupported() || await _auth.canCheckBiometrics;
      final ok = supported && await _auth.authenticate(localizedReason: 'Unlock WarrantyVault', options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true));
      if (mounted) setState(() { _unlocked = ok; _checking = false; });
    } catch (_) { if (mounted) setState(() { _unlocked = false; _checking = false; }); }
  }
  @override Widget build(BuildContext context) {
    if (_unlocked) return const AppShell();
    return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.lock_outline, size: 64, color: blue), const SizedBox(height: 16), const Text('WarrantyVault is locked', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: navy)), const SizedBox(height: 8), const Text('Authenticate to access your saved warranties.', textAlign: TextAlign.center), const SizedBox(height: 20), if (_checking) const CircularProgressIndicator() else FilledButton.icon(onPressed: _authenticate, icon: const Icon(Icons.fingerprint), label: const Text('Unlock app'))]))));
  }
}

/// Opens the details page of [item]; calls [onChanged] if it was edited or deleted there.
Future<void> _openDetails(BuildContext context, Purchase item, VoidCallback onChanged) async {
  final id = item.id;
  if (id == null) return;
  final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PurchaseDetailsScreen(purchaseId: id)));
  if (changed == true) onChanged();
}

// ---------------------------------------------------------------- app shell (bottom navigation)

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  List<Purchase> _items = [];
  bool _loading = true;
  String _filter = 'All';

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final data = await DatabaseHelper.instance.getPurchases();
      try { await ExpiryNotificationService.instance.rescheduleAll(data); } catch (_) { /* Keep the vault usable if notification permission is denied. */ }
      unawaited(GoogleDriveBackupService.instance.maybeAutoBackup());
      if (!mounted) return;
      setState(() { _items = data; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(context, 'Could not load your vault: ${_errText(e)}');
    }
  }

  void _showVault(String status) => setState(() { _filter = status; _tab = 0; });

  @override Widget build(BuildContext context) {
    final pages = <Widget>[
      VaultTab(items: _items, loading: _loading, filter: _filter, onFilter: (f) => setState(() => _filter = f), onReload: _load),
      InsightsTab(items: _items, loading: _loading, onReload: _load, onOpenVault: _showVault),
      ExpiryTimelineTab(items: _items, loading: _loading, onReload: _load),
      SettingsScreen(onDataChanged: _load),
    ];
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, result) { if (!didPop) setState(() => _tab = 0); },
      child: Scaffold(
        body: IndexedStack(index: _tab, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.shield_outlined), selectedIcon: Icon(Icons.shield), label: 'Vault'),
            NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Insights'),
            NavigationDestination(icon: Icon(Icons.event_note_outlined), selectedIcon: Icon(Icons.event_note), label: 'Timeline'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- tab 1: vault

class VaultTab extends StatefulWidget {
  final List<Purchase> items;
  final bool loading;
  final String filter;
  final ValueChanged<String> onFilter;
  final Future<void> Function() onReload;
  const VaultTab({super.key, required this.items, required this.loading, required this.filter, required this.onFilter, required this.onReload});
  @override State<VaultTab> createState() => _VaultTabState();
}

class _VaultTabState extends State<VaultTab> {
  String _query = '';
  VaultSort _sort = VaultSort.newest;

  List<Purchase> get _visible {
    final q = _query.trim().toLowerCase();
    final filtered = widget.items.where((item) {
      final status = warrantyStatus(item.expiryDate);
      final matchesFilter = widget.filter == 'All' || status == widget.filter;
      final matchesQuery = q.isEmpty || item.name.toLowerCase().contains(q) || item.shop.toLowerCase().contains(q) || item.categoryName.toLowerCase().contains(q);
      return matchesFilter && matchesQuery;
    }).toList();
    return sortPurchases(filtered, _sort);
  }

  Future<void> _add() async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const PurchaseFormScreen()));
    if (saved == true) unawaited(widget.onReload());
  }

  @override Widget build(BuildContext context) {
    final items = widget.items;
    final filter = widget.filter;
    final visible = _visible;
    final expiring = items.where((e) => warrantyStatus(e.expiryDate) == 'Expiring Soon').length;
    final totalValue = items.fold<double>(0, (sum, e) => sum + e.price);
    return Scaffold(
      appBar: AppBar(title: Row(children: [ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.asset('assets/images/warrantyvault_logo.png', width: 42, height: 42, fit: BoxFit.cover)), const SizedBox(width: 10), const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('WarrantyVault', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: navy)), Text('Your warranties, protected', style: TextStyle(fontSize: 11, color: Color(0xFF64748B)))])])),
      body: RefreshIndicator(onRefresh: widget.onReload, child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
        Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF173B8F), Color(0xFF2457D6), Color(0xFF10AFA4)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(22), boxShadow: [BoxShadow(color: blue.withValues(alpha: .16), blurRadius: 18, offset: const Offset(0, 8))]), child: Row(children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('YOUR PEACE OF MIND', style: TextStyle(color: Color(0xFFBFE8FF), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2)), const SizedBox(height: 7), const Text('Every warranty,\none safe place.', style: TextStyle(color: Colors.white, fontSize: 21, height: 1.15, fontWeight: FontWeight.w900)), const SizedBox(height: 7), Text('${items.length} registered ${items.length == 1 ? 'item' : 'items'}${totalValue > 0 ? ' • ${formatMoney(totalValue)} total value' : ''}', style: const TextStyle(color: Color(0xFFE0F2FE), fontSize: 12, fontWeight: FontWeight.w600))])), const SizedBox(width: 8), Container(width: 66, height: 66, decoration: BoxDecoration(color: Colors.white.withValues(alpha: .16), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withValues(alpha: .22))), child: Padding(padding: const EdgeInsets.all(7), child: Image.asset('assets/images/warrantyvault_logo.png', fit: BoxFit.contain))) ])),
        const SizedBox(height: 16),
        TextField(decoration: const InputDecoration(hintText: 'Search products or shops...', prefixIcon: Icon(Icons.search), contentPadding: EdgeInsets.symmetric(vertical: 12)), onChanged: (v) => setState(() => _query = v)),
        const SizedBox(height: 14),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: ['All', 'Active', 'Expiring Soon', 'Expired'].map((f) => Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(f == 'All' ? 'All (${items.length})' : f), selected: filter == f, onSelected: (_) => widget.onFilter(f), selectedColor: blue, labelStyle: TextStyle(color: filter == f ? Colors.white : const Color(0xFF475569), fontWeight: FontWeight.w600), backgroundColor: Colors.white, side: BorderSide(color: filter == f ? blue : const Color(0xFFE2E8F0))))).toList())),
        const SizedBox(height: 16),
        if (expiring > 0) Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFFE8EEFF), Color(0xFFEAF8FF)]), borderRadius: BorderRadius.circular(18)), child: Row(children: [Container(width: 42, height: 42, decoration: BoxDecoration(color: blue, borderRadius: BorderRadius.circular(14)), child: const Icon(Icons.timer_outlined, color: Colors.white)), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('$expiring ${expiring == 1 ? 'warranty' : 'warranties'} expiring soon', style: const TextStyle(fontWeight: FontWeight.w800, color: navy)), const SizedBox(height: 3), const Text('Review items that need attention this month', style: TextStyle(fontSize: 12, color: Color(0xFF475569)))])), TextButton(onPressed: () => widget.onFilter('Expiring Soon'), child: const Text('Review'))])),
        const SizedBox(height: 22),
        Row(children: [
          const Expanded(child: Text('Registered Items', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: navy))),
          PopupMenuButton<VaultSort>(
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (ctx) => VaultSort.values.map((s) => PopupMenuItem<VaultSort>(value: s, child: Text(vaultSortLabel(s)))).toList(),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.sort, size: 18, color: blue), const SizedBox(width: 4), Text('${visible.length} • ${vaultSortLabel(_sort)}', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w600))])),
          ),
        ]),
        const SizedBox(height: 10),
        if (widget.loading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (visible.isEmpty) _EmptyState(onAdd: _add, hasSearch: _query.isNotEmpty || filter != 'All')
        else ...visible.map((item) => _PurchaseCard(item: item, onTap: () => _openDetails(context, item, () => unawaited(widget.onReload())))),
      ])),
      floatingActionButton: FloatingActionButton.extended(onPressed: _add, backgroundColor: blue, foregroundColor: Colors.white, icon: const Icon(Icons.add), label: const Text('Add purchase', style: TextStyle(fontWeight: FontWeight.w700))),
    );
  }
}

// ---------------------------------------------------------------- tab 2: insights

class InsightsTab extends StatelessWidget {
  final List<Purchase> items;
  final bool loading;
  final Future<void> Function() onReload;
  final ValueChanged<String> onOpenVault;
  const InsightsTab({super.key, required this.items, required this.loading, required this.onReload, required this.onOpenVault});

  @override Widget build(BuildContext context) {
    final stats = VaultStats.from(items);
    final upcoming = sortPurchases(items.where((e) => daysUntilExpiry(e.expiryDate) >= 0).toList(), VaultSort.soonest).take(3).toList();
    final categoryTotal = stats.categories.fold<double>(0, (sum, c) => sum + c.value);
    final categoryMax = stats.categories.fold<int>(0, (m, c) => c.count > m ? c.count : m);
    return Scaffold(
      appBar: AppBar(title: const Text('Insights', style: TextStyle(fontWeight: FontWeight.w800))),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: onReload,
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          if (stats.total == 0)
            _panel(child: const Column(children: [
              Icon(Icons.insights_outlined, color: Color(0xFF94A3B8), size: 44),
              SizedBox(height: 10),
              Text('Nothing to show yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: navy)),
              SizedBox(height: 6),
              Text('Add a purchase on the Vault tab and your totals and charts will appear here.', textAlign: TextAlign.center, style: TextStyle(height: 1.4, color: Color(0xFF64748B))),
            ]))
          else ...[
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF173B8F), Color(0xFF2457D6), Color(0xFF10AFA4)], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(22)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('VALUE UNDER WARRANTY', style: TextStyle(color: Color(0xFFBFE8FF), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                const SizedBox(height: 6),
                Text(formatMoney(stats.protectedValue), style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text('of ${formatMoney(stats.totalValue)} across ${stats.total} ${stats.total == 1 ? 'item' : 'items'}', style: const TextStyle(color: Color(0xFFE0F2FE), fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _StatTile(icon: Icons.verified_outlined, value: '${stats.active}', label: 'Active', color: statusColor('Active'), background: statusBg('Active'), onTap: () => onOpenVault('Active'))),
              const SizedBox(width: 10),
              Expanded(child: _StatTile(icon: Icons.timer_outlined, value: '${stats.expiringSoon}', label: 'Expiring soon', color: statusColor('Expiring Soon'), background: statusBg('Expiring Soon'), onTap: () => onOpenVault('Expiring Soon'))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _StatTile(icon: Icons.event_busy_outlined, value: '${stats.expired}', label: 'Expired', color: statusColor('Expired'), background: statusBg('Expired'), onTap: () => onOpenVault('Expired'))),
              const SizedBox(width: 10),
              Expanded(child: _StatTile(icon: Icons.inventory_2_outlined, value: '${stats.total}', label: 'All items', color: blue, background: const Color(0xFFEFF6FF), onTap: () => onOpenVault('All'))),
            ]),
            const SizedBox(height: 14),
            _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _panelTitle('Warranty status', 'How your ${stats.total} ${stats.total == 1 ? 'item is' : 'items are'} covered today.'),
              ClipRRect(borderRadius: BorderRadius.circular(8), child: Row(children: [
                if (stats.active > 0) Expanded(flex: stats.active, child: Container(height: 12, color: statusColor('Active'))),
                if (stats.expiringSoon > 0) Expanded(flex: stats.expiringSoon, child: Container(height: 12, color: statusColor('Expiring Soon'))),
                if (stats.expired > 0) Expanded(flex: stats.expired, child: Container(height: 12, color: statusColor('Expired'))),
              ])),
              const SizedBox(height: 12),
              _legendRow('Active', stats.active, stats.total),
              _legendRow('Expiring Soon', stats.expiringSoon, stats.total),
              _legendRow('Expired', stats.expired, stats.total),
            ])),
            const SizedBox(height: 14),
            _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _panelTitle('By category', categoryTotal > 0 ? 'Where your money is, biggest first.' : 'Number of items in each category.'),
              for (final c in stats.categories) _categoryRow(c, categoryTotal, categoryMax),
            ])),
            if (upcoming.isNotEmpty) ...[
              const SizedBox(height: 14),
              _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _panelTitle('Next to expire', 'Tap an item to open it.'),
                for (final item in upcoming)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    onTap: () => _openDetails(context, item, () => unawaited(onReload())),
                    title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, color: navy)),
                    subtitle: Text(warrantyTimeLeft(item.expiryDate), style: TextStyle(fontSize: 12, color: statusColor(warrantyStatus(item.expiryDate)))),
                    trailing: const Icon(Icons.chevron_right, color: Color(0xFF94A3B8)),
                  ),
              ])),
            ],
          ],
        ]),
      ),
    );
  }

  Widget _legendRow(String status, int count, int total) {
    final percent = total == 0 ? 0 : (count * 100 / total).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: statusColor(status), shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(child: Text(status, style: const TextStyle(color: navy, fontWeight: FontWeight.w600, fontSize: 13))),
        Text('$count • $percent%', style: const TextStyle(color: Color(0xFF64748B), fontSize: 13, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _categoryRow(CategoryStat c, double valueTotal, int countMax) {
    final fraction = valueTotal > 0 ? (c.value / valueTotal) : (countMax > 0 ? c.count / countMax : 0.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_categoryIcon(c.name), size: 18, color: blue),
          const SizedBox(width: 8),
          Expanded(child: Text('${c.name} (${c.count})', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: navy, fontWeight: FontWeight.w700, fontSize: 13))),
          Text(formatMoney(c.value), style: const TextStyle(color: Color(0xFF64748B), fontSize: 13, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(value: fraction.clamp(0.0, 1.0).toDouble(), minHeight: 7, color: blue, backgroundColor: const Color(0xFFE2E8F0))),
      ]),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;
  final Color background;
  final VoidCallback onTap;
  const _StatTile({required this.icon, required this.value, required this.label, required this.color, required this.background, required this.onTap});
  @override Widget build(BuildContext context) => Card(
    elevation: 0,
    color: Colors.white,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFFE2E8F0))),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: color, size: 22)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: navy)),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
          ])),
        ]),
      ),
    ),
  );
}

// ---------------------------------------------------------------- tab 3: expiry timeline

class ExpiryTimelineTab extends StatefulWidget {
  final List<Purchase> items;
  final bool loading;
  final Future<void> Function() onReload;
  const ExpiryTimelineTab({super.key, required this.items, required this.loading, required this.onReload});
  @override State<ExpiryTimelineTab> createState() => _ExpiryTimelineTabState();
}

class _ExpiryTimelineTabState extends State<ExpiryTimelineTab> {
  Future<void> _openReminders() async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const NotificationSettingsScreen()));
    if (!mounted) return;
    setState(() {});
    if (saved == true) unawaited(widget.onReload());
  }

  @override Widget build(BuildContext context) {
    final groups = groupByTimeline(widget.items);
    return Scaffold(
      appBar: AppBar(title: const Text('Expiry timeline', style: TextStyle(fontWeight: FontWeight.w800))),
      body: widget.loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: widget.onReload,
        child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          _panel(child: Row(children: [
            const Icon(Icons.notifications_active_outlined, color: blue, size: 26),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Reminders', style: TextStyle(fontWeight: FontWeight.w800, color: navy)),
              const SizedBox(height: 2),
              Text(AppSettings.instance.notifications.summary, style: const TextStyle(fontSize: 12, height: 1.35, color: Color(0xFF64748B))),
            ])),
            TextButton(onPressed: _openReminders, child: const Text('Change')),
          ])),
          const SizedBox(height: 14),
          if (groups.isEmpty)
            _panel(child: const Column(children: [
              Icon(Icons.event_note_outlined, color: Color(0xFF94A3B8), size: 44),
              SizedBox(height: 10),
              Text('Nothing to track yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: navy)),
              SizedBox(height: 6),
              Text('Every warranty you add will be listed here in the order it expires.', textAlign: TextAlign.center, style: TextStyle(height: 1.4, color: Color(0xFF64748B))),
            ]))
          else
            for (final group in groups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 6, 2, 8),
                child: Row(children: [
                  Expanded(child: Text(group.key, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: navy))),
                  Text('${group.value.length} ${group.value.length == 1 ? 'item' : 'items'}', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                ]),
              ),
              for (final item in group.value) _TimelineRow(item: item, onTap: () => _openDetails(context, item, () => unawaited(widget.onReload()))),
              const SizedBox(height: 8),
            ],
        ]),
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final Purchase item;
  final VoidCallback onTap;
  const _TimelineRow({required this.item, required this.onTap});
  @override Widget build(BuildContext context) {
    final days = daysUntilExpiry(item.expiryDate);
    final status = warrantyStatus(item.expiryDate);
    final big = days == 0 ? 'Today' : '${days.abs()}';
    final small = days == 0 ? '' : days < 0 ? (days == -1 ? 'day ago' : 'days ago') : (days == 1 ? 'day' : 'days');
    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFFE5ECF5))),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Container(
              width: 62,
              height: 54,
              decoration: BoxDecoration(color: statusBg(status), borderRadius: BorderRadius.circular(14)),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(big, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: statusColor(status))),
                if (small.isNotEmpty) Text(small, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: statusColor(status))),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: navy)),
              const SizedBox(height: 3),
              Text('${prettyDate(item.expiryDate)} • ${item.expiryTime}', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
              const SizedBox(height: 2),
              Text(item.shop.isEmpty ? item.categoryName : '${item.categoryName} • ${item.shop}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
            ])),
            const Icon(Icons.chevron_right, color: Color(0xFF94A3B8)),
          ]),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd; final bool hasSearch;
  const _EmptyState({required this.onAdd, required this.hasSearch});
  @override Widget build(BuildContext context) => Container(margin: const EdgeInsets.only(top: 18), padding: const EdgeInsets.all(26), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE2E8F0))), child: Column(children: [Icon(hasSearch ? Icons.search_off_rounded : Icons.inventory_2_outlined, size: 46, color: const Color(0xFF94A3B8)), const SizedBox(height: 12), Text(hasSearch ? 'No matching purchases' : 'Your vault is ready', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: navy)), const SizedBox(height: 6), Text(hasSearch ? 'Try another search or filter.' : 'Add a product to start tracking its warranty.', textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF64748B))), if (!hasSearch) ...[const SizedBox(height: 14), FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Add first purchase'))]]));
}

class _PurchaseCard extends StatelessWidget {
  final Purchase item; final VoidCallback onTap;
  const _PurchaseCard({required this.item, required this.onTap});
  @override Widget build(BuildContext context) {
    final status = warrantyStatus(item.expiryDate);
    final label = warrantyTimeLeft(item.expiryDate);
    return Card(elevation: 1, shadowColor: const Color(0xFF1E3A8A).withValues(alpha: .06), color: Colors.white, margin: const EdgeInsets.only(bottom: 11), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: Color(0xFFE5ECF5))), child: InkWell(borderRadius: BorderRadius.circular(17), onTap: onTap, child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [Container(width: 54, height: 54, decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFFE7EEFF), Color(0xFFE1FAF7)]), borderRadius: BorderRadius.circular(14)), child: item.receiptPath.isNotEmpty && File(item.receiptPath).existsSync() ? Stack(fit: StackFit.expand, children: [ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.file(File(item.receiptPath), fit: BoxFit.cover)), if (item.allImages.length > 1) Positioned(right: 3, bottom: 3, child: Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)), child: Text('${item.allImages.length}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800))))]) : Icon(_categoryIcon(item.categoryName), color: blue, size: 26)), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: navy)), const SizedBox(height: 3), Text(item.shop.isEmpty ? item.categoryName : item.shop, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))), const SizedBox(height: 8), Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4), decoration: BoxDecoration(color: statusBg(status), borderRadius: BorderRadius.circular(30)), child: Text(status, style: TextStyle(color: statusColor(status), fontSize: 10, fontWeight: FontWeight.w800))), const SizedBox(width: 7), Expanded(child: Text(label, style: TextStyle(fontSize: 11, color: statusColor(status), fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis))])])), const SizedBox(width: 6), const Icon(Icons.chevron_right, color: Color(0xFF94A3B8))]))));
  }
}

IconData _categoryIcon(String category) => switch (category) { 'Electronics' => Icons.devices_rounded, 'Appliances' => Icons.kitchen_rounded, 'Furniture' => Icons.chair_alt_rounded, _ => Icons.inventory_2_outlined };

class PurchaseFormScreen extends StatefulWidget {
  final Purchase? purchase;
  const PurchaseFormScreen({super.key, this.purchase});
  @override State<PurchaseFormScreen> createState() => _PurchaseFormScreenState();
}

class _PurchaseFormScreenState extends State<PurchaseFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController(); final _shop = TextEditingController(); final _price = TextEditingController(); final _months = TextEditingController(text: '12'); final _notes = TextEditingController();
  final _serial = TextEditingController(); final _coverage = TextEditingController(); final _hotline = TextEditingController();
  int _extendedMonths = 0; bool _extendedEnabled = false;
  String _durationUnit = 'months';
  TimeOfDay _expiryTime = const TimeOfDay(hour: 9, minute: 0);
  List<Map<String, Object?>> _categories = [];
  int? _categoryId; DateTime _purchaseDate = DateTime.now(); final List<String> _images = <String>[]; final List<String> _addedFiles = <String>[]; final List<String> _removedSaved = <String>[]; bool _notifyEnabled = true; bool _savedOk = false; bool _saving = false;
  bool get _editing => widget.purchase != null;
  DateTime get _expiryDate {
    final duration = int.tryParse(_months.text) ?? 0;
    DateTime baseExpiry;
    if (_durationUnit == 'days') {
      baseExpiry = _purchaseDate.add(Duration(days: duration));
    } else if (_durationUnit == 'weeks') {
      baseExpiry = _purchaseDate.add(Duration(days: duration * 7));
    } else {
      baseExpiry = addMonthsClamped(_purchaseDate, duration);
    }
    if (_extendedEnabled && _extendedMonths > 0) {
      baseExpiry = addMonthsClamped(baseExpiry, _extendedMonths);
    }
    return baseExpiry;
  }

  @override void initState() { super.initState(); final p = widget.purchase; if (p != null) { _name.text = p.name; _shop.text = p.shop; _price.text = p.price.toStringAsFixed(2); _months.text = p.warrantyDurationValue.toString(); _durationUnit = p.warrantyDurationUnit; _expiryTime = _parseTime(p.expiryTime); _notes.text = p.notes; _serial.text = p.serialNumber; _coverage.text = p.coveredScopes; _hotline.text = p.supportHotline; _extendedMonths = p.extendedWarrantyMonths; _extendedEnabled = p.extendedWarrantyMonths > 0; _purchaseDate = parseDbDate(p.purchaseDate); _images.addAll(p.allImages); _notifyEnabled = p.notifyEnabled; _categoryId = p.categoryId; } _loadCategories(); }
  Future<void> _loadCategories() async { final rows = await DatabaseHelper.instance.getCategories(); if (!mounted) return; setState(() { _categories = rows; _categoryId ??= rows.isNotEmpty ? rows.first['id'] as int : null; }); }
  @override void dispose() { _name.dispose(); _shop.dispose(); _price.dispose(); _months.dispose(); _notes.dispose(); _serial.dispose(); _coverage.dispose(); _hotline.dispose();
  if (!_savedOk) { for (final f in _addedFiles) { try { final file = File(f); if (file.existsSync()) file.deleteSync(); } catch (_) {} } }
  super.dispose(); }

  TimeOfDay _parseTime(String value) { final bits = value.split(':'); return bits.length == 2 ? TimeOfDay(hour: int.tryParse(bits[0]) ?? 9, minute: int.tryParse(bits[1]) ?? 0) : const TimeOfDay(hour: 9, minute: 0); }
  Future<void> _chooseExpiryTime() async { final picked = await showTimePicker(context: context, initialTime: _expiryTime); if (picked != null) setState(() => _expiryTime = picked); }
  Future<void> _chooseDate() async { final selected = await showDatePicker(context: context, initialDate: _purchaseDate, firstDate: DateTime(1990), lastDate: DateTime(2100)); if (selected != null) setState(() => _purchaseDate = selected); }
  Future<void> _pickReceipt() async {
    try {
      final picked = await ImagePicker().pickMultiImage(imageQuality: 85, maxWidth: 1800);
      if (picked.isEmpty) return;
      final saved = <String>[];
      for (final x in picked) { saved.add(await LocalDataService.instance.saveImageToReceipts(x.path)); }
      if (!mounted) { await LocalDataService.instance.deleteImageFiles(saved); return; }
      setState(() { _images.addAll(saved); _addedFiles.addAll(saved); });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not add photos: $e')));
    }
  }

  void _removeImage(int index) {
    final path = _images[index];
    setState(() => _images.removeAt(index));
    if (_addedFiles.remove(path)) { LocalDataService.instance.deleteImageFiles([path]); } else { _removedSaved.add(path); }
  }

  void _makeCover(int index) {
    if (index <= 0 || index >= _images.length) return;
    setState(() { final x = _images.removeAt(index); _images.insert(0, x); });
  }

  void _viewImages(int index) => Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoViewerScreen(paths: List<String>.of(_images), initialIndex: index)));

  Future<void> _scanReceipt() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera, imageQuality: 90, maxWidth: 2200,
      );
      if (picked == null) return;
      final target = await LocalDataService.instance.saveImageToReceipts(picked.path);
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      String text;
      try {
        final result = await recognizer.processImage(InputImage.fromFilePath(target));
        text = result.text;
      } finally {
        await recognizer.close();
      }
      final lines = text.split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final priceMatch = RegExp(r'(?:total|amount|price|rs\.?|pkr)?\s*[:=-]?\s*(\d{2,}(?:[,.]\d{1,2})?)', caseSensitive: false);
      String? detectedPrice;
      for (final line in lines.reversed) {
        final match = priceMatch.firstMatch(line);
        if (match != null) {
          final value = match.group(1)!.replaceAll(',', '');
          if (double.tryParse(value) != null) { detectedPrice = value; break; }
        }
      }
      if (!mounted) { await LocalDataService.instance.deleteImageFiles([target]); return; }
      setState(() {
        _images.add(target);
        _addedFiles.add(target);
        if (_name.text.trim().isEmpty && lines.isNotEmpty) {
          _name.text = lines.firstWhere((line) => line.length > 2 && !RegExp(r'^\d').hasMatch(line), orElse: () => '');
        }
        if (_shop.text.trim().isEmpty && lines.length > 1) _shop.text = lines[1];
        if (_price.text.trim().isEmpty && detectedPrice != null) _price.text = detectedPrice;
        if (text.trim().isNotEmpty) {
          _notes.text = _notes.text.trim().isEmpty ? 'Scanned receipt text:\n$text' : '${_notes.text.trim()}\n\nScanned receipt text:\n$text';
        }
      });
      if (text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Photo saved, but no readable text was detected. Please enter details manually.')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Receipt scanned. Please review the detected fields before saving.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not scan receipt: $e')));
    }
  }

  Widget _photoStrip() {
    const border = Color(0xFFE2E8F0);
    if (_images.isEmpty) {
      return InkWell(onTap: _pickReceipt, borderRadius: BorderRadius.circular(14), child: Container(width: double.infinity, padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: border)), child: const Row(children: [Icon(Icons.add_a_photo_outlined, color: blue, size: 28), SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Attach receipt images', style: TextStyle(fontWeight: FontWeight.w700)), SizedBox(height: 3), Text('Choose one or more photos from your gallery', style: TextStyle(fontSize: 12, color: Color(0xFF64748B)))])), Icon(Icons.chevron_right, color: Color(0xFF64748B))])));
    }
    return Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: border)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(height: 92, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: _images.length + 1, separatorBuilder: (_, __) => const SizedBox(width: 8), itemBuilder: (ctx, i) {
        if (i == _images.length) {
          return InkWell(onTap: _pickReceipt, borderRadius: BorderRadius.circular(10), child: Container(width: 92, height: 92, decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(10), border: Border.all(color: border)), child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.add_photo_alternate_outlined, color: blue), SizedBox(height: 4), Text('Add more', style: TextStyle(fontSize: 11, color: blue, fontWeight: FontWeight.w700))])));
        }
        return _thumb(i);
      })),
      const SizedBox(height: 8),
      const Text('Tap a photo to view it. The first photo is the cover.', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
    ]));
  }

  Widget _thumb(int i) {
    final path = _images[i];
    final exists = File(path).existsSync();
    return SizedBox(width: 92, height: 92, child: Stack(children: [
      Positioned.fill(child: GestureDetector(onTap: () => _viewImages(i), child: ClipRRect(borderRadius: BorderRadius.circular(10), child: exists ? Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Color(0xFF94A3B8))) : Container(color: const Color(0xFFF1F5F9), child: const Icon(Icons.broken_image_outlined, color: Color(0xFF94A3B8)))))),
      Positioned(top: 2, right: 2, child: InkWell(onTap: () => _removeImage(i), child: const CircleAvatar(radius: 11, backgroundColor: Colors.black54, child: Icon(Icons.close, size: 14, color: Colors.white)))),
      Positioned(left: 4, bottom: 4, child: i == 0
          ? Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: blue, borderRadius: BorderRadius.circular(8)), child: const Text('Cover', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)))
          : InkWell(onTap: () => _makeCover(i), child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)), child: const Text('Set cover', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700))))),
    ]));
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _categoryId == null) return;
    setState(() => _saving = true);
    final categories = _categories.where((c) => c['id'] == _categoryId).toList();
    final purchase = Purchase(id: widget.purchase?.id, name: _name.text.trim(), categoryId: _categoryId!, categoryName: categories.isEmpty ? 'Other' : categories.first['name'] as String, shop: _shop.text.trim(), price: double.tryParse(_price.text.trim()) ?? 0, purchaseDate: dateToDb(_purchaseDate), warrantyMonths: _durationUnit == 'months' ? int.parse(_months.text) : ((_durationUnit == 'weeks' ? int.parse(_months.text) * 7 : int.parse(_months.text)) / 30).ceil(), warrantyDurationValue: int.parse(_months.text), warrantyDurationUnit: _durationUnit, expiryTime: '${_expiryTime.hour.toString().padLeft(2, '0')}:${_expiryTime.minute.toString().padLeft(2, '0')}', expiryDate: dateToDb(_expiryDate), receiptPath: _images.isEmpty ? '' : _images.first, imagePaths: List<String>.of(_images), notifyEnabled: _notifyEnabled, notes: _notes.text.trim(), createdAt: widget.purchase?.createdAt ?? DateTime.now().toIso8601String(), extendedWarrantyMonths: _extendedEnabled ? _extendedMonths : 0, serialNumber: _serial.text.trim(), coveredScopes: _coverage.text.trim(), supportHotline: _hotline.text.trim());
    try { if (_editing) { await DatabaseHelper.instance.updatePurchase(purchase); } else { await DatabaseHelper.instance.insertPurchase(purchase); } _savedOk = true; await LocalDataService.instance.deleteImageFiles(_removedSaved); try { await ExpiryNotificationService.instance.rescheduleAll(await DatabaseHelper.instance.getPurchases()); } catch (_) { /* The purchase is saved even if reminders cannot be scheduled. */ } if (!mounted) return; Navigator.pop(context, true); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save purchase: $e'))); }
    finally { if (mounted) setState(() => _saving = false); }
  }

  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(_editing ? 'Edit Purchase' : 'Add Purchase', style: const TextStyle(fontWeight: FontWeight.w800)), leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context))), body: Form(key: _formKey, child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [const Text('Product information', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: navy)), const SizedBox(height: 4), const Text('Keep the details and receipt in one safe place.', style: TextStyle(color: Color(0xFF64748B))), const SizedBox(height: 20), _fieldLabel('Item name *'), TextFormField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'e.g. Wireless headphones'), validator: (v) => v == null || v.trim().isEmpty ? 'Enter an item name' : null), const SizedBox(height: 14), _fieldLabel('Category *'), DropdownButtonFormField<int>(initialValue: _categoryId, decoration: const InputDecoration(), items: _categories.map((c) => DropdownMenuItem<int>(value: c['id'] as int, child: Text(c['name'] as String))).toList(), onChanged: (v) => setState(() => _categoryId = v)), const SizedBox(height: 14), _fieldLabel('Shop / seller'), TextFormField(controller: _shop, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'Where did you buy it?')), const SizedBox(height: 14), _fieldLabel('Purchase price'), TextFormField(controller: _price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(hintText: '0.00', prefixText: 'Rs. '), validator: (v) => v != null && v.trim().isNotEmpty && (double.tryParse(v) == null || double.parse(v) < 0) ? 'Enter a valid price' : null), const SizedBox(height: 14), _fieldLabel('Purchase date *'), OutlinedButton.icon(onPressed: _chooseDate, icon: const Icon(Icons.calendar_month_outlined), label: Text(prettyDate(dateToDb(_purchaseDate))), style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16), foregroundColor: navy, side: const BorderSide(color: Color(0xFFE2E8F0)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))), const SizedBox(height: 14), _fieldLabel('Warranty duration *'), Row(children: [Expanded(child: TextFormField(controller: _months, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'e.g. 12'), onChanged: (_) => setState(() {}), validator: (v) => v == null || int.tryParse(v) == null || int.parse(v) < 0 ? 'Enter 0 or more' : null)), const SizedBox(width: 10), Expanded(child: DropdownButtonFormField<String>(initialValue: _durationUnit, decoration: const InputDecoration(), items: const [DropdownMenuItem(value: 'days', child: Text('Days')), DropdownMenuItem(value: 'weeks', child: Text('Weeks')), DropdownMenuItem(value: 'months', child: Text('Months'))], onChanged: (v) => setState(() => _durationUnit = v ?? 'months')))]), const SizedBox(height: 10), Wrap(spacing: 8, children: [1, 7, 14, 30, 90, 12].map((n) => ActionChip(label: Text('$n ${_durationUnit == 'days' ? 'd' : _durationUnit == 'weeks' ? 'wk' : 'mo'}'), onPressed: () { _months.text = '$n'; setState(() {}); })).toList()), const SizedBox(height: 10), Row(children: [const Expanded(child: Text('Extended warranty', style: TextStyle(fontWeight: FontWeight.w700, color: navy))), Switch(value: _extendedEnabled, onChanged: (v) => setState(() { _extendedEnabled = v; if (v && _extendedMonths == 0) _extendedMonths = 12; }))]), if (_extendedEnabled) Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Additional $_extendedMonths months'), Slider(value: _extendedMonths.toDouble(), min: 1, max: 60, divisions: 59, label: '$_extendedMonths months', onChanged: (v) => setState(() => _extendedMonths = v.round())), const SizedBox(height: 6)]), Container(padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(12)), child: Row(children: [const Icon(Icons.event_available_outlined, color: blue), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Calculated expiry date & time', style: TextStyle(fontSize: 12, color: Color(0xFF475569))), Text('${prettyDate(dateToDb(_expiryDate))} • ${_expiryTime.format(context)}', style: const TextStyle(fontWeight: FontWeight.w800, color: navy))]))])), const SizedBox(height: 8), OutlinedButton.icon(onPressed: _chooseExpiryTime, icon: const Icon(Icons.schedule), label: Text('Expiry time: ${_expiryTime.format(context)}')), const SizedBox(height: 6), Row(children: [const Expanded(child: Text('Remind me before this expires', style: TextStyle(fontWeight: FontWeight.w700, color: navy))), Switch(value: _notifyEnabled, onChanged: (v) => setState(() => _notifyEnabled = v))]), const SizedBox(height: 8), _fieldLabel(_images.length > 1 ? 'Receipt photos & scanner (${_images.length})' : 'Receipt photo & scanner'), Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _pickReceipt, icon: const Icon(Icons.photo_library_outlined), label: const Text('Gallery'))), const SizedBox(width: 10), Expanded(child: FilledButton.icon(onPressed: _scanReceipt, icon: const Icon(Icons.document_scanner_outlined), label: const Text('Scan receipt')))]), const SizedBox(height: 8), _photoStrip(), const SizedBox(height: 14), _fieldLabel('Serial number'), TextFormField(controller: _serial, decoration: const InputDecoration(hintText: 'Serial / IMEI / model number')), const SizedBox(height: 14), _fieldLabel('What is covered?'), TextFormField(controller: _coverage, minLines: 2, maxLines: 3, decoration: const InputDecoration(hintText: 'Parts, labour, accidental damage...')), const SizedBox(height: 14), _fieldLabel('Support hotline'), TextFormField(controller: _hotline, keyboardType: TextInputType.phone, decoration: const InputDecoration(hintText: 'Manufacturer support phone')), const SizedBox(height: 14), _fieldLabel('Notes'), TextFormField(controller: _notes, minLines: 3, maxLines: 5, decoration: const InputDecoration(hintText: 'Serial number, warranty terms, or other notes...')), const SizedBox(height: 24), SizedBox(height: 52, child: FilledButton.icon(onPressed: _saving ? null : _save, icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check), label: Text(_saving ? 'Saving...' : _editing ? 'Save changes' : 'Save purchase'), style: FilledButton.styleFrom(backgroundColor: blue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)))))])));
}

Widget _fieldLabel(String text) => Padding(padding: const EdgeInsets.only(bottom: 7), child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: navy)));

class PurchaseDetailsScreen extends StatefulWidget {
  final int purchaseId;
  const PurchaseDetailsScreen({super.key, required this.purchaseId});
  @override State<PurchaseDetailsScreen> createState() => _PurchaseDetailsScreenState();
}

class _PurchaseDetailsScreenState extends State<PurchaseDetailsScreen> {
  Purchase? _item; bool _loading = true; bool _changed = false;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { final item = await DatabaseHelper.instance.getPurchase(widget.purchaseId); if (mounted) setState(() { _item = item; _loading = false; }); }
  Future<void> _edit() async { final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PurchaseFormScreen(purchase: _item))); if (saved == true) { _changed = true; _load(); } }
  Future<void> _copySerial(String serial) async { await Clipboard.setData(ClipboardData(text: serial)); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Serial number copied'))); }
  Future<void> _exportPdf(Purchase item) async {
    final doc = pw.Document();
    doc.addPage(pw.Page(build: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [pw.Text('WarrantyVault - Purchase Record', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)), pw.SizedBox(height: 18), for (final row in <String, String>{'Item': item.name, 'Category': item.categoryName, 'Seller': item.shop, 'Price': 'Rs. ${item.price.toStringAsFixed(2)}', 'Purchase date': prettyDate(item.purchaseDate), 'Warranty': '${item.warrantyDurationValue} ${item.warrantyDurationUnit} + ${item.extendedWarrantyMonths} extended months', 'Expiry date': prettyDate(item.expiryDate), 'Serial number': item.serialNumber, 'Coverage': item.coveredScopes, 'Support': item.supportHotline, 'Notes': item.notes}.entries) pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 5), child: pw.Text('${row.key}: ${row.value}'))])));
    for (final path in item.allImages) {
      try {
        final image = pw.MemoryImage(await File(path).readAsBytes());
        doc.addPage(pw.Page(build: (ctx) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain))));
      } catch (_) { /* Skip a photo the PDF library cannot read (for example a missing or unsupported file). */ }
    }
    await Printing.sharePdf(bytes: await doc.save(), filename: 'WarrantyVault_${item.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.pdf');
  }
  void _openPhotos(List<String> paths, int index) => Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoViewerScreen(paths: paths, initialIndex: index)));
  Future<void> _delete() async {
    final item = _item; if (item == null) return;
    final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Delete purchase?'), content: Text('“${item.name}” will be removed from your vault. This action cannot be undone.'), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)), child: const Text('Delete'))]));
    if (yes != true) return;
    await DatabaseHelper.instance.deletePurchase(item.id!);
    await LocalDataService.instance.deleteImageFiles(item.allImages);
    if (mounted) Navigator.pop(context, true);
  }
  @override
  Widget build(BuildContext context) {
    final item = _item;
    if (_loading) return Scaffold(appBar: AppBar(title: const Text('Purchase Details')), body: const Center(child: CircularProgressIndicator()));
    if (item == null) return Scaffold(appBar: AppBar(title: const Text('Purchase Details')), body: const Center(child: Text('Purchase not found')));
    final status = warrantyStatus(item.expiryDate);
    final photos = item.allImages.where((e) => File(e).existsSync()).toList();
    return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) { if (!didPop) Navigator.pop(context, _changed); },
        child: Scaffold(
          appBar: AppBar(title: const Text('Purchase Details', style: TextStyle(fontWeight: FontWeight.w800)), actions: [IconButton(onPressed: _edit, icon: const Icon(Icons.edit_outlined), tooltip: 'Edit')]),
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
            Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE2E8F0))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 62, height: 62, decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(17)), child: Icon(_categoryIcon(item.categoryName), color: blue, size: 32)),
              const SizedBox(height: 16), Text(item.name, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800, color: navy)), const SizedBox(height: 7),
              Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: statusBg(status), borderRadius: BorderRadius.circular(30)), child: Text(status, style: TextStyle(color: statusColor(status), fontWeight: FontWeight.w800, fontSize: 12))), const SizedBox(width: 8), Expanded(child: Text(warrantyTimeLeft(item.expiryDate), style: const TextStyle(color: Color(0xFF64748B), fontSize: 12)))]),
              const SizedBox(height: 18), const Divider(), _detailRow('Category', item.categoryName), _detailRow('Shop / seller', item.shop.isEmpty ? 'Not provided' : item.shop), _detailRow('Purchase price', 'Rs. ${item.price.toStringAsFixed(2)}'), _detailRow('Purchase date', prettyDate(item.purchaseDate)), _detailRow('Warranty duration', '${item.warrantyDurationValue} ${item.warrantyDurationUnit}'), if (item.extendedWarrantyMonths > 0) _detailRow('Extended warranty', '${item.extendedWarrantyMonths} months'), _detailRow('Expiry date & time', '${prettyDate(item.expiryDate)} • ${item.expiryTime}'), _detailRow('Reminders', item.notifyEnabled ? 'On' : 'Off'), if (item.serialNumber.isNotEmpty) Row(children: [Expanded(child: _detailRow('Serial number', item.serialNumber)), IconButton(tooltip: 'Copy serial', onPressed: () => _copySerial(item.serialNumber), icon: const Icon(Icons.copy, color: blue))]), if (item.coveredScopes.isNotEmpty) _detailRow('Coverage', item.coveredScopes), if (item.supportHotline.isNotEmpty) _detailRow('Support hotline', item.supportHotline), if (item.notes.isNotEmpty) _detailRow('Notes', item.notes), const SizedBox(height: 8), ClipRRect(borderRadius: BorderRadius.circular(8), child: LinearProgressIndicator(value: (() { final start = parseDbDate(item.purchaseDate); final end = parseDbDate(item.expiryDate); final total = end.difference(start).inDays; if (total <= 0) return 0.0; final remaining = daysUntilExpiry(item.expiryDate); return (1 - (remaining / total)).clamp(0.0, 1.0); })(), minHeight: 8)), const SizedBox(height: 5), const Text('Warranty coverage timeline', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
            ])),
            if (photos.isNotEmpty) ...[const SizedBox(height: 16), Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE2E8F0))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(photos.length == 1 ? 'Receipt' : 'Receipts & photos (${photos.length})', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)), const SizedBox(height: 12), if (photos.length == 1) GestureDetector(onTap: () => _openPhotos(photos, 0), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(photos.first), width: double.infinity, fit: BoxFit.contain))) else Wrap(spacing: 8, runSpacing: 8, children: [for (var i = 0; i < photos.length; i++) GestureDetector(onTap: () => _openPhotos(photos, i), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(photos[i]), width: 96, height: 96, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(width: 96, height: 96, color: const Color(0xFFF1F5F9), child: const Icon(Icons.broken_image_outlined, color: Color(0xFF94A3B8))))))])]))],
            const SizedBox(height: 18), OutlinedButton.icon(onPressed: () => _exportPdf(item), icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('Export / share PDF'), style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48))), const SizedBox(height: 9), FilledButton.icon(onPressed: _edit, icon: const Icon(Icons.edit_outlined), label: const Text('Edit purchase'), style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50))), const SizedBox(height: 9),
            OutlinedButton.icon(onPressed: _delete, icon: const Icon(Icons.delete_outline, color: Color(0xFFDC2626)), label: const Text('Delete purchase', style: TextStyle(color: Color(0xFFDC2626))), style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50), side: const BorderSide(color: Color(0xFFFECACA)))),
          ]),
        ));
  }
}

Widget _detailRow(String label, String value) => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: Text(label, style: const TextStyle(color: Color(0xFF64748B), fontSize: 13))), const SizedBox(width: 12), Expanded(flex: 2, child: Text(value, textAlign: TextAlign.end, style: const TextStyle(color: navy, fontWeight: FontWeight.w700, fontSize: 13)))]));

class PhotoViewerScreen extends StatefulWidget {
  final List<String> paths;
  final int initialIndex;
  const PhotoViewerScreen({super.key, required this.paths, this.initialIndex = 0});
  @override State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  @override void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text('${_index + 1} of ${widget.paths.length}', style: const TextStyle(fontWeight: FontWeight.w700))),
    body: PageView.builder(
      controller: _controller,
      itemCount: widget.paths.length,
      onPageChanged: (i) => setState(() => _index = i),
      itemBuilder: (ctx, i) {
        final file = File(widget.paths[i]);
        return InteractiveViewer(child: Center(child: file.existsSync() ? Image.file(file, fit: BoxFit.contain) : const Text('This photo file is missing.', style: TextStyle(color: Colors.white))));
      },
    ),
  );
}

// ---------------------------------------------------------------- shared helpers

void _toast(BuildContext context, String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
String _errText(Object e) => e is BackupException ? e.message : e.toString().replaceFirst('Exception: ', '');

Future<bool> _confirm(BuildContext context, String title, String body, String action, {bool danger = false}) async {
  final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
    title: Text(title),
    content: Text(body),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(ctx, true), style: danger ? FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)) : null, child: Text(action)),
    ],
  ));
  return yes == true;
}

Widget _panel({required Widget child}) => Container(
  padding: const EdgeInsets.all(16),
  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE2E8F0))),
  child: child,
);

Widget _panelTitle(String title, [String? subtitle]) => Padding(
  padding: const EdgeInsets.only(bottom: 10),
  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: navy)),
    if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 3), child: Text(subtitle, style: const TextStyle(fontSize: 12, height: 1.35, color: Color(0xFF64748B)))),
  ]),
);

Widget _switchRow(IconData icon, String title, String subtitle, bool value, ValueChanged<bool>? onChanged) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: Row(children: [
    Icon(icon, color: blue, size: 22),
    const SizedBox(width: 12),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: navy)),
      Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
    ])),
    Switch(value: value, onChanged: onChanged),
  ]),
);

Widget _chipRow<T>({required List<T> values, required T selected, required String Function(T) label, required ValueChanged<T> onSelected}) => Wrap(
  spacing: 8,
  runSpacing: 8,
  children: values.map((v) => ChoiceChip(
    label: Text(label(v)),
    selected: v == selected,
    onSelected: (_) => onSelected(v),
    selectedColor: blue,
    labelStyle: TextStyle(color: v == selected ? Colors.white : const Color(0xFF475569), fontWeight: FontWeight.w600),
    backgroundColor: Colors.white,
    side: BorderSide(color: v == selected ? blue : const Color(0xFFE2E8F0)),
  )).toList(),
);

Widget _infoRow(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: Row(children: [
    Expanded(child: Text(label, style: const TextStyle(color: Color(0xFF64748B), fontSize: 13))),
    Text(value, style: const TextStyle(color: navy, fontWeight: FontWeight.w700, fontSize: 13)),
  ]),
);

String _dateTimeLabel(DateTime value) => DateFormat('dd MMM yyyy, hh:mm a').format(value.toLocal());

// ---------------------------------------------------------------- settings

class SettingsScreen extends StatefulWidget {
  /// Called after something changed that the other tabs must reload (restore, reminder settings).
  final VoidCallback onDataChanged;
  const SettingsScreen({super.key, required this.onDataChanged});
  @override State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  bool _biometricEnabled = false;
  final LocalAuthentication _auth = LocalAuthentication();
  @override void initState() { super.initState(); SharedPreferences.getInstance().then((p) { if (mounted) setState(() => _biometricEnabled = p.getBool('biometric_lock_enabled') ?? false); }); }
  Future<void> _setBiometric(bool enabled) async {
    if (enabled) { final supported = await _auth.isDeviceSupported() || await _auth.canCheckBiometrics; if (!supported) throw Exception('Device authentication is not available on this device.'); final ok = await _auth.authenticate(localizedReason: 'Confirm biometric lock for WarrantyVault', options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true)); if (!ok) throw Exception('Authentication cancelled; setting was not changed.'); } else if (_biometricEnabled) { final ok = await _auth.authenticate(localizedReason: 'Confirm disabling WarrantyVault lock', options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true)); if (!ok) throw Exception('Authentication cancelled; lock remains enabled.'); }
    final prefs = await SharedPreferences.getInstance(); await prefs.setBool('biometric_lock_enabled', enabled); if (mounted) setState(() => _biometricEnabled = enabled);
  }
  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final message = await action();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not complete action: ${e.toString().replaceFirst('Exception: ', '')}')));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<bool?> _open(Widget screen) async {
    final result = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() {});
    return result;
  }

  Future<void> _openRestore() async {
    final restored = await _open(const RestoreScreen());
    if (restored == true && mounted) widget.onDataChanged();
  }

  Future<void> _openNotifications() async {
    final saved = await _open(const NotificationSettingsScreen());
    if (saved == true && mounted) widget.onDataChanged();
  }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings & Backup', style: TextStyle(fontWeight: FontWeight.w800))),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE2E8F0))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.cloud_done_outlined, color: blue, size: 34), const SizedBox(height: 12), const Text('Keep your vault safe', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: navy)), const SizedBox(height: 6), const Text('Back up your warranty database and receipt photos to a WarrantyVault backup file in your Google Drive.', style: TextStyle(height: 1.45, color: Color(0xFF64748B))), if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator())])),
      const SizedBox(height: 16),
      _SettingsTile(icon: Icons.cloud_upload_outlined, title: 'Backup to Google Drive', subtitle: 'Save your database and receipt photos', onTap: _busy ? () {} : () => _open(const BackupSettingsScreen())),
      const SizedBox(height: 10),
      _SettingsTile(icon: Icons.cloud_download_outlined, title: 'Restore from Google Drive', subtitle: 'Replace this device vault with the saved backup', onTap: _busy ? () {} : _openRestore),
      const SizedBox(height: 10),
      _SettingsTile(icon: Icons.notifications_active_outlined, title: 'Expiry notifications', subtitle: AppSettings.instance.notifications.summary, onTap: _busy ? () {} : _openNotifications),
      const SizedBox(height: 10),
      Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFE2E8F0))), child: Row(children: [const Icon(Icons.fingerprint, color: blue, size: 24), const SizedBox(width: 12), const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Biometric app lock', style: TextStyle(fontWeight: FontWeight.w700, color: navy)), Text('Require authentication when opening the app', style: TextStyle(fontSize: 12, color: Color(0xFF64748B)))])), Switch(value: _biometricEnabled, onChanged: _busy ? null : (v) => _run(() async { await _setBiometric(v); return v ? 'App lock enabled.' : 'App lock disabled.'; }))])),
      const SizedBox(height: 10),
      _SettingsTile(icon: Icons.table_view_outlined, title: 'Export CSV', subtitle: 'Share a spreadsheet of all warranty records', onTap: _busy ? () {} : () => _open(const ExportCsvScreen())),
      const SizedBox(height: 10),
      _SettingsTile(icon: Icons.archive_outlined, title: 'Export ZIP backup', subtitle: 'Package database and receipt photos for sharing', onTap: _busy ? () {} : () => _open(const ExportZipScreen())),
      const SizedBox(height: 10),
      _SettingsTile(icon: Icons.storage_outlined, title: 'Local storage', subtitle: 'View database and receipt file sizes', onTap: _busy ? () {} : () => _open(const StorageScreen())),
      const SizedBox(height: 26), const Center(child: Text('WarrantyVault • Offline-first', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12))),
    ]),
  );
}

class _SettingsTile extends StatelessWidget {
  final IconData icon; final String title; final String subtitle; final VoidCallback onTap;
  const _SettingsTile({required this.icon, required this.title, required this.subtitle, required this.onTap});
  @override Widget build(BuildContext context) => Card(elevation: 0, color: Colors.white, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFFE2E8F0))), child: ListTile(onTap: onTap, contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), leading: Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: blue)), title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, color: navy)), subtitle: Padding(padding: const EdgeInsets.only(top: 4), child: Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)))), trailing: const Icon(Icons.chevron_right, color: Color(0xFF94A3B8))));
}

// ---------------------------------------------------------------- backup to Drive

class BackupSettingsScreen extends StatefulWidget {
  const BackupSettingsScreen({super.key});
  @override State<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends State<BackupSettingsScreen> {
  final GoogleDriveBackupService _drive = GoogleDriveBackupService.instance;
  BackupPrefs _prefs = AppSettings.instance.backup;
  String? _email;
  bool _checking = true;
  bool _busy = false;

  @override void initState() { super.initState(); _refreshAccount(); }

  Future<void> _refreshAccount() async {
    final email = await _drive.signedInEmail();
    if (!mounted) return;
    setState(() { _email = email; _checking = false; });
  }

  Future<void> _guarded(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final message = await action();
      if (message != null && mounted) _toast(context, message);
    } catch (e) {
      if (mounted) _toast(context, _errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(BackupPrefs value) async {
    setState(() => _prefs = value);
    await AppSettings.instance.saveBackup(value);
  }

  @override
  Widget build(BuildContext context) {
    final last = _prefs.lastBackup;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup to Google Drive', style: TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _panelTitle('Google account', 'Backups are stored in the Google Drive of this account. WarrantyVault can only see files it created itself.'),
          Row(children: [
            const Icon(Icons.account_circle_outlined, color: blue, size: 34),
            const SizedBox(width: 12),
            Expanded(child: Text(_checking ? 'Checking…' : (_email ?? 'Not signed in'), style: const TextStyle(fontWeight: FontWeight.w700, color: navy))),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (_email == null) FilledButton.icon(onPressed: _busy ? null : () => _guarded(() async { final e = await _drive.signIn(); if (mounted) setState(() => _email = e); return e == null ? 'Google sign-in was cancelled.' : 'Signed in as $e.'; }), icon: const Icon(Icons.login), label: const Text('Sign in with Google')),
            if (_email != null) OutlinedButton.icon(onPressed: _busy ? null : () => _guarded(() async { final e = await _drive.switchAccount(); if (mounted) setState(() => _email = e); return e == null ? 'Account was not changed.' : 'Signed in as $e.'; }), icon: const Icon(Icons.swap_horiz), label: const Text('Switch account')),
            if (_email != null) OutlinedButton.icon(onPressed: _busy ? null : () => _guarded(() async { await _drive.signOut(); if (mounted) setState(() => _email = null); return 'Signed out of Google.'; }), icon: const Icon(Icons.logout), label: const Text('Sign out')),
          ]),
        ])),
        const SizedBox(height: 14),
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _panelTitle('Backup options'),
          _switchRow(Icons.photo_library_outlined, 'Include receipt photos', 'Turn off for a smaller, faster backup', _prefs.includePhotos, _busy ? null : (v) => _save(_prefs.copyWith(includePhotos: v))),
          const Divider(height: 22),
          const Text('Keep the latest backups', style: TextStyle(fontWeight: FontWeight.w700, color: navy)),
          const SizedBox(height: 4),
          const Text('Older backups are removed from Drive automatically.', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
          const SizedBox(height: 10),
          _chipRow<int>(values: BackupPrefs.keepChoices, selected: _prefs.keepCount, label: (v) => '$v', onSelected: (v) => _save(_prefs.copyWith(keepCount: v))),
          const Divider(height: 22),
          const Text('Automatic backup', style: TextStyle(fontWeight: FontWeight.w700, color: navy)),
          const SizedBox(height: 4),
          const Text('Runs quietly when you open the app and a backup is due. You must be signed in.', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
          const SizedBox(height: 10),
          _chipRow<String>(values: BackupPrefs.autoChoices, selected: _prefs.autoFrequency, label: (v) => '${v[0].toUpperCase()}${v.substring(1)}', onSelected: (v) => _save(_prefs.copyWith(autoFrequency: v))),
        ])),
        const SizedBox(height: 14),
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _infoRow('Last backup from this device', last == null ? 'Never' : _dateTimeLabel(last)),
          const SizedBox(height: 10),
          SizedBox(height: 50, child: FilledButton.icon(
            onPressed: _busy ? null : () => _guarded(() async { final message = await _drive.backupToDrive(); await _refreshAccount(); if (mounted) setState(() => _prefs = AppSettings.instance.backup); return message; }),
            icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.cloud_upload_outlined),
            label: Text(_busy ? 'Working…' : 'Back up now'),
          )),
        ])),
      ]),
    );
  }
}

// ---------------------------------------------------------------- restore from Drive

class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key});
  @override State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  List<DriveBackupInfo> _backups = const [];
  String? _error;
  bool _loading = true;
  bool _working = false;

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final list = await GoogleDriveBackupService.instance.listBackups();
      if (!mounted) return;
      setState(() { _backups = list; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = _errText(e); _loading = false; });
    }
  }

  Future<void> _restore(DriveBackupInfo backup) async {
    final when = backup.modified == null ? backup.name : _dateTimeLabel(backup.modified!);
    final ok = await _confirm(context, 'Restore this backup?', 'Your current vault on this device will be replaced with the backup from $when. A safety copy is kept until the restore succeeds.', 'Restore');
    if (!ok || !mounted) return;
    setState(() => _working = true);
    try {
      final message = await GoogleDriveBackupService.instance.restoreFromDrive(fileId: backup.id);
      if (!mounted) return;
      _toast(context, message);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _working = false);
      _toast(context, _errText(e));
    }
  }

  Future<void> _delete(DriveBackupInfo backup) async {
    final ok = await _confirm(context, 'Delete this backup?', '“${backup.name}” will be removed from your Google Drive. This cannot be undone.', 'Delete', danger: true);
    if (!ok || !mounted) return;
    try {
      await GoogleDriveBackupService.instance.deleteBackup(backup.id);
      if (!mounted) return;
      _toast(context, 'Backup deleted.');
      await _load();
    } catch (e) {
      if (mounted) _toast(context, _errText(e));
    }
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.cloud_off_outlined, color: Color(0xFFDC2626), size: 34),
          const SizedBox(height: 10),
          const Text('Could not load your backups', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: navy)),
          const SizedBox(height: 6),
          Text(_error!, style: const TextStyle(height: 1.4, color: Color(0xFF475569))),
          const SizedBox(height: 14),
          FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Try again')),
        ])),
      ]);
    }
    if (_backups.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        _panel(child: const Column(children: [
          Icon(Icons.cloud_queue_outlined, color: Color(0xFF94A3B8), size: 44),
          SizedBox(height: 10),
          Text('No backups found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: navy)),
          SizedBox(height: 6),
          Text('No WarrantyVault backup exists in the signed-in Google account yet. Make one from Backup to Google Drive.', textAlign: TextAlign.center, style: TextStyle(height: 1.4, color: Color(0xFF64748B))),
        ])),
      ]);
    }
    return RefreshIndicator(onRefresh: _load, child: ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _backups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) {
        final b = _backups[i];
        return Card(elevation: 0, color: Colors.white, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFFE2E8F0))), child: ListTile(
          onTap: _working ? null : () => _restore(b),
          leading: Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(13)), child: const Icon(Icons.cloud_download_outlined, color: blue)),
          title: Text(b.modified == null ? b.name : _dateTimeLabel(b.modified!), style: const TextStyle(fontWeight: FontWeight.w800, color: navy)),
          subtitle: Text('${i == 0 ? 'Latest • ' : ''}${formatBytes(b.sizeBytes)}', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
          trailing: IconButton(tooltip: 'Delete backup', onPressed: _working ? null : () => _delete(b), icon: const Icon(Icons.delete_outline, color: Color(0xFFDC2626))),
        ));
      },
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Restore from Google Drive', style: TextStyle(fontWeight: FontWeight.w800)), actions: [IconButton(tooltip: 'Refresh', onPressed: _loading || _working ? null : _load, icon: const Icon(Icons.refresh))]),
    body: Stack(children: [
      _body(),
      if (_working) Positioned.fill(child: Container(color: Colors.white70, child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Restoring your vault…', style: TextStyle(fontWeight: FontWeight.w700, color: navy))])))),
    ]),
  );
}

// ---------------------------------------------------------------- expiry notifications

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});
  @override State<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  NotificationPrefs _p = AppSettings.instance.notifications;
  bool _saving = false;

  void _toggleLead(int days) {
    final current = List<int>.of(_p.leadDays);
    if (current.contains(days)) {
      current.remove(days);
    } else {
      if (current.length >= NotificationPrefs.maxLeadTimes) {
        _toast(context, 'You can choose up to ${NotificationPrefs.maxLeadTimes} reminders.');
        return;
      }
      current.add(days);
    }
    setState(() => _p = _p.copyWith(leadDays: current));
  }

  Future<void> _addCustom() async {
    final controller = TextEditingController();
    final value = await showDialog<int>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Custom reminder'),
      content: TextField(controller: controller, keyboardType: TextInputType.number, autofocus: true, decoration: const InputDecoration(labelText: 'Days before expiry', hintText: '1 to 365')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () { final n = int.tryParse(controller.text.trim()); if (n == null || n < 1 || n > 365) return; Navigator.pop(ctx, n); }, child: const Text('Add')),
      ],
    ));
    if (value == null || !mounted) return;
    if (!_p.leadDays.contains(value)) _toggleLead(value);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay(hour: _p.hour, minute: _p.minute));
    if (picked != null) setState(() => _p = _p.copyWith(hour: picked.hour, minute: picked.minute));
  }

  Future<void> _sendTest() async {
    try {
      await ExpiryNotificationService.instance.showTestNotification(prefs: _p);
      if (mounted) _toast(context, 'Test reminder sent. If you do not see it, allow notifications for WarrantyVault in your phone settings.');
    } catch (e) {
      if (mounted) _toast(context, 'Could not show a notification: ${_errText(e)}');
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await AppSettings.instance.saveNotifications(_p);
      String message = 'Reminder settings saved.';
      try {
        await ExpiryNotificationService.instance.rescheduleAll(await DatabaseHelper.instance.getPurchases());
      } catch (e) {
        message = 'Settings saved, but reminders could not be scheduled: ${_errText(e)}';
      }
      if (!mounted) return;
      _toast(context, message);
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) { setState(() => _saving = false); _toast(context, 'Could not save settings: ${_errText(e)}'); }
    }
  }

  @override
  Widget build(BuildContext context) {
    final leadValues = <int>{...NotificationPrefs.presetLeadDays, ..._p.leadDays}.toList()..sort();
    final off = !_p.enabled;
    return Scaffold(
      appBar: AppBar(title: const Text('Expiry notifications', style: TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _switchRow(Icons.notifications_active_outlined, 'Warranty reminders', 'Turn all reminders on or off', _p.enabled, (v) => setState(() => _p = _p.copyWith(enabled: v))),
          const Divider(height: 22),
          Text(_p.summary, style: const TextStyle(color: Color(0xFF475569), height: 1.4)),
        ])),
        const SizedBox(height: 14),
        Opacity(opacity: off ? .45 : 1, child: IgnorePointer(ignoring: off, child: Column(children: [
          _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _panelTitle('Remind me before expiry', 'Pick up to ${NotificationPrefs.maxLeadTimes} reminders. Each one is sent that many days before the warranty ends.'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ...leadValues.map((d) => FilterChip(
                label: Text(d == 1 ? '1 day' : '$d days'),
                selected: _p.leadDays.contains(d),
                onSelected: (_) => _toggleLead(d),
                selectedColor: blue,
                checkmarkColor: Colors.white,
                labelStyle: TextStyle(color: _p.leadDays.contains(d) ? Colors.white : const Color(0xFF475569), fontWeight: FontWeight.w600),
                backgroundColor: Colors.white,
                side: BorderSide(color: _p.leadDays.contains(d) ? blue : const Color(0xFFE2E8F0)),
              )),
              ActionChip(avatar: const Icon(Icons.add, size: 16, color: blue), label: const Text('Custom'), onPressed: _addCustom, backgroundColor: Colors.white, side: const BorderSide(color: Color(0xFFE2E8F0))),
            ]),
            const SizedBox(height: 14),
            OutlinedButton.icon(onPressed: _pickTime, icon: const Icon(Icons.schedule), label: Text('Reminder time: ${formatClock(_p.hour, _p.minute)}')),
          ])),
          const SizedBox(height: 14),
          _panel(child: Column(children: [
            _switchRow(Icons.event_busy_outlined, 'Alert when it expires', 'At the expiry time set on each purchase', _p.notifyOnExpiry, (v) => setState(() => _p = _p.copyWith(notifyOnExpiry: v))),
            _switchRow(Icons.history_toggle_off, 'Catch-up alert', 'If a reminder time already passed, tell me once right away', _p.catchUp, (v) => setState(() => _p = _p.copyWith(catchUp: v))),
            _switchRow(Icons.volume_up_outlined, 'Sound', 'Play the notification sound', _p.sound, (v) => setState(() => _p = _p.copyWith(sound: v))),
            _switchRow(Icons.vibration, 'Vibration', 'Vibrate when a reminder arrives', _p.vibrate, (v) => setState(() => _p = _p.copyWith(vibrate: v))),
          ])),
          const SizedBox(height: 14),
          _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _panelTitle('“Expiring soon” window', 'Warranties ending within this many days are shown as Expiring Soon on your home screen.'),
            _chipRow<int>(values: <int>{...NotificationPrefs.soonWindowChoices, _p.expiringSoonDays}.toList()..sort(), selected: _p.expiringSoonDays, label: (v) => '$v days', onSelected: (v) => setState(() => _p = _p.copyWith(expiringSoonDays: v))),
          ])),
          const SizedBox(height: 14),
          OutlinedButton.icon(onPressed: _sendTest, icon: const Icon(Icons.notifications_none), label: const Text('Send a test notification'), style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48))),
        ]))),
        const SizedBox(height: 14),
        SizedBox(height: 52, child: FilledButton.icon(onPressed: _saving ? null : _save, icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check), label: Text(_saving ? 'Saving…' : 'Save settings'))),
      ]),
    );
  }
}

// ---------------------------------------------------------------- CSV export

class ExportCsvScreen extends StatefulWidget {
  const ExportCsvScreen({super.key});
  @override State<ExportCsvScreen> createState() => _ExportCsvScreenState();
}

class _ExportCsvScreenState extends State<ExportCsvScreen> {
  static const List<String> _statusChoices = ['All', 'Active', 'Expiring Soon', 'Expired'];
  late Set<String> _columns;
  late String _status;
  late String _category;
  late bool _bom;
  List<Purchase> _items = [];
  List<String> _categories = ['All'];
  bool _loading = true;
  bool _busy = false;

  @override void initState() {
    super.initState();
    final prefs = AppSettings.instance.export;
    // Out of the box the CSV keeps the same 12 columns as before.
    _columns = prefs.csvColumns.isEmpty ? allCsvColumnKeys.take(12).toSet() : prefs.csvColumns.toSet();
    _status = _statusChoices.contains(prefs.csvStatus) ? prefs.csvStatus : 'All';
    _category = prefs.csvCategory;
    _bom = prefs.csvBom;
    _load();
  }

  Future<void> _load() async {
    final items = await DatabaseHelper.instance.getPurchases();
    final cats = await DatabaseHelper.instance.getCategories();
    if (!mounted) return;
    final names = ['All', ...cats.map((c) => c['name'] as String)];
    setState(() { _items = items; _categories = names; if (!names.contains(_category)) _category = 'All'; _loading = false; });
  }

  List<Purchase> get _filtered => filterForExport(_items, status: _status, category: _category);

  Future<void> _export() async {
    if (_columns.isEmpty) { _toast(context, 'Choose at least one column.'); return; }
    final rows = _filtered;
    if (rows.isEmpty) { _toast(context, 'No records match these filters.'); return; }
    setState(() => _busy = true);
    try {
      final keys = allCsvColumnKeys.where(_columns.contains).toList();
      await AppSettings.instance.saveExport(AppSettings.instance.export.copyWith(csvColumns: keys, csvStatus: _status, csvCategory: _category, csvBom: _bom));
      final file = await LocalDataService.instance.writeCsvFile(buildCsv(rows, keys), bom: _bom);
      await Share.shareXFiles([XFile(file.path)], text: 'WarrantyVault CSV export');
      if (mounted) _toast(context, 'CSV export ready to share (${rows.length} ${rows.length == 1 ? 'record' : 'records'}).');
    } catch (e) {
      if (mounted) _toast(context, 'Could not export: ${_errText(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Scaffold(appBar: AppBar(title: const Text('Export CSV')), body: const Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('Export CSV', style: TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _panelTitle('Which records?', '${_filtered.length} of ${_items.length} records will be exported.'),
          const Text('Status', style: TextStyle(fontWeight: FontWeight.w700, color: navy)),
          const SizedBox(height: 8),
          _chipRow<String>(values: _statusChoices, selected: _status, label: (v) => v, onSelected: (v) => setState(() => _status = v)),
          const SizedBox(height: 14),
          const Text('Category', style: TextStyle(fontWeight: FontWeight.w700, color: navy)),
          const SizedBox(height: 8),
          _chipRow<String>(values: _categories, selected: _category, label: (v) => v, onSelected: (v) => setState(() => _category = v)),
        ])),
        const SizedBox(height: 14),
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _panelTitle('Columns', '${_columns.length} of ${csvColumnDefs.length} selected.'),
          Wrap(spacing: 8, children: [
            ActionChip(label: const Text('Select all'), onPressed: () => setState(() => _columns = allCsvColumnKeys.toSet())),
            ActionChip(label: const Text('Original 12'), onPressed: () => setState(() => _columns = allCsvColumnKeys.take(12).toSet())),
            ActionChip(label: const Text('Clear'), onPressed: () => setState(() => _columns = <String>{})),
          ]),
          ...csvColumnDefs.map((c) => CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(c.label, style: const TextStyle(fontSize: 14, color: navy)),
            value: _columns.contains(c.key),
            onChanged: (v) => setState(() { if (v == true) { _columns.add(c.key); } else { _columns.remove(c.key); } }),
          )),
        ])),
        const SizedBox(height: 14),
        _panel(child: _switchRow(Icons.translate, 'Excel-friendly encoding', 'Adds a UTF-8 marker so Excel shows all characters correctly', _bom, (v) => setState(() => _bom = v))),
        const SizedBox(height: 16),
        SizedBox(height: 52, child: FilledButton.icon(onPressed: _busy ? null : _export, icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.ios_share), label: Text(_busy ? 'Preparing…' : 'Export & share CSV'))),
      ]),
    );
  }
}

// ---------------------------------------------------------------- ZIP export

class ExportZipScreen extends StatefulWidget {
  const ExportZipScreen({super.key});
  @override State<ExportZipScreen> createState() => _ExportZipScreenState();
}

class _ExportZipScreenState extends State<ExportZipScreen> {
  late bool _photos;
  late bool _csv;
  StorageReport? _report;
  bool _busy = false;

  @override void initState() {
    super.initState();
    final prefs = AppSettings.instance.export;
    _photos = prefs.zipIncludePhotos;
    _csv = prefs.zipIncludeCsv;
    LocalDataService.instance.storageReport().then((r) { if (mounted) setState(() => _report = r); }).catchError((_) {});
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      await AppSettings.instance.saveExport(AppSettings.instance.export.copyWith(zipIncludePhotos: _photos, zipIncludeCsv: _csv));
      final file = await LocalDataService.instance.buildArchive(includePhotos: _photos, includeCsv: _csv, fileName: 'WarrantyVault_export.zip');
      await Share.shareXFiles([XFile(file.path)], text: 'WarrantyVault ZIP backup');
      if (mounted) _toast(context, 'ZIP backup ready to share.');
    } catch (e) {
      if (mounted) _toast(context, 'Could not create ZIP: ${_errText(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    final approx = r == null ? null : (_photos ? r.totalBytes : r.dbBytes);
    return Scaffold(
      appBar: AppBar(title: const Text('Export ZIP backup', style: TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _panelTitle('What goes in the ZIP', 'The ZIP always contains your warranty database. You can share it by email, chat or save it to Files.'),
          _switchRow(Icons.photo_library_outlined, 'Include receipt photos', r == null ? 'Calculating size…' : '${r.photoCount} ${r.photoCount == 1 ? 'photo' : 'photos'} • ${formatBytes(r.photoBytes)}', _photos, (v) => setState(() => _photos = v)),
          _switchRow(Icons.table_view_outlined, 'Add a CSV summary', 'A spreadsheet copy of every record, for reading outside the app', _csv, (v) => setState(() => _csv = v)),
          const Divider(height: 22),
          _infoRow('Approximate size', approx == null ? '…' : formatBytes(approx)),
        ])),
        const SizedBox(height: 16),
        SizedBox(height: 52, child: FilledButton.icon(onPressed: _busy ? null : _export, icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.ios_share), label: Text(_busy ? 'Preparing…' : 'Create & share ZIP'))),
      ]),
    );
  }
}

// ---------------------------------------------------------------- local storage

class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});
  @override State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  StorageReport? _report;
  String? _error;
  bool _busy = false;

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final r = await LocalDataService.instance.storageReport();
      if (!mounted) return;
      setState(() { _report = r; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = _errText(e));
    }
  }

  Future<void> _clean(Future<int> Function() action, String doneLabel) async {
    setState(() => _busy = true);
    try {
      final freed = await action();
      await _load();
      if (mounted) _toast(context, '$doneLabel ${formatBytes(freed)} freed.');
    } catch (e) {
      if (mounted) _toast(context, 'Could not clean up: ${_errText(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return Scaffold(
      appBar: AppBar(title: const Text('Local storage', style: TextStyle(fontWeight: FontWeight.w800)), actions: [IconButton(tooltip: 'Refresh', onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh))]),
      body: r == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
          : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(16), children: [
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _panelTitle('Used by WarrantyVault', formatBytes(r.totalBytes)),
          _infoRow('Registered items', '${r.itemCount}'),
          _infoRow('Database', formatBytes(r.dbBytes)),
          _infoRow('Receipt photos', '${r.photoCount} • ${formatBytes(r.photoBytes)}'),
          _infoRow('Temporary files', formatBytes(r.cacheBytes)),
        ])),
        const SizedBox(height: 14),
        _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _panelTitle('Free up space', 'Neither action touches your warranty records or the photos attached to them.'),
          OutlinedButton.icon(
            onPressed: _busy || r.orphanCount == 0 ? null : () async {
              final ok = await _confirm(context, 'Remove unused photos?', '${r.orphanCount} photo ${r.orphanCount == 1 ? 'file is' : 'files are'} not attached to any purchase (${formatBytes(r.orphanBytes)}). They will be deleted.', 'Remove', danger: true);
              if (ok) await _clean(LocalDataService.instance.removeOrphans, 'Unused photos removed,');
            },
            icon: const Icon(Icons.image_not_supported_outlined),
            label: Text(r.orphanCount == 0 ? 'No unused photos' : 'Remove ${r.orphanCount} unused ${r.orphanCount == 1 ? 'photo' : 'photos'} (${formatBytes(r.orphanBytes)})'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy || r.cacheBytes == 0 ? null : () => _clean(LocalDataService.instance.clearCache, 'Temporary files cleared,'),
            icon: const Icon(Icons.cleaning_services_outlined),
            label: Text(r.cacheBytes == 0 ? 'No temporary files' : 'Clear temporary files (${formatBytes(r.cacheBytes)})'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
        ])),
      ])),
    );
  }
}