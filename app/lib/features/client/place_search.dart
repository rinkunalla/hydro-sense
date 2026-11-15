import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/glass.dart';
import '../../core/theme.dart';
import '../../data/places.dart';

/// "Search a place or building": suggestions appear while typing, after a
/// short pause (Google Places through placeSuggest, D46). Shown only over a
/// Google map, as Google's terms require.
class PlaceSearchBar extends ConsumerStatefulWidget {
  const PlaceSearchBar({super.key, required this.onPick, this.near});

  final ValueChanged<Place> onPick;

  /// The map's centre, so nearby places come first.
  final LatLng? Function()? near;

  @override
  ConsumerState<PlaceSearchBar> createState() => _PlaceSearchBarState();
}

class _PlaceSearchBarState extends ConsumerState<PlaceSearchBar> {
  final _c = TextEditingController();
  final _focus = FocusNode();
  String _session = newPlacesSession();
  Timer? _pause;
  int _seq = 0;
  bool _busy = false;
  String? _message;
  List<PlaceSuggestion>? _results;

  @override
  void dispose() {
    _pause?.cancel();
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _errorText(Object e) => switch (callableDetails(e).code) {
    'SEARCH_OFF' => 'Place search is off for now. Move the map by hand.',
    'PLACES_USER_LIMIT' =>
      "You've searched a lot today. Try again tomorrow, or move the map by hand.",
    'PLACES_PROJECT_LIMIT' =>
      'Place search is resting until tomorrow. Move the map by hand.',
    'QUERY_INVALID' => 'Type at least ${AppConfig.placeQueryMin} letters.',
    _ => "Search isn't working right now. Check your internet.",
  };

  void _typed(String text) {
    _pause?.cancel();
    final q = text.trim();
    if (q.length < AppConfig.placeQueryMin) {
      _seq++; // drop any answer still on its way
      setState(() {
        _busy = false;
        _results = null;
        _message = null;
      });
      return;
    }
    setState(() {});
    _pause = Timer(
      const Duration(milliseconds: AppConfig.placeTypingPauseMs),
      () => _suggest(q),
    );
  }

  Future<void> _suggest(String q) async {
    final id = ++_seq;
    setState(() => _busy = true);
    try {
      final r = await ref
          .read(placeSearchProvider)
          .suggest(q, _session, near: widget.near?.call());
      if (!mounted || id != _seq) return; // a newer search is on its way
      setState(() {
        _results = r;
        _message = r.isEmpty
            ? 'No places found. Try another name or a nearby landmark.'
            : null;
      });
    } catch (e) {
      if (!mounted || id != _seq) return;
      setState(() {
        _results = null;
        _message = _errorText(e);
      });
    } finally {
      if (mounted && id == _seq) setState(() => _busy = false);
    }
  }

  Future<void> _pick(PlaceSuggestion s) async {
    _pause?.cancel();
    final id = ++_seq;
    _focus.unfocus();
    setState(() => _busy = true);
    try {
      final at = await ref
          .read(placeSearchProvider)
          .locate(s.placeId, _session);
      if (!mounted || id != _seq) return;
      _session = newPlacesSession(); // that search is over
      _c.text = s.main;
      setState(() {
        _results = null;
        _message = null;
      });
      widget.onPick(Place(s.main, at.latitude, at.longitude));
    } catch (e) {
      if (mounted && id == _seq) setState(() => _message = _errorText(e));
    } finally {
      if (mounted && id == _seq) setState(() => _busy = false);
    }
  }

  void _submitted(String text) {
    final r = _results;
    if (r != null && r.isNotEmpty) {
      _pick(r.first);
    } else if (text.trim().length >= AppConfig.placeQueryMin) {
      _pause?.cancel();
      _suggest(text.trim());
    } else {
      setState(
        () => _message = 'Type at least ${AppConfig.placeQueryMin} letters.',
      );
    }
  }

  void _clear() {
    _pause?.cancel();
    _seq++;
    setState(() {
      _c.clear();
      _busy = false;
      _results = null;
      _message = null;
    });
  }

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
            onChanged: _typed,
            onSubmitted: _submitted,
            decoration: InputDecoration(
              hintText: 'Search a place or building',
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
                  : _c.text.isNotEmpty
                  ? IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: _clear,
                    )
                  : null,
            ),
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
                    onTap: _busy ? null : () => _pick(p),
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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  p.main,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.strong.copyWith(fontSize: 14),
                                ),
                                if (p.secondary.isNotEmpty)
                                  Text(
                                    p.secondary,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.note.copyWith(fontSize: 12),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
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

/// Glass pill with an icon and its words, for map actions (full screen,
/// back to the pipeline, use my location).
class MapPillButton extends StatelessWidget {
  const MapPillButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: Material(
      color: const Color(0xF2FFFFFF),
      shape: const StadiumBorder(side: BorderSide(color: AppColors.rim)),
      elevation: 2,
      shadowColor: const Color(0x290A1B2E),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: busy ? null : onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : Icon(icon, size: 20, color: AppColors.deepCyan),
                const SizedBox(width: AppSpace.s),
                // Wraps instead of overflowing with large text.
                Flexible(
                  child: Text(
                    label,
                    maxLines: 2,
                    style: AppText.strong.copyWith(fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
