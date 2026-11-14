import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/places.dart';

/// "Search a town, barangay or landmark": searches only when the person taps
/// Search or the keyboard's search key, never while typing (Nominatim policy).
class PlaceSearchBar extends ConsumerStatefulWidget {
  const PlaceSearchBar({super.key, required this.onPick});

  final ValueChanged<Place> onPick;

  @override
  ConsumerState<PlaceSearchBar> createState() => _PlaceSearchBarState();
}

class _PlaceSearchBarState extends ConsumerState<PlaceSearchBar> {
  final _c = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _message;
  List<Place>? _results;

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _c.text.trim();
    if (q.length < AppConfig.placeQueryMin) {
      setState(() {
        _results = null;
        _message = 'Type at least ${AppConfig.placeQueryMin} letters.';
      });
      return;
    }
    _focus.unfocus();
    setState(() {
      _busy = true;
      _message = null;
      _results = null;
    });
    try {
      final r = await ref.read(placeSearchProvider).search(q);
      if (!mounted) return;
      setState(() {
        _results = r;
        _message = r.isEmpty
            ? 'No places found. Try a town or barangay name.'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _message = switch (callableDetails(e).code) {
          'SEARCH_OFF' => 'Place search is off for now. Move the map by hand.',
          'SEARCH_BUSY' => 'Search is busy. Try again in a moment.',
          'QUERY_INVALID' =>
            'Type at least ${AppConfig.placeQueryMin} letters.',
          _ => "Search isn't working right now. Check your internet.",
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _pick(Place p) {
    setState(() {
      _results = null;
      _message = null;
    });
    widget.onPick(p);
  }

  void _clear() => setState(() {
    _c.clear();
    _results = null;
    _message = null;
  });

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: TextField(
            controller: _c,
            focusNode: _focus,
            maxLength: AppConfig.placeQueryMax,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Search a town, barangay or landmark',
              counterText: '',
              prefixIcon: const Icon(
                Icons.search_rounded,
                color: AppColors.deepCyan,
              ),
              suffixIcon: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_c.text.isNotEmpty || results != null)
                          IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: _clear,
                          ),
                        TextButton(
                          onPressed: _search,
                          child: const Text('Search'),
                        ),
                      ],
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (_message != null) ...[
          const SizedBox(height: AppSpace.xs),
          GlassPanel(
            radius: AppSpace.tileRadius,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.m,
              vertical: AppSpace.s,
            ),
            child: Text(_message!, style: AppText.body.copyWith(fontSize: 14)),
          ),
        ],
        if (results != null && results.isNotEmpty) ...[
          const SizedBox(height: AppSpace.xs),
          GlassPanel(
            radius: AppSpace.tileRadius,
            padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final p in results)
                  InkWell(
                    onTap: () => _pick(p),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.m,
                        vertical: AppSpace.s,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.place_outlined,
                            size: 20,
                            color: AppColors.deepCyan,
                          ),
                          const SizedBox(width: AppSpace.s),
                          Expanded(
                            child: Text(
                              p.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.body.copyWith(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.m,
                    AppSpace.xs,
                    AppSpace.m,
                    AppSpace.xs,
                  ),
                  child: Text(
                    'Search © OpenStreetMap contributors',
                    style: AppText.note.copyWith(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Round glass button that finds the phone and reports where it is.
class MyLocationButton extends ConsumerStatefulWidget {
  const MyLocationButton({super.key, required this.onFound});

  final ValueChanged<LatLng> onFound;

  @override
  ConsumerState<MyLocationButton> createState() => _MyLocationButtonState();
}

class _MyLocationButtonState extends ConsumerState<MyLocationButton> {
  bool _busy = false;

  Future<void> _locate() async {
    setState(() => _busy = true);
    try {
      final at = await ref.read(myLocationProvider).current();
      if (mounted) widget.onFound(at);
    } on LocationError catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'My location',
    excludeSemantics: true,
    child: Tooltip(
      message: 'My location',
      child: GestureDetector(
        onTap: _busy ? null : _locate,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xF2FFFFFF),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.rim),
            boxShadow: const [
              BoxShadow(color: Color(0x290A1B2E), blurRadius: 10),
            ],
          ),
          child: Center(
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Icon(
                    Icons.my_location_rounded,
                    color: AppColors.deepCyan,
                  ),
          ),
        ),
      ),
    ),
  );
}

/// The blue "you are here" dot.
class YouAreHere extends StatelessWidget {
  const YouAreHere({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'You are here',
    child: Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.royal,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Color(0x552563EB), blurRadius: 12)],
      ),
    ),
  );
}
