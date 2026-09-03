-- argv: <name>. Returns the new playlist's persistent ID and name.
on run argv
    set US to character id 31
    set nm to (item 1 of argv) as text
    tell application "iTunes"
        set pl to make new user playlist with properties {name:nm}
        return (persistent ID of pl) & US & (name of pl)
    end tell
end run
