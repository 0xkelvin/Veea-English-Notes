import 'package:flutter/material.dart';

import '../../core/theme/pixel_palette.dart';

/// Modern vector icon wrapper preserving the [PixelGlyph] API used across the app.
class PixelIcon extends StatelessWidget {
  const PixelIcon(this.glyph, {super.key, this.color, this.scale = 2});

  final PixelGlyph glyph;
  final Color? color;

  /// Legacy scale factor (default 2 -> ~18px icon).
  final double scale;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? context.palette.ink;
    final size = (scale * 9.0).clamp(14.0, 36.0);

    return Icon(
      glyph.iconData,
      size: size,
      color: effectiveColor,
    );
  }
}

/// Semantic icon catalog mapped to crisp, modern rounded vector icons.
class PixelGlyph {
  const PixelGlyph._(this.iconData);

  final IconData iconData;

  static const plus = PixelGlyph._(Icons.add_rounded);
  static const close = PixelGlyph._(Icons.close_rounded);
  static const arrowUp = PixelGlyph._(Icons.keyboard_arrow_up_rounded);
  static const arrowDown = PixelGlyph._(Icons.keyboard_arrow_down_rounded);
  static const arrowLeft = PixelGlyph._(Icons.chevron_left_rounded);
  static const arrowRight = PixelGlyph._(Icons.chevron_right_rounded);
  static const search = PixelGlyph._(Icons.search_rounded);
  static const speaker = PixelGlyph._(Icons.volume_up_rounded);
  static const pencil = PixelGlyph._(Icons.edit_rounded);
  static const trash = PixelGlyph._(Icons.delete_outline_rounded);
  static const check = PixelGlyph._(Icons.check_rounded);
  static const cloud = PixelGlyph._(Icons.cloud_outlined);
  static const calendar = PixelGlyph._(Icons.calendar_today_rounded);
  static const cards = PixelGlyph._(Icons.style_rounded);
  static const sword = PixelGlyph._(Icons.bolt_rounded);
  static const flame = PixelGlyph._(Icons.local_fire_department_rounded);
  static const trophy = PixelGlyph._(Icons.emoji_events_rounded);
  static const star = PixelGlyph._(Icons.auto_awesome_rounded);
  static const gamepad = PixelGlyph._(Icons.sports_esports_rounded);
  static const heart = PixelGlyph._(Icons.favorite_rounded);
  static const shield = PixelGlyph._(Icons.verified_user_rounded);
  static const skull = PixelGlyph._(Icons.warning_amber_rounded);
  static const bolt = PixelGlyph._(Icons.bolt_rounded);
  static const repeat = PixelGlyph._(Icons.repeat_rounded);
  static const shuffle = PixelGlyph._(Icons.shuffle_rounded);
  static const link = PixelGlyph._(Icons.link_rounded);
  static const gear = PixelGlyph._(Icons.settings_rounded);
  static const alien = PixelGlyph._(Icons.smart_toy_rounded);
  static const brick = PixelGlyph._(Icons.grid_view_rounded);
  static const frog = PixelGlyph._(Icons.eco_rounded);
  static const pacman = PixelGlyph._(Icons.catching_pokemon_rounded);
  static const tetris = PixelGlyph._(Icons.extension_rounded);
  static const fish = PixelGlyph._(Icons.waves_rounded);
  static const target = PixelGlyph._(Icons.my_location_rounded);
  static const fire = PixelGlyph._(Icons.whatshot_rounded);
  static const headphones = PixelGlyph._(Icons.headphones_rounded);
  static const cassette = PixelGlyph._(Icons.album_rounded);
  static const pet = PixelGlyph._(Icons.pets_rounded);
  static const food = PixelGlyph._(Icons.restaurant_rounded);
  static const camera = PixelGlyph._(Icons.camera_alt_rounded);
  static const wand = PixelGlyph._(Icons.auto_fix_high_rounded);
  static const scan = PixelGlyph._(Icons.document_scanner_rounded);
  static const clipboard = PixelGlyph._(Icons.content_paste_rounded);
}
