-- Returns one record: state, volume, position, persistentID, databaseID, name, artist, album, duration, playlistName, playlistPersistentID
on run argv
    set US to character id 31
    tell application "iTunes"
        set pstate to "stopped"
        if player state is playing then
            set pstate to "playing"
        else if player state is paused then
            set pstate to "paused"
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
        set shuf to "false"
        if shuffle enabled then set shuf to "true"
        set rep to "off"
        if song repeat is one then
            set rep to "one"
        else if song repeat is all then
            set rep to "all"
        end if
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
        return pstate & US & vol & US & pos & US & pid & US & dbid & US & nm & US & ar & US & al & US & dur & US & plName & US & plPid & US & shuf & US & rep
    end tell
end run
