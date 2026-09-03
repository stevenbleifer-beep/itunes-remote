-- Returns one record: state, volume, position, persistentID, databaseID, name, artist, album, duration, playlistName, playlistPersistentID
on run argv
    set US to character id 31
    tell application "iTunes"
        set st to "stopped"
        if player state is playing then
            set st to "playing"
        else if player state is paused then
            set st to "paused"
        end if
        set vol to sound volume
        set pos to 0
        set pid to ""
        set dbid to 0
        set nm to ""
        set ar to ""
        set al to ""
        set dur to 0
        set plName to ""
        set plPid to ""
        try
            set t to current track
            set pid to persistent ID of t
            set dbid to database ID of t
            set nm to name of t
            set ar to artist of t
            set al to album of t
            set dur to duration of t
            try
                set pos to player position
            end try
            try
                set plName to name of current playlist
                set plPid to persistent ID of current playlist
            end try
        end try
        return st & US & vol & US & pos & US & pid & US & dbid & US & nm & US & ar & US & al & US & dur & US & plName & US & plPid
    end tell
end run
