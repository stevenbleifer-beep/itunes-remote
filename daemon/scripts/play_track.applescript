-- argv: trackPersistentID [playlistPersistentID]
-- Plays the track in the library, or inside the given playlist so that
-- "next" continues through that playlist.
on run argv
    set pid to item 1 of argv
    set plPid to ""
    if (count of argv) > 1 then set plPid to item 2 of argv
    tell application "iTunes"
        if plPid is "" then
            set t to first track of library playlist 1 whose persistent ID is pid
        else
            set pl to first user playlist whose persistent ID is plPid
            set t to first track of pl whose persistent ID is pid
        end if
        play t
        return persistent ID of current track
    end tell
end run
