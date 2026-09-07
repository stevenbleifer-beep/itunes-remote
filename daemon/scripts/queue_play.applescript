-- argv: <queuePersistentID>
--
-- Plays one of the app's queue playlists — the *playlist*, not a track in it,
-- which is what makes iTunes move through it by itself instead of falling
-- back into the library. Already filled by queue_fill, so this is one fast
-- command and can be run right at the end of a song.
on run argv
    set US to character id 31
    set qpid to (item 1 of argv) as text
    tell application "iTunes"
        set pl to first user playlist whose persistent ID is qpid
        if (count of tracks of pl) is 0 then error "the queue playlist is empty"
        play pl
        return (persistent ID of current track) & US & ((count of tracks of pl) as text)
    end tell
end run
