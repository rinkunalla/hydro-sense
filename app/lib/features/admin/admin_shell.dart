import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/theme.dart';

class _Dest {
  const _Dest(this.path, this.label, this.icon);

  final String path;
  final String label;
  final IconData icon;
}

const _destinations = [
  _Dest('/devices', 'Devices', Icons.memory),
  _Dest('/account', 'Account', Icons.person_outline),
];

/// Left NavigationRail, content max 1200 px; a drawer under 800 px wide
/// (docs/UI_UX_SPEC.md section 3).
class AdminShell extends StatelessWidget {
  const AdminShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  int get _index {
    final i = _destinations.indexWhere((d) => location.startsWith(d.path));
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final wide =
        MediaQuery.sizeOf(context).width >= AppConfig.adminRailBreakpoint;
    final content = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppConfig.adminMaxContentWidth,
        ),
        child: child,
      ),
    );
    final title = Text('Hydro Sense admin · ${_destinations[_index].label}');

    if (!wide) {
      return Scaffold(
        appBar: AppBar(title: title),
        drawer: Drawer(
          child: SafeArea(
            child: ListView(
              children: [
                for (var i = 0; i < _destinations.length; i++)
                  ListTile(
                    leading: Icon(_destinations[i].icon),
                    title: Text(_destinations[i].label),
                    selected: i == _index,
                    onTap: () {
                      Navigator.pop(context);
                      context.go(_destinations[i].path);
                    },
                  ),
              ],
            ),
          ),
        ),
        body: content,
      );
    }
    return Scaffold(
      appBar: AppBar(title: title),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            labelType: NavigationRailLabelType.all,
            backgroundColor: AppColors.surface,
            onDestinationSelected: (i) => context.go(_destinations[i].path),
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: content),
        ],
      ),
    );
  }
}
