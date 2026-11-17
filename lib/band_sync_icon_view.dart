import 'package:flutter/material.dart';

import 'band_sync_icon.dart';

/// Material icons for [bandSyncIconShapes], in the same order. The CYD
/// follower's bitmaps are rendered from these too
/// (tool/render_session_icons_test.dart).
const List<IconData> bandSyncIconGlyphs = [
  Icons.star,
  Icons.anchor,
  Icons.favorite,
  Icons.bolt,
  Icons.dark_mode,
  Icons.light_mode,
  Icons.cloud,
  Icons.key,
  Icons.local_fire_department,
  Icons.eco,
  Icons.pets,
  Icons.rocket_launch,
  Icons.beach_access,
  Icons.notifications,
  Icons.diamond,
  Icons.water_drop,
];

Color bandSyncIconColor(BandSyncIcon icon) => Color(0xFF000000 | icon.rgb);

/// A session icon in its colour on a dark disc, so it reads the same on any
/// background.
class BandSyncIconBadge extends StatelessWidget {
  const BandSyncIconBadge(this.icon, {super.key, this.size = 24});

  final BandSyncIcon icon;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: icon.name,
    child: Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Color(0xFF121018),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(
        bandSyncIconGlyphs[icon.shape],
        size: size * 0.68,
        color: bandSyncIconColor(icon),
      ),
    ),
  );
}

/// Lets the leader choose the band's icon. Returns null if cancelled.
Future<BandSyncIcon?> showBandSyncIconPicker(
  BuildContext context,
  BandSyncIcon current,
) => showDialog<BandSyncIcon>(
  context: context,
  builder: (_) => _IconPickerDialog(current),
);

class _IconPickerDialog extends StatefulWidget {
  const _IconPickerDialog(this.initial);

  final BandSyncIcon initial;

  @override
  State<_IconPickerDialog> createState() => _IconPickerDialogState();
}

class _IconPickerDialogState extends State<_IconPickerDialog> {
  late int _shape = widget.initial.shape;
  late int _colour = widget.initial.colour;

  BandSyncIcon get _icon => BandSyncIcon.of(shape: _shape, colour: _colour);

  @override
  Widget build(BuildContext context) {
    final colour = bandSyncIconColor(_icon);
    return AlertDialog(
      title: const Text('Band icon'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BandSyncIconBadge(_icon, size: 72),
            const SizedBox(height: 8),
            Text(_icon.name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              'Followers see this icon, so bandmates can check they '
              'joined the right leader.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 16),
            // Four per row: a 4 x 4 grid of shapes.
            SizedBox(
              width: 4 * 48 + 3 * 4,
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < bandSyncIconGlyphs.length; i++)
                    IconButton(
                      tooltip: bandSyncIconShapes[i],
                      isSelected: i == _shape,
                      style: IconButton.styleFrom(
                        backgroundColor: i == _shape
                            ? colour.withValues(alpha: 0.2)
                            : null,
                      ),
                      icon: Icon(
                        bandSyncIconGlyphs[i],
                        color: i == _shape ? colour : null,
                      ),
                      onPressed: () => setState(() => _shape = i),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var c = 0; c < bandSyncIconColourNames.length; c++)
                  Tooltip(
                    message: bandSyncIconColourNames[c],
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => _colour = c),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Color(0xFF000000 | bandSyncIconColourRgb[c]),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: c == _colour
                                ? Theme.of(context).colorScheme.onSurface
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _icon),
          child: const Text('Use this icon'),
        ),
      ],
    );
  }
}
