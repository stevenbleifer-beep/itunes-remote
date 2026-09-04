-- argv: <name> [<folder name>]. Returns the new playlist's persistent ID and
-- name, then the folder's persistent ID and name when it was filed in one.
-- The folder is made if it does not exist yet.
on run argv
    set US to character id 31
    set nm to (item 1 of argv) as text
    set folderName to ""
    if (count of argv) > 1 then set folderName to (item 2 of argv) as text
    tell application "iTunes"
        if folderName is "" then
            set pl to make new user playlist with properties {name:nm}
            return (persistent ID of pl) & US & (name of pl)
        end if
        if not (exists folder playlist folderName) then
            make new folder playlist with properties {name:folderName}
        end if
        set fp to folder playlist folderName
        set pl to make new user playlist at fp with properties {name:nm}
        return (persistent ID of pl) & US & (name of pl) & US & (persistent ID of fp) & US & (name of fp)
    end tell
end run
