# Work status (26 Oct 2026)

## Branches
- `main` - timing-clean baseline (tag v2026-timing-clean)
- `tape` - tape support: UEF load (incl. gzip), ACIA/Serial ULA, tape sound
  Low/Medium/Loud/Off, LED, menu messages. Includes inflate timing fix (361e949 equivalent).
- `video-timing` - tape + hoglet67 2022 video timing fixes (6845, SAA5050, 6522, video ULA,
  clock slots). Menu version shows "timing-<date>". CURRENTLY CHECKED OUT.

## Last build (video-timing, 26 Oct 01:55)
- Compiled OK. Worst setup slack -0.541 ns, TNS -12.9 (was -0.977 / -67 before inflate fix).
- report_failing_paths.bat crashed (Quartus 17 bug); now runs single-threaded - re-run it.

## To do next
1. Re-run scripts\report_failing_paths.bat, check remaining failing paths.
2. Test on MiSTer: compressed UEF that gave "Bad program" (inflate fix), uncompressed UEF,
   Mode 7 text/cursor/edges, graphics modes, games/demos, Model B and Master.
3. Remaining known timing paths (pre-existing): sd_lba -> hps_io, odd_field/r0_teletext ->
   video_calc, user_via -> SD timeout.

## Future ideas
- Z80 second processor (T80 already in tree; hoglet Matchbox reference) - start here.
- 80186 (Master 512) and ARM Evaluation System - need large external RAM path.
