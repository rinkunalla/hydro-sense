import 'package:flutter/material.dart';

void main() {
  runApp(const HydroSenseApp());
}

// Phase 0 shell. Firebase, routing and the theme arrive in Phases 5 and 6.
class HydroSenseApp extends StatelessWidget {
  const HydroSenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Hydro Sense',
      home: Scaffold(body: Center(child: Text('Hydro Sense'))),
    );
  }
}
