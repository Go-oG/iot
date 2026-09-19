import 'package:flutter/material.dart';
import 'package:light/src/app/theme.dart';

class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    required this.title,
    required this.subtitle,
    this.action,
    super.key,
  });

  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 27,
                    height: 1.05,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: const TextStyle(color: AppColors.muted, fontSize: 14),
                ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin,
    this.color = Colors.white,
    this.borderColor,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor ?? const Color(0x0D0878F9)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0A3B7A),
            blurRadius: 16,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class AppIconButton extends StatelessWidget {
  const AppIconButton({
    required this.icon,
    required this.onPressed,
    this.filled = false,
    this.tooltip,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool filled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: filled ? AppColors.blue : AppColors.paleBlue,
        foregroundColor: filled ? Colors.white : AppColors.blue,
        minimumSize: const Size(42, 42),
      ),
      icon: Icon(icon, size: 21),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.label,
    required this.color,
    this.icon,
    super.key,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class LampGlyph extends StatelessWidget {
  const LampGlyph({this.size = 52, this.accent = AppColors.blue, super.key});

  final double size;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size * 0.68,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.white, accent.withValues(alpha: 0.22)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.only(
          topLeft: Radius.elliptical(size * 0.48, size * 0.2),
          topRight: Radius.elliptical(size * 0.48, size * 0.2),
          bottomLeft: Radius.circular(size * 0.15),
          bottomRight: Radius.circular(size * 0.15),
        ),
        border: Border.all(color: const Color(0x22071B4B)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.2),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Align(
        alignment: const Alignment(0, 0.6),
        child: Container(
          width: size * 0.5,
          height: 3,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

class SceneArtwork extends StatelessWidget {
  const SceneArtwork({required this.accent, this.height = 58, super.key});

  final Color accent;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.45),
            accent,
            const Color(0xFF0C2559),
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: 13,
            top: 10,
            child: Icon(Icons.water_rounded, color: Colors.white, size: 23),
          ),
          Positioned(
            left: -8,
            right: -8,
            bottom: -18,
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFF163867).withValues(alpha: 0.7),
                borderRadius: const BorderRadius.all(Radius.elliptical(80, 22)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PowerButton extends StatelessWidget {
  const PowerButton({super.key, required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: enabled
                ? const [Color(0xFF36A9FF), Color(0xFF0067F5)]
                : const [Color(0xFFB5C2D5), Color(0xFF7C8CA8)],
          ),
          boxShadow: [
            BoxShadow(
              color: (enabled ? AppColors.blue : AppColors.muted).withValues(
                alpha: 0.32,
              ),
              blurRadius: 14,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(
          Icons.power_settings_new_rounded,
          color: Colors.white,
        ),
      ),
    );
  }
}

class ChannelSlider extends StatelessWidget {
  const ChannelSlider({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    this.min = 0,
    this.max = 100,
    this.divisions,
    this.valueLabel,
  });

  final String label;
  final IconData icon;
  final Color color;
  final int value;
  final ValueChanged<double> onChanged;
  final Future<void> Function() onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final String? valueLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 4),
          SizedBox(
            width: 48,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: color,
                thumbColor: Colors.white,
                inactiveTrackColor: color.withValues(alpha: 0.14),
              ),
              child: Slider(
                padding: EdgeInsets.only(left: 8, right: 8),
                value: value.toDouble(),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
                onChangeEnd: (_) => onChangeEnd(),
              ),
            ),
          ),
          SizedBox(
            width: 26,
            child: Text(
              valueLabel ?? '$value',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
