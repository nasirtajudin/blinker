import 'package:flutter/material.dart';

class BlToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const BlToggle({super.key, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 37,
          height: 22,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: value ? const Color(0xFFE93755) : const Color(0xFF443940),
          ),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? Colors.white : const Color(0xFFD8CDD3),
            ),
          ),
        ),
      );
}
