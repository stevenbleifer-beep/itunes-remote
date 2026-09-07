-- argv: <folderName> <playlistName> <queuePersistentID or ""> <trackPid1> ...
--
-- Empties the app's queue playlist, puts the given tracks in it, and returns
-- it: persistent ID, name, count. Nothing is played; queue_play does that.
--
-- The point of the playlist: a track played by reference is a one-off to
-- iTunes, and with nothing behind it iTunes stops when it ends — which is
-- what the app wants, since it decides what follows. But a playlist iTunes
-- was once told to play stays its standing source for days, resumed after
-- every one-off. Playing this playlist with one song in it replaces that
-- source with one that is used up as soon as the song is.
--
-- Only ever the app's own playlist, and only its membership: no file is
-- touched and no other playlist is read or written.
on run argv
    set US to character id 31
    set folderName to item 1 of argv
    set plName to item 2 of argv
    set qpid to item 3 of argv
    set pids to items 4 thru -1 of argv
    tell application "iTunes"
        set pl to my findQueue(folderName, plName, qpid)
        if (smart of pl) then error "the queue playlist is smart"
        repeat with i from (count of tracks of pl) to 1 by -1
            delete track i of pl
        end repeat
        repeat with p in pids
            try
                duplicate (first track of library playlist 1 whose persistent ID is (p as text)) to pl
            end try
        end repeat
        return (persistent ID of pl) & US & (name of pl) & US & ((count of tracks of pl) as text)
    end tell
end run

on findQueue(folderName, plName, qpid)
    tell application "iTunes"
        if qpid is not "" then
            try
                set pl to first user playlist whose persistent ID is qpid
                if (name of pl) is plName then return pl
            end try
        end if
        if not (exists folder playlist folderName) then
            make new folder playlist with properties {name:folderName}
        end if
        set fp to folder playlist folderName
        repeat with p in (get every user playlist)
            if (name of p) is plName then
                try
                    if (persistent ID of (parent of p)) is (persistent ID of fp) then return p
                end try
            end if
        end repeat
        return (make new user playlist at fp with properties {name:plName})
    end tell
end findQueue
