# iPod classic — snapshot, 2026-09-03T12:15:48

Read-only inventory taken before changing anything about how this iPod syncs.
Nothing was modified to produce it.

## Device
- Serial 8K751E7SYMU, software 1.1.2
- 23,641 items, 21.81 GiB free of 148.86 GiB
- Sync mode: selectedPlaylists; converting to 192 kbps AAC

## What is on it, and where it came from
- **23,640** tracks on the device (7,465 distinct keys explained by playlists)
- **36** playlists are selected, and they account for only **7,098** distinct tracks
- **16,175** tracks came from individually ticked artists / albums / genres

That residue is the important part: it is roughly 70% of the device, and it
would have been lost by switching to "sync only one playlist".

## Rebuilding it without guesswork
Items whose every library track is present, so almost certainly what was ticked:
- 2,329 albums
- 316 artists
- 23 genres

Those filters cover **22,532** of 23,640 tracks,
leaving **1,108** to add individually.

## The plan this supports
Keep the 36 playlists ticked so the iPod keeps its playlist
structure, add one app-owned playlist holding the residue, and untick the
individual artists/albums/genres. The device then holds the same music it does
now, and the app can drive all of it through playlist membership.

Full track list, playlist contents and residue are in the JSON beside this file.
