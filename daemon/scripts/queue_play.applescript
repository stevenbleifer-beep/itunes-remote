-- argv: <queuePersistentID>
--
-- Plays the app's queue playlist — the *playlist*, not a track in it. That
-- makes the playlist iTunes' standing source, replacing whatever it was
-- holding; filled with one song by queue_fill, the source is used up as
-- soon as that song is, and iTunes goes back to stopping after each track
-- the app plays by reference.
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
