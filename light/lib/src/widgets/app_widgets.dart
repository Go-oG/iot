import 'package:flutter/material.dart';
import 'package:light/src/app/theme.dart';
import 'package:marquee/marquee.dart';

class AppPageHeader extends StatelessWidget {
  const AppPageHeader({required this.title, required this.subtitle, this.action, super.key});

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
                  style: const TextStyle(fontSize: 27, height: 1.05, fontWeight: FontWeight.w800, letterSpacing: -0.8),
                ),
                const SizedBox(height: 5),
                Text(subtitle, style: const TextStyle(color: AppColors.muted, fontSize: 14)),
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
        boxShadow: const [BoxShadow(color: Color(0x0A0A3B7A), blurRadius: 16, offset: Offset(0, 5))],
      ),
      child: child,
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(
    this.title, {
    this.titleIcon,
    this.trailing,
    super.key,
    this.titleMaxWidth = double.infinity,
    this.textStyle = const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
  });

  final String title;
  final TextStyle textStyle;
  final double titleMaxWidth;
  final Widget? titleIcon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.max,
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: MarqueeText(text: title, textStyle: textStyle, maxWidth: titleMaxWidth),
              ),
              if (titleIcon != null) ...[const SizedBox(width: 6), titleIcon!],
            ],
          ),
        ),
        if (trailing != null) const SizedBox(width: 8),
        ?trailing,
      ],
    );
  }
}

class AppIconButton extends StatelessWidget {
  const AppIconButton({required this.icon, required this.onPressed, this.filled = false, this.tooltip, super.key});

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
  const StatusPill({required this.label, required this.color, this.icon, super.key});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)],
          Text(
            label,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class OnlineStatusView extends StatelessWidget {
  final EdgeInsets margin;

  const OnlineStatusView({required this.online, super.key, this.margin = EdgeInsets.zero});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.green : AppColors.grey;
    return Container(
      margin: margin,
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
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
          colors: [accent.withValues(alpha: 0.45), accent, const Color(0xFF0C2559)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(right: 13, top: 10, child: Icon(Icons.water_rounded, color: Colors.white, size: 23)),
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
              color: (enabled ? AppColors.blue : AppColors.muted).withValues(alpha: 0.32),
              blurRadius: 14,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(Icons.power_settings_new_rounded, color: Colors.white),
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
            child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
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

class MarqueeText extends StatelessWidget {
  final String text;
  final TextStyle textStyle;
  final double maxWidth;

  const MarqueeText({super.key, required this.text, required this.textStyle, this.maxWidth = double.infinity});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final style = DefaultTextStyle.of(context).style.merge(textStyle);
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final width = painter.width;
          final height = painter.height;
          painter.dispose();
          // 短标题直接显示，溢出的标题在有界视口内滚动
          if (!constraints.hasBoundedWidth || width <= constraints.maxWidth) {
            return Text(text, style: style, maxLines: 1);
          }
          return SizedBox(
            width: constraints.maxWidth,
            height: height,
            child: Marquee(
              text: text,
              style: style,
              scrollAxis: Axis.horizontal,
              crossAxisAlignment: CrossAxisAlignment.start,
              blankSpace: 20.0,
              velocity: 100.0,
              pauseAfterRound: const Duration(seconds: 1),
              startPadding: 10.0,
              accelerationDuration: const Duration(seconds: 1),
              accelerationCurve: Curves.linear,
              decelerationDuration: const Duration(milliseconds: 500),
              decelerationCurve: Curves.easeOut,
            ),
          );
        },
      ),
    );
  }
}
