-- Arguments: URLs. Opens them together in a new window.
on run argv
	tell application "Google Chrome"
		set w to make new window
		set URL of active tab of w to item 1 of argv
		repeat with i from 2 to count of argv
			tell w to make new tab with properties {URL:item i of argv}
		end repeat
		set active tab index of w to 1
		activate
	end tell
end run
