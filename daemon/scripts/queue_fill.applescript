-- argv: <folderName> <playlistName> <queuePersistentID or ""> <trackPid1> ...
--
-- Fills one of the app's two queue playlists and returns it. Nothing is
-- played: iTunes reads a playlist once, when told to play it, and editing the
-- one it is playing from loses its place — so the batch that comes next is
-- built in the *other* playlist while this one plays, and switched to with
-- queue_play, which is one fast command at the boundary.
--
-- Only ever the app's own playlists, and only their membership: no file is
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
