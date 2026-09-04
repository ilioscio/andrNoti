import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
String _dateLabel(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// A date navigation bar: ‹ prev · label (opens calendar) · next › · 📅.
/// Won't page past today; [eventDays] dots the days that have data.
class DateNavBar extends StatelessWidget {
  const DateNavBar({
    super.key,
    required this.day,
    required this.onChanged,
    this.eventDays,
  });

  final DateTime day; // date-only
  final ValueChanged<DateTime> onChanged;
  final Set<DateTime>? eventDays;

  bool get _isToday {
    final n = DateTime.now();
    return day.year == n.year && day.month == n.month && day.day == n.day;
  }

  Future<void> _open(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => CalendarSheet(
        selected: day,
        eventDays: eventDays,
        onSelected: (d) {
          Navigator.pop(context);
          onChanged(dateOnly(d));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => onChanged(dateOnly(day.subtract(const Duration(days: 1)))),
          ),
          Expanded(
            child: InkWell(
              onTap: () => _open(context),
              child: Center(
                child: Text(
                  _dateLabel(day),
                  style: const TextStyle(fontWeight: FontWeight.w500, letterSpacing: 0.5),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _isToday ? null : () => onChanged(dateOnly(day.add(const Duration(days: 1)))),
          ),
          IconButton(
            icon: const Icon(Icons.calendar_month_outlined),
            tooltip: 'Pick a day',
            onPressed: () => _open(context),
          ),
        ],
      ),
    );
  }
}

/// A themed month calendar in a bottom sheet. [eventDays] adds a marker dot to
/// days that have data.
class CalendarSheet extends StatefulWidget {
  const CalendarSheet({
    super.key,
    required this.selected,
    required this.onSelected,
    this.eventDays,
  });

  final DateTime selected;
  final ValueChanged<DateTime> onSelected;
  final Set<DateTime>? eventDays;

  @override
  State<CalendarSheet> createState() => _CalendarSheetState();
}

class _CalendarSheetState extends State<CalendarSheet> {
  late DateTime _focused =
      widget.selected.isAfter(DateTime.now()) ? DateTime.now() : widget.selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
      child: TableCalendar<int>(
        firstDay: DateTime(2020, 1, 1),
        lastDay: DateTime.now(),
        focusedDay: _focused,
        currentDay: DateTime.now(),
        selectedDayPredicate: (d) => isSameDay(d, widget.selected),
        onDaySelected: (selected, focused) => widget.onSelected(selected),
        onPageChanged: (focused) => _focused = focused,
        eventLoader: (d) =>
            (widget.eventDays?.contains(dateOnly(d)) ?? false) ? const [0] : const [],
        availableCalendarFormats: const {CalendarFormat.month: 'Month'},
        headerStyle: const HeaderStyle(formatButtonVisible: false, titleCentered: true),
        calendarStyle: CalendarStyle(
          todayDecoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.3),
            shape: BoxShape.circle,
          ),
          selectedDecoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
          markerDecoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
          markersMaxCount: 1,
        ),
      ),
    );
  }
}
