# Booking windows

A booking window has a start day and an end day, both `YYYY-MM-DD`.

- The window is **inclusive on both ends**: a booking on the start day or on the
  end day is inside the window.
- A booking the day before the start or the day after the end is outside.
- `in_window <day> <start> <end>` in `lib/window.sh` returns 0 when the day is
  inside and 1 when it is outside.
